// Zentrales Rechte-Modell des Sync (gilt für alle Entitäten, siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6).
//
// Jede Entität liefert zu jedem Datensatz "Fakten" (Freigabe-Stufe und Besitzer) und eine Regeltabelle je Rolle. Alles Weitere
// (Lesen im Änderungsstrom, Anlegen, Ändern, Löschen, erlaubte Felder und Werte) entscheidet diese Datei; kein Fachcode vergleicht Rollen selbst.
//
// Grundsätze:
//  - Was eine Rolle nicht lesen darf, gibt es für sie nicht: Ändern/Löschen eines nicht lesbaren Datensatzes antwortet `not_found`
//    (nie `forbidden`, sonst ließe sich die Existenz erraten), auch bei einer fremden Familie (die Abfragen sind an die Familie gebunden).
//  - Rechte hängen an der Rolle der Sitzung (nie an Angaben des Clients).
//  - Gäste sehen nur ausdrücklich freigegebene Datensätze (Stufe `all`); Kinder sehen Stufe `family` und `all`, aber nichts, was
//    nur für Eltern gedacht ist; Eltern und Admins sehen alles.
import type { Role } from '../auth/types.js';

/** Wer einen Datensatz sehen darf: nur Eltern/Admins, die Familie ohne Gäste, oder alle einschließlich Gäste ("freigegeben"). */
export type Audience = 'parents' | 'family' | 'all';
export const AUDIENCES: readonly Audience[] = ['parents', 'family', 'all'];

export type Action = 'read' | 'create' | 'update' | 'delete';

/**
 * Geltungsbereich einer Regel:
 *  - `none`: nie,
 *  - `all`: jeder Datensatz,
 *  - `shared`: Datensätze, die für die Rolle freigegeben sind (Stufe passt),
 *  - `own`: Datensätze, deren Besitzer die Person ist.
 */
export type Scope = 'none' | 'all' | 'shared' | 'own';

export interface Actor {
  userId: string;
  role: Role;
}

/** Was die Rechteprüfung über einen Datensatz wissen muss (bei untergeordneten Datensätzen von der übergeordneten Entität geerbt). */
export interface Facts {
  audience: Audience;
  ownerId: string | null;
}

export interface RoleRule {
  read: Scope;
  create: Scope;
  update: Scope;
  delete: Scope;
  /** Felder, die die Rolle beim Anlegen setzen darf (fehlt: alle vom Client beschreibbaren Felder). */
  createFields?: readonly string[];
  /** Felder, die die Rolle ändern darf (fehlt: alle vom Client beschreibbaren Felder). */
  updateFields?: readonly string[];
  /** Erlaubte Werte je Feld, z. B. Kinder: `audience` nur `family`. Gilt beim Anlegen und Ändern. */
  limits?: Readonly<Record<string, readonly unknown[]>>;
}

export type Rules = Readonly<Record<Role, RoleRule>>;

export const ROLES: readonly Role[] = ['admin', 'parent', 'child', 'guest'];

/** Rollen, die eine Freigabe-Stufe sehen. */
export const AUDIENCE_ROLES: Readonly<Record<Audience, readonly Role[]>> = {
  parents: ['admin', 'parent'],
  family: ['admin', 'parent', 'child'],
  all: ['admin', 'parent', 'child', 'guest'],
};

export const sees = (role: Role, audience: Audience): boolean => AUDIENCE_ROLES[audience].includes(role);

export function scopeAllows(scope: Scope, actor: Actor, facts: Facts): boolean {
  switch (scope) {
    case 'all':
      return true;
    case 'shared':
      return sees(actor.role, facts.audience);
    case 'own':
      return facts.ownerId !== null && facts.ownerId === actor.userId;
    case 'none':
      return false;
  }
}

/** Darf die Person den Datensatz lesen (im Änderungsstrom, als Ziel einer Änderung)? */
export function mayRead(rules: Rules, actor: Actor, facts: Facts): boolean {
  return scopeAllows(rules[actor.role].read, actor, facts);
}

export type Decision = 'ok' | 'forbidden' | 'not_found';

/**
 * Entscheidet über eine Aktion. `fields` sind die Feldnamen der Op, `values` die (bereits geprüften) Werte.
 * Ändern und Löschen setzen Lesen voraus (sonst `not_found`); Anlegen prüft die Fakten des künftigen Datensatzes.
 */
export function authorize(
  rules: Rules,
  action: Exclude<Action, 'read'>,
  actor: Actor,
  facts: Facts,
  fields: readonly string[] = [],
  values: Readonly<Record<string, unknown>> = {},
): Decision {
  const rule = rules[actor.role];
  if (action !== 'create' && !scopeAllows(rule.read, actor, facts)) return 'not_found';
  if (!scopeAllows(rule[action], actor, facts)) return 'forbidden';
  const allowed = action === 'create' ? rule.createFields : action === 'update' ? rule.updateFields : undefined;
  if (allowed && fields.some((f) => !allowed.includes(f))) return 'forbidden';
  if (action !== 'delete' && rule.limits) {
    for (const [field, permitted] of Object.entries(rule.limits)) {
      if (field in values && !permitted.includes(values[field])) return 'forbidden';
    }
  }
  return 'ok';
}
