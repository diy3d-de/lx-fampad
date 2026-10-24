// Wetter-Station-Paket: Verdichtung der Messwerte (Stundenreihen, Tagesextreme) und Sonnenzeiten (NOAA) als reine Funktionen.
import { describe, expect, it } from 'vitest';
import { berlinIso, berlinTag, sonnenTage, stundenReihen, tagesExtreme, type ProbeZeile } from '../src/weather/summary.js';
import { sonnenZeiten } from '../src/weather/sun.js';

const zeile = (iso: string, v: Partial<ProbeZeile> = {}): ProbeZeile => ({ ts: new Date(iso), temperature: null, humidity: null, pressure: null, rain1h: null, windKmh: null, gustKmh: null, windAngle: null, ...v });

describe('Stundenreihen', () => {
  const jetzt = new Date('2026-10-24T12:30:00Z');
  it('liefert höchstens 7·24 Punkte, ausgerichtet auf volle Stunden, ohne Messung null (nie 0)', () => {
    const r = stundenReihen([], jetzt);
    expect(r.from).toBe('2026-10-17T13:00:00.000Z');
    expect(r.stepSec).toBe(3600);
    for (const k of ['temperature', 'humidity', 'pressure', 'rain', 'windKmh', 'gustKmh', 'windAngle'] as const) {
      expect(r[k]).toHaveLength(168);
      expect(r[k].every((v) => v === null)).toBe(true);
    }
  });
  it('mittelt je Stunde und rundet; Böen = Maximum; Regen = letzter rain1h der Stunde', () => {
    const r = stundenReihen(
      [
        zeile('2026-10-24T11:05:00Z', { temperature: 10.04, humidity: 70, pressure: 1010.04, rain1h: 0, windKmh: 10, gustKmh: 20 }),
        zeile('2026-10-24T11:35:00Z', { temperature: 11.06, humidity: 73, pressure: 1011, rain1h: 0.46, windKmh: 15, gustKmh: 31 }),
        zeile('2026-10-24T12:10:00Z', { temperature: 9 }),
      ],
      jetzt,
    );
    expect(r.temperature[166]).toBe(10.6);
    expect(r.humidity[166]).toBe(72);
    expect(r.pressure[166]).toBe(1010.5);
    expect(r.rain[166]).toBe(0.5);
    expect(r.windKmh[166]).toBe(13);
    expect(r.gustKmh[166]).toBe(31);
    expect(r.temperature[167]).toBe(9);
    expect(r.humidity[167]).toBeNull();
    expect(r.rain[167]).toBeNull();
    expect(r.temperature[165]).toBeNull();
  });
  it('Regen 0 bleibt 0 (trocken gemessen), fehlender Regenmesser bleibt null', () => {
    const r = stundenReihen([zeile('2026-10-24T12:10:00Z', { rain1h: 0, temperature: 5 }), zeile('2026-10-24T10:10:00Z', { temperature: 5 })], jetzt);
    expect(r.rain[167]).toBe(0);
    expect(r.rain[165]).toBeNull();
  });
  it('mittelt die Windrichtung als Kreis (350 und 10 ergeben 0, nicht 180)', () => {
    const r = stundenReihen([zeile('2026-10-24T12:05:00Z', { windAngle: 350 }), zeile('2026-10-24T12:15:00Z', { windAngle: 10 })], jetzt);
    expect(r.windAngle[167]).toBe(0);
    const r2 = stundenReihen([zeile('2026-10-24T12:05:00Z', { windAngle: 90 }), zeile('2026-10-24T12:15:00Z', { windAngle: 270 })], jetzt);
    expect(r2.windAngle[167]).not.toBeNull();
  });
  it('ignoriert Messungen außerhalb des Fensters', () => {
    const r = stundenReihen([zeile('2026-10-10T12:00:00Z', { temperature: 99 }), zeile('2026-10-25T12:00:00Z', { temperature: 98 })], jetzt);
    expect(r.temperature.every((v) => v === null)).toBe(true);
  });
});

describe('Tagesextreme', () => {
  it('je Kalendertag in Europe/Berlin (22:30 UTC im Sommer gehört schon zum Folgetag), nur letzte 7 Tage', () => {
    const jetzt = new Date('2026-07-10T10:00:00Z');
    const t = tagesExtreme(
      [
        zeile('2026-07-09T21:30:00Z', { temperature: 8 }), // 23:30 Berlin, 9.7.
        zeile('2026-07-09T22:30:00Z', { temperature: 7 }), // 00:30 Berlin, 10.7.
        zeile('2026-07-10T09:00:00Z', { temperature: 20.04 }),
        zeile('2026-07-10T09:30:00Z', { temperature: null }),
        zeile('2026-06-20T09:00:00Z', { temperature: 50 }),
      ],
      jetzt,
    );
    expect(t).toEqual([
      { date: '2026-07-09', min: 8, max: 8 },
      { date: '2026-07-10', min: 7, max: 20 },
    ]);
  });
  it('berlinTag und berlinIso nutzen Sommer- und Winterzeit', () => {
    expect(berlinTag(new Date('2026-12-31T23:30:00Z'))).toBe('2027-01-01');
    expect(berlinIso(new Date('2026-07-01T10:00:00Z'))).toBe('2026-07-01T12:00:00+02:00');
    expect(berlinIso(new Date('2026-01-15T10:00:00Z'))).toBe('2026-01-15T11:00:00+01:00');
  });
});

describe('Sonnenzeiten (NOAA)', () => {
  const minuten = (iso: string | null): number => {
    expect(iso).not.toBeNull();
    return +iso!.slice(11, 13) * 60 + +iso!.slice(14, 16);
  };
  const BERLIN = [52.52, 13.405] as const;
  it('Berlin zur Sommersonnenwende: 04:43 bis 21:33 (Sommerzeit), Abweichung höchstens 3 Minuten', () => {
    const [t] = sonnenTage(new Date('2026-06-21T10:00:00Z'), ...BERLIN);
    expect(t!.date).toBe('2026-06-21');
    expect(t!.sunrise).toMatch(/\+02:00$/);
    expect(Math.abs(minuten(t!.sunrise) - (4 * 60 + 43))).toBeLessThanOrEqual(3);
    expect(Math.abs(minuten(t!.sunset) - (21 * 60 + 33))).toBeLessThanOrEqual(3);
  });
  it('Berlin zur Wintersonnenwende: 08:16 bis 15:54 (Winterzeit)', () => {
    const [t] = sonnenTage(new Date('2026-12-21T10:00:00Z'), ...BERLIN);
    expect(t!.sunrise).toMatch(/\+01:00$/);
    expect(Math.abs(minuten(t!.sunrise) - (8 * 60 + 16))).toBeLessThanOrEqual(3);
    expect(Math.abs(minuten(t!.sunset) - (15 * 60 + 54))).toBeLessThanOrEqual(3);
  });
  it('Zeitumstellung: 29.3.2026 (Sommerzeit ab 02:00) und 25.10.2026 (Winterzeit)', () => {
    const t = sonnenTage(new Date('2026-03-28T12:00:00Z'), ...BERLIN);
    expect(t[0]!.sunrise).toMatch(/T0[56]:\d\d:\d\d\+01:00$/);
    expect(t[1]!.date).toBe('2026-03-29');
    expect(t[1]!.sunrise).toMatch(/\+02:00$/);
    const h = sonnenTage(new Date('2026-10-24T12:00:00Z'), ...BERLIN);
    expect(h[0]!.sunrise).toMatch(/\+02:00$/);
    expect(h[1]!.sunrise).toMatch(/\+01:00$/);
  });
  it('Westerburg: Tageslänge im Herbst zwischen 9 und 10 Stunden', () => {
    const [t] = sonnenTage(new Date('2026-10-24T10:00:00Z'), 50.56, 7.97);
    const d = minuten(t!.sunset) - minuten(t!.sunrise);
    expect(d).toBeGreaterThan(9 * 60);
    expect(d).toBeLessThan(10 * 60 + 30);
  });
  it('Polartag und Polarnacht liefern null', () => {
    const s = sonnenZeiten(2026, 6, 21, 80, 10);
    expect(s.sunrise).toBeNull();
    expect(s.sunset).toBeNull();
    expect(sonnenZeiten(2026, 12, 21, 80, 10).sunrise).toBeNull();
  });
});
