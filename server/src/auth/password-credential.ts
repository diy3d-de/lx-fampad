// Passwort + TOTP nachträglich zu einem bestehenden Konto (z. B. Passkey-Konto) hinzufügen, ändern oder entfernen.
// Alles nur mit frischem Step-up. Hinzufügen ist zweistufig wie die Registrierung: Schritt 1 prüft die Passwortregeln und legt
// Hash und verschlüsseltes TOTP-Geheimnis als Challenge ab, Schritt 2 weist mit einem Code den Besitz nach und legt beides in
// EINER Transaktion an (nie ein Passwort ohne TOTP).
import { and, eq, inArray, isNull } from 'drizzle-orm';
import { credentials, keyBackupsPw, passwordAuthkeys, webauthnChallenges } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import { assertPasswordInputAllowed, AUTHKEY_ONLY, authKeyDigest, saveAuthKeyDigest } from './authkey.js';
import { peekChallenge, saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, Db, RequestMeta } from './context.js';
import { randomToken } from './crypto.js';
import { promotePwBackup } from './keys-pw.js';
import { findAccountById } from './login.js';
import { assertNotLocked, clearFailures, recordFailure } from './lockout.js';
import { assertPasswordPolicy, hashPassword } from './password.js';
import { isUniqueViolation } from './register.js';
import { consumeStepUp, requireStepUp, revokeAllForUser } from './sessions.js';
import { checkTotp, newTotpSecret, totpUri } from './totp.js';
import type { SessionPrincipal } from './types.js';

/** Eigener Sperrschlüssel für falsche Bestätigungscodes beim Einrichten (zählt nicht gegen die Anmeldung der Person). */
const setupKey = (ctx: AuthContext, userId: string) => `pwsetup:${ctx.keys.hmac('password-setup', userId)}`;

const notFound = () => new AppError(404, 'not_found');
const challengeInvalid = () => new AppError(400, 'challenge_invalid', 'Der Vorgang ist abgelaufen. Bitte neu beginnen.');
const passwordExists = () => new AppError(409, 'password_exists', 'Für dein Konto gibt es bereits ein Passwort.');
const noPassword = () => new AppError(409, 'no_password', 'Für dein Konto ist kein Passwort eingerichtet.');

/** Schritt 1: Passwort prüfen und hashen, TOTP-Geheimnis erzeugen. Gespeichert wird nur die Challenge. */
export async function startAddPassword(ctx: AuthContext, p: SessionPrincipal, input: { password?: string | undefined; authKey?: string | undefined }) {
  requireStepUp(ctx, p);
  assertPasswordInputAllowed(ctx, input);
  const account = await findAccountById(ctx, p.userId, p.familyId);
  if (!account) throw notFound();
  const [existing] = await ctx.db
    .select({ id: credentials.id })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), eq(credentials.type, 'password'), isNull(credentials.revokedAt)));
  if (existing) throw passwordExists();
  // Mit authKey kennt der Server das Passwort nie: Stärke und Länge prüft dann allein die App; gespeichert wird nur der Prüfwert des authKey
  let passwordHash = AUTHKEY_ONLY;
  let authHash: string | undefined;
  if (input.authKey !== undefined) {
    authHash = authKeyDigest(ctx, p.userId, input.authKey);
  } else {
    assertPasswordPolicy(input.password ?? '', ctx.config.auth.minPasswordLength, account.email);
    passwordHash = await hashPassword(input.password ?? '');
  }
  const secret = newTotpSecret();
  // je Person höchstens ein offener Einrichtungsvorgang (ein neuer Start ersetzt den alten)
  const challengeId = await ctx.db.transaction(async (tx) => {
    await tx.delete(webauthnChallenges).where(and(eq(webauthnChallenges.userId, p.userId), eq(webauthnChallenges.purpose, 'add_password')));
    return saveChallenge({ ...ctx, db: tx as unknown as Db }, {
      purpose: 'add_password',
      challenge: randomToken(16),
      userId: p.userId,
      data: { passwordHash, ...(authHash ? { authHash } : {}), totpSecretEnc: ctx.keys.encrypt('totp', secret, `totp:${p.userId}`) },
    });
  });
  return { challengeId, totpSecret: secret, totpUri: totpUri(secret, account.email, ctx.config.auth.rpName) };
}

/** Schritt 2: Code bestätigen; Passwort und TOTP werden gemeinsam angelegt. */
export async function finishAddPassword(ctx: AuthContext, p: SessionPrincipal, input: { challengeId: string; code: string }, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  const account = await findAccountById(ctx, p.userId, p.familyId);
  if (!account) throw notFound();
  await assertNotLocked(ctx, [setupKey(ctx, p.userId)]);
  const peek = await peekChallenge(ctx, input.challengeId, 'add_password');
  // fremde Challenges verhalten sich wie abgelaufene
  if (!peek || peek.userId !== p.userId) throw challengeInvalid();
  const data = peek.data as { passwordHash: string; authHash?: string; totpSecretEnc: string };
  const secret = ctx.keys.decrypt('totp', data.totpSecretEnc, `totp:${p.userId}`);
  const step = await checkTotp(secret, input.code, ctx.now());
  if (step === null) {
    await recordFailure(ctx, setupKey(ctx, p.userId), ctx.config.auth.lockoutPairThreshold);
    await writeAudit(ctx, ctx.db, { event: 'password_setup_failed', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
    throw new AppError(400, 'invalid_code', 'Der Code stimmt nicht. Bitte erneut versuchen.');
  }
  // erst jetzt einlösen (atomar); parallele Doppel-Abschlüsse scheitern hier
  if (!(await takeChallenge(ctx, input.challengeId, 'add_password'))) throw challengeInvalid();
  try {
    await ctx.db.transaction(async (tx) => {
      const now = ctx.now();
      const inserted = await tx
        .insert(credentials)
        .values([
          { userId: p.userId, type: 'password', secret: data.passwordHash, createdAt: now },
          // der bei der Einrichtung benutzte Zeitschritt zählt als verbraucht (kein Wiederverwenden desselben Codes)
          { userId: p.userId, type: 'totp', secret: data.totpSecretEnc, lastTimeStep: step, createdAt: now },
        ])
        .returning({ id: credentials.id, type: credentials.type });
      const pw = inserted.find((c) => c.type === 'password');
      if (data.authHash && pw) await saveAuthKeyDigest(tx, { userId: p.userId, credentialId: pw.id, digest: data.authHash, now });
      await writeAudit(ctx, tx, { event: 'password_added', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
      await revokeAllForUser(ctx, tx, p.userId, { exceptSessionId: p.sessionId });
      await consumeStepUp(tx, p.sessionId);
    });
    await clearFailures(ctx, setupKey(ctx, p.userId));
  } catch (err) {
    if (isUniqueViolation(err)) throw passwordExists();
    throw err;
  }
}

/**
 * Neues Passwort bei bestehendem Passwort (das TOTP-Geheimnis bleibt). Entweder als Klartext (alte Apps) oder als neuer `authKey`; mit
 * `pwBackupId` (nur mit authKey) wird die dazu passende, vorher abgelegte und von der App geprüfte Passwort-Sicherung in DERSELBEN
 * Transaktion die aktuelle: neues Passwort und Sicherung gelten gemeinsam oder gar nicht. Ohne `pwBackupId` bleibt eine vorhandene
 * Sicherung unberührt und gehört weiter zum alten Passwort.
 * Ein Konto im Zustand authkey oder mit Passwort-Sicherung ändert sein Passwort nicht mehr per Klartext (409 password_change_needs_update): eine
 * alte App kann weder die Sicherung nachziehen noch den authKey setzen, das Konto fiele sonst still zurück auf den Klartext-Zustand.
 */
export async function changePassword(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { password?: string | undefined; authKey?: string | undefined; pwBackupId?: string | undefined },
  meta: RequestMeta,
): Promise<void> {
  requireStepUp(ctx, p);
  assertPasswordInputAllowed(ctx, input);
  if (input.pwBackupId !== undefined && input.authKey === undefined) throw new AppError(400, 'invalid_request');
  const account = await findAccountById(ctx, p.userId, p.familyId);
  if (!account) throw notFound();
  let passwordHash = AUTHKEY_ONLY;
  if (input.authKey === undefined) {
    assertPasswordPolicy(input.password ?? '', ctx.config.auth.minPasswordLength, account.email);
    passwordHash = await hashPassword(input.password ?? '');
  }
  await ctx.db.transaction(async (tx) => {
    const own = await tx
      .select({ id: credentials.id, type: credentials.type })
      .from(credentials)
      .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)))
      .for('update');
    const old = own.find((c) => c.type === 'password');
    if (!old) throw noPassword();
    if (input.authKey === undefined) {
      const [hatAuthKey] = await tx.select({ id: passwordAuthkeys.credentialId }).from(passwordAuthkeys).where(eq(passwordAuthkeys.credentialId, old.id));
      // auch mit vorhandener Passwort-Sicherung: sie ließe sich mit einem Klartext-Wechsel nicht mitziehen und wäre danach mit dem neuen Passwort nicht zu öffnen
      const [hatSicherung] = await tx
        .select({ id: keyBackupsPw.id })
        .from(keyBackupsPw)
        .where(and(eq(keyBackupsPw.userId, p.userId), inArray(keyBackupsPw.state, ['active', 'stale'])));
      if (hatAuthKey || hatSicherung) throw new AppError(409, 'password_change_needs_update', 'Bitte aktualisiere die App, um dein Passwort zu ändern.');
    }
    const now = ctx.now();
    await tx.update(credentials).set({ revokedAt: now }).where(eq(credentials.id, old.id));
    const [neu] = await tx.insert(credentials).values({ userId: p.userId, type: 'password', secret: passwordHash, createdAt: now }).returning({ id: credentials.id });
    if (!neu) throw notFound();
    if (input.authKey !== undefined) {
      await saveAuthKeyDigest(tx, { userId: p.userId, credentialId: neu.id, digest: authKeyDigest(ctx, p.userId, input.authKey), now });
      if (input.pwBackupId !== undefined) await promotePwBackup(ctx, tx, p, input.pwBackupId, meta);
    }
    await writeAudit(ctx, tx, {
      event: 'password_changed',
      familyId: p.familyId,
      actorId: p.userId,
      ip: meta.ip,
      ...(input.authKey !== undefined ? { detail: { authKey: true, backup: input.pwBackupId !== undefined } } : {}),
    });
    await revokeAllForUser(ctx, tx, p.userId, { exceptSessionId: p.sessionId });
    await consumeStepUp(tx, p.sessionId);
  });
}

/** Passwort samt TOTP entfernen, aber nur wenn mindestens ein Passkey als Anmeldeart bleibt. */
export async function removePassword(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const own = await tx
      .select({ id: credentials.id, type: credentials.type })
      .from(credentials)
      .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)))
      .for('update');
    if (!own.some((c) => c.type === 'password')) throw noPassword();
    if (!own.some((c) => c.type === 'passkey')) {
      throw new AppError(409, 'last_credential', 'Ohne Passwort bliebe keine Anmeldeart übrig. Richte zuerst einen Passkey ein.');
    }
    const now = ctx.now();
    for (const c of own.filter((x) => x.type === 'password' || x.type === 'totp')) {
      await tx.update(credentials).set({ revokedAt: now }).where(eq(credentials.id, c.id));
    }
    await tx.delete(webauthnChallenges).where(and(eq(webauthnChallenges.userId, p.userId), eq(webauthnChallenges.purpose, 'add_password')));
    await writeAudit(ctx, tx, { event: 'password_removed', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
    await revokeAllForUser(ctx, tx, p.userId, { exceptSessionId: p.sessionId });
    await consumeStepUp(tx, p.sessionId);
  });
}
