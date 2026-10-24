// Aufräumen der Dateiablage (läuft im stündlichen Wartungsjob, auth/maintenance.ts; Löschkonzept: docs/DATENSCHUTZ-ENTWURF.md, Abschnitt 10):
//  - Uploads: abgelaufene (24 h) werden verworfen (Staging-Datei weg), beendete und verworfene Zeilen nach 24 h entfernt; Reste in tmp/ ohne laufenden Upload nach 24 h gelöscht.
//  - Blobs, die niemand beansprucht hat, werden nach 7 Tagen Karenz gelöscht (Waisen).
//  - Blobs, deren Datensatz gelöscht ist oder fehlt (Datei/Fassung/Anhang gelöscht, Tombstone bereinigt), werden als verwaist markiert (`orphaned_at`: zählen ab dann nicht mehr
//    fürs Kontingent) und nach 7 Tagen Karenz gelöscht (Vorbereitung auf den Papierkorb; heute ohne Oberfläche). Blobs eines unbekannten Datensatz-Typs bleiben unberührt.
//  - Abgleich Platte gegen Datenbank: nur lesend. Dateien ohne Zeile und Zeilen ohne Datei werden gezählt und gewarnt, nie automatisch gelöscht.
// Nie ein Name, nie ein Pfad im Log: nur Zahlen.
import { and, eq, inArray, isNull, lt, sql } from 'drizzle-orm';
import { join } from 'node:path';
import type { AuthContext } from '../auth/context.js';
import { dateiBlob, dateiUpload } from '../db/schema.js';
import { defaultRegistry } from '../sync/index.js';
import { syncColumns, type Registry } from '../sync/registry.js';
import { FileStore } from './store.js';

const DAY_MS = 86_400_000;
export const ORPHAN_KARENZ_DAYS = 7;
export const UPLOAD_KEEP_HOURS = 24;

export interface FilesReport {
  uploadsExpired: number;
  uploadsDeleted: number;
  stagingRemoved: number;
  orphansMarked: number;
  orphansRestored: number;
  blobsDeleted: number;
  /** Nur gemeldet: Dateien auf der Platte ohne Zeile in der Datenbank und Zeilen ohne Datei. */
  strayFiles: number;
  missingFiles: number;
}

export async function runFilesMaintenance(ctx: Pick<AuthContext, 'db' | 'config' | 'now' | 'log'>, registry: Registry = defaultRegistry): Promise<FilesReport> {
  const report: FilesReport = { uploadsExpired: 0, uploadsDeleted: 0, stagingRemoved: 0, orphansMarked: 0, orphansRestored: 0, blobsDeleted: 0, strayFiles: 0, missingFiles: 0 };
  if (!ctx.config.files.enabled) return report;
  const { db } = ctx;
  const now = ctx.now();
  const ago = (ms: number) => new Date(now.getTime() - ms);
  const store = new FileStore(ctx.config.filesDir);
  await store.ensure();

  // ----- Uploads -----
  const expired = await db
    .update(dateiUpload)
    .set({ status: 'aborted', updatedAt: now })
    .where(and(inArray(dateiUpload.status, ['open', 'finalizing']), lt(dateiUpload.expiresAt, now)))
    .returning({ id: dateiUpload.id });
  report.uploadsExpired = expired.length;
  for (const u of expired) {
    if (await store.remove(store.partPath(u.id)).catch(() => false)) report.stagingRemoved++;
    await store.remove(store.encPath(u.id)).catch(() => false);
  }
  const dead = await db
    .delete(dateiUpload)
    .where(and(inArray(dateiUpload.status, ['done', 'aborted']), lt(dateiUpload.updatedAt, ago(UPLOAD_KEEP_HOURS * 3_600_000))))
    .returning({ id: dateiUpload.id });
  report.uploadsDeleted = dead.length;
  const active = new Set((await db.select({ id: dateiUpload.id }).from(dateiUpload).where(inArray(dateiUpload.status, ['open', 'finalizing']))).map((u) => u.id));
  const listing = await store.list();
  for (const f of listing.staging) {
    // nur eigene Staging-Dateien (Zufalls-UUID mit .part/.enc), nie Fremdes
    const m = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(part|enc)$/.exec(f.name);
    if (!m?.[1]) continue;
    if (active.has(m[1]) || f.mtimeMs > ago(UPLOAD_KEEP_HOURS * 3_600_000).getTime()) continue;
    if (await store.remove(join(store.tmpDir, f.name)).catch(() => false)) report.stagingRemoved++;
  }

  // ----- Verwaiste Blobs markieren: der beanspruchende Datensatz ist gelöscht oder weg -----
  const claimed = await db
    .select({ id: dateiBlob.id, entity: dateiBlob.claimEntity, claimId: dateiBlob.claimId, orphanedAt: dateiBlob.orphanedAt })
    .from(dateiBlob)
    .where(eq(dateiBlob.state, 'claimed'));
  const byEntity = new Map<string, typeof claimed>();
  for (const b of claimed) {
    if (!b.entity) continue;
    byEntity.set(b.entity, [...(byEntity.get(b.entity) ?? []), b]);
  }
  for (const [entity, blobs] of byEntity) {
    const def = registry.get(entity);
    if (!def) continue; // unbekannter Datensatz-Typ: nie löschen
    const c = syncColumns(def);
    const alive = new Set<string>();
    const ids = [...new Set(blobs.map((b) => b.claimId).filter((x): x is string => x !== null))];
    for (let i = 0; i < ids.length; i += 500) {
      const rows = (await db
        .select({ id: c.id })
        .from(def.table)
        .where(and(inArray(c.id, ids.slice(i, i + 500)), isNull(c.deletedAt)))) as Array<{ id: string }>;
      for (const r of rows) alive.add(r.id);
    }
    const toMark = blobs.filter((b) => b.orphanedAt === null && !(b.claimId && alive.has(b.claimId))).map((b) => b.id);
    const toRestore = blobs.filter((b) => b.orphanedAt !== null && b.claimId && alive.has(b.claimId)).map((b) => b.id);
    for (let i = 0; i < toMark.length; i += 500) {
      const r = await db
        .update(dateiBlob)
        .set({ orphanedAt: now })
        .where(inArray(dateiBlob.id, toMark.slice(i, i + 500)))
        .returning({ id: dateiBlob.id });
      report.orphansMarked += r.length;
    }
    for (let i = 0; i < toRestore.length; i += 500) {
      const r = await db
        .update(dateiBlob)
        .set({ orphanedAt: null })
        .where(inArray(dateiBlob.id, toRestore.slice(i, i + 500)))
        .returning({ id: dateiBlob.id });
      report.orphansRestored += r.length;
    }
  }

  // ----- Löschen nach der Karenz: verwaiste und nie beanspruchte Blobs -----
  const karenz = ago(ORPHAN_KARENZ_DAYS * DAY_MS);
  const due = await db
    .select({ id: dateiBlob.id })
    .from(dateiBlob)
    .where(
      sql`(${dateiBlob.orphanedAt} is not null and ${dateiBlob.orphanedAt} < ${karenz.toISOString()}::timestamptz)
        or (${dateiBlob.state} = 'ready' and ${dateiBlob.createdAt} < ${karenz.toISOString()}::timestamptz)`,
    );
  for (const b of due) {
    try {
      await store.remove(store.blobPath(b.id));
      const gone = await db.delete(dateiBlob).where(eq(dateiBlob.id, b.id)).returning({ id: dateiBlob.id });
      report.blobsDeleted += gone.length;
    } catch (err) {
      ctx.log.warn({ err }, 'Dateiablage: Blob konnte nicht gelöscht werden');
    }
  }

  // ----- Abgleich Platte gegen Datenbank (nur lesend) -----
  const known = new Set((await db.select({ id: dateiBlob.id }).from(dateiBlob)).map((b) => b.id));
  const onDisk = new Set<string>();
  const fresh = ago(DAY_MS).getTime();
  for (const f of (await store.list()).blobs) {
    onDisk.add(f.id);
    // jüngere Dateien können gerade erst abgelegt worden sein (Datei zuerst, Zeile danach)
    if (!known.has(f.id) && f.mtimeMs < fresh) report.strayFiles++;
  }
  for (const id of known) if (!onDisk.has(id)) report.missingFiles++;
  if (report.strayFiles > 0 || report.missingFiles > 0) {
    ctx.log.warn({ strayFiles: report.strayFiles, missingFiles: report.missingFiles }, 'Dateiablage: Platte und Datenbank weichen ab');
  }
  return report;
}
