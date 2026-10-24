// Verdichtung der Messwerte (weather_samples) für GET /weather: Stundenreihen über bis zu 7 Tage, Tagesextreme, Sonnenzeiten.
// Reine Funktionen (testbar). Fehlende Werte sind null, nie 0. Nie Koordinaten oder Stationsdaten in der Ausgabe.
import { sonnenZeiten } from './sun.js';

const HOUR_MS = 3_600_000;
export const HOURLY_POINTS = 7 * 24;
export const ZONE = 'Europe/Berlin';

export interface ProbeZeile {
  ts: Date;
  temperature: number | null;
  humidity: number | null;
  pressure: number | null;
  rain1h: number | null;
  windKmh: number | null;
  gustKmh: number | null;
  windAngle: number | null;
}

export interface Stundenreihen {
  /** Beginn der ersten Stunde (UTC, volle Stunde); Wert i gehört zur Stunde `from + i h`. */
  from: string;
  stepSec: number;
  temperature: (number | null)[];
  humidity: (number | null)[];
  pressure: (number | null)[];
  /** Niederschlag in mm je Stunde: `rain1h` (gleitende Stunde der Station) der letzten Messung der Stunde. */
  rain: (number | null)[];
  windKmh: (number | null)[];
  gustKmh: (number | null)[];
  windAngle: (number | null)[];
}

const runde = (v: number, stellen: number): number => {
  const f = 10 ** stellen;
  return Math.round(v * f) / f;
};
const nichtNull = (a: (number | null)[]): number[] => a.filter((v): v is number => v !== null);
const mittel = (a: (number | null)[], stellen: number): number | null => {
  const w = nichtNull(a);
  return w.length ? runde(w.reduce((s, v) => s + v, 0) / w.length, stellen) : null;
};

/** Stundenreihen der letzten `HOURLY_POINTS` Stunden bis einschließlich der Stunde von `jetzt`. `rows` aufsteigend nach Zeit. */
export function stundenReihen(rows: ProbeZeile[], jetzt: Date): Stundenreihen {
  const letzte = Math.floor(jetzt.getTime() / HOUR_MS);
  const erste = letzte - (HOURLY_POINTS - 1);
  const faecher: ProbeZeile[][] = Array.from({ length: HOURLY_POINTS }, () => []);
  for (const r of rows) {
    const i = Math.floor(r.ts.getTime() / HOUR_MS) - erste;
    if (i >= 0 && i < HOURLY_POINTS) faecher[i]!.push(r);
  }
  const je = (f: (z: ProbeZeile[]) => number | null): (number | null)[] => faecher.map(f);
  return {
    from: new Date(erste * HOUR_MS).toISOString(),
    stepSec: 3600,
    temperature: je((z) => mittel(z.map((r) => r.temperature), 1)),
    humidity: je((z) => mittel(z.map((r) => r.humidity), 0)),
    pressure: je((z) => mittel(z.map((r) => r.pressure), 1)),
    rain: je((z) => {
      const w = nichtNull(z.map((r) => r.rain1h));
      return w.length ? runde(w[w.length - 1]!, 1) : null;
    }),
    windKmh: je((z) => mittel(z.map((r) => r.windKmh), 0)),
    gustKmh: je((z) => {
      const w = nichtNull(z.map((r) => r.gustKmh));
      return w.length ? Math.round(Math.max(...w)) : null;
    }),
    // Windrichtung: Kreismittel (Vektorsumme), nicht der Zahlenmittelwert (350 Grad und 10 Grad ergeben 0, nicht 180)
    windAngle: je((z) => {
      const w = nichtNull(z.map((r) => r.windAngle));
      if (!w.length) return null;
      const x = w.reduce((s, a) => s + Math.cos((a * Math.PI) / 180), 0);
      const y = w.reduce((s, a) => s + Math.sin((a * Math.PI) / 180), 0);
      if (Math.abs(x) < 1e-9 && Math.abs(y) < 1e-9) return Math.round(w[w.length - 1]!) % 360;
      return Math.round(((Math.atan2(y, x) * 180) / Math.PI + 360) % 360) % 360;
    }),
  };
}

const TAG = new Intl.DateTimeFormat('sv-SE', { timeZone: ZONE, year: 'numeric', month: '2-digit', day: '2-digit' });
/** Kalendertag (YYYY-MM-DD) in der Familienzeitzone. */
export function berlinTag(t: Date): string {
  return TAG.format(t);
}

/** Tagesextreme der Temperatur je Kalendertag (Europe/Berlin), die letzten 7 Tage einschließlich heute, aufsteigend; Tage ohne Werte fehlen. */
export function tagesExtreme(rows: ProbeZeile[], jetzt: Date): { date: string; min: number; max: number }[] {
  const tage = new Map<string, { min: number; max: number }>();
  const erlaubt = new Set<string>();
  for (let i = 0; i < 7; i++) erlaubt.add(berlinTag(new Date(jetzt.getTime() - i * 24 * HOUR_MS)));
  for (const r of rows) {
    if (r.temperature === null) continue;
    const d = berlinTag(r.ts);
    if (!erlaubt.has(d)) continue;
    const e = tage.get(d);
    if (!e) tage.set(d, { min: r.temperature, max: r.temperature });
    else {
      e.min = Math.min(e.min, r.temperature);
      e.max = Math.max(e.max, r.temperature);
    }
  }
  return [...tage.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([date, v]) => ({ date, min: runde(v.min, 1), max: runde(v.max, 1) }));
}

/** ISO-Zeit mit Offset der Familienzeitzone (z. B. 2026-10-24T07:52:00+02:00). */
export function berlinIso(t: Date): string {
  const teile: Record<string, string> = {};
  for (const p of new Intl.DateTimeFormat('en-GB', { timeZone: ZONE, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).formatToParts(t)) {
    teile[p.type] = p.value;
  }
  const lokalAlsUtc = Date.UTC(+teile.year!, +teile.month! - 1, +teile.day!, +teile.hour!, +teile.minute!, +teile.second!);
  const offMin = Math.round((lokalAlsUtc - Math.floor(t.getTime() / 1000) * 1000) / 60_000);
  const v = offMin < 0 ? '-' : '+';
  const o = Math.abs(offMin);
  const z = (n: number): string => String(n).padStart(2, '0');
  return `${teile.year}-${teile.month}-${teile.day}T${teile.hour}:${teile.minute}:${teile.second}${v}${z(Math.floor(o / 60))}:${z(o % 60)}`;
}

export interface SonnenTag {
  date: string;
  sunrise: string | null;
  sunset: string | null;
}

/** Sonnenzeiten für heute und morgen (Kalendertage in Europe/Berlin) aus den Koordinaten; die Koordinaten selbst bleiben im Server. */
export function sonnenTage(jetzt: Date, lat: number, lon: number): SonnenTag[] {
  const heute = berlinTag(jetzt);
  const morgen = berlinTag(new Date(Date.UTC(+heute.slice(0, 4), +heute.slice(5, 7) - 1, +heute.slice(8, 10)) + 36 * HOUR_MS));
  return [heute, morgen].map((date) => {
    // das UT-Datum mit gleichem Kalendertag genügt (Auf-/Untergang liegen in Mitteleuropa am selben UT-Tag)
    const { sunrise, sunset } = sonnenZeiten(+date.slice(0, 4), +date.slice(5, 7), +date.slice(8, 10), lat, lon);
    return { date, sunrise: sunrise ? berlinIso(sunrise) : null, sunset: sunset ? berlinIso(sunset) : null };
  });
}
