// Medikamenten-Plan: Medikamente und Einnahmen (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6k). Gesundheitsdaten, Ende-zu-Ende verschlüsselt.
//
// Aufbau (bewusst auf der geprüften Chat-Mechanik): Je Person (Subjekt) gibt es eine verborgene Konversation der Art `meds` (feste ID aus dem Subjekt, `medsChatId`).
// Ihre Teilnehmerliste ist die Sichtgrenze (`Facts.participants`, harte Grenze vor jeder Rollenregel, nie ein Rollen-Durchgriff): das Subjekt und, nur bei einem Kind,
// die Eltern und Admins (Regel in `meds-regeln.ts`, vom Server gegen die Rollen der Datenbank erzwungen). Epochenschlüssel und Wraps laufen über die vorhandenen
// Entitäten `epoche` und `epoche_wrap`; Medikament und Einnahme sind Kinder dieser Konversation und erben ihre Sicht.
//  - Medikament: ein Plan. `inhalt` ist eine e1-Hülle (Name, Dosis, Rhythmus, Uhrzeiten, Vorrat, Notizen, Rezeptdatum, Zustand pausiert/beendet). Der Server sieht nur ID,
//    Konversation (= Person), Zeitstempel und Größe. Teilnehmer legen an, ändern und löschen.
//  - Einnahme: ein Protokolleintrag, Kind eines Medikaments. `inhalt` ist eine e1-Hülle (geplanter Zeitpunkt, Zeitpunkt der Einnahme, Status, Menge). Der Server löscht Einträge
//    nach 120 Tagen (`sync/meds.ts`). Teilnehmer legen an, ändern (nachtragen) und löschen (zurücknehmen).
//  - `bearbeiterId` = Person, die den Inhalt zuletzt geschrieben und signiert hat (setzt der Server): sie steht im AAD der Hülle, damit auch ein Elternteil den Plan des Kindes
//    ändern kann, ohne dass die Signatur des Erstellers nötig wäre.
// Zufalls-IDs (UUID v4), keine abgeleiteten: der Server kennt weder Medikament noch Einnahmezeitpunkt, also kann er keine inhaltsbezogene ID prüfen (Doppelte beim gleichzeitigen
// Erfassen auf zwei Geräten fasst die App zusammen). Weder Push-Wecker noch Betreiber-Ansicht noch Log kennen etwas davon (Facts.quiet, nie ein Inhalt im Protokoll).
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { einnahmen, konversationen, medikamente } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import type { Actor, Facts } from '../permissions.js';
import type { EntityDef, Row } from '../registry.js';
import { istUuidV4 } from './chat-ids.js';
import { E1_MIN, forAllRoles } from './chat.js';
import { iso, uuid } from './common.js';

/** Größte Hülle eines Medikaments / einer Einnahme (Zeichen). Der Klartext ist in der App auf 8000 bzw. 1000 Byte begrenzt. */
export const MAX_MEDIKAMENT = 16_384;
export const MAX_EINNAHME = 2048;
/** Lebende Medikamente je Person (Konversation), Einnahmen je Medikament (120 Tage Verlauf). */
export const MAX_MEDIKAMENTE = 100;
export const MAX_EINNAHMEN = 3000;
/** Neue Medikamente und Einnahmen je Person und Minute/Stunde, Änderungen je Person und Minute. */
export const MEDIKAMENTE_PRO_MINUTE = 20;
export const MEDIKAMENTE_PRO_STUNDE = 200;
export const EINNAHMEN_PRO_MINUTE = 60;
export const EINNAHMEN_PRO_STUNDE = 600;
/** Wie lange der Server Einnahme-Einträge aufbewahrt (Tage, nach `created_at` in Serverzeit). */
export const EINNAHMEN_AUFBEWAHRUNG_TAGE = 120;

const huelle = (max: number) => safeString().pipe(z.string().min(E1_MIN).max(max).regex(/^e1:[A-Za-z0-9_-]+$/));

const verweigert = (): Facts => ({ audience: 'parents', ownerId: null, participants: [] });

type Env = Parameters<NonNullable<EntityDef['validate']>>[0];

/** Die Konversation gehört zur Familie, lebt, ist verschlüsselt (e1) und ist eine Medikamenten-Konversation. */
async function medsKonversation(env: Env, konversationId: string): Promise<boolean> {
  const [k] = await env.tx
    .select({ art: konversationen.art, enc: konversationen.encVersion })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, env.familyId), eq(konversationen.id, konversationId), isNull(konversationen.deletedAt)))
    .limit(1);
  return !!k && k.art === 'meds' && k.enc === 'e1';
}

// Lesen, anlegen, ändern, löschen: jeder Teilnehmer der Konversation (die Teilnehmer-Grenze erzwingt das Rechte-Modell; Rollen spielen hier keine Rolle)
const planRules = forAllRoles({ read: 'shared', create: 'shared', update: 'shared', delete: 'shared', updateFields: ['inhalt'] });

// ---------------------------------------------------------------- Medikament

export const medikamentEntity: EntityDef = {
  name: 'medikament',
  table: medikamente,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle(MAX_MEDIKAMENT), required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: planRules,
  parent: { entity: 'konversation', field: 'konversationId' },
  userRefs: ['bearbeiterId'],
  idValid: (id: string): boolean => istUuidV4(id),
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  // wer den Inhalt schreibt, signiert ihn (beim Anlegen und bei jeder Änderung des Inhalts)
  derive: (actor: Actor, changed: Row): Row => ('inhalt' in changed ? { bearbeiterId: actor.userId } : {}),
  maxLive: { per: 'parent', max: MAX_MEDIKAMENTE },
  rate: { field: 'bearbeiterId', perMinute: MEDIKAMENTE_PRO_MINUTE, perHour: MEDIKAMENTE_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 60 },
  scrubOnUpdate: ['inhalt'],
  validate: async (env, row: Row): Promise<boolean> => medsKonversation(env, String(row.konversationId)),
};

// ---------------------------------------------------------------- Einnahme

export const einnahmeEntity: EntityDef = {
  name: 'einnahme',
  table: einnahmen,
  fields: {
    konversationId: { access: 'create', schema: uuid, required: true },
    medikamentId: { access: 'create', schema: uuid, required: true },
    inhalt: { access: 'rw', schema: huelle(MAX_EINNAHME), required: true, blank: '' },
    bearbeiterId: { access: 'server', schema: uuid.nullable() },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules: planRules,
  parent: { entity: 'medikament', field: 'medikamentId' },
  userRefs: ['bearbeiterId'],
  idValid: (id: string): boolean => istUuidV4(id),
  noWake: true,
  facts: (row: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: (row.bearbeiterId as string | null) ?? null }),
  factsForCreate: (actor: Actor, _values: Row, parent: Facts | null): Facts => ({ ...(parent ?? verweigert()), ownerId: actor.userId }),
  derive: (actor: Actor, changed: Row): Row => ('inhalt' in changed ? { bearbeiterId: actor.userId } : {}),
  maxLive: { per: 'parent', max: MAX_EINNAHMEN },
  rate: { field: 'bearbeiterId', perMinute: EINNAHMEN_PRO_MINUTE, perHour: EINNAHMEN_PRO_STUNDE, viaLog: true },
  updateRate: { fields: ['inhalt'], perMinute: 120 },
  scrubOnUpdate: ['inhalt'],
  // das Medikament gehört zur genannten Konversation (und lebt), die Konversation ist eine verschlüsselte Medikamenten-Konversation
  validate: async (env, row: Row): Promise<boolean> => {
    if (!(await medsKonversation(env, String(row.konversationId)))) return false;
    const [m] = await env.tx
      .select({ id: medikamente.id })
      .from(medikamente)
      .where(
        and(
          eq(medikamente.familyId, env.familyId),
          eq(medikamente.id, String(row.medikamentId)),
          eq(medikamente.konversationId, String(row.konversationId)),
          isNull(medikamente.deletedAt),
        ),
      )
      .limit(1);
    return !!m;
  },
};
