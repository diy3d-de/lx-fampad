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
  | 'transfer_claimed';

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
