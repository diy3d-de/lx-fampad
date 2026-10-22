// GET /api/v1/admin/config: sichere Ausschnitte der Server-Konfiguration für den Betreiber, nur lesend. Die Liste ist eine ausdrückliche Positivliste (nie eine
// Schleife über die ganze Konfiguration): jede Zeile ist von Hand ausgesucht und trägt nur Schalter, Zahlen und feste Kurzwerte. Nie Geheimnisse
// (AUTH_SECRET_KEY, NTFY_TOKEN, Datenbank-URLs, Weather-Zugangsdaten), nie Pfade, Adressen mit Zugangsdaten, Koordinaten oder Stations-Kennungen.
// Geändert wird hier nichts: die Konfiguration liegt in der Datei /etc/lx-fampad/env und ändert sich nur per SSH (mit Neustart).
import type { Config } from '../config.js';

export type ConfigValue = boolean | number | string | null;

/** Einheit eines Zahlenwerts (feste Kennung; die App ordnet die Anzeige zu). */
export type ConfigUnit = 'ms' | 's' | 'd' | 'count' | 'perMinute' | 'perDay';

export interface ConfigItem {
  /** Name der Umgebungsvariablen (bzw. eine feste Kennung für abgeleitete Angaben). */
  key: string;
  value: ConfigValue;
  unit?: ConfigUnit;
}

export interface ConfigGroup {
  id: 'switches' | 'server' | 'auth' | 'sync' | 'websocket' | 'location' | 'weather';
  items: ConfigItem[];
}

export interface ConfigView {
  groups: ConfigGroup[];
}

/** Nur kurze, unkritische Zeichenfolgen (Umgebung, Protokollstufe, Versionen) werden als Text ausgegeben; alles andere heißt "null" (nicht anzeigbar). */
const SAFE_TEXT = /^[A-Za-z0-9._:/-]{1,80}$/;
const safe = (v: string | undefined): string | null => (v !== undefined && SAFE_TEXT.test(v) ? v : null);

/** Herkunft (Schema, Host, Port) einer URL ohne Zugangsdaten, Pfad und Query; bei Fehler null. */
function origin(url: string): string | null {
  try {
    return safe(new URL(url).origin);
  } catch {
    return null;
  }
}

export function collectConfig(config: Config): ConfigView {
  const w = config.weather;
  return {
    groups: [
      {
        id: 'switches',
        items: [
          { key: 'E2EE_PW_BACKUP', value: config.e2eePwBackup },
          { key: 'E2EE_PRF_BACKUP', value: config.e2eePrfBackup },
          { key: 'E2EE_PARENT_RECOVERY', value: config.e2eeParentRecovery },
          { key: 'AUTH_LEGACY_PASSWORD_LOGIN', value: config.auth.legacyPasswordLogin },
          { key: 'WEATHER_ENABLED', value: w.enabled },
          // nur "ist Push eingerichtet" (beide Angaben gesetzt), nie die Adresse oder das Token
          { key: 'NTFY', value: config.ntfyUrl !== undefined && config.ntfyToken !== undefined },
          { key: 'OPERATOR_TLS_PROBE', value: config.operator.tlsProbe !== undefined },
        ],
      },
      {
        id: 'server',
        items: [
          { key: 'NODE_ENV', value: safe(config.env) },
          { key: 'PUBLIC_URL', value: origin(config.publicUrl) },
          { key: 'LOG_LEVEL', value: safe(config.logLevel) },
          { key: 'MIN_APP_VERSION', value: safe(config.minAppVersion) },
          { key: 'MIN_PROTOCOL_VERSION', value: config.minProtocolVersion },
          { key: 'RATE_LIMIT_MAX', value: config.rateLimitMax, unit: 'perMinute' },
          { key: 'AUTH_RATE_LIMIT_MAX', value: config.authRateLimitMax, unit: 'perMinute' },
          { key: 'DB_STATEMENT_TIMEOUT_MS', value: config.dbStatementTimeoutMs, unit: 'ms' },
          { key: 'HEALTH_TIMEOUT_MS', value: config.healthTimeoutMs, unit: 'ms' },
          { key: 'AUDIT_RETENTION_DAYS', value: config.auth.auditRetentionDays, unit: 'd' },
        ],
      },
      {
        id: 'auth',
        items: [
          { key: 'MIN_PASSWORD_LENGTH', value: config.auth.minPasswordLength },
          { key: 'accessTokenTtl', value: config.auth.accessTokenTtlSec, unit: 's' },
          { key: 'stepUpMaxAge', value: config.auth.stepUpMaxAgeSec, unit: 's' },
          { key: 'lockoutAccountThreshold', value: config.auth.lockoutAccountThreshold, unit: 'count' },
          { key: 'lockoutMaxDelay', value: config.auth.lockoutMaxDelaySec, unit: 's' },
          { key: 'CHALLENGE_MAX_PER_IP', value: config.auth.challengeMaxPerIp, unit: 'count' },
        ],
      },
      {
        id: 'sync',
        items: [
          { key: 'SYNC_RATE_LIMIT_MAX', value: config.syncRateLimitMax, unit: 'perMinute' },
          { key: 'SYNC_OPS_BURST', value: config.syncOpsBurst, unit: 'count' },
          { key: 'SYNC_OPS_PER_MINUTE', value: config.syncOpsPerMinute, unit: 'perMinute' },
          { key: 'SYNC_REQ_BURST', value: config.syncReqBurst, unit: 'count' },
          { key: 'SYNC_REQ_PER_MINUTE', value: config.syncReqPerMinute, unit: 'perMinute' },
          { key: 'SYNC_OPS_PER_DAY', value: config.syncOpsPerDay, unit: 'perDay' },
          { key: 'SYNC_LOCK_TIMEOUT_MS', value: config.syncLockTimeoutMs, unit: 'ms' },
          { key: 'SYNC_STATEMENT_TIMEOUT_MS', value: config.syncStatementTimeoutMs, unit: 'ms' },
        ],
      },
      {
        id: 'websocket',
        items: [
          { key: 'WS_MAX_PER_USER', value: config.wsMaxPerUser, unit: 'count' },
          { key: 'WS_MAX_PER_IP', value: config.wsMaxPerIp, unit: 'count' },
          { key: 'WS_MAX_MESSAGES', value: config.wsMaxMessages, unit: 'count' },
          { key: 'WS_MESSAGE_WINDOW_MS', value: config.wsMessageWindowMs, unit: 'ms' },
          { key: 'WS_PING_INTERVAL_MS', value: config.wsPingIntervalMs, unit: 'ms' },
        ],
      },
      {
        id: 'location',
        items: [
          { key: 'LOC_MAX_DURATION_MS', value: config.locMaxDurationMs, unit: 'ms' },
          { key: 'LOC_MAX_SHARES_PER_FAMILY', value: config.locMaxSharesPerFamily, unit: 'count' },
          { key: 'LOC_MIN_INTERVAL_MS', value: config.locMinIntervalMs, unit: 'ms' },
          { key: 'LOC_MAX_PER_MINUTE', value: config.locMaxPerMinute, unit: 'perMinute' },
          { key: 'LOC_GRACE_MS', value: config.locGraceMs, unit: 'ms' },
          { key: 'LOC_WAKE_COOLDOWN_MS', value: config.locWakeCooldownMs, unit: 'ms' },
        ],
      },
      {
        id: 'weather',
        // nur Schalter und Abstand (nie MAC, Rechteck, Ortsname oder Zugangsdaten)
        items: [{ key: 'WEATHER_POLL_MS', value: w.pollMs, unit: 'ms' }],
      },
    ],
  };
}
