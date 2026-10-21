// E2EE-Schlüsselverwaltung (Phase 1): öffentliche Personenschlüssel, opake Schlüsselsicherung, kurzlebige Geräte-Übertragung.
// Der Server sieht und speichert nie ein Geheimnis: Blobs sind für ihn undurchsichtiger Text (mit Wiederherstellungsschlüssel bzw.
// Einmalschlüssel verschlüsselt, beides nur auf den Geräten). Alles gehört zur angemeldeten Person; Blobs und Schlüssel erscheinen nie im Log.
import { and, asc, eq, gt, isNull } from 'drizzle-orm';
import { keyBackupArchive, keyBackups, keyBackupsPw, keyTransfers, memberships, personKeyHistory, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, RequestMeta } from './context.js';
import { sha256Hex } from './crypto.js';
import { countArchive, thinReplaced } from './keys-archive.js';
import { recordDebouncedEvent, recordSecurityEvent, viaOf, wakeAfterCommit, wakeTopics } from './security-events.js';
import { requireDestructiveAllowed, requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

/** Lebensdauer einer Geräte-Übertragung. */
export const KEY_TRANSFER_TTL_SEC = 120;

export interface PublicKeys {
  publicEncKey: string;
  publicSignKey: string;
  keyVersion: number;
}

const notFound = () => new AppError(404, 'not_found');

export interface OwnKeys {
  keys: PublicKeys | null;
  hasBackup: boolean;
  pwBackupStale?: true;
  /** Zeit der letzten bestätigten, aktiven Passwort-Sicherung zur AKTUELLEN Schlüsselversion (ISO) oder null (auch ohne Schalter E2EE_PW_BACKUP). */
  pwBackupVerifiedAt: string | null;
  /** Zeit der Wiederherstellungssicherung (Wiederherstellungsschlüssel) zur aktuellen Schlüsselversion (ISO) oder null. */
  recoveryBackupAt: string | null;
  /** Anzahl archivierter Sicherungen früherer Schlüsselstände (abrufbar über `GET /me/key-backups/archive`). */
  archiveCount: number;
}

/**
 * Eigener Stand, nur Boolesches und Zeiten, nie Geheimnisse. `pwBackupStale: true` steht nur, wenn die aktuelle Passwort-Sicherung veraltet ist (nach einem
 * Passwort-Reset oder Schlüsselwechsel): die App bietet dann "Sicherung erneuern" an, ohne die (protokollierte, Step-up-pflichtige) Sicherung selbst
 * abzurufen. Sonst fehlt das Feld. `pwBackupVerifiedAt`, `recoveryBackupAt` und `archiveCount` stützen die Warnungen vor Abmelden und Löschen der App
 * auf Wissen des Servers (gibt es für den aktuellen Schlüssel wirklich eine bestätigte Sicherung?).
 */
export async function getOwnKeys(ctx: AuthContext, p: SessionPrincipal): Promise<OwnKeys> {
  const [k] = await ctx.db
    .select({ publicEncKey: personKeys.publicEncKey, publicSignKey: personKeys.publicSignKey, keyVersion: personKeys.keyVersion })
    .from(personKeys)
    .where(eq(personKeys.userId, p.userId));
  const [b] = await ctx.db.select({ v: keyBackups.keyVersion, updatedAt: keyBackups.updatedAt }).from(keyBackups).where(eq(keyBackups.userId, p.userId));
  // nur mit Schalter E2EE_PW_BACKUP (ohne ihn gibt es die Passwort-Sicherung nicht und die Antwort bleibt wie bisher)
  const [stale] = ctx.config.e2eePwBackup
    ? await ctx.db.select({ id: keyBackupsPw.id }).from(keyBackupsPw).where(and(eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'stale')))
    : [];
  const [verified] =
    ctx.config.e2eePwBackup && k
      ? await ctx.db
          .select({ at: keyBackupsPw.verifiedAt })
          .from(keyBackupsPw)
          .where(and(eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'active'), eq(keyBackupsPw.keyVersion, k.keyVersion)))
      : [];
  const hasBackup = b !== undefined && k !== undefined && b.v === k.keyVersion;
  return {
    keys: k ?? null,
    hasBackup,
    ...(stale ? { pwBackupStale: true as const } : {}),
    pwBackupVerifiedAt: verified?.at?.toISOString() ?? null,
    recoveryBackupAt: hasBackup && b ? b.updatedAt.toISOString() : null,
    archiveCount: await countArchive(ctx, p.userId, k?.keyVersion ?? 0),
  };
}

/** Erstes Schlüsselpaar der Person anlegen; gibt es schon eines, 409 (Wechsel nur über rotateKeys mit Step-up). */
export async function createKeys(ctx: AuthContext, p: SessionPrincipal, input: { publicEncKey: string; publicSignKey: string }, meta: RequestMeta): Promise<PublicKeys> {
  const created = await ctx.db.transaction(async (tx) => {
    const rows = await tx
      .insert(personKeys)
      .values({ userId: p.userId, publicEncKey: input.publicEncKey, publicSignKey: input.publicSignKey, keyVersion: 1, createdAt: ctx.now(), updatedAt: ctx.now() })
      .onConflictDoNothing()
      .returning({ publicEncKey: personKeys.publicEncKey, publicSignKey: personKeys.publicSignKey, keyVersion: personKeys.keyVersion });
    const row = rows[0];
    if (!row) throw new AppError(409, 'keys_exist', 'Es gibt schon einen Schlüssel für dich.');
    await writeAudit(ctx, tx, { event: 'key_created', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion } });
    return row;
  });
  ctx.onMembersChanged(p.familyId);
  return created;
}

/**
 * Schlüsselwechsel (Verlust aller Geräte ohne Wiederherstellung, Verdacht auf Kompromittierung): key_version steigt, offene Übertragungen gehören
 * zum alten Schlüssel und werden verworfen; der alte Stand wandert in die (nur anhängende) Historie. Die Wiederherstellungssicherung des alten
 * Schlüssels wird NIE gelöscht, sondern ins Archiv verschoben (`key_backup_archive`), die Passwort-Sicherungen bleiben in `key_backups_pw` (die aktuelle
 * wird `stale`, ältere bleiben `superseded`): beides ist über `GET /me/key-backups/archive` abrufbar, so geht der Weg zum alten Verlauf nie verloren.
 * `expectedKeyVersion` ist die Version, die der Client kennt: weicht sie ab (anderes Gerät war schneller), antwortet der Server mit 409.
 * Mit Step-up und Sperrfrist (24 h nach Zugang per Wiederherstellungscode oder Passwort-Reset, `destructive_locked`); die Person bekommt ein
 * Sicherheitsereignis samt Wecker auf ihre Geräte, die Apps der anderen warnen vor dem Wechsel.
 */
export async function rotateKeys(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { publicEncKey: string; publicSignKey: string; expectedKeyVersion: number },
  meta: RequestMeta,
): Promise<PublicKeys> {
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  const rotated = await ctx.db.transaction(async (tx) => {
    const [alt] = await tx.select().from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!alt) throw notFound();
    if (alt.keyVersion !== input.expectedKeyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    // dieselben Schlüssel unter höherer Version wären ein stiller Versionssprung ohne neuen Schlüssel: abgelehnt
    if (alt.publicEncKey === input.publicEncKey && alt.publicSignKey === input.publicSignKey) throw new AppError(409, 'keys_unchanged', 'Der neue Schlüssel entspricht dem bisherigen.');
    const now = ctx.now();
    await tx.insert(personKeyHistory).values({ userId: p.userId, keyVersion: alt.keyVersion, encKey: alt.publicEncKey, signKey: alt.publicSignKey, validFrom: alt.updatedAt, validUntil: now });
    const [row] = await tx
      .update(personKeys)
      .set({ publicEncKey: input.publicEncKey, publicSignKey: input.publicSignKey, keyVersion: alt.keyVersion + 1, updatedAt: now })
      .where(eq(personKeys.userId, p.userId))
      .returning({ publicEncKey: personKeys.publicEncKey, publicSignKey: personKeys.publicSignKey, keyVersion: personKeys.keyVersion });
    if (!row) throw notFound();
    // Wiederherstellungssicherung: ins Archiv verschieben (erst kopieren, dann aus der aktiven Tabelle nehmen), nie verwerfen
    const [bk] = await tx.select().from(keyBackups).where(eq(keyBackups.userId, p.userId)).for('update');
    if (bk) {
      await tx.insert(keyBackupArchive).values({
        userId: p.userId,
        kind: 'recovery',
        blob: bk.blob,
        keyVersion: bk.keyVersion,
        reason: 'rotation',
        backupCreatedAt: bk.createdAt,
        backupUpdatedAt: bk.updatedAt,
        archivedAt: now,
      });
      await tx.delete(keyBackups).where(eq(keyBackups.userId, p.userId));
    }
    await tx.delete(keyTransfers).where(eq(keyTransfers.userId, p.userId));
    // Passwort-Sicherung (E2EE_PW_BACKUP): nie löschen, die aktuelle gehört jetzt zum alten Schlüssel
    await tx.update(keyBackupsPw).set({ state: 'stale', updatedAt: now }).where(and(eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'active')));
    // eine unbestätigte Sicherung gehört zum alten Schlüssel und wird nie mehr aktiv
    await tx.update(keyBackupsPw).set({ state: 'superseded', updatedAt: now }).where(and(eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'pending')));
    await writeAudit(ctx, tx, { event: 'key_rotated', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion, archived: bk !== undefined } });
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_rotated', via: viaOf(p), actorId: p.userId });
    return row;
  });
  wakeAfterCommit(ctx, p.familyId, p.userId, topics);
  // andere Geräte erfahren den Schlüsselwechsel (TOFU-Warnung) ohne Neustart
  ctx.onMembersChanged(p.familyId);
  return rotated;
}

/**
 * Opake Schlüsselsicherung ablegen oder ersetzen (Step-up). Sie muss zur aktuellen key_version gehören. Wird eine vorhandene durch einen ANDEREN Blob
 * ersetzt, wandert die bisherige ins Archiv (`reason = 'replaced'`): ein Angreifer mit einer geliehenen Sitzung kann den Weg zum Schlüssel so nicht durch
 * Überschreiben mit Müll zerstören. Das Ersetzen erzeugt das Sicherheitsereignis `key_backup_replaced` und weckt die anderen Geräte der Person (die App
 * legt nur beim ersten Ablegen oder Erneuern selbst eine Sicherung an: ein unerwartetes Ersetzen soll auffallen). Das Ablegen ist nie gesperrt (auch direkt nach einem
 * Reset muss eine neue Sicherung möglich sein).
 */
export async function setBackup(ctx: AuthContext, p: SessionPrincipal, input: { blob: string; keyVersion: number }, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  const replaced = await ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    const [alt] = await tx.select().from(keyBackups).where(eq(keyBackups.userId, p.userId)).for('update');
    if (alt && alt.blob !== input.blob) {
      await tx.insert(keyBackupArchive).values({
        userId: p.userId,
        kind: 'recovery',
        blob: alt.blob,
        keyVersion: alt.keyVersion,
        reason: 'replaced',
        backupCreatedAt: alt.createdAt,
        backupUpdatedAt: alt.updatedAt,
        archivedAt: ctx.now(),
      });
      await thinReplaced(tx, p.userId);
      await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_replaced', via: viaOf(p), actorId: p.userId });
    }
    await tx
      .insert(keyBackups)
      .values({ userId: p.userId, blob: input.blob, keyVersion: k.v, createdAt: ctx.now(), updatedAt: ctx.now() })
      .onConflictDoUpdate({ target: keyBackups.userId, set: { blob: input.blob, keyVersion: k.v, updatedAt: ctx.now() } });
    await writeAudit(ctx, tx, { event: 'backup_set', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: k.v, replaced: alt !== undefined && alt.blob !== input.blob } });
    return alt !== undefined && alt.blob !== input.blob;
  });
  if (replaced) wakeAfterCommit(ctx, p.familyId, p.userId, topics);
}

/**
 * Opake Schlüsselsicherung abrufen (Step-up). Abruf und Audit-Eintrag stehen in einer Transaktion: Gelingt das Protokollieren
 * nicht, gibt es auch keine Sicherung (lieber ein Fehler als ein unprotokollierter Abruf).
 */
export async function getBackup(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<{ blob: string; keyVersion: number }> {
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  const { b, recorded } = await ctx.db.transaction(async (tx) => {
    const [b] = await tx.select({ blob: keyBackups.blob, keyVersion: keyBackups.keyVersion }).from(keyBackups).where(eq(keyBackups.userId, p.userId));
    if (!b) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion } });
    const recorded = await recordDebouncedEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_read', via: viaOf(p), actorId: p.userId });
    return { b, recorded };
  });
  if (recorded) wakeAfterCommit(ctx, p.familyId, p.userId, topics, { light: true });
  return b;
}

/** PostgreSQL-Fehler "unique_violation" (auch von drizzle verpackt, `cause`). */
function istEindeutigkeitsfehler(e: unknown): boolean {
  const x = e as { code?: unknown; cause?: { code?: unknown } } | null;
  return x?.code === '23505' || x?.cause?.code === '23505';
}

/**
 * Übertragung für ein neues Gerät anlegen (ersetzt eine offene). `lookup` ist die vom Gerät abgeleitete Suchkennung, nie der Einmalschlüssel.
 * `keyVersion` ist die Version, zu der der Blob gehört: stimmt sie nicht mit dem Server überein (Schlüssel inzwischen gewechselt), 409.
 * Kollidiert die Suchkennung mit der einer anderen Person (praktisch ausgeschlossen), antwortet der Server mit 409 statt 500.
 */
export async function createTransfer(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { lookup: string; blob: string; keyVersion: number },
): Promise<{ expiresAt: string; ttlSec: number }> {
  const now = ctx.now();
  const expiresAt = new Date(now.getTime() + KEY_TRANSFER_TTL_SEC * 1000);
  const lookupHash = sha256Hex(input.lookup);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  try {
    const recorded = await ctx.db.transaction(async (tx) => {
      const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
      if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
      if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
      await tx
        .insert(keyTransfers)
        .values({ userId: p.userId, lookupHash, blob: input.blob, keyVersion: k.v, createdAt: now, expiresAt })
        .onConflictDoUpdate({ target: keyTransfers.userId, set: { lookupHash, blob: input.blob, keyVersion: k.v, createdAt: now, expiresAt } });
      return recordDebouncedEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_transfer_created', via: viaOf(p), actorId: p.userId });
    });
    if (recorded) wakeAfterCommit(ctx, p.familyId, p.userId, topics, { light: true });
  } catch (e) {
    if (istEindeutigkeitsfehler(e)) throw new AppError(409, 'transfer_conflict', 'Bitte versuche es noch einmal.');
    throw e;
  }
  return { expiresAt: expiresAt.toISOString(), ttlSec: KEY_TRANSFER_TTL_SEC };
}

/**
 * Übertragung einlösen: genau einmal (DELETE ... RETURNING), nur durch dieselbe Person, nur vor Ablauf. Jeder Fehlschlag (unbekannt,
 * abgelaufen, schon eingelöst, fremde Person) antwortet gleich mit 404. Einlösen und Audit-Eintrag stehen in einer Transaktion: Scheitert
 * das Protokollieren, bleibt die Übertragung erhalten (der Client sieht einen Fehler und kann es innerhalb der Frist wiederholen).
 */
export async function claimTransfer(ctx: AuthContext, p: SessionPrincipal, input: { lookup: string }, meta: RequestMeta): Promise<{ blob: string; keyVersion: number }> {
  return ctx.db.transaction(async (tx) => {
    const rows = await tx
      .delete(keyTransfers)
      .where(and(eq(keyTransfers.userId, p.userId), eq(keyTransfers.lookupHash, sha256Hex(input.lookup)), gt(keyTransfers.expiresAt, ctx.now())))
      .returning({ blob: keyTransfers.blob, keyVersion: keyTransfers.keyVersion });
    const row = rows[0];
    if (!row) throw notFound();
    await writeAudit(ctx, tx, { event: 'transfer_claimed', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion } });
    await recordDebouncedEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_transfer_claimed', via: viaOf(p), actorId: p.userId });
    return row;
  });
}

export interface MemberKeyVersion {
  publicEncKey: string;
  publicSignKey: string;
  keyVersion: number;
  validFrom: string;
  /** null = aktuelle Version. */
  validUntil: string | null;
}

/**
 * Öffentliche Schlüssel eines Familienmitglieds samt Historie (zum Prüfen alter Signaturen). Nur Mitglieder der eigenen Familie (sonst 404,
 * auch für unbekannte IDs und Deaktivierte); mit `version` genau diese Version (aktuell oder aus der Historie), sonst alle, aufsteigend.
 */
export async function getMemberKeys(ctx: AuthContext, p: SessionPrincipal, targetId: string, version?: number): Promise<{ userId: string; keys: MemberKeyVersion[] }> {
  const [m] = await ctx.db
    .select({ id: memberships.userId })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId), isNull(users.disabledAt)));
  if (!m) throw notFound();
  const [cur] = await ctx.db.select().from(personKeys).where(eq(personKeys.userId, targetId));
  const hist = await ctx.db.select().from(personKeyHistory).where(eq(personKeyHistory.userId, targetId)).orderBy(asc(personKeyHistory.keyVersion));
  const all: MemberKeyVersion[] = [
    ...hist.map((h) => ({ publicEncKey: h.encKey, publicSignKey: h.signKey, keyVersion: h.keyVersion, validFrom: h.validFrom.toISOString(), validUntil: h.validUntil.toISOString() })),
    ...(cur ? [{ publicEncKey: cur.publicEncKey, publicSignKey: cur.publicSignKey, keyVersion: cur.keyVersion, validFrom: cur.updatedAt.toISOString(), validUntil: null }] : []),
  ];
  const keys = version === undefined ? all : all.filter((k) => k.keyVersion === version);
  if (version !== undefined && keys.length === 0) throw notFound();
  return { userId: targetId, keys };
}
