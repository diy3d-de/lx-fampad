// Antwort von Netatmo getpublicdata -> eine Messung unserer Station. Alles wird als undurchsichtige Eingabe behandelt:
// nur bekannte Felder, nur endliche Zahlen in plausiblen Bereichen, nie ein Wert aus der Antwort ins Log.
export interface Messung {
  /** Zeitpunkt der Messung (Sekunden seit 1970, aus der Antwort der Station). */
  ts: number;
  temperature: number | null;
  humidity: number | null;
  pressure: number | null;
  rain1h: number | null;
  rain24h: number | null;
  windKmh: number | null;
  gustKmh: number | null;
  windAngle: number | null;
}

const num = (v: unknown, min: number, max: number): number | null => (typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : null);
const rec = (v: unknown): Record<string, unknown> | null => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null);

type Grundwert = 'temperature' | 'humidity' | 'pressure';
const GRENZEN: Record<Grundwert, [number, number]> = { temperature: [-60, 60], humidity: [0, 100], pressure: [800, 1200] };
const istGrundwert = (t: unknown): t is Grundwert => t === 'temperature' || t === 'humidity' || t === 'pressure';

/** Findet die Station mit der MAC in `body` und liest ihre jüngsten Werte; null, wenn sie fehlt oder nichts Brauchbares liefert. */
export function stationMessung(body: unknown, mac: string, nowSec: number): Messung | null {
  // Zeitstempel nur von 1 bis jetzt + 5 Minuten (Uhrenabweichung); alles andere ist ungültig
  const zeit = (v: unknown): number | null => num(v, 1, nowSec + 300);
  if (!Array.isArray(body)) return null;
  const station = body.map(rec).find((s) => typeof s?._id === 'string' && s._id.toLowerCase() === mac.toLowerCase());
  const measures = rec(station?.measures);
  if (!measures) return null;
  const m: Messung = { ts: 0, temperature: null, humidity: null, pressure: null, rain1h: null, rain24h: null, windKmh: null, gustKmh: null, windAngle: null };
  let tsTemp = 0;
  let tsAny = 0;
  for (const modul of Object.values(measures)) {
    const mod = rec(modul);
    if (!mod) continue;
    // Temperatur, Feuchte, Druck: res = { "<Zeit>": [Werte …] }, type = ["temperature", …]
    const res = rec(mod.res);
    const typen = mod.type;
    if (res && Array.isArray(typen)) {
      let neuester = 0;
      let werte: unknown[] | undefined;
      for (const [k, v] of Object.entries(res)) {
        const t = zeit(Number(k));
        if (t !== null && t > neuester && Array.isArray(v)) {
          neuester = t;
          werte = v as unknown[];
        }
      }
      if (neuester > 0 && werte) {
        for (const [i, typ] of typen.entries()) {
          if (!istGrundwert(typ)) continue;
          const g = GRENZEN[typ];
          const wert = num(werte[i], g[0], g[1]);
          if (wert === null) continue;
          m[typ] = wert;
          if (typ === 'temperature') tsTemp = Math.max(tsTemp, neuester);
          tsAny = Math.max(tsAny, neuester);
        }
      }
    }
    // Regenmesser
    const regenZeit = zeit(mod.rain_timeutc);
    if (regenZeit !== null) {
      m.rain1h = num(mod.rain_60min, 0, 1000);
      m.rain24h = num(mod.rain_24h, 0, 2000);
      tsAny = Math.max(tsAny, regenZeit);
    }
    // Windmesser (Netatmo liefert km/h)
    const windZeit = zeit(mod.wind_timeutc);
    if (windZeit !== null) {
      m.windKmh = num(mod.wind_strength, 0, 400);
      m.gustKmh = num(mod.gust_strength, 0, 500);
      m.windAngle = num(mod.wind_angle, 0, 360);
      tsAny = Math.max(tsAny, windZeit);
    }
  }
  m.ts = tsTemp || tsAny;
  if (m.ts <= 0) return null;
  return m;
}
