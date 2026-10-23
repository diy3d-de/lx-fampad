// Zähler: Zähler und Zählerstände des Haushalts (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6l). Verbrauchsdaten verraten Anwesenheit, darum Ende-zu-Ende verschlüsselt.
//
// Aufbau wie beim Medikamenten-Plan (auf der geprüften Chat-Mechanik), aber EINE verborgene Konversation je Familie (Art `zaehler`, feste ID aus der Familie, `zaehlerChatId`).
// Teilnehmer sind alle Eltern und Admins, NIE ein Kind (Regel in `zaehler-regeln.ts`, vom Server gegen die Rollen der Datenbank erzwungen). Die Teilnehmerliste ist die Sichtgrenze
// (`Facts.participants`, harte Grenze vor jeder Rollenregel); zusätzlich haben Kinder in den Regeltabellen unten gar kein Recht (doppelte Sicherung). Epochenschlüssel und Wraps
// laufen über die vorhandenen Entitäten `epoche` und `epoche_wrap`; Zähler und Stand sind Kinder dieser Konversation und erben ihre Sicht. Keine Nachrichten, kein Push-Wecker
// (Facts.quiet), keine Betreiber-Ansicht, kein Log eines Inhalts.
//  - Zähler: `inhalt` ist eine e1-Hülle (Art, Name, Einheit, Preise mit Gültigkeitsdatum, Periode, Abschlag, Gruppe, Vorgänger, Zustand archiviert, ...). Der Server sieht nur ID,
//    Konversation, Zeitstempel und Größe.
//  - Zählerstand: Kind eines Zählers, `inhalt` ist eine e1-Hülle (Datum, Stand, Notiz). Dauerhaft (keine automatische Löschung: Jahresvergleiche brauchen Jahre).
//  - `bearbeiterId` = Person, die den Inhalt zuletzt geschrieben und signiert hat (setzt der Server), steht im AAD der Hülle.
// Zufalls-IDs (UUID v4): der Server kennt weder Zähler noch Ablesedatum, also keine inhaltsbezogene ID (Doppelte beim gleichzeitigen Erfassen fasst die App zusammen).
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { konversationen, zaehler, zaehlerstaende } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import { ROLES, type Actor, type Facts, type RoleRule, type Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { istUuidV4 } from './chat-ids.js';
import { E1_MIN } from './chat.js';
import { iso, uuid } from './common.js';

/** Größte Hülle eines Zählers / eines Standes (Zeichen). Der Klartext ist in der App auf 8000 bzw. 1000 Byte begrenzt. */
export const MAX_ZAEHLER = 16_384;
export const MAX_STAND = 2048;
/** Lebende Zähler je Haushalt (Konversation), Stände je Zähler. */
export const MAX_ZAEHLER_JE_HAUSHALT = 50;
export const MAX_STAENDE = 5000;
/** Neue Zähler und Stände je Person und Minute/Stunde, Änderungen je Person und Minute. */
export const ZAEHLER_PRO_MINUTE = 20;
export const ZAEHLER_PRO_STUNDE = 200;
export const STAENDE_PRO_MINUTE = 60;
export const STAENDE_PRO_STUNDE = 600;

const huelle = (max: number) => safeString().pipe(z.string().min(E1_MIN).max(max).regex(/^e1:[A-Za-z0-9_-]+$/));

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

type Env = Parameters<NonNullable<EntityDef['validate']>>[0];

/** Die Konversation gehört zur Familie, lebt, ist verschlüsselt (e1) und ist die Zähler-Konversation. */
async function zaehlerKonversation(env: Env, konversationId: string): Promise<boolean> {
  const [k] = await env.tx
    .select({ art: konversationen.art, enc: konversationen.encVersion })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, env.familyId), eq(konversationen.id, konversationId), isNull(konversationen.deletedAt)))
    .limit(1);
  return !!k && k.art === 'zaehler' && k.enc === 'e1';
}

// Lesen, anlegen, ändern, löschen: Eltern und Admins (innerhalb der Teilnehmer-Grenze); Kinder haben KEIN Recht
const erwachsene: RoleRule = { read: 'shared', create: 'shared', update: 'shared', delete: 'shared', updateFields: ['inhalt'] };
const kind: RoleRule = { read: 'none', create: 'none', update: 'none', delete: 'none' };
const planRules = Object.fromEntries(ROLES.map((r) => [r, r === 'child' ? kind : erwachsene])) as unknown as Rules;

// ---------------------------------------------------------------- Zähler

export const zaehlerEntity: EntityDef = {
  name: 'zaehler',
  table: zaehler,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle(MAX_ZAEHLER), required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: planRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['bearbeiterId'],
  idValid: (id: string): boolean => istUuidV4(id),
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  derive: (actor: Actor, changed: Row): Row => ('inhalt' in changed ? { bearbeiterId: actor.userId } : {}),
  maxLive: { per: 'parent', max: MAX_ZAEHLER_JE_HAUSHALT },
  rate: { field: 'bearbeiterId', perMinute: ZAEHLER_PRO_MINUTE, perHour: ZAEHLER_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 60 },
  scrubOnUpdate: ['inhalt'],
  validate: async (env, row: Row): Promise<boolean> => zaehlerKonversation(env, String(row.konversationId)),
};

// ---------------------------------------------------------------- Zählerstand

export const zaehlerstandEntity: EntityDef = {
  name: 'zaehlerstand',
  table: zaehlerstaende,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    zaehlerId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle(MAX_STAND), required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: planRules,
  parent: { entity: 'zaehler', field: 'zaehlerId' },
  userRefs: ['bearbeiterId'],
  idValid: (id: string): boolean => istUuidV4(id),
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  derive: (actor: Actor, changed: Row): Row => ('inhalt' in changed ? { bearbeiterId: actor.userId } : {}),
  maxLive: { per: 'parent', max: MAX_STAENDE },
  rate: { field: 'bearbeiterId', perMinute: STAENDE_PRO_MINUTE, perHour: STAENDE_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 120 },
  scrubOnUpdate: ['inhalt'],
  // der Zähler gehört zur genannten Konversation (und lebt), die Konversation ist die verschlüsselte Zähler-Konversation
  validate: async (env, row: Row): Promise<boolean> => {
    if (!(await zaehlerKonversation(env, String(row.konversationId)))) return false;
    const [z0] = await env.tx
      .select({ id: zaehler.id })
      .from(zaehler)
      .where(and(eq(zaehler.familyId, env.familyId), eq(zaehler.id, String(row.zaehlerId)), eq(zaehler.konversationId, String(row.konversationId)), isNull(zaehler.deletedAt)))
      .limit(1);
    return !!z0;
  },
};
