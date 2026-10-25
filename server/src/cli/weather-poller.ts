// Eigener Prozess für den Wetter-Abruf (systemd: lx-fampad-weather.service, deploy/README.md Abschnitt 12).
// Läuft getrennt vom API-Dienst, weil nur dieser Prozess ins Internet (api.netatmo.com) darf. Kein HTTP-Port, kein Listening.
// Der Takt (Zeilensperre, Token-Rotation, Backoff) steckt unverändert in weather/service.ts; die API liest nur aus der Datenbank.
// Ohne WEATHER_ENABLED=true beendet sich der Prozess sofort (Exit 0, der Dienst bleibt dann gestoppt).
// Log nach stdout/stderr (journald), ohne Zugangsdaten und ohne Abfrage-Parameter.
import { Auth } from '../auth/service.js';
import { loadConfig } from '../config.js';
import { createDb } from '../db/index.js';
import { PushService } from '../push/service.js';
import { serializeErr } from '../log.js';
import { ForecastService } from '../weather/forecast.js';
import { WeatherAlerts } from '../weather/alerts.js';
import { startWeatherPoller } from '../weather/poller.js';
import { WeatherService } from '../weather/service.js';

const zeile = (level: string, obj: object, msg?: string) => console.log(JSON.stringify({ level, msg, ...obj, time: new Date().toISOString() }));
const log = {
  info: (obj: object, msg?: string) => zeile('info', obj, msg),
  warn: (obj: object, msg?: string) => zeile('warn', obj, msg),
  error: (obj: object, msg?: string) => zeile('error', 'err' in obj ? { ...obj, err: serializeErr((obj as { err: unknown }).err) } : obj, msg),
};

const config = loadConfig();
if (!config.weather.enabled) {
  log.warn({ code: 'weather_disabled' }, 'WEATHER_ENABLED ist nicht gesetzt: Wetter-Dienst beendet sich');
  process.exit(0);
}
if (!config.databaseUrl) throw new Error('DATABASE_URL fehlt');
const { db, pool } = createDb(config.databaseUrl, (err) => log.error({ err }, 'Fehler im Datenbank-Pool'), config.dbStatementTimeoutMs);
const auth = new Auth({ db, config });
// Wetter-Hinweise per Wecker: derselbe PushService wie in der API (Loopback-ntfy, Endpunkt-Prüfung, Deaktivierung bei 404/410); dieser Prozess hat keine
// WebSocket-Verbindungen, also gilt kein Gerät als "lebendig" und jeder Wecker geht hinaus. Ohne NTFY_URL/NTFY_TOKEN bleibt Push still aus.
const push = new PushService({ db, config, log, now: auth.ctx.now, hasLiveSocket: () => false });
push.logStatusOnce();
const alerts = new WeatherAlerts({ db, push, log, now: auth.ctx.now });
const weather = new WeatherService({ db, config, keys: auth.ctx.keys, log, nachAbruf: (view) => alerts.run(view) });

// Vorhersage und DWD-Warnungen (WEATHER_FORECAST_ENABLED): eigene Takte und eigene Fehlerisolation neben dem Netatmo-Abruf
const forecast = new ForecastService({ db, config, log });
if (forecast.enabled) {
  await forecast.start();
  log.info({ forecastMs: 3 * 3_600_000, alertsMs: 600_000 }, 'Wetter-Vorhersage gestartet');
}

const status = await weather.status();
if (!status.configured) log.warn({ code: 'not_configured' }, 'Keine Wetter-Zugangsdaten: weather-setup ausführen (prüft alle 10 Minuten erneut)');
startWeatherPoller(weather, log);
log.info({ pollMs: config.weather.pollMs }, 'Wetter-Abruf gestartet');

// der Takt-Timer ist unref'd: dieser Intervall hält den Prozess bis zum Signal am Leben
const halten = setInterval(() => undefined, 2 ** 30);
const shutdown = async (signal: string) => {
  log.info({ signal }, 'Beende Wetter-Abruf');
  clearInterval(halten);
  weather.close();
  forecast.close();
  // einen laufenden Abruf (Token-Rotation!) zu Ende laufen lassen, höchstens 10 s (TimeoutStopSec=20 in der Unit)
  await Promise.all([weather.drain(10_000), forecast.drain(10_000)]);
  push.close();
  await pool.end();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
