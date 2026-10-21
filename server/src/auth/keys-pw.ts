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

/** Standardparameter, auch für die Fake-Antwort (damit sie wie eine echte aussieht). */
export const DEFAULT_KDF = { id: 'argon2id-v1', memKiB: 65536, ops: 3 } as const;

export interface KdfParams {
  id: string;
  memKiB: number;
  ops: number;
  /** 16 Byte als Base64url. */
  salt: string;
}

const notFound = () => new AppError(404, 'not_found');

/**
 * Parameter der Passwort-Ableitung vor der Anmeldung. Für unbekannte, deaktivierte und Konten ohne Eintrag kommt eine deterministische
 * Fake-Antwort (Salt = HMAC über AUTH_SECRET_KEY und die E-Mail): gleiche Form, immer genau eine Abfrage, kein Orakel für die Existenz.
 */
export async function getKdfParams(ctx: AuthContext, email: string): Promise<{ kdf: KdfParams }> {
  const norm = email.trim().toLowerCase();
  const fakeSalt = Buffer.from(ctx.keys.hmac('kdf-fake-salt', norm).slice(0, 32), 'hex').toString('base64url');
  const [row] = await ctx.db
    .select({ salt: accountKdf.salt, kdfId: accountKdf.kdfId, memKib: accountKdf.memKib, ops: accountKdf.ops, disabledAt: users.disabledAt })
    .from(users)
    .leftJoin(accountKdf, eq(accountKdf.userId, users.id))
    .where(sql`lower(${users.email}) = ${norm}`)
    .limit(1);
  if (row && row.salt && row.kdfId && row.memKib !== null && row.ops !== null && !row.disabledAt) {
    return { kdf: { id: row.kdfId, memKiB: row.memKib, ops: row.ops, salt: Buffer.from(row.salt).toString('base64url') } };
  }
  return { kdf: { ...DEFAULT_KDF, salt: fakeSalt } };
}

export interface PwBackupInput {
  blob: string;
  keyVersion: number;
  kdf: KdfParams;
}

/**
 * Neue Passwort-Sicherung ablegen (Step-up). Sie muss zur aktuellen key_version gehören. In EINER Transaktion: die bisherige aktuelle
 * Zeile wird `superseded`, die neue `active`, die KDF-Parameter des Kontos werden gesetzt, das Audit geschrieben. Gleichzeitige
 * Anfragen derselben Person laufen nacheinander (Sperre auf person_keys); der Teil-Unique-Index sichert zusätzlich ab.
 */
export async function setPwBackup(ctx: AuthContext, p: SessionPrincipal, input: PwBackupInput, meta: RequestMeta): Promise<{ id: string }> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    const now = ctx.now();
    const salt = Buffer.from(input.kdf.salt, 'base64url');
    const [alt] = await tx.select().from(accountKdf).where(eq(accountKdf.userId, p.userId));
    if (!alt) {
      await tx.insert(accountKdf).values({ userId: p.userId, salt, kdfId: input.kdf.id, memKib: input.kdf.memKiB, ops: input.kdf.ops, createdAt: now });
    } else if (!Buffer.from(alt.salt).equals(salt) || alt.kdfId !== input.kdf.id || alt.memKib !== input.kdf.memKiB || alt.ops !== input.kdf.ops) {
      await tx
        .update(accountKdf)
        .set({ salt, kdfId: input.kdf.id, memKib: input.kdf.memKiB, ops: input.kdf.ops, version: alt.version + 1 })
        .where(eq(accountKdf.userId, p.userId));
    }
    await tx
      .update(keyBackupsPw)
      .set({ state: 'superseded', updatedAt: now })
      .where(and(eq(keyBackupsPw.userId, p.userId), inArray(keyBackupsPw.state, ['active', 'stale'])));
    const [row] = await tx
      .insert(keyBackupsPw)
      .values({ userId: p.userId, familyId: p.familyId, blob: input.blob, keyVersion: k.v, kdfId: input.kdf.id, state: 'active', createdAt: now, updatedAt: now })
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
        salt: accountKdf.salt,
        kdfId: accountKdf.kdfId,
        memKib: accountKdf.memKib,
        ops: accountKdf.ops,
      })
      .from(keyBackupsPw)
      .innerJoin(accountKdf, eq(accountKdf.userId, keyBackupsPw.userId))
      .where(and(eq(keyBackupsPw.userId, p.userId), inArray(keyBackupsPw.state, ['active', 'stale'])));
    if (!b) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_pw_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion } });
    return {
      id: b.id,
      blob: b.blob,
      keyVersion: b.keyVersion,
      state: b.state === 'stale' ? 'stale' : 'active',
      kdf: { id: b.kdfId, memKiB: b.memKib, ops: b.ops, salt: Buffer.from(b.salt).toString('base64url') },
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
