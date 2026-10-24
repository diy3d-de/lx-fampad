// Tresor, Teil des Servers außerhalb der Sync-Engine (Abschnitt 6m): `reconcileTresorTeilnehmer` zieht nach einem Rollenwechsel die Teilnehmerliste der Tresor-Konversation nach:
// Wer nach der neuen Rollenverteilung kein Erwachsener mehr ist (Elternteil wird Kind), fliegt SOFORT aus der Liste und bekommt `hidden` (nie ein Kind unter den Teilnehmern).
// Ein Kind, das Elternteil wird, nimmt der Server NICHT von selbst auf (er kann keinen Schlüssel verpacken, der Verlauf wird nur auf ausdrücklichen Tipp geteilt): das macht die App
// (Teilnehmer-Pflege) mit einem Gerät, das den Schlüssel hat. Die Verbleibenden legen mit dem nächsten Abgleich eine neue Epoche an, danach liest die entfernte Person nichts Neues mehr.
// Aufbau wie `reconcileZaehlerTeilnehmer` (sync/zaehler.ts).
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Executor } from '../auth/context.js';
import { families, konversationen, memberships, users } from '../db/schema.js';
import { LOST_SIGHT, RevCounter, logChange, type EngineEnv } from './engine.js';
import { aktiveRollen } from './entities/meds-regeln.js';
import { tresorTeilnehmerBereinigt } from './entities/tresor-regeln.js';
import type { Registry } from './registry.js';

/** Zieht die Teilnehmerliste der Tresor-Konversation der Familie nach den aktuellen Rollen nach (in derselben Transaktion wie der Rollenwechsel). Liefert die neue Revision (null: nichts zu ändern). */
export async function reconcileTresorTeilnehmer(tx: Executor, registry: Registry, input: { familyId: string; now: Date }): Promise<number | null> {
  const def = registry.get('konversation');
  if (!def) return null;
  const [family] = await tx.select({ rev: families.currentRev }).from(families).where(eq(families.id, input.familyId)).for('update');
  if (!family) return null;
  const revs = new RevCounter(family.rev);
  const env: EngineEnv = {
    tx,
    registry,
    familyId: input.familyId,
    actor: { userId: '00000000-0000-0000-0000-000000000000', role: 'admin' },
    deviceId: null,
    authorId: null,
    now: input.now,
    revs,
  };
  const konvs = await tx
    .select({ id: konversationen.id, teilnehmer: konversationen.teilnehmer, fieldRevs: konversationen.fieldRevs })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, input.familyId), isNull(konversationen.deletedAt), sql`${konversationen.art}::text = 'tresor'`));
  for (const k of konvs) {
    const rollen = await aktiveRollen(tx, input.familyId, k.teilnehmer);
    const alleErwachsenen = (
      await tx
        .select({ id: memberships.userId })
        .from(memberships)
        .innerJoin(users, eq(users.id, memberships.userId))
        .where(and(eq(memberships.familyId, input.familyId), eq(memberships.status, 'active'), isNull(users.disabledAt), sql`${memberships.role} in ('admin', 'parent')`))
    ).map((r) => r.id);
    const neu = tresorTeilnehmerBereinigt(k.teilnehmer, rollen, alleErwachsenen);
    const alt = [...k.teilnehmer].map((t) => t.toLowerCase()).sort();
    if (neu.length === 0 || JSON.stringify(neu) === JSON.stringify(alt)) continue;
    const weg = alt.filter((t) => !neu.includes(t));
    const rev = revs.next();
    const fieldRevs = { ...((k.fieldRevs ?? {}) as Record<string, number>), teilnehmer: rev };
    await tx
      .update(konversationen)
      .set({ teilnehmer: neu, rev, fieldRevs, updatedAt: input.now })
      .where(and(eq(konversationen.familyId, input.familyId), eq(konversationen.id, k.id)));
    await logChange(env, { def, id: k.id, rev, tombstone: false, created: false, changes: { teilnehmer: neu, ...(weg.length > 0 ? { [LOST_SIGHT]: weg } : {}) } });
  }
  if (!revs.changed) return null;
  await tx.update(families).set({ currentRev: revs.rev }).where(eq(families.id, input.familyId));
  return revs.rev;
}
