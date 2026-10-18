// Wiederherstellungs-Codes: 10 Einmal-Codes je Person, gespeichert als HMAC-SHA256 mit serverseitigem Schlüssel.
import { and, eq, isNull, sql } from 'drizzle-orm';
import { recoveryCodes } from '../db/schema.js';
import type { AuthContext, Executor } from './context.js';
import { normalizeRecoveryCode, randomRecoveryCode } from './crypto.js';

export const RECOVERY_CODE_COUNT = 10;

const hashCode = (ctx: AuthContext, code: string) => ctx.keys.hmac('recovery', normalizeRecoveryCode(code));

/** Ersetzt alle Codes der Person durch 10 neue und gibt sie einmalig im Klartext zurück. */
export async function createRecoveryCodes(ctx: AuthContext, exec: Executor, userId: string): Promise<string[]> {
  await exec.delete(recoveryCodes).where(eq(recoveryCodes.userId, userId));
  const codes = Array.from({ length: RECOVERY_CODE_COUNT }, () => randomRecoveryCode());
  await exec.insert(recoveryCodes).values(codes.map((c) => ({ userId, codeHash: hashCode(ctx, c), createdAt: ctx.now() })));
  return codes;
}

/** Löst einen Code atomar ein (UPDATE ... WHERE used_at IS NULL); true, wenn er gültig war. */
export async function consumeRecoveryCode(ctx: AuthContext, userId: string, code: string): Promise<boolean> {
  const rows = await ctx.db
    .update(recoveryCodes)
    .set({ usedAt: ctx.now() })
    .where(and(eq(recoveryCodes.userId, userId), eq(recoveryCodes.codeHash, hashCode(ctx, code)), isNull(recoveryCodes.usedAt)))
    .returning({ id: recoveryCodes.id });
  return rows.length > 0;
}

export async function countRemainingCodes(ctx: AuthContext, userId: string): Promise<number> {
  const [row] = await ctx.db
    .select({ n: sql<number>`count(*)::int` })
    .from(recoveryCodes)
    .where(and(eq(recoveryCodes.userId, userId), isNull(recoveryCodes.usedAt)));
  return row?.n ?? 0;
}
