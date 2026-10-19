// Aufgaben (To-dos) und ihre Unteraufgaben (Phase 1c-4a).
//
// Fälligkeit wie bei Terminen: ein Kalendertag (`faelligDate`, ganztägig) ODER ein Zeitpunkt in UTC (`faelligUtc`) mit IANA-Zeitzone (`tzid`).
// Wiederholung einfach (`daily`/`weekly`/`monthly`): Beim Erledigen legt der Client die nächste Aufgabe an; der Server prüft nur die Form.
//
// Rechte (siehe sync/permissions.ts), wie bei Terminen:
//  - Admin/Eltern: alles.
//  - Kind: sieht Aufgaben der Stufe `family`; darf Aufgaben anlegen (nur Stufe `family`) und eigene ändern oder löschen (Freigabe nicht änderbar).
//    Unteraufgaben erben Freigabe und Besitzer der Aufgabe.
import { z } from 'zod';
import { aufgabePunkte, aufgaben } from '../../db/schema.js';
import type { Actor, Facts, Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { AUDIENCE_INPUT, iso, timestamp, trimmed, uuid } from './common.js';
import { calendarDate, freeText, tzid } from './termine.js';

export const AUFGABE_WIEDERHOLUNGEN = ['daily', 'weekly', 'monthly'] as const;

const fullAccess = { read: 'all', create: 'all', update: 'all', delete: 'all' } as const;

const aufgabeRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: {
    read: 'shared',
    create: 'all',
    update: 'own',
    delete: 'own',
    updateFields: [
      'titel',
      'beschreibung',
      'faelligDate',
      'faelligUtc',
      'tzid',
      'prioritaet',
      'assigneeId',
      'erledigtAt',
      'erledigtVon',
      'wiederholung',
      'erinnerungMin',
    ],
    limits: { audience: ['family'] },
  },
};

const punktRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: { read: 'shared', create: 'own', update: 'own', delete: 'own' },
};

/** Stimmigkeit der Fälligkeit (entspricht `aufgaben_faellig_ck`): Tag oder Zeitpunkt, nie beides; ein Zeitpunkt braucht eine Zeitzone. */
export function aufgabeFaelligValid(row: Row): boolean {
  const datum = row.faelligDate ?? null;
  const utc = row.faelligUtc ?? null;
  if (datum !== null && utc !== null) return false;
  if (utc !== null && typeof row.tzid !== 'string') return false;
  return true;
}

export const aufgabeEntity: EntityDef = {
  name: 'aufgabe',
  table: aufgaben,
  fields: {
    titel: { access: 'rw', schema: trimmed(200), required: true, blank: '' },
    beschreibung: { access: 'rw', schema: freeText(4000), defaultValue: '', blank: '' },
    faelligDate: { access: 'rw', schema: calendarDate.nullable(), defaultValue: null },
    faelligUtc: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, toWire: iso },
    tzid: { access: 'rw', schema: tzid.nullable(), defaultValue: null },
    prioritaet: { access: 'rw', schema: z.number().int().min(0).max(3), defaultValue: 0, blank: 0 },
    assigneeId: { access: 'rw', schema: uuid.nullable(), defaultValue: null, blank: null, memberRef: true },
    erledigtAt: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, blank: null, toWire: iso },
    erledigtVon: { access: 'rw', schema: uuid.nullable(), defaultValue: null, blank: null, memberRef: true },
    wiederholung: { access: 'rw', schema: z.enum(AUFGABE_WIEDERHOLUNGEN).nullable(), defaultValue: null, blank: null },
    erinnerungMin: { access: 'rw', schema: z.number().int().min(0).max(40320).nullable(), defaultValue: null },
    audience: { access: 'rw', schema: AUDIENCE_INPUT, defaultValue: 'family' },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: aufgabeRules,
  visibilityFields: ['audience'],
  userRefs: ['ownerId', 'assigneeId', 'erledigtVon'],
  facts: (row: Row): Facts => ({ audience: row.audience as Facts['audience'], ownerId: (row.ownerId as string | null) ?? null }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({ audience: (values.audience as Facts['audience'] | undefined) ?? 'family', ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  check: aufgabeFaelligValid,
  maxLive: { per: 'family', max: 5000 },
  // ein Kinderkonto kann die Familienobergrenze nicht allein füllen
  ownerLimit: { field: 'ownerId', roles: ['child'], max: 500 },
};

export const aufgabePunktEntity: EntityDef = {
  name: 'aufgabe_punkt',
  table: aufgabePunkte,
  fields: {
    aufgabeId: { access: 'create', schema: uuid, required: true },
    text: { access: 'rw', schema: trimmed(500), required: true, blank: '' },
    doneAt: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, blank: null, toWire: iso },
    position: { access: 'rw', schema: z.number().min(-1e12).max(1e12), defaultValue: 0, blank: 0 },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: punktRules,
  parent: { entity: 'aufgabe', field: 'aufgabeId' },
  facts: (_row: Row, parent: Facts | null): Facts => parent ?? { audience: 'parents', ownerId: null },
  factsForCreate: (_actor: Actor, _values: Row, parent: Facts | null): Facts => parent ?? { audience: 'parents', ownerId: null },
  maxLive: { per: 'parent', max: 100 },
};
