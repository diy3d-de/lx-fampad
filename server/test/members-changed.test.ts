// WebSocket-Hinweis "members_changed": nur Hinweis ohne Inhalt, nur an Geräte der eigenen Familie, bei jeder Änderung der Mitglieder.
import { randomBytes } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { loadConfig } from '../src/config.js';
import { createDb } from '../src/db/index.js';
import { Hub } from '../src/ws/hub.js';
import { TEST_KEY } from './helpers.js';
import { addMember, adminPassword, backends, World, type Client, type Harness } from './helpers.js';

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe('Hub.notifyMembersChanged', () => {
  const fake = () => {
    const sent: string[] = [];
    const handlers: Array<() => void> = [];
    const socket = { readyState: 1, OPEN: 1, send: (s: string) => sent.push(s), once: (_e: string, h: () => void) => handlers.push(h) };
    return { socket: socket as never, sent };
  };

  it('erreicht nur die eigene Familie, keine Standort-Verbindungen, nichts außer dem Typ', () => {
    const hub = new Hub();
    const a = fake();
    const b = fake();
    const loc = fake();
    hub.add('f1', a.socket, { userId: 'u1' });
    hub.add('f2', b.socket, { userId: 'u2' });
    hub.add('f1', loc.socket, { userId: 'u3' });
    hub.markLoc(loc.socket);
    hub.notifyMembersChanged('f1');
    expect(a.sent).toEqual(['{"type":"members_changed"}']);
    expect(b.sent).toEqual([]);
    expect(loc.sent).toEqual([]);
  });
});

describe.each(backends)('members_changed bei Änderungen ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db, { WS_AUTH_TIMEOUT_MS: '60000', WS_PING_INTERVAL_MS: '600000' });
    await world.app.listen({ host: '127.0.0.1', port: 0 });
  });
  afterEach(() => {
    for (const s of sockets.splice(0)) s.terminate();
  });

  async function listen(client: Client) {
    const { port } = world.app.server.address() as AddressInfo;
    const types: string[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': `203.0.113.${10 + sockets.length}` } });
    sockets.push(ws);
    ws.on('message', (raw: Buffer) => types.push((JSON.parse(raw.toString('utf8')) as { type: string }).type));
    await new Promise<void>((resolve, reject) => {
      ws.once('open', () => resolve());
      ws.once('error', reject);
    });
    ws.send(JSON.stringify({ type: 'auth', ticket: (await client.post('/api/v1/ws-ticket')).json.ticket }));
    for (let i = 0; i < 200 && !types.includes('ready'); i++) await wait(10);
    expect(types).toContain('ready');
    return { count: () => types.filter((t) => t === 'members_changed').length };
  }

  /** Führt die Aktion aus und erwartet danach genau einen weiteren Hinweis. */
  async function erwarte(l: { count(): number }, aktion: () => Promise<unknown>) {
    const vorher = l.count();
    await aktion();
    for (let i = 0; i < 100 && l.count() === vorher; i++) await wait(10);
    expect(l.count()).toBe(vorher + 1);
  }

  it('Familienrolle, Profil, Bild, Schlüssel, Beitritt, Rolle und Entfernen lösen je einen Hinweis aus', async () => {
    const a = await adminPassword(world);
    const l = await listen(a.client);
    await wait(50);
    expect(l.count()).toBe(0);

    await erwarte(l, () => a.client.put('/api/v1/me/family-role', { familyRole: 'elternteil' }));
    await erwarte(l, () => a.client.patch('/api/v1/me', { displayName: 'Neuer Name' }));
    await erwarte(l, () => a.client.request('PUT', '/api/v1/me/avatar', { body: { preset: 'K13' } }));
    await erwarte(l, () => a.client.request('DELETE', '/api/v1/me/avatar'));
    await erwarte(l, () => a.client.post('/api/v1/me/keys', { publicEncKey: randomBytes(32).toString('base64url'), publicSignKey: randomBytes(32).toString('base64url') }));
    let kind!: Awaited<ReturnType<typeof addMember>>;
    await erwarte(l, async () => {
      kind = await addMember(world, a.client, 'child', 'kind@example.org');
    });
    const id = ((await a.client.get('/api/v1/members')).json.members as Array<{ id: string; email?: string }>).find((m) => m.email === 'kind@example.org')?.id as string;
    await erwarte(l, () => a.client.patch(`/api/v1/members/${id}/role`, { role: 'parent' }));
    await erwarte(l, () => a.client.request('DELETE', `/api/v1/members/${id}`));
    expect(kind.complete?.status).toBe(200);
  });

  it('wirft der Hinweis, scheitert weder die Änderung noch die Registrierung', async () => {
    const a = await adminPassword(world);
    world.app.hub.notifyMembersChanged = () => {
      throw new Error('Hub kaputt');
    };
    expect((await a.client.put('/api/v1/me/family-role', { familyRole: 'elternteil' })).status).toBe(200);
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    expect(kind.complete?.status).toBe(200);
    expect((await kind.client.get('/api/v1/me')).status).toBe(200);
  });

  it('eine fehlgeschlagene Änderung löst keinen Hinweis aus', async () => {
    const a = await adminPassword(world);
    const l = await listen(a.client);
    expect((await a.client.put('/api/v1/me/family-role', { familyRole: 'unsinn' })).status).toBeGreaterThanOrEqual(400);
    await wait(100);
    expect(l.count()).toBe(0);
  });
});

describe('Zeitlimit der Datenbankanweisungen', () => {
  const env = { NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY };
  it('Standard 30 s, per DB_STATEMENT_TIMEOUT_MS einstellbar, im Pool gesetzt (serverseitig und im Client)', async () => {
    expect(loadConfig(env).dbStatementTimeoutMs).toBe(30_000);
    expect(loadConfig({ ...env, DB_STATEMENT_TIMEOUT_MS: '7000' }).dbStatementTimeoutMs).toBe(7000);
    const { pool } = createDb('postgres://u:p@127.0.0.1:1/x', () => {}, 7000);
    expect(pool.options.statement_timeout).toBe(7000);
    expect(pool.options.query_timeout).toBe(12_000);
    await pool.end();
  });
});
