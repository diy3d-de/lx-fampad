// Wendet die Migrationen aus ./drizzle an. Aufruf: npm run migrate (nach npm run build).
// Läuft mit der Migrationsrolle (Eigentümer, darf DDL): MIGRATION_DATABASE_URL. Ohne sie gilt DATABASE_URL
// (Rückfall für Installationen, die noch mit einer einzigen Rolle laufen). Die Laufzeitrolle hat nur DML-Rechte.
// Bewusst ohne loadConfig: Migrationen brauchen weder AUTH_SECRET_KEY noch die übrige Konfiguration.
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import { fileURLToPath } from 'node:url';
import { createDb } from './index.js';

const url = process.env.MIGRATION_DATABASE_URL || process.env.DATABASE_URL;
if (!url) throw new Error('MIGRATION_DATABASE_URL oder DATABASE_URL fehlt');
if (!process.env.MIGRATION_DATABASE_URL) console.warn('Hinweis: MIGRATION_DATABASE_URL nicht gesetzt, nutze DATABASE_URL (eine Rolle für Migration und Betrieb)');

const { db, pool } = createDb(url, (err) => console.error('Datenbank-Fehler:', err));
try {
  await migrate(db, { migrationsFolder: fileURLToPath(new URL('../../drizzle', import.meta.url)) });
  console.log('Migrationen angewendet');
} finally {
  await pool.end();
}
