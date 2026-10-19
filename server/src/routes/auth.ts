// /api/v1/auth/*: Registrierung per Einladung, Anmeldung, Abmelden, Token-Erneuerung, Step-up. Fachlogik liegt in src/auth/.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { finishPasskeyLogin, finishPasskeyStepUp, findAccountById, loginWithPassword, loginWithRecoveryCode, startPasskeyLogin, startPasskeyStepUp, stepUpWithCode } from '../auth/login.js';
import { logoutCurrent, logoutEverywhere } from '../auth/account.js';
import { lookupInvite } from '../auth/invites.js';
import { finishPasskeyRegistration, finishPasswordRegistration, startPasskeyRegistration, startPasswordRegistration } from '../auth/register.js';
import { refreshSession } from '../auth/sessions.js';
import type { Auth } from '../auth/service.js';
import { AppError } from '../errors.js';
import type { Config } from '../config.js';
import {
  authenticationResponseSchema,
  boundedString,
  clearCookie,
  clientSchema,
  codeSchema,
  deviceSchema,
  displayNameSchema,
  labelSchema,
  passwordSchema,
  emailSchema,
  meta,
  parse,
  pinSchema,
  registrationResponseSchema,
  sessionResponse,
  strictLimit,
  uuid,
} from './util.js';

const tokenSchema = boundedString(16, 128);

const identity = {
  token: tokenSchema,
  pin: pinSchema.optional(),
  email: emailSchema.optional(),
  displayName: displayNameSchema.optional(),
};

async function userBody(auth: Auth, userId: string) {
  const a = await findAccountById(auth.ctx, userId);
  return a ? { id: a.userId, email: a.email, displayName: a.displayName, colorIndex: a.colorIndex, role: a.role, status: a.status } : null;
}

export function registerAuthRoutes(app: FastifyInstance, config: Config, auth: Auth): void {
  const ctx = auth.ctx;
  const strikt = strictLimit(config);

  // ----- Einladung einlösen: Token immer im Body (nie in der URL) -----
  app.post('/api/v1/auth/invites/lookup', strikt, async (req) => {
    const { token } = parse(z.object({ token: tokenSchema }).strict(), req.body);
    const l = await lookupInvite(ctx, token, meta(req));
    return { invite: l };
  });

  app.post('/api/v1/auth/invites/passkey/options', strikt, async (req) => {
    const body = parse(z.object(identity).strict(), req.body);
    return startPasskeyRegistration(ctx, body, meta(req));
  });

  app.post('/api/v1/auth/invites/passkey/complete', strikt, async (req, reply) => {
    const body = parse(
      z.object({ challengeId: uuid, response: registrationResponseSchema, client: clientSchema, device: deviceSchema.optional(), label: labelSchema.optional() }).strict(),
      req.body,
    );
    const r = await finishPasskeyRegistration(ctx, body, meta(req));
    return { member: r.member, status: r.status, recoveryCodes: r.recoveryCodes, ...(r.session ? { session: sessionResponse(ctx, reply, r.session) } : {}) };
  });

  app.post('/api/v1/auth/invites/password/start', strikt, async (req) => {
    const body = parse(z.object({ ...identity, password: passwordSchema }).strict(), req.body);
    return startPasswordRegistration(ctx, body, meta(req));
  });

  app.post('/api/v1/auth/invites/password/complete', strikt, async (req, reply) => {
    const body = parse(z.object({ challengeId: uuid, code: codeSchema, client: clientSchema, device: deviceSchema.optional() }).strict(), req.body);
    const r = await finishPasswordRegistration(ctx, body, meta(req));
    return { member: r.member, status: r.status, recoveryCodes: r.recoveryCodes, ...(r.session ? { session: sessionResponse(ctx, reply, r.session) } : {}) };
  });

  // ----- Anmeldung -----
  app.post('/api/v1/auth/login/passkey/options', strikt, async (req) => startPasskeyLogin(ctx, meta(req)));

  app.post('/api/v1/auth/login/passkey/verify', strikt, async (req, reply) => {
    const body = parse(z.object({ challengeId: uuid, response: authenticationResponseSchema, client: clientSchema, device: deviceSchema.optional() }).strict(), req.body);
    const est = await finishPasskeyLogin(ctx, body, meta(req));
    return { user: await userBody(auth, est.userId), session: sessionResponse(ctx, reply, est) };
  });

  app.post('/api/v1/auth/login/password', strikt, async (req, reply) => {
    const body = parse(
      z
        .object({
          email: emailSchema,
          password: passwordSchema,
          totp: codeSchema.optional(),
          recoveryCode: boundedString(8, 40).optional(),
          client: clientSchema,
          device: deviceSchema.optional(),
        })
        .strict(),
      req.body,
    );
    const est = await loginWithPassword(ctx, body, meta(req));
    return { user: await userBody(auth, est.userId), session: sessionResponse(ctx, reply, est) };
  });

  app.post('/api/v1/auth/login/recovery', strikt, async (req, reply) => {
    const body = parse(z.object({ email: emailSchema, code: boundedString(8, 40), client: clientSchema, device: deviceSchema.optional() }).strict(), req.body);
    const r = await loginWithRecoveryCode(ctx, body, meta(req));
    return { user: await userBody(auth, r.session.userId), session: sessionResponse(ctx, reply, r.session), recoveryCodesRemaining: r.remainingCodes };
  });

  // ----- Token erneuern (App) -----
  app.post('/api/v1/auth/refresh', strikt, async (req, reply) => {
    const body = parse(z.object({ refreshToken: tokenSchema, deviceId: uuid }).strict(), req.body);
    const { established } = await refreshSession(ctx, body, meta(req));
    return { session: sessionResponse(ctx, reply, established) };
  });

  // ----- Abmelden -----
  app.post('/api/v1/auth/logout', strikt, async (req, reply) => {
    const p = await auth.authenticate(req);
    // ohne gültige Sitzung ist Abmelden ein No-op (Cookie wird trotzdem gelöscht)
    if (p) await logoutCurrent(ctx, p, meta(req));
    clearCookie(reply);
    return { ok: true };
  });

  app.post('/api/v1/auth/logout-all', strikt, async (req, reply) => {
    const p = await auth.requireSession(req);
    await logoutEverywhere(ctx, p, meta(req));
    clearCookie(reply);
    return { ok: true };
  });

  // ----- Step-up: erneute Bestätigung per Passkey, TOTP oder Wiederherstellungs-Code -----
  app.post('/api/v1/auth/step-up/passkey/options', strikt, async (req) => startPasskeyStepUp(ctx, await auth.requireSession(req)));

  app.post('/api/v1/auth/step-up/passkey/verify', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ challengeId: uuid, response: authenticationResponseSchema }).strict(), req.body);
    return { stepUpAt: await finishPasskeyStepUp(ctx, p, body, meta(req)) };
  });

  app.post('/api/v1/auth/step-up/code', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ totp: codeSchema.optional(), recoveryCode: boundedString(8, 40).optional() }).strict(), req.body);
    if (!body.totp && !body.recoveryCode) throw new AppError(400, 'invalid_request');
    return { stepUpAt: await stepUpWithCode(ctx, p, body, meta(req)) };
  });
}
