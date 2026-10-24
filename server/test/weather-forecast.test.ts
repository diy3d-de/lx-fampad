// Wetter-Vorhersage und DWD-Warnungen: strenge Auswertung fester Beispielantworten (Bright Sky, erfundene Werte), Abruf (fester Host, gerundete
// Koordinaten, kein Redirect), Fehlerfälle, Veralten, Route (ETag, nie Koordinaten), Schalter aus, /weather unverändert. Es gibt nie einen echten Abruf.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';
import { ForecastService } from '../src/weather/forecast.js';
import { bereinige, brightSky } from '../src/weather/forecast-source.js';
import { adminPassword, backends, TEST_KEY, World, type Harness } from './helpers.js';

const MAC = '70:ee:50:01:79:f2';
const ENV = { WEATHER_ENABLED: 'true', WEATHER_STATION_MAC: MAC, WEATHER_BBOX: '50.54,7.94,50.58,8.00', WEATHER_PLACE: 'Westerburg', WEATHER_FORECAST_ENABLED: 'true' };
const NOW = Date.parse('2026-10-19T08:00:00Z');
const H = 3_600_000;

interface Opt {
  temp?: (i: number) => unknown;
  icon?: (i: number) => unknown;
  pop?: (i: number) => unknown;
  rain?: (i: number) => unknown;
}
/** Stündliche Antwort wie Bright Sky: 8 Tage ab sechs Stunden vor jetzt. */
function stunden(o: Opt = {}, count = 8 * 24) {
  return {
    weather: Array.from({ length: count }, (_, i) => {
      const ms = NOW - 6 * H + i * H;
      return {
        timestamp: new Date(ms).toISOString().replace('Z', '+00:00'),
        source_id: 4711,
        temperature: o.temp ? o.temp(i) : 10 + (i % 24) / 4,
        precipitation: o.rain ? o.rain(i) : 0.1,
        precipitation_probability: o.pop ? o.pop(i) : i % 24 === 0 ? 40 : 10,
        wind_speed: 12 + (i % 5),
        wind_gust_speed: 30 + (i % 7),
        wind_direction: 250,
        icon: o.icon ? o.icon(i) : 'cloudy',
        condition: 'dry',
      };
    }),
    sources: [{ id: 4711, lat: 50.5, lon: 7.9, station_name: 'Geheimstation' }],
  };
}

function warnung(over: Record<string, unknown> = {}) {
  return {
    id: 1,
    alert_id: 'a-1',
    status: 'actual',
    category: 'met',
    severity: 'moderate',
    event_code: 63,
    event_en: 'persistent rain',
    event_de: 'DAUERREGEN',
    headline_de: 'Amtliche WARNUNG vor DAUERREGEN',
    description_de: 'Es tritt Dauerregen auf. Dabei werden Niederschlagsmengen um 40 l/m² erwartet.',
    effective: new Date(NOW - H).toISOString(),
    onset: new Date(NOW + 2 * H).toISOString(),
    expires: new Date(NOW + 20 * H).toISOString(),
    ...over,
  };
}
const alerts = (...a: unknown[]) => ({ alerts: a, location: { warn_cell_id: 807143308, name: 'Stadt Westerburg' } });

describe('Auswertung der Vorhersage', () => {
  it('bildet Tage (Min/Max, Regen, Wahrscheinlichkeit, Wind) und Stunden mit festen Symbolen', () => {
    const d = brightSky.parseForecast(stunden(), NOW);
    expect(d).not.toBeNull();
    expect(d!.days.length).toBeGreaterThanOrEqual(6);
    expect(d!.days.length).toBeLessThanOrEqual(7);
    const t = d!.days[1]!;
    expect(t).toMatchObject({ min: 10, max: 15.8, pop: 40, symbol: 'wolken' });
    expect(t.rain).toBeCloseTo(2.4, 1);
    expect(t.windKmh).toBe(16);
    expect(t.gustKmh).toBe(36);
    expect(d!.hours[0]!.t >= new Date(NOW - 2 * H).toISOString()).toBe(true);
    expect(d!.hours.length).toBeLessThanOrEqual(60);
    expect(d!.hours[0]).toMatchObject({ symbol: 'wolken', windKmh: expect.any(Number) });
  });

  it('verwirft unplausible Werte und Records ohne Temperatur, unbekannte Symbole werden "unbekannt"', () => {
    const d = brightSky.parseForecast(stunden({ temp: (i) => (i === 10 ? 999 : i === 11 ? 'x' : 8), icon: (i) => (i < 40 ? 'ufo' : 'rain'), rain: () => -5, pop: () => 250 }), NOW)!;
    expect(d.hours.some((h) => h.temp === 999)).toBe(false);
    expect(d.hours.every((h) => h.rain === 0 && h.pop === null)).toBe(true);
    expect(d.hours[0]!.symbol).toBe('unbekannt');
    expect(d.days.at(-1)!.symbol).toBe('regen');
  });

  it('das Schlimmste des Tages bestimmt das Tagessymbol (Gewitter schon in einer Stunde)', () => {
    const d = brightSky.parseForecast(stunden({ icon: (i) => (i === 30 ? 'thunderstorm' : 'clear-day') }), NOW)!;
    expect(d.days.map((x) => x.symbol)).toContain('gewitter');
    expect(d.days.filter((x) => x.symbol === 'sonne').length).toBeGreaterThan(3);
  });

  it('kaputte Formen ergeben null', () => {
    for (const x of [null, 5, 'x', [], {}, { weather: [] }, { weather: 'a' }, { weather: [null, 1, { timestamp: 'gestern', temperature: 5 }] }]) {
      expect(brightSky.parseForecast(x, NOW)).toBeNull();
    }
    expect(brightSky.parseAlerts({ alerts: 'x' }, NOW)).toBeNull();
    expect(brightSky.parseAlerts(null, NOW)).toBeNull();
  });
});

describe('Auswertung der Warnungen', () => {
  it('bildet Stufe, Art, Titel, Text und Zeiten; sortiert nach Stufe', () => {
    const w = brightSky.parseAlerts(
      alerts(warnung(), warnung({ severity: 'severe', event_en: 'thunderstorm', event_de: 'GEWITTER', onset: new Date(NOW + H).toISOString() }), warnung({ severity: 'minor', event_en: 'wind gusts', event_de: 'WINDBÖEN' })),
      NOW,
    )!;
    expect(w.map((x) => [x.level, x.kind, x.title])).toEqual([
      [3, 'gewitter', 'Gewitter'],
      [2, 'regen', 'Dauerregen'],
      [1, 'wind', 'Windböen'],
    ]);
    expect(w[1]!.text).toContain('40 l/m²');
    expect(w[1]!.until).toBe(new Date(NOW + 20 * H).toISOString());
  });

  it('lässt Tests, Übungen, abgelaufene und unbekannte Stufen weg', () => {
    const w = brightSky.parseAlerts(
      alerts(warnung({ status: 'test' }), warnung({ status: 'exercise' }), warnung({ expires: new Date(NOW - H).toISOString() }), warnung({ severity: 'unknown' }), warnung({ severity: undefined }), warnung({ onset: 'bald', effective: 'nie' })),
      NOW,
    )!;
    expect(w).toEqual([]);
  });

  it('Texte: Steuerzeichen, spitze Klammern und Längen', () => {
    const bidi = String.fromCharCode(0x202e);
    const roh = `<b>Achtung</b>${bidi}\u0007\n\nSturm${String.fromCharCode(0x200b)}  kommt ${'x '.repeat(400)}`;
    const t = bereinige(roh, 280);
    expect(t).not.toMatch(/[<>]/);
    expect(t).not.toContain(bidi);
    expect(t.includes('\n')).toBe(false);
    expect([...t].length).toBeLessThanOrEqual(280);
    expect(t.endsWith('…')).toBe(true);
    expect(bereinige(42, 10)).toBe('');
    const w = brightSky.parseAlerts(alerts(warnung({ event_de: '<script>alert(1)</script>' })), NOW)!;
    expect(w[0]!.title).not.toMatch(/[<>]/);
  });

  it('höchstens zehn Warnungen', () => {
    const viele = Array.from({ length: 30 }, (_, i) => warnung({ alert_id: `a${i}` }));
    expect(brightSky.parseAlerts(alerts(...viele), NOW)).toHaveLength(10);
  });
});

describe('Konfiguration', () => {
  const base = { NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY };
  it('Vorhersage ist ohne Schalter aus, braucht das Wetter und rundet die Ortsangabe auf zwei Stellen', () => {
    expect(loadConfig({ ...base, ...ENV, WEATHER_FORECAST_ENABLED: '' }).weather.forecast.enabled).toBe(false);
    expect(loadConfig(base).weather.forecast.enabled).toBe(false);
    expect(() => loadConfig({ ...base, WEATHER_FORECAST_ENABLED: 'true' })).toThrow(/WEATHER_ENABLED/);
    expect(() => loadConfig({ ...base, ...ENV, WEATHER_FORECAST_ENABLED: 'ja' })).toThrow(/WEATHER_FORECAST_ENABLED/);
    const c = loadConfig({ ...base, ...ENV, WEATHER_BBOX: '50.5412,7.9433,50.5799,7.9988' });
    expect(c.weather.forecast).toEqual({ enabled: true, lat: 50.56, lon: 7.97 });
  });
});

interface Call {
  url: string;
  redirect: string | undefined;
}
function fakeQuelle() {
  const calls: Call[] = [];
  const state = {
    forecast: stunden() as unknown,
    alerts: alerts(warnung()) as unknown,
    mode: 'ok' as 'ok' | 'timeout' | 'redirect' | 'big' | 'json' | 'http500',
  };
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, redirect: init?.redirect });
    if (state.mode === 'timeout') throw new DOMException('timeout', 'TimeoutError');
    if (state.mode === 'redirect') throw new TypeError('unexpected redirect');
    if (state.mode === 'http500') return new Response('{}', { status: 500 });
    if (state.mode === 'json') return new Response('<html>nein</html>', { status: 200 });
    if (state.mode === 'big') return new Response('{}', { status: 200, headers: { 'content-length': '99999999' } });
    return new Response(JSON.stringify(url.includes('/alerts') ? state.alerts : state.forecast), { status: 200 });
  }) as typeof fetch;
  return { fn, calls, state };
}

describe.each(backends)('Vorhersage: Dienst und Route ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let quelle: ReturnType<typeof fakeQuelle>;
  let svc: ForecastService;

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv = ENV) {
    await world?.close();
    await harness.reset();
    quelle = fakeQuelle();
    world = await World.create(harness.db, env);
    svc = new ForecastService({ db: harness.db, config: world.config, log: world.app.log, now: world.now, fetch: quelle.fn });
  }
  beforeEach(async () => {
    await neu();
  });

  it('Route: ohne Anmeldung 401; Wetter oder Vorhersage aus = {available:false}; ohne Stand leere Teile', async () => {
    expect((await world.client().get('/api/v1/weather/forecast')).status).toBe(401);
    const a = await adminPassword(world);
    const leer = await a.client.get('/api/v1/weather/forecast');
    expect(leer.json).toEqual({ available: true, source: 'Deutscher Wetterdienst', forecast: null, warnings: null });
    await neu({ ...ENV, WEATHER_FORECAST_ENABLED: 'false' });
    const b = await adminPassword(world);
    expect((await b.client.get('/api/v1/weather/forecast')).json).toEqual({ available: false });
    expect(await svc.pollForecast()).toBe('disabled');
    expect(await svc.pollAlerts()).toBe('disabled');
    expect(quelle.calls).toHaveLength(0);
    await neu({});
    const c = await adminPassword(world);
    expect((await c.client.get('/api/v1/weather/forecast')).json).toEqual({ available: false });
  });

  it('Abruf: fester Host, https, gerundete Koordinaten, kein Redirect; Antwort ohne Koordinaten und Quelle', async () => {
    const a = await adminPassword(world);
    expect(await svc.pollForecast()).toBe('ok');
    expect(await svc.pollAlerts()).toBe('ok');
    const [f, w] = quelle.calls;
    for (const c of quelle.calls) {
      expect(c.url.startsWith('https://api.brightsky.dev/')).toBe(true);
      expect(c.redirect).toBe('error');
    }
    const q = new URL(f!.url).searchParams;
    expect(new URL(f!.url).pathname).toBe('/weather');
    expect(q.get('lat')).toBe('50.56');
    expect(q.get('lon')).toBe('7.97');
    expect(q.get('date')).toBe('2026-10-19');
    expect(q.get('tz')).toBe('Europe/Berlin');
    expect(new URL(w!.url).pathname).toBe('/alerts');
    expect(new URL(w!.url).searchParams.get('lat')).toBe('50.56');
    const res = await a.client.get('/api/v1/weather/forecast');
    expect(res.status).toBe(200);
    const j = res.json as { available: boolean; forecast: { stale: boolean; days: unknown[]; hours: unknown[] }; warnings: { stale: boolean; items: { level: number }[] } };
    expect(j.available).toBe(true);
    expect(j.forecast.stale).toBe(false);
    expect(j.forecast.days.length).toBeGreaterThanOrEqual(6);
    expect(j.forecast.hours.length).toBeGreaterThan(24);
    expect(j.warnings.items).toHaveLength(1);
    expect(j.warnings.items[0]!.level).toBe(2);
    const text = JSON.stringify(res.json);
    for (const verboten of ['50.5', '7.9', 'Geheimstation', 'warn_cell', '807143308', 'brightsky', 'lat', 'lon', 'source_id']) expect(text, verboten).not.toContain(verboten);
  });

  it('ETag: gleiche Antwort ergibt 304, nach neuem Stand nicht', async () => {
    const a = await adminPassword(world);
    await svc.pollForecast();
    const r1 = await a.client.get('/api/v1/weather/forecast');
    const etag = String(r1.headers.etag);
    expect(etag).toMatch(/^"wf-/);
    const r2 = await a.client.get('/api/v1/weather/forecast', { headers: { 'if-none-match': etag } });
    expect(r2.status).toBe(304);
    await svc.pollAlerts();
    const r3 = await a.client.get('/api/v1/weather/forecast', { headers: { 'if-none-match': etag } });
    expect(r3.status).toBe(200);
  });

  it('Veralten: Vorhersage nach 12 Stunden als veraltet, nach 48 Stunden gar nicht mehr; Warnungen nach einer Stunde veraltet', async () => {
    const a = await adminPassword(world);
    await svc.pollForecast();
    await svc.pollAlerts();
    world.advance(61 * 60_000);
    let j = (await a.client.get('/api/v1/weather/forecast')).json as { forecast: { stale: boolean }; warnings: { stale: boolean } };
    expect(j.forecast.stale).toBe(false);
    expect(j.warnings.stale).toBe(true);
    world.advance(12 * H);
    j = (await a.client.get('/api/v1/weather/forecast')).json as typeof j;
    expect(j.forecast.stale).toBe(true);
    world.advance(40 * H);
    const k = (await a.client.get('/api/v1/weather/forecast')).json as { forecast: unknown; warnings: unknown };
    expect(k.forecast).toBeNull();
    expect(k.warnings).toBeNull();
  });

  it('abgelaufene Warnungen und vergangene Stunden/Tage fallen beim Lesen weg', async () => {
    const a = await adminPassword(world);
    await svc.pollForecast();
    await svc.pollAlerts();
    world.advance(21 * H);
    const j = (await a.client.get('/api/v1/weather/forecast')).json as { forecast: { days: { date: string }[]; hours: { t: string }[] }; warnings: { items: unknown[] } };
    expect(j.warnings.items).toHaveLength(0);
    expect(j.forecast.days[0]!.date >= '2026-10-20').toBe(true);
    expect(Date.parse(j.forecast.hours[0]!.t)).toBeGreaterThanOrEqual(Math.floor(world.clock / H) * H);
    expect(j.forecast.hours.length).toBeLessThanOrEqual(48);
  });

  it.each([
    ['timeout', 'network'],
    ['redirect', 'network'],
    ['big', 'too_large'],
    ['json', 'bad_json'],
    ['http500', 'http_500'],
  ] as const)('Fehlerfall %s: kein Stand, fester Fehlercode, nichts Falsches geliefert', async (mode, code) => {
    const a = await adminPassword(world);
    quelle.state.mode = mode;
    expect(await svc.pollForecast()).toBe('error');
    expect(await svc.pollAlerts()).toBe('error');
    const j = (await a.client.get('/api/v1/weather/forecast')).json;
    expect(j).toEqual({ available: true, source: 'Deutscher Wetterdienst', forecast: null, warnings: null });
    expect(await world.count('weather_forecast')).toBe(2);
    const { weatherForecast } = await import('../src/db/schema.js');
    const zeilen = await harness.db.select().from(weatherForecast);
    expect(zeilen.map((z) => z.lastErrorCode)).toEqual([code, code]);
  });

  it('kaputte Daten: alter guter Stand bleibt, Fehler wird gezählt; danach wieder ok', async () => {
    const a = await adminPassword(world);
    await svc.pollForecast();
    quelle.state.forecast = { weather: [{ timestamp: 'x', temperature: 1 }] };
    expect(await svc.pollForecast()).toBe('error');
    expect(await svc.pollForecast()).toBe('error');
    const { weatherForecast } = await import('../src/db/schema.js');
    const [z] = await harness.db.select().from(weatherForecast);
    expect(z).toMatchObject({ lastErrorCode: 'bad_data', errorCount: 2 });
    expect(((await a.client.get('/api/v1/weather/forecast')).json as { forecast: { days: unknown[] } }).forecast.days.length).toBeGreaterThan(0);
    quelle.state.forecast = stunden();
    expect(await svc.pollForecast()).toBe('ok');
    const [z2] = await harness.db.select().from(weatherForecast);
    expect(z2).toMatchObject({ lastErrorCode: null, errorCount: 0 });
  });

  it('/weather bleibt unverändert (keine neuen Felder) und kein Abruf der API', async () => {
    const a = await adminPassword(world);
    const res = await a.client.get('/api/v1/weather');
    expect(Object.keys(res.json as object).sort()).toEqual(['available', 'current', 'days', 'hourly', 'max24h', 'min24h', 'place', 'series', 'sun']);
    expect(quelle.calls).toHaveLength(0);
  });

  it('Start verschiebt den Abruf, wenn der Stand frisch ist', async () => {
    await svc.pollForecast();
    const kurz = new ForecastService({ db: harness.db, config: world.config, log: world.app.log, now: world.now, fetch: quelle.fn, intervals: { forecastMs: 10_000_000, alertsMs: 10_000_000 } });
    const vorher = quelle.calls.length;
    await kurz.start();
    await new Promise((r) => setTimeout(r, 50));
    expect(quelle.calls.length).toBe(vorher);
    kurz.close();
  });
});
