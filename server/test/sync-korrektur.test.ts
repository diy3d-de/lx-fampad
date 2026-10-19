// Korrekturrunde Sync-Kern: mehrseitiger Snapshot (Cursor), Geisterlisten (hidden), erzwungene Neusynchronisierung, Mengenbegrenzung,
// Konfliktwerte in applied_ops, Zeitlimits, WebSocket-Hinweise nur an Rollen mit Sicht.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { runSyncMaintenance } from '../src/sync/maintenance.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, listsOf, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const DAY = 86_400_000;
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const rows = async (world: World, query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];

/** Legt `n` Listen an (in Paketen zu je 50 Ops) und liefert ihre IDs. */
async function makeLists(d: Device, n: number, prefix = 'L'): Promise<string[]> {
  const ids: string[] = [];
  for (let from = 0; from < n; from += 50) {
    const batch = Array.from({ length: Math.min(50, n - from) }, (_, i) => ({ id: randomUUID(), name: `${prefix}${from + i}` }));
    const res = await d.sync(batch.map((b) => upsert('list', b.id, { name: b.name })));
    expect(res.json.acked).toHaveLength(batch.length);
    ids.push(...batch.map((b) => b.id));
  }
  return ids;
}

describe.each(backends)('Korrekturrunde Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
    await world.app.listen({ host: '127.0.0.1', port: 0 });
    fam = await createFamily(world);
  }, 120_000);
  afterAll(async () => {
    for (const s of sockets.splice(0)) s.terminate();
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    for (const d of [fam.admin, fam.parent, fam.child, fam.guest]) {
      d.sinceRev = 0;
      d.snapshotRev = undefined;
    }
  });

    /** Eigene Datenbank und Welt mit engen Grenzen (die gemeinsame Familie bleibt unberührt). */
    async function limited(env: NodeJS.ProcessEnv) {
      const h = await backend.open();
      const w = await World.create(h.db, env);
      return {
        w,
        f: await createFamily(w),
        close: async () => {
          await w.close();
          await h.close();
        },
      };
    }
  describe('Mehrseitiger Snapshot', () => {
    it('läuft bei purged_rev > 0 durch (Folgeseiten sind nie resync_required) und schreibt last_rev nicht fort', async () => {
      const ids = await makeLists(fam.admin, 12);
      await world.db.execute(sql`update families set purged_rev = 5`);
      const first = await fam.parent.sync([], { sinceRev: 0, limit: 5 });
      expect(first.json).toMatchObject({ status: 'ok', hasMore: true, next: 5, snapshotRev: 12 });
      expect(first.json.changes).toHaveLength(5);
      // Folgeseite: sinceRev (5) liegt unter purged_rev nicht, aber auch Cursor 3 unter purged 5 darf nicht scheitern
      const second = await fam.parent.sync([], { sinceRev: 3, limit: 5, snapshotRev: 12 });
      expect(second.json.status).toBe('ok');
      const seen = new Set<string>();
      let page = first;
      let snap: number | undefined;
      for (let i = 0; i < 10; i++) {
        for (const c of page.json.changes) seen.add(c.id);
        if (!page.json.hasMore) break;
        const since = page.json.next as number;
        snap = page.json.snapshotRev;
        page = await fam.parent.sync([], { sinceRev: since, limit: 5, ...(snap !== undefined ? { snapshotRev: snap } : {}) });
        expect(page.json.status).toBe('ok');
      }
      expect([...seen].sort()).toEqual([...ids].sort());
      expect(page.json.rev).toBe(12);
      // Folgeseiten haben last_rev nicht angefasst (nur der Start mit sinceRev 0 hat 0 geschrieben)
      expect(Number((await rows(world, sql`select last_rev from devices where id = ${fam.parent.deviceId}`))[0]?.last_rev)).toBe(0);
    });

    it('Änderungen während des Snapshots: Folgeseiten ohne Tombstones, der Delta-Lauf danach holt den Rest', async () => {
      const ids = await makeLists(fam.admin, 8);
      await world.db.execute(sql`update families set purged_rev = 2`);
      const got: Json[] = [];
      const first = await fam.parent.sync([], { sinceRev: 0, limit: 3, follow: true });
      got.push(...first.json.changes);
      expect(first.json.snapshotRev).toBe(8);
      // inzwischen: eine Liste löschen (schon abgeholt oder nicht), eine neue anlegen, eine umbenennen
      const fresh = randomUUID();
      await fam.admin.sync([remove('list', ids[6] as string, 7), upsert('list', fresh, { name: 'Neu' }), upsert('list', ids[1] as string, { name: 'Umbenannt' }, 2)], { sinceRev: 8 });
      const rest: Json[] = [];
      for (let i = 0; i < 10; i++) {
        const res = await fam.parent.sync([], { limit: 3, follow: true });
        expect(res.json.status).toBe('ok');
        rest.push(...res.json.changes);
        if (!res.json.hasMore) break;
      }
      const all = [...got, ...rest];
      // nie ein Tombstone vor Ende des Snapshots; der Stand am Ende stimmt mit dem Server überein
      const final = new Map<string, Json>();
      for (const c of all) {
        if (c.tombstone) final.delete(c.id);
        else final.set(c.id, c);
      }
      expect(final.has(ids[6] as string)).toBe(false);
      expect(final.get(fresh)?.fields.name).toBe('Neu');
      expect(final.get(ids[1] as string)?.fields.name).toBe('Umbenannt');
      expect(final.size).toBe(8);
      expect(fam.parent.sinceRev).toBe(await currentRev());
    });

    it('Ende des Snapshots: ist die Familie weitergekommen, folgt hasMore mit next = snapshotRev ohne snapshotRev; sonst fertig', async () => {
      await makeLists(fam.admin, 6);
      const first = await fam.parent.sync([], { sinceRev: 0, limit: 4 });
      expect(first.json).toMatchObject({ hasMore: true, next: 4, snapshotRev: 6 });
      await makeLists(fam.admin, 2, 'X'); // Revisionen 7 und 8
      const last = await fam.parent.sync([], { sinceRev: 4, limit: 4, snapshotRev: 6 });
      expect(last.json.status).toBe('ok');
      expect(last.json.changes.map((c: Json) => c.rev)).toEqual([5, 6]);
      expect(last.json).toMatchObject({ hasMore: true, next: 6, rev: 8 });
      expect(last.json.snapshotRev).toBeUndefined();
      const delta = await fam.parent.sync([], { sinceRev: 6, limit: 4 });
      expect(delta.json.changes.map((c: Json) => c.rev)).toEqual([7, 8]);
      expect(delta.json).toMatchObject({ hasMore: false, rev: 8, next: 8 });
    });

    it('snapshotRev aus der Zukunft: resync_required; snapshotRev <= sinceRev wird wie ein normaler Lauf behandelt', async () => {
      await makeLists(fam.admin, 4);
      expect((await fam.parent.sync([], { sinceRev: 2, snapshotRev: 99 })).json.status).toBe('resync_required');
      const plain = await fam.parent.sync([], { sinceRev: 2, snapshotRev: 2 });
      expect(plain.json.status).toBe('ok');
      expect(plain.json.changes.map((c: Json) => c.rev)).toEqual([3, 4]);
    });

    it('Folgeseite filtert nach der Rolle (Gast sieht keine Listen für die Familie)', async () => {
      await makeLists(fam.admin, 6);
      const res = await fam.guest.pull(2);
      expect(res).toEqual([]);
    });
  });

  const currentRev = async () => Number((await rows(world, sql`select current_rev from families`))[0]?.current_rev);

  describe('Geisterlisten', () => {
    it('Freigabe entzogen und danach gelöscht: der Gast bekommt einen hidden-Tombstone (auch wenn er den Zwischenstand nie sah)', async () => {
      const lid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'Oma-Liste', audience: 'all' })]);
      await fam.guest.pull(); // Gast kennt die Liste
      await fam.admin.sync([upsert('list', lid, { audience: 'parents' }, 1)], { sinceRev: 1 });
      await fam.admin.sync([remove('list', lid, 2)], { sinceRev: 2 });
      const changes = await fam.guest.pull();
      expect(changes).toEqual([{ rev: 3, entity: 'list', id: lid, tombstone: true, hidden: true, fields: {} }]);
      expect(JSON.stringify(changes)).not.toContain('Oma-Liste');
    });

    it('ein gelöschter Datensatz, den die Person nie sehen durfte, kommt nur im Delta (nicht im Snapshot) als hidden-Tombstone', async () => {
      const lid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'Nur Eltern', audience: 'parents' })]);
      await fam.admin.sync([remove('list', lid, 1)], { sinceRev: 1 });
      expect(await fam.guest.pull()).toEqual([]); // Snapshot (sinceRev 0): nichts
      const delta = await fam.guest.sync([], { sinceRev: 1 });
      expect(listsOf(delta.json.changes)).toEqual([{ rev: 2, entity: 'list', id: lid, tombstone: true, hidden: true, fields: {} }]);
      // Eltern sehen einen normalen Tombstone
      const parent = await fam.parent.sync([], { sinceRev: 1 });
      expect(parent.json.changes).toEqual([{ rev: 2, entity: 'list', id: lid, tombstone: true, fields: {} }]);
    });

    it('Einträge einer entzogenen und gelöschten Liste: hidden-Tombstones für Liste und Einträge', async () => {
      const lid = randomUUID();
      const iid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'X', audience: 'all' }), upsert('list_item', iid, { listId: lid, text: 'a' })]);
      await fam.guest.pull();
      await fam.admin.sync([upsert('list', lid, { audience: 'parents' }, 1)], { sinceRev: 2 });
      await fam.admin.sync([remove('list', lid, 3)], { sinceRev: 4 });
      const changes = await fam.guest.pull();
      expect(changes.map((c) => `${c.entity}:${c.hidden}`).sort()).toEqual(['list:true', 'list_item:true']);
    });
  });

  describe('Erzwungene Neusynchronisierung (devices.resync_required)', () => {
    it('ein Rollenwechsel setzt das Flag der Geräte der Person', async () => {
      const extra = await extraMember(world, fam.admin, 'child', 'zweites-kind@example.org'); // ein Rollenwechsel beendet die Sitzungen der Person
      const res = await fam.admin.client.patch(`/api/v1/members/${extra.userId}/role`, { role: 'guest' });
      expect(res.status).toBe(200);
      const flags = await rows(world, sql`select user_id, resync_required from devices`);
      expect(flags.filter((f) => f.resync_required).map((f) => f.user_id)).toEqual([extra.userId]);
    });

    it('mit Flag: resync_required (Ops werden trotzdem angewendet), bei sinceRev 0 normal und das Flag ist danach gelöscht', async () => {
      await makeLists(fam.admin, 2);
      await world.db.execute(sql`update devices set resync_required = true where id = ${fam.parent.deviceId}`);
      const op = upsert('list', randomUUID(), { name: 'Neu' });
      const res = await fam.parent.sync([op], { sinceRev: 2 });
      expect(res.json).toMatchObject({ status: 'resync_required', changes: [], hasMore: false });
      expect(res.json.acked).toEqual([op.opId]);
      // Folgeseite eines Snapshots zählt ebenfalls
      expect((await fam.parent.sync([], { sinceRev: 1, snapshotRev: 3 })).json.status).toBe('resync_required');
      expect((await rows(world, sql`select resync_required from devices where id = ${fam.parent.deviceId}`))[0]?.resync_required).toBe(true);
      const fresh = await fam.parent.sync([], { sinceRev: 0 });
      expect(fresh.json.status).toBe('ok');
      expect(fresh.json.changes).toHaveLength(3);
      expect((await rows(world, sql`select resync_required from devices where id = ${fam.parent.deviceId}`))[0]?.resync_required).toBe(false);
      expect((await fam.parent.sync([], { sinceRev: 3 })).json.status).toBe('ok');
    });
  });

  describe('Mengenbegrenzung und applied_ops', () => {
    const junk = (n: number) => Array.from({ length: n }, () => remove('list', randomUUID()));

    it('Token-Bucket je Gerät: Burst, dann 429 mit Retry-After, Auffüllung über die Zeit; nichts wird halb verarbeitet', async () => {
      const { w, f, close } = await limited({ SYNC_OPS_BURST: '50', SYNC_OPS_PER_MINUTE: '60', SYNC_REQ_BURST: '1000' });
      try {
        expect((await f.admin.sync(junk(50))).status).toBe(200);
        const blocked = await f.admin.sync([upsert('list', randomUUID(), { name: 'x' })]);
        expect(blocked.status).toBe(429);
        expect(blocked.json.error).toBe('rate_limited');
        expect(Number(blocked.headers['retry-after'])).toBeGreaterThan(0);
        expect(await rows(w, sql`select 1 from lists`)).toEqual([]);
        w.advance(60_000);
        expect((await f.admin.sync(junk(50))).status).toBe(200);
        // Abholen ohne Ops kostet nur eine Anfrage
        expect((await f.admin.sync([])).status).toBe(200);
      } finally {
        await close();
      }
    });

    it('Token-Bucket je Anfrage: nach dem Burst 429, auch ohne Ops', async () => {
      const { w, f, close } = await limited({ SYNC_REQ_BURST: '3', SYNC_REQ_PER_MINUTE: '60' });
      try {
        const codes: number[] = [];
        for (let i = 0; i < 5; i++) codes.push((await f.admin.sync([])).status);
        expect(codes).toEqual([200, 200, 200, 429, 429]);
        w.advance(2000);
        expect((await f.admin.sync([])).status).toBe(200);
      } finally {
        await close();
      }
    });

    it('Token-Bucket je Person: mehrere Geräte teilen sich das Dreifache', async () => {
      const { f, close } = await limited({ SYNC_OPS_BURST: '50', SYNC_OPS_PER_MINUTE: '60', SYNC_REQ_BURST: '1000' });
      try {
        const devices = [f.admin, await f.secondDevice('admin'), await f.secondDevice('admin'), await f.secondDevice('admin')];
        const codes: number[] = [];
        for (const d of devices) codes.push((await d.sync(junk(50))).status);
        expect(codes).toEqual([200, 200, 200, 429]);
        // eine andere Person ist davon unberührt
        expect((await f.parent.sync(junk(50))).status).toBe(200);
      } finally {
        await close();
      }
    });

    it('Tagesobergrenze je Gerät über applied_ops', async () => {
      const { w, f, close } = await limited({ SYNC_OPS_PER_DAY: '5' });
      try {
        expect((await f.admin.sync(junk(3))).status).toBe(200);
        expect((await f.admin.sync(junk(3))).status).toBe(429);
        expect((await f.admin.sync(junk(2))).status).toBe(200);
        w.advance(DAY + 1000);
        expect((await f.admin.sync(junk(5))).status).toBe(200);
      } finally {
        await close();
      }
    });

    it('abgelehnte Ops werden nach 7 Tagen vergessen, übernommene erst nach 90', async () => {
      await fam.admin.sync([upsert('list', randomUUID(), { name: 'ok' }), upsert('list', randomUUID(), { name: '' })]);
      expect(await world.count('applied_ops')).toBe(2);
      world.advance(8 * DAY);
      expect((await runSyncMaintenance(world.auth.ctx)).opsPurged).toBe(1);
      expect((await rows(world, sql`select status from applied_ops`)).map((r) => r.status)).toEqual(['acked']);
      world.advance(83 * DAY);
      expect((await runSyncMaintenance(world.auth.ctx)).opsPurged).toBe(1);
      world.advance(-91 * DAY);
    });

    describe('Konfliktwerte', () => {
      const setup = async () => {
        const lid = randomUUID();
        // das Kind legt seine Liste an, ein Elternteil benennt sie um (Konfliktquelle)
        await fam.child.sync([upsert('list', lid, { name: 'Original' })]);
        await fam.parent.sync([upsert('list', lid, { name: 'VomElternteil' }, 1)], { sinceRev: 1 });
        const op = upsert('list', lid, { name: 'VomKind' }, 1);
        return { lid, op };
      };

      it('gespeichert werden nur Feldnamen, nie Werte; eine Wiederholung liefert den aktuellen Stand', async () => {
        const { lid, op } = await setup();
        const first = await fam.child.sync([op], { sinceRev: 2 });
        expect(first.json.conflicts).toEqual([{ opId: op.opId, entity: 'list', id: lid, fields: { name: 'VomElternteil' }, serverRev: 2 }]);
        const [stored] = await rows(world, sql`select conflicts, entity, entity_id from applied_ops where op_id = ${op.opId}`);
        expect(stored?.conflicts).toEqual([{ fields: ['name'], serverRev: 2 }]);
        expect(stored?.entity).toBe('list');
        expect(JSON.stringify(await rows(world, sql`select * from applied_ops`))).not.toContain('VomElternteil');
        // der Server-Stand ändert sich: die Wiederholung nennt den neuen Wert
        await fam.parent.sync([upsert('list', lid, { name: 'Neuer Stand' }, 2)], { sinceRev: 2 });
        const again = await fam.child.sync([op], { sinceRev: 2 });
        expect(again.json.acked).toEqual([op.opId]);
        expect(again.json.conflicts).toEqual([{ opId: op.opId, entity: 'list', id: lid, fields: { name: 'Neuer Stand' }, serverRev: 3 }]);
      });

      it('verliert die Person inzwischen die Sicht, liefert die Wiederholung keine Werte', async () => {
        const { lid, op } = await setup();
        await fam.child.sync([op], { sinceRev: 2 });
        await fam.parent.sync([upsert('list', lid, { audience: 'parents' }, 2)], { sinceRev: 2 });
        const again = await fam.child.sync([op], { sinceRev: 2 });
        expect(again.json.acked).toEqual([op.opId]);
        expect(again.json.conflicts).toEqual([]);
        expect(JSON.stringify(again.json)).not.toContain('Neuer');
      });

      it('ist der Datensatz gelöscht, liefert die Wiederholung keine Werte', async () => {
        const { lid, op } = await setup();
        await fam.child.sync([op], { sinceRev: 2 });
        await fam.parent.sync([remove('list', lid, 2)], { sinceRev: 2 });
        const again = await fam.child.sync([op], { sinceRev: 2 });
        expect(again.json.conflicts).toEqual([]);
      });
    });
  });

  describe('Zeitlimits', () => {
    it.skipIf(backend.name === 'PGlite')('hält ein anderer Schreiber die Sperre der Familie, antwortet der Sync mit 503 und Retry-After', async () => {
      const { w, f, close } = await limited({ SYNC_LOCK_TIMEOUT_MS: '300' });
      try {
        let result: Awaited<ReturnType<Device['sync']>> | undefined;
        await w.db.transaction(async (tx) => {
          await tx.execute(sql`select 1 from families where id = ${f.familyId} for update`);
          result = await f.admin.sync([upsert('list', randomUUID(), { name: 'x' })]);
        });
        expect(result?.status).toBe(503);
        expect(result?.json.error).toBe('server_busy');
        expect(Number(result?.headers['retry-after'])).toBeGreaterThan(0);
        // danach geht es wieder, und nichts ist halb geschrieben
        expect((await f.admin.sync([upsert('list', randomUUID(), { name: 'y' })])).json.acked).toHaveLength(1);
        expect(await w.count('lists')).toBe(1);
      } finally {
        await close();
      }
    });
  });

  describe('WebSocket-Hinweise nur an Rollen mit Sicht', () => {
    async function connect(d: Device) {
      const { port } = world.app.server.address() as AddressInfo;
      const messages: Json[] = [];
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.60' } });
      sockets.push(ws);
      ws.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8'))));
      await new Promise<void>((resolve, reject) => {
        ws.once('open', () => resolve());
        ws.once('error', reject);
      });
      const ticket = (await d.client.post('/api/v1/ws-ticket')).json.ticket as string;
      ws.send(JSON.stringify({ type: 'auth', ticket }));
      for (let i = 0; i < 40 && !messages.some((m) => m.type === 'ready'); i++) await wait(50);
      expect(messages.some((m) => m.type === 'ready')).toBe(true);
      return messages;
    }
    const revs = (m: Json[]) => m.filter((x) => x.type === 'rev').map((x) => x.rev);

    it('Liste nur für Eltern: Kind und Gast hören nichts; für die Familie: kein Gast; freigegeben: alle', async () => {
      const parent = await connect(fam.parent);
      const child = await connect(fam.child);
      const guest = await connect(fam.guest);
      const lid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'Eltern', audience: 'parents' })]);
      await wait(150);
      expect([revs(parent), revs(child), revs(guest)]).toEqual([[1], [], []]);
      await fam.admin.sync([upsert('list', lid, { audience: 'family' }, 1)], { sinceRev: 1 });
      await wait(150);
      expect([revs(parent), revs(child), revs(guest)]).toEqual([[1, 2], [2], []]);
      await fam.admin.sync([upsert('list', lid, { audience: 'all' }, 2)], { sinceRev: 2 });
      await wait(150);
      expect([revs(parent), revs(child), revs(guest)]).toEqual([[1, 2, 3], [2, 3], [3]]);
      // Freigabe zurückgenommen: der Gast muss es erfahren (hidden-Tombstone), obwohl er danach nichts mehr sieht
      await fam.admin.sync([upsert('list', lid, { audience: 'parents' }, 3)], { sinceRev: 3 });
      await wait(150);
      expect([revs(parent), revs(child), revs(guest)]).toEqual([[1, 2, 3, 4], [2, 3, 4], [3, 4]]);
    });
  });
});
