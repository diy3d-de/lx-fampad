// Härtung Phase 1a: Logging ohne SQL-Parameter, ungültige Zeichen, Freigabe, IPv6, Challenge-Begrenzung, stündliches Aufräumen,
// Einladungsrechte, Mitglied entfernen, Routenprüfung (/%61pi), Sitzungswiderruf.
import { and, eq, isNull } from 'drizzle-orm';
import { Writable } from 'node:stream';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { runMaintenance, startMaintenance } from '../src/auth/maintenance.js';
import type { Db } from '../src/auth/context.js';
import { revokeAllForUser } from '../src/auth/sessions.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, auditEvents, backends, Client, ORIGIN, World, type Harness } from './helpers.js';

const PW = 'ein-sehr-langes-passwort-123';
const HOUR = 3_600_000;
const BAD_VALUES = ['a\u0000b', 'a\ud800b'];

describe.each(backends)('Härtung ($name)', (backend) => {
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
  afterEach(() => {
    vi.useRealTimers();
  });

  /** Neue Anmeldung per Passwort (frischer TOTP-Zeitschritt); gibt den angemeldeten Client zurück. */
  async function login(email: string, secret: string, ip = '203.0.113.99') {
    world.advance(31_000);
    const c = world.client(ip);
    const res = await c.post('/api/v1/auth/login/password', { email, password: PW, totp: await world.totp(secret) });
    expect(res.status).toBe(200);
    c.adopt(res.json.session);
    return c;
  }

  const memberId = async (email: string) => (await harness.db.select().from(schema.users).where(eq(schema.users.email, email)))[0]?.id ?? '';

  // ---------- 1. Logging ----------

  describe('Logging ohne SQL-Parameter', () => {
    const secretEmail = 'geheim.person@example.org';
    const secretHash = '$argon2id$v=19$m=32768,t=3,p=1$geheimer-hash';

    async function dbError(): Promise<unknown> {
      try {
        // NUL in jsonb: PostgreSQL lehnt ab; Drizzle packt Abfrage UND Parameter in die Meldung
        await harness.db.insert(schema.auditLog).values({ event: 'login_failed', detail: { email: secretEmail, hash: secretHash, nul: '\u0000' } });
      } catch (err) {
        return err;
      }
      throw new Error('Der Datenbankfehler blieb aus');
    }

    function capture() {
      const lines: string[] = [];
      const stream = new Writable({
        write(chunk: Buffer, _enc, cb) {
          lines.push(chunk.toString('utf8'));
          cb();
        },
      });
      return { lines, stream };
    }

    it('Fastify-Logger und ctx.log geben von DB-Fehlern nur Name, Code und Ursache aus', async () => {
      const { lines, stream } = capture();
      const w = await World.create(harness.db, { LOG_LEVEL: 'info' }, { logStream: stream });
      try {
        const err = await dbError();
        // Gegenprobe: die Roh-Meldung enthält die Parameter wirklich
        expect(String((err as Error).message)).toContain(secretEmail);
        w.app.log.error({ err }, 'Test App-Log');
        w.auth.ctx.log.error({ err }, 'Test ctx.log');
        const log = lines.join('');
        expect(log).toContain('Test App-Log');
        expect(log).toContain('Test ctx.log');
        expect(log).not.toContain(secretEmail);
        expect(log).not.toContain(secretHash);
        expect(log).not.toContain('Failed query');
        const entry = JSON.parse(lines.find((l) => l.includes('Test App-Log')) ?? '{}') as { err: { type: string; cause?: { code?: string }; stack: string } };
        expect(entry.err.type).toMatch(/Error/);
        expect(entry.err.cause?.code).toBe('22P05');
        expect(entry.err.stack).toMatch(/\n\s+at /);
      } finally {
        await w.close();
      }
    });

    it('unbehandelte Fehler in einer Anfrage landen ohne Parameter im Log (Fehlerhandler)', async () => {
      const { lines, stream } = capture();
      const w = await World.create(harness.db, { LOG_LEVEL: 'info' }, { logStream: stream });
      const a = await adminPassword(w);
      const err = await dbError();
      const spy = vi.spyOn(w.auth.ctx.db, 'update').mockImplementationOnce(() => {
        throw err;
      });
      try {
        const res = await a.client.patch('/api/v1/me', { displayName: 'Neuer Name' });
        expect(res.status).toBe(500);
        expect(res.json).toEqual({ error: 'internal_error', message: 'Interner Fehler.' });
        const log = lines.join('');
        expect(log).toContain('Unbehandelter Fehler');
        expect(log).not.toContain(secretEmail);
        expect(log).not.toContain(secretHash);
        expect(log).not.toContain('Failed query');
      } finally {
        spy.mockRestore();
        await w.close();
      }
    });

    it('der Aufräum-Job protokolliert Fehler ohne Parameter', async () => {
      const { lines, stream } = capture();
      const w = await World.create(harness.db, { LOG_LEVEL: 'info' }, { logStream: stream });
      try {
        const err = await dbError();
        const broken = { ...w.auth.ctx, db: {
          update: () => {
            throw err;
          },
        } as unknown as Db };
        const job = startMaintenance(broken);
        expect(await job.first).toBeNull();
        job.stop();
        const log = lines.join('');
        expect(log).toContain('Aufräum-Job fehlgeschlagen');
        expect(log).not.toContain(secretEmail);
        expect(log).not.toContain(secretHash);
      } finally {
        await w.close();
      }
    });
  });

  // ---------- 2. ungültige Zeichen ----------

  describe('NUL und einzelne Surrogate werden in allen Textfeldern abgelehnt (400)', () => {
    const post = (c: Client, url: string, body: unknown) => c.post(url, body);

    it('PATCH /me, Gerätename, Passkey-Name, Passwort, E-Mail, Codes, Token', async () => {
      const a = await adminPassword(world);
      const boot2 = await a.client.post('/api/v1/invites', { role: 'child' });
      const token = boot2.json.invite.token as string;
      const anon = world.client('198.51.100.5');
      const base = { email: 'neu@example.org', displayName: 'Neu', password: PW, token };

      // (url, Client, gültiger Körper, Feld, das ersetzt wird, Pfad im Körper)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const cases: Array<{ name: string; url: string; client: Client; method?: 'PATCH'; body: Record<string, unknown>; mutate: (b: Record<string, any>, v: string) => void }> = [
        { name: 'PATCH /me displayName', url: '/api/v1/me', client: a.client, method: 'PATCH', body: { displayName: 'Ok' }, mutate: (b, v) => (b.displayName = v) },
        { name: 'Einladung (Passwort) displayName', url: '/api/v1/auth/invites/password/start', client: anon, body: base, mutate: (b, v) => (b.displayName = v) },
        { name: 'Einladung (Passwort) E-Mail', url: '/api/v1/auth/invites/password/start', client: anon, body: base, mutate: (b, v) => (b.email = `${v}@example.org`) },
        { name: 'Einladung (Passwort) Passwort', url: '/api/v1/auth/invites/password/start', client: anon, body: base, mutate: (b, v) => (b.password = `${PW}${v}`) },
        { name: 'Einladung (Passkey) displayName', url: '/api/v1/auth/invites/passkey/options', client: anon, body: { token, email: 'p@example.org', displayName: 'P' }, mutate: (b, v) => (b.displayName = v) },
        { name: 'Einladung Token', url: '/api/v1/auth/invites/lookup', client: anon, body: { token }, mutate: (b, v) => (b.token = `${token}${v}`) },
        { name: 'Anmeldung E-Mail', url: '/api/v1/auth/login/password', client: anon, body: { email: 'x@example.org', password: PW, totp: '123456' }, mutate: (b, v) => (b.email = `${v}@example.org`) },
        { name: 'Anmeldung Passwort', url: '/api/v1/auth/login/password', client: anon, body: { email: 'x@example.org', password: PW, totp: '123456' }, mutate: (b, v) => (b.password = v) },
        { name: 'Anmeldung Gerätename', url: '/api/v1/auth/login/password', client: anon, body: { email: 'x@example.org', password: PW, totp: '123456', client: 'app', device: { name: 'Pixel', platform: 'android' } }, mutate: (b, v) => (b.device.name = v) },
        { name: 'Anmeldung Geräte-appVersion', url: '/api/v1/auth/login/password', client: anon, body: { email: 'x@example.org', password: PW, totp: '123456', client: 'app', device: { name: 'Pixel', platform: 'android', appVersion: '1.0' } }, mutate: (b, v) => (b.device.appVersion = v) },
        { name: 'Anmeldung Wiederherstellungs-Code', url: '/api/v1/auth/login/password', client: anon, body: { email: 'x@example.org', password: PW, recoveryCode: 'AAAA-BBBB-CCCC-DDDD' }, mutate: (b, v) => (b.recoveryCode = `AAAA-${v}-CCCC-DDDD`) },
        { name: 'Wiederherstellung E-Mail', url: '/api/v1/auth/login/recovery', client: anon, body: { email: 'x@example.org', code: 'AAAA-BBBB-CCCC-DDDD' }, mutate: (b, v) => (b.email = `${v}@example.org`) },
        { name: 'Wiederherstellung Code', url: '/api/v1/auth/login/recovery', client: anon, body: { email: 'x@example.org', code: 'AAAA-BBBB-CCCC-DDDD' }, mutate: (b, v) => (b.code = `AAAA-${v}-CCCC`) },
        { name: 'Token erneuern', url: '/api/v1/auth/refresh', client: anon, body: { refreshToken: 'r'.repeat(43), deviceId: '00000000-0000-4000-8000-000000000000' }, mutate: (b, v) => (b.refreshToken = `${v}${'r'.repeat(40)}`) },
        { name: 'Step-up Code', url: '/api/v1/auth/step-up/code', client: a.client, body: { recoveryCode: 'AAAA-BBBB-CCCC-DDDD' }, mutate: (b, v) => (b.recoveryCode = `AAAA-${v}-CCCC`) },
        { name: 'Registrierung abschließen (Gerätename)', url: '/api/v1/auth/invites/password/complete', client: anon, body: { challengeId: '00000000-0000-4000-8000-000000000000', code: '123456', client: 'app', device: { name: 'Pixel', platform: 'android' } }, mutate: (b, v) => (b.device.name = v) },
        { name: 'Passkey-Anmeldung (Gerätename)', url: '/api/v1/auth/login/passkey/verify', client: anon, body: { challengeId: '00000000-0000-4000-8000-000000000000', response: { id: 'x', rawId: 'x', type: 'public-key', response: {} }, client: 'app', device: { name: 'Pixel', platform: 'android' } }, mutate: (b, v) => (b.device.name = v) },
        { name: 'Passkey-Name beim Hinzufügen', url: '/api/v1/me/passkeys/verify', client: a.client, body: { challengeId: '00000000-0000-4000-8000-000000000000', response: { id: 'x', rawId: 'x', type: 'public-key', response: {} }, label: 'Handy' }, mutate: (b, v) => (b.label = v) },
        { name: 'WebAuthn-Antwort (verschachtelt)', url: '/api/v1/auth/login/passkey/verify', client: anon, body: { challengeId: '00000000-0000-4000-8000-000000000000', response: { id: 'x', rawId: 'x', type: 'public-key', response: {} } }, mutate: (b, v) => (b.response.response = { clientDataJSON: v }) },
      ];

      for (const c of cases) {
        for (const bad of BAD_VALUES) {
          const body = structuredClone(c.body);
          c.mutate(body, bad);
          const res = c.method === 'PATCH' ? await c.client.patch(c.url, body) : await post(c.client, c.url, body);
          expect(res.status, `${c.name} mit ${JSON.stringify(bad)}`).toBe(400);
          expect(res.json.error, c.name).toBe('invalid_request');
        }
      }

      // Gegenprobe: dieselben Körper ohne ungültige Zeichen werden NICHT als ungültige Eingabe abgewiesen
      const ok = await a.client.patch('/api/v1/me', { displayName: 'Jürgen 😀' });
      expect(ok.status).toBe(200);
      const clean = await anon.post('/api/v1/auth/login/password', { email: 'x@example.org', password: PW, totp: '123456', client: 'app', device: { name: 'Pixel 😀', platform: 'android' } });
      expect(clean.status).toBe(401);
    });

    it('Freitext in Gerät, Name und Profil erreicht nie die Datenbank (kein 500)', async () => {
      const a = await adminPassword(world);
      const res = await a.client.patch('/api/v1/me', { displayName: '\u0000' });
      expect(res.status).toBe(400);
      expect((await a.client.get('/api/v1/me')).json.user.displayName).toBe('Admin');
    });
  });

  // ---------- 3. Freigabe ----------

  describe('Einladungen: Freigabe nur auf ausdrücklichen Wunsch', () => {
    it('ohne Angabe keine Freigabe nötig; auf Wunsch wartet das neue Mitglied; die Rolle "guest" wird abgelehnt', async () => {
      const a = await adminPassword(world);
      const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
      const standard = await mama.client.post('/api/v1/invites', { role: 'child' });
      expect(standard.json.invite.requireApproval).toBe(false);
      const viaParent = await mama.client.post('/api/v1/invites', { role: 'child', requireApproval: true });
      expect(viaParent.status).toBe(200);
      expect(viaParent.json.invite.requireApproval).toBe(true);
      const lookup = await world.client('198.51.100.7').post('/api/v1/auth/invites/lookup', { token: viaParent.json.invite.token });
      expect(lookup.json.invite.requireApproval).toBe(true);
      const reg = await world.registerPassword(viaParent.json.invite.token, { email: 'gast@example.org' });
      expect(reg.complete?.json.status).toBe('pending');
      expect(reg.complete?.json.session).toBeUndefined();
      expect((await a.client.post('/api/v1/invites', { role: 'guest' })).status).toBe(400);
    });
  });

  // ---------- 5. IPv6 und Challenge-Begrenzung ----------

  describe('IPv6 wird auf /64 zusammengefasst', () => {
    it('IP-Sperre: wechselnde Adressen im selben /64 gelten als eine IP', async () => {
      await adminPassword(world);
      world.config.auth.lockoutIpThreshold = 4;
      for (let i = 1; i <= 4; i++) {
        const c = world.client(`2001:db8:1:2::${i}`);
        expect((await c.post('/api/v1/auth/login/password', { email: `x${i}@example.org`, password: 'falsch-falsch-falsch', totp: '123456' })).status).toBe(401);
      }
      expect((await world.client('2001:db8:1:2:aaaa::9').post('/api/v1/auth/login/passkey/options')).status).toBe(429);
      expect((await world.client('2001:db8:1:3::1').post('/api/v1/auth/login/passkey/options')).status).toBe(200);
      // IPv4-in-IPv6 ist dieselbe Adresse wie IPv4
      for (let i = 0; i < 4; i++) await world.client('192.0.2.77').post('/api/v1/auth/login/password', { email: `y${i}@example.org`, password: 'falsch-falsch-falsch', totp: '123456' });
      expect((await world.client('::ffff:192.0.2.77').post('/api/v1/auth/login/passkey/options')).status).toBe(429);
    });

    it('Rate-Limit je /64', async () => {
      const strict = await World.create(harness.db, { AUTH_RATE_LIMIT_MAX: '3', RATE_LIMIT_MAX: '50' });
      try {
        const codes: number[] = [];
        for (let i = 1; i <= 5; i++) codes.push((await strict.client(`2001:db8:9:9::${i}`).post('/api/v1/ws-ticket')).status);
        expect(codes).toEqual([401, 401, 401, 429, 429]);
        expect((await strict.client('2001:db8:9:a::1').post('/api/v1/ws-ticket')).status).toBe(401);
      } finally {
        await strict.close();
      }
    });

    it('Challenge-Erzeugung ohne Anmeldung: je IP-Präfix und global begrenzt', async () => {
      const w = await World.create(harness.db, { CHALLENGE_MAX_PER_IP: '3', CHALLENGE_MAX_GLOBAL: '5' });
      try {
        const codes: number[] = [];
        for (let i = 1; i <= 5; i++) codes.push((await w.client(`2001:db8:5:5::${i}`).post('/api/v1/auth/login/passkey/options')).status);
        expect(codes).toEqual([200, 200, 200, 429, 429]);
        const limited = await w.client('2001:db8:5:5::99').post('/api/v1/auth/login/passkey/options');
        expect(limited.json.error).toBe('rate_limited');
        expect(Number(limited.headers['retry-after'])).toBeGreaterThan(0);
        // andere IPs: bis zur globalen Grenze (5 offene insgesamt)
        expect((await w.client('198.51.100.1').post('/api/v1/auth/login/passkey/options')).status).toBe(200);
        expect((await w.client('198.51.100.2').post('/api/v1/auth/login/passkey/options')).status).toBe(200);
        expect((await w.client('198.51.100.3').post('/api/v1/auth/login/passkey/options')).status).toBe(429);
        expect(await w.count('webauthn_challenges')).toBe(5);
        // nach Ablauf (5 Minuten) geht es wieder
        w.advance(5 * 60_000 + 1000);
        expect((await w.client('198.51.100.3').post('/api/v1/auth/login/passkey/options')).status).toBe(200);
      } finally {
        await w.close();
      }
    });
  });

  // ---------- 6. Aufräumen ----------

  describe('Aufräumen stündlich', () => {
    it('der Job läuft beim Start und danach jede Stunde (Challenges, Tickets, Fehlversuche, angefangene Registrierungen)', async () => {
      vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
      const expired = new Date(world.clock - 1000);
      const addExpiredChallenge = (purpose: string) => harness.db.insert(schema.webauthnChallenges).values({ purpose, challenge: 'c', expiresAt: expired });
      await addExpiredChallenge('register_password');
      const job = startMaintenance(world.auth.ctx);
      const first = await job.first;
      expect(first?.challengesDeleted).toBe(1);
      await addExpiredChallenge('register_passkey');
      await addExpiredChallenge('login');
      await vi.advanceTimersByTimeAsync(HOUR - 1000);
      expect(await world.count('webauthn_challenges')).toBe(2); // noch keine Stunde
      await vi.advanceTimersByTimeAsync(2000);
      // der Lauf ist asynchron: kurz warten
      for (let i = 0; i < 50 && (await world.count('webauthn_challenges')) > 0; i++) await new Promise((r) => setTimeout(r, 20));
      expect(await world.count('webauthn_challenges')).toBe(0);
      job.stop();
    });

    it('Fehlversuche außerhalb des Fensters verschwinden, aktive Sperren bleiben', async () => {
      const old = new Date(world.clock - 16 * 60_000);
      await harness.db.insert(schema.loginAttempts).values([
        { key: 'ip:alt', failCount: 3, windowStartedAt: old, lastFailedAt: old },
        { key: 'ip:gesperrt', failCount: 9, windowStartedAt: old, lastFailedAt: old, lockedUntil: new Date(world.clock + 60_000) },
        { key: 'ip:frisch', failCount: 1, windowStartedAt: new Date(world.clock), lastFailedAt: new Date(world.clock - 60_000) },
      ]);
      const report = await runMaintenance(world.auth.ctx);
      expect(report.attemptsDeleted).toBe(1);
      expect((await harness.db.select().from(schema.loginAttempts)).map((r) => r.key).sort()).toEqual(['ip:frisch', 'ip:gesperrt']);
    });

    it('invite_expired wird je Ablauf genau einmal protokolliert, nicht für gesperrte Einladungen', async () => {
      const a = await adminPassword(world);
      const inv = await a.client.post('/api/v1/invites', { role: 'child', hours: 1 });
      const locked = await a.client.post('/api/v1/invites', { role: 'child', hours: 1, pin: true });
      await harness.db.update(schema.invites).set({ lockedAt: new Date(world.clock) }).where(eq(schema.invites.id, locked.json.invite.id));
      world.advance(2 * HOUR);
      expect((await runMaintenance(world.auth.ctx)).invitesExpired).toBe(2);
      await runMaintenance(world.auth.ctx);
      const expiredAudits = (await harness.db.select().from(schema.auditLog)).filter((r) => r.event === 'invite_expired');
      expect(expiredAudits).toHaveLength(1);
      expect((expiredAudits[0]?.detail as { inviteId: string }).inviteId).toBe(inv.json.invite.id);
      // nach einer Verlängerung und erneutem Ablauf gibt es einen zweiten Eintrag
      expect((await a.client.post(`/api/v1/invites/${inv.json.invite.id}/extend`, { hours: 1 })).status).toBe(200);
      world.advance(2 * HOUR);
      await runMaintenance(world.auth.ctx);
      expect((await auditEvents(world)).filter((e) => e === 'invite_expired')).toHaveLength(2);
    });
  });

  // ---------- 7. Einladungen ----------

  describe('Einladungen und Rollen', () => {
    it('extend verkürzt nie und verlängert ab jetzt', async () => {
      const a = await adminPassword(world);
      const inv = await a.client.post('/api/v1/invites', { role: 'child', hours: 48 });
      const original = new Date(inv.json.invite.expiresAt).getTime();
      const shorter = await a.client.post(`/api/v1/invites/${inv.json.invite.id}/extend`, { hours: 1 });
      expect(shorter.status).toBe(200);
      expect(new Date(shorter.json.expiresAt).getTime()).toBe(original);
      const longer = await a.client.post(`/api/v1/invites/${inv.json.invite.id}/extend`, { hours: 100 });
      expect(new Date(longer.json.expiresAt).getTime()).toBe(world.clock + 100 * HOUR);
      const row = (await harness.db.select().from(schema.invites).where(eq(schema.invites.id, inv.json.invite.id)))[0];
      expect(row?.expiresAt.getTime()).toBe(world.clock + 100 * HOUR);
    });

    it('PIN-Hash steht schon beim Anlegen (ein Schritt); scheitert die Transaktion, bleibt nichts zurück', async () => {
      const a = await adminPassword(world);
      const inv = await a.client.post('/api/v1/invites', { role: 'child', pin: true });
      expect(inv.json.invite.pin).toMatch(/^\d{6}$/);
      const row = (await harness.db.select().from(schema.invites).where(eq(schema.invites.id, inv.json.invite.id)))[0];
      expect(row?.pinHash).toMatch(/^[0-9a-f]{64}$/);
      const before = await world.count('invites');
      const { createInvite } = await import('../src/auth/invites.js');
      const [fam] = await harness.db.select().from(schema.families);
      await expect(
        harness.db.transaction(async (tx) => {
          await createInvite(world.auth.ctx, tx, { familyId: fam?.id ?? '', role: 'child', hours: 1, withPin: true, createdBy: null }, { ip: undefined });
          throw new Error('abbrechen');
        }),
      ).rejects.toThrow('abbrechen');
      expect(await world.count('invites')).toBe(before);
    });

    it('herabgestufte Rollen dürfen Einladungen der alten Rolle weder verlängern noch widerrufen', async () => {
      const a = await adminPassword(world);
      const second = await addMember(world, a.client, 'admin', 'zweiter@example.org');
      const adminInvite = await second.client.post('/api/v1/invites', { role: 'admin' });
      expect(adminInvite.status).toBe(200);
      const childInvite = await second.client.post('/api/v1/invites', { role: 'child' });
      // Admin 1 stuft den zweiten Admin zum Elternteil herab
      const id = await memberId('zweiter@example.org');
      expect((await a.client.patch(`/api/v1/members/${id}/role`, { role: 'parent' })).status).toBe(200);
      // seine offenen Einladungen sind widerrufen
      const list = (await a.client.get('/api/v1/invites')).json.invites as Array<{ id: string; status: string }>;
      expect(list.find((i) => i.id === adminInvite.json.invite.id)?.status).toBe('revoked');
      expect(list.find((i) => i.id === childInvite.json.invite.id)?.status).toBe('revoked');
      expect((await auditEvents(world)).filter((e) => e === 'invite_revoked')).toHaveLength(2);
      // und selbst eine noch offene Admin-Einladung (hier direkt in der DB wiederhergestellt) kann er als Elternteil nicht mehr verwalten
      await harness.db.update(schema.invites).set({ revokedAt: null }).where(eq(schema.invites.id, adminInvite.json.invite.id));
      const again = await login('zweiter@example.org', second.totpSecret, '203.0.113.150');
      expect((await again.post(`/api/v1/invites/${adminInvite.json.invite.id}/extend`, { hours: 5 })).status).toBe(403);
      expect((await again.post(`/api/v1/invites/${adminInvite.json.invite.id}/revoke`)).status).toBe(403);
      // eine Einladung für ein Kind verwaltet er weiterhin
      await harness.db.update(schema.invites).set({ revokedAt: null }).where(eq(schema.invites.id, childInvite.json.invite.id));
      expect((await again.post(`/api/v1/invites/${childInvite.json.invite.id}/extend`, { hours: 5 })).status).toBe(200);
    });

    it('Heraufstufen widerruft nichts; Entfernen widerruft offene Einladungen der Person', async () => {
      const a = await adminPassword(world);
      const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
      const inv = await mama.client.post('/api/v1/invites', { role: 'child' });
      const mamaId = await memberId('mama@example.org');
      expect((await a.client.patch(`/api/v1/members/${mamaId}/role`, { role: 'admin' })).status).toBe(200);
      let row = (await harness.db.select().from(schema.invites).where(eq(schema.invites.id, inv.json.invite.id)))[0];
      expect(row?.revokedAt).toBeNull();
      expect((await a.client.del(`/api/v1/members/${mamaId}`)).status).toBe(200);
      row = (await harness.db.select().from(schema.invites).where(eq(schema.invites.id, inv.json.invite.id)))[0];
      expect(row?.revokedAt).not.toBeNull();
      // der Link ist tot
      const lookup = await world.client('198.51.100.8').post('/api/v1/auth/invites/lookup', { token: inv.json.invite.token });
      expect(lookup.json.error).toBe('invite_invalid');
    });
  });

  // ---------- 12. Mitglied entfernen/ablehnen ----------

  describe('Mitglied entfernen oder ablehnen löscht nur die Mitgliedschaft', () => {
    async function secondMembership(userId: string) {
      const [fam2] = await harness.db.insert(schema.families).values({ name: 'Andere Familie' }).returning();
      await harness.db.insert(schema.memberships).values({ familyId: fam2?.id ?? '', userId, role: 'child' });
      return fam2;
    }

    it('ohne weitere Mitgliedschaft ist das Konto gesperrt und entfernt (Soft-Delete); nach der Aufbewahrungsfrist verschwindet es ganz', async () => {
      const a = await adminPassword(world);
      const kid = await addMember(world, a.client, 'child', 'kind@example.org');
      const id = await memberId('kind@example.org');
      expect((await a.client.del(`/api/v1/members/${id}`)).status).toBe(200);
      expect(await memberId('kind@example.org')).toBe(id);
      const [u] = await harness.db.select().from(schema.users).where(eq(schema.users.id, id));
      expect(u?.removedAt).not.toBeNull();
      expect(u?.disabledAt).not.toBeNull();
      expect((await kid.client.get('/api/v1/me')).status).toBe(401);
      await harness.db.update(schema.users).set({ removedAt: new Date(world.clock - 31 * 86_400_000) }).where(eq(schema.users.id, id));
      const { runMaintenance } = await import('../src/auth/maintenance.js');
      await runMaintenance(world.auth.ctx);
      expect(await memberId('kind@example.org')).toBe('');
    });

    it('mit weiterer Mitgliedschaft bleibt das Konto bestehen, die Familie verliert die Person', async () => {
      const a = await adminPassword(world);
      const kid = await addMember(world, a.client, 'child', 'kind@example.org');
      const id = await memberId('kind@example.org');
      const fam2 = await secondMembership(id);
      expect((await a.client.del(`/api/v1/members/${id}`)).status).toBe(200);
      expect(await memberId('kind@example.org')).toBe(id);
      const left = await harness.db.select().from(schema.memberships).where(eq(schema.memberships.userId, id));
      expect(left.map((m) => m.familyId)).toEqual([fam2?.id]);
      // Sitzungen und Geräte der entfernten Familie sind weg
      expect((await kid.client.get('/api/v1/me')).status).toBe(401);
      expect((await harness.db.select().from(schema.sessions).where(eq(schema.sessions.userId, id))).length).toBe(0);
      expect((await a.client.get('/api/v1/members')).json.members.some((m: { id: string }) => m.id === id)).toBe(false);
    });

    it('Ablehnen wartender Mitglieder: Konto nur ohne weitere Mitgliedschaft löschen', async () => {
      const a = await adminPassword(world);
      const inv = await a.client.post('/api/v1/invites', { role: 'child', requireApproval: true });
      const reg = await world.registerPassword(inv.json.invite.token, { email: 'gast@example.org' });
      expect(reg.complete?.json.status).toBe('pending');
      const id = await memberId('gast@example.org');
      await secondMembership(id);
      expect((await a.client.post(`/api/v1/members/${id}/reject`)).status).toBe(200);
      expect(await memberId('gast@example.org')).toBe(id);
      const inv2 = await a.client.post('/api/v1/invites', { role: 'child', requireApproval: true });
      await world.registerPassword(inv2.json.invite.token, { email: 'gast2@example.org' });
      const id2 = await memberId('gast2@example.org');
      expect((await a.client.post(`/api/v1/members/${id2}/reject`)).status).toBe(200);
      expect(await memberId('gast2@example.org')).toBe('');
    });
  });

  // ---------- 9. revokeAllForUser ----------

  describe('revokeAllForUser mit exceptSessionId', () => {
    it('markiert das Gerät der ausgenommenen Sitzung nicht als widerrufen', async () => {
      const a = await adminPassword(world);
      const userId = await memberId(a.email);
      const appLogin = async (device: string) => {
        world.advance(31_000);
        const c = world.client('203.0.113.120');
        const res = await c.post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(a.totpSecret), client: 'app', device: { name: device, platform: 'android' } });
        expect(res.status).toBe(200);
        return res.json.session as { deviceId: string; refreshToken: string };
      };
      const phone = await appLogin('Handy');
      const tablet = await appLogin('Tablet');
      // Rotation: die erste Sitzungszeile des Handys ist "benutzt", die zweite aktuell
      expect((await world.client().post('/api/v1/auth/refresh', { refreshToken: phone.refreshToken, deviceId: phone.deviceId })).status).toBe(200);
      const rows = await harness.db.select().from(schema.sessions).where(eq(schema.sessions.deviceId, phone.deviceId));
      expect(rows).toHaveLength(2);
      const current = rows.find((r) => r.usedAt === null);
      expect(current).toBeDefined();

      await harness.db.transaction((tx) => revokeAllForUser(world.auth.ctx, tx, userId, { exceptSessionId: current?.id }));

      const dev = async (id: string) => (await harness.db.select().from(schema.devices).where(eq(schema.devices.id, id)))[0];
      expect((await dev(phone.deviceId))?.revokedAt).toBeNull();
      expect((await dev(tablet.deviceId))?.revokedAt).not.toBeNull();
      const after = await harness.db.select().from(schema.sessions).where(eq(schema.sessions.deviceId, phone.deviceId));
      expect(after.find((r) => r.id === current?.id)?.revokedAt).toBeNull();
      expect(after.find((r) => r.id !== current?.id)?.revokedAt).not.toBeNull();
      // die Web-Sitzung des Admins (anderes Gerät) ist widerrufen
      expect((await a.client.get('/api/v1/me')).status).toBe(401);
      const live = await harness.db.select().from(schema.devices).where(and(eq(schema.devices.userId, userId), isNull(schema.devices.revokedAt)));
      expect(live.map((d) => d.id)).toEqual([phone.deviceId]);
    });
  });
});

// ---------- 11. Routenprüfung ----------

describe.each(backends)('Routenprüfung ohne rohen Pfadvergleich ($name)', (backend) => {
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
    // production: die Origin-Prüfung ist scharf
    world = await World.create(harness.db, { NODE_ENV: 'production' });
  });

  it('/%61pi/… umgeht weder den Origin-Check noch no-store', async () => {
    for (const path of ['/api/v1/auth/logout', '/%61pi/v1/auth/logout', '/%61%70i/v1/auth/logout']) {
      const res = await world.app.inject({ method: 'POST', url: path, headers: { origin: 'https://evil.example', 'x-forwarded-for': '203.0.113.1' }, payload: {} });
      expect(res.statusCode, path).toBe(403);
      expect(res.json().error, path).toBe('origin_not_allowed');
    }
    // eigene Origin passt weiterhin
    const ok = await world.app.inject({ method: 'POST', url: '/%61pi/v1/auth/logout', headers: { origin: ORIGIN }, payload: {} });
    expect(ok.statusCode).toBe(200);
    for (const path of ['/api/v1/version', '/%61pi/v1/version', '/%61pi/v1/gibt-es-nicht', '/api/v1/gibt-es-nicht']) {
      const res = await world.app.inject({ method: 'GET', url: path });
      expect(res.headers['cache-control'], path).toBe('no-store');
    }
  });
});

// ---------- 10. Passwort-Begrenzer ----------

describe('Passwort-Berechnungen: Platz wird übergeben, Warteschlange begrenzt', () => {
  it('nie mehr als MAX_CONCURRENT gleichzeitig, bei Überlauf 503', async () => {
    const { hashPassword, verifyPassword, limiterState, MAX_CONCURRENT, MAX_WAITING } = await import('../src/auth/password.js');
    const { AppError } = await import('../src/errors.js');
    let peak = 0;
    const sampler = setInterval(() => (peak = Math.max(peak, limiterState().running)), 1);
    const total = MAX_CONCURRENT + MAX_WAITING + 10;
    const results = await Promise.allSettled(Array.from({ length: total }, (_, i) => hashPassword(`passwort-nummer-${i}-lang-genug`)));
    peak = Math.max(peak, 0);
    clearInterval(sampler);
    const rejected = results.filter((r) => r.status === 'rejected');
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(MAX_CONCURRENT + MAX_WAITING);
    expect(rejected).toHaveLength(10);
    for (const r of rejected) {
      expect((r as PromiseRejectedResult).reason).toBeInstanceOf(AppError);
      expect((r as PromiseRejectedResult).reason).toMatchObject({ status: 503, code: 'server_busy' });
    }
    expect(peak).toBeLessThanOrEqual(MAX_CONCURRENT);
    expect(limiterState()).toEqual({ running: 0, waiting: 0 });

    // verifyPassword gibt bei Überlast 503 weiter statt "falsches Passwort" zu melden
    const hash = await hashPassword('das-richtige-passwort');
    const flood = Array.from({ length: MAX_CONCURRENT + MAX_WAITING }, () => hashPassword('fuellung-fuer-die-warteschlange'));
    await expect(verifyPassword(hash, 'das-richtige-passwort')).rejects.toMatchObject({ status: 503 });
    await Promise.all(flood);
    expect(await verifyPassword(hash, 'das-richtige-passwort')).toBe(true);
    expect(await verifyPassword(null, 'irgendwas')).toBe(false);
  });
});

// ---------- 8. WebSocket ----------

describe.each(backends)('WebSocket wird bei Widerruf geschlossen ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  const sockets: import('ws').WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await harness.reset();
  });
  afterEach(async () => {
    for (const s of sockets.splice(0)) s.terminate();
    await world?.close();
  });

  async function start(env: NodeJS.ProcessEnv = {}) {
    world = await World.create(harness.db, { WS_AUTH_TIMEOUT_MS: '60000', WS_PING_INTERVAL_MS: '600000', ...env });
    await world.app.listen({ host: '127.0.0.1', port: 0 });
    return world;
  }

  async function connect(c: Client, ip = '203.0.113.10') {
    const { default: WebSocket } = await import('ws');
    const { port } = world.app.server.address() as import('node:net').AddressInfo;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': ip, ...(c.cookie ? { cookie: c.cookie } : {}) } });
    sockets.push(ws);
    const closed = new Promise<number>((resolve) => ws.once('close', (code: number) => resolve(code)));
    const ready = new Promise<void>((resolve, reject) => {
      ws.on('message', (raw: Buffer) => {
        if ((JSON.parse(raw.toString('utf8')) as { type: string }).type === 'ready') resolve();
      });
      ws.once('error', reject);
      ws.once('unexpected-response', (_r, res) => reject(new Error(`HTTP ${res.statusCode}`)));
    });
    await ready;
    return { ws, closed };
  }

  const passwordLogin = async (email: string, secret: string, ip: string) => {
    world.advance(31_000);
    const c = world.client(ip);
    const res = await c.post('/api/v1/auth/login/password', { email, password: PW, totp: await world.totp(secret) });
    expect(res.status).toBe(200);
    c.adopt(res.json.session);
    return { client: c, deviceId: res.json.session.deviceId as string };
  };
  const within = <T,>(p: Promise<T>, ms = 2000) => Promise.race([p, new Promise<never>((_, rej) => setTimeout(() => rej(new Error('Zeitüberschreitung')), ms))]);
  const stillOpen = async (ws: import('ws').WebSocket) => {
    await new Promise((r) => setTimeout(r, 150));
    return ws.readyState === ws.OPEN;
  };

  it('Abmelden schließt den eigenen Socket (4401), ein anderes Gerät bleibt offen', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const other = await passwordLogin(a.email, a.totpSecret, '203.0.113.31');
    const s1 = await connect(a.client);
    const s2 = await connect(other.client, '203.0.113.31');
    expect((await a.client.post('/api/v1/auth/logout')).status).toBe(200);
    expect(await within(s1.closed)).toBe(4401);
    expect(await stillOpen(s2.ws)).toBe(true);
    // Alles abmelden schließt auch den Rest
    expect((await other.client.post('/api/v1/auth/logout-all')).status).toBe(200);
    expect(await within(s2.closed)).toBe(4401);
  });

  it('ein entferntes Gerät verliert seinen Socket, die anderen nicht', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const other = await passwordLogin(a.email, a.totpSecret, '203.0.113.32');
    const sMine = await connect(a.client);
    const sOther = await connect(other.client, '203.0.113.32');
    expect((await a.client.del(`/api/v1/devices/${other.deviceId}`)).status).toBe(200);
    expect(await within(sOther.closed)).toBe(4401);
    expect(await stillOpen(sMine.ws)).toBe(true);
  });

  it('Rollenwechsel und Entfernen schließen die Sockets der Person', async () => {
    const w = await start();
    const a = await adminPassword(w);
    const mama = await addMember(w, a.client, 'parent', 'mama@example.org');
    const papa = await addMember(w, a.client, 'parent', 'papa@example.org');
    const sMama = await connect(mama.client, '203.0.113.41');
    const sPapa = await connect(papa.client, '203.0.113.42');
    const mamaId = (await harness.db.select().from(schema.users).where(eq(schema.users.email, 'mama@example.org')))[0]?.id;
    const papaId = (await harness.db.select().from(schema.users).where(eq(schema.users.email, 'papa@example.org')))[0]?.id;
    expect((await a.client.patch(`/api/v1/members/${mamaId}/role`, { role: 'child' })).status).toBe(200);
    expect(await within(sMama.closed)).toBe(4401);
    expect(await stillOpen(sPapa.ws)).toBe(true);
    expect((await a.client.del(`/api/v1/members/${papaId}`)).status).toBe(200);
    expect(await within(sPapa.closed)).toBe(4401);
    for (let i = 0; i < 40 && w.app.hub.size > 0; i++) await new Promise((r) => setTimeout(r, 25));
    expect(w.app.hub.size).toBe(0);
  });

  it('beim Ping wird die Sitzung geprüft (auch ohne Widerrufs-Ereignis) und die Rolle aktuell gehalten', async () => {
    const w = await start({ WS_PING_INTERVAL_MS: '100' });
    const a = await adminPassword(w);
    const mama = await addMember(w, a.client, 'parent', 'mama@example.org');
    const papa = await addMember(w, a.client, 'parent', 'papa@example.org');
    const sMama = await connect(mama.client, '203.0.113.51');
    const sPapa = await connect(papa.client, '203.0.113.52');
    const roleOf = (userEmail: string, id: string) => w.app.hub.snapshot().find((s) => s.userId === id)?.role ?? userEmail;
    const mamaId = (await harness.db.select().from(schema.users).where(eq(schema.users.email, 'mama@example.org')))[0]?.id ?? '';
    const papaId = (await harness.db.select().from(schema.users).where(eq(schema.users.email, 'papa@example.org')))[0]?.id ?? '';
    expect(roleOf('mama', mamaId)).toBe('parent');
    // direkt in der Datenbank: Rolle ändern bzw. Sitzung widerrufen, ohne dass der Server davon erfährt
    await harness.db.update(schema.memberships).set({ role: 'child' }).where(eq(schema.memberships.userId, mamaId));
    await harness.db.update(schema.sessions).set({ revokedAt: new Date(w.clock) }).where(eq(schema.sessions.userId, papaId));
    expect(await within(sPapa.closed, 3000)).toBe(4401);
    for (let i = 0; i < 40 && roleOf('mama', mamaId) !== 'child'; i++) await new Promise((r) => setTimeout(r, 50));
    expect(roleOf('mama', mamaId)).toBe('child');
    expect(sMama.ws.readyState).toBe(sMama.ws.OPEN);
  });

  it('WS_MAX_PER_IP gilt je IPv6-/64', async () => {
    const w = await start({ WS_MAX_PER_IP: '2' });
    const a = await adminPassword(w);
    await connect(a.client, '2001:db8:7:7::1');
    await connect(a.client, '2001:db8:7:7::2');
    await expect(connect(a.client, '2001:db8:7:7:1::3')).rejects.toThrow(/429/);
    await connect(a.client, '2001:db8:7:8::1');
  });
});

