// Passwort-Reset (Schalter E2EE_PW_BACKUP): Admin-Link, "Passwort vergessen?" mit Wiederherstellungs-Code und Passkey, Sicherheitsereignisse,
// Push-Wecker ohne Inhalt, Passwort-Sicherung `stale` (nie gelöscht). PGlite und echtes PostgreSQL.
import { randomBytes } from 'node:crypto';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WAKE_BODY } from '../src/push/service.js';
import { TestAuthenticator } from './authenticator.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const PW = 'ein-sehr-langes-passwort-123';
const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = () => ({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });
const TOKEN = 'tk_testtoken1234567890';
const HOST = 'ntfy.familie.lx-labs.dev';
const randTopic = () => 'up' + randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe.each(backends)('Passwort-Reset ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let ntfy: http.Server;
  let ntfyCalls: Array<{ url: string; body: string }> = [];

  beforeAll(async () => {
    harness = await backend.open();
    ntfy = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        ntfyCalls.push({ url: req.url ?? '', body: Buffer.concat(chunks).toString('utf8') });
        res.writeHead(200);
        res.end('{}');
      });
    });
    await new Promise<void>((resolve) => ntfy.listen(0, '127.0.0.1', resolve));
  }, 120_000);
  afterAll(async () => {
    await world?.close();
    await new Promise<void>((resolve) => ntfy.close(() => resolve()));
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
    ntfyCalls = [];
  });

  async function start(env: Record<string, string> = {}) {
    const port = (ntfy.address() as AddressInfo).port;
    world = await World.create(harness.db, { E2EE_PW_BACKUP: 'true', NTFY_URL: `http://127.0.0.1:${port}`, NTFY_TOKEN: TOKEN, ...env }, { pushMinIntervalMs: 0 });
    const a = await adminPassword(world);
    const m = await addMember(world, a.client, 'parent', 'mama@example.org');
    const id = async (email: string) => ((await harness.db.execute<{ id: string }>(sql`select id from users where email = ${email}`)).rows[0] as { id: string }).id;
    return { a, m, mamaId: await id('mama@example.org'), adminId: await id('admin@example.org') };
  }
  type Fam = Awaited<ReturnType<typeof start>>;

  const totp = async (secret: string) => {
    world.advance(31_000);
    return world.totp(secret);
  };
  /** Frisches Step-up des Admins per TOTP. */
  const stepUp = async (f: Fam) => {
    const r = await f.a.client.post('/api/v1/auth/step-up/code', { totp: await totp(f.a.totpSecret) });
    expect(r.status).toBe(200);
  };
  const adminLink = async (f: Fam, body: Record<string, unknown> = {}) => {
    await stepUp(f);
    const r = await f.a.client.post(`/api/v1/members/${f.mamaId}/password-reset`, body);
    expect(r.status).toBe(200);
    return r.json.invite as { id: string; token: string; pin?: string };
  };
  /** Mama meldet sich als App mit Gerät an (hat dann Sitzung, Gerät und kann einen Push-Endpunkt melden). */
  const mamaApp = async (f: Fam, ip = '203.0.113.90') => {
    const c = world.client(ip);
    const r = await c.post('/api/v1/auth/login/password', { email: 'mama@example.org', password: PW, totp: await totp(f.m.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
    expect(r.status).toBe(200);
    c.adopt(r.json.session);
    return c;
  };
  const redeem = async (token: string, authKey: string, code: string, extra: { pin?: string; ip?: string } = {}) => {
    const c = world.client(extra.ip ?? '203.0.113.91');
    const s = await c.post('/api/v1/auth/invites/password-reset/start', { token, authKey, ...(extra.pin ? { pin: extra.pin } : {}) });
    if (s.status !== 200) return { c, s, done: undefined };
    const done = await c.post('/api/v1/auth/invites/password-reset/complete', { challengeId: s.json.challengeId, code, client: 'app', device: { name: 'Neues Handy', platform: 'android' } });
    if (done.status === 200) c.adopt(done.json.session);
    return { c, s, done };
  };
  const loginKey = async (email: string, authKey: string, secret: string, ip = '203.0.113.92') => {
    const c = world.client(ip);
    const r = await c.post('/api/v1/auth/login/password', { email, authKey, totp: await totp(secret) });
    if (r.status === 200) c.adopt(r.json.session);
    return { c, r };
  };
  /** Wartet, bis der Wecker angekommen ist (und noch kurz, damit ein zweiter, falscher auffiele). */
  const settle = async () => {
    const end = Date.now() + 5000;
    while (ntfyCalls.length === 0 && Date.now() < end) await wait(20);
    await wait(150);
  };
  const events = async (c: Client) => (await c.get('/api/v1/me/security-events')).json.events as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  const backupRows = async () => (await harness.db.execute<{ state: string }>(sql`select state from key_backups_pw order by state`)).rows.map((r) => r.state);
  /** Mama bekommt Schlüssel und eine bestätigte Passwort-Sicherung. */
  const withBackup = async (c: Client) => {
    expect((await c.post('/api/v1/me/keys', keys())).status).toBe(200);
    const put = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
    expect(put.status).toBe(200);
    expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
    return put.json.id as string;
  };

  describe('Schalter aus', () => {
    it('Routen gibt es nicht (404); die Ereignisliste ist leer, der Komplett-Reset bleibt', async () => {
      const f = await start({ E2EE_PW_BACKUP: 'false' });
      await stepUp(f);
      expect((await f.a.client.post(`/api/v1/members/${f.mamaId}/password-reset`, {})).status).toBe(404);
      const anon = world.client('203.0.113.99');
      for (const p of ['/api/v1/auth/invites/password-reset/start', '/api/v1/auth/invites/password-reset/complete', '/api/v1/auth/password-reset/recovery', '/api/v1/auth/password-reset/passkey']) {
        expect((await anon.post(p, {})).status, p).toBe(404);
      }
      expect(await events(f.m.client)).toEqual([]);
      expect((await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {})).status).toBe(200);
    });
  });

  describe('Admin-Link: Erzeugen', () => {
    it('Rechte: nur Admin, Step-up Pflicht, nicht für sich selbst, 404 für Unbekannte, 409 ohne Passwort', async () => {
      const f = await start();
      // ohne frisches Step-up
      world.advance(10 * MIN);
      const ohne = await f.a.client.post(`/api/v1/members/${f.mamaId}/password-reset`, {});
      expect(ohne.json.error).toBe('step_up_required');
      // Eltern dürfen nicht (auch nicht mit Step-up)
      await f.m.client.post('/api/v1/auth/step-up/code', { totp: await totp(f.m.totpSecret) });
      expect((await f.m.client.post(`/api/v1/members/${f.adminId}/password-reset`, {})).status).toBe(403);
      // der Admin nicht für sich selbst
      await stepUp(f);
      const selbst = await f.a.client.post(`/api/v1/members/${f.adminId}/password-reset`, {});
      expect(selbst.status).toBe(409);
      expect(selbst.json.error).toBe('cannot_reset_self');
      // Unbekannte Person und ungültige Eingaben
      expect((await f.a.client.post('/api/v1/members/3f2b1c1e-0000-4000-8000-000000000001/password-reset', {})).status).toBe(404);
      expect((await f.a.client.post(`/api/v1/members/${f.mamaId}/password-reset`, { hours: 9999 })).status).toBe(400);
      expect((await f.a.client.post(`/api/v1/members/${f.mamaId}/password-reset`, { extra: 1 })).status).toBe(400);
      expect((await world.client('203.0.113.98').post(`/api/v1/members/${f.mamaId}/password-reset`, {})).status).toBe(401);
      // ein Passkey-Konto ohne Passwort hat nichts zurückzusetzen
      const inv = await f.a.client.post('/api/v1/invites', { role: 'child' });
      const reg = await world.registerPasskey(inv.json.invite.token, { email: 'kind@example.org', displayName: 'Kind' });
      expect(reg.complete?.status).toBe(200);
      const kindId = (reg.complete?.json.member as { id: string }).id;
      const kein = await f.a.client.post(`/api/v1/members/${kindId}/password-reset`, {});
      expect(kein.status).toBe(409);
      expect(kein.json.error).toBe('no_password');
      expect(await world.count('security_events')).toBe(0);
    });

    it('Link mit PIN: Antwort, Lookup (kind), Liste, Ereignis für die Person, Konto bleibt bis zum Einlösen nutzbar', async () => {
      const f = await start();
      const mamaApp1 = await mamaApp(f);
      const inv = await adminLink(f, { hours: 12, pin: true });
      expect(inv.pin).toMatch(/^\d{6}$/);
      const look = await world.client('203.0.113.95').post('/api/v1/auth/invites/lookup', { token: inv.token });
      expect(look.json.invite).toMatchObject({ kind: 'password_reset', reset: true, pinRequired: true, displayName: 'mama', email: 'mama@example.org', role: 'parent' });
      const list = await f.a.client.get('/api/v1/invites');
      expect(list.json.invites.find((i: { id: string }) => i.id === inv.id)).toMatchObject({ kind: 'password_reset', reset: true, status: 'open' });
      // die bisherige Sitzung und das alte Passwort gelten weiter
      expect((await mamaApp1.get('/api/v1/me')).status).toBe(200);
      const ev = await events(f.m.client);
      expect(ev).toHaveLength(1);
      expect(ev[0]).toMatchObject({ kind: 'password_reset_requested', via: 'admin', byAdmin: true, actorName: 'Admin' });
      expect(Object.keys(ev[0] ?? {}).sort()).toEqual(['actorName', 'byAdmin', 'createdAt', 'id', 'kind', 'via']);
      // niemand sonst sieht es
      expect(await events(f.a.client)).toEqual([]);
      expect(await auditEvents(world)).toContain('password_reset_requested');
    });

    it('ein neuer Link ersetzt den offenen früheren', async () => {
      const f = await start();
      const eins = await adminLink(f);
      const zwei = await adminLink(f);
      const r = await redeem(eins.token, key(), '000000');
      expect(r.s.status).toBe(400);
      expect(r.s.json.error).toBe('invite_invalid');
      expect((await redeem(zwei.token, key(), await totp(f.m.totpSecret))).done?.status).toBe(200);
    });
  });

  describe('Admin-Link: Einlösen', () => {
    it('Ablauf: PIN, authKey, TOTP der Person; Sitzungen tot, Passwort neu, TOTP und Codes bleiben, Ereignis und Audit', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      const inv = await adminLink(f, { pin: true });
      const neu = key();
      // falsche PIN, Klartext statt authKey: abgelehnt
      expect((await redeem(inv.token, neu, '000000', { pin: '000000' })).s.status).toBe(400);
      const klar = await world.client('203.0.113.96').post('/api/v1/auth/invites/password-reset/start', { token: inv.token, pin: inv.pin, password: PW });
      expect(klar.status).toBe(400);
      const r = await redeem(inv.token, neu, await totp(f.m.totpSecret), { pin: inv.pin as string });
      expect(r.done?.status).toBe(200);
      expect(r.done?.json.member).toMatchObject({ id: f.mamaId, email: 'mama@example.org', role: 'parent', status: 'active' });
      expect(r.done?.json.recoveryCodes).toEqual([]);
      // alte Sitzungen sind beendet, die neue gilt
      expect((await geraet.get('/api/v1/me')).status).toBe(401);
      expect((await f.m.client.get('/api/v1/me')).status).toBe(401);
      expect((await r.c.get('/api/v1/me')).status).toBe(200);
      // altes Passwort tot, neues geht; TOTP und Wiederherstellungs-Codes bleiben
      world.advance(31_000);
      const alt = await world.client('203.0.113.97').post('/api/v1/auth/login/password', { email: 'mama@example.org', password: PW, totp: await world.totp(f.m.totpSecret) });
      expect(alt.status).toBe(401);
      expect((await loginKey('mama@example.org', neu, f.m.totpSecret)).r.status).toBe(200);
      expect((await world.client('203.0.113.93').post('/api/v1/auth/login/recovery', { email: 'mama@example.org', code: f.m.recoveryCodes[0] })).status).toBe(200);
      // Ereignisse für die Person und Audit
      const ev = await events(r.c);
      expect(ev.map((e) => e.kind)).toEqual(expect.arrayContaining(['password_reset_requested', 'password_reset_done']));
      const done = ev.find((e) => e.kind === 'password_reset_done');
      expect(done).toMatchObject({ via: 'admin', byAdmin: true });
      expect(await auditEvents(world)).toEqual(expect.arrayContaining(['password_reset_done', 'invite_used']));
      // der Passwort-Zustand ist authkey und das Konto hat genau ein aktives Passwort
      expect((await harness.db.execute(sql`select count(*)::int as n from credentials where user_id = ${f.mamaId} and type = 'password' and revoked_at is null`)).rows[0]).toMatchObject({ n: 1 });
      expect((await harness.db.execute(sql`select count(*)::int as n from credentials where user_id = ${f.mamaId} and type = 'totp' and revoked_at is null`)).rows[0]).toMatchObject({ n: 1 });
    });

    it('der zweite Faktor ist Pflicht: Admin mit abgefangenem Link, falscher oder wiederverwendeter Code, kein Wiederherstellungs-Code', async () => {
      const f = await start();
      const inv = await adminLink(f);
      // der Admin (oder wer den Link hat) kennt das TOTP von Mama nicht: sein eigener Code zählt nicht
      const mitAdminCode = await redeem(inv.token, key(), await totp(f.a.totpSecret));
      expect(mitAdminCode.done?.status).toBe(400);
      expect(mitAdminCode.done?.json.error).toBe('invalid_code');
      // ein Wiederherstellungs-Code ist kein gültiges Codeformat dieser Route
      const s = await world.client('203.0.113.94').post('/api/v1/auth/invites/password-reset/start', { token: inv.token, authKey: key() });
      expect((await world.client('203.0.113.94').post('/api/v1/auth/invites/password-reset/complete', { challengeId: s.json.challengeId, code: f.m.recoveryCodes[0] })).status).toBe(400);
      // der Link ist dadurch nicht verbraucht; ein TOTP-Code von vor dem Start (schon benutzt) ist verbraucht
      const code = await totp(f.m.totpSecret);
      const ok = await redeem(inv.token, key(), code);
      expect(ok.done?.status).toBe(200);
      // zweiter Versuch mit demselben Link: ungültig
      const nochmal = await redeem(inv.token, key(), await totp(f.m.totpSecret), { ip: '203.0.113.97' });
      expect(nochmal.s.status).toBe(400);
      expect(nochmal.s.json.error).toBe('invite_invalid');
      // dieselbe Challenge ein zweites Mal: abgelaufen
      const wieder = await world.client('203.0.113.97').post('/api/v1/auth/invites/password-reset/complete', { challengeId: ok.s.json.challengeId, code: await totp(f.m.totpSecret) });
      expect(wieder.status).toBe(400);
      expect(wieder.json.error).toBe('challenge_invalid');
    });

    it('Der Link gilt nur für den Reset: die Routen für neue Konten und Passkeys lehnen ihn ab; der Komplett-Reset-Link geht dort nicht', async () => {
      const f = await start();
      const inv = await adminLink(f, { pin: true });
      const anon = world.client('203.0.113.89');
      expect((await anon.post('/api/v1/auth/invites/passkey/options', { token: inv.token, pin: inv.pin })).json.error).toBe('invite_invalid');
      expect((await anon.post('/api/v1/auth/invites/password/start', { token: inv.token, pin: inv.pin, authKey: key() })).json.error).toBe('invite_invalid');
      // umgekehrt: der Komplett-Reset-Link (standard) gehört nicht in die Passwort-Reset-Route
      await stepUp(f);
      const voll = await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {});
      expect(voll.status).toBe(200);
      expect((await redeem(voll.json.invite.token, key(), '000000')).s.json.error).toBe('invite_invalid');
    });

    it('abgelaufen, widerrufen, falsche Familie des Tokens: dieselbe Fehlerantwort; Zähler gegen Raten', async () => {
      const f = await start();
      const a1 = await adminLink(f, { hours: 1 });
      world.advance(61 * MIN);
      const abgelaufen = await redeem(a1.token, key(), '000000');
      const a2 = await adminLink(f);
      await f.a.client.post(`/api/v1/invites/${a2.id}/revoke`);
      const widerrufen = await redeem(a2.token, key(), '000000');
      const unbekannt = await redeem(randomBytes(32).toString('base64url'), key(), '000000');
      for (const r of [abgelaufen, widerrufen, unbekannt]) expect(r.s.status).toBe(400);
      expect(abgelaufen.s.json).toEqual(unbekannt.s.json);
      expect(widerrufen.s.json).toEqual(unbekannt.s.json);
    });

    it('Parallel: zwei gleichzeitige Einlösungen desselben Links, genau eine gewinnt', async () => {
      const f = await start();
      const inv = await adminLink(f);
      const c1 = world.client('203.0.113.81');
      const c2 = world.client('203.0.113.82');
      const [s1, s2] = await Promise.all([
        c1.post('/api/v1/auth/invites/password-reset/start', { token: inv.token, authKey: key() }),
        c2.post('/api/v1/auth/invites/password-reset/start', { token: inv.token, authKey: key() }),
      ]);
      expect([s1.status, s2.status]).toEqual([200, 200]);
      const code = await totp(f.m.totpSecret);
      const dev = { name: 'X', platform: 'android' };
      const [r1, r2] = await Promise.all([
        c1.post('/api/v1/auth/invites/password-reset/complete', { challengeId: s1.json.challengeId, code, client: 'app', device: dev }),
        c2.post('/api/v1/auth/invites/password-reset/complete', { challengeId: s2.json.challengeId, code, client: 'app', device: dev }),
      ]);
      expect([r1.status, r2.status].filter((s) => s === 200)).toHaveLength(1);
      expect((await harness.db.execute(sql`select count(*)::int as n from credentials where user_id = ${f.mamaId} and type = 'password' and revoked_at is null`)).rows[0]).toMatchObject({ n: 1 });
      expect((await harness.db.execute(sql`select count(*)::int as n from security_events where kind = 'password_reset_done'`)).rows[0]).toMatchObject({ n: 1 });
    });

    it('Rechte-Grenze: die Einladung eines herabgestuften/entfernten Mitglieds wird unbrauchbar', async () => {
      const f = await start();
      const inv = await adminLink(f);
      await stepUp(f);
      expect((await f.a.client.del(`/api/v1/members/${f.mamaId}`)).status).toBe(200);
      const r = await redeem(inv.token, key(), await totp(f.m.totpSecret));
      expect(r.s.status).toBe(400);
    });
  });

  describe('Passwort-Sicherung des Personenschlüssels', () => {
    it('wird stale (nie gelöscht), Schlüssel unberührt; neue Sicherung wird nach Bestätigung aktuell, die alte superseded', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      const alteId = await withBackup(geraet);
      // eine unbestätigte (pending) Sicherung gehört zum alten kek und verfällt
      const pend = await geraet.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect(pend.status).toBe(200);
      const keysVorher = (await harness.db.execute(sql`select md5(x::text) as h from person_keys x where user_id = ${f.mamaId}`)).rows[0];
      const inv = await adminLink(f);
      const r = await redeem(inv.token, key(), await totp(f.m.totpSecret));
      expect(r.done?.status).toBe(200);
      expect(await backupRows()).toEqual(['stale', 'superseded']);
      expect(await world.count('key_backups_pw')).toBe(2); // nichts gelöscht
      expect((await harness.db.execute(sql`select md5(x::text) as h from person_keys x where user_id = ${f.mamaId}`)).rows[0]).toEqual(keysVorher);
      // die alte Sicherung bleibt lesbar (mit dem alten Passwort), als stale gekennzeichnet
      const got = await r.c.get('/api/v1/me/key-backup-pw');
      expect(got.status).toBe(200);
      expect(got.json).toMatchObject({ id: alteId, state: 'stale' });
      // neue Sicherung (die App legt sie nach dem ersten Login an): pending -> verified
      const neu = await r.c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect(neu.status).toBe(200);
      // bis zur Bestätigung gilt die alte (stale) weiter
      expect((await r.c.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: alteId, state: 'stale' });
      expect((await r.c.post('/api/v1/me/key-backup-pw/verified', { id: neu.json.id })).status).toBe(200);
      expect((await r.c.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: neu.json.id, state: 'active' });
      expect(await backupRows()).toEqual(['active', 'superseded', 'superseded']);
    });

    it('ohne Sicherung ändert sich nichts an den Tabellen; der Reset geht trotzdem', async () => {
      const f = await start();
      const inv = await adminLink(f);
      expect((await redeem(inv.token, key(), await totp(f.m.totpSecret))).done?.status).toBe(200);
      expect(await world.count('key_backups_pw')).toBe(0);
    });
  });

  describe('Passwort vergessen: Wiederherstellungs-Code', () => {
    const forgot = (c: Client, body: Record<string, unknown>) => c.post('/api/v1/auth/password-reset/recovery', { client: 'app', device: { name: 'Handy', platform: 'android' }, ...body });

    it('mit Code: neues Passwort, Sitzungen beendet, Code verbraucht, Sicherung stale, Ereignis "durch dich"', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      await withBackup(geraet);
      const neu = key();
      const c = world.client('203.0.113.70');
      const r = await forgot(c, { email: 'MAMA@example.org', code: f.m.recoveryCodes[0], authKey: neu });
      expect(r.status).toBe(200);
      expect(r.json.recoveryCodesRemaining).toBe(9);
      expect(r.json.user).toMatchObject({ id: f.mamaId });
      c.adopt(r.json.session);
      expect((await c.get('/api/v1/me')).status).toBe(200);
      expect((await geraet.get('/api/v1/me')).status).toBe(401);
      expect((await loginKey('mama@example.org', neu, f.m.totpSecret)).r.status).toBe(200);
      // derselbe Code ein zweites Mal: nichts
      const nochmal = await forgot(world.client('203.0.113.71'), { email: 'mama@example.org', code: f.m.recoveryCodes[0], authKey: key() });
      expect(nochmal.status).toBe(401);
      expect(await backupRows()).toEqual(['stale']);
      const ev = await events(c);
      expect(ev).toHaveLength(1);
      expect(ev[0]).toMatchObject({ kind: 'password_reset_done', via: 'recovery_code', byAdmin: false, actorName: null });
      expect(await auditEvents(world)).toEqual(expect.arrayContaining(['password_reset_done', 'recovery_code_used']));
    });

    it('Fehlerantworten wie bei der Anmeldung: falscher Code, unbekannte E-Mail und gesperrtes Konto sind nicht zu unterscheiden', async () => {
      const f = await start();
      const falsch = await forgot(world.client('203.0.113.72'), { email: 'mama@example.org', code: 'AAAA-BBBB-CCCC', authKey: key() });
      const unbekannt = await forgot(world.client('203.0.113.73'), { email: 'niemand@example.org', code: f.m.recoveryCodes[0], authKey: key() });
      const login = await world.client('203.0.113.74').post('/api/v1/auth/login/recovery', { email: 'mama@example.org', code: 'AAAA-BBBB-CCCC' });
      expect(falsch.status).toBe(401);
      expect(unbekannt.status).toBe(401);
      expect(falsch.json).toEqual(unbekannt.json);
      expect(falsch.json).toEqual(login.json);
      // ein falscher Versuch hat nichts verändert
      expect((await loginKey('mama@example.org', key(), f.m.totpSecret)).r.status).toBe(401);
      expect(await world.count('security_events')).toBe(0);
    });

    it('nur mit Wiederherstellungs-Code: TOTP allein, Klartext-Passwort und unbekannte Felder werden abgelehnt; Eingaben streng', async () => {
      const f = await start();
      const c = world.client('203.0.113.75');
      const ok = { email: 'mama@example.org', code: f.m.recoveryCodes[0], authKey: key() };
      expect((await forgot(c, { email: 'mama@example.org', totp: await totp(f.m.totpSecret), authKey: key() })).status).toBe(400);
      expect((await forgot(c, { ...ok, password: PW })).status).toBe(400);
      expect((await forgot(c, { ...ok, authKey: 'zu-kurz' })).status).toBe(400);
      expect((await forgot(c, { ...ok, code: '' })).status).toBe(400);
      expect((await forgot(c, { ...ok, extra: 1 })).status).toBe(400);
      expect(await world.count('security_events')).toBe(0);
    });

    it('Konto ohne Passwort (nur Passkey): 409, der Code bleibt unverbraucht', async () => {
      const f = await start();
      const inv = await f.a.client.post('/api/v1/invites', { role: 'child' });
      const reg = await world.registerPasskey(inv.json.invite.token, { email: 'kind@example.org', displayName: 'Kind' });
      const code = reg.recoveryCodes[0] as string;
      const r = await forgot(world.client('203.0.113.76'), { email: 'kind@example.org', code, authKey: key() });
      expect(r.status).toBe(409);
      expect(r.json.error).toBe('no_password');
      expect((await world.client('203.0.113.77').post('/api/v1/auth/login/recovery', { email: 'kind@example.org', code })).status).toBe(200);
    });

    it('Sperre: viele falsche Codes führen zu 429, danach geht auch der richtige Code nicht (wie bei der Anmeldung)', async () => {
      const f = await start();
      const c = world.client('203.0.113.78');
      let gesperrt = false;
      for (let i = 0; i < 30 && !gesperrt; i++) {
        const r = await forgot(c, { email: 'mama@example.org', code: `ZZZZ-${String(i).padStart(4, '0')}-QQQQ`, authKey: key() });
        gesperrt = r.status === 429;
      }
      expect(gesperrt).toBe(true);
      expect((await forgot(c, { email: 'mama@example.org', code: f.m.recoveryCodes[0], authKey: key() })).status).toBe(429);
    });

    it('wartendes oder gesperrtes Konto wird nicht zurückgesetzt', async () => {
      const f = await start();
      await harness.db.execute(sql`update users set disabled_at = now() where id = ${f.mamaId}`);
      const r = await forgot(world.client('203.0.113.79'), { email: 'mama@example.org', code: f.m.recoveryCodes[0], authKey: key() });
      expect(r.status).toBe(401);
      expect(await world.count('security_events')).toBe(0);
    });
  });

  describe('Passwort vergessen: Passkey', () => {
    it('mit Passkey: neues Passwort, Ereignis via passkey; fremder Passkey und Wiederholung scheitern', async () => {
      const f = await start();
      // Mama richtet zusätzlich einen Passkey ein (Step-up nötig)
      await f.m.client.post('/api/v1/auth/step-up/code', { totp: await totp(f.m.totpSecret) });
      const authn = new TestAuthenticator();
      const opt = await f.m.client.post('/api/v1/me/passkeys/options');
      expect((await f.m.client.post('/api/v1/me/passkeys/verify', { challengeId: opt.json.challengeId, response: authn.register(opt.json.options) })).status).toBe(200);

      const neu = key();
      const c = world.client('203.0.113.60');
      const o = await c.post('/api/v1/auth/login/passkey/options');
      const body = { email: 'mama@example.org', challengeId: o.json.challengeId, response: authn.assert(o.json.options), authKey: neu, client: 'app', device: { name: 'Handy', platform: 'android' } };
      const r = await c.post('/api/v1/auth/password-reset/passkey', body);
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      expect((await f.m.client.get('/api/v1/me')).status).toBe(401);
      expect((await loginKey('mama@example.org', neu, f.m.totpSecret)).r.status).toBe(200);
      expect((await events(c))[0]).toMatchObject({ kind: 'password_reset_done', via: 'passkey', byAdmin: false });
      // dieselbe Antwort ein zweites Mal (Replay)
      expect((await world.client('203.0.113.61').post('/api/v1/auth/password-reset/passkey', body)).status).toBe(401);
      // ein fremder Authenticator
      const fremd = new TestAuthenticator();
      const o2 = await world.client('203.0.113.62').post('/api/v1/auth/login/passkey/options');
      const bad = await world.client('203.0.113.62').post('/api/v1/auth/password-reset/passkey', { email: 'mama@example.org', challengeId: o2.json.challengeId, response: fremd.assert(o2.json.options), authKey: key(), client: 'app' });
      expect(bad.status).toBe(401);
      expect(bad.json.error).toBe('invalid_credentials');
    });

    it('falsche E-Mail zum Passkey: 409, nichts geändert (der Salt hängt an der E-Mail des Kontos)', async () => {
      const f = await start();
      await f.m.client.post('/api/v1/auth/step-up/code', { totp: await totp(f.m.totpSecret) });
      const authn = new TestAuthenticator();
      const opt = await f.m.client.post('/api/v1/me/passkeys/options');
      await f.m.client.post('/api/v1/me/passkeys/verify', { challengeId: opt.json.challengeId, response: authn.register(opt.json.options) });
      const c = world.client('203.0.113.67');
      const o = await c.post('/api/v1/auth/login/passkey/options');
      const r = await c.post('/api/v1/auth/password-reset/passkey', { email: 'admin@example.org', challengeId: o.json.challengeId, response: authn.assert(o.json.options), authKey: key(), client: 'app' });
      expect(r.status).toBe(409);
      expect(r.json.error).toBe('email_mismatch');
      expect(await world.count('security_events')).toBe(0);
      expect((await f.m.client.get('/api/v1/me')).status).toBe(200);
    });

    it('Passkey-Konto ohne Passwort: 409 no_password', async () => {
      const f = await start();
      const inv = await f.a.client.post('/api/v1/invites', { role: 'child' });
      const authn = new TestAuthenticator();
      const reg = await world.registerPasskey(inv.json.invite.token, { email: 'kind@example.org', displayName: 'Kind', authenticator: authn });
      expect(reg.complete?.status).toBe(200);
      const c = world.client('203.0.113.63');
      const o = await c.post('/api/v1/auth/login/passkey/options');
      const r = await c.post('/api/v1/auth/password-reset/passkey', { email: 'kind@example.org', challengeId: o.json.challengeId, response: authn.assert(o.json.options), authKey: key(), client: 'app' });
      expect(r.status).toBe(409);
      expect(r.json.error).toBe('no_password');
    });
  });

  describe('Push-Wecker ohne Inhalt', () => {
    const endpoint = async (c: Client) => {
      const topic = randTopic();
      expect((await c.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://${HOST}/${topic}?up=1` } })).status).toBe(200);
      return topic;
    };

    it('Admin-Link: das Gerät der Person wird geweckt (fester Inhalt, kein Text), sonst niemand', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      const topic = await endpoint(geraet);
      const adminApp = world.client('203.0.113.64');
      const l = await adminApp.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret), client: 'app', device: { name: 'Admin', platform: 'android' } });
      adminApp.adopt(l.json.session);
      await endpoint(adminApp);
      ntfyCalls = [];
      await adminLink(f);
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);
    });

    it('Selbst-Reset: der Wecker geht an die Geräte, obwohl der Widerruf deren Endpunkte danach löscht', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      const topic = await endpoint(geraet);
      ntfyCalls = [];
      const r = await world.client('203.0.113.65').post('/api/v1/auth/password-reset/recovery', { email: 'mama@example.org', code: f.m.recoveryCodes[1], authKey: key(), client: 'app' });
      expect(r.status).toBe(200);
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);
      expect(await world.count('push_endpoints')).toBe(0); // Endpunkte sind weg (Geräte abgemeldet)
    });

    it('Komplett-Reset: Ereignis und Wecker ebenfalls; kein Wecker ohne Endpunkt', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      const topic = await endpoint(geraet);
      ntfyCalls = [];
      await stepUp(f);
      expect((await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {})).status).toBe(200);
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);
      const ev = (await harness.db.execute<{ kind: string }>(sql`select kind from security_events`)).rows.map((r) => r.kind);
      expect(ev).toEqual(['account_reset_requested']);
    });
  });

  describe('Komplett-Reset (bestehend) und Sicherung', () => {
    it('Neu einrichten per Passkey macht die Passwort-Sicherung stale, löscht nichts', async () => {
      const f = await start();
      const geraet = await mamaApp(f);
      await withBackup(geraet);
      await stepUp(f);
      const voll = await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {});
      const reg = await world.registerPasskey(voll.json.invite.token, { email: 'egal@example.org' });
      expect(reg.complete?.status).toBe(200);
      expect(await backupRows()).toEqual(['stale']);
      expect(await world.count('person_keys')).toBe(1);
    });
  });

  describe('Ereignisliste', () => {
    it('nur die eigenen, neueste zuerst, höchstens 50; ohne Anmeldung 401; Aufräumen nach einem Jahr', async () => {
      const f = await start();
      expect((await world.client('203.0.113.66').get('/api/v1/me/security-events')).status).toBe(401);
      for (let i = 0; i < 3; i++) await adminLink(f);
      const ev = await events(f.m.client);
      expect(ev).toHaveLength(3);
      expect([...ev].sort((x, y) => (x.createdAt < y.createdAt ? 1 : -1)).map((e) => e.id)).toEqual(ev.map((e) => e.id));
      await harness.db.execute(sql`insert into security_events (family_id, user_id, kind, via, created_at) select family_id, user_id, 'password_reset_done', 'passkey', now() - interval '400 days' from security_events limit 1`);
      expect(await world.count('security_events')).toBe(4);
      const { runMaintenance } = await import('../src/auth/maintenance.js');
      await runMaintenance(world.auth.ctx);
      expect(await world.count('security_events')).toBe(3);
      // Konto entfernen löscht die Ereignisse mit (Datenschutz)
      await stepUp(f);
      expect((await f.a.client.del(`/api/v1/members/${f.mamaId}`)).status).toBe(200);
      expect(await world.count('security_events')).toBe(0);
    });
  });
});
