// Konto-Verwaltung nach der Anmeldung: Profil, Mitglieder, Geräte, Anmeldedaten, Wiederherstellungs-Codes, WebSocket-Tickets.
import type { RegistrationResponseJSON } from '@simplewebauthn/server';
import { and, asc, count, eq, gt, isNotNull, isNull, lt, sql } from 'drizzle-orm';
import { credentials, devices, type FamilyRole, invites, memberships, personKeys, securityEvents, sessions, users, wsTickets } from '../db/schema.js';
import { AppError } from '../errors.js';
import { serializeErr } from '../log.js';
import { defaultRegistry } from '../sync/index.js';
import { reconcileMedsTeilnehmer } from '../sync/meds.js';
import { detachMemberRefs } from '../sync/refs.js';
import { writeAudit } from './audit.js';
import { saveChallenge, takeChallenge } from './challenges.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { randomToken, sha256Hex } from './crypto.js';
import { createInvite, isDowngrade, revokeOpenInvitesBy, type CreatedInvite } from './invites.js';
import { findAccountById, type Account } from './login.js';
import { recordSecurityEvent, wakeAfterCommit, wakeTopics, wakeTopicsFor } from './security-events.js';
import { assertNotLocked, ipKey, recordFailure } from './lockout.js';
import { countRemainingCodes, createRecoveryCodes } from './recovery.js';
import type { MemberView } from './register.js';
import { csrfTokenFor, isAlive, loadLive, markAccessChanged, requireDestructiveAllowed, requireStepUp, revokeAllForUser, revokeDevice } from './sessions.js';
import type { Principal, Role, SessionPrincipal } from './types.js';
import { invalidateGuardianEscrow, invalidateGuardianRole } from './guardian-invalidate.js';
import { checkRegistration, registrationOptions } from './webauthn.js';
import { isOperator } from '../operator/service.js';

const forbidden = () => new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
const notFound = () => new AppError(404, 'not_found');

function requireAdmin(p: SessionPrincipal): void {
  if (p.role !== 'admin') throw forbidden();
}

// ---------- Profil ----------

export async function getMe(ctx: AuthContext, p: SessionPrincipal) {
  const account = await findAccountById(ctx, p.userId);
  if (!account) throw notFound();
  const creds = await ctx.db
    .select({ type: credentials.type })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)));
  const [fr] = await ctx.db
    .select({ familyRole: memberships.familyRole })
    .from(memberships)
    .where(and(eq(memberships.familyId, account.familyId), eq(memberships.userId, p.userId)));
  return {
    user: {
      id: account.userId,
      email: account.email,
      displayName: account.displayName,
      colorIndex: account.colorIndex,
      role: account.role,
      status: account.status,
      familyRole: fr?.familyRole ?? null,
    },
    familyId: account.familyId,
    // Betreiber-Flag nur als Anzeige-Hinweis für die App (Bereich "Betrieb"); die Betreiber-Routen prüfen es selbst
    operator: await isOperator(ctx, p.userId, account.familyId).catch((err: unknown) => {
      // nur ein Anzeige-Hinweis: ein Fehler hier (z. B. Migration noch nicht angewendet) darf /me nie scheitern lassen
      ctx.log.warn({ err }, 'Betreiber-Flag nicht lesbar');
      return false;
    }),
    session: { id: p.sessionId, deviceId: p.deviceId, stepUpAt: p.stepUpAt },
    ...(p.via === 'cookie' ? { csrfToken: csrfTokenFor(ctx, p.sessionId) } : {}),
    credentials: {
      passkeys: creds.filter((c) => c.type === 'passkey').length,
      password: creds.some((c) => c.type === 'password'),
      totp: creds.some((c) => c.type === 'totp'),
    },
    recoveryCodesRemaining: await countRemainingCodes(ctx, p.userId),
  };
}

export async function updateProfile(ctx: AuthContext, p: SessionPrincipal, input: { displayName?: string | undefined; colorIndex?: number | undefined }): Promise<void> {
  const set: Partial<typeof users.$inferInsert> = {};
  if (input.displayName !== undefined) set.displayName = input.displayName;
  if (input.colorIndex !== undefined) set.colorIndex = input.colorIndex;
  if (Object.keys(set).length === 0) return;
  await ctx.db.update(users).set(set).where(eq(users.id, p.userId));
  ctx.onMembersChanged(p.familyId);
}

// ---------- Mitglieder ----------

interface MemberRow {
  id: string;
  email: string;
  displayName: string;
  colorIndex: number;
  role: Role;
  status: 'active' | 'pending';
  publicEncKey: string | null;
  publicSignKey: string | null;
  keyVersion: number | null;
  familyRole: string | null;
}

/** Öffentliche E2EE-Schlüssel eines Mitglieds (null, solange die Person keine eingerichtet hat). */
interface MemberKeys {
  publicEncKey: string | null;
  publicSignKey: string | null;
  keyVersion: number | null;
}

/** Alle sehen aktive Mitglieder (ohne E-Mail); Admins zusätzlich E-Mail und wartende Mitglieder. `familyRole` ist reine Anzeige. */
export async function listMembers(ctx: AuthContext, p: SessionPrincipal): Promise<Array<Omit<MemberView, 'email'> & { email?: string; familyRole: string | null } & MemberKeys>> {
  const rows: MemberRow[] = await ctx.db
    .select({
      id: users.id,
      email: users.email,
      displayName: users.displayName,
      colorIndex: users.colorIndex,
      role: memberships.role,
      status: memberships.status,
      publicEncKey: personKeys.publicEncKey,
      publicSignKey: personKeys.publicSignKey,
      keyVersion: personKeys.keyVersion,
      familyRole: memberships.familyRole,
    })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .leftJoin(personKeys, eq(personKeys.userId, users.id))
    .where(and(eq(memberships.familyId, p.familyId), isNull(users.disabledAt), p.role === 'admin' ? undefined : eq(memberships.status, 'active')))
    .orderBy(asc(users.displayName));
  return rows.map(({ publicEncKey, publicSignKey, keyVersion, ...r }) => {
    const keys: MemberKeys = { publicEncKey, publicSignKey, keyVersion };
    return p.role === 'admin' || r.id === p.userId
      ? { ...r, ...keys }
      : { id: r.id, displayName: r.displayName, colorIndex: r.colorIndex, role: r.role, status: r.status, familyRole: r.familyRole, ...keys };
  });
}

/**
 * Setzt die Familienrolle (reine Anzeige, keine Rechte): jedes Mitglied für sich, ein Admin für jedes Mitglied der eigenen Familie.
 * `null` löscht sie. Fremde Familien und Nicht-Mitglieder ergeben 404, andere Mitglieder ohne Admin-Recht 403.
 */
export async function setFamilyRole(ctx: AuthContext, p: SessionPrincipal, targetId: string, familyRole: FamilyRole | null, meta: RequestMeta): Promise<void> {
  if (targetId !== p.userId) requireAdmin(p);
  // gesperrte und entfernte Konten (Soft-Delete) lassen sich nicht mehr ändern
  const ziel = await findAccountById(ctx, targetId, p.familyId);
  if (!ziel || ziel.disabled) throw notFound();
  await ctx.db.transaction(async (tx) => {
    const done = await tx
      .update(memberships)
      .set({ familyRole })
      .where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId)))
      .returning({ id: memberships.id });
    if (done.length === 0) throw notFound();
    await writeAudit(ctx, tx, { event: 'family_role_set', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId, to: familyRole } });
  });
  ctx.onMembersChanged(p.familyId);
}

async function memberOf(ctx: AuthContext, p: SessionPrincipal, userId: string): Promise<Account> {
  const a = await findAccountById(ctx, userId, p.familyId);
  // gesperrte und entfernte Konten stehen in keiner Liste und lassen sich über die Verwaltung nicht ansprechen (Rückholen: restoreMember)
  if (!a || a.disabled) throw notFound();
  return a;
}

/** Aktive Admins; entfernte (Soft-Delete) und gesperrte Konten zählen nicht mit, sonst bliebe die Familie ohne wirksamen Admin. */
async function activeAdminCount(exec: Executor, familyId: string): Promise<number> {
  const [r] = await exec
    .select({ n: count() })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(and(eq(memberships.familyId, familyId), eq(memberships.role, 'admin'), eq(memberships.status, 'active'), isNull(users.disabledAt)));
  return r?.n ?? 0;
}

export async function changeRole(ctx: AuthContext, p: SessionPrincipal, targetId: string, role: Role, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  requireStepUp(ctx, p);
  const target = await memberOf(ctx, p, targetId);
  if (target.role === role) return;
  let syncRev: number | null = null;
  await ctx.db.transaction(async (tx) => {
    // Admin-Zeilen sperren: zwei gleichzeitige Herabstufungen dürfen nicht den letzten Admin entfernen
    await tx.select({ id: memberships.id }).from(memberships).where(and(eq(memberships.familyId, p.familyId), eq(memberships.role, 'admin'))).for('update');
    if (target.role === 'admin' && (await activeAdminCount(tx, p.familyId)) <= 1) {
      throw new AppError(409, 'last_admin', 'Der letzte Admin kann nicht herabgestuft werden.');
    }
    await tx.update(memberships).set({ role }).where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId)));
    // Medikamenten-Plan: wer nach der neuen Rolle die Medikamente einer Person nicht mehr sehen darf (Kind wird Erwachsener, Elternteil wird Kind), fliegt aus der Teilnehmerliste
    syncRev = await reconcileMedsTeilnehmer(tx, defaultRegistry, { familyId: p.familyId, now: ctx.now() });
    // Rollenwechsel (zum Beispiel Kind zu Elternteil): Hinterlegungen als Kind und als Elternteil werden ungültig
    await invalidateGuardianRole(tx, targetId, ctx.now());
    // die Sicht der Person auf die Daten ändert sich: ihre Geräte müssen den lokalen Stand verwerfen und neu synchronisieren
    await tx.update(devices).set({ resyncRequired: true }).where(and(eq(devices.familyId, p.familyId), eq(devices.userId, targetId)));
    // Rollenwechsel: alle Sitzungen der Person enden (auch ihre WebSockets), sie meldet sich mit der neuen Rolle neu an
    await revokeAllForUser(ctx, tx, targetId);
    // Herabgestuft: ihre noch offenen Einladungen (mit der alten Rolle erstellt) enden ebenfalls
    if (isDowngrade(target.role, role)) {
      await revokeOpenInvitesBy(ctx, tx, { familyId: p.familyId, creatorId: targetId, actorId: p.userId, reason: 'role_downgraded' }, meta);
    }
    await writeAudit(ctx, tx, {
      event: 'role_changed',
      familyId: p.familyId,
      actorId: p.userId,
      ip: meta.ip,
      detail: { target: targetId, from: target.role, to: role },
    });
  });
  if (syncRev !== null) ctx.onRev(p.familyId, syncRev);
  ctx.onMembersChanged(p.familyId);
}

export async function approveMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  const done = await ctx.db
    .update(memberships)
    .set({ status: 'active' })
    .where(and(eq(memberships.familyId, p.familyId), eq(memberships.userId, targetId), eq(memberships.status, 'pending')))
    .returning({ id: memberships.id });
  if (done.length === 0) throw notFound();
  await writeAudit(ctx, ctx.db, { event: 'member_approved', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId } });
  ctx.onMembersChanged(p.familyId);
}

/**
 * Nimmt eine Person aus der Familie: Mitgliedschaft (und damit Geräte, Sitzungen, Tickets der Familie) werden gelöscht, offene
 * Einladungen von ihr und für sie widerrufen. Die Benutzerzeile samt Anmeldedaten verschwindet nur, wenn es keine weitere
 * Mitgliedschaft gibt (der Server bedient heute genau eine Familie, das Schema erlaubt aber mehrere).
 */
async function removeFromFamily(
  ctx: AuthContext,
  tx: Executor,
  input: { familyId: string; userId: string; actorId: string; reason: string },
  meta: RequestMeta,
): Promise<number | null> {
  await revokeOpenInvitesBy(ctx, tx, { familyId: input.familyId, creatorId: input.userId, actorId: input.actorId, reason: input.reason }, meta);
  await tx
    .update(invites)
    .set({ revokedAt: ctx.now() })
    .where(and(eq(invites.familyId, input.familyId), eq(invites.userId, input.userId), isNull(invites.usedAt), isNull(invites.revokedAt)));
  // Verweise (Zuständigkeit, Besitzer) mit Änderungseintrag lösen, bevor die Person verschwindet (sonst räumt nur der Fremdschlüssel still auf)
  const rev = await detachMemberRefs(tx, defaultRegistry, { familyId: input.familyId, userId: input.userId, now: ctx.now() });
  await tx.delete(memberships).where(and(eq(memberships.familyId, input.familyId), eq(memberships.userId, input.userId)));
  const [other] = await tx.select({ id: memberships.id }).from(memberships).where(eq(memberships.userId, input.userId)).limit(1);
  if (!other) await tx.delete(users).where(eq(users.id, input.userId));
  // offene WebSockets der Person schließen
  ctx.onRevoke({ kind: 'user', userId: input.userId });
  return rev;
}

export async function rejectMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  const target = await memberOf(ctx, p, targetId);
  if (target.status !== 'pending') throw new AppError(409, 'not_pending', 'Das Mitglied wartet nicht auf Freigabe.');
  await ctx.db.transaction(async (tx) => {
    await removeFromFamily(ctx, tx, { familyId: p.familyId, userId: targetId, actorId: p.userId, reason: 'member_rejected' }, meta);
    await writeAudit(ctx, tx, { event: 'member_rejected', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId } });
  });
  ctx.onMembersChanged(p.familyId);
}

/** Wie lange ein entferntes Mitglied (Soft-Delete) mit allen Schlüsseln und Sicherungen aufbewahrt wird, bevor der Aufräum-Job es endgültig löscht. */
export const REMOVED_RETENTION_DAYS = 30;
const DAY_MS = 86_400_000;

/**
 * Soft-Delete (P1 "Kein Datenverlust"): nimmt die Person wie bisher aus der Familie (Sitzungen und Geräte enden, Verweise in Listen, Aufgaben, Terminen
 * und Chats werden gelöst, offene Einladungen widerrufen), **löscht aber weder Konto noch Schlüssel**: `users.disabled_at` und `removed_at` werden gesetzt,
 * die Person kann sich nicht mehr anmelden und steht in keiner Liste. Personenschlüssel, Historie, Sicherungen, Archiv und Anmeldedaten bleiben
 * `REMOVED_RETENTION_DAYS` Tage liegen und können in dieser Zeit über [restoreMember] zurückgeholt werden; danach löscht der Aufräum-Job
 * ([purgeRemovedMembers]) endgültig, mit demselben Ergebnis wie früher das sofortige Entfernen. Nicht zurück kommen die gelösten Verweise (Zuständigkeiten, Chat-Teilnahmen).
 */
async function softRemoveFromFamily(ctx: AuthContext, tx: Executor, input: { familyId: string; userId: string; actorId: string; reason: string }, meta: RequestMeta): Promise<number | null> {
  await revokeOpenInvitesBy(ctx, tx, { familyId: input.familyId, creatorId: input.userId, actorId: input.actorId, reason: input.reason }, meta);
  await tx
    .update(invites)
    .set({ revokedAt: ctx.now() })
    .where(and(eq(invites.familyId, input.familyId), eq(invites.userId, input.userId), isNull(invites.usedAt), isNull(invites.revokedAt)));
  const rev = await detachMemberRefs(tx, defaultRegistry, { familyId: input.familyId, userId: input.userId, now: ctx.now() });
  await revokeAllForUser(ctx, tx, input.userId);
  const now = ctx.now();
  await tx.update(users).set({ disabledAt: now, removedAt: now, removedBy: input.actorId }).where(eq(users.id, input.userId));
  return rev;
}

export async function removeMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  if (targetId === p.userId) throw new AppError(409, 'cannot_remove_self', 'Du kannst dich nicht selbst entfernen.');
  const target = await memberOf(ctx, p, targetId);
  let syncRev: number | null = null;
  let soft = false;
  await ctx.db.transaction(async (tx) => {
    await tx.select({ id: memberships.id }).from(memberships).where(and(eq(memberships.familyId, p.familyId), eq(memberships.role, 'admin'))).for('update');
    if (target.role === 'admin' && (await activeAdminCount(tx, p.familyId)) <= 1) {
      throw new AppError(409, 'last_admin', 'Der letzte Admin kann nicht entfernt werden.');
    }
    // Soft-Delete nur für aktive Mitglieder, die zu keiner weiteren Familie gehören (das Konto wäre sonst auch dort gesperrt); wartende haben keine Schlüssel
    const [other] = await tx
      .select({ id: memberships.id })
      .from(memberships)
      .where(and(eq(memberships.userId, targetId), sql`${memberships.familyId} <> ${p.familyId}`))
      .limit(1);
    soft = target.status === 'active' && !other;
    const input = { familyId: p.familyId, userId: targetId, actorId: p.userId, reason: 'member_removed' };
    syncRev = soft ? await softRemoveFromFamily(ctx, tx, input, meta) : await removeFromFamily(ctx, tx, input, meta);
    await writeAudit(ctx, tx, { event: 'member_removed', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId, role: target.role, soft } });
  });
  // die Verweise der Person wurden im Sync bereinigt: die Geräte der Familie erfahren die neue Revision
  if (syncRev !== null) ctx.onRev(p.familyId, syncRev);
  ctx.onMembersChanged(p.familyId);
}

/**
 * Hinweis für Admins beim Einladen: Gehört [email] zu einem **entfernten** Mitglied der eigenen Familie, bleibt die Adresse bis zum endgültigen Löschen belegt (die Registrierung
 * mit ihr würde scheitern). Dann `409 member_removed` mit eigener Meldung. Nur für Admins geprüft: für alle anderen Rollen passiert nichts (kein Konto-Orakel für Eltern).
 */
export async function assertEmailNotRemoved(ctx: AuthContext, p: SessionPrincipal, email: string): Promise<void> {
  if (p.role !== 'admin') return;
  const [row] = await ctx.db
    .select({ id: users.id })
    .from(users)
    .innerJoin(memberships, eq(memberships.userId, users.id))
    .where(and(eq(memberships.familyId, p.familyId), isNotNull(users.removedAt), sql`lower(${users.email}) = lower(${email.trim()})`))
    .limit(1);
  if (row) {
    throw new AppError(
      409,
      'member_removed',
      `Diese Person ist entfernt: Hole sie zuerst zurück (Familie verwalten > Kürzlich entfernt), oder warte bis zum endgültigen Löschen (${REMOVED_RETENTION_DAYS} Tage nach dem Entfernen), bevor du dieselbe Adresse neu einlädst.`,
    );
  }
}

export interface RemovedMemberView {
  id: string;
  displayName: string;
  colorIndex: number;
  role: Role;
  removedAt: string;
  /** Ab diesem Zeitpunkt löscht der Aufräum-Job endgültig (frühestens; er läuft stündlich). */
  purgeAt: string;
  /** Die Person hat Schlüssel eingerichtet (beim endgültigen Löschen gehen sie und ihre Sicherungen verloren). */
  hasKeys: boolean;
}

/** Entfernte Mitglieder der eigenen Familie (nur Admins), die noch zurückgeholt werden können. */
export async function listRemovedMembers(ctx: AuthContext, p: SessionPrincipal): Promise<RemovedMemberView[]> {
  requireAdmin(p);
  const rows = await ctx.db
    .select({ id: users.id, displayName: users.displayName, colorIndex: users.colorIndex, role: memberships.role, removedAt: users.removedAt, keyVersion: personKeys.keyVersion })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .leftJoin(personKeys, eq(personKeys.userId, users.id))
    .where(and(eq(memberships.familyId, p.familyId), isNotNull(users.removedAt)))
    .orderBy(asc(users.removedAt));
  return rows.flatMap((r) =>
    r.removedAt
      ? [
          {
            id: r.id,
            displayName: r.displayName,
            colorIndex: r.colorIndex,
            role: r.role,
            removedAt: r.removedAt.toISOString(),
            purgeAt: new Date(r.removedAt.getTime() + REMOVED_RETENTION_DAYS * DAY_MS).toISOString(),
            hasKeys: r.keyVersion !== null,
          },
        ]
      : [],
  );
}

/**
 * Holt ein entferntes Mitglied zurück (Admin, Step-up): Konto wieder nutzbar, Schlüssel und Sicherungen sind unverändert da. Die Person meldet sich neu an
 * (Sitzungen und Geräte waren beendet). Chat-Teilnahmen, Zuständigkeiten und Termin-Teilnahmen kommen nicht von selbst zurück. Fremde Familien, nicht entfernte
 * und schon endgültig gelöschte Personen ergeben 404.
 */
export async function restoreMember(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  // das Zurückholen gibt einem Konto samt Anmeldedaten und Schlüsseln wieder Zugang: eine Admin-Sitzung aus Wiederherstellungscode/Reset darf das nicht (24 h Sperrfrist)
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const [row] = await tx
      .select({ id: users.id })
      .from(memberships)
      .innerJoin(users, eq(users.id, memberships.userId))
      .where(and(eq(memberships.familyId, p.familyId), eq(users.id, targetId), isNotNull(users.removedAt)))
      .for('update', { of: users });
    if (!row) throw notFound();
    await tx.update(users).set({ disabledAt: null, removedAt: null, removedBy: null }).where(eq(users.id, targetId));
    await writeAudit(ctx, tx, { event: 'member_restored', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId } });
  });
  ctx.onMembersChanged(p.familyId);
}

/**
 * Löscht entfernte Mitglieder endgültig, deren Aufbewahrungsfrist abgelaufen ist (Aufräum-Job): Mitgliedschaft und Konto verschwinden, per Kaskade auch Schlüssel,
 * Historie, Sicherungen, Archiv, Übertragungen, Anmeldedaten und Sicherheitsereignisse. Gibt die Zahl der gelöschten Personen zurück.
 */
export async function purgeRemovedMembers(ctx: AuthContext): Promise<number> {
  const cutoff = new Date(ctx.now().getTime() - REMOVED_RETENTION_DAYS * DAY_MS);
  const due = await ctx.db
    .select({ id: users.id, familyId: memberships.familyId, role: memberships.role })
    .from(users)
    .innerJoin(memberships, eq(memberships.userId, users.id))
    .where(and(isNotNull(users.removedAt), lt(users.removedAt, cutoff), isNotNull(users.disabledAt)));
  let purged = 0;
  for (const d of due) {
    // ein Fehler bei einer Person (nur ihre ID und die Art des Fehlers kommen ins Log, nie Parameter) hält die übrigen nicht auf
    try {
      const syncRev = await ctx.db.transaction(async (tx) => {
        // erneut unter Sperre prüfen: eine Wiederherstellung zwischen Auswahl und Löschen darf nie ein Konto verlieren
        const [still] = await tx
          .select({ id: users.id })
          .from(users)
          .where(and(eq(users.id, d.id), isNotNull(users.removedAt), lt(users.removedAt, cutoff)))
          .for('update');
        if (!still) return undefined;
        const rev = await removeFromFamily(ctx, tx, { familyId: d.familyId, userId: d.id, actorId: d.id, reason: 'member_purged' }, { ip: undefined });
        await writeAudit(ctx, tx, { event: 'member_purged', familyId: d.familyId, detail: { target: d.id, role: d.role, manual: false } });
        return rev;
      });
      if (syncRev === undefined) continue;
      purged++;
      if (syncRev !== null) ctx.onRev(d.familyId, syncRev);
    } catch (err: unknown) {
      ctx.log.error({ userId: d.id, err: serializeErr(err) }, 'Endgültiges Löschen eines entfernten Mitglieds fehlgeschlagen');
    }
  }
  return purged;
}

/**
 * Löscht ein **entferntes** Mitglied sofort endgültig (Admin, Step-up, Sperrfrist; z. B. auf Verlangen nach Art. 17 DSGVO): dieselbe Kaskade wie der Aufräum-Job.
 * Nicht entfernte, fremde und unbekannte Personen ergeben 404 (aktive Mitglieder löscht man nie direkt, sondern über das Entfernen mit Frist). Unwiderruflich.
 */
export async function purgeMemberNow(ctx: AuthContext, p: SessionPrincipal, targetId: string, meta: RequestMeta): Promise<void> {
  requireAdmin(p);
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  const syncRev = await ctx.db.transaction(async (tx) => {
    const [row] = await tx
      .select({ id: users.id, role: memberships.role })
      .from(memberships)
      .innerJoin(users, eq(users.id, memberships.userId))
      .where(and(eq(memberships.familyId, p.familyId), eq(users.id, targetId), isNotNull(users.removedAt), isNotNull(users.disabledAt)))
      .for('update', { of: users });
    if (!row) throw notFound();
    const rev = await removeFromFamily(ctx, tx, { familyId: p.familyId, userId: targetId, actorId: p.userId, reason: 'member_purged' }, meta);
    await writeAudit(ctx, tx, { event: 'member_purged', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { target: targetId, role: row.role, manual: true } });
    return rev;
  });
  if (syncRev !== null) ctx.onRev(p.familyId, syncRev);
  ctx.onMembersChanged(p.familyId);
}

/**
 * Setzt ein Mitglied zurück: alle Anmeldedaten und Sitzungen werden widerrufen, die Wiederherstellungs-Codes entfallen,
 * eine neue Einladung (für dasselbe Konto) wird erzeugt. `actorId` null = Betreiber über die Kommandozeile. Schlüssel und Sicherungen der Person bleiben
 * unberührt (nur die Anmeldedaten werden ersetzt). Die Person und ALLE anderen aktiven Mitglieder bekommen ein Sicherheitsereignis und den Wecker (ohne Inhalt):
 * ein Komplett-Reset ist der Weg, ein Konto zu übernehmen, die Familie soll einen neuen Schlüssel dieser Person nur nach Rücksprache annehmen.
 */
export async function resetMember(
  ctx: AuthContext,
  input: { familyId: string; userId: string; actorId: string | null; hours: number; withPin: boolean; by?: SessionPrincipal },
  meta: RequestMeta,
): Promise<CreatedInvite> {
  // eine Admin-Sitzung aus Wiederherstellungscode/Reset darf niemanden zurücksetzen (normale Admin-Sitzungen und das CLI bleiben frei)
  if (input.by) requireDestructiveAllowed(ctx, input.by);
  const target = await findAccountById(ctx, input.userId, input.familyId);
  // gesperrte und entfernte Konten (Soft-Delete) werden nicht zurückgesetzt (auch nicht per CLI): erst zurückholen
  if (!target || target.disabled) throw notFound();
  // Push-Themen vor dem Widerruf lesen (der löscht die Endpunkte); ein Fehler hier darf den Reset nie verhindern
  const topics = await wakeTopics(ctx.db, input.userId).catch((err: unknown) => {
    ctx.log.warn({ err: (err as Error).message }, 'Push-Themen für den Reset nicht lesbar');
    return [] as string[];
  });
  const result = await ctx.db.transaction(async (tx) => {
    const now = ctx.now();
    await tx.update(credentials).set({ revokedAt: now }).where(and(eq(credentials.userId, input.userId), isNull(credentials.revokedAt)));
    await tx.execute(sql`delete from recovery_codes where user_id = ${input.userId}`);
    await revokeAllForUser(ctx, tx, input.userId);
    // Komplett-Reset: Hinterlegungen für die Eltern-Wiederherstellung werden ungültig (stale), offene Anfragen enden; nichts wird gelöscht
    await invalidateGuardianEscrow(tx, input.userId, now);
    await tx.update(invites).set({ revokedAt: now }).where(and(eq(invites.userId, input.userId), isNull(invites.usedAt), isNull(invites.revokedAt)));
    const invite = await createInvite(
      ctx,
      tx,
      { familyId: input.familyId, role: target.role, hours: input.hours, withPin: input.withPin, requireApproval: false, userId: input.userId, createdBy: input.actorId },
      meta,
    );
    await writeAudit(ctx, tx, { event: 'member_reset', familyId: input.familyId, actorId: input.actorId, ip: meta.ip, detail: { target: input.userId } });
    await recordSecurityEvent(ctx, tx, { familyId: input.familyId, userId: input.userId, kind: 'account_reset_requested', via: 'admin', actorId: input.actorId });
    // Hinweis an ALLE anderen aktiven Mitglieder: ein Komplett-Reset ist der Weg, ein Konto zu übernehmen. Sie sollen einen neuen Schlüssel dieser Person
    // nur nach Rücksprache annehmen (die App warnt bei der Schlüsseländerung ohnehin, der Hinweis erklärt den Anlass). Der Hinweis ist Nebensache: in einem
    // eigenen Teilabschnitt (Savepoint), damit ein Fehler dort den Reset und den Einladungslink nie scheitern lässt.
    let others: string[] = [];
    try {
      others = await tx.transaction(async (sp) => {
        const rows = await sp
          .select({ userId: memberships.userId })
          .from(memberships)
          .innerJoin(users, eq(users.id, memberships.userId))
          .where(and(eq(memberships.familyId, input.familyId), eq(memberships.status, 'active'), isNull(users.disabledAt), sql`${memberships.userId} <> ${input.userId}`));
        if (rows.length > 0) {
          await sp
            .insert(securityEvents)
            .values(rows.map((o) => ({ familyId: input.familyId, userId: o.userId, kind: 'member_account_reset', via: 'admin', actorId: input.actorId, subjectId: input.userId, createdAt: ctx.now() })));
        }
        return rows.map((o) => o.userId);
      });
    } catch (err: unknown) {
      ctx.log.warn({ err: (err as Error).message }, 'Hinweis an die Familie (Komplett-Reset) nicht gespeichert');
    }
    return { invite, others };
  });
  // nach dem Commit: Benachrichtigungen sind Nebensache und dürfen den Reset nie scheitern lassen (Themen gebündelt, Fehler nur ins Log)
  wakeAfterCommit(ctx, input.familyId, input.userId, topics);
  if (result.others.length > 0) {
    try {
      const byUser = await wakeTopicsFor(ctx.db, result.others);
      for (const [other, t] of byUser) wakeAfterCommit(ctx, input.familyId, other, t);
    } catch (err: unknown) {
      ctx.log.warn({ err: (err as Error).message }, 'Weckruf an die Familie (Komplett-Reset) fehlgeschlagen');
    }
  }
  return result.invite;
}

// ---------- Geräte und Abmelden ----------

export async function listDevices(ctx: AuthContext, p: SessionPrincipal) {
  const rows = await ctx.db
    .select({ id: devices.id, name: devices.name, platform: devices.platform, appVersion: devices.appVersion, createdAt: devices.createdAt, lastSeenAt: devices.lastSeenAt })
    .from(devices)
    .where(and(eq(devices.userId, p.userId), isNull(devices.revokedAt)))
    .orderBy(asc(devices.createdAt));
  return rows.map((d) => ({ ...d, current: d.id === p.deviceId }));
}

export async function removeDevice(ctx: AuthContext, p: SessionPrincipal, deviceId: string, meta: RequestMeta): Promise<{ current: boolean }> {
  const [d] = await ctx.db.select({ id: devices.id }).from(devices).where(and(eq(devices.id, deviceId), eq(devices.userId, p.userId), isNull(devices.revokedAt)));
  if (!d) throw notFound();
  await ctx.db.transaction(async (tx) => {
    await revokeDevice(ctx, tx, deviceId);
    await writeAudit(ctx, tx, { event: 'device_removed', familyId: p.familyId, actorId: p.userId, deviceId, ip: meta.ip });
  });
  return { current: deviceId === p.deviceId };
}

export async function logoutCurrent(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<void> {
  await ctx.db.transaction(async (tx) => {
    if (p.deviceId) await revokeDevice(ctx, tx, p.deviceId);
    else {
      await tx.update(sessions).set({ revokedAt: ctx.now() }).where(eq(sessions.id, p.sessionId));
      ctx.onRevoke({ kind: 'session', sessionId: p.sessionId });
    }
    await writeAudit(ctx, tx, { event: 'logout', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip });
  });
}

export async function logoutEverywhere(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<void> {
  await ctx.db.transaction(async (tx) => {
    await revokeAllForUser(ctx, tx, p.userId);
    await writeAudit(ctx, tx, { event: 'logout_all', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
  });
}

// ---------- Anmeldedaten ----------

export async function listCredentials(ctx: AuthContext, p: SessionPrincipal) {
  return ctx.db
    .select({ id: credentials.id, type: credentials.type, label: credentials.label, createdAt: credentials.createdAt, lastUsedAt: credentials.lastUsedAt })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)))
    .orderBy(asc(credentials.createdAt));
}

export async function startAddPasskey(ctx: AuthContext, p: SessionPrincipal) {
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  const account = await findAccountById(ctx, p.userId);
  if (!account) throw notFound();
  const existing = await ctx.db
    .select({ externalId: credentials.externalId, transports: credentials.transports })
    .from(credentials)
    .where(and(eq(credentials.userId, p.userId), eq(credentials.type, 'passkey'), isNull(credentials.revokedAt)));
  const options = await registrationOptions(ctx, {
    userId: p.userId,
    accountName: account.email,
    displayName: account.displayName,
    existing: existing.map((e) => ({ externalId: e.externalId ?? '', transports: e.transports })),
  });
  const challengeId = await saveChallenge(ctx, { purpose: 'add_passkey', challenge: options.challenge, userId: p.userId });
  return { challengeId, options };
}

export async function finishAddPasskey(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { challengeId: string; response: RegistrationResponseJSON; label?: string | undefined },
  meta: RequestMeta,
): Promise<{ id: string }> {
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  await assertNotLocked(ctx, [ipKey(ctx, meta.ip)]);
  const taken = await takeChallenge(ctx, input.challengeId, 'add_passkey');
  if (!taken || taken.userId !== p.userId) throw new AppError(400, 'challenge_invalid', 'Der Vorgang ist abgelaufen. Bitte neu beginnen.');
  const verified = await checkRegistration(ctx, input.response, taken.challenge);
  if (!verified) {
    await recordFailure(ctx, ipKey(ctx, meta.ip), ctx.config.auth.lockoutIpThreshold);
    throw new AppError(400, 'registration_failed', 'Der Passkey konnte nicht überprüft werden.');
  }
  try {
    const [row] = await ctx.db.transaction(async (tx) => {
      await markAccessChanged(ctx, tx, p.userId);
      return tx
        .insert(credentials)
        .values({
          userId: p.userId,
          type: 'passkey',
          label: input.label ?? null,
          externalId: verified.externalId,
          secret: verified.publicKey,
          signCount: verified.counter,
          transports: verified.transports,
          deviceType: verified.deviceType,
          backedUp: verified.backedUp,
          createdAt: ctx.now(),
        })
        .returning({ id: credentials.id });
    });
    await writeAudit(ctx, ctx.db, { event: 'passkey_added', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { credentialId: row?.id } });
    return { id: row?.id ?? '' };
  } catch (err) {
    if ((err as { code?: string; cause?: { code?: string } }).code === '23505' || (err as { cause?: { code?: string } }).cause?.code === '23505') {
      throw new AppError(409, 'passkey_exists', 'Dieser Passkey ist bereits eingerichtet.');
    }
    throw err;
  }
}

export async function removePasskey(ctx: AuthContext, p: SessionPrincipal, credentialId: string, meta: RequestMeta): Promise<void> {
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const own = await tx
      .select({ id: credentials.id, type: credentials.type })
      .from(credentials)
      .where(and(eq(credentials.userId, p.userId), isNull(credentials.revokedAt)))
      .for('update');
    const target = own.find((c) => c.id === credentialId);
    if (!target || target.type !== 'passkey') throw notFound();
    // es muss eine Anmeldemöglichkeit übrig bleiben: weiterer Passkey oder Passwort (mit TOTP)
    const remaining = own.filter((c) => c.id !== credentialId);
    if (!remaining.some((c) => c.type === 'passkey' || c.type === 'password')) {
      throw new AppError(409, 'last_credential', 'Der letzte Passkey kann nicht entfernt werden.');
    }
    await tx.update(credentials).set({ revokedAt: ctx.now() }).where(eq(credentials.id, credentialId));
    await markAccessChanged(ctx, tx, p.userId);
    await writeAudit(ctx, tx, { event: 'passkey_removed', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { credentialId } });
  });
}

export async function regenerateRecoveryCodes(ctx: AuthContext, p: SessionPrincipal, meta: RequestMeta): Promise<string[]> {
  requireDestructiveAllowed(ctx, p);
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const codes = await createRecoveryCodes(ctx, tx, p.userId);
    await markAccessChanged(ctx, tx, p.userId);
    await writeAudit(ctx, tx, { event: 'recovery_codes_created', familyId: p.familyId, actorId: p.userId, ip: meta.ip });
    return codes;
  });
}

// ---------- WebSocket-Tickets ----------

export async function issueWsTicket(ctx: AuthContext, p: SessionPrincipal): Promise<{ ticket: string; expiresInSec: number }> {
  const ticket = randomToken(32);
  const ttl = ctx.config.auth.wsTicketTtlSec;
  const now = ctx.now();
  await ctx.db.insert(wsTickets).values({
    tokenHash: sha256Hex(ticket),
    familyId: p.familyId,
    userId: p.userId,
    sessionId: p.sessionId,
    createdAt: now,
    expiresAt: new Date(now.getTime() + ttl * 1000),
  });
  return { ticket, expiresInSec: ttl };
}

/** Löst ein Ticket genau einmal ein (DELETE ... RETURNING) und liefert die Person samt aktueller Rolle. */
export async function redeemWsTicket(ctx: AuthContext, ticket: string): Promise<Principal | null> {
  const [t] = await ctx.db
    .delete(wsTickets)
    .where(and(eq(wsTickets.tokenHash, sha256Hex(ticket)), gt(wsTickets.expiresAt, ctx.now())))
    .returning();
  if (!t) return null;
  const [s] = await ctx.db
    .select({ session: sessions, role: memberships.role, status: memberships.status, disabledAt: users.disabledAt })
    .from(sessions)
    .innerJoin(memberships, and(eq(memberships.familyId, sessions.familyId), eq(memberships.userId, sessions.userId)))
    .innerJoin(users, eq(users.id, sessions.userId))
    .where(eq(sessions.id, t.sessionId));
  // eine zwischenzeitlich rotierte Sitzung (used_at) gilt für das Ticket weiter; widerrufen oder abgelaufen nicht
  if (!s || s.status !== 'active' || s.disabledAt || !isAlive(ctx, s.session, { allowUsed: true })) return null;
  return { userId: s.session.userId, familyId: s.session.familyId, role: s.role, deviceId: s.session.deviceId, sessionId: s.session.id };
}

/** Prüft eine offene WebSocket-Anmeldung erneut (beim Ping): Sitzung noch gültig und Mitglied noch aktiv? Liefert die aktuelle Rolle. */
export async function recheckSession(ctx: AuthContext, p: Principal): Promise<Principal | null> {
  if (!p.sessionId) return p;
  const live = await loadLive(ctx, { id: p.sessionId });
  // eine rotierte Sitzung (used_at) gilt für den WebSocket weiter, wie beim Einlösen des Tickets
  if (!live || !isAlive(ctx, live.row, { allowUsed: true })) return null;
  return { ...p, role: live.role };
}
