// Betreiber-Rolle: ein Konto-Flag (Tabelle operators), das nur die Server-CLI setzt (cli/operator.ts). Es gilt allein für die Routen
// unter /api/v1/admin; alle anderen Rechte hängen weiterhin nur an memberships.role.
import { and, eq, isNull, sql } from 'drizzle-orm';
import { writeAudit } from '../auth/audit.js';
import type { AuthContext } from '../auth/context.js';
import { requireStepUp } from '../auth/sessions.js';
import type { SessionPrincipal } from '../auth/types.js';
import { memberships, operators, users } from '../db/schema.js';
import { AppError } from '../errors.js';

/** Ist die Person Betreiber? Gilt nur für ein aktives Mitglied der Familie der Sitzung und nur für ein nicht gesperrtes Konto. */
export async function isOperator(ctx: AuthContext, userId: string, familyId: string): Promise<boolean> {
  const [row] = await ctx.db
    .select({ userId: operators.userId })
    .from(operators)
    .innerJoin(users, eq(users.id, operators.userId))
    .innerJoin(memberships, eq(memberships.userId, users.id))
    .where(and(eq(operators.userId, userId), eq(memberships.familyId, familyId), eq(memberships.status, 'active'), isNull(users.disabledAt)))
    .limit(1);
  return row !== undefined;
}

/**
 * Hook für die Betreiber-Routen: Sitzung (sonst 401), Betreiber-Flag (sonst 404: die Routen sollen sich Nicht-Betreibern nicht
 * zu erkennen geben) und, für sensible Ansichten, ein frisches Step-up (403 step_up_required; erst NACH der Betreiber-Prüfung).
 */
export async function requireOperator(
  ctx: AuthContext,
  principal: SessionPrincipal,
  options: { stepUp?: boolean } = {},
): Promise<SessionPrincipal> {
  if (!(await isOperator(ctx, principal.userId, principal.familyId))) throw new AppError(404, 'not_found', 'Nicht gefunden.');
  if (options.stepUp) requireStepUp(ctx, principal);
  return principal;
}

export interface OperatorRow {
  userId: string;
  email: string;
  displayName: string;
  grantedAt: Date;
}

async function findActiveByEmail(ctx: AuthContext, email: string) {
  const [row] = await ctx.db
    .select({ userId: users.id, familyId: memberships.familyId, status: memberships.status, disabledAt: users.disabledAt })
    .from(users)
    .innerJoin(memberships, eq(memberships.userId, users.id))
    .where(sql`lower(${users.email}) = lower(${email.trim()})`)
    .limit(1);
  return row;
}

/** Macht ein aktives Mitglied zum Betreiber (idempotent). Wirft AppError bei unbekanntem, wartendem oder gesperrtem Konto. */
export async function grantOperator(ctx: AuthContext, email: string): Promise<{ userId: string; changed: boolean }> {
  const acc = await findActiveByEmail(ctx, email);
  if (!acc) throw new AppError(404, 'not_found', 'Kein Konto mit dieser E-Mail-Adresse.');
  if (acc.status !== 'active' || acc.disabledAt) throw new AppError(409, 'not_active', 'Das Konto ist nicht aktiv.');
  return ctx.db.transaction(async (tx) => {
    const inserted = await tx.insert(operators).values({ userId: acc.userId, grantedAt: ctx.now(), grantedBy: 'cli' }).onConflictDoNothing().returning({ userId: operators.userId });
    const changed = inserted.length > 0;
    if (changed) await writeAudit(ctx, tx, { event: 'operator_granted', familyId: acc.familyId, actorId: acc.userId, detail: { via: 'cli' } });
    return { userId: acc.userId, changed };
  });
}

/** Nimmt die Betreiber-Rolle zurück (idempotent). */
export async function revokeOperator(ctx: AuthContext, email: string): Promise<{ userId: string; changed: boolean }> {
  const acc = await findActiveByEmail(ctx, email);
  if (!acc) throw new AppError(404, 'not_found', 'Kein Konto mit dieser E-Mail-Adresse.');
  return ctx.db.transaction(async (tx) => {
    const gone = await tx.delete(operators).where(eq(operators.userId, acc.userId)).returning({ userId: operators.userId });
    const changed = gone.length > 0;
    if (changed) await writeAudit(ctx, tx, { event: 'operator_revoked', familyId: acc.familyId, actorId: acc.userId, detail: { via: 'cli' } });
    return { userId: acc.userId, changed };
  });
}

export async function listOperators(ctx: AuthContext): Promise<OperatorRow[]> {
  return ctx.db
    .select({ userId: users.id, email: users.email, displayName: users.displayName, grantedAt: operators.grantedAt })
    .from(operators)
    .innerJoin(users, eq(users.id, operators.userId))
    .orderBy(operators.grantedAt);
}
