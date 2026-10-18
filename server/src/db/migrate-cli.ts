// Wendet die Migrationen aus ./drizzle an. Aufruf: npm run migrate (nach npm run build).
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import { fileURLToPath } from 'node:url';
import { loadConfig } from '../config.js';
import { createDb } from './index.js';

const config = loadConfig();
if (!config.databaseUrl) throw new Error('DATABASE_URL fehlt');

const { db, pool } = createDb(config.databaseUrl, (err) => console.error('Datenbank-Fehler:', err));
try {
  await migrate(db, { migrationsFolder: fileURLToPath(new URL('../../drizzle', import.meta.url)) });
  console.log('Migrationen angewendet');
} finally {
  await pool.end();
}
