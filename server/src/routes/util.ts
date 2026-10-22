import type { AuthenticationResponseJSON, RegistrationResponseJSON } from '@simplewebauthn/server';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { RequestMeta } from '../auth/context.js';
import { clearedSessionCookie, sessionCookie, type Established } from '../auth/sessions.js';
import type { AuthContext } from '../auth/context.js';
import type { Config } from '../config.js';
import { isCanonicalAuthKey } from '../auth/authkey.js';
import { AppError } from '../errors.js';

// NUL (\u0000) lässt PostgreSQL bei text/jsonb mit einem Fehler scheitern (500), ein einzelnes Surrogat (z. B. \ud800) ist kein
// gültiges Unicode und verfälscht sich beim Speichern. Beides wird in JEDEM Text abgelehnt.
// eslint-disable-next-line no-control-regex
const BAD_TEXT = /\u0000|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;

/** true, wenn der Text NUL oder ein einzelnes Surrogat enthält. */
export const hasBadText = (s: string): boolean => BAD_TEXT.test(s);

/** Durchsucht Werte und Schlüssel beliebig verschachtelter Eingaben (ohne Rekursion, damit tiefe Verschachtelung nichts sprengt). */
function containsBadText(root: unknown): boolean {
  const stack: unknown[] = [root];
  while (stack.length > 0) {
    const v = stack.pop();
    if (typeof v === 'string') {
      if (hasBadText(v)) return true;
    } else if (Array.isArray(v)) {
      stack.push(...v);
    } else if (typeof v === 'object' && v !== null) {
      for (const [k, x] of Object.entries(v)) {
        if (hasBadText(k)) return true;
        stack.push(x);
      }
    }
  }
  return false;
}

/** Text ohne NUL und ohne einzelne Surrogate. */
export const safeString = () => z.string().refine((s) => !hasBadText(s), 'Ungültige Zeichen');

/** Eingabe prüfen: bei Fehlern wirft zod, der Fehlerhandler antwortet generisch mit 400. Ungültige Zeichen in irgendeinem Text: 400. */
export function parse<S extends z.ZodType>(schema: S, data: unknown): z.infer<S> {
  if (containsBadText(data)) throw new AppError(400, 'invalid_request');
  return schema.parse(data ?? {});
}

export const meta = (req: FastifyRequest): RequestMeta => ({ ip: req.ip, userAgent: req.headers['user-agent'] });

/** Strengere Grenze für Anmeldung, 2FA, Einladungen einlösen und Tickets. */
export const strictLimit = (config: Config) => ({ config: { rateLimit: { max: config.authRateLimitMax, timeWindow: '1 minute' } } });

export const uuid = z.string().uuid();
export const idParams = z.object({ id: uuid }).strict();

export const text = (max: number) => safeString().pipe(z.string().trim().min(1).max(max));

export const deviceSchema = z
  .object({
    id: uuid.optional(),
    name: text(60),
    platform: z.enum(['android', 'ios', 'web', 'windows', 'linux', 'macos']),
    appVersion: safeString().pipe(z.string().trim().max(32)).optional(),
  })
  .strict();

export const clientSchema = z.enum(['web', 'app']).default('web');
export const emailSchema = safeString().pipe(z.string().trim().email().max(254));
/** Optionale Bezeichnung (z. B. eines Passkeys). */
export const labelSchema = safeString().pipe(z.string().trim().max(60));
/** Passwort: Länge zählt (Zeichen), sonst keine Regeln. */
export const passwordSchema = safeString().pipe(z.string().min(1).max(256));
/** Abgeleiteter Anmelde-Schlüssel (32 Byte, Base64url, kanonisch); ersetzt das Klartext-Passwort, siehe auth/authkey.ts. */
export const authKeySchema = z.string().refine(isCanonicalAuthKey, 'invalid');
/** Felder "Klartext-Passwort ODER authKey"; ob genau eins gesetzt ist und ob das Verfahren erlaubt ist, prüft assertPasswordInputAllowed. */
export const passwordOrAuthKey = { password: passwordSchema.optional(), authKey: authKeySchema.optional() };
/** Code/Token als Text mit fester Längengrenze. */
export const boundedString = (min: number, max: number) => safeString().pipe(z.string().min(min).max(max));
export const displayNameSchema = text(60);
/** 32 Byte als Base64url ohne Auffüllzeichen (43 Zeichen, kanonisch): öffentliche Schlüssel, Suchkennung der Übertragung. */
export const b64urlKey = z
  .string()
  .regex(/^[A-Za-z0-9_-]{43}$/)
  .refine((s) => Buffer.from(s, 'base64url').toString('base64url') === s);
/** Undurchsichtiger verschlüsselter Blob (Base64url) mit Längengrenze. */
export const b64urlBlob = (max: number) => z.string().min(32).max(max).regex(/^[A-Za-z0-9_-]+$/);
/** Wie b64urlBlob, aber mit Mindestlänge (Format der Passwort-Sicherung: Kopf, Nonce, Tag und Schlüssel). */
export const b64urlBlobMin = (min: number, max: number) => z.string().min(min).max(max).regex(/^[A-Za-z0-9_-]+$/);
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
/** Die PRF-Ausgabe des Passkeys (Passkey-Sicherung) darf den Server nie erreichen: die App entfernt sie, und der Server verwirft sie hier noch einmal (Defense in Depth), bevor sie irgendwo landen könnte. */
const ohnePrf = <T extends { clientExtensionResults: Record<string, unknown> }>(v: T): T => {
  const { prf: _prf, ...rest } = v.clientExtensionResults;
  return { ...v, clientExtensionResults: rest };
};
export const registrationResponseSchema = webauthnResponse.transform((v) => ohnePrf(v) as unknown as RegistrationResponseJSON);
export const authenticationResponseSchema = webauthnResponse.transform((v) => ohnePrf(v) as unknown as AuthenticationResponseJSON);

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
