// Chat-Erweiterungen: Reaktionen, Umfrage-Stimmen und angeheftete Nachrichten (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6c).
//
// Alle drei hängen an einer Nachricht (`parent`), erben deren Teilnehmer-Grenze (Direkt-/Gruppenchats sehen nur ihre Teilnehmer, nie ein Rollen-Durchgriff) und werden
// mit ihr gelöscht (Kaskade, Tombstone).
//  - Reaktion und Stimme: feste ID je (Nachricht, Person) (`chat-ids.ts`), Besitzer ist die Person (nur die eigene Zeile anlegen, ändern, löschen; wie der Lesestand).
//    `inhalt` ist eine Ende-zu-Ende verschlüsselte, signierte e1-Hülle (Emoji bzw. gewählte Optionen): der Server prüft nur Form und Größe, nie den Inhalt. Der Server
//    weiß also nicht, WAS jemand reagiert oder gewählt hat, nur DASS (Person, Nachricht, Zeitpunkt). Lesen: alle mit Sicht auf die Nachricht. Kein Push-Wecker.
//  - Pin: feste ID je Nachricht, kein Inhalt (der Server sieht nur, WELCHE Nachricht angeheftet ist). Anheften darf jede Person mit Sicht; im Familienchat nur Eltern und
//    Admins. Lösen: Eltern/Admins jeden Pin, Kinder nur ihre eigenen. Höchstens `MAX_PINS` je Konversation.
// Umfragen sind keine eigene Entität, sondern eine Nachrichtenart in der verschlüsselten Nutzlast der Nachricht (App); der Server kennt sie nicht.
import { and, count, eq, isNull, ne } from 'drizzle-orm';
import { z } from 'zod';
import { konversationen, nachrichten, pins, reaktionen, stimmen } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import type { Actor, Facts, Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { pinId, reaktionId, stimmeId } from './chat-ids.js';
import { E1_MIN, forAllRoles } from './chat.js';
import { iso, uuid } from './common.js';

/** Größte Hülle einer Reaktion oder Stimme (Zeichen; Kopf, Signatur und Tag brauchen ~180, der Klartext ist winzig). */
export const MAX_ZUSATZ = 512;
/** Reaktionen und Stimmen je Nachricht (lebende Zeilen). */
export const MAX_REAKTIONEN_JE_NACHRICHT = 50;
/** Neue Reaktionen und Stimmen je Person und Minute/Stunde, Änderungen je Person und Minute. */
export const REAKTIONEN_PRO_MINUTE = 60;
export const REAKTIONEN_PRO_STUNDE = 600;
export const STIMMEN_PRO_MINUTE = 30;
export const STIMMEN_PRO_STUNDE = 300;
/** Angeheftete Nachrichten je Konversation. */
export const MAX_PINS = 5;
export const PINS_PRO_MINUTE = 10;

const huelle = safeString().pipe(z.string().min(E1_MIN).max(MAX_ZUSATZ).regex(/^e1:[A-Za-z0-9_-]+$/));

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

type Env = Parameters<NonNullable<EntityDef['validate']>>[0];

/** Die Nachricht gehört zur genannten Konversation (und lebt), die Konversation ist verschlüsselt (e1). Liefert die Art der Konversation. */
async function nachrichtInKonversation(env: Env, row: Row): Promise<{ art: string } | undefined> {
  const [n] = await env.tx
    .select({ art: konversationen.art, enc: konversationen.encVersion })
    .from(nachrichten)
    .innerJoin(konversationen, and(eq(konversationen.familyId, nachrichten.familyId), eq(konversationen.id, nachrichten.konversationId)))
    .where(
      and(
        eq(nachrichten.familyId, env.familyId),
        eq(nachrichten.id, String(row.nachrichtId)),
        eq(nachrichten.konversationId, String(row.konversationId)),
        isNull(nachrichten.deletedAt),
        isNull(konversationen.deletedAt),
      ),
    )
    .limit(1);
  return n && n.enc === 'e1' ? { art: n.art } : undefined;
}

// Lesen: alle mit Sicht auf die Nachricht (Anzeige "wer"); anlegen, ändern, löschen nur die eigene Zeile
const eigeneRules = forAllRoles({ read: 'shared', create: 'own', update: 'own', delete: 'own', updateFields: ['inhalt'] });

// ---------------------------------------------------------------- Reaktion

export const reaktionEntity: EntityDef = {
  name: 'reaktion',
  table: reaktionen,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    nachrichtId: { access: 'create', schema: uuid, required: true },
    userId: { access: 'create', schema: uuid, required: true, memberRef: true },
    inhalt: { access: 'rw', schema: huelle, required: true, blank: '' },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: eigeneRules,
  parent: { entity: 'nachricht', field: 'nachrichtId' },
  memberOwned: 'userId',
  // feste ID je (Nachricht, Person); löschen = Tombstone, erneutes Reagieren belebt dieselbe Zeile wieder
  idValid: (id: string, values: Row): boolean => id === reaktionId(String(values.nachrichtId), String(values.userId)),
  revive: (): boolean => true,
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.userId as string | null) ?? null }),
  factsForCreate: (_actor: Actor, values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (values.userId as string | undefined) ?? null }),
  maxLive: { per: 'parent', max: MAX_REAKTIONEN_JE_NACHRICHT },
  rate: { field: 'userId', perMinute: REAKTIONEN_PRO_MINUTE, perHour: REAKTIONEN_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: REAKTIONEN_PRO_MINUTE },
  scrubOnUpdate: ['inhalt'],
  validate: async (env, row: Row): Promise<boolean> => !!(await nachrichtInKonversation(env, row)),
};

// ---------------------------------------------------------------- Stimme

export const stimmeEntity: EntityDef = {
  name: 'stimme',
  table: stimmen,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    nachrichtId: { access: 'create', schema: uuid, required: true },
    userId: { access: 'create', schema: uuid, required: true, memberRef: true },
    inhalt: { access: 'rw', schema: huelle, required: true, blank: '' },
    geaendertAt: { access: 'server', schema: z.unknown(), toWire: iso },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: eigeneRules,
  parent: { entity: 'nachricht', field: 'nachrichtId' },
  memberOwned: 'userId',
  idValid: (id: string, values: Row): boolean => id === stimmeId(String(values.nachrichtId), String(values.userId)),
  revive: (): boolean => true,
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.userId as string | null) ?? null }),
  factsForCreate: (_actor: Actor, values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (values.userId as string | undefined) ?? null }),
  // Zeit der Stimme: bei JEDEM Anlegen und Wiederbeleben (nach Löschen) und jeder Änderung des Inhalts setzt der Server sie neu; sonst ließe sich das Ende einer Umfrage
  // durch Löschen und erneutes Abstimmen umgehen
  onCreate: (_actor: Actor, now: Date): Row => ({ geaendertAt: now }),
  onUpdate: (changed: Row, now: Date): Row => ('inhalt' in changed ? { geaendertAt: now } : {}),
  maxLive: { per: 'parent', max: MAX_REAKTIONEN_JE_NACHRICHT },
  rate: { field: 'userId', perMinute: STIMMEN_PRO_MINUTE, perHour: STIMMEN_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: STIMMEN_PRO_MINUTE },
  scrubOnUpdate: ['inhalt'],
  validate: async (env, row: Row): Promise<boolean> => !!(await nachrichtInKonversation(env, row)),
};

// ---------------------------------------------------------------- Pin

const pinRules = ((): Rules => {
  const basis = forAllRoles({ read: 'shared', create: 'shared', update: 'none', delete: 'shared', updateFields: [] });
  return { ...basis, child: { ...basis.child, delete: 'own' } };
})();

export const pinEntity: EntityDef = {
  name: 'pin',
  table: pins,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    nachrichtId: { access: 'create', schema: uuid, required: true },
    gepinntVon: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: pinRules,
  parent: { entity: 'nachricht', field: 'nachrichtId' },
  userRefs: ['gepinntVon'],
  idValid: (id: string, values: Row): boolean => id === pinId(String(values.nachrichtId)),
  revive: (): boolean => true,
  noWake: true,
  // Besitzer = wer angeheftet hat (Kinder lösen nur eigene Pins); Teilnehmer-Grenze von der Nachricht geerbt
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.gepinntVon as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ gepinntVon: actor.userId }),
  rate: { field: 'gepinntVon', perMinute: PINS_PRO_MINUTE },
  validate: async (env, row: Row): Promise<boolean> => {
    const k = await nachrichtInKonversation(env, row);
    if (!k) return false;
    // im Familienchat heften nur Eltern und Admins an (Kinder sehen die Pins, ändern sie aber nicht)
    if (k.art === 'family' && env.actor.role === 'child') return false;
    // Grenze parallelitätssicher: die Konversationszeile sperren, damit gleichzeitige Anheftungen nacheinander zählen
    await env.tx.select({ id: konversationen.id }).from(konversationen).where(and(eq(konversationen.familyId, env.familyId), eq(konversationen.id, String(row.konversationId)))).for('update');
    const [n] = await env.tx
      .select({ n: count() })
      .from(pins)
      .where(and(eq(pins.familyId, env.familyId), eq(pins.konversationId, String(row.konversationId)), isNull(pins.deletedAt), ne(pins.id, String(row.id))));
    return (n?.n ?? 0) < MAX_PINS;
  },
};
