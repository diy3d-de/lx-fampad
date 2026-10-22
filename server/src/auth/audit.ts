// Audit-Log: nur anhängen. Die IP-Spalte leert der Aufräum-Job nach 7 Tagen, der Eintrag selbst läuft nach der Aufbewahrungsfrist ab.
import { auditLog } from '../db/schema.js';
import type { AuthContext, Executor } from './context.js';

export type AuditEvent =
  | 'bootstrap_created'
  | 'invite_created'
  | 'invite_used'
  | 'invite_revoked'
  | 'invite_extended'
  | 'invite_expired'
  | 'invite_pin_failed'
  | 'invite_locked'
  | 'member_registered'
  | 'member_approved'
  | 'member_rejected'
  | 'member_removed'
  | 'member_restored'
  | 'member_purged'
  | 'avatar_reset'
  | 'member_reset'
  | 'role_changed'
  | 'family_role_set'
  | 'login_ok'
  | 'login_failed'
  | 'device_added'
  | 'device_removed'
  | 'logout'
  | 'logout_all'
  | 'session_reuse_detected'
  | 'session_refresh_retry'
  | 'step_up_ok'
  | 'step_up_failed'
  | 'passkey_added'
  | 'passkey_removed'
  | 'passkey_counter_regression'
  | 'password_added'
  | 'password_setup_failed'
  | 'password_changed'
  | 'password_removed'
  | 'recovery_codes_created'
  | 'recovery_code_used'
  | 'ws_auth_failed'
  | 'key_created'
  | 'key_rotated'
  | 'backup_set'
  | 'key_backup_read'
  | 'transfer_claimed'
  | 'key_backup_pw_set'
  | 'key_backup_pw_read'
  | 'key_backup_pw_verified'
  | 'key_backup_prf_set'
  | 'key_backup_prf_read'
  | 'key_backup_prf_verified'
  | 'guardian_escrow_set'
  | 'guardian_escrow_removed'
  | 'guardian_recovery_requested'
  | 'guardian_recovery_challenged'
  | 'guardian_recovery_revealed'
  | 'guardian_recovery_released'
  | 'guardian_recovery_done'
  | 'guardian_recovery_ended'
  | 'key_backup_archive_list'
  | 'key_backup_archive_read'
  | 'password_authkey_set'
  | 'password_reset_requested'
  | 'password_reset_done'
  | 'operator_granted'
  | 'operator_revoked'
  /** Betreiber-Warnung (Prüfer, `operator/monitor.ts`): je Art ein Ereignis, ohne Inhalt. */
  | 'operator_alert_cert'
  | 'operator_alert_backup'
  | 'operator_alert_database'
  | 'operator_alert_ntfy'
  | 'operator_alert_disk'
  | 'operator_alert_logins'
  | 'operator_alert_key'
  | 'operator_alert_nas_pull'
  | 'operator_alert_nas_restore'
  | 'operator_alert_nas_channel'
  /** Betreiber schaltet seine Warnungen ein oder aus (`detail.enabled`). */
  | 'operator_warnings_set'
  /** Betreiber hebt die Anmeldesperre eines Kontos auf. */
  | 'operator_unlock'
  /** Betreiber schaltet den Wartungsmodus (`detail.from`/`to`, optional `until`; `via: 'cli'` beim Notausgang auf dem Server). */
  | 'operator_maintenance_set'
  /** Betreiber setzt oder löscht den Familienhinweis (`detail.had`/`has`, Länge und Ablauf, nie der Text). */
  | 'operator_notice_set';

export interface AuditEntry {
  event: AuditEvent;
  familyId?: string | null;
  actorId?: string | null;
  deviceId?: string | null;
  detail?: Record<string, unknown>;
  ip?: string | undefined;
}

export async function writeAudit(ctx: Pick<AuthContext, 'now'>, exec: Executor, entry: AuditEntry): Promise<void> {
  await exec.insert(auditLog).values({
    event: entry.event,
    familyId: entry.familyId ?? null,
    actorId: entry.actorId ?? null,
    deviceId: entry.deviceId ?? null,
    detail: entry.detail ?? {},
    ip: entry.ip ?? null,
    createdAt: ctx.now(),
  });
}
