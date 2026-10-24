// Sonnenauf- und -untergang nach der NOAA-Näherung (Meeus, "Astronomical Algorithms", Kap. 15/25; Formeln wie im NOAA Solar Calculator).
// Reine Funktion ohne Abhängigkeit; Genauigkeit etwa eine Minute (ohne Höhenkorrektur, Refraktion 0,833 Grad). Rechnet nur aus Breite/Länge
// und Kalendertag; die Koordinaten verlassen den Server nie (nur die fertigen Uhrzeiten werden ausgeliefert).
const RAD = Math.PI / 180;

function julianDay(jahr: number, monat: number, tag: number): number {
  // Julianischer Tag für 0 Uhr UT des (gregorianischen) Datums
  let y = jahr;
  let m = monat;
  if (m <= 2) {
    y -= 1;
    m += 12;
  }
  const a = Math.floor(y / 100);
  const b = 2 - a + Math.floor(a / 4);
  return Math.floor(365.25 * (y + 4716)) + Math.floor(30.6001 * (m + 1)) + tag + b - 1524.5;
}

/** Minuten nach 0 Uhr UT, zu denen die Sonne auf- (rise) bzw. untergeht; null in der Polarnacht/-tag. */
function minutenUtc(rise: boolean, jd: number, lat: number, lon: number): number | null {
  const t = (jd - 2451545) / 36525;
  const l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360;
  const m = 357.52911 + t * (35999.05029 - 0.0001537 * t);
  const e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
  const c = Math.sin(m * RAD) * (1.914602 - t * (0.004817 + 0.000014 * t)) + Math.sin(2 * m * RAD) * (0.019993 - 0.000101 * t) + Math.sin(3 * m * RAD) * 0.000289;
  const wahr = l0 + c;
  const omega = 125.04 - 1934.136 * t;
  const lambda = wahr - 0.00569 - 0.00478 * Math.sin(omega * RAD);
  const eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60;
  const eps = eps0 + 0.00256 * Math.cos(omega * RAD);
  const dec = Math.asin(Math.sin(eps * RAD) * Math.sin(lambda * RAD));
  const y = Math.tan((eps * RAD) / 2) ** 2;
  const zeitgleichung =
    (4 *
      (y * Math.sin(2 * l0 * RAD) - 2 * e * Math.sin(m * RAD) + 4 * e * y * Math.sin(m * RAD) * Math.cos(2 * l0 * RAD) - 0.5 * y * y * Math.sin(4 * l0 * RAD) - 1.25 * e * e * Math.sin(2 * m * RAD))) /
    RAD;
  const arg = Math.cos(90.833 * RAD) / (Math.cos(lat * RAD) * Math.cos(dec)) - Math.tan(lat * RAD) * Math.tan(dec);
  if (arg < -1 || arg > 1) return null;
  let stundenwinkel = Math.acos(arg);
  if (!rise) stundenwinkel = -stundenwinkel;
  const delta = lon + stundenwinkel / RAD;
  return 720 - 4 * delta - zeitgleichung;
}

/** Auf- und Untergang am Kalendertag (UT-Datum) als Zeitpunkte; null, wenn die Sonne an dem Tag nicht auf-/untergeht. */
export function sonnenZeiten(jahr: number, monat: number, tag: number, lat: number, lon: number): { sunrise: Date | null; sunset: Date | null } {
  const jd = julianDay(jahr, monat, tag);
  const mitternacht = Date.UTC(jahr, monat - 1, tag);
  const ereignis = (rise: boolean): Date | null => {
    const erste = minutenUtc(rise, jd, lat, lon);
    if (erste === null) return null;
    // zweiter Durchgang mit der Zeit des Ereignisses (wie der NOAA-Rechner)
    const zweite = minutenUtc(rise, jd + erste / 1440, lat, lon);
    return zweite === null ? null : new Date(mitternacht + Math.round(zweite * 60_000));
  };
  return { sunrise: ereignis(true), sunset: ereignis(false) };
}
