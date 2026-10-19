// Erstinstallation durch den Betreiber (CLI): genau eine Familie, der erste Admin kommt per Einladungslink dazu.
// Es gibt keine offene Registrierung; dieser Weg läuft nur auf dem Server (Zugriff auf Datenbank und Schlüssel).
import { and, eq, isNull, sql } from 'drizzle-orm';
import { families, invites, memberships, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, RequestMeta } from './context.js';
import { resetMember } from './account.js';
import { createInvite, type CreatedInvite } from './invites.js';

const BOOTSTRAP_LOCK = 727_401;
const CLI_META: RequestMeta = { ip: undefined };

/**
 * Legt die Familie und eine Einladung für den ersten Admin an (7 Tage, Einmaltoken, nur der Hash liegt in der DB).
 * Existiert die Familie schon und hat sie einen Admin, bricht der Aufruf ab. Hat sie noch keinen (Einladung nie
 * eingelöst), wird die alte Einladung widerrufen und eine neue erzeugt.
 */
export async function bootstrapFamily(ctx: AuthContext, input: { familyName: string; withPin?: boolean }): Promise<CreatedInvite & { familyId: string }> {
  return ctx.db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(${BOOTSTRAP_LOCK})`);
    const existing = await tx.select().from(families).limit(2);
    if (existing.length > 1) throw new AppError(409, 'multiple_families', 'Es existiert mehr als eine Familie; der Server bedient genau eine.');
    let familyId: string;
    if (existing[0]) {
      familyId = existing[0].id;
      const [admin] = await tx
        .select({ id: memberships.id })
        .from(memberships)
        .where(and(eq(memberships.familyId, familyId), eq(memberships.role, 'admin')))
        .limit(1);
      if (admin) throw new AppError(409, 'already_bootstrapped', 'Die Familie ist bereits eingerichtet.');
      await tx.update(invites).set({ revokedAt: ctx.now() }).where(and(eq(invites.familyId, familyId), isNull(invites.usedAt), isNull(invites.revokedAt)));
    } else {
      const [fam] = await tx.insert(families).values({ name: input.familyName, createdAt: ctx.now() }).returning({ id: families.id });
      if (!fam) throw new Error('Familie nicht angelegt');
      familyId = fam.id;
    }
    const invite = await createInvite(
      ctx,
      tx,
      { familyId, role: 'admin', hours: ctx.config.auth.bootstrapInviteHours, withPin: input.withPin ?? false, requireApproval: false, createdBy: null },
      CLI_META,
    );
    await writeAudit(ctx, tx, { event: 'bootstrap_created', familyId, detail: { inviteId: invite.id } });
    return { ...invite, familyId };
  });
}

/** Notfall: der Betreiber setzt ein Mitglied (z. B. den einzigen Admin) per E-Mail zurück und bekommt einen neuen Einladungslink. */
export async function resetByEmail(ctx: AuthContext, email: string, withPin = false): Promise<CreatedInvite> {
  const [row] = await ctx.db
    .select({ userId: users.id, familyId: memberships.familyId })
    .from(users)
    .innerJoin(memberships, eq(memberships.userId, users.id))
    .where(sql`lower(${users.email}) = lower(${email})`);
  if (!row) throw new AppError(404, 'not_found', 'Kein Mitglied mit dieser E-Mail-Adresse.');
  return resetMember(ctx, { familyId: row.familyId, userId: row.userId, actorId: null, hours: ctx.config.auth.bootstrapInviteHours, withPin }, CLI_META);
}
