// Kryptografische Bausteine der Anmeldung. Alle Zufallswerte kommen aus dem CSPRNG von Node (node:crypto).
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  hkdfSync,
  randomBytes,
  randomInt,
  timingSafeEqual,
} from 'node:crypto';

/** Zufälliges Token (Standard 256 Bit) als base64url ohne Auffüllung. */
export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString('base64url');
}

/** SHA-256 als Hex. Für Tokens mit ≥128 Bit Zufall genügt ein schneller Hash (nicht für Passwörter oder PINs). */
export function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

/** Vergleich in konstanter Zeit (beliebige Längen). */
export function safeEqual(a: string, b: string): boolean {
  const ha = createHash('sha256').update(a, 'utf8').digest();
  const hb = createHash('sha256').update(b, 'utf8').digest();
  return timingSafeEqual(ha, hb);
}

/** Teilschlüssel für einen Zweck, abgeleitet aus dem Hauptschlüssel (HKDF-SHA256). */
export class KeyRing {
  private readonly cache = new Map<string, Buffer>();
  constructor(private readonly master: Buffer) {}

  derive(purpose: string): Buffer {
    let key = this.cache.get(purpose);
    // Domänen-Label der Schlüsselableitung: bewusst NICHT umbenannt (Projekt hieß früher lx-familie); eine Änderung machte vorhandene HMACs und TOTP-Geheimnisse ungültig.
    if (!key) {
      key = Buffer.from(hkdfSync('sha256', this.master, Buffer.alloc(0), `lx-familie/${purpose}`, 32));
      this.cache.set(purpose, key);
    }
    return key;
  }

  hmac(purpose: string, data: string): string {
    return createHmac('sha256', this.derive(purpose)).update(data, 'utf8').digest('hex');
  }

  /** AES-256-GCM; `aad` bindet den Geheimtext an seinen Verwendungsort (z. B. die Benutzer-ID). */
  encrypt(purpose: string, plaintext: string, aad: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.derive(purpose), iv);
    cipher.setAAD(Buffer.from(aad, 'utf8'));
    const ct = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    return `v1.${Buffer.concat([iv, cipher.getAuthTag(), ct]).toString('base64url')}`;
  }

  decrypt(purpose: string, sealed: string, aad: string): string {
    const [version, body] = sealed.split('.');
    if (version !== 'v1' || !body) throw new Error('Unbekanntes Format');
    const raw = Buffer.from(body, 'base64url');
    if (raw.length < 12 + 16) throw new Error('Zu kurz');
    const decipher = createDecipheriv('aes-256-gcm', this.derive(purpose), raw.subarray(0, 12));
    decipher.setAAD(Buffer.from(aad, 'utf8'));
    decipher.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString('utf8');
  }
}

/** Sechsstellige PIN (führende Nullen möglich), gleichverteilt. */
export function randomPin(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, '0');
}

// ohne leicht verwechselbare Zeichen (0/O, 1/I/L)
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';

/** Wiederherstellungs-Code im Format XXXX-XXXX-XXXX-XXXX (16 Zeichen, rund 78 Bit). */
export function randomRecoveryCode(): string {
  let out = '';
  for (let i = 0; i < 16; i++) {
    if (i > 0 && i % 4 === 0) out += '-';
    out += CODE_ALPHABET[randomInt(0, CODE_ALPHABET.length)];
  }
  return out;
}

/** Normalisiert die Eingabe eines Wiederherstellungs-Codes (Groß-/Kleinschreibung, Striche, Leerzeichen). */
export function normalizeRecoveryCode(input: string): string {
  return input.toUpperCase().replace(/[^A-Z0-9]/g, '');
}
