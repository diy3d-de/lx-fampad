// Sitzungen: Web = Cookie-Sitzung, App = kurzlebiges Access-Token (HMAC, 15 min) + Refresh-Token (Rotation, Wiederverwendungs-Erkennung).
// Jede Zeile in "sessions" ist ein Cookie bzw. ein Refresh-Token; die Rotation erzeugt eine Nachfolgezeile in derselben token_family.
import { and, eq, inArray, isNotNull, isNull, lt, or, sql } from 'drizzle-orm';
import type { FastifyRequest } from 'fastify';
import { devices, memberships, sessions, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { randomToken, safeEqual, sha256Hex } from './crypto.js';
import type { Role, SessionPrincipal } from './types.js';

export const SESSION_COOKIE = '__Host-lxsid';
export type SessionKind = 'web' | 'app';
export type AuthMethod = 'passkey' | 'password' | 'recovery';
type SessionRow = typeof sessions.$inferSelect;

export interface DeviceInput {
  id?: string | undefined;
  name: string;
  platform: string;
  appVersion?: string | undefined;
}

const UNSAFE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const TOUCH_INTERVAL_MS = 60_000;

// ---------- Tokens ----------

export function signAccessToken(ctx: AuthContext, sessionId: string): { token: string; expiresAt: Date } {
  const exp = Math.floor(ctx.now().getTime() / 1000) + ctx.config.auth.accessTokenTtlSec;
  const mac = ctx.keys.hmac('access-token', `${sessionId}.${exp}`);
  return { token: `v1.${sessionId}.${exp}.${mac}`, expiresAt: new Date(exp * 1000) };
}

/** Prüft Aufbau, Signatur und Ablauf des Access-Tokens; gibt die Sitzungs-ID zurück. */
export function parseAccessToken(ctx: AuthContext, token: string): string | null {
  const parts = token.split('.');
  if (parts.length !== 4 || parts[0] !== 'v1') return null;
  const [, sessionId, expRaw, mac] = parts as [string, string, string, string];
  if (!/^\d{1,12}$/.test(expRaw)) return null;
  if (!safeEqual(mac, ctx.keys.hmac('access-token', `${sessionId}.${expRaw}`))) return null;
  if (Number(expRaw) * 1000 <= ctx.now().getTime()) return null;
  return sessionId;
}

/** CSRF-Token der Cookie-Sitzung: aus der Sitzungs-ID abgeleitet, nichts zu speichern. */
export const csrfTokenFor = (ctx: AuthContext, sessionId: string): string => ctx.keys.hmac('csrf', sessionId);

export function parseCookies(header: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!header) return out;
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const name = part.slice(0, i).trim();
    if (name && !(name in out)) out[name] = part.slice(i + 1).trim();
  }
  return out;
}

/** `__Host-`-Präfix: Secure, Path=/, keine Domain; dazu HttpOnly und SameSite=Strict. */
export function sessionCookie(token: string, expiresAt: Date, now: Date): string {
  const maxAge = Math.max(0, Math.floor((expiresAt.getTime() - now.getTime()) / 1000));
  return `${SESSION_COOKIE}=${token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${maxAge}`;
}

export const clearedSessionCookie = (): string => `${SESSION_COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0`;

// ---------- Geräte ----------

/** Grobe, lesbare Gerätebezeichnung aus dem User-Agent (Browser auf System). */
export function describeUserAgent(ua: string | undefined): string {
  if (!ua) return 'Browser';
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const os = /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Windows/.test(ua) ? 'Windows' : /Mac OS X/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : '';
  return os ? `${browser} auf ${os}` : browser;
}

async function ensureDevice(
  ctx: AuthContext,
  exec: Executor,
  input: { familyId: string; userId: string; kind: SessionKind; device?: DeviceInput | undefined; userAgent?: string | undefined },
): Promise<{ id: string; isNew: boolean }> {
  const now = ctx.now();
  if (input.kind === 'app' && input.device?.id) {
    const [existing] = await exec
      .select({ id: devices.id })
      .from(devices)
      .where(and(eq(devices.id, input.device.id), eq(devices.userId, input.userId), eq(devices.familyId, input.familyId), isNull(devices.revokedAt)));
    if (existing) {
      await exec
        .update(devices)
        .set({ lastSeenAt: now, name: input.device.name, ...(input.device.appVersion ? { appVersion: input.device.appVersion } : {}) })
        .where(eq(devices.id, existing.id));
      return { id: existing.id, isNew: false };
    }
  }
  const [row] = await exec
    .insert(devices)
    .values({
      familyId: input.familyId,
      userId: input.userId,
      name: input.kind === 'web' ? describeUserAgent(input.userAgent) : (input.device?.name ?? 'App'),
      platform: input.kind === 'web' ? 'web' : (input.device?.platform ?? 'android'),
      appVersion: input.kind === 'app' ? (input.device?.appVersion ?? null) : null,
      lastSeenAt: now,
      createdAt: now,
    })
    .returning({ id: devices.id });
  if (!row) throw new Error('Gerät nicht angelegt');
  return { id: row.id, isNew: true };
}

// ---------- Anlegen ----------

function limitsFor(ctx: AuthContext, kind: SessionKind) {
  const a = ctx.config.auth;
  return kind === 'web'
    ? { maxMs: a.webSessionMaxDays * 86_400_000, idleMs: a.webSessionIdleDays * 86_400_000 }
    : { maxMs: a.appSessionMaxDays * 86_400_000, idleMs: a.appSessionIdleDays * 86_400_000 };
}

export interface NewSession {
  familyId: string;
  userId: string;
  deviceId: string;
  kind: SessionKind;
  authMethod: AuthMethod;
  stepUpAt: Date | null;
  /** Rotation: Familie und absolute Ablaufzeit der Vorgängerin bleiben erhalten. */
  tokenFamily?: string;
  expiresAt?: Date;
}

export async function insertSession(ctx: AuthContext, exec: Executor, input: NewSession): Promise<{ row: SessionRow; token: string }> {
  const now = ctx.now();
  const token = randomToken(32);
  const [row] = await exec
    .insert(sessions)
    .values({
      familyId: input.familyId,
      userId: input.userId,
      deviceId: input.deviceId,
      kind: input.kind,
      authMethod: input.authMethod,
      stepUpAt: input.stepUpAt,
      tokenHash: sha256Hex(token),
      ...(input.tokenFamily ? { tokenFamily: input.tokenFamily } : {}),
      createdAt: now,
      lastSeenAt: now,
      expiresAt: input.expiresAt ?? new Date(now.getTime() + limitsFor(ctx, input.kind).maxMs),
    })
    .returning();
  if (!row) throw new Error('Sitzung nicht angelegt');
  return { row, token };
}

export interface Established {
  userId: string;
  familyId: string;
  sessionId: string;
  deviceId: string;
  kind: SessionKind;
  /** Web: Wert des Cookies; App: Refresh-Token. */
  token: string;
  expiresAt: Date;
  accessToken?: string;
  accessExpiresAt?: Date;
  csrfToken?: string;
}

export function toEstablished(ctx: AuthContext, row: SessionRow, token: string): Established {
  const base: Established = {
    userId: row.userId,
    familyId: row.familyId,
    sessionId: row.id,
    deviceId: row.deviceId ?? '',
    kind: row.kind as SessionKind,
    token,
    expiresAt: row.expiresAt,
  };
  if (row.kind === 'app') {
    const access = signAccessToken(ctx, row.id);
    return { ...base, accessToken: access.token, accessExpiresAt: access.expiresAt };
  }
  return { ...base, csrfToken: csrfTokenFor(ctx, row.id) };
}

/** Meldet die Person an: Gerät anlegen oder wiederverwenden, Sitzung erzeugen, Audit schreiben. */
export async function establishSession(
  ctx: AuthContext,
  exec: Executor,
  input: { userId: string; familyId: string; client: SessionKind; device?: DeviceInput | undefined; authMethod: AuthMethod; meta: RequestMeta },
): Promise<Established> {
  const device = await ensureDevice(ctx, exec, {
    familyId: input.familyId,
    userId: input.userId,
    kind: input.client,
    device: input.device,
    userAgent: input.meta.userAgent,
  });
  const { row, token } = await insertSession(ctx, exec, {
    familyId: input.familyId,
    userId: input.userId,
    deviceId: device.id,
    kind: input.client,
    authMethod: input.authMethod,
    // die Anmeldung selbst (Passkey mit Nutzerprüfung, Passwort+TOTP, Wiederherstellungs-Code) zählt als frische Bestätigung
    stepUpAt: ctx.now(),
  });
  if (device.isNew) {
    await writeAudit(ctx, exec, { event: 'device_added', familyId: input.familyId, actorId: input.userId, deviceId: device.id, ip: input.meta.ip, detail: { kind: input.client } });
  }
  await writeAudit(ctx, exec, { event: 'login_ok', familyId: input.familyId, actorId: input.userId, deviceId: device.id, ip: input.meta.ip, detail: { method: input.authMethod, kind: input.client } });
  return toEstablished(ctx, row, token);
}

// ---------- Prüfen ----------

interface Live {
  row: SessionRow;
  role: Role;
}

const liveSelect = (ctx: AuthContext) =>
  ctx.db
    .select({ row: sessions, role: memberships.role })
    .from(sessions)
    .innerJoin(memberships, and(eq(memberships.familyId, sessions.familyId), eq(memberships.userId, sessions.userId)))
    .innerJoin(users, eq(users.id, sessions.userId));

/** Gültigkeit einer Sitzungszeile: nicht widerrufen, nicht abgelaufen (absolut und im Leerlauf). */
export function isAlive(ctx: AuthContext, row: SessionRow, opts: { allowUsed?: boolean } = {}): boolean {
  if (row.revokedAt) return false;
  if (row.usedAt && !opts.allowUsed) return false;
  const now = ctx.now().getTime();
  if (row.expiresAt.getTime() <= now) return false;
  const last = (row.lastSeenAt ?? row.createdAt).getTime();
  return now - last <= limitsFor(ctx, row.kind as SessionKind).idleMs;
}

/** Lädt die Sitzung samt Rolle; nur aktive Mitglieder, nicht gesperrte Benutzer. */
export async function loadLive(ctx: AuthContext, by: { id: string } | { tokenHash: string }): Promise<Live | null> {
  const cond = 'id' in by ? eq(sessions.id, by.id) : eq(sessions.tokenHash, by.tokenHash);
  const [r] = await liveSelect(ctx).where(and(cond, eq(memberships.status, 'active'), isNull(users.disabledAt)));
  return r ?? null;
}

async function touch(ctx: AuthContext, row: SessionRow): Promise<void> {
  const now = ctx.now();
  if (row.lastSeenAt && now.getTime() - row.lastSeenAt.getTime() < TOUCH_INTERVAL_MS) return;
  await ctx.db.update(sessions).set({ lastSeenAt: now }).where(eq(sessions.id, row.id));
  if (row.deviceId) await ctx.db.update(devices).set({ lastSeenAt: now }).where(eq(devices.id, row.deviceId));
}

function toPrincipal(row: SessionRow, role: Role, via: 'cookie' | 'bearer'): SessionPrincipal {
  return { userId: row.userId, familyId: row.familyId, role, deviceId: row.deviceId, sessionId: row.id, via, stepUpAt: row.stepUpAt };
}

/** Prüft Bearer-Token (App) oder Session-Cookie (Web); bei Cookie-Sitzungen und ändernden Methoden zusätzlich das CSRF-Token. */
export async function authenticateRequest(ctx: AuthContext, req: FastifyRequest): Promise<SessionPrincipal | null> {
  const authz = req.headers.authorization;
  if (authz !== undefined) {
    // ein vorhandener, aber ungültiger Authorization-Header fällt nie auf das Cookie zurück
    const m = /^Bearer\s+(\S+)$/i.exec(authz);
    const sessionId = m?.[1] ? parseAccessToken(ctx, m[1]) : null;
    if (!sessionId) return null;
    const live = await loadLive(ctx, { id: sessionId });
    if (!live || live.row.kind !== 'app' || !isAlive(ctx, live.row)) return null;
    await touch(ctx, live.row);
    return toPrincipal(live.row, live.role, 'bearer');
  }
  const cookie = parseCookies(req.headers.cookie)[SESSION_COOKIE];
  if (!cookie) return null;
  const live = await loadLive(ctx, { tokenHash: sha256Hex(cookie) });
  if (!live || live.row.kind !== 'web' || !isAlive(ctx, live.row)) return null;
  if (UNSAFE_METHODS.has(req.method)) {
    const header = req.headers['x-csrf-token'];
    const given = typeof header === 'string' ? header : '';
    if (!given || !safeEqual(given, csrfTokenFor(ctx, live.row.id))) {
      throw new AppError(403, 'csrf_invalid', 'Anfrage abgelehnt (CSRF-Prüfung).');
    }
  }
  await touch(ctx, live.row);
  return toPrincipal(live.row, live.role, 'cookie');
}

// ---------- Widerrufen ----------

/** Widerruft alle Sitzungen der Person (und markiert ihre Geräte als abgemeldet); optional eine Sitzung ausnehmen. */
export async function revokeAllForUser(ctx: AuthContext, exec: Executor, userId: string, opts: { exceptSessionId?: string } = {}): Promise<void> {
  const now = ctx.now();
  // Das Gerät der ausgenommenen Sitzung bleibt aktiv, auch wenn dort ältere Sitzungszeilen (Rotation) widerrufen werden.
  let keepDevice: string | null = null;
  if (opts.exceptSessionId) {
    const [kept] = await exec.select({ deviceId: sessions.deviceId }).from(sessions).where(and(eq(sessions.id, opts.exceptSessionId), eq(sessions.userId, userId)));
    keepDevice = kept?.deviceId ?? null;
  }
  const where = and(eq(sessions.userId, userId), isNull(sessions.revokedAt), opts.exceptSessionId ? sql`${sessions.id} <> ${opts.exceptSessionId}` : undefined);
  const hit = await exec.update(sessions).set({ revokedAt: now }).where(where).returning({ deviceId: sessions.deviceId });
  const deviceIds = [...new Set(hit.map((h) => h.deviceId).filter((d): d is string => !!d && d !== keepDevice))];
  if (deviceIds.length > 0) await exec.update(devices).set({ revokedAt: now }).where(and(inArray(devices.id, deviceIds), isNull(devices.revokedAt)));
  if (!opts.exceptSessionId) await exec.update(devices).set({ revokedAt: now }).where(and(eq(devices.userId, userId), isNull(devices.revokedAt)));
  ctx.onRevoke({ kind: 'user', userId, exceptSessionId: opts.exceptSessionId });
}

/** Meldet ein Gerät ab: alle seine Sitzungen werden widerrufen, das Gerät verschwindet aus der Liste. */
export async function revokeDevice(ctx: AuthContext, exec: Executor, deviceId: string): Promise<void> {
  const now = ctx.now();
  await exec.update(sessions).set({ revokedAt: now }).where(and(eq(sessions.deviceId, deviceId), isNull(sessions.revokedAt)));
  await exec.update(devices).set({ revokedAt: now }).where(and(eq(devices.id, deviceId), isNull(devices.revokedAt)));
  ctx.onRevoke({ kind: 'device', deviceId });
}

export async function revokeFamily(ctx: AuthContext, exec: Executor, tokenFamily: string): Promise<void> {
  await exec.update(sessions).set({ revokedAt: ctx.now() }).where(and(eq(sessions.tokenFamily, tokenFamily), isNull(sessions.revokedAt)));
}

// ---------- Refresh-Token mit Rotation ----------

export interface RefreshResult {
  established: Established;
}

/**
 * Toleranzfenster für ein gerade rotiertes Refresh-Token (Antwort ging unterwegs verloren, z. B. Funkloch nach dem Senden).
 * Nur wenn ALLES zutrifft, wird die Wiederholung bedient statt die Familie zu widerrufen:
 *   - die Zeile wurde vor höchstens `refreshGraceSec` Sekunden eingelöst (festes Fenster ab used_at, nicht gleitend),
 *   - dieselbe Geräte-ID wie beim ersten Einlösen,
 *   - die Nachfolgerin ist noch unbenutzt (nicht eingelöst, nicht widerrufen).
 * Dann wird die Nachfolgerin widerrufen und genau eine neue Nachfolgerin ausgestellt (es gibt nie zwei lebende Nachfolger).
 * Alles andere bleibt echte Wiederverwendung (Familie widerrufen). Die Zeile der eingelösten Sitzung wird gesperrt (FOR UPDATE),
 * damit parallele Wiederholungen nacheinander laufen.
 */
async function regrantRefresh(
  ctx: AuthContext,
  rowId: string,
  input: { deviceId: string },
  meta: RequestMeta,
): Promise<{ next: { row: SessionRow; token: string }; revokedSuccessor: string } | null> {
  const graceMs = ctx.config.auth.refreshGraceSec * 1000;
  if (graceMs <= 0) return null;
  return ctx.db.transaction(async (tx) => {
    const [cur] = await tx.select().from(sessions).where(eq(sessions.id, rowId)).for('update');
    if (!cur || cur.kind !== 'app' || cur.revokedAt || !cur.usedAt || !cur.rotatedTo) return null;
    if (!cur.deviceId || cur.deviceId !== input.deviceId) return null;
    const now = ctx.now();
    if (now.getTime() - cur.usedAt.getTime() > graceMs || now.getTime() < cur.usedAt.getTime()) return null;
    if (!isAlive(ctx, cur, { allowUsed: true })) return null;
    const [succ] = await tx.select().from(sessions).where(eq(sessions.id, cur.rotatedTo)).for('update');
    if (!succ || succ.revokedAt || succ.usedAt || succ.tokenFamily !== cur.tokenFamily) return null;
    await tx.update(sessions).set({ revokedAt: now }).where(eq(sessions.id, succ.id));
    const next = await insertSession(ctx, tx, {
      familyId: cur.familyId,
      userId: cur.userId,
      deviceId: cur.deviceId,
      kind: 'app',
      authMethod: cur.authMethod as AuthMethod,
      stepUpAt: cur.stepUpAt,
      tokenFamily: cur.tokenFamily,
      expiresAt: cur.expiresAt,
    });
    await tx.update(sessions).set({ rotatedTo: next.row.id }).where(eq(sessions.id, cur.id));
    await writeAudit(ctx, tx, { event: 'session_refresh_retry', familyId: cur.familyId, actorId: cur.userId, deviceId: cur.deviceId, ip: meta.ip });
    return { next, revokedSuccessor: succ.id };
  });
}

/**
 * Löst ein Refresh-Token ein. Jedes Token gilt genau einmal: Die Zeile bekommt used_at und rotated_to, eine
 * Nachfolgerin in derselben token_family entsteht. Wird ein bereits eingelöstes Token erneut vorgelegt (auch
 * gleichzeitig), ist es gestohlen oder kopiert: die ganze Familie wird widerrufen und ein Audit-Eintrag geschrieben.
 * Ausnahme: das kurze Toleranzfenster, siehe [regrantRefresh].
 */
export async function refreshSession(ctx: AuthContext, input: { refreshToken: string; deviceId: string }, meta: RequestMeta): Promise<RefreshResult> {
  const fail = () => new AppError(401, 'invalid_token', 'Sitzung abgelaufen. Bitte neu anmelden.');
  const live = await loadLive(ctx, { tokenHash: sha256Hex(input.refreshToken) });
  if (!live || live.row.kind !== 'app') throw fail();
  const row = live.row;

  const reuse = async (): Promise<RefreshResult> => {
    // erst das Toleranzfenster (verlorene Antwort, gleiches Gerät, Nachfolgerin unbenutzt), sonst Widerruf der Familie
    const again = await regrantRefresh(ctx, row.id, input, meta);
    if (again) {
      ctx.onRevoke({ kind: 'session', sessionId: again.revokedSuccessor });
      return { established: toEstablished(ctx, again.next.row, again.next.token) };
    }
    await ctx.db.transaction(async (tx) => {
      await revokeFamily(ctx, tx, row.tokenFamily);
      await writeAudit(ctx, tx, { event: 'session_reuse_detected', familyId: row.familyId, actorId: row.userId, deviceId: row.deviceId, ip: meta.ip });
    });
    throw fail();
  };

  if (row.revokedAt) throw fail();
  if (row.usedAt) return reuse();
  if (!isAlive(ctx, row)) throw fail();
  if (row.deviceId !== input.deviceId) throw fail();

  const now = ctx.now();
  const result = await ctx.db.transaction(async (tx) => {
    // Einlösen ist atomar: nur die erste Anfrage setzt used_at, jede weitere gilt als Wiederverwendung (oder Wiederholung im Fenster)
    const claimed = await tx
      .update(sessions)
      .set({ usedAt: now })
      .where(and(eq(sessions.id, row.id), isNull(sessions.usedAt), isNull(sessions.revokedAt)))
      .returning({ id: sessions.id });
    if (claimed.length === 0) return null;
    const next = await insertSession(ctx, tx, {
      familyId: row.familyId,
      userId: row.userId,
      deviceId: row.deviceId ?? input.deviceId,
      kind: 'app',
      authMethod: row.authMethod as AuthMethod,
      stepUpAt: row.stepUpAt,
      tokenFamily: row.tokenFamily,
      expiresAt: row.expiresAt,
    });
    await tx.update(sessions).set({ rotatedTo: next.row.id }).where(eq(sessions.id, row.id));
    if (row.deviceId) await tx.update(devices).set({ lastSeenAt: now }).where(eq(devices.id, row.deviceId));
    return next;
  });
  if (!result) return reuse();
  return { established: toEstablished(ctx, result.row, result.token) };
}

// ---------- Step-up ----------

/** Setzt "frisch bestätigt" für die Sitzung (nach erneuter Passkey-/TOTP-/Code-Prüfung). */
export async function markStepUp(ctx: AuthContext, sessionId: string): Promise<Date> {
  const now = ctx.now();
  await ctx.db.update(sessions).set({ stepUpAt: now }).where(eq(sessions.id, sessionId));
  return now;
}

/** Wiederverwendbare Prüfung für Tresor, Rollenänderung, Familie löschen, neuen Passkey: wirft 403 step_up_required. */
export function requireStepUp(ctx: AuthContext, principal: SessionPrincipal): void {
  const age = principal.stepUpAt ? ctx.now().getTime() - principal.stepUpAt.getTime() : Number.POSITIVE_INFINITY;
  if (age > ctx.config.auth.stepUpMaxAgeSec * 1000) {
    throw new AppError(403, 'step_up_required', 'Bitte bestätige deine Identität erneut.');
  }
}

// ---------- Aufräumen ----------

export async function purgeSessions(ctx: AuthContext): Promise<number> {
  const now = ctx.now();
  const dayAgo = new Date(now.getTime() - 86_400_000);
  const monthAgo = new Date(now.getTime() - 30 * 86_400_000);
  // abgelaufene Sitzungen erst nach einem Tag löschen (Wiederverwendungs-Erkennung braucht die Zeilen bis zum Ablauf);
  // widerrufene nach 30 Tagen; Leerlauf-Abläufe fallen spätestens mit dem absoluten Ablauf heraus
  const gone = await ctx.db
    .delete(sessions)
    .where(or(lt(sessions.expiresAt, dayAgo), and(isNotNull(sessions.revokedAt), lt(sessions.revokedAt, monthAgo))))
    .returning({ id: sessions.id });
  await ctx.db.delete(devices).where(and(isNotNull(devices.revokedAt), lt(devices.revokedAt, monthAgo)));
  return gone.length;
}
