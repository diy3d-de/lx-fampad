// Passwort-Reset (nur mit Schalter E2EE_PW_BACKUP): drei Wege, ein gemeinsamer Kern.
//   1. Admin "Passwort zurücksetzen": Einmal-Link (Einladung `kind = password_reset`, 24 h, optional PIN). Wer ihn einlöst, braucht zusätzlich
//      einen gültigen Code des vorhandenen zweiten Faktors (TOTP): ein gestohlener Admin-Zugang oder ein abgefangener Link reicht nie.
//   2. "Passwort vergessen?" mit einem der Wiederherstellungs-Codes.
//   3. "Passwort vergessen?" mit einem Passkey.
// Nie nur mit TOTP allein und nie per E-Mail-Link ohne zweiten Nachweis.
//
// Der Kern (`applyPasswordReset`) ersetzt NUR das Passwort (neuer authKey; TOTP, Passkeys, Wiederherstellungs-Codes bleiben), widerruft alle
// Sitzungen samt Refresh-Familien und Geräten der Person, markiert die Passwort-Sicherung des Personenschlüssels als `stale` (nie löschen:
// der Wiederherstellungsschlüssel und die QR-Übertragung gelten weiter) und schreibt ein Sicherheitsereignis. Der Server rührt keinen
// Personenschlüssel an und kann ihn nicht neu verpacken (er kennt weder Passwort noch kek).
import type { AuthenticationResponseJSON } from '@simplewebauthn/server';
import { and, eq, isNull, sql } from 'drizzle-orm';
import { credentials, invites, memberships, securityEvents, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import { AUTHKEY_ONLY, authKeyDigest, saveAuthKeyDigest } from './authkey.js';
import { peekChallenge, saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, RequestMeta, Tx } from './context.js';
import { randomToken } from './crypto.js';
import { consumeInvite, createInvite, INVALID_INVITE, verifyInvite, type CreatedInvite } from './invites.js';
import { invalidateGuardianEscrow } from './guardian-invalidate.js';
import { markPwBackupsStaleAfterReset } from './keys-pw.js';
import { authenticatePasskey, checkUserTotp, claimTotpStep, failLogin, findAccountByEmail, findAccountById, type Account } from './login.js';
import { assertNotLocked, clearAccountFailures, loginKeys, recordLoginFailure } from './lockout.js';
import { consumeRecoveryCode, countRemainingCodes, isRecoveryCodeValid } from './recovery.js';
import type { MemberView } from './register.js';
import { recordSecurityEvent, wakeAfterCommit, wakeTopics, type SecurityEventVia } from './security-events.js';
import { establishSession, requireStepUp, revokeAllForUser, type DeviceInput, type Established, type SessionKind } from './sessions.js';
import type { SessionPrincipal } from './types.js';

const notFound = () => new AppError(404, 'not_found');
const challengeInvalid = () => new AppError(400, 'challenge_invalid', 'Der Vorgang ist abgelaufen. Bitte neu beginnen.');
const noPassword = () => new AppError(409, 'no_password', 'Für dieses Konto ist kein Passwort eingerichtet.');
const invalidCode = () => new AppError(400, 'invalid_code', 'Der Code stimmt nicht. Bitte erneut versuchen.');

function assertEnabled(ctx: Pick<AuthContext, 'config'>): void {
  if (!ctx.config.e2eePwBackup) throw notFound();
}

// ---------- gemeinsamer Kern ----------

/**
 * Setzt das Passwort neu (eine Transaktion, `tx` vom Aufrufer): altes Passwort widerrufen, neues mit authKey anlegen, Sicherung `stale`,
 * offene Reset-Links der Person widerrufen, ALLE Sitzungen (Refresh-Familien, Geräte, WebSockets) beenden. Danach stellt der Aufrufer die
 * neue Sitzung aus. Wirft 409 no_password, wenn die Person kein Passwort hat (die Transaktion rollt dann ganz zurück).
 */
async function applyPasswordReset(
  ctx: AuthContext,
  tx: Tx,
  input: { familyId: string; userId: string; authHash: string; via: SecurityEventVia; actorId: string | null },
  meta: RequestMeta,
): Promise<{ backupStale: boolean }> {
  const own = await tx
    .select({ id: credentials.id, type: credentials.type })
    .from(credentials)
    .where(and(eq(credentials.userId, input.userId), isNull(credentials.revokedAt)))
    .for('update');
  const old = own.find((c) => c.type === 'password');
  if (!old) throw noPassword();
  const now = ctx.now();
  await tx.update(credentials).set({ revokedAt: now }).where(eq(credentials.id, old.id));
  const [neu] = await tx.insert(credentials).values({ userId: input.userId, type: 'password', secret: AUTHKEY_ONLY, createdAt: now }).returning({ id: credentials.id });
  if (!neu) throw notFound();
  await saveAuthKeyDigest(tx, { userId: input.userId, credentialId: neu.id, digest: input.authHash, now });
  const backupStale = await markPwBackupsStaleAfterReset(ctx, tx, input.userId);
  // Hinterlegung für die Eltern (Kinder) wird ungültig: wer das Passwort zurücksetzt, bekommt darüber nie den Schlüssel des Kindes
  await invalidateGuardianEscrow(tx, input.userId, now);
  // weitere offene Reset-Links der Person sind hinfällig
  await tx
    .update(invites)
    .set({ revokedAt: now })
    .where(and(eq(invites.userId, input.userId), eq(invites.kind, 'password_reset'), isNull(invites.usedAt), isNull(invites.revokedAt)));
  await revokeAllForUser(ctx, tx, input.userId);
  await recordSecurityEvent(ctx, tx, { familyId: input.familyId, userId: input.userId, kind: 'password_reset_done', via: input.via, actorId: input.actorId });
  await writeAudit(ctx, tx, {
    event: 'password_reset_done',
    familyId: input.familyId,
    actorId: input.userId,
    ip: meta.ip,
    detail: { via: input.via, backupStale },
  });
  return { backupStale };
}

// ---------- 1. Admin erzeugt den Link ----------

/**
 * Admin (frisches Step-up) erzeugt einen Einmal-Link "neues Passwort" für ein anderes Mitglied. Das Konto bleibt bis zum Einlösen unverändert
 * nutzbar (Sitzungen und altes Passwort gelten weiter; so läuft ein abgelaufener oder ungenutzter Link nie in eine Aussperrung); beim
 * Einlösen werden alle Sitzungen beendet. Die Person wird sofort benachrichtigt (Push ohne Inhalt, Ereignis im Profil).
 */
export async function createPasswordResetInvite(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { userId: string; hours: number; withPin: boolean },
  meta: RequestMeta,
): Promise<CreatedInvite> {
  assertEnabled(ctx);
  if (p.role !== 'admin') throw new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
  requireStepUp(ctx, p);
  // der eigene Zugang geht nicht über den Admin-Weg (sonst umgeht ein gestohlener Admin-Zugang seinen eigenen zweiten Faktor)
  if (input.userId === p.userId) {
    throw new AppError(409, 'cannot_reset_self', 'Dein eigenes Passwort änderst du im Profil, oder du nutzt auf der Anmeldeseite „Passwort vergessen?“.');
  }
  const target = await findAccountById(ctx, input.userId, p.familyId);
  if (!target) throw notFound();
  if (target.disabled || target.status !== 'active') throw new AppError(409, 'not_active', 'Dieses Mitglied ist nicht aktiv.');
  const topics = await wakeTopics(ctx.db, target.userId);
  const invite = await ctx.db.transaction(async (tx) => {
    const own = await tx
      .select({ type: credentials.type })
      .from(credentials)
      .where(and(eq(credentials.userId, target.userId), isNull(credentials.revokedAt)))
      .for('update');
    // ohne Passwort gibt es nichts zurückzusetzen; ohne TOTP wäre der zweite Faktor des Links leer (Passwort und TOTP entstehen nur gemeinsam)
    if (!own.some((c) => c.type === 'password')) throw noPassword();
    if (!own.some((c) => c.type === 'totp')) throw new AppError(409, 'no_second_factor', 'Für dieses Konto ist kein zweiter Faktor eingerichtet.');
    const now = ctx.now();
    // ein neuer Link ersetzt einen offenen früheren
    await tx
      .update(invites)
      .set({ revokedAt: now })
      .where(and(eq(invites.userId, target.userId), eq(invites.kind, 'password_reset'), isNull(invites.usedAt), isNull(invites.revokedAt)));
    const created = await createInvite(
      ctx,
      tx,
      { familyId: p.familyId, role: target.role, hours: input.hours, withPin: input.withPin, requireApproval: false, userId: target.userId, kind: 'password_reset', createdBy: p.userId },
      meta,
    );
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: target.userId, kind: 'password_reset_requested', via: 'admin', actorId: p.userId });
    await writeAudit(ctx, tx, { event: 'password_reset_requested', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: target.userId, inviteId: created.id } });
    return created;
  });
  wakeAfterCommit(ctx, p.familyId, target.userId, topics);
  return invite;
}

// ---------- 1b. Einlösen des Admin-Links ----------

/** Schritt 1: Link (und PIN) prüfen, neuen authKey vormerken. Gespeichert wird nur der Prüfwert. */
export async function startPasswordResetRedeem(
  ctx: AuthContext,
  input: { token: string; pin?: string | undefined; authKey: string },
  meta: RequestMeta,
): Promise<{ challengeId: string }> {
  assertEnabled(ctx);
  const invite = await verifyInvite(ctx, input.token, input.pin, meta);
  if (invite.kind !== 'password_reset' || !invite.userId) throw INVALID_INVITE();
  const account = await findAccountById(ctx, invite.userId, invite.familyId);
  if (!account || account.disabled || account.status !== 'active') throw INVALID_INVITE();
  const [pw] = await ctx.db
    .select({ id: credentials.id })
    .from(credentials)
    .where(and(eq(credentials.userId, account.userId), eq(credentials.type, 'password'), isNull(credentials.revokedAt)));
  if (!pw) throw INVALID_INVITE();
  const challengeId = await saveChallenge(ctx, {
    purpose: 'reset_password',
    challenge: randomToken(16), // nur Platzhalter (Pflichtfeld); die Einladung steht über ihre ID in den Daten, nie ein Teil des Tokens
    unauthenticatedFrom: meta,
    data: { inviteId: invite.id, userId: account.userId, familyId: invite.familyId, email: account.email, authHash: authKeyDigest(ctx, account.userId, input.authKey) },
  });
  return { challengeId };
}

export interface ResetResult {
  member: MemberView;
  status: 'active';
  recoveryCodes: string[];
  session: Established;
}

/**
 * Schritt 2: der zweite Faktor. Ein gültiger TOTP-Code des vorhandenen Authenticators (nur dieser, kein Wiederherstellungs-Code) bestätigt, dass die
 * Person selbst den Link einlöst. Falsche Codes zählen am Link: nach `maxInvitePinAttempts` (5) ist er gesperrt (wie bei der PIN). Einladung, Code-Verbrauch und das neue Passwort in EINER Transaktion; parallele Einlösungen scheitern.
 */
export async function finishPasswordResetRedeem(
  ctx: AuthContext,
  input: { challengeId: string; code: string; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<ResetResult> {
  assertEnabled(ctx);
  const peek = await peekChallenge(ctx, input.challengeId, 'reset_password');
  if (!peek) throw challengeInvalid();
  const data = peek.data as { inviteId: string; userId: string; familyId: string; email: string; authHash: string };
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, data.email));
  // ein gesperrter, benutzter oder widerrufener Link ist hier schon erledigt (gleiche Antwort wie jeder ungültige Link)
  const [linkZeile] = await ctx.db.select({ lockedAt: invites.lockedAt, usedAt: invites.usedAt, revokedAt: invites.revokedAt }).from(invites).where(eq(invites.id, data.inviteId));
  if (!linkZeile || linkZeile.lockedAt || linkZeile.usedAt || linkZeile.revokedAt) throw INVALID_INVITE();
  const hit = await checkUserTotp(ctx, data.userId, input.code);
  if (!hit) {
    // Zähler am Link (vor der Antwort, atomar): das Raten des TOTP-Codes mit dem Link ist auf wenige Versuche begrenzt; PIN und TOTP teilen sich den Zähler
    const max = ctx.config.auth.maxInvitePinAttempts;
    const [gezaehlt] = await ctx.db
      .update(invites)
      .set({ pinAttempts: sql`${invites.pinAttempts} + 1` })
      .where(and(eq(invites.id, data.inviteId), isNull(invites.lockedAt)))
      .returning({ n: invites.pinAttempts });
    if (gezaehlt && gezaehlt.n >= max) {
      await ctx.db.update(invites).set({ lockedAt: ctx.now() }).where(and(eq(invites.id, data.inviteId), isNull(invites.lockedAt)));
      await writeAudit(ctx, ctx.db, { event: 'invite_locked', familyId: data.familyId, ip: meta.ip, detail: { inviteId: data.inviteId, reason: 'totp' } });
    }
    await recordLoginFailure(ctx, meta.ip, data.email);
    await writeAudit(ctx, ctx.db, { event: 'login_failed', familyId: data.familyId, actorId: data.userId, ip: meta.ip, detail: { method: 'password_reset' } });
    throw invalidCode();
  }
  // erst jetzt einlösen (atomar); parallele Doppel-Abschlüsse scheitern hier
  if (!(await takeChallenge(ctx, input.challengeId, 'reset_password'))) throw challengeInvalid();
  const topics = await wakeTopics(ctx.db, data.userId);
  const result = await ctx.db.transaction(async (tx) => {
    // Einladungszeile sperren: parallele Einlösungen warten, die zweite scheitert in consumeInvite
    const [inv] = await tx.select({ id: invites.id }).from(invites).where(eq(invites.id, data.inviteId)).for('update');
    if (!inv) throw INVALID_INVITE();
    await consumeInvite(ctx, tx, data.inviteId, data.userId);
    const [m] = await tx
      .select({ role: memberships.role, status: memberships.status, colorIndex: users.colorIndex, email: users.email, displayName: users.displayName, disabledAt: users.disabledAt })
      .from(memberships)
      .innerJoin(users, eq(users.id, memberships.userId))
      .where(and(eq(memberships.userId, data.userId), eq(memberships.familyId, data.familyId)));
    if (!m || m.status !== 'active' || m.disabledAt) throw INVALID_INVITE();
    // Zeitschritt des TOTP verbrauchen (Replay-Schutz); schon vergeben = der Code war nicht mehr einlösbar
    if (!(await claimTotpStep(ctx, tx, hit))) throw invalidCode();
    await applyPasswordReset(ctx, tx, { familyId: data.familyId, userId: data.userId, authHash: data.authHash, via: 'admin', actorId: null }, meta);
    const session = await establishSession(ctx, tx, { userId: data.userId, familyId: data.familyId, client: input.client, device: input.device, authMethod: 'password', origin: 'password_reset', meta });
    const member: MemberView = { id: data.userId, email: m.email, displayName: m.displayName, colorIndex: m.colorIndex, role: m.role, status: 'active' };
    return { member, status: 'active' as const, recoveryCodes: [] as string[], session };
  });
  await clearAccountFailures(ctx, meta.ip, data.email);
  wakeAfterCommit(ctx, data.familyId, data.userId, topics);
  return result;
}

// ---------- 2./3. "Passwort vergessen?" ----------

export interface SelfResetResult {
  account: Account;
  session: Established;
  recoveryCodesRemaining: number;
}

async function finishSelfReset(
  ctx: AuthContext,
  account: Account,
  input: { authKey: string; via: 'recovery_code' | 'passkey'; client: SessionKind; device?: DeviceInput | undefined; verbrauchen?: ((tx: Tx) => Promise<boolean>) | undefined },
  meta: RequestMeta,
): Promise<SelfResetResult | null> {
  // gesperrte und wartende Konten: wie bei der Anmeldung (gesperrt = generischer Fehler, wartend erst nach gültigem Nachweis)
  if (account.disabled) throw new AppError(401, 'invalid_credentials', 'Die Anmeldedaten sind nicht korrekt.');
  if (account.status === 'pending') throw new AppError(403, 'account_pending', 'Dein Konto wartet noch auf die Freigabe durch einen Admin.');
  const topics = await wakeTopics(ctx.db, account.userId);
  const session = await ctx.db.transaction(async (tx) => {
    if (input.verbrauchen && !(await input.verbrauchen(tx))) return null;
    await applyPasswordReset(ctx, tx, { familyId: account.familyId, userId: account.userId, authHash: authKeyDigest(ctx, account.userId, input.authKey), via: input.via, actorId: null }, meta);
    return establishSession(ctx, tx, { userId: account.userId, familyId: account.familyId, client: input.client, device: input.device, authMethod: input.via === 'passkey' ? 'passkey' : 'recovery',
      // Passkey: die Person hat sich mit ihrem Passkey ausgewiesen (normale Anmeldung, keine Sperrfrist); Wiederherstellungscode: wie die Code-Anmeldung gesperrt
      ...(input.via === 'passkey' ? { origin: 'login' as const, ohneZugangsfrist: true } : { origin: 'password_reset' as const }),
      meta,
    });
  });
  if (!session) return null;
  if (input.via !== 'passkey') await clearAccountFailures(ctx, meta.ip, account.email);
  wakeAfterCommit(ctx, account.familyId, account.userId, topics);
  return { account, session, recoveryCodesRemaining: await countRemainingCodes(ctx, account.userId) };
}

/** "Passwort vergessen?" mit einem der Wiederherstellungs-Codes (verbraucht ihn). Gleiche Fehlerantwort und Sperren wie die Anmeldung. */
export async function resetPasswordWithRecoveryCode(
  ctx: AuthContext,
  input: { email: string; code: string; authKey: string; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<SelfResetResult> {
  assertEnabled(ctx);
  await assertNotLocked(ctx, loginKeys(ctx, meta.ip, input.email));
  const account = await findAccountByEmail(ctx, input.email);
  const gueltig = account && !account.disabled ? await isRecoveryCodeValid(ctx, account.userId, input.code) : false;
  if (!account || !gueltig) return failLogin(ctx, meta, 'recovery', input.email, account, 'password_reset');
  const verbrauchen = async (tx: Tx): Promise<boolean> => {
    if (!(await consumeRecoveryCode(ctx, account.userId, input.code, tx))) return false;
    await writeAudit(ctx, tx, { event: 'recovery_code_used', familyId: account.familyId, actorId: account.userId, ip: meta.ip, detail: { with: 'password_reset' } });
    return true;
  };
  const r = await finishSelfReset(ctx, account, { authKey: input.authKey, via: 'recovery_code', client: input.client, device: input.device, verbrauchen }, meta);
  return r ?? failLogin(ctx, meta, 'recovery', input.email, account, 'password_reset');
}

/** "Passwort vergessen?" mit einem Passkey (Challenge von /auth/login/passkey/options). */
export async function resetPasswordWithPasskey(
  ctx: AuthContext,
  input: { email: string; challengeId: string; response: AuthenticationResponseJSON; authKey: string; client: SessionKind; device?: DeviceInput | undefined },
  meta: RequestMeta,
): Promise<SelfResetResult> {
  assertEnabled(ctx);
  const account = await authenticatePasskey(ctx, input, meta);
  // Der Salt der Passwort-Ableitung hängt an der E-Mail des Kontos: eine andere Eingabe ergäbe ein Passwort, mit dem man sich nie anmelden könnte
  if (account.email.trim().toLowerCase() !== input.email.trim().toLowerCase()) {
    throw new AppError(409, 'email_mismatch', 'Die E-Mail-Adresse gehört nicht zu diesem Passkey.');
  }
  const r = await finishSelfReset(ctx, account, { authKey: input.authKey, via: 'passkey', client: input.client, device: input.device }, meta);
  return r ?? failLogin(ctx, meta, 'passkey', undefined, account, 'password_reset');
}

// ---------- Aufräumen ----------

/** Sicherheitsereignisse älter als ein Jahr löschen (der Aufräum-Job ruft das auf). */
export async function purgeSecurityEvents(ctx: AuthContext): Promise<number> {
  const cutoff = new Date(ctx.now().getTime() - 365 * 86_400_000);
  const rows = await ctx.db.delete(securityEvents).where(sql`${securityEvents.createdAt} < ${cutoff.toISOString()}::timestamptz`).returning({ id: securityEvents.id });
  return rows.length;
}
