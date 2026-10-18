// Passwörter: Argon2id. Gleichzeitige Berechnungen sind begrenzt (jede braucht 32 MiB; der Dienst läuft mit 512 MiB).
import argon2 from 'argon2';
import { AppError } from '../errors.js';

const OPTIONS = { type: argon2.argon2id, memoryCost: 32_768, timeCost: 3, parallelism: 1 } as const;
export const MAX_PASSWORD_LENGTH = 256;

const MAX_CONCURRENT = 2;
let running = 0;
const waiting: Array<() => void> = [];

async function limited<T>(work: () => Promise<T>): Promise<T> {
  if (running >= MAX_CONCURRENT) await new Promise<void>((resolve) => waiting.push(resolve));
  running++;
  try {
    return await work();
  } finally {
    running--;
    waiting.shift()?.();
  }
}

export function hashPassword(password: string): Promise<string> {
  return limited(() => argon2.hash(password, OPTIONS));
}

let dummyHash: Promise<string> | undefined;

/**
 * Prüft ein Passwort. Ohne Hash (Konto unbekannt oder ohne Passwort) wird gegen einen Platzhalter gerechnet,
 * damit Antwortzeit und Ergebnis nicht verraten, ob ein Konto existiert.
 */
export async function verifyPassword(hash: string | null, password: string): Promise<boolean> {
  if (password.length > MAX_PASSWORD_LENGTH) return false;
  try {
    if (hash === null) {
      dummyHash ??= hashPassword('platzhalter-fuer-unbekannte-konten');
      await limited(async () => argon2.verify(await dummyHash!, password));
      return false;
    }
    return await limited(() => argon2.verify(hash, password));
  } catch {
    return false;
  }
}

/** Mindestlänge und Obergrenze; keine Zusammensetzungsregeln (Länge zählt mehr als Sonderzeichen). */
export function assertPasswordPolicy(password: string, minLength: number, email?: string): void {
  if (password.length < minLength || password.length > MAX_PASSWORD_LENGTH) {
    throw new AppError(400, 'weak_password', `Das Passwort muss mindestens ${minLength} Zeichen lang sein.`);
  }
  if (email && password.toLowerCase() === email.toLowerCase()) {
    throw new AppError(400, 'weak_password', 'Das Passwort darf nicht der E-Mail-Adresse entsprechen.');
  }
}
