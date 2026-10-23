// Aufräumen des Sync (läuft im stündlichen Wartungsjob, auth/maintenance.ts). Löschkonzept: docs/DATENSCHUTZ-ENTWURF.md, Abschnitt 10.
//  - Tombstones (gelöschte Datensätze) werden entfernt, sobald alle aktiven Geräte der Familie sie kennen (devices.last_rev >= rev)
//    oder sie älter als 90 Tage sind. Mit ihnen verschwinden ihre Protokolleinträge.
//  - Ersetzte Protokolleinträge (nicht mehr der aktuelle Stand ihres Datensatzes) werden nach 90 Tagen entfernt.
//  - Inhalte (change_log.changes) gelöschter Datensätze sind schon beim Löschen geleert; der Job stellt das als Sicherheitsnetz nochmals her.
//  - Verarbeitete Ops (applied_ops) werden nach 90 Tagen entfernt, abgelehnte schon nach 7 Tagen.
//  - families.purged_rev merkt sich die höchste entfernte Revision: Geräte, die dahinter zurückliegen, müssen neu synchronisieren.
import { and, eq, inArray, isNotNull, lt, or, sql } from 'drizzle-orm';
import { getTableName } from 'drizzle-orm';
import type { AuthContext } from '../auth/context.js';
import { appliedOps, changeLog, devices, families } from '../db/schema.js';
import { defaultRegistry } from './index.js';
import { purgeAlteEinnahmen } from './meds.js';
import { syncColumns, type EntityDef, type Registry } from './registry.js';
import { REJECTED_RETENTION_DAYS, RETENTION_DAYS } from './types.js';

const DAY_MS = 86_400_000;

export interface SyncPurgeReport {
  tombstonesPurged: number;
  logEntriesPurged: number;
  opsPurged: number;
  contentCleared: number;
  /** Einnahme-Einträge des Medikamenten-Plans, die älter als 120 Tage waren. */
  einnahmenPurged: number;
}

function depth(registry: Registry, def: EntityDef): number {
  let n = 0;
  for (let d: EntityDef | undefined = def; d?.parent; d = registry.get(d.parent.entity)) n++;
  return n;
}

export async function runSyncMaintenance(ctx: Pick<AuthContext, 'db' | 'now'>, registry: Registry = defaultRegistry): Promise<SyncPurgeReport> {
  const now = ctx.now();
  const cutoff = new Date(now.getTime() - RETENTION_DAYS * DAY_MS);
  const report: SyncPurgeReport = { tombstonesPurged: 0, logEntriesPurged: 0, opsPurged: 0, contentCleared: 0, einnahmenPurged: 0 };
  // Medikamenten-Protokoll: nach 120 Tagen löschen (mit Tombstone); vor dem allgemeinen Aufräumen, damit dessen Fristen die neuen Tombstones mitnehmen
  report.einnahmenPurged = await purgeAlteEinnahmen(ctx, registry);
  // Kinder vor Eltern
  const defs = registry.list().sort((a, b) => depth(registry, b) - depth(registry, a));

  const familyIds = await ctx.db.select({ id: families.id }).from(families);
  for (const { id: familyId } of familyIds) {
    await ctx.db.transaction(async (tx) => {
      const [family] = await tx.select({ purged: families.purgedRev }).from(families).where(eq(families.id, familyId)).for('update');
      if (!family) return;
      let purgedRev = family.purged;

      const [known] = await tx
        .select({ min: sql<number | null>`min(${devices.lastRev})` })
        .from(devices)
        .where(and(eq(devices.familyId, familyId), sql`${devices.revokedAt} is null`));
      // kein aktives Gerät: niemand braucht die Tombstones (ein neues Gerät beginnt mit einem Snapshot)
      const minKnown = known?.min === null || known?.min === undefined ? Number.MAX_SAFE_INTEGER : Number(known.min);

      for (const def of defs) {
        const c = syncColumns(def);
        const gone = (await tx
          .select({ id: c.id, rev: c.rev })
          .from(def.table)
          .where(and(eq(c.familyId, familyId), isNotNull(c.deletedAt), or(lt(c.deletedAt, cutoff), sql`${c.rev} <= ${minKnown}`)))) as Array<{ id: string; rev: number }>;
        if (gone.length > 0) {
          const ids = gone.map((g) => g.id);
          await tx.delete(def.table).where(and(eq(c.familyId, familyId), inArray(c.id, ids)));
          await tx.delete(changeLog).where(and(eq(changeLog.familyId, familyId), eq(changeLog.entity, def.name), inArray(changeLog.entityId, ids)));
          report.tombstonesPurged += gone.length;
          purgedRev = Math.max(purgedRev, ...gone.map((g) => Number(g.rev)));
        }
        const table = sql.identifier(getTableName(def.table));
        // Tombstone-Einträge ohne Zeile (die Zeile ging per Fremdschlüssel-Kaskade weg): nach der Aufbewahrungsfrist entfernen
        const verwaist = await tx.execute<{ rev: number }>(sql`
          delete from change_log cl
          where cl.family_id = ${familyId} and cl.entity = ${def.name} and cl.tombstone and cl.created_at < ${cutoff.toISOString()}::timestamptz
            and not exists (select 1 from ${table} t where t.id = cl.entity_id and t.family_id = cl.family_id)
          returning cl.rev`);
        report.logEntriesPurged += verwaist.rows.length;
        for (const r of verwaist.rows) purgedRev = Math.max(purgedRev, Number(r.rev));
        // ersetzte Einträge nach der Aufbewahrungsfrist
        const old = await tx.execute<{ rev: number }>(sql`
          delete from change_log cl
          where cl.family_id = ${familyId} and cl.entity = ${def.name} and cl.created_at < ${cutoff.toISOString()}::timestamptz and not cl.tombstone
            and cl.rev is distinct from (select t.rev from ${table} t where t.id = cl.entity_id and t.family_id = cl.family_id)
          returning cl.rev`);
        report.logEntriesPurged += old.rows.length;
        for (const r of old.rows) purgedRev = Math.max(purgedRev, Number(r.rev));
        // Sicherheitsnetz: Inhalte gelöschter Datensätze im Protokoll leeren
        const cleared = await tx.execute<{ rev: number }>(sql`
          update change_log cl set changes = case when cl.changes ? '__lostSight' then jsonb_build_object('__lostSight', cl.changes -> '__lostSight') else '{}'::jsonb end
          where cl.family_id = ${familyId} and cl.entity = ${def.name}
            and cl.changes <> case when cl.changes ? '__lostSight' then jsonb_build_object('__lostSight', cl.changes -> '__lostSight') else '{}'::jsonb end
            and exists (select 1 from ${table} t where t.id = cl.entity_id and t.family_id = cl.family_id and t.deleted_at is not null)
          returning cl.rev`);
        report.contentCleared += cleared.rows.length;
      }
      if (purgedRev > family.purged) await tx.update(families).set({ purgedRev }).where(eq(families.id, familyId));
    });
  }
  const rejectedCutoff = new Date(now.getTime() - REJECTED_RETENTION_DAYS * DAY_MS);
  const ops = await ctx.db
    .delete(appliedOps)
    .where(or(lt(appliedOps.createdAt, cutoff), and(eq(appliedOps.status, 'rejected'), lt(appliedOps.createdAt, rejectedCutoff))))
    .returning({ id: appliedOps.opId });
  report.opsPurged = ops.length;
  return report;
}
