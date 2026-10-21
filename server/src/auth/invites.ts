// Einladungen: Einmal-Token (256 Bit, nur SHA-256 gespeichert), Gültigkeit 24 h (bis 7 Tage), feste Rolle, optionale PIN
// (HMAC, 5 Fehlversuche, dann gesperrt) und optionale Freigabe durch einen Admin. Das Token steht im URL-Fragment des Links.
import { randomUUID } from 'node:crypto';
import { and, desc, eq, isNull, sql } from 'drizzle-orm';
import { families, invites, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { randomPin, randomToken, safeEqual, sha256Hex } from './crypto.js';
import { recordFailure, ipKey } from './lockout.js';
import type { Role } from './types.js';

type InviteRow = typeof invites.$inferSelect;

export const INVALID_INVITE = () => new AppError(400, 'invite_invalid', 'Die Einladung ist ungültig, abgelaufen oder gesperrt.');

/** Admins laden jede Rolle ein, Eltern nur Kinder; Kinder gar nicht. */
export function assertMayInvite(actorRole: Role, target: Role): void {
  const allowed = actorRole === 'admin' || (actorRole === 'parent' && target === 'child');
  if (!allowed) throw new AppError(403, 'forbidden', 'Diese Einladung darfst du nicht erstellen.');
}

const ROLE_RANK: Record<Role, number> = { admin: 3, parent: 2, child: 1 };

/** Ist `to` eine niedrigere Rolle als `from`? */
export const isDowngrade = (from: Role, to: Role): boolean => ROLE_RANK[to] < ROLE_RANK[from];

export function inviteLink(ctx: AuthContext, token: string): string {
  // Fragment (#/einladung/<token>): wird vom Browser nie an Server oder Proxy gesendet und landet in keinem Log
  return `${new URL(ctx.config.publicUrl).origin}/#/einladung/${token}`;
}

export const pinHash = (ctx: AuthContext, inviteId: string, pin: string) => ctx.keys.hmac('invite-pin', `${inviteId}:${pin}`);

export interface CreateInviteInput {
  familyId: string;
  role: Role;
  hours: number;
  withPin: boolean;
  requireApproval?: boolean | undefined;
  /** Zurücksetzen: Einladung für ein bestehendes Konto. */
  userId?: string | undefined;
  createdBy: string | null;
}

export interface CreatedInvite {
  id: string;
  token: string;
  link: string;
  pin?: string;
  expiresAt: Date;
  requireApproval: boolean;
}

export async function createInvite(ctx: AuthContext, exec: Executor, input: CreateInviteInput, meta: RequestMeta): Promise<CreatedInvite> {
  const { inviteMaxHours } = ctx.config.auth;
  if (!Number.isFinite(input.hours) || input.hours < 1 || input.hours > inviteMaxHours) {
    throw new AppError(400, 'invalid_request', `Die Gültigkeit darf höchstens ${inviteMaxHours} Stunden betragen.`);
  }
  const now = ctx.now();
  const token = randomToken(32);
  const pin = input.withPin ? randomPin() : undefined;
  const requireApproval = input.requireApproval ?? false;
  const expiresAt = new Date(now.getTime() + input.hours * 3_600_000);
  // ID vorab, damit der PIN-Hash im selben INSERT steht (kein Zwischenzustand ohne PIN, auch ohne umgebende Transaktion)
  const id = randomUUID();
  const [row] = await exec
    .insert(invites)
    .values({
      id,
      ...(pin ? { pinHash: pinHash(ctx, id, pin) } : {}),
      familyId: input.familyId,
      role: input.role,
      tokenHash: sha256Hex(token),
      createdBy: input.createdBy,
      createdAt: now,
      expiresAt,
      userId: input.userId ?? null,
      requireApproval,
    })
    .returning({ id: invites.id });
  if (!row) throw new Error('Einladung nicht angelegt');
  await writeAudit(ctx, exec, {
    event: 'invite_created',
    familyId: input.familyId,
    actorId: input.createdBy,
    ip: meta.ip,
    detail: { inviteId: row.id, role: input.role, hours: input.hours, pin: !!pin, requireApproval, reset: !!input.userId },
  });
  return { id: row.id, token, link: inviteLink(ctx, token), ...(pin ? { pin } : {}), expiresAt, requireApproval };
}

export type InviteStatus = 'open' | 'used' | 'revoked' | 'locked' | 'expired';

export function inviteStatus(ctx: AuthContext, row: InviteRow): InviteStatus {
  if (row.usedAt) return 'used';
  if (row.revokedAt) return 'revoked';
  if (row.lockedAt) return 'locked';
  if (row.expiresAt.getTime() <= ctx.now().getTime()) return 'expired';
  return 'open';
}

export interface InviteView {
  id: string;
  role: Role;
  status: InviteStatus;
  createdAt: Date;
  expiresAt: Date;
  hasPin: boolean;
  requireApproval: boolean;
  reset: boolean;
  createdBy: string | null;
  usedBy: string | null;
}

const view = (ctx: AuthContext, r: InviteRow): InviteView => ({
  id: r.id,
  role: r.role,
  status: inviteStatus(ctx, r),
  createdAt: r.createdAt,
  expiresAt: r.expiresAt,
  hasPin: r.pinHash !== null,
  requireApproval: r.requireApproval,
  reset: r.userId !== null,
  createdBy: r.createdBy,
  usedBy: r.usedBy,
});

/** Liste ohne Token und PIN. Eltern sehen nur ihre eigenen Einladungen. */
export async function listInvites(ctx: AuthContext, actor: { familyId: string; userId: string; role: Role }): Promise<InviteView[]> {
  const rows = await ctx.db
    .select()
    .from(invites)
    .where(and(eq(invites.familyId, actor.familyId), actor.role === 'admin' ? undefined : eq(invites.createdBy, actor.userId)))
    .orderBy(desc(invites.createdAt))
    .limit(200);
  return rows.map((r) => view(ctx, r));
}

async function ownInvite(ctx: AuthContext, actor: { familyId: string; userId: string; role: Role }, inviteId: string): Promise<InviteRow> {
  const [row] = await ctx.db
    .select()
    .from(invites)
    .where(and(eq(invites.id, inviteId), eq(invites.familyId, actor.familyId)));
  if (!row || (actor.role !== 'admin' && row.createdBy !== actor.userId)) throw new AppError(404, 'not_found');
  // wer die Rolle nicht (mehr) einladen darf (z. B. herabgestufter Admin), darf die Einladung auch nicht mehr verwalten
  assertMayInvite(actor.role, row.role);
  return row;
}

export async function revokeInvite(ctx: AuthContext, actor: { familyId: string; userId: string; role: Role }, inviteId: string, meta: RequestMeta): Promise<void> {
  const row = await ownInvite(ctx, actor, inviteId);
  const done = await ctx.db
    .update(invites)
    .set({ revokedAt: ctx.now() })
    .where(and(eq(invites.id, row.id), sql`${invites.usedAt} is null`, sql`${invites.revokedAt} is null`))
    .returning({ id: invites.id });
  if (done.length === 0) throw new AppError(409, 'invite_not_open', 'Die Einladung ist nicht mehr offen.');
  await writeAudit(ctx, ctx.db, { event: 'invite_revoked', familyId: actor.familyId, actorId: actor.userId, ip: meta.ip, detail: { inviteId: row.id } });
}

/**
 * Verlängert eine noch nicht benutzte Einladung auf "jetzt + hours" (höchstens 7 Tage), verkürzt sie aber nie
 * (gilt sie schon länger, bleibt es dabei). Gesperrte (PIN) bleiben gesperrt. Gibt die tatsächliche neue Ablaufzeit zurück.
 */
export async function extendInvite(
  ctx: AuthContext,
  actor: { familyId: string; userId: string; role: Role },
  inviteId: string,
  hours: number,
  meta: RequestMeta,
): Promise<Date> {
  if (hours < 1 || hours > ctx.config.auth.inviteMaxHours) throw new AppError(400, 'invalid_request');
  const row = await ownInvite(ctx, actor, inviteId);
  const wanted = new Date(ctx.now().getTime() + hours * 3_600_000);
  return ctx.db.transaction(async (tx) => {
    const [done] = await tx
      .update(invites)
      .set({
        expiresAt: sql`greatest(${invites.expiresAt}, ${wanted.toISOString()}::timestamptz)`,
        // nur wenn sie wirklich abgelaufen war, beginnt eine neue Ablaufprotokollierung
        expiredLoggedAt: sql`case when ${invites.expiresAt} < ${wanted.toISOString()}::timestamptz then null else ${invites.expiredLoggedAt} end`,
      })
      .where(and(eq(invites.id, row.id), sql`${invites.usedAt} is null`, sql`${invites.revokedAt} is null`, sql`${invites.lockedAt} is null`))
      .returning({ expiresAt: invites.expiresAt });
    if (!done) throw new AppError(409, 'invite_not_open', 'Die Einladung kann nicht verlängert werden.');
    await writeAudit(ctx, tx, { event: 'invite_extended', familyId: actor.familyId, actorId: actor.userId, ip: meta.ip, detail: { inviteId: row.id, hours } });
    return done.expiresAt;
  });
}

/** Widerruft alle offenen Einladungen, die eine Person erstellt hat (Herabstufung, Entfernung). Gibt die Anzahl zurück. */
export async function revokeOpenInvitesBy(
  ctx: AuthContext,
  exec: Executor,
  input: { familyId: string; creatorId: string; actorId: string | null; reason: string },
  meta: RequestMeta,
): Promise<number> {
  const rows = await exec
    .update(invites)
    .set({ revokedAt: ctx.now() })
    .where(and(eq(invites.familyId, input.familyId), eq(invites.createdBy, input.creatorId), isNull(invites.usedAt), isNull(invites.revokedAt)))
    .returning({ id: invites.id });
  for (const r of rows) {
    await writeAudit(ctx, exec, { event: 'invite_revoked', familyId: input.familyId, actorId: input.actorId, ip: meta.ip, detail: { inviteId: r.id, reason: input.reason } });
  }
  return rows.length;
}

/** Liefert die Einladung zum Token, wenn sie benutzbar ist (nicht benutzt, widerrufen, gesperrt oder abgelaufen). */
export async function findUsableInvite(ctx: AuthContext, exec: Executor, token: string): Promise<InviteRow | null> {
  if (token.length < 16 || token.length > 128) return null;
  const [row] = await exec.select().from(invites).where(eq(invites.tokenHash, sha256Hex(token)));
  if (!row || inviteStatus(ctx, row) !== 'open') return null;
  return row;
}

export interface InviteLookup {
  role: Role;
  pinRequired: boolean;
  requireApproval: boolean;
  familyName: string;
  reset: boolean;
  displayName?: string;
  /** Nur bei einer Reset-Einladung und mit Schalter E2EE_PW_BACKUP: die App braucht die E-Mail des Kontos für den Salt der Passwort-Ableitung (authKey). */
  email?: string;
  expiresAt: Date;
}

/** Zeigt der einladenden Person vor der Registrierung, wozu sie eingeladen wird. Gleiche Antwort für jeden ungültigen Fall. */
export async function lookupInvite(ctx: AuthContext, token: string, meta: RequestMeta): Promise<InviteLookup> {
  const row = await findUsableInvite(ctx, ctx.db, token);
  if (!row) {
    await recordFailure(ctx, ipKey(ctx, meta.ip), ctx.config.auth.lockoutIpThreshold);
    throw INVALID_INVITE();
  }
  const [fam] = await ctx.db.select({ name: families.name }).from(families).where(eq(families.id, row.familyId));
  let displayName: string | undefined;
  let email: string | undefined;
  if (row.userId) {
    const [u] = await ctx.db.select({ displayName: users.displayName, email: users.email }).from(users).where(eq(users.id, row.userId));
    displayName = u?.displayName;
    if (ctx.config.e2eePwBackup) email = u?.email;
  }
  return {
    role: row.role,
    pinRequired: row.pinHash !== null,
    requireApproval: row.requireApproval,
    familyName: fam?.name ?? '',
    reset: row.userId !== null,
    ...(displayName ? { displayName } : {}),
    ...(email ? { email } : {}),
    expiresAt: row.expiresAt,
  };
}

/**
 * Prüft die PIN. Der Versuch wird VOR dem Vergleich atomar gezählt (UPDATE ... RETURNING), damit parallele Anfragen
 * die Grenze nicht umgehen: höchstens maxInvitePinAttempts Vergleiche insgesamt; beim letzten Fehlversuch wird die
 * Einladung gesperrt. Gibt bei Erfolg die Einladung zurück, sonst wirft sie die generische Fehlermeldung.
 */
export async function verifyInvite(ctx: AuthContext, token: string, pin: string | undefined, meta: RequestMeta): Promise<InviteRow> {
  const invite = await findUsableInvite(ctx, ctx.db, token);
  if (!invite) {
    await recordFailure(ctx, ipKey(ctx, meta.ip), ctx.config.auth.lockoutIpThreshold);
    throw INVALID_INVITE();
  }
  if (invite.pinHash === null) return invite;
  if (!pin || !/^\d{6}$/.test(pin)) throw INVALID_INVITE();

  const max = ctx.config.auth.maxInvitePinAttempts;
  const [counted] = await ctx.db
    .update(invites)
    .set({ pinAttempts: sql`${invites.pinAttempts} + 1` })
    .where(and(eq(invites.id, invite.id), sql`${invites.lockedAt} is null`))
    .returning({ attempts: invites.pinAttempts });
  if (!counted || counted.attempts > max) throw INVALID_INVITE();

  if (safeEqual(pinHash(ctx, invite.id, pin), invite.pinHash)) {
    // richtig: der Versuch zählt nicht als Fehlversuch
    await ctx.db.update(invites).set({ pinAttempts: sql`greatest(${invites.pinAttempts} - 1, 0)` }).where(eq(invites.id, invite.id));
    return invite;
  }
  await writeAudit(ctx, ctx.db, { event: 'invite_pin_failed', familyId: invite.familyId, ip: meta.ip, detail: { inviteId: invite.id, attempt: counted.attempts } });
  await recordFailure(ctx, ipKey(ctx, meta.ip), ctx.config.auth.lockoutIpThreshold);
  if (counted.attempts >= max) {
    await ctx.db.update(invites).set({ lockedAt: ctx.now() }).where(and(eq(invites.id, invite.id), sql`${invites.lockedAt} is null`));
    await writeAudit(ctx, ctx.db, { event: 'invite_locked', familyId: invite.familyId, ip: meta.ip, detail: { inviteId: invite.id } });
  }
  throw INVALID_INVITE();
}

/** Verbraucht die Einladung atomar (in der Registrierungs-Transaktion); wirft, wenn sie inzwischen nicht mehr benutzbar ist. */
export async function consumeInvite(ctx: AuthContext, exec: Executor, inviteId: string, usedBy: string): Promise<void> {
  const done = await exec
    .update(invites)
    .set({ usedAt: ctx.now(), usedBy })
    .where(
      and(
        eq(invites.id, inviteId),
        sql`${invites.usedAt} is null`,
        sql`${invites.revokedAt} is null`,
        sql`${invites.lockedAt} is null`,
        sql`${invites.expiresAt} > ${ctx.now().toISOString()}::timestamptz`,
      ),
    )
    .returning({ id: invites.id });
  if (done.length === 0) throw INVALID_INVITE();
}
