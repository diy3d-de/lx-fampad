// Abfuhrtermine: strenger ICS-Parser (synthetische Datei im Format der echten Quelle, nie echte Daten), Konfiguration (fail-closed),
// Jahreslogik mit Uhr, Abruf (Host, Redirect, Größe, Fehlercodes), Speicherung, Route (Rechte, 404, ETag, keine Quelle/Straße in der
// Antwort) und „Jetzt prüfen“ (Rechte, Rate-Limit, wird vom Dienst abgearbeitet). Die Quelle wird durch einen Fake-fetch ersetzt.
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { loadConfig, wasteConfig } from '../src/config.js';
import * as schema from '../src/db/schema.js';
import { kindOfSummary, MAX_ICS_BYTES, parseWasteIcs } from '../src/waste/ics.js';
import { berlinJahrMonat, CHECK_REQUEST_GAP_MS, faelligeJahre, naechstePruefung, WasteService, type YearRow } from '../src/waste/service.js';
import { addMember, adminPassword, backends, TEST_KEY, World, type Harness } from './helpers.js';

const URL_TEMPLATE = 'https://abfall.example.org/?key=DUMMYKEY0123456789&mode=export&idhousenumber=99999&timeperiod={YEAR}0101-{YEAR}1231&showinactive=false&type=ics';
const ENV = { WASTE_ENABLED: 'true', WASTE_ICS_URL: URL_TEMPLATE, WASTE_PLACE: 'Beispielort' };
const STRASSE = 'Beispielweg 12, Beispielort';

/** Datei im Format der echten Quelle (K4SYSTEMS/ABFALLPLUS), mit erfundener Straße. */
function ics(termine: [string, string][], extra = ''): string {
  const ev = termine.map(
    ([tag, name], i) =>
      `BEGIN:VEVENT\nDTSTART;VALUE=DATE:${tag}\nDTEND;VALUE=DATE:${tag}\nDTSTAMP:20261022T140836Z\nUID:uid-geheim-${i}\nCREATED:20260101T090000Z\nDESCRIPTION:${STRASSE}\nLAST-MODIFIED:20260101T090000Z\nLOCATION:${STRASSE}\nSEQUENCE:0\nSTATUS:CONFIRMED\nSUMMARY:${name}\nTRANSP:TRANSPARENT\n${extra}END:VEVENT\n`,
  );
  return `BEGIN:VCALENDAR\nPRODID:-//K4SYSTEMS//ABFALLPLUS//DE\nVERSION:2.0\nCALSCALE:GREGORIAN\nMETHOD:PUBLISH\nX-WR-TIMEZONE:Europe/Berlin\nX-WR-CALNAME:Abfuhrtermine ${STRASSE}\nX-WR-RELCALID:abc\n${ev.join('')}END:VCALENDAR\n`;
}

const FIXTURE_2026 = ics([
  ['20261028', 'Bioabfall'],
  ['20261028', 'Gelber Sack'],
  ['20261104', 'Restabfall'],
  ['20261118', 'Altpapier'],
  ['20261125', 'Grünabfall'],
  ['20261126', 'Sonderabfall'],
  ['20261214', 'Sperrmüll'],
  ['20261230', 'Weihnachtsbäume'],
  ['20260107', 'Bioabfall'],
]);

describe('ICS-Parser', () => {
  it('liest Tag und Art, nie Straße, UID oder Beschreibung; sortiert', () => {
    const r = parseWasteIcs(FIXTURE_2026);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.entries).toHaveLength(9);
    expect(r.entries[0]).toEqual({ day: '2026-01-07', kind: 'bio' });
    expect(r.entries.filter((e) => e.day === '2026-10-28').map((e) => e.kind)).toEqual(['bio', 'gelb']);
    expect(r.entries.map((e) => e.kind)).toEqual(expect.arrayContaining(['rest', 'papier', 'gruen', 'sonder', 'sperr', 'baum']));
    const text = JSON.stringify(r);
    for (const verboten of ['Beispielweg', 'uid-geheim', 'Beispielort', 'K4SYSTEMS']) expect(text).not.toContain(verboten);
  });

  it('versteht CRLF, BOM, entfaltete Zeilen und Parameter am SUMMARY', () => {
    const roh = '﻿BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20260107\r\nSUMMARY;LANGUAGE=de:Bio\r\n abfall\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
    expect(parseWasteIcs(roh)).toEqual({ ok: true, entries: [{ day: '2026-01-07', kind: 'bio' }] });
  });

  it('nimmt nur DTSTART;VALUE=DATE mit gültigem Kalendertag und ein SUMMARY; Doppelte fallen weg', () => {
    const r = parseWasteIcs(
      ics([
        ['20260230', 'Bioabfall'], // kein Kalendertag
        ['20261301', 'Bioabfall'],
        ['20260107', 'Bioabfall'],
        ['20260107', 'Bioabfall'], // doppelt
      ]) + '',
    );
    expect(r).toEqual({ ok: true, entries: [{ day: '2026-01-07', kind: 'bio' }] });
    const mitZeit = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20260107T060000Z\nSUMMARY:Bioabfall\nEND:VEVENT\nBEGIN:VEVENT\nDTSTART;VALUE=DATE:20260108\nEND:VEVENT\nEND:VCALENDAR\n';
    expect(parseWasteIcs(mitZeit)).toEqual({ ok: true, entries: [] });
  });

  it('überspringt abgesagte Termine und verschachtelte Blöcke (VALARM) ohne Rekursion', () => {
    const r = parseWasteIcs(ics([['20260107', 'Bioabfall']], 'BEGIN:VALARM\nSUMMARY:Weihnachtsbaum\nACTION:DISPLAY\nEND:VALARM\n'));
    expect(r).toEqual({ ok: true, entries: [{ day: '2026-01-07', kind: 'bio' }] });
    const abgesagt = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART;VALUE=DATE:20260107\nSUMMARY:Bioabfall\nSTATUS:CANCELLED\nEND:VEVENT\nEND:VCALENDAR\n';
    expect(parseWasteIcs(abgesagt)).toEqual({ ok: true, entries: [] });
    const tief = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\n' + 'BEGIN:X\n'.repeat(50) + 'END:VEVENT\nEND:VCALENDAR\n';
    expect(parseWasteIcs(tief)).toEqual({ ok: false, code: 'not_ics' });
  });

  it('lehnt Müll, unvollständige und zu große Dateien ab', () => {
    expect(parseWasteIcs('')).toEqual({ ok: false, code: 'not_ics' });
    expect(parseWasteIcs('<html>403 Forbidden</html>')).toEqual({ ok: false, code: 'not_ics' });
    expect(parseWasteIcs('BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART;VALUE=DATE:20260107\nSUMMARY:Bio\n')).toEqual({ ok: false, code: 'not_ics' }); // abgeschnitten
    expect(parseWasteIcs('BEGIN:VCALENDAR\nEND:VEVENT\nEND:VCALENDAR\n')).toEqual({ ok: true, entries: [] });
    expect(parseWasteIcs('BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VCALENDAR\n')).toEqual({ ok: false, code: 'not_ics' });
    expect(parseWasteIcs('A'.repeat(MAX_ICS_BYTES + 1))).toEqual({ ok: false, code: 'too_large' });
    expect(parseWasteIcs('BEGIN:VCALENDAR\n' + 'X'.repeat(5000) + '\nEND:VCALENDAR\n')).toEqual({ ok: false, code: 'not_ics' });
    const viele = 'BEGIN:VCALENDAR\n' + 'BEGIN:VEVENT\nEND:VEVENT\n'.repeat(3001) + 'END:VCALENDAR\n';
    expect(parseWasteIcs(viele)).toEqual({ ok: false, code: 'too_many' });
  });

  it('bildet Namen auf die feste Liste ab, Unbekanntes wird "sonst"', () => {
    const f: [string, string][] = [
      ['Restabfall', 'rest'],
      ['Restmüll 2-wöchentlich', 'rest'],
      ['Bioabfall', 'bio'],
      ['Gelber Sack', 'gelb'],
      ['Gelbe Tonne', 'gelb'],
      ['Altpapier', 'papier'],
      ['Grünabfall', 'gruen'],
      ['Gruenabfall', 'gruen'],
      ['Sonderabfall', 'sonder'],
      ['Sperrmüll', 'sperr'],
      ['Weihnachtsbäume', 'baum'],
      ['Schornsteinfeger', 'sonst'],
      ['', 'sonst'],
    ];
    for (const [name, kind] of f) expect(kindOfSummary(name), name).toBe(kind);
  });
});

describe('Konfiguration', () => {
  const base = { NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY };
  it('ist ohne Schalter aus und verlangt sonst eine https-Adresse mit {YEAR}', () => {
    expect(loadConfig(base).waste).toMatchObject({ enabled: false });
    expect(loadConfig(base).waste.configError).toBeUndefined();
    expect(loadConfig({ ...base, WASTE_ENABLED: 'true' }).waste.configError).toMatch(/WASTE_ICS_URL/);
    expect(loadConfig({ ...base, WASTE_ENABLED: 'true', WASTE_ICS_URL: 'https://abfall.example.org/?timeperiod=20260101' }).waste.configError).toMatch(/WASTE_ICS_URL/);
    const c = loadConfig({ ...base, ...ENV });
    expect(c.waste).toMatchObject({ enabled: true, host: 'abfall.example.org', place: 'Beispielort', tickMs: 60_000 });
    expect(c.waste.configError).toBeUndefined();
  });
  it('eine ungültige Müll-Konfiguration ist NIE fatal: loadConfig wirft nicht, die Funktion ist aus, die Meldung nennt den Link nicht', () => {
    for (const url of ['http://abfall.example.org/{YEAR}', 'https://u:p@abfall.example.org/{YEAR}', 'https://abfall.example.org:8443/{YEAR}', 'https://127.0.0.1/{YEAR}', 'https://[::1]/{YEAR}', 'https://localhost/{YEAR}', 'https://intern/{YEAR}', 'ftp://abfall.example.org/{YEAR}', 'https://abfall.example.org/{YEAR}#x', 'kein-link mit abfall.example.org']) {
      const c = loadConfig({ ...base, WASTE_ENABLED: 'true', WASTE_ICS_URL: url });
      expect(c.waste.enabled, url).toBe(false);
      expect(c.waste.configError, url).toMatch(/WASTE_ICS_URL/);
      expect(c.waste.icsUrl).toBe('');
      expect(c.waste.configError).not.toContain('abfall.example.org');
    }
  });
  it('Schalter, Ort, Browser-Kennung und Takt werden geprüft (Fehler = aus mit Meldung, nie ein Abbruch)', () => {
    expect(loadConfig({ ...base, ...ENV, WASTE_ENABLED: 'yes' }).waste).toMatchObject({ enabled: false, configError: expect.stringMatching(/WASTE_ENABLED/) });
    expect(loadConfig({ ...base, ...ENV, WASTE_PLACE: '<b>' }).waste.configError).toMatch(/WASTE_PLACE/);
    expect(loadConfig({ ...base, ...ENV, WASTE_USER_AGENT: 'Böse\nHeader' }).waste.configError).toMatch(/WASTE_USER_AGENT/);
    expect(loadConfig({ ...base, ...ENV }).waste.userAgent).toMatch(/^Mozilla\/5\.0/);
    expect(loadConfig({ NODE_ENV: 'production', AUTH_SECRET_KEY: TEST_KEY, ...ENV, WASTE_TICK_MS: '1000' }).waste.configError).toMatch(/WASTE_TICK_MS/);
    expect(loadConfig({ ...base, ...ENV, WASTE_TICK_MS: 'abc' }).waste.configError).toMatch(/WASTE_TICK_MS/);
  });
  it('die Funktion wasteConfig (vom Einrichtungsskript benutzt) meldet dieselben Fehler', () => {
    expect(wasteConfig({ WASTE_ENABLED: 'true', WASTE_ICS_URL: URL_TEMPLATE }, 'production').configError).toBeUndefined();
    expect(wasteConfig({ WASTE_ENABLED: 'true', WASTE_ICS_URL: 'http://x.example.org/{YEAR}' }, 'production').configError).toMatch(/WASTE_ICS_URL/);
  });
});

describe('Jahreslogik', () => {
  const t = (s: string) => new Date(s);
  const geladen = (year: number, last?: string): YearRow => ({ year, status: 'loaded', lastCheckedAt: last ? t(last) : null });
  const fehlt = (year: number, last: string): YearRow => ({ year, status: 'unavailable', lastCheckedAt: t(last) });

  it('Jahr und Monat gelten in Berlin', () => {
    expect(berlinJahrMonat(t('2026-12-31T23:30:00Z'))).toEqual({ year: 2027, month: 1 });
    expect(berlinJahrMonat(t('2026-11-30T23:30:00Z'))).toEqual({ year: 2026, month: 12 });
  });
  it('lädt das laufende Jahr, solange es fehlt: beim Start sofort, sonst alle 6 Stunden', () => {
    expect(faelligeJahre(t('2026-10-22T10:00:00Z'), [], true)).toEqual([2026]);
    expect(faelligeJahre(t('2026-10-22T10:00:00Z'), [fehlt(2026, '2026-10-22T08:00:00Z')], true)).toEqual([2026]);
    expect(faelligeJahre(t('2026-10-22T10:00:00Z'), [fehlt(2026, '2026-10-22T08:00:00Z')], false)).toEqual([]);
    expect(faelligeJahre(t('2026-10-22T14:00:01Z'), [fehlt(2026, '2026-10-22T08:00:00Z')], false)).toEqual([2026]);
  });
  it('mit geladenem Jahr bleibt der Stand bis zum wöchentlichen Neuladen, auch beim Start; vor Dezember wird das nächste Jahr nicht gesucht', () => {
    expect(faelligeJahre(t('2026-10-22T10:00:00Z'), [geladen(2026, '2026-10-20T10:00:00Z')], true)).toEqual([]);
    expect(faelligeJahre(t('2026-11-30T10:00:00Z'), [geladen(2026, '2026-11-29T10:00:00Z')], false)).toEqual([]);
  });
  it('das geladene laufende Jahr wird einmal pro Woche neu geladen (auch nach einem fehlgeschlagenen Versuch erst wieder nach einer Woche)', () => {
    expect(faelligeJahre(t('2026-10-27T10:00:00Z'), [geladen(2026, '2026-10-20T10:00:00Z')], false)).toEqual([2026]);
    expect(faelligeJahre(t('2026-10-27T09:59:00Z'), [geladen(2026, '2026-10-20T10:00:00Z')], false)).toEqual([]);
    expect(faelligeJahre(t('2026-10-22T10:00:00Z'), [geladen(2026)], false)).toEqual([2026]);
  });
  it('im Dezember wird das nächste Jahr einmal pro Woche gesucht, bis es da ist', () => {
    const g = geladen(2026, '2026-12-01T05:59:00Z');
    expect(faelligeJahre(t('2026-12-01T06:00:00Z'), [g], false)).toEqual([2027]);
    expect(faelligeJahre(t('2026-12-01T06:00:00Z'), [g, fehlt(2027, '2026-11-20T06:00:00Z')], false)).toEqual([2027]); // geprüft vor Dezember
    expect(faelligeJahre(t('2026-12-05T06:00:00Z'), [g, fehlt(2027, '2026-12-01T06:00:00Z')], false)).toEqual([]);
    expect(faelligeJahre(t('2026-12-08T06:00:01Z'), [geladen(2026, '2026-12-08T05:00:00Z'), fehlt(2027, '2026-12-01T06:00:00Z')], false)).toEqual([2027]);
    expect(faelligeJahre(t('2026-12-06T06:00:00Z'), [g, geladen(2027, '2026-12-05T06:00:00Z')], false)).toEqual([]);
  });
  it('ab Januar nur noch bei fehlenden Daten (und dem wöchentlichen Neuladen des laufenden Jahres)', () => {
    expect(faelligeJahre(t('2027-01-10T10:00:00Z'), [geladen(2026, '2026-12-30T10:00:00Z'), geladen(2027, '2027-01-08T10:00:00Z')], true)).toEqual([]);
    expect(faelligeJahre(t('2027-01-10T10:00:00Z'), [geladen(2026), fehlt(2027, '2027-01-10T08:00:00Z')], false)).toEqual([]);
    expect(faelligeJahre(t('2027-01-10T10:00:00Z'), [geladen(2026), geladen(2027, '2027-01-02T10:00:00Z')], false)).toEqual([2027]);
    expect(faelligeJahre(t('2027-01-10T10:00:00Z'), [geladen(2026)], false)).toEqual([2027]);
  });
  it('plant die nächste Prüfung für die Anzeige', () => {
    // nächstes Neuladen des laufenden Jahres (eine Woche nach der letzten Prüfung) oder der 1. Dezember: das frühere
    expect(naechstePruefung(t('2026-10-22T10:00:00Z'), [geladen(2026, '2026-10-22T05:00:00Z')])?.toISOString()).toBe('2026-10-29T05:00:00.000Z');
    expect(naechstePruefung(t('2026-11-27T10:00:00Z'), [geladen(2026, '2026-11-26T05:00:00Z')])?.toISOString()).toBe('2026-11-30T23:00:00.000Z');
    expect(naechstePruefung(t('2026-12-03T10:00:00Z'), [geladen(2026, '2026-12-02T05:00:00Z'), fehlt(2027, '2026-12-01T06:00:00Z')])?.toISOString()).toBe('2026-12-08T06:00:00.000Z');
    expect(naechstePruefung(t('2026-12-03T10:00:00Z'), [geladen(2026, '2026-12-02T05:00:00Z'), geladen(2027)])?.toISOString()).toBe('2026-12-09T05:00:00.000Z');
    expect(naechstePruefung(t('2026-10-22T10:00:00Z'), [fehlt(2026, '2026-10-22T08:00:00Z')])?.toISOString()).toBe('2026-10-22T14:00:00.000Z');
  });
});

interface Aufruf {
  url: string;
  ua: string | null;
  redirect: string | undefined;
}
/** Fake-Quelle: je Jahr eine Antwort; zählt Aufrufe. */
function fakeQuelle() {
  const aufrufe: Aufruf[] = [];
  const zustand: { antwort: (jahr: number) => Response } = {
    antwort: (jahr) => (jahr === 2026 ? new Response(FIXTURE_2026, { status: 200 }) : new Response('BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n', { status: 200 })),
  };
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    aufrufe.push({ url, ua: new Headers(init?.headers).get('user-agent'), redirect: init?.redirect });
    const jahr = Number(/timeperiod=(\d{4})0101/.exec(url)?.[1]);
    return zustand.antwort(jahr);
  }) as typeof fetch;
  return { fn, aufrufe, zustand };
}

describe.each(backends)('Abfuhrtermine: Dienst und Route ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let quelle: ReturnType<typeof fakeQuelle>;
  let dienst: WasteService;
  const logZeilen: string[] = [];

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv = ENV) {
    await world?.close();
    await harness.reset();
    quelle = fakeQuelle();
    logZeilen.length = 0;
    world = await World.create(harness.db, env);
    const log = {
      warn: (o: object) => void logZeilen.push(JSON.stringify(o)),
      error: (o: object) => void logZeilen.push(JSON.stringify(o)),
      info: (o: object) => void logZeilen.push(JSON.stringify(o)),
    };
    dienst = new WasteService({ db: harness.db, config: world.config, log, now: world.now, fetch: quelle.fn });
  }
  beforeEach(async () => {
    await neu();
  });
  const jahre = async () => (await harness.db.select().from(schema.wasteYears)).sort((a, b) => a.year - b.year);

  it('ohne Familie passiert nichts; ohne Schalter ruft der Dienst nie ab', async () => {
    expect(await dienst.runDue()).toEqual([]);
    await neu({});
    await adminPassword(world);
    expect(await dienst.runDue()).toEqual([]);
    expect(quelle.aufrufe).toHaveLength(0);
  });

  it('lädt das laufende Jahr einmal (Browser-Kennung, kein Redirect), speichert Tag und Art und ruft nicht erneut ab', async () => {
    await adminPassword(world);
    expect(await dienst.runDue()).toEqual([2026]);
    expect(quelle.aufrufe).toHaveLength(1);
    expect(quelle.aufrufe[0]?.url).toContain('timeperiod=20260101-20261231');
    expect(quelle.aufrufe[0]?.ua).toMatch(/^Mozilla\/5\.0/);
    expect(quelle.aufrufe[0]?.redirect).toBe('manual');
    expect(await world.count('waste_events')).toBe(9);
    expect(await jahre()).toMatchObject([{ year: 2026, status: 'loaded', eventCount: 9, errorCode: null }]);
    world.advance(3 * 24 * 3600_000); // nichts fällig, der gespeicherte Stand bleibt
    expect(await dienst.runDue()).toEqual([]);
    expect(quelle.aufrufe).toHaveLength(1);
    world.advance(5 * 24 * 3600_000); // eine Woche: das laufende Jahr wird neu geladen (Änderungen der Quelle)
    quelle.zustand.antwort = () => new Response(ics([['20261028', 'Bioabfall'], ['20261104', 'Restabfall'], ['20261118', 'Altpapier'], ['20261125', 'Grünabfall'], ['20261126', 'Sonderabfall'], ['20261215', 'Sperrmüll']]), { status: 200 });
    expect(await dienst.runDue()).toEqual([2026]);
    expect(quelle.aufrufe).toHaveLength(2);
    expect(await world.count('waste_events')).toBe(6);
    expect(await dienst.runDue()).toEqual([]);
    // der Wert der Quelle landet nie in der Datenbank (nur Tag und feste Art)
    const roh = JSON.stringify(await harness.db.select().from(schema.wasteEvents));
    for (const verboten of ['Beispielweg', 'uid-geheim', 'Beispielort']) expect(roh).not.toContain(verboten);
  });

  it('Dezember: das nächste Jahr wird einmal pro Woche gesucht; leere Antwort = noch nicht da; danach geladen und nicht mehr gesucht', async () => {
    await adminPassword(world);
    await dienst.runDue();
    world.clock = Date.parse('2026-12-01T06:00:00Z');
    expect(await dienst.runDue()).toEqual([2026, 2027]); // das laufende Jahr ist eine Woche alt (Neuladen), dazu das nächste Jahr
    expect((await jahre()).find((j) => j.year === 2027)).toMatchObject({ status: 'unavailable', errorCode: 'empty', eventCount: 0 });
    world.advance(3 * 24 * 3600_000);
    expect(await dienst.runDue()).toEqual([]);
    world.clock = Date.parse('2026-12-08T06:00:01Z');
    // 2026 liefert jetzt einen Fehler: der Stand bleibt stehen; 2027 ist da
    quelle.zustand.antwort = (jahr) => new Response(ics([['20270105', 'Bioabfall'], ['20270112', 'Restabfall'], ['20260101', 'Bioabfall']]), { status: jahr === 2027 ? 200 : 500 });
    expect(await dienst.runDue()).toEqual([2026, 2027]);
    expect((await jahre()).find((j) => j.year === 2027)).toMatchObject({ status: 'loaded', eventCount: 2, errorCode: null });
    expect((await jahre()).find((j) => j.year === 2026)).toMatchObject({ status: 'loaded', eventCount: 9, errorCode: 'http_500' });
    const n = quelle.aufrufe.length;
    world.advance(3 * 24 * 3600_000);
    expect(await dienst.runDue()).toEqual([]);
    expect(quelle.aufrufe).toHaveLength(n);
    // 2026 blieb unberührt
    expect(await world.count('waste_events')).toBe(11);
  });

  it('Fehler werden als feste Codes festgehalten (nie die URL), ein geladenes Jahr bleibt bei Fehlern erhalten', async () => {
    await adminPassword(world);
    const probe = async (antwort: () => Response, code: string, status: string) => {
      await harness.db.delete(schema.wasteYears);
      await harness.db.delete(schema.wasteEvents);
      quelle.zustand.antwort = antwort;
      await dienst.runDue();
      expect((await jahre())[0], code).toMatchObject({ year: 2026, status, errorCode: code });
    };
    await probe(() => new Response('Forbidden', { status: 403 }), 'http_403', 'error');
    await probe(() => new Response('', { status: 404 }), 'http_404', 'unavailable');
    await probe(() => new Response('', { status: 302, headers: { location: 'https://boese.example.net/x' } }), 'redirect', 'error');
    await probe(() => new Response('<html>nope</html>', { status: 200 }), 'not_ics', 'unavailable');
    await probe(() => new Response('A', { status: 200, headers: { 'content-length': String(MAX_ICS_BYTES + 1) } }), 'too_large', 'error');
    await probe(() => new Response('A'.repeat(MAX_ICS_BYTES + 10), { status: 200 }), 'too_large', 'error');
    await probe(() => {
      throw new Error(`boom ${URL_TEMPLATE}`);
    }, 'network', 'error');
    const log = logZeilen.join('\n');
    expect(log).not.toContain('DUMMYKEY');
    expect(log).not.toContain('abfall.example.org');
    // ein bereits geladenes Jahr bleibt "geladen", der Fehler wird nur vermerkt
    await harness.db.delete(schema.wasteYears);
    await harness.db.delete(schema.wasteEvents);
    quelle.zustand.antwort = (jahr) => new Response(jahr === 2026 ? FIXTURE_2026 : '', { status: 200 });
    await dienst.runDue();
    quelle.zustand.antwort = () => new Response('', { status: 500 });
    const [fam] = await harness.db.select().from(schema.families);
    expect(await dienst.fetchYear(fam?.id as string, 2026)).toBe('http_500');
    expect((await jahre())[0]).toMatchObject({ status: 'loaded', eventCount: 9, errorCode: 'http_500' });
    expect(await world.count('waste_events')).toBe(9);
  });

  it('ersetzt beim erneuten Laden die Termine des Jahres (nicht die anderer Jahre)', async () => {
    await adminPassword(world);
    const [fam] = await harness.db.select().from(schema.families);
    const f = fam?.id as string;
    await dienst.runDue();
    quelle.zustand.antwort = () => new Response(ics([['20260107', 'Restabfall'], ['20261028', 'Bioabfall'], ['20261104', 'Restabfall'], ['20261118', 'Altpapier'], ['20261125', 'Grünabfall']]), { status: 200 });
    expect(await dienst.fetchYear(f, 2026)).toBeNull();
    expect((await harness.db.select().from(schema.wasteEvents)).map((e) => `${e.day} ${e.kind}`).sort()).toEqual(['2026-01-07 rest', '2026-10-28 bio', '2026-11-04 rest', '2026-11-18 papier', '2026-11-25 gruen']);
  });

  it('ein Neuladen mit weniger als der Hälfte der bisherigen Termine überschreibt ein geladenes Jahr nicht (Code shrunk, Status bleibt loaded)', async () => {
    await adminPassword(world);
    const f = (await harness.db.select().from(schema.families))[0]?.id as string;
    await dienst.runDue();
    quelle.zustand.antwort = () => new Response(ics([['20260107', 'Restabfall'], ['20261028', 'Bioabfall'], ['20261104', 'Restabfall'], ['20261118', 'Altpapier'], ['20261125', 'Grünabfall']]), { status: 200 }); // 5 von 9: über der Hälfte
    expect(await dienst.fetchYear(f, 2026)).toBeNull();
    quelle.zustand.antwort = () => new Response(ics([['20260107', 'Restabfall'], ['20261028', 'Bioabfall']]), { status: 200 }); // 2 von 5: unter der Hälfte
    expect(await dienst.fetchYear(f, 2026)).toBe('shrunk');
    expect((await jahre())[0]).toMatchObject({ status: 'loaded', eventCount: 5, errorCode: 'shrunk' });
    expect(await world.count('waste_events')).toBe(5);
  });

  it('Datenbankfehler nach dem Abruf: Code db wird zuerst festgehalten (Wartezeit statt Abruf in jedem Takt), nie eine Ausnahme', async () => {
    await adminPassword(world);
    const f = (await harness.db.select().from(schema.families))[0]?.id as string;
    const kaputt = new Proxy(harness.db, { get: (t, p, r) => (p === 'transaction' ? async () => Promise.reject(new Error('boom mit DUMMYKEY')) : Reflect.get(t, p, r)) });
    const svc = new WasteService({ db: kaputt, config: world.config, log: { warn: (o) => void logZeilen.push(JSON.stringify(o)), error: (o) => void logZeilen.push(JSON.stringify(o)) }, now: world.now, fetch: quelle.fn });
    expect(await svc.fetchYear(f, 2026)).toBe('db');
    expect((await jahre())[0]).toMatchObject({ year: 2026, status: 'error', errorCode: 'db', lastCheckedAt: new Date(world.clock) });
    expect(logZeilen.join('\n')).not.toContain('DUMMYKEY');
    // der Takt ruft nicht in jeder Minute erneut ab: erst nach 6 Stunden
    (svc as unknown as { ersterLauf: boolean }).ersterLauf = false;
    expect(await svc.runDue()).toEqual([]);
    world.advance(6 * 3600_000 + 1000);
    expect(await svc.runDue()).toEqual([2026]);
  });

  it('GET und POST nur für die Familie, die der Dienst bedient (jede andere: 404)', async () => {
    // eine ältere zweite Familie: die bedient der Dienst, nicht die der Sitzung
    const a = await adminPassword(world);
    expect((await a.client.get('/api/v1/waste')).status).toBe(200);
    await harness.db.insert(schema.families).values({ name: 'Alt', createdAt: new Date('2000-01-01T00:00:00Z') });
    expect((await a.client.get('/api/v1/waste')).status).toBe(404);
    expect((await a.client.post('/api/v1/waste/check')).status).toBe(404);
  });

  it('eine ungültige Müll-Konfiguration verhindert den API-Start nicht: die Funktion ist aus (404), nichts wird abgerufen', async () => {
    await neu({ WASTE_ENABLED: 'true', WASTE_ICS_URL: 'http://abfall.example.org/{YEAR}' });
    const a = await adminPassword(world);
    expect(world.config.waste).toMatchObject({ enabled: false, configError: expect.stringMatching(/WASTE_ICS_URL/) });
    expect((await a.client.get('/api/v1/waste')).status).toBe(404);
    expect(await dienst.runDue()).toEqual([]);
    expect(quelle.aufrufe).toHaveLength(0);
  });

  it('Route: ohne Anmeldung 401, ausgeschaltet 404; Antwort ohne Quelle, Straße, UID oder Schlüssel; Kinder lesen mit', async () => {
    expect((await world.client().get('/api/v1/waste')).status).toBe(401);
    const a = await adminPassword(world);
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    const leer = await a.client.get('/api/v1/waste');
    expect(leer.status).toBe(200);
    expect(leer.json).toMatchObject({ place: 'Beispielort', years: [], events: [], check: { pending: false, lastCheckAt: null, nextCheckAt: null, nextRequestAt: null } });
    await dienst.runDue();
    for (const c of [a.client, kind.client]) {
      const res = await c.get('/api/v1/waste');
      expect(res.status).toBe(200);
      expect(res.json.years).toMatchObject([{ year: 2026, status: 'loaded', eventCount: 9, errorCode: null }]);
      expect(res.json.events).toHaveLength(8);
      expect(res.json.events[0]).toEqual({ date: '2026-01-07', kinds: ['bio'] });
      expect(res.json.events.find((e: { date: string }) => e.date === '2026-10-28').kinds).toEqual(['bio', 'gelb']);
      const text = JSON.stringify(res.json);
      for (const verboten of ['Beispielweg', 'uid-geheim', 'DUMMYKEY', 'abfall.example.org', 'K4SYSTEMS', 'idhousenumber', 'http']) expect(text, verboten).not.toContain(verboten);
    }
    await neu({});
    const b = await adminPassword(world);
    expect((await b.client.get('/api/v1/waste')).status).toBe(404);
    expect((await b.client.post('/api/v1/waste/check')).status).toBe(404);
  });

  it('Route: ETag, 304 bei unverändertem Stand', async () => {
    const a = await adminPassword(world);
    await dienst.runDue();
    const r1 = await a.client.get('/api/v1/waste');
    const etag = String(r1.headers.etag);
    expect(etag).toMatch(/^"w-[0-9a-f]{24}"$/);
    expect((await a.client.get('/api/v1/waste', { headers: { 'if-none-match': etag } })).status).toBe(304);
    world.advance(60_000);
    expect((await a.client.get('/api/v1/waste', { headers: { 'if-none-match': etag } })).status).toBe(304);
    await dienst.fetchYear((await harness.db.select().from(schema.families))[0]?.id as string, 2027); // neuer Stand
    expect((await a.client.get('/api/v1/waste', { headers: { 'if-none-match': etag } })).status).toBe(200);
  });

  it('"Jetzt prüfen": Kinder 403, Eltern und Admins 202, Wiederholung 429 mit Hinweis; der Dienst arbeitet die Anforderung ab', async () => {
    const a = await adminPassword(world);
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    expect((await world.client().post('/api/v1/waste/check')).status).toBe(401);
    expect((await kind.client.post('/api/v1/waste/check')).status).toBe(403);
    expect((await harness.db.select().from(schema.wasteState)).length).toBe(0);

    await dienst.runDue(); // 2026 ist geladen
    const vorher = quelle.aufrufe.length;
    const r = await eltern.client.post('/api/v1/waste/check');
    expect(r.status).toBe(202);
    const pending = await a.client.get('/api/v1/waste');
    expect(pending.json.check.pending).toBe(true);
    expect(pending.json.check.nextRequestAt).toBe(new Date(world.clock + CHECK_REQUEST_GAP_MS).toISOString());
    // zu häufig: auch Admin und andere Eltern, solange die Frist läuft
    const zuOft = await a.client.post('/api/v1/waste/check');
    expect(zuOft.status).toBe(429);
    expect(zuOft.json).toMatchObject({ error: 'rate_limited', message: 'Bitte etwas später erneut versuchen.' });
    expect(zuOft.json.retryAfterSec).toBeGreaterThan(0);
    expect(zuOft.headers['retry-after']).toBeDefined();

    // der Dienst holt die Anforderung ab und prüft das laufende (neu laden) und das nächste Jahr
    quelle.zustand.antwort = (jahr) => new Response(jahr === 2027 ? ics([['20270105', 'Bioabfall']]) : FIXTURE_2026, { status: 200 });
    expect(await dienst.runDue()).toEqual([2026, 2027]);
    expect(quelle.aufrufe.length).toBe(vorher + 2);
    const danach = await a.client.get('/api/v1/waste');
    expect(danach.json.check).toMatchObject({ pending: false, lastCheckAt: new Date(world.clock).toISOString() });
    expect(danach.json.years).toMatchObject([{ year: 2026, status: 'loaded' }, { year: 2027, status: 'loaded', eventCount: 1 }]);
    // die Frist gilt weiter, nach Ablauf geht es wieder
    expect((await a.client.post('/api/v1/waste/check')).status).toBe(429);
    world.advance(CHECK_REQUEST_GAP_MS + 1000);
    expect((await a.client.post('/api/v1/waste/check')).status).toBe(202);
    const audit = (await harness.db.select().from(schema.auditLog)).filter((e) => e.event === 'waste_check_requested');
    expect(audit).toHaveLength(2);
  });

  it('Anforderung: prüft auch das laufende Jahr (nachholen oder neu laden); "noch nicht verfügbar" meldet der Stand des Jahres', async () => {
    const a = await adminPassword(world);
    expect((await a.client.post('/api/v1/waste/check')).status).toBe(202);
    expect(await dienst.runDue()).toEqual([2026, 2027]);
    const res = await a.client.get('/api/v1/waste');
    expect(res.json.years).toMatchObject([{ year: 2026, status: 'loaded' }, { year: 2027, status: 'unavailable', errorCode: 'empty', checkedAt: new Date(world.clock).toISOString() }]);
    expect(res.json.check.pending).toBe(false);
  });

  it('der Takt des Dienstes arbeitet von selbst ab (Zeitgeber)', async () => {
    const a = await adminPassword(world);
    await a.client.post('/api/v1/waste/check');
    const svc = new WasteService({ db: harness.db, config: loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, ...ENV, WASTE_TICK_MS: '1000' }), log: { warn: () => undefined, error: () => undefined }, now: world.now, fetch: quelle.fn });
    expect(svc.enabled).toBe(true);
    // Zeitgeber ersetzt: keine echte Wartezeit; der Takt startet nach 3 s und läuft dann im eingestellten Abstand
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    try {
      svc.start();
      await vi.advanceTimersByTimeAsync(3_100);
      await svc.drain(60_000);
      expect(await world.count('waste_years')).toBe(2);
      svc.close();
    } finally {
      vi.useRealTimers();
    }
  });
});
