// Passwort + TOTP nachträglich hinzufügen, ändern, entfernen (PGlite und echtes PostgreSQL).
import { and, eq, isNull } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import { adminPasskey, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const PW = 'ein-sehr-langes-passwort-123';
const PW2 = 'ein-anderes-langes-passwort-456';

describe.each(backends)('Passwort + TOTP nachträglich ($name)', (backend) => {
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

  const active = async (type: 'password' | 'totp' | 'passkey') =>
    (await harness.db.select().from(schema.credentials).where(and(eq(schema.credentials.type, type), isNull(schema.credentials.revokedAt)))).length;

  async function setup() {
    const a = await adminPasskey(world);
    const c = world.client('203.0.113.140');
    await world.loginPasskey(c, a.authenticator);
    return { a, c };
  }

  /** Frisches Step-up per Passkey (nach jeder Änderung ist das Step-up verbraucht). */
  async function reStepUp(c: Client, a: Awaited<ReturnType<typeof setup>>['a']) {
    const opts = await c.post('/api/v1/auth/step-up/passkey/options');
    const ok = await c.post('/api/v1/auth/step-up/passkey/verify', { challengeId: opts.json.challengeId, response: a.authenticator.assert(opts.json.options) });
    expect(ok.status).toBe(200);
  }

  const liveSessions = async () => (await harness.db.select().from(schema.sessions).where(isNull(schema.sessions.revokedAt))).length;

  async function addPassword(c: Client, password = PW) {
    const start = await c.post('/api/v1/me/password/start', { password });
    if (start.status !== 200) return { start, done: undefined, secret: '' };
    const secret = start.json.totpSecret as string;
    world.advance(31_000);
    const done = await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: await world.totp(secret) });
    return { start, done, secret };
  }

  it('fügt Passwort und TOTP zu einem Passkey-Konto hinzu; danach geht die Passwort-Anmeldung', async () => {
    const { a, c } = await setup();
    const { start, done, secret } = await addPassword(c);
    expect(start.json.totpUri).toContain('otpauth://totp/');
    expect(done?.status).toBe(200);
    // Passwort Argon2id, TOTP verschlüsselt
    const creds = await harness.db.select().from(schema.credentials);
    expect(creds.find((x) => x.type === 'password')?.secret).toMatch(/^\$argon2id\$/);
    expect(creds.find((x) => x.type === 'totp')?.secret).toMatch(/^v1\./);
    expect(JSON.stringify(creds)).not.toContain(secret);
    expect((await c.get('/api/v1/me')).json.credentials).toMatchObject({ password: true, totp: true, passkeys: 1 });
    world.advance(31_000);
    const login = await world.client('203.0.113.141').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(secret) });
    expect(login.status).toBe(200);
    expect(await auditEvents(world)).toContain('password_added');
  });

  it('verlangt Step-up auf allen vier Endpunkten', async () => {
    const { c } = await setup();
    world.advance(6 * MIN);
    for (const r of [
      await c.post('/api/v1/me/password/start', { password: PW }),
      await c.post('/api/v1/me/password/complete', { challengeId: '00000000-0000-4000-8000-000000000000', code: '123456' }),
      await c.post('/api/v1/me/password/change', { password: PW }),
      await c.del('/api/v1/me/password'),
    ]) {
      expect(r.status).toBe(403);
      expect(r.json.error).toBe('step_up_required');
    }
    expect(await active('password')).toBe(0);
  });

  it('verlangt eine Anmeldung', async () => {
    const res = await world.client().post('/api/v1/me/password/start', { password: PW });
    expect(res.status).toBe(401);
  });

  it('lehnt zu kurze Passwörter, die E-Mail als Passwort und unbekannte Felder ab', async () => {
    const { a, c } = await setup();
    const short = await c.post('/api/v1/me/password/start', { password: 'kurz' });
    expect([short.status, short.json.error]).toEqual([400, 'weak_password']);
    const mail = await c.post('/api/v1/me/password/start', { password: a.email });
    expect([mail.status, mail.json.error]).toEqual([400, 'weak_password']);
    expect((await c.post('/api/v1/me/password/start', { password: PW, extra: 1 })).status).toBe(400);
    expect((await c.post('/api/v1/me/password/complete', { challengeId: 'x', code: '12' })).status).toBe(400);
  });

  it('falscher Code: 400 invalid_code, legt nichts an; der Vorgang bleibt wiederholbar, danach ist er eingelöst', async () => {
    const { a, c } = await setup();
    const start = await c.post('/api/v1/me/password/start', { password: PW });
    const bad = await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: '000000' });
    expect([bad.status, bad.json.error]).toEqual([400, 'invalid_code']);
    expect(await active('password')).toBe(0);
    world.advance(31_000);
    const code = await world.totp(start.json.totpSecret);
    expect((await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code })).status).toBe(200);
    world.advance(31_000);
    await reStepUp(c, a);
    const again = await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: await world.totp(start.json.totpSecret) });
    expect(again.json.error).toBe('challenge_invalid');
  });

  it('sperrt nach wiederholten falschen Codes (429)', async () => {
    const { c } = await setup();
    const start = await c.post('/api/v1/me/password/start', { password: PW });
    for (let i = 0; i < 5; i++) expect((await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: '000000' })).status).toBe(400);
    const locked = await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: await world.totp(start.json.totpSecret) });
    expect(locked.status).toBe(429);
    expect(locked.json.error).toBe('too_many_attempts');
    expect(await active('password')).toBe(0);
  });

  it('fremde und unbekannte Challenges antworten gleich (challenge_invalid)', async () => {
    const { c } = await setup();
    const inv = await c.post('/api/v1/invites', { role: 'parent' });
    const member = await world.registerPasskey(inv.json.invite.token, { email: 'eltern@example.org' });
    const mine = await member.client.post('/api/v1/me/password/start', { password: PW });
    expect(mine.status).toBe(200);
    const code = await world.totp(mine.json.totpSecret);
    const stolen = await c.post('/api/v1/me/password/complete', { challengeId: mine.json.challengeId, code });
    const unknown = await c.post('/api/v1/me/password/complete', { challengeId: '00000000-0000-4000-8000-000000000000', code });
    expect(stolen.status).toBe(400);
    expect(stolen.json).toEqual(unknown.json);
    expect(stolen.json.error).toBe('challenge_invalid');
    // die Challenge der Person bleibt unberührt gültig
    expect((await member.client.post('/api/v1/me/password/complete', { challengeId: mine.json.challengeId, code })).status).toBe(200);
  });

  it('neuer Start ersetzt den alten; Doppel-Abschluss legt nur eine Anmeldeart an; danach 409 password_exists', async () => {
    const { a, c } = await setup();
    const s1 = await c.post('/api/v1/me/password/start', { password: PW });
    const s2 = await c.post('/api/v1/me/password/start', { password: PW });
    world.advance(31_000);
    expect((await c.post('/api/v1/me/password/complete', { challengeId: s1.json.challengeId, code: await world.totp(s1.json.totpSecret) })).json.error).toBe('challenge_invalid');
    const code = await world.totp(s2.json.totpSecret);
    const two = await Promise.all([1, 2].map(() => c.post('/api/v1/me/password/complete', { challengeId: s2.json.challengeId, code })));
    // der zweite scheitert an der eingelösten Challenge (400) oder am schon verbrauchten Step-up (403)
    expect(two.map((r) => r.status).sort()[0]).toBe(200);
    expect([400, 403]).toContain(two.map((r) => r.status).sort()[1]);
    expect(await active('password')).toBe(1);
    expect(await active('totp')).toBe(1);
    await reStepUp(c, a);
    const again = await c.post('/api/v1/me/password/start', { password: PW2 });
    expect([again.status, again.json.error]).toEqual([409, 'password_exists']);
  });

  it('ändert das Passwort: neues gilt, altes nicht mehr, TOTP bleibt', async () => {
    const { a, c } = await setup();
    const { secret } = await addPassword(c);
    await reStepUp(c, a);
    expect((await c.post('/api/v1/me/password/change', { password: 'kurz' })).json.error).toBe('weak_password');
    expect((await c.post('/api/v1/me/password/change', { password: PW2 })).status).toBe(200);
    expect(await active('password')).toBe(1);
    world.advance(31_000);
    const old = await world.client('203.0.113.142').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(secret) });
    expect(old.status).toBe(401);
    world.advance(31_000);
    const neu = await world.client('203.0.113.143').post('/api/v1/auth/login/password', { email: a.email, password: PW2, totp: await world.totp(secret) });
    expect(neu.status).toBe(200);
    expect(await auditEvents(world)).toContain('password_changed');
  });

  it('Ändern und Entfernen ohne Passwort: 409 no_password', async () => {
    const { c } = await setup();
    expect((await c.post('/api/v1/me/password/change', { password: PW })).json.error).toBe('no_password');
    expect((await c.del('/api/v1/me/password')).json.error).toBe('no_password');
  });

  it('entfernt Passwort und TOTP, wenn ein Passkey bleibt; danach erneut hinzufügbar', async () => {
    const { a, c } = await setup();
    const { secret } = await addPassword(c);
    await reStepUp(c, a);
    expect((await c.del('/api/v1/me/password')).status).toBe(200);
    expect(await active('password')).toBe(0);
    expect(await active('totp')).toBe(0);
    expect(await active('passkey')).toBe(1);
    world.advance(31_000);
    expect((await world.client('203.0.113.144').post('/api/v1/auth/login/password', { email: a.email, password: PW, totp: await world.totp(secret) })).status).toBe(401);
    expect(await auditEvents(world)).toContain('password_removed');
    await reStepUp(c, a);
    expect((await addPassword(c, PW2)).done?.status).toBe(200);
  });

  it('entfernt das Passwort nicht, wenn es die einzige Anmeldeart wäre', async () => {
    const a = await adminPassword(world);
    const res = await a.client.del('/api/v1/me/password');
    expect([res.status, res.json.error]).toEqual([409, 'last_credential']);
    expect(await active('password')).toBe(1);
    expect(await active('totp')).toBe(1);
  });

  it('den letzten Passkey zu entfernen ist möglich, sobald ein Passwort da ist', async () => {
    const { a, c } = await setup();
    await addPassword(c);
    await reStepUp(c, a);
    const list = (await c.get('/api/v1/me/credentials')).json.credentials as Array<{ id: string; type: string }>;
    const pk = list.find((x) => x.type === 'passkey');
    expect((await c.del(`/api/v1/me/passkeys/${pk?.id}`)).status).toBe(200);
  });

  it('beendet nach Hinzufügen, Ändern und Entfernen alle anderen Sitzungen, die aktuelle bleibt', async () => {
    const { a, c } = await setup();
    const other = world.client('203.0.113.150');
    await world.loginPasskey(other, a.authenticator);
    expect((await other.get('/api/v1/me')).status).toBe(200);
    await addPassword(c);
    expect((await other.get('/api/v1/me')).status).toBe(401);
    expect((await c.get('/api/v1/me')).status).toBe(200);
    const actions = [() => c.post('/api/v1/me/password/change', { password: PW2 }), () => c.del('/api/v1/me/password')];
    for (const [i, act] of actions.entries()) {
      const o = world.client(`203.0.113.15${i + 1}`);
      await world.loginPasskey(o, a.authenticator);
      await reStepUp(c, a);
      expect((await act()).status).toBe(200);
      expect((await o.get('/api/v1/me')).status).toBe(401);
      expect((await c.get('/api/v1/me')).status).toBe(200);
    }
    expect(await liveSessions()).toBe(1);
  });

  it('verbraucht das Step-up erst nach Abschluss, nicht nach dem Start; Folgeaktionen brauchen ein neues', async () => {
    const { a, c } = await setup();
    expect((await c.post('/api/v1/me/password/start', { password: PW })).status).toBe(200);
    // Start verbraucht nichts: ein zweiter Start und der Abschluss gehen ohne neues Step-up
    const s2 = await c.post('/api/v1/me/password/start', { password: PW });
    expect(s2.status).toBe(200);
    world.advance(31_000);
    expect((await c.post('/api/v1/me/password/complete', { challengeId: s2.json.challengeId, code: await world.totp(s2.json.totpSecret) })).status).toBe(200);
    for (const r of [await c.post('/api/v1/me/password/change', { password: PW2 }), await c.del('/api/v1/me/password'), await c.post('/api/v1/me/password/start', { password: PW2 })]) {
      expect(r.status).toBe(403);
      expect(r.json.error).toBe('step_up_required');
    }
    await reStepUp(c, a);
    expect((await c.post('/api/v1/me/password/change', { password: PW2 })).status).toBe(200);
    expect((await c.del('/api/v1/me/password')).json.error).toBe('step_up_required');
    await reStepUp(c, a);
    expect((await c.del('/api/v1/me/password')).status).toBe(200);
    expect((await c.post('/api/v1/me/password/start', { password: PW })).json.error).toBe('step_up_required');
  });

  it('falsche Einrichtungscodes zählen nur gegen den eigenen Schlüssel und schreiben password_setup_failed', async () => {
    const { c } = await setup();
    const start = await c.post('/api/v1/me/password/start', { password: PW });
    for (let i = 0; i < 5; i++) expect((await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: '000000' })).status).toBe(400);
    expect((await auditEvents(world)).filter((e) => e === 'password_setup_failed')).toHaveLength(5);
    // Anmelde-Schlüssel (IP, Konto, Paar) blieben unberührt: nur der Einrichtungsschlüssel hat Einträge
    const keys = (await harness.db.select().from(schema.loginAttempts)).map((r) => r.key);
    expect(keys).toHaveLength(1);
    expect(keys[0]).toMatch(/^pwsetup:/);
  });

  it('abgelaufene Challenge bei frischem Step-up: challenge_invalid', async () => {
    const { a, c } = await setup();
    const start = await c.post('/api/v1/me/password/start', { password: PW });
    world.advance(6 * MIN);
    await reStepUp(c, a);
    const res = await c.post('/api/v1/me/password/complete', { challengeId: start.json.challengeId, code: await world.totp(start.json.totpSecret) });
    expect([res.status, res.json.error]).toEqual([400, 'challenge_invalid']);
    expect(await active('password')).toBe(0);
  });

  it('Entfernen räumt offene Einrichtungsvorgänge weg', async () => {
    const { a, c } = await setup();
    await addPassword(c);
    const [user] = await harness.db.select().from(schema.users);
    await harness.db.insert(schema.webauthnChallenges).values({
      purpose: 'add_password',
      challenge: 'x',
      userId: user!.id,
      data: {},
      createdAt: world.now(),
      expiresAt: new Date(world.clock + 5 * MIN),
    });
    await reStepUp(c, a);
    expect((await c.del('/api/v1/me/password')).status).toBe(200);
    expect(await harness.db.select().from(schema.webauthnChallenges).where(eq(schema.webauthnChallenges.purpose, 'add_password'))).toHaveLength(0);
  });

  it('parallel ändern und entfernen: kein halber Zustand (Passwort und TOTP gemeinsam da oder weg)', async () => {
    const { a, c } = await setup();
    await addPassword(c);
    await reStepUp(c, a);
    const res = await Promise.all([c.post('/api/v1/me/password/change', { password: PW2 }), c.del('/api/v1/me/password')]);
    // der zweite Aufruf scheitert je nach Reihenfolge an no_password (409) oder am verbrauchten Step-up (403)
    for (const r of res) expect([200, 403, 409]).toContain(r.status);
    expect(res.some((r) => r.status === 200)).toBe(true);
    expect(await active('password')).toBe(await active('totp'));
    expect(await active('passkey')).toBe(1);
  });

  it('parallel zweimal ändern: genau ein aktives Passwort', async () => {
    const { a, c } = await setup();
    await addPassword(c);
    await reStepUp(c, a);
    const res = await Promise.all([c.post('/api/v1/me/password/change', { password: PW2 }), c.post('/api/v1/me/password/change', { password: PW })]);
    expect(res.some((r) => r.status === 200)).toBe(true);
    for (const r of res) expect([200, 403]).toContain(r.status);
    expect(await active('password')).toBe(1);
  });
});
