// Platzhalter für das Sync-Protokoll (Phase 1), siehe docs/PROJEKTBESCHREIBUNG.md Abschnitt 6.

/**
 * Eine Änderung des Clients. `opId` (UUID, vom Client beim Anlegen der Op vergeben) macht den Upload
 * idempotent: Der Server merkt sich verarbeitete op_ids (Tabelle applied_ops) und beantwortet eine
 * wiederholte Op mit derselben Bestätigung, ohne sie noch einmal anzuwenden.
 */
export interface SyncOp {
  opId: string;
  op: 'upsert' | 'delete';
  entity: string;
  id: string;
  /** Geänderte Felder (bei upsert). */
  fields?: Record<string, unknown>;
  /** Revision, auf der der Client aufgebaut hat. */
  baseRev: number;
}

export interface SyncRequest {
  protocolVersion: number;
  /** Letzte Revision, die der Client vollständig kennt; der Server speichert sie als devices.last_rev. */
  sinceRev: number;
  ops: SyncOp[];
}

/** Feldweiser Konflikt (Last-write-wins pro Feld): Der Server-Wert hat gewonnen, der Client übernimmt ihn. */
export interface SyncConflict {
  opId: string;
  entity: string;
  id: string;
  /** Felder der Op, die nicht übernommen wurden. */
  fields: string[];
  /** Revision des Servers, die gewonnen hat. */
  serverRev: number;
}

export interface SyncResponse {
  rev: number;
  /** op_ids, die der Server übernommen hat (auch bei wiederholtem Upload). */
  acked: string[];
  rejected: { opId: string; reason: string }[];
  conflicts: SyncConflict[];
  changes: {
    rev: number;
    entity: string;
    id: string;
    tombstone: boolean;
    fields: Record<string, unknown>;
  }[];
}
