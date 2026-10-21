// GET /api/v1/admin/audit: das Audit-Protokoll für den Betreiber, nur lesend und seitenweise. Gezeigt werden nur Art, Zeit, Person und
// eine gekürzte Netzadresse; nie das Feld "detail" (kann Kennungen enthalten), nie Inhalte, Geheimnisse, Standorte oder Chat.
import { and, desc, eq, inArray, isNull, notInArray, or, sql, type SQL } from 'drizzle-orm';
import { isIPv4 } from 'node:net';
import type { AuthContext } from '../auth/context.js';
import { auditLog, users } from '../db/schema.js';
import { normalizeIp } from '../net.js';

export const AUDIT_CATEGORIES = ['alle', 'anmeldung', 'aenderungen', 'fehler'] as const;
export type AuditCategory = (typeof AUDIT_CATEGORIES)[number];

/** Anmeldung und Geräte (Alltag); Fehler und Auffälliges; alles Übrige sind Änderungen (neue Ereignisarten landen dort). */
const LOGIN_EVENTS = ['login_ok', 'logout', 'logout_all', 'device_added', 'device_removed', 'step_up_ok', 'recovery_code_used', 'invite_used', 'member_registered'];
const ERROR_EVENTS = [
  'login_failed',
  'step_up_failed',
  'invite_pin_failed',
  'invite_locked',
  'ws_auth_failed',
  'session_reuse_detected',
  'passkey_counter_regression',
  'password_setup_failed',
];

export function categoryOf(event: string): Exclude<AuditCategory, 'alle'> {
  if (ERROR_EVENTS.includes(event)) return 'fehler';
  if (LOGIN_EVENTS.includes(event)) return 'anmeldung';
  return 'aenderungen';
}

/** Kürzt eine Netzadresse für die Anzeige: IPv4 auf /24, IPv6 auf /48 ("203.0.113.0/24", "2a02:1234:5678::/48"). */
export function shortenNetwork(ip: string | null): string | null {
  if (!ip) return null;
  const n = normalizeIp(ip);
  if (isIPv4(n)) return `${n.split('.').slice(0, 3).join('.')}.0/24`;
  const groups = n.replace(/::\/64$/, '').split(':').slice(0, 3);
  return groups.length === 3 && groups.every((g) => /^[0-9a-f]{1,4}$/.test(g)) ? `${groups.join(':')}::/48` : null;
}

export interface AuditItem {
  id: string;
  at: string;
  event: string;
  category: Exclude<AuditCategory, 'alle'>;
  actor: { id: string; displayName: string } | null;
  network: string | null;
}

export interface AuditPage {
  items: AuditItem[];
  nextCursor: string | null;
}

/** Cursor: "<Zeitpunkt mit Mikrosekunden>|<id>"; wird nur als Wert in die Abfrage gebunden. */
export const CURSOR_FORMAT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\|[0-9a-f-]{36}$/;

export async function listAudit(ctx: AuthContext, familyId: string, input: { category: AuditCategory; limit: number; cursor?: string | undefined }): Promise<AuditPage> {
  const microTs = sql<string>`to_char(${auditLog.createdAt} at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;
  const filters: SQL[] = [
    // die Familie der Sitzung; Einträge ohne Familie (z. B. fehlgeschlagene Anmeldung mit unbekanntem Konto) tragen nur Art, Zeit und Netz
    or(eq(auditLog.familyId, familyId), isNull(auditLog.familyId)) as SQL,
  ];
  if (input.category === 'anmeldung') filters.push(inArray(auditLog.event, LOGIN_EVENTS));
  else if (input.category === 'fehler') filters.push(inArray(auditLog.event, ERROR_EVENTS));
  else if (input.category === 'aenderungen') filters.push(notInArray(auditLog.event, [...LOGIN_EVENTS, ...ERROR_EVENTS]));
  if (input.cursor) {
    const [ts, id] = input.cursor.split('|') as [string, string];
    filters.push(sql`(${auditLog.createdAt}, ${auditLog.id}) < (${ts}::timestamptz, ${id}::uuid)`);
  }
  const rows = await ctx.db
    .select({
      id: auditLog.id,
      at: auditLog.createdAt,
      cursorTs: microTs,
      event: auditLog.event,
      ip: auditLog.ip,
      actorId: auditLog.actorId,
      actorName: users.displayName,
    })
    .from(auditLog)
    .leftJoin(users, eq(users.id, auditLog.actorId))
    .where(and(...filters))
    .orderBy(desc(auditLog.createdAt), desc(auditLog.id))
    .limit(input.limit + 1);
  const page = rows.slice(0, input.limit);
  const last = page[page.length - 1];
  return {
    items: page.map((r) => ({
      id: r.id,
      at: r.at.toISOString(),
      event: r.event,
      category: categoryOf(r.event),
      actor: r.actorId && r.actorName ? { id: r.actorId, displayName: r.actorName } : null,
      network: shortenNetwork(r.ip),
    })),
    nextCursor: rows.length > input.limit && last ? `${last.cursorTs}|${last.id}` : null,
  };
}
