// WebSocket-Anmeldung mit Einmal-Ticket: Einmaligkeit, Ablauf, Fehlversuche, Nachrichten- und Verbindungslimits.
import { sql } from 'drizzle-orm';
import type { AddressInfo } from 'node:net';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { WS_CLOSE_RATE_LIMIT, WS_CLOSE_UNAUTHENTICATED } from '../src/ws/route.js';
import { adminPassword, backends, Client, World, type Harness } from './helpers.js';

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe.each(backends)('WebSocket-Anmeldung ($name)', (backend) => {
  let harness: Harness;
  let world: World | undefined;
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await harness.reset();
  });
  afterEach(async () => {
    for (const s of sockets.splice(0)) s.terminate();
    await world?.close();
    world = undefined;
  });

  async function start(env: NodeJS.ProcessEnv = {}) {
    world = await World.create(harness.db, { WS_AUTH_TIMEOUT_MS: '60000', WS_PING_INTERVAL_MS: '60000', ...env });
    await world.app.listen({ host: '127.0.0.1', port: 0 });
    return world;
  }

  /** Öffnet einen Socket; löst bei "open" auf, wirft bei abgelehntem Upgrade ("Unexpected server response: <Status>"). */
  async function open(w: World, opts: { ip?: string; cookie?: string } = {}) {
    const { port } = w.app.server.address() as AddressInfo;
    const messages: Array<Record<string, unknown>> = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': opts.ip ?? '203.0.113.10', ...(opts.cookie ? { cookie: opts.cookie } : {}) } });
    sockets.push(ws);
    ws.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8'))));
    const closed = new Promise<number>((resolve) => ws.once('close', (code: number) => resolve(code)));
    await new Promise<void>((resolve, reject) => {
      ws.once('open', () => resolve());
      ws.once('error', reject);
      ws.once('unexpected-response', (_req, res) => {
        res.destroy();
        reject(new Error(`Unexpected server response: ${res.statusCode}`));
      });
    });
    return { ws, messages, closed };
  }

  const ticketFor = async (c: Client) => (await c.post('/api/v1/ws-ticket')).json.ticket as string;
  const isReady = (m: Array<Record<string, unknown>>) => m.some((x) => x.type === 'ready');

  it('Ticket: ≥128 Bit, 30 Sekunden, nur der Hash wird gespeichert, einmal einlösbar', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const res = await a.client.post('/api/v1/ws-ticket');
    expect(res.status).toBe(200);
    expect(res.json.expiresInSec).toBe(30);
    expect(Buffer.from(res.json.ticket, 'base64url').length).toBeGreaterThanOrEqual(16);
    const rows = await harness.db.execute<{ token_hash: string }>(sql`select token_hash from ws_tickets`);
    expect(JSON.stringify(rows.rows)).not.toContain(res.json.ticket);
    const first = await w.auth.redeemWsTicket(res.json.ticket);
    expect(first).toMatchObject({ role: 'admin' });
    expect(await w.auth.redeemWsTicket(res.json.ticket)).toBeNull();
    // ohne Anmeldung gibt es kein Ticket
    expect((await w.client().post('/api/v1/ws-ticket')).status).toBe(401);
  });

  it('Ticket läuft nach 30 Sekunden ab', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const ticket = await ticketFor(a.client);
    w.advance(29_000);
    const t2 = await ticketFor(a.client);
    expect(await w.auth.redeemWsTicket(t2)).not.toBeNull();
    w.advance(2_000);
    expect(await w.auth.redeemWsTicket(ticket)).toBeNull();
  });

  it('Ticket einer abgemeldeten Sitzung ist wertlos', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const ticket = await ticketFor(a.client);
    await a.client.post('/api/v1/auth/logout');
    expect(await w.auth.redeemWsTicket(ticket)).toBeNull();
  });

  it('der Socket meldet sich in der ersten Nachricht per Ticket an; dasselbe Ticket ein zweites Mal wird abgelehnt', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const ticket = await ticketFor(a.client);
    const one = await open(w);
    one.ws.send(JSON.stringify({ type: 'auth', ticket }));
    await wait(300);
    expect(isReady(one.messages)).toBe(true);
    expect(one.ws.readyState).toBe(WebSocket.OPEN);

    const two = await open(w, { ip: '203.0.113.11' });
    two.ws.send(JSON.stringify({ type: 'auth', ticket }));
    expect(await two.closed).toBe(WS_CLOSE_UNAUTHENTICATED);
    expect(isReady(two.messages)).toBe(false);
  });

  it('Browser: das Session-Cookie genügt beim Upgrade (ohne Ticket)', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const s = await open(w, { cookie: a.client.cookie });
    await wait(300);
    expect(isReady(s.messages)).toBe(true);
  });

  it('abgelehnte Tickets zählen gegen die IP: danach wird schon das Upgrade abgewiesen', async () => {
    const w = await start();
    w.config.auth.lockoutIpThreshold = 3;
    for (let i = 0; i < 3; i++) {
      const s = await open(w, { ip: '192.0.2.50' });
      s.ws.send(JSON.stringify({ type: 'auth', ticket: `falsches-ticket-${i}` }));
      expect(await s.closed).toBe(WS_CLOSE_UNAUTHENTICATED);
    }
    await expect(open(w, { ip: '192.0.2.50' })).rejects.toThrow(/429/);
    // andere IPs sind nicht betroffen
    await open(w, { ip: '192.0.2.51' });
    expect(await w.count('audit_log')).toBeGreaterThanOrEqual(3);
  });

  it('Nachrichtenlimit je Socket: zu viele Nachrichten schließen die Verbindung', async () => {
    const w = await start({ WS_MAX_MESSAGES: '5', WS_MESSAGE_WINDOW_MS: '60000' });
    const s = await open(w);
    for (let i = 0; i < 8; i++) s.ws.send(JSON.stringify({ type: 'ping' }));
    expect(await s.closed).toBe(WS_CLOSE_RATE_LIMIT);
    expect(s.messages.filter((m) => m.type === 'pong').length).toBeLessThanOrEqual(5);
  });

  it('Verbindungslimit je IP wird atomar gezählt: parallele Aufbauten überschreiten es nicht', async () => {
    const w = await start({ WS_MAX_PER_IP: '3' });
    const results = await Promise.allSettled(Array.from({ length: 12 }, () => open(w)));
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(3);
    const rejected = results.filter((r) => r.status === 'rejected') as PromiseRejectedResult[];
    expect(rejected).toHaveLength(9);
    for (const r of rejected) expect(String(r.reason)).toMatch(/429/);
  });

  it('Verbindungslimit je Person: die weitere Verbindung wird nach der Anmeldung geschlossen', async () => {
    const w = await start({ WS_MAX_PER_USER: '1' });
    const a = await adminPassword(w);
    const one = await open(w);
    one.ws.send(JSON.stringify({ type: 'auth', ticket: await ticketFor(a.client) }));
    await wait(300);
    expect(isReady(one.messages)).toBe(true);
    const two = await open(w, { ip: '203.0.113.12' });
    two.ws.send(JSON.stringify({ type: 'auth', ticket: await ticketFor(a.client) }));
    expect(await two.closed).toBe(WS_CLOSE_RATE_LIMIT);
    // nach dem Schließen der ersten ist wieder Platz
    one.ws.close();
    await one.closed;
    await wait(100);
    const three = await open(w, { ip: '203.0.113.13' });
    three.ws.send(JSON.stringify({ type: 'auth', ticket: await ticketFor(a.client) }));
    await wait(300);
    expect(isReady(three.messages)).toBe(true);
  });
});
