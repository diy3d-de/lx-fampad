// Wetter-Hinweise per Wecker: Schwellen (gleich wie in der App), Hysterese, Übergänge, Entprellung je Art und Gerät, Neustart ohne Spam,
// veraltete Messung, nur Geräte mit eingeschalteter Art, Wecker ohne Inhalt, Route /me/weather-alerts, Migration.
// ntfy wird durch einen Loopback-HTTP-Server ersetzt, der die Aufrufe aufzeichnet.
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { sql } from 'drizzle-orm';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WAKE_BODY } from '../src/push/service.js';
import { ALERT_HYSTERESE, ALERT_KINDS, ALERT_THRESHOLDS, aenderung3h, bewerte, kindsToMask, maskHas, WeatherAlerts } from '../src/weather/alerts.js';
import type { WeatherView } from '../src/weather/service.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, resetSync, type Device, type Family, type Json } from './sync-kit.js';

type Cur = NonNullable<WeatherView['current']>;
const NOW = Date.parse('2026-10-19T08:00:00Z');
const cur = (p: Partial<Cur> = {}): Cur => ({
  measuredAt: new Date(NOW - 5 * 60_000).toISOString(),
  stale: false,
  temperature: 10,
  humidity: 70,
  pressure: 1013,
  rain1h: 0,
  rain24h: 0,
  windKmh: 5,
  gustKmh: 10,
  windAngle: 180,
  ...p,
});
const reihe = (...v: (number | null)[]): (number | null)[] => v;
const hourly = (p: Partial<WeatherView['hourly']> = {}): WeatherView['hourly'] => ({
  from: '2026-10-12T09:00:00.000Z',
  stepSec: 3600,
  temperature: [],
  humidity: [],
  pressure: [],
  rain: [],
  windKmh: [],
  gustKmh: [],
  windAngle: [],
  ...p,
});
const view = (c: Cur | null, h: WeatherView['hourly'] = hourly()): WeatherView => ({ place: 'X', current: c, min24h: null, max24h: null, series: [], hourly: h, days: [], sun: [] });

describe('Schwellen und Bitmaske', () => {
  it('gleich der gemeinsamen Datei docs/wetter-hinweis-schwellen.json (die App prüft dieselbe Datei)', () => {
    const j = JSON.parse(readFileSync(new URL('../../docs/wetter-hinweis-schwellen.json', import.meta.url), 'utf8')) as Record<string, number>;
    for (const [k, v] of Object.entries(ALERT_THRESHOLDS)) expect(j[k], k).toBe(v);
  });
  it('Hysterese liegt immer auf der sicheren Seite der Schwelle', () => {
    expect(ALERT_HYSTERESE.frostBisGradC).toBeGreaterThan(ALERT_THRESHOLDS.frostUnterGradC);
    expect(ALERT_HYSTERESE.windBisKmh).toBeLessThan(ALERT_THRESHOLDS.windBoeenUeberKmh);
    expect(ALERT_HYSTERESE.hitzeBisGradC).toBeLessThan(ALERT_THRESHOLDS.hitzeUeberGradC);
    expect(ALERT_HYSTERESE.druckBisHpa3h).toBeLessThan(ALERT_THRESHOLDS.druckAbfallMehrAlsHpa3h);
  });
  it('Maske: fünf Bits, ohne Schieben, Rundreise', () => {
    expect(ALERT_KINDS).toEqual(['frost', 'regen', 'wind', 'hitze', 'druck']);
    expect(kindsToMask([])).toBe(0);
    expect(kindsToMask([...ALERT_KINDS])).toBe(31);
    for (const k of ALERT_KINDS) expect(maskHas(kindsToMask([k]), k)).toBe(true);
    expect(maskHas(kindsToMask(['frost']), 'wind')).toBe(false);
  });
});

describe('bewerte (Schwellen mit Hysterese)', () => {
  const temp = (t: number | null) => cur({ temperature: t });
  it('Frost: unter 2 °C beginnt, erst ab 3 °C endet (kein Flattern bei 1,9/2,1)', () => {
    expect(bewerte('frost', false, temp(2), hourly())).toBe(false);
    expect(bewerte('frost', false, temp(1.9), hourly())).toBe(true);
    expect(bewerte('frost', true, temp(2.1), hourly())).toBe(true);
    expect(bewerte('frost', true, temp(2.9), hourly())).toBe(true);
    expect(bewerte('frost', true, temp(3), hourly())).toBe(false);
    expect(bewerte('frost', false, temp(null), hourly())).toBeNull();
  });
  it('Hitze: über 30 °C beginnt, ab 29 °C endet', () => {
    expect(bewerte('hitze', false, temp(30), hourly())).toBe(false);
    expect(bewerte('hitze', false, temp(30.1), hourly())).toBe(true);
    expect(bewerte('hitze', true, temp(29.5), hourly())).toBe(true);
    expect(bewerte('hitze', true, temp(29), hourly())).toBe(false);
  });
  it('Wind: Böen über 50 km/h beginnen, bis 40 km/h bleibt es aktiv; ohne Böenwert unbeurteilbar', () => {
    expect(bewerte('wind', false, cur({ gustKmh: 50 }), hourly())).toBe(false);
    expect(bewerte('wind', false, cur({ gustKmh: 51 }), hourly())).toBe(true);
    expect(bewerte('wind', true, cur({ gustKmh: 45 }), hourly())).toBe(true);
    expect(bewerte('wind', true, cur({ gustKmh: 40 }), hourly())).toBe(false);
    expect(bewerte('wind', false, cur({ gustKmh: null }), hourly())).toBeNull();
  });
  it('Regen: beginnt nur, wenn die Stunde davor trocken (0) gemessen war; endet, wenn es trocken ist', () => {
    const r = (rain1h: number | null, regen: (number | null)[]) => (a: boolean) => bewerte('regen', a, cur({ rain1h }), hourly({ rain: regen }));
    expect(r(0.3, reihe(0, 0, 0, 0.3))(false)).toBe(true);
    expect(r(0.3, reihe(0, 0, 0.2, 0.3))(false)).toBe(false); // schon nass
    expect(r(0.3, reihe(0, 0, null, 0.3))(false)).toBe(false); // kein Vorwert: nie raten
    expect(r(0.3, reihe(0.3))(false)).toBe(false);
    expect(r(0, reihe(0, 0, 0, 0))(false)).toBe(false);
    expect(r(0.4, reihe(0, 0.2, 0.3, 0.4))(true)).toBe(true); // bleibt aktiv, solange es regnet
    expect(r(0, reihe(0.2, 0.3, 0.1, 0))(true)).toBe(false);
    expect(r(null, reihe(0, 0, 0, 0))(false)).toBeNull();
  });
  it('Druck: mehr als 4 hPa Abfall in 3 h beginnt, unter 2 hPa Abfall endet; fehlende Werte unbeurteilbar', () => {
    const d = (p: (number | null)[], a: boolean) => bewerte('druck', a, cur(), hourly({ pressure: p }));
    expect(d(reihe(1010, 1009, 1008, 1006), false)).toBe(false); // -4,0: nicht mehr als 4
    expect(d(reihe(1010, 1009, 1008, 1005.9), false)).toBe(true);
    expect(d(reihe(1010, 1009, 1008, 1007), true)).toBe(true); // -3: bleibt
    expect(d(reihe(1010, 1009, 1008, 1008.5), true)).toBe(false);
    expect(d(reihe(1010), false)).toBeNull();
    expect(aenderung3h(reihe(1000, null, null, 995))).toBeCloseTo(-5);
    expect(aenderung3h(reihe(null, 1000, null, null, 996))).toBeCloseTo(-4); // Ersatzstunde daneben, wie die App
  });
});

interface Call {
  url: string;
  headers: http.IncomingHttpHeaders;
  body: string;
}

describe.each(backends)('Wetter-Wecker ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  let ntfy: http.Server;
  let calls: Call[] = [];
  let alerts: WeatherAlerts;
  const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
  const topics = new Map<string, string>();
  const rows = async (q: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(q)).rows as Json[];

  beforeAll(async () => {
    harness = await backend.open();
    ntfy = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        calls.push({ url: req.url ?? '', headers: req.headers, body: Buffer.concat(chunks).toString('utf8') });
        res.writeHead(200);
        res.end('{}');
      });
    });
    await new Promise<void>((resolve) => ntfy.listen(0, '127.0.0.1', resolve));
    const port = (ntfy.address() as AddressInfo).port;
    world = await World.create(
      harness.db,
      { NTFY_URL: `http://127.0.0.1:${port}`, NTFY_TOKEN: 'tk_testtoken1234567890', AUTH_RATE_LIMIT_MAX: '100000', WEATHER_ENABLED: 'true', WEATHER_STATION_MAC: '70:ee:50:01:79:f2', WEATHER_BBOX: '50.54,7.94,50.58,8.00', WEATHER_PLACE: 'Testort' },
      { pushMinIntervalMs: 0 },
    );
    fam = await createFamily(world);
    const log = { warn: () => undefined, error: () => undefined, info: () => undefined };
    alerts = new WeatherAlerts({ db: world.db, push: world.app.push!, log, now: world.now });
  }, 120_000);
  afterAll(async () => {
    await world.close();
    await new Promise<void>((resolve) => ntfy.close(() => resolve()));
    await harness.close();
  });
  afterEach(async () => {
    await wait(150); // noch laufende Zustellungen des Tests abwarten
  });
  beforeEach(async () => {
    await resetSync(world);
    await world.db.execute(sql`truncate table push_endpoints`);
    await world.db.execute(sql`truncate table weather_alert_state`);
    world.app.push?.reset();
    if (world.app.push) world.app.push.minIntervalMs = 0;
    world.clock = NOW;
    calls = [];
    topics.clear();
  });

  const register = async (d: Device, name: string) => {
    const topic = 'up' + randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
    const r = await d.client.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://ntfy.familyhub.lx-labs.dev/${topic}?up=1` } });
    expect(r.status).toBe(200);
    topics.set(name, topic);
  };
  const want = (d: Device, kinds: unknown) => d.client.request('PUT', '/api/v1/me/weather-alerts', { body: { kinds } });
  const posted = async () => {
    await wait(200);
    return calls.map((c) => c.url.replace(/^\//, ''));
  };
  /** Ein Lauf bei Zeit `NOW` mit der gegebenen Temperatur. */
  const lauf = (t: number | null, extra: Partial<Cur> = {}, h: WeatherView['hourly'] = hourly()) => alerts.run(view(cur({ temperature: t, ...extra }), h));

  it('Übergang inaktiv -> aktiv weckt nur Geräte mit eingeschalteter Art; der Wecker hat keinen Inhalt', async () => {
    await register(fam.parent, 'parent');
    await register(fam.child, 'child');
    await register(fam.admin, 'admin');
    expect((await want(fam.parent, ['frost', 'wind'])).status).toBe(200);
    expect((await want(fam.child, ['hitze'])).status).toBe(200);
    // admin meldet nichts
    expect((await lauf(5)).uebergaenge).toEqual([]); // erster Lauf: Zustand merken, kein Wecker
    expect(await posted()).toEqual([]);
    const r = await lauf(1);
    expect(r).toMatchObject({ uebergaenge: ['frost'], geweckt: 1 });
    expect(await posted()).toEqual([topics.get('parent')]);
    const c = calls[0]!;
    expect(c.body).toBe(WAKE_BODY);
    expect(c.headers.title).toBeUndefined();
    expect(c.headers.tags).toBeUndefined();
    expect(JSON.stringify(c)).not.toMatch(/frost|1\.0|temperatur/i);
  });

  it('kein Wecker, solange die Bedingung gilt; Hysterese: 2,1 bleibt aktiv, nach >= 3 und erneutem Fall weckt es wieder (nach 6 h)', async () => {
    await register(fam.parent, 'parent');
    await want(fam.parent, ['frost']);
    await lauf(5);
    await lauf(1);
    expect((await posted()).length).toBe(1);
    expect((await lauf(0.5)).uebergaenge).toEqual([]);
    expect((await lauf(2.1)).uebergaenge).toEqual([]); // flattert nicht
    expect((await lauf(1.9)).uebergaenge).toEqual([]);
    expect((await posted()).length).toBe(1);
    await lauf(3.5); // Ende
    // erneuter Frost innerhalb von 6 h: Zustand wechselt, aber der Wecker an das Gerät ist entprellt
    world.advance(2 * 3_600_000);
    expect((await lauf(1, { measuredAt: new Date(world.clock - 60_000).toISOString() })).uebergaenge).toEqual(['frost']);
    expect((await posted()).length).toBe(1);
    // nach mehr als 6 h seit dem letzten Wecker weckt der nächste Übergang wieder
    await lauf(4, { measuredAt: new Date(world.clock - 60_000).toISOString() });
    world.advance(5 * 3_600_000);
    expect((await lauf(1, { measuredAt: new Date(world.clock - 60_000).toISOString() })).geweckt).toBe(1);
    expect((await posted()).length).toBe(2);
  });

  it('Entprellung gilt je Art und Gerät: eine andere Art weckt sofort, ein anderes Gerät hat eigene Frist', async () => {
    await register(fam.parent, 'parent');
    await register(fam.child, 'child');
    await want(fam.parent, ['frost', 'hitze']);
    await lauf(15);
    await lauf(0); // Frost: parent
    await lauf(15);
    expect((await posted()).length).toBe(1);
    await want(fam.child, ['frost']); // Kind schaltet danach ein: hat noch keinen Wecker bekommen
    await lauf(0);
    expect(await posted()).toEqual([topics.get('parent'), topics.get('child')]);
    await lauf(15);
    await lauf(31); // Hitze: parent, andere Art, keine Sperre
    expect(await posted()).toEqual([topics.get('parent'), topics.get('child'), topics.get('parent')]);
  });

  it('Neustart ohne Spam: der Zustand liegt in der Datenbank, eine neue Instanz weckt nicht noch einmal', async () => {
    await register(fam.parent, 'parent');
    await want(fam.parent, ['frost']);
    await lauf(5);
    await lauf(1);
    expect((await posted()).length).toBe(1);
    const log = { warn: () => undefined, error: () => undefined, info: () => undefined };
    const neu = new WeatherAlerts({ db: world.db, push: world.app.push!, log, now: world.now });
    expect((await neu.run(view(cur({ temperature: 0.5 })))).uebergaenge).toEqual([]);
    expect((await posted()).length).toBe(1);
    const st = await rows(sql`select kind, active from weather_alert_state order by kind`);
    expect(st.find((s) => s.kind === 'frost')?.active).toBe(true);
  });

  it('veraltete Messung (älter als 40 Minuten) oder keine Messung: nichts geprüft, Zustand unverändert', async () => {
    await register(fam.parent, 'parent');
    await want(fam.parent, ['frost']);
    await lauf(5);
    const alt = await lauf(0, { measuredAt: new Date(NOW - 41 * 60_000).toISOString() });
    expect(alt).toMatchObject({ veraltet: true, geweckt: 0 });
    expect((await alerts.run(view(null))).veraltet).toBe(true);
    expect(await posted()).toEqual([]);
    expect((await rows(sql`select active from weather_alert_state where kind = 'frost'`))[0]?.active).toBe(false);
    // genau 40 Minuten gelten noch
    expect((await lauf(0, { measuredAt: new Date(NOW - 40 * 60_000).toISOString() })).uebergaenge).toEqual(['frost']);
  });

  it('deaktivierte oder entfernte Endpunkte und abgemeldete Geräte bekommen nichts', async () => {
    await register(fam.parent, 'parent');
    await register(fam.child, 'child');
    await want(fam.parent, ['frost']);
    await want(fam.child, ['frost']);
    await world.db.execute(sql`update push_endpoints set disabled_at = now() where topic = ${topics.get('child')!}`);
    await lauf(5);
    await lauf(0);
    expect(await posted()).toEqual([topics.get('parent')]);
  });

  it('ohne Push (NTFY) bleibt der Zustand gepflegt, es geht aber nichts hinaus', async () => {
    await register(fam.parent, 'parent');
    await want(fam.parent, ['frost']);
    const push = world.app.push!;
    const aus = Object.create(push, { enabled: { value: false } }) as typeof push;
    const log = { warn: () => undefined, error: () => undefined, info: () => undefined };
    const a2 = new WeatherAlerts({ db: world.db, push: aus, log, now: world.now });
    await a2.run(view(cur({ temperature: 5 })));
    const r = await a2.run(view(cur({ temperature: 0 })));
    expect(r).toMatchObject({ uebergaenge: ['frost'], geweckt: 0 });
    expect(await posted()).toEqual([]);
  });

  describe('Route PUT /me/weather-alerts', () => {
    it('speichert Maske am Gerät der Sitzung, nur dort; [] schaltet aus; Duplikate zählen einmal', async () => {
      await register(fam.parent, 'parent');
      await register(fam.child, 'child');
      expect((await want(fam.parent, ['frost', 'frost', 'druck'])).status).toBe(200);
      const m = async (t: string) => (await rows(sql`select weather_kinds from push_endpoints where topic = ${t}`))[0]?.weather_kinds;
      expect(await m(topics.get('parent')!)).toBe(kindsToMask(['frost', 'druck']));
      expect(await m(topics.get('child')!)).toBe(0);
      expect((await want(fam.parent, [])).status).toBe(200);
      expect(await m(topics.get('parent')!)).toBe(0);
    });
    it('ungültige Eingaben: 400, nichts gespeichert (unbekannte Art, Text, zusätzliche Felder, Maske, zu viele)', async () => {
      await register(fam.parent, 'parent');
      for (const bad of ['frost', ['schnee'], [1], ['frost', 'regen', 'wind', 'hitze', 'druck', 'frost'], null]) expect((await want(fam.parent, bad)).status).toBe(400);
      expect((await fam.parent.client.request('PUT', '/api/v1/me/weather-alerts', { body: { kinds: ['frost'], extra: 1 } })).status).toBe(400);
      expect((await fam.parent.client.request('PUT', '/api/v1/me/weather-alerts', { body: { mask: 31 } })).status).toBe(400);
      expect((await rows(sql`select weather_kinds from push_endpoints`))[0]?.weather_kinds).toBe(0);
    });
    it('ohne Anmeldung 401; ohne Push-Endpunkt 409', async () => {
      expect((await world.client().request('PUT', '/api/v1/me/weather-alerts', { body: { kinds: ['frost'] } })).status).toBe(401);
      expect((await want(fam.parent, ['frost'])).status).toBe(409);
    });
    it('Rate-Limit: strenge Grenze je IP wie bei /me/push', async () => {
      const w = await World.create(harness.db, { NTFY_URL: 'http://127.0.0.1:9', NTFY_TOKEN: 'tk_testtoken1234567890', AUTH_RATE_LIMIT_MAX: '3', WEATHER_ENABLED: 'true', WEATHER_STATION_MAC: '70:ee:50:01:79:f2', WEATHER_BBOX: '50.54,7.94,50.58,8.00' });
      try {
        const res: number[] = [];
        for (let i = 0; i < 5; i++) res.push((await w.client().request('PUT', '/api/v1/me/weather-alerts', { body: { kinds: [] } })).status);
        expect(res.slice(0, 3)).toEqual([401, 401, 401]);
        expect(res.slice(3)).toEqual([429, 429]);
      } finally {
        await w.close();
      }
    });
    it('Endpunkt löschen und Deaktivierung erlöschen den Wunsch', async () => {
      await register(fam.parent, 'parent');
      await want(fam.parent, ['frost']);
      await fam.parent.client.del('/api/v1/me/push');
      expect(await rows(sql`select 1 from push_endpoints`)).toHaveLength(0);
      await register(fam.parent, 'parent');
      expect((await rows(sql`select weather_kinds from push_endpoints`))[0]?.weather_kinds).toBe(0);
    });
  });

  it('Migration 0033 ist idempotent (zweimal ausführbar, Daten bleiben)', async () => {
    await register(fam.parent, 'parent');
    await want(fam.parent, ['wind']);
    const sqlText = readFileSync(new URL('../drizzle/0033_weather_alerts.sql', import.meta.url), 'utf8');
    for (const teil of sqlText.split('--> statement-breakpoint')) await world.db.execute(sql.raw(teil));
    for (const teil of sqlText.split('--> statement-breakpoint')) await world.db.execute(sql.raw(teil));
    expect((await rows(sql`select weather_kinds from push_endpoints`))[0]?.weather_kinds).toBe(kindsToMask(['wind']));
  });
});

