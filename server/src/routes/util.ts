import type { AuthenticationResponseJSON, RegistrationResponseJSON } from '@simplewebauthn/server';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { RequestMeta } from '../auth/context.js';
import { clearedSessionCookie, sessionCookie, type Established } from '../auth/sessions.js';
import type { AuthContext } from '../auth/context.js';
import type { Config } from '../config.js';

/** Eingabe prüfen: bei Fehlern wirft zod, der Fehlerhandler antwortet generisch mit 400. */
export function parse<S extends z.ZodType>(schema: S, data: unknown): z.infer<S> {
  return schema.parse(data ?? {});
}

export const meta = (req: FastifyRequest): RequestMeta => ({ ip: req.ip, userAgent: req.headers['user-agent'] });

/** Strengere Grenze für Anmeldung, 2FA, Einladungen einlösen und Tickets. */
export const strictLimit = (config: Config) => ({ config: { rateLimit: { max: config.authRateLimitMax, timeWindow: '1 minute' } } });

export const uuid = z.string().uuid();
export const idParams = z.object({ id: uuid }).strict();

const text = (max: number) => z.string().trim().min(1).max(max);

export const deviceSchema = z
  .object({
    id: uuid.optional(),
    name: text(60),
    platform: z.enum(['android', 'ios', 'web', 'windows', 'linux', 'macos']),
    appVersion: z.string().trim().max(32).optional(),
  })
  .strict();

export const clientSchema = z.enum(['web', 'app']).default('web');
export const emailSchema = z.string().trim().email().max(254);
export const displayNameSchema = text(60);
export const pinSchema = z.string().regex(/^\d{6}$/);
export const codeSchema = z.string().regex(/^\d{6}$/);

/** WebAuthn-Antworten werden von der Bibliothek geprüft; hier nur Grundform und Größe. */
const webauthnResponse = z
  .object({
    id: z.string().min(1).max(1024),
    rawId: z.string().min(1).max(1024),
    type: z.literal('public-key'),
    response: z.record(z.string(), z.unknown()),
    clientExtensionResults: z.record(z.string(), z.unknown()).default({}),
    authenticatorAttachment: z.string().max(32).optional(),
  })
  .passthrough();
export const registrationResponseSchema = webauthnResponse.transform((v) => v as unknown as RegistrationResponseJSON);
export const authenticationResponseSchema = webauthnResponse.transform((v) => v as unknown as AuthenticationResponseJSON);

/** Setzt bei Web-Sitzungen das Cookie und baut die Antwort; die App bekommt Access- und Refresh-Token im Body. */
export function sessionResponse(ctx: AuthContext, reply: FastifyReply, est: Established): Record<string, unknown> {
  if (est.kind === 'web') {
    reply.header('set-cookie', sessionCookie(est.token, est.expiresAt, ctx.now()));
    return { kind: 'web', csrfToken: est.csrfToken, expiresAt: est.expiresAt, deviceId: est.deviceId };
  }
  return {
    kind: 'app',
    accessToken: est.accessToken,
    accessExpiresAt: est.accessExpiresAt,
    refreshToken: est.token,
    refreshExpiresAt: est.expiresAt,
    deviceId: est.deviceId,
  };
}

export const clearCookie = (reply: FastifyReply) => void reply.header('set-cookie', clearedSessionCookie());
