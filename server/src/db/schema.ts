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
  customType,
  type AnyPgColumn,
} from 'drizzle-orm/pg-core';

/** Binärdaten (bytea) als Buffer. */
const bytea = customType<{ data: Buffer; driverData: Buffer | Uint8Array }>({
  dataType: () => 'bytea',
  fromDriver: (v) => Buffer.from(v),
});

/** Reine Anzeige-Familienrolle (ändert keine Rechte); feste Liste, in der Datenbank per CHECK abgesichert. */
export const FAMILY_ROLES = ['vater', 'mutter', 'elternteil', 'kind', 'grosseltern', 'sonstige'] as const;
export type FamilyRole = (typeof FAMILY_ROLES)[number];

export const memberRole = pgEnum('member_role', ['admin', 'parent', 'child']);
/** pending: per Einladung mit Freigabe registriert, darf sich erst nach Freigabe durch einen Admin anmelden. */
export const memberStatus = pgEnum('member_status', ['active', 'pending']);
export const credentialType = pgEnum('credential_type', ['passkey', 'totp', 'password']);
export const listKind = pgEnum('list_kind', ['shopping', 'packing', 'custom']);
/** Wer eine Liste oder einen Termin sehen darf: nur Eltern/Admins oder die ganze Familie (Eingaben alter Apps mit "all" werden auf "family" abgebildet). */
export const listAudience = pgEnum('list_audience', ['parents', 'family']);
export const fileKind = pgEnum('file_kind', ['file', 'folder']);
/** Art einer Konversation: der Familienchat (genau einer je Familie), ein Direktchat (zwei Personen) oder eine Gruppe. */
export const konversationArt = pgEnum('konversation_art', ['family', 'direct', 'group']);

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
    /** Benutzerbild: null = keines (Initialen), 'preset' = Platzhalter aus avatar_preset, 'photo' = Foto in user_avatars. */
    avatarKind: text('avatar_kind'),
    avatarPreset: text('avatar_preset'),
    /** Zählt jede Änderung des Benutzerbilds hoch (Cache-Schlüssel und ETag der Apps). */
    avatarVersion: integer('avatar_version').notNull().default(0),
  },
  (t) => [
    uniqueIndex('users_email_lower_uq').on(sql`lower(${t.email})`),
    check('users_avatar_ck', sql`(${t.avatarKind} is null and ${t.avatarPreset} is null) or (${t.avatarKind} = 'preset' and ${t.avatarPreset} is not null) or (${t.avatarKind} = 'photo' and ${t.avatarPreset} is null)`),
  ],
);

/** Hochgeladenes Benutzerfoto (klein, von der App auf etwa 512x512 verkleinert); je Person höchstens eines, Teil des normalen Datenbank-Backups. */
export const userAvatars = pgTable(
  'user_avatars',
  {
    userId: uuid('user_id')
      .primaryKey()
      .references(() => users.id, { onDelete: 'cascade' }),
    contentType: text('content_type').notNull(),
    width: integer('width').notNull(),
    height: integer('height').notNull(),
    data: bytea('data').notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    check('user_avatars_type_ck', sql`${t.contentType} in ('image/png', 'image/jpeg', 'image/webp')`),
    check('user_avatars_size_ck', sql`octet_length(${t.data}) between 1 and 524288 and ${t.width} between 1 and 1024 and ${t.height} between 1 and 1024`),
  ],
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
    /** Nur Anzeige (z. B. "Elternteil" neben Admin); null = nicht gesetzt. */
    familyRole: text('family_role'),
    createdAt: createdAt(),
  },
  (t) => [
    // Ziel der zusammengesetzten Fremdschlüssel (family_id, user_id): Verweise auf Personen bleiben in der Familie
    unique('memberships_family_user_uq').on(t.familyId, t.userId),
    index('memberships_user_idx').on(t.userId),
    check('memberships_family_role_ck', sql`${t.familyRole} is null or ${t.familyRole} in ('vater', 'mutter', 'elternteil', 'kind', 'grosseltern', 'sonstige')`),
  ],
);

/**
 * E2EE: öffentliche Personenschlüssel (ein Paar je Person, alle Geräte teilen es): X25519 für Sealed Boxes, Ed25519 für
 * Signaturen, je 32 Byte als Base64url. Der Server hält nie ein Geheimnis; key_version zählt Wechsel (die Apps warnen davor).
 */
export const personKeys = pgTable(
  'person_keys',
  {
    userId: uuid('user_id')
      .primaryKey()
      .references(() => users.id, { onDelete: 'cascade' }),
    publicEncKey: text('public_enc_key').notNull(),
    publicSignKey: text('public_sign_key').notNull(),
    keyVersion: integer('key_version').notNull().default(1),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [check('person_keys_version_pos', sql`${t.keyVersion} >= 1`)],
);

/**
 * E2EE: Historie früherer öffentlicher Schlüssel (nur anhängend: es gibt keine Änderungs- oder Löschroute, Zeilen verschwinden nur mit dem Konto).
 * Beim Schlüsselwechsel wandert der alte Stand hierher; so lassen sich Signaturen älterer Nachrichten gegen die damalige key_version prüfen.
 */
export const personKeyHistory = pgTable(
  'person_key_history',
  {
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    keyVersion: integer('key_version').notNull(),
    encKey: text('enc_key').notNull(),
    signKey: text('sign_key').notNull(),
    validFrom: timestamp('valid_from', { withTimezone: true }).notNull(),
    validUntil: timestamp('valid_until', { withTimezone: true }).notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.keyVersion] })],
);

/** E2EE: opake Sicherung des Personenschlüssels (mit dem Wiederherstellungsschlüssel verschlüsselt, der Server kann sie nicht lesen). */
export const keyBackups = pgTable('key_backups', {
  userId: uuid('user_id')
    .primaryKey()
    .references(() => users.id, { onDelete: 'cascade' }),
  blob: text('blob').notNull(),
  /** Zu welcher key_version des Personenschlüssels die Sicherung gehört. */
  keyVersion: integer('key_version').notNull(),
  createdAt: createdAt(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
});

/**
 * E2EE (vereinfachte Schlüsselverwaltung, Schalter E2EE_PW_BACKUP): aktuelle Salt-Generation je Konto. Den Salt der Passwort-Ableitung
 * bestimmt immer der Server, deterministisch aus E-Mail und Generation (HMAC, siehe auth/keys-pw.ts); hier steht nur die Generation
 * (Standard 1, auch für Konten ohne Zeile). Der Client liefert nie einen Salt. Passwort, authKey und kek kennt der Server nie.
 */
export const accountKdf = pgTable(
  'account_kdf',
  {
    userId: uuid('user_id')
      .primaryKey()
      .references(() => users.id, { onDelete: 'cascade' }),
    saltGeneration: integer('salt_generation').notNull().default(1),
    createdAt: createdAt(),
  },
  (t) => [check('account_kdf_generation_ck', sql`${t.saltGeneration} >= 1`)],
);

/**
 * E2EE (Schalter E2EE_PW_BACKUP): opake, mit dem Passwort-Schlüssel (kek, nur auf dem Gerät) verschlüsselte Sicherung des
 * Personenschlüssels. Jede Zeile trägt ihren eigenen Ableitungssatz (kdf_id, mem_kib, ops, salt_generation), so bleiben auch ältere
 * Zeilen lesbar. Zeilen werden nie gelöscht (nur mit dem Konto): eine neue Sicherung setzt die bisherige auf `superseded`, ein
 * Schlüsselwechsel (Rotation) die aktuelle auf `stale` (enthält dann den alten Schlüssel und darf nie als Wiederherstellung des
 * aktuellen gelten). Höchstens eine Zeile je Person ist `active` oder `stale` (die aktuelle).
 */
export const keyBackupsPw = pgTable(
  'key_backups_pw',
  {
    id: id(),
    userId: uuid('user_id').notNull(),
    familyId: familyRef(),
    blob: text('blob').notNull(),
    keyVersion: integer('key_version').notNull(),
    kdfId: text('kdf_id').notNull(),
    memKib: integer('mem_kib').notNull(),
    ops: integer('ops').notNull(),
    saltGeneration: integer('salt_generation').notNull(),
    state: text('state').notNull().default('active'),
    /** Erst nach der Round-Trip-Probe der App gesetzt. */
    verifiedAt: timestamp('verified_at', { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('key_backups_pw_current_uq').on(t.userId).where(sql`${t.state} in ('active', 'stale')`),
    index('key_backups_pw_user_idx').on(t.userId),
    check('key_backups_pw_state_ck', sql`${t.state} in ('active', 'stale', 'superseded')`),
    check('key_backups_pw_size_ck', sql`length(${t.blob}) between 96 and 4096 and ${t.keyVersion} >= 1`),
    // festes Profil: kein Herabsetzen der Kosten über den Server (Untergrenze auch in der App)
    check('key_backups_pw_kdf_ck', sql`${t.kdfId} in ('argon2id-v1') and ${t.memKib} >= 65536 and ${t.ops} >= 3 and ${t.saltGeneration} >= 1`),
  ],
);

/**
 * E2EE: kurzlebige Geräte-Übertragung des Personenschlüssels (QR). Gespeichert wird nur der Hash der Suchkennung; der Blob ist mit
 * einem Einmalschlüssel verschlüsselt, den der Server nie sieht. Höchstens eine je Person, einmal einlösbar (DELETE ... RETURNING).
 */
export const keyTransfers = pgTable('key_transfers', {
  userId: uuid('user_id')
    .primaryKey()
    .references(() => users.id, { onDelete: 'cascade' }),
  lookupHash: text('lookup_hash').notNull().unique(),
  blob: text('blob').notNull(),
  keyVersion: integer('key_version').notNull(),
  createdAt: createdAt(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
});

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

/**
 * UnifiedPush-Endpunkt je Gerät (Wecker ohne Inhalt, siehe docs/API.md "Push"). Gespeichert wird nur das Topic aus dem Endpunkt
 * (ntfy: "up" + 12 Zeichen); gepostet wird nie an die vom Gerät gemeldete URL, sondern an die Loopback-URL des eigenen ntfy.
 * Die Zeile verschwindet mit dem Gerät (ON DELETE CASCADE) und beim Abmelden/Widerruf (explizit gelöscht).
 */
export const pushEndpoints = pgTable(
  'push_endpoints',
  {
    deviceId: uuid('device_id').primaryKey(),
    familyId: familyRef(),
    topic: text('topic').notNull(),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
    lastOkAt: timestamp('last_ok_at', { withTimezone: true }),
    lastErrorAt: timestamp('last_error_at', { withTimezone: true }),
    /** Aufeinanderfolgende Fehlschläge; ab der Grenze (push/service.ts) wird der Endpunkt deaktiviert. */
    failCount: integer('fail_count').notNull().default(0),
    /** Deaktiviert (ntfy meldet 404/410 oder wiederholte Fehler): kein Versand, bis das Gerät sich neu anmeldet (PUT /me/push). */
    disabledAt: timestamp('disabled_at', { withTimezone: true }),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.deviceId], foreignColumns: [devices.familyId, devices.id] }).onDelete('cascade'),
    unique('push_endpoints_topic_uq').on(t.topic),
    index('push_endpoints_family_idx').on(t.familyId),
    check('push_endpoints_topic_ck', sql`${t.topic} ~ '^up[A-Za-z0-9_-]{12,64}$'`),
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
    /** Wer den Termin sehen darf (wie bei Listen); Standard: die Familie. */
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

/**
 * Aufgaben (To-dos, Phase 1c-4a). Fälligkeit wie bei Terminen: ein Kalendertag (`faellig_date`, ganztägig) ODER ein Zeitpunkt in UTC
 * (`faellig_utc`) mit IANA-Zeitzone (`tzid`); beides leer = ohne Fälligkeit. Wiederholung einfach (täglich/wöchentlich/monatlich): Beim Erledigen
 * legt der Client die nächste Aufgabe an (feste ID aus der erledigten Aufgabe), der Server prüft nur die Form.
 */
export const aufgaben = pgTable(
  'aufgaben',
  {
    id: id(),
    familyId: familyRef(),
    titel: text('titel').notNull(),
    beschreibung: text('beschreibung').notNull().default(''),
    faelligDate: date('faellig_date', { mode: 'string' }),
    faelligUtc: timestamp('faellig_utc', { withTimezone: true }),
    tzid: text('tzid'),
    /** 0 keine, 1 niedrig, 2 mittel, 3 hoch. */
    prioritaet: integer('prioritaet').notNull().default(0),
    assigneeId: uuid('assignee_id').references(() => users.id, { onDelete: 'set null' }),
    erledigtAt: timestamp('erledigt_at', { withTimezone: true }),
    erledigtVon: uuid('erledigt_von').references(() => users.id, { onDelete: 'set null' }),
    /** ID der Folgeaufgabe, die beim Erledigen entstand (der Client wählt sie: abgeleitet oder, bei belegter ID, zufällig). */
    folgeId: uuid('folge_id'),
    /** Wunschtag des Monats (1 bis 31) bei monatlicher Wiederholung: bleibt in der Kette erhalten (der 31. wird im Februar der 28., im März wieder der 31.). */
    wiederholungTag: integer('wiederholung_tag'),
    /** daily, weekly, monthly oder leer. */
    wiederholung: text('wiederholung'),
    /** Erinnerung in Minuten vor der Fälligkeit (null: keine). */
    erinnerungMin: integer('erinnerung_min'),
    audience: listAudience('audience').notNull().default('family'),
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('aufgaben_family_rev_idx').on(t.familyId, t.rev),
    index('aufgaben_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('aufgaben_owner_idx')
      .on(t.familyId, t.ownerId)
      .where(sql`${t.ownerId} is not null`),
    index('aufgaben_assignee_idx')
      .on(t.familyId, t.assigneeId)
      .where(sql`${t.assigneeId} is not null`),
    unique('aufgaben_family_id_uq').on(t.familyId, t.id),
    check('aufgaben_titel_len_ck', sql`char_length(${t.titel}) <= 200`),
    check('aufgaben_beschreibung_len_ck', sql`char_length(${t.beschreibung}) <= 4000`),
    check('aufgaben_prioritaet_ck', sql`${t.prioritaet} between 0 and 3`),
    check('aufgaben_wiederholung_ck', sql`${t.wiederholung} is null or ${t.wiederholung} in ('daily', 'weekly', 'monthly')`),
    check('aufgaben_wdh_tag_ck', sql`${t.wiederholungTag} is null or ${t.wiederholungTag} between 1 and 31`),
    check('aufgaben_erinnerung_ck', sql`${t.erinnerungMin} is null or ${t.erinnerungMin} between 0 and 40320`),
    check(
      'aufgaben_faellig_ck',
      sql`(${t.faelligDate} is null or ${t.faelligUtc} is null) and (${t.faelligUtc} is null or ${t.tzid} is not null)`,
    ),
  ],
);

/** Unteraufgaben (Checkliste) einer Aufgabe, einzeln synchronisiert wie Listeneinträge. */
export const aufgabePunkte = pgTable(
  'aufgabe_punkte',
  {
    id: id(),
    familyId: familyRef(),
    aufgabeId: uuid('aufgabe_id').notNull(),
    text: text('text').notNull(),
    doneAt: timestamp('done_at', { withTimezone: true }),
    position: doublePrecision('position').notNull().default(0),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.aufgabeId], foreignColumns: [aufgaben.familyId, aufgaben.id] }).onDelete('cascade'),
    index('aufgabe_punkte_aufgabe_idx').on(t.aufgabeId),
    index('aufgabe_punkte_family_rev_idx').on(t.familyId, t.rev),
    index('aufgabe_punkte_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('aufgabe_punkte_text_len_ck', sql`char_length(${t.text}) <= 500`),
    check('aufgabe_punkte_position_ck', sql`${t.position} between -1e12 and 1e12`),
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

/**
 * Konversationen des Chats (Phase 1c-3a). `teilnehmer` (sortierte, eindeutige Mitglieds-IDs) bestimmt, wer Direkt- und Gruppenchats sieht:
 * nur sie, auch Admins nicht (sync/permissions.ts, Facts.participants). Im Familienchat ist die Liste leer, ihn sieht die ganze Familie.
 * `titel` ist ein undurchsichtiger Text (der Server wertet ihn nie aus; später verschlüsselbar).
 */
export const konversationen = pgTable(
  'konversationen',
  {
    id: id(),
    familyId: familyRef(),
    art: konversationArt('art').notNull(),
    titel: text('titel').notNull().default(''),
    /** Version der Inhaltshülle der Nachrichten dieser Konversation (`e1:` Ende-zu-Ende verschlüsselt, Standard; `p1:` Klartext nur für Altbestand); unveränderlich: schützt vor dem Zurückstufen verschlüsselter Chats. */
    encVersion: text('enc_version').notNull().default('e1'),
    teilnehmer: uuid('teilnehmer')
      .array()
      .notNull()
      .default(sql`'{}'::uuid[]`),
    /** Wer die Konversation angelegt hat (setzt der Server; null beim Familienchat und nach dem Entfernen der Person). */
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('konversationen_family_rev_idx').on(t.familyId, t.rev),
    index('konversationen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('konversationen_owner_idx')
      .on(t.familyId, t.ownerId)
      .where(sql`${t.ownerId} is not null`),
    unique('konversationen_family_id_uq').on(t.familyId, t.id),
    // genau ein Familienchat je Familie, ein Direktchat je Paar (Teilnehmer sind sortiert gespeichert)
    uniqueIndex('konversationen_family_chat_uq')
      .on(t.familyId)
      .where(sql`${t.art} = 'family' and ${t.deletedAt} is null`),
    uniqueIndex('konversationen_direct_uq')
      .on(t.familyId, t.teilnehmer)
      .where(sql`${t.art} = 'direct' and ${t.deletedAt} is null`),
    check('konversationen_titel_len_ck', sql`char_length(${t.titel}) <= 512`),
    check(
      'konversationen_teilnehmer_ck',
      sql`(${t.art} = 'family' and cardinality(${t.teilnehmer}) = 0)
        or (${t.art} = 'direct' and cardinality(${t.teilnehmer}) = 2)
        or (${t.art} = 'group' and cardinality(${t.teilnehmer}) between 2 and 20)`,
    ),
  ],
);

/**
 * Nachrichten. `text` ist ein undurchsichtiger String (Hülle mit Versionspräfix, siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6c): der
 * Server prüft nur die Länge und wertet den Inhalt nie aus (kein Volltext, keine Vorschau, kein Log). Der Autor wird beim Entfernen NULL.
 */
export const nachrichten = pgTable(
  'nachrichten',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    autorId: uuid('autor_id').references(() => users.id, { onDelete: 'set null' }),
    text: text('text').notNull(),
    /** Antwort auf eine andere Nachricht (nur die ID; der Client zeigt das Zitat, wenn er die Nachricht kennt). */
    antwortAuf: uuid('antwort_auf'),
    /** Zeitpunkt der letzten Bearbeitung des Textes (setzt der Server). */
    bearbeitetAt: timestamp('bearbeitet_at', { withTimezone: true }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('nachrichten_family_id_uq').on(t.familyId, t.id),
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('nachrichten_konversation_idx').on(t.familyId, t.konversationId, t.createdAt),
    index('nachrichten_family_rev_idx').on(t.familyId, t.rev),
    index('nachrichten_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('nachrichten_autor_idx')
      .on(t.familyId, t.autorId, t.createdAt)
      .where(sql`${t.autorId} is not null`),
    check('nachrichten_text_len_ck', sql`char_length(${t.text}) <= 16384`),
  ],
);

/** Lesestand: je Person und Konversation eine Zeile, nur für die Person selbst sichtbar. `gelesenBis` = Zeit (createdAt) der letzten gelesenen Nachricht. */
export const lesestand = pgTable(
  'lesestand',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    userId: uuid('user_id').notNull(),
    gelesenBis: timestamp('gelesen_bis', { withTimezone: true }).notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('lesestand_active_uq')
      .on(t.konversationId, t.userId)
      .where(sql`${t.deletedAt} is null`),
    index('lesestand_user_idx').on(t.userId),
    index('lesestand_family_rev_idx').on(t.familyId, t.rev),
    index('lesestand_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
  ],
);

/**
 * Reaktion einer Person auf eine Nachricht (Chat-Erweiterung, docs/PROJEKTBESCHREIBUNG.md 6c): feste ID je (Nachricht, Person). `inhalt` ist eine e1-Hülle (das Emoji
 * ist für den Server undurchsichtig). Besitzer ist die Person; verschwindet die Person aus der Familie, verschwindet ihre Reaktion.
 */
export const reaktionen = pgTable(
  'reaktionen',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    nachrichtId: uuid('nachricht_id').notNull(),
    userId: uuid('user_id').notNull(),
    inhalt: text('inhalt').notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.nachrichtId], foreignColumns: [nachrichten.familyId, nachrichten.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('reaktionen_active_uq')
      .on(t.nachrichtId, t.userId)
      .where(sql`${t.deletedAt} is null`),
    index('reaktionen_konversation_idx').on(t.familyId, t.konversationId),
    index('reaktionen_user_idx').on(t.familyId, t.userId, t.createdAt),
    index('reaktionen_family_rev_idx').on(t.familyId, t.rev),
    index('reaktionen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('reaktionen_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 512`),
  ],
);

/** Stimme einer Person zu einer Umfrage-Nachricht: feste ID je (Nachricht, Person); `inhalt` ist eine e1-Hülle (gewählte Optionen, für den Server undurchsichtig). */
export const stimmen = pgTable(
  'stimmen',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    nachrichtId: uuid('nachricht_id').notNull(),
    userId: uuid('user_id').notNull(),
    inhalt: text('inhalt').notNull(),
    /** Zeitpunkt der letzten Änderung der Stimme (setzt der Server; Grundlage für "Stimme nach Ende der Umfrage zählt nicht"). */
    geaendertAt: timestamp('geaendert_at', { withTimezone: true }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.nachrichtId], foreignColumns: [nachrichten.familyId, nachrichten.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('stimmen_active_uq')
      .on(t.nachrichtId, t.userId)
      .where(sql`${t.deletedAt} is null`),
    index('stimmen_konversation_idx').on(t.familyId, t.konversationId),
    index('stimmen_user_idx').on(t.familyId, t.userId, t.createdAt),
    index('stimmen_family_rev_idx').on(t.familyId, t.rev),
    index('stimmen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('stimmen_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 512`),
  ],
);

/** Angeheftete Nachricht: feste ID je Nachricht. Der Server sieht nur WELCHE Nachricht angeheftet ist, nie ihren Inhalt. `gepinntVon` wird beim Entfernen der Person NULL. */
export const pins = pgTable(
  'pins',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    nachrichtId: uuid('nachricht_id').notNull(),
    gepinntVon: uuid('gepinnt_von').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.nachrichtId], foreignColumns: [nachrichten.familyId, nachrichten.id] }).onDelete('cascade'),
    uniqueIndex('pins_active_uq')
      .on(t.nachrichtId)
      .where(sql`${t.deletedAt} is null`),
    index('pins_konversation_idx').on(t.familyId, t.konversationId),
    index('pins_family_rev_idx').on(t.familyId, t.rev),
    index('pins_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('pins_von_idx')
      .on(t.familyId, t.gepinntVon, t.createdAt)
      .where(sql`${t.gepinntVon} is not null`),
  ],
);

/**
 * Epochen einer verschlüsselten Konversation (E2EE Phase 2): je Epoche genau eine Zeile (feste, abgeleitete ID; der erste Schreiber gewinnt). `mitglieder` ist die
 * vom Verteiler signierte Mitgliederliste der Epoche als undurchsichtiger Text (der Server wertet sie nie aus). Kein Schlüsselmaterial.
 */
export const konversationEpochen = pgTable(
  'konversation_epochen',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    epoche: integer('epoche').notNull(),
    /** Wer die Epoche angelegt hat (setzt der Server; für die Mengenbegrenzung). */
    verteilerId: uuid('verteiler_id').references(() => users.id, { onDelete: 'set null' }),
    mitglieder: text('mitglieder').notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    unique('konversation_epochen_family_id_uq').on(t.familyId, t.id),
    uniqueIndex('konversation_epochen_uq')
      .on(t.familyId, t.konversationId, t.epoche)
      .where(sql`${t.deletedAt} is null`),
    index('konversation_epochen_family_rev_idx').on(t.familyId, t.rev),
    index('konversation_epochen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('konversation_epochen_verteiler_idx')
      .on(t.familyId, t.verteilerId, t.createdAt)
      .where(sql`${t.verteilerId} is not null`),
    check('konversation_epochen_epoche_ck', sql`${t.epoche} between 1 and 100000`),
    check('konversation_epochen_len_ck', sql`char_length(${t.mitglieder}) <= 16384`),
  ],
);

/**
 * Für eine Person verpackter Epochenschlüssel (E2EE Phase 2): Sealed Box plus Signatur des Verteilers, als undurchsichtiger Text. Nur der Empfänger liest seine Zeile.
 * Je (Konversation, Epoche, Empfänger) genau eine (feste, abgeleitete ID; der erste gewinnt).
 */
export const epocheWraps = pgTable(
  'epoche_wraps',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    epoche: integer('epoche').notNull(),
    empfaengerId: uuid('empfaenger_id').notNull(),
    verteilerId: uuid('verteiler_id').references(() => users.id, { onDelete: 'set null' }),
    wrap: text('wrap').notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.empfaengerId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('epoche_wraps_uq')
      .on(t.familyId, t.konversationId, t.epoche, t.empfaengerId)
      .where(sql`${t.deletedAt} is null`),
    index('epoche_wraps_empfaenger_idx').on(t.familyId, t.empfaengerId),
    index('epoche_wraps_family_rev_idx').on(t.familyId, t.rev),
    index('epoche_wraps_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('epoche_wraps_verteiler_idx')
      .on(t.familyId, t.verteilerId, t.createdAt)
      .where(sql`${t.verteilerId} is not null`),
    check('epoche_wraps_epoche_ck', sql`${t.epoche} between 1 and 100000`),
    check('epoche_wraps_len_ck', sql`char_length(${t.wrap}) <= 4096`),
  ],
);
