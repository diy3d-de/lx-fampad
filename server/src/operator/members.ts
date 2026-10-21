// Betreiber-Seite "Mitglieder und Geräte" (`GET /admin/members`) und "Entsperren" (`POST /admin/members/:id/unlock`).
// Gelesen wird nur, was die Betreiberin ohnehin über ihre Familie wissen darf: Name, Rolle, Geräte mit Plattform, App-Version und Schlüsselstand, letzte Anmeldung,
// Art der Anmeldedaten (nur ob vorhanden), Anmeldesperre, Schlüssel-Ampel. Nie E-Mail, Tokens, Hashes, Schlüssel, Sicherungen, Netzadressen oder Inhalte.
import { and, asc, eq, inArray, isNull, max, sql } from 'drizzle-orm';
import { writeAudit } from '../auth/audit.js';
import type { AuthContext, RequestMeta } from '../auth/context.js';
import { accountKey } from '../auth/lockout.js';
import type { SessionPrincipal } from '../auth/types.js';
import { auditLog, credentials, devices, loginAttempts, memberships, operators, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { collectKeyStatus, DEVICE_REPORT_FRESH_DAYS, type Ampel, type KeyEventView, type Ways } from './key-status.js';

const DAY_MS = 86_400_000;

/** Stand des Schlüssels auf einem Gerät, wie das Gerät ihn gemeldet hat (feste Codes, die App ordnet Texte zu). */
export type DeviceKeyState =
  /** meldet die aktuelle Schlüsselversion (in den letzten 30 Tagen) */
  | 'current'
  /** meldet die aktuelle Version, aber der Bericht ist älter als 30 Tage */
  | 'stale'
  /** meldet eine ältere Schlüsselversion */
  | 'old'
  /** meldet, keinen Schlüssel zu haben */
  | 'none'
  /** hat nie gemeldet (alte App, Web ohne Bericht) oder die Person hat keinen Schlüssel */
  | 'unknown';

export function deviceKeyState(d: { keyVersion: number | null; reportedAt: Date | null }, current: number | null, now: Date): DeviceKeyState {
  if (d.keyVersion === null || d.reportedAt === null || current === null) return 'unknown';
  if (d.keyVersion === 0) return 'none';
  if (d.keyVersion < current) return 'old';
  if (d.keyVersion > current) return 'unknown';
  return now.getTime() - d.reportedAt.getTime() > DEVICE_REPORT_FRESH_DAYS * DAY_MS ? 'stale' : 'current';
}

export interface MemberDeviceView {
  id: string;
  name: string;
  platform: string;
  appVersion: string | null;
  createdAt: string;
  lastSeenAt: string | null;
  keyState: DeviceKeyState;
  keyVersion: number | null;
  keyReportedAt: string | null;
}

export interface MemberView {
  userId: string;
  displayName: string;
  role: 'admin' | 'parent' | 'child';
  familyRole: string | null;
  /** Ist diese Person der Betreiber (Konto-Flag)? */
  operator: boolean;
  /** Ist es die Person der Sitzung? */
  you: boolean;
  lastLoginAt: string | null;
  credentials: { passkeys: number; password: boolean; totp: boolean };
  /** Anmeldesperre des Kontos (nur die des Konto-Zählers; die einer einzelnen Netzadresse ist hier nicht sichtbar). */
  locked: { until: string; seconds: number } | null;
  ampel: Ampel;
  hasKeys: boolean;
  keyVersion: number | null;
  ways: Ways;
  legacyPassword: boolean;
  archiveCount: number;
  events: KeyEventView[];
  devices: MemberDeviceView[];
}

export interface MembersPage {
  generatedAt: string;
  members: MemberView[];
}

export async function collectMembers(ctx: AuthContext, p: SessionPrincipal): Promise<MembersPage> {
  const now = ctx.now();
  const keys = await collectKeyStatus(ctx, p.familyId);
  const ids = keys.persons.map((k) => k.userId);
  if (ids.length === 0) return { generatedAt: now.toISOString(), members: [] };

  const rows = await ctx.db
    .select({ userId: users.id, email: users.email, familyRole: memberships.familyRole })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, p.familyId), inArray(users.id, ids)));
  const ops = new Set((await ctx.db.select({ userId: operators.userId }).from(operators).where(inArray(operators.userId, ids))).map((o) => o.userId));
  const logins = new Map(
    (
      await ctx.db
        .select({ userId: auditLog.actorId, at: max(auditLog.createdAt) })
        .from(auditLog)
        .where(and(eq(auditLog.familyId, p.familyId), eq(auditLog.event, 'login_ok'), inArray(auditLog.actorId, ids)))
        .groupBy(auditLog.actorId)
    ).map((r) => [r.userId, r.at]),
  );
  const creds = await ctx.db
    .select({ userId: credentials.userId, type: credentials.type, n: sql<number>`count(*)::int` })
    .from(credentials)
    .where(and(inArray(credentials.userId, ids), isNull(credentials.revokedAt)))
    .groupBy(credentials.userId, credentials.type);
  const devs = await ctx.db
    .select({
      id: devices.id,
      userId: devices.userId,
      name: devices.name,
      platform: devices.platform,
      appVersion: devices.appVersion,
      createdAt: devices.createdAt,
      lastSeenAt: devices.lastSeenAt,
      keyVersion: devices.keyVersion,
      reportedAt: devices.keyReportedAt,
    })
    .from(devices)
    .where(and(eq(devices.familyId, p.familyId), isNull(devices.revokedAt), inArray(devices.userId, ids)))
    .orderBy(asc(devices.createdAt));

  const members: MemberView[] = [];
  for (const k of keys.persons) {
    const row = rows.find((r) => r.userId === k.userId);
    const [lock] = row
      ? await ctx.db.select({ until: loginAttempts.lockedUntil }).from(loginAttempts).where(eq(loginAttempts.key, accountKey(ctx, row.email)))
      : [];
    const locked = lock?.until && lock.until.getTime() > now.getTime() ? { until: lock.until.toISOString(), seconds: Math.ceil((lock.until.getTime() - now.getTime()) / 1000) } : null;
    const c = (t: string) => creds.find((x) => x.userId === k.userId && x.type === t)?.n ?? 0;
    members.push({
      userId: k.userId,
      displayName: k.displayName,
      role: k.role,
      familyRole: row?.familyRole ?? null,
      operator: ops.has(k.userId),
      you: k.userId === p.userId,
      lastLoginAt: logins.get(k.userId)?.toISOString() ?? null,
      credentials: { passkeys: c('passkey'), password: c('password') > 0, totp: c('totp') > 0 },
      locked,
      ampel: k.ampel,
      hasKeys: k.hasKeys,
      keyVersion: k.keyVersion,
      ways: k.ways,
      legacyPassword: k.legacyPassword,
      archiveCount: k.archiveCount,
      events: k.events,
      devices: devs
        .filter((d) => d.userId === k.userId)
        .map((d) => ({
          id: d.id,
          name: d.name,
          platform: d.platform,
          appVersion: d.appVersion,
          createdAt: d.createdAt.toISOString(),
          lastSeenAt: d.lastSeenAt?.toISOString() ?? null,
          keyState: deviceKeyState(d, k.keyVersion, now),
          keyVersion: d.keyVersion,
          keyReportedAt: d.reportedAt?.toISOString() ?? null,
        })),
    });
  }
  return { generatedAt: now.toISOString(), members };
}

/**
 * Hebt die Anmeldesperre des KONTO-Zählers eines Mitglieds auf (löscht den Zähler). Sperren einzelner Netzadressen (IP, Paar aus Konto und IP) bleiben und
 * laufen innerhalb von höchstens `lockoutMaxDelaySec` von selbst ab: das ist Absicht, ein Betreiber soll keine fremde Angriffssperre aufheben können.
 * Nur für aktive Mitglieder der eigenen Familie (sonst 404); protokolliert.
 */
export async function unlockMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<{ cleared: boolean }> {
  const [t] = await ctx.db
    .select({ email: users.email })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId), eq(memberships.status, 'active'), isNull(users.disabledAt)));
  if (!t) throw new AppError(404, 'not_found', 'Nicht gefunden.');
  return ctx.db.transaction(async (tx) => {
    const gone = await tx.delete(loginAttempts).where(eq(loginAttempts.key, accountKey(ctx, t.email))).returning({ key: loginAttempts.key });
    await writeAudit(ctx, tx, { event: 'operator_unlock', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { target: targetId, cleared: gone.length > 0 } });
    return { cleared: gone.length > 0 };
  });
}
