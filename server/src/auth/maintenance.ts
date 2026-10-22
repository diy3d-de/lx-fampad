// Aufräum-Job (beim Start und stündlich): IP-Adressen im Audit-Log nach 7 Tagen entfernen, Audit-Einträge nach der
// Aufbewahrungsfrist löschen, abgelaufene Sitzungen, Challenges (auch angefangene Registrierungen), Tickets und Fehlversuche
// bereinigen, abgelaufene Einladungen protokollieren. Kurzlebiges (Challenges, Tickets, Fehlversuche) bleibt so höchstens
// rund eine Stunde über seinen Ablauf hinaus in der Datenbank.
import { and, eq, isNotNull, isNull, lt, sql } from 'drizzle-orm';
import { runSyncMaintenance, type SyncPurgeReport } from '../sync/maintenance.js';
import { auditLog, invites, keyBackupsPw, keyTransfers, loginAttempts, webauthnChallenges, wsTickets } from '../db/schema.js';
import { serializeErr } from '../log.js';
import { purgeRemovedMembers } from './account.js';
import { writeAudit } from './audit.js';
import type { AuthContext } from './context.js';
import { PW_PENDING_TTL_MS } from './keys-pw.js';
import { purgeSecurityEvents } from './password-reset.js';
import { purgeSessions } from './sessions.js';

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;
export const AUDIT_IP_RETENTION_DAYS = 7;

export interface PurgeReport {
  auditIpCleared: number;
  auditDeleted: number;
  sessionsDeleted: number;
  challengesDeleted: number;
  ticketsDeleted: number;
  keyTransfersDeleted: number;
  attemptsDeleted: number;
  invitesExpired: number;
  invitesDeleted: number;
  removedMembersPurged: number;
  sync: SyncPurgeReport;
}

export async function runMaintenance(ctx: AuthContext): Promise<PurgeReport> {
  const now = ctx.now();
  const ago = (days: number) => new Date(now.getTime() - days * DAY_MS);

  const ipCleared = await ctx.db
    .update(auditLog)
    .set({ ip: null })
    .where(and(isNotNull(auditLog.ip), lt(auditLog.createdAt, ago(AUDIT_IP_RETENTION_DAYS))))
    .returning({ id: auditLog.id });
  const auditGone = await ctx.db.delete(auditLog).where(lt(auditLog.createdAt, ago(ctx.config.auth.auditRetentionDays))).returning({ id: auditLog.id });

  // abgelaufene, nicht benutzte Einladungen einmal je Ablauf im Audit-Log festhalten (Markierung und Eintrag in EINER Transaktion;
  // eine Verlängerung setzt die Markierung zurück). Gesperrte Einladungen sind schon mit invite_locked protokolliert.
  const expired = await ctx.db.transaction(async (tx) => {
    const rows = await tx
      .update(invites)
      .set({ expiredLoggedAt: now })
      .where(and(isNull(invites.usedAt), isNull(invites.revokedAt), isNull(invites.expiredLoggedAt), lt(invites.expiresAt, now)))
      .returning({ id: invites.id, familyId: invites.familyId, role: invites.role, locked: invites.lockedAt });
    for (const e of rows) {
      if (e.locked === null) await writeAudit(ctx, tx, { event: 'invite_expired', familyId: e.familyId, detail: { inviteId: e.id, role: e.role } });
    }
    return rows;
  });
  // alte, nie benutzte Einladungen nach 30 Tagen löschen (benutzte bleiben als Nachweis)
  const invitesGone = await ctx.db
    .delete(invites)
    .where(and(isNull(invites.usedAt), lt(invites.expiresAt, ago(30))))
    .returning({ id: invites.id });

  const sessionsDeleted = await purgeSessions(ctx);
  const challenges = await ctx.db.delete(webauthnChallenges).where(lt(webauthnChallenges.expiresAt, now)).returning({ id: webauthnChallenges.id });
  const tickets = await ctx.db.delete(wsTickets).where(lt(wsTickets.expiresAt, now)).returning({ h: wsTickets.tokenHash });
  const transfers = await ctx.db.delete(keyTransfers).where(lt(keyTransfers.expiresAt, now)).returning({ u: keyTransfers.userId });
  // Fehlversuche zählen nur innerhalb des Fensters; ältere ohne laufende Sperre sind wirkungslos
  const attemptsBefore = new Date(now.getTime() - ctx.config.auth.lockoutWindowSec * 1000);
  const attempts = await ctx.db
    .delete(loginAttempts)
    .where(and(lt(loginAttempts.lastFailedAt, attemptsBefore), sql`(${loginAttempts.lockedUntil} is null or ${loginAttempts.lockedUntil} < ${now.toISOString()}::timestamptz)`))
    .returning({ k: loginAttempts.key });

  // unbestätigte Passwort-Sicherungen verfallen nach einer Stunde (nie löschen: die bisherige bleibt unberührt gültig)
  await ctx.db
    .update(keyBackupsPw)
    .set({ state: 'superseded', updatedAt: now })
    .where(and(eq(keyBackupsPw.state, 'pending'), lt(keyBackupsPw.createdAt, new Date(now.getTime() - PW_PENDING_TTL_MS))));

  await purgeSecurityEvents(ctx);

  // entfernte Mitglieder (Soft-Delete) nach der Aufbewahrungsfrist endgültig löschen; ein Fehler hier darf den übrigen Aufräum-Job nie verhindern
  let removedPurged = 0;
  try {
    removedPurged = await purgeRemovedMembers(ctx);
  } catch (err: unknown) {
    ctx.log.error({ err: serializeErr(err) }, 'Endgültiges Löschen entfernter Mitglieder fehlgeschlagen');
  }

  const sync = await runSyncMaintenance(ctx);

  return {
    auditIpCleared: ipCleared.length,
    auditDeleted: auditGone.length,
    sessionsDeleted,
    challengesDeleted: challenges.length,
    ticketsDeleted: tickets.length,
    keyTransfersDeleted: transfers.length,
    attemptsDeleted: attempts.length,
    invitesExpired: expired.length,
    invitesDeleted: invitesGone.length,
    removedMembersPurged: removedPurged,
    sync,
  };
}

/** Startet den Job einmal sofort und danach stündlich; der Timer hält den Prozess nicht am Leben. */
export function startMaintenance(ctx: AuthContext): { stop: () => void; first: Promise<PurgeReport | null> } {
  const run = () =>
    runMaintenance(ctx).then(
      (report) => report,
      (err: unknown) => {
        ctx.log.error({ err }, 'Aufräum-Job fehlgeschlagen');
        return null;
      },
    );
  const first = run();
  const timer = setInterval(() => void run(), HOUR_MS);
  timer.unref();
  return { stop: () => clearInterval(timer), first };
}
