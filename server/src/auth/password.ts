// Passwörter: Argon2id. Gleichzeitige Berechnungen sind begrenzt (jede braucht 32 MiB; der Dienst läuft mit 512 MiB).
import argon2 from 'argon2';
import { AppError } from '../errors.js';

const OPTIONS = { type: argon2.argon2id, memoryCost: 32_768, timeCost: 3, parallelism: 1 } as const;
export const MAX_PASSWORD_LENGTH = 256;

/** Gleichzeitig laufende Berechnungen (Speicher: je 32 MiB). */
export const MAX_CONCURRENT = 2;
/** Wartende Berechnungen; darüber wird abgewiesen (503), statt den Speicher mit Warteschlange und Anfragen zu füllen. */
export const MAX_WAITING = 16;

let running = 0;
const waiting: Array<() => void> = [];

/** Nur für Tests: aktuelle Belegung. */
export const limiterState = () => ({ running, waiting: waiting.length });

const busy = () => new AppError(503, 'server_busy', 'Der Server ist gerade ausgelastet. Bitte gleich erneut versuchen.', { 'retry-after': '2' });

async function limited<T>(work: () => Promise<T>): Promise<T> {
  if (running < MAX_CONCURRENT) {
    running++;
  } else {
    if (waiting.length >= MAX_WAITING) throw busy();
    // Der Platz wird beim Freigeben direkt an den Wartenden übergeben (running bleibt gleich): nie mehr als MAX_CONCURRENT gleichzeitig.
    await new Promise<void>((resolve) => waiting.push(resolve));
  }
  try {
    return await work();
  } finally {
    const next = waiting.shift();
    if (next) next();
    else running--;
  }
}

export function hashPassword(password: string): Promise<string> {
  return limited(() => argon2.hash(password, OPTIONS));
}

let dummyHash: Promise<string> | undefined;

/**
 * Prüft ein Passwort. Ohne Hash (Konto unbekannt oder ohne Passwort) wird gegen einen Platzhalter gerechnet,
 * damit Antwortzeit und Ergebnis nicht verraten, ob ein Konto existiert. Ist der Server überlastet, wirft die Prüfung
 * 503 (kein Fehlversuch, kein "falsches Passwort").
 */
export async function verifyPassword(hash: string | null, password: string): Promise<boolean> {
  if (password.length > MAX_PASSWORD_LENGTH) return false;
  try {
    if (hash === null) {
      dummyHash ??= hashPassword('platzhalter-fuer-unbekannte-konten');
      let dummy: string;
      try {
        dummy = await dummyHash;
      } catch (err) {
        dummyHash = undefined; // ein abgewiesener Versuch (503) darf nicht für immer im Zwischenspeicher stehen
        throw err;
      }
      await limited(() => argon2.verify(dummy, password));
      return false;
    }
    return await limited(() => argon2.verify(hash, password));
  } catch (err) {
    if (err instanceof AppError) throw err;
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
