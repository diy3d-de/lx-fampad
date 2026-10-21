// Registrierung per Einladung (neues Konto) bzw. Einrichtung neuer Anmeldedaten nach einem Zurücksetzen.
// Zweistufig, damit nie ein halb eingerichtetes Konto entsteht: Schritt 1 prüft Einladung/PIN und legt einen serverseitigen
// Zustand an (Challenge), Schritt 2 weist den Besitz nach (Passkey-Antwort bzw. TOTP-Code) und legt alles in EINER Transaktion an.
import type { RegistrationResponseJSON } from '@simplewebauthn/server';
import { randomUUID } from 'node:crypto';
import { and, eq, sql } from 'drizzle-orm';
import { credentials, invites, memberships, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import { peekChallenge, saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { randomToken } from './crypto.js';
import { consumeInvite, INVALID_INVITE, verifyInvite } from './invites.js';
import { assertNotLocked, ipKey, loginKeys, recordFailure, recordLoginFailure } from './lockout.js';
import { assertPasswordInputAllowed, AUTHKEY_ONLY, authKeyDigest, saveAuthKeyDigest } from './authkey.js';
import { assertPasswordPolicy, hashPassword } from './password.js';
import { createRecoveryCodes } from './recovery.js';
import { establishSession, type DeviceInput, type Established, type SessionKind } from './sessions.js';
import { checkTotp, newTotpSecret, totpUri } from './totp.js';
import type { Role } from './types.js';
import { checkRegistration, registrationOptions } from './webauthn.js';

export interface MemberView {
  id: string;
  email: string;
  displayName: string;
  colorIndex: number;
  role: Role;
  status: 'active' | 'pending';
}

export interface RegistrationResult {
  member: MemberView;
  /** pending: wartet auf die Freigabe durch einen Admin, keine Sitzung. */
  status: 'active' | 'pending';
  recoveryCodes: string[];
  session?: Established;
}

interface Identity {
  inviteId: string;
  userId: string;
  email: string;
  displayName: string;
  /** Zurücksetzen eines bestehenden Kontos statt Neuanlage. */
  reset: boolean;
}

export function isUniqueViolation(err: unknown): boolean {
  const e = err as { code?: string; cause?: { code?: string } } | null;
  return e?.code === '23505' || e?.cause?.code === '23505';
}

const registrationFailed = () => new AppError(409, 'registration_failed', 'Die Registrierung ist nicht möglich.');
const challengeInvalid = () => new AppError(400, 'challenge_invalid', 'Der Vorgang ist abgelaufen. Bitte neu beginnen.');

async function resolveIdentity(
  ctx: AuthContext,
  input: { token: string; pin?: string | undefined; email?: string | undefined; displayName?: string | undefined },
  meta: RequestMeta,
): Promise<Identity> {
  const invite = await verifyInvite(ctx, input.token, input.pin, meta);
  if (invite.userId) {
    const [u] = await ctx.db.select().from(users).where(eq(users.id, invite.userId));
    if (!u) throw INVALID_INVITE();
    return { inviteId: invite.id, userId: u.id, email: u.email, displayName: u.displayName, reset: true };
  }
  const email = input.email?.trim();
  const displayName = input.displayName?.trim();
  if (!email || !displayName) throw new AppError(400, 'invalid_request');
  const [taken] = await ctx.db.select({ id: users.id }).from(users).where(sql`lower(${users.email}) = lower(${email})`);
  if (taken) throw registrationFailed();
  return { inviteId: invite.id, userId: randomUUID(), email, displayName, reset: false };
}

// ---------- Passkey ----------

export async function startPasskeyRegistration(
  ctx: AuthContext,
  input: { token: string; pin?: string | undefined; email?: string | undefined; displayName?: string | undefined },
  meta: RequestMeta,
) {
  const id = await resolveIdentity(ctx, input, meta);
  const options = await registrationOptions(ctx, { userId: id.userId, accountName: id.email, displayName: id.displayName, existing: [] });
  const challengeId = await saveChallenge(ctx, { purpose: 'register_passkey', challenge: options.challenge, data: { ...id }, unauthenticatedFrom: meta });
  return { challengeId, options };
}

export async function finishPasskeyRegistration(
  ctx: AuthContext,
  input: { challengeId: string; response: RegistrationResponseJSON; client: SessionKind; device?: DeviceInput | undefined; label?: string | undefined },
  meta: RequestMeta,
): Promise<RegistrationResult> {
  const taken = await takeChallenge(ctx, input.challengeId, 'register_passkey');
  if (!taken) throw challengeInvalid();
  const id = taken.data as unknown as Identity;
  const verified = await checkRegistration(ctx, input.response, taken.challenge);
  if (!verified) {
    await recordFailure(ctx, ipKey(ctx, meta.ip), ctx.config.auth.lockoutIpThreshold);
    throw new AppError(400, 'registration_failed', 'Der Passkey konnte nicht überprüft werden.');
  }
  return completeRegistration(ctx, {
    identity: id,
    client: input.client,
    device: input.device,
    meta,
    authMethod: 'passkey',
    insertCredentials: async (tx) => {
      await tx.insert(credentials).values({
        userId: id.userId,
        type: 'passkey',
        label: input.label ?? null,
        externalId: verified.externalId,
        secret: verified.publicKey,
        signCount: verified.counter,
        transports: verified.transports,
        createdAt: ctx.now(),
      });
    },
  });
}

// ---------- Passwort + TOTP ----------

export async function startPasswordRegistration(
  ctx: AuthContext,
  input: { token: string; pin?: string | undefined; email?: string | undefined; displayName?: string | undefined; password?: string | undefined; authKey?: string | undefined },
  meta: RequestMeta,
) {
  assertPasswordInputAllowed(ctx, input);
  const id = await resolveIdentity(ctx, input, meta);
  // Mit authKey kennt der Server das Passwort nie: Stärke und Länge prüft dann allein die App; gespeichert wird nur der Prüfwert des authKey
  let passwordHash = AUTHKEY_ONLY;
  let authHash: string | undefined;
  if (input.authKey !== undefined) {
    authHash = authKeyDigest(ctx, id.userId, input.authKey);
  } else {
    assertPasswordPolicy(input.password ?? '', ctx.config.auth.minPasswordLength, id.email);
    passwordHash = await hashPassword(input.password ?? '');
  }
  const secret = newTotpSecret();
  const challengeId = await saveChallenge(ctx, {
    purpose: 'register_password',
    challenge: randomToken(16),
    unauthenticatedFrom: meta,
    data: { ...id, passwordHash, ...(authHash ? { authHash } : {}), totpSecretEnc: ctx.keys.encrypt('totp', secret, `totp:${id.userId}`) },
  });
  return { challengeId, totpSecret: secret, totpUri: totpUri(secret, id.email, ctx.config.auth.rpName) };
}

export async function finishPasswordRegistration(
  ctx: AuthContext,
  input: { challengeId: string; code: string; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<RegistrationResult> {
  const peek = await peekChallenge(ctx, input.challengeId, 'register_password');
  if (!peek) throw challengeInvalid();
  const data = peek.data as unknown as Identity & { passwordHash: string; authHash?: string; totpSecretEnc: string };
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, data.email));
  const secret = ctx.keys.decrypt('totp', data.totpSecretEnc, `totp:${data.userId}`);
  const step = await checkTotp(secret, input.code, ctx.now());
  if (step === null) {
    await recordLoginFailure(ctx, meta.ip, data.email);
    throw new AppError(400, 'invalid_code', 'Der Code stimmt nicht. Bitte erneut versuchen.');
  }
  // erst jetzt einlösen (atomar); parallele Doppel-Abschlüsse scheitern hier
  if (!(await takeChallenge(ctx, input.challengeId, 'register_password'))) throw challengeInvalid();
  return completeRegistration(ctx, {
    identity: data,
    client: input.client,
    device: input.device,
    meta,
    authMethod: 'password',
    insertCredentials: async (tx) => {
      const now = ctx.now();
      const inserted = await tx
        .insert(credentials)
        .values([
          { userId: data.userId, type: 'password', secret: data.passwordHash, createdAt: now },
          // der bei der Einrichtung benutzte Zeitschritt zählt als verbraucht (kein Wiederverwenden desselben Codes)
          { userId: data.userId, type: 'totp', secret: data.totpSecretEnc, lastTimeStep: step, createdAt: now },
        ])
        .returning({ id: credentials.id, type: credentials.type });
      const pw = inserted.find((c) => c.type === 'password');
      if (data.authHash && pw) await saveAuthKeyDigest(tx, { userId: data.userId, credentialId: pw.id, digest: data.authHash, now });
    },
  });
}

// ---------- gemeinsamer Abschluss ----------

async function nextColorIndex(exec: Executor, familyId: string): Promise<number> {
  const rows = await exec
    .select({ c: users.colorIndex })
    .from(users)
    .innerJoin(memberships, eq(memberships.userId, users.id))
    .where(eq(memberships.familyId, familyId));
  const used = new Set(rows.map((r) => r.c));
  for (let i = 0; i < 10; i++) if (!used.has(i)) return i;
  return rows.length % 10;
}

async function completeRegistration(
  ctx: AuthContext,
  input: {
    identity: Identity;
    client: SessionKind;
    device?: DeviceInput | undefined;
    meta: RequestMeta;
    authMethod: 'passkey' | 'password';
    insertCredentials: (tx: Executor) => Promise<void>;
  },
): Promise<RegistrationResult> {
  const { identity: id, meta } = input;
  let joinedFamily: string | undefined;
  try {
    const result = await ctx.db.transaction(async (tx) => {
      // Einladungszeile sperren: parallele Abschlüsse derselben Einladung warten hier, der zweite scheitert in consumeInvite
      const [inviteRow] = await tx.select().from(invites).where(eq(invites.id, id.inviteId)).for('update');
      if (!inviteRow) throw INVALID_INVITE();
      const familyId = inviteRow.familyId;
      joinedFamily = familyId;
      let role: Role = inviteRow.role;
      let status: 'active' | 'pending';
      let colorIndex: number;
      let email = id.email;
      let displayName = id.displayName;

      if (id.reset) {
        const [m] = await tx
          .select({ role: memberships.role, status: memberships.status, colorIndex: users.colorIndex, email: users.email, displayName: users.displayName })
          .from(memberships)
          .innerJoin(users, eq(users.id, memberships.userId))
          .where(and(eq(memberships.userId, id.userId), eq(memberships.familyId, familyId)));
        if (!m) throw INVALID_INVITE();
        role = m.role;
        status = m.status;
        colorIndex = m.colorIndex;
        email = m.email;
        displayName = m.displayName;
        await consumeInvite(ctx, tx, id.inviteId, id.userId);
      } else {
        colorIndex = await nextColorIndex(tx, familyId);
        status = inviteRow.requireApproval ? 'pending' : 'active';
        await tx.insert(users).values({ id: id.userId, email: id.email, displayName: id.displayName, colorIndex, createdAt: ctx.now() });
        await tx.insert(memberships).values({ familyId, userId: id.userId, role, status, createdAt: ctx.now() });
        await consumeInvite(ctx, tx, id.inviteId, id.userId);
      }

      await input.insertCredentials(tx);
      const recoveryCodes = await createRecoveryCodes(ctx, tx, id.userId);
      await writeAudit(ctx, tx, { event: 'invite_used', familyId, actorId: id.userId, ip: meta.ip, detail: { inviteId: id.inviteId, reset: id.reset } });
      await writeAudit(ctx, tx, {
        event: 'member_registered',
        familyId,
        actorId: id.userId,
        ip: meta.ip,
        detail: { role, status, method: input.authMethod, reset: id.reset },
      });

      const member: MemberView = { id: id.userId, email, displayName, colorIndex, role, status };
      if (status === 'pending') return { member, status, recoveryCodes };
      const session = await establishSession(ctx, tx, {
        userId: id.userId,
        familyId,
        client: input.client,
        device: input.device,
        authMethod: input.authMethod,
        meta,
      });
      return { member, status, recoveryCodes, session };
    });
    // neue Person (oder zurückgesetztes Konto): die Geräte der Familie laden die Mitgliederliste neu
    if (joinedFamily) ctx.onMembersChanged(joinedFamily);
    return result;
  } catch (err) {
    if (isUniqueViolation(err)) throw registrationFailed();
    throw err;
  }
}
