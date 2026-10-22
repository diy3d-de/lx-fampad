// Abfuhrtermine: lädt die ICS-Datei des Abfallkalenders (nur der Server, nie ein Client; Abruf nur im Dienst lx-fampad-waste),
// speichert Tag und Art je Familie und liefert sie an die Mitglieder (GET /waste). Die URL (mit dem Schlüssel der Quelle) steht nur
// in der Konfiguration und taucht nie im Log, in Fehlern oder in Antworten auf; Fehler werden nur als feste Codes festgehalten.
// Jahreslogik: das laufende Jahr wird geladen, solange es fehlt; das nächste Jahr ab dem 1. Dezember einmal pro Woche, bis es da ist
// (leere oder ungültige Antwort = noch nicht da); sonst bleibt der gespeicherte Stand. Außerdem auf Anforderung (Eltern/Admins).
import { and, asc, eq, gte, isNotNull, lte, sql } from 'drizzle-orm';
import type { Db, Logger } from '../auth/context.js';
import type { Config } from '../config.js';
import { families, wasteEvents, wasteState, wasteYears, type WasteKind } from '../db/schema.js';
import { leseBegrenzt } from '../http-limit.js';
import { MAX_ICS_BYTES, parseWasteIcs, type WasteEntry } from './ics.js';

const REQUEST_TIMEOUT_MS = 15_000;
const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
/** Fehlt das laufende Jahr, wird frühestens nach dieser Zeit erneut versucht. */
export const RETRY_MISSING_MS = 6 * HOUR_MS;
/** Im Dezember wird das nächste Jahr einmal pro Woche gesucht. */
export const RETRY_NEXT_YEAR_MS = 7 * DAY_MS;
/** Das geladene laufende Jahr wird einmal pro Woche neu geladen (Änderungen der Quelle, z. B. verschobene Abholungen). */
export const RELOAD_CURRENT_MS = 7 * DAY_MS;
/** Liefert ein Neuladen weniger als diesen Anteil der bisherigen Termine, überschreibt es ein geladenes Jahr nicht (Code `shrunk`). */
export const SHRINK_MIN_RATIO = 0.5;
/** „Jetzt prüfen“: höchstens eine Anforderung je Familie in diesem Abstand (serverseitig erzwungen). */
export const CHECK_REQUEST_GAP_MS = 10 * 60_000;

export type YearStatus = 'loaded' | 'unavailable' | 'error';

/** Kalenderjahr und -monat in der Familienzeitzone (Europe/Berlin). */
export function berlinJahrMonat(now: Date): { year: number; month: number } {
  const teile = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin', year: 'numeric', month: 'numeric' }).formatToParts(now);
  const wert = (t: string) => Number(teile.find((p) => p.type === t)?.value);
  return { year: wert('year'), month: wert('month') };
}

/** 1. Dezember, 00:00 Uhr Berlin (Winterzeit, UTC+1) des Jahres. */
const dezemberAnfang = (year: number): number => Date.UTC(year, 10, 30, 23, 0, 0);

export interface YearRow {
  year: number;
  status: YearStatus;
  lastCheckedAt: Date | null;
}

/** Welche Jahre der automatische Takt jetzt abruft (rein, ohne Datenbank). `ersterLauf`: nach dem Start gilt der Wartetabstand nicht. */
export function faelligeJahre(now: Date, rows: YearRow[], ersterLauf: boolean): number[] {
  const { year, month } = berlinJahrMonat(now);
  const nowMs = now.getTime();
  const zeile = (y: number) => rows.find((r) => r.year === y);
  const out: number[] = [];
  const aktuell = zeile(year);
  if (aktuell?.status !== 'loaded') {
    const last = aktuell?.lastCheckedAt?.getTime();
    if (ersterLauf || last === undefined || nowMs - last >= RETRY_MISSING_MS) out.push(year);
  } else {
    // geladen: einmal pro Woche neu laden (bei Fehler oder Schrumpfen bleibt der Stand stehen)
    const last = aktuell.lastCheckedAt?.getTime();
    if (last === undefined || nowMs - last >= RELOAD_CURRENT_MS) out.push(year);
  }
  if (month === 12) {
    const naechst = zeile(year + 1);
    if (naechst?.status !== 'loaded') {
      const last = naechst?.lastCheckedAt?.getTime();
      if (last === undefined || last < dezemberAnfang(year) || nowMs - last >= RETRY_NEXT_YEAR_MS) out.push(year + 1);
    }
  }
  return out;
}

/**
 * Wann der Takt das nächste Mal von selbst abruft (für die Anzeige der Admins); null = nichts geplant oder gleich beim nächsten Takt.
 * Der Wert hängt nur vom gespeicherten Stand ab (nicht von der Uhr), damit die Antwort sich ohne Änderung nicht ändert; liegt er in der Vergangenheit, ist die Prüfung fällig.
 */
export function naechstePruefung(now: Date, rows: YearRow[]): Date | null {
  const { year, month } = berlinJahrMonat(now);
  const zeile = (y: number) => rows.find((r) => r.year === y);
  const aktuell = zeile(year);
  if (aktuell?.status !== 'loaded') {
    const last = aktuell?.lastCheckedAt?.getTime();
    return last === undefined ? null : new Date(last + RETRY_MISSING_MS);
  }
  // geladenes laufendes Jahr: wöchentliches Neuladen; dazu das nächste Jahr ab Dezember, solange es fehlt; das frühere der beiden zählt
  const kandidaten: number[] = [];
  const lastAktuell = aktuell.lastCheckedAt?.getTime();
  if (lastAktuell !== undefined) kandidaten.push(lastAktuell + RELOAD_CURRENT_MS);
  const naechst = zeile(year + 1);
  if (naechst?.status !== 'loaded') {
    if (month < 12) kandidaten.push(dezemberAnfang(year));
    else {
      const last = naechst?.lastCheckedAt?.getTime();
      kandidaten.push(last === undefined || last < dezemberAnfang(year) ? dezemberAnfang(year) : last + RETRY_NEXT_YEAR_MS);
    }
  }
  return kandidaten.length === 0 ? null : new Date(Math.min(...kandidaten));
}

/** Fester Fehlercode -> Zustand des Jahres (leer, ungültig oder 404 = noch nicht da; alles andere = Quelle nicht erreichbar). */
function statusOfCode(code: string): YearStatus {
  return code === 'empty' || code === 'not_ics' || code === 'http_404' ? 'unavailable' : 'error';
}

export interface WasteServiceDeps {
  db: Db;
  config: Config;
  log: Logger;
  now?: () => Date;
  fetch?: typeof fetch;
}

export interface WasteView {
  place?: string;
  /** Alle bekannten Jahre mit Stand (nur feste Codes). */
  years: { year: number; status: YearStatus; eventCount: number; checkedAt: string | null; errorCode: string | null }[];
  /** Termine der geladenen Jahre, je Tag die Arten. */
  events: { date: string; kinds: WasteKind[] }[];
  check: {
    /** Eine Prüfung ist angefordert und noch nicht abgearbeitet. */
    pending: boolean;
    lastCheckAt: string | null;
    nextCheckAt: string | null;
    /** Ab wann „Jetzt prüfen“ wieder angefordert werden darf (null = jederzeit). */
    nextRequestAt: string | null;
  };
}

export type CheckRequest = { ok: true } | { ok: false; retryAfterSec: number };

export class WasteService {
  private readonly db: Db;
  private readonly cfg: Config['waste'];
  private readonly log: Logger;
  private readonly now: () => Date;
  private readonly fetchFn: typeof fetch;
  private timer: NodeJS.Timeout | null = null;
  private currentTick: Promise<void> | null = null;
  private running = false;
  private closed = false;
  private ersterLauf = true;

  constructor(deps: WasteServiceDeps) {
    this.db = deps.db;
    this.cfg = deps.config.waste;
    this.log = deps.log;
    this.now = deps.now ?? (() => new Date());
    this.fetchFn = deps.fetch ?? fetch;
  }

  get enabled(): boolean {
    return this.cfg.enabled;
  }

  // ---- Takt (nur im Dienst lx-fampad-waste) ----

  start(): void {
    if (!this.cfg.enabled || this.timer || this.closed) return;
    this.schedule(3_000);
  }

  close(): void {
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  async drain(timeoutMs: number): Promise<void> {
    const lauf = this.currentTick;
    if (!lauf) return;
    let t: NodeJS.Timeout | undefined;
    await Promise.race([lauf.catch(() => undefined), new Promise<void>((r) => (t = setTimeout(r, timeoutMs)))]);
    clearTimeout(t);
  }

  private schedule(ms: number): void {
    if (this.closed) return;
    this.timer = setTimeout(() => {
      this.currentTick = this.tick().finally(() => {
        this.currentTick = null;
      });
    }, ms);
    this.timer.unref();
  }

  private async tick(): Promise<void> {
    try {
      await this.runDue();
    } catch {
      // nie die Fehlermeldung loggen (könnte die URL enthalten)
      this.log.error({ code: 'waste_tick' }, 'Abfuhrtermine: Takt fehlgeschlagen');
    }
    this.schedule(this.cfg.tickMs);
  }

  /** Die Familie, für die gespeichert wird (der Server bedient genau eine Familie: die älteste). */
  async servedFamilyId(): Promise<string | null> {
    const [row] = await this.db.select({ id: families.id }).from(families).orderBy(asc(families.createdAt), asc(families.id)).limit(1);
    return row?.id ?? null;
  }

  private async yearRows(familyId: string): Promise<(YearRow & { eventCount: number; loadedAt: Date | null; errorCode: string | null })[]> {
    const rows = await this.db.select().from(wasteYears).where(eq(wasteYears.familyId, familyId)).orderBy(asc(wasteYears.year));
    return rows.map((r) => ({ year: r.year, status: r.status as YearStatus, lastCheckedAt: r.lastCheckedAt, eventCount: r.eventCount, loadedAt: r.loadedAt, errorCode: r.errorCode }));
  }

  /**
   * Ein Durchlauf des Takts (auch für Tests): zuerst eine angeforderte Prüfung (laufendes und nächstes Jahr),
   * sonst die fälligen Jahre nach der Jahreslogik. Gibt die abgerufenen Jahre zurück. Läuft nie doppelt.
   */
  async runDue(): Promise<number[]> {
    if (!this.cfg.enabled || this.running) return [];
    this.running = true;
    try {
      const familyId = await this.servedFamilyId();
      if (!familyId) return [];
      const now = this.now();
      const rows = await this.yearRows(familyId);
      const { year } = berlinJahrMonat(now);
      const [state] = await this.db.select().from(wasteState).where(eq(wasteState.familyId, familyId));
      const angefordert = state?.checkRequestedAt ?? null;
      let jahre: number[];
      if (angefordert) {
        // Anforderung (Eltern/Admins): das laufende Jahr (neu laden bzw. nachholen) und das nächste Jahr
        jahre = [year, year + 1];
      } else {
        jahre = faelligeJahre(now, rows, this.ersterLauf);
      }
      this.ersterLauf = false;
      for (const y of jahre) await this.fetchYear(familyId, y);
      if (jahre.length > 0 || angefordert) {
        const fertig = this.now();
        await this.db
          .insert(wasteState)
          .values({ familyId, lastCheckAt: fertig })
          .onConflictDoUpdate({ target: wasteState.familyId, set: { lastCheckAt: fertig } });
      }
      if (angefordert) {
        // nur die abgearbeitete Anforderung löschen (eine neuere bleibt für den nächsten Takt)
        await this.db
          .update(wasteState)
          .set({ checkRequestedAt: null })
          .where(and(eq(wasteState.familyId, familyId), isNotNull(wasteState.checkRequestedAt), lte(wasteState.checkRequestedAt, angefordert)));
      }
      return jahre;
    } finally {
      this.running = false;
    }
  }

  /** Hält einen Fehlschlag fest (nur ein fester Code): ein schon geladenes Jahr bleibt `loaded` und behält seine Termine. */
  private async markiereFehler(familyId: string, year: number, code: string): Promise<void> {
    const now = this.now();
    const [vorhanden] = await this.db.select().from(wasteYears).where(and(eq(wasteYears.familyId, familyId), eq(wasteYears.year, year)));
    const status: YearStatus = vorhanden?.status === 'loaded' ? 'loaded' : statusOfCode(code);
    await this.db
      .insert(wasteYears)
      .values({ familyId, year, status, eventCount: 0, lastCheckedAt: now, errorCode: code })
      .onConflictDoUpdate({ target: [wasteYears.familyId, wasteYears.year], set: { status, lastCheckedAt: now, errorCode: code } });
    this.log.warn({ code, year }, 'Abfuhrtermine: kein Ergebnis');
  }

  /**
   * Lädt und speichert ein Jahr. Gibt den Fehlercode zurück oder null bei Erfolg. Nie eine Ausnahme: scheitert die Datenbank nach dem Abruf, wird
   * zuerst `last_checked_at` mit dem Code `db` geschrieben (Wartezeit statt eines Abrufs in jedem Takt).
   */
  async fetchYear(familyId: string, year: number): Promise<string | null> {
    try {
      return await this.fetchYearInner(familyId, year);
    } catch {
      // nie die Fehlermeldung loggen (könnte Parameter oder die URL enthalten)
      try {
        await this.markiereFehler(familyId, year, 'db');
      } catch {
        this.log.error({ code: 'db', year }, 'Abfuhrtermine: Datenbankfehler');
      }
      return 'db';
    }
  }

  private async fetchYearInner(familyId: string, year: number): Promise<string | null> {
    const ergebnis = await this.holeJahr(year);
    const now = this.now();
    if (!('entries' in ergebnis)) {
      await this.markiereFehler(familyId, year, ergebnis.code);
      return ergebnis.code;
    }
    const entries = ergebnis.entries;
    // Ein geladenes Jahr nicht durch ein deutlich kleineres ersetzen (Fehler der Quelle): unter der Hälfte der bisherigen Termine bleibt der Stand
    const [bisher] = await this.db.select().from(wasteYears).where(and(eq(wasteYears.familyId, familyId), eq(wasteYears.year, year)));
    if (bisher?.status === 'loaded' && bisher.eventCount > 0 && entries.length < bisher.eventCount * SHRINK_MIN_RATIO) {
      await this.markiereFehler(familyId, year, 'shrunk');
      return 'shrunk';
    }
    await this.db.transaction(async (tx) => {
      await tx.delete(wasteEvents).where(and(eq(wasteEvents.familyId, familyId), gte(wasteEvents.day, `${year}-01-01`), lte(wasteEvents.day, `${year}-12-31`)));
      await tx.insert(wasteEvents).values(entries.map((e) => ({ familyId, day: e.day, kind: e.kind })));
      await tx
        .insert(wasteYears)
        .values({ familyId, year, status: 'loaded', eventCount: entries.length, loadedAt: now, lastCheckedAt: now, errorCode: null })
        .onConflictDoUpdate({
          target: [wasteYears.familyId, wasteYears.year],
          set: { status: 'loaded', eventCount: entries.length, loadedAt: sql`coalesce(${wasteYears.loadedAt}, ${now.toISOString()}::timestamptz)`, lastCheckedAt: now, errorCode: null },
        });
    });
    this.log.info?.({ year, count: entries.length }, 'Abfuhrtermine geladen');
    return null;
  }

  /** Ruft die Datei eines Jahres ab und prüft sie streng. Nie ein Fehlertext oder die URL nach außen, nur feste Codes. */
  private async holeJahr(year: number): Promise<{ entries: WasteEntry[] } | { code: string }> {
    const url = this.cfg.icsUrl.replaceAll('{YEAR}', String(year));
    let res: Response;
    let text: string;
    try {
      // nur der konfigurierte Host (Gegenprüfung zur Konfiguration), nie ein Redirect (auch nicht zum selben Host)
      if (new URL(url).hostname !== this.cfg.host) return { code: 'host' };
      res = await this.fetchFn(url, {
        headers: { 'user-agent': this.cfg.userAgent, accept: 'text/calendar, text/plain;q=0.9, */*;q=0.5' },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        redirect: 'manual',
      });
      if (res.status >= 300 && res.status < 400) {
        await res.body?.cancel().catch(() => undefined);
        return { code: 'redirect' };
      }
      if (!res.ok) {
        await res.body?.cancel().catch(() => undefined);
        return { code: `http_${res.status}` };
      }
      const t = await leseBegrenzt(res, MAX_ICS_BYTES);
      if (t === null) return { code: 'too_large' };
      text = t;
    } catch {
      return { code: 'network' };
    }
    const p = parseWasteIcs(text);
    if (!p.ok) return { code: p.code };
    const imJahr = p.entries.filter((e) => e.day.startsWith(`${year}-`));
    if (imJahr.length === 0) return { code: 'empty' };
    return { entries: imJahr };
  }

  // ---- API (nur lesen und Anforderung setzen; der API-Prozess ruft nie ab) ----

  /** „Jetzt prüfen“: setzt die Anforderung, höchstens eine je Familie in [CHECK_REQUEST_GAP_MS]; der Dienst holt sie im nächsten Takt ab. */
  async requestCheck(familyId: string): Promise<CheckRequest> {
    const now = this.now();
    await this.db.insert(wasteState).values({ familyId }).onConflictDoNothing();
    const grenze = new Date(now.getTime() - CHECK_REQUEST_GAP_MS);
    const gesetzt = await this.db
      .update(wasteState)
      .set({ checkRequestedAt: now, lastRequestAt: now })
      .where(and(eq(wasteState.familyId, familyId), sql`(${wasteState.lastRequestAt} is null or ${wasteState.lastRequestAt} <= ${grenze.toISOString()}::timestamptz)`))
      .returning({ id: wasteState.familyId });
    if (gesetzt.length > 0) return { ok: true };
    const [s] = await this.db.select().from(wasteState).where(eq(wasteState.familyId, familyId));
    const last = s?.lastRequestAt?.getTime() ?? 0;
    return { ok: false, retryAfterSec: Math.max(1, Math.ceil((last + CHECK_REQUEST_GAP_MS - now.getTime()) / 1000)) };
  }

  /** Stand und Termine für die Mitglieder der Familie der Sitzung (nie Quelle, Straße, UID oder Fehlertexte). */
  async view(familyId: string): Promise<WasteView> {
    const now = this.now();
    const rows = await this.yearRows(familyId);
    // Hinweis: `now` nur für die Jahreslogik der geplanten Prüfung
    const geladen =rows.filter((r) => r.status === 'loaded').map((r) => r.year);
    const ev = geladen.length
      ? await this.db
          .select({ day: wasteEvents.day, kind: wasteEvents.kind })
          .from(wasteEvents)
          .where(and(eq(wasteEvents.familyId, familyId), gte(wasteEvents.day, `${Math.min(...geladen)}-01-01`), lte(wasteEvents.day, `${Math.max(...geladen)}-12-31`)))
          .orderBy(asc(wasteEvents.day), asc(wasteEvents.kind))
      : [];
    const tage = new Map<string, WasteKind[]>();
    for (const e of ev) {
      if (!geladen.includes(Number(e.day.slice(0, 4)))) continue;
      const liste = tage.get(e.day) ?? [];
      liste.push(e.kind as WasteKind);
      tage.set(e.day, liste);
    }
    const [state] = await this.db.select().from(wasteState).where(eq(wasteState.familyId, familyId));
    const lastReq = state?.lastRequestAt?.getTime();
    const next = naechstePruefung(now, rows);
    return {
      ...(this.cfg.place ? { place: this.cfg.place } : {}),
      years: rows.map((r) => ({ year: r.year, status: r.status, eventCount: r.eventCount, checkedAt: r.lastCheckedAt?.toISOString() ?? null, errorCode: r.errorCode })),
      events: [...tage.entries()].map(([date, kinds]) => ({ date, kinds })),
      check: {
        pending: Boolean(state?.checkRequestedAt),
        lastCheckAt: state?.lastCheckAt?.toISOString() ?? null,
        nextCheckAt: next?.toISOString() ?? null,
        nextRequestAt: lastReq === undefined ? null : new Date(lastReq + CHECK_REQUEST_GAP_MS).toISOString(),
      },
    };
  }
}
