import type { FastifyInstance } from 'fastify';
import type { Config } from '../config.js';
import { PROTOCOL_VERSION, SERVER_VERSION } from '../version.js';
import type { ServerMessage } from './hub.js';

function send(socket: { send(data: string): void }, msg: ServerMessage): void {
  socket.send(JSON.stringify(msg));
}

/**
 * WebSocket-Gerüst unter /ws. Phase 0: Origin-Prüfung, hello und ping/pong, keine Daten.
 * Phase 1: Anmeldung per Session-Cookie oder Einmal-Ticket beim Upgrade, danach Hub.add(familyId, socket).
 */
export function registerWebSocketRoute(app: FastifyInstance, config: Config): void {
  const allowedOrigin = new URL(config.publicUrl).origin;

  app.get('/ws', { websocket: true }, (socket, req) => {
    const origin = req.headers.origin;
    // Browser senden immer einen Origin; die App (kein Browser) sendet keinen
    if (origin && origin !== allowedOrigin && config.env === 'production') {
      socket.close(1008, 'origin');
      return;
    }
    send(socket, { type: 'hello', protocolVersion: PROTOCOL_VERSION, serverVersion: SERVER_VERSION });

    socket.on('message', (raw: Buffer) => {
      let data: unknown;
      try {
        data = JSON.parse(raw.toString('utf8'));
      } catch {
        send(socket, { type: 'error', code: 'bad_json' });
        return;
      }
      if (typeof data === 'object' && data !== null && (data as { type?: unknown }).type === 'ping') {
        send(socket, { type: 'pong' });
      } else {
        send(socket, { type: 'error', code: 'unsupported' });
      }
    });
  });
}
