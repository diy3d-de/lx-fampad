// Sicherheitsereignisse einer Person (sichtbar in ihrem Profil, `GET /me/security-events`) und der Push-Wecker dazu (ohne Inhalt).
// Gemeinsam genutzt von Passwort-Reset, Schlüsselverwaltung (Wechsel, Abruf und Ersetzen von Sicherungen, Übertragung), Anmeldung per Wiederherstellungscode
// und dem Komplett-Reset (Hinweis an die Familie). Nur anhängend; ohne Inhalte, ohne Schlüsselmaterial, ohne IP.
import { and, desc, eq, gt, inArray, isNull, ne, notInArray } from 'drizzle-orm';
import { devices, memberships, pushEndpoints, securityEvents, users } from '../db/schema.js';
import type { AuthContext, Executor } from './context.js';
import type { SessionPrincipal } from './types.js';

/** Feste Codes der Ereignisse (die App ordnet ihnen Texte zu; neue Werte kommen nur additiv hinzu). */
export type SecurityEventKind =
  | 'password_reset_requested'
  | 'password_reset_done'
  | 'account_reset_requested'
  /** Der Personenschlüssel wurde gewechselt. */
  | 'key_rotated'
  /** Die Wiederherstellungssicherung wurde durch eine ANDERE ersetzt (die bisherige liegt im Archiv). */
  | 'key_backup_replaced'
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
  | 'member_account_reset'
  /** Die Passkey-Sicherung wurde abgerufen. */
  | 'key_backup_prf_read'
  /** Eine Passkey-Sicherung wurde angelegt und bestätigt. */
  | 'key_backup_prf_set'
  /** Eltern-Wiederherstellung (Kinder): Hinterlegung angelegt bzw. zurückgenommen. */
  | 'guardian_escrow_set'
  | 'guardian_escrow_removed'
  /** Eine Anfrage zur Wiederherstellung wurde gestellt (Hinweis ans Kind) bzw. wartet auf ein Elternteil (Hinweis an die Eltern, `subjectName` = Kind). */
  | 'guardian_recovery_requested'
  | 'guardian_recovery_asked'
  /** Ein Elternteil hat die Anfrage übernommen (Hinweis ans Kind: jetzt den flüchtigen Schlüssel offenlegen und den Kurzcode nennen). */
  | 'guardian_recovery_challenged'
  /** Ein Elternteil hat freigegeben (Hinweis ans Kind) bzw. die Anfrage endete (abgebrochen, abgelehnt, abgelaufen). */
  | 'guardian_recovery_released'
  | 'guardian_recovery_ended';
export type SecurityEventVia = 'admin' | 'recovery_code' | 'passkey' | 'password';

/**
 * Kritische Arten: werden immer geschrieben, nie entprellt, geweckt ohne Wartezeit und in der Ereignisliste nie von häufigen Lese-Ereignissen verdrängt.
 * Alles andere (Lese-Ereignisse, Übertragung) ist "leicht": je Art und Person höchstens alle 10 Minuten ein Ereignis, höchstens alle 60 Sekunden ein Wecker.
 */
export const CRITICAL_KINDS: readonly SecurityEventKind[] = [
  'password_reset_requested',
  'password_reset_done',
  'account_reset_requested',
  'key_rotated',
  'key_backup_replaced',
  'recovery_code_login',
  'member_account_reset',
  'guardian_escrow_set',
  'guardian_escrow_removed',
  'guardian_recovery_requested',
  'guardian_recovery_asked',
  'guardian_recovery_challenged',
  'guardian_recovery_released',
  'guardian_recovery_ended',
];
const READ_DEBOUNCE_MS = 10 * 60_000;
const WAKE_DEBOUNCE_MS = 60_000;
/** Obergrenze der Ereignisliste: bis zu 100 kritische (immer) plus die letzten 50 leichten. */
const LIST_CRITICAL_LIMIT = 100;
const LIST_OTHER_LIMIT = 50;

/** Auf welchem Weg die Sitzung entstanden ist, aus der eine Aktion kommt (für `via` der Ereignisse). */
export function viaOf(p: Pick<SessionPrincipal, 'authMethod' | 'origin'>): SecurityEventVia {
  if (p.origin === 'recovery_code' || p.authMethod === 'recovery') return 'recovery_code';
  return p.authMethod === 'passkey' ? 'passkey' : 'password';
}

/**
 * Push-Themen der aktiven Geräte einer Person. VOR dem Widerruf der Geräte lesen: der Widerruf löscht die Endpunkte.
 * `exceptDeviceId`: das auslösende Gerät wird nicht geweckt (es weiß es ja).
 */
export async function wakeTopics(exec: Executor, userId: string, exceptDeviceId?: string | null): Promise<string[]> {
  const rows = await exec
    .select({ topic: pushEndpoints.topic })
    .from(pushEndpoints)
    .innerJoin(devices, and(eq(devices.familyId, pushEndpoints.familyId), eq(devices.id, pushEndpoints.deviceId)))
    .where(and(eq(devices.userId, userId), isNull(devices.revokedAt), isNull(pushEndpoints.disabledAt), exceptDeviceId ? ne(devices.id, exceptDeviceId) : undefined));
  return rows.map((r) => r.topic);
}

/** Push-Themen mehrerer Personen in EINER Abfrage (Hinweis an die Familie), je Person gruppiert. */
export async function wakeTopicsFor(exec: Executor, userIds: readonly string[]): Promise<Map<string, string[]>> {
  const out = new Map<string, string[]>();
  if (userIds.length === 0) return out;
  const rows = await exec
    .select({ userId: devices.userId, topic: pushEndpoints.topic })
    .from(pushEndpoints)
    .innerJoin(devices, and(eq(devices.familyId, pushEndpoints.familyId), eq(devices.id, pushEndpoints.deviceId)))
    .where(and(inArray(devices.userId, [...userIds]), isNull(devices.revokedAt), isNull(pushEndpoints.disabledAt)));
  for (const r of rows) out.set(r.userId, [...(out.get(r.userId) ?? []), r.topic]);
  return out;
}

/** Sicherheitsereignis für die betroffene Person (sichtbar in ihrem Profil). Ohne Inhalt, ohne IP. */
export async function recordSecurityEvent(
  ctx: Pick<AuthContext, 'now'>,
  exec: Executor,
  e: { familyId: string; userId: string; kind: SecurityEventKind; via: SecurityEventVia; actorId: string | null; subjectId?: string | null },
): Promise<void> {
  await exec.insert(securityEvents).values({ familyId: e.familyId, userId: e.userId, kind: e.kind, via: e.via, actorId: e.actorId, subjectId: e.subjectId ?? null, createdAt: ctx.now() });
}

/**
 * Wie [recordSecurityEvent], aber für häufige Lese-Ereignisse: je Art und Person höchstens ein Ereignis in 10 Minuten. Gibt zurück, ob eines geschrieben wurde
 * (nur dann wird geweckt). Parallele Abrufe können im ersten Augenblick beide schreiben: harmlos (zwei Zeilen statt einer).
 */
export async function recordDebouncedEvent(
  ctx: Pick<AuthContext, 'now'>,
  exec: Executor,
  e: { familyId: string; userId: string; kind: SecurityEventKind; via: SecurityEventVia; actorId: string | null },
): Promise<boolean> {
  const cutoff = new Date(ctx.now().getTime() - READ_DEBOUNCE_MS);
  const [recent] = await exec
    .select({ id: securityEvents.id })
    .from(securityEvents)
    .where(and(eq(securityEvents.userId, e.userId), eq(securityEvents.kind, e.kind), gt(securityEvents.createdAt, cutoff)))
    .limit(1);
  if (recent) return false;
  await recordSecurityEvent(ctx, exec, e);
  return true;
}

const lastLightWake = new WeakMap<object, Map<string, number>>();

/**
 * Weckt die Geräte der Person nach dem Commit (Push ohne Inhalt); ein Fehler des Hakens darf den Vorgang nie scheitern lassen.
 * `light: true` (Lese-Ereignisse): höchstens ein Wecker je Person in 60 Sekunden; kritische Ereignisse wecken immer.
 */
export function wakeAfterCommit(ctx: AuthContext, familyId: string, userId: string, topics: readonly string[], opts: { light?: boolean } = {}): void {
  if (topics.length === 0) return;
  try {
    if (opts.light) {
      let m = lastLightWake.get(ctx);
      if (!m) lastLightWake.set(ctx, (m = new Map()));
      const now = ctx.now().getTime();
      const last = m.get(userId);
      if (last !== undefined && now >= last && now - last < WAKE_DEBOUNCE_MS) return;
      m.set(userId, now);
      if (m.size > 1000) m.clear();
    }
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
  /** Kennung der betroffenen Person (nur `member_account_reset`, nur Mitglieder der eigenen Familie, sonst null): damit gleicht die App ohne den Anzeigenamen ab. */
  subjectId: string | null;
  createdAt: Date;
}

/**
 * Eigene Sicherheitsereignisse, neueste zuerst. Die kritischen Arten (bis zu 100) kommen immer, getrennt abgefragt: häufige Lese-Ereignisse verdrängen sie nie;
 * dazu die letzten 50 übrigen. Nur die eigenen: fremde Personen gibt es hier nicht.
 */
export async function listSecurityEvents(ctx: AuthContext, p: SessionPrincipal): Promise<SecurityEventView[]> {
  const base = () =>
    ctx.db
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
      .leftJoin(users, eq(users.id, securityEvents.actorId));
  const own = and(eq(securityEvents.userId, p.userId), eq(securityEvents.familyId, p.familyId));
  const critical = await base()
    .where(and(own, inArray(securityEvents.kind, [...CRITICAL_KINDS])))
    .orderBy(desc(securityEvents.createdAt))
    .limit(LIST_CRITICAL_LIMIT);
  const other = await base()
    .where(and(own, notInArray(securityEvents.kind, [...CRITICAL_KINDS])))
    .orderBy(desc(securityEvents.createdAt))
    .limit(LIST_OTHER_LIMIT);
  const rows = [...critical, ...other].sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  // Namen der betroffenen Personen (Hinweise an die Familie) in einer zweiten Abfrage: ein Join auf dieselbe Tabelle bräuchte einen Alias
  const subjectIds = [...new Set(rows.map((r) => r.subjectId).filter((s): s is string => !!s && s !== p.userId))];
  const names = new Map<string, string>();
  if (subjectIds.length > 0) {
    // nur Mitglieder der EIGENEN Familie: Name und Kennung fremder Konten gibt es hier nie
    const us = await ctx.db
      .select({ id: users.id, name: users.displayName })
      .from(users)
      .innerJoin(memberships, and(eq(memberships.userId, users.id), eq(memberships.familyId, p.familyId)))
      .where(inArray(users.id, subjectIds));
    for (const u of us) names.set(u.id, u.name);
  }
  return rows.map((r) => ({
    id: r.id,
    kind: r.kind as SecurityEventKind,
    via: r.via as SecurityEventVia,
    actorName: r.actorId && r.actorId !== p.userId ? (r.actorName ?? null) : null,
    byAdmin: r.via === 'admin',
    subjectName: r.subjectId && r.subjectId !== p.userId ? (names.get(r.subjectId) ?? null) : null,
    subjectId: r.subjectId && r.subjectId !== p.userId && names.has(r.subjectId) ? r.subjectId : null,
    createdAt: r.createdAt,
  }));
}
