// Verweise auf Mitglieder bereinigen, wenn eine Person die Familie verlässt: Spalten wie `assignee_id` oder `owner_id` werden NULL,
// jede betroffene Zeile bekommt eine neue Revision und einen Änderungseintrag (die Geräte erfahren es über den Sync). Die Fremdschlüssel
// haben zwar ON DELETE SET NULL, das ändert aber weder Revision noch Protokoll; deshalb läuft diese Bereinigung VOR dem Löschen der Person
// (gelöschte Datensätze bleiben außen vor: ihr Inhalt ist ohnehin geleert, den Rest erledigt der Fremdschlüssel).
import { and, eq, isNull } from 'drizzle-orm';
import type { Executor } from '../auth/context.js';
import { families } from '../db/schema.js';
import { RevCounter, logChange, type EngineEnv } from './engine.js';
import { columnOf, syncColumns, type Registry, type Row } from './registry.js';

/** Setzt alle Verweise auf `userId` in den Sync-Tabellen der Familie auf NULL. Liefert die neue Revision der Familie (null: nichts geändert). */
export async function detachMemberRefs(
  tx: Executor,
  registry: Registry,
  input: { familyId: string; userId: string; now: Date },
): Promise<number | null> {
  const [family] = await tx.select({ rev: families.currentRev }).from(families).where(eq(families.id, input.familyId)).for('update');
  if (!family) return null;
  const revs = new RevCounter(family.rev);
  const env: EngineEnv = {
    tx,
    registry,
    familyId: input.familyId,
    actor: { userId: input.userId, role: 'admin' },
    deviceId: null,
    authorId: null,
    now: input.now,
    revs,
  };
  for (const def of registry.list()) {
    const c = syncColumns(def);
    for (const field of def.userRefs ?? []) {
      const col = columnOf(def, field);
      const rows = (await tx
        .select()
        .from(def.table)
        .where(and(eq(c.familyId, input.familyId), eq(col, input.userId), isNull(c.deletedAt)))) as Row[];
      for (const row of rows) {
        const rev = revs.next();
        const fieldRevs = { ...((row.fieldRevs ?? {}) as Record<string, number>), [field]: rev };
        await tx
          .update(def.table)
          .set({ [field]: null, rev, fieldRevs, updatedAt: input.now } as never)
          .where(and(eq(c.familyId, input.familyId), eq(c.id, String(row.id))));
        await logChange(env, { def, id: String(row.id), rev, tombstone: false, created: false, changes: { [field]: null } });
      }
    }
  }
  if (!revs.changed) return null;
  await tx.update(families).set({ currentRev: revs.rev }).where(eq(families.id, input.familyId));
  return revs.rev;
}
