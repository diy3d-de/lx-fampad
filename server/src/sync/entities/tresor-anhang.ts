// Anhang eines Tresor-Eintrags (Abschnitt 6m/6n): ein Ende-zu-Ende verschlüsselter Blob (Modus `e2ee`, files/service.ts). Der Server sieht nur die Blob-ID, die Größe und eine e1-Hülle
// (`inhalt`: Name, Typ, Dateischlüssel, Zuordnung zum Eintrag, vom Client verschlüsselt). Der Anhang ist ein Kind der Tresor-Konversation und erbt ihre Teilnehmer-Sicht; die Rechte sind
// dieselben wie bei den Tresor-Einträgen (nur Eltern/Admins als Teilnehmer, nie ein Kind). Lesen darf den Blob nur, wer diesen Datensatz lesen darf (der Blob hängt am Anhang).
// Anhänge sind unveränderlich (Ersetzen = löschen und neu anlegen); der Blob wird beim Anlegen beansprucht.
import { z } from 'zod';
import { tresorAnhaenge } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import { ROLES, type Actor, type Facts, type RoleRule, type Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { istUuidV4 } from './chat-ids.js';
import { E1_MIN } from './chat.js';
import { iso, uuid } from './common.js';
import { tresorKonversation } from './tresor.js';

export const MAX_TRESOR_ANHANG_HUELLE = 4096;
export const MAX_TRESOR_ANHAENGE = 200;

const huelle = safeString().pipe(z.string().min(E1_MIN).max(MAX_TRESOR_ANHANG_HUELLE).regex(/^e1:[A-Za-z0-9_-]+$/));
const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

const erwachsene: RoleRule = { read: 'shared', create: 'shared', update: 'none', delete: 'shared' };
const kind: RoleRule = { read: 'none', create: 'none', update: 'none', delete: 'none' };
const rules = Object.fromEntries(ROLES.map((r) => [r, r === 'child' ? kind : erwachsene])) as unknown as Rules;

export const tresorAnhangEntity: EntityDef = {
  name: 'tresor_anhang',
  table: tresorAnhaenge,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    blobId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'create', schema: huelle, required: true, blank: '' },
    size: { access: 'server', schema: z.number().int().min(0) },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['bearbeiterId'],
  idValid: (id: string): boolean => istUuidV4(id),
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  derive: (actor: Actor): Row => ({ bearbeiterId: actor.userId }),
  claim: {
    fields: [{ field: 'blobId', modus: 'e2ee', kind: 'opak' }],
    derive: (blobs): Row => {
      const b = blobs.get('blobId');
      return b ? { size: b.size } : {};
    },
  },
  maxLive: { per: 'parent', max: MAX_TRESOR_ANHAENGE },
  rate: { field: 'bearbeiterId', perMinute: 30, perHour: 300, viaLog: true },
  validate: async (env, row: Row): Promise<boolean> => env.flags?.filesEnabled === true && (await tresorKonversation(env, String(row.konversationId))),
};
