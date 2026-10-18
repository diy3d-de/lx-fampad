// Konto-Verwaltung nach der Anmeldung: Profil, Mitglieder, Geräte, Anmeldedaten, Wiederherstellungs-Codes, WebSocket-Tickets.
import type { RegistrationResponseJSON } from '@simplewebauthn/server';
import { and, asc, count, eq, gt, isNull, sql } from 'drizzle-orm';
import { credentials, devices, invites, memberships, sessions, users, wsTickets } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import { saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { randomToken, sha256Hex } from './crypto.js';
import { createInvite, type CreatedInvite } from './invites.js';
import { findAccountById, type Account } from './login.js';
import { assertNotLocked, ipKey, recordFailure } from './lockout.js';
import { countRemainingCodes, createRecoveryCodes } from './recovery.js';
import type { MemberView } from './register.js';
import { csrfTokenFor, isAlive, requireStepUp, revokeAllForUser, revokeDevice } from './sessions.js';
import type { Principal, Role, SessionPrincipal } from './types.js';
import { checkRegistration, registrationOptions } from './webauthn.js';

const forbidden = () => new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
const notFound = () => new AppError(404, 'not_found');

function requireAdmin(p: SessionPrincipal): void {
  if (p.role !== 'admin') throw forbidden();
}

// ---------- Profil ----------

export async function getMe(ctx: AuthContext, p: SessionPrincipal) {
  const account = await findAccountById(ctx, p.userId);
  if (!account) throw notFound();
  const creds = await ctx.db
    .select({ type: credentials.type })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)));
  return {
    user: { id: account.userId, email: account.email, displayName: account.displayName, colorIndex: account.colorIndex, role: account.role, status: account.status },
    familyId: account.familyId,
    session: { id: p.sessionId, deviceId: p.deviceId, stepUpAt: p.stepUpAt },
    ...(p.via === 'cookie' ? { csrfToken: csrfTokenFor(ctx, p.sessionId) } : {}),
    credentials: {
      passkeys: creds.filter((c) => c.type === 'passkey').length,
      password: creds.some((c) => c.type === 'password'),
      totp: creds.some((c) => c.type === 'totp'),
    },
    recoveryCodesRemaining: await countRemainingCodes(ctx, p.userId),
  };
}

export async function updateProfile(ctx: AuthContext, p: SessionPrincipal, input: { displayName?: string | undefined; colorIndex?: number | undefined }): Promise<void> {
  const set: Partial<typeof users.$inferInsert> = {};
  if (input.displayName !== undefined) set.displayName = input.displayName;
  if (input.colorIndex !== undefined) set.colorIndex = input.colorIndex;
  if (Object.keys(set).length === 0) return;
  await ctx.db.update(users).set(set).where(eq(users.id, p.userId));
}

// ---------- Mitglieder ----------

interface MemberRow {
  id: string;
  email: string;
  displayName: string;
  colorIndex: number;
  role: Role;
  status: 'active' | 'pending';
}

/** Alle sehen aktive Mitglieder (ohne E-Mail); Admins zusätzlich E-Mail und wartende Mitglieder. */
export async function listMembers(ctx: AuthContext, p: SessionPrincipal): Promise<Array<Omit<MemberView, 'email'> & { email?: string }>> {
  const rows: MemberRow[] = await ctx.db
    .select({ id: users.id, email: users.email, displayName: users.displayName, colorIndex: users.colorIndex, role: memberships.role, status: memberships.status })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, p.familyId), isNull(users.disabledAt), p.role === 'admin' ? undefined : eq(memberships.status, 'active')))
    .orderBy(asc(users.displayName));
  return rows.map((r) => (p.role === 'admin' || r.id === p.userId ? r : { id: r.id, displayName: r.displayName, colorIndex: r.colorIndex, role: r.role, status: r.status }));
}

async function memberOf(ctx: AuthContext, p: SessionPrincipal, userId: string): Promise<Account> {
  const a = await findAccountById(ctx, userId);
  if (!a || a.familyId !== p.familyId) throw notFound();
  return a;
}

async function activeAdminCount(exec: Executor, familyId: string): Promise<number> {
  const [r] = await exec
    .select({ n: count() })
    .from(memberships)
    .where(and(eq(memberships.familyId, familyId), eq(memberships.role, 'admin'), eq(memberships.status, 'active')));
  return r?.n ?? 0;
}

export async function changeRole(ctx: AuthContext, p: SessionPrincipal, targetId: string, role: Role, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  requireStepUp(ctx, p);
  const target = await memberOf(ctx, p, targetId);
  if (target.role === role) return;
  await ctx.db.transaction(async (tx) => {
    // Admin-Zeilen sperren: zwei gleichzeitige Herabstufungen dürfen nicht den letzten Admin entfernen
    await tx.select({ id: memberships.id }).from(memberships).where(and(eq(memberships.familyId, p.familyId), eq(memberships.role, 'admin'))).for('update');
    if (target.role === 'admin' && (await activeAdminCount(tx, p.familyId)) <= 1) {
      throw new AppError(409, 'last_admin', 'Der letzte Admin kann nicht herabgestuft werden.');
    }
    await tx.update(memberships).set({ role }).where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId)));
    // Rollenwechsel: alle Sitzungen der Person enden, sie meldet sich mit der neuen Rolle neu an
    await revokeAllForUser(ctx, tx, targetId);
    await writeAudit(ctx, tx, {
      event: 'role_changed',
      familyId: p.familyId,
      actorId: p.userId,
      ip: meta.ip,
      detail: { target: targetId, from: target.role, to: role },
    });
  });
}

export async function approveMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  const done = await ctx.db
    .update(memberships)
    .set({ status: 'active' })
    .where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId), eq(memberships.status, 'pending')))
    .returning({ id: memberships.id });
  if (done.length === 0) throw notFound();
  await writeAudit(ctx, ctx.db, { event: 'member_approved', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId } });
}

export async function rejectMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  const target = await memberOf(ctx, p, targetId);
  if (target.status !== 'pending') throw new AppError(409, 'not_pending', 'Das Mitglied wartet nicht auf Freigabe.');
  await ctx.db.transaction(async (tx) => {
    await tx.delete(users).where(eq(users.id, targetId));
    await writeAudit(ctx, tx, { event: 'member_rejected', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId } });
  });
}

export async function removeMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  requireStepUp(ctx, p);
  if (targetId === p.userId) throw new AppError(409, 'cannot_remove_self', 'Du kannst dich nicht selbst entfernen.');
  const target = await memberOf(ctx, p, targetId);
  await ctx.db.transaction(async (tx) => {
    await tx.select({ id: memberships.id }).from(memberships).where(and(eq(memberships.familyId, p.familyId), eq(memberships.role, 'admin'))).for('update');
    if (target.role === 'admin' && (await activeAdminCount(tx, p.familyId)) <= 1) {
      throw new AppError(409, 'last_admin', 'Der letzte Admin kann nicht entfernt werden.');
    }
    await tx.delete(users).where(eq(users.id, targetId));
    await writeAudit(ctx, tx, { event: 'member_removed', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId, role: target.role } });
  });
}

/**
 * Setzt ein Mitglied zurück: alle Anmeldedaten und Sitzungen werden widerrufen, die Wiederherstellungs-Codes entfallen,
 * eine neue Einladung (für dasselbe Konto) wird erzeugt. `actorId` null = Betreiber über die Kommandozeile.
 */
export async function resetMember(
  ctx: AuthContext,
  input: { familyId: string; userId: string; actorId: string | null; hours: number; withPin: boolean },
  meta: RequestMeta,
): Promise<CreatedInvite> {
  const target = await findAccountById(ctx, input.userId);
  if (!target || target.familyId !== input.familyId) throw notFound();
  return ctx.db.transaction(async (tx) => {
    const now = ctx.now();
    await tx.update(credentials).set({ revokedAt: now }).where(and(eq(credentials.userId, input.userId), isNull(credentials.revokedAt)));
    await tx.execute(sql`delete from recovery_codes where user_id = ${input.userId}`);
    await revokeAllForUser(ctx, tx, input.userId);
    await tx.update(invites).set({ revokedAt: now }).where(and(eq(invites.userId, input.userId), isNull(invites.usedAt), isNull(invites.revokedAt)));
    const invite = await createInvite(
      ctx,
      tx,
      { familyId: input.familyId, role: target.role, hours: input.hours, withPin: input.withPin, requireApproval: false, userId: input.userId, createdBy: input.actorId },
      meta,
    );
    await writeAudit(ctx, tx, { event: 'member_reset', familyId: input.familyId, actorId: input.actorId, ip: meta.ip, detail: { target: input.userId } });
    return invite;
  });
}

// ---------- Geräte und Abmelden ----------

export async function listDevices(ctx: AuthContext, p: SessionPrincipal) {
  const rows = await ctx.db
    .select({ id: devices.id, name: devices.name, platform: devices.platform, appVersion: devices.appVersion, createdAt: devices.createdAt, lastSeenAt: devices.lastSeenAt })
    .from(devices)
    .where(and(eq(devices.userId, p.userId), isNull(devices.revokedAt)))
    .orderBy(asc(devices.createdAt));
  return rows.map((d) => ({ ...d, current: d.id === p.deviceId }));
}

export async function removeDevice(ctx: AuthContext, p: SessionPrincipal, deviceId: string, meta: RequestMeta): Promise<{ current: boolean }> {
  const [d] = await ctx.db.select({ id: devices.id }).from(devices).where(and(eq(devices.id, deviceId), eq(devices.userId, p.userId), isNull(devices.revokedAt)));
  if (!d) throw notFound();
  await ctx.db.transaction(async (tx) => {
    await revokeDevice(ctx, tx, deviceId);
    await writeAudit(ctx, tx, { event: 'device_removed', familyId: p.familyId, actorId: p.userId, deviceId, ip: meta.ip });
  });
  return { current: deviceId === p.deviceId };
}

export async function logoutCurrent(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<void> {
  await ctx.db.transaction(async (tx) => {
    if (p.deviceId) await revokeDevice(ctx, tx, p.deviceId);
    else await tx.update(sessions).set({ revokedAt: ctx.now() }).where(eq(sessions.id, p.sessionId));
    await writeAudit(ctx, tx, { event: 'logout', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip });
  });
}

export async function logoutEverywhere(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<void> {
  await ctx.db.transaction(async (tx) => {
    await revokeAllForUser(ctx, tx, p.userId);
    await writeAudit(ctx, tx, { event: 'logout_all', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
  });
}

// ---------- Anmeldedaten ----------

export async function listCredentials(ctx: AuthContext, p: SessionPrincipal) {
  return ctx.db
    .select({ id: credentials.id, type: credentials.type, label: credentials.label, createdAt: credentials.createdAt, lastUsedAt: credentials.lastUsedAt })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)))
    .orderBy(asc(credentials.createdAt));
}

export async function startAddPasskey(ctx: AuthContext, p: SessionPrincipal) {
  requireStepUp(ctx, p);
  const account = await findAccountById(ctx, p.userId);
  if (!account) throw notFound();
  const existing = await ctx.db
    .select({ externalId: credentials.externalId, transports: credentials.transports })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), eq(credentials.type, 'passkey'), isNull(credentials.revokedAt)));
  const options = await registrationOptions(ctx, {
    userId: p.userId,
    accountName: account.email,
    displayName: account.displayName,
    existing: existing.map((e) => ({ externalId: e.externalId ?? '', transports: e.transports })),
  });
  const challengeId = await saveChallenge(ctx, { purpose: 'add_passkey', challenge: options.challenge, userId: p.userId });
  return { challengeId, options };
}

export async function finishAddPasskey(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { challengeId: string; response: RegistrationResponseJSON; label?: string | undefined },
  meta: RequestMeta,
): Promise<{ id: string }> {
  requireStepUp(ctx, p);
  await assertNotLocked(ctx, [ipKey(ctx, meta.ip)]);
  const taken = await takeChallenge(ctx, input.challengeId, 'add_passkey');
  if (!taken || taken.userId !== p.userId) throw new AppError(400, 'challenge_invalid', 'Der Vorgang ist abgelaufen. Bitte neu beginnen.');
  const verified = await checkRegistration(ctx, input.response, taken.challenge);
  if (!verified) {
    await recordFailure(ctx, ipKey(ctx, meta.ip), ctx.config.auth.lockoutIpThreshold);
    throw new AppError(400, 'registration_failed', 'Der Passkey konnte nicht überprüft werden.');
  }
  try {
    const [row] = await ctx.db
      .insert(credentials)
      .values({
        userId: p.userId,
        type: 'passkey',
        label: input.label ?? null,
        externalId: verified.externalId,
        secret: verified.publicKey,
        signCount: verified.counter,
        transports: verified.transports,
        createdAt: ctx.now(),
      })
      .returning({ id: credentials.id });
    await writeAudit(ctx, ctx.db, { event: 'passkey_added', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { credentialId: row?.id } });
    return { id: row?.id ?? '' };
  } catch (err) {
    if ((err as { code?: string; cause?: { code?: string } }).code === '23505' || (err as { cause?: { code?: string } }).cause?.code === '23505') {
      throw new AppError(409, 'passkey_exists', 'Dieser Passkey ist bereits eingerichtet.');
    }
    throw err;
  }
}

export async function removePasskey(ctx: AuthContext, p: SessionPrincipal, credentialId: string, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const own = await tx
      .select({ id: credentials.id, type: credentials.type })
      .from(credentials)
      .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)))
      .for('update');
    const target = own.find((c) => c.id === credentialId);
    if (!target || target.type !== 'passkey') throw notFound();
    // es muss eine Anmeldemöglichkeit übrig bleiben: weiterer Passkey oder Passwort (mit TOTP)
    const remaining = own.filter((c) => c.id !== credentialId);
    if (!remaining.some((c) => c.type === 'passkey' || c.type === 'password')) {
      throw new AppError(409, 'last_credential', 'Der letzte Passkey kann nicht entfernt werden.');
    }
    await tx.update(credentials).set({ revokedAt: ctx.now() }).where(eq(credentials.id, credentialId));
    await writeAudit(ctx, tx, { event: 'passkey_removed', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { credentialId } });
  });
}

export async function regenerateRecoveryCodes(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<string[]> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const codes = await createRecoveryCodes(ctx, tx, p.userId);
    await writeAudit(ctx, tx, { event: 'recovery_codes_created', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
    return codes;
  });
}

// ---------- WebSocket-Tickets ----------

export async function issueWsTicket(ctx: AuthContext, p: SessionPrincipal): Promise<{ ticket: string; expiresInSec: number }> {
  const ticket = randomToken(32);
  const ttl = ctx.config.auth.wsTicketTtlSec;
  const now = ctx.now();
  await ctx.db.insert(wsTickets).values({
    tokenHash: sha256Hex(ticket),
    familyId: p.familyId,
    userId: p.userId,
    sessionId: p.sessionId,
    createdAt: now,
    expiresAt: new Date(now.getTime() + ttl * 1000),
  });
  return { ticket, expiresInSec: ttl };
}

/** Löst ein Ticket genau einmal ein (DELETE ... RETURNING) und liefert die Person samt aktueller Rolle. */
export async function redeemWsTicket(ctx: AuthContext, ticket: string): Promise<Principal | null> {
  const [t] = await ctx.db
    .delete(wsTickets)
    .where(and(eq(wsTickets.tokenHash, sha256Hex(ticket)), gt(wsTickets.expiresAt, ctx.now())))
    .returning();
  if (!t) return null;
  const [s] = await ctx.db
    .select({ session: sessions, role: memberships.role, status: memberships.status, disabledAt: users.disabledAt })
    .from(sessions)
    .innerJoin(memberships, and(eq(memberships.familyId, sessions.familyId), eq(memberships.userId, sessions.userId)))
    .innerJoin(users, eq(users.id, sessions.userId))
    .where(eq(sessions.id, t.sessionId));
  // eine zwischenzeitlich rotierte Sitzung (used_at) gilt für das Ticket weiter; widerrufen oder abgelaufen nicht
  if (!s || s.status !== 'active' || s.disabledAt || !isAlive(ctx, s.session, { allowUsed: true })) return null;
  return { userId: s.session.userId, familyId: s.session.familyId, role: s.role, deviceId: s.session.deviceId };
}
