// Epochen und Schlüssel-Wraps der Ende-zu-Ende-Verschlüsselung des Chats (E2EE Phase 2, docs/PROJEKTBESCHREIBUNG.md, Abschnitt 9a).
//
// Der Server speichert nur undurchsichtige Texte (Base64url) und wertet sie NIE aus: weder die vom Verteiler signierte Mitgliederliste einer Epoche noch den
// für eine Person verpackten Epochenschlüssel (Sealed Box + Signatur). Er prüft nur Form (Zeichensatz), Größe, Eindeutigkeit und die Sicht:
//  - Epoche: je (Konversation, Epoche) genau eine Zeile mit fester, abgeleiteter ID; der erste Schreiber gewinnt, jeder weitere Versuch wird abgelehnt (der
//    Verlierer einer gleichzeitigen Rotation übernimmt die Epoche des Gewinners). Unveränderlich, nicht löschbar (nur mit der Konversation). Lückenlos: Epoche N
//    gibt es erst, wenn N-1 da ist. Alle Teilnehmer der Konversation lesen sie.
//  - Wrap: je (Konversation, Epoche, Empfänger, Schlüsselversion) genau eine Zeile (feste ID, der erste gewinnt), unveränderlich. NUR der Empfänger liest seine Zeile
//    (auch Admins und die anderen Teilnehmer nicht), der WebSocket-Hinweis geht nur an ihn. Der Empfänger muss Teilnehmer sein, die Epoche muss es geben.
//    Wrap-ID v2 (PR 7 "Verlauf freigeben"): Ein Wrap OHNE `keyVersion` (Altbestand, ältere Apps) hat die ID v1 (`wrapId`), einer MIT `keyVersion` die ID v2
//    (`wrapIdV2`). So lässt sich dieselbe Epoche nach einem Schlüsselwechsel der Person noch einmal für ihren neuen Schlüssel verpacken, ohne die alten Zeilen
//    anzufassen (sie bleiben für das Archiv des alten Schlüssels). Die Zahl ist öffentlich (sie steht auch in person_keys); der Server liest nichts aus dem Wrap selbst.
//  - Ob Wrap und Mitgliederliste echt sind, prüft allein der Empfänger (Signatur gegen den gemerkten Schlüssel des Verteilers): ein Server oder Admin kann nichts
//    unterschieben, nur Wraps verwerfen oder blockieren (Verfügbarkeit, nicht Vertraulichkeit).
// Verteilt wird nur in verschlüsselten Konversationen (`enc_version` e1).
import { and, eq, isNull, max } from 'drizzle-orm';
import { z } from 'zod';
import type { Executor } from '../../auth/context.js';
import { epocheWraps, konversationen, konversationEpochen, personKeys } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import type { Actor, Facts } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { epocheId, wrapId, wrapIdV2 } from './chat-ids.js';
import { forAllRoles } from './chat.js';
import { iso, uuid } from './common.js';

/** Epochen je Konversation (lebende Zeilen). */
export const MAX_EPOCHEN = 1000;
/** Obergrenze der signierten Mitgliederliste (Zeichen, Base64url). */
export const MAX_EPOCHEN_LISTE = 16_384;
/** Obergrenze eines Wraps (Zeichen, Base64url). */
export const MAX_WRAP = 4096;
/** Wraps je Konversation (lebende Zeilen). */
export const MAX_WRAPS = 20_000;
/** Neue Epochen und Wraps je Person und Minute. */
export const EPOCHEN_PRO_MINUTE = 3;
export const EPOCHEN_PRO_STUNDE = 12;
export const WRAPS_PRO_MINUTE = 100;
export const WRAPS_PRO_STUNDE = 800;
/** Epochen und Wraps je Konversation und anlegender Person (ein Teilnehmer verbraucht die Obergrenze der Konversation nie allein). */
export const MAX_EPOCHEN_JE_PERSON = 100;
export const MAX_WRAPS_JE_PERSON = 2000;

const base64url = (min: number, max: number) => safeString().pipe(z.string().min(min).max(max).regex(/^[A-Za-z0-9_-]+$/));
const epochenNummer = z.number().int().min(1).max(100_000);

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

interface Env {
  tx: Executor;
  familyId: string;
}

/** Nur verschlüsselte Konversationen (e1) bekommen Epochen. Liefert die Konversation, wenn sie zur Familie gehört, lebt und e1 ist. */
async function e1Konversation(env: Env, id: string) {
  const [k] = await env.tx
    .select({ enc: konversationen.encVersion, art: konversationen.art, teilnehmer: konversationen.teilnehmer })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, env.familyId), eq(konversationen.id, id), isNull(konversationen.deletedAt)))
    .limit(1);
  return k && k.enc === 'e1' ? k : undefined;
}

async function epocheDa(env: Env, konversationId: string, epoche: number): Promise<boolean> {
  const [e] = await env.tx
    .select({ id: konversationEpochen.id })
    .from(konversationEpochen)
    .where(
      and(
        eq(konversationEpochen.familyId, env.familyId),
        eq(konversationEpochen.konversationId, konversationId),
        eq(konversationEpochen.epoche, epoche),
        isNull(konversationEpochen.deletedAt),
      ),
    )
    .limit(1);
  return !!e;
}

// ---------------------------------------------------------------- Epoche

// update ist erlaubt, damit die Wiederholung desselben Anlegens (gleiche Werte) bestätigt wird; jeder andere Wert ist `invalid`, löschen nie
const epocheRules = forAllRoles({ read: 'shared', create: 'shared', update: 'shared', delete: 'none', updateFields: [] });

export const epocheEntity: EntityDef = {
  name: 'epoche',
  table: konversationEpochen,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    epoche: { access: 'create', schema: epochenNummer, required: true },
    mitglieder: { access: 'create', schema: base64url(1, MAX_EPOCHEN_LISTE), required: true },
    verteilerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: epocheRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['verteilerId'],
  // feste ID je (Konversation, Epoche): niemand kann sie anders belegen, der erste Schreiber gewinnt
  idValid: (id: string, values: Row): boolean => id === epocheId(String(values.konversationId), Number(values.epoche)),
  facts: (_row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: null }),
  factsForCreate: (_actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: null }),
  onCreate: (actor: Actor): Row => ({ verteilerId: actor.userId }),
  maxLive: { per: 'parent', max: MAX_EPOCHEN },
  rate: { field: 'verteilerId', perMinute: EPOCHEN_PRO_MINUTE, perHour: EPOCHEN_PRO_STUNDE },
  ownerPerParent: { field: 'verteilerId', max: MAX_EPOCHEN_JE_PERSON },
  // feste ID: nach dem Wiederbeleben eines gelöschten Direktchats (selbe ID) bekommt er wieder Epochen
  revive: (): boolean => true,
  // nur in verschlüsselten Konversationen und lückenlos (Epoche N erst nach N-1)
  validate: async (env, row: Row): Promise<boolean> => {
    const konversationId = String(row.konversationId);
    const epoche = Number(row.epoche);
    if (!(await e1Konversation(env, konversationId))) return false;
    return epoche === 1 || (await epocheDa(env, konversationId, epoche - 1));
  },
};

// ---------------------------------------------------------------- Wrap

// create: jeder Teilnehmer (die Signatur im Wrap nennt den Verteiler, der Server prüft sie nicht); lesen nur der Empfänger
const wrapRules = forAllRoles({ read: 'own', create: 'shared', update: 'own', delete: 'none', updateFields: [] });

export const epocheWrapEntity: EntityDef = {
  name: 'epoche_wrap',
  table: epocheWraps,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    epoche: { access: 'create', schema: epochenNummer, required: true },
    empfaengerId: { access: 'create', schema: uuid, required: true, memberRef: true },
    wrap: { access: 'create', schema: base64url(1, MAX_WRAP), required: true },
    // Wrap-ID v2: Schlüsselversion des Empfängers, für die der Wrap verpackt ist (fehlt bei Wraps älterer Apps, dann gilt die ID v1)
    keyVersion: { access: 'create', schema: z.number().int().min(1).max(1_000_000) },
    verteilerId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: wrapRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['verteilerId'],
  // verschwindet die Person aus der Familie, verschwinden ihre Wraps (mit Tombstone für ihre Geräte)
  memberOwned: 'empfaengerId',
  ownerOnlyNotify: true,
  // ohne keyVersion die ID v1 (ältere Apps, Altbestand), mit keyVersion die ID v2 MIT dem Verteiler (dem Akteur): jede andere Kombination ist ungültig
  idValid: (id: string, values: Row, actor: Actor): boolean =>
    values.keyVersion === undefined || values.keyVersion === null
      ? id === wrapId(String(values.konversationId), Number(values.epoche), String(values.empfaengerId))
      : id === wrapIdV2(String(values.konversationId), Number(values.epoche), String(values.empfaengerId), Number(values.keyVersion), actor.userId),
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.empfaengerId as string | null) ?? null }),
  factsForCreate: (_actor: Actor, values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (values.empfaengerId as string | undefined) ?? null }),
  onCreate: (actor: Actor): Row => ({ verteilerId: actor.userId }),
  maxLive: { per: 'parent', max: MAX_WRAPS },
  rate: { field: 'verteilerId', perMinute: WRAPS_PRO_MINUTE, perHour: WRAPS_PRO_STUNDE },
  ownerPerParent: { field: 'verteilerId', max: MAX_WRAPS_JE_PERSON },
  ownerColumn: 'empfaengerId',
  revive: (): boolean => true,
  // nur in verschlüsselten Konversationen, für eine vorhandene Epoche und an einen Teilnehmer (Familienchat: jedes aktive Mitglied, das prüft memberRef)
  validate: async (env, row: Row): Promise<boolean> => {
    const konversationId = String(row.konversationId);
    const k = await e1Konversation(env, konversationId);
    if (!k) return false;
    if (k.art !== 'family' && !k.teilnehmer.map((u) => u.toLowerCase()).includes(String(row.empfaengerId).toLowerCase())) return false;
    // Wrap-ID v2: nur für eine Schlüsselversion, die die Person schon hat (nie eine künftige: niemand kann künftige IDs vorab belegen)
    if (row.keyVersion !== undefined && row.keyVersion !== null) {
      // Schalter E2EE_WRAP_KEY_VERSION (Standard aus): ohne ihn gibt es Wraps mit Version nicht (Apps bis 0.7.0 nehmen bei mehreren Wraps den letzten und ließen sich stören)
      if (env.flags?.wrapKeyVersion !== true) return false;
      const [pk] = await env.tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, String(row.empfaengerId))).limit(1);
      if (!pk || Number(row.keyVersion) > pk.v) return false;
    }
    // Wraps der HÖCHSTEN Epoche nur von deren Verteiler (sonst könnte ein Teilnehmer sie mit Müll vorab belegen: der erste gewinnt); ältere Epochen darf jeder
    // Teilnehmer für neu Aufgenommene nachreichen ("Verlauf teilen", signiert vom Weitergebenden, der Empfänger prüft)
    const [epoche] = await env.tx
      .select({ verteilerId: konversationEpochen.verteilerId })
      .from(konversationEpochen)
      .where(
        and(
          eq(konversationEpochen.familyId, env.familyId),
          eq(konversationEpochen.konversationId, konversationId),
          eq(konversationEpochen.epoche, Number(row.epoche)),
          isNull(konversationEpochen.deletedAt),
        ),
      )
      .limit(1);
    if (!epoche) return false;
    const [hoechste] = await env.tx
      .select({ n: max(konversationEpochen.epoche) })
      .from(konversationEpochen)
      .where(and(eq(konversationEpochen.familyId, env.familyId), eq(konversationEpochen.konversationId, konversationId), isNull(konversationEpochen.deletedAt)));
    if (Number(row.epoche) === (hoechste?.n ?? 0) && epoche.verteilerId !== env.actor.userId) return false;
    return true;
  },
};
