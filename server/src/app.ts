import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import type { Writable } from 'node:stream';
import type { Db } from './auth/context.js';
import { Auth } from './auth/service.js';
import { noAuth, type AuthService } from './auth/types.js';
import { isLax, type Config } from './config.js';
import { serializeErr } from './log.js';
import { normalizeIp } from './net.js';
import { AppError, registerErrorHandling } from './errors.js';
import { registerAccountRoutes } from './routes/account.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerPlaceholderRoutes } from './routes/placeholders.js';
import { registerSystemRoutes } from './routes/system.js';
import { Hub } from './ws/hub.js';
import { registerWebSocketRoute, WS_CLOSE_UNAUTHENTICATED } from './ws/route.js';

declare module 'fastify' {
  interface FastifyInstance {
    /** Anmeldung samt Kontext (nur mit Datenbank); der Aufräum-Job in server.ts nutzt ihn. */
    authCore?: Auth;
    /** Offene WebSocket-Verbindungen (Tests prüfen daran Rollen und Schließen). */
    hub: Hub;
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

/**
 * Gehört die Anfrage zur API? Maßgeblich ist die aufgelöste Route (Fastify dekodiert den Pfad beim Routing: "/%61pi/…" trifft
 * "/api/…"); bei unbekannten Routen der dekodierte, normalisierte Pfad. Ein roher Vergleich von req.url ließe sich mit
 * Prozent-Kodierung umgehen.
 */
export function isApiRequest(req: FastifyRequest): boolean {
  const route = req.routeOptions?.url;
  if (route) return route.startsWith('/api/');
  try {
    return decodeURIComponent(new URL(req.url, 'http://localhost').pathname).startsWith('/api/');
  } catch {
    // nicht dekodierbar (kaputte %-Folge): vorsichtshalber als API behandeln
    return true;
  }
}

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
              // Datenbankfehler ohne SQL-Parameter (E-Mail, Hashes), siehe log.ts
              err: serializeErr,
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
    if (isApiRequest(req) && !reply.hasHeader('cache-control')) reply.header('cache-control', 'no-store');
  });

  // CSRF, Teil 1: ändernde Anfragen mit fremdem Origin werden abgelehnt (Browser senden Origin immer mit; die App sendet keinen).
  // Teil 2 (Token-Header bei Cookie-Sitzungen) steht in auth/sessions.ts.
  const allowedOrigin = new URL(config.publicUrl).origin;
  const lax = isLax(config);
  app.addHook('onRequest', async (req) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method) || !isApiRequest(req)) return;
    const origin = req.headers.origin;
    if (origin !== undefined && origin !== allowedOrigin && !lax) throw new AppError(403, 'origin_not_allowed', 'Anfrage abgelehnt.');
  });

  // global moderat; strengere Grenzen je Route über config.rateLimit (Anmeldung, WebSocket-Ticket)
  await app.register(rateLimit, {
    global: true,
    max: config.rateLimitMax,
    timeWindow: '1 minute',
    // IPv6: ein Anschluss hat ein ganzes /64, die Grenze gilt je Präfix
    keyGenerator: (req) => normalizeIp(req.ip),
  });
  await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

  const hub = new Hub();
  app.decorate('hub', hub);
  registerSystemRoutes(app, { config, pingDb });
  registerPlaceholderRoutes(app);
  let auth: AuthService = authOverride ?? noAuth;
  if (db) {
    const authCore = new Auth({ db, config, log: app.log, ...(now ? { now } : {}) });
    app.decorate('authCore', authCore);
    registerAuthRoutes(app, config, authCore);
    registerAccountRoutes(app, config, authCore);
    auth = authOverride ?? authCore;
    // Widerruf (Abmelden, Gerät entfernen, Rollenwechsel, Mitglied entfernen) schließt die offenen WebSockets sofort
    authCore.ctx.onRevoke = (e) => {
      if (e.kind === 'session') hub.closeSession(e.sessionId, WS_CLOSE_UNAUTHENTICATED, 'session_ended');
      else if (e.kind === 'device') hub.closeDevice(e.deviceId, WS_CLOSE_UNAUTHENTICATED, 'session_ended');
      else hub.closeUser(e.userId, WS_CLOSE_UNAUTHENTICATED, 'session_ended', e.exceptSessionId);
    };
  }
  registerWebSocketRoute(app, config, { auth, hub });

  return app;
}
