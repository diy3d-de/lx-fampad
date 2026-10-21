// E2EE: Archiv der Schlüsselsicherungen früherer Schlüsselstände ("Archivschlüssel" der App). Nichts davon wird je gelöscht: ein Schlüsselwechsel verschiebt die
// Wiederherstellungssicherung hierher (key_backup_archive), die Passwort-Sicherungen bleiben in key_backups_pw (stale/superseded) und werden hier mit angeboten.
// So bleibt der Weg zum alten Schlüssel (und damit zum Verlauf aus der Zeit vor dem Wechsel) offen, auch wenn der Wechsel von einem Angreifer kam.
// Nur die eigene Person (jede Abfrage nach user_id der Sitzung, fremde IDs = 404), Step-up, protokolliert, strenges Rate-Limit an der Route. Blob und Salt
// erscheinen nie im Log oder Audit; der Server kann die Blobs nicht lesen.
import { and, count, desc, eq, inArray, isNotNull, lt, or } from 'drizzle-orm';
import { keyBackupArchive, keyBackupsPw, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { kdfSalt, type KdfParams } from './keys-pw.js';
import { recordSecurityEvent, viaOf, wakeAfterCommit, wakeTopics } from './security-events.js';
import { requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

/** Höchstzahl je Quelle in der Liste (neueste zuerst); die Zahl in `archiveCount` ist nie begrenzt. */
const LIST_LIMIT = 200;

export interface ArchiveEntry {
  id: string;
  /** `recovery` = mit dem Wiederherstellungsschlüssel verschlüsselt, `password` = mit dem Passwort-Schlüssel (kdf beim Einzelabruf). */
  kind: 'recovery' | 'password';
  /** Zu welchem Schlüsselstand (key_version) die Sicherung gehört. */
  keyVersion: number;
  createdAt: string;
  archivedAt: string;
  /** `rotation` = der Schlüssel wurde seither gewechselt, `replaced` = durch eine neuere Sicherung desselben Schlüssels ersetzt. */
  reason: 'rotation' | 'replaced';
  /** Passwort-Sicherung: war sie einmal per Round-Trip bestätigt? (Wiederherstellungssicherungen: immer true.) */
  verified: boolean;
}

export interface ArchiveDetail extends ArchiveEntry {
  blob: string;
  /** Nur bei `kind = 'password'`: Ableitungsparameter samt Salt. */
  kdf?: KdfParams;
}

/**
 * Welche Zeilen von key_backups_pw gehören ins Archiv: ersetzte (`superseded`) oder durch einen Schlüsselwechsel veraltete (`stale`) Sicherungen früherer
 * Schlüsselstände sowie bestätigte, ersetzte Sicherungen desselben Stands (sonst wären sie nach dem Ersetzen durch eine Müll-Sicherung unerreichbar).
 * Nie dabei: unbestätigte (`pending`) und noch aktuelle (`active`; die gibt es über die normale Route).
 */
function pwArchiveWhere(userId: string, currentVersion: number) {
  return and(
    eq(keyBackupsPw.userId, userId),
    or(
      and(inArray(keyBackupsPw.state, ['superseded', 'stale']), lt(keyBackupsPw.keyVersion, currentVersion)),
      and(eq(keyBackupsPw.state, 'superseded'), isNotNull(keyBackupsPw.verifiedAt)),
    ),
  );
}

async function currentVersion(exec: Executor, userId: string): Promise<number> {
  const [k] = await exec.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, userId));
  return k?.v ?? 0;
}

/** Anzahl der archivierten Sicherungen (für `GET /me/keys`). */
export async function countArchive(ctx: Pick<AuthContext, 'db'>, userId: string, current: number): Promise<number> {
  const [a] = await ctx.db.select({ n: count() }).from(keyBackupArchive).where(eq(keyBackupArchive.userId, userId));
  const [b] = await ctx.db.select({ n: count() }).from(keyBackupsPw).where(pwArchiveWhere(userId, current));
  return (a?.n ?? 0) + (b?.n ?? 0);
}

/** Metadaten aller archivierten Sicherungen der eigenen Person (ohne Blob), neueste zuerst. Step-up, protokolliert. */
export async function listArchive(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<{ entries: ArchiveEntry[] }> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const current = await currentVersion(tx, p.userId);
    const rec = await tx
      .select({ id: keyBackupArchive.id, keyVersion: keyBackupArchive.keyVersion, createdAt: keyBackupArchive.backupCreatedAt, archivedAt: keyBackupArchive.archivedAt, reason: keyBackupArchive.reason })
      .from(keyBackupArchive)
      .where(eq(keyBackupArchive.userId, p.userId))
      .orderBy(desc(keyBackupArchive.archivedAt))
      .limit(LIST_LIMIT);
    const pw = await tx
      .select({ id: keyBackupsPw.id, keyVersion: keyBackupsPw.keyVersion, createdAt: keyBackupsPw.createdAt, archivedAt: keyBackupsPw.updatedAt, verifiedAt: keyBackupsPw.verifiedAt })
      .from(keyBackupsPw)
      .where(pwArchiveWhere(p.userId, current))
      .orderBy(desc(keyBackupsPw.updatedAt))
      .limit(LIST_LIMIT);
    const entries: ArchiveEntry[] = [
      ...rec.map((r) => ({
        id: r.id,
        kind: 'recovery' as const,
        keyVersion: r.keyVersion,
        createdAt: r.createdAt.toISOString(),
        archivedAt: r.archivedAt.toISOString(),
        reason: r.reason === 'replaced' ? ('replaced' as const) : ('rotation' as const),
        verified: true,
      })),
      ...pw.map((r) => ({
        id: r.id,
        kind: 'password' as const,
        keyVersion: r.keyVersion,
        createdAt: r.createdAt.toISOString(),
        archivedAt: r.archivedAt.toISOString(),
        reason: r.keyVersion < current ? ('rotation' as const) : ('replaced' as const),
        verified: r.verifiedAt !== null,
      })),
    ].sort((a, b) => b.archivedAt.localeCompare(a.archivedAt));
    await writeAudit(ctx, tx, { event: 'key_backup_archive_list', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { count: entries.length } });
    return { entries };
  });
}

/**
 * Eine archivierte Sicherung der eigenen Person samt Blob (und bei Passwort-Sicherungen den Ableitungsparametern) abrufen. Fremde, unbekannte oder nicht
 * archivierte IDs: 404. Abruf, Audit und Sicherheitsereignis stehen in einer Transaktion (kein unprotokollierter Abruf); die eigenen Geräte werden geweckt.
 * Bewusst NICHT durch die Sperrfrist nach Wiederherstellungscode gesperrt: wer sich mit einem Code anmeldet, braucht genau diesen Weg.
 */
export async function getArchiveEntry(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<ArchiveDetail> {
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId);
  const out = await ctx.db.transaction(async (tx) => {
    const current = await currentVersion(tx, p.userId);
    const [rec] = await tx
      .select()
      .from(keyBackupArchive)
      .where(and(eq(keyBackupArchive.id, id), eq(keyBackupArchive.userId, p.userId)));
    let detail: ArchiveDetail;
    if (rec) {
      detail = {
        id: rec.id,
        kind: 'recovery',
        keyVersion: rec.keyVersion,
        createdAt: rec.backupCreatedAt.toISOString(),
        archivedAt: rec.archivedAt.toISOString(),
        reason: rec.reason === 'replaced' ? 'replaced' : 'rotation',
        verified: true,
        blob: rec.blob,
      };
    } else {
      const [row] = await tx
        .select({
          id: keyBackupsPw.id,
          blob: keyBackupsPw.blob,
          keyVersion: keyBackupsPw.keyVersion,
          createdAt: keyBackupsPw.createdAt,
          archivedAt: keyBackupsPw.updatedAt,
          verifiedAt: keyBackupsPw.verifiedAt,
          kdfId: keyBackupsPw.kdfId,
          memKib: keyBackupsPw.memKib,
          ops: keyBackupsPw.ops,
          generation: keyBackupsPw.saltGeneration,
          email: users.email,
        })
        .from(keyBackupsPw)
        .innerJoin(users, eq(users.id, keyBackupsPw.userId))
        .where(and(eq(keyBackupsPw.id, id), pwArchiveWhere(p.userId, current)));
      if (!row) throw new AppError(404, 'not_found');
      detail = {
        id: row.id,
        kind: 'password',
        keyVersion: row.keyVersion,
        createdAt: row.createdAt.toISOString(),
        archivedAt: row.archivedAt.toISOString(),
        reason: row.keyVersion < current ? 'rotation' : 'replaced',
        verified: row.verifiedAt !== null,
        blob: row.blob,
        kdf: { id: row.kdfId, memKiB: row.memKib, ops: row.ops, salt: kdfSalt(ctx, row.email, row.generation) },
      };
    }
    await writeAudit(ctx, tx, {
      event: 'key_backup_archive_read',
      familyId: p.familyId,
      actorId: p.userId,
      deviceId: p.deviceId,
      ip: meta.ip,
      detail: { keyVersion: detail.keyVersion, kind: detail.kind },
    });
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_archive_read', via: viaOf(p), actorId: p.userId });
    return detail;
  });
  wakeAfterCommit(ctx, p.familyId, p.userId, topics);
  return out;
}
