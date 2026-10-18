import type { FastifyInstance } from 'fastify';
import type { Config } from '../config.js';
import { MIN_PROTOCOL_VERSION, PROTOCOL_VERSION, SERVER_VERSION } from '../version.js';

export interface SystemDeps {
  config: Config;
  /** Prüft die Datenbankverbindung; fehlt sie, meldet /health "db: skipped". */
  pingDb?: () => Promise<void>;
}

export function registerSystemRoutes(app: FastifyInstance, { config, pingDb }: SystemDeps): void {
  app.get('/api/v1/health', async (_req, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!pingDb) return { status: 'ok', db: 'skipped' };
    try {
      await pingDb();
      return { status: 'ok', db: 'ok' };
    } catch (err) {
      app.log.error({ err }, 'Datenbank nicht erreichbar');
      return reply.code(503).send({ status: 'error', db: 'down' });
    }
  });

  app.get('/api/v1/version', async (_req, reply) => {
    reply.header('Cache-Control', 'no-store');
    return {
      service: 'lx-familie',
      version: SERVER_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      minProtocolVersion: MIN_PROTOCOL_VERSION,
      minAppVersion: config.minAppVersion,
      webVersion: config.webVersion ?? null,
    };
  });
}
