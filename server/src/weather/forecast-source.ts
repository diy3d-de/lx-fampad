// Quelle der Vorhersage und der amtlichen Warnungen. Alles, was die Quelle betrifft (Host, Pfade, Aufbau der Antwort), steht NUR in dieser Datei:
// ein anderer Dienst (oder die DWD-Rohdaten direkt) ersetzt `brightSky` durch eine andere `ForecastSource`, ohne dass Dienst, Speicherung, Route oder App
// etwas merken. Aktuelle Quelle: Bright Sky (https://api.brightsky.dev, kostenlos, Daten aus DWD Open Data: MOSMIX-Vorhersage und Warn-Feed des Deutschen
// Wetterdienstes; Quellenangabe "Deutscher Wetterdienst"). Es gehen nur auf 2 Nachkommastellen gerundete Gebietskoordinaten und Tage hinaus.
//
// Die Auswertung ist streng: nur Zahlen in plausiblen Bereichen, Wetterlagen nur als feste Symbolcodes, Warntexte nur gekürzt und von Steuer- und
// Formatierungszeichen bereinigt (nie HTML), alles Unbekannte wird verworfen. Kein Wert der Antwort wird je als Code oder Adresse benutzt.
import { berlinTag } from './summary.js';

/** Feste Symbolcodes (dieselben verwendet die App). */
export const WETTER_SYMBOLE = ['sonne', 'nacht', 'teils', 'teils-nacht', 'wolken', 'nebel', 'wind', 'regen', 'schneeregen', 'schnee', 'hagel', 'gewitter', 'unbekannt'] as const;
export type WetterSymbol = (typeof WETTER_SYMBOLE)[number];

/** Feste Arten der amtlichen Warnungen. */
export const WARN_ARTEN = ['gewitter', 'wind', 'regen', 'schnee', 'glaette', 'frost', 'hitze', 'nebel', 'uv', 'tauwetter', 'sonst'] as const;
export type WarnArt = (typeof WARN_ARTEN)[number];

export interface VorhersageStunde {
  /** Beginn der Stunde (ISO, UTC). */
  t: string;
  temp: number;
  /** Niederschlag in mm in dieser Stunde. */
  rain: number;
  /** Regenwahrscheinlichkeit in Prozent (null = nicht angegeben). */
  pop: number | null;
  windKmh: number | null;
  gustKmh: number | null;
  symbol: WetterSymbol;
}

export interface VorhersageTag {
  /** Kalendertag (YYYY-MM-DD, Europe/Berlin). */
  date: string;
  min: number;
  max: number;
  rain: number;
  pop: number | null;
  windKmh: number | null;
  gustKmh: number | null;
  symbol: WetterSymbol;
}

export interface VorhersageDaten {
  days: VorhersageTag[];
  hours: VorhersageStunde[];
}

export interface Warnung {
  /** DWD-Stufe: 1 Wetterwarnung, 2 markante Wetterwarnung, 3 Unwetterwarnung, 4 extreme Unwetterwarnung. */
  level: 1 | 2 | 3 | 4;
  kind: WarnArt;
  title: string;
  text: string;
  /** Beginn und Ende (ISO, UTC); Ende null = offen. */
  from: string;
  until: string | null;
}

export interface ForecastSource {
  /** Anfrage der Vorhersage ab dem Berliner Tag `ab` bis `bis` (YYYY-MM-DD). */
  forecastUrl(lat: number, lon: number, ab: string, bis: string): string;
  alertsUrl(lat: number, lon: number): string;
  /** null = unbrauchbare Antwort (nichts speichern). */
  parseForecast(json: unknown, nowMs: number): VorhersageDaten | null;
  parseAlerts(json: unknown, nowMs: number): Warnung[] | null;
}

const MAX_RECORDS = 400;
const MAX_ALERTS = 10;
const HOUR_MS = 3_600_000;
export const MAX_HOURS_STORED = 60;
export const MAX_DAYS = 7;

const rec = (v: unknown): Record<string, unknown> | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
function zahl(v: unknown, min: number, max: number): number | null {
  return typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : null;
}
const runde = (n: number, stellen: number) => Math.round(n * 10 ** stellen) / 10 ** stellen;
const zeit = (v: unknown): number | null => {
  if (typeof v !== 'string' || v.length > 40 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) return null;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? ms : null;
};

const ICONS: Record<string, WetterSymbol> = {
  'clear-day': 'sonne',
  'clear-night': 'nacht',
  'partly-cloudy-day': 'teils',
  'partly-cloudy-night': 'teils-nacht',
  cloudy: 'wolken',
  fog: 'nebel',
  wind: 'wind',
  rain: 'regen',
  sleet: 'schneeregen',
  snow: 'schnee',
  hail: 'hagel',
  thunderstorm: 'gewitter',
};
const CONDITIONS: Record<string, WetterSymbol> = { fog: 'nebel', rain: 'regen', sleet: 'schneeregen', snow: 'schnee', hail: 'hagel', thunderstorm: 'gewitter' };

function symbolVon(icon: unknown, condition: unknown): WetterSymbol {
  if (typeof icon === 'string' && Object.hasOwn(ICONS, icon)) return ICONS[icon]!;
  if (typeof condition === 'string' && Object.hasOwn(CONDITIONS, condition)) return CONDITIONS[condition]!;
  return 'unbekannt';
}

/** Rangfolge der Tagessymbole: das Schlimmste des Tages gewinnt (bei Gewitter/Hagel schon eine Stunde, sonst ab zwei Stunden). */
const SCHLIMM: { s: WetterSymbol; ab: number }[] = [
  { s: 'gewitter', ab: 1 },
  { s: 'hagel', ab: 1 },
  { s: 'schnee', ab: 2 },
  { s: 'schneeregen', ab: 2 },
  { s: 'regen', ab: 2 },
  { s: 'nebel', ab: 4 },
];
const TAG_SYMBOL: Partial<Record<WetterSymbol, WetterSymbol>> = { nacht: 'sonne', 'teils-nacht': 'teils' };

function tagesSymbol(symbole: WetterSymbol[]): WetterSymbol {
  const n = (s: WetterSymbol) => symbole.filter((x) => x === s).length;
  for (const { s, ab } of SCHLIMM) if (n(s) >= ab) return s;
  const zaehler = new Map<WetterSymbol, number>();
  for (const s of symbole) {
    const t = TAG_SYMBOL[s] ?? s;
    if (t === 'sonne' || t === 'teils' || t === 'wolken') zaehler.set(t, (zaehler.get(t) ?? 0) + 1);
  }
  let best: WetterSymbol = 'unbekannt';
  let bestN = 0;
  for (const [s, c] of zaehler) if (c > bestN) [best, bestN] = [s, c];
  return best;
}

const BERLIN_STUNDE = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Berlin', hour: '2-digit', hourCycle: 'h23' });

/** Bright Sky `GET /weather` (stündliche Werte, MOSMIX für die Zukunft): Einheiten dwd = °C, mm, km/h, hPa. */
function parseBrightSkyForecast(json: unknown, nowMs: number): VorhersageDaten | null {
  const liste = rec(json)?.weather;
  if (!Array.isArray(liste) || liste.length === 0) return null;
  const stunden: (VorhersageStunde & { ms: number })[] = [];
  for (const raw of liste.slice(0, MAX_RECORDS)) {
    const r = rec(raw);
    if (!r) continue;
    const ms = zeit(r.timestamp);
    const temp = zahl(r.temperature, -60, 60);
    if (ms === null || temp === null) continue;
    const rain = zahl(r.precipitation, 0, 300);
    const pop = zahl(r.precipitation_probability, 0, 100);
    const wind = zahl(r.wind_speed, 0, 400);
    const gust = zahl(r.wind_gust_speed, 0, 500);
    stunden.push({
      ms,
      t: new Date(ms).toISOString(),
      temp: runde(temp, 1),
      rain: rain === null ? 0 : runde(rain, 1),
      pop: pop === null ? null : Math.round(pop),
      windKmh: wind === null ? null : Math.round(wind),
      gustKmh: gust === null ? null : Math.round(gust),
      symbol: symbolVon(r.icon, r.condition),
    });
  }
  if (stunden.length === 0) return null;
  stunden.sort((a, b) => a.ms - b.ms);
  // Tage: nach Berliner Kalendertag gruppieren; ein Rand-Tag mit wenigen Stunden zählt nicht
  const heute = berlinTag(new Date(nowMs));
  const nachTag = new Map<string, typeof stunden>();
  for (const s of stunden) {
    const d = berlinTag(new Date(s.ms));
    if (d < heute) continue;
    const l = nachTag.get(d);
    if (l) l.push(s);
    else nachTag.set(d, [s]);
  }
  const days: VorhersageTag[] = [];
  for (const [date, l] of [...nachTag.entries()].sort(([a], [b]) => (a < b ? -1 : 1))) {
    if (l.length < 6 || days.length >= MAX_DAYS) continue;
    const temps = l.map((s) => s.temp);
    const pops = l.map((s) => s.pop).filter((p): p is number => p !== null);
    const winde = l.map((s) => s.windKmh).filter((w): w is number => w !== null);
    const boeen = l.map((s) => s.gustKmh).filter((w): w is number => w !== null);
    const tagStunden = l.filter((s) => {
      const h = Number(BERLIN_STUNDE.format(new Date(s.ms)));
      return h >= 7 && h <= 21;
    });
    days.push({
      date,
      min: Math.min(...temps),
      max: Math.max(...temps),
      rain: runde(l.reduce((sum, s) => sum + s.rain, 0), 1),
      pop: pops.length ? Math.max(...pops) : null,
      windKmh: winde.length ? Math.max(...winde) : null,
      gustKmh: boeen.length ? Math.max(...boeen) : null,
      symbol: tagesSymbol((tagStunden.length ? tagStunden : l).map((s) => s.symbol)),
    });
  }
  if (days.length === 0) return null;
  const hours = stunden
    .filter((s) => s.ms >= nowMs - 2 * HOUR_MS)
    .slice(0, MAX_HOURS_STORED)
    .map(({ ms: _ms, ...s }) => s);
  return { days, hours };
}

/** Steuer-, Formatierungs- und Richtungszeichen sowie spitze Klammern werden zu Leerzeichen (ohne Escape-Folgen im Quelltext, bewusst als Codepunkt-Prüfung). */
function ohneSteuer(s: string): string {
  let out = '';
  for (const c of s) {
    const n = c.codePointAt(0) ?? 0;
    const schlecht = n < 32 || (n >= 0x7f && n <= 0x9f) || (n >= 0x200b && n <= 0x200f) || (n >= 0x2028 && n <= 0x202e) || (n >= 0x2066 && n <= 0x2069) || n === 0xfeff || c === '<' || c === '>';
    out += schlecht ? ' ' : c;
  }
  return out;
}
/** Text bereinigen: keine Steuer-/Formatierungszeichen, keine spitzen Klammern, Leerraum zusammenfassen, höchstens `max` Zeichen (Wortgrenze, "…"). */
export function bereinige(s: unknown, max: number): string {
  if (typeof s !== 'string') return '';
  const t = ohneSteuer(s).replace(/\s+/g, ' ').trim();
  const zeichen = [...t];
  if (zeichen.length <= max) return t;
  const kurz = zeichen.slice(0, max - 1).join('');
  const w = kurz.lastIndexOf(' ');
  return `${(w > max / 2 ? kurz.slice(0, w) : kurz).trimEnd()}…`;
}

const SEVERITY: Record<string, 1 | 2 | 3 | 4> = { minor: 1, moderate: 2, severe: 3, extreme: 4 };

function warnArt(eventEn: unknown): WarnArt {
  const e = typeof eventEn === 'string' ? eventEn.toLowerCase() : '';
  if (/thunder/.test(e)) return 'gewitter';
  if (/black ice|glaze|slippery|ice/.test(e)) return 'glaette';
  if (/thaw/.test(e)) return 'tauwetter';
  if (/frost|freez|cold/.test(e)) return 'frost';
  if (/heat/.test(e)) return 'hitze';
  if (/wind|gust|storm|hurricane|tornado/.test(e)) return 'wind';
  if (/snow/.test(e)) return 'schnee';
  if (/rain|precipitation|flood/.test(e)) return 'regen';
  if (/fog/.test(e)) return 'nebel';
  if (/uv/.test(e)) return 'uv';
  return 'sonst';
}

/** Bright Sky `GET /alerts` (Warn-Feed des DWD für die Warnzelle des Ortes). Nur echte Warnungen (`status` actual), nie Tests oder Übungen. */
function parseBrightSkyAlerts(json: unknown, nowMs: number): Warnung[] | null {
  const liste = rec(json)?.alerts;
  if (!Array.isArray(liste)) return null;
  const out: Warnung[] = [];
  for (const raw of liste.slice(0, 50)) {
    const a = rec(raw);
    if (!a || a.status !== 'actual') continue;
    const level = typeof a.severity === 'string' && Object.hasOwn(SEVERITY, a.severity) ? SEVERITY[a.severity]! : null;
    if (level === null) continue;
    const von = zeit(a.onset) ?? zeit(a.effective);
    const bis = zeit(a.expires);
    if (von === null || (bis !== null && bis <= nowMs)) continue;
    const event = bereinige(a.event_de, 60).toLocaleLowerCase('de-DE');
    const title = event ? event.charAt(0).toLocaleUpperCase('de-DE') + event.slice(1) : 'Wetterwarnung';
    out.push({ level, kind: warnArt(a.event_en), title, text: bereinige(a.description_de, 280), from: new Date(von).toISOString(), until: bis === null ? null : new Date(bis).toISOString() });
  }
  out.sort((x, y) => y.level - x.level || (x.from < y.from ? -1 : x.from > y.from ? 1 : 0));
  return out.slice(0, MAX_ALERTS);
}

const BRIGHT_SKY = 'https://api.brightsky.dev';

/** Bright Sky (DWD Open Data). Koordinaten nur gerundet; Zeitzone und Einheiten fest. */
export const brightSky: ForecastSource = {
  forecastUrl: (lat, lon, ab, bis) => `${BRIGHT_SKY}/weather?${new URLSearchParams({ lat: lat.toFixed(2), lon: lon.toFixed(2), date: ab, last_date: bis, tz: 'Europe/Berlin', units: 'dwd' }).toString()}`,
  alertsUrl: (lat, lon) => `${BRIGHT_SKY}/alerts?${new URLSearchParams({ lat: lat.toFixed(2), lon: lon.toFixed(2), tz: 'Europe/Berlin' }).toString()}`,
  parseForecast: parseBrightSkyForecast,
  parseAlerts: parseBrightSkyAlerts,
};
