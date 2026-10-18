import { sql } from 'drizzle-orm';
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createDb } from './db/index.js';

const config = loadConfig();
const database = config.databaseUrl ? createDb(config.databaseUrl) : undefined;

const app = await buildApp({
  config,
  pingDb: database ? async () => void (await database.db.execute(sql`select 1`)) : undefined,
});

const shutdown = async (signal: string) => {
  app.log.info({ signal }, 'Beende Server');
  await app.close();
  await database?.pool.end();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

await app.listen({ host: config.host, port: config.port });
