// Entitäten-Register des Sync: Jede synchronisierte Tabelle meldet sich hier mit Feldern, Rechten und Beziehungen an.
// Engine, Änderungsstrom, Löschen/Kaskaden, Aufräumen und das Bereinigen von Mitglieds-Verweisen arbeiten nur über diese
// Beschreibung. Eine neue Entität (Termine, Aufgaben, ...) braucht eine Tabelle mit Sync-Spalten und einen Eintrag hier, keinen Umbau.
import type { AnyPgColumn, AnyPgTable } from 'drizzle-orm/pg-core';
import { getTableColumns } from 'drizzle-orm';
import type { z } from 'zod';
import type { Executor } from '../auth/context.js';
import type { Role } from '../auth/types.js';

/** Schalter der Konfiguration, die eine Entität in ihrer Prüfung braucht. */
export interface EngineFlags {
  /** Wraps mit Schlüsselversion (Wrap-ID v2) annehmen (E2EE_WRAP_KEY_VERSION). */
  wrapKeyVersion: boolean;
  /** Dateiablage (FILES_ENABLED): Ordner, Dateien und Anhänge werden nur dann angenommen. */
  filesEnabled?: boolean;
}
import type { ClaimedBlob, ClaimField } from '../files/claim.js';
import type { Actor, Facts, Rules } from './permissions.js';

/** Eine Zeile aus der Datenbank (Schlüssel = Eigenschaftsnamen der Drizzle-Tabelle, also camelCase). */
export type Row = Record<string, unknown>;

export interface FieldDef {
  /**
   * Wer das Feld schreiben darf:
   *  - `rw`: der Client beim Anlegen und Ändern (Konflikte feldweise),
   *  - `create`: der Client nur beim Anlegen (danach unveränderlich, z. B. der Verweis auf die Liste),
   *  - `server`: nur der Server (z. B. Besitzer, Anlegezeitpunkt); der Client sendet sie nie, bekommt sie aber.
   */
  access: 'rw' | 'create' | 'server';
  /** Prüft und wandelt den Wert aus dem JSON in den Datenbankwert (Zeichenketten ohne NUL/Surrogate, Längen, Enum-Werte). */
  schema: z.ZodType;
  /** Datenbankwert -> JSON-Wert der Antwort. Standard: unverändert. */
  toWire?: (value: unknown) => unknown;
  /** Pflichtfeld beim Anlegen. */
  required?: boolean;
  /** Wert beim Anlegen, wenn der Client das Feld weglässt (sonst gilt der Spaltenstandard). */
  defaultValue?: unknown;
  /** Wert, den ein Tombstone behält (Inhalte werden beim Löschen überschrieben); fehlt: Wert bleibt (nötig für Rechte/Beziehungen). */
  blank?: unknown;
  /** Das Feld enthält eine Mitglieds-ID (`users.id`) oder eine Liste davon: jede muss zu einem aktiven Mitglied DER Familie gehören. */
  memberRef?: boolean;
}

export interface EntityDef {
  /** Name in der Schnittstelle (`entity` einer Op). */
  name: string;
  table: AnyPgTable;
  fields: Readonly<Record<string, FieldDef>>;
  rules: Rules;
  /** Übergeordnete Entität: `field` verweist auf deren `id`; Rechte werden von ihr geerbt. */
  parent?: { entity: string; field: string };
  /** Felder, deren Änderung bestimmt, wer den Datensatz sieht (Freigabe). Eine Änderung stößt die untergeordneten Datensätze neu an. */
  visibilityFields?: readonly string[];
  /** Spalten mit Mitglieds-IDs, die beim Entfernen des Mitglieds auf NULL gesetzt werden (mit Änderungseintrag). */
  userRefs?: readonly string[];
  /** Spalte mit der Mitglieds-ID, die den Datensatz bestimmt (z. B. Teilnehmer): beim Entfernen der Person wird er mit Tombstone gelöscht, die Geräte erfahren es. */
  memberOwned?: string;
  /** Obergrenze lebender Datensätze je Besitzer (`field` = Besitzer-Spalte) für bestimmte Rollen, zusätzlich zu `maxLive` (Schutz vor Überlauf durch ein einzelnes Konto). */
  ownerLimit?: { field: string; roles: readonly Role[]; max: number; /** wie bei `maxLive.openColumn` */ openColumn?: string };
  /** Fakten (Freigabe-Stufe, Besitzer) eines vorhandenen Datensatzes; `parent` sind die Fakten der übergeordneten Entität. */
  facts(row: Row, parent: Facts | null): Facts;
  /** Fakten eines Datensatzes, der angelegt werden soll. */
  factsForCreate(actor: Actor, values: Row, parent: Facts | null): Facts;
  /** Vom Server gesetzte Werte beim Anlegen (z. B. Besitzer = anlegende Person). */
  onCreate?(actor: Actor, now: Date): Row;
  /** Vom Server abgeleitete Werte aus einer Änderung (beim Anlegen und Ändern), z. B. wer eine Aufgabe erledigt hat = Akteur. Kommt nur mit, was `changed` (bzw. die neue Zeile) enthält. */
  derive?(actor: Actor, changed: Row): Row;
  /** Prüft den Datensatz als Ganzes (Felder untereinander, z. B. Ende nach Beginn) beim Anlegen und nach dem Zusammenführen einer Änderung; false = `invalid`. */
  check?(row: Row): boolean;
  /** Obergrenzen lebender Datensätze (Schutz vor Überlauf). `per: 'parent'` zählt je übergeordnetem Datensatz. */
  maxLive?: { per: 'family' | 'parent'; max: number; /** Spalte: gezählt werden nur Datensätze, bei denen sie leer ist (z. B. erledigte Aufgaben zählen nicht). */ openColumn?: string };
  /** Zusätzliche Obergrenze aller lebenden Datensätze der Familie (auch bei `per: 'parent'`, auch die, die `openColumn` ausnimmt). */
  maxFamily?: number;
  /** Zusätzliche, entitätsspezifische Sperre je Aktion (z. B. Direktchats nicht löschen, Teilnehmer nicht ändern); false = `forbidden`. `after` nur bei `update` (Stand nach dem Zusammenführen). */
  guard?(action: 'update' | 'delete', before: Row, after?: Row): boolean;
  /**
   * Vom Server gesetzte Werte, wenn eine Änderung bestimmte Felder berührt (z. B. Zeit der Bearbeitung). Ein Wert `undefined` verwirft die Änderung dieses
   * Feldes (z. B. der Lesestand geht nie zurück); `before` ist der Stand vor der Änderung.
   */
  onUpdate?(changed: Row, now: Date, before: Row): Row;
  /** Prüft die ID eines neuen Datensatzes (feste, aus Inhalten abgeleitete IDs; Schutz vor dem Belegen fremder IDs); false = `invalid`. */
  idValid?(id: string, values: Row, actor: Actor, familyId: string): boolean;
  /** Darf ein gelöschter Datensatz mit fester ID durch erneutes Anlegen (mit Baserev 0) wieder aufleben? */
  revive?(row: Row): boolean;
  /** Prüfung gegen andere Datensätze (gleiche Konversation, Inhaltsversion) beim Anlegen und nach dem Zusammenführen einer Änderung; false = `invalid`. */
  validate?(env: { tx: Executor; familyId: string; actor: Actor; /** Serveruhr der Op */ now?: Date; flags?: EngineFlags }, row: Row): Promise<boolean>;
  /** Felder, die beim Wiederbeleben einer gelöschten Zeile mit fester ID NICHT neu gesetzt werden (z. B. die Hülle `encVersion` eines Chats). */
  reviveKeep?: readonly string[];
  /** Spalte mit der Person, der der Datensatz gehört (Empfänger): der Verlauf für neu Aufgenommene wird schon in der Abfrage darauf beschränkt, damit fremde Zeilen die eigenen nicht verdrängen. */
  ownerColumn?: string;
  /** Obergrenze lebender Datensätze je Elternteil UND anlegender Person (`field` = Spalte mit der Person): ein Teilnehmer kann das Limit der Konversation nicht allein verbrauchen. */
  ownerPerParent?: { field: string; max: number };
  /** Personen, die durch diese Änderung die Sicht auf den Datensatz GEWINNEN; sie bekommen den bisherigen Inhalt (begrenzt) mit dem Änderungsstrom. */
  gainedSight?(before: Row, after: Row): readonly string[];
  /**
   * Blobs der Dateiablage, die der Datensatz beim ANLEGEN beansprucht (Abschnitt 6n): je Feld die ID des hochgeladenen Blobs (Modus und Art müssen passen). Die Engine
   * beansprucht sie atomar in der Sync-Transaktion (`UPDATE … RETURNING`, files/claim.ts) und lehnt die Op mit `invalid_reference` ab, wenn ein Blob fehlt, fremd oder schon
   * vergeben ist. `derive` setzt vom Server gesetzte Felder (Größe, Typ, Prüfsumme) aus den beanspruchten Blobs. Danach hängt die Leseberechtigung der Blobs an diesem Datensatz.
   */
  claim?: { fields: readonly ClaimField[]; derive?(blobs: ReadonlyMap<string, ClaimedBlob>): Row };
  /** Zusätzliche, asynchrone Sperre für das Löschen (z. B. ein Ordner nur, wenn er leer ist); false = `forbidden`. */
  deleteGuard?(env: { tx: Executor; familyId: string; actor: Actor }, row: Row): Promise<boolean>;
  /** Felder, die nach einer Änderung aus älteren Protokolleinträgen des Datensatzes entfernt werden (ersetzte Inhalte bleiben nicht im Protokoll). */
  scrubOnUpdate?: readonly string[];
  /** Mengenbegrenzung für Änderungen: höchstens `perMinute` Änderungen je Person, die eines der Felder berühren. */
  updateRate?: { fields: readonly string[]; perMinute: number };
  /** Der WebSocket-Hinweis geht nur an den Besitzer (facts.ownerId), nie an andere; verschwundene Zeilen erzeugen keinen Tombstone für Dritte. */
  ownerOnlyNotify?: boolean;
  /** Die Änderung geht als WebSocket-Hinweis an alle, die den Datensatz lesen dürfen, weckt aber nie per Push (Lesestand). */
  noWake?: boolean;
  /** Mengenbegrenzung je Person und Minute: höchstens `perMinute` neue Datensätze, deren `field` (Spalte mit der Person) die Person ist; `createdAt` zählt. */
  rate?: { field: string; perMinute: number; perHour?: number; /** zählt Anlegen UND Wiederbeleben über das Änderungsprotokoll (created, Autor) statt über die Zeilen der Tabelle (eine wiederbelebte Zeile zählte sonst nur einmal) */ viaLog?: boolean; bytes?: { field: string; perHour: number; perDay: number } };
  /**
   * Spalte mit einer Liste von Mitglieds-IDs, die den Datensatz sichtbar machen (Teilnehmer). Verlässt eine Person die Familie, wird sie aus der Liste
   * entfernt; bleiben weniger als `keepMin(row)` übrig, wird der Datensatz gelöscht (Tombstone).
   */
  memberArray?: { field: string; keepMin(row: Row): number };
  /** Personen, die durch diese Änderung die Sicht auf den Datensatz verlieren; nur sie bekommen den `hidden`-Tombstone (nie Unbeteiligte). */
  lostSight?(before: Row, after: Row): readonly string[];
}

/** Spalten, die jede synchronisierte Tabelle hat (siehe syncColumns in db/schema.ts). */
export interface SyncColumns {
  id: AnyPgColumn;
  familyId: AnyPgColumn;
  rev: AnyPgColumn;
  fieldRevs: AnyPgColumn;
  updatedAt: AnyPgColumn;
  deletedAt: AnyPgColumn;
}

export function syncColumns(def: EntityDef): SyncColumns {
  return getTableColumns(def.table) as unknown as SyncColumns;
}

export function columnOf(def: EntityDef, field: string): AnyPgColumn {
  const col = (getTableColumns(def.table) as Record<string, AnyPgColumn | undefined>)[field];
  if (!col) throw new Error(`Spalte fehlt: ${def.name}.${field}`);
  return col;
}

export class Registry {
  private readonly byName = new Map<string, EntityDef>();

  constructor(defs: readonly EntityDef[]) {
    for (const d of defs) {
      if (this.byName.has(d.name)) throw new Error(`Entität doppelt: ${d.name}`);
      this.byName.set(d.name, d);
    }
    for (const d of defs) {
      if (d.parent && !this.byName.has(d.parent.entity)) throw new Error(`Übergeordnete Entität fehlt: ${d.parent.entity}`);
    }
  }

  get(name: string): EntityDef | undefined {
    return this.byName.get(name);
  }

  list(): EntityDef[] {
    return [...this.byName.values()];
  }

  /** Untergeordnete Entitäten (die auf `parent` verweisen). */
  childrenOf(parent: string): EntityDef[] {
    return this.list().filter((d) => d.parent?.entity === parent);
  }

  /** Eltern vor Kindern (für Auflösung von Rechten). */
  parentOf(def: EntityDef): EntityDef | undefined {
    return def.parent ? this.byName.get(def.parent.entity) : undefined;
  }
}
