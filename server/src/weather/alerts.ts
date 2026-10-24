// Wetter-Hinweise per Wecker (Frost, Regen, Wind, Hitze, Druckabfall): läuft im Wetter-Dienst (cli/weather-poller.ts) nach jedem erfolgreichen Abruf,
// nie im API-Prozess. Die Schwellen sind dieselben wie in der App (app/lib/data/wetter/wetter_logik.dart); `docs/wetter-hinweis-schwellen.json` hält sie an
// einer Stelle fest, je ein Test auf Server- und App-Seite vergleicht damit.
//
// Ablauf: Messung frisch (höchstens 40 Minuten alt, sonst passiert nichts) -> Zustand je Art (aktiv/inaktiv, mit Hysterese, in `weather_alert_state`) ->
// nur beim Übergang inaktiv -> aktiv: den vorhandenen Wecker OHNE Inhalt (PushService) an die Geräte, die genau diese Art eingeschaltet haben
// (`push_endpoints.weather_kinds`), je Art und Gerät höchstens alle 6 Stunden (`weather_sent`). Der Wecker verrät weder Art noch Wert: das Gerät holt
// den Stand selbst (GET /weather), wertet lokal aus und zeigt die Benachrichtigung. Der Server weiß nur "Gerät will Art X", nie Inhalte oder Standort.
//
// Entscheidungen:
//  - Hysterese verhindert Flattern an der Schwelle: Frost endet erst bei >= 3 °C, Wind bei <= 40 km/h, Hitze bei <= 29 °C, Druckabfall bei weniger als 2 hPa
//    in 3 h, Regen, wenn die Station wieder trocken misst.
//  - Fehlt ein Messwert (null), bleibt der Zustand dieser Art unverändert (nie raten).
//  - Der allererste Lauf (keine Zeile je Art) merkt sich den Zustand, ohne zu wecken: nach dem Einspielen kommt kein Wecker für etwas, das schon lange gilt.
//  - Gemerkt ("zuletzt gesendet") wird beim Planen des Weckers, nicht bei der Zustellung: lieber ein verlorener Wecker als ein doppelter.
import { and, eq, isNull } from 'drizzle-orm';
import type { Db, Logger } from '../auth/context.js';
import { devices, memberships, pushEndpoints, weatherAlertState } from '../db/schema.js';
import type { PushService } from '../push/service.js';
import type { WeatherView } from './service.js';

export const ALERT_KINDS = ['frost', 'regen', 'wind', 'hitze', 'druck'] as const;
export type AlertKind = (typeof ALERT_KINDS)[number];

/** Schwellen (Beginn); identisch zur App, abgesichert durch docs/wetter-hinweis-schwellen.json. */
export const ALERT_THRESHOLDS = {
  frostUnterGradC: 2,
  windBoeenUeberKmh: 50,
  hitzeUeberGradC: 30,
  druckAbfallMehrAlsHpa3h: 4,
  maxAlterMinuten: 40,
  abstandStunden: 6,
} as const;

/** Ende der Bedingung (nur Server): Hysterese gegen Flattern. */
export const ALERT_HYSTERESE = { frostBisGradC: 3, windBisKmh: 40, hitzeBisGradC: 29, druckBisHpa3h: 2 } as const;

const MIN_MS = 60_000;
const HOUR_MS = 3_600_000;

/** Bitmaske (Bit i = Art i); Ganzzahl-Arithmetik ohne Schieben (gilt auch im Web). */
export const kindsToMask = (kinds: readonly AlertKind[]): number => kinds.reduce((m, k) => m + 2 ** ALERT_KINDS.indexOf(k), 0);
export const maskHas = (mask: number, kind: AlertKind): boolean => Math.floor(mask / 2 ** ALERT_KINDS.indexOf(kind)) % 2 === 1;

type Reihe = (number | null)[];

/** Letzter Wert einer Stundenreihe innerhalb der letzten `maxAlt` Stunden (Index, Wert) wie in der App. */
function letzterWert(reihe: Reihe, maxAlt = 2): [number, number] | null {
  for (let i = reihe.length - 1; i >= 0 && i >= reihe.length - maxAlt; i--) {
    const v = reihe[i];
    if (v !== null && v !== undefined) return [i, v];
  }
  return null;
}

/** Veränderung über 3 Stunden wie `trendUeber` der App (Ersatz-Stunden daneben, der nähere zuerst). */
export function aenderung3h(reihe: Reihe): number | null {
  const jetzt = letzterWert(reihe);
  if (!jetzt) return null;
  for (const dv of [0, -1, 1]) {
    const j = jetzt[0] - 3 + dv;
    if (j < 0 || j >= jetzt[0]) continue;
    const alt = reihe[j];
    if (alt === null || alt === undefined) continue;
    return jetzt[1] - alt;
  }
  return null;
}

/** Regen beginnt: die Stunde vor dem letzten Regenwert war trocken gemessen (0). Ohne Vorwert: nein. */
function regenBeginnt(regen: Reihe): boolean {
  const k = letzterWert(regen, 3);
  if (!k || k[0] === 0) return false;
  return regen[k[0] - 1] === 0;
}

/** Neuer Zustand der Art (true/false), null = nicht beurteilbar (Zustand bleibt). `vorher` = bisheriger Zustand (null = unbekannt). */
export function bewerte(art: AlertKind, vorher: boolean | null, cur: NonNullable<WeatherView['current']>, hourly: WeatherView['hourly']): boolean | null {
  const T = ALERT_THRESHOLDS;
  const H = ALERT_HYSTERESE;
  const aktiv = vorher === true;
  switch (art) {
    case 'frost':
      if (cur.temperature === null) return null;
      return aktiv ? cur.temperature < H.frostBisGradC : cur.temperature < T.frostUnterGradC;
    case 'hitze':
      if (cur.temperature === null) return null;
      return aktiv ? cur.temperature > H.hitzeBisGradC : cur.temperature > T.hitzeUeberGradC;
    case 'wind':
      if (cur.gustKmh === null) return null;
      return aktiv ? cur.gustKmh > H.windBisKmh : cur.gustKmh > T.windBoeenUeberKmh;
    case 'regen':
      if (cur.rain1h === null) return null;
      if (aktiv) return cur.rain1h > 0;
      return cur.rain1h > 0 && regenBeginnt(hourly.rain);
    case 'druck': {
      const d = aenderung3h(hourly.pressure);
      if (d === null) return null;
      return aktiv ? d < -H.druckBisHpa3h : d < -T.druckAbfallMehrAlsHpa3h;
    }
  }
}

export interface AlertRunResult {
  /** Arten, die gerade auf aktiv wechselten. */
  uebergaenge: AlertKind[];
  /** Geräte, für die ein Wecker geplant wurde. */
  geweckt: number;
  /** Messung zu alt oder fehlt: nichts geprüft. */
  veraltet: boolean;
}

export class WeatherAlerts {
  private warnedPushOff = false;
  constructor(private readonly o: { db: Db; push: PushService; log: Logger; now: () => Date }) {}

  /** Wertet die frische Messung aus und weckt bei Übergängen. Wirft nie. */
  async run(view: WeatherView): Promise<AlertRunResult> {
    const leer: AlertRunResult = { uebergaenge: [], geweckt: 0, veraltet: false };
    try {
      const now = this.o.now();
      const cur = view.current;
      if (!cur || now.getTime() - Date.parse(cur.measuredAt) > ALERT_THRESHOLDS.maxAlterMinuten * MIN_MS) return { ...leer, veraltet: true };
      const rows = await this.o.db.select().from(weatherAlertState);
      const vorher = new Map(rows.map((r) => [r.kind, r.active]));
      const uebergaenge: AlertKind[] = [];
      for (const art of ALERT_KINDS) {
        const alt = vorher.has(art) ? vorher.get(art)! : null;
        const neu = bewerte(art, alt, cur, view.hourly);
        if (neu === null || neu === alt) continue;
        await this.o.db
          .insert(weatherAlertState)
          .values({ kind: art, active: neu, changedAt: now })
          .onConflictDoUpdate({ target: weatherAlertState.kind, set: { active: neu, changedAt: now } });
        if (neu && alt === false) uebergaenge.push(art);
      }
      if (uebergaenge.length === 0) return leer;
      const geweckt = await this.wecke(uebergaenge, now);
      // inhaltsfrei: nur Zähler und die Art (feste Liste), kein Messwert
      this.o.log.info?.({ arten: uebergaenge, geraete: geweckt }, 'Wetter-Hinweis: Wecker geplant');
      return { uebergaenge, geweckt, veraltet: false };
    } catch (err: unknown) {
      this.o.log.error({ err }, 'Wetter-Hinweise konnten nicht geprüft werden');
      return leer;
    }
  }

  private async wecke(arten: readonly AlertKind[], now: Date): Promise<number> {
    if (!this.o.push.enabled) {
      if (!this.warnedPushOff) {
        this.warnedPushOff = true;
        this.o.log.warn({}, 'Wetter-Hinweise: Push ist aus (NTFY_URL/NTFY_TOKEN fehlen), kein Wecker');
      }
      return 0;
    }
    const eps = await this.o.db
      .select({ deviceId: pushEndpoints.deviceId, kinds: pushEndpoints.weatherKinds, sent: pushEndpoints.weatherSent })
      .from(pushEndpoints)
      .innerJoin(devices, and(eq(devices.familyId, pushEndpoints.familyId), eq(devices.id, pushEndpoints.deviceId)))
      .innerJoin(memberships, and(eq(memberships.familyId, devices.familyId), eq(memberships.userId, devices.userId)))
      .where(and(isNull(pushEndpoints.disabledAt), isNull(devices.revokedAt), eq(memberships.status, 'active')));
    const abstand = ALERT_THRESHOLDS.abstandStunden * HOUR_MS;
    const ids: string[] = [];
    for (const ep of eps) {
      const faellig = arten.filter((a) => {
        const zuletzt = ep.sent[a];
        return maskHas(ep.kinds, a) && !(typeof zuletzt === 'number' && now.getTime() - zuletzt < abstand);
      });
      if (faellig.length === 0) continue;
      const sent = { ...ep.sent };
      for (const a of faellig) sent[a] = now.getTime();
      await this.o.db.update(pushEndpoints).set({ weatherSent: sent }).where(eq(pushEndpoints.deviceId, ep.deviceId));
      ids.push(ep.deviceId);
    }
    this.o.push.weckeEndpunkte(ids);
    return ids.length;
  }
}
