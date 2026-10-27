// Vorsorge und Impfungen (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6p). Gesundheitsdaten, Ende-zu-Ende verschlüsselt.
//
// Gleiche Mechanik und gleiche Sichtgrenze wie der Medikamenten-Plan: Beide Entitäten sind Kinder der verborgenen Konversation `meds` EINER Person (`medsChatId`); ihre Teilnehmerliste
// (Subjekt, bei einem Kind zusätzlich Eltern/Admins, nie ein anderer Erwachsener oder ein Geschwister; Regel in `meds-regeln.ts`, `reconcileMedsTeilnehmer` zieht sie nach
// Rollenwechseln nach) ist die harte Grenze (`Facts.participants`). Es gibt keine neue Konversationsart.
//  - Vorsorge-Profil: je Person genau eines (feste ID aus der Konversation). `inhalt` = e1-Hülle (Geburtsdatum, Geschlecht optional).
//  - Vorsorge-Eintrag: eine Impfung/Vorsorge/Zahnvorsorge/sonstige (Zufalls-ID). `inhalt` = e1-Hülle (Vorlage oder Name, Art, Erledigt-Daten, Vorlauf, Notiz).
// Der Server sieht nur ID, Konversation (= Person), Zeitstempel und Größe. Keine automatische Löschung (die Daten sind der Impfnachweis), kein Wecker, nie ein Inhalt im Log.
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { konversationen, vorsorgeEintraege, vorsorgeProfile } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import { ROLES, type Actor, type Facts, type RoleRule, type Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { istUuidV4, vorsorgeProfilId } from './chat-ids.js';
import { E1_MIN } from './chat.js';
import { iso, uuid } from './common.js';

/** Größte Hülle eines Profils / eines Eintrags (Zeichen). Der Klartext ist in der App auf 512 bzw. 4000 Byte begrenzt. */
export const MAX_VORSORGE_PROFIL = 2048;
export const MAX_VORSORGE_EINTRAG = 8192;
/** Lebende Einträge je Person (Konversation). */
export const MAX_VORSORGE_EINTRAEGE = 200;
/** Neue Einträge je Person und Minute/Stunde, Änderungen je Person und Minute. */
export const VORSORGE_PRO_MINUTE = 20;
export const VORSORGE_PRO_STUNDE = 200;

const huelle = (max: number) => safeString().pipe(z.string().min(E1_MIN).max(max).regex(/^e1:[A-Za-z0-9_-]+$/));

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

type Env = Parameters<NonNullable<EntityDef['validate']>>[0];

/** Die Konversation gehört zur Familie, lebt, ist verschlüsselt (e1) und ist eine Medikamenten-Konversation (`meds`). */
async function medsKonversation(env: Env, konversationId: string): Promise<boolean> {
  const [k] = await env.tx
    .select({ art: konversationen.art, enc: konversationen.encVersion })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, env.familyId), eq(konversationen.id, konversationId), isNull(konversationen.deletedAt)))
    .limit(1);
  return !!k && k.art === 'meds' && k.enc === 'e1';
}

// Kinder dürfen NUR LESEN (ihre eigenen Daten als Teilnehmer); Eltern und Admins tragen ein, ändern und löschen
const erwachsene: RoleRule = { read: 'shared', create: 'shared', update: 'shared', delete: 'shared', updateFields: ['inhalt'] };
const kind: RoleRule = { read: 'shared', create: 'none', update: 'none', delete: 'none' };
const rules = Object.fromEntries(ROLES.map((r) => [r, r === 'child' ? kind : erwachsene])) as unknown as Rules;

const gemeinsam = {
  rules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['bearbeiterId'],
  noWake: true,
  // ownerId = Bearbeiter hat keine Wirkung, solange keine Regel `own` benutzt wird (alle Rechte hier sind `shared`, die Teilnehmer-Grenze entscheidet)
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  // wer den Inhalt schreibt, signiert ihn (beim Anlegen und bei jeder Änderung des Inhalts)
  derive: (actor: Actor, changed: Row): Row => ('inhalt' in changed ? { bearbeiterId: actor.userId } : {}),
  scrubOnUpdate: ['inhalt'],
  validate: async (env: Env, row: Row): Promise<boolean> => medsKonversation(env, String(row.konversationId)),
} satisfies Partial<EntityDef>;

export const vorsorgeProfilEntity: EntityDef = {
  name: 'vorsorge_profil',
  table: vorsorgeProfile,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle(MAX_VORSORGE_PROFIL), required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  ...gemeinsam,
  // je Person genau eines: die ID ist aus der Konversation abgeleitet
  idValid: (id: string, values: Row): boolean => id === vorsorgeProfilId(String(values.konversationId)),
  // Löschen gesperrt: nach einem Tombstone lässt die Engine dieselbe feste ID nie wieder zu (`deleted`), die Person könnte kein Profil mehr anlegen. Ändern geht; mit der Konversation fällt es per Kaskade weg.
  guard: (action: 'update' | 'delete'): boolean => action !== 'delete',
  rate: { field: 'bearbeiterId', perMinute: VORSORGE_PRO_MINUTE, perHour: VORSORGE_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 60 },
};

export const vorsorgeEintragEntity: EntityDef = {
  name: 'vorsorge_eintrag',
  table: vorsorgeEintraege,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle(MAX_VORSORGE_EINTRAG), required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  ...gemeinsam,
  idValid: (id: string): boolean => istUuidV4(id),
  maxLive: { per: 'parent', max: MAX_VORSORGE_EINTRAEGE },
  rate: { field: 'bearbeiterId', perMinute: VORSORGE_PRO_MINUTE, perHour: VORSORGE_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 60 },
};
