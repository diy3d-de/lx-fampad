// Chat: Konversationen (Familienchat, Direktchat, Gruppe), Nachrichten und Lesestand (Phase 1c-3a). Siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6c.
//
// Sichtbarkeit (sync/permissions.ts, Facts.participants): Direkt- und Gruppenchats sehen NUR ihre Teilnehmer, auch Admins und Eltern nicht (kein
// Rollen-Durchgriff, nirgends). Der Familienchat hat keine Teilnehmerliste und gehört der ganzen Familie (alle aktiven Mitglieder, auch später
// hinzugekommene). Nachrichten und Lesestände erben die Sicht der Konversation.
//
// Rechte:
//  - Konversation: anlegen darf jede Person (Kinder auch Gruppen; Teilnehmer sind immer Familienmitglieder, der Server prüft das). Der Familienchat
//    wird von der ersten App angelegt, die ihn nicht findet (jede Rolle; ein zweiter wird abgelehnt: eindeutiger Index, `not_found`); danach
//    ist er für alle unveränderlich und nicht löschbar. Direktchats sind unveränderlich und
//    werden nicht gelöscht (ihre ID ist je Paar fest, siehe App). Gruppen: jeder Teilnehmer darf Namen und Teilnehmer ändern (auch sich selbst
//    entfernen), löschen nur, wer sie angelegt hat.
//  - Nachricht: schreiben jede Person mit Sicht; bearbeiten und löschen nur der Autor. Ausnahme: Admins dürfen im Familienchat fremde Nachrichten
//    löschen (Moderation), nie in privaten Chats (die sie nicht sehen).
//  - Lesestand: nur die eigene Zeile les- und schreibbar.
// Inhalte (`text`, `titel`) sind für den Server undurchsichtige Zeichenketten (E2EE-vorbereitet): nur Länge und Zeichensatz werden geprüft.
import { z } from 'zod';
import { konversationen, lesestand, nachrichten } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import { ROLES, type Actor, type Facts, type RoleRule, type Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { iso, timestamp, uuid } from './common.js';

export const KONVERSATION_ARTEN = ['family', 'direct', 'group'] as const;
/** Teilnehmer je Gruppe (einschließlich der anlegenden Person). */
export const MAX_GRUPPE = 20;
/** Obergrenze des undurchsichtigen Nachrichtentextes (Zeichen; die Hülle für spätere Verschlüsselung braucht Platz). */
export const MAX_NACHRICHT = 16384;
export const MAX_TITEL = 512;
/** Neue Nachrichten je Person und Minute. */
export const NACHRICHTEN_PRO_MINUTE = 60;

/** Undurchsichtiger Text: nur Länge und Zeichensatz (keine NUL/Surrogate), keine Auswertung, kein Trimmen. */
const opaque = (max: number, min: number) => safeString().pipe(z.string().min(min).max(max));

/** Teilnehmerliste: eindeutig und sortiert (damit "dasselbe Paar" immer dieselbe Liste ergibt; der Server erzwingt je Paar einen Direktchat). */
const teilnehmerListe = z
  .array(uuid)
  .max(MAX_GRUPPE)
  .transform((l) => [...new Set(l.map((u) => u.toLowerCase()))].sort());

/** Dieselbe Regel für alle Rollen (Rollen spielen bei privaten Chats keine Rolle); das Rechte-Modell erzwingt die Teilnehmer-Grenze selbst. */
function forAllRoles(rule: RoleRule, admin: Partial<RoleRule> = {}): Rules {
  const rules = Object.fromEntries(ROLES.map((r) => [r, rule])) as unknown as Record<string, RoleRule>;
  rules.admin = { ...rule, ...admin };
  return rules as unknown as Rules;
}

const strings = (v: unknown): string[] => (Array.isArray(v) ? (v as string[]) : []);

// ---------------------------------------------------------------- Konversation

const konversationRules = forAllRoles({ read: 'shared', create: 'shared', update: 'shared', delete: 'own', updateFields: ['titel', 'teilnehmer'] });

/** Stimmigkeit je Art. Der Familienchat hat weder Namen noch Teilnehmer (ihn sieht die ganze Familie). */
export function konversationValid(row: Row): boolean {
  const t = strings(row.teilnehmer);
  switch (row.art) {
    case 'direct':
      return t.length === 2 && row.titel === '';
    case 'group':
      return t.length >= 2 && t.length <= MAX_GRUPPE;
    case 'family':
      return t.length === 0 && row.titel === '';
    default:
      return false;
  }
}

const sameList = (a: unknown, b: unknown): boolean => JSON.stringify(strings(a)) === JSON.stringify(strings(b));

export const konversationEntity: EntityDef = {
  name: 'konversation',
  table: konversationen,
  fields: {
    art: { access: 'create', schema: z.enum(KONVERSATION_ARTEN), required: true },
    titel: { access: 'rw', schema: opaque(MAX_TITEL, 0), defaultValue: '', blank: '' },
    // bleibt auch im Tombstone erhalten: die Löschung bleibt dadurch für Teilnehmer sichtbar und für alle anderen unsichtbar
    teilnehmer: { access: 'rw', schema: teilnehmerListe, defaultValue: [], memberRef: true },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: konversationRules,
  visibilityFields: ['teilnehmer'],
  userRefs: ['ownerId'],
  memberArray: { field: 'teilnehmer', keepMin: () => 2 },
  lostSight: (before: Row, after: Row): string[] => {
    const rest = new Set(strings(after.teilnehmer));
    return strings(before.teilnehmer).filter((u) => !rest.has(u));
  },
  facts: (row: Row): Facts => ({
    audience: 'family',
    ownerId: (row.ownerId as string | null) ?? null,
    participants: row.art === 'family' ? undefined : strings(row.teilnehmer),
  }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({
    audience: 'family',
    ownerId: actor.userId,
    participants: values.art === 'family' ? undefined : strings(values.teilnehmer),
  }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  check: konversationValid,
  guard: (action, before, after) => {
    if (action === 'delete') return before.art === 'group';
    if (before.art === 'group') return true;
    // Familienchat und Direktchat: Name und Teilnehmer bleiben, wie sie sind
    return !!after && before.titel === after.titel && sameList(before.teilnehmer, after.teilnehmer);
  },
  maxLive: { per: 'family', max: 500 },
  ownerLimit: { field: 'ownerId', roles: ['admin', 'parent', 'child'], max: 100 },
};

// ---------------------------------------------------------------- Nachricht

const nachrichtRules = forAllRoles({ read: 'shared', create: 'shared', update: 'own', delete: 'own', updateFields: ['text'] }, { delete: 'own_or_open' });

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

export const nachrichtEntity: EntityDef = {
  name: 'nachricht',
  table: nachrichten,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    text: { access: 'rw', schema: opaque(MAX_NACHRICHT, 1), required: true, blank: '' },
    antwortAuf: { access: 'create', schema: uuid.nullable(), defaultValue: null },
    autorId: { access: 'server', schema: uuid.nullable() },
    bearbeitetAt: { access: 'server', schema: z.unknown(), toWire: iso },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: nachrichtRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['autorId'],
  // Sicht der Konversation, "Besitzer" ist der Autor
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.autorId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ autorId: actor.userId }),
  onUpdate: (changed: Row, now: Date): Row => ('text' in changed ? { bearbeitetAt: now } : {}),
  rate: { field: 'autorId', perMinute: NACHRICHTEN_PRO_MINUTE },
};

// ---------------------------------------------------------------- Lesestand

const lesestandRules = forAllRoles({ read: 'own', create: 'own', update: 'own', delete: 'none' });

export const lesestandEntity: EntityDef = {
  name: 'lesestand',
  table: lesestand,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    userId: { access: 'create', schema: uuid, required: true, memberRef: true },
    gelesenBis: { access: 'rw', schema: timestamp, required: true, toWire: iso },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: lesestandRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  memberOwned: 'userId',
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.userId as string | null) ?? null }),
  factsForCreate: (_actor: Actor, values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (values.userId as string | undefined) ?? null }),
  maxLive: { per: 'parent', max: 50 },
};
