// E2EE, Passkey-Sicherung (Schalter E2EE_PRF_BACKUP): opaker Blob je Passkey, Zustandsautomat wie bei der Passwort-Sicherung, Schlüsselwechsel, Archiv, Ampel
// (PGlite und echtes PostgreSQL). Aus = die Routen gibt es nicht (404), alte Routen verhalten sich unverändert.
import { randomBytes } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { runMaintenance } from '../src/auth/maintenance.js';
import { loadConfig } from '../src/config.js';
import { authenticationResponseSchema, registrationResponseSchema } from '../src/routes/util.js';
import { TestAuthenticator } from './authenticator.js';
import { adminPasskey, auditEvents, backends, TEST_KEY, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const key = () => randomBytes(32).toString('base64url');
const blob = (n = 110) => randomBytes(n).toString('base64url');
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });

describe('Konfiguration E2EE_PRF_BACKUP und E2EE_PARENT_RECOVERY', () => {
  const cfg = (env: Record<string, string>) => loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, ...env });
  it('Standard aus; true/1 an; false/0/leer aus; alles andere bricht ab', () => {
    for (const name of ['E2EE_PRF_BACKUP', 'E2EE_PARENT_RECOVERY'] as const) {
      const f = (v?: string) => {
        const c = cfg(v === undefined ? {} : { [name]: v });
        return name === 'E2EE_PRF_BACKUP' ? c.e2eePrfBackup : c.e2eeParentRecovery;
      };
      expect(f()).toBe(false);
      expect(f('')).toBe(false);
      expect(f('0')).toBe(false);
      expect(f('true')).toBe(true);
      expect(f('1')).toBe(true);
      expect(() => f('ja')).toThrow(new RegExp(name));
    }
  });
  it('Wartefrist: Standard 24 Stunden, 24 bis 168 ganze Stunden, sonst Startabbruch', () => {
    expect(cfg({}).parentRecoveryWaitHours).toBe(24);
    expect(cfg({ E2EE_PARENT_RECOVERY_WAIT_HOURS: '48' }).parentRecoveryWaitHours).toBe(48);
    for (const bad of ['0', '23', '169', '1.5', 'abc', '-1']) expect(() => cfg({ E2EE_PARENT_RECOVERY_WAIT_HOURS: bad }), bad).toThrow(/WAIT_HOURS/);
  });
});

describe('Passkey-Antworten ohne PRF-Ausgabe', () => {
  it('der Server verwirft clientExtensionResults.prf beim Parsen (Anmeldung und Registrierung), anderes bleibt', () => {
    const antwort = { id: 'a', rawId: 'a', type: 'public-key', response: {}, clientExtensionResults: { prf: { results: { first: 'AAAA' } }, credProps: { rk: true } } };
    for (const schema of [authenticationResponseSchema, registrationResponseSchema]) {
      const r = schema.parse(antwort) as unknown as { clientExtensionResults: Record<string, unknown> };
      expect(r.clientExtensionResults).toEqual({ credProps: { rk: true } });
      expect(JSON.stringify(r)).not.toContain('AAAA');
    }
    expect((authenticationResponseSchema.parse({ ...antwort, clientExtensionResults: undefined }) as unknown as { clientExtensionResults: object }).clientExtensionResults).toEqual({});
  });
});

describe.each(backends)('Passkey-Sicherung ($name)', (backend) => {
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

  /** Admin per Passkey (mit Schlüssel), dazu ein Mitglied per Passkey. */
  async function start(env: Record<string, string> = { E2EE_PRF_BACKUP: 'true' }) {
    world = await World.create(harness.db, env);
    const a = await adminPasskey(world);
    const inv = await a.client.post('/api/v1/invites', { role: 'parent' });
    const b = await world.registerPasskey(inv.json.invite.token, { email: 'mama@example.org', displayName: 'Mama' });
    return { a: a.client, aKey: a.authenticator, b: b.client, bKey: b.authenticator };
  }
  const states = async () => (await harness.db.execute<{ state: string }>(sql`select state from key_backups_prf order by state`)).rows.map((r) => r.state);
  const put = (c: Client, credentialId: string, over: Record<string, unknown> = {}) => c.put('/api/v1/me/key-backup-prf', { credentialId, blob: blob(), keyVersion: 1, ...over });

  describe('Schalter aus (Standard)', () => {
    it('Routen gibt es nicht (404), /version meldet false, GET /me/keys ohne die neuen Felder, keine Zeilen', async () => {
      const { a, aKey } = await start({});
      await a.post('/api/v1/me/keys', keys());
      expect((await put(a, aKey.id)).status).toBe(404);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).status).toBe(404);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: '00000000-0000-4000-8000-000000000000' })).status).toBe(404);
      const f = (await world.app.inject('/api/v1/version')).json().features;
      expect(f).toMatchObject({ prfBackup: false, parentRecovery: false });
      const k = (await a.get('/api/v1/me/keys')).json;
      expect(k).not.toHaveProperty('prfBackupVerifiedAt');
      expect(k).not.toHaveProperty('prfBackupCredentialIds');
      expect(await world.count('key_backups_prf')).toBe(0);
    });
  });

  describe('Schalter an', () => {
    it('/version meldet features.prfBackup', async () => {
      await start();
      expect((await world.app.inject('/api/v1/version')).json().features).toMatchObject({ prfBackup: true, parentRecovery: false });
    });

    it('Ablegen, Abrufen, Bestätigen; Antwort nur mit id, credentialId, blob, keyVersion, state', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).status).toBe(404);
      const bl = blob();
      const p = await a.put('/api/v1/me/key-backup-prf', { credentialId: aKey.id, blob: bl, keyVersion: 1 });
      expect(p.status).toBe(200);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).status).toBe(404); // unbestätigt ist noch nichts aktuell
      const got = await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}&pending=1`);
      expect(got.json).toEqual({ id: p.json.id, credentialId: aKey.id, blob: bl, keyVersion: 1, state: 'pending' });
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id })).status).toBe(200);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).json).toEqual({ id: p.json.id, credentialId: aKey.id, blob: bl, keyVersion: 1, state: 'active' });
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id })).status).toBe(200); // wiederholt: folgenlos
      expect(await auditEvents(world)).toEqual(expect.arrayContaining(['key_backup_prf_set', 'key_backup_prf_read', 'key_backup_prf_verified']));
      const k = (await a.get('/api/v1/me/keys')).json;
      expect(k.prfBackupVerifiedAt).toEqual(expect.any(String));
      expect(k.prfBackupCredentialIds).toEqual([aKey.id]);
      expect(k.prfBackupStale).toBeUndefined();
    });

    it('prüft Form streng (400) und verlangt Anmeldung (401) und Step-up (403)', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      for (const bad of [
        { credentialId: aKey.id, blob: 'kurz', keyVersion: 1 },
        { credentialId: aKey.id, blob: blob(10), keyVersion: 1 },
        { credentialId: aKey.id, blob: blob(4000), keyVersion: 1 },
        { credentialId: aKey.id, blob: `${blob()}=`, keyVersion: 1 },
        { credentialId: aKey.id, blob: blob(), keyVersion: 0 },
        { credentialId: '', blob: blob(), keyVersion: 1 },
        { credentialId: 'a b', blob: blob(), keyVersion: 1 },
        { credentialId: aKey.id, blob: blob(), keyVersion: 1, extra: 1 },
        { blob: blob(), keyVersion: 1 },
      ]) {
        expect((await a.put('/api/v1/me/key-backup-prf', bad)).status, JSON.stringify(bad).slice(0, 70)).toBe(400);
      }
      expect((await a.get('/api/v1/me/key-backup-prf')).status).toBe(400); // credentialId ist Pflicht
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}&pending=2`)).status).toBe(400);
      expect((await world.client().put('/api/v1/me/key-backup-prf', { credentialId: aKey.id, blob: blob(), keyVersion: 1 })).status).toBe(401);
      expect((await world.client().get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).status).toBe(401);
      expect(await world.count('key_backups_prf')).toBe(0);
      const p = await put(a, aKey.id);
      world.advance(6 * MIN);
      for (const r of [await put(a, aKey.id), await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`), await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id })]) {
        expect(r.status).toBe(403);
        expect(r.json.error).toBe('step_up_required');
      }
      expect(await states()).toEqual(['pending']);
    });

    it('ohne Schlüssel 409, falsche Version 409, unbekannter oder fremder Passkey 409', async () => {
      const { a, aKey, b, bKey } = await start();
      expect((await put(a, aKey.id)).json.error).toBe('no_keys');
      await a.post('/api/v1/me/keys', keys());
      await b.post('/api/v1/me/keys', keys());
      expect((await put(a, aKey.id, { keyVersion: 2 })).json.error).toBe('key_version_mismatch');
      expect((await put(a, key())).json.error).toBe('passkey_unknown');
      expect((await put(a, bKey.id)).json.error).toBe('passkey_unknown'); // der Passkey einer anderen Person
      expect(await world.count('key_backups_prf')).toBe(0);
    });

    it('neue Sicherung ist pending, die alte bleibt gültig bis zur Bestätigung (nie löschen)', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const b1 = blob();
      const p1 = await put(a, aKey.id, { blob: b1 });
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p1.json.id });
      const p2 = await put(a, aKey.id);
      expect(await states()).toEqual(['active', 'pending']);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).json).toMatchObject({ id: p1.json.id, blob: b1, state: 'active' });
      const p3 = await put(a, aKey.id); // ersetzt nur die pending-Zeile
      expect(await states()).toEqual(['active', 'pending', 'superseded']);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p2.json.id })).json.error).toBe('backup_not_current');
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p3.json.id })).status).toBe(200);
      expect(await states()).toEqual(['active', 'superseded', 'superseded']);
      expect(await world.count('key_backups_prf')).toBe(3);
    });

    it('je Passkey eine eigene aktuelle Sicherung; ein zweiter Passkey ersetzt den ersten nicht', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      // zweiten Passkey der Person anlegen
      const second = new TestAuthenticator();
      const opts = await a.post('/api/v1/me/passkeys/options');
      const added = await a.post('/api/v1/me/passkeys/verify', { challengeId: opts.json.challengeId, response: second.register(opts.json.options), label: 'Zweiter' });
      expect(added.status).toBe(200);
      const p1 = await put(a, aKey.id);
      const p2 = await put(a, second.id); // legt die pending-Zeile des ersten ab (höchstens eine pending je Person): erst bestätigen
      expect(p2.status).toBe(200);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p1.json.id })).json.error).toBe('backup_not_current'); // vom zweiten Ablegen ersetzt
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p2.json.id })).status).toBe(200);
      const p3 = await put(a, aKey.id);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p3.json.id })).status).toBe(200);
      expect((await a.get('/api/v1/me/keys')).json.prfBackupCredentialIds.sort()).toEqual([aKey.id, second.id].sort());
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${second.id}`)).json.id).toBe(p2.json.id);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).json.id).toBe(p3.json.id);
    });

    it('Abbruch: die unbestätigte Sicherung verfällt nach einer Stunde (nie gelöscht), die bestätigte bleibt', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const p1 = await put(a, aKey.id);
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p1.json.id });
      await put(a, aKey.id);
      world.advance(4 * MIN);
      await runMaintenance(world.auth.ctx);
      expect(await states()).toEqual(['active', 'pending']);
      world.advance(60 * MIN);
      await runMaintenance(world.auth.ctx);
      expect(await states()).toEqual(['active', 'superseded']);
      expect(await world.count('key_backups_prf')).toBe(2);
    });

    it('Bestätigen nach Ablauf der Stunde scheitert, auch wenn der Aufräumjob noch nicht lief', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const p = await put(a, aKey.id);
      world.advance(3 * MIN);
      // Step-up erneuern, damit nur der Zeitablauf der Sicherung zählt
      await world.loginPasskey(a, aKey);
      world.advance(58 * MIN);
      await world.loginPasskey(a, aKey);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id })).json.error).toBe('backup_not_current');
    });

    it('Rechte: nur die eigene Zeile (IDOR); fremde ID 404, fremder Passkey beim Abruf 404', async () => {
      const { a, aKey, b, bKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      await b.post('/api/v1/me/keys', keys());
      const pa = await put(a, aKey.id);
      expect((await b.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}&pending=1`)).status).toBe(404);
      expect((await b.get(`/api/v1/me/key-backup-prf?credentialId=${bKey.id}&pending=1`)).status).toBe(404);
      expect((await b.post('/api/v1/me/key-backup-prf/verified', { id: pa.json.id })).status).toBe(404);
      const pb = await put(b, bKey.id);
      expect(await states()).toEqual(['pending', 'pending']);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: pb.json.id })).status).toBe(404);
      expect((await b.post('/api/v1/me/key-backup-prf/verified', { id: pb.json.id })).status).toBe(200);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${bKey.id}`)).status).toBe(404);
    });

    it('Schlüsselwechsel setzt die Sicherung auf stale statt zu löschen; die neue Version ersetzt sie nach Bestätigung', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const p = await put(a, aKey.id);
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id });
      const offen = await put(a, aKey.id);
      expect((await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 })).status).toBe(200);
      expect(await states()).toEqual(['stale', 'superseded']);
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: offen.json.id })).json.error).toBe('backup_not_current');
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).json).toMatchObject({ id: p.json.id, state: 'stale', keyVersion: 1 });
      const k = (await a.get('/api/v1/me/keys')).json;
      expect(k.prfBackupVerifiedAt).toBeNull(); // zählt nicht für die aktuelle Version
      expect(k.prfBackupStale).toBe(true);
      expect((await put(a, aKey.id)).json.error).toBe('key_version_mismatch');
      const neu = await put(a, aKey.id, { keyVersion: 2 });
      expect((await a.post('/api/v1/me/key-backup-prf/verified', { id: neu.json.id })).status).toBe(200);
      expect(await states()).toEqual(['active', 'superseded', 'superseded']);
      // die ersetzten bleiben im Archiv erreichbar (nie unerreichbar)
      const arch = (await a.get('/api/v1/me/key-backups/archive')).json.entries as Array<{ id: string; kind: string; reason: string }>;
      expect(arch.filter((e) => e.kind === 'passkey').map((e) => e.id)).toContain(p.json.id);
      const detail = await a.get(`/api/v1/me/key-backups/archive/${p.json.id}`);
      expect(detail.status).toBe(200);
      expect(detail.json).toMatchObject({ kind: 'passkey', keyVersion: 1, credentialId: aKey.id });
      expect(typeof detail.json.blob).toBe('string');
    });

    it('ein entfernter Passkey: die Zeile bleibt, wird aber weder geliefert noch gezählt noch bestätigt', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      // einen zweiten Passkey anlegen, damit der erste entfernt werden darf
      const second = new TestAuthenticator();
      const opts = await a.post('/api/v1/me/passkeys/options');
      await a.post('/api/v1/me/passkeys/verify', { challengeId: opts.json.challengeId, response: second.register(opts.json.options), label: 'Zweiter' });
      const p = await put(a, aKey.id);
      const ausstehend = await put(a, aKey.id);
      await a.post('/api/v1/me/key-backup-prf/verified', { id: ausstehend.json.id });
      const cred = (await harness.db.execute<{ id: string }>(sql`select id from credentials where external_id = ${aKey.id}`)).rows[0];
      expect((await a.del(`/api/v1/me/passkeys/${cred?.id}`)).status).toBe(200);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).status).toBe(404);
      expect((await a.get('/api/v1/me/keys')).json.prfBackupCredentialIds).toEqual([]);
      expect((await put(a, aKey.id)).json.error).toBe('passkey_unknown');
      expect(await world.count('key_backups_prf')).toBe(2);
      void p;
    });

    it('Datenbank erzwingt Zustände, Blob-Größe und je Person und Passkey höchstens eine aktuelle Zeile', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const m = (await harness.db.execute<{ user_id: string; family_id: string }>(sql`select user_id, family_id from memberships limit 1`)).rows[0];
      const ins = (over: { blob?: string; state?: string; cred?: string }) =>
        harness.db.execute(sql`insert into key_backups_prf (user_id, family_id, credential_id, blob, key_version, state) values (${m?.user_id}, ${m?.family_id}, ${over.cred ?? aKey.id}, ${over.blob ?? blob()}, 1, ${over.state ?? 'superseded'})`);
      await expect(ins({ blob: 'x'.repeat(95) })).rejects.toThrow();
      await expect(ins({ state: 'kaputt' })).rejects.toThrow();
      await ins({ state: 'active' });
      await expect(ins({ state: 'stale' })).rejects.toThrow(); // zweite aktuelle für denselben Passkey
      await ins({ state: 'active', cred: 'anderer' }); // anderer Passkey: erlaubt
      await ins({ state: 'pending' });
      await expect(ins({ state: 'pending', cred: 'dritter' })).rejects.toThrow(); // höchstens eine pending je Person
    });

    it('Sicherheitsereignis beim Abruf (entprellt), Audit ohne Blob', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const bl = blob();
      const p = await put(a, aKey.id, { blob: bl });
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id });
      await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`);
      await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`);
      const ev = (await harness.db.execute<{ kind: string }>(sql`select kind from security_events where kind = 'key_backup_prf_read'`)).rows;
      expect(ev).toHaveLength(1);
      const audit = JSON.stringify((await harness.db.execute(sql`select detail from audit_log`)).rows);
      expect(audit).not.toContain(bl);
      expect(audit).not.toContain(aKey.id);
    });

    it('Ampel: die Passkey-Sicherung zählt wie die Passwort-Sicherung als EIN Weg (Zugangs-Sicherung)', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const ampel = async () => (await a.get('/api/v1/me/key-status')).json.status;
      await a.put('/api/v1/me/device-key', { keyVersion: 1 });
      expect(await ampel()).toMatchObject({ ampel: 'yellow', wayCount: 1, ways: { device: true, prfBackup: false } });
      const p = await put(a, aKey.id);
      expect(await ampel()).toMatchObject({ ampel: 'yellow', wayCount: 1 }); // unbestätigt zählt nicht
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id });
      // ein an EIN Gerät gebundener Passkey (singleDevice) ist kein Weg: mit dem Gerät wäre auch die Sicherung unlesbar
      expect((await a.get('/api/v1/me/keys')).json).toMatchObject({ prfBackupCredentialIds: [aKey.id], prfBackupSynced: false });
      expect(await ampel()).toMatchObject({ ampel: 'yellow', wayCount: 1, ways: { device: true, prfBackup: false } });
      // BE ohne BS (synchronisierbar, aber noch nicht gesichert): zählt noch nicht
      await harness.db.execute(sql`update credentials set device_type = 'multiDevice', backed_up = false where external_id = ${aKey.id}`);
      expect((await a.get('/api/v1/me/keys')).json.prfBackupSynced).toBe(false);
      expect(await ampel()).toMatchObject({ ampel: 'yellow', wayCount: 1, ways: { prfBackup: false } });
      // synchronisiert (BE und BS, laut Authenticator beim nächsten Anmelden/Registrieren gemeldet): zählt
      await harness.db.execute(sql`update credentials set device_type = 'multiDevice', backed_up = true where external_id = ${aKey.id}`);
      expect((await a.get('/api/v1/me/keys')).json.prfBackupSynced).toBe(true);
      expect(await ampel()).toMatchObject({ ampel: 'green', wayCount: 2, ways: { device: true, prfBackup: true } });
    });

    it('Der Passkey meldet beim Registrieren und Anmelden, ob er synchronisiert ist (BE/BS-Flag); die Angabe wird fortgeschrieben', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const typ = async () => (await harness.db.execute<{ device_type: string | null; backed_up: boolean | null }>(sql`select device_type, backed_up from credentials where external_id = ${aKey.id}`)).rows[0];
      expect(await typ()).toEqual({ device_type: 'singleDevice', backed_up: false });
      aKey.multiDevice = true;
      const neu = world.client('198.51.100.77');
      expect((await world.loginPasskey(neu, aKey)).status).toBe(200);
      expect(await typ()).toEqual({ device_type: 'multiDevice', backed_up: true });
      // BE gesetzt, BS nicht: gemeldet als multiDevice, aber nicht gesichert
      aKey.backupState = false;
      expect((await world.loginPasskey(world.client('198.51.100.78'), aKey)).status).toBe(200);
      expect(await typ()).toEqual({ device_type: 'multiDevice', backed_up: false });
    });

    it('Eine Passkey-Sicherung zu einem entfernten Passkey bleibt über das Archiv erreichbar (nie unerreichbar)', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const second = new TestAuthenticator();
      const opts = await a.post('/api/v1/me/passkeys/options');
      await a.post('/api/v1/me/passkeys/verify', { challengeId: opts.json.challengeId, response: second.register(opts.json.options), label: 'Zweiter' });
      const p = await put(a, aKey.id);
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id });
      const cred = (await harness.db.execute<{ id: string }>(sql`select id from credentials where external_id = ${aKey.id}`)).rows[0];
      expect((await a.del(`/api/v1/me/passkeys/${cred?.id}`)).status).toBe(200);
      expect((await a.get(`/api/v1/me/key-backup-prf?credentialId=${aKey.id}`)).status).toBe(404);
      const arch = (await a.get('/api/v1/me/key-backups/archive')).json.entries as Array<{ id: string; kind: string }>;
      expect(arch.filter((e) => e.kind === 'passkey').map((e) => e.id)).toContain(p.json.id);
      const d = await a.get(`/api/v1/me/key-backups/archive/${p.json.id}`);
      expect(d.status).toBe(200);
      expect(d.json).toMatchObject({ kind: 'passkey', credentialId: aKey.id });
    });

    it('Das Bestätigen einer Passkey-Sicherung ist ein Sicherheitsereignis für die Person (ohne Inhalt)', async () => {
      const { a, aKey } = await start();
      await a.post('/api/v1/me/keys', keys());
      const p = await put(a, aKey.id);
      await a.post('/api/v1/me/key-backup-prf/verified', { id: p.json.id });
      const ev = (await a.get('/api/v1/me/security-events')).json.events as Array<{ kind: string }>;
      expect(ev.map((e) => e.kind)).toContain('key_backup_prf_set');
    });
  });
});
