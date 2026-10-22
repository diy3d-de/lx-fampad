// P0-2 "Kein Datenverlust" (Server): Schlüsselwechsel archiviert statt zu löschen, Archiv-Routen, Sperrfrist 24 h für Sitzungen aus Wiederherstellungscode
// oder Passwort-Reset, Sicherheitsereignisse und Wecker für Schlüsselvorgänge, neue Felder in GET /me/keys, Hinweis an die Familie beim Komplett-Reset.
// PGlite und echtes PostgreSQL.
import { randomBytes } from 'node:crypto';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WAKE_BODY } from '../src/push/service.js';
import { TestAuthenticator } from './authenticator.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const H = 3_600_000;
const PW = 'ein-sehr-langes-passwort-123';
const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = () => ({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });
const TOKEN = 'tk_testtoken1234567890';
const HOST = 'ntfy.familie.lx-labs.dev';
const randTopic = () => 'up' + randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe.each(backends)('Kein Datenverlust ($name)', (backend) => {
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
    return { a, m, adminId: await id('admin@example.org'), mamaId: await id('mama@example.org') };
  }
  type Fam = Awaited<ReturnType<typeof start>>;

  const totp = async (secret: string) => {
    world.advance(31_000);
    return world.totp(secret);
  };
  const stepUp = async (c: Client, secret: string) => {
    expect((await c.post('/api/v1/auth/step-up/code', { totp: await totp(secret) })).status).toBe(200);
  };
  const events = async (c: Client) => (await c.get('/api/v1/me/security-events')).json.events as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  const kinds = async (c: Client) => (await events(c)).map((e) => e.kind as string);
  /** Schlüssel anlegen, Wiederherstellungssicherung ablegen, Passwort-Sicherung ablegen und bestätigen. */
  async function volleSicherung(c: Client, keyVersion = 1) {
    const rec = blob();
    expect((await c.put('/api/v1/me/key-backup', { blob: rec, keyVersion })).status).toBe(200);
    const pwBlob = blob();
    const put = await c.put('/api/v1/me/key-backup-pw', { blob: pwBlob, keyVersion, kdf: kdf() });
    expect(put.status).toBe(200);
    expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
    return { rec, pwBlob, pwId: put.json.id as string };
  }
  const rotate = (c: Client, expectedKeyVersion: number) => c.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion });
  const archive = async (c: Client) => (await c.get('/api/v1/me/key-backups/archive')).json.entries as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  /** Zugang per Wiederherstellungscode (eigene Sitzung mit Herkunft `recovery_code`); Browser-Sitzung (Cookie) oder App (Bearer, Refresh-Token). */
  async function codeLogin(f: Fam, code: string, client: 'web' | 'app' = 'web', ip = '203.0.113.150') {
    const c = world.client(ip);
    const r = await c.post('/api/v1/auth/login/recovery', { email: 'admin@example.org', code, client, ...(client === 'app' ? { device: { name: 'Zweitgerät', platform: 'android' } } : {}) });
    expect(r.status).toBe(200);
    c.adopt(r.json.session);
    void f;
    return { c, session: r.json.session as { refreshToken: string; deviceId: string } };
  }
  const settle = async () => {
    const end = Date.now() + 5000;
    while (ntfyCalls.length === 0 && Date.now() < end) await wait(20);
    await wait(150);
  };

  describe('Schlüsselwechsel archiviert (nie löschen)', () => {
    it('Wiederherstellungssicherung wandert ins Archiv, bleibt abrufbar; nach zwei Wechseln sind beide Stände da', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const s1 = await volleSicherung(c, 1);
      expect((await rotate(c, 1)).status).toBe(200);
      expect(await world.count('key_backups')).toBe(0);
      expect(await world.count('key_backup_archive')).toBe(1);
      const l1 = await archive(c);
      expect(l1.filter((e) => e.kind === 'recovery')).toEqual([expect.objectContaining({ kind: 'recovery', keyVersion: 1, reason: 'rotation', verified: true })]);
      expect(Object.keys(l1[0] ?? {}).sort()).toEqual(['archivedAt', 'createdAt', 'id', 'keyVersion', 'kind', 'reason', 'verified']); // nie ein Blob in der Liste
      const rec1 = l1.find((e) => e.kind === 'recovery');
      const d1 = await c.get(`/api/v1/me/key-backups/archive/${rec1?.id}`);
      expect(d1.status).toBe(200);
      expect(d1.json).toMatchObject({ id: rec1?.id, kind: 'recovery', keyVersion: 1, blob: s1.rec, reason: 'rotation' });
      expect(d1.json.kdf).toBeUndefined();
      // zweiter Wechsel mit neuer Sicherung zu Version 2
      const s2 = await volleSicherung(c, 2);
      expect((await rotate(c, 2)).status).toBe(200);
      expect(await world.count('key_backup_archive')).toBe(2);
      const l2 = await archive(c);
      expect(l2.filter((e) => e.kind === 'recovery').map((e) => e.keyVersion).sort()).toEqual([1, 2]);
      const alt1 = l2.find((e) => e.kind === 'recovery' && e.keyVersion === 1);
      const alt2 = l2.find((e) => e.kind === 'recovery' && e.keyVersion === 2);
      expect((await c.get(`/api/v1/me/key-backups/archive/${alt1?.id}`)).json.blob).toBe(s1.rec);
      expect((await c.get(`/api/v1/me/key-backups/archive/${alt2?.id}`)).json.blob).toBe(s2.rec);
      // der aktuelle Zugang (Version 3) ist leer, die alten Stände überschreiben ihn nie
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ keys: { keyVersion: 3 }, hasBackup: false, recoveryBackupAt: null });
      expect((await c.get('/api/v1/me/key-backup')).status).toBe(404);
      expect((await c.put('/api/v1/me/key-backup', { blob: s1.rec, keyVersion: 1 })).status).toBe(409);
      expect((await c.put('/api/v1/me/key-backup-pw', { blob: s1.pwBlob, keyVersion: 1, kdf: kdf() })).status).toBe(409);
    });

    it('Passwort-Sicherungen älterer Stände bleiben: stale, danach superseded, immer über das Archiv (mit KDF-Daten) erreichbar', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const s1 = await volleSicherung(c, 1);
      expect((await rotate(c, 1)).status).toBe(200);
      // nach dem Wechsel: die alte Zeile ist stale und über die normale Route UND das Archiv erreichbar
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ pwBackupStale: true, pwBackupVerifiedAt: null });
      expect((await c.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: s1.pwId, state: 'stale', keyVersion: 1 });
      const stale = (await archive(c)).find((e) => e.kind === 'password');
      expect(stale).toMatchObject({ id: s1.pwId, keyVersion: 1, reason: 'rotation', verified: true });
      // neue bestätigte Sicherung zu Version 2: die alte wird superseded, bleibt aber im Archiv
      const s2 = await volleSicherung(c, 2);
      expect((await harness.db.execute<{ state: string }>(sql`select state from key_backups_pw order by key_version`)).rows.map((r) => r.state)).toEqual(['superseded', 'active']);
      const pwEntries = (await archive(c)).filter((e) => e.kind === 'password');
      expect(pwEntries.map((e) => e.id)).toEqual([s1.pwId]);
      const d = await c.get(`/api/v1/me/key-backups/archive/${s1.pwId}`);
      expect(d.status).toBe(200);
      expect(d.json).toMatchObject({ kind: 'password', keyVersion: 1, blob: s1.pwBlob, verified: true, reason: 'rotation' });
      expect(d.json.kdf).toMatchObject({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
      expect(typeof d.json.kdf.salt).toBe('string');
      // der aktuelle Zugang bleibt Version 2
      expect((await c.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: s2.pwId, state: 'active', keyVersion: 2 });
      // zweiter Wechsel + neue Sicherung zu Version 3: beide älteren Zeilen bleiben abrufbar
      expect((await rotate(c, 2)).status).toBe(200);
      const s3 = await volleSicherung(c, 3);
      const alle = (await archive(c)).filter((e) => e.kind === 'password').map((e) => e.id);
      expect(alle.sort()).toEqual([s1.pwId, s2.pwId].sort());
      expect((await c.get(`/api/v1/me/key-backups/archive/${s2.pwId}`)).json.blob).toBe(s2.pwBlob);
      expect((await c.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: s3.pwId, keyVersion: 3, state: 'active' });
      expect(await world.count('key_backups_pw')).toBe(3); // nie eine Zeile gelöscht
    });

    it('Ersetzen: ein anderer Blob zum selben Schlüssel archiviert den alten (auch Müll-Sicherung eines Angreifers), derselbe Blob nicht', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const s = await volleSicherung(c, 1);
      expect((await c.put('/api/v1/me/key-backup', { blob: s.rec, keyVersion: 1 })).status).toBe(200); // gleicher Blob: nichts zu archivieren
      expect(await world.count('key_backup_archive')).toBe(0);
      const muell = blob();
      expect((await c.put('/api/v1/me/key-backup', { blob: muell, keyVersion: 1 })).status).toBe(200);
      expect(await world.count('key_backup_archive')).toBe(1);
      const ersetzt = (await archive(c)).find((e) => e.kind === 'recovery');
      expect(ersetzt).toMatchObject({ keyVersion: 1, reason: 'replaced' });
      expect((await c.get(`/api/v1/me/key-backups/archive/${ersetzt?.id}`)).json.blob).toBe(s.rec);
      expect((await c.get('/api/v1/me/key-backup')).json.blob).toBe(muell);
      // Passwort-Sicherung: eine bestätigte Müll-Sicherung ersetzt die echte, die echte bleibt im Archiv
      const put = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
      const pwEintrag = (await archive(c)).find((e) => e.kind === 'password');
      expect(pwEintrag).toMatchObject({ id: s.pwId, keyVersion: 1, reason: 'replaced', verified: true });
      expect((await c.get(`/api/v1/me/key-backups/archive/${s.pwId}`)).json.blob).toBe(s.pwBlob);
    });

    it('unbestätigte Sicherung eines gewechselten Stands bleibt (superseded) und ist im Archiv, eine unbestätigte desselben Stands nicht', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const pending = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      const nochmal = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() }); // erste pending wird superseded (nie bestätigt)
      expect((await archive(c)).filter((e) => e.kind === 'password')).toEqual([]);
      expect((await rotate(c, 1)).status).toBe(200);
      const liste = (await archive(c)).filter((e) => e.kind === 'password');
      expect(liste.map((e) => e.id).sort()).toEqual([pending.json.id, nochmal.json.id].sort());
      expect(liste.every((e) => e.verified === false && e.reason === 'rotation')).toBe(true);
      expect(await world.count('key_backups_pw')).toBe(2);
    });

    it('Parallelität: Wechsel gleichzeitig mit Sicherungsbestätigung, nie geht eine Sicherung verloren', async () => {
      for (let i = 0; i < 4; i++) {
        await harness.reset();
        const f = await start();
        const c = f.a.client;
        await c.post('/api/v1/me/keys', keys());
        const s1 = await volleSicherung(c, 1);
        const pending = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
        const [rot, ver] = await Promise.all([rotate(c, 1), c.post('/api/v1/me/key-backup-pw/verified', { id: pending.json.id })]);
        expect(rot.status).toBe(200);
        expect([200, 409]).toContain(ver.status);
        const pw = (await archive(c)).filter((e) => e.kind === 'password').map((e) => e.id);
        // die zuvor bestätigte Sicherung ist erreichbar (archiviert oder noch als aktuelle/stale-Zeile), die zweite ebenfalls
        const reachable = new Set<string>(pw);
        const cur = await c.get('/api/v1/me/key-backup-pw');
        if (cur.status === 200) reachable.add(cur.json.id);
        expect(reachable.has(s1.pwId)).toBe(true);
        expect(reachable.has(pending.json.id)).toBe(true);
        expect(await world.count('key_backups_pw')).toBe(2);
        expect(await world.count('key_backups')).toBe(0);
        expect(await world.count('key_backup_archive')).toBe(1);
        // der Zustandsautomat: höchstens eine aktuelle (active/stale) Zeile
        const aktuell = (await harness.db.execute<{ n: number }>(sql`select count(*)::int as n from key_backups_pw where state in ('active', 'stale')`)).rows[0]?.n;
        expect(aktuell).toBeLessThanOrEqual(1);
        await world.close();
      }
    });

    it('Parallelität: zwei Wechsel mit derselben erwarteten Version, genau einer gewinnt und archiviert genau einmal', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const s = await volleSicherung(c, 1);
      const [x, y] = await Promise.all([rotate(c, 1), rotate(c, 1)]);
      expect([x.status, y.status].sort()).toEqual([200, 409]);
      expect(await world.count('key_backup_archive')).toBe(1);
      const e = (await archive(c)).find((a) => a.kind === 'recovery');
      expect((await c.get(`/api/v1/me/key-backups/archive/${e?.id}`)).json.blob).toBe(s.rec);
    });

    it('Parallelität: Wechsel gleichzeitig mit dem Ablegen einer Sicherung, der Blob geht nie verloren', async () => {
      for (let i = 0; i < 3; i++) {
        await harness.reset();
        const f = await start();
        const c = f.a.client;
        await c.post('/api/v1/me/keys', keys());
        const alt = blob();
        await c.put('/api/v1/me/key-backup', { blob: alt, keyVersion: 1 });
        const neu = blob();
        const [rot, put] = await Promise.all([rotate(c, 1), c.put('/api/v1/me/key-backup', { blob: neu, keyVersion: 1 })]);
        expect(rot.status).toBe(200);
        expect([200, 409]).toContain(put.status);
        const blobs = (await harness.db.execute<{ blob: string }>(sql`select blob from key_backup_archive union all select blob from key_backups`)).rows.map((r) => r.blob);
        expect(blobs).toContain(alt);
        if (put.status === 200) expect(blobs).toContain(neu);
        await world.close();
      }
    });
  });

  describe('Archiv-Routen: Rechte', () => {
    it('nur die eigene Person: fremde IDs 404 (IDOR), anonym 401, Step-up Pflicht, ungültige ID 400, nichts Geheimes im Audit', async () => {
      const f = await start();
      const a = f.a.client;
      const m = f.m.client;
      await a.post('/api/v1/me/keys', keys());
      await m.post('/api/v1/me/keys', keys());
      const sa = await volleSicherung(a, 1);
      await volleSicherung(m, 1);
      await rotate(a, 1);
      await rotate(m, 1);
      const aListe = await archive(a);
      const mListe = await archive(m);
      expect(aListe).toHaveLength(2);
      expect(mListe).toHaveLength(2);
      for (const e of aListe) {
        // Mamas Person darf keine ID von Admin sehen, nicht lesen und nicht erraten
        const r = await m.get(`/api/v1/me/key-backups/archive/${e.id}`);
        expect(r.status, JSON.stringify(e)).toBe(404);
        expect(r.json).toEqual({ error: 'not_found', message: 'Nicht gefunden.' });
      }
      expect(aListe.map((e) => e.id).some((id) => mListe.some((x) => x.id === id))).toBe(false);
      expect((await a.get('/api/v1/me/key-backups/archive/3f2b1c1e-0000-4000-8000-000000000001')).status).toBe(404);
      expect((await a.get('/api/v1/me/key-backups/archive/kein-uuid')).status).toBe(400);
      // aktuelle, noch nicht archivierte Zeilen (Version 2 der Person hat keine) gibt es hier nicht: eine pending-Zeile ist nie abrufbar
      const pending = await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 2, kdf: kdf() });
      expect((await a.get(`/api/v1/me/key-backups/archive/${pending.json.id}`)).status).toBe(404);
      // anonym
      const anon = world.client('203.0.113.99');
      expect((await anon.get('/api/v1/me/key-backups/archive')).status).toBe(401);
      expect((await anon.get(`/api/v1/me/key-backups/archive/${sa.pwId}`)).status).toBe(401);
      // Step-up: nach dem Ablauf der frischen Bestätigung geht weder Liste noch Einzelabruf
      world.advance(10 * MIN);
      expect((await a.get('/api/v1/me/key-backups/archive')).json.error).toBe('step_up_required');
      expect((await a.get(`/api/v1/me/key-backups/archive/${sa.pwId}`)).json.error).toBe('step_up_required');
      await stepUp(a, f.a.totpSecret);
      expect((await a.get(`/api/v1/me/key-backups/archive/${sa.pwId}`)).status).toBe(200);
      // Audit: Liste und Abrufe protokolliert, ohne Blob/Salt
      const ev = await auditEvents(world);
      expect(ev).toEqual(expect.arrayContaining(['key_backup_archive_list', 'key_backup_archive_read']));
      const audits = JSON.stringify((await harness.db.execute(sql`select event, detail from audit_log where event like 'key_backup_archive%'`)).rows);
      expect(audits).not.toContain(sa.pwBlob);
      expect(audits).not.toContain(sa.rec);
    });

    it('strenges Rate-Limit an beiden Routen', async () => {
      const f = await start({ AUTH_RATE_LIMIT_MAX: '4' });
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const statuses: number[] = [];
      for (let i = 0; i < 8; i++) statuses.push((await c.get('/api/v1/me/key-backups/archive')).status);
      expect(statuses).toContain(429);
      const c2 = f.m.client;
      const s2: number[] = [];
      for (let i = 0; i < 8; i++) s2.push((await c2.get('/api/v1/me/key-backups/archive/3f2b1c1e-0000-4000-8000-000000000001')).status);
      expect(s2).toContain(429);
    });

    it('Archivzugang auch ohne Schalter E2EE_PW_BACKUP (Wiederherstellungssicherungen), Passwort-Zeilen nur, wenn es sie gibt', async () => {
      const f = await start({ E2EE_PW_BACKUP: 'false' });
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const rec = blob();
      await c.put('/api/v1/me/key-backup', { blob: rec, keyVersion: 1 });
      expect((await rotate(c, 1)).status).toBe(200);
      const l = await archive(c);
      expect(l).toHaveLength(1);
      expect((await c.get(`/api/v1/me/key-backups/archive/${l[0]?.id}`)).json.blob).toBe(rec);
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ archiveCount: 1, pwBackupVerifiedAt: null });
    });
  });

  describe('Sperrfrist (Sitzungen aus Wiederherstellungscode oder Passwort-Reset)', () => {
    it('Wiederherstellungscode: Wechsel 24 h gesperrt (mit Restdauer), danach erlaubt; Passwort-Anmeldung ohne Sperre; nichts wurde angefasst', async () => {
      const f = await start();
      // normale Anmeldung (Passwort + TOTP) im Browser: kein Sperrfrist
      await f.a.client.post('/api/v1/me/keys', keys());
      const s = await volleSicherung(f.a.client, 1);
      const code = f.a.recoveryCodes[0] as string;
      const { c } = await codeLogin(f, code);
      const gesperrt = await rotate(c, 1);
      expect(gesperrt.status).toBe(403);
      expect(gesperrt.json.error).toBe('destructive_locked');
      expect(gesperrt.json.retryAfterSec).toBe(24 * 3600);
      expect(gesperrt.headers['retry-after']).toBe('86400');
      expect(String(gesperrt.json.message)).toMatch(/gesperrt/);
      // nichts verändert
      expect(await world.count('key_backup_archive')).toBe(0);
      expect((await f.a.client.get('/api/v1/me/keys')).json.keys.keyVersion).toBe(1);
      // das normale Anlegen, Abrufen und das Archiv gehen in der gesperrten Sitzung trotzdem (nach einem Reset legt die App sofort eine neue an)
      expect((await c.put('/api/v1/me/key-backup', { blob: s.rec, keyVersion: 1 })).status).toBe(200);
      const put = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect(put.status).toBe(200);
      expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
      expect((await c.get('/api/v1/me/key-backups/archive')).status).toBe(200);
      // die Restdauer wird kleiner: nach 23 h noch knapp eine Stunde
      world.advance(23 * H);
      await stepUp(c, f.a.totpSecret);
      const rest = await rotate(c, 1);
      expect(rest.json.error).toBe('destructive_locked');
      expect(rest.json.retryAfterSec).toBeGreaterThan(0);
      expect(rest.json.retryAfterSec).toBeLessThanOrEqual(H / 1000);
      // nach Ablauf: erlaubt (das Step-up ist dann abgelaufen, das ist die zweite Prüfung)
      world.advance(H);
      expect((await rotate(c, 1)).json.error).toBe('step_up_required');
      await stepUp(c, f.a.totpSecret);
      const ok = await rotate(c, 1);
      expect(ok.status).toBe(200);
      expect(await world.count('key_backup_archive')).toBeGreaterThanOrEqual(1);
    });

    it('Passwort-Anmeldung und Passkey: sofort erlaubt', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      expect((await rotate(f.a.client, 1)).status).toBe(200);
      const c = world.client('203.0.113.151');
      const r = await c.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      expect((await rotate(c, 2)).status).toBe(200);
      const row = (await harness.db.execute<{ origin: string; origin_at: Date | null }>(sql`select origin, origin_at from sessions order by created_at desc limit 1`)).rows[0];
      expect(row).toMatchObject({ origin: 'login', origin_at: null });
    });

    it('Passwort + Wiederherstellungscode (statt TOTP) zählt als Code-Zugang: gesperrt', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const c = world.client('203.0.113.152');
      const r = await c.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, recoveryCode: f.a.recoveryCodes[1], client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      expect((await rotate(c, 1)).json.error).toBe('destructive_locked');
      expect(await kinds(f.a.client)).toContain('recovery_code_login');
    });

    it('Passwort-Reset (Code und Passkey-Weg gleich): Sitzung danach gesperrt', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const c = world.client('203.0.113.153');
      const r = await c.post('/api/v1/auth/password-reset/recovery', { email: 'admin@example.org', code: f.a.recoveryCodes[2], authKey: key(), client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      const gesperrt = await rotate(c, 1);
      expect(gesperrt.json.error).toBe('destructive_locked');
      const row = (await harness.db.execute<{ origin: string }>(sql`select origin from sessions where user_id = ${f.adminId} and revoked_at is null`)).rows;
      expect(row).toEqual([{ origin: 'password_reset' }]);
    });

    it('Admin-Link (Passwort-Reset) mit TOTP: Sitzung danach ebenfalls gesperrt', async () => {
      const f = await start();
      await f.m.client.post('/api/v1/me/keys', keys());
      await stepUp(f.a.client, f.a.totpSecret);
      const link = await f.a.client.post(`/api/v1/members/${f.mamaId}/password-reset`, {});
      expect(link.status).toBe(200);
      const c = world.client('203.0.113.154');
      const s = await c.post('/api/v1/auth/invites/password-reset/start', { token: link.json.invite.token, authKey: key() });
      expect(s.status).toBe(200);
      const done = await c.post('/api/v1/auth/invites/password-reset/complete', { challengeId: s.json.challengeId, code: await totp(f.m.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect(done.status).toBe(200);
      c.adopt(done.json.session);
      expect((await rotate(c, 1)).json.error).toBe('destructive_locked');
    });

    it('Refresh-Rotation behält die Herkunft und den Zeitpunkt (die Frist läuft nicht neu an und nicht ab)', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const { c, session } = await codeLogin(f, f.a.recoveryCodes[3] as string, 'app');
      const [vor] = (await harness.db.execute<{ origin_at: Date }>(sql`select origin_at from sessions where token_hash is not null and origin = 'recovery_code'`)).rows;
      world.advance(10 * H);
      c.bearer = undefined;
      const r = await c.post('/api/v1/auth/refresh', { refreshToken: session.refreshToken, deviceId: session.deviceId });
      expect(r.status).toBe(200);
      c.bearer = r.json.session.accessToken;
      await stepUp(c, f.a.totpSecret);
      const gesperrt = await rotate(c, 1);
      expect(gesperrt.json.error).toBe('destructive_locked');
      // 24 h ab dem Zugang, nicht ab der Rotation: nach weiteren 10 h (Summe 20 h + Zeitschritte) noch gesperrt, die Restdauer ist < 14 h
      expect(gesperrt.json.retryAfterSec).toBeLessThan(15 * 3600);
      const rows = (await harness.db.execute<{ origin_at: Date }>(sql`select origin_at from sessions where origin = 'recovery_code'`)).rows;
      expect(rows.length).toBeGreaterThanOrEqual(2);
      for (const row of rows) expect(new Date(row.origin_at).getTime()).toBe(new Date(vor?.origin_at as Date).getTime());
    });

    it('Wechsel nach Ablauf der Sperre protokolliert den Weg `recovery_code`', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const { c } = await codeLogin(f, f.a.recoveryCodes[4] as string);
      world.advance(25 * H);
      await stepUp(c, f.a.totpSecret);
      expect((await rotate(c, 1)).status).toBe(200);
      const ev = (await events(f.a.client)).find((e) => e.kind === 'key_rotated');
      expect(ev).toMatchObject({ kind: 'key_rotated', via: 'recovery_code', byAdmin: false, actorName: null });
    });
  });

  describe('Sicherheitsereignisse und Wecker', () => {
    it('Wechsel, Abrufe, Übertragung, Code-Anmeldung erzeugen feste Ereignisse nur für die eigene Person; kein Geheimnis in der Antwort', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const s = await volleSicherung(c, 1);
      expect(await kinds(c)).toEqual([]); // Anlegen und der Round-Trip lösen nichts aus
      await c.get('/api/v1/me/key-backup');
      await c.get('/api/v1/me/key-backup-pw');
      expect((await c.get('/api/v1/me/key-backup-pw?pending=1')).status).toBe(404); // nichts pending: kein Ereignis
      const lookup = key();
      await c.post('/api/v1/me/key-transfer', { lookup, blob: blob(), keyVersion: 1 });
      await c.post('/api/v1/me/key-transfer/claim', { lookup });
      await rotate(c, 1);
      const arch = (await archive(c)).find((e) => e.kind === 'recovery');
      await c.get(`/api/v1/me/key-backups/archive/${arch?.id}`);
      const { c: codeC } = await codeLogin(f, f.a.recoveryCodes[0] as string);
      void codeC;
      const k = await kinds(c);
      expect([...k].sort()).toEqual(
        ['key_backup_archive_read', 'key_backup_pw_read', 'key_backup_read', 'key_rotated', 'key_transfer_claimed', 'key_transfer_created', 'recovery_code_login'].sort(),
      );
      const ev = await events(c);
      for (const e of ev) {
        expect(Object.keys(e).sort()).toEqual(['actorName', 'byAdmin', 'createdAt', 'id', 'kind', 'subjectName', 'via']);
        expect(['password', 'recovery_code']).toContain(e.via);
      }
      // nichts Geheimes: weder Blobs noch Schlüssel noch Codes in der Antwort oder der Tabelle
      const alles = JSON.stringify(ev) + JSON.stringify((await harness.db.execute(sql`select * from security_events`)).rows);
      for (const geheim of [s.rec, s.pwBlob, lookup, f.a.recoveryCodes[0] as string, PW]) expect(alles).not.toContain(geheim);
      // niemand sonst sieht es
      expect(await events(f.m.client)).toEqual([]);
    });

    it('Wecker ohne Inhalt: nur die ANDEREN Geräte der eigenen Person, fester Text; das auslösende Gerät bleibt ruhig', async () => {
      const f = await start();
      const c = world.client('203.0.113.160'); // App-Gerät mit Push
      const r = await c.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
      c.adopt(r.json.session);
      const topic = randTopic();
      expect((await c.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://${HOST}/${topic}?up=1` } })).status).toBe(200);
      const mama = world.client('203.0.113.161');
      const rm = await mama.post('/api/v1/auth/login/password', { email: 'mama@example.org', password: PW, totp: await totp(f.m.totpSecret), client: 'app', device: { name: 'Mama', platform: 'android' } });
      mama.adopt(rm.json.session);
      const topicMama = randTopic();
      expect((await mama.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://${HOST}/${topicMama}?up=1` } })).status).toBe(200);
      const web = f.a.client; // anderes Gerät (Browser)
      await web.post('/api/v1/me/keys', keys());
      await volleSicherung(web, 1);
      ntfyCalls = [];

      // Abruf im Browser weckt das App-Gerät
      expect((await web.get('/api/v1/me/key-backup')).status).toBe(200);
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);

      // dasselbe Gerät mit dem Push-Endpunkt ruft selbst ab: kein Wecker an sich selbst (nach Ablauf der Entprellung, sonst gäbe es auch kein Ereignis)
      world.advance(11 * MIN);
      await stepUp(c, f.a.totpSecret);
      ntfyCalls = [];
      expect((await c.get('/api/v1/me/key-backup')).status).toBe(200);
      await wait(400);
      expect(ntfyCalls).toEqual([]);
      expect((await kinds(web)).filter((k) => k === 'key_backup_read')).toHaveLength(2); // das Ereignis gibt es trotzdem

      // Schlüsselwechsel im Browser: kritisch, weckt das App-Gerät; Mamas Gerät nie
      await stepUp(web, f.a.totpSecret);
      ntfyCalls = [];
      expect((await rotate(web, 1)).status).toBe(200);
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);
      expect(ntfyCalls.some((x) => x.url.includes(topicMama))).toBe(false);

      // Anmeldung per Wiederherstellungscode: kritisch, das neue Gerät hat keinen Endpunkt, das App-Gerät wird geweckt
      ntfyCalls = [];
      await codeLogin(f, f.a.recoveryCodes[5] as string, 'app', '203.0.113.162');
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);
      expect(WAKE_BODY).not.toMatch(/Schl|key|Code/i);
    });

    it('der Push-Wecker scheitert nie am Vorgang (Haken wirft)', async () => {
      const f = await start();
      world.auth.ctx.onSecurityEvent = () => {
        throw new Error('kaputt');
      };
      await f.a.client.post('/api/v1/me/keys', keys());
      await f.a.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      expect((await f.a.client.get('/api/v1/me/key-backup')).status).toBe(200);
      expect((await rotate(f.a.client, 1)).status).toBe(200);
    });
  });

  describe('GET /me/keys: Serverwissen für die Warnungen der App', () => {
    it('pwBackupVerifiedAt, recoveryBackupAt, archiveCount; alte Felder unverändert, nie Geheimnisse', async () => {
      const f = await start();
      const c = f.a.client;
      expect((await c.get('/api/v1/me/keys')).json).toEqual({ keys: null, hasBackup: false, pwBackupVerifiedAt: null, recoveryBackupAt: null, archiveCount: 0 });
      const k = keys();
      await c.post('/api/v1/me/keys', k);
      await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      const t1 = world.now().toISOString();
      const put = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      // unbestätigt: noch kein pwBackupVerifiedAt
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ pwBackupVerifiedAt: null, recoveryBackupAt: t1 });
      world.advance(MIN);
      await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id });
      const t2 = world.now().toISOString();
      const nach = (await c.get('/api/v1/me/keys')).json;
      expect(nach).toEqual({ keys: { ...k, keyVersion: 1 }, hasBackup: true, pwBackupVerifiedAt: t2, recoveryBackupAt: t1, archiveCount: 0 });
      // nach dem Wechsel gilt nichts mehr für den neuen Schlüssel; das Archiv zählt beide alten Sicherungen, stale kommt wie bisher dazu
      await rotate(c, 1);
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ hasBackup: false, pwBackupVerifiedAt: null, recoveryBackupAt: null, pwBackupStale: true, archiveCount: 2 });
    });

    it('Schalter aus: pwBackupVerifiedAt bleibt null, der Rest gilt', async () => {
      const f = await start({ E2EE_PW_BACKUP: 'false' });
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ hasBackup: true, pwBackupVerifiedAt: null, archiveCount: 0 });
    });
  });

  describe('Komplett-Reset und Mitglied entfernen', () => {
    it('Komplett-Reset benachrichtigt ALLE anderen aktiven Mitglieder (Ereignis mit Name, Wecker), die Person selbst bekommt ihr eigenes Ereignis', async () => {
      const f = await start();
      const papa = await addMember(world, f.a.client, 'child', 'papa@example.org');
      const wartend = await addMember(world, f.a.client, 'parent', 'wartet@example.org', { requireApproval: true });
      void wartend;
      const login = async (email: string, secret: string, ip: string) => {
        const c = world.client(ip);
        const r = await c.post('/api/v1/auth/login/password', { email, password: PW, totp: await totp(secret), client: 'app', device: { name: email, platform: 'android' } });
        expect(r.status, email).toBe(200);
        c.adopt(r.json.session);
        const topic = randTopic();
        expect((await c.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://${HOST}/${topic}?up=1` } })).status).toBe(200);
        return { c, topic };
      };
      const adminG = await login('admin@example.org', f.a.totpSecret, '203.0.113.170');
      const papaG = await login('papa@example.org', papa.totpSecret, '203.0.113.171');
      const mamaG = await login('mama@example.org', f.m.totpSecret, '203.0.113.172');
      ntfyCalls = [];
      await stepUp(adminG.c, f.a.totpSecret);
      expect((await adminG.c.post(`/api/v1/members/${f.mamaId}/reset`, {})).status).toBe(200);
      await settle();
      await wait(300);
      const urls = ntfyCalls.map((x) => x.url).sort();
      expect(urls).toEqual([`/${adminG.topic}`, `/${papaG.topic}`, `/${mamaG.topic}`].sort());
      expect(ntfyCalls.every((x) => x.body === WAKE_BODY)).toBe(true);
      // Ereignisse
      const rows = (await harness.db.execute<{ user_id: string; kind: string; subject_id: string | null; actor_id: string | null; via: string }>(sql`select user_id, kind, subject_id, actor_id, via from security_events order by kind, user_id`)).rows;
      const familie = rows.filter((r) => r.kind === 'member_account_reset').map((r) => r.user_id).sort();
      expect(familie).toEqual([f.adminId, (await harness.db.execute<{ id: string }>(sql`select id from users where email = 'papa@example.org'`)).rows[0]?.id as string].sort());
      expect(rows.filter((r) => r.kind === 'member_account_reset').every((r) => r.subject_id === f.mamaId && r.via === 'admin' && r.actor_id === f.adminId)).toBe(true);
      expect(rows.filter((r) => r.kind === 'account_reset_requested').map((r) => r.user_id)).toEqual([f.mamaId]);
      // Sicht der Familie: Name der betroffenen Person, keine Mail, keine Rollen
      const papaEv = (await papaG.c.get('/api/v1/me/security-events')).json.events as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
      expect(papaEv).toHaveLength(1);
      expect(papaEv[0]).toMatchObject({ kind: 'member_account_reset', via: 'admin', subjectName: 'mama', actorName: 'Admin', byAdmin: true });
      expect(JSON.stringify(papaEv)).not.toContain('mama@example.org');
      // die betroffene Person sieht nur ihr eigenes Ereignis (Sitzungen sind widerrufen: neu anmelden geht erst nach der Einladung, also über die Tabelle geprüft)
      expect(rows.some((r) => r.user_id === f.mamaId && r.kind === 'member_account_reset')).toBe(false);
      // die wartende Person bekommt nichts
      expect(rows.filter((r) => r.kind === 'member_account_reset')).toHaveLength(2);
    });

    it('Mitglied entfernen ist ein Soft-Delete (P1): Schlüssel, Sicherungen, Archiv und Ereignisse bleiben bis zum endgültigen Löschen liegen (Einzelheiten: p1-schluessel.test.ts)', async () => {
      const f = await start();
      const m = f.m.client;
      await m.post('/api/v1/me/keys', keys());
      await volleSicherung(m, 1);
      await rotate(m, 1);
      expect(await world.count('key_backup_archive')).toBe(1);
      await stepUp(f.a.client, f.a.totpSecret);
      expect((await f.a.client.del(`/api/v1/members/${f.mamaId}`)).status).toBe(200);
      expect(await world.count('key_backup_archive')).toBe(1);
      expect(await world.count('key_backups_pw')).toBeGreaterThan(0);
      expect(await world.count('person_keys')).toBe(1);
      // nach der Aufbewahrungsfrist löscht der Aufräum-Job endgültig, mit allem, was daran hängt
      await harness.db.execute(sql`update users set removed_at = ${new Date(world.clock - 31 * 86_400_000).toISOString()}::timestamptz where id = ${f.mamaId}`);
      const { runMaintenance } = await import('../src/auth/maintenance.js');
      expect((await runMaintenance(world.auth.ctx)).removedMembersPurged).toBe(1);
      expect(await world.count('key_backup_archive')).toBe(0);
      expect(await world.count('key_backups_pw')).toBe(0);
      expect(await world.count('person_keys')).toBe(0);
    });
  });

  describe('Sperrfrist: kein Umgehen über neue Zugänge (H1)', () => {
    /** Passkey zu einem Konto hinzufügen (frisches Step-up, Sitzung ohne Sperre). */
    async function addPasskey(c: Client, secret: string) {
      await stepUp(c, secret);
      const authn = new TestAuthenticator();
      const opt = await c.post('/api/v1/me/passkeys/options');
      expect(opt.status).toBe(200);
      const done = await c.post('/api/v1/me/passkeys/verify', { challengeId: opt.json.challengeId, response: authn.register(opt.json.options) });
      expect(done.status).toBe(200);
      return { authn, id: done.json.id as string };
    }

    it('Code-Sitzung: Passkey, Passwort, Codes, Entfernen und Zurücksetzen sind 24 h gesperrt (nichts ändert sich), danach erlaubt', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const { c } = await codeLogin(f, f.a.recoveryCodes[0] as string);
      const gesperrt = async (r: Promise<{ status: number; json: Record<string, any> }>, was: string) => { // eslint-disable-line @typescript-eslint/no-explicit-any
        const x = await r;
        expect(x.status, was).toBe(403);
        expect(x.json.error, was).toBe('destructive_locked');
        expect(x.json.retryAfterSec, was).toBeGreaterThan(0);
      };
      const codesVorher = await world.count('recovery_codes');
      await gesperrt(c.post('/api/v1/me/passkeys/options'), 'Passkey anlegen (Start)');
      // eine echte Challenge aus einer normalen Sitzung der Person: das Ende wird in der Code-Sitzung trotzdem abgelehnt
      await stepUp(f.a.client, f.a.totpSecret);
      const opt = await f.a.client.post('/api/v1/me/passkeys/options');
      await gesperrt(c.post('/api/v1/me/passkeys/verify', { challengeId: opt.json.challengeId, response: new TestAuthenticator().register(opt.json.options) }), 'Passkey anlegen (Ende)');
      await gesperrt(c.del('/api/v1/me/passkeys/3f2b1c1e-0000-4000-8000-000000000001'), 'Passkey entfernen');
      await gesperrt(c.post('/api/v1/me/password/start', { authKey: key() }), 'Passwort setzen (Start)');
      await gesperrt(c.post('/api/v1/me/password/complete', { challengeId: '3f2b1c1e-0000-4000-8000-000000000001', code: '123456' }), 'Passwort setzen (Ende)');
      await gesperrt(c.post('/api/v1/me/password/change', { authKey: key() }), 'Passwort ändern');
      await gesperrt(c.del('/api/v1/me/password'), 'Passwort entfernen');
      await gesperrt(c.post('/api/v1/me/recovery-codes'), 'Wiederherstellungscodes neu erzeugen');
      await gesperrt(c.del(`/api/v1/members/${f.mamaId}`), 'Mitglied entfernen');
      await gesperrt(c.post(`/api/v1/members/${f.mamaId}/reset`, {}), 'Mitglied zurücksetzen');
      await gesperrt(rotate(c, 1), 'Schlüsselwechsel');
      // nichts hat sich geändert: Mama ist da, ihre Anmeldedaten, die Codes und die Schlüssel auch
      expect((await f.m.client.get('/api/v1/me')).status).toBe(200);
      expect(await world.count('recovery_codes')).toBe(codesVorher);
      expect(await world.count('person_keys')).toBe(1);
      expect((await harness.db.execute<{ n: number }>(sql`select count(*)::int as n from users where access_changed_at is not null`)).rows[0]?.n).toBe(0);
      // nach 24 h geht es (erst das Step-up erneuern)
      world.advance(24 * H + MIN);
      await stepUp(c, f.a.totpSecret);
      expect((await c.post('/api/v1/me/recovery-codes')).status).toBe(200);
    });

    it('Kette: Passkey in einer normalen Sitzung angelegt, Anmeldung damit erbt die Frist; eine bestehende Sitzung bleibt frei', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const { authn } = await addPasskey(f.a.client, f.a.totpSecret);
      const geaendert = world.now();
      // die Sitzung, die den Passkey angelegt hat, ist eine normale Anmeldung (Herkunft login): sie wechselt ohne Sperre
      expect((await harness.db.execute<{ origin: string }>(sql`select origin from sessions where user_id = ${f.adminId} order by created_at`)).rows.map((r) => r.origin)).toEqual(['login']);
      // eine NEUE Anmeldung mit dem frischen Passkey erbt die Frist
      const c = world.client('203.0.113.140');
      const r = await world.loginPasskey(c, authn);
      expect(r.status).toBe(200);
      const row = (await harness.db.execute<{ origin: string; origin_at: Date }>(sql`select origin, origin_at from sessions where user_id = ${f.adminId} order by created_at desc limit 1`)).rows[0];
      expect(row?.origin).toBe('access_change');
      expect(new Date(row?.origin_at as Date).getTime()).toBe(geaendert.getTime());
      const gesperrt = await rotate(c, 1);
      expect(gesperrt.json.error).toBe('destructive_locked');
      expect(gesperrt.json.retryAfterSec).toBeGreaterThan(86_000 - 600);
      // Passwort-Anmeldung innerhalb der Frist: ebenfalls geerbt
      const c2 = world.client('203.0.113.141');
      const r2 = await c2.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret) });
      c2.adopt(r2.json.session);
      expect((await rotate(c2, 1)).json.error).toBe('destructive_locked');
      // nach 24 h: frei (frische Anmeldung)
      world.advance(24 * H + MIN);
      const c3 = world.client('203.0.113.142');
      const r3 = await c3.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret) });
      c3.adopt(r3.json.session);
      expect((await rotate(c3, 1)).status).toBe(200);
    });

    it('Wiederherstellungscodes neu erzeugen oder Passwort ändern in einer normalen Sitzung: neue Anmeldungen erben die Frist', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      await stepUp(f.a.client, f.a.totpSecret);
      expect((await f.a.client.post('/api/v1/me/recovery-codes')).status).toBe(200);
      const c = world.client('203.0.113.143');
      const r = await c.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      expect((await rotate(c, 1)).json.error).toBe('destructive_locked');
      // Registrierung setzt es nie: ein neues Mitglied meldet sich sofort normal an
      const papa = await addMember(world, f.a.client, 'child', 'papa@example.org');
      await papa.client.post('/api/v1/me/keys', keys());
      const pc = world.client('203.0.113.144');
      const pr = await pc.post('/api/v1/auth/login/password', { email: 'papa@example.org', password: PW, totp: await totp(papa.totpSecret) });
      pc.adopt(pr.json.session);
      expect((await rotate(pc, 1)).status).toBe(200);
    });

    it('Passkey-Selbst-Reset: Sitzung ist `login` (keine Sperre, auch kurz nach einer Änderung der Anmeldedaten); der Weg über den Code bleibt gesperrt', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const { authn } = await addPasskey(f.a.client, f.a.totpSecret); // setzt access_changed_at: der Passkey-Reset darf das nicht erben
      const c = world.client('203.0.113.145');
      const o = await c.post('/api/v1/auth/login/passkey/options');
      const r = await c.post('/api/v1/auth/password-reset/passkey', { email: 'admin@example.org', challengeId: o.json.challengeId, response: authn.assert(o.json.options), authKey: key(), client: 'app', device: { name: 'Handy', platform: 'android' } });
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      expect((await harness.db.execute<{ origin: string }>(sql`select origin from sessions where user_id = ${f.adminId} and revoked_at is null`)).rows).toEqual([{ origin: 'login' }]);
      expect((await rotate(c, 1)).status).toBe(200);
      expect((await kinds(c)).includes('key_rotated')).toBe(true);
      // derselbe Konto-Reset mit einem Wiederherstellungscode: gesperrt
      const c2 = world.client('203.0.113.146');
      const r2 = await c2.post('/api/v1/auth/password-reset/recovery', { email: 'admin@example.org', code: f.a.recoveryCodes[0], authKey: key(), client: 'app', device: { name: 'Zweit', platform: 'android' } });
      expect(r2.status).toBe(200);
      c2.adopt(r2.json.session);
      expect((await rotate(c2, 2)).json.error).toBe('destructive_locked');
    });

    it('Admin-Sitzung aus Code: Mitglied entfernen und zurücksetzen gesperrt; normale Admin-Sitzung bleibt frei', async () => {
      const f = await start();
      const { c } = await codeLogin(f, f.a.recoveryCodes[1] as string);
      expect((await c.post(`/api/v1/members/${f.mamaId}/reset`, {})).json.error).toBe('destructive_locked');
      expect((await c.del(`/api/v1/members/${f.mamaId}`)).json.error).toBe('destructive_locked');
      await stepUp(f.a.client, f.a.totpSecret);
      expect((await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {})).status).toBe(200);
    });
  });

  describe('key_backup_replaced, Ausdünnen, Seiten', () => {
    it('ein anderer Blob erzeugt das Ereignis key_backup_replaced und weckt die anderen Geräte; derselbe Blob nicht', async () => {
      const f = await start();
      const app = world.client('203.0.113.130');
      const r = await app.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
      app.adopt(r.json.session);
      const topic = randTopic();
      expect((await app.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://${HOST}/${topic}?up=1` } })).status).toBe(200);
      const web = f.a.client;
      await web.post('/api/v1/me/keys', keys());
      const first = blob();
      await web.put('/api/v1/me/key-backup', { blob: first, keyVersion: 1 });
      ntfyCalls = [];
      await web.put('/api/v1/me/key-backup', { blob: first, keyVersion: 1 }); // gleich: nichts
      await wait(300);
      expect(ntfyCalls).toEqual([]);
      expect(await kinds(web)).not.toContain('key_backup_replaced');
      await web.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      await settle();
      expect(ntfyCalls).toEqual([{ url: `/${topic}`, body: WAKE_BODY }]);
      const ev = (await events(web)).filter((e) => e.kind === 'key_backup_replaced');
      expect(ev).toHaveLength(1);
      expect(ev[0]).toMatchObject({ via: 'password', byAdmin: false, actorName: null });
      // kritisch: nie entprellt (zweites Ersetzen kurz danach: zweites Ereignis)
      await web.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      expect((await events(web)).filter((e) => e.kind === 'key_backup_replaced')).toHaveLength(2);
    });

    it('viele Ersetzungen: die ältesten 5 und die neuesten 50 bleiben (die echte Sicherung geht nicht unter), Rotation-Einträge nie ausgedünnt', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const echt = blob();
      await c.put('/api/v1/me/key-backup', { blob: echt, keyVersion: 1 });
      for (let i = 0; i < 60; i++) {
        world.advance(1000);
        expect((await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
      }
      const rows = (await harness.db.execute<{ n: number }>(sql`select count(*)::int as n from key_backup_archive where reason = 'replaced'`)).rows[0]?.n;
      expect(rows).toBe(55);
      const alle = (await archive(c)).filter((e) => e.kind === 'recovery');
      expect(alle).toHaveLength(50); // die Liste zeigt höchstens 50 ersetzte
      // die echte (älteste) Sicherung ist in der Tabelle geblieben
      const blobs = (await harness.db.execute<{ blob: string }>(sql`select blob from key_backup_archive`)).rows.map((r) => r.blob);
      expect(blobs).toContain(echt);
      // Wechsel: der Eintrag `rotation` kommt immer zuerst, vollständig, und wird beim Ausdünnen nie berührt
      expect((await rotate(c, 1)).status).toBe(200);
      const s2 = await volleSicherung(c, 2);
      for (let i = 0; i < 60; i++) {
        world.advance(1000);
        await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 2 });
      }
      expect((await rotate(c, 2)).status).toBe(200);
      const liste = await archive(c);
      expect(liste.filter((e) => e.reason === 'rotation' && e.kind === 'recovery')).toHaveLength(2);
      expect(liste.slice(0, 2).every((e) => e.reason === 'rotation')).toBe(true);
      expect(liste.filter((e) => e.reason === 'replaced').length).toBeLessThanOrEqual(50);
      const rot2 = liste.find((e) => e.reason === 'rotation' && e.keyVersion === 2);
      expect(rot2).toBeTruthy();
      void s2;
      // je Stand die ältesten 5 bleiben: Stand 1 behält seine ältesten, auch wenn Stand 2 viele Ersetzungen hat
      const v1 = (await harness.db.execute<{ n: number }>(sql`select count(*)::int as n from key_backup_archive where reason = 'replaced' and key_version = 1`)).rows[0]?.n;
      expect(v1).toBeGreaterThanOrEqual(5);
    });

    it('Seiten über limit und before: lückenlos, ohne Doppelte, Reihenfolge fest; ungültiger Cursor 400', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      await volleSicherung(c, 1);
      for (let i = 0; i < 12; i++) {
        world.advance(1000);
        await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      }
      expect((await rotate(c, 1)).status).toBe(200);
      const voll = (await c.get('/api/v1/me/key-backups/archive')).json;
      expect(voll.next).toBeNull();
      const ids: string[] = [];
      let before: string | undefined;
      let seiten = 0;
      do {
        const r = await c.get(`/api/v1/me/key-backups/archive?limit=5${before ? `&before=${encodeURIComponent(before)}` : ''}`);
        expect(r.status).toBe(200);
        expect(r.json.entries.length).toBeLessThanOrEqual(5);
        ids.push(...r.json.entries.map((e: { id: string }) => e.id));
        before = r.json.next ?? undefined;
        seiten++;
      } while (before && seiten < 20);
      expect(ids).toEqual(voll.entries.map((e: { id: string }) => e.id));
      expect(new Set(ids).size).toBe(ids.length);
      expect(seiten).toBeGreaterThan(2);
      expect(voll.entries.length).toBeGreaterThanOrEqual(13); // 12 ersetzte + 1 Rotation (+ Passwort-Zeile)
      expect(voll.entries[0].reason).toBe('rotation');
      expect((await c.get('/api/v1/me/key-backups/archive?before=quatsch')).status).toBe(400);
      expect((await c.get('/api/v1/me/key-backups/archive?limit=0')).status).toBe(400);
      expect((await c.get('/api/v1/me/key-backups/archive?limit=500')).status).toBe(400);
      expect((await c.get('/api/v1/me/key-backups/archive?x=1')).status).toBe(400);
    });

    it('unbestätigte Passwort-Sicherungen älterer Stände: höchstens 50 in der Liste, die Zahl stimmt mit der Liste überein, bestätigte vollständig', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const s1 = await volleSicherung(c, 1);
      for (let i = 0; i < 55; i++) await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect((await rotate(c, 1)).status).toBe(200);
      const liste = (await archive(c)).filter((e) => e.kind === 'password');
      expect(liste.filter((e) => !e.verified).length).toBeLessThanOrEqual(50);
      expect(liste.find((e) => e.id === s1.pwId)).toMatchObject({ verified: true, reason: 'rotation' });
      const k = (await c.get('/api/v1/me/keys')).json;
      expect(k.archiveCount).toBe((await archive(c)).length);
    });

    it('ohne Schalter E2EE_PW_BACKUP: Liste, Zahl und Einzelabruf zählen nur Wiederherstellungssicherungen (konsistent)', async () => {
      const f = await start({ E2EE_PW_BACKUP: 'false' });
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      expect((await rotate(c, 1)).status).toBe(200);
      // eine Passwort-Zeile aus der Zeit mit Schalter an (direkt eingefügt)
      const pwId = (
        await harness.db.execute<{ id: string }>(sql`insert into key_backups_pw (user_id, family_id, blob, key_version, kdf_id, mem_kib, ops, salt_generation, state, verified_at)
          select user_id, family_id, ${blob()}::text, 1, 'argon2id-v1', 65536, 3, 1, 'superseded', now() from memberships where user_id = ${f.adminId} returning id`)
      ).rows[0]?.id as string;
      const liste = await archive(c);
      expect(liste.map((e) => e.kind)).toEqual(['recovery']);
      expect((await c.get('/api/v1/me/keys')).json.archiveCount).toBe(1);
      expect((await c.get(`/api/v1/me/key-backups/archive/${pwId}`)).status).toBe(404);
    });
  });

  describe('Entprellung und Ereignisliste (M4)', () => {
    it('Lese-Ereignisse je Art und Person höchstens alle 10 Minuten, Wecker höchstens einer je Person in 60 s; kritische nie entprellt', async () => {
      const f = await start();
      const app = world.client('203.0.113.131');
      const r = await app.post('/api/v1/auth/login/password', { email: 'admin@example.org', password: PW, totp: await totp(f.a.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
      app.adopt(r.json.session);
      const topic = randTopic();
      await app.request('PUT', '/api/v1/me/push', { body: { endpoint: `https://${HOST}/${topic}?up=1` } });
      const web = f.a.client;
      await web.post('/api/v1/me/keys', keys());
      await volleSicherung(web, 1);
      ntfyCalls = [];
      world.advance(1000);
      for (let i = 0; i < 5; i++) expect((await web.get('/api/v1/me/key-backup')).status).toBe(200); // fünf Abrufe: ein Ereignis, ein Wecker
      expect((await web.get('/api/v1/me/key-backup-pw')).status).toBe(200); // andere Art: eigenes Ereignis, aber der Wecker kommt höchstens einmal je Minute
      await settle();
      await wait(300);
      expect(await kinds(web)).toEqual(expect.arrayContaining(['key_backup_read', 'key_backup_pw_read']));
      expect((await kinds(web)).filter((k) => k === 'key_backup_read')).toHaveLength(1);
      expect(ntfyCalls).toHaveLength(1);
      // nach 11 Minuten wieder ein Ereignis und ein Wecker
      world.advance(11 * MIN);
      await stepUp(web, f.a.totpSecret);
      ntfyCalls = [];
      await web.get('/api/v1/me/key-backup');
      await settle();
      expect((await kinds(web)).filter((k) => k === 'key_backup_read')).toHaveLength(2);
      expect(ntfyCalls).toHaveLength(1);
      // kritisch: zwei Wechsel kurz hintereinander = zwei Ereignisse und zwei Wecker
      ntfyCalls = [];
      await stepUp(web, f.a.totpSecret);
      expect((await rotate(web, 1)).status).toBe(200);
      expect((await rotate(web, 2)).status).toBe(200);
      await wait(400);
      expect((await kinds(web)).filter((k) => k === 'key_rotated')).toHaveLength(2);
      expect(ntfyCalls.length).toBeGreaterThanOrEqual(1); // kritisch: nie durch die Lese-Entprellung unterdrückt (zwei Ereignisse oben)
      // das Round-Trip-Lesen (?pending=1) bleibt ereignisfrei
      const vorher = await world.count('security_events');
      await web.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 3, kdf: kdf() });
      expect((await web.get('/api/v1/me/key-backup-pw?pending=1')).status).toBe(200);
      expect(await world.count('security_events')).toBe(vorher);
    });

    it('kritische Ereignisse werden in der Liste nie von Lese-Ereignissen verdrängt; Obergrenzen je Art', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      await rotate(c, 1); // ein altes, kritisches Ereignis
      world.advance(MIN);
      // 80 neuere Lese-Ereignisse und 120 kritische (direkt eingefügt)
      await harness.db.execute(sql`insert into security_events (family_id, user_id, kind, via, created_at)
        select m.family_id, m.user_id, 'key_backup_read', 'password', now() + (g || ' seconds')::interval from memberships m, generate_series(1, 80) g where m.user_id = ${f.adminId}`);
      const liste = await events(c);
      expect(liste.filter((e) => e.kind === 'key_rotated')).toHaveLength(1);
      expect(liste.filter((e) => e.kind === 'key_backup_read')).toHaveLength(50);
      await harness.db.execute(sql`insert into security_events (family_id, user_id, kind, via, created_at)
        select m.family_id, m.user_id, 'key_rotated', 'password', now() + (g || ' seconds')::interval from memberships m, generate_series(1, 120) g where m.user_id = ${f.adminId}`);
      const l2 = await events(c);
      expect(l2.filter((e) => e.kind === 'key_rotated')).toHaveLength(100);
      expect(l2.filter((e) => e.kind === 'key_backup_read')).toHaveLength(50);
      // absteigend nach Zeit sortiert
      const zeiten = l2.map((e) => new Date(e.createdAt as string).getTime());
      expect([...zeiten].sort((a, b) => b - a)).toEqual(zeiten);
    });
  });

  describe('Komplett-Reset: Benachrichtigung ist Nebensache (REVIEW M1)', () => {
    it('der Weckhaken wirft: der Reset liefert trotzdem 200 samt Einladung, alle Ereignisse sind da', async () => {
      const f = await start();
      await addMember(world, f.a.client, 'child', 'papa@example.org');
      world.auth.ctx.onSecurityEvent = () => {
        throw new Error('kaputt');
      };
      await stepUp(f.a.client, f.a.totpSecret);
      const r = await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {});
      expect(r.status).toBe(200);
      expect(r.json.invite.token).toBeTruthy();
      const k = (await harness.db.execute<{ kind: string }>(sql`select kind from security_events order by kind`)).rows.map((x) => x.kind);
      expect(k).toEqual(['account_reset_requested', 'member_account_reset', 'member_account_reset']);
    });

    it('das Speichern des Familienhinweises scheitert (Datenbank): Reset und Einladungslink gelingen trotzdem, das eigene Ereignis der Person bleibt', async () => {
      const f = await start();
      await harness.db.execute(sql`create or replace function lx_test_blockiere() returns trigger language plpgsql as $$ begin if new.kind = 'member_account_reset' then raise exception 'blockiert'; end if; return new; end $$`);
      await harness.db.execute(sql`create trigger lx_test_blockiere before insert on security_events for each row execute function lx_test_blockiere()`);
      try {
        await stepUp(f.a.client, f.a.totpSecret);
        const r = await f.a.client.post(`/api/v1/members/${f.mamaId}/reset`, {});
        expect(r.status).toBe(200);
        expect(r.json.invite.token).toBeTruthy();
        const k = (await harness.db.execute<{ kind: string }>(sql`select kind from security_events`)).rows.map((x) => x.kind);
        expect(k).toEqual(['account_reset_requested']);
        // die alten Anmeldedaten sind widerrufen (der Reset hat wirklich stattgefunden)
        expect((await f.m.client.get('/api/v1/me')).status).toBe(401);
      } finally {
        await harness.db.execute(sql`drop trigger if exists lx_test_blockiere on security_events`);
        await harness.db.execute(sql`drop function if exists lx_test_blockiere()`);
      }
    });
  });

  describe('alte Apps bleiben kompatibel', () => {
    it('bestehende Antworten behalten ihre Felder (neue nur additiv); der Wechsel ohne Besonderheiten funktioniert wie bisher', async () => {
      const f = await start();
      const c = f.a.client;
      const k = keys();
      expect((await c.post('/api/v1/me/keys', k)).json).toEqual({ keys: { ...k, keyVersion: 1 } });
      expect((await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).json).toEqual({ ok: true });
      const b = blob();
      await c.put('/api/v1/me/key-backup', { blob: b, keyVersion: 1 });
      expect((await c.get('/api/v1/me/key-backup')).json).toEqual({ blob: b, keyVersion: 1 });
      const k2 = keys();
      const r = await c.put('/api/v1/me/keys', { ...k2, expectedKeyVersion: 1 });
      expect(r.json).toEqual({ keys: { ...k2, keyVersion: 2 } });
      const g = (await c.get('/api/v1/me/keys')).json;
      for (const feld of ['keys', 'hasBackup']) expect(g).toHaveProperty(feld);
      // Fehlercodes der Altwege unverändert
      expect((await c.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 })).json.error).toBe('key_version_mismatch');
      expect((await c.put('/api/v1/me/keys', { ...k2, expectedKeyVersion: 2 })).json.error).toBe('keys_unchanged');
    });
  });
});
