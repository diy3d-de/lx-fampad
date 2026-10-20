import { and, eq, isNull } from 'drizzle-orm';
import type { Db } from '../auth/context.js';
import { memberships, users } from '../db/schema.js';
import type { MemberDirectory } from './service.js';

/** Aktive, nicht gesperrte Mitglieder einer Familie. */
export function dbDirectory(db: Db): MemberDirectory {
  return async (familyId) =>
    db
      .select({ userId: memberships.userId, role: memberships.role })
      .from(memberships)
      .innerJoin(users, eq(users.id, memberships.userId))
      .where(and(eq(memberships.familyId, familyId), eq(memberships.status, 'active'), isNull(users.disabledAt)));
}
