// E2EE, Eltern-Wiederherstellung für Kinder (Schalter E2EE_PARENT_RECOVERY, Standard aus). Der Server speichert nur Undurchsichtiges und Öffentliches: die
// Hinterlegung (Sealed Box der Seeds des Kindes je Elternteil, vom Kind signiert), die Verpflichtung des Kindes auf seinen flüchtigen Schlüssel, die Zufallszahl des Elternteils,
// den später offengelegten flüchtigen öffentlichen Schlüssel und die Übergabe (Sealed Box an diesen Schlüssel, vom Elternteil signiert). Er kennt nie Seeds, nie einen
// geheimen Schlüssel und rechnet nichts davon nach (Blobs erscheinen nie im Log oder Audit). Nur Konten mit Rolle `child`; Erwachsene bekommen die Funktion nie.
//
// Ablauf (Einzelheiten und Bedrohungsüberlegung: Projektbeschreibung 9a):
//   Kind legt eine Hinterlegung an (`setEscrow`) -> später, auf einem neuen Gerät: Anfrage mit Verpflichtung (`createRecovery`, Wartefrist, Hinweise ans Kind und an die Eltern)
//   -> nach der Frist sendet ein Elternteil die Zufallszahl (`challengeRecovery`) -> das Kind legt den flüchtigen Schlüssel offen (`revealRecovery`)
//   -> das Elternteil gibt nach dem Vergleich des Kurzcodes die Übergabe ab (`releaseRecovery`) -> das Kind holt sie ab und bestätigt (`doneRecovery`).
// Abbrechen (Kind, jederzeit) und Ablehnen (Elternteil) sind immer möglich und brauchen kein Step-up (die sichere Richtung).
import { and, eq, inArray, isNull, lt, notInArray, sql } from 'drizzle-orm';
import { guardianEscrows, guardianRecoveries, memberships, personKeys, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Executor, RequestMeta, Tx } from './context.js';
import { recordSecurityEvent, viaOf, wakeAfterCommit, wakeTopics, wakeTopicsFor, type SecurityEventKind } from './security-events.js';
import { requireDestructiveAllowed, requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

const notFound = () => new AppError(404, 'not_found');
const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;
/** Nach der Wartefrist bleibt die Anfrage so lange offen; danach verfällt sie. */
export const RECOVERY_WINDOW_MS = 3 * DAY_MS;
/** Beendete Anfragen (ohne Geheimnisse, nur Zustand und Zeiten) bleiben so lange zur Einsicht liegen. */
const ENDED_RETENTION_MS = 90 * DAY_MS;
/** Ersetzte und zurückgenommene Hinterlegungen bleiben so lange liegen (nie sofort löschen; danach endgültig weg: Löschfrist des Widerrufs). */
export const ESCROW_RETENTION_MS = 30 * DAY_MS;
/** Eine übernommene Anfrage ohne Fortschritt wird nach dieser Zeit wieder frei (nach der Übernahme) bzw. beendet (nach der Offenlegung). */
export const TAKEOVER_TIMEOUT_MS = 12 * HOUR_MS;
/** Eine beendete Anfrage zeigt das Kind nur so lange. */
const ENDED_SHOWN_MS = DAY_MS;
const CURRENT_ESCROW = ['active', 'stale'] as const;
const OPEN_STATES = ['pending', 'challenged', 'revealed', 'released'] as const;
export const MAX_GUARDIANS = 8;

function requireChild(p: SessionPrincipal): void {
  if (p.role !== 'child') throw new AppError(403, 'forbidden', 'Die Eltern-Wiederherstellung gibt es nur für Kinder-Konten.');
}
function requireParent(p: SessionPrincipal): void {
  if (p.role !== 'admin' && p.role !== 'parent') throw new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
}

/** Aktive Eltern-Konten (Rolle admin oder parent, nicht deaktiviert) der Familie mit ihrer Schlüsselversion. */
async function guardianCandidates(exec: Executor, familyId: string, ids?: readonly string[]) {
  return exec
    .select({ id: users.id, displayName: users.displayName, keyVersion: personKeys.keyVersion })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .innerJoin(personKeys, eq(personKeys.userId, users.id))
    .where(
      and(
        eq(memberships.familyId, familyId),
        eq(memberships.status, 'active'),
        inArray(memberships.role, ['admin', 'parent']),
        isNull(users.disabledAt),
        ids ? inArray(users.id, [...ids]) : undefined,
      ),
    );
}

/** Beendet eine offene Anfrage und löscht die Übergabedaten; gibt zurück, ob sich etwas geändert hat. */
async function endRecovery(exec: Executor, id: string, childId: string, to: 'cancelled' | 'declined' | 'expired' | 'done', now: Date): Promise<boolean> {
  const rows = await exec
    .update(guardianRecoveries)
    .set({ state: to, releaseBlob: null, releaseSig: null, revealPub: null, revealNonce: null, challenge: null, updatedAt: now })
    .where(and(eq(guardianRecoveries.id, id), eq(guardianRecoveries.childId, childId), inArray(guardianRecoveries.state, [...OPEN_STATES])))
    .returning({ id: guardianRecoveries.id });
  return rows.length > 0;
}

// ---------------------------------------------------------------- Hinterlegung (Kind)

export interface EscrowEntryInput {
  guardianId: string;
  guardianKeyVersion: number;
  blob: string;
  sig: string;
}

/**
 * Hinterlegung anlegen oder aktualisieren (Step-up, nur Kinder, mit Zustimmung des Kindes: die App des Kindes ruft das nur auf Wunsch). Der Eintrag je Elternteil
 * muss zur AKTUELLEN Schlüsselversion des Kindes und zur aktuellen Schlüsselversion des Elternteils gehören (sonst 409); Eltern, die nicht mehr in der Liste stehen, verlieren
 * ihren Eintrag (die Liste ersetzt die bisherige). Zurücknehmen: [removeEscrow].
 */
export async function setEscrow(ctx: AuthContext, p: SessionPrincipal, input: { keyVersion: number; entries: EscrowEntryInput[] }, meta: RequestMeta): Promise<{ count: number }> {
  requireChild(p);
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  const ids = input.entries.map((e) => e.guardianId);
  if (new Set(ids).size !== ids.length || ids.includes(p.userId) || input.entries.length < 1 || input.entries.length > MAX_GUARDIANS) throw new AppError(400, 'invalid_request');
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  await ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    const cands = new Map((await guardianCandidates(tx, p.familyId, ids)).map((c) => [c.id, c]));
    for (const e of input.entries) {
      const c = cands.get(e.guardianId);
      if (!c) throw new AppError(409, 'guardian_invalid', 'Dieses Elternteil kann nicht hinterlegt werden.');
      if (c.keyVersion !== e.guardianKeyVersion) throw new AppError(409, 'guardian_key_changed', 'Der Schlüssel eines Elternteils hat sich geändert, bitte neu laden.');
    }
    const now = ctx.now();
    // Eltern, die nicht mehr gewählt sind, verlieren ihren Eintrag (Einwilligung enger gefasst): er wird `revoked`, nicht gelöscht (Löschfrist ESCROW_RETENTION_MS)
    await tx
      .update(guardianEscrows)
      .set({ state: 'revoked', updatedAt: now })
      .where(and(eq(guardianEscrows.childId, p.userId), inArray(guardianEscrows.state, [...CURRENT_ESCROW]), notInArray(guardianEscrows.guardianId, ids)));
    for (const e of input.entries) {
      // der bisherige gültige Eintrag wird ersetzt (`superseded`, bleibt liegen), nie überschrieben; die erste Zustimmung bleibt als Zeitpunkt erhalten
      const alt = await tx
        .update(guardianEscrows)
        .set({ state: 'superseded', updatedAt: now })
        .where(and(eq(guardianEscrows.childId, p.userId), eq(guardianEscrows.guardianId, e.guardianId), inArray(guardianEscrows.state, [...CURRENT_ESCROW])))
        .returning({ consentAt: guardianEscrows.consentAt });
      await tx
        .insert(guardianEscrows)
        .values({ familyId: p.familyId, childId: p.userId, guardianId: e.guardianId, keyVersion: k.v, guardianKeyVersion: e.guardianKeyVersion, blob: e.blob, sig: e.sig, state: 'active', consentAt: alt[0]?.consentAt ?? now, createdAt: now, updatedAt: now });
    }
    await writeAudit(ctx, tx, { event: 'guardian_escrow_set', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: k.v, guardians: ids.length } });
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'guardian_escrow_set', via: viaOf(p), actorId: p.userId });
  });
  wakeAfterCommit(ctx, p.familyId, p.userId, topics);
  return { count: input.entries.length };
}

/**
 * Zustimmung zurücknehmen (Step-up, nach einem Reset 24 h gesperrt): die Einträge werden `revoked` und nie wieder angeboten, eine offene Anfrage endet. Die Zeilen bleiben bis zur
 * Löschfrist ESCROW_RETENTION_MS (30 Tage) liegen (nie sofort hart gelöscht) und verschwinden dann mit dem Aufräumjob. Gibt zurück, ob es Einträge gab.
 */
export async function removeEscrow(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<{ removed: boolean }> {
  requireChild(p);
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  const removed = await ctx.db.transaction(async (tx) => {
    const now = ctx.now();
    const rows = await tx
      .update(guardianEscrows)
      .set({ state: 'revoked', updatedAt: now })
      .where(and(eq(guardianEscrows.childId, p.userId), inArray(guardianEscrows.state, [...CURRENT_ESCROW])))
      .returning({ id: guardianEscrows.id });
    await tx
      .update(guardianRecoveries)
      .set({ state: 'cancelled', releaseBlob: null, releaseSig: null, revealPub: null, revealNonce: null, challenge: null, updatedAt: now })
      .where(and(eq(guardianRecoveries.childId, p.userId), inArray(guardianRecoveries.state, [...OPEN_STATES])));
    if (rows.length > 0) {
      await writeAudit(ctx, tx, { event: 'guardian_escrow_removed', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { guardians: rows.length } });
      await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'guardian_escrow_removed', via: viaOf(p), actorId: p.userId });
    }
    return rows.length > 0;
  });
  if (removed) wakeAfterCommit(ctx, p.familyId, p.userId, topics);
  return { removed };
}

export interface EscrowStatus {
  /** Die Person darf die Funktion überhaupt nutzen (Rolle `child`). */
  eligible: boolean;
  enabled: boolean;
  /** Seit wann die Zustimmung besteht (ISO), null ohne Hinterlegung. */
  since: string | null;
  /** Schlüsselversion des Kindes, zu der die Einträge gehören. */
  keyVersion: number | null;
  /** Eltern mit Eintrag; `stale`: Eintrag veraltet (Schlüssel des Kindes oder des Elternteils hat sich geändert), die App bietet „Hinterlegung aktualisieren“ an. */
  guardians: Array<{ id: string; displayName: string; guardianKeyVersion: number; stale: boolean }>;
}

/** Eigener Stand der Hinterlegung (nur Namen, Versionen, Zeiten, nie Blobs). */
export async function getEscrowStatus(ctx: AuthContext, p: SessionPrincipal): Promise<EscrowStatus> {
  if (p.role !== 'child') return { eligible: false, enabled: false, since: null, keyVersion: null, guardians: [] };
  const [k] = await ctx.db.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId));
  const rows = await ctx.db
    .select({
      id: guardianEscrows.guardianId,
      displayName: users.displayName,
      keyVersion: guardianEscrows.keyVersion,
      guardianKeyVersion: guardianEscrows.guardianKeyVersion,
      state: guardianEscrows.state,
      consentAt: guardianEscrows.consentAt,
      currentGuardianKey: personKeys.keyVersion,
    })
    .from(guardianEscrows)
    .innerJoin(users, eq(users.id, guardianEscrows.guardianId))
    .innerJoin(memberships, and(eq(memberships.familyId, guardianEscrows.familyId), eq(memberships.userId, guardianEscrows.guardianId)))
    .leftJoin(personKeys, eq(personKeys.userId, guardianEscrows.guardianId))
    .where(and(eq(guardianEscrows.childId, p.userId), inArray(guardianEscrows.state, [...CURRENT_ESCROW]), isNull(users.disabledAt)));
  const since = rows.reduce<Date | null>((m, r) => (!m || r.consentAt < m ? r.consentAt : m), null);
  return {
    eligible: true,
    enabled: rows.length > 0,
    since: since?.toISOString() ?? null,
    keyVersion: rows[0]?.keyVersion ?? null,
    guardians: rows.map((r) => ({
      id: r.id,
      displayName: r.displayName,
      guardianKeyVersion: r.guardianKeyVersion,
      stale: r.state !== 'active' || r.keyVersion !== (k?.v ?? -1) || r.currentGuardianKey !== r.guardianKeyVersion,
    })),
  };
}

// ---------------------------------------------------------------- Anfrage (Kind)

export interface RecoveryView {
  id: string;
  state: (typeof guardianRecoveries.$inferSelect)['state'];
  keyVersion: number;
  readyAt: string;
  expiresAt: string;
  createdAt: string;
  /** Verpflichtung des Kindes (vom Kind selbst gesendet): die App ordnet damit eine Anfrage zu, deren Antwort verloren ging. */
  commit: string;
  /** Das Elternteil, das die Anfrage bearbeitet (ab `challenged`). */
  guardianId: string | null;
  guardianName: string | null;
  /** Zufallszahl des Elternteils (ab `challenged`), der Kurzcode des Kindes hängt von ihr ab. */
  challenge: string | null;
  /** Übergabe des Elternteils (nur `released`, nur für das Kind). */
  releaseBlob: string | null;
  releaseSig: string | null;
}

/** `geraet`: false = ein anderes Gerät des Kindes als das, das die Anfrage gestellt hat: Zufallszahl und Übergabe bleiben verborgen (nur der Zustand). */
async function viewOf(exec: Executor, r: typeof guardianRecoveries.$inferSelect, geraet = true): Promise<RecoveryView> {
  let guardianName: string | null = null;
  if (r.guardianId) {
    const [g] = await exec.select({ n: users.displayName }).from(users).where(eq(users.id, r.guardianId));
    guardianName = g?.n ?? null;
  }
  return {
    id: r.id,
    state: r.state as RecoveryView['state'],
    keyVersion: r.keyVersion,
    readyAt: r.readyAt.toISOString(),
    expiresAt: r.expiresAt.toISOString(),
    createdAt: r.createdAt.toISOString(),
    commit: r.commit,
    guardianId: r.guardianId,
    guardianName,
    challenge: geraet ? r.challenge : null,
    releaseBlob: geraet ? r.releaseBlob : null,
    releaseSig: geraet ? r.releaseSig : null,
  };
}

/** Hinweise ans Kind (andere Geräte, kritisch) und an die hinterlegten Eltern; alles ohne Inhalt. */
async function noteRecovery(ctx: AuthContext, tx: Tx, p: SessionPrincipal, kindForChild: SecurityEventKind | null, kindForGuardians: SecurityEventKind | null): Promise<Array<{ userId: string; topics: string[] }>> {
  const out: Array<{ userId: string; topics: string[] }> = [];
  if (kindForChild) {
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: kindForChild, via: viaOf(p), actorId: p.userId });
    out.push({ userId: p.userId, topics: await wakeTopics(tx, p.userId, p.deviceId) });
  }
  if (kindForGuardians) {
    const gs = await tx
      .select({ id: guardianEscrows.guardianId })
      .from(guardianEscrows)
      .where(and(eq(guardianEscrows.childId, p.userId), inArray(guardianEscrows.state, [...CURRENT_ESCROW])));
    const ids = gs.map((g) => g.id);
    const topics = await wakeTopicsFor(tx, ids);
    for (const id of ids) {
      await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: id, kind: kindForGuardians, via: viaOf(p), actorId: p.userId, subjectId: p.userId });
      out.push({ userId: id, topics: topics.get(id) ?? [] });
    }
  }
  return out;
}

function wakeAll(ctx: AuthContext, familyId: string, list: Array<{ userId: string; topics: string[] }>): void {
  for (const w of list) wakeAfterCommit(ctx, familyId, w.userId, w.topics);
}

/**
 * Anfrage des Kindes (Step-up, nur Kinder, nur mit Hinterlegung zur aktuellen Schlüsselversion): legt die Verpflichtung ab und startet die Wartefrist
 * (`E2EE_PARENT_RECOVERY_WAIT_HOURS`). Höchstens eine offene Anfrage je Kind (`409 recovery_open`). Hinweis ans Kind (andere Geräte) und an alle hinterlegten Eltern.
 */
export async function createRecovery(ctx: AuthContext, p: SessionPrincipal, input: { commit: string }, meta: RequestMeta): Promise<RecoveryView> {
  requireChild(p);
  // nach einer Anmeldung mit Wiederherstellungscode, einem Passwort-Reset oder einer Änderung der Anmeldedaten 24 h gesperrt: wer ein Kinder-Konto gerade übernommen hat, kann
  // darüber nicht sofort den Schlüssel anfordern (die Hinterlegung ist nach einem Reset ohnehin veraltet)
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  const woken: Array<{ userId: string; topics: string[] }> = [];
  const view = await ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    const now = ctx.now();
    await expireOpen(tx, p.userId, now);
    await releaseStaleTakeovers(tx, now, p.userId);
    const usable = await tx
      .select({ id: guardianEscrows.guardianId })
      .from(guardianEscrows)
      .innerJoin(personKeys, eq(personKeys.userId, guardianEscrows.guardianId))
      .innerJoin(memberships, and(eq(memberships.familyId, guardianEscrows.familyId), eq(memberships.userId, guardianEscrows.guardianId)))
      .where(
        and(
          eq(guardianEscrows.childId, p.userId),
          eq(guardianEscrows.state, 'active'),
          eq(guardianEscrows.keyVersion, k.v),
          eq(memberships.status, 'active'),
          inArray(memberships.role, ['admin', 'parent']),
          sql`${personKeys.keyVersion} = ${guardianEscrows.guardianKeyVersion}`,
        ),
      );
    if (usable.length === 0) throw new AppError(409, 'no_escrow', 'Es gibt keine gültige Hinterlegung bei deinen Eltern.');
    const readyAt = new Date(now.getTime() + ctx.config.parentRecoveryWaitHours * HOUR_MS);
    const rows = await tx
      .insert(guardianRecoveries)
      .values({ familyId: p.familyId, childId: p.userId, state: 'pending', keyVersion: k.v, commit: input.commit, deviceId: p.deviceId, readyAt, expiresAt: new Date(readyAt.getTime() + RECOVERY_WINDOW_MS), createdAt: now, updatedAt: now })
      .onConflictDoNothing()
      .returning();
    const row = rows[0];
    if (!row) throw new AppError(409, 'recovery_open', 'Es läuft schon eine Anfrage.');
    await writeAudit(ctx, tx, { event: 'guardian_recovery_requested', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: k.v, guardians: usable.length } });
    woken.push(...(await noteRecovery(ctx, tx, p, 'guardian_recovery_requested', 'guardian_recovery_asked')));
    return viewOf(tx, row);
  });
  wakeAll(ctx, p.familyId, woken);
  return view;
}

/** Offene Anfragen eines Kindes, deren Frist abgelaufen ist, enden (`expired`). */
async function expireOpen(exec: Executor, childId: string, now: Date): Promise<void> {
  await exec
    .update(guardianRecoveries)
    .set({ state: 'expired', releaseBlob: null, releaseSig: null, revealPub: null, revealNonce: null, challenge: null, updatedAt: now })
    .where(and(eq(guardianRecoveries.childId, childId), inArray(guardianRecoveries.state, [...OPEN_STATES]), lt(guardianRecoveries.expiresAt, now)));
}

/**
 * Stand der eigenen Anfrage (die offene, sonst die zuletzt beendete der letzten 24 Stunden); null, wenn es keine gibt. Nur Kinder. Zufallszahl und Übergabe sieht nur das
 * Gerät, das die Anfrage gestellt hat; andere Geräte des Kindes sehen den Zustand (und können abbrechen).
 */
export async function getMyRecovery(ctx: AuthContext, p: SessionPrincipal): Promise<RecoveryView | null> {
  requireChild(p);
  const now = ctx.now();
  await expireOpen(ctx.db, p.userId, now);
  await releaseStaleTakeovers(ctx.db, now, p.userId);
  const rows = await ctx.db
    .select()
    .from(guardianRecoveries)
    .where(and(eq(guardianRecoveries.childId, p.userId)))
    .orderBy(sql`${guardianRecoveries.createdAt} desc`)
    .limit(1);
  const r = rows[0];
  if (!r) return null;
  if (!(OPEN_STATES as readonly string[]).includes(r.state) && now.getTime() - r.updatedAt.getTime() > ENDED_SHOWN_MS) return null;
  return viewOf(ctx.db, r, sameDevice(r.deviceId, p.deviceId));
}

/** Gehört die Anfrage zu diesem Gerät? (Ohne Gerätekennung in beiden Fällen ja.) */
const sameDevice = (anfrage: string | null, gerät: string | null): boolean => (anfrage ?? null) === (gerät ?? null);

/** Das Kind legt den flüchtigen öffentlichen Schlüssel und die Nonce offen (nur im Zustand `challenged`, nur für die eigene Anfrage). */
export async function revealRecovery(ctx: AuthContext, p: SessionPrincipal, id: string, input: { pub: string; nonce: string; challenge?: string | undefined }, meta: RequestMeta): Promise<void> {
  requireChild(p);
  await ctx.db.transaction(async (tx) => {
    const now = ctx.now();
    const rows = await tx
      .update(guardianRecoveries)
      .set({ state: 'revealed', revealPub: input.pub, revealNonce: input.nonce, updatedAt: now })
      .where(
        and(
          eq(guardianRecoveries.id, id),
          eq(guardianRecoveries.childId, p.userId),
          eq(guardianRecoveries.state, 'challenged'),
          // die Zufallszahl, die das Kind gesehen hat: wurde sie inzwischen ausgetauscht, wird nicht offengelegt (App seit PR 89; ältere Apps senden sie nicht)
          input.challenge !== undefined ? eq(guardianRecoveries.challenge, input.challenge) : undefined,
          p.deviceId ? eq(guardianRecoveries.deviceId, p.deviceId) : isNull(guardianRecoveries.deviceId),
          sql`${guardianRecoveries.expiresAt} > ${now.toISOString()}::timestamptz`,
        ),
      )
      .returning({ id: guardianRecoveries.id });
    if (!rows[0]) throw await notFoundOrConflict(tx, id, p.userId);
    await writeAudit(ctx, tx, { event: 'guardian_recovery_revealed', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip });
  });
}

async function notFoundOrConflict(exec: Executor, id: string, childId: string): Promise<AppError> {
  const [r] = await exec.select({ s: guardianRecoveries.state }).from(guardianRecoveries).where(and(eq(guardianRecoveries.id, id), eq(guardianRecoveries.childId, childId)));
  return r ? new AppError(409, 'recovery_state', 'Diese Anfrage ist in einem anderen Zustand.') : notFound();
}

/** Abbrechen durch das Kind (jederzeit, von jedem Gerät, ohne Step-up). */
export async function cancelRecovery(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireChild(p);
  const woken: Array<{ userId: string; topics: string[] }> = [];
  await ctx.db.transaction(async (tx) => {
    const ended = await endRecovery(tx, id, p.userId, 'cancelled', ctx.now());
    if (!ended) throw await notFoundOrConflict(tx, id, p.userId);
    await writeAudit(ctx, tx, { event: 'guardian_recovery_ended', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { to: 'cancelled' } });
    woken.push(...(await noteRecovery(ctx, tx, p, 'guardian_recovery_ended', 'guardian_recovery_ended')));
  });
  wakeAll(ctx, p.familyId, woken);
}

/** Das Kind hat die Übergabe abgeholt und den Schlüssel übernommen: Anfrage fertig, Übergabedaten weg. */
export async function doneRecovery(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireChild(p);
  await ctx.db.transaction(async (tx) => {
    const [r] = await tx
      .select({ s: guardianRecoveries.state, d: guardianRecoveries.deviceId })
      .from(guardianRecoveries)
      .where(and(eq(guardianRecoveries.id, id), eq(guardianRecoveries.childId, p.userId)))
      .for('update');
    if (!r) throw notFound();
    if (!sameDevice(r.d, p.deviceId)) throw new AppError(409, 'recovery_device', 'Diese Anfrage gehört zu einem anderen Gerät.');
    if (r.s === 'done') return; // verlorene Antwort: folgenlos
    if (r.s !== 'released') throw new AppError(409, 'recovery_state', 'Diese Anfrage ist in einem anderen Zustand.');
    await endRecovery(tx, id, p.userId, 'done', ctx.now());
    await writeAudit(ctx, tx, { event: 'guardian_recovery_done', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip });
  });
}

// ---------------------------------------------------------------- Eltern

export interface GuardianRequestView extends RecoveryView {
  childId: string;
  childName: string;
  /** Verpflichtung des Kindes auf seinen flüchtigen Schlüssel. */
  commit: string;
  /** Offengelegter flüchtiger Schlüssel und Nonce (ab `revealed`). */
  revealPub: string | null;
  revealNonce: string | null;
  /** Der Eintrag dieses Elternteils (nur wenn das Elternteil die Anfrage bearbeitet und der Schlüssel offengelegt ist). */
  escrow: { blob: string; sig: string; keyVersion: number; guardianKeyVersion: number } | null;
}

export interface GuardianOverview {
  /** Kinder, die dieses Elternteil hinterlegt haben. */
  children: Array<{ id: string; displayName: string; keyVersion: number; guardianKeyVersion: number; stale: boolean }>;
  requests: GuardianRequestView[];
}

/** Übersicht für ein Elternteil: Kinder mit Hinterlegung und offene Anfragen (nur für Kinder, bei denen dieses Elternteil einen Eintrag hat). Nur lesend. */
export async function guardianOverview(ctx: AuthContext, p: SessionPrincipal): Promise<GuardianOverview> {
  requireParent(p);
  const now = ctx.now();
  await releaseStaleTakeovers(ctx.db, now);
  const ents = await ctx.db
    .select({
      childId: guardianEscrows.childId,
      childName: users.displayName,
      keyVersion: guardianEscrows.keyVersion,
      guardianKeyVersion: guardianEscrows.guardianKeyVersion,
      state: guardianEscrows.state,
      currentChildKey: personKeys.keyVersion,
      blob: guardianEscrows.blob,
      sig: guardianEscrows.sig,
    })
    .from(guardianEscrows)
    .innerJoin(users, eq(users.id, guardianEscrows.childId))
    .innerJoin(memberships, and(eq(memberships.familyId, guardianEscrows.familyId), eq(memberships.userId, guardianEscrows.childId), eq(memberships.status, 'active'), eq(memberships.role, 'child')))
    .leftJoin(personKeys, eq(personKeys.userId, guardianEscrows.childId))
    .where(and(eq(guardianEscrows.guardianId, p.userId), eq(guardianEscrows.familyId, p.familyId), inArray(guardianEscrows.state, [...CURRENT_ESCROW]), isNull(users.disabledAt)));
  const [mine] = await ctx.db.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId));
  const childIds = ents.map((e) => e.childId);
  const reqs =
    childIds.length === 0
      ? []
      : await ctx.db
          .select()
          .from(guardianRecoveries)
          .where(and(inArray(guardianRecoveries.childId, childIds), inArray(guardianRecoveries.state, [...OPEN_STATES]), sql`${guardianRecoveries.expiresAt} > ${now.toISOString()}::timestamptz`))
          .orderBy(guardianRecoveries.createdAt);
  const requests: GuardianRequestView[] = [];
  for (const r of reqs) {
    const e = ents.find((x) => x.childId === r.childId);
    if (!e) continue;
    const base = await viewOf(ctx.db, r);
    const mineNow = r.guardianId === p.userId;
    requests.push({
      ...base,
      // die Zufallszahl und die Übergabe gehören dem Bearbeiter und dem Kind; andere Eltern sehen nur, dass jemand dran ist
      challenge: mineNow ? base.challenge : null,
      releaseBlob: null,
      releaseSig: null,
      childId: r.childId,
      childName: e.childName,
      commit: r.commit,
      revealPub: mineNow ? r.revealPub : null,
      revealNonce: mineNow ? r.revealNonce : null,
      escrow: mineNow && r.state === 'revealed' && e.state === 'active' && e.keyVersion === r.keyVersion && e.currentChildKey === r.keyVersion ? { blob: e.blob, sig: e.sig, keyVersion: e.keyVersion, guardianKeyVersion: e.guardianKeyVersion } : null,
    });
  }
  return {
    children: ents.map((e) => ({ id: e.childId, displayName: e.childName, keyVersion: e.keyVersion, guardianKeyVersion: e.guardianKeyVersion, stale: e.state !== 'active' || e.currentChildKey !== e.keyVersion || mine?.v !== e.guardianKeyVersion })),
    requests,
  };
}

/** Prüft, dass das Elternteil für diese Anfrage hinterlegt ist; lädt und sperrt die Anfrage. */
async function lockForGuardian(tx: Tx, p: SessionPrincipal, id: string) {
  const [r] = await tx.select().from(guardianRecoveries).where(and(eq(guardianRecoveries.id, id), eq(guardianRecoveries.familyId, p.familyId))).for('update');
  if (!r) throw notFound();
  const [e] = await tx
    .select({ state: guardianEscrows.state, keyVersion: guardianEscrows.keyVersion, guardianKeyVersion: guardianEscrows.guardianKeyVersion })
    .from(guardianEscrows)
    .where(and(eq(guardianEscrows.childId, r.childId), eq(guardianEscrows.guardianId, p.userId), inArray(guardianEscrows.state, [...CURRENT_ESCROW])));
  if (!e) throw notFound(); // kein (gültiger) Eintrag für dieses Elternteil: wie nicht vorhanden
  const [own] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId));
  return { r, e, ownKeyVersion: own?.v ?? null };
}

/**
 * Das Elternteil übernimmt die Anfrage und sendet die Zufallszahl (Step-up; erst nach der Wartefrist, nur im Zustand `pending`). Genau ein Elternteil gewinnt (atomar).
 * Das Kind wird benachrichtigt (es soll jetzt den flüchtigen Schlüssel offenlegen).
 */
export async function challengeRecovery(ctx: AuthContext, p: SessionPrincipal, id: string, input: { challenge: string }, meta: RequestMeta): Promise<void> {
  requireParent(p);
  requireStepUp(ctx, p);
  const woken: Array<{ userId: string; topics: string[] }> = [];
  await ctx.db.transaction(async (tx) => {
    await releaseStaleTakeovers(tx, ctx.now());
    const { r, e, ownKeyVersion } = await lockForGuardian(tx, p, id);
    const now = ctx.now();
    if (r.state !== 'pending' || r.expiresAt <= now) throw new AppError(409, 'recovery_state', 'Diese Anfrage ist in einem anderen Zustand.');
    if (now < r.readyAt) throw new AppError(409, 'recovery_wait', 'Die Wartefrist läuft noch.');
    // der Eintrag muss zum aktuellen Schlüssel des Kindes UND zum aktuellen Schlüssel dieses Elternteils gehören (sonst könnte das Elternteil ihn nicht öffnen und die Anfrage hinge fest)
    if (e.state !== 'active' || e.keyVersion !== r.keyVersion || ownKeyVersion !== e.guardianKeyVersion) throw new AppError(409, 'escrow_stale', 'Deine Hinterlegung ist veraltet.');
    const rows = await tx
      .update(guardianRecoveries)
      .set({ state: 'challenged', guardianId: p.userId, challenge: input.challenge, updatedAt: now })
      .where(and(eq(guardianRecoveries.id, id), eq(guardianRecoveries.state, 'pending')))
      .returning({ id: guardianRecoveries.id });
    if (!rows[0]) throw new AppError(409, 'recovery_state', 'Diese Anfrage ist in einem anderen Zustand.');
    await writeAudit(ctx, tx, { event: 'guardian_recovery_challenged', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { child: r.childId } });
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: r.childId, kind: 'guardian_recovery_challenged', via: viaOf(p), actorId: p.userId });
    woken.push({ userId: r.childId, topics: await wakeTopics(tx, r.childId) });
  });
  for (const w of woken) wakeAfterCommit(ctx, p.familyId, w.userId, w.topics);
}

/**
 * Das Elternteil legt die Übergabe ab (Step-up): Sealed Box der Seeds an den offengelegten flüchtigen Schlüssel, vom Elternteil signiert. Nur der Bearbeiter, nur im Zustand
 * `revealed`. Das Kind wird benachrichtigt.
 */
export async function releaseRecovery(ctx: AuthContext, p: SessionPrincipal, id: string, input: { blob: string; sig: string }, meta: RequestMeta): Promise<void> {
  requireParent(p);
  requireStepUp(ctx, p);
  const woken: Array<{ userId: string; topics: string[] }> = [];
  await ctx.db.transaction(async (tx) => {
    const { r, e } = await lockForGuardian(tx, p, id);
    const now = ctx.now();
    if (e.state !== 'active') throw new AppError(409, 'escrow_stale', 'Die Hinterlegung des Kindes ist veraltet.');
    if (r.guardianId !== p.userId || r.state !== 'revealed' || r.expiresAt <= now) throw new AppError(409, 'recovery_state', 'Diese Anfrage ist in einem anderen Zustand.');
    await tx.update(guardianRecoveries).set({ state: 'released', releaseBlob: input.blob, releaseSig: input.sig, updatedAt: now }).where(eq(guardianRecoveries.id, id));
    await writeAudit(ctx, tx, { event: 'guardian_recovery_released', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { child: r.childId } });
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: r.childId, kind: 'guardian_recovery_released', via: viaOf(p), actorId: p.userId });
    woken.push({ userId: r.childId, topics: await wakeTopics(tx, r.childId) });
  });
  for (const w of woken) wakeAfterCommit(ctx, p.familyId, w.userId, w.topics);
}

/**
 * Das Elternteil lehnt ab (zum Beispiel weil der Kurzcode nicht stimmt): die Anfrage endet, die Übergabedaten verschwinden, das Kind bekommt einen Hinweis. Ohne Step-up
 * (sichere Richtung); jedes hinterlegte Elternteil darf eine offene Anfrage ablehnen.
 */
export async function declineRecovery(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireParent(p);
  const woken: Array<{ userId: string; topics: string[] }> = [];
  await ctx.db.transaction(async (tx) => {
    const { r } = await lockForGuardian(tx, p, id);
    const ended = await endRecovery(tx, id, r.childId, 'declined', ctx.now());
    if (!ended) throw new AppError(409, 'recovery_state', 'Diese Anfrage ist in einem anderen Zustand.');
    await writeAudit(ctx, tx, { event: 'guardian_recovery_ended', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { to: 'declined', child: r.childId } });
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: r.childId, kind: 'guardian_recovery_ended', via: viaOf(p), actorId: p.userId });
    woken.push({ userId: r.childId, topics: await wakeTopics(tx, r.childId) });
  });
  for (const w of woken) wakeAfterCommit(ctx, p.familyId, w.userId, w.topics);
}

// ---------------------------------------------------------------- Aufräumen

/**
 * Eine übernommene Anfrage ohne Fortschritt (länger als TAKEOVER_TIMEOUT_MS im selben Zustand) hängt nicht ewig fest: `challenged` wird wieder `pending` (ein anderes Elternteil
 * kann übernehmen; das Kind hat noch nichts offengelegt); `revealed` endet (`expired`), weil das Kind den flüchtigen Schlüssel schon offengelegt hat und für eine neue
 * Zufallszahl nie ein zweites Mal offenlegen darf (sonst ließe sich der Kurzcode adaptiv drehen): es braucht eine neue Anfrage mit neuer Verpflichtung.
 */
export async function releaseStaleTakeovers(exec: Executor, now: Date, childId?: string): Promise<void> {
  const before = new Date(now.getTime() - TAKEOVER_TIMEOUT_MS);
  const own = childId ? eq(guardianRecoveries.childId, childId) : undefined;
  await exec
    .update(guardianRecoveries)
    .set({ state: 'pending', guardianId: null, challenge: null, revealPub: null, revealNonce: null, releaseBlob: null, releaseSig: null, updatedAt: now })
    .where(and(eq(guardianRecoveries.state, 'challenged'), lt(guardianRecoveries.updatedAt, before), own));
  await exec
    .update(guardianRecoveries)
    .set({ state: 'expired', releaseBlob: null, releaseSig: null, revealPub: null, revealNonce: null, challenge: null, updatedAt: now })
    .where(and(eq(guardianRecoveries.state, 'revealed'), lt(guardianRecoveries.updatedAt, before), own));
}

/** Aufräum-Job: überfällige offene Anfragen enden (Übergabedaten gelöscht), sehr alte beendete verschwinden. Nur Zustände, nie Schlüsselmaterial bleibt liegen. */
export async function expireGuardianRecoveries(ctx: Pick<AuthContext, 'db'>, now: Date): Promise<void> {
  await releaseStaleTakeovers(ctx.db, now);
  // ersetzte und zurückgenommene Hinterlegungen: nach der Löschfrist endgültig weg (vorher nie)
  await ctx.db
    .delete(guardianEscrows)
    .where(and(inArray(guardianEscrows.state, ['superseded', 'revoked']), lt(guardianEscrows.updatedAt, new Date(now.getTime() - ESCROW_RETENTION_MS))));
  await ctx.db
    .update(guardianRecoveries)
    .set({ state: 'expired', releaseBlob: null, releaseSig: null, revealPub: null, revealNonce: null, challenge: null, updatedAt: now })
    .where(and(inArray(guardianRecoveries.state, [...OPEN_STATES]), lt(guardianRecoveries.expiresAt, now)));
  await ctx.db
    .delete(guardianRecoveries)
    .where(and(inArray(guardianRecoveries.state, ['done', 'cancelled', 'declined', 'expired']), lt(guardianRecoveries.updatedAt, new Date(now.getTime() - ENDED_RETENTION_MS))));
}

