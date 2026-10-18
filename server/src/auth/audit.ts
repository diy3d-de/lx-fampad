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
  | 'member_reset'
  | 'role_changed'
  | 'login_ok'
  | 'login_failed'
  | 'device_added'
  | 'device_removed'
  | 'logout'
  | 'logout_all'
  | 'session_reuse_detected'
  | 'step_up_ok'
  | 'step_up_failed'
  | 'passkey_added'
  | 'passkey_removed'
  | 'passkey_counter_regression'
  | 'recovery_codes_created'
  | 'recovery_code_used'
  | 'ws_auth_failed';

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
