// Update-Stand der Geräte (Betrieb Paket 3, Teil D): welche App-Version meldet jedes Gerät, und wie steht sie zur neuesten veröffentlichten Android-Version (Release-Manifest)
// und zur Mindestversion des Servers? Gelesen wird nur, was die Geräte selbst melden (`devices.app_version`, beim Anmelden und beim Start der App über `PUT /me/device-info`):
// ein Versionsstring `x.y.z`, nie mehr. Die Übersicht liefert nur Zähler (ohne Namen); je Person steht der Stand in der Mitgliederseite (mit Step-up).
import { and, eq, isNull } from 'drizzle-orm';
import type { AuthContext } from '../auth/context.js';
import { devices, memberships, users } from '../db/schema.js';

const DAY_MS = 86_400_000;
/** Geräte, die länger nicht gesehen wurden, zählen nicht als "veraltet" (vermutlich aufgegeben), sondern als "inaktiv". */
export const INACTIVE_AFTER_DAYS = 90;

/** Stand der App eines Geräts (feste Codes, die die App-Oberfläche in Wörter übersetzt). */
export type AppState =
  /** auf der neuesten veröffentlichten Version (oder neuer) */
  | 'current'
  /** älter als die neueste veröffentlichte Version, aber noch nicht unter der Mindestversion */
  | 'outdated'
  /** unter der Mindestversion des Servers (die App verlangt dort ein Update) */
  | 'below_min'
  /** seit über 90 Tagen nicht gesehen */
  | 'inactive'
  /** keine (lesbare) Versionsangabe */
  | 'unknown';

export type VersionTuple = [number, number, number];

const VERSION = /^(\d{1,4})\.(\d{1,4})\.(\d{1,4})(?:\+\d{1,9})?$/;

/** `x.y.z` (optional mit `+Build`) als Zahlen; alles andere ist `null` (nie ein Fehler). */
export function parseVersion(v: string | null | undefined): VersionTuple | null {
  if (typeof v !== 'string') return null;
  const m = VERSION.exec(v);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

export function compareVersions(a: VersionTuple, b: VersionTuple): number {
  for (let i = 0; i < 3; i++) {
    const d = (a[i] as number) - (b[i] as number);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

/** Strenge Prüfung der vom Gerät gemeldeten Version (Eingabe von `PUT /me/device-info`). */
export function isReportableVersion(v: string): boolean {
  return /^\d{1,4}\.\d{1,4}\.\d{1,4}$/.test(v);
}

export interface DeviceForState {
  platform: string;
  appVersion: string | null;
  lastSeenAt: Date | null;
}

/**
 * Stand der App eines Geräts; `null`, wenn es kein App-Gerät mit Release-Verfolgung ist (Web, andere Plattformen: die Web-App wird mit dem Server ausgeliefert).
 * `reference` = neueste veröffentlichte Android-Version (Release-Manifest; `null` = nicht lesbar: dann gibt es nie "veraltet", nur "unter Mindestversion").
 */
export function appStateOf(d: DeviceForState, reference: string | null, minVersion: string, now: Date): AppState | null {
  if (d.platform !== 'android') return null;
  if (d.lastSeenAt === null || now.getTime() - d.lastSeenAt.getTime() > INACTIVE_AFTER_DAYS * DAY_MS) return 'inactive';
  const v = parseVersion(d.appVersion);
  if (v === null) return 'unknown';
  const min = parseVersion(minVersion);
  if (min !== null && compareVersions(v, min) < 0) return 'below_min';
  const ref = parseVersion(reference);
  if (ref !== null && compareVersions(v, ref) < 0) return 'outdated';
  return 'current';
}

export interface UpdateStatus {
  /** Neueste veröffentlichte Android-Version laut Release-Manifest (null: nicht lesbar). */
  reference: string | null;
  minAppVersion: string;
  android: { total: number; current: number; outdated: number; belowMin: number; inactive: number; unknown: number };
  /** Geräte ohne Release-Verfolgung (Web und andere). */
  otherDevices: number;
  /** Personen mit mindestens einem veralteten oder zu alten Android-Gerät (nur die Zahl, keine Namen). */
  personsBehind: number;
}

/** Leerer Update-Stand (Datenbank nicht erreichbar oder nicht lesbar). */
export function emptyUpdates(reference: string | null, minAppVersion: string): UpdateStatus {
  return { reference: parseVersion(reference) ? reference : null, minAppVersion, android: { total: 0, current: 0, outdated: 0, belowMin: 0, inactive: 0, unknown: 0 }, otherDevices: 0, personsBehind: 0 };
}

export async function collectUpdateStatus(ctx: AuthContext, familyId: string, reference: string | null): Promise<UpdateStatus> {
  const now = ctx.now();
  const minVersion = ctx.config.minAppVersion;
  const rows = await ctx.db
    .select({ userId: devices.userId, platform: devices.platform, appVersion: devices.appVersion, lastSeenAt: devices.lastSeenAt })
    .from(devices)
    .innerJoin(memberships, and(eq(memberships.familyId, devices.familyId), eq(memberships.userId, devices.userId)))
    .innerJoin(users, eq(users.id, devices.userId))
    .where(and(eq(devices.familyId, familyId), isNull(devices.revokedAt), eq(memberships.status, 'active'), isNull(users.disabledAt)));
  const out: UpdateStatus = {
    reference: parseVersion(reference) ? reference : null,
    minAppVersion: minVersion,
    android: { total: 0, current: 0, outdated: 0, belowMin: 0, inactive: 0, unknown: 0 },
    otherDevices: 0,
    personsBehind: 0,
  };
  const behind = new Set<string>();
  for (const r of rows) {
    const s = appStateOf(r, reference, minVersion, now);
    if (s === null) {
      out.otherDevices++;
      continue;
    }
    out.android.total++;
    if (s === 'current') out.android.current++;
    else if (s === 'outdated') out.android.outdated++;
    else if (s === 'below_min') out.android.belowMin++;
    else if (s === 'inactive') out.android.inactive++;
    else out.android.unknown++;
    if (s === 'outdated' || s === 'below_min') behind.add(r.userId);
  }
  out.personsBehind = behind.size;
  return out;
}
