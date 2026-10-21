// Anmeldung mit abgeleitetem `authKey` statt Klartext-Passwort (vereinfachte Schlüsselverwaltung, Schalter E2EE_PW_BACKUP).
// Der Client leitet aus dem Passwort per Argon2id (Salt: POST /auth/kdf-params) einen Master ab und daraus per BLAKE2b zwei unabhängige
// Teilschlüssel: `authKey` (geht an den Server) und `kek` (bleibt auf dem Gerät). Der Server sieht das Passwort so nie.
//
// Gespeichert wird nur ein HMAC-SHA256 des authKey (Schlüssel aus AUTH_SECRET_KEY, an die Person gebunden): eine gestohlene Datenbank allein
// erlaubt weder die Anmeldung (der authKey ist nicht daraus berechenbar) noch das Raten ohne den Hauptschlüssel; selbst mit ihm bleibt
// jeder Ratversuch ein Argon2id-Lauf (64 MiB) auf dem Rechner des Angreifers. Der authKey ist 32 zufällig wirkende Byte, daher reicht ein
// schneller Hash (kein Argon2id auf dem Server nötig, kein Speicher-Angriffspunkt).
//
// Zustand je Konto (nur abgeleitet, keine eigene Spalte):
//   legacy   Passwort-Eintrag ohne Zeile in password_authkeys: nur Klartext-Anmeldung (Altbestand, alte Apps)
//   authkey  Passwort-Eintrag mit Zeile: Anmeldung mit authKey; der alte Hash bleibt, solange der Schalter AUTH_LEGACY_PASSWORD_LOGIN an ist
//            (alte Apps), oder ist durch AUTHKEY_ONLY ersetzt, wenn das Passwort mit authKey gesetzt wurde
//   none     kein Passwort (nur Passkey)
// legacy -> authkey geschieht nur beim erfolgreichen Klartext-Login (Passwort UND zweiter Faktor geprüft, `upgradeAuthKey`) oder beim
// Setzen/Ändern des Passworts mit authKey; zurück zu legacy nur durch Entfernen und neues Einrichten per Klartext (alte App).
import { timingSafeEqual } from 'node:crypto';
import { and, eq, isNull } from 'drizzle-orm';
import { accountKdf, credentials, memberships, passwordAuthkeys } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { AuthContext, Executor } from './context.js';
import { DEFAULT_SALT_GENERATION } from './keys-pw.js';

/** Platzhalter in `credentials.secret`, wenn das Passwort nur als authKey gesetzt wurde: kein gültiger Argon2-Hash, nie anmeldbar per Klartext. */
export const AUTHKEY_ONLY = '!authkey';

/** Kennung des Ableitungsverfahrens, mit dem der authKey entstand (heute das einzige feste Profil). */
const KDF_ID = 'argon2id-v1';

export type PasswordMode = 'legacy' | 'authkey' | 'none';

/** 32 Byte als Base64url ohne Auffüllung (43 Zeichen), kanonisch: nur die eine Schreibweise je Wert. */
export const AUTHKEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export function isCanonicalAuthKey(value: string): boolean {
  return AUTHKEY_PATTERN.test(value) && Buffer.from(value, 'base64url').toString('base64url') === value;
}

const legacyDisabled = () =>
  new AppError(403, 'legacy_login_disabled', 'Diese App-Version meldet sich mit einem Verfahren an, das der Server nicht mehr zulässt. Bitte aktualisiere die App.');

/**
 * Prüft die Wahl der Passwort-Eingabe einer Anfrage (Klartext ODER authKey): genau eins von beidem; authKey nur mit dem Schalter
 * E2EE_PW_BACKUP (sonst gibt es das Verfahren nicht), Klartext nur solange AUTH_LEGACY_PASSWORD_LOGIN an ist. Vor jeder Konto-Abfrage,
 * damit die Antwort nie vom Konto abhängt.
 */
export function assertPasswordInputAllowed(ctx: Pick<AuthContext, 'config'>, input: { password?: string | undefined; authKey?: string | undefined }): void {
  if ((input.password === undefined) === (input.authKey === undefined)) throw new AppError(400, 'invalid_request');
  if (input.authKey !== undefined && !ctx.config.e2eePwBackup) throw new AppError(400, 'invalid_request');
  if (input.password !== undefined && !ctx.config.auth.legacyPasswordLogin) throw legacyDisabled();
}

/** HMAC des authKey (hex, 64 Zeichen), an die Person gebunden: ein Prüfwert lässt sich nicht auf ein anderes Konto übertragen. */
export function authKeyDigest(ctx: Pick<AuthContext, 'keys'>, userId: string, authKey: string): string {
  return ctx.keys.hmac('authkey-verifier-v1', `${userId}|${authKey}`);
}

const hexEqual = (a: string, b: string): boolean => {
  const x = Buffer.from(a, 'hex');
  const y = Buffer.from(b, 'hex');
  return x.length === y.length && timingSafeEqual(x, y);
};

const DUMMY_USER = '00000000-0000-4000-8000-000000000000';

/**
 * Prüft den authKey gegen den gespeicherten Prüfwert. Ohne Prüfwert (Konto unbekannt, deaktiviert, legacy, ohne Passwort) wird gegen einen
 * Platzhalter gerechnet: gleicher Aufwand, immer false. Läuft in konstanter Zeit.
 */
export function verifyAuthKey(ctx: Pick<AuthContext, 'keys'>, stored: string | null, userId: string, authKey: string): boolean {
  const calc = authKeyDigest(ctx, stored === null ? DUMMY_USER : userId, authKey);
  const ok = hexEqual(stored ?? authKeyDigest(ctx, DUMMY_USER, 'platzhalter-fuer-unbekannte-konten'), calc);
  return stored !== null && ok;
}

/**
 * Aktuelle Salt-Generation der Person. Bis es eine Salt-Rotation gibt, ist das immer 1 und stimmt mit der des Clients überein. Vor einer Rotation muss der Client die
 * Generation, mit der er abgeleitet hat, mitschicken und der Server sie prüfen (sonst würde ein Prüfwert zur falschen Generation gespeichert).
 */
async function currentGeneration(exec: Executor, userId: string): Promise<number> {
  const [g] = await exec.select({ g: accountKdf.saltGeneration }).from(accountKdf).where(eq(accountKdf.userId, userId));
  return g?.g ?? DEFAULT_SALT_GENERATION;
}

/** Legt den Prüfwert zum (aktiven) Passwort-Eintrag an oder ersetzt ihn (z. B. nach einer wiederholten Umstellung). Gehört in eine Transaktion. */
export async function saveAuthKeyDigest(exec: Executor, input: { userId: string; credentialId: string; digest: string; now: Date }): Promise<void> {
  const generation = await currentGeneration(exec, input.userId);
  await exec
    .insert(passwordAuthkeys)
    .values({ credentialId: input.credentialId, userId: input.userId, authHash: input.digest, kdfId: KDF_ID, saltGeneration: generation, createdAt: input.now, updatedAt: input.now })
    .onConflictDoUpdate({
      target: passwordAuthkeys.credentialId,
      set: { authHash: input.digest, kdfId: KDF_ID, saltGeneration: generation, updatedAt: input.now },
    });
}

/** Zustand der Passwort-Anmeldung je Konto der Familie (nur lesend, für die Admin-Übersicht). Kein Prüfwert verlässt diese Funktion. */
export async function passwordModes(ctx: AuthContext, familyId: string): Promise<Array<{ userId: string; mode: PasswordMode }>> {
  const rows = await ctx.db
    .select({ userId: memberships.userId, credentialId: credentials.id, authCredential: passwordAuthkeys.credentialId })
    .from(memberships)
    .leftJoin(credentials, and(eq(credentials.userId, memberships.userId), eq(credentials.type, 'password'), isNull(credentials.revokedAt)))
    .leftJoin(passwordAuthkeys, eq(passwordAuthkeys.credentialId, credentials.id))
    .where(eq(memberships.familyId, familyId));
  return rows.map((r) => ({ userId: r.userId, mode: r.credentialId === null ? 'none' : r.authCredential === null ? 'legacy' : 'authkey' }));
}

/** Zustand eines einzelnen Kontos. */
export async function passwordMode(exec: Executor, userId: string): Promise<PasswordMode> {
  const [r] = await exec
    .select({ credentialId: credentials.id, authCredential: passwordAuthkeys.credentialId })
    .from(credentials)
    .leftJoin(passwordAuthkeys, eq(passwordAuthkeys.credentialId, credentials.id))
    .where(and(eq(credentials.userId, userId), eq(credentials.type, 'password'), isNull(credentials.revokedAt)));
  return !r ? 'none' : r.authCredential === null ? 'legacy' : 'authkey';
}

