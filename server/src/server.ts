import { sql } from 'drizzle-orm';
import type { FastifyBaseLogger } from 'fastify';
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createDb } from './db/index.js';

const config = loadConfig();
// der Pool entsteht vor der App; Fehler gehen erst ins App-Log, sobald es existiert
const logRef: { current?: FastifyBaseLogger } = {};
const database = config.databaseUrl
  ? createDb(config.databaseUrl, (err) => (logRef.current ? logRef.current.error({ err }, 'Fehler im Datenbank-Pool') : console.error(err)))
  : undefined;

const app = await buildApp({
  config,
  pingDb: database ? async () => void (await database.db.execute(sql`select 1`)) : undefined,
});
logRef.current = app.log;

const shutdown = async (signal: string) => {
  app.log.info({ signal }, 'Beende Server');
  await app.close();
  await database?.pool.end();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

await app.listen({ host: config.host, port: config.port });
