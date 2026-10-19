// Push (UnifiedPush-Wecker): Endpunkt-Prüfung (SSRF), API (IDOR, Rate-Limit), Aufräumen, Auslöser (Rollen, Absender, aktive WebSocket,
// Entprellung), Fehlerbehandlung. ntfy wird durch einen echten HTTP-Server auf Loopback ersetzt (Fake), der die Aufrufe aufzeichnet.
import { randomBytes, randomUUID } from 'node:crypto';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { sql } from 'drizzle-orm';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { loadConfig } from '../src/config.js';
import { topicFromEndpoint } from '../src/push/endpoint.js';
import { MAX_FAILS, WAKE_BODY } from '../src/push/service.js';
import { familienchatId } from '../src/sync/entities/chat-ids.js';
import { backends, TEST_KEY, World, type Harness } from './helpers.js';
import { createFamily, extraMember, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const HOST = 'ntfy.familie.lx-labs.dev';
const TOKEN = 'tk_testtoken1234567890';
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const randTopic = () => 'up' + randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
const endpointOf = (topic: string, query = '?up=1') => `https://${HOST}/${topic}${query}`;

describe('topicFromEndpoint (SSRF-Prüfung)', () => {
  const ok = 'upAbCdEfGhIjKl';
  it('akzeptiert genau https://<Host>/up<12..64 Zeichen>, mit oder ohne ?up=1', () => {
    expect(topicFromEndpoint(`https://${HOST}/${ok}`, HOST)).toBe(ok);
    expect(topicFromEndpoint(`https://${HOST}/${ok}?up=1`, HOST)).toBe(ok);
    expect(topicFromEndpoint(`https://${HOST}/up${'a'.repeat(64)}`, HOST)).toBe(`up${'a'.repeat(64)}`);
    expect(topicFromEndpoint(`https://${HOST}/up_-AbCdEfGhIj`, HOST)).toBe('up_-AbCdEfGhIj');
  });

  it.each([
    ['falscher Host', `https://evil.example/${ok}`],
    ['Host mit Zusatz davor', `https://x${HOST}/${ok}`],
    ['Host als Unterdomain eines Fremden', `https://${HOST}.evil.example/${ok}`],
    ['Host im Pfad', `https://evil.example/${HOST}/${ok}`],
    ['Userinfo', `https://user:pw@${HOST}/${ok}`],
    ['Userinfo mit Fremdhost (@-Trick)', `https://${HOST}@evil.example/${ok}`],
    ['Userinfo mit Fremdhost (Backslash)', `https://evil.example\\@${HOST}/${ok}`],
    ['http statt https', `http://${HOST}/${ok}`],
    ['Port 443', `https://${HOST}:443/${ok}`],
    ['anderer Port', `https://${HOST}:8443/${ok}`],
    ['Loopback-IP', `https://127.0.0.1/${ok}`],
    ['IPv6', `https://[::1]/${ok}`],
    ['IP des Servers im Host', `https://10.0.0.1/${ok}`],
    ['Topic zu kurz', `https://${HOST}/up12345678901`],
    ['Topic zu lang', `https://${HOST}/up${'a'.repeat(65)}`],
    ['falsches Präfix', `https://${HOST}/xx${'a'.repeat(12)}`],
    ['Großschreibung des Präfixes', `https://${HOST}/UP${'a'.repeat(12)}`],
    ['zusätzlicher Pfad', `https://${HOST}/${ok}/json`],
    ['Pfad davor', `https://${HOST}/x/${ok}`],
    ['Pfad-Trick ..', `https://${HOST}/../${ok}`],
    ['Pfad-Trick Punkt', `https://${HOST}/${ok}/..`],
    ['Prozent-Kodierung', `https://${HOST}/%75pAbCdEfGhIjKl`],
    ['kodierter Slash', `https://${HOST}/up%2FAbCdEfGhIjKl`],
    ['Semikolon', `https://${HOST}/${ok};x`],
    ['andere Query', `https://${HOST}/${ok}?x=1`],
    ['Query mit Anhang', `https://${HOST}/${ok}?up=1&x=1`],
    ['Fragment', `https://${HOST}/${ok}#frag`],
    ['Zeilenumbruch', `https://${HOST}/${ok}\n`],
    ['Leerzeichen am Ende', `https://${HOST}/${ok} `],
    ['Leerzeichen am Anfang', ` https://${HOST}/${ok}`],
    ['Großschreibung des Hosts', `https://${HOST.toUpperCase()}/${ok}`],
    ['Punkt am Hostende', `https://${HOST}./${ok}`],
    ['ohne Topic', `https://${HOST}/`],
    ['nur Host', `https://${HOST}`],
    ['sehr lang', `https://${HOST}/${ok}?up=1${'a'.repeat(300)}`],
  ])('lehnt ab: %s', (_name, raw) => {
    expect(topicFromEndpoint(raw, HOST)).toBeNull();
  });

  it('lehnt Nicht-Texte ab', () => {
    for (const v of [undefined, null, 5, {}, [], ['https://' + HOST + '/' + ok]]) expect(topicFromEndpoint(v, HOST)).toBeNull();
  });

  it('der Host stammt aus der Konfiguration (anderer Host gilt nur, wenn so konfiguriert)', () => {
    expect(topicFromEndpoint('https://push.example.org/upAbCdEfGhIjKl', 'push.example.org')).toBe('upAbCdEfGhIjKl');
    expect(topicFromEndpoint(`https://${HOST}/upAbCdEfGhIjKl`, 'push.example.org')).toBeNull();
  });
});

describe('Konfiguration Push', () => {
  const basis = { NODE_ENV: 'production', AUTH_SECRET_KEY: TEST_KEY, PUBLIC_URL: 'https://familie.lx-labs.dev' };
  it('NTFY_URL: in Produktion nur Loopback, sonst Startabbruch; in Entwicklung/Test frei', () => {
    for (const ok of ['http://127.0.0.1:2586', 'http://localhost:2586', 'http://[::1]:2586']) expect(loadConfig({ ...basis, NTFY_URL: ok }).ntfyUrl).toBeDefined();
    for (const bad of ['http://10.0.0.5:2586', 'https://ntfy.familie.lx-labs.dev', 'http://127.0.0.1.evil.example:2586', 'http://169.254.169.254']) {
      expect(() => loadConfig({ ...basis, NTFY_URL: bad })).toThrow(/Loopback/);
    }
    expect(loadConfig({ ...basis, NODE_ENV: 'test', NTFY_URL: 'http://10.0.0.5:2586' }).ntfyUrl).toBe('http://10.0.0.5:2586');
    expect(() => loadConfig({ ...basis, NTFY_URL: 'http://user:pw@127.0.0.1:2586' })).toThrow();
  });
  it('NTFY_PUBLIC_HOST: Punkte müssen echte Punkte sein', () => {
    expect(loadConfig({ ...basis, NODE_ENV: 'test' }).ntfyPublicHost).toBe('ntfy.familie.lx-labs.dev');
    for (const bad of ['ntfyxfamilie', 'ntfy_familie.example', 'a b.example', '.example.org', 'example..org']) {
      expect(() => loadConfig({ ...basis, NODE_ENV: 'test', NTFY_PUBLIC_HOST: bad })).toThrow(/NTFY_PUBLIC_HOST/);
    }
  });
});

interface Call {
  url: string;
  method: string;
  headers: http.IncomingHttpHeaders;
  body: string;
}

describe.each(backends)('Push ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  let ntfy: http.Server;
  let calls: Call[] = [];
  let reply: { status: number; headers?: Record<string, string> } = { status: 200 };
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
    ntfy = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        calls.push({ url: req.url ?? '', method: req.method ?? '', headers: req.headers, body: Buffer.concat(chunks).toString('utf8') });
        res.writeHead(reply.status, reply.headers);
        res.end('{}');
      });
    });
    await new Promise<void>((resolve) => ntfy.listen(0, '127.0.0.1', resolve));
    const port = (ntfy.address() as AddressInfo).port;
    world = await World.create(harness.db, { NTFY_URL: `http://127.0.0.1:${port}`, NTFY_TOKEN: TOKEN, AUTH_RATE_LIMIT_MAX: '100000', WS_PING_INTERVAL_MS: '300', WS_AUTH_TIMEOUT_MS: '60000' }, { pushMinIntervalMs: 0 });
    await world.app.listen({ host: '127.0.0.1', port: 0 });
    fam = await createFamily(world);
  }, 120_000);
  afterAll(async () => {
    for (const s of sockets.splice(0)) s.terminate();
    await world.close();
    await new Promise<void>((resolve) => ntfy.close(() => resolve()));
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    await world.db.execute(sql`truncate table push_endpoints`);
    world.app.push?.reset();
    if (world.app.push) {
      world.app.push.minIntervalMs = 0;
      world.app.push.fehlerPauseMs = 300;
      world.app.push.authPauseMs = 300;
    }
    calls = [];
    reply = { status: 200 };
  });
  afterEach(() => {
    for (const s of sockets.splice(0)) s.terminate();
  });

  const put = (d: Device, endpoint: unknown) => d.client.request('PUT', '/api/v1/me/push', { body: { endpoint } });
  const register = async (d: Device, topic = randTopic()) => {
    const r = await put(d, endpointOf(topic));
    expect(r.status).toBe(200);
    return topic;
  };
  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const until = async (cond: () => boolean, ms = 3000) => {
    const end = Date.now() + ms;
    while (!cond() && Date.now() < end) await wait(10);
    return cond();
  };
  const change = (by: Device, audience: 'parents' | 'family' | 'all' = 'family') => by.sync([upsert('list', randomUUID(), { name: 'Einkauf', audience })]);
  /** Wartet kurz und liefert die Themen, an die gepostet wurde. */
  const topicsPosted = async (settle = 250) => {
    await wait(settle);
    return calls.map((c) => c.url.replace(/^\//, ''));
  };

  describe('API', () => {
    it('Endpunkt anmelden, Status lesen, ersetzen (Topic-Rotation), löschen', async () => {
      const before = await fam.child.client.get('/api/v1/me/push');
      expect(before.json).toMatchObject({ available: true, registered: false, active: false, server: `https://${HOST}` });
      const t1 = await register(fam.child);
      expect((await fam.child.client.get('/api/v1/me/push')).json).toMatchObject({ registered: true, active: true });
      const t2 = await register(fam.child);
      const stored = await rows(sql`select topic, device_id from push_endpoints`);
      expect(stored).toHaveLength(1);
      expect(stored[0]?.topic).toBe(t2);
      expect(stored[0]?.topic).not.toBe(t1);
      expect((await fam.child.client.del('/api/v1/me/push')).status).toBe(200);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);
      expect((await fam.child.client.del('/api/v1/me/push')).status).toBe(200); // idempotent
    });

    it('ungültige Endpunkte: 400, nichts gespeichert; unbekannte Felder und fehlender Endpunkt ebenso', async () => {
      for (const bad of [`https://evil.example/${randTopic()}`, `http://${HOST}/${randTopic()}`, `https://${HOST}@evil.example/${randTopic()}`, 5, null, '']) {
        expect((await put(fam.child, bad)).status).toBe(400);
      }
      expect((await fam.child.client.request('PUT', '/api/v1/me/push', { body: { endpoint: endpointOf(randTopic()), extra: 1 } })).status).toBe(400);
      expect((await fam.child.client.request('PUT', '/api/v1/me/push', { body: {} })).status).toBe(400);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);
    });

    it('ohne Anmeldung 401', async () => {
      const anon = world.client();
      expect((await anon.request('PUT', '/api/v1/me/push', { body: { endpoint: endpointOf(randTopic()) } })).status).toBe(401);
      expect((await anon.get('/api/v1/me/push')).status).toBe(401);
      expect((await anon.del('/api/v1/me/push')).status).toBe(401);
      expect((await anon.post('/api/v1/me/push/test')).status).toBe(401);
    });

    it('IDOR: ein Topic gehört einem Gerät; fremde Geräte lassen sich weder überschreiben noch löschen', async () => {
      const t = await register(fam.child);
      const steal = await put(fam.parent, endpointOf(t));
      // wie ein ungültiger Endpunkt (verrät nicht, dass das Topic vergeben ist)
      const ungueltig = await put(fam.parent, `https://evil.example/${t}`);
      expect(steal.status).toBe(400);
      expect(steal.json).toEqual(ungueltig.json);
      // Löschen trifft nur das eigene Gerät: das Gerät des Elternteils hat keinen Endpunkt, der des Kindes bleibt
      await fam.parent.client.del('/api/v1/me/push');
      expect((await rows(sql`select topic from push_endpoints`)).map((r) => r.topic)).toEqual([t]);
      // Einen Endpunkt mit fremder Geräte-ID kann man nicht angeben (Body ist strikt, Gerät kommt aus der Sitzung)
      const r = await fam.parent.client.request('PUT', '/api/v1/me/push', { body: { endpoint: endpointOf(randTopic()), deviceId: fam.child.deviceId } });
      expect(r.status).toBe(400);
      expect((await rows(sql`select device_id from push_endpoints`)).map((x) => x.device_id)).toEqual([fam.child.deviceId]);
      // Status und Test betreffen nur das eigene Gerät
      expect((await fam.parent.client.get('/api/v1/me/push')).json.registered).toBe(false);
      expect((await fam.parent.client.post('/api/v1/me/push/test')).status).toBe(409);
      expect(calls).toHaveLength(0);
    });

    it('Rate-Limit (strikt je IP)', async () => {
      const w = await World.create(harness.db, { NTFY_URL: 'http://127.0.0.1:9', NTFY_TOKEN: TOKEN, AUTH_RATE_LIMIT_MAX: '3' });
      try {
        const res = [];
        for (let i = 0; i < 5; i++) res.push((await w.client().request('DELETE', '/api/v1/me/push')).status);
        expect(res.slice(0, 3)).toEqual([401, 401, 401]);
        expect(res.slice(3)).toEqual([429, 429]);
      } finally {
        await w.close();
      }
    });

    it('Push aus (NTFY_* fehlt): Status available=false, Anmelden 503, kein Fehler beim Start', async () => {
      const w = await World.create(harness.db, {});
      try {
        const c = w.client();
        const r = await c.get('/api/v1/me/push');
        expect(r.status).toBe(401); // Routen gibt es, nur ohne Sitzung nicht nutzbar
        expect(w.app.push?.enabled).toBe(false);
        await w.app.push?.weckeGeraete({ familyId: randomUUID(), rev: 1 }); // still, kein Fehler
      } finally {
        await w.close();
      }
    });

    it('Push aus bei laufender Familie: Anmelden 503, Status available=false, Test 503', async () => {
      const old = world.config.ntfyToken;
      world.config.ntfyToken = undefined;
      try {
        expect((await put(fam.child, endpointOf(randTopic()))).status).toBe(503);
        expect((await fam.child.client.get('/api/v1/me/push')).json.available).toBe(false);
        expect((await fam.child.client.post('/api/v1/me/push/test')).status).toBe(503);
        expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);
      } finally {
        world.config.ntfyToken = old;
      }
    });

    it('Test-Wecker: sendet an das eigene Gerät, zweiter sofort danach 429', async () => {
      const t = await register(fam.child);
      world.app.push!.minIntervalMs = 2000;
      const r = await fam.child.client.post('/api/v1/me/push/test');
      expect(r.status).toBe(200);
      expect(r.json.result).toBe('sent');
      expect(calls).toHaveLength(1);
      expect(calls[0]?.url).toBe(`/${t}`);
      expect((await fam.child.client.post('/api/v1/me/push/test')).status).toBe(429);
      expect(calls).toHaveLength(1);
    });

    it('Test-Wecker ohne Endpunkt: 409; bei ntfy-Fehler result=failed', async () => {
      expect((await fam.child.client.post('/api/v1/me/push/test')).status).toBe(409);
      await register(fam.child);
      reply = { status: 500 };
      const r = await fam.child.client.post('/api/v1/me/push/test');
      expect(r.json.result).toBe('failed');
    });
  });

  describe('Aufräumen', () => {
    it('Gerät entfernen, Abmelden und "überall abmelden" löschen den Endpunkt', async () => {
      const second = await fam.secondDevice('child');
      await register(second);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(1);
      const del = await fam.child.client.del(`/api/v1/devices/${second.deviceId}`);
      expect(del.status).toBe(200);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);

      const third = await fam.secondDevice('child');
      await register(third);
      expect((await third.client.post('/api/v1/auth/logout')).status).toBe(200);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);

      // "überall abmelden" an einer eigens angelegten Person (die Familien-Testgeräte bleiben angemeldet)
      const m = await extraMember(world, fam.admin, 'parent', 'alle@example.org');
      await register(m);
      await register(fam.child);
      expect((await m.client.post('/api/v1/auth/logout-all')).status).toBe(200);
      expect((await rows(sql`select device_id from push_endpoints`)).map((r) => r.device_id)).toEqual([fam.child.deviceId]);
    });

    it('wird das Gerät gelöscht, verschwindet die Zeile per Fremdschlüssel (ON DELETE CASCADE)', async () => {
      const second = await fam.secondDevice('child');
      await register(second);
      await world.db.execute(sql`delete from devices where id = ${second.deviceId}`);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);
    });

    it('Mitglied entfernen: Endpunkte seiner Geräte verschwinden', async () => {
      const m = await extraMember(world, fam.admin, 'child', 'weg@example.org');
      await register(m);
      // Entfernen verlangt eine frische Bestätigung (Step-up)
      await world.db.execute(sql`update sessions set step_up_at = ${new Date(world.clock).toISOString()} where user_id = ${fam.admin.userId}`);
      const res = await fam.admin.client.del(`/api/v1/members/${m.userId}`);
      expect(res.status).toBe(200);
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);
    });
  });

  describe('Auslöser', () => {
    it('weckt die berechtigten Geräte der anderen, nicht den Absender; Inhalt leer; nur an die Loopback-URL mit Token', async () => {
      const tParent = await register(fam.parent);
      const tChild = await register(fam.child);
      const tAdmin = await register(fam.admin);
      const res = await change(fam.admin, 'family');
      expect(res.status).toBe(200);
      expect(await until(() => calls.length >= 2)).toBe(true);
      const posted = await topicsPosted();
      expect(posted.sort()).toEqual([tChild, tParent].sort()); // nicht der Absender
      expect(posted).not.toContain(tAdmin);
      for (const c of calls) {
        expect(c.method).toBe('POST');
        expect(c.body).toBe(WAKE_BODY);
        expect(c.headers.authorization).toBe(`Bearer ${TOKEN}`);
        expect(c.headers['x-unifiedpush']).toBe('1');
        expect(c.headers.firebase).toBe('no');
        for (const h of ['title', 'tags', 'x-title', 'x-tags', 'priority', 'click', 'attach', 'actions']) expect(c.headers[h]).toBeUndefined();
        expect(c.headers.host).toMatch(/^127\.0\.0\.1:\d+$/);
        expect(c.url).toMatch(/^\/up[A-Za-z0-9]{12}$/);
      }
    });

    it('die gemeldete URL wird nie angesprochen: der Wecker geht nur an die Loopback-URL', async () => {
      // der Endpunkt nennt den öffentlichen Host; der Fake-Server hört nur auf Loopback und sieht Pfad = Topic ohne Query
      const t = randTopic();
      expect((await put(fam.child, endpointOf(t, '?up=1'))).status).toBe(200);
      await change(fam.admin);
      expect(await until(() => calls.length === 1)).toBe(true);
      expect(calls[0]?.url).toBe(`/${t}`);
    });

    it('Freigabe-Stufe: "nur Eltern" weckt kein Kind; "alle" (alte Apps, gespeichert als family) weckt auch das Kind', async () => {
      await register(fam.parent);
      const tChild = await register(fam.child);
      await change(fam.admin, 'parents');
      expect(await topicsPosted()).toHaveLength(1); // nur der Elternteil
      calls = [];
      world.app.push!.reset();
      await change(fam.admin, 'all');
      expect(await until(() => calls.length >= 2)).toBe(true);
      expect((await topicsPosted()).sort()).toContain(tChild);
    });

    it('Privatchat: nur Teilnehmer werden geweckt (nie Admin oder Eltern ohne Teilnehmerschaft), der Familienchat weckt alle Rollen; Wecker ohne Inhalt', async () => {
      const tAdmin = await register(fam.admin);
      const tParent = await register(fam.parent);
      const tChild = await register(fam.child);
      const konv = randomUUID();
      // Direktchat Elternteil und Kind: Absender ist das Elternteil, geweckt wird nur das Kind (nicht der Admin)
      expect((await fam.parent.sync([upsert('konversation', konv, { art: 'group', teilnehmer: [fam.parent.userId, fam.child.userId] })])).json.rejected).toEqual([]);
      expect(await until(() => calls.length >= 1)).toBe(true);
      expect(await topicsPosted()).toEqual([tChild]);
      calls = [];
      world.app.push!.reset();
      const e1 = `e1:${"A".repeat(200)}`;
      expect((await fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: konv, text: e1 })])).json.rejected).toEqual([]);
      expect(await until(() => calls.length >= 1)).toBe(true);
      const posted = await topicsPosted();
      expect(posted).toEqual([tChild]);
      expect(posted).not.toContain(tAdmin);
      for (const c of calls) {
        expect(c.body).toBe(WAKE_BODY);
        expect(c.body).not.toContain("AAAA");
      }
      // eine Gruppe mit Kind und Admin: das Elternteil schreibt, geweckt werden beide Teilnehmer, aber keine Unbeteiligten
      calls = [];
      world.app.push!.reset();
      const gruppe = randomUUID();
      expect((await fam.child.sync([upsert('konversation', gruppe, { art: 'group', teilnehmer: [fam.child.userId, fam.admin.userId] })])).json.rejected).toEqual([]);
      expect(await until(() => calls.length >= 1)).toBe(true);
      expect(await topicsPosted()).toEqual([tAdmin]);
      expect(await topicsPosted(0)).not.toContain(tParent);
      // Familienchat: alle Rollen mit Sicht (außer dem Absender)
      calls = [];
      world.app.push!.reset();
      expect((await fam.child.sync([upsert('konversation', familienchatId(fam.familyId), { art: 'family' })])).json.rejected).toEqual([]);
      expect(await until(() => calls.length >= 2)).toBe(true);
      expect((await topicsPosted()).sort()).toEqual([tAdmin, tParent].sort());
    });

    it('Absender: nur das auslösende Gerät wird ausgenommen, das zweite Gerät derselben Person wird geweckt', async () => {
      const second = await fam.secondDevice('admin');
      const tSecond = await register(second);
      const tAdmin = await register(fam.admin);
      await change(fam.admin);
      expect(await until(() => calls.length >= 1)).toBe(true);
      expect(await topicsPosted()).toEqual([tSecond]);
      expect(calls.map((c) => c.url)).not.toContain(`/${tAdmin}`);
    });

    it('kein Push an ein Gerät mit aktiver WebSocket-Verbindung, danach schon', async () => {
      await register(fam.parent);
      const tChild = await register(fam.child);
      const { port } = world.app.server.address() as AddressInfo;
      const ticket = (await fam.parent.client.post('/api/v1/ws-ticket')).json.ticket as string;
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.10' } });
      sockets.push(ws);
      const ready = new Promise<void>((resolve) => ws.on('message', (raw: Buffer) => JSON.parse(raw.toString('utf8')).type === 'ready' && resolve()));
      await new Promise<void>((resolve, reject) => {
        ws.once('open', () => resolve());
        ws.once('error', reject);
      });
      ws.send(JSON.stringify({ type: 'auth', ticket }));
      await ready;
      expect(world.app.hub.hasDevice(fam.parent.deviceId, 450)).toBe(true);
      await change(fam.admin);
      expect(await until(() => calls.length >= 1)).toBe(true);
      expect(await topicsPosted()).toEqual([tChild]);
      // Verbindung weg: wieder Push
      calls = [];
      ws.close();
      expect(await until(() => !world.app.hub.hasDevice(fam.parent.deviceId))).toBe(true);
      await change(fam.admin);
      expect(await until(() => calls.length >= 2)).toBe(true);
    });

    it('halbtoter Socket (kein Pong mehr) verschluckt den Wecker nicht: er kommt nach der Ping-Frist', async () => {
      const t = await register(fam.parent);
      const { port } = world.app.server.address() as AddressInfo;
      const ticket = (await fam.parent.client.post('/api/v1/ws-ticket')).json.ticket as string;
      // autoPong aus: der Client antwortet nicht mehr auf Pings (Funkloch, Standby)
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.10' }, autoPong: false });
      sockets.push(ws);
      const ready = new Promise<void>((resolve) => ws.on('message', (raw: Buffer) => JSON.parse(raw.toString('utf8')).type === 'ready' && resolve()));
      await new Promise<void>((resolve, reject) => {
        ws.once('open', () => resolve());
        ws.once('error', reject);
      });
      ws.send(JSON.stringify({ type: 'auth', ticket }));
      await ready;
      await change(fam.admin); // Verbindung gilt noch als lebendig: kein sofortiger Wecker
      expect(calls).toHaveLength(0);
      expect(await until(() => calls.length >= 1, 4000)).toBe(true); // Nachprüfung nach Ablauf der Ping-Frist
      expect(calls[0]?.url).toBe(`/${t}`);
    });

    it('Entprellung: erster Wecker sofort, Änderungen dazwischen werden zu genau einem weiteren zusammengefasst', async () => {
      const t = await register(fam.child);
      world.app.push!.minIntervalMs = 1000;
      for (let i = 0; i < 5; i++) await change(fam.admin);
      expect(await until(() => calls.length >= 1)).toBe(true);
      expect(calls).toHaveLength(1);
      expect(await until(() => calls.length >= 2, 3000)).toBe(true);
      await wait(1200);
      expect(calls).toHaveLength(2);
      expect(calls.every((c) => c.url === `/${t}`)).toBe(true);
    });

    it('Empfängerfilter (Erweiterungsstelle, z. B. Chat-Teilnehmer): schneidet die Empfänger ein', async () => {
      await register(fam.parent);
      await register(fam.child);
      world.app.push!.addRecipientFilter((ev) => {
        expect(ev.familyId).toBe(fam.familyId);
        return new Set([fam.child.userId]);
      });
      try {
        await change(fam.admin);
        expect(await until(() => calls.length >= 1)).toBe(true);
        expect(await topicsPosted()).toHaveLength(1);
        expect(calls[0]?.url).toBeDefined();
      } finally {
        (world.app.push as unknown as { filters: unknown[] }).filters.length = 0;
      }
    });

    it('abgemeldete, entfernte und nicht freigegebene (pending) Mitglieder bekommen nichts', async () => {
      await register(fam.child);
      await world.db.execute(sql`update memberships set status = 'pending' where user_id = ${fam.child.userId}`);
      try {
        await change(fam.admin);
        expect(await topicsPosted()).toHaveLength(0);
      } finally {
        await world.db.execute(sql`update memberships set status = 'active' where user_id = ${fam.child.userId}`);
      }
    });
  });

  describe('Fehler von ntfy', () => {
    it('404/410: Endpunkt wird deaktiviert, danach kein Versand; neue Anmeldung aktiviert wieder', async () => {
      await register(fam.child);
      reply = { status: 410 };
      await change(fam.admin);
      expect(await until(() => calls.length === 1)).toBe(true);
      await wait(100);
      const [row] = await rows(sql`select disabled_at, fail_count from push_endpoints`);
      expect(row?.disabled_at).not.toBeNull();
      expect((await fam.child.client.get('/api/v1/me/push')).json).toMatchObject({ registered: true, active: false });
      await change(fam.admin);
      expect(await topicsPosted()).toHaveLength(1); // kein zweiter Versuch
      expect((await fam.child.client.post('/api/v1/me/push/test')).json.result).toBe('disabled');
      reply = { status: 200 };
      await register(fam.child);
      expect((await fam.child.client.get('/api/v1/me/push')).json.active).toBe(true);
      calls = [];
      await change(fam.admin);
      expect(await until(() => calls.length === 1)).toBe(true);
    });

    it('5xx von ntfy (z. B. Neustart): kein Zählen je Endpunkt, globale Pause, nichts wird deaktiviert; danach geht es weiter', async () => {
      await register(fam.parent);
      await register(fam.child);
      await register(await fam.secondDevice('parent'));
      world.app.push!.fehlerPauseMs = 1500;
      reply = { status: 503 };
      await change(fam.admin, 'all');
      expect(await until(() => calls.length >= 3)).toBe(true);
      await wait(60);
      const vorher = calls.length;
      for (let i = 0; i < MAX_FAILS + 2; i++) await change(fam.admin, 'all');
      await wait(60);
      expect(calls.length).toBe(vorher); // Pause: keine weiteren Versuche
      const alle = await rows(sql`select disabled_at, fail_count from push_endpoints`);
      expect(alle).toHaveLength(3);
      for (const r of alle) {
        expect(r.disabled_at).toBeNull();
        expect(r.fail_count).toBe(0);
      }
      reply = { status: 200 };
      await wait(1600); // Pause (1,5 s) vorbei
      await change(fam.admin, 'all');
      expect(await until(() => calls.length >= vorher + 3)).toBe(true);
      await wait(100);
    });

    it('gezielte 4xx (z. B. 400) zählen je Endpunkt: nach MAX_FAILS in Folge deaktiviert', async () => {
      await register(fam.child);
      reply = { status: 400 };
      for (let i = 0; i < MAX_FAILS; i++) {
        await change(fam.admin);
        expect(await until(() => calls.length === i + 1)).toBe(true);
        await wait(80);
      }
      const [row] = await rows(sql`select disabled_at, fail_count from push_endpoints`);
      expect(row?.fail_count).toBe(MAX_FAILS);
      expect(row?.disabled_at).not.toBeNull();
    });

    it('Timer prüft die Pause neu: wird sie verlängert, wird mit der Restdauer neu geplant', async () => {
      await register(fam.parent);
      await register(fam.child);
      world.app.push!.minIntervalMs = 0;
      const svc = world.app.push as unknown as { backoffUntil: number };
      svc.backoffUntil = Date.now() + 250; // Pause läuft: beide Geräte bekommen einen Timer
      await change(fam.admin);
      await wait(60);
      expect(calls).toHaveLength(0);
      svc.backoffUntil = Date.now() + 800; // Pause verlängert
      await wait(300); // der ursprüngliche Ablauf (250 ms) ist vorbei
      expect(calls).toHaveLength(0);
      expect(await until(() => calls.length >= 2, 3000)).toBe(true);
    });

    it('Test-Wecker respektiert die globale Pause', async () => {
      await register(fam.child);
      reply = { status: 503 };
      expect((await fam.child.client.post('/api/v1/me/push/test')).json.result).toBe('failed');
      reply = { status: 200 };
      expect((await fam.child.client.post('/api/v1/me/push/test')).json.result).toBe('failed'); // Pause läuft noch
      await wait(350);
      expect((await fam.child.client.post('/api/v1/me/push/test')).json.result).toBe('sent');
    });

    it('ein Erfolg setzt den Fehlerzähler zurück', async () => {
      await register(fam.child);
      reply = { status: 500 };
      await change(fam.admin);
      await until(() => calls.length === 1);
      await wait(80);
      reply = { status: 200 };
      await change(fam.admin);
      await until(() => calls.length === 2);
      await wait(80);
      const [row] = await rows(sql`select fail_count, last_ok_at from push_endpoints`);
      expect(row?.fail_count).toBe(0);
      expect(row?.last_ok_at).not.toBeNull();
    });

    it('4xx außer 404/410/429 (z. B. 400): kein Wiederholen', async () => {
      await register(fam.child);
      reply = { status: 400 };
      await change(fam.admin);
      expect(await topicsPosted(300)).toHaveLength(1);
    });

    it('401/403 (Token/Rechte falsch): Endpunkt bleibt aktiv, Versand pausiert, danach genau ein zusammengefasster Wecker', async () => {
      await register(fam.child);
      reply = { status: 403 };
      await change(fam.admin);
      expect(await until(() => calls.length === 1)).toBe(true);
      await wait(80);
      const [row] = await rows(sql`select disabled_at, fail_count from push_endpoints`);
      expect(row?.disabled_at).toBeNull();
      expect(row?.fail_count).toBe(0);
      reply = { status: 200 };
      await change(fam.admin); // während der Pause: zusammengefasst mit dem geplanten
      await change(fam.admin);
      await wait(100);
      expect(calls).toHaveLength(1);
      expect(await until(() => calls.length === 2, 2000)).toBe(true);
      await wait(400);
      expect(calls).toHaveLength(2);
    });

    it('429 mit Retry-After: kein Fehler des Geräts, ein zusammengefasster Wecker nach der Pause', async () => {
      await register(fam.child);
      reply = { status: 429, headers: { 'retry-after': '1' } };
      await change(fam.admin);
      expect(await until(() => calls.length === 1)).toBe(true);
      reply = { status: 200 };
      await change(fam.admin);
      await change(fam.admin);
      await wait(300);
      expect(calls).toHaveLength(1); // während der Pause nichts
      expect(await until(() => calls.length === 2, 3000)).toBe(true);
      await wait(300);
      expect(calls).toHaveLength(2);
      const [row] = await rows(sql`select disabled_at, fail_count from push_endpoints`);
      expect(row?.disabled_at).toBeNull();
      expect(row?.fail_count).toBe(0);
    });

    it('nicht erreichbares ntfy: kein Absturz, globale Pause statt Zählen, Antwort des Sync bleibt 200', async () => {
      await register(fam.child);
      const svc = world.app.push as unknown as { o: { config: { ntfyUrl: string } } };
      const old = svc.o.config.ntfyUrl;
      svc.o.config.ntfyUrl = 'http://127.0.0.1:1';
      try {
        const res = await change(fam.admin);
        expect(res.status).toBe(200);
        await wait(300);
        const [row] = await rows(sql`select fail_count, disabled_at, last_error_at from push_endpoints`);
        expect(row?.fail_count).toBe(0);
        expect(row?.disabled_at).toBeNull();
        expect(row?.last_error_at).not.toBeNull();
      } finally {
        svc.o.config.ntfyUrl = old;
      }
    });
  });
});
