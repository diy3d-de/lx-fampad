// Listen (Einkauf, Packliste, beliebige Listen) und ihre Einträge: erster Fachbereich im Sync.
//
// Rechte (siehe sync/permissions.ts):
//  - Admin/Eltern: alles.
//  - Kind: sieht Listen der Stufe `family` und `all`; darf dort Einträge anlegen, ändern, abhaken und löschen; darf Listen anlegen
//    (nur Stufe `family`) und eigene Listen umbenennen oder löschen, aber weder die Freigabe ändern noch fremde Listen verändern.
//  - Gast: sieht nur freigegebene Listen (Stufe `all`) und darf dort Einträge abhaken; sonst nichts.
// Sortierung: `position` ist eine Kommazahl; eine neue Position liegt zwischen den Nachbarn (Mittelwert). Beim Verschieben ändert sich
// nur ein Feld eines Eintrags, gleichzeitige Verschiebungen verschiedener Einträge kollidieren nicht.
import { z } from 'zod';
import { listItems, lists } from '../../db/schema.js';
import type { Actor, Facts, Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { iso, timestamp, trimmed, uuid } from './common.js';

export const LIST_KINDS = ['shopping', 'packing', 'custom'] as const;
export const LIST_AUDIENCES = ['parents', 'family', 'all'] as const;

const fullAccess = { read: 'all', create: 'all', update: 'all', delete: 'all' } as const;

const listRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: { read: 'shared', create: 'all', update: 'own', delete: 'own', updateFields: ['name', 'kind'], limits: { audience: ['family'] } },
  guest: { read: 'shared', create: 'none', update: 'none', delete: 'none' },
};

const itemRules: Rules = {
  admin: fullAccess,
  parent: fullAccess,
  child: { read: 'shared', create: 'shared', update: 'shared', delete: 'shared' },
  guest: { read: 'shared', create: 'none', update: 'shared', delete: 'none', updateFields: ['doneAt'] },
};

export const listEntity: EntityDef = {
  name: 'list',
  table: lists,
  fields: {
    name: { access: 'rw', schema: trimmed(100), required: true, blank: '' },
    kind: { access: 'rw', schema: z.enum(LIST_KINDS), defaultValue: 'custom' },
    audience: { access: 'rw', schema: z.enum(LIST_AUDIENCES), defaultValue: 'family' },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: listRules,
  visibilityFields: ['audience'],
  userRefs: ['ownerId'],
  facts: (row: Row): Facts => ({ audience: row.audience as Facts['audience'], ownerId: (row.ownerId as string | null) ?? null }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({ audience: (values.audience as Facts['audience'] | undefined) ?? 'family', ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  maxLive: { per: 'family', max: 200 },
};

export const listItemEntity: EntityDef = {
  name: 'list_item',
  table: listItems,
  fields: {
    listId: { access: 'create', schema: uuid, required: true },
    text: { access: 'rw', schema: trimmed(500), required: true, blank: '' },
    assigneeId: { access: 'rw', schema: uuid.nullable(), defaultValue: null, blank: null, memberRef: true },
    doneAt: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, blank: null, toWire: iso },
    position: { access: 'rw', schema: z.number().min(-1e12).max(1e12), defaultValue: 0, blank: 0 },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: itemRules,
  parent: { entity: 'list', field: 'listId' },
  userRefs: ['assigneeId'],
  // Einträge erben Freigabe und Besitzer der Liste
  facts: (_row: Row, parent: Facts | null): Facts => parent ?? { audience: 'parents', ownerId: null },
  factsForCreate: (_actor: Actor, _values: Row, parent: Facts | null): Facts => parent ?? { audience: 'parents', ownerId: null },
  maxLive: { per: 'parent', max: 1000 },
};
