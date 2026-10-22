// Betreiber-Ansicht, Paket 2a: Geräte melden den Schlüsselstand, Schlüssel-Ampel je Person, Seite "Mitglieder und Geräte" (mit Entsperren) und Push-Warnungen an den Betreiber.
// Geprüft wird: Rechte-Tabelle (nur Betreiber, alle anderen 404, ohne Sitzung 401), Step-up, Familiengrenze/IDOR, die Ampel in allen Kombinationen (mit Uhr), der Prüfer
// (Zustandswechsel, Entprellung, Neustart ohne Wiederholung, "unbekannt" ohne Alarm, Schalter) und dass weder Antworten noch Wecker Inhalte oder Geheimnisse tragen.
import { randomBytes } from 'node:crypto';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import { ampelOf, collectKeyStatus, overallAmpel, type Ampel, type Ways } from '../src/operator/key-status.js';
import { deviceKeyState } from '../src/operator/members.js';
import { ALERT_DEBOUNCE_MS, evaluateConditions, KEY_ALERT_GRACE_MS, OperatorMonitor } from '../src/operator/monitor.js';
import type { Probes } from '../src/operator/probes.js';
import { NAS_ABSENT } from '../src/operator/nas-status.js';
import { emptyUpdates } from '../src/operator/update-status.js';
import type { OperatorStatus } from '../src/operator/status.js';
import { grantOperator } from '../src/operator/service.js';
import { WAKE_BODY } from '../src/push/service.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const HOST = 'ntfy.familie.lx-labs.dev';
const GEHEIM = 'tk_geheimes-ntfy-token-123';
const ENV = { NTFY_URL: 'http://127.0.0.1:2586', NTFY_TOKEN: GEHEIM, OPERATOR_TLS_PROBE: '127.0.0.1:443', E2EE_PW_BACKUP: 'true' };
const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = { id: 'argon2id-v1', memKiB: 65536, ops: 3 };
const topic = (n: number) => `upWeckerTopic${String(n).padStart(2, '0')}`;

function probes(now: number, over: Partial<Probes> = {}): Partial<Probes> {
  return {
    readText: async (path) => {
      if (path.endsWith('backup.status')) return `last_result=ok\nlast_success_epoch=${Math.floor(now / 1000) - 5 * 3600}\ntotal_bytes=617472\n`;
      return null;
    },
    disk: async () => ({ totalBytes: 100, freeBytes: 59 }),
    karteBytes: async () => 1,
    tlsValidTo: async () => new Date(now + 85 * DAY),
    ntfyReachable: async () => true,
    ...over,
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------- reine Logik

describe('Schlüssel-Ampel (rein)', () => {
  const kombis: Array<[boolean, boolean, boolean, Ampel]> = [
    // Gerät, Passwort-Sicherung, Wiederherstellung -> Ampel
    [false, false, false, 'red'],
    [true, false, false, 'yellow'],
    [false, true, false, 'red'],
    [false, false, true, 'red'],
    [true, true, false, 'green'],
    [true, false, true, 'green'],
    [false, true, true, 'yellow'],
    [true, true, true, 'green'],
  ];
  it.each(kombis)('Gerät=%s Passwort-Sicherung=%s Wiederherstellung=%s -> %s', (device, pwBackup, recoveryBackup, erwartet) => {
    expect(ampelOf({ device, pwBackup, recoveryBackup }, true)).toBe(erwartet);
  });

  it('ohne Schlüssel ist die Person immer rot', () => {
    const alle: Ways = { device: true, pwBackup: true, recoveryBackup: true };
    expect(ampelOf(alle, false)).toBe('red');
  });

  it('Gesamtbild: schlechteste Ampel, bereit nur wenn alle grün (und es Mitglieder gibt)', () => {
    expect(overallAmpel(['green', 'green'])).toEqual({ overall: 'green', ready: true, counts: { green: 2, yellow: 0, red: 0 } });
    expect(overallAmpel(['green', 'yellow'])).toMatchObject({ overall: 'yellow', ready: false });
    expect(overallAmpel(['yellow', 'red', 'green'])).toMatchObject({ overall: 'red', ready: false, counts: { green: 1, yellow: 1, red: 1 } });
    expect(overallAmpel([])).toMatchObject({ overall: 'green', ready: false });
  });

  it('Gerätestand: gemeldete Version gegen die aktuelle, mit Frist von 30 Tagen', () => {
    const now = new Date('2026-10-20T08:00:00Z');
    const vor = (d: number) => new Date(now.getTime() - d * DAY);
    expect(deviceKeyState({ keyVersion: null, reportedAt: null }, 2, now)).toBe('unknown');
    expect(deviceKeyState({ keyVersion: 2, reportedAt: vor(1) }, 2, now)).toBe('current');
    expect(deviceKeyState({ keyVersion: 2, reportedAt: vor(31) }, 2, now)).toBe('stale');
    expect(deviceKeyState({ keyVersion: 1, reportedAt: vor(1) }, 2, now)).toBe('old');
    expect(deviceKeyState({ keyVersion: 0, reportedAt: vor(1) }, 2, now)).toBe('none');
    expect(deviceKeyState({ keyVersion: 3, reportedAt: vor(1) }, 2, now)).toBe('unknown');
    expect(deviceKeyState({ keyVersion: 2, reportedAt: vor(1) }, null, now)).toBe('unknown');
  });
});

describe('Warn-Bedingungen (rein)', () => {
  const now = new Date('2026-10-20T08:00:00Z');
  function status(over: Partial<OperatorStatus> = {}): OperatorStatus {
    return {
      generatedAt: now.toISOString(),
      overall: 'ok',
      unknownCount: 0,
      server: { version: '0.7.0', protocolVersion: 1, startedAt: now.toISOString(), uptimeSec: 1, memoryRssMb: 1 },
      database: { ok: true, latencyMs: 1, sizeBytes: 1, migrations: { applied: 1, expected: 1, latest: 'x', pending: false, grantMissing: false } },
      services: [{ id: 'ntfy', state: 'ok', detail: {} }],
      backup: { state: 'ok', lastSuccessAt: new Date(now.getTime() - 5 * HOUR).toISOString(), ageHours: 5, totalBytes: 1, lastResult: 'ok' },
      nas: NAS_ABSENT,
      updates: emptyUpdates(null, '0.1.0'),
      disk: { totalBytes: 100, freeBytes: 50, usedPercent: 50 },
      certificate: { validTo: new Date(now.getTime() + 60 * DAY).toISOString(), daysLeft: 60 },
      counts: { members: 1, devices: 1, pushDevices: 1, activeSessions: 1 },
      versions: { server: '0.7.0', web: null, app: null, minAppVersion: '0.1.0' },
      features: { pwBackup: true, legacyPasswordLogin: true, weather: false, push: true, map: { available: false, sizeBytes: null } },
      ...over,
    };
  }
  const erg = (s: OperatorStatus, fails: number | null = 0) => Object.fromEntries(evaluateConditions(s, fails, null, now).map((c) => [c.key, c.result]));

  it('alles in Ordnung: nichts aktiv', () => {
    const e = erg(status());
    // die Rückmeldung des NAS (Paket 3) ist ohne Einrichtung "unbekannt" und warnt nie
    expect(Object.entries(e).filter(([k]) => !k.startsWith('nas_')).every(([, r]) => r === 'ok')).toBe(true);
    expect(e).toMatchObject({ nas_pull: 'unknown', nas_restore: 'unknown' });
  });

  it('Grenzen: Zertifikat 14 Tage, Sicherung 36 Stunden, Platte 85 %, Anmeldungen 20 in 15 Minuten', () => {
    expect(erg(status({ certificate: { validTo: '', daysLeft: 14 } })).cert).toBe('ok');
    expect(erg(status({ certificate: { validTo: '', daysLeft: 13 } })).cert).toBe('active');
    expect(erg(status({ certificate: { validTo: '', daysLeft: -1 } })).cert).toBe('active');
    const b = (h: number) => status({ backup: { state: 'ok', lastSuccessAt: new Date(now.getTime() - h * HOUR).toISOString(), ageHours: h, totalBytes: 1, lastResult: 'ok' } });
    expect(erg(b(36)).backup).toBe('ok');
    expect(erg(b(37)).backup).toBe('active');
    expect(erg(status({ disk: { totalBytes: 100, freeBytes: 15, usedPercent: 85 } })).disk).toBe('ok');
    expect(erg(status({ disk: { totalBytes: 100, freeBytes: 14, usedPercent: 86 } })).disk).toBe('active');
    expect(erg(status(), 20).logins).toBe('ok');
    expect(erg(status(), 21).logins).toBe('active');
  });

  it('nicht messbar ist "unbekannt", nie "aktiv"', () => {
    const r = erg(
      status({
        certificate: null,
        disk: null,
        backup: { state: 'unknown', lastSuccessAt: null, ageHours: null, totalBytes: null, lastResult: null },
        services: [{ id: 'ntfy', state: 'off', detail: {} }],
      }),
      null,
    );
    expect(r).toMatchObject({ cert: 'unknown', disk: 'unknown', backup: 'unknown', ntfy: 'unknown', logins: 'unknown' });
  });

  it('Schlüssel: Karenz von 7 Tagen ohne Gerät mit gemeldeter Version; mit gemeldetem Gerät und rot sofort; nicht rot oder ohne Schlüssel nie', () => {
    const person = (userId: string, ampel: Ampel, devicesReported: number, hasKeys = true) =>
      ({ userId, displayName: userId, role: 'child', ampel, hasKeys, keyVersion: hasKeys ? 1 : null, ways: { device: false, pwBackup: false, recoveryBackup: false }, wayCount: 0, devicesTotal: 1, devicesWithKey: 0, devicesReported, legacyPassword: false, archiveCount: 0, events: [] }) as const;
    const keys = { generatedAt: '', overall: 'red', ready: false, counts: { green: 0, yellow: 0, red: 3 }, persons: [person('a', 'red', 0), person('b', 'red', 1), person('c', 'yellow', 1), person('d', 'red', 0, false)] } as const;
    const c = Object.fromEntries(evaluateConditions(status(), 0, keys as never, now).filter((x) => x.kind === 'key').map((x) => [x.key, x]));
    expect(c['key:a']).toMatchObject({ result: 'active', graceMs: KEY_ALERT_GRACE_MS });
    expect(c['key:b']).toMatchObject({ result: 'active', graceMs: 0 });
    expect(c['key:c']).toMatchObject({ result: 'ok', graceMs: 0 });
    expect(c['key:d']).toBeUndefined();
    expect(KEY_ALERT_GRACE_MS).toBe(7 * DAY);
  });

  it('Datenbank und ntfy nicht erreichbar sind aktiv; ein gemeldeter Fehlschlag ohne je einen Erfolg ebenfalls', () => {
    expect(erg(status({ database: { ok: false, latencyMs: null, sizeBytes: null, migrations: { applied: null, expected: null, latest: null, pending: null, grantMissing: false } } })).database).toBe('active');
    expect(erg(status({ services: [{ id: 'ntfy', state: 'error', detail: {} }] })).ntfy).toBe('active');
    expect(erg(status({ backup: { state: 'error', lastSuccessAt: null, ageHours: null, totalBytes: null, lastResult: 'fehler' } })).backup).toBe('active');
  });
});

// ---------------------------------------------------------------------------------------------------------------------------------- mit Datenbank

describe.each(backends)('Betreiber Paket 2a ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let aktuell: Partial<Probes>;
  const umschaltbar: Probes = {
    readText: (p, m) => aktuell.readText!(p, m),
    disk: (p) => aktuell.disk!(p),
    karteBytes: (d) => aktuell.karteBytes!(d),
    tlsValidTo: (x, s) => aktuell.tlsValidTo!(x, s),
    ntfyReachable: (u) => aktuell.ntfyReachable!(u),
  };
  /** Aufgezeichnete Wecker: (Thema, Body, Methode). */
  let wecker: Array<{ topic: string; body: string; method: string }>;
  const fakeFetch: typeof fetch = async (url, init) => {
    wecker.push({ topic: String(url).split('/').pop() ?? '', body: String(init?.body ?? ''), method: String(init?.method ?? '') });
    return new Response('{}', { status: 200 });
  };

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
    wecker = [];
    world = await World.create(harness.db, ENV, { operatorProbes: umschaltbar, pushFetch: fakeFetch });
    aktuell = probes(world.clock);
  });

  type Person = Awaited<ReturnType<typeof addMember>> | Awaited<ReturnType<typeof adminPassword>>;
  const idOf = async (p: Person) => (await p.client.get('/api/v1/me')).json.user.id as string;

  /** Admin (Betreiber), zweiter Admin, Elternteil, Kind. */
  async function familie() {
    const a = await adminPassword(world);
    const zweiter = await addMember(world, a.client, 'admin', 'admin2@example.org');
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    await grantOperator(world.auth.ctx, a.email);
    return { a, zweiter, eltern, kind };
  }

  async function ersteSchluessel(c: Client): Promise<void> {
    expect((await c.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
  }
  const ampelOfUser = async (c: Client, id: string) => ((await c.get('/api/v1/admin/key-status')).json.persons as Array<{ userId: string; ampel: Ampel }>).find((p) => p.userId === id)?.ampel;
  async function stepUp(p: Person) {
    // derselbe TOTP-Zeitschritt wie bei der Anmeldung wird nicht zweimal angenommen (Replay-Schutz)
    world.advance(31_000);
    expect((await p.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(p.totpSecret) })).status).toBe(200);
  }

  // ---- Rechte ----

  const lesend = ['/api/v1/admin/key-status', '/api/v1/admin/key-status?summary=1', '/api/v1/admin/members', '/api/v1/admin/warnings'];

  it('Rechte-Tabelle: nur der Betreiber; Admin, Eltern, Kind 404; ohne Sitzung 401', async () => {
    const { a, zweiter, eltern, kind } = await familie();
    const zielId = await idOf(kind);
    const aufrufe: Array<[string, string, unknown?]> = [
      ...lesend.map((u): [string, string] => ['GET', u]),
      ['PUT', '/api/v1/admin/warnings', { enabled: false }],
      ['POST', `/api/v1/admin/members/${zielId}/unlock`, {}],
    ];
    for (const [m, u, body] of aufrufe) {
      expect((await world.client().request(m, u, body === undefined ? {} : { body })).status, `${m} ${u} ohne Sitzung`).toBe(401);
      for (const [name, c] of [['zweiter Admin', zweiter.client], ['Eltern', eltern.client], ['Kind', kind.client]] as const) {
        const res = await c.request(m, u, body === undefined ? {} : { body });
        expect(res.status, `${m} ${u} ${name}`).toBe(404);
        expect(res.json.error).toBe('not_found');
      }
    }
    for (const u of lesend) expect((await a.client.get(u)).status, u).toBe(200);
    // ein Nicht-Betreiber kann weder die Warnungen umschalten noch etwas entsperren, auch mit frischem Step-up
    await stepUp(zweiter);
    expect((await zweiter.client.put('/api/v1/admin/warnings', { enabled: false })).status).toBe(404);
    expect((await zweiter.client.post(`/api/v1/admin/members/${zielId}/unlock`, {})).status).toBe(404);
  });

  it('Step-up: Mitglieder, Entsperren und Warn-Schalter brauchen ihn, Ampel und Warn-Stand nicht', async () => {
    const { a, kind } = await familie();
    const zielId = await idOf(kind);
    world.advance(6 * MIN);
    for (const [m, u, body] of [['GET', '/api/v1/admin/members', undefined], ['PUT', '/api/v1/admin/warnings', { enabled: false }], ['POST', `/api/v1/admin/members/${zielId}/unlock`, {}]] as const) {
      const res = await a.client.request(m, u, body === undefined ? {} : { body });
      expect(res.status, `${m} ${u}`).toBe(403);
      expect(res.json.error).toBe('step_up_required');
    }
    // die Einzelheiten je Person (Namen, Wege, Ereignisse) brauchen es, die Zusammenfassung (nur Zähler) nicht
    const voll = await a.client.get('/api/v1/admin/key-status');
    expect(voll.status).toBe(403);
    expect(voll.json.error).toBe('step_up_required');
    const kurz = await a.client.get('/api/v1/admin/key-status?summary=1');
    expect(kurz.status).toBe(200);
    expect(Object.keys(kurz.json).sort()).toEqual(['counts', 'generatedAt', 'overall', 'ready']);
    expect(JSON.stringify(kurz.json)).not.toMatch(/admin|kind|@/i);
    expect((await a.client.get('/api/v1/admin/key-status?summary=2')).status).toBe(400);
    expect((await a.client.get('/api/v1/admin/warnings')).status).toBe(200);
    await stepUp(a);
    expect((await a.client.get('/api/v1/admin/members')).status).toBe(200);
  });

  it('Familiengrenze: fremde Personen erscheinen nie und lassen sich nicht entsperren (404)', async () => {
    const { a } = await familie();
    // zweite Familie mit einer Person, einem Schlüssel und einem Gerät (direkt in der Datenbank)
    const [fam] = await world.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning({ id: schema.families.id });
    const [u] = await world.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'Fremd' }).returning({ id: schema.users.id });
    await world.db.insert(schema.memberships).values({ familyId: fam!.id, userId: u!.id, role: 'admin' });
    await world.db.insert(schema.personKeys).values({ userId: u!.id, publicEncKey: key(), publicSignKey: key() });
    await world.db.insert(schema.devices).values({ familyId: fam!.id, userId: u!.id, name: 'Fremdgerät', platform: 'android', keyVersion: 1, keyReportedAt: new Date(world.clock) });
    await stepUp(a);
    const mem = (await a.client.get('/api/v1/admin/members')).json.members as Array<{ userId: string; devices: Array<{ name: string }> }>;
    expect(mem.map((m) => m.userId)).not.toContain(u!.id);
    expect(JSON.stringify(mem)).not.toContain('Fremdgerät');
    const ks = (await a.client.get('/api/v1/admin/key-status')).json.persons as Array<{ userId: string }>;
    expect(ks.map((m) => m.userId)).not.toContain(u!.id);
    expect((await a.client.post(`/api/v1/admin/members/${u!.id}/unlock`, {})).status).toBe(404);
    expect((await a.client.post('/api/v1/admin/members/00000000-0000-4000-8000-000000000000/unlock', {})).status).toBe(404);
    expect((await a.client.post('/api/v1/admin/members/kein-uuid/unlock', {})).status).toBe(400);
    // aus Sicht der fremden Familie ist nur die eigene Person sichtbar
    const fremd = await collectKeyStatus(world.auth.ctx, fam!.id);
    expect(fremd.persons.map((p) => p.userId)).toEqual([u!.id]);
    expect(fremd.persons[0]).toMatchObject({ hasKeys: true, devicesWithKey: 1, ampel: 'yellow' });
  });

  // ---- Geräte melden den Schlüsselstand ----

  it('PUT /me/device-key: nur das eigene Gerät, nur eine Zahl; ungültige Angaben 400; ohne Sitzung 401', async () => {
    const { a, kind } = await familie();
    expect((await world.client().put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(401);
    for (const body of [{ keyVersion: -1 }, { keyVersion: 1.5 }, { keyVersion: '1' }, { keyVersion: 1_000_001 }, { keyVersion: 1, key: 'geheim' }, {}, { keyVersion: null }]) {
      expect((await a.client.put('/api/v1/me/device-key', body)).status, JSON.stringify(body)).toBe(400);
    }
    expect((await a.client.put('/api/v1/me/device-key', { keyVersion: 3 })).status).toBe(200);
    const rows = await world.db.select({ u: schema.devices.userId, v: schema.devices.keyVersion, at: schema.devices.keyReportedAt }).from(schema.devices);
    const eigene = rows.filter((r) => r.v !== null);
    expect(eigene).toHaveLength(1);
    expect(eigene[0]!.u).toBe(await idOf(a));
    expect(eigene[0]!.v).toBe(3);
    expect(eigene[0]!.at?.getTime()).toBe(world.clock);
    // 0 = "kein Schlüssel" und späteres Überschreiben
    expect((await a.client.put('/api/v1/me/device-key', { keyVersion: 0 })).status).toBe(200);
    expect((await world.db.select({ v: schema.devices.keyVersion }).from(schema.devices).where(eq(schema.devices.userId, await idOf(a))))[0]!.v).toBe(0);
    // andere Personen bleiben unberührt
    const kindId = await idOf(kind);
    expect(rows.filter((r) => r.u === kindId)[0]!.v).toBeNull();
  });

  it('abgemeldetes Gerät: Meldung 404/401, der Bestand zählt nicht', async () => {
    const { a } = await familie();
    expect((await a.client.post('/api/v1/auth/logout')).status).toBe(200);
    expect((await a.client.put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(401);
  });

  // ---- Ampel ----

  it('Ampel über die Wege: Gerät, Wiederherstellung, Passwort-Sicherung; Frist 30 Tage; Schlüsselwechsel entwertet', async () => {
    const { a, kind } = await familie();
    const kid = await idOf(kind);
    await ersteSchluessel(kind.client);
    // Schlüssel, aber nichts gemeldet und keine Sicherung: rot
    expect(await ampelOfUser(a.client, kid)).toBe('red');
    // nur ein Gerät: gelb
    expect((await kind.client.put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(200);
    expect(await ampelOfUser(a.client, kid)).toBe('yellow');
    // Gerät + Wiederherstellungssicherung: grün
    expect((await kind.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
    expect(await ampelOfUser(a.client, kid)).toBe('green');
    let p = (await a.client.get('/api/v1/admin/key-status')).json.persons.find((x: { userId: string }) => x.userId === kid);
    expect(p).toMatchObject({ hasKeys: true, keyVersion: 1, wayCount: 2, ways: { device: true, pwBackup: false, recoveryBackup: true }, devicesWithKey: 1, devicesTotal: 1 });
    // Gerät meldet "keinen Schlüssel": nur noch eine Sicherung ohne Gerät: rot
    expect((await kind.client.put('/api/v1/me/device-key', { keyVersion: 0 })).status).toBe(200);
    expect(await ampelOfUser(a.client, kid)).toBe('red');
    // zusätzlich bestätigte Passwort-Sicherung: zwei Sicherungen ohne Gerät: gelb
    const put = await kind.client.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf });
    expect(put.status).toBe(200);
    expect(await ampelOfUser(a.client, kid)).toBe('red'); // unbestätigt zählt nicht
    expect((await kind.client.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id })).status).toBe(200);
    expect(await ampelOfUser(a.client, kid)).toBe('yellow');
    // Gerät wieder mit Schlüssel: alles drei, grün
    await kind.client.put('/api/v1/me/device-key', { keyVersion: 1 });
    p = (await a.client.get('/api/v1/admin/key-status')).json.persons.find((x: { userId: string }) => x.userId === kid);
    expect(p).toMatchObject({ ampel: 'green', wayCount: 3 });
    // Bericht älter als 30 Tage: das Gerät zählt nicht mehr
    await world.db.update(schema.devices).set({ keyReportedAt: new Date(world.clock - 31 * DAY) }).where(eq(schema.devices.userId, kid));
    expect(await ampelOfUser(a.client, kid)).toBe('yellow');
    await kind.client.put('/api/v1/me/device-key', { keyVersion: 1 });
    expect(await ampelOfUser(a.client, kid)).toBe('green');
    // Schlüsselwechsel (Version 2): Sicherungen und Gerät gehören zur alten Version
    await world.db.update(schema.personKeys).set({ keyVersion: 2 }).where(eq(schema.personKeys.userId, kid));
    expect(await ampelOfUser(a.client, kid)).toBe('red');
    await kind.client.put('/api/v1/me/device-key', { keyVersion: 2 });
    expect(await ampelOfUser(a.client, kid)).toBe('yellow');
  });

  it('Gesamtbild: Mitglieder ohne Schlüssel sind rot; "bereit" erst, wenn alle grün sind; keine Geheimnisse in der Antwort', async () => {
    const { a, zweiter, eltern, kind } = await familie();
    for (const p of [a, zweiter, eltern, kind]) {
      await ersteSchluessel(p.client);
      await p.client.put('/api/v1/me/device-key', { keyVersion: 1 });
      await p.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
    }
    let ks = (await a.client.get('/api/v1/admin/key-status')).json;
    expect(ks).toMatchObject({ overall: 'green', ready: true, counts: { green: 4, yellow: 0, red: 0 } });
    // ein Kind ohne Sicherung: nicht bereit
    await world.db.delete(schema.keyBackups).where(eq(schema.keyBackups.userId, await idOf(kind)));
    ks = (await a.client.get('/api/v1/admin/key-status')).json;
    expect(ks).toMatchObject({ overall: 'yellow', ready: false, counts: { green: 3, yellow: 1, red: 0 } });
    const text = JSON.stringify(ks);
    for (const verboten of [GEHEIM, 'blob', 'publicEncKey', 'publicSignKey', 'secret', 'passwordhash', 'email', '@example.org', 'token']) {
      expect(text.toLowerCase(), verboten).not.toContain(verboten.toLowerCase());
    }
    expect(Object.keys(ks.persons[0]).sort()).toEqual(['ampel', 'archiveCount', 'devicesTotal', 'devicesReported', 'devicesWithKey', 'displayName', 'events', 'hasKeys', 'keyVersion', 'legacyPassword', 'role', 'userId', 'ways', 'wayCount'].sort());
  });

  it('Schlüsselereignisse (Art, Zeit) und Archiv-Anzahl erscheinen; altes Passwort-Verfahren wird gemeldet', async () => {
    const { a, kind } = await familie();
    const kid = await idOf(kind);
    await world.db.insert(schema.securityEvents).values({ familyId: (await world.db.select().from(schema.families))[0]!.id, userId: kid, kind: 'key_rotated', via: 'password', createdAt: new Date(world.clock - HOUR) });
    const p = (await a.client.get('/api/v1/admin/key-status')).json.persons.find((x: { userId: string }) => x.userId === kid);
    expect(p.events).toEqual([{ kind: 'key_rotated', at: new Date(world.clock - HOUR).toISOString() }]);
    expect(typeof p.legacyPassword).toBe('boolean');
    // die Registrierung per Passwort legt noch keinen authKey an: "legacy"
    expect(p.legacyPassword).toBe(true);
  });

  // ---- Mitglieder und Geräte ----

  it('Mitglieder und Geräte: Rolle, Geräte mit Schlüsselstand, letzte Anmeldung; nie E-Mail oder Geheimnisse', async () => {
    const { a, kind } = await familie();
    await stepUp(a);
    await ersteSchluessel(kind.client);
    await kind.client.put('/api/v1/me/device-key', { keyVersion: 1 });
    const res = await a.client.get('/api/v1/admin/members');
    expect(res.status).toBe(200);
    const m = res.json.members as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
    expect(m).toHaveLength(4);
    const k = m.find((x) => x.userId === (res.json.members.find((y: { role: string; displayName: string }) => y.displayName === 'kind')?.userId))!;
    expect(k).toMatchObject({ role: 'child', operator: false, you: false, hasKeys: true, ampel: 'yellow', locked: null });
    expect(k.devices).toHaveLength(1);
    expect(k.devices[0]).toMatchObject({ platform: 'web', keyState: 'current', keyVersion: 1 });
    expect(k.lastLoginAt).toBeTruthy();
    expect(k.credentials).toMatchObject({ passkeys: 0, password: true, totp: true });
    expect(m.find((x) => x.you)).toMatchObject({ role: 'admin', operator: true });
    const text = JSON.stringify(res.json).toLowerCase();
    for (const verboten of ['@example.org', GEHEIM.toLowerCase(), 'secret', 'hash', 'argon', 'token', 'blob']) expect(text, verboten).not.toContain(verboten);
    // ein Gerät ohne Bericht (alte App) heißt "unbekannt"
    const a0 = m.find((x) => x.you)!;
    expect(a0.devices[0].keyState).toBe('unknown');
  });

  it('Entsperren: das Konto wird nach Fehlversuchen gesperrt angezeigt, "Entsperren" hebt es auf und steht im Protokoll', async () => {
    const { a, kind } = await familie();
    await stepUp(a);
    const kid = await idOf(kind);
    // Fehlversuche mit dem Konto von verschiedenen Adressen, bis der Konto-Zähler sperrt
    for (let i = 0; i < 30; i++) {
      const c = world.client(`198.51.100.${i + 1}`);
      await c.post('/api/v1/auth/login/password', { email: 'kind@example.org', password: 'falsch-falsch-falsch-123', totp: '000000' });
    }
    let m = (await a.client.get('/api/v1/admin/members')).json.members.find((x: { userId: string }) => x.userId === kid);
    expect(m.locked).not.toBeNull();
    expect(m.locked.seconds).toBeGreaterThan(0);
    const res = await a.client.post(`/api/v1/admin/members/${kid}/unlock`, {});
    expect(res.status).toBe(200);
    expect(res.json).toEqual({ cleared: true });
    m = (await a.client.get('/api/v1/admin/members')).json.members.find((x: { userId: string }) => x.userId === kid);
    expect(m.locked).toBeNull();
    expect(await auditEvents(world)).toContain('operator_unlock');
    // zweites Mal: nichts mehr zu löschen, trotzdem kein Fehler
    expect((await a.client.post(`/api/v1/admin/members/${kid}/unlock`, {})).json).toEqual({ cleared: false });
  });

  // ---- Prüfer und Warnungen ----

  async function mitPush(p: Person, n: number) {
    expect((await p.client.put('/api/v1/me/push', { endpoint: `https://${HOST}/${topic(n)}?up=1` })).status).toBe(200);
  }
  const monitor = () => world.app.operatorMonitor!;
  const alerts = async () => (await auditEvents(world)).filter((e) => e.startsWith('operator_alert_'));

  it('ohne Probleme: kein Wecker; Warn-Stand leer und ohne Inhalt', async () => {
    const { a, eltern } = await familie();
    await mitPush(a, 1);
    await mitPush(eltern, 2);
    const r = await monitor().runOnce();
    expect(r.notified).toEqual([]);
    expect(wecker).toEqual([]);
    const w = (await a.client.get('/api/v1/admin/warnings')).json;
    expect(w).toMatchObject({ enabled: true, pushAvailable: true, active: [], lastNotifiedAt: null });
    expect(w.checkedAt).toBeTruthy();
  });

  it('Zertifikat bald ab: ein Wecker nur an die Geräte des Betreibers, fester Inhalt, Protokolleintrag, keine Wiederholung', async () => {
    const { a, zweiter, eltern } = await familie();
    await mitPush(a, 1);
    await mitPush(zweiter, 2);
    await mitPush(eltern, 3);
    aktuell = probes(world.clock, { tlsValidTo: async () => new Date(world.clock + 13 * DAY) });
    expect((await monitor().runOnce()).notified).toEqual(['cert']);
    expect(wecker).toEqual([{ topic: topic(1), body: WAKE_BODY, method: 'POST' }]);
    expect(await alerts()).toEqual(['operator_alert_cert']);
    // besteht weiter: nach 5, 30 Minuten und 7 Stunden keine Wiederholung
    for (const schritt of [5 * MIN, 25 * MIN, 7 * HOUR]) {
      world.advance(schritt);
      aktuell = probes(world.clock, { tlsValidTo: async () => new Date(world.clock + 13 * DAY) });
      expect((await monitor().runOnce()).notified).toEqual([]);
    }
    expect(wecker).toHaveLength(1);
    const w = (await a.client.get('/api/v1/admin/warnings')).json;
    expect(w.active).toEqual([{ kind: 'cert', since: expect.any(String), count: 1 }]);
    expect(w.lastNotifiedAt).toBeTruthy();
    // der Wecker trägt nichts: nur das feste Wort, kein Titel, keine Namen
    expect(JSON.stringify(wecker)).not.toMatch(/Zertifikat|cert|admin|Betrieb/i);
  });

  it('Entprellung je Art: Problem geht und kommt wieder, höchstens ein Wecker in 6 Stunden; Rückkehr ohne Meldung', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    const schlecht = () => (aktuell = probes(world.clock, { disk: async () => ({ totalBytes: 100, freeBytes: 10 }) }));
    const gut = () => (aktuell = probes(world.clock));
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual(['disk']);
    world.advance(5 * MIN);
    gut();
    expect((await monitor().runOnce()).notified).toEqual([]); // zurück: keine Meldung
    expect((await a.client.get('/api/v1/admin/warnings')).json.active).toEqual([]);
    world.advance(5 * MIN);
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual([]); // zu früh (Entprellung)
    expect(wecker).toHaveLength(1);
    // nach Ablauf der Entprellfrist und neuem Wechsel wieder
    world.advance(ALERT_DEBOUNCE_MS);
    gut();
    await monitor().runOnce();
    world.advance(5 * MIN);
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual(['disk']);
    expect(wecker).toHaveLength(2);
  });

  it('Neustart: der Zustand steht in der Datenbank, ein neuer Prüfer wiederholt nichts', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    aktuell = probes(world.clock, { ntfyReachable: async () => false });
    expect((await monitor().runOnce()).notified).toEqual(['ntfy']);
    const neu = new OperatorMonitor({ ctx: world.auth.ctx, push: world.app.push, weather: world.app.weather, probes: umschaltbar });
    world.advance(5 * MIN);
    expect((await neu.runOnce()).notified).toEqual([]);
    expect(wecker).toHaveLength(1);
    // ... und nach der Wiederherstellung und einem neuen Problem kommt es wieder (nach der Entprellfrist), auch über den Neustart hinweg
    aktuell = probes(world.clock);
    await neu.runOnce();
    world.advance(ALERT_DEBOUNCE_MS + MIN);
    aktuell = probes(world.clock, { ntfyReachable: async () => false });
    const nochNeuer = new OperatorMonitor({ ctx: world.auth.ctx, push: world.app.push, weather: world.app.weather, probes: umschaltbar });
    expect((await nochNeuer.runOnce()).notified).toEqual(['ntfy']);
  });

  it('"unbekannt" löst nie Alarm aus und ändert den Zustand nicht', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    aktuell = probes(world.clock, { readText: async () => null, disk: async () => null, tlsValidTo: async () => null });
    expect((await monitor().runOnce()).notified).toEqual([]);
    expect(wecker).toEqual([]);
    // erst ein echtes Problem, dann "unbekannt": der Zustand bleibt aktiv (keine stille Entwarnung, keine Wiederholung)
    aktuell = probes(world.clock, { disk: async () => ({ totalBytes: 100, freeBytes: 5 }) });
    await monitor().runOnce();
    aktuell = probes(world.clock, { disk: async () => null });
    world.advance(5 * MIN);
    await monitor().runOnce();
    expect((await a.client.get('/api/v1/admin/warnings')).json.active).toEqual([{ kind: 'disk', since: expect.any(String), count: 1 }]);
    expect(wecker).toHaveLength(1);
  });

  it('Sicherung älter als 36 Stunden warnt; jünger nicht', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    const mitAlter = (h: number) => (aktuell = probes(world.clock, { readText: async (p) => (p.endsWith('backup.status') ? `last_result=ok\nlast_success_epoch=${Math.floor(world.clock / 1000) - h * 3600}\ntotal_bytes=1\n` : null) }));
    mitAlter(35);
    expect((await monitor().runOnce()).notified).toEqual([]);
    mitAlter(37);
    expect((await monitor().runOnce()).notified).toEqual(['backup']);
    expect(await alerts()).toEqual(['operator_alert_backup']);
  });

  it('viele Fehlanmeldungen: mehr als 20 in 15 Minuten', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    const fid = (await world.db.select().from(schema.families))[0]!.id;
    const fehl = (n: number, vor: number) => world.db.insert(schema.auditLog).values(Array.from({ length: n }, () => ({ event: 'login_failed', familyId: fid, createdAt: new Date(world.clock - vor) })));
    await fehl(25, 20 * MIN); // außerhalb des Fensters
    expect((await monitor().runOnce()).notified).toEqual([]);
    await fehl(20, 5 * MIN);
    expect((await monitor().runOnce()).notified).toEqual([]);
    // Einträge ohne Familie (unbekanntes Konto) zählen mit
    await world.db.insert(schema.auditLog).values({ event: 'login_failed', familyId: null, createdAt: new Date(world.clock - MIN) });
    expect((await monitor().runOnce()).notified).toEqual(['logins']);
  });

  it('Schlüssel-Ampel rot MIT gemeldetem Gerät: sofort ein Wecker; wer nie einen Schlüssel hatte, löst nichts aus', async () => {
    const { a, kind } = await familie();
    await mitPush(a, 1);
    expect((await monitor().runOnce()).notified).toEqual([]);
    // das Kind hat einen Schlüssel, sein Gerät meldet "keinen Schlüssel" (0): echter Mangel, kein Weg
    await ersteSchluessel(kind.client);
    await kind.client.put('/api/v1/me/device-key', { keyVersion: 0 });
    world.advance(5 * MIN);
    expect((await monitor().runOnce()).notified).toEqual(['key']);
    expect(await alerts()).toEqual(['operator_alert_key']);
    expect(wecker).toHaveLength(1);
    // grün (Gerät + Sicherung) und wieder weg: keine Meldung für die Rückkehr
    await kind.client.put('/api/v1/me/device-key', { keyVersion: 1 });
    await kind.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
    world.advance(5 * MIN);
    expect((await monitor().runOnce()).notified).toEqual([]);
    expect((await a.client.get('/api/v1/admin/warnings')).json.active).toEqual([]);
  });

  it('Karenz: rote Ampel ohne je gemeldetes Gerät wird erst nach 7 Tagen gemeldet; die Anzeige bleibt rot', async () => {
    const { a, kind } = await familie();
    await mitPush(a, 1);
    await stepUp(a);
    await ersteSchluessel(kind.client);
    const kid = await idOf(kind);
    expect(await ampelOfUser(a.client, kid)).toBe('red'); // Anzeige unverändert
    for (const schritt of [5 * MIN, DAY, 5 * DAY, 90 * MIN]) {
      world.advance(schritt);
      aktuell = probes(world.clock); // die Messungen altern nicht mit (frische Sicherung)
      expect((await monitor().runOnce()).notified, `nach ${schritt}`).toEqual([]);
    }
    expect(wecker).toEqual([]);
    // die Warnliste zeigt die Person (aktiv), gewarnt wurde noch nicht
    expect((await a.client.get('/api/v1/admin/warnings')).json).toMatchObject({ lastNotifiedAt: null, active: [{ kind: 'key', count: 1 }] });
    world.advance(2 * DAY);
    aktuell = probes(world.clock);
    expect((await monitor().runOnce()).notified).toEqual(['key']);
    expect(wecker).toHaveLength(1);
    world.advance(10 * MIN);
    aktuell = probes(world.clock);
    expect((await monitor().runOnce()).notified).toEqual([]);
  });

  it('nachholen: nicht gemeldete Zustände (Entprellung) werden nach Ablauf gemeldet; ein wiederkehrendes Problem und eine zweite Person ebenso', async () => {
    const { a, zweiter, eltern } = await familie();
    await mitPush(a, 1);
    const schlecht = () => (aktuell = probes(world.clock, { disk: async () => ({ totalBytes: 100, freeBytes: 10 }) }));
    const gut = () => (aktuell = probes(world.clock));
    // Problem: gemeldet (t0), weg (+5 min), wieder da (+1 h): wegen der Entprellung noch nicht gemeldet ...
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual(['disk']);
    world.advance(5 * MIN);
    gut();
    await monitor().runOnce();
    world.advance(55 * MIN);
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual([]);
    expect(wecker).toHaveLength(1);
    // ... und es wird NICHT als gemeldet geführt: es besteht weiter und wird nach Ablauf der 6 Stunden nachgeholt
    world.advance(3 * HOUR);
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual([]);
    world.advance(3 * HOUR);
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual(['disk']);
    expect(wecker).toHaveLength(2);
    // danach keine Wiederholung
    world.advance(10 * MIN);
    schlecht();
    expect((await monitor().runOnce()).notified).toEqual([]);
    // zweite Person mit roter Ampel (jeweils mit gemeldetem Gerät ohne Schlüssel): erste wird gemeldet, die zweite nach Ablauf der Entprellung
    gut();
    await monitor().runOnce();
    await ersteSchluessel(zweiter.client);
    await zweiter.client.put('/api/v1/me/device-key', { keyVersion: 0 });
    world.advance(5 * MIN);
    expect((await monitor().runOnce()).notified).toEqual(['key']);
    await ersteSchluessel(eltern.client);
    await eltern.client.put('/api/v1/me/device-key', { keyVersion: 0 });
    world.advance(5 * MIN);
    expect((await monitor().runOnce()).notified).toEqual([]);
    world.advance(ALERT_DEBOUNCE_MS);
    expect((await monitor().runOnce()).notified).toEqual(['key']);
    const n = wecker.length;
    world.advance(10 * MIN);
    expect((await monitor().runOnce()).notified).toEqual([]);
    expect(wecker).toHaveLength(n);
    // die Warnliste fasst die Schlüssel-Warnungen zusammen (Art mit Anzahl, kein Name)
    const w = (await a.client.get('/api/v1/admin/warnings')).json;
    expect(w.active).toEqual([{ kind: 'key', since: expect.any(String), count: 2 }]);
    expect(JSON.stringify(w)).not.toMatch(/admin2|mama/);
  });

  it('Schalter "Warnungen": aus = nie ein Wecker, der Zustand läuft weiter; Step-up und Protokoll; wieder an', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    await stepUp(a);
    const res = await a.client.put('/api/v1/admin/warnings', { enabled: false });
    expect(res.status).toBe(200);
    expect(res.json.enabled).toBe(false);
    expect((await a.client.put('/api/v1/admin/warnings', { enabled: 'nein' })).status).toBe(400);
    expect((await a.client.put('/api/v1/admin/warnings', { enabled: false, extra: 1 })).status).toBe(400);
    expect(await auditEvents(world)).toContain('operator_warnings_set');
    aktuell = probes(world.clock, { disk: async () => ({ totalBytes: 100, freeBytes: 1 }) });
    expect((await monitor().runOnce()).notified).toEqual([]);
    expect(wecker).toEqual([]);
    expect(await alerts()).toEqual([]);
    expect((await a.client.get('/api/v1/admin/warnings')).json).toMatchObject({ enabled: false, active: [{ kind: 'disk' }] });
    // wieder an: ein neues Problem UND das in der Ausschaltzeit nie gemeldete (noch bestehende) werden gemeldet
    expect((await a.client.put('/api/v1/admin/warnings', { enabled: true })).json.enabled).toBe(true);
    world.advance(5 * MIN);
    aktuell = probes(world.clock, { disk: async () => ({ totalBytes: 100, freeBytes: 1 }), tlsValidTo: async () => new Date(world.clock + 2 * DAY) });
    expect((await monitor().runOnce()).notified).toEqual(['cert', 'disk']);
  });

  it('Datenbank im Prüflauf nicht erreichbar: "database" wird gemeldet, der Lauf wirft nie', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    await monitor().runOnce(); // füllt den Speicher (Betreiber, Push-Themen)
    expect(wecker).toEqual([]);
    // die Datenbank "bricht weg": jede Abfrage scheitert
    const ctx = world.auth.ctx;
    const echteDb = ctx.db;
    const kaputt = new Proxy(echteDb, {
      get(t, prop, rec) {
        if (prop === 'select' || prop === 'insert' || prop === 'update' || prop === 'delete' || prop === 'execute' || prop === 'transaction') {
          return () => {
            throw new Error('Datenbank nicht erreichbar');
          };
        }
        return Reflect.get(t, prop, rec);
      },
    });
    (ctx as { db: typeof echteDb }).db = kaputt as typeof echteDb;
    try {
      world.advance(5 * MIN);
      const r = await monitor().runOnce();
      expect(r.notified).toEqual(['database']);
      expect(wecker).toEqual([{ topic: topic(1), body: WAKE_BODY, method: 'POST' }]);
    } finally {
      (ctx as { db: typeof echteDb }).db = echteDb;
    }
  });

  it('nichts in den Antworten außer Art und Zeit: keine Namen, Pfade oder Geheimnisse', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    aktuell = probes(world.clock, { tlsValidTo: async () => new Date(world.clock + DAY) });
    await monitor().runOnce();
    const res = await a.client.get('/api/v1/admin/warnings');
    const text = JSON.stringify(res.json);
    for (const verboten of ['Admin', 'admin@', GEHEIM, '/var/', 'topic', topic(1)]) expect(text, verboten).not.toContain(verboten);
    expect(Object.keys(res.json).sort()).toEqual(['active', 'checkedAt', 'enabled', 'lastNotifiedAt', 'pushAvailable']);
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('Ereignisse "Betrieb-Warnung" stehen im Protokoll (Kategorie Änderungen, ohne Inhalt)', async () => {
    const { a } = await familie();
    await mitPush(a, 1);
    aktuell = probes(world.clock, { tlsValidTo: async () => new Date(world.clock + DAY) });
    await monitor().runOnce();
    await stepUp(a);
    const audit = (await a.client.get('/api/v1/admin/audit?category=aenderungen')).json.items as Array<{ event: string; category: string; actor: unknown }>;
    const e = audit.find((x) => x.event === 'operator_alert_cert');
    expect(e).toMatchObject({ category: 'aenderungen', actor: null });
  });

  it('Mitglied entfernt: der Zustand seiner Schlüsselwarnung verschwindet', async () => {
    const { a, kind } = await familie();
    await mitPush(a, 1);
    await ersteSchluessel(kind.client);
    await monitor().runOnce();
    expect(await world.count('operator_alert_state')).toBeGreaterThan(0);
    const kid = await idOf(kind);
    expect(await world.db.execute(sql`select 1 from operator_alert_state where kind = ${`key:${kid}`}`).then((r) => r.rows.length)).toBe(1);
    await stepUp(a);
    expect((await a.client.del(`/api/v1/members/${kid}`)).status).toBe(200);
    world.advance(5 * MIN);
    await monitor().runOnce();
    expect(await world.db.execute(sql`select 1 from operator_alert_state where kind = ${`key:${kid}`}`).then((r) => r.rows.length)).toBe(0);
  });
});
