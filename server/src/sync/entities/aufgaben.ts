// Aufgaben (To-dos) und ihre Unteraufgaben (Phase 1c-4a).
//
// Fälligkeit wie bei Terminen: ein Kalendertag (`faelligDate`, ganztägig) ODER ein Zeitpunkt in UTC (`faelligUtc`) mit IANA-Zeitzone (`tzid`).
// Fristen (`frist`): Aufgaben mit Ablaufdatum; Vorwarnzeit = `erinnerungMin`, Wiederholung alle `fristMonate` Monate (Client legt die nächste an).
// Wiederholung einfach (`daily`/`weekly`/`monthly`): Beim Erledigen legt der Client die nächste Aufgabe an; der Server prüft nur die Form.
//
// Rechte (siehe sync/permissions.ts), wie bei Terminen, dazu die zuständige Person:
//  - Admin/Eltern: alles.
//  - Kind: sieht Aufgaben der Stufe `family`; darf Aufgaben anlegen (nur Stufe `family`) und eigene ändern oder löschen (Freigabe nicht änderbar).
//    Unteraufgaben erben Freigabe, Besitzer und Zuständige der Aufgabe.
//  - Zuständige Person (auch Kind): darf NUR den Erledigt-Status (`erledigtAt`) der ihr zugewiesenen Aufgabe und das Häkchen (`doneAt`) ihrer
//    Unteraufgaben setzen; Titel, Fälligkeit, Zuständige, Freigabe und Löschen bleiben dem Besitzer bzw. den Eltern. `erledigtVon` setzt der Server.
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
      'folgeId',
      'wiederholung',
      'wiederholungTag',
      'erinnerungMin',
      'frist',
      'fristMonate',
    ],
    limits: { audience: ['family'] },
    // zuständige Kinder dürfen nur den Erledigt-Status setzen (erledigtVon setzt der Server)
    assignedFields: ['erledigtAt', 'folgeId'],
  },
};

const punktRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: { read: 'shared', create: 'own', update: 'own', delete: 'own', assignedFields: ['doneAt'] },
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
    // setzt der Server (Akteur beim Erledigen, sonst leer): der Client sendet es nie (sonst invalid)
    erledigtVon: { access: 'server', schema: uuid.nullable(), blank: null },
    // ID der beim Erledigen angelegten Folgeaufgabe (der Client setzt sie mit dem Erledigen; verhindert doppelte Folgeaufgaben)
    folgeId: { access: 'rw', schema: uuid.nullable(), defaultValue: null, blank: null },
    wiederholungTag: { access: 'rw', schema: z.number().int().min(1).max(31).nullable(), defaultValue: null, blank: null },
    wiederholung: { access: 'rw', schema: z.enum(AUFGABE_WIEDERHOLUNGEN).nullable(), defaultValue: null, blank: null },
    // bis 365 Tage (Vorwarnzeit der Fristen); die App bietet bei normalen Aufgaben weiter höchstens 1 Tag an
    erinnerungMin: { access: 'rw', schema: z.number().int().min(0).max(525600).nullable(), defaultValue: null },
    // Fristen-Tracker: additiv, alte Apps ignorieren beides und zeigen die Frist als normale Aufgabe
    frist: { access: 'rw', schema: z.boolean(), defaultValue: false, blank: false },
    fristMonate: { access: 'rw', schema: z.number().int().min(1).max(120).nullable(), defaultValue: null, blank: null },
    audience: { access: 'rw', schema: AUDIENCE_INPUT, defaultValue: 'family' },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: aufgabeRules,
  visibilityFields: ['audience'],
  userRefs: ['ownerId', 'assigneeId', 'erledigtVon'],
  facts: (row: Row): Facts => ({ audience: row.audience as Facts['audience'], ownerId: (row.ownerId as string | null) ?? null, assigneeId: (row.assigneeId as string | null) ?? null }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({
    audience: (values.audience as Facts['audience'] | undefined) ?? 'family',
    ownerId: actor.userId,
    assigneeId: (values.assigneeId as string | null | undefined) ?? null,
  }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  derive: (actor: Actor, changed: Row): Row => (changed.erledigtAt === undefined ? {} : { erledigtVon: changed.erledigtAt === null ? null : actor.userId }),
  check: aufgabeFaelligValid,
  // Obergrenze für OFFENE Aufgaben (Erledigte füllen sie nicht); alle lebenden zusammen höchstens 20000
  maxLive: { per: 'family', max: 5000, openColumn: 'erledigtAt' },
  maxFamily: 20000,
  // ein Kinderkonto kann die Familienobergrenze nicht allein füllen (zählt nur offene)
  ownerLimit: { field: 'ownerId', roles: ['child'], max: 500, openColumn: 'erledigtAt' },
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
  maxFamily: 50000,
};
