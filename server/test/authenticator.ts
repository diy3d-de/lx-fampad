// Simulierter WebAuthn-Authenticator für Tests (ES256, Attestation "none"): erzeugt Registrierungs- und Anmeldeantworten,
// die @simplewebauthn/server wie die eines echten Geräts prüft (inkl. rpIdHash, Flags, signCount und Signatur).
import { createHash, generateKeyPairSync, randomBytes, sign, type KeyObject } from 'node:crypto';
import type {
  AuthenticationResponseJSON,
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON,
  RegistrationResponseJSON,
} from '@simplewebauthn/server';

// ---- minimaler CBOR-Encoder (Ganzzahlen, Bytes, Text, Maps) ----
type Cbor = number | string | Uint8Array | Map<Cbor, Cbor>;

function head(major: number, n: number): Buffer {
  if (n < 24) return Buffer.from([(major << 5) | n]);
  if (n < 256) return Buffer.from([(major << 5) | 24, n]);
  if (n < 65536) return Buffer.from([(major << 5) | 25, n >> 8, n & 255]);
  throw new Error('zu groß');
}

function cbor(v: Cbor): Buffer {
  if (typeof v === 'number') return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (typeof v === 'string') return Buffer.concat([head(3, Buffer.byteLength(v)), Buffer.from(v)]);
  if (v instanceof Uint8Array) return Buffer.concat([head(2, v.length), v]);
  return Buffer.concat([head(5, v.size), ...[...v].flatMap(([k, val]) => [cbor(k), cbor(val)])]);
}

const b64 = (b: Uint8Array) => Buffer.from(b).toString('base64url');
const sha256 = (b: Uint8Array | string) => createHash('sha256').update(b).digest();

export class TestAuthenticator {
  readonly credentialId = randomBytes(32);
  readonly privateKey: KeyObject;
  private readonly x: Buffer;
  private readonly y: Buffer;
  counter: number;
  userHandle: Buffer | null = null;
  /** true: synchronisierter Passkey (BE- und BS-Flag gesetzt, multiDevice); Standard: an ein Gerät gebunden (singleDevice). */
  multiDevice = false;
  /** Mit multiDevice: BS-Flag (aktuell gesichert/synchronisiert); false = BE ohne BS (synchronisierbar, aber noch nicht gesichert). */
  backupState = true;

  constructor(
    private readonly rpId = 'familie.lx-labs.dev',
    private readonly origin = 'https://familie.lx-labs.dev',
    opts: { initialCounter?: number } = {},
  ) {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    this.privateKey = privateKey;
    const jwk = publicKey.export({ format: 'jwk' });
    this.x = Buffer.from(jwk.x ?? '', 'base64url');
    this.y = Buffer.from(jwk.y ?? '', 'base64url');
    this.counter = opts.initialCounter ?? 1;
  }

  get id(): string {
    return b64(this.credentialId);
  }

  private authData(flags: number, counter: number, attested: boolean): Buffer {
    const c = Buffer.alloc(4);
    c.writeUInt32BE(counter);
    const parts: Buffer[] = [sha256(this.rpId), Buffer.from([flags]), c];
    if (attested) {
      const cose = cbor(
        new Map<Cbor, Cbor>([
          [1, 2],
          [3, -7],
          [-1, 1],
          [-2, this.x],
          [-3, this.y],
        ]),
      );
      const len = Buffer.alloc(2);
      len.writeUInt16BE(this.credentialId.length);
      parts.push(Buffer.alloc(16), len, Buffer.from(this.credentialId), cose);
    }
    return Buffer.concat(parts);
  }

  /** Antwort auf navigator.credentials.create(). `origin` überschreibbar für Negativtests. */
  register(options: PublicKeyCredentialCreationOptionsJSON, opts: { origin?: string; userVerified?: boolean } = {}): RegistrationResponseJSON {
    this.userHandle = Buffer.from(options.user.id, 'base64url');
    const clientData = JSON.stringify({ type: 'webauthn.create', challenge: options.challenge, origin: opts.origin ?? this.origin, crossOrigin: false });
    const uv = opts.userVerified === false ? 0 : 0x04;
    const authData = this.authData(0x01 | uv | 0x40 | (this.multiDevice ? (this.backupState ? 0x18 : 0x08) : 0), this.counter, true);
    const attestationObject = cbor(new Map<Cbor, Cbor>([['fmt', 'none'], ['attStmt', new Map()], ['authData', authData]]));
    return {
      id: this.id,
      rawId: this.id,
      type: 'public-key',
      response: { clientDataJSON: b64(Buffer.from(clientData)), attestationObject: b64(attestationObject), transports: ['internal'] },
      clientExtensionResults: {},
      authenticatorAttachment: 'platform',
    };
  }

  /** Antwort auf navigator.credentials.get(). Der signCount steigt bei jedem Aufruf (außer `counter` wird vorgegeben). */
  assert(options: PublicKeyCredentialRequestOptionsJSON, opts: { origin?: string; counter?: number; userVerified?: boolean } = {}): AuthenticationResponseJSON {
    if (opts.counter === undefined) this.counter += 1;
    else this.counter = opts.counter;
    const clientData = Buffer.from(JSON.stringify({ type: 'webauthn.get', challenge: options.challenge, origin: opts.origin ?? this.origin, crossOrigin: false }));
    const uv = opts.userVerified === false ? 0 : 0x04;
    const authData = this.authData(0x01 | uv | (this.multiDevice ? (this.backupState ? 0x18 : 0x08) : 0), this.counter, false);
    const signature = sign('sha256', Buffer.concat([authData, sha256(clientData)]), this.privateKey);
    return {
      id: this.id,
      rawId: this.id,
      type: 'public-key',
      response: {
        clientDataJSON: b64(clientData),
        authenticatorData: b64(authData),
        signature: b64(signature),
        ...(this.userHandle ? { userHandle: b64(this.userHandle) } : {}),
      },
      clientExtensionResults: {},
      authenticatorAttachment: 'platform',
    };
  }
}
