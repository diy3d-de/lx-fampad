// Anmeldung (Passkey; Passwort + TOTP; Wiederherstellungs-Code) und erneute Bestätigung (Step-up).
// Jede fehlgeschlagene Anmeldung antwortet gleich (401 invalid_credentials) und zählt gegen IP, Konto und Paar (Konto+IP); unbekannte Konten
// laufen durch dieselben Schritte (Platzhalter-Hash), damit weder Antwort noch Zeit verraten, ob ein Konto existiert.
import type { AuthenticationResponseJSON } from '@simplewebauthn/server';
import { and, eq, isNull, sql } from 'drizzle-orm';
import { credentials, memberships, passwordAuthkeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import { assertPasswordInputAllowed, AUTHKEY_ONLY, authKeyDigest, saveAuthKeyDigest, verifyAuthKey } from './authkey.js';
import { saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, Executor, RequestMeta, Tx } from './context.js';
import { assertNotLocked, clearAccountFailures, ipKey, loginKeys, recordLoginFailure } from './lockout.js';
import { verifyPassword } from './password.js';
import { consumeRecoveryCode, countRemainingCodes, isRecoveryCodeValid } from './recovery.js';
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

async function failLogin(ctx: AuthContext, meta: RequestMeta, method: string, email: string | undefined, account: Account | null, via?: string, code = 'invalid_credentials'): Promise<never> {
  await recordLoginFailure(ctx, meta.ip, email);
  await writeAudit(ctx, ctx.db, {
    event: 'login_failed',
    familyId: account?.familyId ?? null,
    actorId: account?.userId ?? null,
    ip: meta.ip,
    detail: via ? { method, via } : { method },
  });
  throw code === 'invalid_credentials' ? invalidCredentials() : new AppError(401, code, 'Die Anmeldedaten sind nicht korrekt.');
}

/**
 * Nach erfolgreicher Prüfung: Konto muss aktiv sein (pending/gesperrt gehören nicht angemeldet).
 * [verbrauchen] (zweiter Faktor: TOTP-Zeitschritt, Wiederherstellungscode) läuft in DERSELBEN Transaktion wie die Sitzungserstellung
 * und erst NACH der Statusprüfung: bei pending/gesperrt wird nichts verbraucht. Gibt null zurück, wenn der Faktor nicht (mehr) einlösbar war.
 */
async function finishLogin(
  ctx: AuthContext,
  account: Account,
  input: { client: SessionKind; device?: DeviceInput | undefined; method: AuthMethod; meta: RequestMeta; verbrauchen?: ((tx: Tx) => Promise<boolean>) | undefined },
): Promise<Established | null> {
  if (account.disabled) throw invalidCredentials();
  if (account.status === 'pending') throw pending();
  const established = await ctx.db.transaction(async (tx) => {
    if (input.verbrauchen && !(await input.verbrauchen(tx))) return null;
    return establishSession(ctx, tx, { userId: account.userId, familyId: account.familyId, client: input.client, device: input.device, authMethod: input.method, meta: input.meta });
  });
  // Passkeys sind nicht ratbar: sie setzen die Zähler der Passwort-Anmeldung nicht zurück
  if (established && input.method !== 'passkey') await clearAccountFailures(ctx, input.meta.ip, account.email);
  return established;
}

interface TotpHit {
  credentialId: string;
  step: number;
}

/** Prüft einen TOTP-Code der Person, OHNE den Zeitschritt zu verbrauchen. */
export async function checkUserTotp(ctx: AuthContext, userId: string, code: string): Promise<TotpHit | null> {
  const [c] = await ctx.db
    .select()
    .from(credentials)
    .where(and(eq(credentials.userId, userId), eq(credentials.type, 'totp'), isNull(credentials.revokedAt)));
  if (!c) return null;
  let secret: string;
  try {
    secret = ctx.keys.decrypt('totp', c.secret, `totp:${userId}`);
  } catch (err) {
    ctx.log.error({ err: (err as Error).message, userId }, 'TOTP-Geheimnis nicht entschlüsselbar (Schlüssel geändert?)');
    return null;
  }
  const step = await checkTotp(secret, code, ctx.now(), c.lastTimeStep);
  return step === null ? null : { credentialId: c.id, step };
}

/** Verbraucht den Zeitschritt atomar (Replay-Schutz auch bei parallelen Anfragen); false, wenn er schon vergeben ist. */
async function claimTotpStep(ctx: AuthContext, exec: Executor, hit: TotpHit): Promise<boolean> {
  const claimed = await exec
    .update(credentials)
    .set({ lastTimeStep: hit.step, lastUsedAt: ctx.now() })
    .where(and(eq(credentials.id, hit.credentialId), sql`(${credentials.lastTimeStep} is null or ${credentials.lastTimeStep} < ${hit.step})`))
    .returning({ id: credentials.id });
  return claimed.length > 0;
}

/** Prüft einen TOTP-Code der Person; der Zeitschritt wird atomar verbraucht (Replay-Schutz auch bei parallelen Anfragen). */
export async function verifyUserTotp(ctx: AuthContext, userId: string, code: string): Promise<boolean> {
  const hit = await checkUserTotp(ctx, userId, code);
  return hit !== null && (await claimTotpStep(ctx, ctx.db, hit));
}

// ---------- Passwort + TOTP ----------

/**
 * Anmeldung mit Passwort + zweitem Faktor. Das Passwort kommt entweder als Klartext (`password`, alte Apps; nur solange
 * AUTH_LEGACY_PASSWORD_LOGIN an ist) oder als abgeleiteter `authKey` (der Server sieht das Passwort nie). Beide Wege laufen durch dieselben
 * Schritte, Sperren und Fehlerantworten. Mit `upgradeAuthKey` (nur zusammen mit `password`) wird nach erfolgreicher Prüfung von Passwort UND
 * zweitem Faktor der authKey des Kontos angelegt bzw. ersetzt (legacy -> authkey), in derselben Transaktion wie die Sitzung.
 */
export async function loginWithPassword(
  ctx: AuthContext,
  input: {
    email: string;
    password?: string | undefined;
    authKey?: string | undefined;
    upgradeAuthKey?: string | undefined;
    totp?: string | undefined;
    recoveryCode?: string | undefined;
    client: SessionKind;
    device?: DeviceInput | undefined;
  },
  meta: RequestMeta,
): Promise<Established> {
  assertPasswordInputAllowed(ctx, input);
  if (input.upgradeAuthKey !== undefined && (input.password === undefined || !ctx.config.e2eePwBackup)) throw new AppError(400, 'invalid_request');
  const via = input.authKey !== undefined ? 'authkey' : 'plain';
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, input.email));
  const account = await findAccountByEmail(ctx, input.email);
  let hash: string | null = null;
  let authHash: string | null = null;
  let credentialId: string | null = null;
  if (account) {
    const [c] = await ctx.db
      .select({ id: credentials.id, secret: credentials.secret, authHash: passwordAuthkeys.authHash })
      .from(credentials)
      .leftJoin(passwordAuthkeys, eq(passwordAuthkeys.credentialId, credentials.id))
      .where(and(eq(credentials.userId, account.userId), eq(credentials.type, 'password'), isNull(credentials.revokedAt)));
    // AUTHKEY_ONLY ist kein Hash: wie "kein Passwort" behandeln (Platzhalter-Rechnung), damit die Zeit nichts verrät
    hash = c && c.secret !== AUTHKEY_ONLY ? c.secret : null;
    authHash = c?.authHash ?? null;
    credentialId = c?.id ?? null;
  }
  const passwordOk =
    input.authKey !== undefined
      ? verifyAuthKey(ctx, account && !account.disabled ? authHash : null, account?.userId ?? '', input.authKey)
      : await verifyPassword(hash, input.password ?? '');
  if (!account || !passwordOk) return failLogin(ctx, meta, 'password', input.email, account, via);
  // gesperrte Konten: wie ein falsches Passwort, ohne den zweiten Faktor anzufassen
  if (account.disabled) return failLogin(ctx, meta, 'password', input.email, account, via);
  // Zweiter Faktor: zuerst nur prüfen; verbraucht wird er erst in der Anmelde-Transaktion, nach der Statusprüfung
  let verbrauchen: ((tx: Tx) => Promise<boolean>) | undefined;
  if (input.totp) {
    const hit = await checkUserTotp(ctx, account.userId, input.totp);
    if (hit) verbrauchen = (tx) => claimTotpStep(ctx, tx, hit);
  } else if (input.recoveryCode) {
    const code = input.recoveryCode;
    if (await isRecoveryCodeValid(ctx, account.userId, code)) {
      verbrauchen = async (tx) => {
        if (!(await consumeRecoveryCode(ctx, account.userId, code, tx))) return false;
        await writeAudit(ctx, tx, { event: 'recovery_code_used', familyId: account.familyId, actorId: account.userId, ip: meta.ip, detail: { with: 'password' } });
        return true;
      };
    }
  }
  // Nur auf dem authKey-Weg, und nur mit KORREKTEM authKey (den kennt niemand ohne das Passwort): der Fehler liegt am zweiten Faktor. Die App wiederholt dann nicht
  // mit Klartext (kein doppelter Fehlversuch, kein Passwort im Netz bei einem Tippfehler im Code). Zählt wie jeder Fehlversuch genau einmal.
  const zweiterFaktor = via === 'authkey' ? 'invalid_second_factor' : 'invalid_credentials';
  if (!verbrauchen) return failLogin(ctx, meta, 'password', input.email, account, via, zweiterFaktor);
  const faktor = verbrauchen;
  const upgrade = input.upgradeAuthKey;
  if (upgrade !== undefined && credentialId !== null) {
    const cid = credentialId;
    verbrauchen = async (tx) => {
      if (!(await faktor(tx))) return false;
      // nur wenn das geprüfte Passwort noch das aktive ist (kein Überschreiben nach einem gleichzeitigen Passwortwechsel)
      const aktiv = await tx
        .select({ id: credentials.id })
        .from(credentials)
        .where(and(eq(credentials.id, cid), isNull(credentials.revokedAt)))
        .for('update');
      if (aktiv.length > 0) {
        await saveAuthKeyDigest(tx, { userId: account.userId, credentialId: cid, digest: authKeyDigest(ctx, account.userId, upgrade), now: ctx.now() });
        await writeAudit(ctx, tx, { event: 'password_authkey_set', familyId: account.familyId, actorId: account.userId, ip: meta.ip, detail: { how: 'login' } });
      }
      return true;
    };
  }
  // Erst nach erfolgreicher Prüfung von Passwort UND zweitem Faktor darf die Antwort den Status verraten (403 account_pending)
  const est = await finishLogin(ctx, account, { client: input.client, device: input.device, method: 'password', meta, verbrauchen });
  return est ?? failLogin(ctx, meta, 'password', input.email, account, via, zweiterFaktor);
}

// ---------- Wiederherstellungs-Code (verlorener Passkey/TOTP) ----------

export async function loginWithRecoveryCode(
  ctx: AuthContext,
  input: { email: string; code: string; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<{ session: Established; remainingCodes: number }> {
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, input.email));
  const account = await findAccountByEmail(ctx, input.email);
  // gesperrte Konten: wie ein falscher Code; pending: der Code wird geprüft, aber erst nach gültigem Code kommt 403 und nichts wird verbraucht
  const gueltig = account && !account.disabled ? await isRecoveryCodeValid(ctx, account.userId, input.code) : false;
  if (!account || !gueltig) return failLogin(ctx, meta, 'recovery', input.email, account);
  const verbrauchen = async (tx: Tx): Promise<boolean> => {
    if (!(await consumeRecoveryCode(ctx, account.userId, input.code, tx))) return false;
    await writeAudit(ctx, tx, { event: 'recovery_code_used', familyId: account.familyId, actorId: account.userId, ip: meta.ip, detail: { with: 'recovery' } });
    return true;
  };
  const session = await finishLogin(ctx, account, { client: input.client, device: input.device, method: 'recovery', meta, verbrauchen });
  if (!session) return failLogin(ctx, meta, 'recovery', input.email, account);
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
  const est = await finishLogin(ctx, account, { client: input.client, device: input.device, method: 'passkey', meta });
  if (!est) return failLogin(ctx, meta, 'passkey', undefined, account);
  return est;
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
