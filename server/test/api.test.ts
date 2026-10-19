import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type { AddressInfo } from 'node:net';
import WebSocket, { type ClientOptions } from 'ws';
import { buildApp } from '../src/app.js';
import type { AuthService, Principal } from '../src/auth/types.js';
import { loadConfig } from '../src/config.js';
import { TEST_KEY } from './helpers.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../src/version.js';
import { WS_CLOSE_PING_TIMEOUT, WS_CLOSE_UNAUTHENTICATED } from '../src/ws/route.js';

let app: FastifyInstance | undefined;
const sockets: WebSocket[] = [];
const tmpDirs: string[] = [];

interface StartOptions {
  env?: NodeJS.ProcessEnv;
  pingDb?: () => Promise<void>;
  auth?: AuthService;
  logStream?: Writable;
}

async function start({ env = {}, pingDb, auth, logStream }: StartOptions = {}) {
  app = await buildApp({
    config: loadConfig({ NODE_ENV: 'test', LOG_LEVEL: 'silent', AUTH_SECRET_KEY: TEST_KEY, ...env }),
    pingDb,
    auth,
    logStream,
  });
  await app.ready();
  return app;
}

afterEach(async () => {
  for (const s of sockets.splice(0)) s.terminate();
  await app?.close();
  app = undefined;
  for (const d of tmpDirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

const principal: Principal = { userId: 'u1', familyId: 'f1', role: 'admin', deviceId: null };
const ticketAuth: AuthService = {
  authenticate: async () => null,
  redeemWsTicket: async (ticket) => (ticket === 'good-ticket' ? principal : null),
};

/**
 * Öffnet einen echten WebSocket gegen einen lokal lauschenden Server (injectWS umgeht die Netzwerkschicht,
 * dann gäbe es keine Client-IP). `closed` löst mit dem Schließcode auf; bei abgelehntem Upgrade
 * wirft die Funktion "Unexpected server response: <HTTP-Status>".
 */
async function connect(
  instance: FastifyInstance,
  headers: Record<string, string> = {},
  path = '/ws',
  clientOptions: ClientOptions = {},
) {
  if (!instance.server.listening) await instance.listen({ host: '127.0.0.1', port: 0 });
  const { port } = instance.server.address() as AddressInfo;
  const messages: unknown[] = [];
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`, { headers, ...clientOptions });
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

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe('GET /api/v1/health', () => {
  it('meldet ok ohne Datenbank', async () => {
    const res = await (await start()).inject('/api/v1/health');
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: 'ok', db: 'skipped' });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('meldet ok bei erreichbarer Datenbank', async () => {
    const res = await (await start({ pingDb: async () => {} })).inject('/api/v1/health');
    expect(res.json()).toEqual({ status: 'ok', db: 'ok' });
  });

  it('antwortet 503, wenn die Datenbank nicht erreichbar ist', async () => {
    const res = await (
      await start({
        pingDb: async () => {
          throw new Error('down');
        },
      })
    ).inject('/api/v1/health');
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: 'error', db: 'down' });
  });

  it('antwortet 503 nach dem Zeitlimit, wenn die Datenbank hängt', async () => {
    const t0 = Date.now();
    const res = await (
      await start({ env: { HEALTH_TIMEOUT_MS: '100' }, pingDb: () => new Promise<void>(() => {}) })
    ).inject('/api/v1/health');
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: 'error', db: 'down' });
    expect(Date.now() - t0).toBeLessThan(2000);
  });
});

describe('GET /api/v1/version', () => {
  it('liefert Server-, Protokoll- und Mindestversion', async () => {
    const res = await (await start({ env: { MIN_APP_VERSION: '0.2.0', WEB_VERSION: 'abc123' } })).inject('/api/v1/version');
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      service: 'lx-fampad',
      version: SERVER_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      minAppVersion: '0.2.0',
      webVersion: 'abc123',
    });
  });

  it('webVersion ist null, wenn nicht gesetzt', async () => {
    const res = await (await start()).inject('/api/v1/version');
    expect(res.json().webVersion).toBeNull();
  });

  it('liest webVersion aus der Datei, die deploy-web.sh schreibt', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'lx-version-'));
    tmpDirs.push(dir);
    const file = join(dir, 'version.txt');
    writeFileSync(file, '0.1.0-20261018120000\n');
    const instance = await start({ env: { WEB_VERSION_FILE: file } });
    expect((await instance.inject('/api/v1/version')).json().webVersion).toBe('0.1.0-20261018120000');
    // neuer Build: die Datei wird bei jeder Abfrage frisch gelesen
    writeFileSync(file, '0.1.0-20261019090000\n');
    expect((await instance.inject('/api/v1/version')).json().webVersion).toBe('0.1.0-20261019090000');
  });

  it('ignoriert fehlende oder ungültige Versionsdatei', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'lx-version-'));
    tmpDirs.push(dir);
    const file = join(dir, 'version.txt');
    writeFileSync(file, '<script>alert(1)</script>');
    expect((await (await start({ env: { WEB_VERSION_FILE: file } })).inject('/api/v1/version')).json().webVersion).toBeNull();
    await app?.close();
    const missing = await start({ env: { WEB_VERSION_FILE: join(dir, 'gibt-es-nicht.txt') } });
    expect((await missing.inject('/api/v1/version')).json().webVersion).toBeNull();
  });
});

describe('Platzhalter-Schnittstellen', () => {
  it('POST /api/v1/sync ist in Phase 0 nicht implementiert', async () => {
    const res = await (await start()).inject({ method: 'POST', url: '/api/v1/sync', payload: {} });
    expect(res.statusCode).toBe(501);
  });
});

describe('Rate-Limit', () => {
  it('begrenzt alle Routen je IP', async () => {
    const instance = await start({ env: { RATE_LIMIT_MAX: '3' } });
    const codes: number[] = [];
    for (let i = 0; i < 5; i++) codes.push((await instance.inject('/api/v1/version')).statusCode);
    expect(codes).toEqual([200, 200, 200, 429, 429]);
  });

  it('zählt je Client-IP (X-Forwarded-For von Caddy)', async () => {
    const instance = await start({ env: { RATE_LIMIT_MAX: '1' } });
    const get = (ip: string) => instance.inject({ url: '/api/v1/version', headers: { 'x-forwarded-for': ip } });
    expect((await get('203.0.113.1')).statusCode).toBe(200);
    expect((await get('203.0.113.1')).statusCode).toBe(429);
    expect((await get('203.0.113.2')).statusCode).toBe(200);
  });

  it('begrenzt den Health-Check von außen (Client-IP aus X-Forwarded-For)', async () => {
    const instance = await start({ env: { RATE_LIMIT_MAX: '2' } });
    const get = (ip: string) => instance.inject({ url: '/api/v1/health', headers: { 'x-forwarded-for': ip } });
    expect((await get('203.0.113.1')).statusCode).toBe(200);
    expect((await get('203.0.113.1')).statusCode).toBe(200);
    expect((await get('203.0.113.1')).statusCode).toBe(429);
    expect((await get('203.0.113.2')).statusCode).toBe(200);
  });

  it('nimmt nur 127.0.0.1 vom Limit des Health-Checks aus (deploy.sh)', async () => {
    const instance = await start({ env: { RATE_LIMIT_MAX: '1' } });
    for (let i = 0; i < 5; i++) expect((await instance.inject('/api/v1/health')).statusCode).toBe(200);
    // andere Routen bleiben auch für 127.0.0.1 begrenzt
    expect((await instance.inject('/api/v1/version')).statusCode).toBe(200);
    expect((await instance.inject('/api/v1/version')).statusCode).toBe(429);
  });
});

describe('Protokollierung', () => {
  it('schwärzt Cookie und Authorization und loggt nie die Query', async () => {
    const lines: string[] = [];
    const logStream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(String(chunk));
        cb();
      },
    });
    const instance = await start({ env: { LOG_LEVEL: 'info' }, logStream });
    instance.log.info({ headers: { cookie: 'session=GEHEIM', authorization: 'Bearer GEHEIM' } }, 'Test');
    await instance.inject({
      url: '/api/v1/version?ticket=GEHEIM',
      headers: { cookie: 'session=GEHEIM', authorization: 'Bearer GEHEIM' },
    });
    await wait(50);
    const log = lines.join('');
    expect(log).toContain('[geschwärzt]');
    expect(log).toContain('/api/v1/version');
    expect(log).not.toContain('GEHEIM');
  });
});

describe('WebSocket /ws', () => {
  it('sendet hello und beantwortet ping', async () => {
    const { ws, messages } = await connect(await start());
    ws.send(JSON.stringify({ type: 'ping' }));
    await wait(100);
    expect(messages[0]).toMatchObject({ type: 'hello', protocolVersion: PROTOCOL_VERSION });
    expect(messages).toContainEqual({ type: 'pong' });
  });

  it('schließt unangemeldete Verbindungen nach der Frist', async () => {
    const { closed } = await connect(await start({ env: { WS_AUTH_TIMEOUT_MS: '150' } }));
    expect(await closed).toBe(WS_CLOSE_UNAUTHENTICATED);
  });

  it('meldet per Ticket als erste Nachricht an und schließt dann nicht mehr', async () => {
    const { ws, messages } = await connect(await start({ env: { WS_AUTH_TIMEOUT_MS: '300' }, auth: ticketAuth }));
    ws.send(JSON.stringify({ type: 'auth', ticket: 'good-ticket' }));
    await wait(500);
    expect(messages).toContainEqual({ type: 'ready' });
    expect(ws.readyState).toBe(ws.OPEN);
  });

  it('schließt bei ungültigem Ticket sofort', async () => {
    const { ws, closed } = await connect(await start({ auth: ticketAuth }));
    ws.send(JSON.stringify({ type: 'auth', ticket: 'falsch' }));
    expect(await closed).toBe(WS_CLOSE_UNAUTHENTICATED);
  });

  it('lehnt Daten-Nachrichten vor der Anmeldung ab', async () => {
    const { ws, messages } = await connect(await start({ auth: ticketAuth }));
    ws.send(JSON.stringify({ type: 'subscribe' }));
    await wait(100);
    expect(messages).toContainEqual({ type: 'error', code: 'unauthenticated' });
  });

  it('lehnt ein Ticket in der URL vor dem Upgrade ab', async () => {
    const instance = await start({ auth: ticketAuth });
    await expect(connect(instance, {}, '/ws?ticket=good-ticket')).rejects.toThrow(/400/);
    await expect(connect(instance, {}, '/ws?token=abc')).rejects.toThrow(/400/);
  });

  it('trennt Verbindungen, die nicht auf Server-Pings antworten', async () => {
    const instance = await start({ env: { WS_PING_INTERVAL_MS: '100', WS_AUTH_TIMEOUT_MS: '60000' } });
    // ein toter Peer: antwortet nicht mit Pong
    const { closed } = await connect(instance, {}, '/ws', { autoPong: false });
    expect(await closed).toBe(WS_CLOSE_PING_TIMEOUT);
  });

  it('hält Verbindungen offen, die auf Pings antworten', async () => {
    const instance = await start({ env: { WS_PING_INTERVAL_MS: '100', WS_AUTH_TIMEOUT_MS: '60000' } });
    const { ws } = await connect(instance);
    await wait(450);
    expect(ws.readyState).toBe(ws.OPEN);
  });

  it('begrenzt gleichzeitige Verbindungen je IP schon vor dem Upgrade', async () => {
    const instance = await start({ env: { WS_MAX_PER_IP: '2', WS_AUTH_TIMEOUT_MS: '60000' } });
    await connect(instance);
    const second = await connect(instance);
    await expect(connect(instance)).rejects.toThrow(/429/);
    // andere Client-IP ist nicht betroffen
    await connect(instance, { 'x-forwarded-for': '203.0.113.9' });
    // nach dem Schließen wird der Platz wieder frei
    second.ws.close();
    await second.closed;
    await wait(50);
    await connect(instance);
  });

  describe('Origin-Prüfung vor dem Upgrade (fail-closed)', () => {
    it('lehnt fremde Origins in production ab', async () => {
      const instance = await start({ env: { NODE_ENV: 'production', PUBLIC_URL: 'https://familie.lx-labs.dev' } });
      await expect(connect(instance, { origin: 'https://evil.example' })).rejects.toThrow(/403/);
      // Origin "null" (z. B. sandboxed iframe) ist ebenfalls fremd
      await expect(connect(instance, { origin: 'null' })).rejects.toThrow(/403/);
    });

    it('lässt die eigene Origin und Clients ohne Origin (App) durch', async () => {
      const instance = await start({ env: { NODE_ENV: 'production', PUBLIC_URL: 'https://familie.lx-labs.dev', WS_AUTH_TIMEOUT_MS: '60000' } });
      await connect(instance, { origin: 'https://familie.lx-labs.dev' });
      await connect(instance);
    });

    it('behandelt fehlendes NODE_ENV wie production', async () => {
      const config = loadConfig({ LOG_LEVEL: 'silent', PUBLIC_URL: 'https://familie.lx-labs.dev', AUTH_SECRET_KEY: TEST_KEY });
      expect(config.env).toBe('production');
      app = await buildApp({ config });
      await app.ready();
      await expect(connect(app, { origin: 'https://evil.example' })).rejects.toThrow(/403/);
    });

    it('lockert nur in development und test', async () => {
      for (const NODE_ENV of ['development', 'test']) {
        const instance = await start({ env: { NODE_ENV, WS_AUTH_TIMEOUT_MS: '60000' } });
        await connect(instance, { origin: 'https://evil.example' });
        await app?.close();
      }
    });
  });
});

describe('loadConfig', () => {
  it('lehnt ungültige Werte ab', () => {
    expect(() => loadConfig({ PORT: 'abc' })).toThrow(/PORT/);
    expect(() => loadConfig({ MIN_APP_VERSION: '1.2' })).toThrow(/MIN_APP_VERSION/);
    expect(() => loadConfig({ PUBLIC_URL: 'kein url' })).toThrow(/PUBLIC_URL/);
    expect(() => loadConfig({ AUTH_SECRET_KEY: TEST_KEY, RATE_LIMIT_MAX: '0' })).toThrow(/RATE_LIMIT_MAX/);
    expect(() => loadConfig({ AUTH_SECRET_KEY: TEST_KEY, WS_MAX_PER_IP: 'viele' })).toThrow(/WS_MAX_PER_IP/);
  });

  it('lehnt unbekannte NODE_ENV ab (fail-closed) und nimmt production als Standard', () => {
    expect(() => loadConfig({ NODE_ENV: 'staging' })).toThrow(/NODE_ENV/);
    expect(() => loadConfig({ NODE_ENV: 'prod' })).toThrow(/NODE_ENV/);
    expect(loadConfig({ AUTH_SECRET_KEY: TEST_KEY }).env).toBe('production');
    expect(loadConfig({ NODE_ENV: '', AUTH_SECRET_KEY: TEST_KEY }).env).toBe('production');
    expect(loadConfig({ NODE_ENV: 'development' }).env).toBe('development');
  });

  it('hat sichere Standardwerte (nur localhost)', () => {
    const c = loadConfig({ AUTH_SECRET_KEY: TEST_KEY });
    expect(c.host).toBe('127.0.0.1');
    expect(c.port).toBe(4400);
    expect(c.wsMaxPerIp).toBeGreaterThan(0);
    expect(c.authRateLimitMax).toBeLessThan(c.rateLimitMax);
  });
});

describe('Schlüssel und Datenbank-Rollen (Konfiguration)', () => {
  it('production verlangt AUTH_SECRET_KEY und lehnt Platzhalter, kurze und gleichförmige Schlüssel ab', () => {
    expect(() => loadConfig({ NODE_ENV: 'production' })).toThrow(/AUTH_SECRET_KEY/);
    expect(() => loadConfig({ AUTH_SECRET_KEY: 'CHANGE_ME_CHANGE_ME_CHANGE_ME_CHANGE_ME' })).toThrow(/Platzhalter/);
    expect(() => loadConfig({ AUTH_SECRET_KEY: Buffer.from('zu kurz').toString('base64') })).toThrow(/32 Byte/);
    expect(() => loadConfig({ AUTH_SECRET_KEY: Buffer.alloc(32).toString('base64') })).toThrow(/unzulässig/);
    expect(loadConfig({ AUTH_SECRET_KEY: TEST_KEY }).auth.secretKey.length).toBe(32);
    expect(loadConfig({ AUTH_SECRET_KEY: Buffer.from(TEST_KEY, 'base64').toString('hex') }).auth.secretKey.length).toBe(32);
  });

  it('Entwicklung und Test erzeugen ohne Schlüssel einen flüchtigen', () => {
    const a = loadConfig({ NODE_ENV: 'test' }).auth.secretKey;
    const b = loadConfig({ NODE_ENV: 'test' }).auth.secretKey;
    expect(a.length).toBe(32);
    expect(a.equals(b)).toBe(false);
  });

  it('liest den Schlüssel aus einer Datei außerhalb der Datenbank (AUTH_SECRET_KEY_FILE)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'lx-key-'));
    tmpDirs.push(dir);
    const file = join(dir, 'auth.key');
    writeFileSync(file, `${TEST_KEY}
`);
    expect(loadConfig({ AUTH_SECRET_KEY_FILE: file }).auth.secretKey.toString('base64')).toBe(TEST_KEY);
    expect(() => loadConfig({ AUTH_SECRET_KEY_FILE: join(dir, 'fehlt') })).toThrow(/AUTH_SECRET_KEY_FILE/);
  });

  it('trennt Migrations- und Laufzeit-Datenbank (Rückfall: nur DATABASE_URL)', () => {
    const both = loadConfig({ AUTH_SECRET_KEY: TEST_KEY, DATABASE_URL: 'postgres://app@h/db', MIGRATION_DATABASE_URL: 'postgres://owner@h/db' });
    expect(both.databaseUrl).toBe('postgres://app@h/db');
    expect(both.migrationDatabaseUrl).toBe('postgres://owner@h/db');
    expect(loadConfig({ AUTH_SECRET_KEY: TEST_KEY, DATABASE_URL: 'postgres://app@h/db' }).migrationDatabaseUrl).toBeUndefined();
  });

  it('RP-ID ist konfigurierbar und Standard ist der Hostname von PUBLIC_URL', () => {
    expect(loadConfig({ NODE_ENV: 'test', PUBLIC_URL: 'https://familie.lx-labs.dev' }).auth.rpId).toBe('familie.lx-labs.dev');
    expect(loadConfig({ NODE_ENV: 'test', WEBAUTHN_RP_ID: 'lx-labs.dev' }).auth.rpId).toBe('lx-labs.dev');
    expect(() => loadConfig({ NODE_ENV: 'test', WEBAUTHN_RP_ID: 'https://x' })).toThrow(/WEBAUTHN_RP_ID/);
  });
});

describe('Fehlerhandler', () => {
  it('gibt nie interne Meldungen aus (500) und antwortet auf kaputte Eingaben generisch (400/404)', async () => {
    const lines: string[] = [];
    const logStream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(String(chunk));
        cb();
      },
    });
    const instance = await start({ env: { LOG_LEVEL: 'error' }, logStream });
    const missing = await instance.inject('/api/v1/gibt-es-nicht');
    expect(missing.json()).toEqual({ error: 'not_found', message: 'Nicht gefunden.' });
    const bad = await instance.inject({ method: 'POST', url: '/api/v1/sync', headers: { 'content-type': 'application/json' }, payload: '{kaputt' });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toEqual({ error: 'invalid_request', message: 'Ungültige Eingabe.' });
    expect(bad.payload).not.toMatch(/JSON|token|position/i);
    const wrongType = await instance.inject({ method: 'POST', url: '/api/v1/sync', headers: { 'content-type': 'application/xml' }, payload: '<x/>' });
    expect(wrongType.statusCode).toBe(415);
    expect(wrongType.json().error).toBe('unsupported_media_type');
  });

  it('antwortet auf unerwartete Fehler mit 500 und generischem Text; Details stehen nur im Log', async () => {
    const { default: Fastify } = await import('fastify');
    const { registerErrorHandling } = await import('../src/errors.js');
    const lines: string[] = [];
    const logStream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(String(chunk));
        cb();
      },
    });
    const f = Fastify({ logger: { level: 'error', stream: logStream } });
    registerErrorHandling(f);
    f.get('/boom', async () => {
      throw new Error('GEHEIM: select * from users');
    });
    const res = await f.inject('/boom');
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({ error: 'internal_error', message: 'Interner Fehler.' });
    expect(res.payload).not.toContain('GEHEIM');
    expect(lines.join('')).toContain('GEHEIM');
    await f.close();
  });
});
