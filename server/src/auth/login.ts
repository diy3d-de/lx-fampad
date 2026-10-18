// Anmeldung (Passkey; Passwort + TOTP; Wiederherstellungs-Code) und erneute Bestätigung (Step-up).
// Jede fehlgeschlagene Anmeldung antwortet gleich (401 invalid_credentials) und zählt gegen IP, Konto und Paar (Konto+IP); unbekannte Konten
// laufen durch dieselben Schritte (Platzhalter-Hash), damit weder Antwort noch Zeit verraten, ob ein Konto existiert.
import type { AuthenticationResponseJSON } from '@simplewebauthn/server';
import { and, eq, isNull, sql } from 'drizzle-orm';
import { credentials, memberships, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import { saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, RequestMeta } from './context.js';
import { assertNotLocked, clearAccountFailures, ipKey, loginKeys, recordLoginFailure } from './lockout.js';
import { verifyPassword } from './password.js';
import { consumeRecoveryCode, countRemainingCodes } from './recovery.js';
import { establishSession, markStepUp, type AuthMethod, type DeviceInput, type Established, type SessionKind } from './sessions.js';
import { checkTotp } from './totp.js';
import type { Role, SessionPrincipal } from './types.js';
import { authenticationOptions, checkAuthentication, userHandleString } from './webauthn.js';

export interface Account {
  userId: string;
  email: string;
  displayName: string;
  colorIndex: number;
  familyId: string;
  role: Role;
  status: 'active' | 'pending';
  disabled: boolean;
}

const accountSelect = (ctx: AuthContext) =>
  ctx.db
    .select({
      userId: users.id,
      email: users.email,
      displayName: users.displayName,
      colorIndex: users.colorIndex,
      familyId: memberships.familyId,
      role: memberships.role,
      status: memberships.status,
      disabledAt: users.disabledAt,
    })
    .from(users)
    .innerJoin(memberships, eq(memberships.userId, users.id));

const toAccount = (r: { disabledAt: Date | null } & Omit<Account, 'disabled'>): Account => {
  const { disabledAt, ...rest } = r;
  return { ...rest, disabled: disabledAt !== null };
};

export async function findAccountByEmail(ctx: AuthContext, email: string): Promise<Account | null> {
  const [r] = await accountSelect(ctx).where(sql`lower(${users.email}) = lower(${email.trim()})`).limit(1);
  return r ? toAccount(r) : null;
}

/** Mit `familyId` gilt genau diese Mitgliedschaft (sonst irgendeine, der Server bedient heute genau eine Familie). */
export async function findAccountById(ctx: AuthContext, userId: string, familyId?: string): Promise<Account | null> {
  const [r] = await accountSelect(ctx)
    .where(and(eq(users.id, userId), familyId ? eq(memberships.familyId, familyId) : undefined))
    .limit(1);
  return r ? toAccount(r) : null;
}

const invalidCredentials = () => new AppError(401, 'invalid_credentials', 'Die Anmeldedaten sind nicht korrekt.');
const pending = () => new AppError(403, 'account_pending', 'Dein Konto wartet noch auf die Freigabe durch einen Admin.');

async function failLogin(ctx: AuthContext, meta: RequestMeta, method: string, email: string | undefined, account: Account | null): Promise<never> {
  await recordLoginFailure(ctx, meta.ip, email);
  await writeAudit(ctx, ctx.db, {
    event: 'login_failed',
    familyId: account?.familyId ?? null,
    actorId: account?.userId ?? null,
    ip: meta.ip,
    detail: { method },
  });
  throw invalidCredentials();
}

/** Nach erfolgreicher Prüfung: Konto muss aktiv sein (pending/gesperrt gehören nicht angemeldet). */
async function finishLogin(
  ctx: AuthContext,
  account: Account,
  input: { client: SessionKind; device?: DeviceInput | undefined; method: AuthMethod; meta: RequestMeta },
): Promise<Established> {
  if (account.disabled) throw invalidCredentials();
  if (account.status === 'pending') throw pending();
  // Passkeys sind nicht ratbar: sie setzen die Zähler der Passwort-Anmeldung nicht zurück
  if (input.method !== 'passkey') await clearAccountFailures(ctx, input.meta.ip, account.email);
  return ctx.db.transaction((tx) =>
    establishSession(ctx, tx, { userId: account.userId, familyId: account.familyId, client: input.client, device: input.device, authMethod: input.method, meta: input.meta }),
  );
}

/** Prüft einen TOTP-Code der Person; der Zeitschritt wird atomar verbraucht (Replay-Schutz auch bei parallelen Anfragen). */
export async function verifyUserTotp(ctx: AuthContext, userId: string, code: string): Promise<boolean> {
  const [c] = await ctx.db
    .select()
    .from(credentials)
    .where(and(eq(credentials.userId, userId), eq(credentials.type, 'totp'), isNull(credentials.revokedAt)));
  if (!c) return false;
  let secret: string;
  try {
    secret = ctx.keys.decrypt('totp', c.secret, `totp:${userId}`);
  } catch (err) {
    ctx.log.error({ err: (err as Error).message, userId }, 'TOTP-Geheimnis nicht entschlüsselbar (Schlüssel geändert?)');
    return false;
  }
  const step = await checkTotp(secret, code, ctx.now(), c.lastTimeStep);
  if (step === null) return false;
  const claimed = await ctx.db
    .update(credentials)
    .set({ lastTimeStep: step, lastUsedAt: ctx.now() })
    .where(and(eq(credentials.id, c.id), sql`(${credentials.lastTimeStep} is null or ${credentials.lastTimeStep} < ${step})`))
    .returning({ id: credentials.id });
  return claimed.length > 0;
}

// ---------- Passwort + TOTP ----------

export async function loginWithPassword(
  ctx: AuthContext,
  input: { email: string; password: string; totp?: string | undefined; recoveryCode?: string | undefined; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<Established> {
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, input.email));
  const account = await findAccountByEmail(ctx, input.email);
  let hash: string | null = null;
  if (account) {
    const [c] = await ctx.db
      .select({ secret: credentials.secret })
      .from(credentials)
      .where(and(eq(credentials.userId, account.userId), eq(credentials.type, 'password'), isNull(credentials.revokedAt)));
    hash = c?.secret ?? null;
  }
  const passwordOk = await verifyPassword(hash, input.password);
  let secondOk = false;
  if (passwordOk && account) {
    if (input.totp) secondOk = await verifyUserTotp(ctx, account.userId, input.totp);
    else if (input.recoveryCode) {
      secondOk = await consumeRecoveryCode(ctx, account.userId, input.recoveryCode);
      if (secondOk) await writeAudit(ctx, ctx.db, { event: 'recovery_code_used', familyId: account.familyId, actorId: account.userId, ip: meta.ip, detail: { with: 'password' } });
    }
  }
  if (!account || !passwordOk || !secondOk) return failLogin(ctx, meta, 'password', input.email, account);
  return finishLogin(ctx, account, { client: input.client, device: input.device, method: 'password', meta });
}

// ---------- Wiederherstellungs-Code (verlorener Passkey/TOTP) ----------

export async function loginWithRecoveryCode(
  ctx: AuthContext,
  input: { email: string; code: string; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<{ session: Established; remainingCodes: number }> {
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, input.email));
  const account = await findAccountByEmail(ctx, input.email);
  const ok = account ? await consumeRecoveryCode(ctx, account.userId, input.code) : false;
  if (!account || !ok) return failLogin(ctx, meta, 'recovery', input.email, account);
  await writeAudit(ctx, ctx.db, { event: 'recovery_code_used', familyId: account.familyId, actorId: account.userId, ip: meta.ip, detail: { with: 'recovery' } });
  const session = await finishLogin(ctx, account, { client: input.client, device: input.device, method: 'recovery', meta });
  return { session, remainingCodes: await countRemainingCodes(ctx, account.userId) };
}

// ---------- Passkey ----------

export async function startPasskeyLogin(ctx: AuthContext, meta: RequestMeta) {
  await assertNotLocked(ctx, [ipKey(ctx, meta.ip)]);
  const options = await authenticationOptions(ctx);
  const challengeId = await saveChallenge(ctx, { purpose: 'login', challenge: options.challenge, unauthenticatedFrom: meta });
  return { challengeId, options };
}

interface PasskeyRow {
  id: string;
  userId: string;
  externalId: string;
  publicKey: string;
  signCount: number;
  transports: string[] | null;
}

async function loadPasskey(ctx: AuthContext, externalId: string, userId?: string): Promise<PasskeyRow | null> {
  const [c] = await ctx.db
    .select()
    .from(credentials)
    .where(
      and(
        eq(credentials.externalId, externalId),
        eq(credentials.type, 'passkey'),
        isNull(credentials.revokedAt),
        userId ? eq(credentials.userId, userId) : undefined,
      ),
    );
  return c ? { id: c.id, userId: c.userId, externalId, publicKey: c.secret, signCount: c.signCount, transports: c.transports } : null;
}

/** Prüft die Passkey-Antwort samt signCount; true = gültig. Bei Zählerrückgang (geklonter Schlüssel) Audit-Eintrag. */
async function verifyPasskeyAssertion(
  ctx: AuthContext,
  passkey: PasskeyRow,
  response: AuthenticationResponseJSON,
  challenge: string,
  meta: RequestMeta,
): Promise<boolean> {
  const handle = response.response.userHandle;
  if (handle && handle !== userHandleString(passkey.userId)) return false;
  const check = await checkAuthentication(ctx, response, challenge, passkey);
  if (!check.ok) {
    if (check.counterRegression) {
      const account = await findAccountById(ctx, passkey.userId);
      await writeAudit(ctx, ctx.db, {
        event: 'passkey_counter_regression',
        familyId: account?.familyId ?? null,
        actorId: passkey.userId,
        ip: meta.ip,
        detail: { credentialId: passkey.id },
      });
    }
    return false;
  }
  // signCount atomar fortschreiben: ein gleichzeitig eingelöster Replay derselben Antwort scheitert hier
  const claimed = await ctx.db
    .update(credentials)
    .set({ signCount: check.newCounter, lastUsedAt: ctx.now() })
    .where(
      and(
        eq(credentials.id, passkey.id),
        sql`(${credentials.signCount} < ${check.newCounter} or (${credentials.signCount} = 0 and ${check.newCounter} = 0))`,
      ),
    )
    .returning({ id: credentials.id });
  return claimed.length > 0;
}

export async function finishPasskeyLogin(
  ctx: AuthContext,
  input: { challengeId: string; response: AuthenticationResponseJSON; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<Established> {
  await assertNotLocked(ctx, [ipKey(ctx, meta.ip)]);
  const taken = await takeChallenge(ctx, input.challengeId, 'login');
  const passkey = taken ? await loadPasskey(ctx, input.response.id) : null;
  const account = passkey ? await findAccountById(ctx, passkey.userId) : null;
  if (!taken || !passkey || !account) return failLogin(ctx, meta, 'passkey', undefined, account);
  // bewusst keine Konto-Sperre und kein Konto-Zähler: ein Passkey lässt sich nicht erraten, und wer fremde Passkey-Anmeldungen
  // fehlschlagen lässt, soll das Konto nicht sperren können (nur die IP-Sperre gilt)
  const ok = await verifyPasskeyAssertion(ctx, passkey, input.response, taken.challenge, meta);
  if (!ok) return failLogin(ctx, meta, 'passkey', undefined, account);
  return finishLogin(ctx, account, { client: input.client, device: input.device, method: 'passkey', meta });
}

// ---------- Step-up ----------

export async function startPasskeyStepUp(ctx: AuthContext, principal: SessionPrincipal) {
  const own = await ctx.db
    .select({ externalId: credentials.externalId, transports: credentials.transports })
    .from(credentials)
    .where(and(eq(credentials.userId, principal.userId), eq(credentials.type, 'passkey'), isNull(credentials.revokedAt)));
  if (own.length === 0) throw new AppError(409, 'no_passkey', 'Für dieses Konto ist kein Passkey eingerichtet.');
  const options = await authenticationOptions(
    ctx,
    own.map((c) => ({ externalId: c.externalId ?? '', transports: c.transports })),
  );
  const challengeId = await saveChallenge(ctx, { purpose: 'step_up', challenge: options.challenge, userId: principal.userId, data: { sessionId: principal.sessionId } });
  return { challengeId, options };
}

/** Schlüssel der Bestätigung: derselbe Konto-Schlüssel (E-Mail) wie bei der Anmeldung, damit beide EINEN Zähler teilen. */
async function stepUpIdentifier(ctx: AuthContext, principal: SessionPrincipal): Promise<string> {
  return (await findAccountById(ctx, principal.userId))?.email ?? principal.userId;
}

async function stepUpFailed(ctx: AuthContext, principal: SessionPrincipal, meta: RequestMeta, method: string): Promise<never> {
  await recordLoginFailure(ctx, meta.ip, await stepUpIdentifier(ctx, principal));
  await writeAudit(ctx, ctx.db, { event: 'step_up_failed', familyId: principal.familyId, actorId: principal.userId, ip: meta.ip, detail: { method } });
  throw new AppError(401, 'step_up_failed', 'Die Bestätigung ist fehlgeschlagen.');
}

export async function finishPasskeyStepUp(
  ctx: AuthContext,
  principal: SessionPrincipal,
  input: { challengeId: string; response: AuthenticationResponseJSON },
  meta: RequestMeta,
): Promise<Date> {
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, await stepUpIdentifier(ctx, principal)));
  const taken = await takeChallenge(ctx, input.challengeId, 'step_up');
  if (!taken || taken.userId !== principal.userId || taken.data.sessionId !== principal.sessionId) return stepUpFailed(ctx, principal, meta, 'passkey');
  const passkey = await loadPasskey(ctx, input.response.id, principal.userId);
  if (!passkey || !(await verifyPasskeyAssertion(ctx, passkey, input.response, taken.challenge, meta))) return stepUpFailed(ctx, principal, meta, 'passkey');
  const at = await markStepUp(ctx, principal.sessionId);
  await writeAudit(ctx, ctx.db, { event: 'step_up_ok', familyId: principal.familyId, actorId: principal.userId, ip: meta.ip, detail: { method: 'passkey' } });
  return at;
}

export async function stepUpWithCode(
  ctx: AuthContext,
  principal: SessionPrincipal,
  input: { totp?: string | undefined; recoveryCode?: string | undefined },
  meta: RequestMeta,
): Promise<Date> {
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, await stepUpIdentifier(ctx, principal)));
  let ok = false;
  let method = 'totp';
  if (input.totp) ok = await verifyUserTotp(ctx, principal.userId, input.totp);
  else if (input.recoveryCode) {
    method = 'recovery';
    ok = await consumeRecoveryCode(ctx, principal.userId, input.recoveryCode);
    if (ok) await writeAudit(ctx, ctx.db, { event: 'recovery_code_used', familyId: principal.familyId, actorId: principal.userId, ip: meta.ip, detail: { with: 'step_up' } });
  }
  if (!ok) return stepUpFailed(ctx, principal, meta, method);
  const at = await markStepUp(ctx, principal.sessionId);
  await writeAudit(ctx, ctx.db, { event: 'step_up_ok', familyId: principal.familyId, actorId: principal.userId, ip: meta.ip, detail: { method } });
  return at;
}
