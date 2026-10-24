// Betreiber-Rolle und Betreiber-Ansicht (/api/v1/admin/*, nur lesend): Rechte-Tabelle (nur Betreiber; alle anderen 404, ohne Sitzung 401),
// das Flag gibt keine Familienrechte, Step-up für das Protokoll, Familiengrenze, Seiten und Filter des Protokolls, gekürzte Netzadresse,
// keine Geheimnisse in den Antworten, CLI-Logik (grant/revoke), Status mit ersetzten Messungen.
import { eq, sql } from 'drizzle-orm';
import { readFileSync } from 'node:fs';
import { loadConfig } from '../src/config.js';
import { realProbes } from '../src/operator/probes.js';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import { categoryOf, shortenNetwork } from '../src/operator/audit-view.js';
import type { Probes } from '../src/operator/probes.js';
import { grantOperator, isOperator, listOperators, revokeOperator } from '../src/operator/service.js';
import { parseBackupStatus, parseManifest } from '../src/operator/status.js';
import { addMember, adminPassword, auditEvents, backends, TEST_KEY, World, type Harness } from './helpers.js';

const MIN = 60_000;
const GEHEIM = 'tk_geheimes-ntfy-token-123';
const ENV = { NTFY_URL: 'http://127.0.0.1:2586', NTFY_TOKEN: GEHEIM, OPERATOR_TLS_PROBE: '127.0.0.1:443' };

/** Ersetzte Messungen: nichts liest echte Dateien oder Netze. */
function probes(over: Partial<Probes> = {}): Partial<Probes> {
  const now = Date.parse('2026-10-19T08:00:00Z');
  return {
    readText: async (path) => {
      if (path.endsWith('backup.status')) return `last_run_epoch=${Math.floor(now / 1000) - 5 * 3600}\nlast_result=ok\nlast_success_epoch=${Math.floor(now / 1000) - 5 * 3600}\ntotal_bytes=617472\nlast_dir=GEHEIMER-PFAD\n`;
      if (path.endsWith('latest.json')) return JSON.stringify({ payload: JSON.stringify({ version: '0.6.1', versionCode: 6100, minVersion: '0.1.0', url: 'https://x/geheim.apk' }), signature: 'AAAA' });
      return null;
    },
    disk: async () => ({ totalBytes: 44_000_000_000, freeBytes: 26_000_000_000 }),
    karteBytes: async () => 1_100_000_000,
    tlsValidTo: async () => new Date(now + 85 * 86_400_000),
    ntfyReachable: async () => true,
    ...over,
  };
}

describe('Hilfsfunktionen', () => {
  it('kürzt Netzadressen (IPv4 /24, IPv6 /48) und ordnet Ereignisse Kategorien zu', () => {
    expect(shortenNetwork('203.0.113.77')).toBe('203.0.113.0/24');
    expect(shortenNetwork('::ffff:203.0.113.77')).toBe('203.0.113.0/24');
    expect(shortenNetwork('2a02:1234:5678:9abc:def0::1')).toBe('2a02:1234:5678::/48');
    expect(shortenNetwork(null)).toBeNull();
    expect(shortenNetwork('kein-ip')).toBeNull();
    expect(categoryOf('login_failed')).toBe('fehler');
    expect(categoryOf('login_ok')).toBe('anmeldung');
    expect(categoryOf('role_changed')).toBe('aenderungen');
    expect(categoryOf('session_refresh_retry')).toBe('anmeldung');
    expect(categoryOf('key_backup_read')).toBe('anmeldung');
    expect(categoryOf('irgendwas_neues')).toBe('aenderungen');
  });

  it('liest Sicherungs-Status und Manifest nur mit bekannten, geprüften Feldern', () => {
    expect(parseBackupStatus('last_result=ok\nlast_success_epoch=1700000000\ntotal_bytes=12\nx=y')).toEqual({ lastResult: 'ok', lastSuccessEpoch: 1700000000, totalBytes: 12 });
    expect(parseBackupStatus('last_success_epoch=abc\nlast_result=böse')).toEqual({ lastResult: null, lastSuccessEpoch: null, totalBytes: null });
    expect(parseManifest(JSON.stringify({ payload: JSON.stringify({ version: '1.2.3', versionCode: 5, minVersion: '0.1.0' }) }))).toEqual({ version: '1.2.3', versionCode: 5, minVersion: '0.1.0' });
    expect(parseManifest('kaputt')).toBeNull();
    expect(parseManifest(JSON.stringify({ payload: JSON.stringify({ version: '<script>' }) }))).toBeNull();
  });
});

describe.each(backends)('Betreiber-Ansicht ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  // die Messungen lassen sich je Test austauschen, ohne die Welt neu zu bauen (die Sitzungen bleiben)
  let aktuell: Partial<Probes> = probes();
  const umschaltbar: Probes = {
    readText: (p, m) => aktuell.readText!(p, m),
    disk: (p) => aktuell.disk!(p),
    karteBytes: (d) => aktuell.karteBytes!(d),
    dirBytes: (d, n) => (aktuell.dirBytes ? aktuell.dirBytes(d, n) : Promise.resolve(null)),
    tlsValidTo: (x, s) => aktuell.tlsValidTo!(x, s),
    ntfyReachable: (u) => aktuell.ntfyReachable!(u),
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
    aktuell = probes();
    world = await World.create(harness.db, ENV, { operatorProbes: umschaltbar });
  });

  /** Admin (zugleich Betreiber), zweiter Admin, Elternteil, Kind. */
  async function familie() {
    const a = await adminPassword(world);
    const zweiter = await addMember(world, a.client, 'admin', 'admin2@example.org');
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    await grantOperator(world.auth.ctx, a.email);
    return { a, zweiter, eltern, kind };
  }

  it('Rechte-Tabelle: nur der Betreiber; Admin, Eltern, Kind: 404; ohne Sitzung 401', async () => {
    const { a, zweiter, eltern, kind } = await familie();
    for (const url of ['/api/v1/admin/status', '/api/v1/admin/audit']) {
      expect((await world.client().get(url)).status, `${url} ohne Sitzung`).toBe(401);
      for (const [name, c] of [['zweiter Admin', zweiter.client], ['Eltern', eltern.client], ['Kind', kind.client]] as const) {
        const res = await c.get(url);
        expect(res.status, `${url} ${name}`).toBe(404);
        expect(res.json.error).toBe('not_found');
      }
      expect((await a.client.get(url)).status, `${url} Betreiber`).toBe(200);
    }
    // frisches Step-up hilft einem Nicht-Betreiber nicht
    expect((await zweiter.client.get('/api/v1/admin/audit')).status).toBe(404);
  });

  it('das Flag gibt keine Familienrechte: ein Elternteil als Betreiber bleibt Elternteil', async () => {
    const { eltern } = await familie();
    await grantOperator(world.auth.ctx, 'mama@example.org');
    expect((await eltern.client.get('/api/v1/admin/status')).status).toBe(200);
    // Rechte hängen nur an role: weder Admin-Einladung noch Mitglieder-Zurücksetzen noch Passwort-Modi
    expect((await eltern.client.post('/api/v1/invites', { role: 'admin' })).status).toBe(403);
    expect((await eltern.client.get('/api/v1/members/password-modes')).status).not.toBe(200);
    const me = (await eltern.client.get('/api/v1/me')).json;
    expect(me.user.role).toBe('parent');
    expect(me.operator).toBe(true);
  });

  it('/me meldet operator: true nur für Betreiber', async () => {
    const { a, zweiter, kind } = await familie();
    expect((await a.client.get('/api/v1/me')).json.operator).toBe(true);
    expect((await zweiter.client.get('/api/v1/me')).json.operator).toBe(false);
    expect((await kind.client.get('/api/v1/me')).json.operator).toBe(false);
  });

  it('es gibt keinen Weg über die API, die Rolle zu setzen (kein Schreib-Endpunkt)', async () => {
    const { a, zweiter } = await familie();
    for (const [m, u] of [['POST', '/api/v1/admin/operators'], ['PUT', '/api/v1/admin/operators'], ['PATCH', `/api/v1/members/${(await a.client.get('/api/v1/members')).json.members[0].id}`], ['POST', '/api/v1/admin/status']] as const) {
      const res = await zweiter.client.request(m, u, { body: { operator: true } });
      expect([404, 400, 405], `${m} ${u}`).toContain(res.status);
    }
    // auch ein "operator"-Feld im Profil ändert nichts
    await zweiter.client.patch('/api/v1/me', { displayName: 'Zwei', operator: true });
    expect(await isOperator(world.auth.ctx, (await zweiter.client.get('/api/v1/me')).json.user.id, (await zweiter.client.get('/api/v1/me')).json.familyId)).toBe(false);
  });

  it('Rolle entziehen: sofort wieder 404, Sitzung bleibt; Audit-Einträge; idempotent', async () => {
    const { a } = await familie();
    expect((await a.client.get('/api/v1/admin/status')).status).toBe(200);
    expect((await revokeOperator(world.auth.ctx, a.email)).changed).toBe(true);
    expect((await a.client.get('/api/v1/admin/status')).status).toBe(404);
    expect((await a.client.get('/api/v1/me')).status).toBe(200);
    expect((await revokeOperator(world.auth.ctx, a.email)).changed).toBe(false);
    expect((await grantOperator(world.auth.ctx, a.email)).changed).toBe(true);
    expect((await grantOperator(world.auth.ctx, a.email)).changed).toBe(false);
    const ev = await auditEvents(world);
    expect(ev.filter((e) => e === 'operator_granted')).toHaveLength(2);
    expect(ev.filter((e) => e === 'operator_revoked')).toHaveLength(1);
    expect((await listOperators(world.auth.ctx)).map((o) => o.email)).toEqual([a.email]);
  });

  it('grant: unbekannte E-Mail 404, gesperrtes Konto 409; Konto löschen entfernt die Zeile', async () => {
    const { a, kind } = await familie();
    await expect(grantOperator(world.auth.ctx, 'niemand@example.org')).rejects.toMatchObject({ status: 404 });
    const kindId = (await kind.client.get('/api/v1/me')).json.user.id as string;
    await world.db.update(schema.users).set({ disabledAt: new Date() }).where(eq(schema.users.id, kindId));
    await expect(grantOperator(world.auth.ctx, 'KIND@example.org')).rejects.toMatchObject({ status: 409 });
    // gesperrt nach der Vergabe: die Rolle gilt nicht mehr
    await grantOperator(world.auth.ctx, a.email);
    const adminId = (await a.client.get('/api/v1/me')).json.user.id as string;
    await world.db.update(schema.users).set({ disabledAt: new Date() }).where(eq(schema.users.id, adminId));
    expect(await isOperator(world.auth.ctx, adminId, (await world.db.select().from(schema.families))[0]!.id)).toBe(false);
    await world.db.delete(schema.users).where(eq(schema.users.id, adminId));
    expect(await world.count('operators')).toBe(0);
  });

  it('Protokoll braucht frisches Step-up (403 step_up_required), Status nicht', async () => {
    const { a, zweiter } = await familie();
    world.advance(6 * MIN);
    const alt = await a.client.get('/api/v1/admin/audit');
    expect(alt.status).toBe(403);
    expect(alt.json.error).toBe('step_up_required');
    expect((await a.client.get('/api/v1/admin/status')).status).toBe(200);
    // Nicht-Betreiber erfahren auch bei altem Step-up nichts: 404 statt 403
    expect((await zweiter.client.get('/api/v1/admin/audit')).status).toBe(404);
    expect((await a.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(a.totpSecret) })).status).toBe(200);
    expect((await a.client.get('/api/v1/admin/audit')).status).toBe(200);
  });

  it('Status: Inhalt, Zustände aus den Messungen, keine Geheimnisse', async () => {
    const { a } = await familie();
    const res = await a.client.get('/api/v1/admin/status');
    expect(res.status).toBe(200);
    const s = res.json;
    expect(s.server.version).toMatch(/^\d+\.\d+\.\d+$/);
    expect(s.database).toMatchObject({ ok: true });
    expect(s.database.migrations.expected).toBeGreaterThanOrEqual(18);
    expect(s.counts).toMatchObject({ members: 4, devices: 4 });
    expect(s.counts.activeSessions).toBeGreaterThanOrEqual(4);
    expect(s.backup).toMatchObject({ state: 'ok', ageHours: 5, totalBytes: 617472 });
    expect(s.disk).toEqual({ totalBytes: 44_000_000_000, freeBytes: 26_000_000_000, usedPercent: 41 });
    expect(s.versions.app).toEqual({ version: '0.6.1', versionCode: 6100, minVersion: '0.1.0' });
    expect(s.features).toMatchObject({ pwBackup: false, legacyPasswordLogin: true, weather: false, push: true, map: { available: true } });
    const svc = Object.fromEntries((s.services as Array<{ id: string; state: string }>).map((x) => [x.id, x.state]));
    expect(svc).toMatchObject({ api: 'ok', database: expect.stringMatching(/ok|warn/), weather: 'off', ntfy: 'ok', caddy: 'ok' });
    // keine Geheimnisse, Pfade oder Roh-Inhalte der Quellen in der Antwort
    const text = JSON.stringify(res.json);
    for (const verboten of [GEHEIM, 'GEHEIMER-PFAD', 'geheim.apk', 'AAAA', 'AUTH_SECRET', 'DATABASE_URL', 'postgres://', '/var/backups', 'secret']) {
      expect(text.toLowerCase(), verboten).not.toContain(verboten.toLowerCase());
    }
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('Status: nicht lesbare Quellen heißen "unbekannt", nie ein Fehler; ntfy nicht erreichbar ist "error"', async () => {
    const { a } = await familie();
    aktuell = probes({ readText: async () => null, disk: async () => null, karteBytes: async () => null, tlsValidTo: async () => null, ntfyReachable: async () => false });
    const s = (await a.client.get('/api/v1/admin/status')).json;
    expect(s.backup.state).toBe('unknown');
    expect(s.disk).toBeNull();
    expect(s.versions.app).toBeNull();
    expect(s.features.map.available).toBe(false);
    const svc = Object.fromEntries((s.services as Array<{ id: string; state: string }>).map((x) => [x.id, x.state]));
    expect(svc.ntfy).toBe('error');
    expect(svc.caddy).toBe('unknown');
    expect(s.overall).toBe('error');
  });

  it('Status: Sicherung zu alt oder fehlgeschlagen, Platte voll, Zertifikat bald ab', async () => {
    const { a } = await familie();
    const now = world.clock;
    const ep = Math.floor(now / 1000);
    const lauf = async (text: string) => {
      aktuell = probes({ readText: async (p) => (p.endsWith('backup.status') ? text : null), disk: async () => ({ totalBytes: 100, freeBytes: 10 }), tlsValidTo: async () => new Date(now + 3 * 86_400_000) });
      world.advance(16_000); // Status-Cache (15 s) ablaufen lassen
      return (await a.client.get('/api/v1/admin/status')).json;
    };
    const warn = await lauf(`last_result=ok\nlast_success_epoch=${ep - 40 * 3600}\n`);
    expect(warn.backup.state).toBe('warn');
    expect(warn.disk.usedPercent).toBe(90);
    expect([2, 3]).toContain(warn.certificate.daysLeft);
    // exaktes Alter statt gerundeter Stunden (dieselbe Grenze wie die Warnung): 36 h 20 min ist schon zu alt, 35 h 40 min noch nicht; Platte erst über 85 %
    expect((await lauf(`last_result=ok
last_success_epoch=${ep - 36 * 3600 - 20 * 60}
`)).backup.state).toBe('warn');
    expect((await lauf(`last_result=ok
last_success_epoch=${ep - 35 * 3600 - 40 * 60}
`)).backup.state).toBe('ok');
    const fehler = await lauf(`last_result=fehler\nlast_success_epoch=${ep - 3600}\n`);
    expect(fehler.backup.state).toBe('error');
    expect(fehler.overall).toBe('error');
  });

  it('Status: Migrationsstand wird gelesen, ausstehende Migration erkannt, fehlende Leserechte heißen "unbekannt" mit Hinweis', async () => {
    const { a } = await familie();
    const m1 = (await a.client.get('/api/v1/admin/status')).json.database.migrations;
    expect(m1.applied).toBe(m1.expected);
    expect(m1).toMatchObject({ pending: false, grantMissing: false, latest: expect.stringContaining('_') });
    // letzte Migration "zurücknehmen": ausstehend
    const letzte = (await world.db.execute<{ id: number; hash: string; created_at: string }>(sql`select id, hash, created_at from drizzle.__drizzle_migrations order by id desc limit 1`)).rows[0]!;
    await world.db.execute(sql`delete from drizzle.__drizzle_migrations where id = ${letzte.id}`);
    world.advance(16_000);
    const m2 = (await a.client.get('/api/v1/admin/status')).json.database.migrations;
    expect(m2).toMatchObject({ applied: m1.applied - 1, pending: true });
    // die Laufzeitrolle ohne Grant: Stand unbekannt, Hinweis grantMissing (kein 500)
    await world.db.execute(sql.raw('drop role if exists lx_rt_test'));
    await world.db.execute(sql.raw('create role lx_rt_test nosuperuser'));
    const lesen = (grant: boolean) =>
      world.db.transaction(async (tx) => {
        if (grant) {
          // genau die Anweisungen aus deploy/einrichtung-auth.sh
          const skript = readFileSync(new URL('../../deploy/einrichtung-auth.sh', import.meta.url), 'utf8');
          for (const m of skript.matchAll(/^ +(GRANT [^;]+);$/gm)) if (m[1]!.includes('drizzle')) await tx.execute(sql.raw(m[1]!.replaceAll('$RUNTIME_ROLE', 'lx_rt_test')));
        }
        await tx.execute(sql.raw('set local role lx_rt_test'));
        const r = await tx.execute<{ n: number }>(sql`select count(*)::int as n from drizzle.__drizzle_migrations`);
        return r.rows[0]?.n;
      });
    // Migrationszeile wieder einsetzen (die Tabelle liegt außerhalb der Test-Zurücksetzung)
    await world.db.execute(sql`insert into drizzle.__drizzle_migrations (id, hash, created_at) values (${letzte.id}, ${letzte.hash}, ${letzte.created_at})`);
    await expect(lesen(false)).rejects.toBeTruthy();
    expect(await lesen(true)).toBe(m1.applied);
    await world.db.execute(sql.raw('drop owned by lx_rt_test'));
    await world.db.execute(sql.raw('drop role lx_rt_test'));
  });

  it('Status: wird 15 s zwischengespeichert; "fresh" umgeht den Cache höchstens alle 5 s', async () => {
    const { a } = await familie();
    let n = 0;
    aktuell = probes({ ntfyReachable: async () => (n++, true) });
    await a.client.get('/api/v1/admin/status');
    await a.client.get('/api/v1/admin/status');
    expect(n).toBe(1);
    await a.client.get('/api/v1/admin/status?fresh=1');
    expect(n).toBe(1);
    world.advance(6000);
    await a.client.get('/api/v1/admin/status?fresh=1');
    expect(n).toBe(2);
    world.advance(10_000);
    await a.client.get('/api/v1/admin/status');
    expect(n).toBe(2);
    world.advance(6000);
    await a.client.get('/api/v1/admin/status');
    expect(n).toBe(3);
    expect((await a.client.get('/api/v1/admin/status?fresh=2')).status).toBe(400);
  });

  it('Status: nicht messbare Quellen zählen als unbekannt, nicht als "in Ordnung"', async () => {
    const { a } = await familie();
    aktuell = probes({ readText: async () => null, disk: async () => null, tlsValidTo: async () => null });
    const s = (await a.client.get('/api/v1/admin/status')).json;
    expect(s.overall).toBe('ok');
    expect(s.unknownCount).toBeGreaterThanOrEqual(3);
    aktuell = probes();
    world.advance(16_000);
    expect((await a.client.get('/api/v1/admin/status')).json.unknownCount).toBe(0);
  });

  it('TLS-Prüfung: ungültiger Port in der Konfiguration bricht den Start ab, die Messung wirft nie', async () => {
    expect(() => loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, OPERATOR_TLS_PROBE: '127.0.0.1:70000' })).toThrow(/OPERATOR_TLS_PROBE/);
    expect(() => loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, OPERATOR_TLS_PROBE: 'kein port' })).toThrow(/OPERATOR_TLS_PROBE/);
    expect(await realProbes.tlsValidTo('127.0.0.1:99999', 'familyhub.lx-labs.dev')).toBeNull();
    expect(await realProbes.tlsValidTo('127.0.0.1:1', 'familyhub.lx-labs.dev')).toBeNull();
  });

  describe('Protokoll', () => {
    async function betreiber() {
      const f = await familie();
      return f.a.client;
    }

    it('liefert nur Art, Zeit, Person und gekürzte Netzadresse, nie detail', async () => {
      const c = await betreiber();
      const res = await c.get('/api/v1/admin/audit?limit=100');
      expect(res.status).toBe(200);
      const items = res.json.items as Array<Record<string, unknown>>;
      expect(items.length).toBeGreaterThan(3);
      for (const it of items) {
        expect(Object.keys(it).sort()).toEqual(['actor', 'at', 'category', 'event', 'id', 'network']);
        if (it.network !== null) expect(it.network).toMatch(/^203\.0\.113\.0\/24$/);
      }
      const text = JSON.stringify(res.json);
      expect(text).not.toContain('203.0.113.10');
      expect(text).not.toContain('detail');
      expect(text).not.toContain('@example.org');
      // absteigend nach Zeit
      const zeiten = items.map((i) => Date.parse(i.at as string));
      expect([...zeiten].sort((x, y) => y - x)).toEqual(zeiten);
    });

    it('Seiten per Cursor ohne Doppelte und Lücken; Kategorien filtern', async () => {
      const c = await betreiber();
      const alle = (await c.get('/api/v1/admin/audit?limit=100')).json.items as Array<{ id: string }>;
      const gesehen: string[] = [];
      let cursor: string | null = null;
      let seiten = 0;
      do {
        const r = await c.get(`/api/v1/admin/audit?limit=3${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
        gesehen.push(...r.json.items.map((i: { id: string }) => i.id));
        cursor = r.json.nextCursor;
        seiten++;
      } while (cursor && seiten < 50);
      expect(gesehen).toEqual(alle.map((i) => i.id));
      expect(seiten).toBeGreaterThan(1);
      // Fehler: ein falsches Passwort erzeugt login_failed
      await world.client('198.51.100.7').post('/api/v1/auth/login/password', { email: 'admin@example.org', password: 'falsch-falsch-falsch-1', totp: '000000' });
      const fehler = (await c.get('/api/v1/admin/audit?category=fehler')).json.items as Array<{ event: string; category: string; network: string | null }>;
      expect(fehler.length).toBeGreaterThan(0);
      expect(fehler.every((i) => i.category === 'fehler')).toBe(true);
      expect(fehler.some((i) => i.network === '198.51.100.0/24')).toBe(true);
      const anmeldung = (await c.get('/api/v1/admin/audit?category=anmeldung&limit=100')).json.items as Array<{ category: string }>;
      expect(anmeldung.length).toBeGreaterThan(0);
      expect(anmeldung.every((i) => i.category === 'anmeldung')).toBe(true);
      const aender = (await c.get('/api/v1/admin/audit?category=aenderungen&limit=100')).json.items as Array<{ event: string }>;
      expect(aender.some((i) => i.event === 'operator_granted')).toBe(true);
      expect(aender.every((i) => !['login_ok', 'login_failed'].includes(i.event))).toBe(true);
    });

    it('prüft die Eingabe (Kategorie, Limit, Cursor, unbekannte Parameter) mit 400 ohne interne Details', async () => {
      const c = await betreiber();
      for (const q of ['category=alles', 'limit=0', 'limit=101', 'limit=abc', 'cursor=1%27%3B%20drop%20table', 'cursor=2026-10-19T08:00:00.000000Z', 'x=1']) {
        const res = await c.get(`/api/v1/admin/audit?${q}`);
        expect(res.status, q).toBe(400);
        expect(JSON.stringify(res.json)).not.toMatch(/zod|sql|select|stack/i);
      }
    });

    it('Person nur, wenn sie Mitglied der Sitzungsfamilie ist (sonst ohne Person)', async () => {
      const c = await betreiber();
      const [fremd] = await world.db.insert(schema.families).values({ name: 'Fremd2' }).returning({ id: schema.families.id });
      const [u] = await world.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'FremdeFrau' }).returning({ id: schema.users.id });
      await world.db.insert(schema.memberships).values({ familyId: fremd!.id, userId: u!.id, role: 'admin' });
      await world.db.insert(schema.auditLog).values({ familyId: null, actorId: u!.id, event: 'login_failed', ip: '192.0.2.77' });
      const res = await c.get('/api/v1/admin/audit?limit=100');
      expect(JSON.stringify(res.json)).not.toContain('FremdeFrau');
      expect((res.json.items as Array<{ event: string; actor: unknown; network: string }>).find((i) => i.network === '192.0.2.0/24')).toMatchObject({ event: 'login_failed', actor: null });
    });

    it('Familiengrenze: Einträge einer fremden Familie erscheinen nie; Einträge ohne Familie nur mit Art, Zeit und Netz', async () => {
      const c = await betreiber();
      const [fremd] = await world.db.insert(schema.families).values({ name: 'Fremd' }).returning({ id: schema.families.id });
      await world.db.insert(schema.auditLog).values([
        { familyId: fremd!.id, event: 'role_changed', ip: '192.0.2.99', detail: { geheim: 'FREMD-DETAIL' } },
        { familyId: null, event: 'ws_auth_failed', ip: '192.0.2.50', detail: { geheim: 'OHNE-FAMILIE' } },
      ]);
      const res = await c.get('/api/v1/admin/audit?limit=100');
      const text = JSON.stringify(res.json);
      expect(text).not.toContain('192.0.2.99');
      expect(text).not.toContain('FREMD-DETAIL');
      expect(text).not.toContain('OHNE-FAMILIE');
      const items = res.json.items as Array<{ event: string; network: string | null; actor: unknown }>;
      expect(items.filter((i) => i.event === 'role_changed')).toHaveLength(0);
      expect(items.find((i) => i.event === 'ws_auth_failed')).toMatchObject({ network: '192.0.2.0/24', actor: null });
    });
  });

  it('Fehlerantworten enthalten keine internen Details', async () => {
    const { zweiter } = await familie();
    const res = await zweiter.client.get('/api/v1/admin/status');
    expect(res.json).toEqual({ error: 'not_found', message: 'Nicht gefunden.' });
  });
});
