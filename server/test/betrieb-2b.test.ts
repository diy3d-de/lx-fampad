// Betreiber-Ansicht, Paket 2b: Konfiguration (nur sichere Ausschnitte), Wartungsmodus (sperrt Schreiben, Sync und neue Anmeldungen mit einer festen Antwort, lässt Lesen,
// bestehende Sitzungen und die Betreiber-Routen durch, mit automatischem Ende und Notausgang) und Familienhinweis (reiner Text, Ablauf, Version).
// Geprüft wird: Rechte-Tabelle (nur Betreiber, alle anderen 404, ohne Sitzung 401), Step-up, Eingabeprüfung, Audit (alter und neuer Zustand, nie der Text),
// Familiengrenze und dass die Konfiguration nie Geheimnisse oder Adressen mit Zugangsdaten enthält.
import { randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import WebSocket from 'ws';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import { blockedDuringMaintenance, MaintenanceGate, MAINTENANCE_MESSAGE, retryAfterSeconds } from '../src/operator/maintenance.js';
import { grantOperator } from '../src/operator/service.js';
import { clearMaintenanceAll, cleanNoticeText, NOTICE_MAX_CHARS } from '../src/operator/settings.js';
import { addMember, adminPassword, backends, World, type Harness } from './helpers.js';
import { deviceOf, upsert } from './sync-kit.js';

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const GEHEIM_TOKEN = 'tk_geheimes-ntfy-token-123';
const ENV = {
  NTFY_URL: 'http://127.0.0.1:2586',
  NTFY_TOKEN: GEHEIM_TOKEN,
  E2EE_PW_BACKUP: 'true',
  PUBLIC_URL: 'https://nutzer:passwort-im-url@familie.example.org/pfad?token=abc',
  DATABASE_URL: 'postgres://lx:datenbank-passwort@127.0.0.1:5432/x',
};

// ---------------------------------------------------------------------------------------------------------------------------------- reine Logik

describe('Hinweistext prüfen (rein)', () => {
  it('trimmt, normalisiert (NFC) und nimmt 1 bis 280 Zeichen', () => {
    expect(cleanNoticeText('  Wartung am Samstag  ')).toBe('Wartung am Samstag');
    expect(cleanNoticeText('A\u030a')).toBe('Å');
    expect(cleanNoticeText('x'.repeat(NOTICE_MAX_CHARS))).toHaveLength(NOTICE_MAX_CHARS);
    // 280 Zeichen mit Emoji (je ein Zeichen, aber zwei UTF-16-Einheiten)
    expect([...cleanNoticeText('😀'.repeat(NOTICE_MAX_CHARS))]).toHaveLength(NOTICE_MAX_CHARS);
  });

  it.each([
    ['leer', ''],
    ['nur Leerraum', '   '],
    ['281 Zeichen', 'x'.repeat(NOTICE_MAX_CHARS + 1)],
    ['281 Emoji', '😀'.repeat(NOTICE_MAX_CHARS + 1)],
    ['Zeilenumbruch', 'a\nb'],
    ['Tabulator', 'a\tb'],
    ['NUL', 'a\u0000b'],
    ['Steuerzeichen', 'a\u0007b'],
    ['Zeilentrenner', 'a\u2028b'],
    ['Richtungsumkehr', 'a\u202eb'],
    ['unsichtbares Zeichen', 'a\u200bb'],
  ])('lehnt ab: %s', (_name, text) => {
    expect(() => cleanNoticeText(text)).toThrow();
  });

  // unsichtbare Zeichen und Tag-Zeichen: mit Codepunkten gebaut, damit sie im Quelltext nicht unsichtbar stehen
  it.each([
    ['Tag-Zeichen U+E0041', 0xe0041],
    ['Tag-Zeichen U+E007F', 0xe007f],
    ['Combining Grapheme Joiner U+034F', 0x34f],
    ['Hangul-Füllzeichen U+115F', 0x115f],
    ['Hangul-Füllzeichen U+1160', 0x1160],
    ['Hangul Filler U+3164', 0x3164],
    ['Halfwidth Hangul Filler U+FFA0', 0xffa0],
    ['leeres Braille-Muster U+2800', 0x2800],
    ['Khmer U+17B4', 0x17b4],
    ['Khmer U+17B5', 0x17b5],
    ['Objekt-Ersatzzeichen U+FFFC', 0xfffc],
    ['LRM U+200E', 0x200e],
    ['RLM U+200F', 0x200f],
    ['Null-Breite-Leerzeichen U+200B', 0x200b],
    ['Word Joiner U+2060', 0x2060],
    ['BOM U+FEFF', 0xfeff],
  ])('lehnt unsichtbares Zeichen ab: %s', (_name, cp) => {
    expect(() => cleanNoticeText('Hallo ' + String.fromCodePoint(cp) + ' Welt')).toThrow(expect.objectContaining({ status: 400, code: 'invalid_notice' }));
  });

  it('erlaubt ZWJ und ZWNJ (Familien-Emoji) und Variationsselektoren', () => {
    const zwj = String.fromCodePoint(0x200d);
    const familie = ['👨', '👩', '👧'].join(zwj);
    expect(cleanNoticeText('Familie ' + familie)).toBe('Familie ' + familie);
    const herz = '❤' + String.fromCodePoint(0xfe0f);
    expect(cleanNoticeText('Danke ' + herz)).toContain('Danke');
    expect(cleanNoticeText('a' + String.fromCodePoint(0x200c) + 'b')).toHaveLength(3);
  });

  it.each([
    'Mehr auf https://lx-labs.dev',
    'http://example.org',
    'ftp://x',
    'Siehe www.beispiel',
    'WWW.X.DE',
    'gehe auf lx-labs.dev',
    'mail an info.familie.de bitte',
    'login.example.com öffnen',
  ])('lehnt Links ab: %s', (text) => {
    expect(() => cleanNoticeText(text)).toThrow(expect.objectContaining({ status: 400, code: 'notice_link' }));
  });

  it('normale Sätze mit Punkten bleiben möglich', () => {
    for (const text of ['Wartung z. B. am Sa. um 9.30 Uhr', 'Ca. 2 Std., danach geht es wieder.', 'Version 1.2.3 kommt', 'Ende.Fertig']) {
      expect(cleanNoticeText(text)).toBe(text);
    }
  });
});

const FAMILIE = ['👨', '👩', '👧'].join(String.fromCodePoint(0x200d));

describe('Wartung: Retry-After (rein)', () => {
  it('höchstens 60 Sekunden, kurz vor dem Ende nur noch der Rest, mindestens 1', () => {
    const jetzt = new Date('2026-10-22T10:00:00Z');
    expect(retryAfterSeconds(null, jetzt)).toBe(60);
    expect(retryAfterSeconds(new Date('2026-10-22T12:00:00Z'), jetzt)).toBe(60);
    expect(retryAfterSeconds(new Date('2026-10-22T10:00:30Z'), jetzt)).toBe(30);
    expect(retryAfterSeconds(new Date('2026-10-22T10:00:00.400Z'), jetzt)).toBe(1);
    expect(retryAfterSeconds(new Date('2026-10-22T09:59:00Z'), jetzt)).toBe(1);
  });
});

describe('Wartung: welche Anfragen gesperrt sind (rein)', () => {
  const sperre = (method: string, url: string | undefined) => blockedDuringMaintenance({ method, routeOptions: { url } as never });
  it('Lesen ist frei, Schreiben gesperrt, Betreiber-Routen und bestehende Sitzungen bleiben', () => {
    expect(sperre('GET', '/api/v1/me')).toBe(false);
    expect(sperre('HEAD', '/api/v1/me')).toBe(false);
    expect(sperre('POST', '/api/v1/sync')).toBe(true);
    expect(sperre('PATCH', '/api/v1/me')).toBe(true);
    expect(sperre('PUT', '/api/v1/me/push')).toBe(true);
    expect(sperre('DELETE', '/api/v1/devices/:id')).toBe(true);
    // neue Anmeldungen und Einladungen
    for (const u of ['/api/v1/auth/login/password', '/api/v1/auth/login/passkey/options', '/api/v1/auth/login/passkey/verify', '/api/v1/auth/login/recovery', '/api/v1/auth/invites/lookup', '/api/v1/auth/invites/password/start', '/api/v1/auth/password-reset/recovery']) {
      expect(sperre('POST', u), u).toBe(true);
    }
    // Betreiber, Sitzung erhalten und beenden, Bestätigung, WebSocket-Ticket
    for (const u of ['/api/v1/admin/maintenance', '/api/v1/admin/notice', '/api/v1/admin/members/:id/unlock', '/api/v1/auth/refresh', '/api/v1/auth/logout', '/api/v1/auth/logout-all', '/api/v1/auth/step-up/code', '/api/v1/auth/step-up/passkey/options', '/api/v1/auth/step-up/passkey/verify', '/api/v1/ws-ticket']) {
      expect(sperre(u.startsWith('/api/v1/admin/') ? 'PUT' : 'POST', u), u).toBe(false);
    }
    // unbekannte Routen (404) und Nicht-API bleiben, wie sie sind
    expect(sperre('POST', undefined)).toBe(false);
    expect(sperre('POST', '/')).toBe(false);
  });

  it('Tor: fällt die Datenbank aus, gilt der zuletzt bekannte Stand (nie ein Fehler, nie "gesperrt ohne Grund")', async () => {
    let fail = false;
    let rows: Array<{ until: Date | null }> = [];
    const db = {
      select: () => ({
        from: () => ({
          where: async () => {
            if (fail) throw new Error('Datenbank weg');
            return rows;
          },
        }),
      }),
    };
    const warnungen: unknown[] = [];
    let jetzt = new Date('2026-10-22T10:00:00Z');
    const gate = new MaintenanceGate({ db: db as never, now: () => jetzt, log: { warn: (o) => warnungen.push(o), error: () => undefined } });
    fail = true;
    expect(await gate.current()).toBeNull(); // nie gelesen: nicht gesperrt
    expect(warnungen).toHaveLength(1);
    fail = false;
    rows = [{ until: null }];
    gate.invalidate();
    expect(await gate.current()).toEqual({ until: null });
    fail = true;
    gate.invalidate();
    expect(await gate.current()).toEqual({ until: null }); // gelesener Stand bleibt
    expect(warnungen).toHaveLength(2);
    // Ablauf mit der Uhr: "until" in der Vergangenheit zählt nicht mehr
    fail = false;
    rows = [{ until: new Date('2026-10-22T11:00:00Z') }];
    gate.invalidate();
    expect(await gate.current()).toEqual({ until: new Date('2026-10-22T11:00:00Z') });
    jetzt = new Date('2026-10-22T11:00:00Z');
    expect(await gate.current()).toBeNull();
  });

  it('Tor: wird während eines laufenden Lesevorgangs geschaltet, gilt danach der neue Stand (kein veralteter Zwischenspeicher)', async () => {
    // jeder Lesevorgang wartet auf sein eigenes Freigabe-Signal und liefert den Stand, den er beim Start sah
    const lesevorgaenge: Array<{ rows: Array<{ until: Date | null }>; frei: () => void; fertig: Promise<void> }> = [];
    let stand: Array<{ until: Date | null }> = [];
    const db = {
      select: () => ({
        from: () => ({
          where: () => {
            const rows = stand;
            let frei!: () => void;
            const fertig = new Promise<void>((resolve) => (frei = resolve));
            lesevorgaenge.push({ rows, frei, fertig });
            return fertig.then(() => rows);
          },
        }),
      }),
    };
    const gate = new MaintenanceGate({ db: db as never, now: () => new Date('2026-10-22T10:00:00Z'), log: { warn: () => undefined, error: () => undefined } });
    const bis = new Date('2026-10-22T12:00:00Z');
    const abfrage = gate.current(); // Lesevorgang 1 sieht "aus" und hängt
    await new Promise((r) => setTimeout(r, 5));
    expect(lesevorgaenge).toHaveLength(1);
    stand = [{ until: bis }]; // der Betreiber schaltet ein ...
    gate.invalidate(); // ... und leert den Zwischenspeicher, während Lesevorgang 1 noch läuft
    lesevorgaenge[0]!.frei(); // Lesevorgang 1 endet mit dem ALTEN Stand: er darf nicht festgeschrieben werden
    await new Promise((r) => setTimeout(r, 5));
    expect(lesevorgaenge).toHaveLength(2); // der Durchlauf liest neu
    lesevorgaenge[1]!.frei();
    expect(await abfrage).toEqual({ until: bis });
    // und der Zwischenspeicher hält den neuen Stand (kein weiterer Lesevorgang)
    expect(await gate.current()).toEqual({ until: bis });
    expect(lesevorgaenge).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------------------------------------------------------------- Server

describe.each(backends)('Betreiber Paket 2b ($name)', (backend) => {
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
    world = await World.create(harness.db, ENV);
  });

  type Person = Awaited<ReturnType<typeof addMember>> | Awaited<ReturnType<typeof adminPassword>>;
  /** Admin (Betreiber), zweiter Admin, Elternteil, Kind. */
  async function familie() {
    const a = await adminPassword(world);
    const zweiter = await addMember(world, a.client, 'admin', 'admin2@example.org');
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    await grantOperator(world.auth.ctx, a.email);
    return { a, zweiter, eltern, kind };
  }
  async function stepUp(p: Person) {
    world.advance(31_000);
    expect((await p.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(p.totpSecret) })).status).toBe(200);
  }
  const wartungAn = async (p: Person, body: Record<string, unknown> = { active: true }) => {
    await stepUp(p);
    return p.client.put('/api/v1/admin/maintenance', body);
  };
  const syncMit = async (p: Person) => (await deviceOf(world, p.client)).sync([upsert('liste', randomUUID(), { name: 'Einkauf', kind: 'shopping', audience: 'family' })]);
  const audit = async (event: string) => (await world.db.select().from(schema.auditLog).where(eq(schema.auditLog.event, event as never))).sort((x, y) => x.createdAt.getTime() - y.createdAt.getTime());

  // ---- Rechte ----

  it('Rechte-Tabelle: nur der Betreiber; Admin, Eltern, Kind 404; ohne Sitzung 401; der Familienhinweis gilt für alle Angemeldeten', async () => {
    const { a, zweiter, eltern, kind } = await familie();
    const aufrufe: Array<[string, string, unknown?]> = [
      ['GET', '/api/v1/admin/config'],
      ['GET', '/api/v1/admin/settings'],
      ['PUT', '/api/v1/admin/maintenance', { active: true }],
      ['PUT', '/api/v1/admin/notice', { text: 'Hallo' }],
    ];
    for (const [m, u, body] of aufrufe) {
      expect((await world.client().request(m, u, body === undefined ? {} : { body })).status, `${m} ${u} ohne Sitzung`).toBe(401);
      for (const [name, c] of [['zweiter Admin', zweiter.client], ['Eltern', eltern.client], ['Kind', kind.client]] as const) {
        const res = await c.request(m, u, body === undefined ? {} : { body });
        expect(res.status, `${m} ${u} ${name}`).toBe(404);
        expect(res.json.error).toBe('not_found');
      }
    }
    // auch mit frischem Step-up bleibt es für Nicht-Betreiber 404, und nichts ändert sich
    await stepUp(zweiter);
    expect((await zweiter.client.put('/api/v1/admin/maintenance', { active: true })).status).toBe(404);
    expect((await zweiter.client.put('/api/v1/admin/notice', { text: 'Fremd' })).status).toBe(404);
    expect(await world.count('operator_settings')).toBe(0);
    for (const u of ['/api/v1/admin/config', '/api/v1/admin/settings']) expect((await a.client.get(u)).status, u).toBe(200);
    // der Hinweis-Stand ist für jede angemeldete Person lesbar, ohne Sitzung nicht
    expect((await world.client().get('/api/v1/family-notice')).status).toBe(401);
    for (const p of [a, zweiter, eltern, kind]) {
      const res = await p.client.get('/api/v1/family-notice');
      expect(res.status).toBe(200);
      expect(res.json).toEqual({ maintenance: { active: false, since: null, until: null }, notice: null });
    }
  });

  it('Step-up: Wartung und Hinweis brauchen ihn, Lesen (Konfiguration, Stand) nicht', async () => {
    const { a } = await familie();
    world.advance(6 * MIN);
    for (const [u, body] of [['/api/v1/admin/maintenance', { active: true }], ['/api/v1/admin/notice', { text: 'Hallo' }]] as const) {
      const res = await a.client.put(u, body);
      expect(res.status, u).toBe(403);
      expect(res.json.error).toBe('step_up_required');
    }
    expect(await world.count('operator_settings')).toBe(0);
    expect((await a.client.get('/api/v1/admin/config')).status).toBe(200);
    expect((await a.client.get('/api/v1/admin/settings')).status).toBe(200);
    await stepUp(a);
    expect((await a.client.put('/api/v1/admin/notice', { text: 'Hallo' })).status).toBe(200);
  });

  // ---- Konfiguration ----

  it('Konfiguration: Schalter und Limits, nie Geheimnisse, Zugangsdaten, Adressen oder Pfade', async () => {
    const { a } = await familie();
    const res = await a.client.get('/api/v1/admin/config');
    expect(res.status).toBe(200);
    const alle = (res.json.groups as Array<{ id: string; items: Array<{ key: string; value: unknown; unit?: string }> }>).flatMap((g) => g.items);
    const wert = (k: string) => alle.find((i) => i.key === k)?.value;
    expect(wert('E2EE_PW_BACKUP')).toBe(true);
    expect(wert('WEATHER_ENABLED')).toBe(false);
    expect(wert('NTFY')).toBe(true); // nur "eingerichtet", nie Adresse oder Token
    expect(wert('LOC_MAX_PER_MINUTE')).toBe(world.auth.ctx.config.locMaxPerMinute);
    expect(wert('SYNC_OPS_PER_DAY')).toBe(world.auth.ctx.config.syncOpsPerDay);
    // die Adresse nur als Herkunft, ohne Zugangsdaten, Pfad und Query
    expect(wert('PUBLIC_URL')).toBe('https://familie.example.org');
    const json = JSON.stringify(res.json);
    for (const verboten of [GEHEIM_TOKEN, '2586', 'passwort-im-url', 'nutzer', 'token=abc', 'datenbank-passwort', 'postgres://', world.auth.ctx.config.auth.secretKey.toString('base64'), world.auth.ctx.config.auth.secretKey.toString('hex')]) {
      expect(json, verboten).not.toContain(verboten);
    }
    // keine Schlüssel nach Geheimnissen und keine Pfade
    for (const i of alle) {
      expect(i.key, i.key).not.toMatch(/SECRET|PASSWORD_HASH|DATABASE|NTFY_TOKEN|NTFY_URL|FILE|DIR|MAC|BBOX|PLACE/);
      if (typeof i.value === 'string') expect(i.value, i.key).toMatch(/^[A-Za-z0-9._:/-]{1,80}$/);
    }
    // die Gruppen sind fest
    expect((res.json.groups as Array<{ id: string }>).map((g) => g.id)).toEqual(['switches', 'server', 'auth', 'sync', 'websocket', 'location', 'weather']);
  });

  // ---- Wartungsmodus ----

  it('Eingabeprüfung Wartung: Ende nur in der Zukunft und höchstens 72 Stunden, "aus" ohne Ende, nur bekannte Felder', async () => {
    const { a } = await familie();
    await stepUp(a);
    const now = world.clock;
    const iso = (ms: number) => new Date(now + ms).toISOString();
    for (const body of [
      {},
      { active: 'ja' },
      { active: true, extra: 1 },
      { active: true, until: iso(HOUR) }, // das Ende kommt nie als Uhrzeit vom Gerät
      { active: true, untilMinutes: 'morgen' },
      { active: true, untilMinutes: 0 },
      { active: true, untilMinutes: -5 },
      { active: true, untilMinutes: 1.5 },
      { active: true, untilMinutes: 72 * 60 + 1 },
      { active: false, untilMinutes: 60 },
    ]) {
      expect((await a.client.put('/api/v1/admin/maintenance', body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(await world.count('operator_settings')).toBe(0);
    const ok = await a.client.put('/api/v1/admin/maintenance', { active: true, untilMinutes: 72 * 60 });
    expect(ok.status).toBe(200);
    expect(ok.json.maintenance.until).toBe(new Date(world.clock + 72 * HOUR).toISOString());
    // die Fehlerantwort nennt den Grund (die App zeigt dazu eine eigene deutsche Meldung)
    expect((await a.client.put('/api/v1/admin/maintenance', { active: true, untilMinutes: 0 })).json.error).toBe('invalid_duration');
  });

  it('Wartung an: Sync, Schreiben und neue Anmeldungen bekommen 503 "maintenance" mit fester deutscher Meldung; Lesen, bestehende Sitzungen und Betreiber bleiben', async () => {
    const { a, eltern, kind } = await familie();
    expect((await syncMit(eltern)).status).toBe(200);
    const an = await wartungAn(a);
    expect(an.status).toBe(200);
    // ohne Angabe gilt das Höchstmaß von 72 Stunden: der Wartungsmodus hat immer ein Ende
    expect(an.json.maintenance).toMatchObject({ active: true, until: new Date(world.clock + 72 * HOUR).toISOString() });

    // gesperrt: Sync und andere schreibende Anfragen einer bestehenden Sitzung
    const s = await syncMit(eltern);
    expect(s.status).toBe(503);
    expect(s.json).toEqual({ maintenance: true, error: 'maintenance', message: MAINTENANCE_MESSAGE });
    expect(s.headers['retry-after']).toBe('60');
    expect((await eltern.client.patch('/api/v1/me', { displayName: 'Neu' })).status).toBe(503);
    expect((await eltern.client.put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(503);
    expect((await kind.client.post('/api/v1/invites', { role: 'child' })).status).toBe(503);
    // gesperrt: neue Anmeldungen und Einladungen einlösen (auch mit falschen Angaben: immer dieselbe Antwort, kein Hinweis auf das Konto)
    const frisch = world.client('203.0.113.77');
    for (const [u, body] of [
      ['/api/v1/auth/login/password', { email: 'mama@example.org', password: 'ein-sehr-langes-passwort-123', totp: '000000' }],
      ['/api/v1/auth/login/password', { email: 'gibt-es-nicht@example.org', password: 'x' }],
      ['/api/v1/auth/login/passkey/options', {}],
      ['/api/v1/auth/login/recovery', { email: 'mama@example.org', code: 'abc' }],
      ['/api/v1/auth/invites/lookup', { token: 'x'.repeat(30) }],
    ] as const) {
      const r = await frisch.post(u, body);
      expect(r.status, u).toBe(503);
      expect(r.json.error, u).toBe('maintenance');
    }
    // erreichbar: Lesen, die App-Startabfrage, der Hinweis-Stand, bestehende Sitzungen (Bestätigung, WebSocket-Ticket)
    expect((await eltern.client.get('/api/v1/me')).status).toBe(200);
    expect((await eltern.client.get('/api/v1/members')).status).toBe(200);
    const stand = await eltern.client.get('/api/v1/family-notice');
    expect(stand.status).toBe(200);
    expect(stand.json.maintenance).toMatchObject({ active: true });
    expect(typeof stand.json.maintenance.until).toBe('string');
    expect(typeof stand.json.maintenance.since).toBe('string');
    const version = await world.client().get('/api/v1/version');
    expect(version.json.maintenance).toBe(true);
    expect((await eltern.client.post('/api/v1/ws-ticket', {})).status).toBe(200);
    await stepUp(eltern);
    // unbekannte Routen bleiben 404 (nicht 503)
    expect((await eltern.client.post('/api/v1/gibt-es-nicht', {})).status).toBe(404);

    // fail-safe: der Betreiber erreicht seine Routen und schaltet selbst wieder aus
    expect((await a.client.get('/api/v1/admin/status')).status).toBe(200);
    expect((await a.client.get('/api/v1/admin/config')).status).toBe(200);
    await stepUp(a);
    const aus = await a.client.put('/api/v1/admin/maintenance', { active: false });
    expect(aus.status).toBe(200);
    expect(aus.json.maintenance).toEqual({ active: false, since: null, until: null });
    expect((await syncMit(eltern)).status).toBe(200);
    expect((await world.client().get('/api/v1/version')).json.maintenance).toBe(false);
    // die Anmeldung geht wieder (es kommt wieder die eigentliche Antwort, nicht 503)
    expect((await frisch.post('/api/v1/auth/login/password', { email: 'gibt-es-nicht@example.org', password: 'x' })).status).not.toBe(503);
  });

  it('Wartung: Abmelden bleibt möglich (die Sitzung geht nie verloren, weil der Server sperrt)', async () => {
    const { a, eltern } = await familie();
    expect((await wartungAn(a)).status).toBe(200);
    expect((await eltern.client.post('/api/v1/auth/logout', {})).status).toBe(200);
    expect((await eltern.client.get('/api/v1/me')).status).toBe(401);
  });

  it('Wartung: Retry-After endet mit der Wartung (höchstens 60 s, kurz vor dem Ende nur der Rest)', async () => {
    const { a, eltern } = await familie();
    expect((await wartungAn(a, { active: true, untilMinutes: 5 })).status).toBe(200);
    expect((await syncMit(eltern)).headers['retry-after']).toBe('60');
    world.advance(5 * MIN - 30_000);
    expect((await syncMit(eltern)).headers['retry-after']).toBe('30');
    world.advance(31_000);
    expect((await syncMit(eltern)).status).toBe(200);
  });

  it('Wartung: WebSocket und WS-Ticket laufen weiter (Lesen und Hinweise; nichts wird gespeichert)', async () => {
    const { a, eltern } = await familie();
    await world.app.listen({ host: '127.0.0.1', port: 0 });
    expect((await wartungAn(a)).status).toBe(200);
    const ticket = await eltern.client.post('/api/v1/ws-ticket', {});
    expect(ticket.status).toBe(200);
    const { port } = world.app.server.address() as AddressInfo;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.10' } });
    try {
      const nachrichten: Array<Record<string, unknown>> = [];
      ws.on('message', (raw: Buffer) => nachrichten.push(JSON.parse(raw.toString('utf8'))));
      await new Promise<void>((resolve, reject) => {
        ws.once('open', () => resolve());
        ws.once('error', reject);
        ws.once('unexpected-response', (_req, res) => reject(new Error(`Upgrade abgelehnt: ${res.statusCode}`)));
      });
      ws.send(JSON.stringify({ type: 'auth', ticket: ticket.json.ticket }));
      const ende = Date.now() + 5000;
      while (!nachrichten.some((m) => m.type === 'ready') && Date.now() < ende) await new Promise((r) => setTimeout(r, 10));
      expect(nachrichten.some((m) => m.type === 'ready')).toBe(true);
    } finally {
      ws.terminate();
    }
    // die Gegenprobe: schreibend bleibt es gesperrt
    expect((await syncMit(eltern)).status).toBe(503);
  });

  it('Wartung: automatisches Ende ("untilMinutes") und Notausgang (Server-CLI)', async () => {
    const { a, eltern } = await familie();
    const an = await wartungAn(a, { active: true, untilMinutes: 60 });
    const bis = new Date(world.clock + HOUR).toISOString();
    expect(an.json.maintenance).toMatchObject({ active: true, until: bis });
    expect((await syncMit(eltern)).status).toBe(503);
    world.advance(HOUR + MIN);
    // das Ende gilt von selbst (auch für die Anzeige), ohne dass jemand schaltet
    expect((await syncMit(eltern)).status).toBe(200);
    expect((await eltern.client.get('/api/v1/family-notice')).json.maintenance).toEqual({ active: false, since: null, until: null });

    // Notausgang: ohne Sitzung, protokolliert als "cli"
    expect((await wartungAn(a)).status).toBe(200);
    expect((await syncMit(eltern)).status).toBe(503);
    expect(await clearMaintenanceAll(world.auth.ctx)).toBe(true);
    world.app.maintenance?.invalidate();
    expect((await syncMit(eltern)).status).toBe(200);
    expect(await clearMaintenanceAll(world.auth.ctx)).toBe(false);
    const ereignisse = await audit('operator_maintenance_set');
    expect(ereignisse.at(-1)?.detail).toMatchObject({ from: true, to: false, via: 'cli' });
  });

  it('Wartung: Audit mit altem und neuem Zustand; "seit" bleibt beim erneuten Einschalten, bis ausgeschaltet wird', async () => {
    const { a } = await familie();
    const t0 = world.clock;
    const erst = await wartungAn(a);
    const since1 = erst.json.maintenance.since as string;
    expect(new Date(since1).getTime()).toBeGreaterThanOrEqual(t0);
    world.advance(10 * MIN);
    // erneut an (jetzt mit Ende): "seit" bleibt
    const zweit = await wartungAn(a, { active: true, untilMinutes: 60 });
    expect(zweit.json.maintenance.since).toBe(since1);
    await stepUp(a);
    expect((await a.client.put('/api/v1/admin/maintenance', { active: false })).status).toBe(200);
    const ereignisse = await audit('operator_maintenance_set');
    expect(ereignisse.map((e) => [(e.detail as { from: boolean }).from, (e.detail as { to: boolean }).to])).toEqual([
      [false, true],
      [true, true],
      [true, false],
    ]);
    expect((ereignisse[1]!.detail as { until: string | null }).until).not.toBeNull();
    expect(ereignisse.every((e) => e.actorId !== null && e.familyId !== null)).toBe(true);
    // die Antwort der Audit-Ansicht kennt die neuen Ereignisse als Änderungen
    await stepUp(a);
    const liste = (await a.client.get('/api/v1/admin/audit?category=aenderungen')).json.items as Array<{ event: string }>;
    expect(liste.some((i) => i.event === 'operator_maintenance_set')).toBe(true);
  });

  // ---- Familienhinweis ----

  it('Eingabeprüfung Hinweis: Text 1 bis 280 Zeichen, eine Zeile, reiner Text; Ablauf nur in der Zukunft und höchstens 90 Tage; nur bekannte Felder', async () => {
    const { a } = await familie();
    await stepUp(a);
    const iso = (ms: number) => new Date(world.clock + ms).toISOString();
    for (const body of [
      {},
      { text: '' },
      { text: '   ' },
      { text: 5 },
      { text: 'x'.repeat(NOTICE_MAX_CHARS + 1) },
      { text: 'zwei\nZeilen' },
      { text: 'umgekehrt \u202e Text' },
      { text: 'NUL \u0000' },
      { text: 'Hallo', extra: 1 },
      { text: 'Hallo', expiresAt: iso(DAY) }, // der Ablauf kommt nie als Uhrzeit vom Gerät
      { text: 'Hallo', expiresInMinutes: 'bald' },
      { text: 'Hallo', expiresInMinutes: 0 },
      { text: 'Hallo', expiresInMinutes: -1 },
      { text: 'Hallo', expiresInMinutes: 1.5 },
      { text: 'Hallo', expiresInMinutes: 90 * 24 * 60 + 1 },
      { text: null, expiresInMinutes: 60 },
      { text: 'Mehr unter https://lx-labs.dev' },
      { text: 'Bitte auf lx-labs.dev gehen' },
      { text: 'Tag ' + String.fromCodePoint(0xe0041) + ' Zeichen' },
    ]) {
      expect((await a.client.put('/api/v1/admin/notice', body)).status, JSON.stringify(body)).toBe(400);
    }
    // klare Gründe (die App zeigt dazu eigene deutsche Meldungen)
    const code = async (body: unknown) => (await a.client.put('/api/v1/admin/notice', body)).json.error;
    expect(await code({ text: 'zwei\nZeilen' })).toBe('invalid_notice');
    expect(await code({ text: 'Mehr unter https://lx-labs.dev' })).toBe('notice_link');
    expect(await code({ text: 'Hallo', expiresInMinutes: 0 })).toBe('invalid_duration');
    expect(await code({ text: null, expiresInMinutes: 5 })).toBe('invalid_duration');
    expect(await world.count('operator_settings')).toBe(0);
    for (const body of [{ text: 'x'.repeat(NOTICE_MAX_CHARS) }, { text: 'Hallo', expiresInMinutes: 90 * 24 * 60 }, { text: 'Mit Ümläuten und 😀' }, { text: 'Familie ' + FAMILIE }]) {
      expect((await a.client.put('/api/v1/admin/notice', body)).status, JSON.stringify(body)).toBe(200);
    }
  });

  it('Hinweis setzen: alle Angemeldeten sehen ihn mit Version und Ablauf; er läuft von selbst ab; löschen; neue Version bei jedem Setzen', async () => {
    const { a, eltern, kind } = await familie();
    await stepUp(a);
    const gesetzt = await a.client.put('/api/v1/admin/notice', { text: '  Samstag Vormittag: Wartung  ', expiresInMinutes: 2 * 24 * 60 });
    expect(gesetzt.status).toBe(200);
    const bis = new Date(world.clock + 2 * DAY).toISOString();
    expect(gesetzt.json.notice).toMatchObject({ text: 'Samstag Vormittag: Wartung', expiresAt: bis });
    const v1 = gesetzt.json.notice.setAt as string;
    for (const p of [a, eltern, kind]) {
      const r = await p.client.get('/api/v1/family-notice');
      expect(r.json.notice).toEqual({ text: 'Samstag Vormittag: Wartung', setAt: v1, expiresAt: bis });
      expect(Object.keys(r.json).sort()).toEqual(['maintenance', 'notice']);
    }
    // neu setzen = neue Version (die App zeigt ihn dann auch denen wieder, die den alten weggeklickt haben)
    world.advance(5 * MIN);
    await stepUp(a);
    const neu = await a.client.put('/api/v1/admin/notice', { text: 'Wartung verschoben' });
    expect(neu.json.notice.text).toBe('Wartung verschoben');
    expect(neu.json.notice.expiresAt).toBeNull();
    expect(neu.json.notice.setAt).not.toBe(v1);
    // Ablauf von selbst
    await stepUp(a);
    expect((await a.client.put('/api/v1/admin/notice', { text: 'Kurz', expiresInMinutes: 60 })).status).toBe(200);
    expect((await kind.client.get('/api/v1/family-notice')).json.notice?.text).toBe('Kurz');
    world.advance(HOUR + MIN);
    expect((await kind.client.get('/api/v1/family-notice')).json.notice).toBeNull();
    expect((await a.client.get('/api/v1/admin/settings')).json.notice).toBeNull();
    // löschen
    await stepUp(a);
    expect((await a.client.put('/api/v1/admin/notice', { text: 'Wieder da' })).status).toBe(200);
    const weg = await a.client.put('/api/v1/admin/notice', { text: null });
    expect(weg.status).toBe(200);
    expect(weg.json.notice).toBeNull();
    expect((await eltern.client.get('/api/v1/family-notice')).json.notice).toBeNull();
    // der Hinweis ändert den Wartungsmodus nicht
    expect(weg.json.maintenance.active).toBe(false);
  });

  it('Hinweis: das Audit-Log kennt Länge und Ablauf, nie den Text', async () => {
    const { a } = await familie();
    await stepUp(a);
    const text = 'Geheimer Wartungstext 4711';
    expect((await a.client.put('/api/v1/admin/notice', { text, expiresInMinutes: 24 * 60 })).status).toBe(200);
    expect((await a.client.put('/api/v1/admin/notice', { text: null })).status).toBe(200);
    const ereignisse = await audit('operator_notice_set');
    expect(ereignisse).toHaveLength(2);
    expect(ereignisse[0]!.detail).toMatchObject({ had: false, has: true, length: [...text].length });
    expect(ereignisse[1]!.detail).toMatchObject({ had: true, has: false, length: 0, expiresAt: null });
    expect(JSON.stringify(await world.db.select().from(schema.auditLog))).not.toContain('4711');
    // und die Betreiber-Ansicht des Protokolls zeigt es als Änderung, ohne Text
    await stepUp(a);
    const seite = await a.client.get('/api/v1/admin/audit?category=aenderungen');
    expect(JSON.stringify(seite.json)).not.toContain('4711');
    expect((seite.json.items as Array<{ event: string }>).some((i) => i.event === 'operator_notice_set')).toBe(true);
  });

  it('Familiengrenze: der Hinweis einer fremden Familie erscheint nie; Wartung und Hinweis hängen an der Familie der Sitzung', async () => {
    const { a, eltern } = await familie();
    const [fam] = await world.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning({ id: schema.families.id });
    await world.db.insert(schema.operatorSettings).values({ familyId: fam!.id, noticeText: 'Fremder Hinweis', noticeSetAt: new Date(world.clock), updatedAt: new Date(world.clock) });
    for (const p of [a, eltern]) {
      const r = await p.client.get('/api/v1/family-notice');
      expect(r.json.notice).toBeNull();
      expect(JSON.stringify(r.json)).not.toContain('Fremder');
    }
    await stepUp(a);
    expect((await a.client.put('/api/v1/admin/notice', { text: 'Eigener Hinweis' })).status).toBe(200);
    const fremd = await world.db.select().from(schema.operatorSettings).where(eq(schema.operatorSettings.familyId, fam!.id));
    expect(fremd[0]?.noticeText).toBe('Fremder Hinweis');
    expect(await world.count('operator_settings')).toBe(2);
  });

  it('Datenbank-Prüfungen: Hinweis höchstens 280 Zeichen mit Version, Wartung nur mit "seit"', async () => {
    const { a } = await familie();
    await stepUp(a);
    expect((await a.client.put('/api/v1/admin/notice', { text: 'x' })).status).toBe(200);
    const [row] = await world.db.select().from(schema.operatorSettings);
    const fam = row!.familyId;
    await expect(world.db.update(schema.operatorSettings).set({ noticeText: 'y'.repeat(281) }).where(eq(schema.operatorSettings.familyId, fam))).rejects.toThrow();
    await expect(world.db.update(schema.operatorSettings).set({ noticeText: '' }).where(eq(schema.operatorSettings.familyId, fam))).rejects.toThrow();
    await expect(world.db.update(schema.operatorSettings).set({ noticeSetAt: null }).where(eq(schema.operatorSettings.familyId, fam))).rejects.toThrow();
    await expect(world.db.update(schema.operatorSettings).set({ maintenanceActive: true, maintenanceSince: null }).where(eq(schema.operatorSettings.familyId, fam))).rejects.toThrow();
    // wird die Familie gelöscht, verschwindet die Zeile mit
    const [fremd] = await world.db.insert(schema.families).values({ name: 'Weg' }).returning({ id: schema.families.id });
    await world.db.insert(schema.operatorSettings).values({ familyId: fremd!.id });
    await world.db.delete(schema.families).where(eq(schema.families.id, fremd!.id));
    expect(await world.count('operator_settings')).toBe(1);
  });
});
