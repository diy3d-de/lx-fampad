// Einrichtung der Wetter-Zugangsdaten (Netatmo) durch den Betreiber. Läuft auf dem Server, nicht über das Netz.
//   node dist/cli/weather-setup.js            fragt client_id, client_secret und Refresh-Token ab (ohne Echo) und speichert sie verschlüsselt
//   node dist/cli/weather-setup.js --status   zeigt den Zustand (ohne Geheimnisse)
//   node dist/cli/weather-setup.js --remove   löscht die Zugangsdaten
// Eingabe nur über die Tastatur (oder eine Pipe, eine Zeile je Wert); nie als Argument, nie in Dateien, nie im Log.
import { Auth } from '../auth/service.js';
import { loadConfig } from '../config.js';
import { createDb } from '../db/index.js';
import { WeatherService } from '../weather/service.js';
import { frageVerdeckt } from './prompt.js';

const config = loadConfig();
if (!config.databaseUrl) throw new Error('DATABASE_URL fehlt');
const { db, pool } = createDb(config.databaseUrl, (err) => console.error('Datenbank-Fehler:', err));
const auth = new Auth({ db, config });
const weather = new WeatherService({ db, config, keys: auth.ctx.keys, log: { warn: () => undefined, error: () => undefined } });

try {
  if (process.argv.includes('--status')) {
    const s = await weather.status();
    console.log(`Wetter-Schalter (WEATHER_ENABLED): ${config.weather.enabled ? 'an' : 'aus'}`);
    console.log(`Zugangsdaten: ${s.configured ? 'gespeichert' : 'nicht eingerichtet'}${s.disabled ? ' (ABGESCHALTET, Token ungültig: neu eingeben)' : ''}`);
    console.log(`Letzter erfolgreicher Abruf: ${s.lastOkAt ? s.lastOkAt.toISOString() : 'noch keiner'}`);
    if (s.lastErrorCode) console.log(`Letzter Fehler: ${s.lastErrorCode}`);
  } else if (process.argv.includes('--remove')) {
    await weather.loescheZugangsdaten();
    console.log('Zugangsdaten gelöscht.');
  } else {
    console.log('Netatmo-Zugangsdaten (Eingabe wird nicht angezeigt; scope read_station).');
    const clientId = await frageVerdeckt('client_id: ');
    const clientSecret = await frageVerdeckt('client_secret: ');
    const refreshToken = await frageVerdeckt('refresh_token: ');
    if (!clientId || !clientSecret || refreshToken.length < 10) throw new Error('Eingabe unvollständig.');
    await weather.speichereZugangsdaten({ clientId, clientSecret, refreshToken });
    console.log('Gespeichert (verschlüsselt).');
    if (config.weather.enabled) {
      const r = await weather.pollOnce();
      console.log(`Probeabruf: ${r}`);
      if (r !== 'ok') process.exitCode = 1;
    } else {
      console.log('Hinweis: WEATHER_ENABLED=true setzen und den Dienst neu starten, damit abgerufen wird.');
    }
  }
} catch (err) {
  console.error(`Abbruch: ${err instanceof Error ? err.message : 'Fehler'}`);
  process.exitCode = 1;
} finally {
  await pool.end();
}
