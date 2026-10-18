// TOTP (RFC 6238) mit otplib. Replay-Schutz: Ein Zeitschritt, der schon akzeptiert wurde (oder ein älterer), gilt nicht noch einmal.
import { generateSecret, generateURI, verify } from 'otplib';

export function newTotpSecret(): string {
  return generateSecret();
}

export function totpUri(secret: string, accountName: string, issuer: string): string {
  return generateURI({ issuer, label: accountName, secret });
}

/**
 * Prüft einen Code (±1 Zeitschritt Toleranz für Uhrenabweichung). Gibt den akzeptierten Zeitschritt zurück
 * oder null. `afterTimeStep` ist der zuletzt akzeptierte Schritt der Person.
 */
export async function checkTotp(secret: string, code: string, now: Date, afterTimeStep?: number | null): Promise<number | null> {
  if (!/^\d{6}$/.test(code)) return null;
  try {
    const result = await verify({
      secret,
      token: code,
      epoch: Math.floor(now.getTime() / 1000),
      epochTolerance: 30,
      ...(afterTimeStep !== null && afterTimeStep !== undefined ? { afterTimeStep } : {}),
    });
    return result.valid && 'timeStep' in result ? result.timeStep : null;
  } catch {
    return null;
  }
}
