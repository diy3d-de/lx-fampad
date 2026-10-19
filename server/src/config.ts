// Konfiguration ausschließlich über Umgebungsvariablen (siehe .env.example).
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { MAX_OPS } from './sync/types.js';
import { MIN_PROTOCOL_VERSION } from './version.js';

/** Zeiten und Grenzen der Anmeldung (Standardwerte, nur Tests überschreiben sie). */
export interface AuthConfig {
  /** WebAuthn: Relying-Party-ID (registrierbare Domain, ohne Schema und Port). */
  rpId: string;
  rpName: string;
  /** Weitere erlaubte WebAuthn-Origins (z. B. android:apk-key-hash:... für die App); die Origin aus PUBLIC_URL gilt immer. */
  extraOrigins: string[];
  /** Hauptschlüssel (32 Byte): daraus werden per HKDF die Teilschlüssel abgeleitet (TOTP-Verschlüsselung, HMACs). */
  secretKey: Buffer;
  inviteDefaultHours: number;
  inviteMaxHours: number;
  /** Standard-Gültigkeit der Einladung aus dem Bootstrap (Stunden). */
  bootstrapInviteHours: number;
  accessTokenTtlSec: number;
  /** Cookie-Sitzung (Web): absolute Dauer und Leerlauf in Tagen. */
  webSessionMaxDays: number;
  webSessionIdleDays: number;
  /** Refresh-Token (App): absolute Dauer und Leerlauf in Tagen. */
  appSessionMaxDays: number;
  appSessionIdleDays: number;
  /** Toleranzfenster (Sekunden) für ein gerade rotiertes Refresh-Token derselben Geräte-ID, solange die Nachfolgerin unbenutzt ist (Antwort ging verloren). 0 = aus. */
  refreshGraceSec: number;
  /** So lange gilt eine erneute Bestätigung (Step-up) bzw. die Anmeldung als frisch. */
  stepUpMaxAgeSec: number;
  wsTicketTtlSec: number;
  challengeTtlSec: number;
  minPasswordLength: number;
  /** Fehlversuche, ab denen die verzögerte Sperre beginnt (je Konto bzw. je IP). */
  lockoutAccountThreshold: number;
  lockoutIpThreshold: number;
  /** Je Paar aus Konto und IP: sperrt früher als der Konto-Zähler und trifft nur die tippende IP. */
  lockoutPairThreshold: number;
  /** Fehlversuche verfallen nach dieser Zeit ohne neuen Fehlversuch. */
  lockoutWindowSec: number;
  /** Höchstdauer einer Sperre (Sekunden); kurz gehalten, damit niemand fremde Konten lange aussperren kann. */
  lockoutMaxDelaySec: number;
  /** Unauthentifiziert erzeugte WebAuthn-Challenges, die gleichzeitig offen sein dürfen: je IP (IPv6: /64) und insgesamt. */
  challengeMaxPerIp: number;
  challengeMaxGlobal: number;
  maxInvitePinAttempts: number;
  auditRetentionDays: number;
}

export interface Config {
  env: 'development' | 'production' | 'test';
  host: string;
  port: number;
  /** Laufzeit-Rolle (nur DML). */
  databaseUrl: string | undefined;
  /** Migrationsrolle (DDL, Eigentümer); nur migrate-cli. Ohne Angabe gilt databaseUrl (Rückfall für bestehende Installationen). */
  migrationDatabaseUrl: string | undefined;
  publicUrl: string;
  auth: AuthConfig;
  /** WebSocket: Verbindungen je Benutzer sowie Nachrichten je Socket und Zeitfenster. */
  wsMaxPerUser: number;
  wsMaxMessages: number;
  wsMessageWindowMs: number;
  filesDir: string;
  minAppVersion: string;
  /** Älteste Protokollversion, die der Server noch bedient (darunter: 426 update_required). */
  minProtocolVersion: number;
  webVersion: string | undefined;
  /** Datei, deren Inhalt die Version des ausgelieferten Web-Builds ist (schreibt deploy-web.sh). */
  webVersionFile: string | undefined;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'silent';
  /** Anfragen je Minute und IP für alle Routen. */
  rateLimitMax: number;
  /** Anfragen je Minute und IP für /api/v1/auth/* und /api/v1/ws-ticket. */
  authRateLimitMax: number;
  /** Anfragen je Minute und IP für POST /api/v1/sync. */
  syncRateLimitMax: number;
  /** Mengenbegrenzung des Sync je Gerät (je Person das Dreifache): Fassungsvermögen und Auffüllung je Minute für Ops und für Anfragen. */
  syncOpsBurst: number;
  syncOpsPerMinute: number;
  syncReqBurst: number;
  syncReqPerMinute: number;
  /** Höchstzahl Ops je Gerät in 24 Stunden (zählt applied_ops, auch abgelehnte). */
  syncOpsPerDay: number;
  /** Zeitlimits einer Op in der Datenbank (Sperre auf die Familienzeile, Anweisung); danach 503 mit Retry-After. */
  syncLockTimeoutMs: number;
  syncStatementTimeoutMs: number;
  /** Zeitlimit für die Datenbankprüfung in /api/v1/health. */
  healthTimeoutMs: number;
  /** Gleichzeitige WebSocket-Verbindungen je IP. */
  wsMaxPerIp: number;
  /** Push (UnifiedPush über das eigene ntfy): Loopback-URL und Token; fehlt eines, ist Push still aus. */
  ntfyUrl: string | undefined;
  ntfyToken: string | undefined;
  /** Host, den gemeldete UnifiedPush-Endpunkte haben müssen (SSRF-Schutz; gepostet wird nie dorthin, sondern an ntfyUrl). */
  ntfyPublicHost: string;
  /** Abstand der Server-Pings; bleibt ein Pong bis zum nächsten Ping aus, wird die Verbindung getrennt. */
  wsPingIntervalMs: number;
  /** Frist, in der sich ein WebSocket nach dem Verbinden anmelden muss. */
  wsAuthTimeoutMs: number;
}

/** NTFY_URL: nur http(s) ohne Zugangsdaten, Pfad und Query; ohne Angabe oder Token ist Push aus. */
function ntfyUrl(env: NodeJS.ProcessEnv): string | undefined {
  const raw = env.NTFY_URL?.trim();
  if (!raw) return undefined;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new Error('NTFY_URL ungültig');
  }
  if ((u.protocol !== 'http:' && u.protocol !== 'https:') || u.username || u.password || u.search || u.hash || u.pathname !== '/') {
    throw new Error('NTFY_URL ungültig (nur http(s)://Host[:Port] ohne Zugangsdaten und Pfad)');
  }
  return u.origin;
}

function ntfyPublicHost(env: NodeJS.ProcessEnv): string {
  const host = (env.NTFY_PUBLIC_HOST?.trim() || 'ntfy.familie.lx-labs.dev').toLowerCase();
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(host)) throw new Error(`NTFY_PUBLIC_HOST ungültig: ${host}`);
  return host;
}

const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'] as const;
const SEMVER = /^\d+\.\d+\.\d+$/;
const NODE_ENVS = ['development', 'production', 'test'] as const;

function positiveInt(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) throw new Error(`${name} ungültig: ${raw}`);
  return n;
}

/** Fassungsvermögen der Op-Bucket: mindestens so groß wie die größte Anfrage (MAX_OPS), sonst ginge sie nie durch. */
function syncOpsBurst(env: NodeJS.ProcessEnv): number {
  const n = positiveInt(env, 'SYNC_OPS_BURST', 100);
  if (n < MAX_OPS) throw new Error(`SYNC_OPS_BURST ungültig: mindestens ${MAX_OPS}`);
  return n;
}

const PLACEHOLDER_KEYS = ['CHANGE_ME', 'changeme', 'secret'];

/** Mindestlänge neuer Passwörter: einstellbar, aber nie unter 10. */
export const MIN_PASSWORD_LENGTH_FLOOR = 10;
function minPasswordLength(env: NodeJS.ProcessEnv): number {
  const n = positiveInt(env, 'MIN_PASSWORD_LENGTH', 12);
  if (n < MIN_PASSWORD_LENGTH_FLOOR) throw new Error(`MIN_PASSWORD_LENGTH darf nicht unter ${MIN_PASSWORD_LENGTH_FLOOR} liegen: ${n}`);
  return n;
}

/** Liest den Hauptschlüssel aus AUTH_SECRET_KEY (Base64/Hex) oder AUTH_SECRET_KEY_FILE; mindestens 32 Byte. */
function loadSecretKey(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): Buffer {
  let raw = env.AUTH_SECRET_KEY?.trim();
  const file = env.AUTH_SECRET_KEY_FILE?.trim();
  if (!raw && file) {
    try {
      raw = readFileSync(file, 'utf8').trim();
    } catch {
      throw new Error('AUTH_SECRET_KEY_FILE nicht lesbar');
    }
  }
  if (!raw) {
    // fail-closed: nur Entwicklung und Test erzeugen einen flüchtigen Schlüssel (Sitzungen überleben keinen Neustart)
    if (nodeEnv === 'production') throw new Error('AUTH_SECRET_KEY (oder AUTH_SECRET_KEY_FILE) fehlt');
    return randomBytes(32);
  }
  if (PLACEHOLDER_KEYS.some((p) => raw.includes(p))) throw new Error('AUTH_SECRET_KEY ist ein Platzhalter');
  const key = /^[0-9a-fA-F]{64,}$/.test(raw) ? Buffer.from(raw, 'hex') : Buffer.from(raw, 'base64');
  if (key.length < 32) throw new Error('AUTH_SECRET_KEY muss mindestens 32 Byte lang sein (Base64 oder Hex)');
  if (key.every((b) => b === key[0])) throw new Error('AUTH_SECRET_KEY ist unzulässig (gleichförmig)');
  return key;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // fail-closed: ohne NODE_ENV gilt "production" (strenge Prüfungen); unbekannte Werte werden abgelehnt.
  // Gelockert wird nur bei ausdrücklich gesetztem "development" oder "test".
  const rawEnv = env.NODE_ENV || 'production';
  if (!(NODE_ENVS as readonly string[]).includes(rawEnv)) {
    throw new Error(`NODE_ENV ungültig: ${rawEnv} (erlaubt: ${NODE_ENVS.join(', ')})`);
  }
  const nodeEnv = rawEnv as Config['env'];

  const port = Number(env.PORT ?? 4400);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`PORT ungültig: ${env.PORT}`);

  const publicUrl = env.PUBLIC_URL ?? 'http://localhost:4400';
  try {
    new URL(publicUrl);
  } catch {
    throw new Error(`PUBLIC_URL ungültig: ${publicUrl}`);
  }

  const rpId = env.WEBAUTHN_RP_ID?.trim() || new URL(publicUrl).hostname;
  if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i.test(rpId)) throw new Error(`WEBAUTHN_RP_ID ungültig: ${rpId}`);

  const minAppVersion = env.MIN_APP_VERSION ?? '0.1.0';
  if (!SEMVER.test(minAppVersion)) throw new Error(`MIN_APP_VERSION ungültig: ${minAppVersion}`);

  const level = env.LOG_LEVEL ?? 'info';
  if (!(LOG_LEVELS as readonly string[]).includes(level)) throw new Error(`LOG_LEVEL ungültig: ${level}`);

  return {
    env: nodeEnv,
    host: env.HOST ?? '127.0.0.1',
    port,
    databaseUrl: env.DATABASE_URL || undefined,
    migrationDatabaseUrl: env.MIGRATION_DATABASE_URL || undefined,
    publicUrl,
    auth: {
      rpId,
      rpName: env.WEBAUTHN_RP_NAME?.trim() || 'lx-fampad',
      extraOrigins: (env.WEBAUTHN_ORIGINS ?? '')
        .split(',')
        .map((o) => o.trim())
        .filter(Boolean),
      secretKey: loadSecretKey(env, nodeEnv),
      inviteDefaultHours: 24,
      inviteMaxHours: 168,
      bootstrapInviteHours: 168,
      accessTokenTtlSec: 15 * 60,
      webSessionMaxDays: 30,
      webSessionIdleDays: 7,
      appSessionMaxDays: 90,
      appSessionIdleDays: 30,
      refreshGraceSec: 30,
      stepUpMaxAgeSec: 5 * 60,
      wsTicketTtlSec: 30,
      challengeTtlSec: 5 * 60,
      minPasswordLength: minPasswordLength(env),
      lockoutAccountThreshold: 10,
      lockoutIpThreshold: 20,
      lockoutPairThreshold: 5,
      lockoutWindowSec: 15 * 60,
      lockoutMaxDelaySec: 90,
      challengeMaxPerIp: positiveInt(env, 'CHALLENGE_MAX_PER_IP', 20),
      challengeMaxGlobal: positiveInt(env, 'CHALLENGE_MAX_GLOBAL', 2000),
      maxInvitePinAttempts: 5,
      auditRetentionDays: positiveInt(env, 'AUDIT_RETENTION_DAYS', 365),
    },
    wsMaxPerUser: positiveInt(env, 'WS_MAX_PER_USER', 8),
    wsMaxMessages: positiveInt(env, 'WS_MAX_MESSAGES', 30),
    wsMessageWindowMs: positiveInt(env, 'WS_MESSAGE_WINDOW_MS', 10_000),
    filesDir: env.FILES_DIR ?? './data/files',
    minAppVersion,
    minProtocolVersion: positiveInt(env, 'MIN_PROTOCOL_VERSION', MIN_PROTOCOL_VERSION),
    webVersion: env.WEB_VERSION || undefined,
    webVersionFile: env.WEB_VERSION_FILE || undefined,
    logLevel: level as Config['logLevel'],
    rateLimitMax: positiveInt(env, 'RATE_LIMIT_MAX', 300),
    authRateLimitMax: positiveInt(env, 'AUTH_RATE_LIMIT_MAX', 10),
    syncRateLimitMax: positiveInt(env, 'SYNC_RATE_LIMIT_MAX', 120),
    syncOpsBurst: syncOpsBurst(env),
    syncOpsPerMinute: positiveInt(env, 'SYNC_OPS_PER_MINUTE', 120),
    syncReqBurst: positiveInt(env, 'SYNC_REQ_BURST', 30),
    syncReqPerMinute: positiveInt(env, 'SYNC_REQ_PER_MINUTE', 120),
    syncOpsPerDay: positiveInt(env, 'SYNC_OPS_PER_DAY', 5000),
    syncLockTimeoutMs: positiveInt(env, 'SYNC_LOCK_TIMEOUT_MS', 5000),
    syncStatementTimeoutMs: positiveInt(env, 'SYNC_STATEMENT_TIMEOUT_MS', 10_000),
    healthTimeoutMs: positiveInt(env, 'HEALTH_TIMEOUT_MS', 2000),
    ntfyUrl: ntfyUrl(env),
    ntfyToken: env.NTFY_TOKEN?.trim() || undefined,
    ntfyPublicHost: ntfyPublicHost(env),
    wsMaxPerIp: positiveInt(env, 'WS_MAX_PER_IP', 10),
    wsPingIntervalMs: positiveInt(env, 'WS_PING_INTERVAL_MS', 30_000),
    wsAuthTimeoutMs: positiveInt(env, 'WS_AUTH_TIMEOUT_MS', 5000),
  };
}

/** Lockerungen (z. B. Origin-Prüfung) gibt es nur in Entwicklung und Test. */
export function isLax(config: Pick<Config, 'env'>): boolean {
  return config.env === 'development' || config.env === 'test';
}
