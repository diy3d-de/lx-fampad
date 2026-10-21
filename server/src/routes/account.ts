// /api/v1/me, /members, /invites, /devices, /ws-ticket (alle nur mit Anmeldung). Fachlogik liegt in src/auth/.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import {
  approveMember,
  changeRole,
  finishAddPasskey,
  getMe,
  issueWsTicket,
  listCredentials,
  listDevices,
  listMembers,
  regenerateRecoveryCodes,
  rejectMember,
  removeDevice,
  removeMember,
  removePasskey,
  resetMember,
  setFamilyRole,
  startAddPasskey,
  updateProfile,
} from '../auth/account.js';
import { FAMILY_ROLES } from '../db/schema.js';
import { avatarMetaFor } from '../avatar/service.js';
import { claimTransfer, createKeys, createTransfer, getBackup, getMemberKeys, getOwnKeys, rotateKeys, setBackup } from '../auth/keys.js';
import { getPwBackup, markPwBackupVerified, setPwBackup, KDF_IDS } from '../auth/keys-pw.js';
import { assertMayInvite, createInvite, extendInvite, listInvites, revokeInvite } from '../auth/invites.js';
import { changePassword, finishAddPassword, removePassword, startAddPassword } from '../auth/password-credential.js';
import { requireStepUp } from '../auth/sessions.js';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { AppError } from '../errors.js';
import { b64urlBlob, b64urlKey, b64urlSalt16, clearCookie, codeSchema, displayNameSchema, idParams, labelSchema, meta, parse, passwordSchema, registrationResponseSchema, strictLimit, uuid } from './util.js';

const role = z.enum(['admin', 'parent', 'child']);
const familyRoleBody = z.object({ familyRole: z.enum(FAMILY_ROLES).nullable() }).strict();

export function registerAccountRoutes(app: FastifyInstance, config: Config, auth: Auth): void {
  const ctx = auth.ctx;
  const strikt = strictLimit(config);
  const maxHours = ctx.config.auth.inviteMaxHours;

  // ----- Profil -----
  app.get('/api/v1/me', async (req) => {
    const me = await getMe(ctx, await auth.requireSession(req));
    return { ...me, user: { ...me.user, avatar: (await avatarMetaFor(ctx, [me.user.id])).get(me.user.id) ?? null } };
  });

  app.patch('/api/v1/me', async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ displayName: displayNameSchema.optional(), colorIndex: z.number().int().min(0).max(9).optional() }).strict(), req.body);
    await updateProfile(ctx, p, body);
    return { ok: true };
  });

  // Familienrolle: reine Anzeige (keine Rechte), jedes Mitglied für sich
  app.put('/api/v1/me/family-role', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await setFamilyRole(ctx, p, p.userId, parse(familyRoleBody, req.body).familyRole, meta(req));
    return { ok: true };
  });

  app.get('/api/v1/me/credentials', async (req) => ({ credentials: await listCredentials(ctx, await auth.requireSession(req)) }));

  app.post('/api/v1/me/passkeys/options', strikt, async (req) => startAddPasskey(ctx, await auth.requireSession(req)));

  app.post('/api/v1/me/passkeys/verify', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ challengeId: uuid, response: registrationResponseSchema, label: labelSchema.optional() }).strict(), req.body);
    return finishAddPasskey(ctx, p, body, meta(req));
  });

  app.delete('/api/v1/me/passkeys/:id', async (req) => {
    const p = await auth.requireSession(req);
    await removePasskey(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });

  // Passwort + TOTP nachträglich (alles mit Step-up): hinzufügen in zwei Schritten, ändern, entfernen
  app.post('/api/v1/me/password/start', strikt, async (req) => {
    const p = await auth.requireSession(req);
    return startAddPassword(ctx, p, parse(z.object({ password: passwordSchema }).strict(), req.body));
  });

  app.post('/api/v1/me/password/complete', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await finishAddPassword(ctx, p, parse(z.object({ challengeId: uuid, code: codeSchema }).strict(), req.body), meta(req));
    return { ok: true };
  });

  app.post('/api/v1/me/password/change', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await changePassword(ctx, p, parse(z.object({ password: passwordSchema }).strict(), req.body), meta(req));
    return { ok: true };
  });

  app.delete('/api/v1/me/password', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await removePassword(ctx, p, meta(req));
    return { ok: true };
  });

  app.post('/api/v1/me/recovery-codes', strikt, async (req) => ({ recoveryCodes: await regenerateRecoveryCodes(ctx, await auth.requireSession(req), meta(req)) }));

  // ----- E2EE-Schlüssel (Phase 1): öffentliche Personenschlüssel, opake Sicherung, Geräte-Übertragung -----
  app.get('/api/v1/me/keys', async (req) => getOwnKeys(ctx, await auth.requireSession(req)));

  const keysBody = z.object({ publicEncKey: b64urlKey, publicSignKey: b64urlKey }).strict();

  app.post('/api/v1/me/keys', strikt, async (req) => {
    const p = await auth.requireSession(req);
    return { keys: await createKeys(ctx, p, parse(keysBody, req.body), meta(req)) };
  });

  app.put('/api/v1/me/keys', strikt, async (req) => {
    const p = await auth.requireSession(req);
    return { keys: await rotateKeys(ctx, p, parse(keysBody.extend({ expectedKeyVersion: z.number().int().min(1) }).strict(), req.body), meta(req)) };
  });

  app.put('/api/v1/me/key-backup', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await setBackup(ctx, p, parse(z.object({ blob: b64urlBlob(2048), keyVersion: z.number().int().min(1) }).strict(), req.body), meta(req));
    return { ok: true };
  });

  app.get('/api/v1/me/key-backup', strikt, async (req) => getBackup(ctx, await auth.requireSession(req), meta(req)));

  // Passwort-Sicherung (vereinfachte Schlüsselverwaltung): nur mit Schalter E2EE_PW_BACKUP, sonst gibt es die Routen nicht (404)
  if (config.e2eePwBackup) {
    const kdfBody = z.object({ id: z.enum(KDF_IDS), memKiB: z.number().int().min(8192).max(1_048_576), ops: z.number().int().min(1).max(20), salt: b64urlSalt16 }).strict();
    app.put('/api/v1/me/key-backup-pw', strikt, async (req) => {
      const p = await auth.requireSession(req);
      const body = parse(z.object({ blob: b64urlBlob(4096), keyVersion: z.number().int().min(1), kdf: kdfBody }).strict(), req.body);
      return { ok: true, ...(await setPwBackup(ctx, p, body, meta(req))) };
    });
    app.get('/api/v1/me/key-backup-pw', strikt, async (req) => getPwBackup(ctx, await auth.requireSession(req), meta(req)));
    app.post('/api/v1/me/key-backup-pw/verified', strikt, async (req) => {
      const p = await auth.requireSession(req);
      await markPwBackupVerified(ctx, p, parse(z.object({ id: uuid }).strict(), req.body).id, meta(req));
      return { ok: true };
    });
  }

  app.post('/api/v1/me/key-transfer', strikt, async (req) => {
    const p = await auth.requireSession(req);
    return createTransfer(ctx, p, parse(z.object({ lookup: b64urlKey, blob: b64urlBlob(1024), keyVersion: z.number().int().min(1) }).strict(), req.body));
  });

  app.post('/api/v1/me/key-transfer/claim', strikt, async (req) => {
    const p = await auth.requireSession(req);
    return claimTransfer(ctx, p, parse(z.object({ lookup: b64urlKey }).strict(), req.body), meta(req));
  });

  // ----- Mitglieder -----
  // Öffentliche Schlüssel eines Mitglieds samt Historie (alte Signaturen prüfen); nur Familie, sonst 404
  app.get('/api/v1/members/:id/keys', async (req) => {
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    const q = parse(z.object({ version: z.coerce.number().int().min(1).optional() }).strict(), req.query);
    return getMemberKeys(ctx, p, id, q.version);
  });

  app.get('/api/v1/members', async (req) => {
    const members = await listMembers(ctx, await auth.requireSession(req));
    const avatars = await avatarMetaFor(ctx, members.map((m) => m.id));
    return { members: members.map((m) => ({ ...m, avatar: avatars.get(m.id) ?? null })) };
  });

  app.patch('/api/v1/members/:id/role', async (req) => {
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    const body = parse(z.object({ role }).strict(), req.body);
    await changeRole(ctx, p, id, body.role, meta(req));
    return { ok: true };
  });

  // Admin setzt die Familienrolle (reine Anzeige) eines Mitglieds; ohne Step-up, da ohne Wirkung auf Rechte
  app.put('/api/v1/members/:id/family-role', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    await setFamilyRole(ctx, p, id, parse(familyRoleBody, req.body).familyRole, meta(req));
    return { ok: true };
  });

  app.post('/api/v1/members/:id/approve', async (req) => {
    const p = await auth.requireSession(req);
    await approveMember(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });

  app.post('/api/v1/members/:id/reject', async (req) => {
    const p = await auth.requireSession(req);
    await rejectMember(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });

  app.post('/api/v1/members/:id/reset', strikt, async (req) => {
    const p = await auth.requireSession(req);
    if (p.role !== 'admin') throw new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
    requireStepUp(ctx, p);
    const { id } = parse(idParams, req.params);
    const body = parse(z.object({ hours: z.number().int().min(1).max(maxHours).default(ctx.config.auth.inviteDefaultHours), pin: z.boolean().default(false) }).strict(), req.body);
    const invite = await resetMember(ctx, { familyId: p.familyId, userId: id, actorId: p.userId, hours: body.hours, withPin: body.pin }, meta(req));
    return { invite };
  });

  app.delete('/api/v1/members/:id', async (req) => {
    const p = await auth.requireSession(req);
    await removeMember(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });

  // ----- Einladungen (Admin; Eltern nur Kinder und nur die eigenen) -----
  app.get('/api/v1/invites', async (req) => {
    const p = await auth.requireSession(req);
    if (p.role !== 'admin' && p.role !== 'parent') throw new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
    return { invites: await listInvites(ctx, p) };
  });

  app.post('/api/v1/invites', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(
      z
        .object({
          role,
          hours: z.number().int().min(1).max(maxHours).default(ctx.config.auth.inviteDefaultHours),
          pin: z.boolean().default(false),
          requireApproval: z.boolean().optional(),
        })
        .strict(),
      req.body,
    );
    assertMayInvite(p.role, body.role);
    if (body.role === 'admin') requireStepUp(ctx, p);
    // Freigabe durch einen Admin ist nur auf ausdrücklichen Wunsch nötig (Standard: nein)
    const requireApproval = body.requireApproval;
    // Einladung samt PIN-Hash und Audit-Eintrag in einer Transaktion
    const invite = await ctx.db.transaction((tx) =>
      createInvite(ctx, tx, { familyId: p.familyId, role: body.role, hours: body.hours, withPin: body.pin, requireApproval, createdBy: p.userId }, meta(req)),
    );
    // Token und PIN erscheinen nur in dieser Antwort; die Liste zeigt sie nie wieder
    return { invite };
  });

  app.post('/api/v1/invites/:id/revoke', async (req) => {
    const p = await auth.requireSession(req);
    await revokeInvite(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });

  app.post('/api/v1/invites/:id/extend', async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ hours: z.number().int().min(1).max(maxHours) }).strict(), req.body);
    const expiresAt = await extendInvite(ctx, p, parse(idParams, req.params).id, body.hours, meta(req));
    return { expiresAt };
  });

  // ----- Geräte -----
  app.get('/api/v1/devices', async (req) => ({ devices: await listDevices(ctx, await auth.requireSession(req)) }));

  app.delete('/api/v1/devices/:id', async (req, reply) => {
    const p = await auth.requireSession(req);
    const { current } = await removeDevice(ctx, p, parse(idParams, req.params).id, meta(req));
    if (current) clearCookie(reply);
    return { ok: true };
  });

  // ----- WebSocket-Ticket -----
  app.post('/api/v1/ws-ticket', strikt, async (req) => issueWsTicket(ctx, await auth.requireSession(req)));
}
