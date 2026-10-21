// Wetter: ruft die öffentliche Netatmo-Station des Betreibers ab (nur der Server, nie ein Client) und hält die Messwerte
// selbst vor (Verlauf, Min/Max). Abruf per getpublicdata mit Suchrechteck und Filter auf die MAC; kein Weathermap-Scraping.
// OAuth2: Refresh-Token mit Rotation. Das neue Token wird in derselben Transaktion unter Zeilensperre gespeichert, in der es
// abgeholt wird (nur eine Erneuerung gleichzeitig); bei `invalid_grant` wird der Abruf abgeschaltet, bis der Betreiber die
// Zugangsdaten neu eingibt. Zugangsdaten stehen nur verschlüsselt in der Datenbank, nie im Log.
import { asc, eq, gte, lt } from 'drizzle-orm';
import type { Db, Logger } from '../auth/context.js';
import type { KeyRing } from '../auth/crypto.js';
import type { Config } from '../config.js';
import { weatherCredentials, weatherSamples } from '../db/schema.js';
import { stationMessung, type Messung } from './parse.js';

const API = 'https://api.netatmo.com';
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_BODY_CHARS = 2_000_000;
const HOUR_MS = 3_600_000;
export const SAMPLE_RETENTION_MS = 7 * 24 * HOUR_MS;
/** Eine Messung, die älter ist, gilt in der Anzeige als veraltet. */
export const STALE_AFTER_MS = HOUR_MS;
const MAX_BACKOFF_MS = 2 * HOUR_MS;
const SERIES_BUCKET_MS = 15 * 60_000;

export type PollResult = 'ok' | 'not_configured' | 'disabled' | 'invalid_grant' | 'auth_error' | 'upstream_error' | 'station_not_found' | 'busy';

const AAD = { clientId: 'weather/client_id', clientSecret: 'weather/client_secret', refreshToken: 'weather/refresh_token' } as const;
const PURPOSE = 'weather';

export interface WeatherServiceDeps {
  db: Db;
  config: Config;
  keys: KeyRing;
  log: Logger;
  now?: () => Date;
  fetch?: typeof fetch;
}

/** Sichtbarer Zustand für die Route (nie Zugangsdaten, nie Station). */
export interface WeatherView {
  place: string;
  current: {
    measuredAt: string;
    stale: boolean;
    temperature: number | null;
    humidity: number | null;
    pressure: number | null;
    rain1h: number | null;
    rain24h: number | null;
    windKmh: number | null;
    gustKmh: number | null;
    windAngle: number | null;
  } | null;
  min24h: number | null;
  max24h: number | null;
  series: { t: string; temperature: number }[];
}

export class WeatherService {
  private readonly db: Db;
  private readonly cfg: Config['weather'];
  private readonly keys: KeyRing;
  private readonly log: Logger;
  private readonly now: () => Date;
  private readonly fetchFn: typeof fetch;
  private access: { token: string; expiresAt: number } | null = null;
  private running = false;
  private timer: NodeJS.Timeout | null = null;
  private failures = 0;
  private closed = false;

  constructor(deps: WeatherServiceDeps) {
    this.db = deps.db;
    this.cfg = deps.config.weather;
    this.keys = deps.keys;
    this.log = deps.log;
    this.now = deps.now ?? (() => new Date());
    this.fetchFn = deps.fetch ?? fetch;
  }

  get enabled(): boolean {
    return this.cfg.enabled;
  }

  /** Startet den einen Abruf-Takt dieses Prozesses (nur mit eingeschaltetem Wetter). */
  start(): void {
    if (!this.cfg.enabled || this.timer || this.closed) return;
    this.schedule(5_000);
  }

  close(): void {
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(ms: number): void {
    if (this.closed) return;
    this.timer = setTimeout(() => void this.tick(), ms);
    this.timer.unref();
  }

  private backoff(): number {
    return Math.min(this.cfg.pollMs * 2 ** Math.min(this.failures, 6), MAX_BACKOFF_MS);
  }

  private async tick(): Promise<void> {
    let next = this.cfg.pollMs;
    try {
      const r = await this.pollOnce();
      if (r === 'ok') this.failures = 0;
      else if (r === 'disabled' || r === 'not_configured' || r === 'invalid_grant') next = Math.max(this.cfg.pollMs, HOUR_MS);
      else if (r !== 'busy') {
        this.failures++;
        next = this.backoff();
      }
    } catch (err: unknown) {
      this.failures++;
      next = this.backoff();
      this.log.error({ err }, 'Wetter-Abruf fehlgeschlagen');
    }
    this.schedule(next);
  }

  /** Ein Abruf (auch für Tests und die Einrichtung). Läuft nie doppelt im selben Prozess. */
  async pollOnce(): Promise<PollResult> {
    if (!this.cfg.enabled) return 'disabled';
    if (this.running) return 'busy';
    this.running = true;
    try {
      const [row] = await this.db.select({ disabledAt: weatherCredentials.disabledAt }).from(weatherCredentials);
      if (!row) return 'not_configured';
      if (row.disabledAt) return 'disabled';
      let result = await this.fetchPublic();
      if (result === 'auth_error') {
        // Zugangstoken abgelehnt: einmal erneuern und wiederholen
        this.access = null;
        result = await this.fetchPublic();
        if (result === 'auth_error') result = await this.fail('auth_rejected');
      }
      return result;
    } finally {
      this.running = false;
    }
  }

  private async fetchPublic(): Promise<PollResult> {
    const token = await this.accessToken();
    if (token === 'invalid_grant') return 'invalid_grant';
    if (token === 'error') return 'upstream_error';
    const b = this.cfg.bbox;
    const q = new URLSearchParams({ lat_ne: String(b.latNe), lon_ne: String(b.lonNe), lat_sw: String(b.latSw), lon_sw: String(b.lonSw), filter: 'false' });
    let res: Response;
    let text: string;
    try {
      res = await this.fetchFn(`${API}/api/getpublicdata?${q.toString()}`, {
        headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        redirect: 'error',
      });
      text = await res.text();
    } catch {
      return this.fail('network');
    }
    if (res.status === 401 || res.status === 403) return 'auth_error';
    if (!res.ok || text.length > MAX_BODY_CHARS) return this.fail(`http_${res.status}`);
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      return this.fail('bad_json');
    }
    const body = (json as { body?: unknown } | null)?.body;
    const m = stationMessung(body, this.cfg.stationMac);
    if (!m) return this.fail('station_not_found', 'station_not_found');
    await this.speichern(m);
    return 'ok';
  }

  private async fail(code: string, result: PollResult = 'upstream_error'): Promise<PollResult> {
    await this.db.update(weatherCredentials).set({ lastErrorAt: this.now(), lastErrorCode: code }).where(eq(weatherCredentials.id, 1));
    this.log.warn({ code }, 'Wetter-Abruf ohne Ergebnis');
    return result;
  }

  private async speichern(m: Messung): Promise<void> {
    const now = this.now();
    await this.db
      .insert(weatherSamples)
      .values({
        ts: new Date(m.ts * 1000),
        temperature: m.temperature,
        humidity: m.humidity,
        pressure: m.pressure,
        rain1h: m.rain1h,
        rain24h: m.rain24h,
        windKmh: m.windKmh,
        gustKmh: m.gustKmh,
        windAngle: m.windAngle,
      })
      .onConflictDoNothing();
    await this.db.delete(weatherSamples).where(lt(weatherSamples.ts, new Date(now.getTime() - SAMPLE_RETENTION_MS)));
    await this.db.update(weatherCredentials).set({ lastOkAt: now, lastErrorAt: null, lastErrorCode: null }).where(eq(weatherCredentials.id, 1));
  }

  /** Gültiges Zugangstoken (im Speicher); erneuert es bei Bedarf über das Refresh-Token mit Rotation. */
  private async accessToken(): Promise<string | 'invalid_grant' | 'error'> {
    const nowMs = this.now().getTime();
    if (this.access && this.access.expiresAt - 60_000 > nowMs) return this.access.token;
    // Zeilensperre: nur eine Erneuerung gleichzeitig; das neue Refresh-Token wird vor dem Commit gespeichert
    return this.db.transaction(async (tx) => {
      const [row] = await tx.select().from(weatherCredentials).where(eq(weatherCredentials.id, 1)).for('update');
      if (!row || row.disabledAt) return 'error';
      const markiere = (code: string) => tx.update(weatherCredentials).set({ lastErrorAt: this.now(), lastErrorCode: code }).where(eq(weatherCredentials.id, 1));
      let clientId: string, clientSecret: string, refresh: string;
      try {
        clientId = this.keys.decrypt(PURPOSE, row.clientIdEnc, AAD.clientId);
        clientSecret = this.keys.decrypt(PURPOSE, row.clientSecretEnc, AAD.clientSecret);
        refresh = this.keys.decrypt(PURPOSE, row.refreshTokenEnc, AAD.refreshToken);
      } catch {
        await markiere('decrypt');
        this.log.error({ code: 'decrypt' }, 'Wetter-Zugangsdaten nicht lesbar');
        return 'error';
      }
      let res: Response;
      let text: string;
      try {
        res = await this.fetchFn(`${API}/oauth2/token`, {
          method: 'POST',
          headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
          body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refresh, client_id: clientId, client_secret: clientSecret }).toString(),
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
          redirect: 'error',
        });
        text = await res.text();
      } catch {
        await markiere('token_network');
        return 'error';
      }
      let json: { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown; error?: unknown } = {};
      try {
        json = JSON.parse(text) as typeof json;
      } catch {
        // keine JSON-Antwort: gilt wie ein Fehler
      }
      if (!res.ok) {
        if (json.error === 'invalid_grant') {
          const now = this.now();
          await tx.update(weatherCredentials).set({ disabledAt: now, lastErrorAt: now, lastErrorCode: 'invalid_grant' }).where(eq(weatherCredentials.id, 1));
          this.log.error({ code: 'invalid_grant' }, 'Wetter abgeschaltet: Zugangsdaten neu eingeben (weather-setup)');
          return 'invalid_grant';
        }
        await markiere(`token_http_${res.status}`);
        return 'error';
      }
      const access = json.access_token;
      const expires = typeof json.expires_in === 'number' && json.expires_in > 0 ? json.expires_in : 3600;
      if (typeof access !== 'string' || access.length < 10 || access.length > 1000) {
        await markiere('token_bad');
        return 'error';
      }
      // Rotation: das neue Refresh-Token ersetzt das alte noch vor dem Commit
      const neu = json.refresh_token;
      if (typeof neu === 'string' && neu.length >= 10 && neu.length <= 1000 && neu !== refresh) {
        await tx.update(weatherCredentials).set({ refreshTokenEnc: this.keys.encrypt(PURPOSE, neu, AAD.refreshToken), updatedAt: this.now() }).where(eq(weatherCredentials.id, 1));
      }
      this.access = { token: access, expiresAt: this.now().getTime() + Math.min(expires, 3 * 3600) * 1000 };
      return access;
    });
  }

  /** Zugangsdaten setzen oder ersetzen (CLI); hebt eine Abschaltung auf. */
  async speichereZugangsdaten(c: { clientId: string; clientSecret: string; refreshToken: string }): Promise<void> {
    const werte = {
      clientIdEnc: this.keys.encrypt(PURPOSE, c.clientId, AAD.clientId),
      clientSecretEnc: this.keys.encrypt(PURPOSE, c.clientSecret, AAD.clientSecret),
      refreshTokenEnc: this.keys.encrypt(PURPOSE, c.refreshToken, AAD.refreshToken),
      updatedAt: this.now(),
      disabledAt: null,
      lastErrorAt: null,
      lastErrorCode: null,
    };
    await this.db.insert(weatherCredentials).values({ id: 1, ...werte }).onConflictDoUpdate({ target: weatherCredentials.id, set: werte });
    this.access = null;
  }

  async loescheZugangsdaten(): Promise<void> {
    await this.db.delete(weatherCredentials);
    this.access = null;
  }

  /** Zustand für die Einrichtung (ohne Geheimnisse). */
  async status(): Promise<{ configured: boolean; disabled: boolean; lastOkAt: Date | null; lastErrorCode: string | null }> {
    const [r] = await this.db.select().from(weatherCredentials);
    return { configured: !!r, disabled: !!r?.disabledAt, lastOkAt: r?.lastOkAt ?? null, lastErrorCode: r?.lastErrorCode ?? null };
  }

  /** Aktueller Stand und 24-h-Verlauf aus der eigenen Zwischenspeicherung. Nur Ortsname und Messwerte. */
  async view(): Promise<WeatherView> {
    const now = this.now();
    const von = new Date(now.getTime() - 24 * HOUR_MS);
    const rows = await this.db.select().from(weatherSamples).where(gte(weatherSamples.ts, new Date(now.getTime() - SAMPLE_RETENTION_MS))).orderBy(asc(weatherSamples.ts));
    const letzte = rows[rows.length - 1];
    const tag = rows.filter((r) => r.ts >= von);
    const temps = tag.map((r) => r.temperature).filter((t): t is number => t !== null);
    // Verlauf: je 15-Minuten-Fach die letzte Messung
    const faecher = new Map<number, { t: Date; temperature: number }>();
    for (const r of tag) {
      if (r.temperature === null) continue;
      faecher.set(Math.floor(r.ts.getTime() / SERIES_BUCKET_MS), { t: r.ts, temperature: r.temperature });
    }
    return {
      place: this.cfg.place,
      current: letzte
        ? {
            measuredAt: letzte.ts.toISOString(),
            stale: now.getTime() - letzte.ts.getTime() > STALE_AFTER_MS,
            temperature: letzte.temperature,
            humidity: letzte.humidity,
            pressure: letzte.pressure,
            rain1h: letzte.rain1h,
            rain24h: letzte.rain24h,
            windKmh: letzte.windKmh,
            gustKmh: letzte.gustKmh,
            windAngle: letzte.windAngle,
          }
        : null,
      min24h: temps.length ? Math.min(...temps) : null,
      max24h: temps.length ? Math.max(...temps) : null,
      series: [...faecher.values()].map((f) => ({ t: f.t.toISOString(), temperature: f.temperature })),
    };
  }
}
