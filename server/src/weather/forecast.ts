// Vorhersage und amtliche Warnungen (DWD): Abruf NUR im Wetter-Dienst (cli/weather-poller.ts), die API liest nur aus der Datenbank.
// Zwei unabhängige Takte (Vorhersage alle 3 Stunden, Warnungen alle 10 Minuten) mit Backoff nach Fehlern, nie ein Abruf direkt nach einem
// Neustart, wenn der gespeicherte Stand noch frisch ist. Feste Hosts (Quelle in forecast-source.ts), nur https, kein Redirect, Größen- und
// Zeitlimit; Fehler nur als feste Codes. Die Ortsangabe ist die gerundete Mitte des Wetter-Rechtecks und verlässt den Server nur so.
import { eq, sql } from 'drizzle-orm';
import type { Db, Logger } from '../auth/context.js';
import type { Config } from '../config.js';
import { weatherForecast } from '../db/schema.js';
import { leseBegrenzt } from '../http-limit.js';
import { brightSky, MAX_DAYS, type ForecastSource, type VorhersageDaten, type VorhersageStunde, type VorhersageTag, type Warnung } from './forecast-source.js';
import { berlinTag } from './summary.js';

const HOUR_MS = 3_600_000;
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_BODY_BYTES = 1_500_000;
export const FORECAST_INTERVAL_MS = 3 * HOUR_MS;
export const ALERTS_INTERVAL_MS = 10 * 60_000;
const FORECAST_MAX_BACKOFF_MS = 6 * HOUR_MS;
const ALERTS_MAX_BACKOFF_MS = HOUR_MS;
/** Vorhersage, die älter ist, gilt als veraltet; deutlich ältere wird gar nicht mehr geliefert. */
export const FORECAST_STALE_MS = 12 * HOUR_MS;
const FORECAST_DROP_MS = 48 * HOUR_MS;
/** Warnungen, die älter sind (sechs verpasste Abrufe), gelten als veraltet; nach einem Tag werden sie nicht mehr geliefert. */
export const ALERTS_STALE_MS = HOUR_MS;
const ALERTS_DROP_MS = 24 * HOUR_MS;
const HOURS_SHOWN = 48;

export type ForecastKind = 'forecast' | 'alerts';
export type ForecastPoll = 'ok' | 'disabled' | 'error' | 'busy';

export interface ForecastDeps {
  db: Db;
  config: Config;
  log: Logger;
  now?: () => Date;
  fetch?: typeof fetch;
  source?: ForecastSource;
  /** Nur für Tests: kürzere Abstände. */
  intervals?: { forecastMs: number; alertsMs: number };
}

/** Sichtbarer Zustand der Route (nie Koordinaten, Warnzelle, Quelle-Adresse oder Fehlertexte). */
export interface ForecastView {
  source: string;
  forecast: { updatedAt: string; stale: boolean; days: VorhersageTag[]; hours: VorhersageStunde[] } | null;
  warnings: { updatedAt: string; stale: boolean; items: Warnung[] } | null;
}

const rec = (v: unknown): Record<string, unknown> | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null);

export class ForecastService {
  private readonly db: Db;
  private readonly cfg: Config['weather'];
  private readonly log: Logger;
  private readonly now: () => Date;
  private readonly fetchFn: typeof fetch;
  private readonly source: ForecastSource;
  private readonly intervals: { forecastMs: number; alertsMs: number };
  private readonly timers = new Map<ForecastKind, NodeJS.Timeout>();
  private readonly running = new Set<ForecastKind>();
  private readonly failures: Record<ForecastKind, number> = { forecast: 0, alerts: 0 };
  private readonly laeufe = new Set<Promise<void>>();
  private closed = false;

  constructor(deps: ForecastDeps) {
    this.db = deps.db;
    this.cfg = deps.config.weather;
    this.log = deps.log;
    this.now = deps.now ?? (() => new Date());
    this.fetchFn = deps.fetch ?? fetch;
    this.source = deps.source ?? brightSky;
    this.intervals = deps.intervals ?? { forecastMs: FORECAST_INTERVAL_MS, alertsMs: ALERTS_INTERVAL_MS };
  }

  get enabled(): boolean {
    return this.cfg.enabled && this.cfg.forecast.enabled;
  }

  /** Startet die beiden Takte (nur mit eingeschalteter Vorhersage). Ein frischer gespeicherter Stand verschiebt den ersten Abruf. */
  async start(): Promise<void> {
    if (!this.enabled || this.closed || this.timers.size > 0) return;
    for (const kind of ['forecast', 'alerts'] as const) {
      const basis = kind === 'forecast' ? this.intervals.forecastMs : this.intervals.alertsMs;
      let wartezeit = kind === 'forecast' ? 8_000 : 20_000;
      try {
        const [row] = await this.db.select({ fetchedAt: weatherForecast.fetchedAt }).from(weatherForecast).where(eq(weatherForecast.kind, kind));
        if (row?.fetchedAt) wartezeit = Math.max(wartezeit, row.fetchedAt.getTime() + basis - this.now().getTime());
      } catch {
        // ohne lesbaren Stand: normaler erster Abruf
      }
      this.schedule(kind, Math.min(wartezeit, basis));
    }
  }

  close(): void {
    this.closed = true;
    for (const t of this.timers.values()) clearTimeout(t);
    this.timers.clear();
  }

  async drain(timeoutMs: number): Promise<void> {
    if (this.laeufe.size === 0) return;
    let t: NodeJS.Timeout | undefined;
    await Promise.race([Promise.allSettled([...this.laeufe]), new Promise<void>((r) => (t = setTimeout(r, timeoutMs)))]);
    clearTimeout(t);
  }

  private schedule(kind: ForecastKind, ms: number): void {
    if (this.closed) return;
    const t = setTimeout(() => {
      const lauf = this.tick(kind).finally(() => this.laeufe.delete(lauf));
      this.laeufe.add(lauf);
    }, ms);
    t.unref();
    this.timers.set(kind, t);
  }

  private async tick(kind: ForecastKind): Promise<void> {
    const basis = kind === 'forecast' ? this.intervals.forecastMs : this.intervals.alertsMs;
    const maxBackoff = kind === 'forecast' ? FORECAST_MAX_BACKOFF_MS : ALERTS_MAX_BACKOFF_MS;
    let next = basis;
    try {
      const r = kind === 'forecast' ? await this.pollForecast() : await this.pollAlerts();
      if (r === 'ok') this.failures[kind] = 0;
      else if (r === 'error') {
        this.failures[kind]++;
        next = Math.min(basis * 2 ** Math.min(this.failures[kind], 6), Math.max(maxBackoff, basis));
      }
    } catch (err: unknown) {
      this.failures[kind]++;
      next = Math.min(basis * 2 ** Math.min(this.failures[kind], 6), Math.max(maxBackoff, basis));
      this.log.error({ err }, 'Wetter-Vorhersage: Abruf fehlgeschlagen');
    }
    this.schedule(kind, next);
  }

  pollForecast(): Promise<ForecastPoll> {
    return this.poll('forecast');
  }

  pollAlerts(): Promise<ForecastPoll> {
    return this.poll('alerts');
  }

  /** Ein Abruf (auch für Tests). Läuft nie doppelt im selben Prozess. */
  private async poll(kind: ForecastKind): Promise<ForecastPoll> {
    if (!this.enabled) return 'disabled';
    if (this.running.has(kind)) return 'busy';
    this.running.add(kind);
    try {
      const now = this.now();
      const { lat, lon } = this.cfg.forecast;
      let url: string;
      if (kind === 'forecast') {
        const ab = berlinTag(now);
        // acht Berliner Kalendertage (heute + 7), damit sieben volle Tage vorliegen
        url = this.source.forecastUrl(lat, lon, ab, berlinTag(new Date(now.getTime() + 8 * 24 * HOUR_MS)));
      } else {
        url = this.source.alertsUrl(lat, lon);
      }
      const antwort = await this.hole(url);
      if (typeof antwort === 'string') return this.fail(kind, antwort);
      let daten: VorhersageDaten | Warnung[] | null;
      try {
        daten = kind === 'forecast' ? this.source.parseForecast(antwort.json, now.getTime()) : this.source.parseAlerts(antwort.json, now.getTime());
      } catch {
        daten = null;
      }
      if (daten === null) return this.fail(kind, 'bad_data');
      await this.db
        .insert(weatherForecast)
        .values({ kind, data: daten, fetchedAt: now, lastErrorAt: null, lastErrorCode: null, errorCount: 0 })
        .onConflictDoUpdate({ target: weatherForecast.kind, set: { data: daten, fetchedAt: now, lastErrorAt: null, lastErrorCode: null, errorCount: 0 } });
      return 'ok';
    } finally {
      this.running.delete(kind);
    }
  }

  /** Eine Anfrage an die feste Quelle: nur GET, nur https, kein Redirect, Zeit- und Größenlimit. Rückgabe: JSON oder ein fester Fehlercode. */
  private async hole(url: string): Promise<{ json: unknown } | string> {
    if (!url.startsWith('https://')) return 'bad_url';
    try {
      const res = await this.fetchFn(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS), redirect: 'error' });
      if (res.status !== 200) {
        await res.body?.cancel().catch(() => undefined);
        return `http_${res.status}`;
      }
      const text = await leseBegrenzt(res, MAX_BODY_BYTES);
      if (text === null) return 'too_large';
      try {
        return { json: JSON.parse(text) as unknown };
      } catch {
        return 'bad_json';
      }
    } catch {
      return 'network';
    }
  }

  private async fail(kind: ForecastKind, code: string): Promise<ForecastPoll> {
    const now = this.now();
    // gab es noch nie einen Stand, entsteht die Zeile mit leerem Platzhalter (fetched_at bleibt leer = kein Stand)
    await this.db
      .insert(weatherForecast)
      .values({ kind, data: {}, fetchedAt: null, lastErrorAt: now, lastErrorCode: code, errorCount: 1 })
      .onConflictDoUpdate({ target: weatherForecast.kind, set: { lastErrorAt: now, lastErrorCode: code, errorCount: sql`${weatherForecast.errorCount} + 1` } });
    this.log.warn({ kind, code }, 'Wetter-Vorhersage: Abruf ohne Ergebnis');
    return 'error';
  }

  /** Stand für die Route; nur aus der Datenbank. Nie Koordinaten, nie Rohdaten. */
  async view(): Promise<ForecastView> {
    const rows = await this.db.select().from(weatherForecast);
    const now = this.now();
    const nowMs = now.getTime();
    const f = rows.find((r) => r.kind === 'forecast');
    const w = rows.find((r) => r.kind === 'alerts');
    let forecast: ForecastView['forecast'] = null;
    if (f?.fetchedAt && nowMs - f.fetchedAt.getTime() <= FORECAST_DROP_MS) {
      const d = rec(f.data);
      const heute = berlinTag(now);
      const stundeMs = Math.floor(nowMs / HOUR_MS) * HOUR_MS;
      const days = (Array.isArray(d?.days) ? (d.days as VorhersageTag[]) : []).filter((t) => t.date >= heute).slice(0, MAX_DAYS);
      const hours = (Array.isArray(d?.hours) ? (d.hours as VorhersageStunde[]) : []).filter((h) => Date.parse(h.t) >= stundeMs).slice(0, HOURS_SHOWN);
      if (days.length > 0) forecast = { updatedAt: f.fetchedAt.toISOString(), stale: nowMs - f.fetchedAt.getTime() > FORECAST_STALE_MS, days, hours };
    }
    let warnings: ForecastView['warnings'] = null;
    if (w?.fetchedAt && nowMs - w.fetchedAt.getTime() <= ALERTS_DROP_MS && Array.isArray(w.data)) {
      const items = (w.data as Warnung[]).filter((x) => x.until === null || Date.parse(x.until) > nowMs);
      warnings = { updatedAt: w.fetchedAt.toISOString(), stale: nowMs - w.fetchedAt.getTime() > ALERTS_STALE_MS, items };
    }
    return { source: 'Deutscher Wetterdienst', forecast, warnings };
  }
}

