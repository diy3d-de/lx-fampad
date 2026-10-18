// Kurzlebige, einmal einlösbare Zustände (WebAuthn-Challenges, Registrierungsschritte), serverseitig in der Datenbank.
import { and, eq, gt } from 'drizzle-orm';
import { webauthnChallenges } from '../db/schema.js';
import type { AuthContext } from './context.js';

export type ChallengePurpose = 'login' | 'register_passkey' | 'register_password' | 'add_passkey' | 'step_up';

export async function saveChallenge(
  ctx: AuthContext,
  input: { purpose: ChallengePurpose; challenge: string; userId?: string | null; data?: Record<string, unknown> },
): Promise<string> {
  const now = ctx.now();
  const [row] = await ctx.db
    .insert(webauthnChallenges)
    .values({
      purpose: input.purpose,
      challenge: input.challenge,
      userId: input.userId ?? null,
      data: input.data ?? {},
      createdAt: now,
      expiresAt: new Date(now.getTime() + ctx.config.auth.challengeTtlSec * 1000),
    })
    .returning({ id: webauthnChallenges.id });
  if (!row) throw new Error('Challenge nicht gespeichert');
  return row.id;
}

export interface TakenChallenge {
  challenge: string;
  userId: string | null;
  data: Record<string, unknown>;
}

/** Löst eine Challenge ein: atomar gelesen und gelöscht (zweiter Versuch und abgelaufene liefern null). */
export async function takeChallenge(ctx: AuthContext, id: string, purpose: ChallengePurpose): Promise<TakenChallenge | null> {
  const [row] = await ctx.db
    .delete(webauthnChallenges)
    .where(and(eq(webauthnChallenges.id, id), eq(webauthnChallenges.purpose, purpose), gt(webauthnChallenges.expiresAt, ctx.now())))
    .returning({ challenge: webauthnChallenges.challenge, userId: webauthnChallenges.userId, data: webauthnChallenges.data });
  return row ?? null;
}

/** Liest eine Challenge, ohne sie zu verbrauchen (mehrstufige Einrichtung mit Fehlversuchen, z. B. TOTP-Bestätigung). */
export async function peekChallenge(ctx: AuthContext, id: string, purpose: ChallengePurpose): Promise<TakenChallenge | null> {
  const [row] = await ctx.db
    .select({ challenge: webauthnChallenges.challenge, userId: webauthnChallenges.userId, data: webauthnChallenges.data })
    .from(webauthnChallenges)
    .where(and(eq(webauthnChallenges.id, id), eq(webauthnChallenges.purpose, purpose), gt(webauthnChallenges.expiresAt, ctx.now())));
  return row ?? null;
}
