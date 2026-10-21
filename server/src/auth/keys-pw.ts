// E2EE, vereinfachte Schlüsselverwaltung (Schalter E2EE_PW_BACKUP, Standard aus): Parameter der Passwort-Ableitung (Argon2id) und die
// opake Passwort-Sicherung des Personenschlüssels. Der Server sieht nie Passwort, authKey oder kek: Blobs sind für ihn undurchsichtiger
// Text, der Salt ist öffentlich. Blob und Salt erscheinen nie im Log oder Audit. Zeilen der Sicherung werden nie gelöscht, nur
// ersetzt (`superseded`) oder durch einen Schlüsselwechsel `stale` gesetzt (siehe rotateKeys in keys.ts); jede ersetzte oder veraltete Zeile bleibt über
// das Archiv (`GET /me/key-backups/archive`, keys-archive.ts) abrufbar, nie unerreichbar.
import { and, eq, inArray, sql } from 'drizzle-orm';
import { accountKdf, keyBackupsPw, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, RequestMeta, Tx } from './context.js';
import { recordSecurityEvent, viaOf, wakeAfterCommit, wakeTopics } from './security-events.js';
import { requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

/** Bekannte Ableitungsverfahren (Kennung im Blob und in der Antwort). */
export const KDF_IDS = ['argon2id-v1'] as const;

/**
 * Das feste Profil für ALLE Konten (echte wie Fake-Antworten): Der Client darf keine eigenen Zahlen setzen, und solange nicht alle
 * Konten umgestellt sind, darf kein echtes Konto ein anderes Profil zeigen als der Standard (sonst entstünde ein Orakel). Ein
 * Profilwechsel gilt nur global (neue kdf_id und Konstanten im Code), nie je Konto.
 */
export const DEFAULT_KDF = { id: 'argon2id-v1', memKiB: 65536, ops: 3 } as const;

export interface KdfParams {
  id: string;
  memKiB: number;
  ops: number;
  /** 16 Byte als Base64url. */
  salt: string;
}

/** Salt-Generation, die jedes Konto ohne eigene Zeile hat. Eine Rotation wäre eine eigene, seltene, protokollierte Aktion (nicht Teil dieses Pakets). */
export const DEFAULT_SALT_GENERATION = 1;

const notFound = () => new AppError(404, 'not_found');

/**
 * Salt der Passwort-Ableitung: bestimmt immer der Server, deterministisch aus der normalisierten E-Mail und der Generation
 * (HMAC über AUTH_SECRET_KEY). Echte und Fake-Antwort entstehen aus derselben Ableitung und sind nicht zu unterscheiden; der Client
 * liefert nie einen Salt. (Die E-Mail eines Kontos ist unveränderlich; ein Wechsel würde den Salt ändern.)
 */
export function kdfSalt(ctx: AuthContext, email: string, generation: number): string {
  return Buffer.from(ctx.keys.hmac('kdf-salt-v1', `${email.trim().toLowerCase()}|${generation}`).slice(0, 32), 'hex').toString('base64url');
}

/**
 * Parameter der Passwort-Ableitung vor der Anmeldung. Für JEDE E-Mail kommt dasselbe Profil und ein aus E-Mail und Generation
 * abgeleiteter Salt: kein Orakel für die Existenz eines Kontos. Nur eine (künftige) Salt-Rotation eines echten, nicht
 * deaktivierten Kontos würde die Generation ändern; bis dahin gibt es immer genau eine Abfrage und Generation 1.
 */
export async function getKdfParams(ctx: AuthContext, email: string): Promise<{ kdf: KdfParams }> {
  const norm = email.trim().toLowerCase();
  const [row] = await ctx.db
    .select({ generation: accountKdf.saltGeneration, disabledAt: users.disabledAt })
    .from(users)
    .leftJoin(accountKdf, eq(accountKdf.userId, users.id))
    .where(sql`lower(${users.email}) = ${norm}`)
    .limit(1);
  const generation = row && !row.disabledAt && row.generation ? row.generation : DEFAULT_SALT_GENERATION;
  return { kdf: { ...DEFAULT_KDF, salt: kdfSalt(ctx, norm, generation) } };
}

export interface PwBackupInput {
  blob: string;
  keyVersion: number;
  /** Was der Client benutzt hat; muss genau dem festen Profil entsprechen (kein Salt: den bestimmt der Server). */
  kdf: { id: string; memKiB: number; ops: number };
}

/** Eine noch nicht bestätigte Sicherung verfällt (wird `superseded`, nie gelöscht) nach dieser Zeit (Aufräumjob). */
export const PW_PENDING_TTL_MS = 3_600_000;

/**
 * Neue Passwort-Sicherung ablegen (Step-up). Sie muss zur aktuellen key_version gehören und mit dem festen Profil abgeleitet sein
 * (sonst 409 kdf_mismatch). Sie entsteht als `pending`; die bisherige aktuelle Zeile (active/stale) bleibt UNBERÜHRT und gültig, bis
 * die neue per `verified` bestätigt ist. Eine eigene ältere pending-Zeile wird `superseded`. In EINER Transaktion mit Audit;
 * gleichzeitige Anfragen derselben Person laufen nacheinander (Sperre auf person_keys), die Teil-Unique-Indizes sichern zusätzlich ab.
 */
export async function setPwBackup(ctx: AuthContext, p: SessionPrincipal, input: PwBackupInput, meta: RequestMeta): Promise<{ id: string }> {
  requireStepUp(ctx, p);
  if (input.kdf.id !== DEFAULT_KDF.id || input.kdf.memKiB !== DEFAULT_KDF.memKiB || input.kdf.ops !== DEFAULT_KDF.ops) {
    throw new AppError(409, 'kdf_mismatch', 'Die Parameter der Schlüsselableitung stimmen nicht, bitte neu laden.');
  }
  return ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    const now = ctx.now();
    await tx.insert(accountKdf).values({ userId: p.userId, createdAt: now }).onConflictDoNothing();
    const [g] = await tx.select({ generation: accountKdf.saltGeneration }).from(accountKdf).where(eq(accountKdf.userId, p.userId));
    await tx
      .update(keyBackupsPw)
      .set({ state: 'superseded', updatedAt: now })
      .where(and(eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'pending')));
    const [row] = await tx
      .insert(keyBackupsPw)
      .values({
        userId: p.userId,
        familyId: p.familyId,
        blob: input.blob,
        keyVersion: k.v,
        kdfId: DEFAULT_KDF.id,
        memKib: DEFAULT_KDF.memKiB,
        ops: DEFAULT_KDF.ops,
        saltGeneration: g?.generation ?? DEFAULT_SALT_GENERATION,
        state: 'pending',
        createdAt: now,
        updatedAt: now,
      })
      .returning({ id: keyBackupsPw.id });
    if (!row) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_pw_set', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: k.v } });
    return row;
  });
}

export interface PwBackupOut {
  id: string;
  blob: string;
  keyVersion: number;
  state: 'pending' | 'active' | 'stale';
  kdf: KdfParams;
}

/**
 * Passwort-Sicherung abrufen (Step-up). Abruf und Audit stehen in einer Transaktion (kein unprotokollierter Abruf).
 * Standard (`which = 'current'`): die aktuelle, bestätigte Sicherung; `state` ist `stale`, wenn der Personenschlüssel seither gewechselt
 * hat (die Sicherung enthält dann den alten Schlüssel). `which = 'pending'`: die eigene, noch nicht bestätigte Sicherung für den
 * Round-Trip der App (nur der Besitzer, gleiche Rechte und Protokollierung). Der Abruf der aktuellen Sicherung erzeugt ein Sicherheitsereignis
 * (`key_backup_pw_read`) samt Wecker auf die eigenen Geräte; der Round-Trip-Abruf der eigenen unbestätigten Sicherung nicht (das ist die App selbst).
 */
export async function getPwBackup(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta, which: 'current' | 'pending' = 'current'): Promise<PwBackupOut> {
  requireStepUp(ctx, p);
  const topics = which === 'current' ? await wakeTopics(ctx.db, p.userId) : [];
  const out = await ctx.db.transaction(async (tx): Promise<PwBackupOut> => {
    const [b] = await tx
      .select({
        id: keyBackupsPw.id,
        blob: keyBackupsPw.blob,
        keyVersion: keyBackupsPw.keyVersion,
        state: keyBackupsPw.state,
        kdfId: keyBackupsPw.kdfId,
        memKib: keyBackupsPw.memKib,
        ops: keyBackupsPw.ops,
        generation: keyBackupsPw.saltGeneration,
        email: users.email,
      })
      .from(keyBackupsPw)
      .innerJoin(users, eq(users.id, keyBackupsPw.userId))
      .where(and(eq(keyBackupsPw.userId, p.userId), which === 'pending' ? eq(keyBackupsPw.state, 'pending') : inArray(keyBackupsPw.state, ['active', 'stale'])));
    if (!b) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_pw_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion, which } });
    if (which === 'current') await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_pw_read', via: viaOf(p), actorId: p.userId });
    return {
      id: b.id,
      blob: b.blob,
      keyVersion: b.keyVersion,
      state: b.state === 'stale' ? 'stale' : b.state === 'pending' ? 'pending' : 'active',
      kdf: { id: b.kdfId, memKiB: b.memKib, ops: b.ops, salt: kdfSalt(ctx, b.email, b.generation) },
    };
  });
  wakeAfterCommit(ctx, p.familyId, p.userId, topics);
  return out;
}

/**
 * Bestätigt die eigene Sicherung `id` (Step-up), erst nach der Round-Trip-Probe der App: in EINER Transaktion wird die bisherige
 * aktuelle Zeile (active/stale) `superseded` und die `pending`-Zeile `active` mit `verified_at`. Vorher bleibt die alte gültig.
 * Fremde oder unbekannte ID: 404; nicht (mehr) pending, verfallen oder zu einer anderen Schlüsselversion gehörend: 409. Eine schon
 * bestätigte aktuelle Zeile bestätigt erneut folgenlos (verlorene Antwort). Atomar mit Audit.
 */
export async function markPwBackupVerified(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  await ctx.db.transaction((tx) => promotePwBackup(ctx, tx, p, id, meta));
}

/**
 * Kern von [markPwBackupVerified] in einer vorhandenen Transaktion (auch für den Passwortwechsel: neues Passwort und die dazu passende
 * Sicherung werden gemeinsam gültig, nie nur eins von beiden). Prüft das Step-up NICHT selbst (der Aufrufer hat es geprüft). Mit [nurPending] gilt nur eine unbestätigte Zeile (sonst `409 backup_not_current`).
 */
export async function promotePwBackup(ctx: AuthContext, tx: Tx, p: SessionPrincipal, id: string, meta: RequestMeta, nurPending = false): Promise<void> {
  // gleiche Sperre wie Schlüsselwechsel und Ablegen: kein Bestätigen gegen einen gerade wechselnden Schlüssel
  const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
  const [row] = await tx
    .select({ state: keyBackupsPw.state, keyVersion: keyBackupsPw.keyVersion, verifiedAt: keyBackupsPw.verifiedAt, createdAt: keyBackupsPw.createdAt })
    .from(keyBackupsPw)
    .where(and(eq(keyBackupsPw.id, id), eq(keyBackupsPw.userId, p.userId)))
    .for('update');
  if (!row) throw notFound();
  // eine unbestätigte Sicherung verfällt nach PW_PENDING_TTL_MS auch dann, wenn der Aufräumjob sie noch nicht erfasst hat
  if (nurPending && row.state === 'pending' && ctx.now().getTime() - row.createdAt.getTime() > PW_PENDING_TTL_MS) throw new AppError(409, 'backup_not_current', 'Diese Sicherung ist nicht mehr aktuell.');
  // schon bestätigt: für die einzelne Bestätigung folgenlos (verlorene Antwort); beim Passwortwechsel (nurPending) nie, dort muss es die frisch geprüfte sein
  if (!nurPending && row.state === 'active' && row.verifiedAt) return;
  if (row.state !== 'pending' || !k || k.v !== row.keyVersion) throw new AppError(409, 'backup_not_current', 'Diese Sicherung ist nicht mehr aktuell.');
  const now = ctx.now();
  await tx
    .update(keyBackupsPw)
    .set({ state: 'superseded', updatedAt: now })
    .where(and(eq(keyBackupsPw.userId, p.userId), inArray(keyBackupsPw.state, ['active', 'stale'])));
  const rows = await tx
    .update(keyBackupsPw)
    .set({ state: 'active', verifiedAt: now, updatedAt: now })
    .where(and(eq(keyBackupsPw.id, id), eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'pending')))
    .returning({ keyVersion: keyBackupsPw.keyVersion });
  if (!rows[0]) throw new AppError(409, 'backup_not_current', 'Diese Sicherung ist nicht mehr aktuell.');
  await writeAudit(ctx, tx, { event: 'key_backup_pw_verified', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: rows[0].keyVersion } });
}

/**
 * Nach einem Passwort-Reset (neuer authKey UND neuer kek): die bisherige aktuelle Sicherung ist mit dem neuen Passwort nicht mehr zu öffnen.
 * Sie wird `stale` (nie gelöscht: mit dem alten Passwort bliebe sie lesbar, der Wiederherstellungsschlüssel und die QR-Übertragung gelten
 * unverändert weiter); eine noch unbestätigte (pending) gehört zum alten kek und verfällt (`superseded`). Gehört in die Transaktion des Resets.
 * Gibt zurück, ob es eine aktuelle Sicherung gab (dann legt die App nach dem ersten Login eine neue an).
 */
export async function markPwBackupsStaleAfterReset(ctx: Pick<AuthContext, 'now'>, tx: Tx, userId: string): Promise<boolean> {
  const now = ctx.now();
  await tx.update(keyBackupsPw).set({ state: 'superseded', updatedAt: now }).where(and(eq(keyBackupsPw.userId, userId), eq(keyBackupsPw.state, 'pending')));
  const hit = await tx
    .update(keyBackupsPw)
    .set({ state: 'stale', updatedAt: now })
    .where(and(eq(keyBackupsPw.userId, userId), eq(keyBackupsPw.state, 'active')))
    .returning({ id: keyBackupsPw.id });
  return hit.length > 0;
}
