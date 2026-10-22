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

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;

// Steuerzeichen, Zeilentrenner und Richtungs-/Formatzeichen (Bidi-Umkehr, unsichtbare Zeichen) haben in einem Hinweis nichts verloren.
// eslint-disable-next-line no-control-regex
const FORBIDDEN_CHARS = /[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb]/u;

/** Prüft und bereinigt den Hinweistext: Unicode NFC, getrimmt, 1 bis 280 Zeichen, eine Zeile, reiner Text. Wirft 400 bei Verstoß. */
export function cleanNoticeText(raw: string): string {
  const text = raw.normalize('NFC').trim();
  if (text.length === 0 || [...text].length > NOTICE_MAX_CHARS || FORBIDDEN_CHARS.test(text)) throw new AppError(400, 'invalid_request');
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
  /** Automatisches Ende (höchstens 72 Stunden voraus); nur zusammen mit active=true. */
  until: Date | null;
}

/** Schaltet den Wartungsmodus. Ein Ende in der Vergangenheit oder über 72 Stunden hinaus wird abgelehnt (400); "aus" mit Ende ist ungültig. */
export async function setMaintenance(ctx: AuthContext, gate: MaintenanceGate | undefined, p: SessionPrincipal, input: MaintenanceInput, meta: RequestMeta): Promise<SettingsView> {
  const now = ctx.now();
  if (!input.active && input.until !== null) throw new AppError(400, 'invalid_request');
  if (input.until !== null && (input.until.getTime() <= now.getTime() || input.until.getTime() > now.getTime() + MAINTENANCE_MAX_HOURS * HOUR_MS)) throw new AppError(400, 'invalid_request');
  const view = await ctx.db.transaction(async (tx) => {
    const before = viewOf(await lockRow(ctx, tx, p.familyId), now);
    await tx
      .update(operatorSettings)
      .set({
        maintenanceActive: input.active,
        maintenanceSince: input.active ? (before.maintenance.active ? new Date(before.maintenance.since ?? now) : now) : null,
        maintenanceUntil: input.active ? input.until : null,
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
      detail: { from: before.maintenance.active, to: input.active, until: input.active ? (input.until?.toISOString() ?? null) : null },
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
  /** Ablauf (höchstens 90 Tage voraus); null = bis zum Löschen. */
  expiresAt: Date | null;
}

/** Setzt oder löscht den Familienhinweis. Der Text steht nicht im Audit-Log, nur seine Länge und der Ablauf. */
export async function setNotice(ctx: AuthContext, p: SessionPrincipal, input: NoticeInput, meta: RequestMeta): Promise<SettingsView> {
  const now = ctx.now();
  if (input.text === null && input.expiresAt !== null) throw new AppError(400, 'invalid_request');
  const text = input.text === null ? null : cleanNoticeText(input.text);
  if (input.expiresAt !== null && (input.expiresAt.getTime() <= now.getTime() || input.expiresAt.getTime() > now.getTime() + NOTICE_MAX_DAYS * DAY_MS)) throw new AppError(400, 'invalid_request');
  return ctx.db.transaction(async (tx) => {
    const before = viewOf(await lockRow(ctx, tx, p.familyId), now);
    await tx
      .update(operatorSettings)
      .set({
        noticeText: text,
        noticeExpiresAt: text === null ? null : input.expiresAt,
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
      detail: { had: before.notice !== null, has: text !== null, length: text === null ? 0 : [...text].length, expiresAt: text === null ? null : (input.expiresAt?.toISOString() ?? null) },
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
