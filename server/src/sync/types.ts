// Protokoll des Sync (POST /api/v1/sync), siehe docs/API.md und docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6.
import { z } from 'zod';

/** Höchstzahl Ops je Aufruf und Änderungen je Seite (Obergrenzen; Antworten und Anfragen bleiben klein). */
export const MAX_OPS = 50;
export const MAX_PAGE = 500;
export const DEFAULT_PAGE = 500;
/** Tombstones, ersetzte Protokolleinträge und verarbeitete Ops werden spätestens nach so vielen Tagen entfernt. */
export const RETENTION_DAYS = 90;
/** Abgelehnte Ops enthalten nichts Wiederverwertbares und werden früher entfernt. */
export const REJECTED_RETENTION_DAYS = 7;

/** Gründe, aus denen eine Op abgelehnt wird (`rejected[].code`). Stabil: die App ordnet jedem Code eine Meldung zu. */
export const REJECT_CODES = [
  /** Eingabe ungültig: unbekanntes Feld, falscher Wert/Typ, zu lang, ungültige Zeichen, Pflichtfeld fehlt, unveränderliches Feld geändert. */
  'invalid',
  /** Unbekannte Entität. */
  'unknown_entity',
  /** Die Rolle darf das nicht (obwohl sie den Datensatz sehen darf). */
  'forbidden',
  /** Datensatz unbekannt, gehört einer anderen Familie oder ist für die Rolle nicht sichtbar. */
  'not_found',
  /** Der Datensatz wurde gelöscht (Löschung gewinnt gegen spätere Änderungen). */
  'deleted',
  /** Der übergeordnete Datensatz (z. B. die Liste) wurde gelöscht. */
  'parent_deleted',
  /** Ein Verweis zeigt auf ein Mitglied, das nicht (mehr) zur Familie gehört. */
  'invalid_reference',
  /** Obergrenze erreicht (Listen je Familie, Einträge je Liste). */
  'limit_reached',
  /** Die op_id wurde von einem anderen Gerät benutzt. */
  'duplicate_op',
] as const;
export type RejectCode = (typeof REJECT_CODES)[number];

/** Kopf der Anfrage (ohne Ops). Die Ops werden einzeln geprüft: eine fehlerhafte Op blockiert die anderen nicht. */
export const syncHead = z
  .object({
    protocolVersion: z.number().int().min(1).max(1_000_000),
    deviceId: z.uuid(),
    sinceRev: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
    limit: z.number().int().min(1).max(MAX_PAGE).optional(),
    /** Ziel-Revision eines laufenden mehrseitigen Snapshots (aus der Antwort der ersten Seite; sinceRev ist dann der Cursor). */
    snapshotRev: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER).optional(),
  })
  .strict();
export const opList = z.array(z.unknown()).max(MAX_OPS);

/** Eine Op, so wie der Client sie sendet. `fields` nur bei upsert, `baseRev`: Revision, auf der die Änderung aufbaut (0 = neu). */
export const opEnvelope = z
  .object({
    opId: z.uuid(),
    op: z.enum(['upsert', 'delete']),
    entity: z.string().min(1).max(40),
    id: z.uuid(),
    fields: z.record(z.string().max(40), z.unknown()).optional(),
    baseRev: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  })
  .strict();
export type ParsedOp = z.infer<typeof opEnvelope>;

export interface ConflictOut {
  opId: string;
  entity: string;
  id: string;
  /** Felder der Op, die nicht übernommen wurden, mit dem Wert des Servers. */
  fields: Record<string, unknown>;
  /** Revision des Servers, die gewonnen hat. */
  serverRev: number;
}

export interface ChangeOut {
  rev: number;
  entity: string;
  id: string;
  /** Der Datensatz ist gelöscht (oder, mit `hidden`, für diese Person nicht mehr sichtbar): lokal entfernen. */
  tombstone: boolean;
  hidden?: true;
  /** Vollständiger Stand des Datensatzes (leer bei Tombstone). */
  fields: Record<string, unknown>;
}

export interface SyncResponse {
  status: 'ok' | 'resync_required';
  /** Stand der Familie zum Zeitpunkt der Abfrage. Gilt als neues `sinceRev`, wenn `hasMore` false ist. */
  rev: number;
  acked: string[];
  rejected: { opId: string; code: RejectCode }[];
  conflicts: ConflictOut[];
  changes: ChangeOut[];
  hasMore: boolean;
  /** Bei `hasMore`: das `sinceRev` der nächsten Anfrage. */
  next: number;
  /** Nur solange ein mehrseitiger Snapshot läuft: Ziel-Revision, die der Client in den Folgeanfragen als `snapshotRev` mitsendet. */
  snapshotRev?: number;
  serverTime: string;
}
