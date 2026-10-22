// Betreiber-Einstellungen (Paket 2b): Wartungsmodus und Familienhinweis. Gelesen werden sie von der Familie (Hinweis als Banner, Wartung als Meldung) über
// `GET /api/v1/family-notice`, geschrieben nur vom Betreiber (`PUT /admin/maintenance`, `PUT /admin/notice`, jeweils mit Step-up) oder per Server-CLI. Jede Änderung
// steht im Audit-Log (alter und neuer Zustand; der Hinweistext selbst nicht, nur seine Länge). Eine Zeile je Familie in `operator_settings`.
import { eq } from 'drizzle-orm';
import { writeAudit } from '../auth/audit.js';
import type { AuthContext, RequestMeta, Tx } from '../auth/context.js';
import type { SessionPrincipal } from '../auth/types.js';
import { operatorSettings } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { MaintenanceGate } from './maintenance.js';

/** Obergrenzen (auch von der Datenbank geprüft bzw. vom Server erzwungen). */
export const NOTICE_MAX_CHARS = 280;
export const NOTICE_MAX_DAYS = 90;
export const MAINTENANCE_MAX_HOURS = 72;

// Steuerzeichen, Zeilentrenner, Richtungs- und Formatzeichen (Bidi-Umkehr), unsichtbare Zeichen (Null-Breite-Leerzeichen, Füllzeichen der Hangul- und Braille-Blöcke,
// Tag-Zeichen, Objekt-Ersatzzeichen) haben in einem Hinweis nichts verloren. Als Zahlenbereiche geschrieben (Codepunkte), damit nichts davon unsichtbar im Quelltext steht.
// ZWJ (200D) und ZWNJ (200C) bleiben erlaubt: Emoji-Folgen (Familie, Berufe) und Schreibweisen mancher Sprachen brauchen sie; Variationsselektoren (FE00-FE0F) ebenso.
const FORBIDDEN_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x0000, 0x001f], // Steuerzeichen (Zeilenumbruch, Tabulator, NUL)
  [0x007f, 0x009f],
  [0x00ad, 0x00ad], // weicher Trennstrich
  [0x034f, 0x034f], // Combining Grapheme Joiner
  [0x061c, 0x061c], // Arabic Letter Mark
  [0x115f, 0x1160], // Hangul-Füllzeichen
  [0x17b4, 0x17b5], // Khmer, unsichtbare Vokale
  [0x180e, 0x180e], // Mongolian Vowel Separator
  [0x200b, 0x200b], // Null-Breite-Leerzeichen
  [0x200e, 0x200f], // LRM, RLM
  [0x2028, 0x202e], // Zeilen-/Absatztrenner und Richtungsumkehr (LRE bis RLO)
  [0x2060, 0x206f], // Word Joiner, unsichtbare Operatoren, veraltete Formatzeichen
  [0x2800, 0x2800], // leeres Braille-Muster
  [0x3164, 0x3164], // Hangul Filler
  [0xfeff, 0xfeff], // BOM / Zero Width No-Break Space
  [0xffa0, 0xffa0], // Halfwidth Hangul Filler
  [0xfff9, 0xfffc], // Interlinear Annotation, Objekt-Ersatzzeichen
  [0xe0000, 0xe007f], // Tag-Zeichen (unsichtbarer Text)
];

function hasForbiddenChar(text: string): boolean {
  for (const ch of text) {
    const cp = ch.codePointAt(0) ?? 0;
    if (FORBIDDEN_RANGES.some(([from, to]) => cp >= from && cp <= to)) return true;
  }
  return false;
}

// Links im Hinweis (der Betreiber ist vertrauenswürdig, ein Hinweis soll aber nie wie eine Aufforderung zum Klicken oder wie eine Anmeldeseite wirken):
// Schema mit "://", "www." und Domain-artige Muster mit gängigen Endungen. Bewusst einfach gehalten: normale Sätze ("z. B.", "9.30 Uhr") bleiben möglich.
const LINK_PATTERN = /[a-z][a-z0-9+.-]*:\/\/|\bwww\./i;
const DOMAIN_PATTERN = /[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|de|org|net|info|io|dev|app|eu|ch|at|uk|ru|cn|xyz|top|me|co|link|click|online|site|shop|biz|cc|tk|ml)\b/i;

/** Prüft und bereinigt den Hinweistext: Unicode NFC, getrimmt, 1 bis 280 Zeichen, eine Zeile, reiner Text ohne Links. Wirft 400 `invalid_notice` bzw. `notice_link`. */
export function cleanNoticeText(raw: string): string {
  const text = raw.normalize('NFC').trim();
  if (text.length === 0 || [...text].length > NOTICE_MAX_CHARS || hasForbiddenChar(text)) throw new AppError(400, 'invalid_notice', 'Hinweistext ungültig.');
  if (LINK_PATTERN.test(text) || DOMAIN_PATTERN.test(text)) throw new AppError(400, 'notice_link', 'Der Hinweis darf keine Links enthalten.');
  return text;
}

export interface SettingsRow {
  maintenanceActive: boolean;
  maintenanceSince: Date | null;
  maintenanceUntil: Date | null;
  noticeText: string | null;
  noticeExpiresAt: Date | null;
  noticeSetAt: Date | null;
}

const EMPTY: SettingsRow = { maintenanceActive: false, maintenanceSince: null, maintenanceUntil: null, noticeText: null, noticeExpiresAt: null, noticeSetAt: null };

export interface SettingsView {
  /** Ist der Wartungsmodus gerade wirksam (an und nicht durch "until" abgelaufen)? */
  maintenance: { active: boolean; since: string | null; until: string | null };
  /** Der aktuelle Familienhinweis (nicht abgelaufen) oder null. `setAt` ist die Version (die App merkt sich daran, was weggeklickt wurde). */
  notice: { text: string; setAt: string; expiresAt: string | null } | null;
}

export function viewOf(row: SettingsRow, now: Date): SettingsView {
  const active = row.maintenanceActive && (row.maintenanceUntil === null || row.maintenanceUntil.getTime() > now.getTime());
  const noticeLive = row.noticeText !== null && row.noticeSetAt !== null && (row.noticeExpiresAt === null || row.noticeExpiresAt.getTime() > now.getTime());
  return {
    maintenance: { active, since: active ? (row.maintenanceSince?.toISOString() ?? null) : null, until: active ? (row.maintenanceUntil?.toISOString() ?? null) : null },
    notice: noticeLive ? { text: row.noticeText!, setAt: row.noticeSetAt!.toISOString(), expiresAt: row.noticeExpiresAt?.toISOString() ?? null } : null,
  };
}

async function readRow(ctx: AuthContext, familyId: string): Promise<SettingsRow> {
  const [row] = await ctx.db
    .select({
      maintenanceActive: operatorSettings.maintenanceActive,
      maintenanceSince: operatorSettings.maintenanceSince,
      maintenanceUntil: operatorSettings.maintenanceUntil,
      noticeText: operatorSettings.noticeText,
      noticeExpiresAt: operatorSettings.noticeExpiresAt,
      noticeSetAt: operatorSettings.noticeSetAt,
    })
    .from(operatorSettings)
    .where(eq(operatorSettings.familyId, familyId));
  return row ?? EMPTY;
}

/** Stand für die Familie (jede Sitzung) und den Betreiber. */
export async function getSettings(ctx: AuthContext, familyId: string): Promise<SettingsView> {
  return viewOf(await readRow(ctx, familyId), ctx.now());
}

/** Legt die Zeile an, falls es sie noch nicht gibt (das erste Schalten); die Sperre auf die Zeile hält gleichzeitige Schaltungen hintereinander. */
async function lockRow(ctx: AuthContext, tx: Tx, familyId: string): Promise<SettingsRow> {
  await tx.insert(operatorSettings).values({ familyId, updatedAt: ctx.now() }).onConflictDoNothing();
  const [row] = await tx.select().from(operatorSettings).where(eq(operatorSettings.familyId, familyId)).for('update');
  return row ?? EMPTY;
}

export interface MaintenanceInput {
  active: boolean;
  /**
   * Dauer in Minuten ab JETZT (Serverzeit, nie die Uhr des Geräts), 1 bis 72 Stunden; nur zusammen mit active=true. Ohne Angabe gelten 72 Stunden:
   * der Wartungsmodus hat immer ein Ende (ein vergessener Modus sperrt nie auf Dauer).
   */
  minutes: number | null;
}

export const MAINTENANCE_MAX_MINUTES = MAINTENANCE_MAX_HOURS * 60;
export const NOTICE_MAX_MINUTES = NOTICE_MAX_DAYS * 24 * 60;

/** Schaltet den Wartungsmodus. "aus" mit Dauer oder eine Dauer außerhalb von 1 Minute bis 72 Stunden wird abgelehnt (400 `invalid_duration`). */
export async function setMaintenance(ctx: AuthContext, gate: MaintenanceGate | undefined, p: SessionPrincipal, input: MaintenanceInput, meta: RequestMeta): Promise<SettingsView> {
  const now = ctx.now();
  if (!input.active && input.minutes !== null) throw new AppError(400, 'invalid_duration', 'Dauer ungültig.');
  if (input.minutes !== null && (!Number.isInteger(input.minutes) || input.minutes < 1 || input.minutes > MAINTENANCE_MAX_MINUTES)) throw new AppError(400, 'invalid_duration', 'Dauer ungültig.');
  const until = input.active ? new Date(now.getTime() + (input.minutes ?? MAINTENANCE_MAX_MINUTES) * 60_000) : null;
  const view = await ctx.db.transaction(async (tx) => {
    const before = viewOf(await lockRow(ctx, tx, p.familyId), now);
    await tx
      .update(operatorSettings)
      .set({
        maintenanceActive: input.active,
        maintenanceSince: input.active ? (before.maintenance.active ? new Date(before.maintenance.since ?? now) : now) : null,
        maintenanceUntil: until,
        maintenanceBy: input.active ? p.userId : null,
        updatedAt: now,
      })
      .where(eq(operatorSettings.familyId, p.familyId));
    await writeAudit(ctx, tx, {
      event: 'operator_maintenance_set',
      familyId: p.familyId,
      actorId: p.userId,
      deviceId: p.deviceId,
      ip: meta.ip,
      detail: { from: before.maintenance.active, to: input.active, until: until?.toISOString() ?? null },
    });
    return viewOf(await readRowIn(tx, p.familyId), now);
  });
  gate?.invalidate();
  return view;
}

async function readRowIn(tx: Tx, familyId: string): Promise<SettingsRow> {
  const [row] = await tx.select().from(operatorSettings).where(eq(operatorSettings.familyId, familyId));
  return row ?? EMPTY;
}

export interface NoticeInput {
  /** null löscht den Hinweis. */
  text: string | null;
  /** Ablauf als Dauer in Minuten ab JETZT (Serverzeit), 1 Minute bis 90 Tage; null = bis zum Löschen. */
  expiresInMinutes: number | null;
}

/** Setzt oder löscht den Familienhinweis. Der Text steht nicht im Audit-Log, nur seine Länge und der Ablauf. */
export async function setNotice(ctx: AuthContext, p: SessionPrincipal, input: NoticeInput, meta: RequestMeta): Promise<SettingsView> {
  const now = ctx.now();
  const mins = input.expiresInMinutes;
  if (input.text === null && mins !== null) throw new AppError(400, 'invalid_duration', 'Dauer ungültig.');
  const text = input.text === null ? null : cleanNoticeText(input.text);
  if (mins !== null && (!Number.isInteger(mins) || mins < 1 || mins > NOTICE_MAX_MINUTES)) throw new AppError(400, 'invalid_duration', 'Dauer ungültig.');
  const expiresAt = mins === null || text === null ? null : new Date(now.getTime() + mins * 60_000);
  return ctx.db.transaction(async (tx) => {
    const before = viewOf(await lockRow(ctx, tx, p.familyId), now);
    await tx
      .update(operatorSettings)
      .set({
        noticeText: text,
        noticeExpiresAt: expiresAt,
        noticeSetAt: text === null ? null : now,
        noticeSetBy: text === null ? null : p.userId,
        updatedAt: now,
      })
      .where(eq(operatorSettings.familyId, p.familyId));
    await writeAudit(ctx, tx, {
      event: 'operator_notice_set',
      familyId: p.familyId,
      actorId: p.userId,
      deviceId: p.deviceId,
      ip: meta.ip,
      detail: { had: before.notice !== null, has: text !== null, length: text === null ? 0 : [...text].length, expiresAt: expiresAt?.toISOString() ?? null },
    });
    return viewOf(await readRowIn(tx, p.familyId), now);
  });
}

/** Notausgang für die Server-CLI: Wartungsmodus aller Familien ausschalten (ohne Sitzung, protokolliert als "cli"). Gibt zurück, ob etwas an war. */
export async function clearMaintenanceAll(ctx: AuthContext): Promise<boolean> {
  return ctx.db.transaction(async (tx) => {
    const rows = await tx
      .update(operatorSettings)
      .set({ maintenanceActive: false, maintenanceSince: null, maintenanceUntil: null, maintenanceBy: null, updatedAt: ctx.now() })
      .where(eq(operatorSettings.maintenanceActive, true))
      .returning({ familyId: operatorSettings.familyId });
    for (const r of rows) await writeAudit(ctx, tx, { event: 'operator_maintenance_set', familyId: r.familyId, detail: { from: true, to: false, until: null, via: 'cli' } });
    return rows.length > 0;
  });
}
