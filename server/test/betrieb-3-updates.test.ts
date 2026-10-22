// Betrieb Paket 3, Teil D (Update-Stand): Geräte melden ihre App-Version (`PUT /me/device-info`, streng geprüft), die Betreiber-Ansicht zählt Geräte auf älterer Version
// (Übersicht nur Zähler, je Person in der Mitgliederseite) gegen die neueste veröffentlichte Android-Version und die Mindestversion. Geprüft werden die reine Logik, die Rechte,
// die Familiengrenze, die strenge Eingabe und dass nie mehr als Zahlen, Stände und Namen (mit Step-up) herauskommen.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import type { Probes } from '../src/operator/probes.js';
import { grantOperator } from '../src/operator/service.js';
import { appStateOf, compareVersions, emptyUpdates, isReportableVersion, parseVersion } from '../src/operator/update-status.js';
import { addMember, adminPassword, backends, World, type Client, type Harness } from './helpers.js';

const DAY = 24 * 3_600_000;
const ENV = { MIN_APP_VERSION: '0.4.0' };
const NOW = new Date('2026-10-20T08:00:00Z');

describe('Update-Stand (rein)', () => {
  it('parseVersion: x.y.z (mit optionalem +Build), alles andere ist null', () => {
    expect(parseVersion('0.7.0')).toEqual([0, 7, 0]);
    expect(parseVersion('1.12.345+7000')).toEqual([1, 12, 345]);
    for (const k of ['', '1.2', '1.2.3.4', 'v1.2.3', '1.2.3-beta', '1.2.x', ' 1.2.3', '12345.1.1', '1.2.3+', null, undefined]) expect(parseVersion(k as string), String(k)).toBeNull();
  });

  it('compareVersions vergleicht Zahlen, nicht Texte (0.10.0 ist neuer als 0.9.0)', () => {
    expect(compareVersions([0, 10, 0], [0, 9, 0])).toBe(1);
    expect(compareVersions([0, 7, 0], [0, 7, 0])).toBe(0);
    expect(compareVersions([0, 6, 9], [0, 7, 0])).toBe(-1);
    expect(compareVersions([1, 0, 0], [0, 99, 99])).toBe(1);
  });

  it('isReportableVersion: nur x.y.z, keine Zusätze', () => {
    expect(isReportableVersion('0.7.0')).toBe(true);
    for (const k of ['0.7.0+7000', '0.7', '0.7.0-rc1', 'abc', '0.7.0; drop table', '', '0.7.0\n']) expect(isReportableVersion(k), k).toBe(false);
  });

  const dev = (over: Partial<{ platform: string; appVersion: string | null; lastSeenAt: Date | null }> = {}) => ({ platform: 'android', appVersion: '0.7.0', lastSeenAt: new Date(NOW.getTime() - DAY), ...over });

  it('appStateOf: aktuell, veraltet, unter Mindestversion, inaktiv, unbekannt; Web und andere ohne Verfolgung', () => {
    const s = (d: ReturnType<typeof dev>, ref: string | null = '0.7.0', min = '0.4.0') => appStateOf(d, ref, min, NOW);
    expect(s(dev())).toBe('current');
    expect(s(dev({ appVersion: '0.8.0' }))).toBe('current'); // neuer als die Referenz (Vorab-Build)
    expect(s(dev({ appVersion: '0.6.1' }))).toBe('outdated');
    expect(s(dev({ appVersion: '0.4.0' }))).toBe('outdated'); // genau die Mindestversion ist erlaubt
    expect(s(dev({ appVersion: '0.3.9' }))).toBe('below_min');
    expect(s(dev({ appVersion: null }))).toBe('unknown');
    expect(s(dev({ appVersion: 'komisch' }))).toBe('unknown');
    expect(s(dev({ lastSeenAt: new Date(NOW.getTime() - 91 * DAY), appVersion: '0.1.0' }))).toBe('inactive');
    expect(s(dev({ lastSeenAt: new Date(NOW.getTime() - 90 * DAY) }))).toBe('current');
    expect(s(dev({ lastSeenAt: null }))).toBe('inactive');
    expect(s(dev({ platform: 'web', appVersion: null }))).toBeNull();
    expect(s(dev({ platform: 'ios' }))).toBeNull();
    // ohne lesbare Referenz nie "veraltet", aber die Mindestversion gilt weiter
    expect(s(dev({ appVersion: '0.6.1' }), null)).toBe('current');
    expect(s(dev({ appVersion: '0.3.9' }), null)).toBe('below_min');
    expect(s(dev({ appVersion: '0.6.1' }), 'kaputt')).toBe('current');
  });

  it('emptyUpdates: ungültige Referenz wird nicht weitergegeben', () => {
    expect(emptyUpdates('kaputt', '0.1.0').reference).toBeNull();
    expect(emptyUpdates('0.7.0', '0.1.0').reference).toBe('0.7.0');
  });
});

describe.each(backends)('Betrieb Paket 3, Update-Stand ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let manifest: string | null;
  const probes: Probes = {
    readText: async (p) => (p.endsWith('latest.json') ? manifest : null),
    disk: async () => null,
    karteBytes: async () => null,
    tlsValidTo: async () => null,
    ntfyReachable: async () => true,
  };
  const release = (version: string) => JSON.stringify({ payload: JSON.stringify({ version, versionCode: 7000, minVersion: '0.1.0', url: 'https://x/geheim.apk' }), signature: 'AAAA' });

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
    manifest = release('0.7.0');
    world = await World.create(harness.db, ENV, { operatorProbes: probes });
  });

  type Person = Awaited<ReturnType<typeof addMember>> | Awaited<ReturnType<typeof adminPassword>>;
  const idOf = async (p: Person) => (await p.client.get('/api/v1/me')).json.user.id as string;
  const familyId = async () => (await world.db.select().from(schema.families))[0]!.id;
  async function stepUp(p: Person) {
    world.advance(31_000);
    expect((await p.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(p.totpSecret) })).status).toBe(200);
  }
  async function geraet(userId: string, name: string, over: Partial<typeof schema.devices.$inferInsert> = {}) {
    await world.db.insert(schema.devices).values({ familyId: await familyId(), userId, name, platform: 'android', appVersion: '0.7.0', lastSeenAt: new Date(world.clock - DAY), ...over });
  }
  async function familie() {
    const a = await adminPassword(world);
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    await grantOperator(world.auth.ctx, a.email);
    return { a, eltern, kind };
  }
  const status = async (c: Client) => (await c.get('/api/v1/admin/status?fresh=1')).json;

  it('PUT /me/device-info: nur das eigene Gerät, nur x.y.z; ungültige Angaben 400; ohne Sitzung 401; abgemeldet 401', async () => {
    const { a, kind } = await familie();
    expect((await world.client().put('/api/v1/me/device-info', { appVersion: '0.7.0' })).status).toBe(401);
    for (const body of [{}, { appVersion: '' }, { appVersion: '0.7' }, { appVersion: 'v0.7.0' }, { appVersion: '0.7.0-rc1' }, { appVersion: '0.7.0+7000' }, { appVersion: 7 }, { appVersion: null }, { appVersion: '0.7.0', geheim: 'x' }, { appVersion: '1'.repeat(40) + '.0.0' }, { appVersion: '0.7.0; drop table devices' }]) {
      expect((await a.client.put('/api/v1/me/device-info', body)).status, JSON.stringify(body)).toBe(400);
    }
    expect((await a.client.put('/api/v1/me/device-info', { appVersion: '0.6.1' })).json).toEqual({ ok: true });
    const mein = (await world.db.select().from(schema.devices).where(eq(schema.devices.userId, await idOf(a))))[0]!;
    expect(mein.appVersion).toBe('0.6.1');
    // andere Personen bleiben unberührt
    const fremd = await world.db.select().from(schema.devices).where(eq(schema.devices.userId, await idOf(kind)));
    expect(fremd.every((d) => d.appVersion !== '0.6.1')).toBe(true);
    expect((await a.client.post('/api/v1/auth/logout')).status).toBe(200);
    expect((await a.client.put('/api/v1/me/device-info', { appVersion: '0.7.0' })).status).toBe(401);
  });

  it('Übersicht: Zähler je Stand, Referenz aus dem Manifest, nur Zahlen (keine Namen, keine Gerätenamen)', async () => {
    const { a, eltern, kind } = await familie();
    const [ida, ide, idk] = [await idOf(a), await idOf(eltern), await idOf(kind)];
    // vorhandene Geräte der Anmeldungen (Web, ohne Verfolgung) bleiben außen vor
    await geraet(ida, 'Annas Handy', { appVersion: '0.7.0' }); // aktuell
    await geraet(ide, 'Mamas Handy GEHEIMNAME', { appVersion: '0.6.1' }); // veraltet
    await geraet(ide, 'Mamas Tablet', { appVersion: '0.3.0' }); // unter Mindestversion 0.4.0
    await geraet(idk, 'Kinderhandy', { appVersion: null }); // unbekannt
    await geraet(idk, 'Altgerät', { appVersion: '0.2.0', lastSeenAt: new Date(world.clock - 120 * DAY) }); // inaktiv
    const s = await status(a.client);
    expect(s.updates).toMatchObject({
      reference: '0.7.0',
      minAppVersion: '0.4.0',
      android: { total: 5, current: 1, outdated: 1, belowMin: 1, inactive: 1, unknown: 1 },
      personsBehind: 1,
    });
    expect(s.updates.otherDevices).toBeGreaterThanOrEqual(3); // die Web-Geräte der drei Anmeldungen
    expect(JSON.stringify(s.updates)).not.toMatch(/GEHEIMNAME|Annas|Mama|Kinder|@example/);
    expect(Object.keys(s.updates).sort()).toEqual(['android', 'minAppVersion', 'otherDevices', 'personsBehind', 'reference']);
  });

  it('ohne lesbares Manifest: keine Referenz, nie "veraltet", aber die Mindestversion zählt', async () => {
    const { a, eltern } = await familie();
    await geraet(await idOf(eltern), 'Mamas Handy', { appVersion: '0.6.1' });
    await geraet(await idOf(eltern), 'Mamas Tablet', { appVersion: '0.3.0' });
    manifest = null;
    const s = await status(a.client);
    expect(s.updates.reference).toBeNull();
    expect(s.updates.android).toMatchObject({ total: 2, current: 1, outdated: 0, belowMin: 1 });
    manifest = '{"kaputt":';
    world.advance(20_000);
    expect((await status(a.client)).updates.reference).toBeNull();
  });

  it('Mitgliederseite: Stand je Gerät und Zahl der Geräte auf älterer Version je Person (mit Step-up)', async () => {
    const { a, eltern, kind } = await familie();
    const ide = await idOf(eltern);
    await geraet(ide, 'Mamas Handy', { appVersion: '0.6.1' });
    await geraet(ide, 'Mamas Tablet', { appVersion: '0.7.0' });
    await geraet(await idOf(kind), 'Kinderhandy', { appVersion: '0.3.0' });
    world.advance(6 * 60_000);
    expect((await a.client.get('/api/v1/admin/members')).status).toBe(403);
    await stepUp(a);
    const m = (await a.client.get('/api/v1/admin/members')).json.members as Array<{ userId: string; devicesBehind: number; devices: Array<{ name: string; appState: string | null }> }>;
    const mama = m.find((x) => x.userId === ide)!;
    expect(mama.devicesBehind).toBe(1);
    expect(Object.fromEntries(mama.devices.map((d) => [d.name, d.appState]))).toMatchObject({ 'Mamas Handy': 'outdated', 'Mamas Tablet': 'current' });
    expect(m.find((x) => x.userId !== ide && x.devices.some((d) => d.name === 'Kinderhandy'))!.devicesBehind).toBe(1);
    // Web-Geräte der Anmeldungen: keine Verfolgung
    const web = m.flatMap((x) => x.devices).filter((d) => d.appState === null);
    expect(web.length).toBeGreaterThan(0);
  });

  it('Rechte und Familiengrenze: nur der Betreiber (alle anderen 404, ohne Sitzung 401); Geräte einer fremden Familie zählen nie', async () => {
    const { a, eltern, kind } = await familie();
    expect((await world.client().get('/api/v1/admin/status')).status).toBe(401);
    for (const c of [eltern.client, kind.client]) expect((await c.get('/api/v1/admin/status')).status).toBe(404);
    const [fam] = await world.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning({ id: schema.families.id });
    const [u] = await world.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'Fremd' }).returning({ id: schema.users.id });
    await world.db.insert(schema.memberships).values({ familyId: fam!.id, userId: u!.id, role: 'admin' });
    await world.db.insert(schema.devices).values({ familyId: fam!.id, userId: u!.id, name: 'Fremdgerät', platform: 'android', appVersion: '0.1.0', lastSeenAt: new Date(world.clock) });
    expect((await status(a.client)).updates.android.total).toBe(0);
    // ein nicht mehr aktives Mitglied zählt nicht mehr
    await geraet(await idOf(kind), 'Kinderhandy', { appVersion: '0.6.1' });
    world.advance(20_000);
    expect((await status(a.client)).updates.android.total).toBe(1);
    await world.db.update(schema.memberships).set({ status: 'pending' }).where(eq(schema.memberships.userId, await idOf(kind)));
    world.advance(20_000);
    expect((await status(a.client)).updates.android.total).toBe(0);
  });
});
