import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { Config } from '../config.js';
import type * as schema from '../db/schema.js';
import type { KeyRing } from './crypto.js';
import type { Role } from './types.js';

export type Db = NodePgDatabase<typeof schema>;
export type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];
/** Verbindung oder Transaktion: Funktionen, die beides akzeptieren, lassen sich in Transaktionen zusammensetzen. */
export type Executor = Db | Tx;

export interface Logger {
  warn(obj: object, msg?: string): void;
  error(obj: object, msg?: string): void;
}

/** Sitzungen, die gerade widerrufen wurden (der WebSocket-Hub schließt daraufhin die zugehörigen Verbindungen). */
export type RevokeEvent =
  | { kind: 'user'; userId: string; exceptSessionId?: string | undefined }
  | { kind: 'device'; deviceId: string }
  | { kind: 'session'; sessionId: string };

/** Wer eine Änderung ausgelöst hat (Push: weder die Person noch ihre Geräte werden geweckt). Fehlt die Angabe, gibt es keinen Push. */
export interface RevOrigin {
  userId: string;
  deviceId: string | null;
}

/** Gemeinsamer Kontext aller Auth-Funktionen. `now` ist austauschbar (Tests). */
export interface AuthContext {
  db: Db;
  config: Config;
  keys: KeyRing;
  now: () => Date;
  log: Logger;
  /** Wird nach jedem Widerruf aufgerufen; app.ts hängt den WebSocket-Hub ein. */
  onRevoke: (event: RevokeEvent) => void;
  /** Wird nach dem Commit einer Änderung im Sync aufgerufen (neue Revision der Familie); app.ts hängt den WebSocket-Hub ein. */
  /** Wird nach dem Commit einer Änderung der Mitglieder aufgerufen (Beitritt, Freigabe, Entfernen, Rolle, Familienrolle, Name, Farbe, Bild, Schlüssel); app.ts hängt den WebSocket-Hub ein. Nur ein Hinweis, nie Inhalt. */
  onMembersChanged: (familyId: string) => void;
  onRev: (familyId: string, rev: number, roles?: readonly Role[], users?: readonly string[], origin?: RevOrigin) => void;
}

/** Angaben zur Anfrage, die ins Audit-Log und in die Fehlversuchs-Zähler fließen. */
export interface RequestMeta {
  ip: string | undefined;
  userAgent?: string | undefined;
}
