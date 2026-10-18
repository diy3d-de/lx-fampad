import { afterEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../src/version.js';

let app: FastifyInstance | undefined;

async function start(env: NodeJS.ProcessEnv = {}, pingDb?: () => Promise<void>) {
  app = await buildApp({ config: loadConfig({ NODE_ENV: 'test', LOG_LEVEL: 'silent', ...env }), pingDb });
  return app;
}

afterEach(async () => {
  await app?.close();
  app = undefined;
});

describe('GET /api/v1/health', () => {
  it('meldet ok ohne Datenbank', async () => {
    const res = await (await start()).inject('/api/v1/health');
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: 'ok', db: 'skipped' });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('meldet ok bei erreichbarer Datenbank', async () => {
    const res = await (await start({}, async () => {})).inject('/api/v1/health');
    expect(res.json()).toEqual({ status: 'ok', db: 'ok' });
  });

  it('antwortet 503, wenn die Datenbank nicht erreichbar ist', async () => {
    const res = await (
      await start({}, async () => {
        throw new Error('down');
      })
    ).inject('/api/v1/health');
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: 'error', db: 'down' });
  });
});

describe('GET /api/v1/version', () => {
  it('liefert Server-, Protokoll- und Mindestversion', async () => {
    const res = await (await start({ MIN_APP_VERSION: '0.2.0', WEB_VERSION: 'abc123' })).inject('/api/v1/version');
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      service: 'lx-familie',
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
});

describe('Platzhalter-Schnittstellen', () => {
  it('POST /api/v1/sync ist in Phase 0 nicht implementiert', async () => {
    const res = await (await start()).inject({ method: 'POST', url: '/api/v1/sync', payload: {} });
    expect(res.statusCode).toBe(501);
  });
});

describe('WebSocket /ws', () => {
  it('sendet hello und beantwortet ping', async () => {
    const instance = await start();
    await instance.ready();
    const messages: unknown[] = [];
    const ws = await instance.injectWS(
      '/ws',
      {},
      { onInit: (socket) => socket.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8')))) },
    );
    ws.send(JSON.stringify({ type: 'ping' }));
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(messages[0]).toMatchObject({ type: 'hello', protocolVersion: PROTOCOL_VERSION });
    expect(messages).toContainEqual({ type: 'pong' });
    ws.terminate();
  });
});

describe('loadConfig', () => {
  it('lehnt ungültige Werte ab', () => {
    expect(() => loadConfig({ PORT: 'abc' })).toThrow(/PORT/);
    expect(() => loadConfig({ MIN_APP_VERSION: '1.2' })).toThrow(/MIN_APP_VERSION/);
    expect(() => loadConfig({ PUBLIC_URL: 'kein url' })).toThrow(/PUBLIC_URL/);
  });

  it('hat sichere Standardwerte (nur localhost)', () => {
    const c = loadConfig({});
    expect(c.host).toBe('127.0.0.1');
    expect(c.port).toBe(4400);
  });
});
