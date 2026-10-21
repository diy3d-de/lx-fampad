// Betreiber-Rolle setzen oder entziehen. Läuft nur auf dem Server (Zugriff auf die Datenbank), nie über das Netz und nie über die App.
//   node dist/cli/operator.js grant <E-Mail>    macht ein aktives Mitglied zum Betreiber (sieht das Dashboard "Betrieb")
//   node dist/cli/operator.js revoke <E-Mail>   nimmt die Rolle zurück
//   node dist/cli/operator.js list              zeigt die Betreiber
// Die Rolle gilt nur für die Betreiber-Routen (/api/v1/admin); Familienrechte (Admin, Eltern, Kind) ändert sie nicht.
import { Auth } from '../auth/service.js';
import { loadConfig } from '../config.js';
import { createDb } from '../db/index.js';
import { AppError } from '../errors.js';
import { grantOperator, listOperators, revokeOperator } from '../operator/service.js';

const [command, email] = process.argv.slice(2);
const usage = 'Aufruf: operator.js grant <E-Mail> | revoke <E-Mail> | list';

const config = loadConfig();
if (!config.databaseUrl) throw new Error('DATABASE_URL fehlt');
const { db, pool } = createDb(config.databaseUrl, (err) => console.error('Datenbank-Fehler:', err));
const auth = new Auth({ db, config });

try {
  if (command === 'list') {
    const rows = await listOperators(auth.ctx);
    if (rows.length === 0) console.log('Keine Betreiber eingetragen.');
    for (const r of rows) console.log(`${r.email}  (${r.displayName})  seit ${r.grantedAt.toISOString()}`);
  } else if ((command === 'grant' || command === 'revoke') && email) {
    const result = command === 'grant' ? await grantOperator(auth.ctx, email) : await revokeOperator(auth.ctx, email);
    if (command === 'grant') console.log(result.changed ? `${email} ist jetzt Betreiber.` : `${email} war schon Betreiber.`);
    else console.log(result.changed ? `${email} ist kein Betreiber mehr.` : `${email} war kein Betreiber.`);
  } else {
    console.error(usage);
    process.exitCode = 2;
  }
} catch (err) {
  console.error(err instanceof AppError ? `Abbruch: ${err.message}` : 'Fehler (Details im Datenbank-/Systemlog).');
  if (!(err instanceof AppError)) console.error(err);
  process.exitCode = 1;
} finally {
  await pool.end();
}
