// Änderungsstrom: liefert einem Gerät den aktuellen Stand aller seit `sinceRev` geänderten Datensätze seiner Familie,
// gefiltert nach der Rolle der Person (sync/permissions.ts), stabil nach Revision sortiert, seitenweise.
//
// Der Strom ist zustandsbasiert: das change_log nennt, WAS sich seit sinceRev geändert hat; geliefert wird der aktuelle Stand des
// Datensatzes (nur der jeweils letzte Eintrag je Datensatz; ersetzte Einträge werden übersprungen). Bei sinceRev 0 ist das der
// Snapshot (ohne Tombstones). Verliert eine Person die Sicht auf einen Datensatz (Freigabe zurückgenommen), bekommt sie einen
// Tombstone mit `hidden` (nur die ID, kein Inhalt), damit die App ihre Kopie entfernt. Dasselbe gilt für gelöschte Datensätze, die die
// Person nicht (mehr) sehen darf: sonst bliebe eine zuvor sichtbare, dann unsichtbar gemachte und gelöschte Liste als Geist stehen.
// Das verrät IDs nie sichtbarer gelöschter Datensätze (siehe docs/DATENSCHUTZ-ENTWURF.md).
//
// Mehrseitiger Snapshot: Die erste Seite (sinceRev 0) legt die Ziel-Revision fest (Stand der Familie) und nennt sie als `snapshotRev`.
// Folgeseiten senden sie zurück (sinceRev ist der Cursor): sie prüfen nie gegen purged_rev (Tombstones sind für einen Snapshot ohne
// Belang), liefern nur Einträge bis zur Ziel-Revision und nie Tombstones. Danach beginnt der normale Delta-Lauf ab der Ziel-Revision.
import { and, asc, eq, gt, inArray, lte } from 'drizzle-orm';
import type { AuthContext, Executor } from '../auth/context.js';
import { changeLog, families } from '../db/schema.js';
import { LOST_SIGHT, wireRow } from './engine.js';
import { mayRead, type Actor, type Facts } from './permissions.js';
import { syncColumns, type EntityDef, type Registry, type Row } from './registry.js';
import type { ChangeOut } from './types.js';

export interface PullResult {
  status: 'ok' | 'resync_required';
  rev: number;
  changes: ChangeOut[];
  hasMore: boolean;
  next: number;
  /** Nur bei einem laufenden Snapshot (es folgen weitere Seiten). */
  snapshotRev?: number;
}

type RowMap = Map<string, Map<string, Row>>;

/** Lädt Zeilen (und deren übergeordnete) in die Map; vorhandene werden nicht erneut gelesen. */
async function load(tx: Executor, registry: Registry, familyId: string, rows: RowMap, def: EntityDef, ids: string[]): Promise<void> {
  const have = rows.get(def.name) ?? new Map<string, Row>();
  rows.set(def.name, have);
  const missing = [...new Set(ids)].filter((id) => !have.has(id));
  if (missing.length === 0) return;
  const c = syncColumns(def);
  const found = (await tx
    .select()
    .from(def.table)
    .where(and(eq(c.familyId, familyId), inArray(c.id, missing)))) as Row[];
  for (const row of found) have.set(String(row.id), row);
  const parentDef = def.parent ? registry.get(def.parent.entity) : undefined;
  if (def.parent && parentDef) {
    await load(tx, registry, familyId, rows, parentDef, found.map((r) => String(r[def.parent!.field])));
  }
}

function factsFrom(registry: Registry, rows: RowMap, def: EntityDef, row: Row): Facts {
  let parentFacts: Facts | null = null;
  if (def.parent) {
    const parentDef = registry.get(def.parent.entity);
    const parentRow = rows.get(def.parent.entity)?.get(String(row[def.parent.field]));
    if (parentDef && parentRow) parentFacts = factsFrom(registry, rows, parentDef, parentRow);
  }
  return def.facts(row, parentFacts);
}

export async function pullChanges(
  ctx: Pick<AuthContext, 'db'>,
  registry: Registry,
  input: { actor: Actor; familyId: string; sinceRev: number; limit: number; snapshotRev?: number | undefined; forceResync?: boolean },
): Promise<PullResult> {
  const { actor, familyId, sinceRev, limit } = input;
  // eine Momentaufnahme für Stand der Familie, Protokoll und Zeilen
  return ctx.db.transaction(
    async (tx) => {
      const [family] = await tx.select({ rev: families.currentRev, purged: families.purgedRev }).from(families).where(eq(families.id, familyId));
      if (!family) return { status: 'ok' as const, rev: 0, changes: [], hasMore: false, next: 0 };
      const resync = { status: 'resync_required' as const, rev: family.rev, changes: [], hasMore: false, next: 0 };
      // die Sicht des Geräts hat sich geändert (Rolle gewechselt): alles verwerfen und neu beginnen
      if (input.forceResync) return resync;
      // laufender Snapshot: Folgeseite (sinceRev ist der Cursor, snapshotRev die Ziel-Revision); sonst Start oder normaler Delta-Lauf
      const following = sinceRev > 0 && input.snapshotRev !== undefined && input.snapshotRev > sinceRev;
      const snapshotMode = following || sinceRev === 0;
      const target = following ? (input.snapshotRev as number) : family.rev;
      // "aus der Zukunft" (Datenbank zurückgespielt): von vorn beginnen
      if (sinceRev > family.rev || target > family.rev) return resync;
      // Gerät kennt Löschungen nicht mehr (bereinigt): von vorn beginnen (ein laufender Snapshot braucht keine Tombstones)
      if (!following && sinceRev > 0 && sinceRev < family.purged) return resync;
      const entries = await tx
        .select()
        .from(changeLog)
        .where(and(eq(changeLog.familyId, familyId), gt(changeLog.rev, sinceRev), lte(changeLog.rev, target)))
        .orderBy(asc(changeLog.rev))
        .limit(limit + 1);
      const more = entries.length > limit;
      const page = more ? entries.slice(0, limit) : entries;
      // Seite voll: weiter ab dem letzten Eintrag. Letzte Seite eines Snapshots: ist die Familie weitergekommen, folgt der Delta-Lauf ab der Ziel-Revision.
      const cursor = more ? (page[limit - 1]?.rev ?? sinceRev) : target;
      const hasMore = more || (snapshotMode && family.rev > target);
      const next = hasMore ? cursor : family.rev;
      const snapshotRev = more && snapshotMode ? target : undefined;

      const rows: RowMap = new Map();
      for (const def of registry.list()) {
        const ids = page.filter((e) => e.entity === def.name).map((e) => e.entityId);
        if (ids.length > 0) await load(tx, registry, familyId, rows, def, ids);
      }

      const changes: ChangeOut[] = [];
      const hiddenSent = new Set<string>();
      for (const e of page) {
        const def = registry.get(e.entity);
        const row = rows.get(e.entity)?.get(e.entityId);
        if (def && !row && e.tombstone && !snapshotMode) {
          // Zeile ist weg (Fremdschlüssel-Kaskade beim Entfernen eines Mitglieds), der Tombstone-Eintrag bleibt: die Geräte sollen ihre Kopie entfernen
          // (nur die ID wird sichtbar, nie ein Inhalt; wie beim "hidden"-Tombstone unsichtbar gelöschter Datensätze)
          changes.push({ rev: e.rev, entity: e.entity, id: e.entityId, tombstone: true, hidden: true, fields: {} });
          continue;
        }
        if (!def || !row) continue; // unbekannte Entität oder bereits bereinigt
        const facts = factsFrom(registry, rows, def, row);
        const visible = mayRead(def.rules, actor, facts);
        // auf Teilnehmer beschränkte Datensätze: Unbeteiligte erfahren nie etwas (auch keine ID); wer die Sicht verliert, bekommt den Tombstone,
        // weil die Löschung für Teilnehmer sichtbar bleibt (Teilnehmerliste im Tombstone bleibt erhalten) und der Entzug im Protokoll vermerkt ist
        const restricted = facts.participants !== undefined;
        const current = Number(row.rev) === e.rev; // sonst ersetzt durch einen späteren Eintrag
        if (visible) {
          if (!current) continue;
          if (row.deletedAt) {
            if (!snapshotMode) changes.push({ rev: e.rev, entity: e.entity, id: e.entityId, tombstone: true, fields: {} });
          } else {
            changes.push({ rev: e.rev, entity: e.entity, id: e.entityId, tombstone: false, fields: wireRow(def, row) });
          }
        } else if (restricted) {
          const lost = e.changes[LOST_SIGHT];
          if (!snapshotMode && Array.isArray(lost) && lost.includes(actor.userId) && !hiddenSent.has(`${e.entity}:${e.entityId}`)) {
            hiddenSent.add(`${e.entity}:${e.entityId}`);
            changes.push({ rev: e.rev, entity: e.entity, id: e.entityId, tombstone: true, hidden: true, fields: {} });
          }
        } else if (!snapshotMode && row.deletedAt) {
          // gelöscht und nicht sichtbar: die Person kannte den Datensatz womöglich vorher (Sicht inzwischen entzogen)
          if (current && e.tombstone && !hiddenSent.has(`${e.entity}:${e.entityId}`)) {
            hiddenSent.add(`${e.entity}:${e.entityId}`);
            changes.push({ rev: e.rev, entity: e.entity, id: e.entityId, tombstone: true, hidden: true, fields: {} });
          }
        } else if (
          !snapshotMode &&
          !e.created &&
          !e.tombstone &&
          def.visibilityFields?.some((f) => f in e.changes) &&
          !hiddenSent.has(`${e.entity}:${e.entityId}`)
        ) {
          hiddenSent.add(`${e.entity}:${e.entityId}`);
          changes.push({ rev: e.rev, entity: e.entity, id: e.entityId, tombstone: true, hidden: true, fields: {} });
        }
      }
      return { status: 'ok' as const, rev: family.rev, changes, hasMore, next, ...(snapshotRev !== undefined ? { snapshotRev } : {}) };
    },
    { isolationLevel: 'repeatable read', accessMode: 'read only' },
  );
}
