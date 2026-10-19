// Sync-Kern: Idempotenz, Feldkonflikte, Löschen, Paginierung, Resync, Parallelität, Validierung.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, deviceOf, items, listsOf, remove, resetSync, upsert, type Family, type Json } from './sync-kit.js';

const rows = async (world: World, query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];

describe.each(backends)('Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000' });
    fam = await createFamily(world);
  }, 120_000);
  afterAll(async () => {
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    fam.admin.sinceRev = fam.parent.sinceRev = fam.child.sinceRev = fam.guest.sinceRev = 0;
  });

  const listId = () => randomUUID();
  const newList = async (name = 'Einkauf', extra: Json = {}) => {
    const id = listId();
    const res = await fam.admin.sync([upsert('list', id, { name, ...extra })]);
    expect(res.json.acked).toHaveLength(1);
    return id;
  };

  describe('Grundablauf', () => {
    it('Liste und Eintrag anlegen: Revisionen laufen lückenlos, Änderungen kommen mit vollem Stand zurück', async () => {
      const lid = listId();
      const iid = randomUUID();
      const res = await fam.admin.sync([upsert('list', lid, { name: 'Einkauf', kind: 'shopping' }), upsert('list_item', iid, { listId: lid, text: 'Milch', position: 1 })]);
      expect(res.status).toBe(200);
      expect(res.json).toMatchObject({ status: 'ok', rev: 2, rejected: [], conflicts: [], hasMore: false });
      expect(res.json.acked).toHaveLength(2);
      expect(res.json.changes.map((c: Json) => [c.rev, c.entity, c.tombstone])).toEqual([
        [1, 'list', false],
        [2, 'list_item', false],
      ]);
      const list = res.json.changes[0];
      expect(list.fields).toMatchObject({ name: 'Einkauf', kind: 'shopping', audience: 'family', ownerId: fam.admin.userId });
      expect(res.json.changes[1].fields).toMatchObject({ listId: lid, text: 'Milch', position: 1, assigneeId: null, doneAt: null });
      expect(typeof res.json.serverTime).toBe('string');
    });

    it('ein zweites Gerät bekommt den Stand per Snapshot und danach nur noch Neues', async () => {
      const lid = await newList();
      const pulled = await fam.parent.pull();
      expect(listsOf(pulled).map((c) => c.id)).toEqual([lid]);
      expect(fam.parent.sinceRev).toBe(1);
      await fam.admin.sync([upsert('list_item', randomUUID(), { listId: lid, text: 'Brot' })]);
      const next = await fam.parent.pull();
      expect(next).toHaveLength(1);
      expect(next[0]?.fields.text).toBe('Brot');
      expect(await fam.parent.pull()).toEqual([]);
    });

    it('ein Eintrag zeigt nur geänderte Felder im Protokoll, der Strom liefert den vollen Stand', async () => {
      const lid = await newList();
      const iid = randomUUID();
      await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Milch' })]);
      await fam.parent.pull();
      const res = await fam.admin.sync([upsert('list_item', iid, { doneAt: '2026-10-19T08:00:00.000Z' }, 2)], { sinceRev: 2 });
      expect(res.json.acked).toHaveLength(1);
      const log = await rows(world, sql`select rev, changes, created from change_log order by rev`);
      expect(log.at(-1)).toMatchObject({ created: false, changes: { doneAt: '2026-10-19T08:00:00.000Z' } });
      expect(Number(log.at(-1)?.rev)).toBe(3);
      const change = (await fam.parent.pull())[0] as Json;
      expect(change.fields).toMatchObject({ text: 'Milch', doneAt: '2026-10-19T08:00:00.000Z' });
    });

    it('eine Änderung ohne Wirkung (gleiche Werte) vergibt keine Revision', async () => {
      const lid = await newList('Einkauf');
      const res = await fam.admin.sync([upsert('list', lid, { name: 'Einkauf' }, 1)], { sinceRev: 1 });
      expect(res.json.acked).toHaveLength(1);
      expect(res.json.rev).toBe(1);
      expect(await world.count('change_log')).toBe(1);
    });
  });

  describe('Idempotenz', () => {
    it('derselbe Upload nach verlorenem Ack erhöht die Revision nicht und liefert dasselbe Ergebnis', async () => {
      const lid = listId();
      const op = upsert('list', lid, { name: 'Einkauf' });
      const first = await fam.admin.sync([op]);
      const second = await fam.admin.sync([op]);
      expect(second.json.acked).toEqual(first.json.acked);
      expect(second.json.rev).toBe(first.json.rev);
      expect(await world.count('change_log')).toBe(1);
      expect(await world.count('lists')).toBe(1);
    });

    it('derselbe Upload mit Konflikt liefert denselben Konflikt noch einmal', async () => {
      const lid = await newList('A');
      await fam.parent.sync([], { sinceRev: 0 });
      await fam.parent.sync([upsert('list', lid, { name: 'B' }, 1)]);
      const op = upsert('list', lid, { name: 'C' }, 1);
      const first = await fam.admin.sync([op]);
      expect(first.json.conflicts).toHaveLength(1);
      const again = await fam.admin.sync([op]);
      expect(again.json.conflicts).toEqual(first.json.conflicts);
      expect(again.json.acked).toEqual([op.opId]);
    });

    it('eine abgelehnte Op bleibt abgelehnt, auch wenn sich die Lage später ändert', async () => {
      const op = upsert('list_item', randomUUID(), { listId: randomUUID(), text: 'x' });
      expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'not_found' }]);
      const again = await fam.admin.sync([op]);
      expect(again.json.rejected).toEqual([{ opId: op.opId, code: 'not_found' }]);
      expect(again.json.acked).toEqual([]);
    });

    it('dieselbe op_id in einer Anfrage zweimal: nur einmal angewendet', async () => {
      const op = upsert('list', listId(), { name: 'Einkauf' });
      const res = await fam.admin.sync([op, op]);
      expect(res.json.acked).toEqual([op.opId, op.opId]);
      expect(await world.count('lists')).toBe(1);
      expect(res.json.rev).toBe(1);
    });

    it('eine op_id eines anderen Geräts wird nicht übernommen', async () => {
      const op = upsert('list', listId(), { name: 'Einkauf' });
      await fam.admin.sync([op]);
      const res = await fam.parent.sync([op]);
      expect(res.json.rejected).toEqual([{ opId: op.opId, code: 'duplicate_op' }]);
    });

    it('wiederholtes Löschen ist ein Erfolg ohne neue Revision', async () => {
      const lid = await newList();
      const del = remove('list', lid, 1);
      await fam.admin.sync([del]);
      const rev = (await fam.admin.sync([], { sinceRev: 99 })).json.rev;
      const res = await fam.admin.sync([remove('list', lid, 1)]);
      expect(res.json.acked).toHaveLength(1);
      expect(res.json.rev).toBe(rev === 0 ? res.json.rev : rev);
      expect(await world.count('change_log')).toBe(2);
    });
  });

  describe('Feldkonflikte (Last-write-wins pro Feld)', () => {
    it('zwei Geräte ändern verschiedene Felder: beide Änderungen bleiben', async () => {
      const lid = await newList('Einkauf');
      const iid = randomUUID();
      await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Milch' })]);
      const a = fam.admin;
      const b = fam.parent;
      await b.pull();
      const resA = await a.sync([upsert('list_item', iid, { text: 'Milch (2x)' }, 2)]);
      const resB = await b.sync([upsert('list_item', iid, { doneAt: '2026-10-19T09:00:00.000Z' }, 2)]);
      expect(resA.json.conflicts).toEqual([]);
      expect(resB.json.conflicts).toEqual([]);
      const state = (await b.pull()).find((c) => c.id === iid) as Json;
      expect(state.fields).toMatchObject({ text: 'Milch (2x)', doneAt: '2026-10-19T09:00:00.000Z' });
    });

    it('zwei Geräte ändern dasselbe Feld: die später eintreffende Änderung verliert und bekommt den Serverwert', async () => {
      const lid = await newList('Einkauf');
      await fam.parent.pull();
      const a = await fam.admin.sync([upsert('list', lid, { name: 'Wocheneinkauf' }, 1)]);
      expect(a.json.conflicts).toEqual([]);
      const b = await fam.parent.sync([upsert('list', lid, { name: 'Großeinkauf', kind: 'packing' }, 1)]);
      expect(b.json.acked).toHaveLength(1);
      expect(b.json.conflicts).toEqual([{ opId: expect.any(String), entity: 'list', id: lid, fields: { name: 'Wocheneinkauf' }, serverRev: 2 }]);
      const state = (await fam.parent.pull()).find((c) => c.id === lid) as Json;
      // das nicht umstrittene Feld der verlierenden Op wurde übernommen
      expect(state.fields).toMatchObject({ name: 'Wocheneinkauf', kind: 'packing' });
    });

    it('mehrere Ops desselben Geräts mit gleichem baseRev kollidieren nicht miteinander', async () => {
      const lid = await newList('A');
      const res = await fam.admin.sync([upsert('list', lid, { name: 'B' }, 1), upsert('list', lid, { name: 'C' }, 1), upsert('list', lid, { name: 'D' }, 1)]);
      expect(res.json.conflicts).toEqual([]);
      expect((await fam.admin.pull()).find((c) => c.id === lid)?.fields.name).toBe('D');
    });

    it('Anlegen und sofort Ändern in einer Anfrage (baseRev 0) funktioniert', async () => {
      const lid = listId();
      const res = await fam.admin.sync([upsert('list', lid, { name: 'A' }), upsert('list', lid, { name: 'B' }, 0)]);
      expect(res.json.conflicts).toEqual([]);
      expect(res.json.changes.find((c: Json) => c.id === lid).fields.name).toBe('B');
    });

    it('die Reihenfolge bestimmt der Server, nicht die Uhr des Clients', async () => {
      const lid = await newList('A');
      await fam.parent.pull();
      world.advance(3_600_000);
      await fam.admin.sync([upsert('list', lid, { name: 'später in der Zeit, früher am Server' }, 1)]);
      world.advance(-7_200_000);
      const res = await fam.parent.sync([upsert('list', lid, { name: 'andere Uhr' }, 1)]);
      expect(res.json.conflicts[0].fields.name).toBe('später in der Zeit, früher am Server');
    });

    it('Abhaken gewinnt nicht gegen gleichzeitiges Umbenennen (verschiedene Einträge und Felder bleiben unabhängig)', async () => {
      const lid = await newList();
      const i1 = randomUUID();
      const i2 = randomUUID();
      await fam.admin.sync([upsert('list_item', i1, { listId: lid, text: 'Milch' }), upsert('list_item', i2, { listId: lid, text: 'Brot' })]);
      await fam.parent.pull();
      await fam.admin.sync([upsert('list_item', i1, { doneAt: '2026-10-19T09:00:00.000Z' }, 2)]);
      const res = await fam.parent.sync([upsert('list_item', i1, { text: 'Hafermilch' }, 2), upsert('list_item', i2, { doneAt: '2026-10-19T09:01:00.000Z' }, 3)]);
      expect(res.json.conflicts).toEqual([]);
      const s = await fam.admin.pull();
      const first = s.find((c) => c.id === i1) as Json;
      expect(first.fields).toMatchObject({ text: 'Hafermilch', doneAt: '2026-10-19T09:00:00.000Z' });
    });

    it('gleicher Wert wie auf dem Server ist kein Konflikt', async () => {
      const lid = await newList('A');
      await fam.parent.pull();
      await fam.admin.sync([upsert('list', lid, { name: 'B' }, 1)]);
      const res = await fam.parent.sync([upsert('list', lid, { name: 'B' }, 1)]);
      expect(res.json.conflicts).toEqual([]);
      expect(res.json.acked).toHaveLength(1);
    });
  });

  describe('Löschen', () => {
    it('Löschen gewinnt: eine Änderung an einem gelöschten Datensatz wird mit deleted abgelehnt', async () => {
      const lid = await newList();
      const iid = randomUUID();
      await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Milch' })]);
      await fam.parent.pull();
      await fam.admin.sync([remove('list_item', iid, 2)]);
      const op = upsert('list_item', iid, { text: 'Hafermilch' }, 2);
      const res = await fam.parent.sync([op]);
      expect(res.json.rejected).toEqual([{ opId: op.opId, code: 'deleted' }]);
      expect(res.json.acked).toEqual([]);
      const change = res.json.changes.find((c: Json) => c.id === iid);
      expect(change).toMatchObject({ tombstone: true, fields: {} });
    });

    it('Löschen wirkt auch gegen eine frühere gleichzeitige Änderung und leert den Inhalt', async () => {
      const lid = await newList();
      const iid = randomUUID();
      await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Geheimer Inhalt', assigneeId: fam.child.userId })]);
      await fam.parent.sync([upsert('list_item', iid, { text: 'Geändert' }, 0)], { sinceRev: 0 });
      await fam.admin.sync([remove('list_item', iid, 2)]);
      const [row] = await rows(world, sql`select text, assignee_id, deleted_at, field_revs from list_items where id = ${iid}`);
      expect(row).toMatchObject({ text: '', assignee_id: null });
      expect(row?.deleted_at).not.toBeNull();
      const log = await rows(world, sql`select changes, tombstone from change_log where entity_id = ${iid} order by rev`);
      expect(log.length).toBeGreaterThan(1);
      for (const l of log) expect(l.changes).toEqual({});
      expect(log.at(-1)?.tombstone).toBe(true);
    });

    it('Liste löschen löscht ihre Einträge mit (Tombstones, Kinder vor der Liste)', async () => {
      const lid = await newList();
      const a = randomUUID();
      const b = randomUUID();
      await fam.admin.sync([upsert('list_item', a, { listId: lid, text: 'A' }), upsert('list_item', b, { listId: lid, text: 'B' })]);
      await fam.parent.pull();
      const res = await fam.admin.sync([remove('list', lid, 1)], { sinceRev: 3 });
      expect(res.json.rev).toBe(6);
      const tomb = res.json.changes.map((c: Json) => [c.rev, c.entity, c.tombstone]);
      expect(tomb).toEqual([
        [4, 'list_item', true],
        [5, 'list_item', true],
        [6, 'list', true],
      ]);
      expect((await rows(world, sql`select count(*)::int as n from list_items where deleted_at is null`))[0]?.n).toBe(0);
    });

    it('in einer gelöschten Liste lässt sich kein Eintrag anlegen (parent_deleted)', async () => {
      const lid = await newList();
      await fam.admin.sync([remove('list', lid, 1)]);
      const op = upsert('list_item', randomUUID(), { listId: lid, text: 'x' });
      expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'parent_deleted' }]);
    });

    it('Löschen eines unbekannten Datensatzes: not_found; ein frischer Snapshot enthält keine Tombstones', async () => {
      const op = remove('list', randomUUID(), 1);
      expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'not_found' }]);
      const lid = await newList();
      await fam.admin.sync([remove('list', lid, 1)]);
      const fresh = await fam.child.sync([], { sinceRev: 0 });
      expect(fresh.json.changes).toEqual([]);
    });
  });

  describe('Änderungsstrom: Paginierung und Resync', () => {
    it('liefert seitenweise in stabiler Reihenfolge', async () => {
      const lid = await newList();
      const ids = Array.from({ length: 12 }, () => randomUUID());
      await fam.admin.sync(ids.map((id, i) => upsert('list_item', id, { listId: lid, text: `E${i}`, position: i })));
      const first = await fam.parent.sync([], { sinceRev: 0, limit: 5 });
      expect(first.json).toMatchObject({ hasMore: true, next: 5 });
      expect(first.json.changes).toHaveLength(5);
      const got: number[] = first.json.changes.map((c: Json) => c.rev);
      let since = first.json.next as number;
      for (let i = 0; i < 5; i++) {
        const page = await fam.parent.sync([], { sinceRev: since, limit: 5 });
        got.push(...page.json.changes.map((c: Json) => c.rev));
        if (!page.json.hasMore) {
          expect(page.json.rev).toBe(13);
          break;
        }
        since = page.json.next;
      }
      expect(got).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
    });

    it('ersetzte Einträge werden übersprungen: nur der letzte Stand je Datensatz', async () => {
      const lid = await newList('A');
      await fam.admin.sync([upsert('list', lid, { name: 'B' }, 1)], { sinceRev: 1 });
      await fam.admin.sync([upsert('list', lid, { name: 'C' }, 2)], { sinceRev: 2 });
      const fresh = await fam.parent.sync([], { sinceRev: 0 });
      expect(fresh.json.changes).toHaveLength(1);
      expect(fresh.json.changes[0]).toMatchObject({ rev: 3, fields: { name: 'C' } });
    });

    it('sinceRev vor der bereinigten Revision: resync_required', async () => {
      await newList();
      await world.db.execute(sql`update families set purged_rev = 10, current_rev = 20`);
      const res = await fam.parent.sync([], { sinceRev: 5 });
      expect(res.status).toBe(200);
      expect(res.json).toMatchObject({ status: 'resync_required', rev: 20, changes: [], hasMore: false });
      // ab 0 oder ab der bereinigten Revision geht es normal weiter
      expect((await fam.parent.sync([], { sinceRev: 0 })).json.status).toBe('ok');
      expect((await fam.parent.sync([], { sinceRev: 10 })).json.status).toBe('ok');
    });

    it('sinceRev aus der Zukunft (Datenbank zurückgespielt): resync_required', async () => {
      await newList();
      const res = await fam.parent.sync([], { sinceRev: 500 });
      expect(res.json.status).toBe('resync_required');
    });

    it('Ops werden auch bei resync_required angewendet', async () => {
      await world.db.execute(sql`update families set purged_rev = 10, current_rev = 20`);
      const op = upsert('list', listId(), { name: 'Neu' });
      const res = await fam.admin.sync([op], { sinceRev: 5 });
      expect(res.json.status).toBe('resync_required');
      expect(res.json.acked).toEqual([op.opId]);
      expect(res.json.rev).toBe(21);
    });

    it('das Gerät merkt sich den Stand (devices.last_rev)', async () => {
      await newList();
      await fam.parent.sync([], { sinceRev: 1 });
      const [d] = await rows(world, sql`select last_rev, last_seen_at from devices where id = ${fam.parent.deviceId}`);
      expect(Number(d?.last_rev)).toBe(1);
      expect(d?.last_seen_at).not.toBeNull();
    });
  });

  describe('Parallelität', () => {
    it('viele gleichzeitige Syncs vergeben lückenlose, eindeutige Revisionen', async () => {
      const lid = await newList();
      const devices = [fam.admin, fam.parent, fam.child];
      const calls = Array.from({ length: 30 }, (_, i) => {
        const d = devices[i % devices.length]!;
        return d.sync([upsert('list_item', randomUUID(), { listId: lid, text: `E${i}` }), upsert('list_item', randomUUID(), { listId: lid, text: `F${i}` })], { sinceRev: 0, limit: 5 });
      });
      const results = await Promise.all(calls);
      for (const r of results) {
        expect(r.status).toBe(200);
        expect(r.json.rejected).toEqual([]);
      }
      const log = await rows(world, sql`select rev from change_log order by rev`);
      expect(log.map((l) => Number(l.rev))).toEqual(Array.from({ length: 61 }, (_, i) => i + 1));
      expect(Number((await rows(world, sql`select current_rev from families`))[0]?.current_rev)).toBe(61);
    });

    it('gleichzeitige gleiche Op (Wiederholung während des ersten Aufrufs): genau einmal angewendet', async () => {
      const op = upsert('list', listId(), { name: 'Einkauf' });
      const results = await Promise.all([fam.admin.sync([op]), fam.admin.sync([op]), fam.admin.sync([op])]);
      for (const r of results) expect(r.json.acked).toEqual([op.opId]);
      expect(await world.count('lists')).toBe(1);
      expect(await world.count('change_log')).toBe(1);
    });

    it('gleichzeitige Änderung desselben Felds von zwei Geräten: genau ein Gewinner, ein Konflikt', async () => {
      const lid = await newList('A');
      await fam.parent.pull();
      const [x, y] = await Promise.all([fam.admin.sync([upsert('list', lid, { name: 'X' }, 1)]), fam.parent.sync([upsert('list', lid, { name: 'Y' }, 1)])]);
      expect(x.json.conflicts.length + y.json.conflicts.length).toBe(1);
      const [row] = await rows(world, sql`select name from lists where id = ${lid}`);
      const winner = x.json.conflicts.length === 0 ? 'X' : 'Y';
      expect(row?.name).toBe(winner);
    });
  });

  describe('Validierung', () => {
    const bad = async (fields: Json, entity = 'list') => {
      const op = upsert(entity, randomUUID(), fields);
      const res = await fam.admin.sync([op]);
      expect(res.status).toBe(200);
      return { op, res };
    };

    it('NUL und einzelne Surrogate im Text: Op abgelehnt (invalid), nichts gespeichert', async () => {
      for (const name of ['a\u0000b', 'a\ud800b', '\udc00']) {
        const { op, res } = await bad({ name });
        expect(res.json.rejected).toEqual([{ opId: op.opId, code: 'invalid' }]);
      }
      expect(await world.count('lists')).toBe(0);
    });

    it('zu lang, leer, falscher Typ, unbekannter Enum-Wert, unbekanntes Feld, Server-Feld: invalid', async () => {
      for (const fields of [{ name: 'x'.repeat(101) }, { name: '   ' }, { name: 5 }, { name: 'A', kind: 'unbekannt' }, { name: 'A', farbe: 'rot' }, { name: 'A', ownerId: randomUUID() }, { name: 'A', createdAt: '2020-01-01T00:00:00Z' }, { kind: 'shopping' }, { name: 'A', __proto__: { a: 1 }, constructor: 1 }]) {
        const { op, res } = await bad(fields);
        expect(res.json.rejected, JSON.stringify(fields)).toEqual([{ opId: op.opId, code: 'invalid' }]);
      }
      const lid = await newList();
      const long = upsert('list_item', randomUUID(), { listId: lid, text: 'x'.repeat(501) });
      expect((await fam.admin.sync([long])).json.rejected[0].code).toBe('invalid');
      const pos = upsert('list_item', randomUUID(), { listId: lid, text: 'x', position: 1e13 });
      expect((await fam.admin.sync([pos])).json.rejected[0].code).toBe('invalid');
      const done = upsert('list_item', randomUUID(), { listId: lid, text: 'x', doneAt: 'gestern' });
      expect((await fam.admin.sync([done])).json.rejected[0].code).toBe('invalid');
    });

    it('unbekannte Entität und Delete mit Feldern', async () => {
      const op = upsert('kalender', randomUUID(), { name: 'x' });
      expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'unknown_entity' }]);
      const del = { ...remove('list', randomUUID()), fields: { name: 'x' } };
      expect((await fam.admin.sync([del])).json.rejected[0].code).toBe('invalid');
    });

    it('listId lässt sich nachträglich nicht ändern; derselbe Wert ist erlaubt', async () => {
      const l1 = await newList('A');
      const l2 = await newList('B');
      const iid = randomUUID();
      await fam.admin.sync([upsert('list_item', iid, { listId: l1, text: 'x' })]);
      const op = upsert('list_item', iid, { listId: l2 }, 3);
      expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'invalid' }]);
      expect((await fam.admin.sync([upsert('list_item', iid, { listId: l1, text: 'y' }, 3)])).json.acked).toHaveLength(1);
    });

    it('Pflichtfelder beim Anlegen', async () => {
      const lid = await newList();
      const op = upsert('list_item', randomUUID(), { listId: lid });
      expect((await fam.admin.sync([op])).json.rejected[0].code).toBe('invalid');
      const op2 = upsert('list_item', randomUUID(), { text: 'x' });
      expect((await fam.admin.sync([op2])).json.rejected[0].code).toBe('invalid');
    });

    it('Umschlag: Pflichtfelder, unbekanntes Feld, zu viele Ops, ungültige opId: 400', async () => {
      const head = { protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [] };
      expect((await fam.admin.raw(head)).status).toBe(200);
      for (const body of [
        { ...head, sinceRev: -1 },
        { ...head, sinceRev: 1.5 },
        { ...head, extra: 1 },
        { ...head, deviceId: 'abc' },
        { ...head, ops: 'nein' },
        { ...head, limit: 501 },
        { ...head, ops: Array.from({ length: 51 }, () => upsert('list', randomUUID(), { name: 'x' })) },
        { ...head, ops: [{ op: 'upsert' }] },
        { ...head, ops: [{ ...upsert('list', randomUUID(), { name: 'x' }), opId: 'keine-uuid' }] },
        { ...head, deviceId: 'a\u0000b' },
      ]) {
        const res = await fam.admin.raw(body);
        expect(res.status, JSON.stringify(body).slice(0, 80)).toBe(400);
        expect(res.json.error).toBe('invalid_request');
      }
      for (const body of [[], null]) expect((await fam.admin.raw(body as never)).status).toBe(400);
    });

    it('genau 50 Ops sind erlaubt, 51 nicht', async () => {
      const batch = (n: number, from: number) => Array.from({ length: n }, (_, i) => upsert('list', randomUUID(), { name: `L${from + i}` }));
      expect((await fam.admin.sync(batch(51, 0))).status).toBe(400);
      for (let i = 0; i < 4; i++) {
        const res = await fam.admin.sync(batch(50, i * 50), { limit: 1 });
        expect(res.status).toBe(200);
        expect(res.json.acked).toHaveLength(50);
      }
      // Obergrenze lebender Listen: 200 sind erreicht, die nächste wird abgelehnt
      const more = upsert('list', randomUUID(), { name: 'zu viel' });
      expect((await fam.admin.sync([more])).json.rejected).toEqual([{ opId: more.opId, code: 'limit_reached' }]);
    });

    it('ein ungültiges Op blockiert die anderen nicht', async () => {
      const good = upsert('list', listId(), { name: 'ok' });
      const badOp = upsert('list', listId(), { name: '' });
      const good2 = upsert('list', listId(), { name: 'ok2' });
      const res = await fam.admin.sync([good, badOp, good2]);
      expect(res.json.acked).toEqual([good.opId, good2.opId]);
      expect(res.json.rejected).toEqual([{ opId: badOp.opId, code: 'invalid' }]);
    });

    it('Protokollversion zu alt: 426 update_required (Mindestversion einstellbar)', async () => {
      const strict = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', MIN_PROTOCOL_VERSION: '2' });
      try {
        const c = strict.client();
        c.cookie = fam.admin.client.cookie;
        c.csrf = fam.admin.client.csrf;
        const body = { protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [] };
        const res = await c.post('/api/v1/sync', body);
        expect(res.status).toBe(426);
        expect(res.json.error).toBe('update_required');
        expect((await c.post('/api/v1/sync', { ...body, protocolVersion: 2 })).status).toBe(200);
        expect((await strict.client().get('/api/v1/version')).json.minProtocolVersion).toBe(2);
      } finally {
        await strict.close();
      }
      expect((await fam.admin.sync([], { protocolVersion: 0 })).status).toBe(400);
    });

    it('Body über 1 MB: 413', async () => {
      const res = await fam.admin.raw({ protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [{ x: 'a'.repeat(1_100_000) }] });
      expect(res.status).toBe(413);
    });

    it('Gerät muss zur Sitzung passen (409 device_mismatch); ohne Anmeldung 401', async () => {
      const res = await fam.admin.raw({ protocolVersion: 1, deviceId: randomUUID(), sinceRev: 0, ops: [] });
      expect(res.status).toBe(409);
      expect(res.json.error).toBe('device_mismatch');
      expect((await world.client().post('/api/v1/sync', { protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [] })).status).toBe(401);
      // das Gerät einer anderen Person geht nicht
      const other = await fam.parent.raw({ protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [] });
      expect(other.status).toBe(409);
    });
  });
});

// (weitere Gruppen: sync-rights.test.ts, sync-ws.test.ts, sync-maintenance.test.ts)
void deviceOf;
void items;
