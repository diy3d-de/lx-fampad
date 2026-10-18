import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type { Writable } from 'node:stream';
import { noAuth, type AuthService } from './auth/types.js';
import type { Config } from './config.js';
import { registerPlaceholderRoutes } from './routes/placeholders.js';
import { registerSystemRoutes } from './routes/system.js';
import { Hub } from './ws/hub.js';
import { registerWebSocketRoute } from './ws/route.js';

export interface AppDeps {
  config: Config;
  pingDb?: () => Promise<void>;
  /** Anmeldung (Phase 1); Standard: niemand ist angemeldet. */
  auth?: AuthService;
  /** Nur für Tests: Ziel des Logs (Standard: stdout). */
  logStream?: Writable;
}

/** Felder, die nie im Log landen dürfen. */
export const LOG_REDACT_PATHS = [
  'req.headers.cookie',
  'req.headers.authorization',
  'res.headers["set-cookie"]',
  'headers.cookie',
  'headers.authorization',
];

export async function buildApp({ config, pingDb, auth = noAuth, logStream }: AppDeps): Promise<FastifyInstance> {
  const app = Fastify({
    logger:
      config.logLevel === 'silent'
        ? false
        : {
            level: config.logLevel,
            redact: { paths: LOG_REDACT_PATHS, censor: '[geschwärzt]' },
            // nur der Pfad, nie die Query (Tokens/Tickets gehören nie in eine URL und nie ins Log)
            serializers: {
              req: (req) => ({
                method: req.method,
                url: req.url?.split('?')[0],
                host: req.host,
                remoteAddress: req.ip,
              }),
            },
            ...(logStream ? { stream: logStream } : {}),
          },
    // hinter Caddy: echte Client-IP aus X-Forwarded-For
    trustProxy: '127.0.0.1',
    bodyLimit: 1024 * 1024,
  });

  // global moderat; strengere Grenzen je Route über config.rateLimit (Anmeldung, WebSocket-Ticket)
  await app.register(rateLimit, { global: true, max: config.rateLimitMax, timeWindow: '1 minute' });
  await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

  const hub = new Hub();
  registerSystemRoutes(app, { config, pingDb });
  registerPlaceholderRoutes(app, config);
  registerWebSocketRoute(app, config, { auth, hub });

  return app;
}
