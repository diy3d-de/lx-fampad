// Betreiber-Warnungen: ein Prüfer im Server-Takt (alle 5 Minuten, gestartet in server.ts) wertet die Messungen der Betreiber-Ansicht aus und weckt bei einem Problem
// die Geräte des Betreibers per Push OHNE Inhalt (derselbe Wecker wie überall; die App holt danach `GET /admin/warnings` und zeigt einen festen Text).
//
// Regeln:
//  - Eine Warnung gilt je "Episode" (das Problem besteht seit `since`): sie wird höchstens einmal je Episode gemeldet, nicht bei jedem Lauf; geht das Problem weg, gibt es keine Meldung.
//    Als "gemeldet" gilt eine Episode nur, wenn wirklich gewarnt wurde (`lastNotifiedAt >= since`): wurde wegen der Entprellung oder der Karenz noch nicht gewarnt, wird es
//    im nächsten Lauf nachgeholt, sobald beides abgelaufen ist (auch eine zweite Person mit roter Ampel und ein wiederkehrendes Problem).
//  - Entprellung je Art 6 Stunden: höchstens ein Wecker je Art in diesem Zeitraum (bei der Schlüssel-Ampel zählen alle Personen als eine Art).
//  - Karenz der Schlüssel-Warnung: eine rote Ampel ohne jedes Gerät, das je einen Schlüsselstand gemeldet hat (alte App), wird erst nach 7 Tagen gemeldet; hat die Person ein
//    Gerät mit gemeldeter Version und ist trotzdem rot, ist es ein echter Mangel und wird gemeldet. Die ANZEIGE bleibt rot.
//  - "unbekannt" (Messung nicht lesbar) ist nie ein Alarm und ändert den gemerkten Zustand nicht.
//  - Der Zustand steht in der Datenbank (`operator_alert_state`), ein Neustart wiederholt also nichts. Ist die Datenbank nicht erreichbar, gilt der Speicher des Prozesses
//    (und die zuletzt bekannten Push-Themen), damit auch "Datenbank nicht erreichbar" gemeldet werden kann.
//  - Pro Betreiber schaltbar (`operators.alerts_enabled`, Standard an); ohne eingeschaltete Betreiber wird der Zustand weitergeführt, aber nie geweckt.
//  - Jede Warnung steht im Protokoll ("Betrieb-Warnung: <Art>"), ohne Inhalt; der Wecker enthält nichts (kein Text, kein Titel, keine Namen).
import { and, asc, eq, isNull, sql } from 'drizzle-orm';
import { writeAudit, type AuditEvent } from '../auth/audit.js';
import type { AuthContext, RequestMeta } from '../auth/context.js';
import { wakeTopicsFor } from '../auth/security-events.js';
import type { SessionPrincipal } from '../auth/types.js';
import { auditLog, memberships, operatorAlertState, operators, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { PushService } from '../push/service.js';
import type { WeatherService } from '../weather/service.js';
import { serializeErr } from '../log.js';
import { collectKeyStatus, type KeyStatus } from './key-status.js';
import { collectActivity, FILES_MAX_ENTRIES, FILES_MEASURE_INTERVAL_MS, FILES_MEASURE_TIMEOUT_MS, recordMetrics, type CounterDelta, type UsageCounters } from './metrics.js';
import { realProbes, type Probes } from './probes.js';
import { BACKUP_WARN_HOURS, CERT_WARN_DAYS, collectStatus, DISK_WARN_PERCENT, type OperatorStatus } from './status.js';

export const ALERT_KINDS = ['cert', 'backup', 'database', 'ntfy', 'disk', 'logins', 'key', 'nas_pull', 'nas_restore', 'nas_channel'] as const;
export type AlertKind = (typeof ALERT_KINDS)[number];

export const CHECK_INTERVAL_MS = 5 * 60_000;
/** Das Schreiben der Zähler beim Beenden darf höchstens so lange dauern. */
const FLUSH_TIMEOUT_MS = 3_000;
/** Je Art höchstens ein Wecker in diesem Zeitraum. */
export const ALERT_DEBOUNCE_MS = 6 * 3_600_000;
// dieselben Schwellen wie die Ansicht (status.ts), damit Seite und Warnung nie auseinanderlaufen
export const CERT_ALERT_DAYS = CERT_WARN_DAYS;
export const BACKUP_ALERT_HOURS = BACKUP_WARN_HOURS;
export const DISK_ALERT_PERCENT = DISK_WARN_PERCENT;
/** Karenz der Schlüssel-Warnung für Personen ohne ein Gerät, das je einen Schlüsselstand gemeldet hat. */
export const KEY_ALERT_GRACE_MS = 7 * 24 * 3_600_000;
/** Mehr als so viele fehlgeschlagene Anmeldungen innerhalb des Fensters. */
export const LOGIN_FAIL_THRESHOLD = 20;
export const LOGIN_FAIL_WINDOW_MS = 15 * 60_000;

export type AlertResult = 'active' | 'ok' | 'unknown';

export interface Condition {
  /** Schlüssel des Zustands: die Art, bei Schlüsselwarnungen `key:<Personen-ID>`. */
  key: string;
  kind: AlertKind;
  result: AlertResult;
  /** Erst melden, wenn das Problem so lange besteht (Karenz); 0 = sofort. */
  graceMs: number;
}

const KEY_PREFIX = 'key:';

/** Wertet die Messungen aus (rein, mit Uhr als Parameter testbar). `loginFailures`/`keys` = null: nicht ermittelbar. */
/** Schlüssel des Zustands, der merkt, dass der Kanal des NAS schon einmal eine gültige Datei geliefert hat (kein Alarm in `view`, keine Meldung). */
const NAS_SEEN_KEY = 'nas_seen';

export function evaluateConditions(status: OperatorStatus, loginFailures: number | null, keys: KeyStatus | null, now: Date, nasSeen = false): Condition[] {
  const out: Condition[] = [];
  const add = (kind: AlertKind, result: AlertResult, key: string = kind, graceMs = 0) => out.push({ key, kind, result, graceMs });

  // Zertifikat: weniger als 14 Tage (auch abgelaufen)
  add('cert', status.certificate === null ? 'unknown' : status.certificate.daysLeft < CERT_ALERT_DAYS ? 'active' : 'ok');

  // Sicherung: letzter Erfolg älter als 36 Stunden, oder nie gelungen laut Statusdatei; nicht lesbar = unbekannt
  const b = status.backup;
  if (b.lastResult === null && b.lastSuccessAt === null) add('backup', 'unknown');
  else if (b.lastSuccessAt === null) add('backup', b.lastResult === 'fehler' ? 'active' : 'unknown');
  else add('backup', now.getTime() - new Date(b.lastSuccessAt).getTime() > BACKUP_ALERT_HOURS * 3_600_000 ? 'active' : 'ok');

  // Rückmeldung des NAS (Paket 3): Abholung älter als 36 Stunden oder fehlgeschlagen, Wiederherstellungstest älter als 10 Tage oder fehlgeschlagen. Solange das NAS nichts
  // gemeldet hat (nicht eingerichtet, ungültige Datei, noch kein Test), ist es "unbekannt" und warnt nie (Karenz bis zur Einrichtung).
  const nasAlert = (state: string): AlertResult => (state === 'warn' || state === 'error' ? 'active' : state === 'ok' ? 'ok' : 'unknown');
  add('nas_pull', nasAlert(status.nas.pull.state));
  add('nas_restore', nasAlert(status.nas.restore.state));
  // Stiller Ausfall des Kanals: war schon einmal eine gültige Datei da und fehlt sie jetzt (oder ist ungültig), ist das eine Warnung; vor der ersten gültigen Datei nie
  add('nas_channel', status.nas.configured ? 'ok' : nasSeen ? 'active' : 'unknown');

  // Datenbank und ntfy nicht erreichbar (ntfy aus = nichts zu melden)
  add('database', status.database.ok ? 'ok' : 'active');
  const ntfy = status.services.find((s) => s.id === 'ntfy');
  add('ntfy', !ntfy || ntfy.state === 'off' || ntfy.state === 'unknown' ? 'unknown' : ntfy.state === 'error' ? 'active' : 'ok');

  // Platte über 85 %
  add('disk', status.disk === null ? 'unknown' : status.disk.usedPercent > DISK_ALERT_PERCENT ? 'active' : 'ok');

  // viele Fehlanmeldungen
  add('logins', loginFailures === null ? 'unknown' : loginFailures > LOGIN_FAIL_THRESHOLD ? 'active' : 'ok');

  // Schlüssel-Ampel einer Person wird rot (nur Personen, die schon einen Schlüssel haben: wer nie angefangen hat, ist kein Verlust)
  // Geräte, die nie gemeldet haben, sind für die Warnung "unbekannt", nicht "fehlt": ohne gemeldetes Gerät gilt eine Karenz von 7 Tagen
  if (keys) {
    for (const p of keys.persons) {
      if (!p.hasKeys) continue;
      const rot = p.ampel === 'red';
      add('key', rot ? 'active' : 'ok', `${KEY_PREFIX}${p.userId}`, rot && p.devicesReported === 0 ? KEY_ALERT_GRACE_MS : 0);
    }
  }
  return out;
}

interface StateRow {
  active: boolean;
  since: Date | null;
  lastNotifiedAt: Date | null;
}

interface FamilyOperators {
  familyId: string;
  /** Betreiber mit eingeschalteten Warnungen. */
  enabledUserIds: string[];
}

export interface RunReport {
  families: number;
  /** Gesendete Wecker (Art, ohne Inhalt). */
  notified: AlertKind[];
}

export interface MonitorDeps {
  ctx: AuthContext;
  push: PushService | undefined;
  weather: WeatherService | undefined;
  probes?: Partial<Probes> | undefined;
  /** Zähler des Prozesses (Abgleiche, Fehler, Rate-Limit-Treffer): der Prüfer übernimmt sie bei jedem Lauf in den Messpunkt des Tages (Paket 3). */
  counters?: UsageCounters | undefined;
}

export interface WarningsView {
  /** Hat DIESER Betreiber seine Warnungen eingeschaltet? */
  enabled: boolean;
  /** Kann der Server überhaupt warnen (Push eingerichtet)? */
  pushAvailable: boolean;
  /** Zeitpunkt der letzten Prüfung dieses Prozesses (null: noch keine). */
  checkedAt: string | null;
  /** Zeitpunkt des letzten Weckers der Familie (die App zeigt daraufhin einmal den festen Hinweis). */
  lastNotifiedAt: string | null;
  /** Aktive Warnungen je Art (Schlüssel-Warnungen mehrerer Personen zusammengefasst: `count` = Anzahl, `since` = die älteste). */
  active: Array<{ kind: AlertKind; since: string | null; count: number }>;
}

export class OperatorMonitor {
  private timer: NodeJS.Timeout | undefined;
  private running = false;
  private lastRunAt: Date | null = null;
  /** Speicher-Spiegel des Zustands (Quelle der Wahrheit ist die Datenbank, solange sie erreichbar ist). */
  private readonly states = new Map<string, StateRow>();
  private readonly cache = new Map<string, FamilyOperators>();
  private readonly topicCache = new Map<string, string[]>();
  /** Zähler, die in diesem Lauf noch nicht in die Datenbank übernommen sind (gehen sonst zurück in den Zähler). */
  private pending: CounterDelta | null = null;
  private filesCache: { at: number; bytes: number | null } | null = null;
  private filesPromise: Promise<void> | null = null;
  /** Beendet eine laufende Messung der Dateiablage sofort (Timer weg, Ergebnis unbekannt); die hängende Probe selbst wird nicht mehr abgewartet. */
  private cancelFiles: (() => void) | null = null;

  constructor(private readonly deps: MonitorDeps) {}

  /** Erster Lauf sofort, danach alle 5 Minuten; der Timer hält den Prozess nicht am Leben. */
  start(): void {
    if (this.timer) return;
    void this.runOnce();
    this.timer = setInterval(() => void this.runOnce(), CHECK_INTERVAL_MS);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    // keine offenen Timer und kein Warten auf die Dateimessung nach dem Beenden
    this.cancelFiles?.();
  }

  private sk(familyId: string, key: string): string {
    return `${familyId}|${key}`;
  }

  /** Ein Prüflauf (auch für Tests). Wirft nie; ein laufender Lauf wird nicht überholt. */
  async runOnce(): Promise<RunReport> {
    const report: RunReport = { families: 0, notified: [] };
    if (this.running) return report;
    this.running = true;
    const { ctx } = this.deps;
    this.pending = this.deps.counters?.take() ?? null;
    try {
      let families: FamilyOperators[];
      try {
        families = await this.loadFamilies();
        this.cache.clear();
        for (const f of families) this.cache.set(f.familyId, f);
      } catch {
        families = [...this.cache.values()];
      }
      for (const fam of families) {
        report.families++;
        try {
          report.notified.push(...(await this.checkFamily(fam)));
        } catch (err: unknown) {
          ctx.log.warn({ err: serializeErr(err) }, 'Betreiber-Prüfung fehlgeschlagen');
        }
      }
      this.lastRunAt = ctx.now();
    } finally {
      // nicht übernommene Zähler (keine Familie, Datenbank nicht erreichbar) gehen zurück in den Zähler: nichts geht verloren
      if (this.pending && this.deps.counters) this.deps.counters.restore(this.pending);
      this.pending = null;
      this.running = false;
    }
    return report;
  }

  /**
   * Familien, die mindestens einen aktiven Betreiber haben (auch mit ausgeschalteten Warnungen: der Zustand wird weitergeführt). Geordnet nach Familien-ID: ein Server
   * bedient genau eine Familie; die Zähler des Prozesses (Nutzung und Verlauf) werden der ersten Familie des Laufs zugerechnet, die Reihenfolge ist deshalb fest.
   */
  private async loadFamilies(): Promise<FamilyOperators[]> {
    const rows = await this.deps.ctx.db
      .select({ familyId: memberships.familyId, userId: operators.userId, enabled: operators.alertsEnabled })
      .from(operators)
      .innerJoin(users, eq(users.id, operators.userId))
      .innerJoin(memberships, eq(memberships.userId, users.id))
      .where(and(eq(memberships.status, 'active'), isNull(users.disabledAt)))
      .orderBy(asc(memberships.familyId));
    const byFamily = new Map<string, FamilyOperators>();
    for (const r of rows) {
      const f = byFamily.get(r.familyId) ?? { familyId: r.familyId, enabledUserIds: [] };
      if (r.enabled) f.enabledUserIds.push(r.userId);
      byFamily.set(r.familyId, f);
    }
    return [...byFamily.values()];
  }

  /**
   * Dateiablage (nur die Summe): der zuletzt gemessene Wert. Die Messung läuft höchstens stündlich im HINTERGRUND mit Zeitlimit und wird nie vor den Warn-Prüfungen
   * abgewartet (ein großer Ordner darf weder den Prüfer noch den Dateisystem-Pool aufhalten); ein neuer Wert kommt mit dem nächsten Lauf in den Messpunkt.
   */
  private filesBytes(): number | null {
    const { ctx } = this.deps;
    const dir = ctx.config.operator.filesDir;
    if (!dir) return null;
    const now = ctx.now().getTime();
    const hit = this.filesCache;
    const frisch = hit !== null && now >= hit.at && now - hit.at < FILES_MEASURE_INTERVAL_MS;
    if (!frisch && this.filesPromise === null) {
      const probes: Probes = { ...realProbes, ...this.deps.probes };
      let timer: NodeJS.Timeout | undefined;
      const frist = new Promise<null>((resolve) => {
        timer = setTimeout(() => resolve(null), FILES_MEASURE_TIMEOUT_MS);
        timer.unref();
        this.cancelFiles = () => {
          clearTimeout(timer);
          resolve(null);
        };
      });
      this.filesPromise = Promise.race([probes.dirBytes(dir, FILES_MAX_ENTRIES).catch(() => null), frist])
        .then((bytes) => {
          this.filesCache = { at: ctx.now().getTime(), bytes };
        })
        .finally(() => {
          if (timer) clearTimeout(timer);
          this.cancelFiles = null;
          this.filesPromise = null;
        });
    }
    return hit?.bytes ?? null;
  }

  /** Wartet auf eine laufende Messung der Dateiablage (für Tests und das Beenden). */
  async whenIdle(): Promise<void> {
    await this.filesPromise;
  }

  /**
   * Schreibt die noch nicht übernommenen Zähler beim Beenden einmal in den Messpunkt (ein Neustart verliert so keine Zähler); wirft nie und wartet höchstens
   * `FLUSH_TIMEOUT_MS` (danach gehen die Zähler zurück in den Zähler und gelten als verloren: das Beenden hängt nie an der Datenbank). Unabhängig von der Dateimessung.
   */
  async flushCounters(): Promise<void> {
    const { ctx, counters } = this.deps;
    const fam = [...this.cache.values()][0];
    if (!counters || !fam || this.running) return;
    const delta = counters.take();
    let timer: NodeJS.Timeout | undefined;
    try {
      const schreiben = (async () => {
        const activity = await collectActivity(ctx, fam.familyId);
        await recordMetrics(ctx, fam.familyId, { activity, dbBytes: null, filesBytes: null }, delta);
        return true;
      })();
      const frist = new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), FLUSH_TIMEOUT_MS);
      });
      schreiben.catch(() => undefined);
      if (!(await Promise.race([schreiben, frist]))) counters.restore(delta);
    } catch {
      counters.restore(delta);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  /** Tägliche Messpunkte (Nutzung und Verlauf): nur Zahlen; ein Fehler hier lässt nie die Prüfung der Warnungen scheitern. */
  private async recordUsage(familyId: string, status: OperatorStatus): Promise<void> {
    const { ctx } = this.deps;
    try {
      const activity = await collectActivity(ctx, familyId);
      const files = this.filesBytes();
      await recordMetrics(ctx, familyId, { activity, dbBytes: status.database.sizeBytes, filesBytes: files }, this.pending ?? { syncRuns: 0, syncErrors: 0, rateLimited: 0 });
      this.pending = null; // übernommen (weitere Familien in diesem Lauf bekommen keine Zähler mehr)
    } catch (err: unknown) {
      ctx.log.warn({ err: serializeErr(err) }, 'Messpunkt der Betreiber-Ansicht nicht geschrieben');
    }
  }

  private async loginFailures(familyId: string): Promise<number | null> {
    const { ctx } = this.deps;
    try {
      const since = new Date(ctx.now().getTime() - LOGIN_FAIL_WINDOW_MS);
      // die Familie der Sitzung und Einträge ohne Familie (fehlgeschlagene Anmeldung mit unbekanntem Konto), wie das Protokoll
      const r = await ctx.db.execute<{ n: number }>(
        sql`select count(*)::int as n from ${auditLog} where ${auditLog.event} = 'login_failed' and ${auditLog.createdAt} >= ${since.toISOString()}::timestamptz and (${auditLog.familyId} = ${familyId}::uuid or ${auditLog.familyId} is null)`,
      );
      return r.rows[0]?.n ?? 0;
    } catch {
      return null;
    }
  }

  private async loadStates(familyId: string): Promise<boolean> {
    try {
      const rows = await this.deps.ctx.db.select().from(operatorAlertState).where(eq(operatorAlertState.familyId, familyId));
      for (const k of [...this.states.keys()]) if (k.startsWith(`${familyId}|`)) this.states.delete(k);
      for (const r of rows) this.states.set(this.sk(familyId, r.kind), { active: r.active, since: r.since, lastNotifiedAt: r.lastNotifiedAt });
      return true;
    } catch {
      return false;
    }
  }

  /** Letzter Wecker dieser Art (bei `key`: über alle Personen). */
  private lastNotified(familyId: string, kind: AlertKind): Date | null {
    let best: Date | null = null;
    for (const [k, row] of this.states) {
      if (!k.startsWith(`${familyId}|`)) continue;
      const key = k.slice(familyId.length + 1);
      if ((key.startsWith(KEY_PREFIX) ? 'key' : key) !== kind) continue;
      if (row.lastNotifiedAt && (!best || row.lastNotifiedAt > best)) best = row.lastNotifiedAt;
    }
    return best;
  }

  private async saveState(familyId: string, key: string, row: StateRow): Promise<void> {
    const { ctx } = this.deps;
    this.states.set(this.sk(familyId, key), row);
    try {
      await ctx.db
        .insert(operatorAlertState)
        .values({ familyId, kind: key, active: row.active, since: row.since, lastNotifiedAt: row.lastNotifiedAt, updatedAt: ctx.now() })
        .onConflictDoUpdate({ target: [operatorAlertState.familyId, operatorAlertState.kind], set: { active: row.active, since: row.since, lastNotifiedAt: row.lastNotifiedAt, updatedAt: ctx.now() } });
    } catch {
      // Datenbank nicht erreichbar: der Speicher-Spiegel genügt bis zum nächsten Lauf
    }
  }

  private async checkFamily(fam: FamilyOperators): Promise<AlertKind[]> {
    const { ctx } = this.deps;
    const now = ctx.now();
    const status = await collectStatus({ ctx, weather: this.deps.weather, probes: this.deps.probes }, fam.familyId);
    const dbUp = status.database.ok;
    const keys = dbUp ? await collectKeyStatus(ctx, fam.familyId).catch(() => null) : null;
    const failures = dbUp ? await this.loginFailures(fam.familyId) : null;
    if (dbUp) {
      await this.loadStates(fam.familyId);
      // die Push-Themen der Betreiber merken: fällt die Datenbank später aus, kann "Datenbank nicht erreichbar" trotzdem geweckt werden
      await wakeTopicsFor(ctx.db, fam.enabledUserIds).then((m) => this.topicCache.set(fam.familyId, [...m.values()].flat()), () => undefined);
    }
    // einmal gültig gesehen: ab jetzt ist ein Verschwinden oder eine ungültige Datei eine Warnung (der Zustand steht in der Datenbank)
    if (status.nas.configured && !this.states.get(this.sk(fam.familyId, NAS_SEEN_KEY))?.active) {
      await this.saveState(fam.familyId, NAS_SEEN_KEY, { active: true, since: now, lastNotifiedAt: null });
    }
    const nasSeen = this.states.get(this.sk(fam.familyId, NAS_SEEN_KEY))?.active === true;
    const conditions = evaluateConditions(status, failures, keys, now, nasSeen);
    const notified: AlertKind[] = [];

    for (const c of conditions) {
      if (c.result === 'unknown') continue;
      const prev = this.states.get(this.sk(fam.familyId, c.key));
      if (c.result === 'ok') {
        if (prev?.active) await this.saveState(fam.familyId, c.key, { active: false, since: null, lastNotifiedAt: prev.lastNotifiedAt });
        continue;
      }
      // eine neue Episode beginnt jetzt; die bisherige Meldung (einer früheren Episode) bleibt für die Entprellung erhalten
      let cur = prev;
      if (!cur?.active) {
        cur = { active: true, since: now, lastNotifiedAt: prev?.lastNotifiedAt ?? null };
        await this.saveState(fam.familyId, c.key, cur);
      }
      const since = cur.since ?? now;
      // in dieser Episode schon gewarnt: keine Wiederholung
      if (cur.lastNotifiedAt !== null && cur.lastNotifiedAt.getTime() >= since.getTime()) continue;
      // Karenz noch nicht abgelaufen: später nachholen
      if (now.getTime() - since.getTime() < c.graceMs) continue;
      // Entprellung je ART (bei Schlüsselwarnungen zählen alle Personen als eine Art); in einem Lauf höchstens ein Wecker je Art
      const last = this.lastNotified(fam.familyId, c.kind);
      const debounced = last !== null && now.getTime() - last.getTime() < ALERT_DEBOUNCE_MS && now.getTime() >= last.getTime();
      if (fam.enabledUserIds.length === 0 || debounced || notified.includes(c.kind)) continue; // wird nachgeholt, sobald es möglich ist
      // erst als gemeldet führen, wenn wirklich gewarnt wurde
      await this.saveState(fam.familyId, c.key, { active: true, since: cur.since, lastNotifiedAt: now });
      notified.push(c.kind);
      await this.notify(fam, c.kind, now);
    }

    // Zustände von Personen, die es nicht mehr gibt (oder die keinen Schlüssel mehr haben), wegräumen
    if (dbUp && keys) {
      const live = new Set(conditions.filter((c) => c.key.startsWith(KEY_PREFIX)).map((c) => c.key));
      const stale = [...this.states.keys()].filter((k) => k.startsWith(`${fam.familyId}|${KEY_PREFIX}`) && !live.has(k.slice(fam.familyId.length + 1)));
      for (const k of stale) {
        this.states.delete(k);
        await ctx.db
          .delete(operatorAlertState)
          .where(and(eq(operatorAlertState.familyId, fam.familyId), eq(operatorAlertState.kind, k.slice(fam.familyId.length + 1))))
          .catch(() => undefined);
      }
    }
    // Messpunkt zuletzt: nach den Warn-Prüfungen, nie davor
    if (dbUp) await this.recordUsage(fam.familyId, status);
    return notified;
  }

  /** Protokolleintrag und Wecker (ohne Inhalt) an die Geräte der Betreiber mit eingeschalteten Warnungen. */
  private async notify(fam: FamilyOperators, kind: AlertKind, now: Date): Promise<void> {
    const { ctx, push } = this.deps;
    ctx.log.info?.({ kind }, 'Betreiber-Warnung');
    try {
      await writeAudit({ now: () => now }, ctx.db, { event: `operator_alert_${kind}` as AuditEvent, familyId: fam.familyId });
    } catch {
      // Datenbank nicht erreichbar: der Wecker ist wichtiger als der Eintrag
    }
    if (!push) return;
    let topics: string[];
    try {
      topics = [...(await wakeTopicsFor(ctx.db, fam.enabledUserIds)).values()].flat();
      this.topicCache.set(fam.familyId, topics);
    } catch {
      topics = this.topicCache.get(fam.familyId) ?? [];
    }
    await push.weckeThemen(topics);
  }

  /** Warn-Stand für `GET /admin/warnings` (nur aktive Warnungen und Zeiten, kein Inhalt). */
  async view(p: SessionPrincipal): Promise<WarningsView> {
    const { ctx, push } = this.deps;
    const [op] = await ctx.db.select({ enabled: operators.alertsEnabled }).from(operators).where(eq(operators.userId, p.userId));
    const rows = await ctx.db.select().from(operatorAlertState).where(eq(operatorAlertState.familyId, p.familyId));
    const grouped = new Map<AlertKind, { since: Date | null; count: number }>();
    for (const r of rows) {
      if (!r.active) continue;
      const kind = (r.kind.startsWith(KEY_PREFIX) ? 'key' : r.kind) as AlertKind;
      if (!(ALERT_KINDS as readonly string[]).includes(kind)) continue;
      const g = grouped.get(kind);
      const alt = g?.since ?? null;
      grouped.set(kind, { count: (g?.count ?? 0) + 1, since: alt && r.since ? (alt < r.since ? alt : r.since) : (alt ?? r.since) });
    }
    const known = [...grouped].map(([kind, g]) => ({ kind, since: g.since?.toISOString() ?? null, count: g.count }));
    const lastNotified = rows.reduce<Date | null>((m, r) => (r.lastNotifiedAt && (!m || r.lastNotifiedAt > m) ? r.lastNotifiedAt : m), null);
    return {
      enabled: op?.enabled ?? true,
      pushAvailable: push?.enabled ?? false,
      checkedAt: this.lastRunAt?.toISOString() ?? null,
      lastNotifiedAt: lastNotified?.toISOString() ?? null,
      active: known,
    };
  }
}

/** Schaltet die Warnungen des Betreibers ein oder aus (Step-up in der Route); protokolliert. */
export async function setWarningsEnabled(ctx: AuthContext, p: SessionPrincipal, enabled: boolean, meta: RequestMeta): Promise<void> {
  await ctx.db.transaction(async (tx) => {
    const rows = await tx.update(operators).set({ alertsEnabled: enabled }).where(eq(operators.userId, p.userId)).returning({ userId: operators.userId });
    if (rows.length === 0) throw new AppError(404, 'not_found', 'Nicht gefunden.');
    await writeAudit(ctx, tx, { event: 'operator_warnings_set', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { enabled } });
  });
}
