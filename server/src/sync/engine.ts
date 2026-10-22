// Sync-Engine: wendet Ops des Clients an. Jede Op läuft in einer eigenen Transaktion:
//   1. Familienzeile sperren (serialisiert alle Schreiber der Familie; Commit-Reihenfolge = Revisions-Reihenfolge, keine Lücken),
//   2. Idempotenz über applied_ops (wiederholter Upload -> dasselbe Ergebnis, keine neue Revision),
//   3. Rechte (sync/permissions.ts), Validierung (Zod je Feld), Familienzugehörigkeit aller Verweise,
//   4. Konflikte feldweise, neue Revision, change_log, field_revs.
//
// Konfliktregeln (Entscheidung, siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6):
//  - Der Client sendet je Op `baseRev` (Revision des Datensatzes, auf der seine Änderung aufbaut). Ein Feld verliert, wenn seine
//    field_rev größer als `baseRev` ist (jemand hat es seitdem geändert) und die Änderung nicht vom selben Gerät stammt. Der Serverwert
//    bleibt, die Antwort nennt ihn in `conflicts`. Die Reihenfolge bestimmt der Server, nie die Uhr des Clients.
//  - Verschiedene Felder verschiedener Geräte werden zusammengeführt (Abhaken gewinnt nicht gegen Umbenennen).
//  - Löschen gewinnt: ein Update auf einen gelöschten Datensatz wird mit `deleted` abgelehnt, ein Löschen wirkt immer.
import { and, count, eq, gt, inArray, isNull, sql } from 'drizzle-orm';
import type { AuthContext, Executor } from '../auth/context.js';
import { appliedOps, changeLog, families, memberships, users } from '../db/schema.js';
import type { Role } from '../auth/types.js';
import { AppError } from '../errors.js';
import { authorize, mayRead, rolesThatMayRead, type Actor, type Facts } from './permissions.js';
import { columnOf, syncColumns, type EngineFlags, type EntityDef, type Registry, type Row } from './registry.js';
import type { ConflictOut, ParsedOp, RejectCode } from './types.js';

export interface OpOutcome {
  status: 'acked' | 'rejected';
  code?: RejectCode;
  /** Revision, unter der die Op übernommen wurde (null: ohne Wirkung oder abgelehnt). */
  rev: number | null;
  conflicts: Array<{ fields: Record<string, unknown>; serverRev: number }>;
  /** Rollen, die die Änderung (vorher oder nachher) sehen dürfen; nur bei einer frisch angewendeten Op mit Wirkung. */
  roles?: Role[];
  /** Personen, die die Änderung sehen dürfen, wenn der Datensatz auf Teilnehmer beschränkt ist (dann ist `roles` leer). */
  users?: string[];
  /** false: kein Push-Wecker (nur der WebSocket-Hinweis), z. B. Lesestand und Schlüssel-Wraps: sie betreffen nur die eigene Person. */
  wake?: boolean;
}

/** Schlüssel im Protokolleintrag (change_log.changes): Personen, die durch die Änderung die Sicht verloren haben (siehe EntityDef.lostSight). */
export const LOST_SIGHT = '__lostSight';
/** Wie LOST_SIGHT: Personen, die durch die Änderung die Sicht gewonnen haben (sie bekommen den bisherigen Inhalt beim Abgleich). */
export const GAINED_SIGHT = '__gainedSight';

const rejected = (code: RejectCode): OpOutcome => ({ status: 'rejected', code, rev: null, conflicts: [] });

/** Zähler der vergebenen Revisionen innerhalb einer Transaktion (die Familienzeile ist gesperrt). */
export class RevCounter {
  changed = false;
  constructor(public rev: number) {}
  next(): number {
    this.changed = true;
    return ++this.rev;
  }
}

export interface EngineEnv {
  tx: Executor;
  registry: Registry;
  familyId: string;
  actor: Actor;
  /** Gerät, von dem die Änderung kommt (null: der Server selbst, z. B. beim Entfernen eines Mitglieds). */
  deviceId: string | null;
  /** Person, der die Änderung im Protokoll zugeschrieben wird (null: der Server selbst). */
  authorId: string | null;
  now: Date;
  revs: RevCounter;
  /** Schalter des Servers, die einzelne Entitäten brauchen (aus der Konfiguration; fehlt bei Aufrufen des Servers selbst). */
  flags?: EngineFlags;
}

// ---------------------------------------------------------------- Hilfen

export async function loadRow(tx: Executor, def: EntityDef, familyId: string, id: string): Promise<Row | undefined> {
  const c = syncColumns(def);
  const rows = (await tx
    .select()
    .from(def.table)
    .where(and(eq(c.familyId, familyId), eq(c.id, id)))
    .limit(1)) as Row[];
  return rows[0];
}

/** Fakten (Freigabe, Besitzer) eines Datensatzes; untergeordnete Datensätze erben sie vom übergeordneten. */
export async function factsOf(env: Pick<EngineEnv, 'tx' | 'registry' | 'familyId'>, def: EntityDef, row: Row): Promise<Facts> {
  let parentFacts: Facts | null = null;
  if (def.parent) {
    const parentDef = env.registry.get(def.parent.entity);
    const parentRow = parentDef ? await loadRow(env.tx, parentDef, env.familyId, String(row[def.parent.field])) : undefined;
    if (parentDef && parentRow) parentFacts = await factsOf(env, parentDef, parentRow);
  }
  return def.facts(row, parentFacts);
}

/** Wert eines Feldes in der Schnittstelle (JSON). */
export function wireValue(def: EntityDef, field: string, value: unknown): unknown {
  const f = def.fields[field];
  return f?.toWire ? f.toWire(value) : value;
}

/** Alle Felder eines Datensatzes in der Schnittstelle. */
export function wireRow(def: EntityDef, row: Row): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const name of Object.keys(def.fields)) out[name] = wireValue(def, name, row[name]) ?? null;
  return out;
}

const sameValue = (def: EntityDef, field: string, a: unknown, b: unknown): boolean =>
  JSON.stringify(wireValue(def, field, a) ?? null) === JSON.stringify(wireValue(def, field, b) ?? null);

/** Wer die Änderung erfährt: Rollen (Sicht nach Freigabe) und Personen (Sicht nach Teilnehmerliste), jeweils über alle genannten Stände vereinigt. */
function recipients(def: EntityDef, ...facts: Facts[]): { roles: Role[]; users: string[]; wake: boolean } {
  const roles = new Set<Role>();
  const users = new Set<string>();
  for (const f of facts) {
    if (def.ownerOnlyNotify) {
      if (f.ownerId) users.add(f.ownerId);
      continue;
    }
    for (const r of rolesThatMayRead(def.rules, f)) roles.add(r);
    for (const u of f.participants ?? []) users.add(u);
  }
  return { roles: [...roles], users: [...users], wake: !def.ownerOnlyNotify && !def.noWake };
}

/** Prüft einen Wert, der eine Mitglieds-ID oder eine Liste davon ist: alle müssen aktive Mitglieder der Familie sein. */
async function memberRefsValid(tx: Executor, familyId: string, value: unknown): Promise<boolean> {
  if (typeof value === 'string') return isActiveMember(tx, familyId, value);
  if (Array.isArray(value)) {
    for (const v of value) if (typeof v !== 'string' || !(await isActiveMember(tx, familyId, v))) return false;
  }
  return true;
}

async function isActiveMember(tx: Executor, familyId: string, userId: string): Promise<boolean> {
  // entfernte (Soft-Delete) und gesperrte Konten sind keine gültigen Verweise mehr, auch wenn ihre Mitgliedschaft bis zum endgültigen Löschen liegen bleibt
  const rows = await tx
    .select({ id: memberships.id })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, familyId), eq(memberships.userId, userId), eq(memberships.status, 'active'), isNull(users.disabledAt)))
    .limit(1);
  return rows.length > 0;
}

export async function logChange(
  env: EngineEnv,
  input: { def: EntityDef; id: string; rev: number; tombstone: boolean; created: boolean; changes: Record<string, unknown> },
): Promise<void> {
  await env.tx.insert(changeLog).values({
    familyId: env.familyId,
    rev: input.rev,
    entity: input.def.name,
    entityId: input.id,
    tombstone: input.tombstone,
    created: input.created,
    changes: input.changes,
    authorId: env.authorId,
    deviceId: env.deviceId,
    createdAt: env.now,
  });
}

/** Untergeordnete lebende Datensätze. */
async function liveChildren(env: EngineEnv, def: EntityDef, parentId: string): Promise<Array<{ def: EntityDef; row: Row }>> {
  const out: Array<{ def: EntityDef; row: Row }> = [];
  for (const child of env.registry.childrenOf(def.name)) {
    if (!child.parent) continue;
    const c = syncColumns(child);
    const rows = (await env.tx
      .select()
      .from(child.table)
      .where(and(eq(c.familyId, env.familyId), eq(columnOf(child, child.parent.field), parentId), isNull(c.deletedAt)))) as Row[];
    for (const row of rows) out.push({ def: child, row });
  }
  return out;
}

/** Stößt untergeordnete Datensätze neu an (neue Revision ohne Inhaltsänderung), z. B. wenn sich die Freigabe der Liste ändert. */
async function touchChildren(env: EngineEnv, def: EntityDef, parentId: string): Promise<void> {
  for (const { def: child, row } of await liveChildren(env, def, parentId)) {
    const rev = env.revs.next();
    const c = syncColumns(child);
    await env.tx
      .update(child.table)
      .set({ rev, updatedAt: env.now } as never)
      .where(and(eq(c.familyId, env.familyId), eq(c.id, String(row.id))));
    await logChange(env, { def: child, id: String(row.id), rev, tombstone: false, created: false, changes: {} });
    await touchChildren(env, child, String(row.id));
  }
}

/**
 * Löscht einen Datensatz samt untergeordneten (Tombstones). Kinder bekommen niedrigere Revisionen als der Elternteil: wird der
 * Tombstone des Elternteils bereinigt, kennen alle Geräte auch die der Kinder. Inhalte werden überschrieben, Protokolleinträge geleert.
 */
export async function tombstoneTree(env: EngineEnv, def: EntityDef, row: Row): Promise<number> {
  for (const { def: child, row: childRow } of await liveChildren(env, def, String(row.id))) {
    await tombstoneTree(env, child, childRow);
  }
  const rev = env.revs.next();
  const c = syncColumns(def);
  const blanks: Row = {};
  for (const [name, f] of Object.entries(def.fields)) if (f.blank !== undefined) blanks[name] = f.blank;
  await env.tx
    .update(def.table)
    .set({ ...blanks, deletedAt: env.now, rev, fieldRevs: {}, updatedAt: env.now } as never)
    .where(and(eq(c.familyId, env.familyId), eq(c.id, String(row.id))));
  await env.tx
    .update(changeLog)
    // Inhalte weg; nur der Vermerk, wer die Sicht verloren hat, bleibt (sonst bliebe die Gruppe bei einem Gerät, das den Entzug noch nicht kannte, als Geist stehen)
    .set({ changes: sql`case when ${changeLog.changes} ? '__lostSight' then jsonb_build_object('__lostSight', ${changeLog.changes} -> '__lostSight') else '{}'::jsonb end` })
    .where(and(eq(changeLog.familyId, env.familyId), eq(changeLog.entity, def.name), eq(changeLog.entityId, String(row.id))));
  await logChange(env, { def, id: String(row.id), rev, tombstone: true, created: false, changes: {} });
  return rev;
}

// ---------------------------------------------------------------- Ops

type ParsedFields = { ok: true; values: Row } | { ok: false };

function parseFields(def: EntityDef, raw: Record<string, unknown>): ParsedFields {
  const values: Row = {};
  for (const [name, value] of Object.entries(raw)) {
    const spec = Object.hasOwn(def.fields, name) ? def.fields[name] : undefined;
    if (!spec || spec.access === 'server') return { ok: false };
    const parsed = spec.schema.safeParse(value);
    if (!parsed.success) return { ok: false };
    values[name] = parsed.data;
  }
  return { ok: true, values };
}

async function create(env: EngineEnv, def: EntityDef, op: ParsedOp, supplied: Row, revive?: Row): Promise<OpOutcome> {
  const values: Row = { ...supplied };
  for (const [name, f] of Object.entries(def.fields)) {
    if (f.access === 'server' || values[name] !== undefined) continue;
    if (f.required) return rejected('invalid');
    if (f.defaultValue !== undefined) values[name] = f.defaultValue;
  }
  // feste, abgeleitete IDs: jede andere ID ist ungültig (immer `invalid`, kein Orakel darüber, wer sie schon belegt hat)
  if (def.idValid && !def.idValid(op.id, values, env.actor, env.familyId)) return rejected('invalid');
  // übergeordneter Datensatz: vorhanden, lesbar, nicht gelöscht
  let parentFacts: Facts | null = null;
  let parentId: string | undefined;
  if (def.parent) {
    const parentDef = env.registry.get(def.parent.entity);
    parentId = String(values[def.parent.field]);
    const parentRow = parentDef ? await loadRow(env.tx, parentDef, env.familyId, parentId) : undefined;
    if (!parentDef || !parentRow) return rejected('not_found');
    parentFacts = await factsOf(env, parentDef, parentRow);
    if (!mayRead(parentDef.rules, env.actor, parentFacts)) return rejected('not_found');
    if (parentRow.deletedAt) return rejected('parent_deleted');
  }
  const decision = authorize(def.rules, 'create', env.actor, def.factsForCreate(env.actor, values, parentFacts), Object.keys(supplied), values);
  if (decision !== 'ok') return rejected(decision);
  if (def.check && !def.check(values)) return rejected('invalid');
  if (def.validate && !(await def.validate({ tx: env.tx, familyId: env.familyId, actor: env.actor, ...(env.flags ? { flags: env.flags } : {}) }, { ...values, id: op.id }))) return rejected('invalid');

  for (const [name, f] of Object.entries(def.fields)) {
    const v = values[name];
    if (f.memberRef && !(await memberRefsValid(env.tx, env.familyId, v))) return rejected('invalid_reference');
  }
  if (def.maxLive) {
    const c = syncColumns(def);
    const where = [eq(c.familyId, env.familyId), isNull(c.deletedAt)];
    if (def.maxLive.per === 'parent' && def.parent && parentId) where.push(eq(columnOf(def, def.parent.field), parentId));
    if (def.maxLive.openColumn) where.push(isNull(columnOf(def, def.maxLive.openColumn)));
    const [n] = await env.tx.select({ n: count() }).from(def.table).where(and(...where));
    if ((n?.n ?? 0) >= def.maxLive.max) return rejected('limit_reached');
  }
  if (def.maxFamily !== undefined) {
    const c = syncColumns(def);
    const [n] = await env.tx.select({ n: count() }).from(def.table).where(and(eq(c.familyId, env.familyId), isNull(c.deletedAt)));
    if ((n?.n ?? 0) >= def.maxFamily) return rejected('limit_reached');
  }

  if (def.ownerPerParent && def.parent && parentId) {
    const c = syncColumns(def);
    const [n] = await env.tx
      .select({ n: count() })
      .from(def.table)
      .where(
        and(
          eq(c.familyId, env.familyId),
          isNull(c.deletedAt),
          eq(columnOf(def, def.parent.field), parentId),
          eq(columnOf(def, def.ownerPerParent.field), env.actor.userId),
        ),
      );
    if ((n?.n ?? 0) >= def.ownerPerParent.max) return rejected('limit_reached');
  }

  if (def.ownerLimit && def.ownerLimit.roles.includes(env.actor.role)) {
    const c = syncColumns(def);
    const ownerWhere = [eq(c.familyId, env.familyId), isNull(c.deletedAt), eq(columnOf(def, def.ownerLimit.field), env.actor.userId)];
    if (def.ownerLimit.openColumn) ownerWhere.push(isNull(columnOf(def, def.ownerLimit.openColumn)));
    const [n] = await env.tx.select({ n: count() }).from(def.table).where(and(...ownerWhere));
    if ((n?.n ?? 0) >= def.ownerLimit.max) return rejected('limit_reached');
  }

  if (def.rate) {
    const c = syncColumns(def);
    const since = new Date(env.now.getTime() - 60_000);
    const zaehle = async (von: Date): Promise<number> => {
      if (def.rate?.viaLog) {
        // Anlegen und Wiederbeleben stehen als created im Protokoll (mit Autor): ein Umschalten derselben Zeile zählt jedes Mal
        const [x] = await env.tx
          .select({ n: count() })
          .from(changeLog)
          .where(and(eq(changeLog.familyId, env.familyId), eq(changeLog.entity, def.name), eq(changeLog.authorId, env.actor.userId), eq(changeLog.created, true), gt(changeLog.createdAt, von)));
        return x?.n ?? 0;
      }
      const [x] = await env.tx
        .select({ n: count() })
        .from(def.table)
        .where(and(eq(c.familyId, env.familyId), eq(columnOf(def, def.rate!.field), env.actor.userId), gt(columnOf(def, 'createdAt'), von)));
      return x?.n ?? 0;
    };
    if ((await zaehle(since)) >= def.rate.perMinute) return rejected('limit_reached');
    if (def.rate.perHour !== undefined && (await zaehle(new Date(env.now.getTime() - 3_600_000))) >= def.rate.perHour) return rejected('limit_reached');
    // Byte-Kontingent je Person (Stunde und Tag) über die Länge des Inhalts
    const b = def.rate.bytes;
    if (b) {
      const incoming = Buffer.byteLength(String(values[b.field] ?? ''), 'utf8');
      for (const [span, max] of [
        [3_600_000, b.perHour],
        [86_400_000, b.perDay],
      ] as const) {
        const [used] = await env.tx
          .select({ n: sql<string>`coalesce(sum(octet_length(${columnOf(def, b.field)})), 0)::text` })
          .from(def.table)
          .where(and(eq(c.familyId, env.familyId), eq(columnOf(def, def.rate.field), env.actor.userId), gt(columnOf(def, 'createdAt'), new Date(env.now.getTime() - span))));
        if (Number(used?.n ?? 0) + incoming > max) return rejected('limit_reached');
      }
    }
  }

  const rev = env.revs.rev + 1; // erst nach erfolgreichem Einfügen vergeben (sonst entstünde eine Lücke)
  const fieldRevs: Record<string, number> = {};
  for (const [name, f] of Object.entries(def.fields)) if (f.access !== 'server') fieldRevs[name] = rev;
  const row: Row = { ...values, ...(def.onCreate?.(env.actor, env.now) ?? {}), ...(def.derive?.(env.actor, values) ?? {}), id: op.id, familyId: env.familyId, rev, fieldRevs, createdAt: env.now, updatedAt: env.now };
  const c = syncColumns(def);
  // Wiederbeleben: der gelöschte Datensatz mit fester ID wird zu einem neuen (Tombstone verschwindet, Kinder bleiben gelöscht)
  const inserted = revive
    ? await env.tx
        .update(def.table)
        .set({ ...Object.fromEntries(Object.entries(row).filter(([k]) => !(def.reviveKeep ?? []).includes(k))), deletedAt: null } as never)
        .where(and(eq(c.familyId, env.familyId), eq(c.id, op.id)))
        .returning({ id: c.id })
    : await env.tx
        .insert(def.table)
        .values(row as never)
        .onConflictDoNothing() // jede Eindeutigkeit (ID, aktive Teilnehmer/Ausnahmen) ergibt eine Ablehnung, nie einen Datenbankfehler
        .returning({ id: c.id });
  // die ID gehört einem fremden Datensatz (auch einer anderen Familie) oder der Datensatz gibt es schon: nicht verraten, was davon
  if (inserted.length === 0) return rejected('not_found');
  env.revs.next();
  await logChange(env, { def, id: op.id, rev, tombstone: false, created: true, changes: wireRow(def, row) });
  const to = recipients(def, def.factsForCreate(env.actor, values, parentFacts));
  return { status: 'acked', rev, conflicts: [], roles: to.roles, users: to.users, wake: to.wake };
}

async function update(env: EngineEnv, def: EntityDef, op: ParsedOp, row: Row, supplied: Row): Promise<OpOutcome> {
  const facts = await factsOf(env, def, row);
  const written = Object.keys(supplied).filter((n) => def.fields[n]?.access !== 'create');
  const decision = authorize(def.rules, 'update', env.actor, facts, written, supplied);
  if (decision === 'not_found') return rejected('not_found');
  if (row.deletedAt) return rejected('deleted');
  if (decision !== 'ok') return rejected(decision);
  if (def.guard && !def.guard('update', row, { ...row, ...supplied })) return rejected('forbidden');

  // unveränderliche Felder (access 'create') dürfen nur denselben Wert wiederholen
  const wanted: Row = {};
  for (const [name, value] of Object.entries(supplied)) {
    if (def.fields[name]?.access === 'create') {
      if (!sameValue(def, name, row[name], value)) return rejected('invalid');
      continue;
    }
    wanted[name] = value;
  }

  const fieldRevs = (row.fieldRevs ?? {}) as Record<string, number>;
  // Änderungen desselben Geräts gelten nicht als Konflikt (mehrere Ops des Geräts mit gleichem baseRev nacheinander)
  const newer = Object.keys(wanted)
    .map((f) => fieldRevs[f] ?? 0)
    .filter((r) => r > op.baseRev);
  const authors = new Map<number, string | null>();
  if (newer.length > 0) {
    const logs = await env.tx
      .select({ rev: changeLog.rev, deviceId: changeLog.deviceId })
      .from(changeLog)
      .where(and(eq(changeLog.familyId, env.familyId), inArray(changeLog.rev, newer)));
    for (const l of logs) authors.set(l.rev, l.deviceId);
  }

  const changed: Row = {};
  const lost: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(wanted)) {
    if (sameValue(def, name, row[name], value)) continue;
    const fr = fieldRevs[name] ?? 0;
    const own = env.deviceId !== null && authors.get(fr) === env.deviceId;
    if (fr > op.baseRev && !own) lost[name] = wireValue(def, name, row[name]) ?? null;
    else changed[name] = value;
  }
  const conflicts = Object.keys(lost).length > 0 ? [{ fields: lost, serverRev: Number(row.rev) }] : [];
  if (Object.keys(changed).length === 0) return { status: 'acked', rev: null, conflicts };
  Object.assign(changed, def.derive?.(env.actor, changed) ?? {});
  if (def.onUpdate) {
    for (const [k, v] of Object.entries(def.onUpdate(changed, env.now, row))) {
      if (v === undefined) delete changed[k];
      else changed[k] = v;
    }
    if (Object.keys(changed).length === 0) return { status: 'acked', rev: null, conflicts };
  }
  if (def.validate && !(await def.validate({ tx: env.tx, familyId: env.familyId, actor: env.actor, ...(env.flags ? { flags: env.flags } : {}) }, { ...row, ...changed }))) return rejected('invalid');
  // Mengenbegrenzung für Änderungen (z. B. Teilnehmerwechsel, Text-Bearbeitungen): gezählt wird im Änderungsprotokoll
  if (def.updateRate && def.updateRate.fields.some((f) => f in changed)) {
    const fieldList = sql.join(def.updateRate.fields.map((f) => sql`${f}`), sql`, `);
    const [n] = await env.tx
      .select({ n: count() })
      .from(changeLog)
      .where(
        and(
          eq(changeLog.familyId, env.familyId),
          eq(changeLog.entity, def.name),
          eq(changeLog.authorId, env.actor.userId),
          eq(changeLog.created, false),
          gt(changeLog.createdAt, new Date(env.now.getTime() - 60_000)),
          sql`${changeLog.changes} ?| array[${fieldList}]::text[]`,
        ),
      );
    if ((n?.n ?? 0) >= def.updateRate.perMinute) return rejected('limit_reached');
  }
  if (def.check && !def.check({ ...row, ...changed })) return rejected('invalid');
  if (def.guard && !def.guard('update', row, { ...row, ...changed })) return rejected('forbidden');
  for (const [name, value] of Object.entries(changed)) {
    if (def.fields[name]?.memberRef && !(await memberRefsValid(env.tx, env.familyId, value))) return rejected('invalid_reference');
  }

  const rev = env.revs.next();
  const newFieldRevs = { ...fieldRevs };
  for (const name of Object.keys(changed)) newFieldRevs[name] = rev;
  const c = syncColumns(def);
  await env.tx
    .update(def.table)
    .set({ ...changed, rev, fieldRevs: newFieldRevs, updatedAt: env.now } as never)
    .where(and(eq(c.familyId, env.familyId), eq(c.id, op.id)));
  const wireChanges: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(changed)) wireChanges[name] = wireValue(def, name, value) ?? null;
  // wer durch diese Änderung die Sicht verliert (nur diese Personen bekommen später den hidden-Tombstone; steht nur im Protokoll, nie in einer Antwort)
  const gone = def.lostSight?.(row, { ...row, ...changed }) ?? [];
  if (gone.length > 0) wireChanges[LOST_SIGHT] = [...gone];
  const gained = def.gainedSight?.(row, { ...row, ...changed }) ?? [];
  if (gained.length > 0) wireChanges[GAINED_SIGHT] = [...gained];
  await logChange(env, { def, id: op.id, rev, tombstone: false, created: false, changes: wireChanges });
  // wer die Änderung sehen darf: Sicht vorher und nachher (bei geänderter Freigabe erfahren auch die, die die Sicht verlieren, davon)
  // ersetzte Inhalte bleiben nicht in älteren Protokolleinträgen (der Stand steht in der Fachtabelle; Protokolle brauchen nur die Feldnamen)
  for (const field of def.scrubOnUpdate ?? []) {
    if (!(field in changed)) continue;
    await env.tx.execute(
      sql`update change_log set changes = changes - ${field}::text where family_id = ${env.familyId} and entity = ${def.name} and entity_id = ${op.id} and rev < ${rev}`,
    );
  }
  const to = recipients(def, facts, await factsOf(env, def, { ...row, ...changed }));
  // Freigabe geändert: untergeordnete Datensätze neu anstoßen, damit Geräte, die sie jetzt sehen dürfen, sie bekommen
  if (def.visibilityFields?.some((f) => f in changed)) await touchChildren(env, def, op.id);
  return { status: 'acked', rev, conflicts, roles: to.roles, users: to.users, wake: to.wake };
}

async function remove(env: EngineEnv, def: EntityDef, row: Row | undefined): Promise<OpOutcome> {
  if (!row) return rejected('not_found');
  const facts = await factsOf(env, def, row);
  const decision = authorize(def.rules, 'delete', env.actor, facts);
  if (decision === 'not_found') return rejected('not_found');
  if (row.deletedAt) return { status: 'acked', rev: null, conflicts: [] }; // schon gelöscht: nichts zu tun
  if (decision !== 'ok') return rejected(decision);
  if (def.guard && !def.guard('delete', row)) return rejected('forbidden');
  const rev = await tombstoneTree(env, def, row);
  const to = recipients(def, facts);
  return { status: 'acked', rev, conflicts: [], roles: to.roles, users: to.users, wake: to.wake };
}

/** Bewertet eine Op im Rahmen einer geöffneten Transaktion (die Familienzeile ist gesperrt). */
export async function evaluateOp(env: EngineEnv, op: ParsedOp): Promise<OpOutcome> {
  const def = env.registry.get(op.entity);
  if (!def) return rejected('unknown_entity');
  const row = await loadRow(env.tx, def, env.familyId, op.id);
  if (op.op === 'delete') {
    if (op.fields !== undefined) return rejected('invalid');
    return remove(env, def, row);
  }
  const parsed = parseFields(def, op.fields ?? {});
  if (!parsed.ok) return rejected('invalid');
  if (!row) {
    // baseRev > 0: der Client kannte den Datensatz, er ist inzwischen (bereinigt) weg
    if (op.baseRev > 0) return rejected('not_found');
    return create(env, def, op, parsed.values);
  }
  // gelöschter Datensatz mit fester ID (z. B. Direktchat nach Entfernen der Person): erneutes Anlegen belebt ihn wieder
  if (row.deletedAt && op.baseRev === 0 && def.revive?.(row)) return create(env, def, op, parsed.values, row);
  return update(env, def, op, row, parsed.values);
}

export interface AppliedOp {
  outcome: OpOutcome;
  /** Neue Revision der Familie, wenn die Op etwas geändert hat. */
  committedRev: number | null;
}

/** Zeitlimits einer Op in der Datenbank (Millisekunden). */
export interface OpTimeouts {
  lockMs: number;
  statementMs: number;
}

/** PostgreSQL-Fehlercode (auch aus der Ursache, in die Drizzle den Fehler einpackt). */
function pgCode(err: unknown): string | undefined {
  for (let e: unknown = err, depth = 0; e && typeof e === 'object' && depth < 4; e = (e as { cause?: unknown }).cause, depth++) {
    const code = (e as { code?: unknown }).code;
    if (typeof code === 'string') return code;
  }
  return undefined;
}

const busy = () => new AppError(503, 'server_busy', 'Der Server ist gerade ausgelastet. Bitte gleich erneut versuchen.', { 'retry-after': '2' });

/**
 * Konflikte einer wiederholten Op: gespeichert sind nur Feldnamen. Die Rechte werden neu geprüft; wer den Datensatz inzwischen nicht mehr
 * sehen darf (oder wenn er gelöscht ist), bekommt keine Werte. Sonst gilt der aktuelle Stand des Servers.
 */
async function replayConflicts(
  env: Pick<EngineEnv, 'tx' | 'registry' | 'familyId' | 'actor'>,
  prior: { entity: string | null; entityId: string | null; conflicts: Array<{ fields: string[]; serverRev: number }> },
  op: ParsedOp,
): Promise<OpOutcome['conflicts']> {
  if (prior.conflicts.length === 0) return [];
  const def = env.registry.get(prior.entity ?? op.entity);
  if (!def) return [];
  const row = await loadRow(env.tx, def, env.familyId, prior.entityId ?? op.id);
  if (!row || row.deletedAt || !mayRead(def.rules, env.actor, await factsOf(env, def, row))) return [];
  return prior.conflicts.map((c) => ({
    fields: Object.fromEntries(c.fields.filter((f) => Object.hasOwn(def.fields, f)).map((f) => [f, wireValue(def, f, row[f]) ?? null])),
    serverRev: Number(row.rev),
  }));
}

/** Wendet eine Op an (eine Transaktion, idempotent über applied_ops; Zeitlimits: Überlast wird zu 503 statt zu hängenden Anfragen). */
export async function applyOp(
  ctx: Pick<AuthContext, 'db' | 'now' | 'config'>,
  registry: Registry,
  input: { actor: Actor; familyId: string; deviceId: string | null; op: ParsedOp; timeouts?: OpTimeouts },
): Promise<AppliedOp> {
  const { actor, familyId, deviceId, op, timeouts } = input;
  try {
    return await ctx.db.transaction(async (tx) => {
      if (timeouts) {
        await tx.execute(sql`select set_config('lock_timeout', ${String(timeouts.lockMs)}, true), set_config('statement_timeout', ${String(timeouts.statementMs)}, true)`);
      }
      // Sperre: ab hier ist der Schreiber der einzige dieser Familie bis zum Commit
      const [family] = await tx.select({ rev: families.currentRev }).from(families).where(eq(families.id, familyId)).for('update');
      if (!family) return { outcome: rejected('not_found'), committedRev: null };
      const [prior] = await tx
        .select()
        .from(appliedOps)
        .where(and(eq(appliedOps.familyId, familyId), eq(appliedOps.opId, op.opId)));
      if (prior) {
        if (prior.deviceId !== deviceId) return { outcome: rejected('duplicate_op'), committedRev: null };
        const outcome: OpOutcome = {
          status: prior.status === 'rejected' ? 'rejected' : 'acked',
          ...(prior.code ? { code: prior.code as RejectCode } : {}),
          rev: prior.rev,
          conflicts: prior.status === 'rejected' ? [] : await replayConflicts({ tx, registry, familyId, actor }, prior, op),
        };
        return { outcome, committedRev: null };
      }
      const revs = new RevCounter(family.rev);
      const env: EngineEnv = { tx, registry, familyId, actor, deviceId, authorId: actor.userId, now: ctx.now(), revs, flags: { wrapKeyVersion: ctx.config.e2eeWrapKeyVersion } };
      const outcome = await evaluateOp(env, op);
      if (outcome.status === 'rejected' && revs.changed) throw new Error('Abgelehnte Op hat eine Revision vergeben');
      if (revs.changed) await tx.update(families).set({ currentRev: revs.rev }).where(eq(families.id, familyId));
      await tx.insert(appliedOps).values({
        familyId,
        opId: op.opId,
        deviceId,
        rev: outcome.rev,
        status: outcome.status,
        code: outcome.code ?? null,
        // nur die Namen der Felder, nie die Werte (siehe schema.ts)
        conflicts: outcome.conflicts.map((c) => ({ fields: Object.keys(c.fields), serverRev: c.serverRev })),
        entity: op.entity,
        entityId: op.id,
        createdAt: env.now,
      });
      return { outcome, committedRev: revs.changed ? revs.rev : null };
    });
  } catch (err) {
    // 55P03: Sperre nicht rechtzeitig bekommen, 57014: Anweisung zu lange gelaufen
    const code = pgCode(err);
    if (code === '55P03' || code === '57014') throw busy();
    throw err;
  }
}

export function toConflicts(op: ParsedOp, outcome: OpOutcome): ConflictOut[] {
  return outcome.conflicts.map((c) => ({ opId: op.opId, entity: op.entity, id: op.id, fields: c.fields, serverRev: c.serverRev }));
}
