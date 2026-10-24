import { readFile } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import type { Config } from '../config.js';
import type { MaintenanceGate } from '../operator/maintenance.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../version.js';

export interface SystemDeps {
  config: Config;
  /** Prüft die Datenbankverbindung; fehlt sie, meldet /health "db: skipped". */
  pingDb?: () => Promise<void>;
  /** Wartungsmodus (nur mit Datenbank): `GET /version` meldet ihn, damit die App ihn schon vor der Anmeldung kennt. */
  maintenance?: MaintenanceGate | undefined;
}

const WEB_VERSION_FORMAT = /^[A-Za-z0-9._-]{1,64}$/;

/** Bricht [work] nach [ms] ab (der Pool hat zusätzlich eigene Timeouts). */
function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Zeitüberschreitung nach ${ms} ms`)), ms);
  });
  return Promise.race([work, timeout]).finally(() => clearTimeout(timer));
}

/** Version des Web-Builds: aus WEB_VERSION oder der Datei, die deploy-web.sh mitliefert (null, wenn unbekannt). */
async function readWebVersion(config: Config): Promise<string | null> {
  if (config.webVersion) return config.webVersion;
  if (!config.webVersionFile) return null;
  try {
    const text = (await readFile(config.webVersionFile, 'utf8')).trim();
    return WEB_VERSION_FORMAT.test(text) ? text : null;
  } catch {
    return null;
  }
}

export function registerSystemRoutes(app: FastifyInstance, { config, pingDb, maintenance }: SystemDeps): void {
  // Health-Check bleibt begrenzt (er fragt die Datenbank ab). Nur Aufrufe von 127.0.0.1 (deploy.sh, lokale Überwachung)
  // sind ausgenommen; über Caddy ist req.ip die echte Client-IP aus X-Forwarded-For, nie 127.0.0.1.
  app.get('/api/v1/health', { config: { rateLimit: { allowList: ['127.0.0.1'] } } }, async (_req, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!pingDb) return { status: 'ok', db: 'skipped' };
    try {
      await withTimeout(pingDb(), config.healthTimeoutMs);
      return { status: 'ok', db: 'ok' };
    } catch (err) {
      app.log.error({ err }, 'Datenbank nicht erreichbar');
      return reply.code(503).send({ status: 'error', db: 'down' });
    }
  });

  app.get('/api/v1/version', async (_req, reply) => {
    reply.header('Cache-Control', 'no-store');
    return {
      service: 'lx-fampad',
      version: SERVER_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      minProtocolVersion: config.minProtocolVersion,
      minAppVersion: config.minAppVersion,
      webVersion: await readWebVersion(config),
      maintenance: maintenance ? (await maintenance.current()) !== null : false,
      // wrapKeyVersion (Schalter E2EE_WRAP_KEY_VERSION): der Server nimmt Wraps mit Schlüsselversion (Wrap-ID v2, "Verlauf freigeben"/"Verlauf teilen") an; die App
      // nutzt sie nur dann
      features: {
        pwBackup: config.e2eePwBackup,
        authKey: config.e2eePwBackup,
        legacyPasswordLogin: config.auth.legacyPasswordLogin,
        wrapKeyVersion: config.e2eeWrapKeyVersion,
        prfBackup: config.e2eePrfBackup,
        parentRecovery: config.e2eeParentRecovery,
        // Dateiablage (FILES_ENABLED): Uploads, Ordner, Dateien und verschlüsselte Anhänge; die App zeigt den Bereich nur dann
        files: config.files.enabled,
      },
    };
  });
}
