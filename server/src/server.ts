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
// Aufräumen beim Start und stündlich: IPs im Audit-Log nach 7 Tagen, abgelaufene Sitzungen, Challenges, Tickets
// Wetter: der eine Abruf-Takt (nur mit WEATHER_ENABLED=true)
app.weather?.start();
const maintenance = app.authCore ? startMaintenance(app.authCore.ctx) : undefined;

const shutdown = async (signal: string) => {
  app.log.info({ signal }, 'Beende Server');
  maintenance?.stop();
  await app.close();
  await database?.pool.end();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

await app.listen({ host: config.host, port: config.port });
