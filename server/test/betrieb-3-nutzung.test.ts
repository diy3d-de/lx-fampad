// Betrieb Paket 3, Teile B und C: Wetter und Push (Zähler ohne Fehlertexte, Endpunkte nie sichtbar) sowie Nutzung und Verlauf (tägliche Messpunkte nur aus Zahlen).
// Geprüft werden die Zähler im Prozess, die Messpunkte (Aktivität, Zähler addieren sich, Größen, UTC-Tage), die Aufbewahrung von 400 Tagen, die Route (nur Betreiber, Eingabe),
// der Fehlerzähler des Wetter-Dienstes und die Zähler des Push-Wecker-Stands.
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { runMaintenance } from '../src/auth/maintenance.js';
import * as schema from '../src/db/schema.js';
import { collectActivity, dayOf, FILES_MEASURE_INTERVAL_MS, listMetrics, METRICS_RETENTION_DAYS, recordMetrics, UsageCounters } from '../src/operator/metrics.js';
import { realProbes, type Probes } from '../src/operator/probes.js';
import { grantOperator } from '../src/operator/service.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, upsert, type Family } from './sync-kit.js';

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const MAC = '70:ee:50:01:79:f2';
const WEATHER = { WEATHER_ENABLED: 'true', WEATHER_STATION_MAC: MAC, WEATHER_BBOX: '50.54,7.94,50.58,8.00', WEATHER_PLACE: 'Westerburg' };

// ---------------------------------------------------------------------------------------------------------------------------------- reine Teile

describe('Zähler im Prozess (rein)', () => {
  it('zählen, herausnehmen setzt auf 0, zurückgeben addiert', () => {
    const c = new UsageCounters();
    c.syncRun();
    c.syncRun();
    c.syncError();
    c.rateLimit();
    c.rateLimit();
    c.rateLimit();
    expect(c.take()).toEqual({ syncRuns: 2, syncErrors: 1, rateLimited: 3 });
    expect(c.take()).toEqual({ syncRuns: 0, syncErrors: 0, rateLimited: 0 });
    c.syncRun();
    c.restore({ syncRuns: 2, syncErrors: 1, rateLimited: 3 });
    expect(c.take()).toEqual({ syncRuns: 3, syncErrors: 1, rateLimited: 3 });
  });

  it('dayOf: der Tag ist der UTC-Tag', () => {
    expect(dayOf(new Date('2026-10-20T23:59:59Z'))).toBe('2026-10-20');
    expect(dayOf(new Date('2026-10-21T00:00:00Z'))).toBe('2026-10-21');
    expect(dayOf(new Date('2026-10-20T23:30:00-05:00'))).toBe('2026-10-21');
  });
});

describe('Lesen der Statusdateien ohne Symlinks (echte Messung auf einem Wegwerf-Ordner)', () => {
  it('mit noFollow wird ein Symlink als Datei nicht gelesen, eine reguläre Datei schon; ohne noFollow wie bisher', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fampad-read-'));
    try {
      writeFileSync(join(dir, 'echt.status'), 'a=1\n');
      expect(await realProbes.readText(join(dir, 'echt.status'), 100, true)).toBe('a=1\n');
      expect(await realProbes.readText(join(dir, 'gibtsnicht'), 100, true)).toBeNull();
      expect(await realProbes.readText(dir, 100, true)).toBeNull(); // ein Ordner ist keine Datei
      let link = false;
      try {
        symlinkSync(join(dir, 'echt.status'), join(dir, 'link.status'));
        link = true;
      } catch {
        // ohne Recht für Links (Windows): der Teil entfällt
      }
      if (link && process.platform !== 'win32') {
        expect(await realProbes.readText(join(dir, 'link.status'), 100, true)).toBeNull();
        expect(await realProbes.readText(join(dir, 'link.status'), 100)).toBe('a=1\n');
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('Größe der Dateiablage (echte Messung auf einem Wegwerf-Ordner)', () => {
  it('summiert nur Dateigrößen (auch in Unterordnern), keine Namen; null bei fehlendem Ordner oder zu vielen Einträgen', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fampad-files-'));
    try {
      writeFileSync(join(dir, 'a.bin'), Buffer.alloc(1000));
      mkdirSync(join(dir, 'unter'));
      writeFileSync(join(dir, 'unter', 'b.bin'), Buffer.alloc(234));
      try {
        symlinkSync(join(dir, 'a.bin'), join(dir, 'link')); // Links werden nicht verfolgt (unter Windows ohne Recht: übersprungen)
      } catch {
        // ohne Rechte für Links
      }
      expect(await realProbes.dirBytes(dir, 100)).toBe(1234);
      expect(await realProbes.dirBytes(dir, 2)).toBeNull();
      expect(await realProbes.dirBytes(join(dir, 'gibtsnicht'), 100)).toBeNull();
      expect(await realProbes.dirBytes(join(dir, 'a.bin'), 100)).toBeNull(); // kein Ordner
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------------------------------------------------------------- mit Datenbank

describe.each(backends)('Betrieb Paket 3, Nutzung, Wetter und Push ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let files: number | null;
  let filesAufrufe: number;
  let aktuell: Partial<Probes>;
  const umschaltbar: Probes = {
    readText: (p, m) => aktuell.readText!(p, m),
    disk: (p) => aktuell.disk!(p),
    karteBytes: (d) => aktuell.karteBytes!(d),
    dirBytes: (d, n) => aktuell.dirBytes!(d, n),
    tlsValidTo: (x, s) => aktuell.tlsValidTo!(x, s),
    ntfyReachable: (u) => aktuell.ntfyReachable!(u),
  };
  const messungen = (): Partial<Probes> => ({
    readText: async () => null,
    disk: async () => ({ totalBytes: 100, freeBytes: 59 }),
    karteBytes: async () => 1,
    dirBytes: async () => {
      filesAufrufe++;
      return files;
    },
    tlsValidTo: async () => new Date(world.clock + 85 * DAY),
    ntfyReachable: async () => true,
  });

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv = {}, extra: { weatherFetch?: typeof fetch } = {}) {
    await world?.close();
    await harness.reset();
    files = 5000;
    filesAufrufe = 0;
    world = await World.create(harness.db, { NTFY_URL: 'http://127.0.0.1:2586', NTFY_TOKEN: 'tk_geheim', OPERATOR_TLS_PROBE: '127.0.0.1:443', SYNC_RATE_LIMIT_MAX: '100000', ...env }, { operatorProbes: umschaltbar, ...extra });
    aktuell = messungen();
  }
  beforeEach(async () => {
    await neu();
  });

  const monitor = () => world.app.operatorMonitor!;
  const einzeln = async () => (await world.db.select().from(schema.operatorMetrics))[0];
  /** Führt [fn] mit der Weltuhr um [vor] Tage zurückgestellt aus (die Uhr gehört der Welt, nicht dem Kontext). */
  async function amTag<T>(vor: number, fn: () => Promise<T>): Promise<T> {
    const alt = world.clock;
    world.clock = alt - vor * DAY;
    try {
      return await fn();
    } finally {
      world.clock = alt;
    }
  }
  async function familie(): Promise<Family> {
    const fam = await createFamily(world);
    await grantOperator(world.auth.ctx, 'admin@example.org');
    return fam;
  }

  // ---- Messpunkte ----

  it('Messpunkt des Tages: aktive Personen und Geräte, Datenbank- und Dateigröße; zweiter Lauf überschreibt die Größen, addiert nichts doppelt', async () => {
    const fam = await familie();
    await monitor().runOnce();
    const z = (await einzeln())!;
    expect(z.day).toBe(dayOf(new Date(world.clock)));
    expect(z).toMatchObject({ activePersons7: 3, activePersons30: 3, activeDevices7: 3, activeDevices30: 3 });
    expect(z.dbBytes).toBeGreaterThan(0);
    // die Dateiablage wird im Hintergrund gemessen, nie vor den Warn-Prüfungen abgewartet: der erste Lauf hat noch keinen Wert
    expect(z.filesBytes).toBeNull();
    await monitor().whenIdle();
    expect(await world.count('operator_metrics')).toBe(1);
    // ein weiterer Lauf: weiter genau eine Zeile; der Wert kommt jetzt hinein, die Dateigröße wird höchstens stündlich neu gemessen
    world.advance(5 * MIN);
    files = 9999;
    await monitor().runOnce();
    expect(await world.count('operator_metrics')).toBe(1);
    expect((await einzeln())!.filesBytes).toBe(5000);
    expect(filesAufrufe).toBe(1);
    world.advance(FILES_MEASURE_INTERVAL_MS);
    await monitor().runOnce(); // veraltet: schreibt den alten Wert und misst im Hintergrund neu
    await monitor().whenIdle();
    expect(filesAufrufe).toBe(2);
    world.advance(5 * MIN);
    await monitor().runOnce();
    expect((await einzeln())!.filesBytes).toBe(9999);
    // ein neuer Tag legt eine neue Zeile an
    world.advance(DAY);
    await monitor().runOnce();
    expect(await world.count('operator_metrics')).toBe(2);
    expect(fam.familyId).toBeTruthy();
  });

  it('Eine hängende Messung der Dateiablage hält weder den Prüflauf noch die Warnungen auf', async () => {
    await familie();
    aktuell = { ...messungen(), dirBytes: () => new Promise<number | null>(() => undefined) }; // kehrt nie zurück
    const t0 = Date.now();
    await expect(monitor().runOnce()).resolves.toBeDefined();
    expect(Date.now() - t0).toBeLessThan(10_000);
    expect(((await einzeln())!).filesBytes).toBeNull();
  });

  it('Beim Schließen werden die noch nicht übernommenen Zähler einmal in den Messpunkt geschrieben', async () => {
    const fam = await familie();
    await monitor().runOnce(); // die Familie ist dem Prüfer bekannt
    await fam.admin.sync([]);
    await fam.admin.sync([]);
    await monitor().flushCounters();
    expect(((await einzeln())!).syncRuns).toBe(2);
    await monitor().flushCounters(); // nichts mehr offen: nichts doppelt
    expect(((await einzeln())!).syncRuns).toBe(2);
  });

  it('Aktivität: 7 und 30 Tage getrennt; abgemeldete Geräte, nicht aktive Mitglieder und lange nicht gesehene Geräte zählen nicht', async () => {
    const fam = await familie();
    const ctx = world.auth.ctx;
    const ids = { admin: fam.admin.userId, parent: fam.parent.userId, child: fam.child.userId };
    const setze = async (userId: string, vor: number) => world.db.update(schema.devices).set({ lastSeenAt: new Date(world.clock - vor) }).where(eq(schema.devices.userId, userId));
    await setze(ids.admin, 2 * DAY); // 7 und 30 Tage
    await setze(ids.parent, 20 * DAY); // nur 30 Tage
    await setze(ids.child, 45 * DAY); // weder noch
    expect(await collectActivity(ctx, fam.familyId)).toEqual({ persons7: 1, persons30: 2, devices7: 1, devices30: 2 });
    // ein zweites Gerät der Person mit dem Admin (abgemeldet) zählt nicht
    await world.db.insert(schema.devices).values({ familyId: fam.familyId, userId: ids.admin, name: 'Altes Handy', platform: 'android', lastSeenAt: new Date(world.clock - DAY), revokedAt: new Date(world.clock - HOUR) });
    expect((await collectActivity(ctx, fam.familyId)).devices7).toBe(1);
    // ein weiteres Gerät derselben Person zählt als Gerät, nicht als zweite Person
    await world.db.insert(schema.devices).values({ familyId: fam.familyId, userId: ids.admin, name: 'Tablet', platform: 'android', lastSeenAt: new Date(world.clock - DAY) });
    expect(await collectActivity(ctx, fam.familyId)).toEqual({ persons7: 1, persons30: 2, devices7: 2, devices30: 3 });
    // ein nicht mehr aktives Mitglied zählt nicht
    await world.db.update(schema.memberships).set({ status: 'pending' }).where(eq(schema.memberships.userId, ids.parent));
    expect(await collectActivity(ctx, fam.familyId)).toEqual({ persons7: 1, persons30: 1, devices7: 2, devices30: 2 });
    // fremde Familien erscheinen nie
    expect(await collectActivity(ctx, '00000000-0000-4000-8000-000000000000')).toEqual({ persons7: 0, persons30: 0, devices7: 0, devices30: 0 });
  });

  it('Zähler: Abgleiche, Rate-Limit-Treffer (429) und Fehler werden gezählt und in den Messpunkt übernommen; ein zweiter Lauf addiert nur Neues', async () => {
    await neu({ SYNC_REQ_BURST: '3', SYNC_REQ_PER_MINUTE: '3' });
    const fam = await familie();
    // die Anmeldungen und Abfragen oben gehören nicht zu den Abgleichen: erst ab hier zählen
    await monitor().runOnce();
    const vorher = (await einzeln())!;
    for (let i = 0; i < 3; i++) expect((await fam.admin.sync([upsert('list', crypto.randomUUID(), { name: `Liste ${i}` })])).status).toBe(200);
    const limited = await fam.admin.sync([]);
    expect(limited.status).toBe(429);
    expect((await fam.admin.raw({ nonsense: true })).status).toBe(400); // zählt als Lauf, nicht als Serverfehler
    world.advance(5 * MIN);
    await monitor().runOnce();
    const z = (await einzeln())!;
    expect(z.syncRuns - vorher.syncRuns).toBe(5);
    expect(z.rateLimited - vorher.rateLimited).toBe(1);
    expect(z.syncErrors - vorher.syncErrors).toBe(0);
    // kein neuer Abgleich: nichts kommt dazu
    world.advance(5 * MIN);
    await monitor().runOnce();
    expect(((await einzeln())!).syncRuns).toBe(z.syncRuns);
  });

  it('Scheitert das Schreiben des Messpunkts, gehen die Zähler nicht verloren (kommen beim nächsten Lauf)', async () => {
    const fam = await familie();
    await fam.admin.sync([]);
    // die Tabelle kurz unbrauchbar machen: das Schreiben scheitert, die Prüfung der Warnungen läuft trotzdem
    await world.db.execute(sql.raw('alter table operator_metrics rename to operator_metrics_weg'));
    const wiederherstellen = async () => world.db.execute(sql.raw('alter table operator_metrics_weg rename to operator_metrics'));
    try {
      await expect(monitor().runOnce()).resolves.toBeDefined();
    } finally {
      await wiederherstellen();
    }
    await monitor().runOnce();
    expect(((await einzeln())!).syncRuns).toBeGreaterThanOrEqual(1);
  });

  it('Messpunkte: Größen bleiben stehen, wenn sie nicht messbar sind (null); die Datenbank prüft negative Werte', async () => {
    const fam = await familie();
    const ctx = world.auth.ctx;
    const nichts = { syncRuns: 0, syncErrors: 0, rateLimited: 0 };
    const akt = { persons7: 1, persons30: 1, devices7: 1, devices30: 1 };
    await recordMetrics(ctx, fam.familyId, { activity: akt, dbBytes: 100, filesBytes: 50 }, { syncRuns: 2, syncErrors: 1, rateLimited: 0 });
    await recordMetrics(ctx, fam.familyId, { activity: akt, dbBytes: null, filesBytes: null }, { syncRuns: 3, syncErrors: 0, rateLimited: 4 });
    expect(await einzeln()).toMatchObject({ dbBytes: 100, filesBytes: 50, syncRuns: 5, syncErrors: 1, rateLimited: 4 });
    await recordMetrics(ctx, fam.familyId, { activity: akt, dbBytes: 200, filesBytes: null }, nichts);
    expect(await einzeln()).toMatchObject({ dbBytes: 200, filesBytes: 50 });
    await expect(world.db.execute(sql.raw('update operator_metrics set sync_runs = -1'))).rejects.toThrow();
  });

  // ---- Route ----

  it('GET /admin/metrics: nur der Betreiber (alle anderen 404, ohne Sitzung 401), kein Step-up, Eingabe geprüft, nur Zahlen', async () => {
    const fam = await familie();
    await monitor().runOnce();
    expect((await world.client().get('/api/v1/admin/metrics')).status).toBe(401);
    expect((await fam.parent.client.get('/api/v1/admin/metrics')).status).toBe(404);
    expect((await fam.child.client.get('/api/v1/admin/metrics')).status).toBe(404);
    world.advance(10 * MIN); // ohne frisches Step-up
    const res = await fam.admin.client.get('/api/v1/admin/metrics');
    expect(res.status).toBe(200);
    expect(res.json).toMatchObject({ retentionDays: METRICS_RETENTION_DAYS, days: [{ activePersons7: 3, filesBytes: null }] });
    expect(Object.keys(res.json.days[0]).sort()).toEqual(['activeDevices30', 'activeDevices7', 'activePersons30', 'activePersons7', 'dbBytes', 'day', 'filesBytes', 'rateLimited', 'syncErrors', 'syncRuns'].sort());
    for (const q of ['days=0', 'days=401', 'days=abc', 'days=1.5', 'days=-1', 'x=1', 'days=7&days=8']) {
      expect((await fam.admin.client.get(`/api/v1/admin/metrics?${q}`)).status, q).toBe(400);
    }
    expect((await fam.admin.client.get('/api/v1/admin/metrics?days=400')).status).toBe(200);
  });

  it('Verlauf: nur die gewünschten Tage, aufsteigend, Lücken bleiben Lücken', async () => {
    const fam = await familie();
    const ctx = world.auth.ctx;
    const akt = { persons7: 1, persons30: 1, devices7: 1, devices30: 1 };
    for (const vor of [0, 2, 40]) {
      await amTag(vor, () => recordMetrics(ctx, fam.familyId, { activity: akt, dbBytes: 1000 - vor, filesBytes: null }, { syncRuns: vor, syncErrors: 0, rateLimited: 0 }));
    }
    const sieben = await listMetrics(ctx, fam.familyId, 7);
    expect(sieben.days.map((d) => d.syncRuns)).toEqual([2, 0]);
    const hundert = await listMetrics(ctx, fam.familyId, 100);
    expect(hundert.days.map((d) => d.syncRuns)).toEqual([40, 2, 0]);
    expect(hundert.days.map((d) => d.day)).toEqual([...hundert.days.map((d) => d.day)].sort());
  });

  it('Aufbewahrung: Messpunkte nach 400 Tagen werden vom Aufräum-Job gelöscht, jüngere bleiben', async () => {
    const fam = await familie();
    const ctx = world.auth.ctx;
    const akt = { persons7: 0, persons30: 0, devices7: 0, devices30: 0 };
    const nichts = { syncRuns: 1, syncErrors: 0, rateLimited: 0 };
    for (const vor of [0, 399, 400, 401, 500]) {
      await amTag(vor, () => recordMetrics(ctx, fam.familyId, { activity: akt, dbBytes: 1, filesBytes: null }, nichts));
    }
    expect(await world.count('operator_metrics')).toBe(5);
    const report = await runMaintenance(ctx);
    expect(report.metricsDeleted).toBe(2); // 401 und 500 Tage
    expect(await world.count('operator_metrics')).toBe(3);
    const bleibt = (await world.db.select().from(schema.operatorMetrics)).map((r) => r.day).sort();
    expect(bleibt).toEqual([dayOf(new Date(world.clock - 400 * DAY)), dayOf(new Date(world.clock - 399 * DAY)), dayOf(new Date(world.clock))].sort());
  });

  it('Messwerte tragen nie Inhalte: die Tabelle hat nur Zahlen- und Datumsspalten', async () => {
    const spalten = (await world.db.execute(sql.raw("select column_name, data_type from information_schema.columns where table_name = 'operator_metrics'"))).rows as Array<{ column_name: string; data_type: string }>;
    expect(spalten.length).toBeGreaterThan(5);
    for (const s of spalten) expect(['integer', 'bigint', 'date', 'uuid', 'timestamp with time zone'], s.column_name).toContain(s.data_type);
  });

  // ---- Wetter ----

  describe('Wetter: Fehlerzähler ohne Fehlertexte', () => {
    let nasZustand: { tokenStatus: number; dataStatus: number };
    const netatmo = (async (input: string | URL | Request) => {
      const url = String(input);
      if (url.endsWith('/oauth2/token')) {
        if (nasZustand.tokenStatus !== 200) return new Response('{}', { status: nasZustand.tokenStatus });
        return new Response(JSON.stringify({ access_token: 'access-abcdefghij', refresh_token: 'refresh-geheim-abcdefghij', expires_in: 10800 }), { status: 200 });
      }
      if (nasZustand.dataStatus !== 200) return new Response('{}', { status: nasZustand.dataStatus });
      const ts = Math.floor(Date.now() / 1000);
      return new Response(JSON.stringify({ status: 'ok', body: [{ _id: MAC, place: { location: [7.97, 50.56] }, measures: { m1: { res: { [ts - 60]: [12.5, 71] }, type: ['temperature', 'humidity'] } } }] }), { status: 200 });
    }) as typeof fetch;
    const zugang = () => world.app.weather!.speichereZugangsdaten({ clientId: 'client-id-xyz', clientSecret: 'client-secret-xyz', refreshToken: 'refresh-0-secret-token' });

    beforeEach(async () => {
      nasZustand = { tokenStatus: 200, dataStatus: 200 };
      await neu({ ...WEATHER }, { weatherFetch: netatmo });
      // die Messung trägt die Uhr des Rechners: die Weltuhr passend setzen
      world.clock = Date.now();
    });

    it('zählt Fehlschläge in Folge, setzt nach einem Erfolg auf 0 und zeigt nur Zahl und Code', async () => {
      await zugang();
      const a = await familie();
      expect((await world.app.weather!.status()).errorCount).toBe(0);
      nasZustand.dataStatus = 500;
      expect(await world.app.weather!.pollOnce()).toBe('upstream_error');
      world.advance(MIN);
      expect(await world.app.weather!.pollOnce()).toBe('upstream_error');
      expect(await world.app.weather!.status()).toMatchObject({ errorCount: 2, lastErrorCode: 'http_500' });
      let s = (await a.admin.client.get('/api/v1/admin/status?fresh=1')).json.services.find((x: { id: string }) => x.id === 'weather');
      expect(s.detail).toMatchObject({ errorCount: 2, lastErrorCode: 'http_500', configured: true });
      expect(JSON.stringify(s)).not.toMatch(/geheim|secret|Westerburg|7\.97|50\.56/);
      // Erfolg setzt zurück
      nasZustand.dataStatus = 200;
      world.advance(MIN);
      expect(await world.app.weather!.pollOnce()).toBe('ok');
      expect((await world.app.weather!.status()).errorCount).toBe(0);
      world.advance(20_000);
      s = (await a.admin.client.get('/api/v1/admin/status?fresh=1')).json.services.find((x: { id: string }) => x.id === 'weather');
      expect(s.detail.errorCount).toBe(0);
    });

    it('Fehler beim Zugangstoken zählen einmal je Abruf; neue Zugangsdaten setzen den Zähler zurück', async () => {
      await zugang();
      nasZustand.tokenStatus = 500;
      await world.app.weather!.pollOnce();
      expect((await world.app.weather!.status()).errorCount).toBe(1);
      await zugang();
      expect((await world.app.weather!.status()).errorCount).toBe(0);
    });
  });

  // ---- Push ----

  describe('Push: Zähler, nie Endpunkte', () => {
    it('zählt aktive, deaktivierte und fehlerhafte Geräte, Fehler der letzten 24 Stunden und den letzten Erfolg; fremde und abgemeldete Geräte nie', async () => {
      const fam = await familie();
      const devs = await world.db.select().from(schema.devices).where(eq(schema.devices.familyId, fam.familyId));
      expect(devs.length).toBeGreaterThanOrEqual(3);
      const [d1, d2, d3] = devs as [typeof devs[number], typeof devs[number], typeof devs[number]];
      const ep = (d: typeof d1, n: number, extra: Partial<typeof schema.pushEndpoints.$inferInsert> = {}) =>
        world.db.insert(schema.pushEndpoints).values({ deviceId: d.id, familyId: fam.familyId, topic: `upGeheimesThema${String(n).padStart(2, '0')}`, ...extra });
      await ep(d1, 1, { lastOkAt: new Date(world.clock - HOUR) });
      await ep(d2, 2, { lastOkAt: new Date(world.clock - 2 * HOUR), failCount: 2, lastErrorAt: new Date(world.clock - 2 * HOUR) });
      await ep(d3, 3, { disabledAt: new Date(world.clock - DAY), lastErrorAt: new Date(world.clock - 3 * DAY), failCount: 5 });
      const res = await fam.admin.client.get('/api/v1/admin/status?fresh=1');
      expect(res.json.push).toEqual({ devicesActive: 2, devicesDisabled: 1, devicesFailing: 1, errors24h: 1, lastOkAt: new Date(world.clock - HOUR).toISOString() });
      expect(JSON.stringify(res.json)).not.toMatch(/upGeheimesThema|Endpunkt|endpoint/i);
      // ein abgemeldetes Gerät zählt nicht mehr
      await world.db.update(schema.devices).set({ revokedAt: new Date(world.clock) }).where(eq(schema.devices.id, d1.id));
      world.advance(20_000);
      expect((await fam.admin.client.get('/api/v1/admin/status?fresh=1')).json.push).toMatchObject({ devicesActive: 1 });
    });

    it('ohne Geräte alles 0 und kein letzter Erfolg', async () => {
      const fam = await familie();
      expect((await fam.admin.client.get('/api/v1/admin/status')).json.push).toEqual({ devicesActive: 0, devicesDisabled: 0, devicesFailing: 0, errors24h: 0, lastOkAt: null });
    });
  });
});

