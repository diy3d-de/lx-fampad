import { drizzle } from 'drizzle-orm/node-postgres';
import pg from 'pg';
import * as schema from './schema.js';

export type Db = ReturnType<typeof createDb>['db'];

/**
 * @param statementTimeoutMs Zeitlimit je Anweisung (nur Laufzeit-Pool; die Migrationsrolle in migrate-cli hat kein Limit).
 * @param onPoolError Wird bei Fehlern auf Leerlauf-Verbindungen aufgerufen (z. B. Datenbank neu gestartet).
 *   Ohne Handler würde Node bei einem solchen Fehler abstürzen.
 */
export function createDb(databaseUrl: string, onPoolError: (err: Error) => void, statementTimeoutMs = 30_000) {
  const pool = new pg.Pool({
    connectionString: databaseUrl,
    max: 10,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30_000,
    // keine Abfrage darf den Dienst dauerhaft blockieren: serverseitig (statement_timeout, gibt die Verbindung frei) und im Client (etwas später)
    statement_timeout: statementTimeoutMs,
    query_timeout: statementTimeoutMs + 5000,
  });
  pool.on('error', onPoolError);
  const db = drizzle(pool, { schema });
  return { db, pool };
}

export { schema };
