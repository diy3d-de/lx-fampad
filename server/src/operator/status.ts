// GET /api/v1/admin/status: Zustand des Servers für den Betreiber, nur lesend. Nie Geheimnisse, Standorte, Chat-Inhalte oder Schlüssel
// (nur Zahlen, Zeitpunkte, Versionen, Schalterstände), nie Pfade oder Fehlertexte. Was ohne root nicht lesbar ist, heißt "unbekannt".
import { readFileSync } from 'node:fs';
import { and, count, eq, gt, isNull, sql } from 'drizzle-orm';
import type { AuthContext } from '../auth/context.js';
import type { Config } from '../config.js';
import { devices, memberships, pushEndpoints, sessions } from '../db/schema.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../version.js';
import type { WeatherService } from '../weather/service.js';
import { realProbes, type Probes } from './probes.js';

export type Level = 'ok' | 'warn' | 'error' | 'off' | 'unknown';

export interface ServiceStatus {
  id: 'api' | 'database' | 'weather' | 'ntfy' | 'caddy';
  state: Level;
  /** Kurze Kennzahlen für die Anzeige (Zahlen, Zeiten und feste Codes, nie Rohtext aus Quellen). */
  detail: Record<string, string | number | boolean | null>;
}

export interface OperatorStatus {
  generatedAt: string;
  overall: 'ok' | 'warn' | 'error';
  /** Anzahl der Quellen ohne Messwert (nicht lesbar): "in Ordnung" gilt nur für das, was gemessen wurde. */
  unknownCount: number;
  server: { version: string; protocolVersion: number; startedAt: string; uptimeSec: number; memoryRssMb: number };
  database: {
    ok: boolean;
    latencyMs: number | null;
    sizeBytes: number | null;
    migrations: { applied: number | null; expected: number | null; latest: string | null; pending: boolean | null; grantMissing: boolean };
  };
  services: ServiceStatus[];
  backup: { state: Level; lastSuccessAt: string | null; ageHours: number | null; totalBytes: number | null; lastResult: 'ok' | 'fehler' | null };
  disk: { totalBytes: number; freeBytes: number; usedPercent: number } | null;
  certificate: { validTo: string; daysLeft: number } | null;
  counts: { members: number; devices: number; pushDevices: number; activeSessions: number };
  versions: {
    server: string;
    web: string | null;
    app: { version: string; versionCode: number | null; minVersion: string | null } | null;
    minAppVersion: string;
  };
  features: { pwBackup: boolean; legacyPasswordLogin: boolean; weather: boolean; push: boolean; map: { available: boolean; sizeBytes: number | null } };
}

const STARTED_AT = new Date();
const SEMVER = /^\d+\.\d+\.\d+$/;
// Schwellen der Ansicht UND der Warnungen (operator/monitor.ts rechnet mit denselben Werten und demselben exakten Alter)
export const BACKUP_WARN_HOURS = 36;
const BACKUP_ERROR_HOURS = 72;
export const CERT_WARN_DAYS = 14;
export const DISK_WARN_PERCENT = 85;
const DISK_ERROR_PERCENT = 95;

/** PostgreSQL 42501 (insufficient_privilege), auch wenn der Treiber den Fehler als Ursache einpackt. */
function isPermissionDenied(err: unknown): boolean {
  for (let e: unknown = err, i = 0; e && typeof e === 'object' && i < 4; i++) {
    if ((e as { code?: unknown }).code === '42501') return true;
    e = (e as { cause?: unknown }).cause;
  }
  return false;
}

/** Anzahl und letzter Eintrag der mitgelieferten Migrationen (Journal im Ordner drizzle/); null, wenn nicht lesbar. */
function expectedMigrations(): { count: number; latest: string } | null {
  try {
    const raw = readFileSync(new URL('../../drizzle/meta/_journal.json', import.meta.url), 'utf8');
    const entries = (JSON.parse(raw) as { entries: Array<{ tag: string }> }).entries;
    const last = entries[entries.length - 1];
    return last ? { count: entries.length, latest: last.tag } : null;
  } catch {
    return null;
  }
}

/** Liest "Schlüssel=Wert"-Zeilen der Sicherungs-Statusdatei (nur bekannte Schlüssel, Werte als Zahl geprüft). */
export function parseBackupStatus(text: string): { lastResult: 'ok' | 'fehler' | null; lastSuccessEpoch: number | null; totalBytes: number | null } {
  const kv = new Map<string, string>();
  for (const line of text.split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) kv.set(line.slice(0, i).trim(), line.slice(i + 1).trim());
  }
  const num = (k: string): number | null => {
    const v = kv.get(k);
    return v !== undefined && /^\d{1,15}$/.test(v) ? Number(v) : null;
  };
  const result = kv.get('last_result');
  return { lastResult: result === 'ok' || result === 'fehler' ? result : null, lastSuccessEpoch: num('last_success_epoch'), totalBytes: num('total_bytes') };
}

/** Versionsangaben aus dem Payload des signierten Manifests (die Signatur prüft die App, hier nur Anzeige). */
export function parseManifest(text: string): { version: string; versionCode: number | null; minVersion: string | null } | null {
  try {
    const outer = JSON.parse(text) as { payload?: unknown };
    if (typeof outer.payload !== 'string') return null;
    const p = JSON.parse(outer.payload) as { version?: unknown; versionCode?: unknown; minVersion?: unknown };
    if (typeof p.version !== 'string' || !SEMVER.test(p.version)) return null;
    return {
      version: p.version,
      versionCode: typeof p.versionCode === 'number' && Number.isInteger(p.versionCode) ? p.versionCode : null,
      minVersion: typeof p.minVersion === 'string' && SEMVER.test(p.minVersion) ? p.minVersion : null,
    };
  } catch {
    return null;
  }
}

async function readWebVersion(config: Config, probes: Probes): Promise<string | null> {
  if (config.webVersion) return config.webVersion;
  if (!config.webVersionFile) return null;
  const text = (await probes.readText(config.webVersionFile, 256))?.trim();
  return text && /^[A-Za-z0-9._-]{1,64}$/.test(text) ? text : null;
}

export interface StatusDeps {
  ctx: AuthContext;
  weather: WeatherService | undefined;
  probes?: Partial<Probes> | undefined;
}

export async function collectStatus(deps: StatusDeps, familyId: string): Promise<OperatorStatus> {
  const { ctx } = deps;
  const config = ctx.config;
  const probes: Probes = { ...realProbes, ...deps.probes };
  const now = ctx.now();
  const oc = config.operator;

  // ----- Datenbank -----
  let dbOk = true;
  let latencyMs: number | null = null;
  const t0 = performance.now();
  try {
    await ctx.db.execute(sql`select 1`);
    latencyMs = Math.round(performance.now() - t0);
  } catch {
    dbOk = false;
  }
  let sizeBytes: number | null = null;
  let applied: number | null = null;
  let grantMissing = false;
  if (dbOk) {
    try {
      const r = await ctx.db.execute<{ size: string }>(sql`select pg_database_size(current_database())::text as size`);
      const raw = r.rows[0]?.size;
      sizeBytes = raw && /^\d+$/.test(raw) ? Number(raw) : null;
    } catch {
      sizeBytes = null;
    }
    try {
      // Die Laufzeitrolle darf die Migrations-Tabelle evtl. nicht lesen: dann bleibt der Stand "unbekannt".
      const r = await ctx.db.execute<{ n: number }>(sql`select count(*)::int as n from drizzle.__drizzle_migrations`);
      applied = r.rows[0]?.n ?? null;
    } catch (err) {
      applied = null;
      grantMissing = isPermissionDenied(err);
    }
  }
  const exp = expectedMigrations();
  const migrations = {
    applied,
    expected: exp?.count ?? null,
    latest: exp && applied !== null && applied === exp.count ? exp.latest : null,
    pending: exp && applied !== null ? applied < exp.count : null,
    grantMissing,
  };

  // ----- Zähler (nur die Familie der Sitzung) -----
  let counts: OperatorStatus['counts'] = { members: 0, devices: 0, pushDevices: 0, activeSessions: 0 };
  if (dbOk) {
    const [m] = await ctx.db.select({ n: count() }).from(memberships).where(and(eq(memberships.familyId, familyId), eq(memberships.status, 'active')));
    const [d] = await ctx.db.select({ n: count() }).from(devices).where(and(eq(devices.familyId, familyId), isNull(devices.revokedAt)));
    const [p] = await ctx.db.select({ n: count() }).from(pushEndpoints).where(and(eq(pushEndpoints.familyId, familyId), isNull(pushEndpoints.disabledAt)));
    const [s] = await ctx.db
      .select({ n: count() })
      .from(sessions)
      .where(and(eq(sessions.familyId, familyId), isNull(sessions.revokedAt), isNull(sessions.usedAt), gt(sessions.expiresAt, now)));
    counts = { members: m?.n ?? 0, devices: d?.n ?? 0, pushDevices: p?.n ?? 0, activeSessions: s?.n ?? 0 };
  }

  // ----- Wetter (Zustand aus der Datenbank, der Abruf läuft im eigenen Dienst lx-fampad-weather) -----
  let weather: ServiceStatus;
  if (!config.weather.enabled || !deps.weather) {
    weather = { id: 'weather', state: 'off', detail: {} };
  } else {
    const w = dbOk ? await deps.weather.status().catch(() => null) : null;
    if (!w) weather = { id: 'weather', state: 'unknown', detail: {} };
    else if (!w.configured) weather = { id: 'weather', state: 'warn', detail: { configured: false } };
    else if (w.disabled) weather = { id: 'weather', state: 'error', detail: { configured: true, disabled: true } };
    else {
      const ageMin = w.lastOkAt ? Math.max(0, Math.round((now.getTime() - w.lastOkAt.getTime()) / 60_000)) : null;
      const stale = ageMin === null || ageMin > (config.weather.pollMs / 60_000) * 3;
      weather = {
        id: 'weather',
        state: stale ? 'warn' : 'ok',
        detail: {
          configured: true,
          lastOkAt: w.lastOkAt?.toISOString() ?? null,
          lastOkMinutesAgo: ageMin,
          lastErrorCode: w.lastErrorCode && /^[a-z0-9_]{1,40}$/.test(w.lastErrorCode) ? w.lastErrorCode : null,
        },
      };
    }
  }

  // ----- ntfy, Zertifikat, Sicherung, Platte, Karte, Versionen (parallel, jede Quelle für sich fehlertolerant) -----
  const [ntfyUp, validTo, backupText, disk, karte, manifestText, web] = await Promise.all([
    config.ntfyUrl ? probes.ntfyReachable(config.ntfyUrl) : Promise.resolve(null),
    oc.tlsProbe ? probes.tlsValidTo(oc.tlsProbe, new URL(config.publicUrl).hostname) : Promise.resolve(null),
    oc.backupStatusFile ? probes.readText(oc.backupStatusFile, 4096) : Promise.resolve(null),
    oc.diskPath ? probes.disk(oc.diskPath) : Promise.resolve(null),
    oc.karteDir ? probes.karteBytes(oc.karteDir) : Promise.resolve(null),
    oc.releaseManifestFile ? probes.readText(oc.releaseManifestFile, 64 * 1024) : Promise.resolve(null),
    readWebVersion(config, probes),
  ]);

  const ntfy: ServiceStatus = ntfyUp === null ? { id: 'ntfy', state: 'off', detail: {} } : { id: 'ntfy', state: ntfyUp ? 'ok' : 'error', detail: { devices: counts.pushDevices } };

  const certificate = validTo ? { validTo: validTo.toISOString(), daysLeft: Math.floor((validTo.getTime() - now.getTime()) / 86_400_000) } : null;
  const caddy: ServiceStatus = {
    id: 'caddy',
    state: certificate === null ? 'unknown' : certificate.daysLeft < 0 ? 'error' : certificate.daysLeft < CERT_WARN_DAYS ? 'warn' : 'ok',
    detail: certificate ? { daysLeft: certificate.daysLeft } : {},
  };

  const bs = backupText ? parseBackupStatus(backupText) : null;
  let backup: OperatorStatus['backup'] = { state: 'unknown', lastSuccessAt: null, ageHours: null, totalBytes: null, lastResult: null };
  if (bs) {
    const lastMs = bs.lastSuccessEpoch !== null ? bs.lastSuccessEpoch * 1000 : null;
    // Die Zustände rechnen mit dem exakten Alter (nicht mit den gerundeten Stunden der Anzeige): die Warnungen des Betreibers gelten für dieselbe Grenze
    const ageMs = lastMs !== null ? Math.max(0, now.getTime() - lastMs) : null;
    const ageHours = ageMs !== null ? Math.round(ageMs / 3_600_000) : null;
    const state: Level = bs.lastResult === 'fehler' || ageMs === null || ageMs > BACKUP_ERROR_HOURS * 3_600_000 ? 'error' : ageMs > BACKUP_WARN_HOURS * 3_600_000 ? 'warn' : 'ok';
    backup = { state, lastSuccessAt: lastMs !== null ? new Date(lastMs).toISOString() : null, ageHours, totalBytes: bs.totalBytes, lastResult: bs.lastResult };
  }

  const diskView = disk && disk.totalBytes > 0 ? { ...disk, usedPercent: Math.round(((disk.totalBytes - disk.freeBytes) / disk.totalBytes) * 100) } : null;

  const api: ServiceStatus = { id: 'api', state: 'ok', detail: { version: SERVER_VERSION } };
  const database: ServiceStatus = { id: 'database', state: dbOk ? (migrations.pending ? 'warn' : 'ok') : 'error', detail: { latencyMs } };
  const services = [api, database, weather, ntfy, caddy];

  const diskLevel: Level = diskView === null ? 'unknown' : diskView.usedPercent >= DISK_ERROR_PERCENT ? 'error' : diskView.usedPercent > DISK_WARN_PERCENT ? 'warn' : 'ok';
  const levels: Level[] = [...services.map((s) => s.state), backup.state, diskLevel];
  const overall = levels.includes('error') ? 'error' : levels.includes('warn') ? 'warn' : 'ok';
  const unknownCount = levels.filter((l) => l === 'unknown').length + (migrations.applied === null ? 1 : 0);

  return {
    generatedAt: now.toISOString(),
    overall,
    unknownCount,
    server: {
      version: SERVER_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      startedAt: STARTED_AT.toISOString(),
      uptimeSec: Math.round(process.uptime()),
      memoryRssMb: Math.round(process.memoryUsage.rss() / 1_048_576),
    },
    database: { ok: dbOk, latencyMs, sizeBytes, migrations },
    services,
    backup,
    disk: diskView,
    certificate,
    counts,
    versions: { server: SERVER_VERSION, web, app: manifestText ? parseManifest(manifestText) : null, minAppVersion: config.minAppVersion },
    features: {
      pwBackup: config.e2eePwBackup,
      legacyPasswordLogin: config.auth.legacyPasswordLogin,
      weather: config.weather.enabled,
      push: config.ntfyUrl !== undefined && config.ntfyToken !== undefined,
      map: { available: karte !== null, sizeBytes: karte },
    },
  };
}
