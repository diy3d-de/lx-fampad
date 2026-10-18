// Fehlversuche je Konto und je IP mit verzögerter Sperre. Die Schlüssel sind HMACs (keine Klartext-IP, keine Klartext-E-Mail
// in der Tabelle); die Zähler laufen ohne neuen Fehlversuch ab. Zählen und Sperren geschehen in der Datenbank (atomar).
import { eq, inArray, sql } from 'drizzle-orm';
import { loginAttempts } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { AuthContext } from './context.js';

export const ipKey = (ctx: AuthContext, ip: string | undefined) => `ip:${ctx.keys.hmac('lockout-ip', ip ?? 'unbekannt')}`;
export const accountKey = (ctx: AuthContext, identifier: string) =>
  `acct:${ctx.keys.hmac('lockout-account', identifier.trim().toLowerCase())}`;

const ts = (d: Date) => sql`${d.toISOString()}::timestamptz`;

/** Sekunden, die einer der Schlüssel noch gesperrt ist (0 = nicht gesperrt). */
export async function lockedForSeconds(ctx: AuthContext, keys: string[]): Promise<number> {
  const rows = await ctx.db.select({ lockedUntil: loginAttempts.lockedUntil }).from(loginAttempts).where(inArray(loginAttempts.key, keys));
  const now = ctx.now().getTime();
  let max = 0;
  for (const r of rows) if (r.lockedUntil) max = Math.max(max, Math.ceil((r.lockedUntil.getTime() - now) / 1000));
  return Math.max(0, max);
}

/** Wirft 429, wenn einer der Schlüssel gesperrt ist (immer dieselbe Antwort, egal ob das Konto existiert). */
export async function assertNotLocked(ctx: AuthContext, keys: string[]): Promise<void> {
  const wait = await lockedForSeconds(ctx, keys);
  if (wait > 0) {
    throw new AppError(429, 'too_many_attempts', 'Zu viele Fehlversuche. Bitte später erneut versuchen.', { 'retry-after': String(wait) });
  }
}

/** Zählt einen Fehlversuch; ab der Schwelle wächst die Sperre exponentiell (30 s, 60 s, ... bis zum Höchstwert). */
export async function recordFailure(ctx: AuthContext, key: string, threshold: number): Promise<void> {
  const { lockoutWindowSec: windowSec, lockoutMaxDelaySec: maxDelay } = ctx.config.auth;
  const now = ctx.now();
  const cut = new Date(now.getTime() - windowSec * 1000);
  const [row] = await ctx.db
    .insert(loginAttempts)
    .values({ key, failCount: 1, windowStartedAt: now, lastFailedAt: now })
    .onConflictDoUpdate({
      target: loginAttempts.key,
      set: {
        failCount: sql`case when ${loginAttempts.lastFailedAt} < ${ts(cut)} then 1 else ${loginAttempts.failCount} + 1 end`,
        windowStartedAt: sql`case when ${loginAttempts.lastFailedAt} < ${ts(cut)} then ${ts(now)} else ${loginAttempts.windowStartedAt} end`,
        lastFailedAt: now,
        lockedUntil: sql`case when ${loginAttempts.lastFailedAt} < ${ts(cut)} then null else ${loginAttempts.lockedUntil} end`,
      },
    })
    .returning({ failCount: loginAttempts.failCount });
  const count = row?.failCount ?? 1;
  if (count >= threshold) {
    const delay = Math.min(30 * 2 ** (count - threshold), maxDelay);
    await ctx.db
      .update(loginAttempts)
      .set({ lockedUntil: new Date(now.getTime() + delay * 1000) })
      .where(eq(loginAttempts.key, key));
  }
}

export async function clearFailures(ctx: AuthContext, key: string): Promise<void> {
  await ctx.db.delete(loginAttempts).where(eq(loginAttempts.key, key));
}

/** Fehlversuch für die IP und (optional) das Konto zählen. */
export async function recordLoginFailure(ctx: AuthContext, ip: string | undefined, identifier?: string): Promise<void> {
  await recordFailure(ctx, ipKey(ctx, ip), ctx.config.auth.lockoutIpThreshold);
  if (identifier) await recordFailure(ctx, accountKey(ctx, identifier), ctx.config.auth.lockoutAccountThreshold);
}
