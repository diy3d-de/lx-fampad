// Wetter (Netatmo): Messwerte aus getpublicdata, Token-Rotation, invalid_grant, Route (nur angemeldet, nur Ortsname und Messwerte),
// Konfiguration (fail-closed). Netatmo wird durch einen Fake-fetch ersetzt, es gibt nie einen echten Abruf.
import { readFileSync } from 'node:fs';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { loadConfig } from '../src/config.js';
import * as schema from '../src/db/schema.js';
import { stationMessung } from '../src/weather/parse.js';
import { startWeatherPoller } from '../src/weather/poller.js';
import type { WeatherService } from '../src/weather/service.js';
import { adminPassword, backends, TEST_KEY, World, type Harness } from './helpers.js';

const MAC = '70:ee:50:01:79:f2';
const ENV = { WEATHER_ENABLED: 'true', WEATHER_STATION_MAC: MAC, WEATHER_BBOX: '50.54,7.94,50.58,8.00', WEATHER_PLACE: 'Westerburg' };
const T0 = Date.parse('2026-10-19T08:00:00Z') / 1000;

/** Antwort wie getpublicdata: unsere Station neben einer fremden. */
function publicData(ts = T0 - 120, temp = 12.5) {
  return {
    status: 'ok',
    body: [
      { _id: '70:ee:50:99:99:99', place: { location: [8, 50.5], street: 'Fremdweg 1' }, measures: { a: { res: { [ts]: [30, 10] }, type: ['temperature', 'humidity'] } } },
      {
        _id: MAC,
        place: { location: [7.97, 50.56], altitude: 300, street: 'Geheimstraße 7' },
        measures: {
          m1: { res: { [ts - 600]: [temp - 1, 70], [ts]: [temp, 71] }, type: ['temperature', 'humidity'] },
          m2: { res: { [ts]: [1013.2] }, type: ['pressure'] },
          m3: { rain_60min: 0.5, rain_24h: 2.1, rain_live: 0, rain_timeutc: ts },
          m4: { wind_strength: 12, wind_angle: 270, gust_strength: 25, gust_angle: 250, wind_timeutc: ts },
        },
      },
    ],
  };
}

interface Call {
  url: string;
  method: string;
  auth: string | null;
  body: string;
}
/** Fake-Netatmo: zählt Aufrufe, rotiert das Refresh-Token bei jeder Erneuerung. */
function fakeNetatmo() {
  const calls: Call[] = [];
  const state = { refreshOk: true, grantError: false, data: publicData() as unknown, dataStatus: 200, tokenN: 0, expiresIn: 10800, expectRefresh: 'refresh-0-secret-token' };
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, method: init?.method ?? 'GET', auth: new Headers(init?.headers).get('authorization'), body: String(init?.body ?? '') });
    if (url.endsWith('/oauth2/token')) {
      const form = new URLSearchParams(String(init?.body));
      if (state.grantError || form.get('refresh_token') !== state.expectRefresh) return new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
      if (!state.refreshOk) return new Response('{}', { status: 500 });
      state.tokenN++;
      state.expectRefresh = `refresh-${state.tokenN}-secret-token`;
      return new Response(JSON.stringify({ access_token: `access-${state.tokenN}-abcdefgh`, refresh_token: state.expectRefresh, expires_in: state.expiresIn }), { status: 200 });
    }
    if (state.dataStatus !== 200) return new Response('{}', { status: state.dataStatus });
    return new Response(JSON.stringify(state.data), { status: 200 });
  }) as typeof fetch;
  return { fn, calls, state };
}

describe('Messwerte aus getpublicdata', () => {
  it('liest Temperatur, Feuchte, Druck, Regen und Wind nur der Station mit der MAC', () => {
    const m = stationMessung(publicData().body, MAC, T0);
    expect(m).toEqual({ ts: T0 - 120, temperature: 12.5, humidity: 71, pressure: 1013.2, rain1h: 0.5, rain24h: 2.1, windKmh: 12, gustKmh: 25, windAngle: 270 });
    expect(stationMessung(publicData().body, MAC.toUpperCase(), T0)?.temperature).toBe(12.5);
  });
  it('liefert null bei fehlender Station, falscher Form und ohne Messung', () => {
    expect(stationMessung(publicData().body, '70:ee:50:00:00:00', T0)).toBeNull();
    expect(stationMessung(null, MAC, T0)).toBeNull();
    expect(stationMessung({ body: [] }, MAC, T0)).toBeNull();
    expect(stationMessung([{ _id: MAC, measures: {} }], MAC, T0)).toBeNull();
    expect(stationMessung([{ _id: MAC }], MAC, T0)).toBeNull();
  });
  it('verwirft unplausible Werte', () => {
    const m = stationMessung([{ _id: MAC, measures: { a: { res: { [T0]: [99, 150] }, type: ['temperature', 'humidity'] }, b: { res: { [T0]: [20] }, type: ['temperature'] } } }], MAC, T0);
    expect(m?.temperature).toBe(20);
    expect(m?.humidity).toBeNull();
    const nur = stationMessung([{ _id: MAC, measures: { a: { res: { [T0]: [Infinity, '5'] }, type: ['temperature', 'humidity'] } } }], MAC, T0);
    expect(nur).toBeNull();
  });
});

describe('Zeitstempel', () => {
  it('nimmt keine Zeiten aus der Zukunft oder ausserhalb des Bereichs an', () => {
    const mit = (ts: number | string) => stationMessung([{ _id: MAC, measures: { a: { res: { [ts]: [10, 50] }, type: ['temperature', 'humidity'] } } }], MAC, T0);
    expect(mit(T0)?.ts).toBe(T0);
    expect(mit(T0 + 300)?.ts).toBe(T0 + 300);
    expect(mit(T0 + 301)).toBeNull();
    expect(mit('1e20')).toBeNull();
    expect(mit(0)).toBeNull();
    expect(mit(-5)).toBeNull();
    const regen = stationMessung([{ _id: MAC, measures: { r: { rain_60min: 1, rain_24h: 2, rain_timeutc: 1e20 } } }], MAC, T0);
    expect(regen).toBeNull();
    const wind = stationMessung([{ _id: MAC, measures: { w: { wind_strength: 5, wind_timeutc: T0 + 10_000 } } }], MAC, T0);
    expect(wind).toBeNull();
  });
});

describe('Konfiguration', () => {
  const base = { NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY };
  it('ist ohne Schalter aus und verlangt sonst MAC und Rechteck', () => {
    expect(loadConfig(base).weather.enabled).toBe(false);
    expect(() => loadConfig({ ...base, WEATHER_ENABLED: 'true' })).toThrow(/WEATHER_STATION_MAC/);
    expect(() => loadConfig({ ...base, WEATHER_ENABLED: 'true', WEATHER_STATION_MAC: MAC })).toThrow(/WEATHER_BBOX/);
    expect(() => loadConfig({ ...base, ...ENV, WEATHER_BBOX: '50,7,60,9' })).toThrow(/WEATHER_BBOX/);
    expect(() => loadConfig({ ...base, ...ENV, WEATHER_BBOX: '50.6,7.9,50.5,8' })).toThrow(/WEATHER_BBOX/);
    expect(() => loadConfig({ ...base, ...ENV, WEATHER_STATION_MAC: 'xyz' })).toThrow(/WEATHER_STATION_MAC/);
    const c = loadConfig({ ...base, ...ENV });
    expect(c.weather).toMatchObject({ enabled: true, place: 'Westerburg', stationMac: MAC, pollMs: 600_000 });
  });
  it('WEATHER_ENABLED ist strikt: nur true/1/false/0', () => {
    expect(() => loadConfig({ ...base, ...ENV, WEATHER_ENABLED: 'yes' })).toThrow(/WEATHER_ENABLED/);
    expect(loadConfig({ ...base, ...ENV, WEATHER_ENABLED: '1' }).weather.enabled).toBe(true);
    expect(loadConfig({ ...base, WEATHER_ENABLED: 'false' }).weather.enabled).toBe(false);
  });
  it('lässt in Produktion kein zu schnelles Abfragen zu', () => {
    expect(() => loadConfig({ NODE_ENV: 'production', AUTH_SECRET_KEY: TEST_KEY, ...ENV, WEATHER_POLL_MS: '1000' })).toThrow(/WEATHER_POLL_MS/);
  });
});

describe.each(backends)('Wetter-Dienst und Route ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let net: ReturnType<typeof fakeNetatmo>;

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv = ENV) {
    await world?.close();
    await harness.reset();
    net = fakeNetatmo();
    world = await World.create(harness.db, env, { weatherFetch: net.fn });
  }
  beforeEach(async () => {
    await neu();
  });

  const zugang = () => world.app.weather!.speichereZugangsdaten({ clientId: 'client-id-xyz', clientSecret: 'client-secret-xyz', refreshToken: 'refresh-0-secret-token' });
  const svc = () => world.app.weather!;
  const jetzt = () => world.clock / 1000;

  it('Route: ohne Anmeldung 401; ausgeschaltet {available:false}', async () => {
    expect((await world.client().get('/api/v1/weather')).status).toBe(401);
    await neu({});
    const a = await adminPassword(world);
    const res = await a.client.get('/api/v1/weather');
    expect(res.status).toBe(200);
    expect(res.json).toEqual({ available: false });
    expect(await svc().pollOnce()).toBe('disabled');
    expect(net.calls).toHaveLength(0);
  });

  it('ohne Zugangsdaten kein Abruf; Route zeigt nur Ortsname ohne Messwerte', async () => {
    const a = await adminPassword(world);
    expect(await svc().pollOnce()).toBe('not_configured');
    expect(net.calls).toHaveLength(0);
    const res = await a.client.get('/api/v1/weather');
    expect(res.json).toMatchObject({ available: true, place: 'Westerburg', current: null, min24h: null, max24h: null, series: [] });
  });

  it('Abruf: Token holen, Rechteck und Filter senden, Messwerte speichern; Antwort ohne Straße, Koordinaten, MAC', async () => {
    const a = await adminPassword(world);
    await zugang();
    net.state.data = publicData(jetzt() - 120);
    expect(await svc().pollOnce()).toBe('ok');
    const [token, data] = net.calls;
    expect(token?.url).toBe('https://api.netatmo.com/oauth2/token');
    expect(new URLSearchParams(token?.body).get('client_id')).toBe('client-id-xyz');
    expect(data?.auth).toBe('Bearer access-1-abcdefgh');
    const q = new URL(data?.url ?? '').searchParams;
    expect(q.get('lat_sw')).toBe('50.54');
    expect(q.get('lon_ne')).toBe('8');
    expect(q.get('filter')).toBe('false');
    const res = await a.client.get('/api/v1/weather');
    expect(res.status).toBe(200);
    expect(res.json).toMatchObject({
      available: true,
      place: 'Westerburg',
      current: { temperature: 12.5, humidity: 71, pressure: 1013.2, rain1h: 0.5, rain24h: 2.1, windKmh: 12, gustKmh: 25, windAngle: 270, stale: false },
      min24h: 12.5,
      max24h: 12.5,
    });
    const text = JSON.stringify(res.json);
    for (const verboten of ['Geheimstra', 'Fremdweg', MAC, '7.97', '50.56', 'altitude', 'location', 'street', 'token', 'secret']) expect(text, verboten).not.toContain(verboten);
  });

  it('Zugangstoken wird wiederverwendet; gleiche Messung wird nicht doppelt gespeichert', async () => {
    await zugang();
    net.state.data = publicData(jetzt() - 60);
    await svc().pollOnce();
    await svc().pollOnce();
    expect(net.calls.filter((c) => c.url.endsWith('/oauth2/token'))).toHaveLength(1);
    expect(await world.count('weather_samples')).toBe(1);
    // nach Ablauf (fast drei Stunden) wird erneuert
    world.advance(3 * 3600_000);
    net.state.data = publicData(jetzt() - 60);
    await svc().pollOnce();
    expect(net.calls.filter((c) => c.url.endsWith('/oauth2/token'))).toHaveLength(2);
    expect(await world.count('weather_samples')).toBe(2);
  });

  it('Rotation: das neue Refresh-Token ersetzt das alte (verschlüsselt, nie im Klartext)', async () => {
    await zugang();
    const vorher = (await harness.db.select().from(schema.weatherCredentials))[0];
    await svc().pollOnce();
    const nachher = (await harness.db.select().from(schema.weatherCredentials))[0];
    expect(nachher?.refreshTokenEnc).not.toBe(vorher?.refreshTokenEnc);
    for (const wert of [nachher?.clientIdEnc, nachher?.clientSecretEnc, nachher?.refreshTokenEnc]) {
      expect(wert).toMatch(/^v1\./);
      expect(wert).not.toContain('secret');
      expect(wert).not.toContain('client-id');
    }
    // der zweite Abruf nach Ablauf benutzt wirklich das rotierte Token (der Fake lehnt sonst mit invalid_grant ab)
    world.advance(4 * 3600_000);
    net.state.data = publicData(jetzt() - 60);
    expect(await svc().pollOnce()).toBe('ok');
  });

  it('invalid_grant schaltet den Abruf ab, bis die Zugangsdaten neu eingegeben werden', async () => {
    await zugang();
    net.state.grantError = true;
    expect(await svc().pollOnce()).toBe('invalid_grant');
    expect((await svc().status()).disabled).toBe(true);
    const n = net.calls.length;
    expect(await svc().pollOnce()).toBe('disabled');
    expect(net.calls).toHaveLength(n);
    net.state.grantError = false;
    await zugang();
    net.state.data = publicData(jetzt() - 60);
    expect(await svc().pollOnce()).toBe('ok');
  });

  it('Fehler der Datenabfrage: 401 erneuert einmal; 500 und fehlende Station melden Fehler ohne Messwert', async () => {
    await zugang();
    net.state.dataStatus = 401;
    expect(await svc().pollOnce()).toBe('upstream_error');
    expect(net.calls.filter((c) => c.url.endsWith('/oauth2/token'))).toHaveLength(2);
    net.state.dataStatus = 500;
    expect(await svc().pollOnce()).toBe('upstream_error');
    net.state.dataStatus = 200;
    net.state.data = { body: [] };
    expect(await svc().pollOnce()).toBe('station_not_found');
    const [row] = await harness.db.select().from(schema.weatherCredentials);
    expect(row?.lastErrorCode).toBe('station_not_found');
    expect(row?.disabledAt).toBeNull();
    expect(await world.count('weather_samples')).toBe(0);
  });

  it('Tokenfehler (500) lässt das gespeicherte Token unverändert', async () => {
    await zugang();
    const vorher = (await harness.db.select().from(schema.weatherCredentials))[0]?.refreshTokenEnc;
    net.state.refreshOk = false;
    expect(await svc().pollOnce()).toBe('upstream_error');
    expect((await harness.db.select().from(schema.weatherCredentials))[0]?.refreshTokenEnc).toBe(vorher);
  });

  it('erweiterte Antwort: Stundenreihen, Tagesextreme, Sonne; alte Felder unverändert, nie Koordinaten', async () => {
    const a = await adminPassword(world);
    await zugang();
    const ins = (sek: number, v: Partial<typeof schema.weatherSamples.$inferInsert>) => harness.db.insert(schema.weatherSamples).values({ ts: new Date((jetzt() - sek) * 1000), ...v });
    await ins(3 * 3600, { temperature: 4, humidity: 80, pressure: 1010, rain1h: 0, windKmh: 10, gustKmh: 20, windAngle: 350 });
    await ins(4800, { temperature: 6, humidity: 82, pressure: 1011, rain1h: 0.4, windKmh: 14, gustKmh: 31, windAngle: 10 });
    await ins(3 * 86400, { temperature: 1 });
    const res = await a.client.get('/api/v1/weather');
    const j = res.json;
    expect(j.available).toBe(true);
    expect(Object.keys(j)).toEqual(expect.arrayContaining(['place', 'current', 'min24h', 'max24h', 'series']));
    expect(j.series.map((p: { temperature: number }) => p.temperature)).toEqual([4, 6]);
    const h = j.hourly;
    expect(h.stepSec).toBe(3600);
    for (const k of ['temperature', 'humidity', 'pressure', 'rain', 'windKmh', 'gustKmh', 'windAngle']) expect(h[k]).toHaveLength(168);
    expect(h.temperature.filter((v: number | null) => v !== null).length).toBeGreaterThanOrEqual(2);
    expect(h.temperature.filter((v: number | null) => v === 0)).toEqual([]);
    expect(j.days.length).toBeGreaterThanOrEqual(2);
    expect(j.sun).toHaveLength(2);
    expect(j.sun[0].sunrise).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/);
    // Datenschutz: keine Koordinaten, Straße, MAC, Rechteck
    const text = JSON.stringify(j);
    for (const verboten of [MAC, '50.56', '7.97', '50.54', '8.00', 'lat', 'lon', 'Geheimstra', 'bbox', 'location']) expect(text).not.toContain(verboten);
  });

  it('Verlauf, Min/Max über 24 Stunden, veralteter Stand, Aufräumen nach 7 Tagen', async () => {
    const a = await adminPassword(world);
    await zugang();
    // vier Messungen im Abstand von 10 Minuten, dazu eine uralte
    const alt = new Date((jetzt() - 8 * 86400) * 1000);
    await harness.db.insert(schema.weatherSamples).values({ ts: alt, temperature: -20 });
    for (const [i, t] of [5, 8, 3, 6].entries()) {
      await harness.db.insert(schema.weatherSamples).values({ ts: new Date((jetzt() - 600 - (3 - i) * 1800) * 1000), temperature: t });
    }
    const res = await a.client.get('/api/v1/weather');
    expect(res.json.min24h).toBe(3);
    expect(res.json.max24h).toBe(8);
    expect(res.json.series.map((p: { temperature: number }) => p.temperature)).toEqual([5, 8, 3, 6]);
    expect(res.json.current.stale).toBe(false);
    world.advance(2 * 3600_000);
    expect((await a.client.get('/api/v1/weather')).json.current.stale).toBe(true);
    // Abruf räumt Alte weg
    net.state.data = publicData(jetzt() - 60);
    await svc().pollOnce();
    const rest = await harness.db.select().from(schema.weatherSamples).where(eq(schema.weatherSamples.temperature, -20));
    expect(rest).toHaveLength(0);
  });

  it('Messung aus der Zukunft oder älter als 7 Tage wird nicht gespeichert', async () => {
    await zugang();
    net.state.data = publicData(jetzt() + 10_000);
    expect(await svc().pollOnce()).toBe('station_not_found');
    net.state.data = publicData(jetzt() - 8 * 86400);
    expect(await svc().pollOnce()).toBe('upstream_error');
    expect(await world.count('weather_samples')).toBe(0);
    expect((await harness.db.select().from(schema.weatherCredentials))[0]?.lastErrorCode).toBe('measurement_old');
  });

  it('Notanker: scheitert das Speichern in der Transaktion, wird das neue Refresh-Token ersatzweise gespeichert', async () => {
    await zugang();
    const keys = world.auth.ctx.keys;
    const orig = keys.encrypt.bind(keys);
    let n = 0;
    const spy = vi.spyOn(keys, 'encrypt').mockImplementation((...a) => {
      if (n++ === 0) throw new Error('boom');
      return orig(...a);
    });
    expect(await svc().pollOnce()).toBe('upstream_error');
    spy.mockRestore();
    const [row] = await harness.db.select().from(schema.weatherCredentials);
    expect(row?.lastErrorCode).toBe('rotate_persist');
    // das ersatzweise gespeicherte Token ist das rotierte: der nächste Abruf klappt (der Fake lehnt das alte ab)
    net.state.data = publicData(jetzt() - 60);
    expect(await svc().pollOnce()).toBe('ok');
  });

  it('zu große Antworten werden abgebrochen (Content-Length und Strom)', async () => {
    await zugang();
    const orig = net.fn;
    const gross = 'x'.repeat(2_100_000);
    const fn = (async (input: string | URL | Request, init?: RequestInit) => {
      if (String(input).includes('getpublicdata')) return new Response(gross, { status: 200 });
      return orig(input, init);
    }) as typeof fetch;
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db, ENV, { weatherFetch: fn });
    await zugang();
    expect(await svc().pollOnce()).toBe('upstream_error');
    expect((await harness.db.select().from(schema.weatherCredentials))[0]?.lastErrorCode).toBe('too_large');
    expect(await world.count('weather_samples')).toBe(0);
  });

  it('läuft nie doppelt im selben Prozess', async () => {
    await zugang();
    net.state.data = publicData(jetzt() - 60);
    const [a, b] = await Promise.all([svc().pollOnce(), svc().pollOnce()]);
    expect([a, b].sort()).toEqual(['busy', 'ok']);
  });

  it('Zugangsdaten löschen', async () => {
    await zugang();
    await svc().loescheZugangsdaten();
    expect(await svc().pollOnce()).toBe('not_configured');
  });
});

describe('Abruf-Takt nur im eigenen Dienst', () => {
  const base = { NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY };
  it('der API-Prozess startet keinen Takt (server.ts), der Poller-Einstieg schon', () => {
    const dir = new URL('../src/', import.meta.url);
    const api = readFileSync(new URL('server.ts', dir), 'utf8');
    expect(api).not.toMatch(/weather\??\.start\(/);
    expect(api).not.toMatch(/startWeatherPoller/);
    const poller = readFileSync(new URL('cli/weather-poller.ts', dir), 'utf8');
    expect(poller).toMatch(/startWeatherPoller\(/);
    expect(poller).not.toMatch(/listen\(|buildApp/);
  });
  it('buildApp ruft Netatmo nie von selbst ab', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'setInterval'] });
    const fn = vi.fn(async () => new Response('{}'));
    const h = await backends[0]!.open();
    const w = await World.create(h.db, ENV, { weatherFetch: fn as unknown as typeof fetch });
    try {
      await vi.advanceTimersByTimeAsync(30 * 60_000);
      expect(fn).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
      await w.close();
      await h.close();
    }
  });
  it('startWeatherPoller: aus ohne WEATHER_ENABLED, sonst genau ein Takt', () => {
    const log = { warn: vi.fn(), error: vi.fn() };
    const mach = (env: NodeJS.ProcessEnv) => ({ enabled: loadConfig({ ...base, ...env }).weather.enabled, start: vi.fn() });
    const aus = mach({});
    expect(startWeatherPoller(aus as unknown as WeatherService, log)).toBe(false);
    expect(aus.start).not.toHaveBeenCalled();
    expect(log.warn).toHaveBeenCalledTimes(1);
    const an = mach(ENV);
    expect(startWeatherPoller(an as unknown as WeatherService, log)).toBe(true);
    expect(an.start).toHaveBeenCalledTimes(1);
  });
});

describe('Shutdown während der Token-Rotation', () => {
  it('drain wartet auf den laufenden Abruf, das neue Refresh-Token wird noch gespeichert', async () => {
    const h = await backends[0]!.open();
    vi.useFakeTimers({ toFake: ['setTimeout'] });
    let freigeben!: () => void;
    const gate = new Promise<void>((r) => (freigeben = r));
    const net = fakeNetatmo();
    const fn = (async (input: string | URL | Request, init?: RequestInit) => {
      if (String(input).endsWith('/oauth2/token')) await gate;
      return net.fn(input, init);
    }) as typeof fetch;
    const w = await World.create(h.db, ENV, { weatherFetch: fn });
    try {
      const svc = w.app.weather!;
      await svc.speichereZugangsdaten({ clientId: 'client-id-xyz', clientSecret: 'client-secret-xyz', refreshToken: 'refresh-0-secret-token' });
      const vorher = (await h.db.select().from(schema.weatherCredentials))[0]?.refreshTokenEnc;
      net.state.data = publicData(w.clock / 1000 - 60);
      svc.start();
      await vi.advanceTimersByTimeAsync(5_000);
      svc.close();
      let fertig = false;
      const drain = svc.drain(10_000).then(() => (fertig = true));
      await Promise.resolve();
      expect(fertig).toBe(false);
      freigeben();
      await drain;
      const nachher = (await h.db.select().from(schema.weatherCredentials))[0]?.refreshTokenEnc;
      expect(nachher).not.toBe(vorher);
      expect(await w.count('weather_samples')).toBe(1);
    } finally {
      vi.useRealTimers();
      await w.close();
      await h.close();
    }
  });
});
