// Bausteine ohne Datenbank: Schlüsselableitung (Known-Answer), IP-Normalisierung, Fehler-Serializer, Eingabe-Zeichen, Konfiguration.
import { createHmac, hkdfSync } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { KDF_DOMAIN, KeyRing } from '../src/auth/crypto.js';
import { loadConfig } from '../src/config.js';
import { serializeErr } from '../src/log.js';
import { normalizeIp } from '../src/net.js';
import { deviceSchema, displayNameSchema, emailSchema, hasBadText, labelSchema, parse, passwordSchema } from '../src/routes/util.js';
import { TEST_KEY } from './helpers.js';

describe('Schlüsselableitung', () => {
  // fester Hauptschlüssel (0x00..0x1f); die Erwartungswerte stammen aus einer unabhängigen HKDF-/HMAC-Rechnung mit dem Label "lx-fampad/<Zweck>"
  const master = Buffer.from(Array.from({ length: 32 }, (_, i) => i));

  it('KDF_DOMAIN ist lx-fampad (nie ändern: sonst werden alle gespeicherten HMACs und TOTP-Geheimnisse ungültig)', () => {
    expect(KDF_DOMAIN).toBe('lx-fampad');
  });

  it('Known-Answer: fester Schlüssel + Zweck ergeben feste Bytes', () => {
    const ring = new KeyRing(master);
    expect(ring.derive('invite-pin').toString('hex')).toBe('2dd8c42ae8bee9bc2f0158d34b91ffdd886f7b4d26ba382efeacf2040ee9a542');
    expect(ring.hmac('recovery', 'ABCD')).toBe('8e4e7b290d6aac50e77b8c1bf0f351977d0aceb07bd5a942b21b85caa59bc666');
  });

  it('das Label ist "lx-fampad/<Zweck>" und trennt die Zwecke', () => {
    const ring = new KeyRing(master);
    const expected = Buffer.from(hkdfSync('sha256', master, Buffer.alloc(0), 'lx-fampad/recovery', 32));
    expect(ring.derive('recovery').equals(expected)).toBe(true);
    expect(ring.derive('recovery').equals(ring.derive('invite-pin'))).toBe(false);
    expect(ring.hmac('recovery', 'x')).toBe(createHmac('sha256', expected).update('x').digest('hex'));
    // das alte Label liefert andere Bytes
    expect(ring.derive('recovery').equals(Buffer.from(hkdfSync('sha256', master, Buffer.alloc(0), 'lx-familie/recovery', 32)))).toBe(false);
  });
});

describe('IP-Normalisierung (IPv6 auf /64)', () => {
  it.each([
    ['203.0.113.10', '203.0.113.10'],
    ['::ffff:203.0.113.10', '203.0.113.10'],
    ['::ffff:cb00:710a', '203.0.113.10'],
    ['2001:db8:1:2::1', '2001:db8:1:2::/64'],
    ['2001:0db8:0001:0002:aaaa:bbbb:cccc:dddd', '2001:db8:1:2::/64'],
    ['2001:DB8:1:2:ffff:ffff:ffff:ffff', '2001:db8:1:2::/64'],
    ['2001:db8:1:3::1', '2001:db8:1:3::/64'],
    ['fe80::1%eth0', 'fe80:0:0:0::/64'],
    ['::1', '0:0:0:0::/64'],
    [undefined, 'unbekannt'],
    ['kein-ip', 'kein-ip'],
  ])('%s -> %s', (input, expected) => {
    expect(normalizeIp(input)).toBe(expected);
  });
});

describe('Fehler-Serializer', () => {
  const drizzleLike = () =>
    Object.assign(new Error('Failed query: insert into "users" values ($1, $2)\nparams: geheim@example.org,abcdef-hash'), {
      name: 'DrizzleQueryError',
      query: 'insert into "users" values ($1, $2)',
      params: ['geheim@example.org', 'abcdef-hash'],
      cause: Object.assign(new Error('unsupported Unicode escape sequence'), { name: 'error', code: '22P05' }),
    });

  it('Drizzle-Fehler: Name, Code, Ursache und Stack, aber weder Meldung noch Parameter', () => {
    const out = serializeErr(drizzleLike());
    const text = JSON.stringify(out);
    expect(text).not.toContain('geheim@example.org');
    expect(text).not.toContain('abcdef-hash');
    expect(text).not.toContain('Failed query');
    expect(out.type).toBe('DrizzleQueryError');
    expect(out.cause).toMatchObject({ code: '22P05', message: 'unsupported Unicode escape sequence' });
    expect(out.stack).toMatch(/^DrizzleQueryError\n\s+at /);
  });

  it('normale Fehler behalten Meldung, Code, Stack und Ursache', () => {
    const out = serializeErr(Object.assign(new Error('kaputt', { cause: new Error('darunter') }), { code: 'E_TEST' }));
    expect(out).toMatchObject({ type: 'Error', message: 'kaputt', code: 'E_TEST' });
    expect(out.stack).toContain('kaputt');
    expect(out.cause).toMatchObject({ message: 'darunter' });
  });

  it('Nicht-Fehler (Text) werden eingepackt, nichts wirft', () => {
    expect(serializeErr('nur text')).toMatchObject({ message: 'nur text' });
    expect(serializeErr(undefined)).toMatchObject({ type: 'Error' });
  });
});

describe('Text-Eingaben: NUL und einzelne Surrogate', () => {
  it.each(['a\u0000b', 'a\ud800b', '\udc00', 'ende\ud83d'])('lehnt %j ab', (bad) => {
    expect(hasBadText(bad)).toBe(true);
    for (const schema of [displayNameSchema, emailSchema, labelSchema, passwordSchema]) expect(schema.safeParse(bad).success).toBe(false);
    expect(deviceSchema.safeParse({ name: bad, platform: 'web' }).success).toBe(false);
    expect(deviceSchema.safeParse({ name: 'ok', platform: 'web', appVersion: bad }).success).toBe(false);
    expect(() => parse(deviceSchema, { name: 'ok', platform: 'web', extra: { tief: [bad] } })).toThrow();
    expect(() => parse(deviceSchema, { name: 'ok', platform: 'web', [`k${bad}`]: 1 })).toThrow();
  });

  it('erlaubt normale Texte, Umlaute und gültige Surrogatpaare (Emoji)', () => {
    for (const ok of ['Mama', 'Jürgen Müller', 'Kind 😀', '日本語']) {
      expect(hasBadText(ok)).toBe(false);
      expect(displayNameSchema.parse(ok)).toBe(ok);
    }
  });
});

describe('Konfiguration', () => {
  const base = { NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY };
  it('MIN_PASSWORD_LENGTH darf nicht unter 10 liegen', () => {
    expect(() => loadConfig({ ...base, MIN_PASSWORD_LENGTH: '9' })).toThrow(/MIN_PASSWORD_LENGTH/);
    expect(() => loadConfig({ ...base, MIN_PASSWORD_LENGTH: '1' })).toThrow(/MIN_PASSWORD_LENGTH/);
    expect(loadConfig({ ...base, MIN_PASSWORD_LENGTH: '10' }).auth.minPasswordLength).toBe(10);
    expect(loadConfig(base).auth.minPasswordLength).toBe(12);
  });

  it('die Sperre ist auf höchstens 90 Sekunden begrenzt', () => {
    expect(loadConfig(base).auth.lockoutMaxDelaySec).toBe(90);
  });
});
