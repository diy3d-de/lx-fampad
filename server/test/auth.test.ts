// Tests der Anmeldung (Phase 1a). Jeder Test läuft gegen PGlite und, mit TEST_DATABASE_URL, gegen echtes PostgreSQL.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { bootstrapFamily } from '../src/auth/bootstrap.js';
import { sha256Hex } from '../src/auth/crypto.js';
import * as schema from '../src/db/schema.js';
import { backends, Client, ORIGIN, World, type Harness } from './helpers.js';

const DAY = 86_400_000;
const HOUR = 3_600_000;

describe.each(backends)('Anmeldung ($name)', (backend) => {
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

  /** Erstinstallation + Admin per Passwort; gibt den angemeldeten Admin-Client zurück. */
  async function adminPassword(email = 'admin@example.org') {
    const boot = await world.bootstrap();
    const reg = await world.registerPassword(boot.token, { email, displayName: 'Admin' });
    expect(reg.complete?.status).toBe(200);
    return { ...reg, boot };
  }

  /** Einladung erzeugen (als `by`) und per Passwort einlösen; gibt den neuen Client zurück. */
  async function addMember(by: Client, role: 'admin' | 'parent' | 'child' | 'guest', email: string, extra: Record<string, unknown> = {}) {
    const inv = await by.post('/api/v1/invites', { role, ...extra });
    expect(inv.status, JSON.stringify(inv.json)).toBe(200);
    const reg = await world.registerPassword(inv.json.invite.token, { email, displayName: email.split('@')[0] });
    return { ...reg, invite: inv.json.invite };
  }

  const auditEvents = async () => (await harness.db.select().from(schema.auditLog)).map((a) => a.event);

  describe('Erstinstallation (Bootstrap)', () => {
    it('legt Familie und Einladung an; nur der Hash steht in der Datenbank', async () => {
      const boot = await world.bootstrap();
      expect(boot.link).toBe(`${ORIGIN}/#/einladung/${boot.token}`);
      expect(boot.token.length).toBeGreaterThanOrEqual(43); // 256 Bit base64url
      const [row] = await harness.db.select().from(schema.invites);
      expect(row?.tokenHash).toBe(sha256Hex(boot.token));
      expect(JSON.stringify(row)).not.toContain(boot.token);
      expect(row?.role).toBe('admin');
      expect((row?.expiresAt.getTime() ?? 0) - world.clock).toBe(7 * DAY);
      expect(await world.count('families')).toBe(1);
      expect(await auditEvents()).toContain('bootstrap_created');
    });

    it('nach der Einrichtung des Admins ist ein zweiter Bootstrap nicht möglich (genau eine Familie)', async () => {
      await adminPassword();
      await expect(bootstrapFamily(world.auth.ctx, { familyName: 'Zweite' })).rejects.toMatchObject({ code: 'already_bootstrapped' });
      expect(await world.count('families')).toBe(1);
    });

    it('vor dem Einlösen ersetzt ein erneuter Aufruf die Einladung; die alte wird ungültig', async () => {
      const first = await world.bootstrap();
      const second = await world.bootstrap();
      expect(await world.count('families')).toBe(1);
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: first.token })).status).toBe(400);
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: second.token })).status).toBe(200);
    });

    it('gleichzeitige Bootstrap-Aufrufe erzeugen nur eine Familie', async () => {
      const results = await Promise.allSettled([bootstrapFamily(world.auth.ctx, { familyName: 'A' }), bootstrapFamily(world.auth.ctx, { familyName: 'B' })]);
      expect(await world.count('families')).toBe(1);
      expect(results.filter((r) => r.status === 'fulfilled').length).toBeGreaterThanOrEqual(1);
    });

    it('es gibt keine offene Registrierung', async () => {
      const c = world.client();
      for (const url of ['/api/v1/auth/register', '/api/v1/auth/signup']) expect((await c.post(url, { email: 'x@example.org' })).status).toBe(404);
      const res = await c.post('/api/v1/auth/invites/password/start', { token: 'x'.repeat(43), email: 'x@example.org', displayName: 'X', password: 'ein-sehr-langes-passwort-123' });
      expect(res.status).toBe(400);
      expect(await world.count('users')).toBe(0);
    });
  });

  describe('Einladungen', () => {
    it('Admin lädt jede Rolle ein; Eltern nur Kinder und Gäste; Kinder und Gäste gar nicht', async () => {
      const { client: admin } = await adminPassword();
      expect((await admin.post('/api/v1/invites', { role: 'admin' })).status).toBe(200);
      expect((await admin.post('/api/v1/invites', { role: 'parent' })).status).toBe(200);
      const parent = await addMember(admin, 'parent', 'mama@example.org');
      expect((await parent.client.post('/api/v1/invites', { role: 'child' })).status).toBe(200);
      expect((await parent.client.post('/api/v1/invites', { role: 'guest' })).status).toBe(200);
      expect((await parent.client.post('/api/v1/invites', { role: 'admin' })).status).toBe(403);
      expect((await parent.client.post('/api/v1/invites', { role: 'parent' })).status).toBe(403);
      const child = await addMember(admin, 'child', 'kind@example.org');
      expect((await child.client.post('/api/v1/invites', { role: 'guest' })).status).toBe(403);
      expect((await child.client.get('/api/v1/invites')).status).toBe(403);
    });

    it('ist ohne Anmeldung nicht möglich', async () => {
      expect((await world.client().post('/api/v1/invites', { role: 'guest' })).status).toBe(401);
    });

    it('Standard 24 Stunden, höchstens 7 Tage; Token ≥128 Bit, nur der Hash gespeichert', async () => {
      const { client: admin } = await adminPassword();
      const a = await admin.post('/api/v1/invites', { role: 'child' });
      expect(new Date(a.json.invite.expiresAt).getTime() - world.clock).toBe(24 * HOUR);
      const b = await admin.post('/api/v1/invites', { role: 'child', hours: 168 });
      expect(new Date(b.json.invite.expiresAt).getTime() - world.clock).toBe(7 * DAY);
      expect((await admin.post('/api/v1/invites', { role: 'child', hours: 169 })).status).toBe(400);
      expect((await admin.post('/api/v1/invites', { role: 'child', hours: 0 })).status).toBe(400);
      expect(Buffer.from(a.json.invite.token, 'base64url').length).toBeGreaterThanOrEqual(16);
      const rows = await harness.db.select().from(schema.invites).where(eq(schema.invites.id, a.json.invite.id));
      expect(rows[0]?.tokenHash).toBe(sha256Hex(a.json.invite.token));
      expect(a.json.invite.link).toBe(`${ORIGIN}/#/einladung/${a.json.invite.token}`);
    });

    it('ist einmalig: die zweite Einlösung scheitert, auch gleichzeitig', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child' });
      const first = await world.registerPassword(inv.json.invite.token, { email: 'a@example.org' });
      expect(first.complete?.status).toBe(200);
      const second = await world.registerPassword(inv.json.invite.token, { email: 'b@example.org' });
      expect(second.start.status).toBe(400);
      expect(second.start.json.error).toBe('invite_invalid');

      // parallel: beide starten, beide schließen ab -> genau eines gewinnt
      const inv2 = await admin.post('/api/v1/invites', { role: 'child' });
      const c1 = world.client('203.0.113.21');
      const c2 = world.client('203.0.113.22');
      const mk = async (c: Client, email: string) => {
        const s = await c.post('/api/v1/auth/invites/password/start', { token: inv2.json.invite.token, email, displayName: 'P', password: 'ein-sehr-langes-passwort-123' });
        return { c, s };
      };
      const [p1, p2] = await Promise.all([mk(c1, 'p1@example.org'), mk(c2, 'p2@example.org')]);
      const done = await Promise.all(
        [p1, p2].map(async ({ c, s }) => c.post('/api/v1/auth/invites/password/complete', { challengeId: s.json.challengeId, code: await world.totp(s.json.totpSecret) })),
      );
      expect(done.filter((d) => d.status === 200)).toHaveLength(1);
      expect(await world.count('users')).toBe(1 + 1 + 1); // Admin, erstes Mitglied, ein Gewinner
    });

    it('läuft nach der Gültigkeit ab (auch beim Abschluss)', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child' });
      // Einrichtung begonnen, dann läuft die Einladung ab
      const c = world.client('203.0.113.30');
      const start = await c.post('/api/v1/auth/invites/password/start', { token: inv.json.invite.token, email: 'k@example.org', displayName: 'K', password: 'ein-sehr-langes-passwort-123' });
      expect(start.status).toBe(200);
      world.advance(25 * HOUR);
      const done = await c.post('/api/v1/auth/invites/password/complete', { challengeId: start.json.challengeId, code: await world.totp(start.json.totpSecret) });
      expect(done.status).toBe(400);
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: inv.json.invite.token })).json.error).toBe('invite_invalid');
      expect(await world.count('users')).toBe(1);
    });

    it('lookup zeigt Rolle und PIN-Pflicht, ohne Token oder PIN zu verraten; das Token gehört nie in die URL', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'parent', pin: true });
      const look = await world.client().post('/api/v1/auth/invites/lookup', { token: inv.json.invite.token });
      expect(look.status).toBe(200);
      expect(look.json.invite).toMatchObject({ role: 'parent', pinRequired: true, familyName: 'Familie Test', reset: false });
      expect(JSON.stringify(look.json)).not.toContain(inv.json.invite.token);
      // Token als Pfad oder Query wird nicht angenommen
      expect((await world.client().get(`/api/v1/auth/invites/${inv.json.invite.token}`)).status).toBe(404);
      expect((await world.client().get(`/api/v1/auth/invites/lookup?token=${inv.json.invite.token}`)).status).toBe(404);
    });

    it('Admin sieht die Liste ohne Token und PIN; Eltern sehen nur eigene Einladungen', async () => {
      const { client: admin } = await adminPassword();
      const created = await admin.post('/api/v1/invites', { role: 'guest', pin: true });
      const parent = await addMember(admin, 'parent', 'mama@example.org');
      await parent.client.post('/api/v1/invites', { role: 'child' });
      const list = await admin.get('/api/v1/invites');
      const text = JSON.stringify(list.json);
      expect(text).not.toContain(created.json.invite.token);
      expect(text).not.toContain(created.json.invite.pin);
      expect(text).not.toContain('tokenHash');
      expect(text).not.toContain('pinHash');
      expect(list.json.invites.length).toBeGreaterThanOrEqual(3);
      expect(list.json.invites.find((i: { id: string }) => i.id === created.json.invite.id)).toMatchObject({ role: 'guest', status: 'open', hasPin: true, requireApproval: true });
      const mine = await parent.client.get('/api/v1/invites');
      expect(mine.json.invites).toHaveLength(1);
      expect(mine.json.invites[0].role).toBe('child');
    });

    it('Widerruf: die Einladung ist danach ungültig, ein zweiter Widerruf meldet Konflikt', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child' });
      expect((await admin.post(`/api/v1/invites/${inv.json.invite.id}/revoke`)).status).toBe(200);
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: inv.json.invite.token })).status).toBe(400);
      expect((await admin.post(`/api/v1/invites/${inv.json.invite.id}/revoke`)).status).toBe(409);
      const list = await admin.get('/api/v1/invites');
      expect(list.json.invites.find((i: { id: string }) => i.id === inv.json.invite.id).status).toBe('revoked');
    });

    it('Verlängern: auch eine abgelaufene Einladung wird wieder nutzbar; höchstens 7 Tage', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child' });
      world.advance(30 * HOUR);
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: inv.json.invite.token })).status).toBe(400);
      const ext = await admin.post(`/api/v1/invites/${inv.json.invite.id}/extend`, { hours: 48 });
      expect(ext.status).toBe(200);
      expect(new Date(ext.json.expiresAt).getTime() - world.clock).toBe(48 * HOUR);
      expect((await world.client().post('/api/v1/auth/invites/lookup', { token: inv.json.invite.token })).status).toBe(200);
      expect((await admin.post(`/api/v1/invites/${inv.json.invite.id}/extend`, { hours: 169 })).status).toBe(400);
    });

    it('eine fremde Einladung kann ein Elternteil weder widerrufen noch verlängern', async () => {
      const { client: admin } = await adminPassword();
      const parent = await addMember(admin, 'parent', 'mama@example.org');
      const inv = await admin.post('/api/v1/invites', { role: 'child' });
      expect((await parent.client.post(`/api/v1/invites/${inv.json.invite.id}/revoke`)).status).toBe(404);
      expect((await parent.client.post(`/api/v1/invites/${inv.json.invite.id}/extend`, { hours: 5 })).status).toBe(404);
    });

    it('PIN: richtig angenommen, falsch abgelehnt, nach 5 Fehlversuchen ist die Einladung gesperrt (auch mit richtiger PIN)', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child', pin: true });
      expect(inv.json.invite.pin).toMatch(/^\d{6}$/);
      const row = (await harness.db.select().from(schema.invites).where(eq(schema.invites.id, inv.json.invite.id)))[0];
      expect(row?.pinHash).toBeTruthy();
      expect(JSON.stringify(row)).not.toContain(inv.json.invite.pin);

      const start = (pin?: string, ip = '203.0.113.40') =>
        world.client(ip).post('/api/v1/auth/invites/password/start', { token: inv.json.invite.token, email: 'k@example.org', displayName: 'K', password: 'ein-sehr-langes-passwort-123', ...(pin ? { pin } : {}) });
      const wrong = inv.json.invite.pin === '000000' ? '111111' : '000000';
      expect((await start()).status).toBe(400); // ohne PIN
      for (let i = 0; i < 5; i++) {
        const r = await start(wrong, `203.0.113.${50 + i}`);
        expect(r.status).toBe(400);
        expect(r.json.error).toBe('invite_invalid');
      }
      const after = await start(inv.json.invite.pin, '203.0.113.60');
      expect(after.status).toBe(400);
      const list = await admin.get('/api/v1/invites');
      expect(list.json.invites.find((i: { id: string }) => i.id === inv.json.invite.id).status).toBe('locked');
      const events = await auditEvents();
      expect(events.filter((e) => e === 'invite_pin_failed')).toHaveLength(5);
      expect(events).toContain('invite_locked');
    });

    it('PIN: parallele Versuche umgehen die Grenze nicht', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child', pin: true });
      const guesses = Array.from({ length: 12 }, (_, i) => String(100000 + i));
      const results = await Promise.all(
        guesses.map((pin, i) => world.client(`198.51.100.${i + 1}`).post('/api/v1/auth/invites/password/start', { token: inv.json.invite.token, email: 'k@example.org', displayName: 'K', password: 'ein-sehr-langes-passwort-123', pin })),
      );
      expect(results.every((r) => r.status === 400)).toBe(true);
      const [row] = await harness.db.select().from(schema.invites).where(eq(schema.invites.id, inv.json.invite.id));
      expect(row?.lockedAt).not.toBeNull();
      expect((await harness.db.select().from(schema.auditLog).where(eq(schema.auditLog.event, 'invite_pin_failed'))).length).toBeLessThanOrEqual(5);
    });

    it('PIN richtig: Registrierung klappt', async () => {
      const { client: admin } = await adminPassword();
      const inv = await admin.post('/api/v1/invites', { role: 'child', pin: true });
      const reg = await world.registerPassword(inv.json.invite.token, { email: 'k@example.org', pin: inv.json.invite.pin });
      expect(reg.complete?.status).toBe(200);
    });

    it('Freigabe: Gäste sind standardmäßig pending und können sich erst nach Freigabe anmelden', async () => {
      const { client: admin } = await adminPassword();
      const guest = await addMember(admin, 'guest', 'oma@example.org');
      expect(guest.complete?.json.status).toBe('pending');
      expect(guest.complete?.json.session).toBeUndefined();
      expect(guest.recoveryCodes).toHaveLength(10);

      const login = (c = world.client()) =>
        world.totp(guest.totpSecret).then((totp) => c.post('/api/v1/auth/login/password', { email: 'oma@example.org', password: guest.password, totp }));
      world.advance(31_000); // neuer TOTP-Zeitschritt (der Registrierungs-Code ist verbraucht)
      const denied = await login();
      expect(denied.status).toBe(403);
      expect(denied.json.error).toBe('account_pending');

      const members = await admin.get('/api/v1/members');
      const pending = members.json.members.find((m: { email: string }) => m.email === 'oma@example.org');
      expect(pending.status).toBe('pending');
      // Eltern/Gäste sehen wartende Mitglieder nicht; nur Admins können freigeben
      expect((await guest.client.post(`/api/v1/members/${pending.id}/approve`)).status).toBe(401);

      expect((await admin.post(`/api/v1/members/${pending.id}/approve`)).status).toBe(200);
      world.advance(31_000); // neuer TOTP-Zeitschritt
      const ok = await login(world.client('203.0.113.77'));
      expect(ok.status).toBe(200);
      expect(await auditEvents()).toContain('member_approved');
    });

    it('Freigabe ablehnen entfernt das Mitglied; require_approval lässt sich je Einladung setzen', async () => {
      const { client: admin } = await adminPassword();
      const g = await addMember(admin, 'guest', 'oma@example.org');
      const id = (await admin.get('/api/v1/members')).json.members.find((m: { email: string }) => m.email === 'oma@example.org').id;
      expect((await admin.post(`/api/v1/members/${id}/reject`)).status).toBe(200);
      expect((await harness.db.select().from(schema.users).where(eq(schema.users.email, 'oma@example.org'))).length).toBe(0);
      expect(g.recoveryCodes.length).toBe(10);
      // Kind mit Freigabe, Gast ohne Freigabe
      const kind = await addMember(admin, 'child', 'kind@example.org', { requireApproval: true });
      expect(kind.complete?.json.status).toBe('pending');
      const gast = await addMember(admin, 'guest', 'gast@example.org', { requireApproval: false });
      expect(gast.complete?.json.status).toBe('active');
      expect(await auditEvents()).toContain('member_rejected');
    });

    it('schreibt Audit-Einträge für erstellt/benutzt/widerrufen/abgelaufen', async () => {
      const { client: admin } = await adminPassword();
      const used = await admin.post('/api/v1/invites', { role: 'child' });
      await world.registerPassword(used.json.invite.token, { email: 'k@example.org' });
      const revoked = await admin.post('/api/v1/invites', { role: 'child' });
      await admin.post(`/api/v1/invites/${revoked.json.invite.id}/revoke`);
      await admin.post('/api/v1/invites', { role: 'child' });
      world.advance(25 * HOUR);
      const { runMaintenance } = await import('../src/auth/maintenance.js');
      const report = await runMaintenance(world.auth.ctx);
      expect(report.invitesExpired).toBe(1);
      const events = await auditEvents();
      for (const e of ['invite_created', 'invite_used', 'invite_revoked', 'invite_expired']) expect(events, e).toContain(e);
      // ein zweiter Lauf protokolliert den Ablauf nicht noch einmal
      expect((await runMaintenance(world.auth.ctx)).invitesExpired).toBe(0);
    });
  });
});
