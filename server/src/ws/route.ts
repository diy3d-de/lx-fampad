import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AuthService, Principal } from '../auth/types.js';
import { isLax, type Config } from '../config.js';
import { normalizeIp } from '../net.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../version.js';
import type { Hub, ServerMessage } from './hub.js';

/** Schließcode: nicht (rechtzeitig) angemeldet. */
export const WS_CLOSE_UNAUTHENTICATED = 4401;
/** Schließcode: Verbindung antwortet nicht auf Pings. */
export const WS_CLOSE_PING_TIMEOUT = 4408;
/** Schließcode: zu viele Nachrichten bzw. zu viele Verbindungen der Person. */
export const WS_CLOSE_RATE_LIMIT = 4429;

const MAX_TICKET_LENGTH = 256;
/** Eine reservierte, aber nie zum Socket gewordene Verbindung (abgebrochenes Upgrade) wird nach dieser Frist freigegeben. */
const RESERVATION_TIMEOUT_MS = 10_000;

function send(socket: { send(data: string): void }, msg: ServerMessage): void {
  socket.send(JSON.stringify(msg));
}

export interface WebSocketDeps {
  auth: AuthService;
  hub: Hub;
}

/** Zähler, bei dem Prüfen und Erhöhen in einem synchronen Schritt geschehen (kein Wettlauf zwischen Anfragen). */
class Counter {
  private readonly counts = new Map<string, number>();

  /** true, wenn noch Platz war und der Zähler erhöht wurde. */
  tryAcquire(key: string, max: number): boolean {
    const n = this.counts.get(key) ?? 0;
    if (n >= max) return false;
    this.counts.set(key, n + 1);
    return true;
  }

  release(key: string): void {
    const left = (this.counts.get(key) ?? 1) - 1;
    if (left <= 0) this.counts.delete(key);
    else this.counts.set(key, left);
  }
}

interface Reservation {
  claimed: boolean;
  released: boolean;
}

/**
 * WebSocket unter /ws.
 *
 * Vor dem Upgrade (preValidation, die Verbindung wird dann mit HTTP 4xx abgelehnt):
 *  - Origin-Prüfung, fail-closed: Ein Origin, der nicht PUBLIC_URL entspricht, wird abgelehnt; nur in
 *    "development" und "test" ist das gelockert. Die App (kein Browser) sendet keinen Origin und muss sich
 *    trotzdem anmelden.
 *  - kein Ticket oder Token in der URL (landet sonst in Logs und Verlauf)
 *  - gesperrte IPs (zu viele Fehlversuche, auch von früheren WebSocket-Anmeldungen) werden abgewiesen
 *  - höchstens [Config.wsMaxPerIp] gleichzeitige Verbindungen je IP; Prüfen und Zählen geschehen atomar
 *    (Reservierung in preValidation, Freigabe beim Schließen oder nach Ablauf der Frist)
 *
 * Nach dem Upgrade: Anmeldung per Session-Cookie oder als erste Nachricht {type:'auth', ticket}
 * innerhalb von [Config.wsAuthTimeoutMs], sonst wird die Verbindung geschlossen. Ein Ticket (30 s, einmal einlösbar,
 * aus POST /api/v1/ws-ticket) wird über [AuthService.redeemWsTicket] eingelöst; ein ungültiges zählt als Fehlversuch
 * gegen die IP. Je Socket gilt ein Nachrichtenlimit, je Person ein Verbindungslimit. Der Server pingt alle
 * [Config.wsPingIntervalMs]; bleibt das Pong aus, wird getrennt.
 */
export function registerWebSocketRoute(app: FastifyInstance, config: Config, { auth, hub }: WebSocketDeps): void {
  const allowedOrigin = new URL(config.publicUrl).origin;
  const lax = isLax(config);
  const perIp = new Counter();
  const perUser = new Counter();
  const reservations = new WeakMap<FastifyRequest, Reservation & { ip: string }>();

  const preValidation = async (req: FastifyRequest, reply: FastifyReply) => {
    const origin = req.headers.origin;
    if (!lax && origin !== undefined && origin !== allowedOrigin) {
      return reply.code(403).send({ error: 'origin_not_allowed' });
    }
    const query = (req.query ?? {}) as Record<string, unknown>;
    if ('ticket' in query || 'token' in query) {
      return reply.code(400).send({ error: 'ticket_in_url_not_allowed' });
    }
    if (auth.isIpBlocked && (await auth.isIpBlocked(req.ip))) {
      return reply.code(429).send({ error: 'too_many_attempts' });
    }
    // ab hier kein await mehr bis zur Reservierung: prüfen und zählen in einem Schritt
    // (IPv6: ein Anschluss hat ein ganzes /64, das Limit gilt je Präfix)
    const ipKey = normalizeIp(req.ip);
    if (!perIp.tryAcquire(ipKey, config.wsMaxPerIp)) {
      return reply.code(429).send({ error: 'too_many_connections' });
    }
    const reservation = { ip: ipKey, claimed: false, released: false };
    reservations.set(req, reservation);
    setTimeout(() => {
      if (!reservation.claimed && !reservation.released) {
        reservation.released = true;
        perIp.release(reservation.ip);
      }
    }, RESERVATION_TIMEOUT_MS).unref();
  };

  app.get('/ws', { websocket: true, preValidation }, (socket, req) => {
    const ip = req.ip;
    const ipKey = normalizeIp(ip);
    const reservation = reservations.get(req);
    if (reservation && !reservation.released) reservation.claimed = true;
    else perIp.tryAcquire(ipKey, Number.MAX_SAFE_INTEGER);

    let principal: Principal | null = null;
    let userKey: string | null = null;
    let alive = true;
    let windowStart = Date.now();
    let windowCount = 0;

    const authTimer = setTimeout(() => {
      if (!principal) socket.close(WS_CLOSE_UNAUTHENTICATED, 'auth_timeout');
    }, config.wsAuthTimeoutMs);

    const pingTimer = setInterval(() => {
      if (!alive) {
        socket.close(WS_CLOSE_PING_TIMEOUT, 'ping_timeout');
        // reagiert der Peer nicht einmal auf das Schließen, nach kurzer Frist hart trennen
        setTimeout(() => socket.terminate(), 1000).unref();
        return;
      }
      alive = false;
      socket.ping();
      void recheck();
    }, config.wsPingIntervalMs);

    // Beim Ping die Sitzung prüfen: widerrufen, abgelaufen oder Mitglied entfernt -> schließen; sonst Rolle aktuell halten
    let rechecking = false;
    const recheck = async () => {
      if (!principal || !auth.recheck || rechecking) return;
      rechecking = true;
      try {
        const current = await auth.recheck(principal);
        if (!current) socket.close(WS_CLOSE_UNAUTHENTICATED, 'session_ended');
        else if (principal && current.role !== principal.role) {
          principal = { ...principal, role: current.role };
          hub.setRole(socket, current.role);
        }
      } catch (err: unknown) {
        req.log.warn({ err }, 'Sitzungsprüfung des WebSockets fehlgeschlagen');
      } finally {
        rechecking = false;
      }
    };

    socket.on('pong', () => {
      alive = true;
      hub.touch(socket);
    });
    socket.on('error', (err: Error) => req.log.warn({ err }, 'WebSocket-Fehler'));
    socket.once('close', () => {
      clearTimeout(authTimer);
      clearInterval(pingTimer);
      perIp.release(ipKey);
      if (userKey) perUser.release(userKey);
    });

    const failAuth = (reason: string) => {
      // abgelehnte Anmeldungen zählen gegen die IP (verzögerte Sperre), nicht nur erfolgreiche Verbindungen
      void auth.noteWsFailure?.(ip)?.catch((err: unknown) => req.log.warn({ err }, 'Fehlversuch nicht gezählt'));
      socket.close(WS_CLOSE_UNAUTHENTICATED, reason);
    };

    const onAuthenticated = (p: Principal) => {
      if (principal || socket.readyState !== socket.OPEN) return;
      if (!perUser.tryAcquire(p.userId, config.wsMaxPerUser)) {
        socket.close(WS_CLOSE_RATE_LIMIT, 'too_many_connections');
        return;
      }
      userKey = p.userId;
      principal = p;
      clearTimeout(authTimer);
      hub.add(p.familyId, socket, { userId: p.userId, sessionId: p.sessionId, deviceId: p.deviceId, role: p.role });
      send(socket, { type: 'ready' });
    };

    send(socket, { type: 'hello', protocolVersion: PROTOCOL_VERSION, serverVersion: SERVER_VERSION });

    // Browser: Session-Cookie. Ohne gültige Sitzung bleibt die Anmeldung per Ticket.
    auth
      .authenticate(req)
      .then((p) => p && onAuthenticated(p))
      .catch((err: unknown) => req.log.warn({ err }, 'WebSocket-Anmeldung fehlgeschlagen'));

    socket.on('message', (raw: Buffer) => {
      hub.touch(socket);
      // Nachrichtenlimit je Socket (feste Zeitfenster)
      const now = Date.now();
      if (now - windowStart >= config.wsMessageWindowMs) {
        windowStart = now;
        windowCount = 0;
      }
      if (++windowCount > config.wsMaxMessages) {
        socket.close(WS_CLOSE_RATE_LIMIT, 'rate_limited');
        return;
      }

      let data: unknown;
      try {
        data = JSON.parse(raw.toString('utf8'));
      } catch {
        send(socket, { type: 'error', code: 'bad_json' });
        return;
      }
      const msg = (typeof data === 'object' && data !== null ? data : {}) as { type?: unknown; ticket?: unknown };

      if (msg.type === 'ping') {
        send(socket, { type: 'pong' });
      } else if (msg.type === 'auth') {
        if (principal) return;
        if (typeof msg.ticket !== 'string' || msg.ticket.length === 0 || msg.ticket.length > MAX_TICKET_LENGTH) {
          failAuth('bad_ticket');
          return;
        }
        auth
          .redeemWsTicket(msg.ticket)
          .then((p) => (p ? onAuthenticated(p) : failAuth('bad_ticket')))
          .catch((err: unknown) => {
            req.log.warn({ err }, 'Ticket konnte nicht eingelöst werden');
            socket.close(WS_CLOSE_UNAUTHENTICATED, 'bad_ticket');
          });
      } else if (!principal) {
        send(socket, { type: 'error', code: 'unauthenticated' });
      } else {
        send(socket, { type: 'error', code: 'unsupported' });
      }
    });
  });
}
