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
import { registerAvatarRoutes } from './routes/avatar.js';
import { registerPushRoutes } from './routes/push.js';
import { PushService } from './push/service.js';
import { registerWeatherRoutes } from './routes/weather.js';
import { WeatherService } from './weather/service.js';
import { registerSyncRoutes } from './routes/sync.js';
import { registerSystemRoutes } from './routes/system.js';
import { dbDirectory } from './location/directory.js';
import { LocationService, type MemberDirectory } from './location/service.js';
import { Hub } from './ws/hub.js';
import { registerWebSocketRoute, WS_CLOSE_UNAUTHENTICATED } from './ws/route.js';

declare module 'fastify' {
  interface FastifyInstance {
    /** Anmeldung samt Kontext (nur mit Datenbank); der Aufräum-Job in server.ts nutzt ihn. */
    authCore?: Auth;
    /** Offene WebSocket-Verbindungen (Tests prüfen daran Rollen und Schließen). */
    hub: Hub;
    /** Standort teilen: flüchtiger Kanal, nur Prozessspeicher. */
    location: LocationService;
    /** Wetter (nur mit Datenbank); der Abruf-Takt startet in server.ts. */
    weather?: WeatherService;
    /** Push-Wecker (nur mit Datenbank); Chat & Co. hängen hier ihren Empfängerfilter ein (push/service.ts). */
    push?: PushService;
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
  /** Nur Tests: Mitglieder für den Standort-Kanal statt der Datenbank (ohne Datenbank und ohne dies kennt der Kanal niemanden). */
  memberDirectory?: MemberDirectory;
  /** Nur Tests: Zugriff auf den Standort-Dienst (Prüfung per Hand statt Zeitgeber). */
  locationClock?: () => number;
  /** Nur Tests: ntfy ersetzen (Fake-HTTP) und Mindestabstand der Wecker verkürzen. */
  pushFetch?: typeof fetch;
  pushMinIntervalMs?: number;
  /** Nur Tests: Netatmo ersetzen (Fake-HTTP). */
  weatherFetch?: typeof fetch;
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

export async function buildApp({ config, pingDb, db, auth: authOverride, now, logStream, pushFetch, pushMinIntervalMs, weatherFetch, memberDirectory, locationClock }: AppDeps): Promise<FastifyInstance> {
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
  const location = new LocationService({
    hub,
    directory: memberDirectory ?? (db ? dbDirectory(db) : async () => []),
    ...(locationClock ? { now: locationClock } : {}),
    maxDurationMs: config.locMaxDurationMs,
    maxSharesPerFamily: config.locMaxSharesPerFamily,
    minIntervalMs: config.locMinIntervalMs,
    maxPerMinute: config.locMaxPerMinute,
    graceMs: config.locGraceMs,
    wakeCooldownMs: config.locWakeCooldownMs,
    sweepMs: config.locSweepMs,
    directoryTimeoutMs: config.locDirectoryTimeoutMs,
    log: app.log,
  });
  app.decorate('location', location);
  location.startTimer();
  app.addHook('onClose', async () => location.close());
  registerSystemRoutes(app, { config, pingDb });
  let auth: AuthService = authOverride ?? noAuth;
  if (db) {
    const authCore = new Auth({ db, config, log: app.log, ...(now ? { now } : {}) });
    app.decorate('authCore', authCore);
    registerAuthRoutes(app, config, authCore);
    registerAccountRoutes(app, config, authCore);
    registerAvatarRoutes(app, config, authCore);
    registerSyncRoutes(app, config, authCore);
    const push = new PushService({
      db,
      config,
      log: app.log,
      now: authCore.ctx.now,
      hasLiveSocket: (deviceId, maxIdleMs) => hub.hasDevice(deviceId, maxIdleMs),
      hasAnySocket: (deviceId, maxIdleMs) => hub.hasAnySocket(deviceId, maxIdleMs),
      // lebendig = Lebenszeichen innerhalb von 1,5 Ping-Intervallen; Nachprüfung kurz danach
      liveFensterMs: Math.round(config.wsPingIntervalMs * 1.5),
      nachpruefenMs: Math.round(config.wsPingIntervalMs * 1.5) + 1000,
      ...(pushFetch ? { fetch: pushFetch } : {}),
      ...(pushMinIntervalMs !== undefined ? { minIntervalMs: pushMinIntervalMs } : {}),
    });
    app.decorate('push', push);
    push.logStatusOnce();
    // Standort-Freigabe gestartet: Empfänger ohne offene Verbindung per Push wecken (ohne Inhalt)
    location.onWake = (familyId, userIds) => push.weckeStandort(familyId, userIds);
    app.addHook('onClose', async () => push.close());
    registerPushRoutes(app, config, authCore, push);
    const weather = new WeatherService({ db, config, keys: authCore.ctx.keys, log: app.log, now: authCore.ctx.now, ...(weatherFetch ? { fetch: weatherFetch } : {}) });
    app.decorate('weather', weather);
    app.addHook('onClose', async () => weather.close());
    registerWeatherRoutes(app, authCore, weather);
    auth = authOverride ?? authCore;
    // Widerruf (Abmelden, Gerät entfernen, Rollenwechsel, Mitglied entfernen) schließt die offenen WebSockets sofort
    authCore.ctx.onRev = (familyId, rev, roles, users, origin) => {
      hub.notifyRev(familyId, rev, roles, users);
      // Push nur für Änderungen einer Person (Sync); nicht an deren Gerät, nicht an Geräte mit offener Verbindung
      if (origin) void push.weckeGeraete({ familyId, rev, roles, users, origin });
    };
    // Sicherheitsereignis (Passwort-Reset): Geräte der Person ohne Inhalt wecken, nie die Anfrage scheitern lassen
    authCore.ctx.onSecurityEvent = (e) => void push.weckeThemen(e.topics);
    authCore.ctx.onMembersChanged = (familyId) => {
      // nur ein Hinweis: ein Fehler hier darf nie die Anfrage (Registrierung, Änderung) scheitern lassen
      try {
        hub.notifyMembersChanged(familyId);
      } catch (err: unknown) {
        app.log.warn({ err }, 'Hinweis "Mitglieder geändert" fehlgeschlagen');
      }
    };
    authCore.ctx.onRevoke = (e) => {
      // eine widerrufene Sitzung, ein entferntes Gerät oder Mitglied beendet das Teilen sofort (nicht erst nach der Schonfrist)
      location.revoke(e);
      if (e.kind === 'session') hub.closeSession(e.sessionId, WS_CLOSE_UNAUTHENTICATED, 'session_ended');
      else if (e.kind === 'device') hub.closeDevice(e.deviceId, WS_CLOSE_UNAUTHENTICATED, 'session_ended');
      else hub.closeUser(e.userId, WS_CLOSE_UNAUTHENTICATED, 'session_ended', e.exceptSessionId);
    };
  }
  registerWebSocketRoute(app, config, { auth, hub, location });

  return app;
}
