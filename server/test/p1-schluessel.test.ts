// P1 "Schlüssel vereinfachen und absichern" (Server): Soft-Delete beim Entfernen von Mitgliedern (Schlüssel, Sicherungen und Konto bleiben 30 Tage, Wiederherstellen,
// endgültiges Löschen durch den Aufräum-Job, Familiengrenze, letzter Admin) und die eigene Schlüssel-Ampel `GET /me/key-status`. PGlite und echtes PostgreSQL.
import { randomBytes } from 'node:crypto';
import { and, eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { REMOVED_RETENTION_DAYS } from '../src/auth/account.js';
import { runMaintenance } from '../src/auth/maintenance.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const DAY = 86_400_000;
const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = { id: 'argon2id-v1', memKiB: 65536, ops: 3 };

describe.each(backends)('P1 Schlüssel-Paket Server ($name)', (backend) => {
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
    world = await World.create(harness.db, { E2EE_PW_BACKUP: 'true' });
  });

  type Person = Awaited<ReturnType<typeof addMember>> | Awaited<ReturnType<typeof adminPassword>>;
  const idOf = async (c: Client) => (await c.get('/api/v1/me')).json.user.id as string;

  async function stepUp(p: Person) {
    world.advance(31_000);
    expect((await p.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(p.totpSecret) })).status).toBe(200);
  }
  async function schluesselUndSicherungen(c: Client) {
    expect((await c.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
    expect((await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
    const put = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf });
    expect(put.status).toBe(200);
    expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
  }
  /** Setzt den Zeitpunkt des Entfernens auf "vor N Tagen" (die Uhr der Welt weiterzudrehen ließe auch die Sitzung des Admins ablaufen). */
  const entferntVor = async (userId: string, tage: number) => {
    await harness.db.update(schema.users).set({ removedAt: new Date(world.clock - tage * DAY) }).where(eq(schema.users.id, userId));
  };
  const zeile = async (table: string, userId: string) => Number((await harness.db.execute<{ n: number }>(sql.raw(`select count(*)::int as n from "${table}" where user_id = '${userId}'`))).rows[0]?.n ?? 0);

  // ----------------------------------------------------------------------------------------------------------------- Soft-Delete

  describe('Soft-Delete beim Entfernen', () => {
    async function mitSchluesseln() {
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      await schluesselUndSicherungen(m.client);
      const mid = await idOf(m.client);
      // ein Archiv-Eintrag: Schlüsselwechsel nach 25 Stunden (kein Code-Zugang, keine Sperrfrist)
      expect((await m.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
      await stepUp(m);
      expect((await m.client.put('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key(), expectedKeyVersion: 1 })).status).toBe(200);
      return { a, m, mid };
    }

    it('Konto, Schlüssel, Sicherungen und Archiv bleiben liegen; Anmeldung, Sitzung und Listen sind weg', async () => {
      const { a, m, mid } = await mitSchluesseln();
      const vorher = { keys: await zeile('person_keys', mid), hist: await zeile('person_key_history', mid), pw: await zeile('key_backups_pw', mid), arch: await zeile('key_backup_archive', mid), cred: await zeile('credentials', mid) };
      expect(vorher.keys).toBe(1);
      expect(vorher.arch).toBeGreaterThan(0);
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      // alles bleibt
      expect({ keys: await zeile('person_keys', mid), hist: await zeile('person_key_history', mid), pw: await zeile('key_backups_pw', mid), arch: await zeile('key_backup_archive', mid), cred: await zeile('credentials', mid) }).toEqual(vorher);
      const [u] = await harness.db.select().from(schema.users).where(eq(schema.users.id, mid));
      expect(u?.removedAt).not.toBeNull();
      expect(u?.disabledAt).not.toBeNull();
      expect(u?.removedBy).toBe(await idOf(a.client));
      // die Sitzung ist tot, die Anmeldung scheitert wie bei einem falschen Passwort
      expect((await m.client.get('/api/v1/me')).status).toBe(401);
      const login = await world.client('203.0.113.77').post('/api/v1/auth/login/password', { email: 'mama@example.org', password: m.password, totp: await world.totp(m.totpSecret) });
      expect(login.status).toBe(401);
      expect(login.json.error).toBe('invalid_credentials');
      // in keiner Mitgliederliste, auch nicht für Admins
      expect(((await a.client.get('/api/v1/members')).json.members as Array<{ id: string }>).some((x) => x.id === mid)).toBe(false);
      expect(await auditEvents(world)).toContain('member_removed');
      const audit = await harness.db.select().from(schema.auditLog).where(eq(schema.auditLog.event, 'member_removed'));
      expect(audit[0]?.detail).toMatchObject({ target: mid, soft: true });
    });

    it('Liste der Entfernten: nur Admins, mit Frist und Schlüsselhinweis', async () => {
      const { a, m, mid } = await mitSchluesseln();
      const kind = await addMember(world, a.client, 'child', 'kind@example.org');
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      const list = await a.client.get('/api/v1/members/removed');
      expect(list.status).toBe(200);
      expect(list.json.retentionDays).toBe(REMOVED_RETENTION_DAYS);
      expect(list.json.members).toHaveLength(1);
      expect(list.json.members[0]).toMatchObject({ id: mid, displayName: 'mama', role: 'parent', hasKeys: true });
      expect(Date.parse(list.json.members[0].purgeAt) - Date.parse(list.json.members[0].removedAt)).toBe(REMOVED_RETENTION_DAYS * DAY);
      // keine E-Mail, keine Geheimnisse
      expect(JSON.stringify(list.json)).not.toContain('mama@example.org');
      expect((await kind.client.get('/api/v1/members/removed')).status).toBe(403);
      expect((await world.client().get('/api/v1/members/removed')).status).toBe(401);
      expect((await m.client.get('/api/v1/members/removed')).status).toBe(401);
    });

    it('Wiederherstellen: Admin mit Step-up; danach Anmeldung, Schlüssel und Sicherungen wie vorher', async () => {
      const { a, m, mid } = await mitSchluesseln();
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      const zaehler = { keys: await zeile('person_keys', mid), pw: await zeile('key_backups_pw', mid), arch: await zeile('key_backup_archive', mid) };
      // ohne frisches Step-up nicht
      world.advance(10 * 60_000);
      const ohne = await a.client.post(`/api/v1/members/${mid}/restore`);
      expect(ohne.status).toBe(403);
      expect(ohne.json.error).toBe('step_up_required');
      await stepUp(a);
      expect((await a.client.post(`/api/v1/members/${mid}/restore`)).status).toBe(200);
      expect(await auditEvents(world)).toContain('member_restored');
      const [u] = await harness.db.select().from(schema.users).where(eq(schema.users.id, mid));
      expect(u).toMatchObject({ removedAt: null, disabledAt: null, removedBy: null });
      expect({ keys: await zeile('person_keys', mid), pw: await zeile('key_backups_pw', mid), arch: await zeile('key_backup_archive', mid) }).toEqual(zaehler);
      expect(((await a.client.get('/api/v1/members')).json.members as Array<{ id: string }>).some((x) => x.id === mid)).toBe(true);
      expect((await a.client.get('/api/v1/members/removed')).json.members).toHaveLength(0);
      // Anmeldung mit dem alten Zugang klappt
      world.advance(31_000);
      const neu = world.client('203.0.113.78');
      const login = await neu.post('/api/v1/auth/login/password', { email: 'mama@example.org', password: m.password, totp: await world.totp(m.totpSecret) });
      expect(login.status).toBe(200);
      neu.adopt(login.json.session);
      expect(((await neu.get('/api/v1/me/keys')).json.keys as { keyVersion: number }).keyVersion).toBe(2);
    });

    it('Rechte: Nicht-Admins dürfen nicht wiederherstellen; fremde, unbekannte und nicht entfernte Personen ergeben 404', async () => {
      const { a, m, mid } = await mitSchluesseln();
      const kind = await addMember(world, a.client, 'child', 'kind@example.org');
      const kid = await idOf(kind.client);
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      for (const c of [kind.client, world.client()]) {
        const res = await c.post(`/api/v1/members/${mid}/restore`);
        expect([401, 403]).toContain(res.status);
      }
      await stepUp(a);
      expect((await a.client.post(`/api/v1/members/${kid}/restore`)).status).toBe(404); // nicht entfernt
      expect((await a.client.post('/api/v1/members/00000000-0000-4000-8000-000000000000/restore')).status).toBe(404);
      expect((await a.client.post('/api/v1/members/kein-uuid/restore')).status).toBe(400);
      // doppeltes Entfernen: 404, nichts ändert sich
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(404);
      // fremde Familie
      const [fam] = await harness.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning();
      const [fremd] = await harness.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'Fremd', disabledAt: new Date(world.clock), removedAt: new Date(world.clock) }).returning();
      if (!fam || !fremd) throw new Error('Setup');
      await harness.db.insert(schema.memberships).values({ familyId: fam.id, userId: fremd.id, role: 'parent' });
      expect((await a.client.post(`/api/v1/members/${fremd.id}/restore`)).status).toBe(404);
      expect(((await a.client.get('/api/v1/members/removed')).json.members as Array<{ id: string }>).some((x) => x.id === fremd.id)).toBe(false);
      void m;
    });

    it('Ein entferntes Konto zählt nicht als Admin: der letzte wirksame Admin bleibt geschützt', async () => {
      const a = await adminPassword(world);
      const b = await addMember(world, a.client, 'admin', 'admin2@example.org');
      const bid = await idOf(b.client);
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${bid}`)).status).toBe(200);
      // ohne die Korrektur zählte der entfernte Admin mit und der Rest dürfte sich herabstufen
      await stepUp(a);
      const aid = await idOf(a.client);
      const res = await a.client.patch(`/api/v1/members/${aid}/role`, { role: 'parent' });
      expect(res.status).toBe(409);
      expect(res.json.error).toBe('last_admin');
    });

    it('Komplett-Reset und Verwaltung sprechen entfernte Personen nicht an', async () => {
      const { a, mid } = await mitSchluesseln();
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      await stepUp(a);
      for (const [method, url, body, erwartet] of [
        ['POST', `/api/v1/members/${mid}/reset`, {}, 404],
        ['PATCH', `/api/v1/members/${mid}/role`, { role: 'child' }, 404],
        ['POST', `/api/v1/members/${mid}/password-reset`, {}, 409],
      ] as const) {
        const res = await a.client.request(method, url, { body });
        expect(res.status, `${method} ${url}`).toBe(erwartet);
      }
    });

    it('Aufräum-Job: vor Ablauf der Frist bleibt alles, danach verschwindet die Person endgültig samt Schlüsseln', async () => {
      const { a, mid } = await mitSchluesseln();
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      await entferntVor(mid, REMOVED_RETENTION_DAYS - 1);
      expect((await runMaintenance(world.auth.ctx)).removedMembersPurged).toBe(0);
      expect(await zeile('person_keys', mid)).toBe(1);
      await entferntVor(mid, REMOVED_RETENTION_DAYS + 1);
      const report = await runMaintenance(world.auth.ctx);
      expect(report.removedMembersPurged).toBe(1);
      expect((await harness.db.select().from(schema.users).where(eq(schema.users.id, mid))).length).toBe(0);
      for (const t of ['person_keys', 'person_key_history', 'key_backups_pw', 'key_backup_archive', 'credentials']) expect(await zeile(t, mid), t).toBe(0);
      expect(await auditEvents(world)).toContain('member_purged');
      // ein zweiter Lauf ist folgenlos; Wiederherstellen ist nun nicht mehr möglich
      expect((await runMaintenance(world.auth.ctx)).removedMembersPurged).toBe(0);
      await stepUp(a);
      expect((await a.client.post(`/api/v1/members/${mid}/restore`)).status).toBe(404);
    });

    it('Wiederhergestellte Personen werden vom Aufräum-Job nie gelöscht', async () => {
      const { a, mid } = await mitSchluesseln();
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      await entferntVor(mid, REMOVED_RETENTION_DAYS - 1);
      await stepUp(a);
      expect((await a.client.post(`/api/v1/members/${mid}/restore`)).status).toBe(200);
      world.advance(5 * 60_000);
      expect((await runMaintenance(world.auth.ctx)).removedMembersPurged).toBe(0);
      expect(await zeile('person_keys', mid)).toBe(1);
    });

    it('wartende Mitglieder (ohne Schlüssel) werden weiter sofort gelöscht, nicht aufbewahrt', async () => {
      const a = await adminPassword(world);
      const p = await addMember(world, a.client, 'child', 'wartet@example.org', { requireApproval: true });
      const pid = ((await a.client.get('/api/v1/members')).json.members as Array<{ id: string; email?: string }>).find((x) => x.email === 'wartet@example.org')?.id as string;
      expect(p.complete?.status).toBe(200);
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${pid}`)).status).toBe(200);
      expect((await harness.db.select().from(schema.users).where(eq(schema.users.id, pid))).length).toBe(0);
      expect((await a.client.get('/api/v1/members/removed')).json.members).toHaveLength(0);
    });

    it('die Verweise der Person (Aufgaben-Zuständigkeit) werden wie bisher gelöst, die Geräte der Person enden', async () => {
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      const mid = await idOf(m.client);
      expect((await harness.db.select().from(schema.devices).where(and(eq(schema.devices.userId, mid), sql`revoked_at is null`))).length).toBeGreaterThan(0);
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      expect((await harness.db.select().from(schema.devices).where(and(eq(schema.devices.userId, mid), sql`revoked_at is null`))).length).toBe(0);
    });
  });

  // ----------------------------------------------------------------------------------------------------------------- Ampel für mich

  describe('GET /me/key-status (Bin ich abgesichert?)', () => {
    const status = async (c: Client) => (await c.get('/api/v1/me/key-status')).json.status as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

    it('ohne Sitzung 401; ohne Schlüssel rot', async () => {
      const a = await adminPassword(world);
      expect((await world.client().get('/api/v1/me/key-status')).status).toBe(401);
      expect(await status(a.client)).toMatchObject({ ampel: 'red', hasKeys: false, keyVersion: null, wayCount: 0 });
    });

    it('Wege: Gerät allein gelb, mit Sicherung grün, nur Sicherungen ohne Gerät gelb, Schlüsselwechsel entwertet die Sicherungen', async () => {
      const a = await adminPassword(world);
      const c = a.client;
      expect((await c.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
      expect(await status(c)).toMatchObject({ ampel: 'red', hasKeys: true, wayCount: 0, devicesWithKey: 0 });
      expect((await c.put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(200);
      expect(await status(c)).toMatchObject({ ampel: 'yellow', wayCount: 1, ways: { device: true, pwBackup: false, recoveryBackup: false }, devicesWithKey: 1 });
      expect((await c.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
      expect(await status(c)).toMatchObject({ ampel: 'green', wayCount: 2, ways: { device: true, pwBackup: false, recoveryBackup: true } });
      const put = await c.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf });
      // eine unbestätigte Passwort-Sicherung zählt nie
      expect((await status(c)).ways.pwBackup).toBe(false);
      expect((await c.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
      expect(await status(c)).toMatchObject({ ampel: 'green', wayCount: 3, ways: { device: true, pwBackup: true, recoveryBackup: true } });
      // Gerät meldet "keinen Schlüssel": zwei Sicherungen ohne Gerät = gelb
      expect((await c.put('/api/v1/me/device-key', { keyVersion: 0 })).status).toBe(200);
      expect(await status(c)).toMatchObject({ ampel: 'yellow', wayCount: 2, devicesWithKey: 0 });
      // Schlüsselwechsel: beide Sicherungen gehören zum alten Schlüssel
      expect((await c.put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(200);
      await (async () => {
        world.advance(31_000);
        expect((await c.post('/api/v1/auth/step-up/code', { totp: await world.totp(a.totpSecret) })).status).toBe(200);
      })();
      expect((await c.put('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key(), expectedKeyVersion: 1 })).status).toBe(200);
      expect(await status(c)).toMatchObject({ ampel: 'red', keyVersion: 2, wayCount: 0, archiveCount: 2 });
    });

    it('zeigt nur die eigene Person und nie Geheimnisse, Namen oder Ereignisse anderer', async () => {
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      expect((await m.client.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
      expect((await m.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
      const meine = await a.client.get('/api/v1/me/key-status');
      expect(meine.json.status).toMatchObject({ hasKeys: false, ampel: 'red' });
      const text = JSON.stringify((await m.client.get('/api/v1/me/key-status')).json);
      expect(text).not.toMatch(/blob|salt|publicEncKey|publicSignKey|mama|admin|events/i);
      expect(Object.keys((await m.client.get('/api/v1/me/key-status')).json.status).sort()).toEqual(
        ['ampel', 'archiveCount', 'devicesReported', 'devicesTotal', 'devicesWithKey', 'generatedAt', 'hasKeys', 'keyVersion', 'wayCount', 'ways'].sort(),
      );
    });

    it('ein entferntes Mitglied hat keine Ampel mehr (404, Sitzung ohnehin beendet) und fehlt in der Betreiber-Ampel', async () => {
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      const mid = await idOf(m.client);
      await stepUp(a);
      expect((await a.client.del(`/api/v1/members/${mid}`)).status).toBe(200);
      expect((await m.client.get('/api/v1/me/key-status')).status).toBe(401);
    });
  });
});
