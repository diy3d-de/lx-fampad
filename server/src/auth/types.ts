// Platzhalter-Schnittstellen für Phase 1 (Anmeldung). In Phase 0 gibt es keine Implementierung.
import type { FastifyRequest } from 'fastify';

export type Role = 'admin' | 'parent' | 'child' | 'guest';

/** Angemeldete Person samt Familie und Rolle. */
export interface Principal {
  userId: string;
  familyId: string;
  role: Role;
  deviceId: string | null;
}

export interface AuthService {
  /** Prüft Session-Cookie (Web) bzw. Bearer-Token (App); null = nicht angemeldet. */
  authenticate(request: FastifyRequest): Promise<Principal | null>;
  /** Einmal-Ticket für den WebSocket-Aufbau (Phase 1); null = nicht erlaubt. */
  redeemWsTicket(ticket: string): Promise<Principal | null>;
}

/** Phase 0: niemand ist angemeldet. */
export const noAuth: AuthService = {
  authenticate: async () => null,
  redeemWsTicket: async () => null,
};
