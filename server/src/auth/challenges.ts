// Kurzlebige, einmal einlösbare Zustände (WebAuthn-Challenges, Registrierungsschritte), serverseitig in der Datenbank.
import { and, eq, gt, inArray, sql } from 'drizzle-orm';
import { webauthnChallenges } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { AuthContext } from './context.js';
import { ipKey } from './lockout.js';

export type ChallengePurpose = 'login' | 'register_passkey' | 'register_password' | 'add_passkey' | 'add_password' | 'step_up';

/** Vorgänge, die ohne Anmeldung eine Challenge erzeugen (Anmeldung, Registrierung per Einladung). */
const UNAUTHENTICATED: ChallengePurpose[] = ['login', 'register_passkey', 'register_password'];

/**
 * Begrenzt die Challenge-Erzeugung ohne Anmeldung, damit die Tabelle nicht ungebremst wächst: je IP (IPv6: /64) und insgesamt
 * höchstens so viele offene Challenges. Die Challenges laufen nach 5 Minuten ab und werden stündlich gelöscht.
 */
async function assertChallengeBudget(ctx: AuthContext, key: string): Promise<void> {
  const { challengeMaxPerIp, challengeMaxGlobal } = ctx.config.auth;
  const [r] = await ctx.db
    .select({
      total: sql<number>`count(*)::int`,
      mine: sql<number>`(count(*) filter (where ${webauthnChallenges.data}->>'ip' = ${key}))::int`,
    })
    .from(webauthnChallenges)
    .where(and(inArray(webauthnChallenges.purpose, UNAUTHENTICATED), gt(webauthnChallenges.expiresAt, ctx.now())));
  if ((r?.mine ?? 0) >= challengeMaxPerIp || (r?.total ?? 0) >= challengeMaxGlobal) {
    throw new AppError(429, 'rate_limited', 'Zu viele Anfragen. Bitte später erneut versuchen.', { 'retry-after': '60' });
  }
}

export async function saveChallenge(
  ctx: AuthContext,
  input: {
    purpose: ChallengePurpose;
    challenge: string;
    userId?: string | null;
    data?: Record<string, unknown>;
    /** Pflicht für Vorgänge ohne Anmeldung: IP der Anfrage (für die Begrenzung). */
    unauthenticatedFrom?: { ip: string | undefined };
  },
): Promise<string> {
  const now = ctx.now();
  let ip: string | undefined;
  if (input.unauthenticatedFrom) {
    ip = ipKey(ctx, input.unauthenticatedFrom.ip);
    await assertChallengeBudget(ctx, ip);
  }
  const [row] = await ctx.db
    .insert(webauthnChallenges)
    .values({
      purpose: input.purpose,
      challenge: input.challenge,
      userId: input.userId ?? null,
      data: { ...(input.data ?? {}), ...(ip ? { ip } : {}) },
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
