// Datenbankschema (PostgreSQL 17) für Phase 1. Jede fachliche Tabelle trägt family_id, auch wenn der
// Server genau eine Familie bedient. Änderbare Tabellen führen die Sync-Spalten (rev, field_revs,
// updated_at, deleted_at); jede Änderung erzeugt zusätzlich einen Eintrag in change_log.
import { sql } from 'drizzle-orm';
import {
  bigint,
  boolean,
  check,
  date,
  doublePrecision,
  foreignKey,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid,
  unique,
  type AnyPgColumn,
} from 'drizzle-orm/pg-core';

export const memberRole = pgEnum('member_role', ['admin', 'parent', 'child', 'guest']);
/** pending: per Einladung mit Freigabe registriert, darf sich erst nach Freigabe durch einen Admin anmelden. */
export const memberStatus = pgEnum('member_status', ['active', 'pending']);
export const credentialType = pgEnum('credential_type', ['passkey', 'totp', 'password']);
export const listKind = pgEnum('list_kind', ['shopping', 'packing', 'custom']);
/** Wer eine Liste sehen darf: nur Eltern, die Familie (ohne Gäste) oder alle (auch Gäste, "freigegeben"). */
export const listAudience = pgEnum('list_audience', ['parents', 'family', 'all']);
export const fileKind = pgEnum('file_kind', ['file', 'folder']);

const id = () => uuid('id').primaryKey().default(sql`gen_random_uuid()`);
const createdAt = () => timestamp('created_at', { withTimezone: true }).notNull().defaultNow();
const familyRef = () =>
  uuid('family_id')
    .notNull()
    .references((): AnyPgColumn => families.id, { onDelete: 'cascade' });

/** Sync-Spalten: Revision der letzten Änderung, Revision je Feld (Last-write-wins pro Feld), Tombstone. */
const syncColumns = () => ({
  rev: bigint('rev', { mode: 'number' }).notNull(),
  fieldRevs: jsonb('field_revs').$type<Record<string, number>>().notNull().default({}),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
});

export const families = pgTable('families', {
  id: id(),
  name: text('name').notNull(),
  /** Zuletzt vergebene Revision; wird in der Transaktion hochgezählt (UPDATE ... RETURNING). */
  currentRev: bigint('current_rev', { mode: 'number' }).notNull().default(0),
  /**
   * Höchste Revision, für die Tombstones bzw. Protokolleinträge bereits entfernt wurden. Ein Gerät mit sinceRev darunter
   * kennt eventuell Löschungen nicht mehr und muss neu synchronisieren (resync_required).
   */
  purgedRev: bigint('purged_rev', { mode: 'number' }).notNull().default(0),
  createdAt: createdAt(),
});

export const users = pgTable(
  'users',
  {
    id: id(),
    email: text('email').notNull(),
    displayName: text('display_name').notNull(),
    /** Index in die feste Personenfarben-Palette (0 bis 9). */
    colorIndex: integer('color_index').notNull().default(0),
    createdAt: createdAt(),
    disabledAt: timestamp('disabled_at', { withTimezone: true }),
  },
  (t) => [uniqueIndex('users_email_lower_uq').on(sql`lower(${t.email})`)],
);

export const memberships = pgTable(
  'memberships',
  {
    id: id(),
    familyId: familyRef(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    role: memberRole('role').notNull(),
    status: memberStatus('status').notNull().default('active'),
    createdAt: createdAt(),
  },
  (t) => [
    // Ziel der zusammengesetzten Fremdschlüssel (family_id, user_id): Verweise auf Personen bleiben in der Familie
    unique('memberships_family_user_uq').on(t.familyId, t.userId),
    index('memberships_user_idx').on(t.userId),
  ],
);

/** Anmeldedaten je Benutzer (nicht je Familie): Passkey, TOTP-Geheimnis oder Argon2id-Passwort-Hash. */
export const credentials = pgTable(
  'credentials',
  {
    id: id(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    type: credentialType('type').notNull(),
    label: text('label'),
    /** Passkey: Credential-ID (base64url); sonst leer. */
    externalId: text('external_id'),
    /** Passkey: öffentlicher Schlüssel; TOTP: verschlüsseltes Geheimnis; Passwort: Argon2id-Hash. */
    secret: text('secret').notNull(),
    signCount: bigint('sign_count', { mode: 'number' }).notNull().default(0),
    transports: jsonb('transports').$type<string[]>(),
    /** TOTP-Replay-Schutz: letzter akzeptierter Zeitschritt. */
    lastTimeStep: bigint('last_time_step', { mode: 'number' }),
    createdAt: createdAt(),
    lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
  },
  (t) => [
    index('credentials_user_idx').on(t.userId),
    uniqueIndex('credentials_external_id_uq')
      .on(t.externalId)
      .where(sql`${t.externalId} is not null`),
    // je Person höchstens ein aktives Passwort bzw. TOTP-Geheimnis (Passkeys beliebig viele)
    uniqueIndex('credentials_single_active_uq')
      .on(t.userId, t.type)
      .where(sql`${t.type} in ('password', 'totp') and ${t.revokedAt} is null`),
  ],
);

export const invites = pgTable(
  'invites',
  {
    id: id(),
    familyId: familyRef(),
    role: memberRole('role').notNull(),
    /** SHA-256 des Einladungstokens; das Token selbst wird nie gespeichert. */
    tokenHash: text('token_hash').notNull().unique(),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    usedAt: timestamp('used_at', { withTimezone: true }),
    usedBy: uuid('used_by').references(() => users.id, { onDelete: 'set null' }),
    /** Zurücksetzen: Einladung für ein bestehendes Konto (neue Anmeldedaten); sonst null (neues Konto). */
    userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }),
    /** HMAC-SHA256 der 6-stelligen PIN (mit Server-Schlüssel); null = keine PIN. */
    pinHash: text('pin_hash'),
    /** Gezählte PIN-Versuche (vor dem Vergleich erhöht, damit parallele Versuche nicht durchrutschen). */
    pinAttempts: integer('pin_attempts').notNull().default(0),
    /** Nach zu vielen PIN-Fehlversuchen gesperrt. */
    lockedAt: timestamp('locked_at', { withTimezone: true }),
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
    /** Neues Mitglied bleibt bis zur Freigabe durch einen Admin "pending". */
    requireApproval: boolean('require_approval').notNull().default(false),
    /** Wann der Ablauf ins Audit-Log geschrieben wurde (Aufräum-Job). */
    expiredLoggedAt: timestamp('expired_logged_at', { withTimezone: true }),
  },
  (t) => [index('invites_family_idx').on(t.familyId), check('invites_pin_attempts_ck', sql`${t.pinAttempts} >= 0`)],
);

export const devices = pgTable(
  'devices',
  {
    id: id(),
    familyId: familyRef(),
    userId: uuid('user_id').notNull(),
    name: text('name').notNull(),
    platform: text('platform').notNull(),
    appVersion: text('app_version'),
    /** UnifiedPush-/ntfy-Endpunkt oder Web-Push-Abo; enthält nie Inhalte. */
    pushEndpoint: text('push_endpoint'),
    /**
     * Zuletzt vom Gerät bestätigte Revision (sinceRev des letzten erfolgreichen Abgleichs). Tombstones im
     * change_log dürfen erst entfernt werden, wenn alle Geräte der Familie sie mit last_rev kennen.
     */
    lastRev: bigint('last_rev', { mode: 'number' }).notNull().default(0),
    /**
     * Das Gerät muss neu synchronisieren (sinceRev 0), weil sich seine Sicht geändert hat (Rolle gewechselt, Mitglied entfernt):
     * der Sync antwortet resync_required, bis das Gerät mit sinceRev 0 neu beginnt. Der Client leert dann seine Fachtabellen.
     */
    resyncRequired: boolean('resync_required').notNull().default(false),
    createdAt: createdAt(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }),
    /** Abgemeldetes Gerät: erscheint nicht mehr in der Liste; der Aufräum-Job löscht die Zeile später. */
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
  },
  (t) => [
    index('devices_user_idx').on(t.userId),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    index('devices_family_idx').on(t.familyId),
    // Ziel der zusammengesetzten Fremdschlüssel (family_id, device_id): eine Sitzung gehört nie zu einem fremden Gerät
    unique('devices_family_id_uq').on(t.familyId, t.id),
  ],
);

export const sessions = pgTable(
  'sessions',
  {
    id: id(),
    familyId: familyRef(),
    userId: uuid('user_id').notNull(),
    deviceId: uuid('device_id'),
    /** web: Cookie-Sitzung; app: Refresh-Token (Rotation). */
    kind: text('kind').notNull().default('web'),
    /** passkey | password | recovery */
    authMethod: text('auth_method').notNull().default('passkey'),
    /** Letzte erneute Bestätigung (Step-up) oder Anmeldung; Grundlage für "frisch bestätigt". */
    stepUpAt: timestamp('step_up_at', { withTimezone: true }),
    /** Hash von Session-Cookie (Web) bzw. Refresh-Token (App); Rotation über token_family. */
    tokenHash: text('token_hash').notNull().unique(),
    tokenFamily: uuid('token_family')
      .notNull()
      .default(sql`gen_random_uuid()`),
    createdAt: createdAt(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }),
    /**
     * Wiederverwendungs-Erkennung für Refresh-Token: Beim Einlösen wird used_at gesetzt und rotated_to auf die
     * Nachfolge-Sitzung. Wird ein Token mit gesetztem used_at erneut vorgelegt, ist es gestohlen oder
     * kopiert: dann wird die ganze token_family widerrufen (revoked_at).
     */
    usedAt: timestamp('used_at', { withTimezone: true }),
    rotatedTo: uuid('rotated_to').references((): AnyPgColumn => sessions.id, { onDelete: 'set null' }),
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
  },
  (t) => [
    index('sessions_user_idx').on(t.userId),
    index('sessions_device_idx').on(t.deviceId),
    index('sessions_token_family_idx').on(t.tokenFamily),
    foreignKey({ columns: [t.familyId, t.deviceId], foreignColumns: [devices.familyId, devices.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    check('sessions_kind_ck', sql`${t.kind} in ('web', 'app')`),
  ],
);

/** Wiederherstellungs-Codes (10 Stück je Person): nur der Hash wird gespeichert, jeder Code gilt einmal. */
export const recoveryCodes = pgTable(
  'recovery_codes',
  {
    id: id(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    /** HMAC-SHA256 des normalisierten Codes mit serverseitigem Schlüssel (nie der Klartext, kein ungesalzener Hash). */
    codeHash: text('code_hash').notNull().unique(),
    createdAt: createdAt(),
    usedAt: timestamp('used_at', { withTimezone: true }),
  },
  (t) => [index('recovery_codes_user_idx').on(t.userId)],
);

/** Sicherheitsrelevante Ereignisse (Anmeldung, neues Gerät, Rollenänderung, Codes). Nur anhängen. */
export const auditLog = pgTable(
  'audit_log',
  {
    id: id(),
    /** Bleibt erhalten, wenn die Familie gelöscht wird (dann null), damit Löschungen nachvollziehbar sind. */
    familyId: uuid('family_id').references(() => families.id, { onDelete: 'set null' }),
    actorId: uuid('actor_id').references(() => users.id, { onDelete: 'set null' }),
    deviceId: uuid('device_id').references(() => devices.id, { onDelete: 'set null' }),
    /** z. B. login_ok, login_failed, device_added, role_changed, recovery_code_used, session_reuse_detected */
    event: text('event').notNull(),
    detail: jsonb('detail').$type<Record<string, unknown>>().notNull().default({}),
    /** Nur kurz aufbewahren: ein Aufräum-Job leert die Spalte nach 7 Tagen (siehe docs/DATENSCHUTZ-ENTWURF.md). */
    ip: text('ip'),
    createdAt: createdAt(),
  },
  (t) => [index('audit_log_family_created_idx').on(t.familyId, t.createdAt), index('audit_log_actor_idx').on(t.actorId), index('audit_log_created_idx').on(t.createdAt)],
);

/**
 * Kurzlebige WebAuthn-Challenges und Registrierungszustände (Passkey-/Passwort-Einrichtung): einmal einlösbar,
 * wenige Minuten gültig, werden beim Einlösen gelöscht (DELETE ... RETURNING) und vom Aufräum-Job bereinigt.
 */
export const webauthnChallenges = pgTable(
  'webauthn_challenges',
  {
    id: id(),
    /** login | register_passkey | register_password | add_passkey | add_password | step_up */
    purpose: text('purpose').notNull(),
    challenge: text('challenge').notNull(),
    userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }),
    data: jsonb('data').$type<Record<string, unknown>>().notNull().default({}),
    createdAt: createdAt(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  },
  (t) => [index('webauthn_challenges_expires_idx').on(t.expiresAt)],
);

/** Fehlversuche je Schlüssel (HMACs: "ip:" je IP/IPv6-/64, "acct:" je Konto, "acip:" je Konto+IP) mit verzögerter Sperre. */
export const loginAttempts = pgTable(
  'login_attempts',
  {
    key: text('key').primaryKey(),
    failCount: integer('fail_count').notNull().default(0),
    windowStartedAt: timestamp('window_started_at', { withTimezone: true }).notNull().defaultNow(),
    lastFailedAt: timestamp('last_failed_at', { withTimezone: true }).notNull().defaultNow(),
    lockedUntil: timestamp('locked_until', { withTimezone: true }),
  },
  (t) => [index('login_attempts_last_failed_idx').on(t.lastFailedAt)],
);

/** Einmal-Tickets für die WebSocket-Anmeldung: nur der Hash wird gespeichert, 30 s gültig, einmal einlösbar. */
export const wsTickets = pgTable(
  'ws_tickets',
  {
    tokenHash: text('token_hash').primaryKey(),
    familyId: familyRef(),
    userId: uuid('user_id').notNull(),
    sessionId: uuid('session_id')
      .notNull()
      .references(() => sessions.id, { onDelete: 'cascade' }),
    createdAt: createdAt(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  },
  (t) => [
    index('ws_tickets_expires_idx').on(t.expiresAt),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
  ],
);

/** Bereits verarbeitete Client-Operationen (op_id): ein wiederholter Upload derselben Op ändert nichts. */
export const appliedOps = pgTable(
  'applied_ops',
  {
    familyId: familyRef(),
    opId: uuid('op_id').notNull(),
    deviceId: uuid('device_id').references(() => devices.id, { onDelete: 'set null' }),
    /** Revision, unter der die Op übernommen wurde (null: abgelehnt oder ohne Wirkung). */
    rev: bigint('rev', { mode: 'number' }),
    /** acked (übernommen, ggf. mit Konflikten) | rejected (abgelehnt, dann code). Ein wiederholter Upload liefert dasselbe Ergebnis. */
    status: text('status').notNull().default('acked'),
    code: text('code'),
    /**
     * Konflikte der Op: nur die Namen der Felder, die nicht übernommen wurden (nie Werte: Werte könnten bei einer Wiederholung
     * Inhalte offenlegen, die die Person inzwischen nicht mehr sehen darf). Eine Wiederholung prüft die Rechte neu und liefert den aktuellen Stand.
     */
    conflicts: jsonb('conflicts').$type<Array<{ fields: string[]; serverRev: number }>>().notNull().default([]),
    /** Ziel der Op (für die Konflikt-Antwort einer Wiederholung). */
    entity: text('entity'),
    entityId: uuid('entity_id'),
    createdAt: createdAt(),
  },
  (t) => [
    primaryKey({ columns: [t.familyId, t.opId] }),
    index('applied_ops_created_idx').on(t.createdAt),
    index('applied_ops_device_idx').on(t.deviceId, t.createdAt),
    check('applied_ops_status_ck', sql`${t.status} in ('acked', 'rejected')`),
  ],
);

/** Änderungsprotokoll: pro Familie fortlaufende Revision, Löschungen bleiben als Tombstone stehen. */
export const changeLog = pgTable(
  'change_log',
  {
    familyId: familyRef(),
    rev: bigint('rev', { mode: 'number' }).notNull(),
    entity: text('entity').notNull(),
    entityId: uuid('entity_id').notNull(),
    tombstone: boolean('tombstone').notNull().default(false),
    /** Anlage der Entität (false: Änderung); für die Erkennung "nicht mehr sichtbar" (Freigabe zurückgenommen). */
    created: boolean('created').notNull().default(false),
    /** Geänderte Felder mit neuen Werten (leer bei Tombstone). */
    changes: jsonb('changes').$type<Record<string, unknown>>().notNull().default({}),
    authorId: uuid('author_id').references(() => users.id, { onDelete: 'set null' }),
    deviceId: uuid('device_id').references(() => devices.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
  },
  (t) => [
    primaryKey({ columns: [t.familyId, t.rev] }),
    index('change_log_entity_idx').on(t.familyId, t.entity, t.entityId),
    index('change_log_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.tombstone}`),
  ],
);

/**
 * Termine (Phase 1c-2a). Familienzeitzone ist fest Europe/Berlin; jeder Zeittermin trägt aber seine IANA-Zeitzone (`tzid`), in der die
 * Wiederholung gerechnet wird (Wanduhrzeit der Zeitzone, Sommerzeit bleibt erhalten).
 *  - Zeittermine: `start_utc`/`end_utc` (Zeitpunkte) + `tzid`.
 *  - Ganztägige Termine: `start_date`/`end_date` (Kalendertage ohne Uhrzeit und Zeitzone, Ende exklusiv wie in iCalendar).
 *  - `rrule`: RFC-5545-Text ohne Präfix (UNTIL bei Zeitterminen in UTC, bei ganztägigen als Datum).
 * Die Felder der jeweils anderen Art dürfen als Rest stehen bleiben (beim Umschalten); maßgeblich ist `ganztaegig`.
 */
export const termine = pgTable(
  'termine',
  {
    id: id(),
    familyId: familyRef(),
    titel: text('titel').notNull(),
    ort: text('ort').notNull().default(''),
    beschreibung: text('beschreibung').notNull().default(''),
    ganztaegig: boolean('ganztaegig').notNull().default(false),
    startUtc: timestamp('start_utc', { withTimezone: true }),
    endUtc: timestamp('end_utc', { withTimezone: true }),
    tzid: text('tzid'),
    startDate: date('start_date', { mode: 'string' }),
    endDate: date('end_date', { mode: 'string' }),
    rrule: text('rrule'),
    /** Erinnerung in Minuten vor dem Beginn (null: keine); wird mit dem Termin synchronisiert. */
    erinnerungMin: integer('erinnerung_min'),
    /** UID aus iCalendar für den späteren Import (Duplikaterkennung). */
    icalUid: text('ical_uid'),
    /** Wer den Termin sehen darf (wie bei Listen); Standard: die Familie ohne Gäste. */
    audience: listAudience('audience').notNull().default('family'),
    /** Wer den Termin angelegt hat (setzt der Server, bestimmt die Personenfarbe; Kinder ändern nur eigene Termine). */
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('termine_family_start_idx').on(t.familyId, t.startUtc),
    index('termine_family_rev_idx').on(t.familyId, t.rev),
    index('termine_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('termine_owner_idx')
      .on(t.familyId, t.ownerId)
      .where(sql`${t.ownerId} is not null`),
    index('termine_ical_uid_idx')
      .on(t.familyId, t.icalUid)
      .where(sql`${t.icalUid} is not null`),
    unique('termine_family_id_uq').on(t.familyId, t.id),
    check('termine_titel_len_ck', sql`char_length(${t.titel}) <= 200`),
    check('termine_ort_len_ck', sql`char_length(${t.ort}) <= 200`),
    check('termine_beschreibung_len_ck', sql`char_length(${t.beschreibung}) <= 4000`),
    check('termine_rrule_len_ck', sql`${t.rrule} is null or char_length(${t.rrule}) <= 300`),
    check('termine_erinnerung_ck', sql`${t.erinnerungMin} is null or ${t.erinnerungMin} between 0 and 40320`),
    check(
      'termine_zeit_ck',
      sql`(${t.ganztaegig} and ${t.startDate} is not null and ${t.endDate} is not null and ${t.endDate} > ${t.startDate})
        or (not ${t.ganztaegig} and ${t.startUtc} is not null and ${t.endUtc} is not null and ${t.tzid} is not null and ${t.endUtc} >= ${t.startUtc})`,
    ),
  ],
);

/** Teilnehmer eines Termins: je Person eine Zeile mit Sync-Spalten (Hinzufügen/Entfernen konfliktfrei). */
export const terminTeilnehmer = pgTable(
  'termin_teilnehmer',
  {
    id: id(),
    familyId: familyRef(),
    terminId: uuid('termin_id').notNull(),
    userId: uuid('user_id').notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.terminId], foreignColumns: [termine.familyId, termine.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    // eine aktive Zeile je Person und Termin; entfernte Teilnehmer bleiben als Tombstone stehen
    uniqueIndex('termin_teilnehmer_active_uq')
      .on(t.terminId, t.userId)
      .where(sql`${t.deletedAt} is null`),
    index('termin_teilnehmer_user_idx').on(t.userId),
    index('termin_teilnehmer_family_rev_idx').on(t.familyId, t.rev),
    index('termin_teilnehmer_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
  ],
);

/**
 * Ausnahmen einer Terminserie: eine Zeile je (Termin, Beginn des ursprünglichen Vorkommens). `original_start` ist unveränderlich:
 * bei Zeitterminen der Beginn in UTC (`YYYY-MM-DDTHH:MM:SSZ`), bei ganztägigen das Datum (`YYYY-MM-DD`). `abgesagt` blendet das Vorkommen
 * aus; die übrigen Felder überschreiben (null: unverändert). Wird nur noch geändert, nicht gelöscht (Zurücksetzen = alle Felder leer).
 */
export const terminAusnahmen = pgTable(
  'termin_ausnahmen',
  {
    id: id(),
    familyId: familyRef(),
    terminId: uuid('termin_id').notNull(),
    originalStart: text('original_start').notNull(),
    abgesagt: boolean('abgesagt').notNull().default(false),
    titel: text('titel'),
    start: text('start'),
    ende: text('ende'),
    ort: text('ort'),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.terminId], foreignColumns: [termine.familyId, termine.id] }).onDelete('cascade'),
    uniqueIndex('termin_ausnahmen_active_uq')
      .on(t.terminId, t.originalStart)
      .where(sql`${t.deletedAt} is null`),
    index('termin_ausnahmen_family_rev_idx').on(t.familyId, t.rev),
    index('termin_ausnahmen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('termin_ausnahmen_original_len_ck', sql`char_length(${t.originalStart}) between 10 and 20`),
    check('termin_ausnahmen_titel_len_ck', sql`${t.titel} is null or char_length(${t.titel}) <= 200`),
    check('termin_ausnahmen_ort_len_ck', sql`${t.ort} is null or char_length(${t.ort}) <= 200`),
    check('termin_ausnahmen_zeit_len_ck', sql`(${t.start} is null or char_length(${t.start}) between 10 and 20) and (${t.ende} is null or char_length(${t.ende}) between 10 and 20)`),
  ],
);

export const lists = pgTable(
  'lists',
  {
    id: id(),
    familyId: familyRef(),
    name: text('name').notNull(),
    kind: listKind('kind').notNull().default('custom'),
    audience: listAudience('audience').notNull().default('family'),
    /** Wer die Liste angelegt hat (setzt der Server; Kinder dürfen nur eigene Listen ändern). Wird beim Entfernen der Person NULL. */
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('lists_family_rev_idx').on(t.familyId, t.rev),
    index('lists_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('lists_owner_idx')
      .on(t.familyId, t.ownerId)
      .where(sql`${t.ownerId} is not null`),
    unique('lists_family_id_uq').on(t.familyId, t.id),
    check('lists_name_len_ck', sql`char_length(${t.name}) <= 100`),
  ],
);

/** Listeneinträge werden einzeln synchronisiert (Abhaken gewinnt nicht gegen gleichzeitiges Umbenennen). */
export const listItems = pgTable(
  'list_items',
  {
    id: id(),
    familyId: familyRef(),
    listId: uuid('list_id').notNull(),
    text: text('text').notNull(),
    assigneeId: uuid('assignee_id').references(() => users.id, { onDelete: 'set null' }),
    doneAt: timestamp('done_at', { withTimezone: true }),
    /** Sortierung innerhalb der Liste: Kommazahl, neue Position zwischen zwei Nachbarn = Mittelwert (nur das verschobene Feld ändert sich). */
    position: doublePrecision('position').notNull().default(0),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.listId], foreignColumns: [lists.familyId, lists.id] }).onDelete('cascade'),
    index('list_items_list_idx').on(t.listId),
    index('list_items_family_rev_idx').on(t.familyId, t.rev),
    index('list_items_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('list_items_assignee_idx')
      .on(t.familyId, t.assigneeId)
      .where(sql`${t.assigneeId} is not null`),
    check('list_items_text_len_ck', sql`char_length(${t.text}) <= 500`),
    check('list_items_position_ck', sql`${t.position} between -1e12 and 1e12`),
  ],
);

export const tasks = pgTable(
  'tasks',
  {
    id: id(),
    familyId: familyRef(),
    title: text('title').notNull(),
    dueAt: timestamp('due_at', { withTimezone: true }),
    assigneeId: uuid('assignee_id').references(() => users.id, { onDelete: 'set null' }),
    doneAt: timestamp('done_at', { withTimezone: true }),
    rrule: text('rrule'),
    remindMinutes: integer('remind_minutes'),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('tasks_family_due_idx').on(t.familyId, t.dueAt),
    index('tasks_family_rev_idx').on(t.familyId, t.rev),
  ],
);

/** Dateien sind unveränderlich: eine neue Fassung ist ein neuer Eintrag mit gleichem version_of. */
export const files = pgTable(
  'files',
  {
    id: id(),
    familyId: familyRef(),
    kind: fileKind('kind').notNull().default('file'),
    parentId: uuid('parent_id'),
    name: text('name').notNull(),
    mime: text('mime'),
    size: bigint('size', { mode: 'number' }),
    sha256: text('sha256'),
    /** Schlüssel der verschlüsselten Datei unterhalb von FILES_DIR (nie ein Nutzerpfad). */
    storageKey: text('storage_key'),
    /** Pro Datei verpackter AES-256-GCM-Schlüssel (Hauptschlüssel liegt außerhalb des Datenverzeichnisses). */
    wrappedKey: text('wrapped_key'),
    versionOf: uuid('version_of'),
    version: integer('version').notNull().default(1),
    uploadedBy: uuid('uploaded_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('files_family_parent_idx').on(t.familyId, t.parentId),
    index('files_family_rev_idx').on(t.familyId, t.rev),
    unique('files_family_id_uq').on(t.familyId, t.id),
    // Ordner und Dateien liegen immer in derselben Familie
    foreignKey({ columns: [t.familyId, t.parentId], foreignColumns: [t.familyId, t.id] }).onDelete('cascade'),
  ],
);

/** Chat: nur Anhängen. Veränderlich sind nur Lesestatus und Reaktionen, nie der Text. */
export const messages = pgTable(
  'messages',
  {
    id: id(),
    familyId: familyRef(),
    /** Unterhaltung; "family" ist der Familien-Chat, sonst eine Gruppen-/Einzelchat-ID. */
    chatId: text('chat_id').notNull().default('family'),
    senderId: uuid('sender_id').references(() => users.id, { onDelete: 'set null' }),
    body: text('body').notNull().default(''),
    fileId: uuid('file_id').references(() => files.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('messages_chat_idx').on(t.familyId, t.chatId, t.createdAt),
    index('messages_family_rev_idx').on(t.familyId, t.rev),
    unique('messages_family_id_uq').on(t.familyId, t.id),
  ],
);

/** Reaktionen: je Person und Emoji eine Zeile mit Sync-Spalten (Entfernen = Tombstone), kein JSON in messages. */
export const messageReactions = pgTable(
  'message_reactions',
  {
    id: id(),
    familyId: familyRef(),
    messageId: uuid('message_id').notNull(),
    userId: uuid('user_id').notNull(),
    emoji: text('emoji').notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.messageId], foreignColumns: [messages.familyId, messages.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('message_reactions_active_uq')
      .on(t.messageId, t.userId, t.emoji)
      .where(sql`${t.deletedAt} is null`),
    index('message_reactions_user_idx').on(t.userId),
    index('message_reactions_family_rev_idx').on(t.familyId, t.rev),
    check('message_reactions_emoji_len_ck', sql`char_length(${t.emoji}) between 1 and 32`),
  ],
);

/** Lesebestätigungen: je Person und Nachricht eine Zeile (gelesen bleibt gelesen). */
export const messageReads = pgTable(
  'message_reads',
  {
    id: id(),
    familyId: familyRef(),
    messageId: uuid('message_id').notNull(),
    userId: uuid('user_id').notNull(),
    readAt: timestamp('read_at', { withTimezone: true }).notNull().defaultNow(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.messageId], foreignColumns: [messages.familyId, messages.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('message_reads_message_user_uq').on(t.messageId, t.userId),
    index('message_reads_user_idx').on(t.userId),
    index('message_reads_family_rev_idx').on(t.familyId, t.rev),
  ],
);
