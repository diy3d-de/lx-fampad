import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type { Writable } from 'node:stream';
import type { Db } from './auth/context.js';
import { Auth } from './auth/service.js';
import { noAuth, type AuthService } from './auth/types.js';
import { isLax, type Config } from './config.js';
import { AppError, registerErrorHandling } from './errors.js';
import { registerAccountRoutes } from './routes/account.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerPlaceholderRoutes } from './routes/placeholders.js';
import { registerSystemRoutes } from './routes/system.js';
import { Hub } from './ws/hub.js';
import { registerWebSocketRoute } from './ws/route.js';

declare module 'fastify' {
  interface FastifyInstance {
    /** Anmeldung samt Kontext (nur mit Datenbank); der Aufräum-Job in server.ts nutzt ihn. */
    authCore?: Auth;
  }
}

export interface AppDeps {
  config: Config;
  pingDb?: () => Promise<void>;
  /** Datenbank (Laufzeit-Rolle). Ohne sie gibt es keine Anmeldung: Auth-Routen fehlen, niemand ist angemeldet. */
  db?: Db;
  /** Nur Tests: eigene Anmeldung für den WebSocket statt der echten. */
  auth?: AuthService;
  /** Nur Tests: austauschbare Uhr. */
  now?: () => Date;
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

export async function buildApp({ config, pingDb, db, auth: authOverride, now, logStream }: AppDeps): Promise<FastifyInstance> {
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

  registerErrorHandling(app);

  // Antworten der API werden nie zwischengespeichert (Sitzungen, Tokens, Listen)
  app.addHook('onSend', async (req, reply) => {
    if (req.url.startsWith('/api/') && !reply.hasHeader('cache-control')) reply.header('cache-control', 'no-store');
  });

  // CSRF, Teil 1: ändernde Anfragen mit fremdem Origin werden abgelehnt (Browser senden Origin immer mit; die App sendet keinen).
  // Teil 2 (Token-Header bei Cookie-Sitzungen) steht in auth/sessions.ts.
  const allowedOrigin = new URL(config.publicUrl).origin;
  const lax = isLax(config);
  app.addHook('onRequest', async (req) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method) || !req.url.startsWith('/api/')) return;
    const origin = req.headers.origin;
    if (origin !== undefined && origin !== allowedOrigin && !lax) throw new AppError(403, 'origin_not_allowed', 'Anfrage abgelehnt.');
  });

  // global moderat; strengere Grenzen je Route über config.rateLimit (Anmeldung, WebSocket-Ticket)
  await app.register(rateLimit, { global: true, max: config.rateLimitMax, timeWindow: '1 minute' });
  await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

  const hub = new Hub();
  registerSystemRoutes(app, { config, pingDb });
  registerPlaceholderRoutes(app);
  let auth: AuthService = authOverride ?? noAuth;
  if (db) {
    const authCore = new Auth({ db, config, log: app.log, ...(now ? { now } : {}) });
    app.decorate('authCore', authCore);
    registerAuthRoutes(app, config, authCore);
    registerAccountRoutes(app, config, authCore);
    auth = authOverride ?? authCore;
  }
  registerWebSocketRoute(app, config, { auth, hub });

  return app;
}
