// Schnittstellen zwischen Anmeldung (src/auth/), WebSocket (src/ws/) und später dem Sync (src/sync/).
import type { FastifyRequest } from 'fastify';

export type Role = 'admin' | 'parent' | 'child';

/**
 * Herkunft einer Sitzung: normale Anmeldung (Passkey, Passwort + TOTP), Zugang über einen einzelnen Wiederherstellungscode, einen Passwort-Reset oder eine
 * Anmeldung kurz nach einer Änderung der Anmeldedaten (`access_change`).
 * Nur die erste ist frei für destruktive Schlüssel-Aktionen; die anderen warten 24 h (`destructive_locked`, siehe requireDestructiveAllowed).
 */
export type SessionOrigin = 'login' | 'recovery_code' | 'password_reset' | 'access_change';

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
  /** Anmeldeart der Sitzung (passkey | password | recovery). */
  authMethod: string;
  /** Herkunft der Sitzung und deren Zeitpunkt (null bei `login`). */
  origin: SessionOrigin;
  originAt: Date | null;
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
