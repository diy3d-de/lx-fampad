// E2EE, vereinfachte Schlüsselverwaltung (Schalter E2EE_PW_BACKUP): KDF-Parameter vor der Anmeldung und opake Passwort-Sicherung
// (PGlite und echtes PostgreSQL). Aus = die Routen gibt es nicht (404), alte Routen verhalten sich unverändert.
import { randomBytes } from 'node:crypto';
import { Writable } from 'node:stream';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';
import { addMember, adminPassword, auditEvents, backends, TEST_KEY, World, type Harness } from './helpers.js';

const MIN = 60_000;
const key = () => randomBytes(32).toString('base64url');
const blob = (n = 160) => randomBytes(n).toString('base64url');
const kdf = (over: Record<string, unknown> = {}) => ({ id: 'argon2id-v1', memKiB: 65536, ops: 3, salt: randomBytes(16).toString('base64url'), ...over });
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });

describe('Konfiguration E2EE_PW_BACKUP', () => {
  const cfg = (v?: string) => loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, ...(v === undefined ? {} : { E2EE_PW_BACKUP: v }) }).e2eePwBackup;
  it('Standard aus; true/1 an; false/0/leer aus; alles andere bricht ab', () => {
    expect(cfg()).toBe(false);
    expect(cfg('')).toBe(false);
    expect(cfg('false')).toBe(false);
    expect(cfg('0')).toBe(false);
    expect(cfg('true')).toBe(true);
    expect(cfg('1')).toBe(true);
    expect(() => cfg('ja')).toThrow(/E2EE_PW_BACKUP/);
  });
});

describe.each(backends)('Passwort-Sicherung ($name)', (backend) => {
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

  async function start(env: Record<string, string> = { E2EE_PW_BACKUP: 'true' }, extra: { logStream?: Writable } = {}) {
    world = await World.create(harness.db, env, extra);
    const a = await adminPassword(world);
    const b = await addMember(world, a.client, 'parent', 'mama@example.org');
    return { a: a.client, b: b.client };
  }
  const states = async () => (await harness.db.execute<{ state: string }>(sql`select state from key_backups_pw order by state`)).rows.map((r) => r.state);

  describe('Schalter aus (Standard)', () => {
    it('Routen gibt es nicht (404, auch mit Anmeldung), /version meldet false, Alt-Routen unverändert, keine Zeilen', async () => {
      const { a } = await start({});
      expect((await a.post('/api/v1/auth/kdf-params', { email: 'admin@example.org' })).status).toBe(404);
      expect((await world.client().post('/api/v1/auth/kdf-params', { email: 'x@example.org' })).json.error).toBe('not_found');
      await a.post('/api/v1/me/keys', keys());
      expect((await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() })).status).toBe(404);
      expect((await a.get('/api/v1/me/key-backup-pw')).status).toBe(404);
      expect((await a.post('/api/v1/me/key-backup-pw/verified', { id: '00000000-0000-4000-8000-000000000000' })).status).toBe(404);
      expect((await world.app.inject('/api/v1/version')).json().features).toEqual({ pwBackup: false });
      // alter Weg funktioniert wie zuvor
      expect((await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
      expect((await a.get('/api/v1/me/keys')).json.hasBackup).toBe(true);
      expect((await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 })).status).toBe(200);
      expect(await world.count('key_backups_pw')).toBe(0);
      expect(await world.count('account_kdf')).toBe(0);
    });
  });

  describe('Schalter an', () => {
    it('/version meldet features.pwBackup', async () => {
      await start();
      expect((await world.app.inject('/api/v1/version')).json().features).toEqual({ pwBackup: true });
    });

    it('Ablegen, Abrufen, Verifizieren; Antwort nur mit blob, kdf, keyVersion, state (und id)', async () => {
      const { a } = await start();
      await a.post('/api/v1/me/keys', keys());
      expect((await a.get('/api/v1/me/key-backup-pw')).status).toBe(404);
      const bl = blob();
      const k = kdf();
      const put = await a.put('/api/v1/me/key-backup-pw', { blob: bl, keyVersion: 1, kdf: k });
      expect(put.status).toBe(200);
      expect(put.json.ok).toBe(true);
      const got = await a.get('/api/v1/me/key-backup-pw');
      expect(got.status).toBe(200);
      expect(got.json).toEqual({ id: put.json.id, blob: bl, keyVersion: 1, state: 'active', kdf: k });
      expect((await harness.db.execute(sql`select verified_at from key_backups_pw`)).rows[0]).toEqual({ verified_at: null });
      expect((await a.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
      expect(((await harness.db.execute(sql`select verified_at from key_backups_pw`)).rows[0] as { verified_at: unknown }).verified_at).not.toBeNull();
      expect(await auditEvents(world)).toEqual(expect.arrayContaining(['key_backup_pw_set', 'key_backup_pw_read', 'key_backup_pw_verified']));
    });

    it('prüft Form und Größe streng (400), ohne Anmeldung 401', async () => {
      const { a } = await start();
      await a.post('/api/v1/me/keys', keys());
      const ok = { blob: blob(), keyVersion: 1, kdf: kdf() };
      for (const bad of [
        { ...ok, blob: 'kurz' },
        { ...ok, blob: blob(4000) }, // > 4096 Zeichen
        { ...ok, blob: `${blob()}=` },
        { ...ok, keyVersion: 0 },
        { ...ok, kdf: kdf({ id: 'scrypt' }) },
        { ...ok, kdf: kdf({ salt: randomBytes(15).toString('base64url') }) },
        { ...ok, kdf: kdf({ salt: randomBytes(17).toString('base64url') }) },
        { ...ok, kdf: kdf({ salt: `${randomBytes(16).toString('base64url').slice(0, 21)}B` }) }, // nicht kanonisch
        { ...ok, kdf: kdf({ memKiB: 1024 }) },
        { ...ok, kdf: kdf({ memKiB: 99_999_999 }) },
        { ...ok, kdf: kdf({ ops: 0 }) },
        { ...ok, kdf: kdf({ ops: 99 }) },
        { ...ok, kdf: { ...kdf(), extra: 1 } },
        { ...ok, extra: 1 },
        { blob: ok.blob, keyVersion: 1 },
      ]) {
        expect((await a.put('/api/v1/me/key-backup-pw', bad)).status, JSON.stringify(bad).slice(0, 80)).toBe(400);
      }
      expect(await world.count('key_backups_pw')).toBe(0);
      expect((await world.client().put('/api/v1/me/key-backup-pw', ok)).status).toBe(401);
      expect((await world.client().get('/api/v1/me/key-backup-pw')).status).toBe(401);
      expect((await world.client().post('/api/v1/me/key-backup-pw/verified', { id: '00000000-0000-4000-8000-000000000000' })).status).toBe(401);
    });

    it('verlangt Step-up (Ablegen, Abrufen, Verifizieren); ohne Schlüssel 409, falsche Version 409', async () => {
      const { a } = await start();
      const body = { blob: blob(), keyVersion: 1, kdf: kdf() };
      expect((await a.put('/api/v1/me/key-backup-pw', body)).json.error).toBe('no_keys');
      await a.post('/api/v1/me/keys', keys());
      expect((await a.put('/api/v1/me/key-backup-pw', { ...body, keyVersion: 2 })).json.error).toBe('key_version_mismatch');
      const put = await a.put('/api/v1/me/key-backup-pw', body);
      expect(put.status).toBe(200);
      world.advance(6 * MIN);
      for (const r of [await a.put('/api/v1/me/key-backup-pw', body), await a.get('/api/v1/me/key-backup-pw'), await a.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })]) {
        expect(r.status).toBe(403);
        expect(r.json.error).toBe('step_up_required');
      }
      expect(await states()).toEqual(['active']);
    });

    it('eine neue Sicherung ersetzt die aktuelle: alte Zeilen bleiben als superseded erhalten (nie löschen)', async () => {
      const { a } = await start();
      await a.post('/api/v1/me/keys', keys());
      const k1 = kdf();
      const b1 = blob();
      const p1 = await a.put('/api/v1/me/key-backup-pw', { blob: b1, keyVersion: 1, kdf: k1 });
      const k2 = kdf();
      const b2 = blob();
      const p2 = await a.put('/api/v1/me/key-backup-pw', { blob: b2, keyVersion: 1, kdf: k2 });
      expect(p1.json.id).not.toBe(p2.json.id);
      expect(await states()).toEqual(['active', 'superseded']);
      expect((await a.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: p2.json.id, blob: b2, kdf: k2 });
      // die ersetzte lässt sich nicht mehr verifizieren (409), die Zeile bleibt
      expect((await a.post('/api/v1/me/key-backup-pw/verified', { id: p1.json.id })).json.error).toBe('backup_not_current');
      expect((await harness.db.execute<{ blob: string }>(sql`select blob from key_backups_pw where id = ${p1.json.id}`)).rows[0]?.blob).toBe(b1);
      const v = (await harness.db.execute<{ version: number }>(sql`select version from account_kdf`)).rows[0]?.version;
      expect(v).toBe(2);
      // gleiche Parameter erhöhen die KDF-Version nicht
      await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: k2 });
      expect((await harness.db.execute<{ version: number }>(sql`select version from account_kdf`)).rows[0]?.version).toBe(2);
    });

    it('Rechte: nur die eigene Zeile (IDOR); fremde ID beim Verifizieren 404, fremder Abruf liefert nichts', async () => {
      const { a, b } = await start();
      await a.post('/api/v1/me/keys', keys());
      await b.post('/api/v1/me/keys', keys());
      const pa = await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect((await b.get('/api/v1/me/key-backup-pw')).status).toBe(404);
      expect((await b.post('/api/v1/me/key-backup-pw/verified', { id: pa.json.id })).status).toBe(404);
      expect((await b.post('/api/v1/me/key-backup-pw/verified', { id: '00000000-0000-4000-8000-000000000000' })).status).toBe(404);
      expect((await b.post('/api/v1/me/key-backup-pw/verified', { id: 'nichtuuid' })).status).toBe(400);
      // b legt eigene ab: a's Zeile bleibt unberührt
      const pb = await b.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect(await states()).toEqual(['active', 'active']);
      expect((await a.get('/api/v1/me/key-backup-pw')).json.id).toBe(pa.json.id);
      expect((await b.get('/api/v1/me/key-backup-pw')).json.id).toBe(pb.json.id);
      expect((await a.post('/api/v1/me/key-backup-pw/verified', { id: pb.json.id })).status).toBe(404);
    });

    it('Schlüsselwechsel setzt die Sicherung auf stale statt zu löschen; neue Sicherung der neuen Version ersetzt sie', async () => {
      const { a } = await start();
      await a.post('/api/v1/me/keys', keys());
      await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
      const pw = await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      const r = await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 });
      expect(r.status).toBe(200);
      expect(await world.count('key_backups')).toBe(0); // alter Weg: wie bisher gelöscht
      expect(await states()).toEqual(['stale']);
      const got = await a.get('/api/v1/me/key-backup-pw');
      expect(got.json).toMatchObject({ id: pw.json.id, state: 'stale', keyVersion: 1 });
      expect((await a.post('/api/v1/me/key-backup-pw/verified', { id: pw.json.id })).json.error).toBe('backup_not_current');
      expect((await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() })).json.error).toBe('key_version_mismatch');
      expect((await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 2, kdf: kdf() })).status).toBe(200);
      expect(await states()).toEqual(['active', 'superseded']);
    });

    it('Teilausfall: scheitert das Audit, bleibt alles wie zuvor (nichts halb)', async () => {
      const log: string[] = [];
      const { a } = await start({ E2EE_PW_BACKUP: 'true', LOG_LEVEL: 'info' }, { logStream: new Writable({ write: (c, _e, cb) => (log.push(String(c)), cb()) }) });
      await a.post('/api/v1/me/keys', keys());
      const k1 = kdf();
      const first = await a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: k1 });
      const geheimBlob = blob();
      const geheimSalt = randomBytes(16).toString('base64url');
      await harness.db.execute(sql`create function pw_fail() returns trigger language plpgsql as $$ begin if new.event in ('key_backup_pw_set', 'key_backup_pw_read') then raise exception 'boom'; end if; return new; end $$`);
      await harness.db.execute(sql`create trigger pw_fail_t before insert on audit_log for each row execute function pw_fail()`);
      try {
        const put = await a.put('/api/v1/me/key-backup-pw', { blob: geheimBlob, keyVersion: 1, kdf: kdf({ salt: geheimSalt }) });
        expect(put.status).toBe(500);
        expect((await a.get('/api/v1/me/key-backup-pw')).status).toBe(500); // kein unprotokollierter Abruf
      } finally {
        await harness.db.execute(sql`drop trigger pw_fail_t on audit_log`);
        await harness.db.execute(sql`drop function pw_fail()`);
      }
      expect(await states()).toEqual(['active']);
      expect(await world.count('account_kdf')).toBe(1);
      expect((await a.get('/api/v1/me/key-backup-pw')).json).toMatchObject({ id: first.json.id, kdf: k1 });
      // weder Blob noch Salt im Log
      const text = log.join('');
      expect(text).not.toContain(geheimBlob);
      expect(text).not.toContain(geheimSalt);
    });

    it('Audit enthält weder Blob noch Salt', async () => {
      const { a } = await start();
      await a.post('/api/v1/me/keys', keys());
      const bl = blob();
      const k = kdf();
      const p = await a.put('/api/v1/me/key-backup-pw', { blob: bl, keyVersion: 1, kdf: k });
      await a.get('/api/v1/me/key-backup-pw');
      await a.post('/api/v1/me/key-backup-pw/verified', { id: p.json.id });
      const audit = JSON.stringify((await harness.db.execute(sql`select detail from audit_log`)).rows);
      expect(audit).not.toContain(bl);
      expect(audit).not.toContain(k.salt);
    });

    it('gleichzeitige Ablagen: alle gelingen nacheinander, genau eine Zeile bleibt aktuell', async () => {
      const { a } = await start();
      await a.post('/api/v1/me/keys', keys());
      const res = await Promise.all(Array.from({ length: 5 }, () => a.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() })));
      expect(res.map((r) => r.status)).toEqual([200, 200, 200, 200, 200]);
      const st = await states();
      expect(st).toHaveLength(5);
      expect(st.filter((s) => s === 'active')).toHaveLength(1);
      expect(st.filter((s) => s === 'superseded')).toHaveLength(4);
      expect(await world.count('account_kdf')).toBe(1);
    });

    it('Rate-Limit: strenge Grenze auf kdf-params, Abruf und Ablegen', async () => {
      await world?.close();
      world = await World.create(harness.db, { E2EE_PW_BACKUP: 'true', AUTH_RATE_LIMIT_MAX: '5' });
      const a = (await adminPassword(world)).client;
      await a.post('/api/v1/me/keys', keys());
      const codes = async (f: () => Promise<{ status: number }>) => {
        const out: number[] = [];
        for (let i = 0; i < 12; i++) out.push((await f()).status);
        return out;
      };
      expect(await codes(() => world.client('198.51.100.1').post('/api/v1/auth/kdf-params', { email: 'x@example.org' }))).toContain(429);
      expect(await codes(() => a.get('/api/v1/me/key-backup-pw'))).toContain(429);
    });
  });

  describe('POST /auth/kdf-params', () => {
    it('echte Parameter nach der Ablage; vorher, bei unbekannten und deaktivierten Konten eine gleich geformte, stabile Fake-Antwort', async () => {
      const { b } = await start();
      const anon = world.client('198.51.100.7');
      const get = async (email: string) => {
        const r = await anon.post('/api/v1/auth/kdf-params', { email });
        expect(r.status).toBe(200);
        return r.json.kdf as { id: string; memKiB: number; ops: number; salt: string };
      };
      const unbekannt = await get('niemand@example.org');
      expect(Object.keys(unbekannt).sort()).toEqual(['id', 'memKiB', 'ops', 'salt']);
      expect(unbekannt).toMatchObject({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
      expect(Buffer.from(unbekannt.salt, 'base64url')).toHaveLength(16);
      // stabil, von der E-Mail abhängig, Groß-/Kleinschreibung egal
      expect(await get('niemand@example.org')).toEqual(unbekannt);
      expect(await get('  NIEMAND@example.org ')).toEqual(unbekannt);
      expect((await get('anderer@example.org')).salt).not.toBe(unbekannt.salt);
      // Konto ohne Eintrag: ebenfalls Fake
      const ohne = await get('mama@example.org');
      expect(Object.keys(ohne).sort()).toEqual(['id', 'memKiB', 'ops', 'salt']);
      expect(await get('mama@example.org')).toEqual(ohne);
      // mit Eintrag: echte Werte
      await b.post('/api/v1/me/keys', keys());
      const k = kdf({ memKiB: 32768, ops: 4 });
      await b.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: k });
      expect(await get('mama@example.org')).toEqual(k);
      expect(await get('MAMA@example.org')).toEqual(k);
      expect(await get('admin@example.org')).not.toEqual(k);
      // deaktiviert: wieder Fake, nicht die echten Werte
      await harness.db.execute(sql`update users set disabled_at = now() where email = 'mama@example.org'`);
      const gesperrt = await get('mama@example.org');
      expect(gesperrt).not.toEqual(k);
      expect(gesperrt).toEqual(ohne);
    });

    it('Eingabe streng (400), Anmeldung nicht nötig, Antwort kennt nur kdf', async () => {
      await start();
      const anon = world.client('198.51.100.8');
      expect((await anon.post('/api/v1/auth/kdf-params', {})).status).toBe(400);
      expect((await anon.post('/api/v1/auth/kdf-params', { email: 'kein-mail' })).status).toBe(400);
      expect((await anon.post('/api/v1/auth/kdf-params', { email: 'a@example.org', x: 1 })).status).toBe(400);
      const ok = await anon.post('/api/v1/auth/kdf-params', { email: 'a@example.org' });
      expect(Object.keys(ok.json)).toEqual(['kdf']);
    });

    it('Antwortzeit für bekannte und unbekannte Konten grob gleich (kein Orakel)', async () => {
      const { b } = await start();
      await b.post('/api/v1/me/keys', keys());
      await b.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      const anon = world.client('198.51.100.9');
      const median = async (email: string) => {
        const t: number[] = [];
        for (let i = 0; i < 15; i++) {
          const s = process.hrtime.bigint();
          await anon.post('/api/v1/auth/kdf-params', { email });
          t.push(Number(process.hrtime.bigint() - s) / 1e6);
        }
        return t.sort((x, y) => x - y)[7] as number;
      };
      await median('warmup@example.org');
      const bekannt = await median('mama@example.org');
      const unbekannt = await median('niemand@example.org');
      expect(Math.abs(bekannt - unbekannt)).toBeLessThan(100);
    });
  });
});
