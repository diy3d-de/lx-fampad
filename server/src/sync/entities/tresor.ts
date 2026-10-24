// Tresor: Einträge des gemeinsamen Eltern-Tresors (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6m). Zugangsdaten, Ausweis- und Versicherungsnummern, Notfall-Infos: alles Ende-zu-Ende verschlüsselt.
//
// Aufbau wie bei den Zählern (auf der geprüften Chat-Mechanik): EINE verborgene Konversation je Familie (Art `tresor`, feste ID aus der Familie, `tresorChatId`). Teilnehmer sind alle
// Eltern und Admins, NIE ein Kind (Regel in `tresor-regeln.ts`, vom Server gegen die Rollen der Datenbank erzwungen). Es gibt EINEN gemeinsamen Tresor, keinen persönlichen je Person:
// alle Teilnehmer lesen und bearbeiten alle Einträge. Die Teilnehmerliste ist die Sichtgrenze (`Facts.participants`, harte Grenze vor jeder Rollenregel); zusätzlich haben Kinder in der
// Regeltabelle unten gar kein Recht (doppelte Sicherung). Epochenschlüssel und Wraps laufen über die vorhandenen Entitäten `epoche` und `epoche_wrap`; der Eintrag ist ein Kind der
// Konversation und erbt ihre Sicht. Keine Nachrichten, kein Push-Wecker (Facts.quiet), keine Betreiber-Ansicht, kein Log eines Inhalts.
//  - `inhalt` ist eine e1-Hülle (Kategorie, Titel, Felder mit Bezeichnung/Wert/geheim, Notiz, Vorlage). Der Server sieht nur ID, Konversation, Zeitstempel und Größe.
//  - `bearbeiterId` = Person, die den Inhalt zuletzt geschrieben und signiert hat (setzt der Server), steht im AAD der Hülle.
//  - Dauerhaft: keine Fristen und keine automatische Löschung aus Einträgen (der Server kann nichts darin lesen, ein Ablaufdatum wäre unverschlüsselt).
// Zufalls-IDs (UUID v4): der Server kennt weder Titel noch Kategorie, also keine inhaltsbezogene ID.
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { konversationen, tresorEintraege } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import { ROLES, type Actor, type Facts, type RoleRule, type Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { istUuidV4 } from './chat-ids.js';
import { E1_MIN } from './chat.js';
import { iso, uuid } from './common.js';

/** Größte Hülle eines Eintrags (Zeichen). Der Klartext ist in der App auf 16000 Byte begrenzt (Base64url macht daraus rund 21 700 Zeichen). */
export const MAX_TRESOR_EINTRAG = 24_576;
/** Lebende Einträge je Tresor (Konversation). */
export const MAX_TRESOR_EINTRAEGE = 500;
/** Neue Einträge je Person und Minute/Stunde, Änderungen je Person und Minute. */
export const TRESOR_PRO_MINUTE = 30;
export const TRESOR_PRO_STUNDE = 300;

const huelle = safeString().pipe(z.string().min(E1_MIN).max(MAX_TRESOR_EINTRAG).regex(/^e1:[A-Za-z0-9_-]+$/));

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

type Env = Parameters<NonNullable<EntityDef['validate']>>[0];

/** Die Konversation gehört zur Familie, lebt, ist verschlüsselt (e1) und ist die Tresor-Konversation. */
async function tresorKonversation(env: Env, konversationId: string): Promise<boolean> {
  const [k] = await env.tx
    .select({ art: konversationen.art, enc: konversationen.encVersion })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, env.familyId), eq(konversationen.id, konversationId), isNull(konversationen.deletedAt)))
    .limit(1);
  return !!k && k.art === 'tresor' && k.enc === 'e1';
}

// Lesen, anlegen, ändern, löschen: Eltern und Admins (innerhalb der Teilnehmer-Grenze); Kinder haben KEIN Recht
const erwachsene: RoleRule = { read: 'shared', create: 'shared', update: 'shared', delete: 'shared', updateFields: ['inhalt'] };
const kind: RoleRule = { read: 'none', create: 'none', update: 'none', delete: 'none' };
const tresorRules = Object.fromEntries(ROLES.map((r) => [r, r === 'child' ? kind : erwachsene])) as unknown as Rules;

export const tresorEintragEntity: EntityDef = {
  name: 'tresor_eintrag',
  table: tresorEintraege,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle, required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: tresorRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['bearbeiterId'],
  idValid: (id: string): boolean => istUuidV4(id),
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  derive: (actor: Actor, changed: Row): Row => ('inhalt' in changed ? { bearbeiterId: actor.userId } : {}),
  maxLive: { per: 'parent', max: MAX_TRESOR_EINTRAEGE },
  rate: { field: 'bearbeiterId', perMinute: TRESOR_PRO_MINUTE, perHour: TRESOR_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 60 },
  scrubOnUpdate: ['inhalt'],
  validate: async (env, row: Row): Promise<boolean> => tresorKonversation(env, String(row.konversationId)),
};
