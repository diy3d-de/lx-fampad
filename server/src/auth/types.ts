// Schnittstellen zwischen Anmeldung (src/auth/), WebSocket (src/ws/) und später dem Sync (src/sync/).
import type { FastifyRequest } from 'fastify';

export type Role = 'admin' | 'parent' | 'child' | 'guest';

/** Angemeldete Person samt Familie und Rolle. */
export interface Principal {
  userId: string;
  familyId: string;
  role: Role;
  deviceId: string | null;
  /** Sitzung, aus der die Anmeldung stammt (WebSocket: für das Schließen bei Widerruf und die Prüfung beim Ping). */
  sessionId?: string;
}

/** Principal einer echten Sitzung (Cookie oder Access-Token). */
export interface SessionPrincipal extends Principal {
  sessionId: string;
  via: 'cookie' | 'bearer';
  /** Letzte Anmeldung oder erneute Bestätigung (Step-up) dieser Sitzung. */
  stepUpAt: Date | null;
}

export interface AuthService {
  /** Prüft Session-Cookie (Web) bzw. Bearer-Token (App); null = nicht angemeldet. */
  authenticate(request: FastifyRequest): Promise<Principal | null>;
  /** Löst ein Einmal-Ticket für den WebSocket-Aufbau ein (einmal, 30 s); null = ungültig. */
  redeemWsTicket(ticket: string): Promise<Principal | null>;
  /** Prüft eine bestehende Anmeldung erneut (Sitzung widerrufen/abgelaufen, Rolle geändert): aktuelle Person oder null. */
  recheck?(principal: Principal): Promise<Principal | null>;
  /** Ist die IP wegen zu vieler Fehlversuche gesperrt? (Prüfung vor dem WebSocket-Upgrade) */
  isIpBlocked?(ip: string): Promise<boolean>;
  /** Zählt eine fehlgeschlagene WebSocket-Anmeldung gegen die IP (verzögerte Sperre, Audit-Log). */
  noteWsFailure?(ip: string): Promise<void>;
}

/** Ohne Datenbank: niemand ist angemeldet. */
export const noAuth: AuthService = {
  authenticate: async () => null,
  redeemWsTicket: async () => null,
};
