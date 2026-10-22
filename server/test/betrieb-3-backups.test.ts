// Betrieb Paket 3, Teil A (Backups): Rückmeldung des NAS (letzte Abholung, letzter Wiederherstellungstest). Geprüft wird die strenge Auswertung der Statusdatei (rein),
// die Zustände mit ihren Grenzen (36 Stunden, 10 Tage), dass die Anzeige nur feste Felder liefert, die Karenz bis zur Einrichtung ("unbekannt" warnt nie) und die Warnungen im Prüfer.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { ALERT_DEBOUNCE_MS, evaluateConditions, OperatorMonitor, type AlertKind } from '../src/operator/monitor.js';
import { NAS_ABSENT, NAS_STATUS_MAX_BYTES, parseNasStatus } from '../src/operator/nas-status.js';
import type { Probes } from '../src/operator/probes.js';
import { grantOperator } from '../src/operator/service.js';
import type { OperatorStatus } from '../src/operator/status.js';
import { WAKE_BODY } from '../src/push/service.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const HOST = 'ntfy.familie.lx-labs.dev';
const ENV = { NTFY_URL: 'http://127.0.0.1:2586', NTFY_TOKEN: 'tk_geheimes-ntfy-token-123', OPERATOR_TLS_PROBE: '127.0.0.1:443', E2EE_PW_BACKUP: 'true' };
const topic = (n: number) => `upWeckerTopic${String(n).padStart(2, '0')}`;
const NOW = new Date('2026-10-20T08:00:00Z');
const sec = (d: Date) => Math.floor(d.getTime() / 1000);

/** Baut eine Statusdatei des NAS: Alter von Abholung und Test in Stunden (null = nicht enthalten). */
function nasText(now: Date, o: { pullH?: number | null; pull?: 'ok' | 'fehler'; restoreH?: number | null; restore?: 'ok' | 'fehler'; extra?: string } = {}): string {
  const at = (h: number) => sec(now) - Math.round(h * 3600);
  const lines = ['nas_format=1', `reported_epoch=${sec(now)}`, `received_epoch=${sec(now)}`];
  if (o.pullH !== null) {
    lines.push(`pull_result=${o.pull ?? 'ok'}`, `pull_run_epoch=${at(0.5)}`, `pull_success_epoch=${at(o.pullH ?? 5)}`, `pull_newest_epoch=${at((o.pullH ?? 5) + 1)}`, 'pull_count=14');
  }
  if (o.restoreH !== undefined && o.restoreH !== null) {
    lines.push(`restore_result=${o.restore ?? 'ok'}`, `restore_run_epoch=${at(o.restoreH)}`, `restore_success_epoch=${at(o.restoreH)}`, 'restore_config_check=nein');
  }
  if (o.extra) lines.push(o.extra);
  return `${lines.join('\n')}\n`;
}

// ---------------------------------------------------------------------------------------------------------------------------------- reine Logik

describe('Rückmeldung des NAS (rein)', () => {
  it('fehlt die Datei (null): nicht eingerichtet, alles "unbekannt", kein Alarm', () => {
    const n = parseNasStatus(null, NOW);
    expect(n).toEqual(NAS_ABSENT);
    expect(n.configured).toBe(false);
    expect(n.pull.state).toBe('unknown');
    expect(n.restore.state).toBe('unknown');
  });

  it('gültige Datei: Zeiten, Alter, Zähler, Prüfung der Konfiguration', () => {
    const n = parseNasStatus(nasText(NOW, { pullH: 5, restoreH: 48 }), NOW);
    expect(n).toMatchObject({ configured: true, invalid: false, receivedAt: NOW.toISOString() });
    expect(n.pull).toMatchObject({ result: 'ok', ageHours: 5, count: 14, state: 'ok' });
    expect(n.pull.lastSuccessAt).toBe(new Date(NOW.getTime() - 5 * HOUR).toISOString());
    expect(n.pull.newestBackupAt).toBe(new Date(NOW.getTime() - 6 * HOUR).toISOString());
    expect(n.restore).toMatchObject({ result: 'ok', ageDays: 2, configChecked: false, state: 'ok' });
  });

  it('Abholung: 36 Stunden ist in Ordnung, darüber Warnung, über 72 Stunden Fehler; gemeldeter Fehlschlag ist ein Fehler', () => {
    const z = (h: number, r: 'ok' | 'fehler' = 'ok') => parseNasStatus(nasText(NOW, { pullH: h, pull: r }), NOW).pull.state;
    expect(z(36)).toBe('ok');
    expect(z(37)).toBe('warn');
    expect(z(72)).toBe('warn');
    expect(z(73)).toBe('error');
    expect(z(2, 'fehler')).toBe('error');
  });

  it('Wiederherstellungstest: 10 Tage ist in Ordnung, darüber Warnung, über 21 Tage Fehler; Fehlschlag ist ein Fehler; nie gemeldet ist "unbekannt"', () => {
    const z = (d: number, r: 'ok' | 'fehler' = 'ok') => parseNasStatus(nasText(NOW, { restoreH: d * 24, restore: r }), NOW).restore.state;
    expect(z(10)).toBe('ok');
    expect(z(10.1)).toBe('warn');
    expect(z(21)).toBe('warn');
    expect(z(22)).toBe('error');
    expect(z(1, 'fehler')).toBe('error');
    const ohne = parseNasStatus(nasText(NOW, { pullH: 3 }), NOW);
    expect(ohne.configured).toBe(true);
    expect(ohne.restore.state).toBe('unknown');
    expect(ohne.restore.result).toBeNull();
  });

  it('streng: Format, doppelte Schlüssel, Größe, NUL, Zeit in der Zukunft, ungültige Werte machen die ganze Datei ungültig (nie ein Alarm)', () => {
    const gut = nasText(NOW, { pullH: 2 });
    const ungueltig = (text: string) => {
      const n = parseNasStatus(text, NOW);
      expect(n, text.slice(0, 40)).toMatchObject({ configured: false, invalid: true });
      expect(n.pull.state).toBe('unknown');
      expect(n.restore.state).toBe('unknown');
    };
    ungueltig(`${gut}das ist keine zeile\n`);
    ungueltig(`${gut}pull_count=1; rm -rf /\n`);
    ungueltig(`${gut}pull_result=fehler\n`); // doppelt
    ungueltig(`${gut}Pull_Count=1\n`); // Großbuchstaben
    ungueltig(`${gut}pull_count=123456\n`);
    ungueltig(`${gut}restore_config_check=vielleicht\n`);
    ungueltig(`${gut}pull_result=\n`.replace(/pull_result=ok\n/, ''));
    ungueltig(`pull_result=ok\npull_success_epoch=${sec(NOW) + 2 * 3600}\n`); // Zukunft
    ungueltig(`pull_result=ok\npull_success_epoch=${sec(NOW) - 100}x\n`);
    ungueltig('pull_result=ok\npull_success_epoch=1000\n'); // vor 2020
    ungueltig(`${gut}x=${'a'.repeat(NAS_STATUS_MAX_BYTES)}\n`); // zu groß
    ungueltig(`${gut}pull_count=1\0\n`);
    ungueltig('');
    ungueltig('\n\n');
    // ein Zeitpunkt knapp in der Zukunft (Uhr des NAS geht etwas vor) ist erlaubt
    expect(parseNasStatus(`pull_result=ok\npull_success_epoch=${sec(NOW) + 1800}\n`, NOW).configured).toBe(true);
  });

  it('unbekannte, aber gut geformte Schlüssel einer neueren Fassung werden ignoriert, nie angezeigt', () => {
    const n = parseNasStatus(nasText(NOW, { pullH: 2, extra: 'zukunft=42' }), NOW);
    expect(n.configured).toBe(true);
    expect(JSON.stringify(n)).not.toContain('zukunft');
    expect(Object.keys(n).sort()).toEqual(['configured', 'invalid', 'pull', 'receivedAt', 'restore']);
  });

  it('Windows-Zeilenenden und fehlende letzte Zeile werden vertragen', () => {
    expect(parseNasStatus(nasText(NOW, { pullH: 2 }).replace(/\n/g, '\r\n'), NOW).pull.state).toBe('ok');
    expect(parseNasStatus(nasText(NOW, { pullH: 2 }).trimEnd(), NOW).pull.state).toBe('ok');
  });
});

describe('Warn-Bedingungen der NAS-Rückmeldung (rein)', () => {
  function status(nas = NAS_ABSENT): OperatorStatus {
    return {
      generatedAt: NOW.toISOString(),
      overall: 'ok',
      unknownCount: 0,
      server: { version: '0.7.0', protocolVersion: 1, startedAt: NOW.toISOString(), uptimeSec: 1, memoryRssMb: 1 },
      database: { ok: true, latencyMs: 1, sizeBytes: 1, migrations: { applied: 1, expected: 1, latest: 'x', pending: false, grantMissing: false } },
      services: [{ id: 'ntfy', state: 'ok', detail: {} }],
      backup: { state: 'ok', lastSuccessAt: new Date(NOW.getTime() - 5 * HOUR).toISOString(), ageHours: 5, totalBytes: 1, lastResult: 'ok' },
      nas,
      disk: { totalBytes: 100, freeBytes: 50, usedPercent: 50 },
      certificate: { validTo: new Date(NOW.getTime() + 60 * DAY).toISOString(), daysLeft: 60 },
      counts: { members: 1, devices: 1, pushDevices: 1, activeSessions: 1 },
      versions: { server: '0.7.0', web: null, app: null, minAppVersion: '0.1.0' },
      features: { pwBackup: true, legacyPasswordLogin: true, weather: false, push: true, map: { available: false, sizeBytes: null } },
    } as OperatorStatus;
  }
  const erg = (nas: ReturnType<typeof parseNasStatus>) => Object.fromEntries(evaluateConditions(status(nas), 0, null, NOW).map((c) => [c.key, c.result]));

  it('Karenz: nicht eingerichtet oder ungültig ist "unbekannt" und warnt nie', () => {
    expect(erg(NAS_ABSENT)).toMatchObject({ nas_pull: 'unknown', nas_restore: 'unknown' });
    expect(erg(parseNasStatus('Müll', NOW))).toMatchObject({ nas_pull: 'unknown', nas_restore: 'unknown' });
    // eingerichtet, aber noch kein Wiederherstellungstest gemeldet: nur die Abholung zählt
    expect(erg(parseNasStatus(nasText(NOW, { pullH: 3 }), NOW))).toMatchObject({ nas_pull: 'ok', nas_restore: 'unknown' });
  });

  it('Stiller Ausfall des Kanals: nach der ersten gültigen Datei ist Verschwinden oder Ungültigkeit eine Warnung, davor nie', () => {
    const kanal = (nas: ReturnType<typeof parseNasStatus>, gesehen: boolean) => evaluateConditions(status(nas), 0, null, NOW, gesehen).find((c) => c.key === 'nas_channel')?.result;
    expect(kanal(NAS_ABSENT, false)).toBe('unknown');
    expect(kanal(parseNasStatus('Müll', NOW), false)).toBe('unknown');
    expect(kanal(NAS_ABSENT, true)).toBe('active');
    expect(kanal(parseNasStatus('Müll', NOW), true)).toBe('active');
    expect(kanal(parseNasStatus(nasText(NOW, { pullH: 2 }), NOW), true)).toBe('ok');
    expect(kanal(parseNasStatus(nasText(NOW, { pullH: 2 }), NOW), false)).toBe('ok');
  });

  it('Grenzen: Abholung 36 Stunden, Wiederherstellungstest 10 Tage, Fehlschlag', () => {
    const e = (o: Parameters<typeof nasText>[1]) => erg(parseNasStatus(nasText(NOW, o), NOW));
    expect(e({ pullH: 36, restoreH: 240 })).toMatchObject({ nas_pull: 'ok', nas_restore: 'ok' });
    expect(e({ pullH: 37, restoreH: 241 })).toMatchObject({ nas_pull: 'active', nas_restore: 'active' });
    expect(e({ pullH: 3, pull: 'fehler', restoreH: 3, restore: 'fehler' })).toMatchObject({ nas_pull: 'active', nas_restore: 'active' });
  });
});

// ---------------------------------------------------------------------------------------------------------------------------------- mit Datenbank

describe.each(backends)('Betrieb Paket 3, Backups ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let nas: string | null;
  let aktuell: Partial<Probes>;
  const umschaltbar: Probes = {
    readText: (p, m) => aktuell.readText!(p, m),
    disk: (p) => aktuell.disk!(p),
    karteBytes: (d) => aktuell.karteBytes!(d),
    dirBytes: async () => null,
    tlsValidTo: (x, s) => aktuell.tlsValidTo!(x, s),
    ntfyReachable: (u) => aktuell.ntfyReachable!(u),
  };
  let wecker: Array<{ topic: string; body: string }>;
  const fakeFetch: typeof fetch = async (url, init) => {
    wecker.push({ topic: String(url).split('/').pop() ?? '', body: String(init?.body ?? '') });
    return new Response('{}', { status: 200 });
  };
  const nowDate = () => new Date(world.clock);
  function messungen(): Partial<Probes> {
    return {
      readText: async (path) => {
        const now = world.clock;
        if (path.endsWith('backup.status')) return `last_result=ok\nlast_success_epoch=${Math.floor(now / 1000) - 5 * 3600}\ntotal_bytes=617472\n`;
        if (path.endsWith('nas.status')) return nas;
        return null;
      },
      disk: async () => ({ totalBytes: 100, freeBytes: 59 }),
      karteBytes: async () => 1,
      tlsValidTo: async () => new Date(world.clock + 85 * DAY),
      ntfyReachable: async () => true,
    };
  }

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
    nas = null;
    world = await World.create(harness.db, ENV, { operatorProbes: umschaltbar, pushFetch: fakeFetch });
    aktuell = messungen();
  });

  async function betreiber() {
    const a = await adminPassword(world);
    const zweiter = await addMember(world, a.client, 'admin', 'admin2@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    await grantOperator(world.auth.ctx, a.email);
    expect((await a.client.put('/api/v1/me/push', { endpoint: `https://${HOST}/${topic(1)}?up=1` })).status).toBe(200);
    return { a, zweiter, kind };
  }
  const statusVon = async (c: Client) => (await c.get('/api/v1/admin/status?fresh=1')).json;
  const monitor = () => world.app.operatorMonitor!;

  it('nicht eingerichtet: "nas" ist leer und unbekannt, die Gesamtampel und die Zahl der unbekannten Quellen bleiben unverändert', async () => {
    const { a } = await betreiber();
    const s = await statusVon(a.client);
    expect(s.nas).toMatchObject({ configured: false, invalid: false, receivedAt: null, pull: { state: 'unknown', result: null }, restore: { state: 'unknown', result: null } });
    const vorher = { overall: s.overall, unknown: s.unknownCount };
    nas = nasText(nowDate(), { pullH: 3, restoreH: 48 });
    world.advance(20_000);
    const s2 = await statusVon(a.client);
    expect(s2.nas.configured).toBe(true);
    expect({ overall: s2.overall, unknown: s2.unknownCount }).toEqual(vorher);
  });

  it('Anzeige: nur feste Felder, nie Rohtext, Pfade oder unbekannte Schlüssel', async () => {
    const { a } = await betreiber();
    nas = nasText(nowDate(), { pullH: 3, restoreH: 48, extra: 'geheim_zukunft=42' });
    const s = await statusVon(a.client);
    expect(Object.keys(s.nas).sort()).toEqual(['configured', 'invalid', 'pull', 'receivedAt', 'restore']);
    expect(Object.keys(s.nas.pull).sort()).toEqual(['ageHours', 'count', 'lastRunAt', 'lastSuccessAt', 'newestBackupAt', 'result', 'state']);
    expect(Object.keys(s.nas.restore).sort()).toEqual(['ageDays', 'configChecked', 'lastRunAt', 'lastSuccessAt', 'result', 'state']);
    expect(JSON.stringify(s)).not.toMatch(/geheim_zukunft|nas\.status|\/var\//);
  });

  it('eine ungültige Datei ergibt "ungültig" ohne Alarm und ohne Einfluss auf die Gesamtampel', async () => {
    const { a } = await betreiber();
    const vorher = (await statusVon(a.client)).overall;
    nas = 'pull_result=ok\nsonst nichts erlaubtes\n';
    world.advance(20_000);
    const s = await statusVon(a.client);
    expect(s.nas).toMatchObject({ configured: false, invalid: true });
    expect(s.overall).toBe(vorher);
    expect((await monitor().runOnce()).notified).toEqual([]);
    expect(wecker).toEqual([]);
  });

  it('alte Abholung macht die Gesamtampel gelb und löst genau einen Wecker aus (ohne Inhalt), mit Protokolleintrag; Wiederholung bleibt aus', async () => {
    const { a } = await betreiber();
    nas = nasText(nowDate(), { pullH: 40, restoreH: 48 });
    expect((await statusVon(a.client)).overall).toBe('warn');
    expect((await monitor().runOnce()).notified).toEqual<AlertKind[]>(['nas_pull']);
    expect(wecker).toEqual([{ topic: topic(1), body: WAKE_BODY }]);
    expect((await auditEvents(world)).filter((e) => e.startsWith('operator_alert_'))).toEqual(['operator_alert_nas_pull']);
    world.advance(5 * MIN);
    nas = nasText(nowDate(), { pullH: 40, restoreH: 48 });
    expect((await monitor().runOnce()).notified).toEqual([]);
    const w = (await a.client.get('/api/v1/admin/warnings')).json;
    expect(w.active).toEqual([{ kind: 'nas_pull', since: expect.any(String), count: 1 }]);
    expect(JSON.stringify(wecker)).not.toMatch(/nas|Abholung|Sicherung/i);
  });

  it('alter oder fehlgeschlagener Wiederherstellungstest warnt; ein frischer nicht; noch kein Test (Karenz) warnt nie', async () => {
    const { a } = await betreiber();
    nas = nasText(nowDate(), { pullH: 3 }); // noch kein Test gemeldet
    expect((await monitor().runOnce()).notified).toEqual([]);
    nas = nasText(nowDate(), { pullH: 3, restoreH: 9 * 24 });
    world.advance(5 * MIN);
    nas = nasText(nowDate(), { pullH: 3, restoreH: 9 * 24 });
    expect((await monitor().runOnce()).notified).toEqual([]);
    world.advance(DAY * 2);
    nas = nasText(nowDate(), { pullH: 3, restoreH: 11 * 24 });
    expect((await monitor().runOnce()).notified).toEqual(['nas_restore']);
    expect(wecker).toHaveLength(1);
    // gemeldeter Fehlschlag nach erfolgreichem Test: nach der Entprellfrist (neue Episode) wieder
    world.advance(5 * MIN);
    nas = nasText(nowDate(), { pullH: 3, restoreH: 1 });
    await monitor().runOnce();
    world.advance(ALERT_DEBOUNCE_MS + MIN);
    nas = nasText(nowDate(), { pullH: 3, restoreH: 1, restore: 'fehler' });
    expect((await monitor().runOnce()).notified).toEqual(['nas_restore']);
    expect((await a.client.get('/api/v1/admin/warnings')).json.active.map((x: { kind: string }) => x.kind)).toEqual(['nas_restore']);
  });

  it('Kanal-Ausfall: vor der ersten gültigen Datei nie eine Warnung; danach meldet das Verschwinden genau einmal, auch nach einem Neustart des Prüfers', async () => {
    const { a } = await betreiber();
    nas = null;
    expect((await monitor().runOnce()).notified).toEqual([]); // nie eingerichtet
    nas = nasText(nowDate(), { pullH: 3, restoreH: 24 });
    expect((await monitor().runOnce()).notified).toEqual([]); // gültig: wird gemerkt
    world.advance(5 * MIN);
    nas = null; // Datei verschwindet
    expect((await monitor().runOnce()).notified).toEqual(['nas_channel']);
    expect((await auditEvents(world)).filter((e) => e.startsWith('operator_alert_'))).toEqual(['operator_alert_nas_channel']);
    const w = (await a.client.get('/api/v1/admin/warnings')).json;
    expect(w.active).toEqual([{ kind: 'nas_channel', since: expect.any(String), count: 1 }]);
    // der gemerkte Zustand steht in der Datenbank: ein neuer Prüfer wiederholt nichts, "nas_seen" taucht nie in der Anzeige auf
    const neu = new OperatorMonitor({ ctx: world.auth.ctx, push: world.app.push, weather: world.app.weather, probes: umschaltbar });
    world.advance(5 * MIN);
    expect((await neu.runOnce()).notified).toEqual([]);
    expect(JSON.stringify((await a.client.get('/api/v1/admin/warnings')).json)).not.toContain('nas_seen');
    // ungültige Datei zählt wie ein Ausfall; eine gültige beendet ihn ohne Meldung
    world.advance(5 * MIN);
    nas = nasText(nowDate(), { pullH: 3, restoreH: 24 });
    expect((await neu.runOnce()).notified).toEqual([]);
    expect((await a.client.get('/api/v1/admin/warnings')).json.active).toEqual([]);
  });

  it('Rechte: nur der Betreiber sieht die Rückmeldung (Admin und Kind 404, ohne Sitzung 401)', async () => {
    const { a, zweiter, kind } = await betreiber();
    nas = nasText(nowDate(), { pullH: 3, restoreH: 48 });
    expect((await world.client().get('/api/v1/admin/status')).status).toBe(401);
    for (const c of [zweiter.client, kind.client]) expect((await c.get('/api/v1/admin/status')).status).toBe(404);
    expect((await a.client.get('/api/v1/admin/status')).status).toBe(200);
  });
});
