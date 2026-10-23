// Medikamenten-Plan, Teil des Servers außerhalb der Sync-Engine (Abschnitt 6i):
//  - `purgeAlteEinnahmen`: Einnahme-Einträge werden nach 120 Tagen gelöscht (Serverzeit, `created_at`), mit Tombstone, damit die Geräte ihre Kopie entfernen. Läuft im
//    stündlichen Wartungsjob (sync/maintenance.ts); je Familie in einer eigenen Transaktion mit gesperrter Familienzeile (wie jede andere Änderung).
//  - `reconcileMedsTeilnehmer`: nach einem Rollenwechsel (Kind wird Erwachsener, Elternteil wird Kind) zieht der Server die Teilnehmerlisten der Medikamenten-Konversationen
//    nach: Wer nach der neuen Rollenverteilung nichts mehr sehen darf, fliegt aus der Liste (und bekommt `hidden`). Der Server kann keinen Schlüssel rotieren; die
//    Verbleibenden legen mit dem nächsten Abgleich eine neue Epoche an (App: Teilnehmer-Pflege), danach liest die entfernte Person nichts Neues mehr.
import { and, asc, eq, isNull, lt, sql } from 'drizzle-orm';
import type { AuthContext, Executor } from '../auth/context.js';
import { konversationen, einnahmen, families } from '../db/schema.js';
import { LOST_SIGHT, RevCounter, logChange, tombstoneTree, type EngineEnv } from './engine.js';
import { aktiveRollen, medsTeilnehmerBereinigt } from './entities/meds-regeln.js';
import { EINNAHMEN_AUFBEWAHRUNG_TAGE } from './entities/medikamente.js';
import { defaultRegistry } from './index.js';
import type { Registry, Row } from './registry.js';

const DAY_MS = 86_400_000;
const BATCH = 500;

/** Löscht Einnahme-Einträge, die älter als 120 Tage sind. Liefert die Anzahl. */
export async function purgeAlteEinnahmen(ctx: Pick<AuthContext, 'db' | 'now'>, registry: Registry = defaultRegistry): Promise<number> {
  const now = ctx.now();
  const cutoff = new Date(now.getTime() - EINNAHMEN_AUFBEWAHRUNG_TAGE * DAY_MS);
  const def = registry.get('einnahme');
  if (!def) return 0;
  let total = 0;
  const familyIds = await ctx.db
    .selectDistinct({ id: einnahmen.familyId })
    .from(einnahmen)
    .where(and(isNull(einnahmen.deletedAt), lt(einnahmen.createdAt, cutoff)));
  for (const { id: familyId } of familyIds) {
    for (let runde = 0; runde < 100; runde++) {
      const n = await ctx.db.transaction(async (tx) => {
        const [family] = await tx.select({ rev: families.currentRev }).from(families).where(eq(families.id, familyId)).for('update');
        if (!family) return 0;
        const alte = (await tx
          .select()
          .from(einnahmen)
          .where(and(eq(einnahmen.familyId, familyId), isNull(einnahmen.deletedAt), lt(einnahmen.createdAt, cutoff)))
          .orderBy(asc(einnahmen.createdAt))
          .limit(BATCH)) as Row[];
        if (alte.length === 0) return 0;
        const revs = new RevCounter(family.rev);
        const env: EngineEnv = { tx, registry, familyId, actor: { userId: '00000000-0000-0000-0000-000000000000', role: 'admin' }, deviceId: null, authorId: null, now, revs };
        for (const row of alte) await tombstoneTree(env, def, row);
        await tx.update(families).set({ currentRev: revs.rev }).where(eq(families.id, familyId));
        return alte.length;
      });
      total += n;
      if (n < BATCH) break;
    }
  }
  return total;
}

/**
 * Zieht die Teilnehmerlisten aller Medikamenten-Konversationen der Familie nach den aktuellen Rollen nach (nach einem Rollenwechsel, in derselben Transaktion). Liefert die
 * neue Revision der Familie (null: nichts zu ändern).
 */
export async function reconcileMedsTeilnehmer(tx: Executor, registry: Registry, input: { familyId: string; now: Date }): Promise<number | null> {
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
    .select({ id: konversationen.id, subjektId: konversationen.subjektId, teilnehmer: konversationen.teilnehmer, fieldRevs: konversationen.fieldRevs })
    .from(konversationen)
    .where(and(eq(konversationen.familyId, input.familyId), isNull(konversationen.deletedAt), sql`${konversationen.art}::text = 'meds'`));
  for (const k of konvs) {
    if (!k.subjektId) continue;
    const rollen = await aktiveRollen(tx, input.familyId, [k.subjektId, ...k.teilnehmer]);
    const neu = medsTeilnehmerBereinigt(k.subjektId, k.teilnehmer, rollen);
    const alt = [...k.teilnehmer].map((t) => t.toLowerCase()).sort();
    if (JSON.stringify(neu) === JSON.stringify(alt)) continue;
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
