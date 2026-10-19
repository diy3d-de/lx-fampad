// Familienrolle: reine Anzeige (Rechte, Sichtbarkeit und Sync bleiben unberührt); Berechtigung, Familiengrenze, Validierung.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, auditEvents, backends, World, type Harness } from './helpers.js';

describe.each(backends)('Familienrolle ($name)', (backend) => {
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

  async function ids(a: Awaited<ReturnType<typeof adminPassword>>) {
    const members = (await a.client.get('/api/v1/members')).json.members as Array<{ id: string; email?: string }>;
    const byMail = (mail: string) => members.find((m) => m.email === mail)?.id as string;
    return { byMail };
  }

  it('ist ohne Wert null (Altdaten) in /me und /members', async () => {
    const a = await adminPassword(world);
    expect((await a.client.get('/api/v1/me')).json.user.familyRole).toBeNull();
    const list = (await a.client.get('/api/v1/members')).json.members as Array<{ familyRole: unknown }>;
    expect(list.every((m) => m.familyRole === null)).toBe(true);
  });

  it('Admin trägt sich selbst als Elternteil ein; Rolle und Rechte bleiben admin', async () => {
    const a = await adminPassword(world);
    const res = await a.client.put('/api/v1/me/family-role', { familyRole: 'elternteil' });
    expect(res.status).toBe(200);
    const me = (await a.client.get('/api/v1/me')).json.user;
    expect(me).toMatchObject({ role: 'admin', familyRole: 'elternteil' });
    const mit = (await a.client.get('/api/v1/members')).json.members as Array<{ role: string; familyRole: string }>;
    expect(mit[0]).toMatchObject({ role: 'admin', familyRole: 'elternteil' });
    // zurücksetzen
    expect((await a.client.put('/api/v1/me/family-role', { familyRole: null })).status).toBe(200);
    expect((await a.client.get('/api/v1/me')).json.user.familyRole).toBeNull();
  });

  it('ein Kind setzt nur die eigene Familienrolle, nicht die anderer (403) und sieht die der anderen', async () => {
    const a = await adminPassword(world);
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    const { byMail } = await ids(a);
    const adminId = byMail(a.email);
    const kindId = byMail('kind@example.org');
    expect((await kind.client.put('/api/v1/me/family-role', { familyRole: 'kind' })).status).toBe(200);
    expect((await kind.client.put(`/api/v1/members/${adminId}/family-role`, { familyRole: 'kind' })).status).toBe(403);
    expect((await kind.client.put(`/api/v1/members/${kindId}/family-role`, { familyRole: 'sonstige' })).status).toBe(200); // eigene ID erlaubt
    expect((await a.client.put(`/api/v1/members/${adminId}/family-role`, { familyRole: 'vater' })).status).toBe(200);
    const sicht = (await kind.client.get('/api/v1/members')).json.members as Array<{ id: string; familyRole: string; email?: string }>;
    expect(sicht.find((m) => m.id === adminId)?.familyRole).toBe('vater');
    expect(sicht.find((m) => m.id === kindId)?.familyRole).toBe('sonstige');
    // gekürzte Zeile für Nicht-Admins: familyRole bleibt, E-Mail der anderen fehlt
    expect(sicht.find((m) => m.id === adminId)).not.toHaveProperty('email');
  });

  it('Admin setzt die Familienrolle anderer Mitglieder; das Audit-Ereignis enthält nur ID und festen Wert', async () => {
    const a = await adminPassword(world);
    const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
    const { byMail } = await ids(a);
    const mamaId = byMail('mama@example.org');
    const res = await a.client.put(`/api/v1/members/${mamaId}/family-role`, { familyRole: 'mutter' });
    expect(res.status).toBe(200);
    expect((await mama.client.get('/api/v1/me')).json.user).toMatchObject({ role: 'parent', familyRole: 'mutter' });
    expect(await auditEvents(world)).toContain('family_role_set');
    const audit = (await harness.db.select().from(schema.auditLog).where(eq(schema.auditLog.event, 'family_role_set')))[0];
    expect(audit?.detail).toEqual({ target: mamaId, to: 'mutter' });
  });

  it('ungültige Werte, fehlende und zusätzliche Felder ergeben 400, die Datenbank bleibt unverändert', async () => {
    const a = await adminPassword(world);
    for (const body of [{ familyRole: 'admin' }, { familyRole: '' }, { familyRole: 'Vater' }, { familyRole: 5 }, {}, { familyRole: 'vater', role: 'admin' }]) {
      const res = await a.client.put('/api/v1/me/family-role', body);
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
    expect((await a.client.get('/api/v1/me')).json.user.familyRole).toBeNull();
  });

  it('die Datenbank erzwingt die feste Liste (CHECK)', async () => {
    await adminPassword(world);
    await expect(harness.db.update(schema.memberships).set({ familyRole: 'chef' })).rejects.toThrow();
    await harness.db.update(schema.memberships).set({ familyRole: 'grosseltern' });
  });

  it('Familiengrenze: fremde Mitglieder ergeben 404, nichts wird verändert (IDOR)', async () => {
    const a = await adminPassword(world);
    const [fam] = await harness.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning();
    const [user] = await harness.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'Fremd' }).returning();
    if (!fam || !user) throw new Error('Setup');
    await harness.db.insert(schema.memberships).values({ familyId: fam.id, userId: user.id, role: 'admin' });
    const res = await a.client.put(`/api/v1/members/${user.id}/family-role`, { familyRole: 'vater' });
    expect(res.status).toBe(404);
    const [m] = await harness.db.select().from(schema.memberships).where(eq(schema.memberships.userId, user.id));
    expect(m?.familyRole).toBeNull();
    expect((await a.client.put('/api/v1/members/00000000-0000-4000-8000-000000000000/family-role', { familyRole: 'vater' })).status).toBe(404);
  });

  it('Rate-Limit: beide Routen strikt (11. Anfrage je Route und IP gibt 429)', async () => {
    const strict = await World.create(harness.db, { AUTH_RATE_LIMIT_MAX: '10', RATE_LIMIT_MAX: '1000' });
    try {
      const a = await adminPassword(strict);
      const { byMail } = await ids(a);
      const adminId = byMail(a.email);
      for (const url of ['/api/v1/me/family-role', `/api/v1/members/${adminId}/family-role`]) {
        const codes: number[] = [];
        for (let i = 0; i < 11; i++) codes.push((await a.client.put(url, { familyRole: 'vater' })).status);
        expect(codes, url).toEqual([...Array(10).fill(200), 429]);
      }
    } finally {
      await strict.close();
    }
  });

  it('ohne Anmeldung 401', async () => {
    await adminPassword(world);
    expect((await world.client('203.0.113.77').put('/api/v1/me/family-role', { familyRole: 'vater' })).status).toBe(401);
  });
});
