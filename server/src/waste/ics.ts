// Strenger ICS-Parser für den Abfuhrkalender. Gelesen werden NUR Tag (DTSTART;VALUE=DATE) und Art (SUMMARY) je VEVENT.
// UID, LOCATION, DESCRIPTION und alle anderen Felder der Quelle werden nie gelesen, gespeichert oder weitergegeben (die Straße
// gehört nicht in die Schnittstelle). Harte Obergrenzen für Größe, Zeilen und Termine; keine Rekursion (Zustandsautomat, tiefe
// Verschachtelung wird nur gezählt und übersprungen).
import type { WasteKind } from '../db/schema.js';

export const MAX_ICS_BYTES = 1_000_000;
const MAX_LINES = 50_000;
const MAX_LINE_LENGTH = 4000;
const MAX_EVENTS = 3000;
const MAX_DEPTH = 8;
const MAX_SUMMARY = 120;

export interface WasteEntry {
  /** YYYY-MM-DD */
  day: string;
  kind: WasteKind;
}

export type IcsResult = { ok: true; entries: WasteEntry[] } | { ok: false; code: 'not_ics' | 'too_large' | 'too_many' };

/** Name der Quelle -> feste Abfallart. Unbekanntes wird `sonst`. */
export function kindOfSummary(summary: string): WasteKind {
  const s = summary.toLowerCase().replaceAll('ä', 'ae').replaceAll('ö', 'oe').replaceAll('ü', 'ue').replaceAll('ß', 'ss');
  if (s.includes('weihnacht') || s.includes('tannenbaum')) return 'baum';
  if (s.includes('sperr')) return 'sperr';
  if (s.includes('sonderabfall') || s.includes('schadstoff') || s.includes('problem')) return 'sonder';
  if (s.includes('gelb') || s.includes('wertstoff') || s.includes('leichtverpack')) return 'gelb';
  if (s.includes('papier') || s.includes('pappe') || s.includes('karton')) return 'papier';
  if (s.includes('bio')) return 'bio';
  if (s.includes('gruen') || s.includes('garten') || s.includes('strauch')) return 'gruen';
  if (s.includes('rest') || s.includes('hausmuell')) return 'rest';
  return 'sonst';
}

/** Gültiges Kalenderdatum YYYYMMDD -> "YYYY-MM-DD", sonst null. */
function datum(v: string): string | null {
  const m = /^(\d{4})(\d{2})(\d{2})$/.exec(v);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const t = new Date(Date.UTC(y, mo - 1, d));
  if (y < 2000 || y > 2200 || t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return null;
  return `${m[1]}-${m[2]}-${m[3]}`;
}

/** Entfernt die ICS-Maskierung (\, \; \\ \n) des SUMMARY-Textes. */
function entmaskiere(v: string): string {
  return v.replace(/\\([,;\\nN])/g, (_m, c: string) => (c === 'n' || c === 'N' ? ' ' : c));
}

export function parseWasteIcs(text: string): IcsResult {
  if (Buffer.byteLength(text, 'utf8') > MAX_ICS_BYTES) return { ok: false, code: 'too_large' };
  // Zeilen entfalten (Fortsetzungszeilen beginnen mit Leerzeichen oder Tab), CRLF oder LF
  const roh = (text.charCodeAt(0) === 0xfeff ? text.slice(1) : text).split(/\r\n|\n|\r/);
  if (roh.length > MAX_LINES) return { ok: false, code: 'too_large' };
  const zeilen: string[] = [];
  for (const z of roh) {
    if ((z.startsWith(' ') || z.startsWith('\t')) && zeilen.length > 0) zeilen[zeilen.length - 1] += z.slice(1);
    else zeilen.push(z);
    if ((zeilen[zeilen.length - 1] as string).length > MAX_LINE_LENGTH) return { ok: false, code: 'not_ics' };
  }
  let i = 0;
  while (i < zeilen.length && (zeilen[i] as string).trim() === '') i++;
  if ((zeilen[i] ?? '').trim().toUpperCase() !== 'BEGIN:VCALENDAR') return { ok: false, code: 'not_ics' };

  const entries = new Map<string, WasteEntry>();
  let beendet = false;
  let inEvent = false;
  let tiefe = 0; // Verschachtelung innerhalb eines VEVENT (z. B. VALARM): wird übersprungen
  let start: string | null = null;
  let summary: string | null = null;
  let abgesagt = false;
  let gesehen = 0;

  for (const zeile of zeilen.slice(i + 1)) {
    const l = zeile.trim();
    if (l === '') continue;
    const u = l.toUpperCase();
    if (!inEvent) {
      if (u === 'BEGIN:VEVENT') {
        inEvent = true;
        tiefe = 0;
        start = null;
        summary = null;
        abgesagt = false;
        if (++gesehen > MAX_EVENTS) return { ok: false, code: 'too_many' };
      } else if (u === 'END:VCALENDAR') {
        beendet = true;
        break;
      }
      continue;
    }
    if (u.startsWith('BEGIN:')) {
      if (++tiefe > MAX_DEPTH) return { ok: false, code: 'not_ics' };
      continue;
    }
    if (u.startsWith('END:')) {
      if (tiefe > 0) {
        tiefe--;
        continue;
      }
      if (u !== 'END:VEVENT') return { ok: false, code: 'not_ics' };
      inEvent = false;
      if (start !== null && summary !== null && !abgesagt) {
        const kind = kindOfSummary(summary);
        entries.set(`${start}|${kind}`, { day: start, kind });
      }
      continue;
    }
    if (tiefe > 0) continue;
    const dp = l.indexOf(':');
    if (dp < 1) continue;
    const name = l.slice(0, dp).toUpperCase().replaceAll(' ', '');
    const wert = l.slice(dp + 1);
    if (name === 'DTSTART;VALUE=DATE') start = datum(wert.trim());
    else if (name === 'SUMMARY' || name.startsWith('SUMMARY;')) summary = entmaskiere(wert).trim().slice(0, MAX_SUMMARY);
    else if (name === 'STATUS' && wert.trim().toUpperCase() === 'CANCELLED') abgesagt = true;
  }
  if (!beendet || inEvent) return { ok: false, code: 'not_ics' };
  return { ok: true, entries: [...entries.values()].sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : a.kind < b.kind ? -1 : 1)) };
}
