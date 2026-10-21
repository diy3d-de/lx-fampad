// E2EE-Schlüsselverwaltung (Phase 1): öffentliche Personenschlüssel, opake Schlüsselsicherung, kurzlebige Geräte-Übertragung.
// Der Server sieht und speichert nie ein Geheimnis: Blobs sind für ihn undurchsichtiger Text (mit Wiederherstellungsschlüssel bzw.
// Einmalschlüssel verschlüsselt, beides nur auf den Geräten). Alles gehört zur angemeldeten Person; Blobs und Schlüssel erscheinen nie im Log.
import { and, asc, eq, gt, isNull } from 'drizzle-orm';
import { keyBackups, keyBackupsPw, keyTransfers, memberships, personKeyHistory, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, RequestMeta } from './context.js';
import { sha256Hex } from './crypto.js';
import { requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

/** Lebensdauer einer Geräte-Übertragung. */
export const KEY_TRANSFER_TTL_SEC = 120;

export interface PublicKeys {
  publicEncKey: string;
  publicSignKey: string;
  keyVersion: number;
}

const notFound = () => new AppError(404, 'not_found');

export async function getOwnKeys(ctx: AuthContext, p: SessionPrincipal): Promise<{ keys: PublicKeys | null; hasBackup: boolean }> {
  const [k] = await ctx.db
    .select({ publicEncKey: personKeys.publicEncKey, publicSignKey: personKeys.publicSignKey, keyVersion: personKeys.keyVersion })
    .from(personKeys)
    .where(eq(personKeys.userId, p.userId));
  const [b] = await ctx.db.select({ v: keyBackups.keyVersion }).from(keyBackups).where(eq(keyBackups.userId, p.userId));
  return { keys: k ?? null, hasBackup: b !== undefined && k !== undefined && b.v === k.keyVersion };
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
 * Schlüsselwechsel (Verlust aller Geräte ohne Wiederherstellung, Verdacht auf Kompromittierung): key_version steigt, Sicherung und
 * offene Übertragungen gehören zum alten Schlüssel und werden verworfen; der alte Stand wandert in die (nur anhängende) Historie.
 * `expectedKeyVersion` ist die Version, die der Client kennt: weicht sie ab (anderes Gerät war schneller), antwortet der Server mit 409.
 * Mit Step-up; die Apps der anderen warnen vor dem Wechsel.
 */
export async function rotateKeys(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { publicEncKey: string; publicSignKey: string; expectedKeyVersion: number },
  meta: RequestMeta,
): Promise<PublicKeys> {
  requireStepUp(ctx, p);
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
    await tx.delete(keyBackups).where(eq(keyBackups.userId, p.userId));
    await tx.delete(keyTransfers).where(eq(keyTransfers.userId, p.userId));
    // Passwort-Sicherung (E2EE_PW_BACKUP): nie löschen, die aktuelle gehört jetzt zum alten Schlüssel
    await tx.update(keyBackupsPw).set({ state: 'stale', updatedAt: now }).where(and(eq(keyBackupsPw.userId, p.userId), eq(keyBackupsPw.state, 'active')));
    await writeAudit(ctx, tx, { event: 'key_rotated', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion } });
    return row;
  });
  // andere Geräte erfahren den Schlüsselwechsel (TOFU-Warnung) ohne Neustart
  ctx.onMembersChanged(p.familyId);
  return rotated;
}

/** Opake Schlüsselsicherung ablegen oder ersetzen (Step-up). Sie muss zur aktuellen key_version gehören. */
export async function setBackup(ctx: AuthContext, p: SessionPrincipal, input: { blob: string; keyVersion: number }, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    await tx
      .insert(keyBackups)
      .values({ userId: p.userId, blob: input.blob, keyVersion: k.v, createdAt: ctx.now(), updatedAt: ctx.now() })
      .onConflictDoUpdate({ target: keyBackups.userId, set: { blob: input.blob, keyVersion: k.v, updatedAt: ctx.now() } });
    await writeAudit(ctx, tx, { event: 'backup_set', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: k.v } });
  });
}

/**
 * Opake Schlüsselsicherung abrufen (Step-up). Abruf und Audit-Eintrag stehen in einer Transaktion: Gelingt das Protokollieren
 * nicht, gibt es auch keine Sicherung (lieber ein Fehler als ein unprotokollierter Abruf).
 */
export async function getBackup(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<{ blob: string; keyVersion: number }> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const [b] = await tx.select({ blob: keyBackups.blob, keyVersion: keyBackups.keyVersion }).from(keyBackups).where(eq(keyBackups.userId, p.userId));
    if (!b) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion } });
    return b;
  });
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
  try {
    await ctx.db.transaction(async (tx) => {
      const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
      if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
      if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
      await tx
        .insert(keyTransfers)
        .values({ userId: p.userId, lookupHash, blob: input.blob, keyVersion: k.v, createdAt: now, expiresAt })
        .onConflictDoUpdate({ target: keyTransfers.userId, set: { lookupHash, blob: input.blob, keyVersion: k.v, createdAt: now, expiresAt } });
    });
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
