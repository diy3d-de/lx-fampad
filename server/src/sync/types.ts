// Platzhalter für das Sync-Protokoll (Phase 1), siehe docs/PROJEKTBESCHREIBUNG.md Abschnitt 6.
export interface SyncOp {
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
  sinceRev: number;
  ops: SyncOp[];
}

export interface SyncResponse {
  rev: number;
  acked: string[];
  rejected: { id: string; reason: string }[];
  changes: {
    rev: number;
    entity: string;
    id: string;
    tombstone: boolean;
    fields: Record<string, unknown>;
  }[];
}
