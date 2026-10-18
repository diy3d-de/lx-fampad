// WebAuthn / Passkeys über @simplewebauthn/server. Die Challenge liegt serverseitig (challenges.ts), nie im Client-Zustand.
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
  type AuthenticationResponseJSON,
  type PublicKeyCredentialCreationOptionsJSON,
  type PublicKeyCredentialRequestOptionsJSON,
  type RegistrationResponseJSON,
  type WebAuthnCredential,
} from '@simplewebauthn/server';
import type { AuthContext } from './context.js';

/** Klassische Algorithmen: ES256 (-7) und RS256 (-257); keine exotischen COSE-Algorithmen. */
export const SUPPORTED_ALGORITHMS = [-7, -257];

/** user.id in WebAuthn: die 16 Byte der Benutzer-UUID (kein Name, keine E-Mail). */
export const userHandle = (userId: string): Uint8Array<ArrayBuffer> =>
  new Uint8Array(Buffer.from(userId.replaceAll('-', ''), 'hex')) as Uint8Array<ArrayBuffer>;

export const userHandleString = (userId: string): string => Buffer.from(userHandle(userId)).toString('base64url');

function expectedOrigins(ctx: AuthContext): string[] {
  return [new URL(ctx.config.publicUrl).origin, ...ctx.config.auth.extraOrigins];
}

export interface PasskeyRef {
  externalId: string;
  transports?: string[] | null;
}

export function registrationOptions(
  ctx: AuthContext,
  input: { userId: string; accountName: string; displayName: string; existing: PasskeyRef[] },
): Promise<PublicKeyCredentialCreationOptionsJSON> {
  return generateRegistrationOptions({
    rpName: ctx.config.auth.rpName,
    rpID: ctx.config.auth.rpId,
    userName: input.accountName,
    userDisplayName: input.displayName,
    userID: userHandle(input.userId),
    attestationType: 'none',
    supportedAlgorithmIDs: SUPPORTED_ALGORITHMS,
    authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
    excludeCredentials: input.existing.map((c) => ({ id: c.externalId, ...(c.transports ? { transports: c.transports } : {}) })),
    timeout: ctx.config.auth.challengeTtlSec * 1000,
  });
}

export interface VerifiedRegistration {
  externalId: string;
  publicKey: string;
  counter: number;
  transports: string[] | null;
}

export async function checkRegistration(
  ctx: AuthContext,
  response: RegistrationResponseJSON,
  expectedChallenge: string,
): Promise<VerifiedRegistration | null> {
  try {
    const result = await verifyRegistrationResponse({
      response,
      expectedChallenge,
      expectedOrigin: expectedOrigins(ctx),
      expectedRPID: ctx.config.auth.rpId,
      requireUserVerification: true,
      supportedAlgorithmIDs: SUPPORTED_ALGORITHMS,
    });
    if (!result.verified) return null;
    const cred = result.registrationInfo.credential;
    return {
      externalId: cred.id,
      publicKey: Buffer.from(cred.publicKey).toString('base64url'),
      counter: cred.counter,
      transports: cred.transports ? [...cred.transports] : null,
    };
  } catch (err) {
    ctx.log.warn({ err: (err as Error).message }, 'Passkey-Registrierung abgelehnt');
    return null;
  }
}

export function authenticationOptions(ctx: AuthContext, allow?: PasskeyRef[]): Promise<PublicKeyCredentialRequestOptionsJSON> {
  return generateAuthenticationOptions({
    rpID: ctx.config.auth.rpId,
    userVerification: 'required',
    timeout: ctx.config.auth.challengeTtlSec * 1000,
    ...(allow ? { allowCredentials: allow.map((c) => ({ id: c.externalId, ...(c.transports ? { transports: c.transports } : {}) })) } : {}),
  });
}

export interface StoredPasskey {
  externalId: string;
  publicKey: string;
  signCount: number;
  transports: string[] | null;
}

export type AuthenticationCheck = { ok: true; newCounter: number } | { ok: false; counterRegression: boolean };

export async function checkAuthentication(
  ctx: AuthContext,
  response: AuthenticationResponseJSON,
  expectedChallenge: string,
  stored: StoredPasskey,
): Promise<AuthenticationCheck> {
  const credential: WebAuthnCredential = {
    id: stored.externalId,
    publicKey: new Uint8Array(Buffer.from(stored.publicKey, 'base64url')) as Uint8Array<ArrayBuffer>,
    counter: stored.signCount,
    ...(stored.transports ? { transports: stored.transports as WebAuthnCredential['transports'] } : {}),
  };
  try {
    const result = await verifyAuthenticationResponse({
      response,
      expectedChallenge,
      expectedOrigin: expectedOrigins(ctx),
      expectedRPID: ctx.config.auth.rpId,
      credential,
      requireUserVerification: true,
    });
    if (!result.verified) return { ok: false, counterRegression: false };
    return { ok: true, newCounter: result.authenticationInfo.newCounter };
  } catch (err) {
    const message = (err as Error).message ?? '';
    // die Bibliothek meldet einen nicht steigenden signCount (geklonter Authenticator) mit "counter" im Text
    return { ok: false, counterRegression: /counter/i.test(message) };
  }
}
