// Fehlversuche mit verzögerter Sperre, gezählt je IP (IPv6: /64), je Konto UND je Paar (Konto + IP). Die Schlüssel sind HMACs
// (keine Klartext-IP, keine Klartext-E-Mail in der Tabelle); die Zähler laufen ohne neuen Fehlversuch ab. Zählen und Sperren
// geschehen in der Datenbank (atomar).
//
// Warum drei Zähler: Der Konto-Zähler allein ließe fremde Konten sperren (jeder kann fünfmal falsch tippen). Deshalb sperrt der
// Paar-Zähler früh (nur die tippende IP verliert den Zugang), der Konto-Zähler erst später und höchstens kurz (Höchstdauer
// lockoutMaxDelaySec); er bremst nur verteilte Angriffe. Passkeys sind nicht ratbar und hängen nicht an der Konto-Sperre.
import { eq, inArray, sql } from 'drizzle-orm';
import { loginAttempts } from '../db/schema.js';
import { AppError } from '../errors.js';
import { normalizeIp } from '../net.js';
import type { AuthContext } from './context.js';

export const ipKey = (ctx: AuthContext, ip: string | undefined) => `ip:${ctx.keys.hmac('lockout-ip', normalizeIp(ip))}`;
export const accountKey = (ctx: AuthContext, identifier: string) =>
  `acct:${ctx.keys.hmac('lockout-account', identifier.trim().toLowerCase())}`;
/** Paar aus Konto (E-Mail) und IP (IPv6: /64). */
export const accountIpKey = (ctx: AuthContext, identifier: string, ip: string | undefined) =>
  `acip:${ctx.keys.hmac('lockout-account-ip', `${identifier.trim().toLowerCase()}|${normalizeIp(ip)}`)}`;

/** Alle Schlüssel einer Anmeldung bzw. Bestätigung: IP, Konto und Paar (ohne Konto nur die IP). */
export const loginKeys = (ctx: AuthContext, ip: string | undefined, identifier?: string): string[] => [
  ipKey(ctx, ip),
  ...(identifier ? [accountKey(ctx, identifier), accountIpKey(ctx, identifier, ip)] : []),
];

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

/** Zählt einen Fehlversuch; ab der Schwelle wächst die Sperre exponentiell (30 s, 60 s, ... bis zum Höchstwert, standardmäßig 90 s). */
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

/** Fehlversuch für die IP und (optional) das Konto sowie das Paar Konto+IP zählen. */
export async function recordLoginFailure(ctx: AuthContext, ip: string | undefined, identifier?: string): Promise<void> {
  const { lockoutIpThreshold, lockoutAccountThreshold, lockoutPairThreshold } = ctx.config.auth;
  await recordFailure(ctx, ipKey(ctx, ip), lockoutIpThreshold);
  if (identifier) {
    await recordFailure(ctx, accountKey(ctx, identifier), lockoutAccountThreshold);
    await recordFailure(ctx, accountIpKey(ctx, identifier, ip), lockoutPairThreshold);
  }
}

/** Nach erfolgreicher Anmeldung: Zähler des Kontos und des Paares zurücksetzen (der IP-Zähler läuft von selbst ab). */
export async function clearAccountFailures(ctx: AuthContext, ip: string | undefined, identifier: string): Promise<void> {
  await ctx.db.delete(loginAttempts).where(inArray(loginAttempts.key, [accountKey(ctx, identifier), accountIpKey(ctx, identifier, ip)]));
}
