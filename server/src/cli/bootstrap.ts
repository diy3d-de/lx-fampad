// Erstinstallation und Notfall-Zurücksetzen durch den Betreiber. Läuft auf dem Server, nicht über das Netz.
//   node dist/cli/bootstrap.js [--family "Name"] [--pin]      legt Familie + Einladung für den ersten Admin an
//   node dist/cli/bootstrap.js --reset <E-Mail> [--pin]       neue Einladung für ein bestehendes Mitglied (Anmeldedaten und Sitzungen werden widerrufen)
// Der Einladungslink wird nur hier ausgegeben (7 Tage gültig, einmal einlösbar, in der Datenbank steht nur der Hash).
import { Auth } from '../auth/service.js';
import { bootstrapFamily, resetByEmail } from '../auth/bootstrap.js';
import { loadConfig } from '../config.js';
import { createDb } from '../db/index.js';
import { AppError } from '../errors.js';

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const config = loadConfig();
if (!config.databaseUrl) throw new Error('DATABASE_URL fehlt');
const { db, pool } = createDb(config.databaseUrl, (err) => console.error('Datenbank-Fehler:', err));
const auth = new Auth({ db, config });
const withPin = process.argv.includes('--pin');

try {
  const resetEmail = arg('--reset');
  const invite = resetEmail ? await resetByEmail(auth.ctx, resetEmail, withPin) : await bootstrapFamily(auth.ctx, { familyName: arg('--family') ?? 'Familie', withPin });
  console.log(resetEmail ? 'Zurückgesetzt. Neuer Einladungslink (einmalig, 7 Tage gültig):' : 'Familie eingerichtet. Einladungslink für den ersten Admin (einmalig, 7 Tage gültig):');
  console.log(`\n  ${invite.link}\n`);
  if (invite.pin) console.log(`  PIN (nur jetzt sichtbar, getrennt weitergeben): ${invite.pin}\n`);
  console.log('Der Link enthält das Token im Fragment (#), es erscheint in keinem Server-Log. Nicht weitergeben außer an die einzuladende Person.');
} catch (err) {
  console.error(err instanceof AppError ? `Abbruch: ${err.message}` : 'Fehler beim Einrichten (Details im Datenbank-/Systemlog).');
  if (!(err instanceof AppError)) console.error(err);
  process.exitCode = 1;
} finally {
  await pool.end();
}
