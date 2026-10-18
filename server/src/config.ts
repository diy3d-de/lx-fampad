// Konfiguration ausschließlich über Umgebungsvariablen (siehe .env.example).
export interface Config {
  env: 'development' | 'production' | 'test';
  host: string;
  port: number;
  databaseUrl: string | undefined;
  publicUrl: string;
  filesDir: string;
  minAppVersion: string;
  webVersion: string | undefined;
  /** Datei, deren Inhalt die Version des ausgelieferten Web-Builds ist (schreibt deploy-web.sh). */
  webVersionFile: string | undefined;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'silent';
  /** Anfragen je Minute und IP für alle Routen. */
  rateLimitMax: number;
  /** Anfragen je Minute und IP für /api/v1/auth/* und /api/v1/ws-ticket. */
  authRateLimitMax: number;
  /** Zeitlimit für die Datenbankprüfung in /api/v1/health. */
  healthTimeoutMs: number;
  /** Gleichzeitige WebSocket-Verbindungen je IP. */
  wsMaxPerIp: number;
  /** Abstand der Server-Pings; bleibt ein Pong bis zum nächsten Ping aus, wird die Verbindung getrennt. */
  wsPingIntervalMs: number;
  /** Frist, in der sich ein WebSocket nach dem Verbinden anmelden muss. */
  wsAuthTimeoutMs: number;
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

  const minAppVersion = env.MIN_APP_VERSION ?? '0.1.0';
  if (!SEMVER.test(minAppVersion)) throw new Error(`MIN_APP_VERSION ungültig: ${minAppVersion}`);

  const level = env.LOG_LEVEL ?? 'info';
  if (!(LOG_LEVELS as readonly string[]).includes(level)) throw new Error(`LOG_LEVEL ungültig: ${level}`);

  return {
    env: nodeEnv,
    host: env.HOST ?? '127.0.0.1',
    port,
    databaseUrl: env.DATABASE_URL || undefined,
    publicUrl,
    filesDir: env.FILES_DIR ?? './data/files',
    minAppVersion,
    webVersion: env.WEB_VERSION || undefined,
    webVersionFile: env.WEB_VERSION_FILE || undefined,
    logLevel: level as Config['logLevel'],
    rateLimitMax: positiveInt(env, 'RATE_LIMIT_MAX', 300),
    authRateLimitMax: positiveInt(env, 'AUTH_RATE_LIMIT_MAX', 10),
    healthTimeoutMs: positiveInt(env, 'HEALTH_TIMEOUT_MS', 2000),
    wsMaxPerIp: positiveInt(env, 'WS_MAX_PER_IP', 10),
    wsPingIntervalMs: positiveInt(env, 'WS_PING_INTERVAL_MS', 30_000),
    wsAuthTimeoutMs: positiveInt(env, 'WS_AUTH_TIMEOUT_MS', 5000),
  };
}

/** Lockerungen (z. B. Origin-Prüfung) gibt es nur in Entwicklung und Test. */
export function isLax(config: Pick<Config, 'env'>): boolean {
  return config.env === 'development' || config.env === 'test';
}
