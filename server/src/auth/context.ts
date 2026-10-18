import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { Config } from '../config.js';
import type * as schema from '../db/schema.js';
import type { KeyRing } from './crypto.js';

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

/** Gemeinsamer Kontext aller Auth-Funktionen. `now` ist austauschbar (Tests). */
export interface AuthContext {
  db: Db;
  config: Config;
  keys: KeyRing;
  now: () => Date;
  log: Logger;
  /** Wird nach jedem Widerruf aufgerufen; app.ts hängt den WebSocket-Hub ein. */
  onRevoke: (event: RevokeEvent) => void;
}

/** Angaben zur Anfrage, die ins Audit-Log und in die Fehlversuchs-Zähler fließen. */
export interface RequestMeta {
  ip: string | undefined;
  userAgent?: string | undefined;
}
