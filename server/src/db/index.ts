import { drizzle } from 'drizzle-orm/node-postgres';
import pg from 'pg';
import * as schema from './schema.js';

export type Db = ReturnType<typeof createDb>['db'];

/**
 * @param onPoolError Wird bei Fehlern auf Leerlauf-Verbindungen aufgerufen (z. B. Datenbank neu gestartet).
 *   Ohne Handler würde Node bei einem solchen Fehler abstürzen.
 */
export function createDb(databaseUrl: string, onPoolError: (err: Error) => void) {
  const pool = new pg.Pool({
    connectionString: databaseUrl,
    max: 10,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30_000,
    // keine Abfrage darf den Dienst dauerhaft blockieren
    query_timeout: 30_000,
  });
  pool.on('error', onPoolError);
  const db = drizzle(pool, { schema });
  return { db, pool };
}

export { schema };
