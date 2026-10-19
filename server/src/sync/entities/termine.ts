// Kalender: Termine, ihre Teilnehmer und die Ausnahmen einer Terminserie (Phase 1c-2a).
//
// Zeitmodell (siehe db/schema.ts): Zeittermine = Zeitpunkte in UTC + IANA-Zeitzone (`tzid`), ganztägige = Kalendertage mit exklusivem Ende.
// Die Wiederholung (`rrule`) rechnet der Client in der Wanduhrzeit der `tzid`; der Server prüft nur die Form (sync/rrule.ts).
//
// Rechte (siehe sync/permissions.ts):
//  - Admin/Eltern: alles.
//  - Kind: sieht Termine der Stufe `family`; darf Termine anlegen (nur Stufe `family`) und eigene ändern oder löschen
//    (Freigabe nicht änderbar). Teilnehmer und Ausnahmen erben Freigabe und Besitzer des Termins: ein Kind pflegt sie nur an eigenen Terminen.
import { z } from 'zod';
import { termine, terminAusnahmen, terminTeilnehmer } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import type { Actor, Facts, Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { isValidRrule, RRULE_MAX_LENGTH } from '../rrule.js';
import { AUDIENCE_INPUT, iso, timestamp, trimmed, uuid } from './common.js';

/** Kalendertag `YYYY-MM-DD` (echtes Datum, Jahr 2000 bis 2199). */
export const calendarDate = safeString()
  .pipe(z.string().regex(/^\d{4}-\d{2}-\d{2}$/))
  .refine((s) => {
    const y = Number(s.slice(0, 4));
    const m = Number(s.slice(5, 7));
    const d = Number(s.slice(8, 10));
    if (y < 2000 || y >= 2200) return false;
    const date = new Date(Date.UTC(y, m - 1, d));
    return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
  }, 'ungültiges Datum');

/** Beginn/Ende eines Vorkommens: ein Kalendertag oder ein Zeitpunkt, normalisiert auf `YYYY-MM-DDTHH:MM:SSZ` (UTC). */
export const occurrenceStamp = z.union([calendarDate, timestamp.transform((d) => d.toISOString().replace(/\.\d{3}Z$/, 'Z'))]);

const isDateStamp = (s: string): boolean => s.length === 10;

/**
 * IANA-Zeitzone: muss der Laufzeit bekannt sein und in der Schreibweise der IANA-Datenbank stehen (Groß-/Kleinschreibung: die Zeitzonen-Datenbank
 * der App unterscheidet sie, "europe/berlin" fiele dort auf die Familienzone zurück). Ältere Namen (z. B. Asia/Kolkata) bleiben erlaubt.
 */
export function isIanaTimeZone(s: string): boolean {
  try {
    const resolved = new Intl.DateTimeFormat('en', { timeZone: s }).resolvedOptions().timeZone;
    return resolved === s || resolved.toLowerCase() !== s.toLowerCase();
  } catch {
    return false;
  }
}

const tzid = safeString()
  .pipe(z.string().min(1).max(64).regex(/^[A-Za-z][A-Za-z0-9_+\-/]*$/))
  .refine(isIanaTimeZone, 'unbekannte Zeitzone');

const rrule = safeString().pipe(z.string().min(1).max(RRULE_MAX_LENGTH)).refine(isValidRrule, 'ungültige Wiederholungsregel');
const freeText = (max: number) => safeString().pipe(z.string().trim().max(max));

const fullAccess = { read: 'all', create: 'all', update: 'all', delete: 'all' } as const;

const terminRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: {
    read: 'shared',
    create: 'all',
    update: 'own',
    delete: 'own',
    updateFields: ['titel', 'ort', 'beschreibung', 'ganztaegig', 'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate', 'rrule', 'erinnerungMin', 'icalUid'],
    limits: { audience: ['family'] },
  },
};

/** Teilnehmer: wie der Termin. */
const teilnehmerRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: { read: 'shared', create: 'own', update: 'own', delete: 'own' },
};

/** Ausnahmen: Rechte des Termins (Freigabe und Besitzer werden vererbt). */
const childRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: { read: 'shared', create: 'own', update: 'own', delete: 'own' },
};

const inherited = (_row: Row, parent: Facts | null): Facts => parent ?? { audience: 'parents', ownerId: null };
const inheritedForCreate = (_actor: Actor, _values: Row, parent: Facts | null): Facts => parent ?? { audience: 'parents', ownerId: null };

const time = (v: unknown): number | null => (v instanceof Date ? v.getTime() : null);

/** Stimmigkeit der Zeitangaben (entspricht `termine_zeit_ck` in der Datenbank). */
export function terminTimesValid(row: Row): boolean {
  if (row.ganztaegig === true) {
    const s = row.startDate;
    const e = row.endDate;
    return typeof s === 'string' && typeof e === 'string' && e > s;
  }
  const s = time(row.startUtc);
  const e = time(row.endUtc);
  return s !== null && e !== null && e >= s && typeof row.tzid === 'string';
}

export const terminEntity: EntityDef = {
  name: 'termin',
  table: termine,
  fields: {
    titel: { access: 'rw', schema: trimmed(200), required: true, blank: '' },
    ort: { access: 'rw', schema: freeText(200), defaultValue: '', blank: '' },
    beschreibung: { access: 'rw', schema: freeText(4000), defaultValue: '', blank: '' },
    ganztaegig: { access: 'rw', schema: z.boolean(), defaultValue: false },
    startUtc: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, toWire: iso },
    endUtc: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, toWire: iso },
    tzid: { access: 'rw', schema: tzid.nullable(), defaultValue: null },
    startDate: { access: 'rw', schema: calendarDate.nullable(), defaultValue: null },
    endDate: { access: 'rw', schema: calendarDate.nullable(), defaultValue: null },
    rrule: { access: 'rw', schema: rrule.nullable(), defaultValue: null, blank: null },
    erinnerungMin: { access: 'rw', schema: z.number().int().min(0).max(40320).nullable(), defaultValue: null },
    icalUid: { access: 'rw', schema: trimmed(255).nullable(), defaultValue: null, blank: null },
    audience: { access: 'rw', schema: AUDIENCE_INPUT, defaultValue: 'family' },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: terminRules,
  visibilityFields: ['audience'],
  userRefs: ['ownerId'],
  facts: (row: Row): Facts => ({ audience: row.audience as Facts['audience'], ownerId: (row.ownerId as string | null) ?? null }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({ audience: (values.audience as Facts['audience'] | undefined) ?? 'family', ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  check: terminTimesValid,
  maxLive: { per: 'family', max: 5000 },
  // ein Kinderkonto kann die Familienobergrenze nicht allein füllen
  ownerLimit: { field: 'ownerId', roles: ['child'], max: 500 },
};

export const terminTeilnehmerEntity: EntityDef = {
  name: 'termin_teilnehmer',
  table: terminTeilnehmer,
  fields: {
    terminId: { access: 'create', schema: uuid, required: true },
    userId: { access: 'create', schema: uuid, required: true, memberRef: true },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: teilnehmerRules,
  parent: { entity: 'termin', field: 'terminId' },
  memberOwned: 'userId',
  facts: inherited,
  factsForCreate: inheritedForCreate,
  maxLive: { per: 'parent', max: 50 },
};

/** Stimmigkeit einer Ausnahme: Beginn/Ende haben dieselbe Art (Tag oder Zeitpunkt) wie das ursprüngliche Vorkommen, Ende nicht vor Beginn. */
export function ausnahmeValid(row: Row): boolean {
  const original = row.originalStart;
  if (typeof original !== 'string') return false;
  const kind = isDateStamp(original);
  const start = row.start;
  const ende = row.ende;
  for (const v of [start, ende]) if (typeof v === 'string' && isDateStamp(v) !== kind) return false;
  // ganztägig ist das Ende exklusiv (mindestens der Folgetag), sonst nicht vor dem Beginn
  if (typeof start === 'string' && typeof ende === 'string' && (kind ? ende <= start : ende < start)) return false;
  return true;
}

export const terminAusnahmeEntity: EntityDef = {
  name: 'termin_ausnahmen',
  table: terminAusnahmen,
  fields: {
    terminId: { access: 'create', schema: uuid, required: true },
    originalStart: { access: 'create', schema: occurrenceStamp, required: true },
    abgesagt: { access: 'rw', schema: z.boolean(), defaultValue: false, blank: false },
    titel: { access: 'rw', schema: trimmed(200).nullable(), defaultValue: null, blank: null },
    start: { access: 'rw', schema: occurrenceStamp.nullable(), defaultValue: null, blank: null },
    ende: { access: 'rw', schema: occurrenceStamp.nullable(), defaultValue: null, blank: null },
    ort: { access: 'rw', schema: freeText(200).nullable(), defaultValue: null, blank: null },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: childRules,
  parent: { entity: 'termin', field: 'terminId' },
  facts: inherited,
  factsForCreate: inheritedForCreate,
  check: ausnahmeValid,
  maxLive: { per: 'parent', max: 500 },
};
