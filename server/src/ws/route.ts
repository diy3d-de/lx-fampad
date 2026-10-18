import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AuthService, Principal } from '../auth/types.js';
import { isLax, type Config } from '../config.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../version.js';
import type { Hub, ServerMessage } from './hub.js';

/** Schließcode: nicht (rechtzeitig) angemeldet. */
export const WS_CLOSE_UNAUTHENTICATED = 4401;
/** Schließcode: Verbindung antwortet nicht auf Pings. */
export const WS_CLOSE_PING_TIMEOUT = 4408;

const MAX_TICKET_LENGTH = 256;

function send(socket: { send(data: string): void }, msg: ServerMessage): void {
  socket.send(JSON.stringify(msg));
}

export interface WebSocketDeps {
  auth: AuthService;
  hub: Hub;
}

/**
 * WebSocket unter /ws.
 *
 * Vor dem Upgrade (preValidation, die Verbindung wird dann mit HTTP 4xx abgelehnt):
 *  - Origin-Prüfung, fail-closed: Ein Origin, der nicht PUBLIC_URL entspricht, wird abgelehnt; nur in
 *    "development" und "test" ist das gelockert. Die App (kein Browser) sendet keinen Origin und muss sich
 *    trotzdem anmelden.
 *  - kein Ticket oder Token in der URL (landet sonst in Logs und Verlauf)
 *  - höchstens [Config.wsMaxPerIp] gleichzeitige Verbindungen je IP
 *
 * Nach dem Upgrade: Anmeldung per Session-Cookie (Phase 1) oder als erste Nachricht {type:'auth', ticket}
 * innerhalb von [Config.wsAuthTimeoutMs], sonst wird die Verbindung geschlossen. Der Server pingt alle
 * [Config.wsPingIntervalMs]; bleibt das Pong aus, wird getrennt. Phase 0: niemand kann sich anmelden.
 */
export function registerWebSocketRoute(app: FastifyInstance, config: Config, { auth, hub }: WebSocketDeps): void {
  const allowedOrigin = new URL(config.publicUrl).origin;
  const lax = isLax(config);
  const perIp = new Map<string, number>();

  const preValidation = async (req: FastifyRequest, reply: FastifyReply) => {
    const origin = req.headers.origin;
    if (!lax && origin !== undefined && origin !== allowedOrigin) {
      return reply.code(403).send({ error: 'origin_not_allowed' });
    }
    const query = (req.query ?? {}) as Record<string, unknown>;
    if ('ticket' in query || 'token' in query) {
      return reply.code(400).send({ error: 'ticket_in_url_not_allowed' });
    }
    if ((perIp.get(req.ip) ?? 0) >= config.wsMaxPerIp) {
      return reply.code(429).send({ error: 'too_many_connections' });
    }
  };

  app.get('/ws', { websocket: true, preValidation }, (socket, req) => {
    const ip = req.ip;
    perIp.set(ip, (perIp.get(ip) ?? 0) + 1);

    let principal: Principal | null = null;
    let alive = true;

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
    }, config.wsPingIntervalMs);

    socket.on('pong', () => {
      alive = true;
    });
    socket.on('error', (err: Error) => req.log.warn({ err }, 'WebSocket-Fehler'));
    socket.once('close', () => {
      clearTimeout(authTimer);
      clearInterval(pingTimer);
      const left = (perIp.get(ip) ?? 1) - 1;
      if (left <= 0) perIp.delete(ip);
      else perIp.set(ip, left);
    });

    const onAuthenticated = (p: Principal) => {
      if (principal || socket.readyState !== socket.OPEN) return;
      principal = p;
      clearTimeout(authTimer);
      hub.add(p.familyId, socket);
      send(socket, { type: 'ready' });
    };

    send(socket, { type: 'hello', protocolVersion: PROTOCOL_VERSION, serverVersion: SERVER_VERSION });

    // Browser: Session-Cookie (Phase 1). Ohne gültige Sitzung bleibt die Anmeldung per Ticket.
    auth
      .authenticate(req)
      .then((p) => p && onAuthenticated(p))
      .catch((err: unknown) => req.log.warn({ err }, 'WebSocket-Anmeldung fehlgeschlagen'));

    socket.on('message', (raw: Buffer) => {
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
        if (typeof msg.ticket !== 'string' || msg.ticket.length === 0 || msg.ticket.length > MAX_TICKET_LENGTH) {
          socket.close(WS_CLOSE_UNAUTHENTICATED, 'bad_ticket');
          return;
        }
        auth
          .redeemWsTicket(msg.ticket)
          .then((p) => (p ? onAuthenticated(p) : socket.close(WS_CLOSE_UNAUTHENTICATED, 'bad_ticket')))
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
