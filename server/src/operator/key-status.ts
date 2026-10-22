// Schlüssel-Ampel je Person (Betreiber-Ansicht, `GET /admin/key-status`): zeigt, ob der Personenschlüssel auf mehr als einem unabhängigen Weg erhalten
// bleibt (Gerät mit dem aktuellen Schlüssel, bestätigte Passwort-Sicherung, Wiederherstellungssicherung). Nur Zustände und Zeiten, nie Schlüssel,
// Sicherungen oder deren Inhalt; der Server kennt keine Geheimnisse und prüft hier nichts davon, er zählt nur, was die Datenbank sagt.
//
// Grenzen der Aussage: Geräte MELDEN ihren Schlüsselstand selbst (`PUT /me/device-key`), das ist kein Beweis; "getestet" (ein Wiederherstellungstest der
// Sicherung) gibt es noch nicht, deshalb zählt die Existenz einer Sicherung zur aktuellen Schlüsselversion.
import { and, desc, eq, inArray, isNull } from 'drizzle-orm';
import { passwordModes } from '../auth/authkey.js';
import type { AuthContext } from '../auth/context.js';
import { countArchive } from '../auth/keys-archive.js';
import { devices, keyBackups, keyBackupsPw, memberships, personKeys, securityEvents, users } from '../db/schema.js';

export type Ampel = 'green' | 'yellow' | 'red';

/** Ein Geräte-Bericht gilt so lange als Beleg (danach kennt der Server den Stand des Geräts nicht mehr). */
export const DEVICE_REPORT_FRESH_DAYS = 30;
const DAY_MS = 86_400_000;
const EVENTS_PER_PERSON = 5;

export interface Ways {
  /** Mindestens ein aktives Gerät hat in den letzten 30 Tagen gemeldet, die AKTUELLE Schlüsselversion zu haben. */
  device: boolean;
  /** Bestätigte, aktive Passwort-Sicherung zur aktuellen Schlüsselversion. */
  pwBackup: boolean;
  /** Wiederherstellungssicherung (Wiederherstellungsschlüssel) zur aktuellen Schlüsselversion. */
  recoveryBackup: boolean;
}

/**
 * Die Ampel. Zwei unabhängige Wege schützen vor Verlust, ein Gerät mit dem Schlüssel braucht es für den Alltag:
 * - grün: mindestens zwei Wege, darunter ein Gerät mit aktuellem Schlüssel;
 * - gelb: ein einzelner Weg, der ein Gerät ist (fällt es aus, ist der Schlüssel weg), oder zwei Sicherungen ohne Gerät (kein Verlust, aber im Alltag unbenutzbar);
 * - rot: kein Weg, oder genau eine Sicherung und kein Gerät mit Schlüssel (kein zweiter Weg und niemand, der ihn gerade hält), oder die Person hat noch keinen Schlüssel.
 */
export function ampelOf(ways: Ways, hasKeys: boolean): Ampel {
  if (!hasKeys) return 'red';
  const n = [ways.device, ways.pwBackup, ways.recoveryBackup].filter(Boolean).length;
  if (n >= 2 && ways.device) return 'green';
  if (n === 0) return 'red';
  if (n === 1) return ways.device ? 'yellow' : 'red';
  return 'yellow'; // zwei Sicherungen, aber kein Gerät mit dem Schlüssel
}

/** Gesamtbild: die schlechteste Ampel; "bereit" nur, wenn alle grün sind (und es Mitglieder gibt). */
export function overallAmpel(ampeln: readonly Ampel[]): { overall: Ampel; ready: boolean; counts: Record<Ampel, number> } {
  const counts: Record<Ampel, number> = { green: 0, yellow: 0, red: 0 };
  for (const a of ampeln) counts[a]++;
  const overall: Ampel = counts.red > 0 ? 'red' : counts.yellow > 0 ? 'yellow' : 'green';
  return { overall, ready: ampeln.length > 0 && counts.green === ampeln.length, counts };
}

/** Feste Arten der Schlüsselereignisse in der Ansicht (security_events.kind). */
export const KEY_EVENT_KINDS = ['key_rotated', 'key_backup_replaced', 'key_backup_read', 'key_backup_pw_read', 'key_backup_archive_read', 'key_transfer_created', 'key_transfer_claimed', 'recovery_code_login'] as const;

export interface KeyEventView {
  kind: string;
  at: string;
}

export interface PersonKeyStatus {
  userId: string;
  displayName: string;
  role: 'admin' | 'parent' | 'child';
  ampel: Ampel;
  hasKeys: boolean;
  keyVersion: number | null;
  ways: Ways;
  wayCount: number;
  devicesTotal: number;
  devicesWithKey: number;
  /** Aktive Geräte, die überhaupt einen Schlüsselstand gemeldet haben (egal welchen, egal wann): Geräte ohne Bericht (alte App) sind für die WARNUNG "unbekannt", nicht "fehlt". */
  devicesReported: number;
  /** Passwort noch im alten Klartext-Verfahren (nur mit Schalter E2EE_PW_BACKUP aussagekräftig). */
  legacyPassword: boolean;
  /** Anzahl archivierter Sicherungen früherer Schlüsselstände. */
  archiveCount: number;
  events: KeyEventView[];
}

/** Nur die Zusammenfassung (ohne Namen, ohne Ereignisse): für die Übersicht ohne Step-up. */
export interface KeySummary {
  generatedAt: string;
  overall: Ampel;
  ready: boolean;
  counts: Record<Ampel, number>;
}

export const summarize = (k: KeyStatus): KeySummary => ({ generatedAt: k.generatedAt, overall: k.overall, ready: k.ready, counts: k.counts });

export interface KeyStatus {
  generatedAt: string;
  overall: Ampel;
  /** "Stichtag-bereit": alle Mitglieder grün. */
  ready: boolean;
  counts: Record<Ampel, number>;
  persons: PersonKeyStatus[];
}

/** Ampel aller aktiven Mitglieder der Familie (mit `onlyUserId` nur einer Person und ohne Ereignisse: für `GET /me/key-status`). Nur lesend. */
export async function collectKeyStatus(ctx: AuthContext, familyId: string, opts: { onlyUserId?: string } = {}): Promise<KeyStatus> {
  const now = ctx.now();
  const fresh = new Date(now.getTime() - DEVICE_REPORT_FRESH_DAYS * DAY_MS);
  const members = await ctx.db
    .select({ userId: users.id, displayName: users.displayName, role: memberships.role, keyVersion: personKeys.keyVersion })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .leftJoin(personKeys, eq(personKeys.userId, users.id))
    .where(and(eq(memberships.familyId, familyId), eq(memberships.status, 'active'), isNull(users.disabledAt), opts.onlyUserId ? eq(users.id, opts.onlyUserId) : undefined))
    .orderBy(users.displayName);
  const ids = members.map((m) => m.userId);
  const empty = { generatedAt: now.toISOString(), ...overallAmpel([]), persons: [] as PersonKeyStatus[] };
  if (ids.length === 0) return empty;

  const devs = await ctx.db
    .select({ userId: devices.userId, keyVersion: devices.keyVersion, reportedAt: devices.keyReportedAt })
    .from(devices)
    .where(and(eq(devices.familyId, familyId), isNull(devices.revokedAt), inArray(devices.userId, ids)));
  const recovery = await ctx.db.select({ userId: keyBackups.userId, keyVersion: keyBackups.keyVersion }).from(keyBackups).where(inArray(keyBackups.userId, ids));
  const pw = await ctx.db
    .select({ userId: keyBackupsPw.userId, keyVersion: keyBackupsPw.keyVersion, verifiedAt: keyBackupsPw.verifiedAt })
    .from(keyBackupsPw)
    .where(and(inArray(keyBackupsPw.userId, ids), eq(keyBackupsPw.state, 'active')));
  const modes = ctx.config.e2eePwBackup ? new Map((await passwordModes(ctx, familyId)).map((m) => [m.userId, m.mode])) : new Map<string, string>();

  const persons: PersonKeyStatus[] = [];
  for (const m of members) {
    const hasKeys = m.keyVersion !== null;
    const current = m.keyVersion;
    const own = devs.filter((d) => d.userId === m.userId);
    const withKey = own.filter((d) => current !== null && d.keyVersion === current && d.reportedAt !== null && d.reportedAt.getTime() >= fresh.getTime());
    const ways: Ways = {
      device: hasKeys && withKey.length > 0,
      pwBackup: hasKeys && pw.some((r) => r.userId === m.userId && r.keyVersion === current && r.verifiedAt !== null),
      recoveryBackup: hasKeys && recovery.some((r) => r.userId === m.userId && r.keyVersion === current),
    };
    // je Person abgefragt: eine Person mit vielen Ereignissen verdrängt die Ereignisse der anderen nie
    const events = opts.onlyUserId
      ? []
      : (
          await ctx.db
            .select({ kind: securityEvents.kind, at: securityEvents.createdAt })
            .from(securityEvents)
            .where(and(eq(securityEvents.familyId, familyId), eq(securityEvents.userId, m.userId), inArray(securityEvents.kind, [...KEY_EVENT_KINDS])))
            .orderBy(desc(securityEvents.createdAt))
            .limit(EVENTS_PER_PERSON)
        ).map((e) => ({ kind: e.kind, at: e.at.toISOString() }));
    persons.push({
      userId: m.userId,
      displayName: m.displayName,
      role: m.role,
      ampel: ampelOf(ways, hasKeys),
      hasKeys,
      keyVersion: current,
      ways,
      wayCount: [ways.device, ways.pwBackup, ways.recoveryBackup].filter(Boolean).length,
      devicesTotal: own.length,
      devicesWithKey: withKey.length,
      devicesReported: own.filter((d) => d.keyVersion !== null && d.reportedAt !== null).length,
      legacyPassword: modes.get(m.userId) === 'legacy',
      archiveCount: hasKeys ? await countArchive(ctx, m.userId, current ?? 0) : 0,
      events,
    });
  }
  return { generatedAt: now.toISOString(), ...overallAmpel(persons.map((p) => p.ampel)), persons };
}
