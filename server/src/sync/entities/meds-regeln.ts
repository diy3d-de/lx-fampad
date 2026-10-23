// Regeln der Medikamenten-Konversation (Abschnitt 6k): wer die Medikamente einer Person sehen darf. Rein (ohne Datenbank), damit Register, Rollenwechsel und Tests dieselbe Regel benutzen.
//
//  - Subjekt = die Person, um deren Medikamente es geht. Sie sieht immer ihre eigenen.
//  - Subjekt ist ein Kind (Rolle `child`): zusätzlich dürfen Eltern und Admins (Rollen `parent`/`admin`) teilnehmen, nie ein anderes Kind (auch kein Geschwister).
//  - Subjekt ist erwachsen (`parent`/`admin`): nur die Person selbst, nie ein anderer Erwachsener (auch kein Admin, auch nicht der Betreiber: das Betreiber-Flag zählt hier nicht).
// Die Rolle kommt vom Server (Tabelle memberships), nie vom Client; die Familienrolle (reine Anzeige) zählt nie.
import { and, eq, inArray, isNull } from 'drizzle-orm';
import type { Executor } from '../../auth/context.js';
import type { Role } from '../../auth/types.js';
import { memberships, users } from '../../db/schema.js';

export const istErwachsen = (rolle: Role | undefined): boolean => rolle === 'admin' || rolle === 'parent';

/** Ist diese Teilnehmerliste für die Medikamente von [subjektId] zulässig? [rollen]: Rollen der aktiven Mitglieder (Schlüssel = ID in Kleinbuchstaben). */
export function medsTeilnehmerGueltig(subjektId: string, teilnehmer: readonly string[], rollen: ReadonlyMap<string, Role>): boolean {
  const subjekt = subjektId.toLowerCase();
  const liste = teilnehmer.map((t) => t.toLowerCase());
  const rolleSubjekt = rollen.get(subjekt);
  if (rolleSubjekt === undefined || !liste.includes(subjekt)) return false;
  if (istErwachsen(rolleSubjekt)) return liste.length === 1;
  // Kind: alle anderen müssen aktive Erwachsene sein
  return liste.every((t) => t === subjekt || istErwachsen(rollen.get(t)));
}

/** Zulässige Teilnehmer aus [aktuell] (für das Nachziehen nach einem Rollenwechsel): das Subjekt und, bei einem Kind, die noch erwachsenen aktuellen Teilnehmer. */
export function medsTeilnehmerBereinigt(subjektId: string, aktuell: readonly string[], rollen: ReadonlyMap<string, Role>): string[] {
  const subjekt = subjektId.toLowerCase();
  const kind = rollen.get(subjekt) === 'child';
  const rest = aktuell.map((t) => t.toLowerCase()).filter((t) => t === subjekt || (kind && istErwachsen(rollen.get(t))));
  return [...new Set([subjekt, ...rest])].sort();
}

/** Rollen der aktiven (nicht entfernten, nicht gesperrten) Mitglieder der Familie unter [ids]; Schlüssel in Kleinbuchstaben. */
export async function aktiveRollen(tx: Executor, familyId: string, ids: readonly string[]): Promise<Map<string, Role>> {
  const out = new Map<string, Role>();
  if (ids.length === 0) return out;
  const rows = await tx
    .select({ id: memberships.userId, role: memberships.role })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, familyId), eq(memberships.status, 'active'), isNull(users.disabledAt), inArray(memberships.userId, [...ids])));
  for (const r of rows) out.set(r.id.toLowerCase(), r.role);
  return out;
}
