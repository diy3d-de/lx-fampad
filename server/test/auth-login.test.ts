// Anmeldung, Sitzungen, Step-up, Sperren, Mandantengrenze, Zurücksetzen und Aufräumen (PGlite und echtes PostgreSQL).
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { resetByEmail } from '../src/auth/bootstrap.js';
import { runMaintenance } from '../src/auth/maintenance.js';
import { sha256Hex } from '../src/auth/crypto.js';
import * as schema from '../src/db/schema.js';
import { TestAuthenticator } from './authenticator.js';
import { addMember, adminPasskey, adminPassword, auditEvents, backends, Client, ORIGIN, World, type Harness } from './helpers.js';

const DAY = 86_400_000;
const MIN = 60_000;
const PW = 'ein-sehr-langes-passwort-123';

describe.each(backends)('Sitzungen und Anmeldearten ($name)', (backend) => {
  let harness: Harness;
  let world: World;

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db);
  });

  const events = () => auditEvents(world);

  /** Passwort-Login mit frischem TOTP-Zeitschritt (die Uhr springt, damit der Registrierungs-Code nicht erneut gilt). */
  async function passwordLogin(email: string, secret: string, client: Client, extra: Record<string, unknown> = {}) {
    world.advance(31_000);
    const res = await client.post('/api/v1/auth/login/password', { email, password: PW, totp: await world.totp(secret), ...extra });
    if (res.status === 200) client.adopt(res.json.session);
    return res;
  }

  describe('Passwort + TOTP', () => {
    it('meldet an und setzt ein __Host-Cookie (Secure, HttpOnly, SameSite=Strict, ohne Domain)', async () => {
      const a = await adminPassword(world);
      const c = world.client('203.0.113.50');
      const res = await passwordLogin(a.email, a.totpSecret, c);
      expect(res.status).toBe(200);
      const cookie = String(res.headers['set-cookie']);
      expect(cookie).toMatch(/^__Host-lxsid=[A-Za-z0-9_-]{40,}/);
      expect(cookie).toContain('Secure');
      expect(cookie).toContain('HttpOnly');
      expect(cookie).toContain('SameSite=Strict');
      expect(cookie).toContain('Path=/');
      expect(cookie).not.toMatch(/Domain=/i);
      expect(res.json.user).toMatchObject({ email: a.email, role: 'admin' });
      expect(res.headers['cache-control']).toBe('no-store');
      const me = await c.get('/api/v1/me');
      expect(me.status).toBe(200);
      expect(me.json.credentials).toMatchObject({ password: true, totp: true, passkeys: 0 });
    });

    it('speichert Passwort als Argon2id, TOTP-Geheimnis verschlüsselt (nie im Klartext)', async () => {
      const a = await adminPassword(world);
      const creds = await harness.db.select().from(schema.credentials);
      const pw = creds.find((c) => c.type === 'password');
      const totp = creds.find((c) => c.type === 'totp');
      expect(pw?.secret).toMatch(/^\$argon2id\$/);
      expect(pw?.secret).not.toContain(PW);
      expect(totp?.secret).toMatch(/^v1\./);
      expect(totp?.secret).not.toContain(a.totpSecret);
      // der Schlüssel stammt aus der Konfiguration, nicht aus der Datenbank: mit anderem Schlüssel nicht lesbar
      const other = await World.create(harness.db, { AUTH_SECRET_KEY: Buffer.from('anderer-schluessel-fuer-den-test-0123456789abcdef').toString('base64') });
      const row = (await harness.db.select().from(schema.users))[0];
      expect(() => other.auth.ctx.keys.decrypt('totp', totp?.secret ?? '', `totp:${row?.id}`)).toThrow();
      expect(world.auth.ctx.keys.decrypt('totp', totp?.secret ?? '', `totp:${row?.id}`)).toBe(a.totpSecret);
      await other.close();
    });

    it('lehnt zu kurze Passwörter ab (Mindestlänge)', async () => {
      const boot = await world.bootstrap();
      const res = await world.client().post('/api/v1/auth/invites/password/start', { token: boot.token, email: 'a@example.org', displayName: 'A', password: 'kurz' });
      expect(res.status).toBe(400);
      expect(res.json.error).toBe('weak_password');
    });

    it('falscher Code, falsches Passwort und unbekanntes Konto geben dieselbe Antwort', async () => {
      const a = await adminPassword(world);
      world.advance(31_000);
      const good = await world.totp(a.totpSecret);
      const wrongCode = await world.client('203.0.113.61').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: good === '000000' ? '111111' : '000000' });
      const wrongPw = await world.client('203.0.113.62').post('/api/v1/auth/login/password', { email: a.email, password: 'falsch-falsch-falsch', totp: good });
      const unknown = await world.client('203.0.113.63').post('/api/v1/auth/login/password', { email: 'nobody@example.org', password: PW, totp: good });
      for (const r of [wrongCode, wrongPw, unknown]) {
        expect(r.status).toBe(401);
        expect(r.json).toEqual({ error: 'invalid_credentials', message: 'Die Anmeldedaten sind nicht korrekt.' });
        expect(r.headers['set-cookie']).toBeUndefined();
      }
      expect((await events()).filter((e) => e === 'login_failed')).toHaveLength(3);
    });

    it('Replay-Schutz: derselbe TOTP-Code gilt nur einmal (auch parallel)', async () => {
      const a = await adminPassword(world);
      world.advance(31_000);
      const code = await world.totp(a.totpSecret);
      const login = (ip: string) => world.client(ip).post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: code });
      const first = await login('203.0.113.70');
      expect(first.status).toBe(200);
      expect((await login('203.0.113.71')).status).toBe(401);
      // parallel mit dem nächsten Code: genau ein Erfolg
      world.advance(31_000);
      const next = await world.totp(a.totpSecret);
      const two = await Promise.all(['203.0.113.72', '203.0.113.73'].map((ip) => world.client(ip).post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: next })));
      expect(two.map((r) => r.status).sort()).toEqual([200, 401]);
    });

    it('der bei der Einrichtung benutzte Code gilt nicht noch einmal', async () => {
      const a = await adminPassword(world);
      const res = await world.client('203.0.113.74').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(a.totpSecret) });
      expect(res.status).toBe(401);
    });

    it('Wiederherstellungs-Codes: 10 Stück, als HMAC gespeichert, jeder gilt einmal', async () => {
      const a = await adminPassword(world);
      expect(a.recoveryCodes).toHaveLength(10);
      expect(new Set(a.recoveryCodes).size).toBe(10);
      const rows = await harness.db.select().from(schema.recoveryCodes);
      expect(rows).toHaveLength(10);
      for (const code of a.recoveryCodes) {
        expect(rows.some((r) => r.codeHash === sha256Hex(code) || r.codeHash === code)).toBe(false);
        expect(rows.some((r) => r.codeHash === world.auth.ctx.keys.hmac('recovery', code.replaceAll('-', '')))).toBe(true);
      }
      const code = a.recoveryCodes[0] ?? '';
      const c = world.client('203.0.113.80');
      const res = await c.post('/api/v1/auth/login/recovery', { email: a.email, code: code.toLowerCase() });
      expect(res.status).toBe(200);
      expect(res.json.recoveryCodesRemaining).toBe(9);
      expect((await world.client('203.0.113.81').post('/api/v1/auth/login/recovery', { email: a.email, code })).status).toBe(401);
      // Passwort + Wiederherstellungs-Code statt TOTP
      const withPw = await world.client('203.0.113.82').post('/api/v1/auth/login/password', { email: a.email, password: PW, recoveryCode: a.recoveryCodes[1] });
      expect(withPw.status).toBe(200);
      const used = await harness.db.select().from(schema.recoveryCodes);
      expect(used.filter((r) => r.usedAt)).toHaveLength(2);
      expect(await events()).toContain('recovery_code_used');
    });
  });

  describe('Passkey', () => {
    it('Registrierung und Anmeldung mit simuliertem Authenticator; klassische Algorithmen, RP-ID konfigurierbar', async () => {
      const a = await adminPasskey(world);
      const opts = await world.client().post('/api/v1/auth/login/passkey/options');
      expect(opts.json.options.rpId).toBe('familie.lx-labs.dev');
      expect(opts.json.options.userVerification).toBe('required');
      const reg = await world.client().post('/api/v1/auth/invites/passkey/options', { token: 'x'.repeat(43), email: 'x@example.org', displayName: 'X' });
      expect(reg.status).toBe(400);

      const c = world.client('203.0.113.90');
      const res = await world.loginPasskey(c, a.authenticator);
      expect(res.status).toBe(200);
      expect(res.json.user.email).toBe(a.email);
      const cred = (await harness.db.select().from(schema.credentials).where(eq(schema.credentials.type, 'passkey')))[0];
      expect(cred?.signCount).toBe(a.authenticator.counter);
      expect(cred?.externalId).toBe(a.authenticator.id);

      const boot = await world.bootstrap().catch(() => null);
      expect(boot).toBeNull();
    });

    it('Registrierungsoptionen erlauben nur ES256/RS256, verlangen Nutzerprüfung und finden die RP-ID aus der Konfiguration', async () => {
      const w2 = await World.create(harness.db, { WEBAUTHN_RP_ID: 'lx-labs.dev', WEBAUTHN_RP_NAME: 'Test' });
      const boot = await w2.bootstrap();
      const res = await w2.client().post('/api/v1/auth/invites/passkey/options', { token: boot.token, email: 'a@example.org', displayName: 'A' });
      expect(res.status).toBe(200);
      expect(res.json.options.rp).toMatchObject({ id: 'lx-labs.dev', name: 'Test' });
      expect(res.json.options.pubKeyCredParams.map((p: { alg: number }) => p.alg).sort()).toEqual([-257, -7]);
      expect(res.json.options.authenticatorSelection).toMatchObject({ residentKey: 'required', userVerification: 'required' });
      expect(res.json.options.attestation).toBe('none');
      await w2.close();
    });

    it('lehnt Registrierung mit falscher Origin oder ohne Nutzerprüfung ab', async () => {
      const boot = await world.bootstrap();
      for (const opts of [{ origin: 'https://evil.example' }, { userVerified: false }]) {
        const c = world.client();
        const start = await c.post('/api/v1/auth/invites/passkey/options', { token: boot.token, email: 'a@example.org', displayName: 'A' });
        const authn = new TestAuthenticator();
        const done = await c.post('/api/v1/auth/invites/passkey/complete', { challengeId: start.json.challengeId, response: authn.register(start.json.options, opts) });
        expect(done.status).toBe(400);
      }
      expect(await world.count('users')).toBe(0);
    });

    it('Challenge ist einmalig und kurzlebig', async () => {
      const a = await adminPasskey(world);
      const c = world.client('203.0.113.91');
      const opts = await c.post('/api/v1/auth/login/passkey/options');
      const response = a.authenticator.assert(opts.json.options);
      expect((await c.post('/api/v1/auth/login/passkey/verify', { challengeId: opts.json.challengeId, response })).status).toBe(200);
      // dieselbe Antwort noch einmal: Challenge verbraucht
      expect((await c.post('/api/v1/auth/login/passkey/verify', { challengeId: opts.json.challengeId, response })).status).toBe(401);
      // abgelaufene Challenge
      const old = await c.post('/api/v1/auth/login/passkey/options');
      world.advance(6 * MIN);
      expect((await c.post('/api/v1/auth/login/passkey/verify', { challengeId: old.json.challengeId, response: a.authenticator.assert(old.json.options) })).status).toBe(401);
    });

    it('prüft den signCount: ein Rückgang (geklonter Schlüssel) wird abgelehnt und protokolliert', async () => {
      const a = await adminPasskey(world);
      const c = world.client('203.0.113.92');
      expect((await world.loginPasskey(c, a.authenticator)).status).toBe(200);
      const opts = await c.post('/api/v1/auth/login/passkey/options');
      const stale = a.authenticator.assert(opts.json.options, { counter: 1 });
      const res = await c.post('/api/v1/auth/login/passkey/verify', { challengeId: opts.json.challengeId, response: stale });
      expect(res.status).toBe(401);
      expect(await events()).toContain('passkey_counter_regression');
      // der gespeicherte Zähler bleibt unverändert hoch
      const cred = (await harness.db.select().from(schema.credentials).where(eq(schema.credentials.type, 'passkey')))[0];
      expect(cred?.signCount).toBeGreaterThan(1);
    });

    it('lehnt falsche Origin, unbekannte Credentials und fremde Benutzer-Handles generisch ab', async () => {
      const a = await adminPasskey(world);
      const c = world.client('203.0.113.93');
      const opts = await c.post('/api/v1/auth/login/passkey/options');
      const bad = await c.post('/api/v1/auth/login/passkey/verify', { challengeId: opts.json.challengeId, response: a.authenticator.assert(opts.json.options, { origin: 'https://evil.example' }) });
      const stranger = new TestAuthenticator();
      const opts2 = await c.post('/api/v1/auth/login/passkey/options');
      const unknown = await c.post('/api/v1/auth/login/passkey/verify', { challengeId: opts2.json.challengeId, response: stranger.assert(opts2.json.options) });
      expect([bad.status, unknown.status]).toEqual([401, 401]);
      expect(bad.json).toEqual(unknown.json);
    });

    it('Nutzerprüfung (UV) ist Pflicht bei der Anmeldung', async () => {
      const a = await adminPasskey(world);
      const c = world.client('203.0.113.94');
      const opts = await c.post('/api/v1/auth/login/passkey/options');
      const res = await c.post('/api/v1/auth/login/passkey/verify', { challengeId: opts.json.challengeId, response: a.authenticator.assert(opts.json.options, { userVerified: false }) });
      expect(res.status).toBe(401);
    });
  });

  describe('Sitzungen', () => {
    it('CSRF: ändernde Cookie-Anfragen brauchen das Token im Header; GET nicht', async () => {
      const a = await adminPassword(world);
      const c = a.client;
      expect((await c.get('/api/v1/me', { headers: {} })).status).toBe(200);
      const without = await c.request('POST', '/api/v1/invites', { body: { role: 'child' }, noCsrf: true });
      expect(without.status).toBe(403);
      expect(without.json.error).toBe('csrf_invalid');
      const wrong = await c.request('POST', '/api/v1/invites', { body: { role: 'child' }, headers: { 'x-csrf-token': 'x'.repeat(64) }, noCsrf: true });
      expect(wrong.status).toBe(403);
      expect((await c.post('/api/v1/invites', { role: 'child' })).status).toBe(200);
      // das Token einer anderen Sitzung gilt nicht
      const other = world.client('203.0.113.100');
      await passwordLogin(a.email, a.totpSecret, other);
      expect(other.csrf).not.toBe(c.csrf);
      expect((await c.request('POST', '/api/v1/invites', { body: { role: 'child' }, headers: { 'x-csrf-token': other.csrf ?? '' }, noCsrf: true })).status).toBe(403);
    });

    it('CSRF: fremde Origin wird in production abgelehnt, auch ohne Sitzung', async () => {
      const prod = await World.create(harness.db, { NODE_ENV: 'production' });
      const c = prod.client();
      c.origin = 'https://evil.example';
      const res = await c.post('/api/v1/auth/login/passkey/options');
      expect(res.status).toBe(403);
      expect(res.json.error).toBe('origin_not_allowed');
      c.origin = ORIGIN;
      expect((await c.post('/api/v1/auth/login/passkey/options')).status).toBe(200);
      // die App sendet keinen Origin
      c.origin = undefined;
      expect((await c.post('/api/v1/auth/login/passkey/options')).status).toBe(200);
      await prod.close();
    });

    it('Web-Sitzung: Leerlauf nach 7 Tagen, absolutes Ende nach 30 Tagen trotz Aktivität', async () => {
      const a = await adminPassword(world);
      const idle = world.client('203.0.113.101');
      await passwordLogin(a.email, a.totpSecret, idle);
      world.advance(8 * DAY);
      expect((await idle.get('/api/v1/me')).status).toBe(401);

      const active = world.client('203.0.113.102');
      await passwordLogin(a.email, a.totpSecret, active);
      for (let i = 0; i < 5; i++) {
        world.advance(5 * DAY);
        expect((await active.get('/api/v1/me')).status).toBe(200);
      }
      world.advance(6 * DAY); // über 30 Tage seit der Anmeldung
      expect((await active.get('/api/v1/me')).status).toBe(401);
    });

    it('Abmelden beendet nur die eigene Sitzung; "überall abmelden" alle', async () => {
      const a = await adminPassword(world);
      const second = world.client('203.0.113.103');
      await passwordLogin(a.email, a.totpSecret, second);
      expect((await a.client.post('/api/v1/auth/logout')).status).toBe(200);
      expect((await a.client.get('/api/v1/me')).status).toBe(401);
      expect((await second.get('/api/v1/me')).status).toBe(200);
      const third = world.client('203.0.113.104');
      await passwordLogin(a.email, a.totpSecret, third);
      expect((await second.post('/api/v1/auth/logout-all')).status).toBe(200);
      expect((await third.get('/api/v1/me')).status).toBe(401);
      expect(await events()).toEqual(expect.arrayContaining(['logout', 'logout_all']));
    });

    it('Geräteliste und einzelnes Abmelden', async () => {
      const a = await adminPassword(world);
      const phone = world.client('203.0.113.105');
      await passwordLogin(a.email, a.totpSecret, phone, { client: 'app', device: { name: 'Pixel', platform: 'android', appVersion: '0.2.0' } });
      const list = await a.client.get('/api/v1/devices');
      expect(list.json.devices).toHaveLength(2);
      expect(list.json.devices.find((d: { current: boolean }) => d.current).platform).toBe('web');
      const pixel = list.json.devices.find((d: { name: string }) => d.name === 'Pixel');
      expect(pixel).toMatchObject({ platform: 'android', appVersion: '0.2.0', current: false });
      expect((await a.client.del(`/api/v1/devices/${pixel.id}`)).status).toBe(200);
      expect((await phone.get('/api/v1/me')).status).toBe(401);
      expect((await a.client.get('/api/v1/devices')).json.devices).toHaveLength(1);
      // fremde oder unbekannte Geräte: 404
      expect((await a.client.del(`/api/v1/devices/${pixel.id}`)).status).toBe(404);
      const events1 = await events();
      expect(events1).toEqual(expect.arrayContaining(['device_added', 'device_removed']));
    });

    describe('App: Access- und Refresh-Token', () => {
      async function appLogin() {
        const a = await adminPassword(world);
        const c = world.client('203.0.113.110');
        const res = await passwordLogin(a.email, a.totpSecret, c, { client: 'app', device: { name: 'Pixel', platform: 'android' } });
        expect(res.status).toBe(200);
        expect(res.json.session.cookie).toBeUndefined();
        expect(res.headers['set-cookie']).toBeUndefined();
        return { a, c, session: res.json.session as { accessToken: string; refreshToken: string; deviceId: string; accessExpiresAt: string } };
      }

      it('Access-Token gilt 15 Minuten, ohne CSRF-Header', async () => {
        const { c, session } = await appLogin();
        c.origin = undefined;
        expect((await c.post('/api/v1/invites', { role: 'child' })).status).toBe(200);
        expect(new Date(session.accessExpiresAt).getTime() - world.clock).toBe(15 * MIN);
        world.advance(15 * MIN + 1000);
        expect((await c.get('/api/v1/me')).status).toBe(401);
        c.bearer = 'v1.00000000-0000-0000-0000-000000000000.9999999999.' + 'a'.repeat(64);
        expect((await c.get('/api/v1/me')).status).toBe(401);
      });

      it('Refresh rotiert das Token; das alte wird abgelehnt und löst Wiederverwendungs-Erkennung aus', async () => {
        const { c, session } = await appLogin();
        c.bearer = undefined;
        const r1 = await c.post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: session.deviceId });
        expect(r1.status).toBe(200);
        const s1 = r1.json.session;
        expect(s1.refreshToken).not.toBe(session.refreshToken);
        expect(s1.deviceId).toBe(session.deviceId);
        c.bearer = s1.accessToken;
        expect((await c.get('/api/v1/me')).status).toBe(200);

        const rows = await harness.db.select().from(schema.sessions);
        const old = rows.find((r) => r.tokenHash === sha256Hex(session.refreshToken));
        const fresh = rows.find((r) => r.tokenHash === sha256Hex(s1.refreshToken));
        expect(old?.usedAt).not.toBeNull();
        expect(old?.rotatedTo).toBe(fresh?.id);
        expect(old?.tokenFamily).toBe(fresh?.tokenFamily);

        // Diebstahl: das alte Token wird erneut vorgelegt -> die ganze Familie fällt
        const reuse = await world.client('198.51.100.9').post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: session.deviceId });
        expect(reuse.status).toBe(401);
        expect((await c.get('/api/v1/me')).status).toBe(401); // auch das neue Access-Token ist tot
        const again = await c.post('/api/v1/auth/refresh', { refreshToken: s1.refreshToken, deviceId: session.deviceId });
        expect(again.status).toBe(401);
        const family = (await harness.db.select().from(schema.sessions)).filter((r) => r.tokenFamily === old?.tokenFamily);
        expect(family.every((r) => r.revokedAt !== null)).toBe(true);
        expect(await events()).toContain('session_reuse_detected');
      });

      it('gleichzeitige Einlösung desselben Refresh-Tokens: nur eine Anfrage gewinnt, die Familie wird widerrufen', async () => {
        const { session } = await appLogin();
        const results = await Promise.all(
          ['198.51.100.21', '198.51.100.22', '198.51.100.23'].map((ip) => world.client(ip).post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: session.deviceId })),
        );
        expect(results.filter((r) => r.status === 200).length).toBeLessThanOrEqual(1);
        const rows = (await harness.db.select().from(schema.sessions)).filter((r) => r.kind === 'app');
        expect(rows.length).toBeGreaterThanOrEqual(1);
        expect(rows.every((r) => r.revokedAt !== null)).toBe(true);
      });

      it('ist an das Gerät gebunden: falsche Geräte-ID wird abgelehnt', async () => {
        const { session } = await appLogin();
        const wrong = await world.client('198.51.100.30').post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: '00000000-0000-4000-8000-000000000000' });
        expect(wrong.status).toBe(401);
        // das Token ist dadurch nicht verbraucht
        expect((await world.client('198.51.100.31').post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: session.deviceId })).status).toBe(200);
      });

      it('Leerlauf: nach 30 Tagen ohne Erneuerung ist das Refresh-Token ungültig', async () => {
        const { session } = await appLogin();
        world.advance(31 * DAY);
        expect((await world.client('198.51.100.32').post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: session.deviceId })).status).toBe(401);

      });

      it('Rotation behält das absolute Ablaufdatum der Anmeldung', async () => {
        const { session } = await appLogin();
        let current = session;
        const start = world.clock;
        for (let i = 0; i < 8; i++) {
          world.advance(12 * DAY);
          const r = await world.client(`198.51.100.${40 + i}`).post('/api/v1/auth/refresh', { refreshToken: current.refreshToken, deviceId: current.deviceId });
          if (world.clock - start > 90 * DAY) {
            expect(r.status).toBe(401);
            return;
          }
          expect(r.status).toBe(200);
          expect(new Date(r.json.session.refreshExpiresAt).getTime() - start).toBe(90 * DAY);
          current = r.json.session;
        }
        throw new Error('Ablauf nicht erreicht');
      });
    });

    it('Rollenwechsel widerruft alle Sitzungen der Person (Admin bleibt angemeldet)', async () => {
      const a = await adminPassword(world);
      const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
      const mamaApp = world.client('203.0.113.120');
      await passwordLogin('mama@example.org', mama.totpSecret, mamaApp, { client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect((await mama.client.get('/api/v1/me')).status).toBe(200);
      const id = (await a.client.get('/api/v1/members')).json.members.find((m: { email: string }) => m.email === 'mama@example.org').id;
      const res = await a.client.patch(`/api/v1/members/${id}/role`, { role: 'child' });
      expect(res.status).toBe(200);
      expect((await mama.client.get('/api/v1/me')).status).toBe(401);
      expect((await mamaApp.get('/api/v1/me')).status).toBe(401);
      expect((await a.client.get('/api/v1/me')).status).toBe(200);
      // nach erneuter Anmeldung gilt die neue Rolle
      const again = await passwordLogin('mama@example.org', mama.totpSecret, world.client('203.0.113.121'));
      expect(again.json.user.role).toBe('child');
      const audit = (await harness.db.select().from(schema.auditLog).where(eq(schema.auditLog.event, 'role_changed')))[0];
      expect(audit?.detail).toMatchObject({ from: 'parent', to: 'child', target: id });
    });

    it('Rollenregeln: nur Admins ändern Rollen; der letzte Admin bleibt', async () => {
      const a = await adminPassword(world);
      const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
      const members = (await a.client.get('/api/v1/members')).json.members as Array<{ id: string; email: string }>;
      const adminId = members.find((m) => m.email === a.email)?.id;
      const mamaId = members.find((m) => m.email === 'mama@example.org')?.id;
      expect((await mama.client.patch(`/api/v1/members/${adminId}/role`, { role: 'guest' })).status).toBe(403);
      expect((await mama.client.patch(`/api/v1/members/${mamaId}/role`, { role: 'admin' })).status).toBe(403);
      const last = await a.client.patch(`/api/v1/members/${adminId}/role`, { role: 'parent' });
      expect(last.status).toBe(409);
      expect(last.json.error).toBe('last_admin');
      expect((await a.client.del(`/api/v1/members/${adminId}`)).status).toBe(409);
    });

    it('Mitgliederliste: Nicht-Admins sehen keine E-Mail-Adressen und keine wartenden Mitglieder', async () => {
      const a = await adminPassword(world);
      const kind = await addMember(world, a.client, 'child', 'kind@example.org');
      await addMember(world, a.client, 'guest', 'oma@example.org');
      const list = (await kind.client.get('/api/v1/members')).json.members as Array<Record<string, unknown>>;
      expect(list.map((m) => m.displayName).sort()).toEqual(['Admin', 'kind']);
      for (const m of list) if (m.displayName !== 'kind') expect(m.email).toBeUndefined();
      expect((await a.client.get('/api/v1/members')).json.members).toHaveLength(3);
    });
  });

  describe('Step-up (erneute Bestätigung)', () => {
    it('frische Anmeldung zählt als Bestätigung; nach 5 Minuten verlangt die Rollenänderung eine erneute', async () => {
      const a = await adminPassword(world);
      const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
      const id = (await a.client.get('/api/v1/members')).json.members.find((m: { email: string }) => m.email === 'mama@example.org').id;
      world.advance(6 * MIN);
      const denied = await a.client.patch(`/api/v1/members/${id}/role`, { role: 'child' });
      expect(denied.status).toBe(403);
      expect(denied.json.error).toBe('step_up_required');
      void mama;

      const wrong = await a.client.post('/api/v1/auth/step-up/code', { totp: '000000' });
      expect(wrong.status).toBe(401);
      expect((await a.client.patch(`/api/v1/members/${id}/role`, { role: 'child' })).status).toBe(403);
      const ok = await a.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(a.totpSecret) });
      expect(ok.status).toBe(200);
      expect((await a.client.patch(`/api/v1/members/${id}/role`, { role: 'child' })).status).toBe(200);
      expect(await events()).toEqual(expect.arrayContaining(['step_up_ok', 'step_up_failed']));
    });

    it('Step-up per Passkey; Wiederherstellungs-Code funktioniert ebenfalls; fremde Antworten nicht', async () => {
      const a = await adminPasskey(world);
      const login = world.client('203.0.113.130');
      await world.loginPasskey(login, a.authenticator);
      const target = await addMember(world, a.client, 'parent', 'mama@example.org');
      const id = (await a.client.get('/api/v1/members')).json.members.find((m: { email: string }) => m.email === 'mama@example.org').id;
      world.advance(6 * MIN);
      expect((await a.client.patch(`/api/v1/members/${id}/role`, { role: 'child' })).json.error).toBe('step_up_required');

      const opts = await a.client.post('/api/v1/auth/step-up/passkey/options');
      expect(opts.status).toBe(200);
      const stranger = new TestAuthenticator();
      const bad = await a.client.post('/api/v1/auth/step-up/passkey/verify', { challengeId: opts.json.challengeId, response: stranger.assert(opts.json.options) });
      expect(bad.status).toBe(401);
      const opts2 = await a.client.post('/api/v1/auth/step-up/passkey/options');
      const good = await a.client.post('/api/v1/auth/step-up/passkey/verify', { challengeId: opts2.json.challengeId, response: a.authenticator.assert(opts2.json.options) });
      expect(good.status).toBe(200);
      expect((await a.client.patch(`/api/v1/members/${id}/role`, { role: 'child' })).status).toBe(200);

      // Wiederherstellungs-Code
      world.advance(6 * MIN);
      const rec = await a.client.post('/api/v1/auth/step-up/code', { recoveryCode: a.recoveryCodes[0] });
      expect(rec.status).toBe(200);
      void target;
    });

    it('neuen Passkey hinzufügen verlangt Step-up und funktioniert danach', async () => {
      const a = await adminPasskey(world);
      const c = world.client('203.0.113.131');
      await world.loginPasskey(c, a.authenticator);
      world.advance(6 * MIN);
      expect((await c.post('/api/v1/me/passkeys/options')).json.error).toBe('step_up_required');
      const so = await c.post('/api/v1/auth/step-up/passkey/options');
      expect((await c.post('/api/v1/auth/step-up/passkey/verify', { challengeId: so.json.challengeId, response: a.authenticator.assert(so.json.options) })).status).toBe(200);
      const opts = await c.post('/api/v1/me/passkeys/options');
      expect(opts.status).toBe(200);
      expect(opts.json.options.excludeCredentials).toHaveLength(1);
      const second = new TestAuthenticator();
      const done = await c.post('/api/v1/me/passkeys/verify', { challengeId: opts.json.challengeId, response: second.register(opts.json.options), label: 'Zweitgerät' });
      expect(done.status).toBe(200);
      const list = await c.get('/api/v1/me/credentials');
      expect(list.json.credentials.filter((x: { type: string }) => x.type === 'passkey')).toHaveLength(2);
      expect(JSON.stringify(list.json)).not.toContain('secret');
      // der zweite Passkey meldet an
      expect((await world.loginPasskey(world.client('203.0.113.132'), second)).status).toBe(200);
      // entfernen: erst mit Step-up, nie den letzten
      const id = list.json.credentials.find((x: { label: string }) => x.label === 'Zweitgerät').id;
      expect((await c.del(`/api/v1/me/passkeys/${id}`)).status).toBe(200);
      const left = (await c.get('/api/v1/me/credentials')).json.credentials[0].id;
      expect((await c.del(`/api/v1/me/passkeys/${left}`)).json.error).toBe('last_credential');
    });

    it('neue Wiederherstellungs-Codes ersetzen die alten', async () => {
      const a = await adminPassword(world);
      const res = await a.client.post('/api/v1/me/recovery-codes');
      expect(res.status).toBe(200);
      expect(res.json.recoveryCodes).toHaveLength(10);
      const old = await world.client('203.0.113.133').post('/api/v1/auth/login/recovery', { email: a.email, code: a.recoveryCodes[0] });
      expect(old.status).toBe(401);
      expect((await world.client('203.0.113.134').post('/api/v1/auth/login/recovery', { email: a.email, code: res.json.recoveryCodes[0] })).status).toBe(200);
    });
  });

  describe('Fehlversuche und Sperren', () => {
    it('sperrt ein Konto nach 5 Fehlversuchen verzögert (auch mit richtigen Daten) und gibt es später wieder frei', async () => {
      const a = await adminPassword(world);
      world.advance(31_000);
      for (let i = 0; i < 5; i++) {
        const r = await world.client(`198.51.100.${60 + i}`).post('/api/v1/auth/login/password', { email: a.email, password: 'falsch-falsch-falsch', totp: '123456' });
        expect(r.status).toBe(401);
      }
      const code = await world.totp(a.totpSecret);
      const locked = await world.client('198.51.100.70').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: code });
      expect(locked.status).toBe(429);
      expect(locked.json.error).toBe('too_many_attempts');
      expect(Number(locked.headers['retry-after'])).toBeGreaterThan(0);
      world.advance(31_000);
      const free = await world.client('198.51.100.71').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(a.totpSecret) });
      expect(free.status).toBe(200);
    });

    it('die Sperre wächst bei weiteren Fehlversuchen und gilt für unbekannte Konten gleich (keine Konto-Enumeration)', async () => {
      const known = await adminPassword(world);
      const trace = async (email: string) => {
        const out: Array<[number, string]> = [];
        for (let i = 0; i < 8; i++) {
          const r = await world.client(`192.0.2.${i + 1}`).post('/api/v1/auth/login/password', { email, password: 'falsch-falsch-falsch', totp: '123456' });
          out.push([r.status, r.json.error as string]);
        }
        return out;
      };
      const a = await trace(known.email);
      const b = await trace('gibt-es-nicht@example.org');
      expect(a).toEqual(b);
      expect(a.map((x) => x[0])).toEqual([401, 401, 401, 401, 401, 429, 429, 429]);
      const rows = await harness.db.select().from(schema.loginAttempts);
      // Schlüssel enthalten weder E-Mail noch IP im Klartext
      expect(JSON.stringify(rows)).not.toContain('example.org');
      expect(JSON.stringify(rows)).not.toContain('192.0.2.');
    });

    it('zählt Fehlversuche je IP über alle Konten und sperrt dann auch andere Anmelderouten', async () => {
      await adminPassword(world);
      world.config.auth.lockoutIpThreshold = 4;
      const c = world.client('192.0.2.200');
      for (let i = 0; i < 4; i++) expect((await c.post('/api/v1/auth/login/password', { email: `x${i}@example.org`, password: 'falsch-falsch-falsch', totp: '123456' })).status).toBe(401);
      expect((await c.post('/api/v1/auth/login/passkey/options')).status).toBe(429);
      expect((await c.post('/api/v1/auth/login/recovery', { email: 'x@example.org', code: 'AAAA-BBBB-CCCC-DDDD' })).status).toBe(429);
      // eine andere IP ist nicht betroffen
      expect((await world.client('192.0.2.201').post('/api/v1/auth/login/passkey/options')).status).toBe(200);
    });

    it('erfolgreiche Anmeldung setzt den Konto-Zähler zurück', async () => {
      const a = await adminPassword(world);
      for (let i = 0; i < 3; i++) await world.client(`198.51.100.${80 + i}`).post('/api/v1/auth/login/password', { email: a.email, password: 'falsch-falsch-falsch', totp: '123456' });
      expect((await passwordLogin(a.email, a.totpSecret, world.client('198.51.100.90'))).status).toBe(200);
      for (let i = 0; i < 4; i++) await world.client(`198.51.100.${91 + i}`).post('/api/v1/auth/login/password', { email: a.email, password: 'falsch-falsch-falsch', totp: '123456' });
      world.advance(31_000);
      expect((await world.client('198.51.100.99').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(a.totpSecret) })).status).toBe(200);
    });

    it('Rate-Limit je IP: strenger für Anmelde- und Ticket-Routen', async () => {
      const strict = await World.create(harness.db, { AUTH_RATE_LIMIT_MAX: '3', RATE_LIMIT_MAX: '50' });
      const c = strict.client('198.51.100.150');
      const codes: number[] = [];
      for (let i = 0; i < 5; i++) codes.push((await c.post('/api/v1/auth/login/passkey/options')).status);
      expect(codes).toEqual([200, 200, 200, 429, 429]);
      const limited = await c.post('/api/v1/auth/login/passkey/options');
      expect(limited.json.error).toBe('rate_limited');
      expect(JSON.stringify(limited.json)).not.toMatch(/statusCode|Rate limit exceeded/i);
      const codes2: number[] = [];
      for (let i = 0; i < 4; i++) codes2.push((await strict.client('198.51.100.151').post('/api/v1/ws-ticket')).status);
      expect(codes2).toEqual([401, 401, 401, 429]);
      expect((await c.get('/api/v1/version')).status).toBe(200);
      await strict.close();
    });

    it('Konto-Enumeration: Einladung, Wiederherstellung und Passkey antworten für alle Fehlerfälle gleich', async () => {
      const a = await adminPassword(world);
      const lookups = [];
      const inv = await a.client.post('/api/v1/invites', { role: 'child' });
      await a.client.post(`/api/v1/invites/${inv.json.invite.id}/revoke`);
      const used = await addMember(world, a.client, 'child', 'k@example.org');
      for (const token of ['u'.repeat(43), inv.json.invite.token, used.invite.token]) {
        lookups.push(await world.client('203.0.113.140').post('/api/v1/auth/invites/lookup', { token }));
      }
      for (const r of lookups) expect(r.json).toEqual({ error: 'invite_invalid', message: 'Die Einladung ist ungültig, abgelaufen oder gesperrt.' });
      expect(new Set(lookups.map((r) => r.status))).toEqual(new Set([400]));

      const rec = await world.client('203.0.113.141').post('/api/v1/auth/login/recovery', { email: a.email, code: 'AAAA-BBBB-CCCC-DDDD' });
      const rec2 = await world.client('203.0.113.142').post('/api/v1/auth/login/recovery', { email: 'niemand@example.org', code: 'AAAA-BBBB-CCCC-DDDD' });
      expect([rec.status, rec.json]).toEqual([rec2.status, rec2.json]);
    });
  });

  describe('Mandanten- und Familiengrenze', () => {
    async function secondFamily() {
      const [fam] = await harness.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning();
      const [user] = await harness.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'Fremd' }).returning();
      if (!fam || !user) throw new Error('Setup');
      await harness.db.insert(schema.memberships).values({ familyId: fam.id, userId: user.id, role: 'admin' });
      await harness.db.insert(schema.invites).values({ familyId: fam.id, role: 'guest', tokenHash: sha256Hex('fremde-einladung'), expiresAt: new Date(world.clock + DAY) });
      return { fam, user };
    }

    it('Admin einer Familie sieht und ändert nichts in einer fremden Familie', async () => {
      const a = await adminPassword(world);
      const { user, fam } = await secondFamily();
      const list = (await a.client.get('/api/v1/members')).json.members as Array<{ email?: string }>;
      expect(JSON.stringify(list)).not.toContain('fremd@example.org');
      for (const [m, url, body] of [
        ['PATCH', `/api/v1/members/${user.id}/role`, { role: 'guest' }],
        ['POST', `/api/v1/members/${user.id}/approve`, {}],
        ['POST', `/api/v1/members/${user.id}/reject`, {}],
        ['POST', `/api/v1/members/${user.id}/reset`, {}],
        ['DELETE', `/api/v1/members/${user.id}`, undefined],
      ] as const) {
        const res = await a.client.request(m, url, body === undefined ? {} : { body });
        expect(res.status, `${m} ${url}`).toBe(404);
      }
      const invites = (await a.client.get('/api/v1/invites')).json.invites as Array<{ id: string }>;
      const foreign = (await harness.db.select().from(schema.invites).where(eq(schema.invites.familyId, fam.id)))[0];
      expect(invites.some((i) => i.id === foreign?.id)).toBe(false);
      expect((await a.client.post(`/api/v1/invites/${foreign?.id}/revoke`)).status).toBe(404);
      // nichts verändert
      expect((await harness.db.select().from(schema.users).where(eq(schema.users.id, user.id))).length).toBe(1);
    });

    it('die Datenbank verhindert Sitzungen, Geräte und Verweise über Familiengrenzen (zusammengesetzte Fremdschlüssel)', async () => {
      const a = await adminPassword(world);
      const { fam, user } = await secondFamily();
      const [own] = await harness.db.select().from(schema.families).where(eq(schema.families.name, 'Familie Test'));
      const adminUser = (await harness.db.select().from(schema.users).where(eq(schema.users.email, a.email)))[0];
      if (!own || !adminUser) throw new Error('Setup');
      const farFuture = new Date(world.clock + DAY);
      // Benutzer der fremden Familie in meiner Familie: keine Mitgliedschaft -> abgelehnt
      await expect(harness.db.insert(schema.sessions).values({ familyId: own.id, userId: user.id, tokenHash: 'h1', expiresAt: farFuture })).rejects.toThrow();
      await expect(harness.db.insert(schema.devices).values({ familyId: own.id, userId: user.id, name: 'x', platform: 'web' })).rejects.toThrow();
      await expect(harness.db.insert(schema.wsTickets).values({ tokenHash: 'h2', familyId: fam.id, userId: adminUser.id, sessionId: '00000000-0000-4000-8000-000000000000', expiresAt: farFuture })).rejects.toThrow();
      // Termin-Teilnehmer: Person aus Familie A bei Termin von Familie B
      const [ev] = await harness.db.insert(schema.events).values({ familyId: fam.id, title: 'x', allDay: true, startsOn: '2026-10-20', rev: 1 }).returning();
      await expect(harness.db.insert(schema.eventAttendees).values({ familyId: fam.id, eventId: ev?.id ?? '', userId: adminUser.id, rev: 2 })).rejects.toThrow();
      await expect(harness.db.insert(schema.eventAttendees).values({ familyId: fam.id, eventId: ev?.id ?? '', userId: user.id, rev: 2 })).resolves.toBeDefined();
    });

    it('WebSocket-Tickets und Sitzungen tragen die Familie des Ausstellers', async () => {
      const a = await adminPassword(world);
      const t = await a.client.post('/api/v1/ws-ticket');
      const p = await world.auth.redeemWsTicket(t.json.ticket);
      const [fam] = await harness.db.select().from(schema.families).where(eq(schema.families.name, 'Familie Test'));
      expect(p).toMatchObject({ familyId: fam?.id, role: 'admin' });
    });
  });

  describe('Zurücksetzen durch Admin', () => {
    it('widerruft Anmeldedaten und Sitzungen; die neue Einladung richtet neue Anmeldedaten für dasselbe Konto ein', async () => {
      const a = await adminPassword(world);
      const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
      const mamaApp = world.client('203.0.113.160');
      await passwordLogin('mama@example.org', mama.totpSecret, mamaApp, { client: 'app', device: { name: 'Handy', platform: 'android' } });
      const [before] = await harness.db.select().from(schema.users).where(eq(schema.users.email, 'mama@example.org'));
      const id = before?.id ?? '';

      world.advance(6 * MIN);
      expect((await a.client.post(`/api/v1/members/${id}/reset`)).json.error).toBe('step_up_required');
      await a.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(a.totpSecret) });
      const reset = await a.client.post(`/api/v1/members/${id}/reset`, { hours: 12, pin: true });
      expect(reset.status).toBe(200);
      expect(reset.json.invite.pin).toMatch(/^\d{6}$/);

      // alt: Sitzungen tot, Passwort/Codes unbrauchbar
      expect((await mama.client.get('/api/v1/me')).status).toBe(401);
      expect((await mamaApp.get('/api/v1/me')).status).toBe(401);
      world.advance(31_000);
      const oldLogin = await world.client('203.0.113.161').post('/api/v1/auth/login/password', { email: 'mama@example.org', password: PW, totp: await world.totp(mama.totpSecret) });
      expect(oldLogin.status).toBe(401);
      expect((await world.client('203.0.113.162').post('/api/v1/auth/login/recovery', { email: 'mama@example.org', code: mama.recoveryCodes[0] })).status).toBe(401);
      const creds = await harness.db.select().from(schema.credentials).where(eq(schema.credentials.userId, id));
      expect(creds.every((c) => c.revokedAt !== null)).toBe(true);
      expect(await harness.db.select().from(schema.recoveryCodes).where(eq(schema.recoveryCodes.userId, id))).toHaveLength(0);

      // neu: Einladung zeigt "reset", verlangt weder E-Mail noch Namen, aber die PIN
      const look = await world.client().post('/api/v1/auth/invites/lookup', { token: reset.json.invite.token });
      expect(look.json.invite).toMatchObject({ reset: true, displayName: 'mama', pinRequired: true, role: 'parent' });
      const authn = new TestAuthenticator();
      const noPin = await world.client('203.0.113.163').post('/api/v1/auth/invites/passkey/options', { token: reset.json.invite.token });
      expect(noPin.status).toBe(400);
      const c = world.client('203.0.113.164');
      const start = await c.post('/api/v1/auth/invites/passkey/options', { token: reset.json.invite.token, pin: reset.json.invite.pin });
      expect(start.status).toBe(200);
      const done = await c.post('/api/v1/auth/invites/passkey/complete', { challengeId: start.json.challengeId, response: authn.register(start.json.options) });
      expect(done.status).toBe(200);
      expect(done.json.member).toMatchObject({ id, role: 'parent', email: 'mama@example.org' });
      expect(await world.count('users')).toBe(2);
      expect((await world.loginPasskey(world.client('203.0.113.165'), authn)).status).toBe(200);
      expect(await events()).toContain('member_reset');
    });

    it('Notfall: der Betreiber setzt den einzigen Admin per Kommandozeile zurück', async () => {
      const a = await adminPassword(world);
      const invite = await resetByEmail(world.auth.ctx, a.email.toUpperCase());
      expect((await a.client.get('/api/v1/me')).status).toBe(401);
      const reg = await world.registerPasskey(invite.token, { email: 'ignoriert@example.org' });
      expect(reg.complete?.status).toBe(200);
      expect(reg.complete?.json.member).toMatchObject({ email: a.email, role: 'admin' });
      await expect(resetByEmail(world.auth.ctx, 'unbekannt@example.org')).rejects.toMatchObject({ code: 'not_found' });
    });
  });

  describe('Aufräumen und Aufbewahrung', () => {
    it('entfernt IP-Adressen nach 7 Tagen und Audit-Einträge nach der Aufbewahrungsfrist', async () => {
      const a = await adminPassword(world);
      await passwordLogin(a.email, a.totpSecret, world.client('203.0.113.170'));
      const withIp = () => harness.db.select().from(schema.auditLog);
      expect((await withIp()).some((r) => r.ip !== null)).toBe(true);
      world.advance(6 * DAY);
      await runMaintenance(world.auth.ctx);
      expect((await withIp()).some((r) => r.ip !== null)).toBe(true);
      world.advance(2 * DAY);
      const report = await runMaintenance(world.auth.ctx);
      expect(report.auditIpCleared).toBeGreaterThan(0);
      const rows = await withIp();
      expect(rows.length).toBeGreaterThan(0);
      expect(rows.every((r) => r.ip === null)).toBe(true);
      world.advance(366 * DAY);
      const report2 = await runMaintenance(world.auth.ctx);
      expect(report2.auditDeleted).toBe(rows.length);
      expect(await world.count('audit_log')).toBeGreaterThanOrEqual(0);
    });

    it('bereinigt abgelaufene Sitzungen, Challenges, Tickets und Fehlversuche', async () => {
      const a = await adminPassword(world);
      await world.client('203.0.113.171').post('/api/v1/auth/login/passkey/options');
      await a.client.post('/api/v1/ws-ticket');
      await world.client('203.0.113.172').post('/api/v1/auth/login/password', { email: 'x@example.org', password: 'falsch-falsch-falsch', totp: '123456' });
      expect(await world.count('webauthn_challenges')).toBe(1);
      expect(await world.count('ws_tickets')).toBe(1);
      expect(await world.count('login_attempts')).toBeGreaterThan(0);
      world.advance(31 * DAY + 2 * DAY);
      const r = await runMaintenance(world.auth.ctx);
      expect(r.challengesDeleted).toBe(1);
      expect(r.sessionsDeleted).toBe(1);
      expect(await world.count('sessions')).toBe(0);
      expect(await world.count('webauthn_challenges')).toBe(0);
      expect(await world.count('ws_tickets')).toBe(0);
      expect(await world.count('login_attempts')).toBe(0);
    });
  });
});
