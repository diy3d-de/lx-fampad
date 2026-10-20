// Zentrales Rechte-Modell des Sync (gilt für alle Entitäten, siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6).
//
// Jede Entität liefert zu jedem Datensatz "Fakten" (Freigabe-Stufe und Besitzer) und eine Regeltabelle je Rolle. Alles Weitere
// (Lesen im Änderungsstrom, Anlegen, Ändern, Löschen, erlaubte Felder und Werte) entscheidet diese Datei; kein Fachcode vergleicht Rollen selbst.
//
// Grundsätze:
//  - Was eine Rolle nicht lesen darf, gibt es für sie nicht: Ändern/Löschen eines nicht lesbaren Datensatzes antwortet `not_found`
//    (nie `forbidden`, sonst ließe sich die Existenz erraten), auch bei einer fremden Familie (die Abfragen sind an die Familie gebunden).
//  - Rechte hängen an der Rolle der Sitzung (nie an Angaben des Clients).
//  - Kinder sehen Stufe `family`, aber nichts, was nur für Eltern gedacht ist; Eltern und Admins sehen alles. Gäste gibt es nicht.
//  - Teilnehmer-Sichtbarkeit (Chat): Nennen die Fakten `participants`, sieht den Datensatz NUR, wer dort steht. Das ist eine harte Grenze vor jeder
//    Regel : kein Rollen-Durchgriff, Admins und Eltern sehen private Chats nicht. Ohne `participants` gilt die Freigabe-Stufe.
import type { Role } from '../auth/types.js';

/** Wer einen Datensatz sehen darf: nur Eltern/Admins oder die ganze Familie. */
export type Audience = 'parents' | 'family';
export const AUDIENCES: readonly Audience[] = ['parents', 'family'];

export type Action = 'read' | 'create' | 'update' | 'delete';

/**
 * Geltungsbereich einer Regel:
 *  - `none`: nie,
 *  - `all`: jeder Datensatz,
 *  - `shared`: Datensätze, die für die Rolle freigegeben sind (Stufe passt),
 *  - `own`: Datensätze, deren Besitzer die Person ist,
 *  - `own_or_open`: eigene Datensätze, und alle, die nicht auf Teilnehmer beschränkt sind (Admin darf im Familienchat fremde Nachrichten löschen,
 *    nie in privaten Chats).
 * Jeder Bereich außer `none` gilt nur innerhalb der Teilnehmer-Grenze (siehe oben).
 */
export type Scope = 'none' | 'all' | 'shared' | 'own' | 'own_or_open';

export interface Actor {
  userId: string;
  role: Role;
}

/** Was die Rechteprüfung über einen Datensatz wissen muss (bei untergeordneten Datensätzen von der übergeordneten Entität geerbt). */
export interface Facts {
  audience: Audience;
  ownerId: string | null;
  /** Zuständige Person (Aufgaben; Unteraufgaben erben sie): darf mit `assignedFields` auch fremde Datensätze in diesen Feldern ändern. */
  assigneeId?: string | null;
  /** Nur diese Personen sehen den Datensatz (Direkt-/Gruppenchat und alles darunter); fehlt: es gilt `audience` (Familienchat). */
  participants?: readonly string[] | undefined;
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
  /** Felder, die die Rolle an Datensätzen ändern darf, deren zuständige Person (`facts.assigneeId`) sie ist, auch wenn `update` sonst nicht gilt (z. B. Kinder: Erledigt-Status). Nur diese Felder, nichts sonst. */
  assignedFields?: readonly string[];
  /** Erlaubte Werte je Feld, z. B. Kinder: `audience` nur `family`. Gilt beim Anlegen und Ändern. */
  limits?: Readonly<Record<string, readonly unknown[]>>;
}

export type Rules = Readonly<Record<Role, RoleRule>>;

export const ROLES: readonly Role[] = ['admin', 'parent', 'child'];

/** Rollen, die eine Freigabe-Stufe sehen. */
export const AUDIENCE_ROLES: Readonly<Record<Audience, readonly Role[]>> = {
  parents: ['admin', 'parent'],
  family: ['admin', 'parent', 'child'],
};

export const sees = (role: Role, audience: Audience): boolean => AUDIENCE_ROLES[audience].includes(role);

/** Steht die Person in der Teilnehmerliste (oder gibt es keine)? */
export const isParticipant = (actor: Actor, facts: Facts): boolean => facts.participants === undefined || facts.participants.includes(actor.userId);

export function scopeAllows(scope: Scope, actor: Actor, facts: Facts): boolean {
  if (!isParticipant(actor, facts)) return false;
  switch (scope) {
    case 'all':
      return true;
    case 'shared':
      return sees(actor.role, facts.audience);
    case 'own':
      return facts.ownerId !== null && facts.ownerId === actor.userId;
    case 'own_or_open':
      return sees(actor.role, facts.audience) && (facts.participants === undefined || (facts.ownerId !== null && facts.ownerId === actor.userId));
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
  const scoped = scopeAllows(rule[action], actor, facts);
  // zuständige Person: nur die freigegebenen Felder (assignedFields), nie Anlegen/Löschen
  const assigned =
    !scoped &&
    action === 'update' &&
    rule.assignedFields !== undefined &&
    facts.assigneeId !== undefined &&
    facts.assigneeId !== null &&
    facts.assigneeId === actor.userId &&
    fields.length > 0 &&
    fields.every((f) => rule.assignedFields?.includes(f));
  if (!scoped && !assigned) return 'forbidden';
  const allowed = assigned ? undefined : action === 'create' ? rule.createFields : action === 'update' ? rule.updateFields : undefined;
  if (allowed && fields.some((f) => !allowed.includes(f))) return 'forbidden';
  if (action !== 'delete' && rule.limits) {
    for (const [field, permitted] of Object.entries(rule.limits)) {
      if (field in values && !permitted.includes(values[field])) return 'forbidden';
    }
  }
  return 'ok';
}

/**
 * Rollen, die einen Datensatz mit diesen Fakten möglicherweise lesen (für die Benachrichtigung per WebSocket; im Zweifel großzügig:
 * Regeln mit Geltungsbereich `own` zählen als lesbar). Wer den Datensatz nicht sehen darf, erfährt nicht einmal, dass es eine Änderung gab.
 */
export function rolesThatMayRead(rules: Rules, facts: Facts): Role[] {
  if (facts.participants !== undefined) return []; // Teilnehmer-Sichtbarkeit: nie über Rollen, siehe usersThatMayRead
  return ROLES.filter((role) => {
    const scope = rules[role].read;
    return scope === 'all' || scope === 'own' || (scope === 'shared' && sees(role, facts.audience));
  });
}

/**
 * Personen unter `members` (aktive Mitglieder der Familie mit Rolle), die den Datensatz lesen dürfen: je Person über `mayRead` gefiltert, also für Privatchats
 * nur Teilnehmer (nie über die Rolle) und für den Familienchat ausdrücklich alle Mitglieder mit Sicht. Grundlage für gezielte Benachrichtigungen (Push).
 */
export function usersThatMayRead(rules: Rules, facts: Facts, members: readonly Actor[]): string[] {
  return members.filter((m) => mayRead(rules, m, facts)).map((m) => m.userId);
}

/**
 * Standort teilen (flüchtiger Kanal, kein Sync): Wer darf einem Mitglied die eigene Position schicken?
 *
 * Die Freigabe geht immer von der Person selbst aus (nie angefordert oder eingeschaltet von anderen); sie wählt die Empfänger. Eine Rolle
 * schränkt weder Senden noch Empfangen ein (auch Kinder wählen selbst; "an Eltern" ist nur die Voreinstellung der App). Es zählen nur
 * **aktive Mitglieder der eigenen Familie** (`members` kommt vom Server, nie vom Client), nie die Person selbst. Alles andere wird abgelehnt.
 */
export function locationRecipients(sender: Actor, members: readonly Actor[], chosen: readonly string[]): { allowed: string[]; rejected: string[] } {
  const active = new Set(members.map((m) => m.userId));
  const allowed: string[] = [];
  const rejected: string[] = [];
  for (const id of new Set(chosen)) (id !== sender.userId && active.has(id) ? allowed : rejected).push(id);
  return { allowed, rejected };
}
