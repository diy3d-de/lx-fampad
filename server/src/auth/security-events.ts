// Sicherheitsereignisse einer Person (sichtbar in ihrem Profil, `GET /me/security-events`) und der Push-Wecker dazu (ohne Inhalt).
// Gemeinsam genutzt von Passwort-Reset, Schlüsselverwaltung (Wechsel, Abruf von Sicherungen, Übertragung), Anmeldung per Wiederherstellungscode
// und dem Komplett-Reset (Hinweis an die Familie). Nur anhängend; ohne Inhalte, ohne Schlüsselmaterial, ohne IP.
import { and, desc, eq, isNull } from 'drizzle-orm';
import { devices, pushEndpoints, securityEvents, users } from '../db/schema.js';
import type { AuthContext, Executor } from './context.js';
import type { SessionPrincipal } from './types.js';

/** Feste Codes der Ereignisse (die App ordnet ihnen Texte zu; neue Werte kommen nur additiv hinzu). */
export type SecurityEventKind =
  | 'password_reset_requested'
  | 'password_reset_done'
  | 'account_reset_requested'
  /** Der Personenschlüssel wurde gewechselt. */
  | 'key_rotated'
  /** Die Wiederherstellungssicherung wurde abgerufen. */
  | 'key_backup_read'
  /** Die Passwort-Sicherung wurde abgerufen. */
  | 'key_backup_pw_read'
  /** Eine archivierte Sicherung (alter Schlüsselstand) wurde abgerufen. */
  | 'key_backup_archive_read'
  /** Anmeldung mit einem Wiederherstellungscode (statt Passkey bzw. TOTP). */
  | 'recovery_code_login'
  /** Eine Geräte-Übertragung des Schlüssels wurde angelegt bzw. eingelöst. */
  | 'key_transfer_created'
  | 'key_transfer_claimed'
  /** Hinweis an die Familie: der Zugang eines Mitglieds wurde komplett zurückgesetzt (`subjectName` = wessen). */
  | 'member_account_reset';
export type SecurityEventVia = 'admin' | 'recovery_code' | 'passkey' | 'password';

/** Auf welchem Weg die Sitzung entstanden ist, aus der eine Aktion kommt (für `via` der Ereignisse). */
export function viaOf(p: Pick<SessionPrincipal, 'authMethod' | 'origin'>): SecurityEventVia {
  if (p.origin === 'recovery_code' || p.authMethod === 'recovery') return 'recovery_code';
  return p.authMethod === 'passkey' ? 'passkey' : 'password';
}

/** Push-Themen der aktiven Geräte einer Person. VOR dem Widerruf der Geräte lesen: der Widerruf löscht die Endpunkte. */
export async function wakeTopics(exec: Executor, userId: string): Promise<string[]> {
  const rows = await exec
    .select({ topic: pushEndpoints.topic })
    .from(pushEndpoints)
    .innerJoin(devices, and(eq(devices.familyId, pushEndpoints.familyId), eq(devices.id, pushEndpoints.deviceId)))
    .where(and(eq(devices.userId, userId), isNull(devices.revokedAt), isNull(pushEndpoints.disabledAt)));
  return rows.map((r) => r.topic);
}

/** Sicherheitsereignis für die betroffene Person (sichtbar in ihrem Profil). Ohne Inhalt, ohne IP. */
export async function recordSecurityEvent(
  ctx: Pick<AuthContext, 'now'>,
  exec: Executor,
  e: { familyId: string; userId: string; kind: SecurityEventKind; via: SecurityEventVia; actorId: string | null; subjectId?: string | null },
): Promise<void> {
  await exec.insert(securityEvents).values({ familyId: e.familyId, userId: e.userId, kind: e.kind, via: e.via, actorId: e.actorId, subjectId: e.subjectId ?? null, createdAt: ctx.now() });
}

/** Weckt die Geräte der Person nach dem Commit (Push ohne Inhalt); ein Fehler des Hakens darf den Vorgang nie scheitern lassen. */
export function wakeAfterCommit(ctx: AuthContext, familyId: string, userId: string, topics: readonly string[]): void {
  if (topics.length === 0) return;
  try {
    ctx.onSecurityEvent?.({ familyId, userId, topics });
  } catch (err: unknown) {
    ctx.log.warn({ err: (err as Error).message }, 'Sicherheitshinweis (Push) fehlgeschlagen');
  }
}

export interface SecurityEventView {
  id: string;
  kind: SecurityEventKind;
  via: SecurityEventVia;
  /** Wer es ausgelöst hat (Name aus der Familie); null = die Person selbst (oder die Person ist nicht mehr da). */
  actorName: string | null;
  byAdmin: boolean;
  /** Um wen es geht, wenn nicht um die Person selbst (nur `member_account_reset`); sonst null. */
  subjectName: string | null;
  createdAt: Date;
}

/** Eigene Sicherheitsereignisse, neueste zuerst (höchstens 50). Nur die eigenen: fremde Personen gibt es hier nicht. */
export async function listSecurityEvents(ctx: AuthContext, p: SessionPrincipal): Promise<SecurityEventView[]> {
  const rows = await ctx.db
    .select({
      id: securityEvents.id,
      kind: securityEvents.kind,
      via: securityEvents.via,
      actorId: securityEvents.actorId,
      actorName: users.displayName,
      subjectId: securityEvents.subjectId,
      createdAt: securityEvents.createdAt,
    })
    .from(securityEvents)
    .leftJoin(users, eq(users.id, securityEvents.actorId))
    .where(and(eq(securityEvents.userId, p.userId), eq(securityEvents.familyId, p.familyId)))
    .orderBy(desc(securityEvents.createdAt))
    .limit(50);
  // Namen der betroffenen Personen (Hinweise an die Familie) in einer zweiten Abfrage: ein Join auf dieselbe Tabelle bräuchte einen Alias
  const subjectIds = [...new Set(rows.map((r) => r.subjectId).filter((s): s is string => !!s && s !== p.userId))];
  const names = new Map<string, string>();
  for (const id of subjectIds) {
    const [u] = await ctx.db.select({ name: users.displayName }).from(users).where(eq(users.id, id));
    if (u) names.set(id, u.name);
  }
  return rows.map((r) => ({
    id: r.id,
    kind: r.kind as SecurityEventKind,
    via: r.via as SecurityEventVia,
    actorName: r.actorId && r.actorId !== p.userId ? (r.actorName ?? null) : null,
    byAdmin: r.via === 'admin',
    subjectName: r.subjectId && r.subjectId !== p.userId ? (names.get(r.subjectId) ?? null) : null,
    createdAt: r.createdAt,
  }));
}
