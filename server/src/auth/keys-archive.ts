// E2EE: Archiv der Schlüsselsicherungen früherer Schlüsselstände ("Archivschlüssel" der App). Ein Schlüsselwechsel verschiebt die Wiederherstellungssicherung hierher
// (key_backup_archive); die Passwort-Sicherungen bleiben in key_backups_pw (stale/superseded) und werden hier mit angeboten. So bleibt der Weg zum alten Schlüssel
// (und damit zum Verlauf aus der Zeit vor dem Wechsel) offen, auch wenn der Wechsel von einem Angreifer kam.
// Nur die eigene Person (jede Abfrage nach user_id der Sitzung, fremde IDs = 404), Step-up, protokolliert, strenges Rate-Limit an der Route. Blob und Salt
// erscheinen nie im Log oder Audit; der Server kann die Blobs nicht lesen.
//
// Umfang der Liste: Eintragsarten, die einen Schlüsselwechsel überlebt haben ("rotation": Sicherung eines früheren Stands), kommen IMMER vollständig und zuerst.
// Ersetzte Sicherungen desselben Stands ("replaced") sind die einzigen, die sich ausdünnen lassen: die Liste zeigt nur die neuesten 50, und die Tabelle selbst behält je
// Schlüsselstand die ältesten 5 (die echte Sicherung liegt vor einer Flut von Müll-Ersetzungen) und insgesamt die neuesten 50 (siehe thinReplaced).
// Ohne Schalter E2EE_PW_BACKUP erscheinen nur Wiederherstellungssicherungen (Liste, Zahl und Einzelabruf gleich).
import { and, desc, eq, gte, inArray, isNotNull, isNull, lt, or, sql } from 'drizzle-orm';
import { keyBackupArchive, keyBackupsPw, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { kdfSalt, type KdfParams } from './keys-pw.js';
import { recordDebouncedEvent, viaOf, wakeAfterCommit, wakeTopics } from './security-events.js';
import { requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

/** Wie viele ersetzte Sicherungen die Liste zeigt (neueste zuerst) und wie viele die Tabelle insgesamt behält. */
const REPLACED_SHOWN = 50;
/** Je Schlüsselstand bleiben die ältesten so viele ersetzte Sicherungen immer erhalten (dort liegt die echte, vor einer Flut von Ersetzungen). */
const REPLACED_KEEP_OLDEST = 5;
const PAGE_DEFAULT = 100;
const PAGE_MAX = 200;

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

interface Cand extends ArchiveEntry {
  /** 0 = immer dabei (frühere Schlüsselstände), 1 = ausdünnbar (ersetzt). */
  rank: 0 | 1;
  archived: number;
}

/** Alle Einträge der Liste (nur Metadaten), sortiert: erst vollständig die der früheren Stände, dann die neuesten ersetzten. */
async function collect(ctx: Pick<AuthContext, 'config'>, exec: Executor, userId: string, current: number): Promise<Cand[]> {
  const rec = await exec
    .select({ id: keyBackupArchive.id, keyVersion: keyBackupArchive.keyVersion, createdAt: keyBackupArchive.backupCreatedAt, archivedAt: keyBackupArchive.archivedAt, reason: keyBackupArchive.reason })
    .from(keyBackupArchive)
    .where(eq(keyBackupArchive.userId, userId));
  const cands: Cand[] = rec.map((r) => ({
    id: r.id,
    kind: 'recovery',
    keyVersion: r.keyVersion,
    createdAt: r.createdAt.toISOString(),
    archivedAt: r.archivedAt.toISOString(),
    reason: r.reason === 'replaced' ? 'replaced' : 'rotation',
    verified: true,
    rank: r.reason === 'replaced' ? 1 : 0,
    archived: r.archivedAt.getTime(),
  }));
  if (ctx.config.e2eePwBackup) {
    const cols = { id: keyBackupsPw.id, keyVersion: keyBackupsPw.keyVersion, createdAt: keyBackupsPw.createdAt, archivedAt: keyBackupsPw.updatedAt, verifiedAt: keyBackupsPw.verifiedAt };
    const toCand = (r: { id: string; keyVersion: number; createdAt: Date; archivedAt: Date; verifiedAt: Date | null }, rank: 0 | 1): Cand => ({
      id: r.id,
      kind: 'password',
      keyVersion: r.keyVersion,
      createdAt: r.createdAt.toISOString(),
      archivedAt: r.archivedAt.toISOString(),
      reason: r.keyVersion < current ? 'rotation' : 'replaced',
      verified: r.verifiedAt !== null,
      rank,
      archived: r.archivedAt.getTime(),
    });
    // bestätigte Sicherungen früherer Stände: immer vollständig; alles übrige (ersetzt desselben Stands, nie bestätigte): nur die neuesten
    const always = await exec
      .select(cols)
      .from(keyBackupsPw)
      .where(and(pwArchiveWhere(userId, current), lt(keyBackupsPw.keyVersion, current), isNotNull(keyBackupsPw.verifiedAt)));
    const rest = await exec
      .select(cols)
      .from(keyBackupsPw)
      .where(and(pwArchiveWhere(userId, current), or(gte(keyBackupsPw.keyVersion, current), isNull(keyBackupsPw.verifiedAt))))
      .orderBy(desc(keyBackupsPw.updatedAt))
      .limit(REPLACED_SHOWN);
    cands.push(...always.map((r) => toCand(r, 0)), ...rest.map((r) => toCand(r, 1)));
  }
  const fest = cands.filter((c) => c.rank === 0);
  const duenn = cands
    .filter((c) => c.rank === 1)
    .sort((a, b) => b.archived - a.archived || a.id.localeCompare(b.id))
    .slice(0, REPLACED_SHOWN);
  return [...fest, ...duenn].sort((a, b) => a.rank - b.rank || b.archived - a.archived || a.id.localeCompare(b.id));
}

/** Anzahl der archivierten Sicherungen (für `GET /me/keys`); dieselbe Auswahl wie die Liste. */
export async function countArchive(ctx: Pick<AuthContext, 'db' | 'config'>, userId: string, current: number): Promise<number> {
  return (await collect(ctx, ctx.db, userId, current)).length;
}

const encodeCursor = (c: Cand) => Buffer.from(`${c.rank}|${c.archived}|${c.id}`).toString('base64url');
function decodeCursor(s: string): { rank: number; archived: number; id: string } {
  const m = /^(\d)\|(\d{1,16})\|([0-9a-f-]{36})$/.exec(Buffer.from(s, 'base64url').toString('utf8'));
  if (!m) throw new AppError(400, 'invalid_request');
  return { rank: Number(m[1]), archived: Number(m[2]), id: m[3] as string };
}

/**
 * Metadaten der archivierten Sicherungen der eigenen Person (ohne Blob). Reihenfolge: erst alle der früheren Schlüsselstände (neueste zuerst), dann die
 * neuesten ersetzten. Seiten über `limit` (Standard 100, höchstens 200) und `before` (der `next`-Wert der vorigen Seite). Step-up, protokolliert.
 */
export async function listArchive(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta, page: { limit?: number | undefined; before?: string | undefined } = {}): Promise<{ entries: ArchiveEntry[]; next: string | null }> {
  requireStepUp(ctx, p);
  const limit = Math.min(Math.max(page.limit ?? PAGE_DEFAULT, 1), PAGE_MAX);
  const cur = page.before ? decodeCursor(page.before) : null;
  return ctx.db.transaction(async (tx) => {
    const current = await currentVersion(tx, p.userId);
    const all = await collect(ctx, tx, p.userId, current);
    const after = cur ? all.filter((c) => c.rank > cur.rank || (c.rank === cur.rank && (c.archived < cur.archived || (c.archived === cur.archived && c.id > cur.id)))) : all;
    const slice = after.slice(0, limit);
    const last = slice[slice.length - 1];
    await writeAudit(ctx, tx, { event: 'key_backup_archive_list', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { count: slice.length } });
    return {
      entries: slice.map(({ rank: _r, archived: _a, ...e }) => e),
      next: slice.length < after.length && last ? encodeCursor(last) : null,
    };
  });
}

/**
 * Dünnt die ersetzten Wiederherstellungssicherungen einer Person aus (nur `replaced`, nie `rotation`): behalten werden je Schlüsselstand die ältesten
 * REPLACED_KEEP_OLDEST und insgesamt die neuesten REPLACED_SHOWN. Gehört in die Transaktion, die eine neue `replaced`-Zeile anlegt.
 */
export async function thinReplaced(exec: Executor, userId: string): Promise<void> {
  await exec.execute(sql`
    delete from key_backup_archive where id in (
      select id from (
        select id,
               row_number() over (partition by key_version order by archived_at asc, id asc) as r_old,
               row_number() over (order by archived_at desc, id desc) as r_new
        from key_backup_archive where user_id = ${userId} and reason = 'replaced'
      ) t where r_old > ${REPLACED_KEEP_OLDEST} and r_new > ${REPLACED_SHOWN}
    )`);
}

/**
 * Eine archivierte Sicherung der eigenen Person samt Blob (und bei Passwort-Sicherungen den Ableitungsparametern) abrufen. Fremde, unbekannte oder nicht
 * archivierte IDs: 404. Abruf, Audit und Sicherheitsereignis stehen in einer Transaktion (kein unprotokollierter Abruf); die eigenen anderen Geräte werden geweckt
 * (entprellt). Bewusst NICHT durch die Sperrfrist nach Wiederherstellungscode gesperrt: wer sich mit einem Code anmeldet, braucht genau diesen Weg.
 */
export async function getArchiveEntry(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<ArchiveDetail> {
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  const { detail, recorded } = await ctx.db.transaction(async (tx) => {
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
      // ohne Schalter E2EE_PW_BACKUP gibt es die Passwort-Einträge nicht (wie in der Liste)
      if (!ctx.config.e2eePwBackup) throw new AppError(404, 'not_found');
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
    const recorded = await recordDebouncedEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_archive_read', via: viaOf(p), actorId: p.userId });
    return { detail, recorded };
  });
  if (recorded) wakeAfterCommit(ctx, p.familyId, p.userId, topics, { light: true });
  return detail;
}
