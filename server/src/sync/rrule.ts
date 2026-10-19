// Prüfung von Wiederholungsregeln (RFC 5545, Teilmenge) für Termine. Bewusst ein Hand-Tokenizer ohne verschachtelte reguläre Ausdrücke
// (kein ReDoS) und mit harten Obergrenzen; der Client expandiert die Regel (Paket `rrule`) und ist auf dieselbe Teilmenge begrenzt.
//
// Erlaubt: FREQ (DAILY, WEEKLY, MONTHLY, YEARLY), INTERVAL (1-999), COUNT (1-1000) oder UNTIL (nicht beide), BYDAY (je Tag MO..SU, bei
// MONTHLY/YEARLY mit Zahl -5..5 davor), BYMONTHDAY (-31..31 ohne 0), BYMONTH (1-12), BYSETPOS (-5..5 ohne 0), WKST.
// Abgelehnt: SECONDLY/MINUTELY/HOURLY, BYHOUR/BYMINUTE/BYSECOND, BYYEARDAY/BYWEEKNO, Präfix "RRULE:", Kleinbuchstaben, doppelte Teile.
export const RRULE_MAX_LENGTH = 300;
export const RRULE_MAX_COUNT = 1000;
const MAX_LIST = 31;
const FREQS = new Set(['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY']);
const DAYS = new Set(['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU']);

const isDigits = (s: string, maxLen: number): boolean => {
  if (s.length === 0 || s.length > maxLen) return false;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 48 || c > 57) return false;
  }
  return true;
};

/** Ganze Zahl mit optionalem Vorzeichen im Bereich [min, max]. */
function intInRange(s: string, min: number, max: number, allowZero: boolean): boolean {
  const neg = s.startsWith('-');
  const body = neg || s.startsWith('+') ? s.slice(1) : s;
  if (!isDigits(body, 4)) return false;
  const n = (neg ? -1 : 1) * Number(body);
  if (n === 0 && !allowZero) return false;
  return n >= min && n <= max;
}

/** `YYYYMMDD` oder `YYYYMMDDTHHMMSSZ` als echter Zeitpunkt. */
export function isRruleUntil(v: string): boolean {
  const dateOnly = v.length === 8;
  if (!(dateOnly || (v.length === 16 && v[8] === 'T' && v[15] === 'Z'))) return false;
  const d = v.slice(0, 8);
  const t = dateOnly ? '000000' : v.slice(9, 15);
  if (!isDigits(d, 8) || !isDigits(t, 6)) return false;
  const [y, mo, da, h, mi, se] = [d.slice(0, 4), d.slice(4, 6), d.slice(6, 8), t.slice(0, 2), t.slice(2, 4), t.slice(4, 6)].map(Number) as [number, number, number, number, number, number];
  if (y < 2000 || y >= 2200 || h > 23 || mi > 59 || se > 59) return false;
  const date = new Date(Date.UTC(y, mo - 1, da, h, mi, se));
  return date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === da;
}

function dayList(value: string, withOrdinal: boolean): boolean {
  const items = value.split(',');
  if (items.length > MAX_LIST) return false;
  return items.every((item) => {
    const day = item.slice(-2);
    const prefix = item.slice(0, -2);
    if (!DAYS.has(day)) return false;
    if (prefix === '') return true;
    return withOrdinal && intInRange(prefix, -5, 5, false);
  });
}

function numberList(value: string, min: number, max: number, allowZero: boolean): boolean {
  const items = value.split(',');
  return items.length <= MAX_LIST && items.every((i) => intInRange(i, min, max, allowZero));
}

/** Ist `text` eine zulässige Wiederholungsregel? */
export function isValidRrule(text: string): boolean {
  if (text.length === 0 || text.length > RRULE_MAX_LENGTH) return false;
  const seen = new Set<string>();
  const parts = text.split(';');
  if (parts.length > 10) return false;
  let freq = '';
  for (const part of parts) {
    const eq = part.indexOf('=');
    if (eq <= 0) return false;
    const key = part.slice(0, eq);
    const value = part.slice(eq + 1);
    if (seen.has(key) || value.length === 0) return false;
    seen.add(key);
    switch (key) {
      case 'FREQ':
        if (!FREQS.has(value)) return false;
        freq = value;
        break;
      case 'INTERVAL':
        if (!isDigits(value, 3) || Number(value) < 1) return false;
        break;
      case 'COUNT':
        if (!isDigits(value, 4) || Number(value) < 1 || Number(value) > RRULE_MAX_COUNT) return false;
        break;
      case 'UNTIL':
        if (!isRruleUntil(value)) return false;
        break;
      case 'BYDAY':
        // Zahl vor dem Wochentag nur bei MONTHLY/YEARLY (FREQ steht eventuell erst später: unten nochmals geprüft)
        if (!dayList(value, true)) return false;
        break;
      case 'BYMONTHDAY':
        if (!numberList(value, -31, 31, false)) return false;
        break;
      case 'BYMONTH':
        if (!numberList(value, 1, 12, false)) return false;
        break;
      case 'BYSETPOS':
        if (!numberList(value, -5, 5, false)) return false;
        break;
      case 'WKST':
        if (!DAYS.has(value)) return false;
        break;
      default:
        return false;
    }
  }
  if (freq === '') return false;
  if (seen.has('COUNT') && seen.has('UNTIL')) return false;
  if (freq !== 'MONTHLY' && freq !== 'YEARLY') {
    const byday = parts.find((p) => p.startsWith('BYDAY='));
    if (byday && !dayList(byday.slice(6), false)) return false;
    if (seen.has('BYSETPOS') || seen.has('BYMONTHDAY')) return false;
  }
  return true;
}
