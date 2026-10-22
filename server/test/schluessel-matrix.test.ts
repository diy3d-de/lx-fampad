// QM-Verlustmatrix (Server), Ergänzung zu kein-datenverlust.test.ts: Grenzfälle, die dort nicht einzeln festgenagelt sind.
//  1. Archiv-Ausdünnen: wie viele spätere Ersetzungen übersteht die zuletzt gültige echte Sicherung (dokumentierte Grenze, Abschnitt 9a)?
//  2. Rückweg aus dem Archiv nach einem Angriff mit geliehener Sitzung (Müll in beide Sicherungen, danach Schlüsselwechsel): die echten Blobs
//     sind byte-genau erreichbar, auch die Passwort-Sicherung samt Ableitungsdaten.
//  3. Sperrfrist 24 h auf die Sekunde: knapp davor gesperrt, genau nach 24 h frei; die Restdauer sinkt gleichmäßig.
// PGlite und echtes PostgreSQL.
import { randomBytes } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { addMember, adminPassword, backends, World, type Client, type Harness } from './helpers.js';
const H = 3_600_000;
const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = () => ({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });

describe.each(backends)('Verlustmatrix Schlüssel ($name)', (backend) => {
  let harness: Harness;
  let world: World;

  beforeAll(async () => {
    harness = await backend.open();
  }, 120_000);
  afterAll(async () => {
    await world?.close();
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
  });

  async function start() {
    world = await World.create(harness.db, { E2EE_PW_BACKUP: 'true' }, { pushMinIntervalMs: 0 });
    const a = await adminPassword(world);
    await addMember(world, a.client, 'parent', 'mama@example.org');
    return { a };
  }

  const rotate = (c: Client, expectedKeyVersion: number) => c.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion });
  const archiv = async (c: Client) => (await c.get('/api/v1/me/key-backups/archive')).json.entries as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  const archivBlobs = async () => (await harness.db.execute<{ blob: string }>(sql`select blob from key_backup_archive`)).rows.map((r) => r.blob);

  describe('Archiv-Ausdünnen: Grenze der zuletzt gültigen echten Sicherung', () => {
    it('6 echte Stände, dann 50 Ersetzungen: der letzte echte Stand ist noch im Archiv; mit der 51. ist er weg (dokumentierte Grenze), die ältesten 5 und der Eintrag `rotation` nie', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      // zwei Wechsel vorab: ein `rotation`-Eintrag (Stand 1) muss alles Folgende überleben
      const stand1 = blob();
      await c.put('/api/v1/me/key-backup', { blob: stand1, keyVersion: 1 });
      expect((await rotate(c, 1)).status).toBe(200);
      // Stand 2: sechs echte Wiederherstellungsschlüssel nacheinander (jeder neue ersetzt den vorigen), der sechste ist der, den die Familie aufbewahrt
      const echte = Array.from({ length: 6 }, () => blob());
      for (const e of echte) {
        world.advance(1000);
        expect((await c.put('/api/v1/me/key-backup', { blob: e, keyVersion: 2 })).status).toBe(200);
      }
      const letzteEchte = echte[5] as string;
      const muellEinspielen = async (n: number) => {
        for (let i = 0; i < n; i++) {
          world.advance(1000);
          expect((await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 2 })).status).toBe(200);
        }
      };
      // 50 spätere Ersetzungen (z. B. mit geliehener Sitzung): die letzte echte Sicherung liegt noch im Archiv
      await muellEinspielen(50);
      expect(await archivBlobs()).toContain(letzteEchte);
      // die 51. verdrängt sie (Regel: je Stand die ältesten 5 und insgesamt die neuesten 50)
      await muellEinspielen(1);
      const blobs = await archivBlobs();
      expect(blobs).not.toContain(letzteEchte);
      // aber: die ältesten 5 echten Stände bleiben, und der Stand vor dem Wechsel (`rotation`) wird nie ausgedünnt
      for (const e of echte.slice(0, 5)) expect(blobs).toContain(e);
      expect(blobs).toContain(stand1);
      const liste = await archiv(c);
      expect(liste.filter((e) => e.reason === 'rotation')).toHaveLength(1);
      expect(liste.filter((e) => e.reason === 'replaced').length).toBeLessThanOrEqual(50);
    });
  });

  describe('Rückweg aus dem Archiv nach einem Angriff mit geliehener Sitzung', () => {
    it('Müll in Wiederherstellungs- und Passwort-Sicherung, danach Schlüsselwechsel: die echten Blobs sind byte-genau abrufbar, Passwort-Sicherung mit Ableitungsdaten', async () => {
      const f = await start();
      const c = f.a.client;
      await c.post('/api/v1/me/keys', keys());
      const echteRec = blob();
      const echtesPw = blob();
      expect((await c.put('/api/v1/me/key-backup', { blob: echteRec, keyVersion: 1 })).status).toBe(200);
      const pw = await c.put('/api/v1/me/key-backup-pw', { blob: echtesPw, keyVersion: 1, kdf: kdf() });
      expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: pw.json.id })).status).toBe(200);
      // Angreifer: beide Sicherungen durch Müll ersetzen (das normale Anlegen ist nie gesperrt)
      expect((await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
      const muellPw = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf: kdf() });
      expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: muellPw.json.id })).status).toBe(200);
      // die Person wechselt später den Schlüssel (nach Wiederherstellung des Zugangs): auch der Müll wandert ins Archiv, nichts wird gelöscht
      expect((await rotate(c, 1)).status).toBe(200);
      const liste = await archiv(c);
      const rec = liste.find((e) => e.kind === 'recovery' && e.reason === 'replaced');
      const pwEintrag = liste.find((e) => e.kind === 'password' && e.id === pw.json.id);
      expect(rec, 'ersetzte Wiederherstellungssicherung fehlt im Archiv').toBeTruthy();
      expect(pwEintrag, 'ersetzte Passwort-Sicherung fehlt im Archiv').toBeTruthy();
      const recDetail = await c.get(`/api/v1/me/key-backups/archive/${rec?.id}`);
      expect(recDetail.status).toBe(200);
      expect(recDetail.json.blob).toBe(echteRec);
      const pwDetail = await c.get(`/api/v1/me/key-backups/archive/${pw.json.id}`);
      expect(pwDetail.status).toBe(200);
      expect(pwDetail.json.blob).toBe(echtesPw);
      expect(pwDetail.json.kdf).toMatchObject({ id: 'argon2id-v1', memKiB: 65536, ops: 3 });
      expect(typeof pwDetail.json.kdf.salt).toBe('string');
      // der aktuelle Zugang (Version 2) ist leer: die Altstände überschreiben ihn nie
      expect((await c.get('/api/v1/me/keys')).json).toMatchObject({ keys: { keyVersion: 2 }, hasBackup: false, recoveryBackupAt: null, pwBackupVerifiedAt: null });
    });
  });

  describe('Sperrfrist 24 h auf die Sekunde', () => {
    it('Restdauer sinkt gleichmäßig und erreicht nie 0, solange gesperrt; ab genau 24 h kein `destructive_locked` mehr; nichts wird vorher angefasst', async () => {
      const f = await start();
      await f.a.client.post('/api/v1/me/keys', keys());
      const c = world.client('203.0.113.151');
      const r = await c.post('/api/v1/auth/login/recovery', { email: 'admin@example.org', code: f.a.recoveryCodes[0] as string, client: 'web' });
      expect(r.status).toBe(200);
      c.adopt(r.json.session);
      const rest = async () => {
        const x = await rotate(c, 1);
        expect(x.status).toBe(403);
        // vor Ablauf kommt die Sperre vor der Step-up-Prüfung (sonst würde ein Angreifer ohne Step-up den Stand nicht erfahren)
        expect(x.json.error).toBe('destructive_locked');
        return x.json.retryAfterSec as number;
      };
      const r0 = await rest();
      expect(r0).toBe(24 * 3600);
      world.advance(12 * H);
      expect(await rest()).toBe(12 * 3600);
      world.advance(12 * H - 1000);
      expect(await rest()).toBe(1);
      world.advance(1000); // genau 24 h
      const frei = await rotate(c, 1);
      expect(frei.json.error).not.toBe('destructive_locked');
      // nichts ist während der Sperre passiert
      expect(await world.count('key_backup_archive')).toBe(0);
      expect((await f.a.client.get('/api/v1/me/keys')).json.keys.keyVersion).toBe(1);
    });
  });
});
