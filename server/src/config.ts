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
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'silent';
}

const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'] as const;
const SEMVER = /^\d+\.\d+\.\d+$/;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const nodeEnv = env.NODE_ENV === 'production' || env.NODE_ENV === 'test' ? env.NODE_ENV : 'development';

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
    logLevel: level as Config['logLevel'],
  };
}
