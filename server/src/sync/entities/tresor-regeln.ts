// Regeln der Tresor-Konversation (Abschnitt 6m): wer den Tresor der Eltern sehen darf. Rein (ohne Datenbank), damit Register, Rollenwechsel und Tests dieselbe Regel benutzen.
//
//  - Teilnehmer sind ausschließlich aktive Erwachsene (Rolle `admin`/`parent`), mindestens eine Person; nie ein Kind. Die Rolle kommt vom Server (Tabelle memberships), nie vom Client;
//    Familienrolle (reine Anzeige) und Betreiber-Flag zählen nie.
//  - Muss die Liste ALLE Erwachsenen enthalten? Nein: der Server erzwingt nur "nur Erwachsene". Neue Erwachsene nimmt die App in die Liste auf (Teilnehmer-Pflege).
import type { Role } from '../../auth/types.js';
import { istErwachsen } from './meds-regeln.js';

/** Ist diese Teilnehmerliste für den Tresor zulässig? [rollen]: Rollen der aktiven Mitglieder (Schlüssel = ID in Kleinbuchstaben). */
export function tresorTeilnehmerGueltig(teilnehmer: readonly string[], rollen: ReadonlyMap<string, Role>): boolean {
  const liste = teilnehmer.map((t) => t.toLowerCase());
  return liste.length >= 1 && new Set(liste).size === liste.length && liste.every((t) => istErwachsen(rollen.get(t)));
}

/**
 * Zulässige Teilnehmer aus [aktuell] (Nachziehen nach einem Rollenwechsel): die noch erwachsenen aktuellen Teilnehmer. Bleibt niemand übrig, gelten ersatzweise [alleErwachsenen]
 * (die aktiven Erwachsenen der Familie), damit nie ein Kind in der Liste bleibt und die Liste nie leer wird.
 */
export function tresorTeilnehmerBereinigt(aktuell: readonly string[], rollen: ReadonlyMap<string, Role>, alleErwachsenen: readonly string[]): string[] {
  const rest = aktuell.map((t) => t.toLowerCase()).filter((t) => istErwachsen(rollen.get(t)));
  const liste = rest.length > 0 ? rest : alleErwachsenen.map((t) => t.toLowerCase());
  return [...new Set(liste)].sort();
}
