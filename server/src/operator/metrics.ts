// Nutzung und Verlauf (Betrieb Paket 3, Teil C): tägliche Messpunkte NUR aus Zahlen. Der Prüfer (operator/monitor.ts, alle 5 Minuten) schreibt in die Zeile des Tages (UTC) die aktuellen
// Größen und addiert die Zähler seit dem letzten Lauf; die Betreiber-Ansicht liest den Verlauf (`GET /admin/metrics`). Nie Inhalte, Titel, Namen oder Kennungen in den Messwerten.
//
//  - aktive Personen/Geräte: Mitglieder bzw. Geräte, die in den letzten 7 bzw. 30 Tagen gesehen wurden (`devices.last_seen_at`: Anmeldung, Erneuerung, Abgleich)
//  - Zähler des Tages: Abgleich-Anfragen, Serverfehler im Abgleich (5xx außer der Wartung 503), Antworten mit 429 (Rate-Limit und Mengengrenzen)
//  - Größen: Datenbank (pg_database_size) und Dateiablage (nur die Summe, höchstens stündlich gemessen)
// Die Zähler leben im Prozess und werden bei jedem Lauf in die Tabelle übernommen (höchstens 5 Minuten gehen bei einem Absturz verloren); scheitert das Schreiben, kommen sie zurück.
import { and, asc, eq, gte, isNull, lt, sql } from 'drizzle-orm';
import type { AuthContext } from '../auth/context.js';
import { devices, memberships, operatorMetrics, users } from '../db/schema.js';

const DAY_MS = 86_400_000;
/** Aufbewahrung der Messpunkte (der Aufräum-Job löscht ältere). */
export const METRICS_RETENTION_DAYS = 400;
/** Größte Zahl Tage, die `GET /admin/metrics` liefert. */
export const METRICS_MAX_DAYS = METRICS_RETENTION_DAYS;
/** Die Größe der Dateiablage wird höchstens so oft gemessen (der Ordner kann groß sein). */
export const FILES_MEASURE_INTERVAL_MS = 3_600_000;
/** Obergrenze der Einträge, die die Messung der Dateiablage durchläuft (darüber: "unbekannt"). */
export const FILES_MAX_ENTRIES = 20_000;
/** Zeitlimit der Messung der Dateiablage (sie läuft im Hintergrund und hält nie die Prüfung der Warnungen auf). */
export const FILES_MEASURE_TIMEOUT_MS = 15_000;

export interface CounterDelta {
  syncRuns: number;
  syncErrors: number;
  rateLimited: number;
}

/** Zähler im Prozess (Fastify-Haken in app.ts zählen, der Prüfer nimmt sie heraus). */
export class UsageCounters {
  private runs = 0;
  private errors = 0;
  private limited = 0;

  syncRun(): void {
    this.runs++;
  }
  syncError(): void {
    this.errors++;
  }
  rateLimit(): void {
    this.limited++;
  }

  /** Nimmt die gezählten Werte heraus und setzt auf 0. */
  take(): CounterDelta {
    const d = { syncRuns: this.runs, syncErrors: this.errors, rateLimited: this.limited };
    this.runs = this.errors = this.limited = 0;
    return d;
  }

  /** Gibt herausgenommene Werte zurück (das Schreiben ist gescheitert). */
  restore(d: CounterDelta): void {
    this.runs += d.syncRuns;
    this.errors += d.syncErrors;
    this.limited += d.rateLimited;
  }
}

export interface Activity {
  persons7: number;
  persons30: number;
  devices7: number;
  devices30: number;
}

/** Aktive Personen und Geräte der Familie (nur Zahlen); nur nicht abgemeldete Geräte aktiver Mitglieder. */
export async function collectActivity(ctx: AuthContext, familyId: string): Promise<Activity> {
  const now = ctx.now();
  const since30 = new Date(now.getTime() - 30 * DAY_MS);
  const since7 = now.getTime() - 7 * DAY_MS;
  const rows = await ctx.db
    .select({ userId: devices.userId, lastSeenAt: devices.lastSeenAt })
    .from(devices)
    .innerJoin(memberships, and(eq(memberships.familyId, devices.familyId), eq(memberships.userId, devices.userId)))
    .innerJoin(users, eq(users.id, devices.userId))
    .where(and(eq(devices.familyId, familyId), isNull(devices.revokedAt), eq(memberships.status, 'active'), isNull(users.disabledAt), gte(devices.lastSeenAt, since30)));
  const p7 = new Set<string>();
  const p30 = new Set<string>();
  let d7 = 0;
  for (const r of rows) {
    p30.add(r.userId);
    if (r.lastSeenAt && r.lastSeenAt.getTime() >= since7) {
      p7.add(r.userId);
      d7++;
    }
  }
  return { persons7: p7.size, persons30: p30.size, devices7: d7, devices30: rows.length };
}

/** Der Tag (UTC) als `YYYY-MM-DD`. */
export const dayOf = (d: Date): string => d.toISOString().slice(0, 10);

export interface MetricSnapshot {
  activity: Activity;
  dbBytes: number | null;
  filesBytes: number | null;
}

/** Schreibt die Zeile des heutigen Tages: Größen überschreiben, Zähler werden addiert; eine nicht messbare Größe (null) lässt den bisherigen Wert stehen. */
export async function recordMetrics(ctx: AuthContext, familyId: string, snap: MetricSnapshot, delta: CounterDelta): Promise<void> {
  const now = ctx.now();
  const day = dayOf(now);
  const a = snap.activity;
  await ctx.db
    .insert(operatorMetrics)
    .values({
      familyId,
      day,
      activePersons7: a.persons7,
      activePersons30: a.persons30,
      activeDevices7: a.devices7,
      activeDevices30: a.devices30,
      syncRuns: delta.syncRuns,
      syncErrors: delta.syncErrors,
      rateLimited: delta.rateLimited,
      dbBytes: snap.dbBytes,
      filesBytes: snap.filesBytes,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: [operatorMetrics.familyId, operatorMetrics.day],
      set: {
        activePersons7: a.persons7,
        activePersons30: a.persons30,
        activeDevices7: a.devices7,
        activeDevices30: a.devices30,
        syncRuns: sql`${operatorMetrics.syncRuns} + ${delta.syncRuns}`,
        syncErrors: sql`${operatorMetrics.syncErrors} + ${delta.syncErrors}`,
        rateLimited: sql`${operatorMetrics.rateLimited} + ${delta.rateLimited}`,
        dbBytes: sql`coalesce(${snap.dbBytes}::bigint, ${operatorMetrics.dbBytes})`,
        filesBytes: sql`coalesce(${snap.filesBytes}::bigint, ${operatorMetrics.filesBytes})`,
        updatedAt: now,
      },
    });
}

export interface MetricDay {
  day: string;
  activePersons7: number;
  activePersons30: number;
  activeDevices7: number;
  activeDevices30: number;
  syncRuns: number;
  syncErrors: number;
  rateLimited: number;
  dbBytes: number | null;
  filesBytes: number | null;
}

export interface MetricsView {
  generatedAt: string;
  retentionDays: number;
  /** Aufsteigend nach Tag; nur Tage mit Messpunkt (Lücken bleiben Lücken). */
  days: MetricDay[];
}

export async function listMetrics(ctx: AuthContext, familyId: string, days: number): Promise<MetricsView> {
  const now = ctx.now();
  const from = dayOf(new Date(now.getTime() - (days - 1) * DAY_MS));
  const rows = await ctx.db
    .select()
    .from(operatorMetrics)
    .where(and(eq(operatorMetrics.familyId, familyId), gte(operatorMetrics.day, from)))
    .orderBy(asc(operatorMetrics.day));
  return {
    generatedAt: now.toISOString(),
    retentionDays: METRICS_RETENTION_DAYS,
    days: rows.map((r) => ({
      day: r.day,
      activePersons7: r.activePersons7,
      activePersons30: r.activePersons30,
      activeDevices7: r.activeDevices7,
      activeDevices30: r.activeDevices30,
      syncRuns: r.syncRuns,
      syncErrors: r.syncErrors,
      rateLimited: r.rateLimited,
      dbBytes: r.dbBytes,
      filesBytes: r.filesBytes,
    })),
  };
}

/** Löscht Messpunkte, die älter als die Aufbewahrung sind (Aufräum-Job); gibt die Anzahl zurück. */
export async function purgeMetrics(ctx: AuthContext): Promise<number> {
  const before = dayOf(new Date(ctx.now().getTime() - METRICS_RETENTION_DAYS * DAY_MS));
  const gone = await ctx.db.delete(operatorMetrics).where(lt(operatorMetrics.day, before)).returning({ d: operatorMetrics.day });
  return gone.length;
}
