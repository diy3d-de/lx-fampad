import { sql } from 'drizzle-orm';
import type { FastifyBaseLogger } from 'fastify';
import { buildApp } from './app.js';
import { startMaintenance } from './auth/maintenance.js';
import { loadConfig } from './config.js';
import { createDb } from './db/index.js';
import { serializeErr } from './log.js';

const config = loadConfig();
// der Pool entsteht vor der App; Fehler gehen erst ins App-Log, sobald es existiert
const logRef: { current?: FastifyBaseLogger } = {};
const database = config.databaseUrl
  ? createDb(config.databaseUrl, (err) => (logRef.current ? logRef.current.error({ err }, 'Fehler im Datenbank-Pool') : console.error('Fehler im Datenbank-Pool', serializeErr(err))), config.dbStatementTimeoutMs)
  : undefined;

const app = await buildApp({
  config,
  db: database?.db,
  pingDb: database ? async () => void (await database.db.execute(sql`select 1`)) : undefined,
});
logRef.current = app.log;
// ungültige Müll-Konfiguration: Funktion aus, der API-Start bleibt unberührt (die Meldung nennt nie den Link); der Abruf-Dienst bricht selbst ab
if (config.waste.configError) app.log.warn({ code: 'waste_config' }, `Müll ist aus: ${config.waste.configError}`);
// Wetter: KEIN Abruf-Takt im API-Prozess (dieser darf nur Loopback erreichen); er läuft in cli/weather-poller.ts (lx-fampad-weather.service)
// Aufräumen beim Start und stündlich: IPs im Audit-Log nach 7 Tagen, abgelaufene Sitzungen, Challenges, Tickets
const maintenance = app.authCore ? startMaintenance(app.authCore.ctx) : undefined;
// Betreiber-Warnungen: Prüfer alle 5 Minuten (Zustand in der Datenbank, nach einem Neustart keine Wiederholung); Push nur ohne Inhalt an den Betreiber
app.operatorMonitor?.start();

const shutdown = async (signal: string) => {
  app.log.info({ signal }, 'Beende Server');
  maintenance?.stop();
  app.operatorMonitor?.stop();
  await app.close();
  await database?.pool.end();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

await app.listen({ host: config.host, port: config.port });
