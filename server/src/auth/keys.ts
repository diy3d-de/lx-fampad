// E2EE-Schlüsselverwaltung (Phase 1): öffentliche Personenschlüssel, opake Schlüsselsicherung, kurzlebige Geräte-Übertragung.
// Der Server sieht und speichert nie ein Geheimnis: Blobs sind für ihn undurchsichtiger Text (mit Wiederherstellungsschlüssel bzw.
// Einmalschlüssel verschlüsselt, beides nur auf den Geräten). Alles gehört zur angemeldeten Person; Blobs und Schlüssel erscheinen nie im Log.
import { and, eq, gt, sql } from 'drizzle-orm';
import { keyBackups, keyTransfers, personKeys } from '../db/schema.js';
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
  return ctx.db.transaction(async (tx) => {
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
}

/**
 * Schlüsselwechsel (Verlust aller Geräte ohne Wiederherstellung, Verdacht auf Kompromittierung): key_version steigt, Sicherung und
 * offene Übertragungen gehören zum alten Schlüssel und werden verworfen. Mit Step-up; die Apps der anderen warnen vor dem Wechsel.
 */
export async function rotateKeys(ctx: AuthContext, p: SessionPrincipal, input: { publicEncKey: string; publicSignKey: string }, meta: RequestMeta): Promise<PublicKeys> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const rows = await tx
      .update(personKeys)
      .set({ publicEncKey: input.publicEncKey, publicSignKey: input.publicSignKey, keyVersion: sql`${personKeys.keyVersion} + 1`, updatedAt: ctx.now() })
      .where(eq(personKeys.userId, p.userId))
      .returning({ publicEncKey: personKeys.publicEncKey, publicSignKey: personKeys.publicSignKey, keyVersion: personKeys.keyVersion });
    const row = rows[0];
    if (!row) throw notFound();
    await tx.delete(keyBackups).where(eq(keyBackups.userId, p.userId));
    await tx.delete(keyTransfers).where(eq(keyTransfers.userId, p.userId));
    await writeAudit(ctx, tx, { event: 'key_rotated', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion } });
    return row;
  });
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

/** Opake Schlüsselsicherung abrufen (Step-up); jeder Abruf wird protokolliert. */
export async function getBackup(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<{ blob: string; keyVersion: number }> {
  requireStepUp(ctx, p);
  const [b] = await ctx.db.select({ blob: keyBackups.blob, keyVersion: keyBackups.keyVersion }).from(keyBackups).where(eq(keyBackups.userId, p.userId));
  if (!b) throw notFound();
  await writeAudit(ctx, ctx.db, { event: 'key_backup_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion } });
  return b;
}

/** Übertragung für ein neues Gerät anlegen (ersetzt eine offene). `lookup` ist die vom Gerät abgeleitete Suchkennung, nie der Einmalschlüssel. */
export async function createTransfer(ctx: AuthContext, p: SessionPrincipal, input: { lookup: string; blob: string }): Promise<{ expiresAt: string; ttlSec: number }> {
  const now = ctx.now();
  const expiresAt = new Date(now.getTime() + KEY_TRANSFER_TTL_SEC * 1000);
  await ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    await tx
      .insert(keyTransfers)
      .values({ userId: p.userId, lookupHash: sha256Hex(input.lookup), blob: input.blob, keyVersion: k.v, createdAt: now, expiresAt })
      .onConflictDoUpdate({ target: keyTransfers.userId, set: { lookupHash: sha256Hex(input.lookup), blob: input.blob, keyVersion: k.v, createdAt: now, expiresAt } });
  });
  return { expiresAt: expiresAt.toISOString(), ttlSec: KEY_TRANSFER_TTL_SEC };
}

/**
 * Übertragung einlösen: genau einmal (DELETE ... RETURNING), nur durch dieselbe Person, nur vor Ablauf. Jeder Fehlschlag (unbekannt,
 * abgelaufen, schon eingelöst, fremde Person) antwortet gleich mit 404.
 */
export async function claimTransfer(ctx: AuthContext, p: SessionPrincipal, input: { lookup: string }, meta: RequestMeta): Promise<{ blob: string; keyVersion: number }> {
  const rows = await ctx.db
    .delete(keyTransfers)
    .where(and(eq(keyTransfers.userId, p.userId), eq(keyTransfers.lookupHash, sha256Hex(input.lookup)), gt(keyTransfers.expiresAt, ctx.now())))
    .returning({ blob: keyTransfers.blob, keyVersion: keyTransfers.keyVersion });
  const row = rows[0];
  if (!row) throw notFound();
  await writeAudit(ctx, ctx.db, { event: 'transfer_claimed', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: row.keyVersion } });
  return row;
}
