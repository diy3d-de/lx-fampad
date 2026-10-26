// Einwurf (Home Assistant, Zähler-Postfach): Token (nur Admin, Step-up, Klartext einmal, Limit 5, Widerruf), Einwurf (Token im Header, Duplikate über k, einheitliches 401,
// Form- und Größenprüfung, inbox_full, Rate-Limit), Abholen und Quittieren (Rechte, Familiengrenze, Seiten, Parallelität), Schalter aus = 404, Wartungsmodus = 503,
// Aufräumen nach 30 Tagen. Der Server wertet Päckchen nie aus: die Tests werfen Zufallsbytes ein.
import { randomBytes, randomUUID } from 'node:crypto';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { runMaintenance } from '../src/auth/maintenance.js';
import { sha256Hex } from '../src/auth/crypto.js';
import * as schema from '../src/db/schema.js';
import { BoundedLimiter } from '../src/ingest/limiter.js';
import { MAX_ACTIVE_TOKENS, MAX_OPEN_BOXES } from '../src/ingest/service.js';
import { BAD_TOKEN_PER_HOUR } from '../src/routes/ingest.js';
import { grantOperator } from '../src/operator/service.js';
import { addMember, adminPassword, backends, type Client, World, type Harness } from './helpers.js';

const MIN = 60_000;
const ENV = { INGEST_ENABLED: 'true' };
const box = (n = 80): string => randomBytes(n).toString('base64');

describe.each(backends)('Einwurf ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv = ENV) {
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db, env);
  }
  beforeEach(async () => {
    await neu();
  });

  type Person = Awaited<ReturnType<typeof addMember>> | Awaited<ReturnType<typeof adminPassword>>;
  async function familie() {
    const a = await adminPassword(world);
    const zweiter = await addMember(world, a.client, 'admin', 'admin2@example.org');
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    const familyId = (await world.db.select().from(schema.families))[0]!.id;
    return { a, zweiter, eltern, kind, familyId };
  }
  async function stepUp(p: Person) {
    world.advance(31_000);
    expect((await p.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(p.totpSecret) })).status).toBe(200);
  }
  const tokenAnlegen = async (p: Person, name = 'Home Assistant') => {
    const res = await p.client.post('/api/v1/ingest/tokens', { name });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    return res.json as { token: string; id: string; name: string };
  };
  /** Client ohne Cookie, nur mit dem Token im Header (wie Home Assistant). */
  const ha = (token: string): Client => {
    const c = world.client('198.51.100.7');
    c.origin = undefined;
    c.bearer = token;
    return c;
  };
  const einwerfen = (token: string, items: unknown) => ha(token).post('/api/v1/ingest/zaehler', { items });
  const offen = async () => world.count('ingest_inbox');

  describe('Tokens', () => {
    it('nur Admin legt an (Step-up Pflicht), Klartext genau einmal, Hash in der Datenbank, Audit ohne Token', async () => {
      const f = await familie();
      for (const p of [f.eltern, f.kind]) expect((await p.client.post('/api/v1/ingest/tokens', { name: 'x' })).status).toBe(403);
      expect((await world.client().post('/api/v1/ingest/tokens', { name: 'x' })).status).toBe(401);
      world.advance(6 * MIN);
      const alt = await f.a.client.post('/api/v1/ingest/tokens', { name: 'HA' });
      expect(alt.status).toBe(403);
      expect(alt.json.error).toBe('step_up_required');
      await stepUp(f.a);
      const t = await tokenAnlegen(f.a);
      expect(t.token).toMatch(/^fhi_[A-Za-z0-9_-]{43}$/);
      expect(t.name).toBe('Home Assistant');
      const rows = await world.db.select().from(schema.ingestTokens);
      expect(rows).toHaveLength(1);
      expect(rows[0]!.tokenHash).toBe(sha256Hex(t.token));
      expect(JSON.stringify(rows)).not.toContain(t.token);
      const audit = JSON.stringify(await world.db.select().from(schema.auditLog));
      expect(audit).toContain('ingest_token_created');
      expect(audit).not.toContain(t.token);
      // Liste: ohne Hash und ohne Klartext
      const liste = await f.a.client.get('/api/v1/ingest/tokens');
      expect(liste.status).toBe(200);
      expect(liste.json.tokens).toEqual([{ id: t.id, name: 'Home Assistant', createdAt: expect.any(String), lastUsedAt: null, revokedAt: null }]);
      expect(JSON.stringify(liste.json)).not.toContain(t.token);
      expect(JSON.stringify(liste.json)).not.toContain(rows[0]!.tokenHash);
      // Liste nur für Admins
      for (const p of [f.eltern, f.kind]) expect((await p.client.get('/api/v1/ingest/tokens')).status).toBe(403);
    });

    it('ungültige Namen: 400; höchstens 5 aktive Tokens (Widerruf macht Platz)', async () => {
      const f = await familie();
      expect((await f.a.client.post('/api/v1/ingest/tokens', { name: '' })).status).toBe(400);
      expect((await f.a.client.post('/api/v1/ingest/tokens', { name: 'x'.repeat(41) })).status).toBe(400);
      expect((await f.a.client.post('/api/v1/ingest/tokens', { name: 'ok', extra: 1 })).status).toBe(400);
      const ids: string[] = [];
      for (let i = 0; i < MAX_ACTIVE_TOKENS; i++) ids.push((await tokenAnlegen(f.a, `T${i}`)).id);
      const sechs = await f.a.client.post('/api/v1/ingest/tokens', { name: 'zu viel' });
      expect(sechs.status).toBe(409);
      expect(sechs.json.error).toBe('token_limit');
      expect((await f.a.client.del(`/api/v1/ingest/tokens/${ids[0]}`)).status).toBe(200);
      await tokenAnlegen(f.a, 'wieder');
    });

    it('Widerruf: nur Admin mit Step-up, markiert nur (kein Löschen), danach 401; unbekannt und doppelt 404', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      expect((await einwerfen(t.token, [{ k: 'a', box: box() }])).status).toBe(200);
      expect((await f.eltern.client.del(`/api/v1/ingest/tokens/${t.id}`)).status).toBe(403);
      world.advance(6 * MIN);
      const alt = await f.a.client.del(`/api/v1/ingest/tokens/${t.id}`);
      expect(alt.status).toBe(403);
      expect(alt.json.error).toBe('step_up_required');
      await stepUp(f.a);
      expect((await f.a.client.del(`/api/v1/ingest/tokens/${randomUUID()}`)).status).toBe(404);
      expect((await f.a.client.del('/api/v1/ingest/tokens/kein-uuid')).status).toBe(400);
      expect((await f.a.client.del(`/api/v1/ingest/tokens/${t.id}`)).status).toBe(200);
      expect((await f.a.client.del(`/api/v1/ingest/tokens/${t.id}`)).status).toBe(404);
      const rows = await world.db.select().from(schema.ingestTokens);
      expect(rows).toHaveLength(1);
      expect(rows[0]!.revokedAt).not.toBeNull();
      expect((await einwerfen(t.token, [{ k: 'b', box: box() }])).status).toBe(401);
      expect((await world.db.select().from(schema.auditLog).where(eq(schema.auditLog.event, 'ingest_token_revoked'))).length).toBe(1);
      const liste = await f.a.client.get('/api/v1/ingest/tokens');
      expect(liste.json.tokens[0].revokedAt).not.toBeNull();
    });

    it('ein Token einer anderen Familie lässt sich weder sehen noch widerrufen', async () => {
      const f = await familie();
      const fremd = randomUUID();
      const tid = randomUUID();
      await world.db.execute(sql`insert into families (id, name) values (${fremd}, 'Fremd')`);
      await world.db.execute(sql`insert into ingest_tokens (id, family_id, name, token_hash) values (${tid}, ${fremd}, 'F', 'x')`);
      expect((await f.a.client.get('/api/v1/ingest/tokens')).json.tokens).toEqual([]);
      expect((await f.a.client.del(`/api/v1/ingest/tokens/${tid}`)).status).toBe(404);
      expect((await world.db.select().from(schema.ingestTokens).where(eq(schema.ingestTokens.id, tid)))[0]!.revokedAt).toBeNull();
    });
  });

  describe('Einwurf', () => {
    it('gültig: speichert undurchsichtig, Antwort accepted/duplicates, Duplikat über k wird nur gezählt', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const b1 = box();
      const res = await einwerfen(t.token, [{ k: 'm1', box: b1 }, { k: 'm2', box: box() }]);
      expect(res.status).toBe(200);
      expect(res.json).toEqual({ accepted: 2, duplicates: 0 });
      const wieder = await einwerfen(t.token, [{ k: 'm1', box: box() }, { k: 'm3', box: box() }, { k: 'm3', box: box() }]);
      expect(wieder.json).toEqual({ accepted: 1, duplicates: 2 });
      expect(await offen()).toBe(3);
      const row = (await world.db.select().from(schema.ingestInbox).where(eq(schema.ingestInbox.k, 'm1')))[0]!;
      expect(row.box.toString('base64')).toBe(b1);
      expect(row.familyId).toBe(f.familyId);
      expect(row.tokenId).toBe(t.id);
      // zweites Token: dasselbe k ist ein eigener Schlüssel
      const t2 = await tokenAnlegen(f.a, 'zweites');
      expect((await einwerfen(t2.token, [{ k: 'm1', box: box() }])).json).toEqual({ accepted: 1, duplicates: 0 });
    });

    it('die Familie kommt aus dem Token, nie aus dem Body; zusätzliche Felder werden abgelehnt', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      expect((await ha(t.token).post('/api/v1/ingest/zaehler', { items: [{ k: 'a', box: box() }], familyId: randomUUID() })).status).toBe(400);
      expect((await ha(t.token).post('/api/v1/ingest/zaehler', { items: [{ k: 'a', box: box(), familyId: randomUUID() }] })).status).toBe(400);
      expect(await offen()).toBe(0);
    });

    it('fehlendes, falsches, unbekanntes und widerrufenes Token: identische 401-Antwort', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const t2 = await tokenAnlegen(f.a, 'zweites');
      await stepUp(f.a);
      await f.a.client.del(`/api/v1/ingest/tokens/${t2.id}`);
      const items = [{ k: 'a', box: box() }];
      const antworten = [
        await world.client().post('/api/v1/ingest/zaehler', { items }), // gar kein Header
        await einwerfen('fhi_' + 'A'.repeat(43), items), // wohlgeformt, unbekannt
        await einwerfen('kein-token', items), // falsche Form
        await einwerfen(t.token.slice(0, -1) + (t.token.endsWith('A') ? 'B' : 'A'), items), // fast richtig
        await einwerfen(t2.token, items), // widerrufen
      ];
      for (const a of antworten) expect(a.status).toBe(401);
      expect(new Set(antworten.map((a) => JSON.stringify(a.json))).size).toBe(1);
      expect(await offen()).toBe(0);
    });

    it('eine Cookie-Sitzung ohne Token geht nicht, auch nicht mit CSRF; das Token gilt auf keiner anderen Route', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      expect((await f.a.client.post('/api/v1/ingest/zaehler', { items: [{ k: 'a', box: box() }] })).status).toBe(401);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler', { items: [{ k: 'a', box: box() }] })).status).toBe(401);
      const c = ha(t.token);
      for (const [m, u, b] of [
        ['GET', '/api/v1/me', undefined],
        ['GET', '/api/v1/ingest/tokens', undefined],
        ['POST', '/api/v1/ingest/tokens', { name: 'x' }],
        ['GET', '/api/v1/ingest/zaehler/pending', undefined],
        ['POST', '/api/v1/ingest/zaehler/ack', { ids: [randomUUID()] }],
        ['POST', '/api/v1/sync', { protocolVersion: 1, deviceId: randomUUID(), sinceRev: 0, ops: [] }],
      ] as const) {
        const res = await c.request(m, u, b === undefined ? {} : { body: b });
        expect(res.status, `${m} ${u}`).toBe(401);
      }
      expect(await offen()).toBe(0);
    });

    it('ungültige Eingaben: base64, leere und zu große Box, k, zu viele Items, leere Liste', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const ok = box();
      const schlecht: unknown[] = [
        [{ k: 'a', box: '***nicht base64***' }],
        [{ k: 'a', box: ok.replace(/=+$/, '') + '!' }],
        [{ k: 'a', box: Buffer.from(ok, 'base64').toString('base64url') + '-' }], // URL-Alphabet
        [{ k: 'a', box: '' }],
        [{ k: 'a', box: box(1025) }],
        [{ k: 'a', box: box(5000) }],
        [{ k: '', box: ok }],
        [{ k: 'k'.repeat(65), box: ok }],
        [{ k: 'a\u0000b', box: ok }],
        [{ k: 'a' }],
        [{ box: ok }],
        [{ k: 1, box: ok }],
        [],
        Array.from({ length: 51 }, (_, i) => ({ k: `k${i}`, box: ok })),
      ];
      for (const items of schlecht) expect((await einwerfen(t.token, items)).status, JSON.stringify(items).slice(0, 60)).toBe(400);
      expect((await ha(t.token).post('/api/v1/ingest/zaehler', { items: 'x' })).status).toBe(400);
      expect((await ha(t.token).post('/api/v1/ingest/zaehler', {})).status).toBe(400);
      expect(await offen()).toBe(0);
      // Grenzen sind erlaubt: 1 Byte, 1024 Bytes, 64 Zeichen, 50 Items
      expect((await einwerfen(t.token, [{ k: 'k'.repeat(64), box: box(1) }, { k: 'b', box: box(1024) }])).status).toBe(200);
      expect((await einwerfen(t.token, Array.from({ length: 50 }, (_, i) => ({ k: `n${i}`, box: ok })))).json.accepted).toBe(50);
    });

    it('ein zu großer Body (über 100 KB) wird abgelehnt', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const res = await einwerfen(t.token, Array.from({ length: 50 }, (_, i) => ({ k: `k${i}`, box: 'A'.repeat(2400) })));
      expect([400, 413]).toContain(res.status);
      expect(await offen()).toBe(0);
    });

    it('Obergrenze offener Päckchen: darüber 429 inbox_full ohne etwas zu speichern, Duplikate gehen weiter', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await world.db.execute(
        sql`insert into ingest_inbox (family_id, token_id, k, box) select ${f.familyId}::uuid, ${t.id}::uuid, 'g' || g, '\x01'::bytea from generate_series(1, ${MAX_OPEN_BOXES - 1}) g`,
      );
      const zwei = await einwerfen(t.token, [{ k: 'neu1', box: box() }, { k: 'neu2', box: box() }]);
      expect(zwei.status).toBe(429);
      expect(zwei.json.error).toBe('inbox_full');
      expect(JSON.stringify(zwei.json)).not.toContain('neu1');
      expect(await offen()).toBe(MAX_OPEN_BOXES - 1);
      expect((await einwerfen(t.token, [{ k: 'neu1', box: box() }])).status).toBe(200);
      expect(await offen()).toBe(MAX_OPEN_BOXES);
      const voll = await einwerfen(t.token, [{ k: 'neu3', box: box() }]);
      expect(voll.status).toBe(429);
      expect((await einwerfen(t.token, [{ k: 'g1', box: box() }])).json).toEqual({ accepted: 0, duplicates: 1 });
      // nach dem Quittieren ist wieder Platz
      const ids = (await f.eltern.client.get('/api/v1/ingest/zaehler/pending?limit=10')).json.items.map((i: { id: string }) => i.id);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids })).json.deleted).toBe(10);
      expect((await einwerfen(t.token, [{ k: 'neu3', box: box() }])).status).toBe(200);
    });

    it('last_used_at wird höchstens alle paar Minuten geschrieben', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const gelesen = async () => (await world.db.select().from(schema.ingestTokens))[0]!.lastUsedAt;
      expect(await gelesen()).toBeNull();
      // ein ungültiger Body schreibt nichts
      expect((await einwerfen(t.token, [])).status).toBe(400);
      expect(await gelesen()).toBeNull();
      await einwerfen(t.token, [{ k: 'a', box: box() }]);
      const erst = await gelesen();
      expect(erst?.getTime()).toBe(world.clock);
      world.advance(MIN);
      await einwerfen(t.token, [{ k: 'b', box: box() }]);
      expect((await gelesen())?.getTime()).toBe(erst?.getTime());
      world.advance(6 * MIN);
      await einwerfen(t.token, [{ k: 'c', box: box() }]);
      expect((await gelesen())?.getTime()).toBe(world.clock);
    });

    it('Rate-Limit je Token: darüber 429, ein anderes Token ist unberührt', async () => {
      await neu({ ...ENV, INGEST_RATE_PER_HOUR: '3' });
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const t2 = await tokenAnlegen(f.a, 'zweites');
      for (let i = 0; i < 3; i++) expect((await einwerfen(t.token, [{ k: `a${i}`, box: box() }])).status).toBe(200);
      expect((await einwerfen(t.token, [{ k: 'a9', box: box() }])).status).toBe(429);
      expect((await einwerfen(t2.token, [{ k: 'b0', box: box() }])).status).toBe(200);
    });

    it('zufällige Tokens umgehen die Grenze nicht: nach 20 Fehlschlägen je Netzadresse 429, ein gültiges Token einer anderen Adresse bleibt frei', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const fremd = (token: string): Client => {
        const c = world.client('203.0.113.9');
        c.origin = undefined;
        c.bearer = token;
        return c;
      };
      const items = [{ k: 'a', box: box() }];
      for (let i = 0; i < BAD_TOKEN_PER_HOUR; i++) {
        const res = await fremd('fhi_' + randomBytes(32).toString('base64url')).post('/api/v1/ingest/zaehler', { items });
        expect(res.status).toBe(401);
      }
      // jetzt ist die Adresse gesperrt, auch mit einem gültigen Token (bis das Fenster abläuft)
      expect((await fremd('fhi_' + randomBytes(32).toString('base64url')).post('/api/v1/ingest/zaehler', { items })).status).toBe(429);
      expect((await fremd(t.token).post('/api/v1/ingest/zaehler', { items })).status).toBe(429);
      // andere Adresse: unberührt
      expect((await einwerfen(t.token, items)).status).toBe(200);
      // nach dem Fenster geht es wieder
      world.advance(61 * MIN);
      expect((await fremd(t.token).post('/api/v1/ingest/zaehler', { items: [{ k: 'b', box: box() }] })).status).toBe(200);
    });

    it('wenige Fehlschläge derselben Adresse blockieren ein gültiges Token nicht', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      for (let i = 0; i < 5; i++) expect((await einwerfen('fhi_' + randomBytes(32).toString('base64url'), [{ k: 'x', box: box() }])).status).toBe(401);
      expect((await einwerfen(t.token, [{ k: 'ok', box: box() }])).status).toBe(200);
    });

    it('Grenze je Token zählt erst nach der Anmeldung (Fehlschläge verbrauchen sie nicht)', async () => {
      await neu({ ...ENV, INGEST_RATE_PER_HOUR: '3' });
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      for (let i = 0; i < 10; i++) await einwerfen('fhi_' + randomBytes(32).toString('base64url'), [{ k: 'x', box: box() }]);
      // andere Adresse als die der Fehlschläge ist hier nicht nötig: 10 < 20, das Token hat noch alle drei
      for (let i = 0; i < 3; i++) expect((await einwerfen(t.token, [{ k: `a${i}`, box: box() }])).status).toBe(200);
      expect((await einwerfen(t.token, [{ k: 'a9', box: box() }])).status).toBe(429);
    });

    it('der Zähler wächst nicht mit fremden Eingaben: feste Obergrenze der Schlüssel, ältester wird verdrängt', async () => {
      let t = 1_000_000;
      const l = new BoundedLimiter(2, 60_000, () => new Date(t), 50);
      for (let i = 0; i < 500; i++) l.hit(`ip-${i}`);
      expect(l.size).toBeLessThanOrEqual(50);
      // abgelaufene Fenster werden zuerst geräumt
      t += 61_000;
      l.hit('neu');
      expect(l.size).toBeLessThanOrEqual(50);
      expect(l.hit('neu')).toBe(true);
      expect(l.hit('neu')).toBe(false);
      expect(l.blocked('neu')).toBe(true);
    });
  });

  describe('Abholen und Quittieren', () => {
    it('Kinder bekommen 404, ohne Sitzung 401, Eltern und Admins dürfen', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await einwerfen(t.token, [{ k: 'a', box: box() }]);
      const id = (await world.db.select().from(schema.ingestInbox))[0]!.id;
      expect((await f.kind.client.get('/api/v1/ingest/zaehler/pending')).status).toBe(404);
      expect((await f.kind.client.post('/api/v1/ingest/zaehler/ack', { ids: [id] })).status).toBe(404);
      expect(await offen()).toBe(1);
      expect((await world.client().get('/api/v1/ingest/zaehler/pending')).status).toBe(401);
      expect((await world.client().post('/api/v1/ingest/zaehler/ack', { ids: [id] })).status).toBe(401);
      for (const p of [f.a, f.zweiter, f.eltern]) {
        const res = await p.client.get('/api/v1/ingest/zaehler/pending');
        expect(res.status).toBe(200);
        expect(res.json.items).toHaveLength(1);
        expect(res.json.items[0]).toMatchObject({ id, receivedAt: expect.any(String) });
        expect(res.json.next).toBeNull();
      }
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: [id] })).json).toEqual({ deleted: 1 });
      expect(await offen()).toBe(0);
    });

    it('liefert die Bytes unverändert als base64', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const b = box(200);
      await einwerfen(t.token, [{ k: 'a', box: b }]);
      expect((await f.eltern.client.get('/api/v1/ingest/zaehler/pending')).json.items[0].box).toBe(b);
    });

    it('fremde Familie: sieht nichts, quittiert nichts, ihre Päckchen bleiben', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await einwerfen(t.token, [{ k: 'a', box: box() }]);
      const fremd = randomUUID();
      const ftok = randomUUID();
      const fid = randomUUID();
      await world.db.execute(sql`insert into families (id, name) values (${fremd}, 'Fremd')`);
      await world.db.execute(sql`insert into ingest_tokens (id, family_id, name, token_hash) values (${ftok}, ${fremd}, 'F', 'xx')`);
      await world.db.execute(sql`insert into ingest_inbox (id, family_id, token_id, k, box) values (${fid}, ${fremd}, ${ftok}, 'f', '\x01')`);
      const mein = (await f.eltern.client.get('/api/v1/ingest/zaehler/pending')).json.items.map((i: { id: string }) => i.id);
      expect(mein).toHaveLength(1);
      expect(mein).not.toContain(fid);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: [fid, randomUUID()] })).json).toEqual({ deleted: 0 });
      expect(await offen()).toBe(2);
      // ein Token der fremden Familie gehört nicht zu uns: eigenes Token legt nur in die eigene Familie
      expect((await world.db.select().from(schema.ingestInbox).where(eq(schema.ingestInbox.id, fid)))[0]!.familyId).toBe(fremd);
    });

    it('Seiten: limit und next, stabile Reihenfolge nach Eingang, nichts doppelt oder verloren', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      for (let i = 0; i < 5; i++) {
        await einwerfen(t.token, [{ k: `k${i}`, box: box() }]);
        world.advance(1000);
      }
      const reihenfolge = (await world.db.select().from(schema.ingestInbox)).sort((x, y) => x.seq - y.seq).map((r) => r.id);
      const gesehen: string[] = [];
      let after: string | null = null;
      for (let seite = 0; seite < 10; seite++) {
        const res = await f.eltern.client.get(`/api/v1/ingest/zaehler/pending?limit=2${after ? `&after=${after}` : ''}`);
        expect(res.status).toBe(200);
        expect(res.json.items.length).toBeLessThanOrEqual(2);
        gesehen.push(...res.json.items.map((i: { id: string }) => i.id));
        if (res.json.next === null) break;
        expect(res.json.items).toHaveLength(2);
        after = res.json.next as string;
      }
      expect(gesehen).toEqual(reihenfolge);
      // ungültige Parameter
      for (const q of ['limit=0', 'limit=201', 'limit=abc', 'after=abc', 'after=-1', 'x=1']) expect((await f.eltern.client.get(`/api/v1/ingest/zaehler/pending?${q}`)).status, q).toBe(400);
      expect((await f.eltern.client.get('/api/v1/ingest/zaehler/pending?limit=200')).status).toBe(200);
    });

    it('Filter ?token=: nur die Päckchen dieser Verbindung; ohne Filter alle; Familie bleibt maßgeblich', async () => {
      const f = await familie();
      const t1 = await tokenAnlegen(f.a, 'Haus');
      const t2 = await tokenAnlegen(f.a, 'Keller');
      await einwerfen(t1.token, [{ k: 'a', box: box() }, { k: 'b', box: box() }]);
      await einwerfen(t2.token, [{ k: 'c', box: box() }]);
      const hole = async (q: string) => (await f.eltern.client.get(`/api/v1/ingest/zaehler/pending${q}`)).json.items as Array<{ id: string }>;
      expect(await hole('')).toHaveLength(3);
      expect(await hole(`?token=${t1.id}`)).toHaveLength(2);
      expect(await hole(`?token=${t2.id}`)).toHaveLength(1);
      // mit Seiten: der Filter gilt auch beim Weiterblättern
      const s1 = (await f.eltern.client.get(`/api/v1/ingest/zaehler/pending?token=${t1.id}&limit=1`)).json;
      expect(s1.items).toHaveLength(1);
      const s2 = (await f.eltern.client.get(`/api/v1/ingest/zaehler/pending?token=${t1.id}&limit=1&after=${s1.next}`)).json;
      expect(s2.items).toHaveLength(1);
      expect(s2.next).toBeNull();
      // ein unbekanntes Token und das Token einer fremden Familie ergeben eine leere Liste, nie Päckchen einer anderen Familie
      const fremd = randomUUID();
      const ftok = randomUUID();
      await world.db.execute(sql`insert into families (id, name) values (${fremd}, 'Fremd')`);
      await world.db.execute(sql`insert into ingest_tokens (id, family_id, name, token_hash) values (${ftok}, ${fremd}, 'F', 'xx')`);
      await world.db.execute(sql`insert into ingest_inbox (id, family_id, token_id, k, box) values (${randomUUID()}, ${fremd}, ${ftok}, 'f', '\x01')`);
      expect(await hole(`?token=${ftok}`)).toHaveLength(0);
      expect(await hole(`?token=${randomUUID()}`)).toHaveLength(0);
      // ungültige Kennung
      expect((await f.eltern.client.get('/api/v1/ingest/zaehler/pending?token=abc')).status).toBe(400);
      // Kinder haben auch mit Filter keinen Zugriff
      expect((await f.kind.client.get(`/api/v1/ingest/zaehler/pending?token=${t1.id}`)).status).toBe(404);
    });

    it('ack: Obergrenze 200 IDs, nur UUIDs, doppelte IDs zählen einmal', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await einwerfen(t.token, [{ k: 'a', box: box() }]);
      const id = (await world.db.select().from(schema.ingestInbox))[0]!.id;
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: [] })).status).toBe(400);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: ['x'] })).status).toBe(400);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: Array.from({ length: 201 }, () => randomUUID()) })).status).toBe(400);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: Array.from({ length: 200 }, () => randomUUID()) })).json).toEqual({ deleted: 0 });
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: [id, id] })).json).toEqual({ deleted: 1 });
    });

    it('Parallelität: zwei gleichzeitige Acks derselben IDs löschen zusammen genau so viele, wie es gibt', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await einwerfen(t.token, Array.from({ length: 40 }, (_, i) => ({ k: `p${i}`, box: box() })));
      const ids = (await world.db.select().from(schema.ingestInbox)).map((r) => r.id);
      expect(ids).toHaveLength(40);
      const [r1, r2] = await Promise.all([f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids }), f.a.client.post('/api/v1/ingest/zaehler/ack', { ids })]);
      expect(r1.status).toBe(200);
      expect(r2.status).toBe(200);
      expect((r1.json.deleted as number) + (r2.json.deleted as number)).toBe(40);
      expect(await offen()).toBe(0);
    });

    it('Parallelität beim Einwerfen: gleiche k gleichzeitig ergeben genau einen Eintrag', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const antworten = await Promise.all(Array.from({ length: 4 }, () => einwerfen(t.token, [{ k: 'gleich', box: box() }])));
      for (const a of antworten) expect(a.status).toBe(200);
      expect(antworten.reduce((s, a) => s + (a.json.accepted as number), 0)).toBe(1);
      expect(await offen()).toBe(1);
    });

    it('Parallelität: die Obergrenze offener Päckchen gilt auch bei gleichzeitigen Einwürfen', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await world.db.execute(
        sql`insert into ingest_inbox (family_id, token_id, k, box) select ${f.familyId}::uuid, ${t.id}::uuid, 'g' || g, '\x01'::bytea from generate_series(1, ${MAX_OPEN_BOXES - 3}) g`,
      );
      const antworten = await Promise.all(Array.from({ length: 6 }, (_, i) => einwerfen(t.token, [{ k: `p${i}a`, box: box() }, { k: `p${i}b`, box: box() }])));
      expect(antworten.every((a) => a.status === 200 || a.status === 429)).toBe(true);
      expect(await offen()).toBeLessThanOrEqual(MAX_OPEN_BOXES);
    });
  });

  describe('Schalter, Wartung, Aufräumen', () => {
    it('Schalter aus (Standard): alle Routen 404, auch ohne Anmeldung', async () => {
      await neu({});
      const f = await familie();
      expect(world.config.ingest.enabled).toBe(false);
      const id = randomUUID();
      for (const [m, u, b] of [
        ['POST', '/api/v1/ingest/zaehler', { items: [{ k: 'a', box: box() }] }],
        ['POST', '/api/v1/ingest/tokens', { name: 'x' }],
        ['GET', '/api/v1/ingest/tokens', undefined],
        ['DELETE', `/api/v1/ingest/tokens/${id}`, undefined],
        ['GET', '/api/v1/ingest/zaehler/pending', undefined],
        ['POST', '/api/v1/ingest/zaehler/ack', { ids: [id] }],
      ] as const) {
        for (const c of [f.a.client, world.client()]) {
          const res = await c.request(m, u, b === undefined ? {} : { body: b });
          expect(res.status, `${m} ${u}`).toBe(404);
        }
      }
    });

    it('GET /version meldet features.ingest nach dem Schalter', async () => {
      expect((await world.client().get('/api/v1/version')).json.features.ingest).toBe(true);
      await neu({});
      expect((await world.client().get('/api/v1/version')).json.features.ingest).toBe(false);
    });

    it('ungültiger Schalterwert bricht den Start ab (fail-closed)', async () => {
      const { loadConfig } = await import('../src/config.js');
      expect(() => loadConfig({ NODE_ENV: 'development', INGEST_ENABLED: 'vielleicht' })).toThrow(/INGEST_ENABLED/);
      expect(() => loadConfig({ NODE_ENV: 'development', INGEST_RATE_PER_HOUR: '0' })).toThrow(/INGEST_RATE_PER_HOUR/);
    });

    it('Wartungsmodus sperrt den Einwurf mit 503 (maintenance), Lesen bleibt erreichbar', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      await einwerfen(t.token, [{ k: 'a', box: box() }]);
      await grantOperator(world.auth.ctx, f.a.email);
      await stepUp(f.a);
      expect((await f.a.client.put('/api/v1/admin/maintenance', { active: true })).status).toBe(200);
      const res = await einwerfen(t.token, [{ k: 'b', box: box() }]);
      expect(res.status).toBe(503);
      expect(res.json.error).toBe('maintenance');
      expect(await offen()).toBe(1);
      expect((await f.eltern.client.get('/api/v1/ingest/zaehler/pending')).status).toBe(200);
      expect((await f.eltern.client.post('/api/v1/ingest/zaehler/ack', { ids: [randomUUID()] })).status).toBe(503);
    });

    it('Aufräumen: Päckchen älter als 30 Tage werden gelöscht, jüngere bleiben', async () => {
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const tag = 86_400_000;
      const vor = (tage: number) => new Date(world.clock - tage * tag);
      await world.db.insert(schema.ingestInbox).values([
        { familyId: f.familyId, tokenId: t.id, k: 'alt', box: Buffer.from([1]), receivedAt: vor(31) },
        { familyId: f.familyId, tokenId: t.id, k: 'grenze', box: Buffer.from([1]), receivedAt: vor(29) },
        { familyId: f.familyId, tokenId: t.id, k: 'neu', box: Buffer.from([1]), receivedAt: vor(0) },
      ]);
      const report = await runMaintenance(world.auth.ctx);
      expect(report.ingestDeleted).toBe(1);
      expect((await world.db.select().from(schema.ingestInbox)).map((r) => r.k).sort()).toEqual(['grenze', 'neu']);
    });

    it('Aufräumen: widerrufene Tokens nach 400 Tagen endgültig weg, jüngere widerrufene und aktive bleiben', async () => {
      const f = await familie();
      const tag = 86_400_000;
      const vor = (tage: number) => new Date(world.clock - tage * tag);
      const mk = (n: string, revoked: Date | null) => ({ familyId: f.familyId, name: n, tokenHash: sha256Hex(n), revokedAt: revoked });
      await world.db.insert(schema.ingestTokens).values([mk('alt', vor(401)), mk('jung', vor(399)), mk('aktiv', null)]);
      const report = await runMaintenance(world.auth.ctx);
      expect(report.ingestTokensDeleted).toBe(1);
      expect((await world.db.select().from(schema.ingestTokens)).map((r) => r.name).sort()).toEqual(['aktiv', 'jung']);
    });

    it('nichts davon steht im Log: Token, k und Päckchen', async () => {
      const zeilen: string[] = [];
      const { Writable } = await import('node:stream');
      await world.close();
      await harness.reset();
      world = await World.create(harness.db, { ...ENV, LOG_LEVEL: 'debug' }, { logStream: new Writable({ write: (c, _e, cb) => (zeilen.push(String(c)), cb()) }) });
      const f = await familie();
      const t = await tokenAnlegen(f.a);
      const b = box(60);
      await einwerfen(t.token, [{ k: 'GEHEIMES-K', box: b }]);
      await einwerfen('fhi_' + 'Z'.repeat(43), [{ k: 'GEHEIMES-K', box: b }]);
      await einwerfen(t.token, [{ k: 'GEHEIMES-K', box: '***' }]);
      const log = zeilen.join('');
      expect(log.length).toBeGreaterThan(0);
      for (const s of [t.token, 'GEHEIMES-K', b, 'ZZZZZZZZZZ']) expect(log).not.toContain(s);
    });
  });
});
