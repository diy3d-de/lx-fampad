// Entitäten-Register des Sync: Jede synchronisierte Tabelle meldet sich hier mit Feldern, Rechten und Beziehungen an.
// Engine, Änderungsstrom, Löschen/Kaskaden, Aufräumen und das Bereinigen von Mitglieds-Verweisen arbeiten nur über diese
// Beschreibung. Eine neue Entität (Termine, Aufgaben, ...) braucht eine Tabelle mit Sync-Spalten und einen Eintrag hier, keinen Umbau.
import type { AnyPgColumn, AnyPgTable } from 'drizzle-orm/pg-core';
import { getTableColumns } from 'drizzle-orm';
import type { z } from 'zod';
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
  /** Das Feld enthält eine Mitglieds-ID (`users.id`): sie muss zu einem aktiven Mitglied DER Familie gehören. */
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
  /** Fakten (Freigabe-Stufe, Besitzer) eines vorhandenen Datensatzes; `parent` sind die Fakten der übergeordneten Entität. */
  facts(row: Row, parent: Facts | null): Facts;
  /** Fakten eines Datensatzes, der angelegt werden soll. */
  factsForCreate(actor: Actor, values: Row, parent: Facts | null): Facts;
  /** Vom Server gesetzte Werte beim Anlegen (z. B. Besitzer = anlegende Person). */
  onCreate?(actor: Actor): Row;
  /** Prüft den Datensatz als Ganzes (Felder untereinander, z. B. Ende nach Beginn) beim Anlegen und nach dem Zusammenführen einer Änderung; false = `invalid`. */
  check?(row: Row): boolean;
  /** Obergrenzen lebender Datensätze (Schutz vor Überlauf). `per: 'parent'` zählt je übergeordnetem Datensatz. */
  maxLive?: { per: 'family' | 'parent'; max: number };
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
