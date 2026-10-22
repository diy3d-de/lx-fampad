// Eigener Prozess für den Abruf der Abfuhrtermine (systemd: lx-fampad-waste.service, deploy/README.md Abschnitt 13).
// Läuft getrennt vom API-Dienst, weil nur dieser Prozess ins Internet (die Abfall-Plattform) darf, und getrennt vom Wetter-Dienst
// (ein Fehler dort stoppt diesen Abruf nicht und umgekehrt). Kein HTTP-Port. Der Takt (waste/service.ts) liest nur den Zustand aus der
// Datenbank und ruft nach der Jahreslogik oder auf Anforderung (Eltern/Admin: "Jetzt prüfen") ab.
// Ohne WASTE_ENABLED=true beendet sich der Prozess sofort (Exit 0). Log nach stdout (journald), nie die URL und nie Fehlertexte.
import { loadConfig } from '../config.js';
import { createDb } from '../db/index.js';
import { serializeErr } from '../log.js';
import { WasteService } from '../waste/service.js';

const zeile = (level: string, obj: object, msg?: string) => console.log(JSON.stringify({ level, msg, ...obj, time: new Date().toISOString() }));
const log = {
  info: (obj: object, msg?: string) => zeile('info', obj, msg),
  warn: (obj: object, msg?: string) => zeile('warn', obj, msg),
  error: (obj: object, msg?: string) => zeile('error', 'err' in obj ? { ...obj, err: serializeErr((obj as { err: unknown }).err) } : obj, msg),
};

const config = loadConfig();
if (config.waste.configError) {
  // ungültige Müll-Konfiguration: nicht neu starten (Exit 78 = EX_CONFIG, RestartPreventExitStatus in der Unit); die Meldung nennt nie den Link
  log.error({ code: 'waste_config' }, `Abfuhr-Dienst beendet: ${config.waste.configError}`);
  process.exit(78);
}
if (!config.waste.enabled) {
  log.warn({ code: 'waste_disabled' }, 'WASTE_ENABLED ist nicht gesetzt: Abfuhr-Dienst beendet sich');
  process.exit(0);
}
if (!config.databaseUrl) throw new Error('DATABASE_URL fehlt');
const { db, pool } = createDb(config.databaseUrl, (err) => log.error({ err }, 'Fehler im Datenbank-Pool'), config.dbStatementTimeoutMs);
const waste = new WasteService({ db, config, log });
waste.start();
log.info({ tickMs: config.waste.tickMs }, 'Abfuhr-Abruf gestartet');

// der Takt-Timer ist unref'd: dieser Intervall hält den Prozess bis zum Signal am Leben
const halten = setInterval(() => undefined, 2 ** 30);
const shutdown = async (signal: string) => {
  log.info({ signal }, 'Beende Abfuhr-Abruf');
  clearInterval(halten);
  waste.close();
  await waste.drain(10_000);
  await pool.end();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
