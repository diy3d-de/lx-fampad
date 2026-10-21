// E2EE, vereinfachte Schlüsselverwaltung (Schalter E2EE_PW_BACKUP, Standard aus): Parameter der Passwort-Ableitung (Argon2id) und die
// opake Passwort-Sicherung des Personenschlüssels. Der Server sieht nie Passwort, authKey oder kek: Blobs sind für ihn undurchsichtiger
// Text, der Salt ist öffentlich. Blob und Salt erscheinen nie im Log oder Audit. Zeilen der Sicherung werden nie gelöscht, nur
// ersetzt (`superseded`) oder durch einen Schlüsselwechsel `stale` gesetzt (siehe rotateKeys in keys.ts).
import { and, eq, inArray, sql } from 'drizzle-orm';
import { accountKdf, keyBackupsPw, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, RequestMeta } from './context.js';
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

/**
 * Neue Passwort-Sicherung ablegen (Step-up). Sie muss zur aktuellen key_version gehören und mit dem festen Profil abgeleitet sein
 * (sonst 409 kdf_mismatch). In EINER Transaktion: die bisherige aktuelle Zeile wird `superseded`, die neue `active` mit ihrem eigenen
 * Ableitungssatz, das Audit geschrieben. Gleichzeitige Anfragen derselben Person laufen nacheinander (Sperre auf person_keys); der
 * Teil-Unique-Index sichert zusätzlich ab.
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
      .where(and(eq(keyBackupsPw.userId, p.userId), inArray(keyBackupsPw.state, ['active', 'stale'])));
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
        state: 'active',
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
  state: 'active' | 'stale';
  kdf: KdfParams;
}

/**
 * Aktuelle Passwort-Sicherung abrufen (Step-up). Abruf und Audit stehen in einer Transaktion (kein unprotokollierter Abruf).
 * `state` ist `stale`, wenn der Personenschlüssel seither gewechselt hat (die Sicherung enthält dann den alten Schlüssel).
 */
export async function getPwBackup(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<PwBackupOut> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
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
      .where(and(eq(keyBackupsPw.userId, p.userId), inArray(keyBackupsPw.state, ['active', 'stale'])));
    if (!b) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_pw_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion } });
    return {
      id: b.id,
      blob: b.blob,
      keyVersion: b.keyVersion,
      state: b.state === 'stale' ? 'stale' : 'active',
      kdf: { id: b.kdfId, memKiB: b.memKib, ops: b.ops, salt: kdfSalt(ctx, b.email, b.generation) },
    };
  });
}

/**
 * Setzt `verified_at` der Sicherung `id` (Step-up), erst nach der Round-Trip-Probe der App. Nur die eigene, noch aktuelle (`active`)
 * Zeile: fremde oder unbekannte ergeben 404, eine bereits ersetzte oder veraltete 409. Atomar mit Audit.
 */
export async function markPwBackupVerified(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const rows = await tx
      .update(keyBackupsPw)
      .set({ verifiedAt: ctx.now(), updatedAt: ctx.now() })
      .where(and(eq(keyBackupsPw.id, id), eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'active')))
      .returning({ keyVersion: keyBackupsPw.keyVersion });
    const row = rows[0];
    if (!row) {
      const [vorhanden] = await tx.select({ id: keyBackupsPw.id }).from(keyBackupsPw).where(and(eq(keyBackupsPw.id, id), eq(keyBackupsPw.userId, p.userId)));
      if (!vorhanden) throw notFound();
      throw new AppError(409, 'backup_not_current', 'Diese Sicherung ist nicht mehr aktuell.');
    }
    await writeAudit(ctx, tx, { event: 'key_backup_pw_verified', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion } });
  });
}
