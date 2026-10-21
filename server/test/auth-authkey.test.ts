// Anmeldung und Passwortwechsel mit abgeleitetem authKey statt Klartext-Passwort (PGlite und echtes PostgreSQL).
// Zustandsautomat legacy -> authkey, Schalter AUTH_LEGACY_PASSWORD_LOGIN, gleiche Fehlerantworten, Sperren, Atomarität, Parallelität.
import { randomBytes } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { authKeyDigest, isCanonicalAuthKey } from '../src/auth/authkey.js';
import { loadConfig } from '../src/config.js';
import { adminPassword, auditEvents, backends, TEST_KEY, World, type Client, type Harness } from './helpers.js';

const PW = 'ein-sehr-langes-passwort-123';
const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = () => ({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });
const BODY_FALSCH = { error: 'invalid_credentials' };

describe('Konfiguration AUTH_LEGACY_PASSWORD_LOGIN', () => {
  const cfg = (v?: string, pw = 'true') =>
    loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, E2EE_PW_BACKUP: pw, ...(v === undefined ? {} : { AUTH_LEGACY_PASSWORD_LOGIN: v }) }).auth.legacyPasswordLogin;
  it('Standard an; true/1/false/0; alles andere bricht den Start ab', () => {
    expect(cfg()).toBe(true);
    expect(cfg('')).toBe(true);
    expect(cfg('true')).toBe(true);
    expect(cfg('1')).toBe(true);
    expect(cfg('false')).toBe(false);
    expect(cfg('0')).toBe(false);
    expect(() => cfg('nein')).toThrow(/AUTH_LEGACY_PASSWORD_LOGIN/);
    expect(() => cfg('aus')).toThrow(/AUTH_LEGACY_PASSWORD_LOGIN/);
  });
  it('aus ohne E2EE_PW_BACKUP bricht den Start ab (sonst wären alle Passwort-Konten ausgesperrt)', () => {
    expect(() => cfg('false', 'false')).toThrow(/E2EE_PW_BACKUP/);
    expect(cfg('true', 'false')).toBe(true);
  });
});

describe('authKey-Bausteine', () => {
  it('kanonisches Base64url (43 Zeichen, 32 Byte)', () => {
    expect(isCanonicalAuthKey(key())).toBe(true);
    expect(isCanonicalAuthKey('a'.repeat(43))).toBe(false); // letztes Zeichen mit Restbits: nicht kanonisch
    expect(isCanonicalAuthKey('A'.repeat(42))).toBe(false);
    expect(isCanonicalAuthKey(`${key()}=`)).toBe(false);
    expect(isCanonicalAuthKey(`${key().slice(0, 42)}+`)).toBe(false);
  });
});

describe.each(backends)('Anmeldung mit authKey ($name)', (backend) => {
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
  });

  async function start(env: Record<string, string> = { E2EE_PW_BACKUP: 'true' }) {
    world = await World.create(harness.db, env);
    const a = await adminPassword(world);
    return a;
  }
  type Admin = Awaited<ReturnType<typeof start>>;
  /** Server mit anderem Schalter auf derselben Datenbank neu starten (Stichtag). */
  async function restart(env: Record<string, string>) {
    await world.close();
    world = await World.create(harness.db, env);
  }

  /** Frischer TOTP-Code (die Uhr springt einen Zeitschritt). */
  async function code(a: Admin) {
    world.advance(31_000);
    return world.totp(a.totpSecret);
  }
  const login = async (a: Admin, body: Record<string, unknown>, ip = '203.0.113.50') => {
    const c = world.client(ip);
    const res = await c.post('/api/v1/auth/login/password', { email: a.email, totp: await code(a), ...body });
    if (res.status === 200) c.adopt(res.json.session);
    return { res, c };
  };
  const mode = async (a: Admin, by: Client = a.client) => {
    const r = await by.get('/api/v1/members/password-modes');
    const id = (await harness.db.execute<{ id: string }>(sql`select id from users where email = ${a.email}`)).rows[0]?.id;
    return (r.json.modes as Array<{ userId: string; mode: string }> | undefined)?.find((m) => m.userId === id)?.mode;
  };
  const rows = async () => (await harness.db.execute<{ n: number }>(sql`select count(*)::int as n from password_authkeys`)).rows[0]?.n;

  describe('Schalter E2EE_PW_BACKUP aus', () => {
    it('authKey und upgradeAuthKey werden abgelehnt, Klartext-Anmeldung unverändert, /version meldet false', async () => {
      const a = await start({});
      const v = await world.client().get('/api/v1/version');
      expect(v.json.features).toMatchObject({ pwBackup: false, authKey: false, legacyPasswordLogin: true });
      expect((await login(a, { authKey: key() })).res.status).toBe(400);
      expect((await login(a, { password: PW, upgradeAuthKey: key() })).res.status).toBe(400);
      expect((await login(a, { password: PW })).res.status).toBe(200);
      expect(await rows()).toBe(0);
    });
    it('Passwortwechsel mit authKey: 400; mit Klartext wie bisher', async () => {
      const a = await start({});
      expect((await a.client.post('/api/v1/me/password/change', { authKey: key() })).status).toBe(400);
      expect((await a.client.post('/api/v1/me/password/change', { password: 'ein-neues-langes-passwort-9' })).status).toBe(200);
    });
  });

  describe('legacy -> authkey', () => {
    it('/version meldet die Fähigkeit und den Schalter', async () => {
      await start();
      const v = await world.client().get('/api/v1/version');
      expect(v.json.features).toMatchObject({ pwBackup: true, authKey: true, legacyPasswordLogin: true });
    });

    it('Konto beginnt als legacy; authKey-Anmeldung scheitert mit derselben Antwort wie ein falsches Passwort', async () => {
      const a = await start();
      expect(await mode(a)).toBe('legacy');
      const falsch = await login(a, { password: 'falsch-falsch-falsch' }, '203.0.113.51');
      const legacyKey = await login(a, { authKey: key() }, '203.0.113.52');
      const unbekannt = await world.client('203.0.113.53').post('/api/v1/auth/login/password', { email: 'niemand@example.org', authKey: key(), totp: await code(a) });
      for (const r of [falsch.res, legacyKey.res, unbekannt]) {
        expect(r.status).toBe(401);
        expect(r.json).toMatchObject(BODY_FALSCH);
        expect(r.json.message).toBe(falsch.res.json.message);
      }
    });

    it('erfolgreicher Klartext-Login mit upgradeAuthKey legt den Prüfwert an; danach geht authKey UND (Schalter an) weiter Klartext', async () => {
      const a = await start();
      const ak = key();
      const up = await login(a, { password: PW, upgradeAuthKey: ak });
      expect(up.res.status).toBe(200);
      expect(await mode(a)).toBe('authkey');
      expect(await rows()).toBe(1);
      expect((await login(a, { authKey: ak })).res.status).toBe(200);
      expect((await login(a, { authKey: key() })).res.status).toBe(401);
      expect((await login(a, { password: PW })).res.status).toBe(200); // alte Apps
      expect(await auditEvents(world)).toContain('password_authkey_set');
    });

    it('Prüfwert ist ein HMAC (64 Hex), nie der authKey selbst; an die Person gebunden', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const r = (await harness.db.execute<{ auth_hash: string; user_id: string; salt_generation: number; kdf_id: string }>(sql`select * from password_authkeys`)).rows[0];
      expect(r?.auth_hash).toMatch(/^[0-9a-f]{64}$/);
      expect(r?.auth_hash).not.toContain(ak);
      expect(r?.auth_hash).toBe(authKeyDigest(world.auth.ctx, r?.user_id ?? '', ak));
      expect(r?.auth_hash).not.toBe(authKeyDigest(world.auth.ctx, '00000000-0000-4000-8000-000000000001', ak));
      expect(r).toMatchObject({ salt_generation: 1, kdf_id: 'argon2id-v1' });
    });

    it('kein Upgrade bei falschem Passwort, falschem zweiten Faktor oder wiederverwendetem Code', async () => {
      const a = await start();
      expect((await login(a, { password: 'falsch-falsch-falsch', upgradeAuthKey: key() })).res.status).toBe(401);
      expect((await login(a, { password: PW, upgradeAuthKey: key(), totp: '000000' })).res.status).toBe(401);
      expect(await rows()).toBe(0);
      expect(await mode(a)).toBe('legacy');
    });

    it('upgradeAuthKey nur mit Klartext (nicht mit authKey), genau eins von password/authKey', async () => {
      const a = await start();
      expect((await login(a, { authKey: key(), upgradeAuthKey: key() })).res.status).toBe(400);
      expect((await login(a, { password: PW, authKey: key() })).res.status).toBe(400);
      expect((await login(a, {})).res.status).toBe(400);
      expect((await login(a, { authKey: 'zu-kurz' })).res.status).toBe(400);
      expect((await login(a, { password: PW, upgradeAuthKey: 'a'.repeat(43) })).res.status).toBe(400);
    });

    it('ein späteres Upgrade ersetzt den Prüfwert (selbstheilend, Klartext-Login nötig)', async () => {
      const a = await start();
      const k1 = key();
      const k2 = key();
      await login(a, { password: PW, upgradeAuthKey: k1 });
      await login(a, { password: PW, upgradeAuthKey: k2 });
      expect(await rows()).toBe(1);
      expect((await login(a, { authKey: k1 })).res.status).toBe(401);
      expect((await login(a, { authKey: k2 })).res.status).toBe(200);
    });

    it('authKey-Anmeldung verlangt weiter den zweiten Faktor (TOTP oder Wiederherstellungscode), Codes sind einmalig', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const c = world.client('203.0.113.60');
      expect((await c.post('/api/v1/auth/login/password', { email: a.email, authKey: ak })).status).toBe(401);
      expect((await c.post('/api/v1/auth/login/password', { email: a.email, authKey: ak, totp: '123456' })).status).toBe(401);
      const rc = a.recoveryCodes[0] ?? '';
      expect((await c.post('/api/v1/auth/login/password', { email: a.email, authKey: ak, recoveryCode: rc })).status).toBe(200);
      expect((await world.client('203.0.113.61').post('/api/v1/auth/login/password', { email: a.email, authKey: ak, recoveryCode: rc })).status).toBe(401);
    });

    it('Sperren gelten unverändert: fünf falsche authKey-Versuche sperren das Paar (429), richtige Daten gehen danach nicht', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const ip = '203.0.113.70';
      // ohne Uhrsprung: die Sperre (30 s) läuft sonst zwischen den Versuchen ab
      const direkt = (authKey: string) => world.client(ip).post('/api/v1/auth/login/password', { email: a.email, authKey, totp: '123456' });
      for (let i = 0; i < 5; i++) expect((await direkt(key())).status).toBe(401);
      const gesperrt = await direkt(ak);
      expect(gesperrt.status).toBe(429);
      expect(gesperrt.json.error).toBe('too_many_attempts');
      expect((await login(a, { authKey: ak }, '203.0.113.71')).res.status).toBe(200); // andere IP nicht betroffen
    });

    it('Fehlversuche stehen im Audit ohne Geheimnis (nur Methode und Weg)', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      await login(a, { authKey: key() }, '203.0.113.72');
      const logs = await harness.db.execute<{ detail: unknown }>(sql`select detail from audit_log where event = 'login_failed'`);
      expect(JSON.stringify(logs.rows)).toContain('authkey');
      expect(JSON.stringify(await harness.db.execute(sql`select * from audit_log`))).not.toContain(ak);
    });

    it('gesperrtes Konto: authKey wie falsches Passwort', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      await harness.db.execute(sql`update users set disabled_at = now() where email = ${a.email}`);
      const r = await login(a, { authKey: ak });
      expect(r.res.status).toBe(401);
      expect(r.res.json).toMatchObject(BODY_FALSCH);
    });

    it('Parallel: gleichzeitige Upgrades mit demselben Code: genau einer gewinnt, Zustand bleibt ein einzelner gültiger Prüfwert', async () => {
      const a = await start();
      const c = await code(a);
      const k = [key(), key(), key()];
      const res = await Promise.all(k.map((x, i) => world.client(`203.0.113.${80 + i}`).post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: c, upgradeAuthKey: x })));
      expect(res.filter((r) => r.status === 200)).toHaveLength(1);
      expect(await rows()).toBe(1);
      const gueltig = [];
      for (const x of k) gueltig.push((await login(a, { authKey: x }, `203.0.113.${90 + gueltig.length}`)).res.status === 200);
      expect(gueltig.filter(Boolean)).toHaveLength(1);
    });

    it('Parallel: viele authKey-Anmeldungen mit verschiedenen Wiederherstellungscodes gelingen alle', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const res = await Promise.all(a.recoveryCodes.slice(0, 4).map((rc, i) => world.client(`203.0.113.${100 + i}`).post('/api/v1/auth/login/password', { email: a.email, authKey: ak, recoveryCode: rc })));
      expect(res.map((r) => r.status)).toEqual([200, 200, 200, 200]);
    });
  });

  describe('Zweiter Faktor, Rennen, Sicherung', () => {
    it('korrekter authKey, falscher Code: eigener Fehlercode (kein Klartext-Wiederholen nötig), zählt einmal; falscher authKey und Klartext-Fehler bleiben invalid_credentials', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const ip = '203.0.113.150';
      const c = world.client(ip);
      const body = (extra: Record<string, unknown>) => c.post('/api/v1/auth/login/password', { email: a.email, totp: '000000', ...extra });
      const falscherCode = await body({ authKey: ak });
      expect(falscherCode.status).toBe(401);
      expect(falscherCode.json.error).toBe('invalid_second_factor');
      expect((await body({ authKey: key() })).json.error).toBe('invalid_credentials');
      expect((await body({ password: PW })).json.error).toBe('invalid_credentials'); // Klartext verrät nie, ob das Passwort stimmt
      const n = (await harness.db.execute<{ n: number }>(sql`select count(*)::int as n from audit_log where event = 'login_failed'`)).rows[0]?.n;
      expect(n).toBe(3);
    });

    it('Upgrade gegen gleichzeitigen Passwortwechsel: nie bleibt ein Prüfwert des alten Passworts am neuen Eintrag', async () => {
      for (let i = 0; i < 3; i++) {
        await world?.close();
        await harness.reset();
        const a = await start();
        const alt = key();
        const neu = key();
        const code1 = await code(a);
        const [l, w] = await Promise.all([
          world.client('203.0.113.152').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: code1, upgradeAuthKey: alt }),
          a.client.post('/api/v1/me/password/change', { authKey: neu }),
        ]);
        expect(w.status).toBe(200);
        expect([200, 401]).toContain(l.status);
        expect(await rows()).toBeLessThanOrEqual(2);
        // aktiv gilt höchstens der neue authKey, nie der des Upgrades
        expect((await login(a, { authKey: alt }, '203.0.113.153')).res.status).toBe(401);
        expect((await login(a, { authKey: neu }, '203.0.113.154')).res.status).toBe(200);
      }
    });

    it('Passwortwechsel mit pwBackupId einer schon bestätigten (aktiven) Sicherung: 409, alles bleibt', async () => {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const c = world.client('203.0.113.155');
      const r = await c.post('/api/v1/auth/login/password', { email: a.email, authKey: ak, totp: await code(a) });
      c.adopt(r.json.session);
      await c.post('/api/v1/me/keys', keys());
      const b1 = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      await c.post('/api/v1/me/key-backup-pw/verified', { id: b1.json.id });
      const res = await c.post('/api/v1/me/password/change', { authKey: key(), pwBackupId: b1.json.id });
      expect(res.status).toBe(409);
      expect(res.json.error).toBe('backup_not_current');
      expect((await login(a, { authKey: ak }, '203.0.113.156')).res.status).toBe(200);
    });

    it('Passwort nach "entfernen" per Klartext neu einrichten, solange eine Passwort-Sicherung besteht: 409', async () => {
      const a = await start();
      await a.client.post('/api/v1/me/keys', keys());
      const put = await a.client.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      await a.client.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id });
      await harness.db.execute(sql`update credentials set revoked_at = now() where type in ('password', 'totp')`);
      const r = await a.client.post('/api/v1/me/password/start', { password: PW });
      expect(r.status).toBe(409);
      expect(r.json.error).toBe('password_change_needs_update');
      expect((await a.client.post('/api/v1/me/password/start', { authKey: key() })).status).toBe(200);
    });
  });

  describe('Stichtag AUTH_LEGACY_PASSWORD_LOGIN=false', () => {
    const ENV = { E2EE_PW_BACKUP: 'true', AUTH_LEGACY_PASSWORD_LOGIN: 'false' };

    it('Klartext-Anmeldung wird für JEDE E-Mail gleich abgewiesen (403 legacy_login_disabled), auch ohne Konto-Abfrage', async () => {
      const a = await start();
      await restart(ENV);
      const echt = await login(a, { password: PW });
      const fremd = await world.client('203.0.113.110').post('/api/v1/auth/login/password', { email: 'niemand@example.org', password: PW, totp: '123456' });
      for (const r of [echt.res, fremd]) {
        expect(r.status).toBe(403);
        expect(r.json.error).toBe('legacy_login_disabled');
      }
      expect(await auditEvents(world)).not.toContain('login_failed'); // zählt nicht als Fehlversuch
    });

    it('/version meldet den Schalter; authKey-Konten melden sich weiter an; Klartext-Passwortwechsel und -Einrichtung sind zu', async () => {
      const a = await start();
      await restart(ENV);
      const sitzung = world.client('203.0.113.111');
      sitzung.cookie = a.client.cookie;
      sitzung.csrf = a.client.csrf;
      expect((await world.client().get('/api/v1/version')).json.features).toMatchObject({ authKey: true, legacyPasswordLogin: false });
      // ein Konto, das vor dem Stichtag umgestellt wurde
      const ak = key();
      await harness.db.execute(sql`insert into password_authkeys (credential_id, user_id, auth_hash) select id, user_id, ${authKeyDigest(world.auth.ctx, '', 'x')} from credentials where type = 'password'`);
      const userId = (await harness.db.execute<{ id: string }>(sql`select id from users limit 1`)).rows[0]?.id ?? '';
      await harness.db.execute(sql`update password_authkeys set auth_hash = ${authKeyDigest(world.auth.ctx, userId, ak)}`);
      expect((await login(a, { authKey: ak })).res.status).toBe(200);
      expect((await sitzung.post('/api/v1/me/password/change', { password: 'ein-neues-langes-passwort-9' })).json.error).toBe('legacy_login_disabled');
      expect((await sitzung.post('/api/v1/me/password/start', { password: PW })).json.error).toBe('legacy_login_disabled');
    });

    it('Reset-Einladung: Registrierung nur mit authKey, E-Mail kommt aus dem Lookup, danach Anmeldung mit authKey', async () => {
      const a = await start();
      const inv = await a.client.post('/api/v1/invites', { role: 'child' });
      const m = await world.registerPassword(inv.json.invite.token, { email: 'kind@example.org', displayName: 'Kind' });
      const kindId = m.complete?.json.member.id as string;
      await restart(ENV);
      const sitzung = world.client('203.0.113.160');
      sitzung.cookie = a.client.cookie;
      sitzung.csrf = a.client.csrf;
      const reset = await sitzung.post(`/api/v1/members/${kindId}/reset`, { hours: 2, pin: false });
      expect(reset.status).toBe(200);
      const token = reset.json.invite.token as string;
      const anon = world.client('203.0.113.161');
      expect((await anon.post('/api/v1/auth/invites/lookup', { token })).json.invite.email).toBe('kind@example.org');
      expect((await anon.post('/api/v1/auth/invites/password/start', { token, password: PW })).json.error).toBe('legacy_login_disabled');
      const ak = key();
      const s2 = await anon.post('/api/v1/auth/invites/password/start', { token, authKey: ak });
      expect(s2.status).toBe(200);
      world.advance(31_000);
      const done = await anon.post('/api/v1/auth/invites/password/complete', { challengeId: s2.json.challengeId, code: await world.totp(s2.json.totpSecret) });
      expect(done.status).toBe(200);
      world.advance(31_000);
      const l = await world.client('203.0.113.162').post('/api/v1/auth/login/password', { email: 'kind@example.org', authKey: ak, totp: await world.totp(s2.json.totpSecret) });
      expect(l.status).toBe(200);
    });

    it('Registrierung mit Klartext ist zu, mit authKey möglich; danach Anmeldung mit authKey', async () => {
      const a = await start();
      const inv = await a.client.post('/api/v1/invites', { role: 'parent' });
      const token = inv.json.invite.token as string;
      await restart(ENV);
      const c = world.client('203.0.113.120');
      const klar = await c.post('/api/v1/auth/invites/password/start', { token, email: 'mama@example.org', displayName: 'Mama', password: PW });
      expect(klar.json.error).toBe('legacy_login_disabled');
      const ak = key();
      const s = await c.post('/api/v1/auth/invites/password/start', { token, email: 'mama@example.org', displayName: 'Mama', authKey: ak });
      expect(s.status).toBe(200);
      world.advance(31_000);
      const done = await c.post('/api/v1/auth/invites/password/complete', { challengeId: s.json.challengeId, code: await world.totp(s.json.totpSecret) });
      expect(done.status).toBe(200);
      const c2 = world.client('203.0.113.121');
      world.advance(31_000);
      const ok = await c2.post('/api/v1/auth/login/password', { email: 'mama@example.org', authKey: ak, totp: await world.totp(s.json.totpSecret) });
      expect(ok.status).toBe(200);
      // der Platzhalter im Passwort-Eintrag ist nie per Klartext anmeldbar (Schalter an)
      const sec = (await harness.db.execute<{ secret: string }>(sql`select secret from credentials where type = 'password' order by created_at desc limit 1`)).rows[0]?.secret;
      expect(sec).toBe('!authkey');
    });
  });

  describe('Passwortwechsel mit authKey', () => {
    async function umgestellt() {
      const a = await start();
      const ak = key();
      await login(a, { password: PW, upgradeAuthKey: ak });
      const c = world.client('203.0.113.130');
      const r = await c.post('/api/v1/auth/login/password', { email: a.email, authKey: ak, totp: await code(a) });
      c.adopt(r.json.session);
      return { a, ak, c };
    }

    it('braucht Step-up; danach gilt nur noch der neue authKey, der alte Klartext-Hash ist ersetzt', async () => {
      const { a, ak, c } = await umgestellt();
      world.advance(20 * 60_000); // Step-up der Anmeldung abgelaufen
      expect((await c.post('/api/v1/me/password/change', { authKey: key() })).json.error).toBe('step_up_required');
      const neu = key();
      const s = await c.post('/api/v1/auth/step-up/code', { totp: await code(a) });
      expect(s.status).toBe(200);
      expect((await c.post('/api/v1/me/password/change', { authKey: neu })).status).toBe(200);
      expect((await login(a, { authKey: ak })).res.status).toBe(401);
      expect((await login(a, { authKey: neu })).res.status).toBe(200);
      expect((await login(a, { password: PW })).res.status).toBe(401); // alter Klartext gilt nicht mehr
      expect(await mode(a, c)).toBe('authkey');
      const ev = await harness.db.execute<{ detail: { authKey?: boolean } }>(sql`select detail from audit_log where event = 'password_changed'`);
      expect(ev.rows[0]?.detail).toMatchObject({ authKey: true, backup: false });
    });

    it('Klartext-Wechsel eines authkey-Kontos wird abgelehnt (409 password_change_needs_update), nichts ändert sich', async () => {
      const { a, ak, c } = await umgestellt();
      const r = await c.post('/api/v1/me/password/change', { password: 'ein-neues-langes-passwort-9' });
      expect(r.status).toBe(409);
      expect(r.json.error).toBe('password_change_needs_update');
      expect((await login(a, { authKey: ak })).res.status).toBe(200);
      expect((await login(a, { password: PW })).res.status).toBe(200);
    });

    it('legacy-Konto mit Passwort-Sicherung: Klartext-Wechsel ebenfalls abgelehnt (die Sicherung bliebe sonst unlesbar)', async () => {
      const a = await start();
      await a.client.post('/api/v1/me/keys', keys());
      const put = await a.client.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      await a.client.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id });
      const r = await a.client.post('/api/v1/me/password/change', { password: 'ein-neues-langes-passwort-9' });
      expect(r.json.error).toBe('password_change_needs_update');
    });

    it('legacy-Konto ohne Sicherung: Klartext-Wechsel wie bisher (alte Apps)', async () => {
      const a = await start();
      expect((await a.client.post('/api/v1/me/password/change', { password: 'ein-neues-langes-passwort-9' })).status).toBe(200);
      expect(await mode(a)).toBe('legacy');
    });

    it('mit pwBackupId: Passwort und Sicherung werden gemeinsam gültig (atomar)', async () => {
      const { a, c } = await umgestellt();
      await c.post('/api/v1/me/keys', keys());
      const b1 = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      await c.post('/api/v1/me/key-backup-pw/verified', { id: b1.json.id });
      const b2 = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect(b2.status).toBe(200);
      const neu = key();
      const r = await c.post('/api/v1/me/password/change', { authKey: neu, pwBackupId: b2.json.id });
      expect(r.status).toBe(200);
      const st = (await harness.db.execute<{ id: string; state: string }>(sql`select id, state from key_backups_pw`)).rows;
      expect(st.find((x) => x.id === b2.json.id)?.state).toBe('active');
      expect(st.find((x) => x.id === b1.json.id)?.state).toBe('superseded');
      expect((await login(a, { authKey: neu })).res.status).toBe(200);
    });

    it('ungültige pwBackupId: alles wird zurückgerollt (altes Passwort und alte Sicherung bleiben)', async () => {
      const { a, ak, c } = await umgestellt();
      await c.post('/api/v1/me/keys', keys());
      const b1 = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      await c.post('/api/v1/me/key-backup-pw/verified', { id: b1.json.id });
      const fremd = await c.post('/api/v1/me/password/change', { authKey: key(), pwBackupId: '00000000-0000-4000-8000-000000000009' });
      expect(fremd.status).toBe(404);
      expect((await login(a, { authKey: ak })).res.status).toBe(200);
      expect((await harness.db.execute<{ state: string }>(sql`select state from key_backups_pw`)).rows.map((x) => x.state)).toEqual(['active']);
      // pwBackupId nur zusammen mit authKey
      expect((await c.post('/api/v1/me/password/change', { password: 'ein-neues-langes-passwort-9', pwBackupId: b1.json.id })).status).toBe(400);
    });

    it('Passwort einrichten (Passkey-Konto) mit authKey; Konto ist danach authkey, Klartext nie gespeichert', async () => {
      world = await World.create(harness.db, { E2EE_PW_BACKUP: 'true' });
      const { adminPasskey } = await import('./helpers.js');
      const a = await adminPasskey(world);
      const c = world.client('203.0.113.140');
      await world.loginPasskey(c, a.authenticator);
      const ak = key();
      const s = await c.post('/api/v1/me/password/start', { authKey: ak });
      expect(s.status).toBe(200);
      world.advance(31_000);
      expect((await c.post('/api/v1/me/password/complete', { challengeId: s.json.challengeId, code: await world.totp(s.json.totpSecret) })).status).toBe(200);
      expect(await rows()).toBe(1);
      world.advance(31_000);
      const l = await world.client('203.0.113.141').post('/api/v1/auth/login/password', { email: a.email, authKey: ak, totp: await world.totp(s.json.totpSecret) });
      expect(l.status).toBe(200);
    });

    it('Passwort entfernen ohne Passkey bleibt gesperrt; der authKey-Zugang bleibt dann unverändert', async () => {
      const { a, ak, c } = await umgestellt();
      expect((await c.del('/api/v1/me/password')).status).toBe(409);
      expect((await login(a, { authKey: ak })).res.status).toBe(200);
    });
  });

  describe('Wartung', () => {
    it('Prüfwert verschwindet mit dem Passwort-Eintrag (Löschen des Kontos kaskadiert)', async () => {
      const a = await start();
      await login(a, { password: PW, upgradeAuthKey: key() });
      expect(await rows()).toBe(1);
      await harness.db.execute(sql`delete from users where email = ${a.email}`);
      expect(await rows()).toBe(0);
    });
  });

  it('Admin-Übersicht (nur lesend): legacy/authkey/none je Mitglied, nur für Admins, ohne Prüfwert; /members bleibt unverändert', async () => {
    const a = await start();
    const inv = await a.client.post('/api/v1/invites', { role: 'child' });
    const m = await world.registerPassword(inv.json.invite.token, { email: 'kind@example.org', displayName: 'Kind' });
    expect(await mode(a)).toBe('legacy');
    const kind = m.client as Client;
    expect((await kind.get('/api/v1/members/password-modes')).status).toBe(403);
    expect((await world.client().get('/api/v1/members/password-modes')).status).toBe(401);
    const roh = JSON.stringify((await a.client.get('/api/v1/members/password-modes')).json);
    expect(roh).not.toMatch(/auth_hash|authHash|authKey/);
    expect(roh).toContain('"legacyPasswordLogin":true');
    expect(JSON.stringify((await a.client.get('/api/v1/members')).json)).not.toMatch(/passwordMode|authHash/);
    await a.client.post('/api/v1/auth/logout').catch(() => undefined);
  });

  it('Einladung zum Zurücksetzen nennt die E-Mail des Kontos nur mit Schalter (die App braucht sie für den Salt), eine normale Einladung nie', async () => {
    for (const schalter of [true, false]) {
      await world?.close();
      await harness.reset();
      const a = await start(schalter ? { E2EE_PW_BACKUP: 'true' } : {});
      const inv = await a.client.post('/api/v1/invites', { role: 'child' });
      const m = await world.registerPassword(inv.json.invite.token, { email: 'kind@example.org', displayName: 'Kind' });
      const kindId = m.complete?.json.member.id as string;
      const normal = await a.client.post('/api/v1/invites', { role: 'child' });
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: normal.json.invite.token })).json.invite).not.toHaveProperty('email');
      const reset = await a.client.post(`/api/v1/members/${kindId}/reset`, { hours: 2, pin: false });
      expect(reset.status).toBe(200);
      const look = await world.client().post('/api/v1/auth/invites/lookup', { token: reset.json.invite.token });
      expect(look.json.invite.reset).toBe(true);
      if (schalter) expect(look.json.invite.email).toBe('kind@example.org');
      else expect(look.json.invite).not.toHaveProperty('email');
    }
  });

  it('Admin-Übersicht gibt es ohne Schalter nicht (404)', async () => {
    const a = await start({});
    expect((await a.client.get('/api/v1/members/password-modes')).status).toBe(404);
  });
});
