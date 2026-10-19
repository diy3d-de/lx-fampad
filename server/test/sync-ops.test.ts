// Betrieb des Sync: WebSocket-Hinweis "rev N", Tombstone-Bereinigung und Löschkonzept, Rate-Limit, Log ohne Inhalte.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { Writable } from 'node:stream';
import type { AddressInfo } from 'node:net';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { runMaintenance } from '../src/auth/maintenance.js';
import { Hub } from '../src/ws/hub.js';
import { runSyncMaintenance } from '../src/sync/maintenance.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const DAY = 86_400_000;
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const rows = async (world: World, query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];

describe('Hub: Revisionshinweis', () => {
  it('geht nur an die Verbindungen der eigenen Familie und enthält keine Inhalte', () => {
    const hub = new Hub();
    const sent: Record<string, string[]> = { a1: [], a2: [], b1: [] };
    const socket = (name: string, state = 1) => ({
      OPEN: 1,
      readyState: state,
      send: (m: string) => sent[name]?.push(m),
      once: () => undefined,
    });
    hub.add('fam-a', socket('a1') as never, { userId: 'u1' });
    hub.add('fam-a', socket('a2', 3) as never, { userId: 'u2' }); // geschlossen
    hub.add('fam-b', socket('b1') as never, { userId: 'u3' });
    hub.notifyRev('fam-a', 42);
    expect(sent).toEqual({ a1: ['{"type":"rev","rev":42}'], a2: [], b1: [] });
  });
});

describe.each(backends)('Sync im Betrieb ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
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
    for (const d of [fam.admin, fam.parent, fam.child, fam.guest]) d.sinceRev = 0;
  });
  afterEach(() => {
    world.advance(0);
  });

  async function connect(d: Device) {
    const { port } = world.app.server.address() as AddressInfo;
    const messages: Json[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.50' } });
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
    return { ws, messages };
  }
  const revs = (messages: Json[]) => messages.filter((m) => m.type === 'rev').map((m) => m.rev);

  describe('WebSocket', () => {
    it('nach dem Commit melden sich alle Sockets der Familie mit "rev N" (ohne Inhalt)', async () => {
      const a = await connect(fam.parent);
      const b = await connect(fam.child);
      const lid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'GEHEIMER-NAME' }), upsert('list_item', randomUUID(), { listId: lid, text: 'Milch' })]);
      await wait(150);
      expect(revs(a.messages)).toEqual([2]);
      expect(revs(b.messages)).toEqual([2]);
      expect(JSON.stringify(a.messages)).not.toContain('GEHEIMER-NAME');
      // ohne Änderung (nur Abholen, abgelehnte Op) gibt es keinen Hinweis
      await fam.admin.sync([], { sinceRev: 0 });
      await fam.admin.sync([upsert('list', randomUUID(), { name: '' })]);
      await wait(100);
      expect(revs(a.messages)).toEqual([2]);
    });

    it('wiederholter Upload löst keinen zweiten Hinweis aus', async () => {
      const a = await connect(fam.parent);
      const op = upsert('list', randomUUID(), { name: 'Einkauf' });
      await fam.admin.sync([op]);
      await fam.admin.sync([op]);
      await wait(150);
      expect(revs(a.messages)).toEqual([1]);
    });

    it('beim Abmelden einer Person schließt der Hub ihre Sockets (4401), die anderen bleiben', async () => {
      const kid = await fam.secondDevice('child');
      const a = await connect(kid);
      const b = await connect(fam.parent);
      const closed = new Promise<number>((resolve) => a.ws.once('close', (code: number) => resolve(code)));
      expect((await kid.client.post('/api/v1/auth/logout')).status).toBe(200);
      expect(await closed).toBe(4401);
      expect(b.ws.readyState).toBe(WebSocket.OPEN);
    });
  });

  describe('Tombstones und Löschkonzept', () => {
    const setLastRev = (rev: number) => world.db.execute(sql`update devices set last_rev = ${rev}`);
    const seed = async () => {
      const lid = randomUUID();
      const iid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'Einkauf' }), upsert('list_item', iid, { listId: lid, text: 'Kaffee' })]);
      await fam.admin.sync([remove('list', lid, 1)], { sinceRev: 2 });
      return { lid, iid };
    };

    it('Tombstones bleiben, solange ein aktives Gerät sie nicht kennt', async () => {
      await seed(); // Revisionen: Liste 1, Eintrag 2, Eintrag-Tombstone 3, Listen-Tombstone 4
      await setLastRev(3);
      const report = await runSyncMaintenance(world.auth.ctx);
      expect(report.tombstonesPurged).toBe(1); // der Eintrag (3) ist bekannt, die Liste (4) nicht
      expect(await world.count('lists')).toBe(1);
      expect(await world.count('list_items')).toBe(0);
      expect(Number((await rows(world, sql`select purged_rev from families`))[0]?.purged_rev)).toBe(3);
    });

    it('sind alle aktiven Geräte auf dem Stand, verschwinden Tombstones samt Protokoll; zurückliegende Geräte müssen neu synchronisieren', async () => {
      const { lid, iid } = await seed();
      await setLastRev(4);
      const report = await runSyncMaintenance(world.auth.ctx);
      expect(report.tombstonesPurged).toBe(2);
      expect(await world.count('lists')).toBe(0);
      expect(await world.count('list_items')).toBe(0);
      expect(await rows(world, sql`select * from change_log where entity_id in (${lid}, ${iid})`)).toEqual([]);
      expect(Number((await rows(world, sql`select purged_rev from families`))[0]?.purged_rev)).toBe(4);
      expect((await fam.parent.sync([], { sinceRev: 2 })).json.status).toBe('resync_required');
      expect((await fam.parent.sync([], { sinceRev: 4 })).json.status).toBe('ok');
      expect((await fam.parent.sync([], { sinceRev: 0 })).json.status).toBe('ok');
    });

    it('nach 90 Tagen werden Tombstones auch dann entfernt, wenn ein Gerät sie nie abgeholt hat', async () => {
      await seed();
      await setLastRev(0);
      expect((await runSyncMaintenance(world.auth.ctx)).tombstonesPurged).toBe(0);
      world.advance(89 * DAY);
      expect((await runSyncMaintenance(world.auth.ctx)).tombstonesPurged).toBe(0);
      world.advance(2 * DAY);
      expect((await runSyncMaintenance(world.auth.ctx)).tombstonesPurged).toBe(2);
      world.advance(-91 * DAY);
      expect((await fam.guest.sync([], { sinceRev: 1 })).json.status).toBe('resync_required');
    });

    it('abgemeldete Geräte halten Tombstones nicht fest; ohne aktive Geräte werden alle entfernt', async () => {
      await seed();
      await setLastRev(0);
      await world.db.execute(sql`update devices set revoked_at = now()`);
      expect((await runSyncMaintenance(world.auth.ctx)).tombstonesPurged).toBe(2);
      await world.db.execute(sql`update devices set revoked_at = null`);
    });

    it('lebende Datensätze und frische Einträge anderer Listen bleiben unberührt', async () => {
      const keep = randomUUID();
      await fam.admin.sync([upsert('list', keep, { name: 'Bleibt' })]);
      await seed();
      await setLastRev(1000);
      await runSyncMaintenance(world.auth.ctx);
      expect((await rows(world, sql`select name from lists`)).map((r) => r.name)).toEqual(['Bleibt']);
      expect((await fam.admin.pull()).map((c) => c.id)).toContain(keep);
    });

    it('Inhalte gelöschter Datensätze im Protokoll werden (als Sicherheitsnetz) geleert', async () => {
      const { iid } = await seed();
      await world.db.execute(sql`update change_log set changes = '{"text":"Kaffee"}'::jsonb where entity_id = ${iid}`);
      const report = await runSyncMaintenance(world.auth.ctx);
      expect(report.contentCleared).toBeGreaterThan(0);
      for (const l of await rows(world, sql`select changes from change_log where entity_id = ${iid}`)) expect(l.changes).toEqual({});
    });

    it('ersetzte Protokolleinträge werden nach 90 Tagen entfernt und zwingen sehr alte Geräte zum Neuabgleich', async () => {
      const lid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'A' })]);
      await fam.admin.sync([upsert('list', lid, { name: 'B' }, 1)], { sinceRev: 1 });
      await fam.admin.sync([upsert('list', lid, { name: 'C' }, 2)], { sinceRev: 2 });
      world.advance(91 * DAY);
      const report = await runSyncMaintenance(world.auth.ctx);
      expect(report.logEntriesPurged).toBe(2);
      expect((await rows(world, sql`select rev from change_log`)).map((r) => Number(r.rev))).toEqual([3]);
      expect(Number((await rows(world, sql`select purged_rev from families`))[0]?.purged_rev)).toBe(2);
      world.advance(-91 * DAY);
      expect((await fam.parent.sync([], { sinceRev: 1 })).json.status).toBe('resync_required');
      const fresh = await fam.parent.sync([], { sinceRev: 0 });
      expect(fresh.json.changes[0].fields.name).toBe('C');
    });

    it('verarbeitete Ops werden nach 90 Tagen vergessen', async () => {
      await fam.admin.sync([upsert('list', randomUUID(), { name: 'A' })]);
      expect(await world.count('applied_ops')).toBe(1);
      world.advance(91 * DAY);
      expect((await runSyncMaintenance(world.auth.ctx)).opsPurged).toBe(1);
      world.advance(-91 * DAY);
    });

    it('der stündliche Wartungsjob räumt den Sync mit auf', async () => {
      await seed();
      await setLastRev(1000);
      const report = await runMaintenance(world.auth.ctx);
      expect(report.sync.tombstonesPurged).toBe(2);
    });
  });

  describe('Begrenzungen', () => {
    it('Anfragelimit für /sync: 429 mit Retry-After, andere Routen bleiben erreichbar', async () => {
      const limited = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '3' });
      try {
        const c = limited.client('203.0.113.99');
        c.cookie = fam.admin.client.cookie;
        c.csrf = fam.admin.client.csrf;
        const body = { protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [] };
        const codes: number[] = [];
        let last: Awaited<ReturnType<typeof c.post>> | undefined;
        for (let i = 0; i < 5; i++) {
          last = await c.post('/api/v1/sync', body);
          codes.push(last.status);
        }
        expect(codes).toEqual([200, 200, 200, 429, 429]);
        expect(last?.json.error).toBe('rate_limited');
        expect(Number(last?.headers['retry-after'])).toBeGreaterThan(0);
        expect((await c.get('/api/v1/me')).status).toBe(200);
      } finally {
        await limited.close();
      }
    });

    it('Inhalte tauchen nie im Log auf (auch nicht bei abgelehnten Ops)', async () => {
      const lines: string[] = [];
      const logStream = new Writable({
        write(chunk: Buffer, _enc, cb) {
          lines.push(chunk.toString('utf8'));
          cb();
        },
      });
      const logged = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', LOG_LEVEL: 'debug' }, { logStream });
      try {
        const c = logged.client();
        c.cookie = fam.admin.client.cookie;
        c.csrf = fam.admin.client.csrf;
        const lid = randomUUID();
        const ops = [
          upsert('list', lid, { name: 'GEHEIMER-LISTENNAME' }),
          upsert('list_item', randomUUID(), { listId: lid, text: 'GEHEIMER-EINTRAG' }),
          upsert('list_item', randomUUID(), { listId: lid, text: 'x'.repeat(600) + 'GEHEIMER-ZU-LANG' }),
        ];
        const res = await c.post('/api/v1/sync', { protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops });
        expect(res.status).toBe(200);
        await c.post('/api/v1/sync', { protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, ops: [{ text: 'GEHEIMER-KAPUTT' }] });
        const log = lines.join('');
        expect(log.length).toBeGreaterThan(0);
        expect(log).not.toContain('GEHEIMER');
      } finally {
        await logged.close();
      }
    });
  });
});
