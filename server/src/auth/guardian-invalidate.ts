// Eltern-Wiederherstellung: Hinterlegungen und Anfragen eines Kindes werden ungültig, wenn sich Anmeldedaten oder Rolle ändern (Komplett-Reset, Passwort-Reset, Änderung
// der Anmeldedaten, Rollenwechsel): sonst bekäme, wer das Konto des Kindes übernimmt, über die Eltern dessen Schlüssel. Nichts wird gelöscht: die Einträge werden `stale`
// (nie wieder angeboten, bis das Kind sie von einem Gerät mit seinem Schlüssel neu anlegt), offene Anfragen enden (`cancelled`, Übergabedaten weg).
// Eigene Datei, damit sessions.ts sie ohne Importzyklus nutzen kann.
import { and, eq, inArray } from 'drizzle-orm';
import { guardianEscrows, guardianRecoveries, personKeys } from '../db/schema.js';
import type { Executor } from './context.js';

export const OPEN_RECOVERY_STATES = ['pending', 'challenged', 'revealed', 'released'] as const;

/** Setzt die Hinterlegungen des Kindes auf `stale` und beendet seine offenen Anfragen. Gehört in die Transaktion der auslösenden Änderung. */
export async function invalidateGuardianEscrow(exec: Executor, childId: string, now: Date): Promise<void> {
  // dieselbe Zeile sperren wie das Hinterlegen und Anfragen (setEscrow, createRecovery): eine gleichzeitige Hinterlegung wartet, statt nach der Entwertung noch als aktiv zu entstehen
  await exec.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, childId)).for('update');
  await exec.update(guardianEscrows).set({ state: 'stale', updatedAt: now }).where(and(eq(guardianEscrows.childId, childId), eq(guardianEscrows.state, 'active')));
  await exec
    .update(guardianRecoveries)
    .set({ state: 'cancelled', releaseBlob: null, releaseSig: null, revealPub: null, revealNonce: null, challenge: null, updatedAt: now })
    .where(and(eq(guardianRecoveries.childId, childId), inArray(guardianRecoveries.state, [...OPEN_RECOVERY_STATES])));
}

/** Rollenwechsel einer Person: ihre Hinterlegungen als Kind werden ungültig, und Einträge, in denen sie Elternteil ist, werden `stale`. */
export async function invalidateGuardianRole(exec: Executor, userId: string, now: Date): Promise<void> {
  await invalidateGuardianEscrow(exec, userId, now);
  await exec.update(guardianEscrows).set({ state: 'stale', updatedAt: now }).where(and(eq(guardianEscrows.guardianId, userId), eq(guardianEscrows.state, 'active')));
}
