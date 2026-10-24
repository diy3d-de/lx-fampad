// Dateien-Bereich im Sync (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6n): Ordner, Dateien und ihre unveränderlichen Fassungen. Die Bytes liegen NICHT im Sync, sondern in der Blob-Schicht
// (src/files/): erst hochladen (tus), dann Datei und Fassung mit der Upload-ID anlegen; der Registry-Haken `claim` beansprucht den Blob atomar in der Sync-Transaktion.
//
// Freigabe ohne Vererbung (Entscheidung nach dem Registry-Spike): Ordner und Dateien tragen je ihre eigene Stufe (`parents`/`family`). Die Registry kennt nur Eltern, die nie leer sind und
// sich nie ändern (`parent`), ein Ordner steckt aber in einem Ordner (selbstbezüglich, Tiefe bis 6, Verschieben) und eine Datei darf im Wurzelverzeichnis liegen. Statt die Engine
// umzubauen, gilt eine feste INVARIANTE, die der Server bei jedem Anlegen, Verschieben und Ändern der Stufe erzwingt: ein Eintrag der Stufe `family` liegt nur in einem Ordner der Stufe
// `family` (oder oben). Damit ist die ganze Kette über einem sichtbaren Eintrag immer sichtbar, und ein Kind sieht nie etwas unter einem Elternordner, den es nicht sieht. Ein Ordner
// lässt sich nur auf `parents` stellen, wenn keine direkt darunter liegende Datei und kein direkt darunter liegender Ordner `family` ist (darunter kann dann nichts `family` sein);
// die App stellt die Kinder zuerst um. Ordner lassen sich nur leer löschen (`deleteGuard`), die App löscht von unten nach oben.
//
// Rechte (wie die Aufgaben): Admin/Eltern alles; Kind sieht Stufe `family`, legt nur Stufe `family` an und ändert/löscht nur Eigenes. Fassungen erben Stufe und Besitzer der Datei.
import { and, count, eq, inArray, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { dateien, dateiVersionen, ordner } from '../../db/schema.js';
import { dateiName } from '../../files/names.js';
import { sees, type Actor, type Audience, type Facts, type RoleRule, type Rules } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { istUuidV4 } from './chat-ids.js';
import { AUDIENCE_INPUT, iso, uuid } from './common.js';

/** Tiefe der Ordner: höchstens 6 Ebenen (ein Ordner oben hat die Tiefe 1). */
export const MAX_ORDNER_TIEFE = 6;
export const MAX_ORDNER = 2000;
export const MAX_DATEIEN = 20_000;
export const MAX_VERSIONEN_JE_DATEI = 100;

type Env = Parameters<NonNullable<EntityDef['validate']>>[0];

const volleRechte: RoleRule = { read: 'all', create: 'all', update: 'all', delete: 'all' };
const kindRegel = (updateFields: readonly string[]): RoleRule => ({ read: 'shared', create: 'all', update: 'own', delete: 'own', updateFields, limits: { audience: ['family'] } });

const ordnerRules: Rules = { admin: volleRechte, parent: volleRechte, child: kindRegel(['name', 'parentId']) };
const dateiRules: Rules = { admin: volleRechte, parent: volleRechte, child: kindRegel(['name', 'ordnerId']) };
// Fassungen: unveränderlich (alle Felder nur beim Anlegen oder vom Server); ein Kind legt Fassungen nur für eigene Dateien an
const versionRules: Rules = {
  admin: { read: 'all', create: 'all', update: 'none', delete: 'all' },
  parent: { read: 'all', create: 'all', update: 'none', delete: 'all' },
  child: { read: 'shared', create: 'own', update: 'none', delete: 'own' },
};

const dateienAn = (env: Env): boolean => env.flags?.filesEnabled === true;

interface OrdnerKopf {
  id: string;
  parentId: string | null;
  audience: Audience;
}

async function ordnerKopf(env: Env, id: string): Promise<OrdnerKopf | undefined> {
  const [r] = await env.tx
    .select({ id: ordner.id, parentId: ordner.parentId, audience: ordner.audience })
    .from(ordner)
    .where(and(eq(ordner.familyId, env.familyId), eq(ordner.id, id), isNull(ordner.deletedAt)))
    .limit(1);
  return r;
}

/** Die Ordner von `startId` nach oben (der Ordner selbst zuerst); null bei einem fehlenden oder gelöschten Glied oder einer Kette über der Höchsttiefe (auch bei einem Zyklus). */
async function kette(env: Env, startId: string): Promise<OrdnerKopf[] | null> {
  const out: OrdnerKopf[] = [];
  let id: string | null = startId;
  while (id !== null) {
    if (out.length >= MAX_ORDNER_TIEFE) return null;
    const k: OrdnerKopf | undefined = await ordnerKopf(env, id);
    if (!k) return null;
    out.push(k);
    id = k.parentId;
  }
  return out;
}

/** Wie viele Ebenen unterhalb des Ordners lebende Ordner liegen (0 = keine). */
async function hoeheUnter(env: Env, id: string): Promise<number> {
  let ebene = [id];
  for (let h = 0; h <= MAX_ORDNER_TIEFE; h++) {
    const kinder = await env.tx
      .select({ id: ordner.id })
      .from(ordner)
      .where(and(eq(ordner.familyId, env.familyId), inArray(ordner.parentId, ebene), isNull(ordner.deletedAt)));
    if (kinder.length === 0) return h;
    ebene = kinder.map((k) => k.id);
  }
  return MAX_ORDNER_TIEFE + 1;
}

/** Liegt irgendetwas Lebendes (Ordner oder Datei) direkt unter dem Ordner? Mit `nurFamilie`: nur Einträge der Stufe `family`. */
async function hatKinder(env: Pick<Env, 'tx' | 'familyId'>, id: string, nurFamilie: boolean): Promise<boolean> {
  const ordnerWhere = [eq(ordner.familyId, env.familyId), eq(ordner.parentId, id), isNull(ordner.deletedAt)];
  const dateiWhere = [eq(dateien.familyId, env.familyId), eq(dateien.ordnerId, id), isNull(dateien.deletedAt)];
  if (nurFamilie) {
    ordnerWhere.push(eq(ordner.audience, 'family'));
    dateiWhere.push(eq(dateien.audience, 'family'));
  }
  const [o] = await env.tx.select({ n: count() }).from(ordner).where(and(...ordnerWhere));
  if ((o?.n ?? 0) > 0) return true;
  const [d] = await env.tx.select({ n: count() }).from(dateien).where(and(...dateiWhere));
  return (d?.n ?? 0) > 0;
}

/** Zielordner für einen Eintrag: lebt, ist für die Person sichtbar und (bei Stufe `family`) selbst `family`. Leer (oberste Ebene) ist immer zulässig. */
async function zielOrdnerGueltig(env: Env, ordnerId: string | null, audience: Audience): Promise<boolean> {
  if (ordnerId === null) return true;
  const k = await ordnerKopf(env, ordnerId);
  if (!k) return false;
  if (!sees(env.actor.role, k.audience)) return false;
  return audience !== 'family' || k.audience === 'family';
}

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null });

export const ordnerEntity: EntityDef = {
  name: 'ordner',
  table: ordner,
  fields: {
    parentId: { access: 'rw', schema: uuid.nullable(), defaultValue: null, blank: null },
    name: { access: 'rw', schema: dateiName, required: true, blank: '' },
    audience: { access: 'rw', schema: AUDIENCE_INPUT, defaultValue: 'family' },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: ordnerRules,
  userRefs: ['ownerId'],
  idValid: (id: string): boolean => istUuidV4(id),
  facts: (row: Row): Facts => ({ audience: row.audience as Audience, ownerId: (row.ownerId as string | null) ?? null }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({ audience: (values.audience as Audience | undefined) ?? 'family', ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  maxLive: { per: 'family', max: MAX_ORDNER },
  ownerLimit: { field: 'ownerId', roles: ['child'], max: 100 },
  rate: { field: 'ownerId', perMinute: 30, perHour: 300, viaLog: true },
  updateRate: { fields: ['name', 'parentId'], perMinute: 60 },
  validate: async (env, row: Row): Promise<boolean> => {
    if (!dateienAn(env)) return false;
    const id = String(row.id);
    const audience = row.audience as Audience;
    const parentId = (row.parentId ?? null) as string | null;
    let tiefe = 1;
    if (parentId !== null) {
      if (parentId === id) return false;
      const oben = await kette(env, parentId);
      // Zyklus (der Ordner liegt über seinem neuen Elternordner), fehlender/gelöschter Elternordner oder zu tief
      if (!oben || oben.some((k) => k.id === id)) return false;
      const eltern = oben[0];
      if (!eltern || !sees(env.actor.role, eltern.audience)) return false;
      if (audience === 'family' && eltern.audience !== 'family') return false;
      tiefe = oben.length + 1;
    }
    if (tiefe + (await hoeheUnter(env, id)) > MAX_ORDNER_TIEFE) return false;
    // auf `parents` nur, wenn darunter nichts `family` ist
    if (audience === 'parents' && (await hatKinder(env, id, true))) return false;
    return true;
  },
  deleteGuard: async (env, row: Row): Promise<boolean> => !(await hatKinder(env, String(row.id), false)),
};

export const dateiEntity: EntityDef = {
  name: 'datei',
  table: dateien,
  fields: {
    ordnerId: { access: 'rw', schema: uuid.nullable(), defaultValue: null, blank: null },
    name: { access: 'rw', schema: dateiName, required: true, blank: '' },
    audience: { access: 'rw', schema: AUDIENCE_INPUT, defaultValue: 'family' },
    ownerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: dateiRules,
  userRefs: ['ownerId'],
  idValid: (id: string): boolean => istUuidV4(id),
  facts: (row: Row): Facts => ({ audience: row.audience as Audience, ownerId: (row.ownerId as string | null) ?? null }),
  factsForCreate: (actor: Actor, values: Row): Facts => ({ audience: (values.audience as Audience | undefined) ?? 'family', ownerId: actor.userId }),
  onCreate: (actor: Actor): Row => ({ ownerId: actor.userId }),
  maxLive: { per: 'family', max: MAX_DATEIEN },
  ownerLimit: { field: 'ownerId', roles: ['child'], max: 1000 },
  rate: { field: 'ownerId', perMinute: 30, perHour: 300, viaLog: true },
  updateRate: { fields: ['name', 'ordnerId'], perMinute: 60 },
  validate: async (env, row: Row): Promise<boolean> => dateienAn(env) && (await zielOrdnerGueltig(env, (row.ordnerId ?? null) as string | null, row.audience as Audience)),
};

export const dateiVersionEntity: EntityDef = {
  name: 'datei_version',
  table: dateiVersionen,
  fields: {
    dateiId: { access: 'create', schema: uuid, required: true },
    // laufende Nummer je Datei (der Client nimmt die höchste + 1; ein Doppel ergibt eine Ablehnung, dann neu zählen)
    nr: { access: 'create', schema: z.number().int().min(1).max(9999), required: true },
    // ID des hochgeladenen Blobs (= ID des tus-Uploads); wird in der Sync-Transaktion beansprucht
    blobId: { access: 'create', schema: uuid, required: true },
    thumbBlobId: { access: 'create', schema: uuid.nullable(), defaultValue: null },
    // vom Server aus dem beanspruchten Blob gesetzt
    size: { access: 'server', schema: z.number().int().min(0) },
    mime: { access: 'server', schema: z.string().nullable() },
    sha256: { access: 'server', schema: z.string().nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: versionRules,
  parent: { entity: 'datei', field: 'dateiId' },
  idValid: (id: string): boolean => istUuidV4(id),
  facts: (_row: Row, parent: Facts | null): Facts => parent ?? verweigert(),
  factsForCreate: (_actor: Actor, _values: Row, parent: Facts | null): Facts => parent ?? verweigert(),
  claim: {
    fields: [
      { field: 'blobId', modus: 'server', kind: 'datei' },
      { field: 'thumbBlobId', modus: 'server', kind: 'thumb' },
    ],
    derive: (blobs): Row => {
      const b = blobs.get('blobId');
      return b ? { size: b.size, mime: b.mime, sha256: b.sha256 } : {};
    },
  },
  maxLive: { per: 'parent', max: MAX_VERSIONEN_JE_DATEI },
  maxFamily: 50_000,
  validate: async (env): Promise<boolean> => dateienAn(env),
};
