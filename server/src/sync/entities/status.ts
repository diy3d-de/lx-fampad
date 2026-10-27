// Familien-Status (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6o): je Person genau ein kurzer Status ("Beim Sport") mit optionalem Ablauf `bis`.
//  - Feste ID aus der Person (`statusId`, Known-Answer-Test auf beiden Seiten): niemand belegt die ID einer anderen Person vorab.
//  - Unverschlüsselt, Sicht für die ganze Familie (alle Rollen); anlegen, ändern, löschen nur die eigene Zeile (Regeltabelle nach `role`, nie Familienrolle oder
//    Betreiber-Flag, auch Admins ändern fremde Stati nicht).
//  - Kein Push-Wecker (`noWake`), Inhalt nie im Log. `bis` höchstens 7 Tage nach der Serveruhr (die Vergangenheit ist erlaubt: ein spät übertragener Eintrag
//    ist dann einfach schon abgelaufen); abgelaufene Stati zeigt die App nie, gelöscht werden sie nicht.
import { z } from 'zod';
import { familienStatus } from '../../db/schema.js';
import { safeString } from '../../routes/util.js';
import type { Actor, Facts } from '../permissions.js';
import { forAllRoles } from './chat.js';
import type { EntityDef, Row } from '../registry.js';
import { statusId } from './chat-ids.js';
import { iso, timestamp, uuid } from './common.js';

export const STATUS_MAX_ZEICHEN = 60;
/** Weiter als so viele Tage in die Zukunft darf `bis` nicht reichen. */
export const STATUS_MAX_TAGE = 7;
/** Spielraum für Uhrenunterschiede zwischen Gerät und Server. */
const SPIELRAUM_MS = 5 * 60_000;
/** Neue und geänderte Stati je Person und Minute. */
export const STATUS_PRO_MINUTE = 20;

// Steuerzeichen (C0/C1), Zeilenumbrüche, Format- und Trennzeichen (Nullbreite, Richtungsmarken, Zeilen-/Absatztrenner) sind nicht erlaubt
function ungueltig(s: string): boolean {
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 0;
    if (c <= 0x1f || (c >= 0x7f && c <= 0x9f) || c === 0xad || c === 0x61c || c === 0x180e || (c >= 0x200b && c <= 0x200f) || (c >= 0x2028 && c <= 0x202e)) return true;
    if ((c >= 0x2060 && c <= 0x206f) || c === 0xfeff || (c >= 0xfff9 && c <= 0xfffb)) return true;
  }
  return false;
}
const statusText = safeString()
  .pipe(z.string().trim().min(1).max(STATUS_MAX_ZEICHEN))
  .refine((s) => !ungueltig(s), 'Ungültige Zeichen');

// Lesen: alle (Stufe family); schreiben: nur die eigene Zeile
const rules = forAllRoles({ read: 'shared', create: 'own', update: 'own', delete: 'own', updateFields: ['text', 'bis'] });

const familie = (ownerId: string | null): Facts => ({ audience: 'family', ownerId });

export const statusEntity: EntityDef = {
  name: 'status',
  table: familienStatus,
  fields: {
    userId: { access: 'create', schema: uuid, required: true, memberRef: true },
    text: { access: 'rw', schema: statusText, required: true, blank: '' },
    bis: { access: 'rw', schema: timestamp.nullable(), defaultValue: null, blank: null, toWire: iso },
    createdAt: { access: 'server', schema: z.unknown(), toWire: iso },
  },
  rules,
  memberOwned: 'userId',
  idValid: (id: string, values: Row): boolean => id === statusId(String(values.userId)),
  revive: (): boolean => true,
  noWake: true,
  facts: (row: Row): Facts => familie((row.userId as string | null) ?? null),
  factsForCreate: (_actor: Actor, values: Row): Facts => familie((values.userId as string | undefined) ?? null),
  maxFamily: 50,
  rate: { field: 'userId', perMinute: STATUS_PRO_MINUTE, viaLog: true },
  updateRate: { fields: ['text', 'bis'], perMinute: STATUS_PRO_MINUTE },
  scrubOnUpdate: ['text'],
  validate: async (env, row: Row): Promise<boolean> => {
    const bis = row.bis;
    if (!(bis instanceof Date)) return true;
    return bis.getTime() <= (env.now ?? new Date()).getTime() + STATUS_MAX_TAGE * 86_400_000 + SPIELRAUM_MS;
  },
};
