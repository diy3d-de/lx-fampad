// Datenbankschema (PostgreSQL 17) für Phase 1. Jede fachliche Tabelle trägt family_id, auch wenn der
// Server genau eine Familie bedient. Änderbare Tabellen führen die Sync-Spalten (rev, field_revs,
// updated_at, deleted_at); jede Änderung erzeugt zusätzlich einen Eintrag in change_log.
import { sql } from 'drizzle-orm';
import {
  bigint,
  boolean,
  check,
  date,
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
export const credentialType = pgEnum('credential_type', ['passkey', 'totp', 'password']);
export const listKind = pgEnum('list_kind', ['shopping', 'packing', 'custom']);
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
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex('memberships_family_user_uq').on(t.familyId, t.userId), index('memberships_user_idx').on(t.userId)],
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
  },
  (t) => [index('invites_family_idx').on(t.familyId)],
);

export const devices = pgTable(
  'devices',
  {
    id: id(),
    familyId: familyRef(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
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
    createdAt: createdAt(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }),
  },
  (t) => [
    index('devices_user_idx').on(t.userId),
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
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    deviceId: uuid('device_id'),
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
    /** SHA-256 des Codes (der Code hat genug Zufall, ein schneller Hash genügt); nie der Klartext. */
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
  (t) => [index('audit_log_family_created_idx').on(t.familyId, t.createdAt), index('audit_log_actor_idx').on(t.actorId)],
);

/** Bereits verarbeitete Client-Operationen (op_id): ein wiederholter Upload derselben Op ändert nichts. */
export const appliedOps = pgTable(
  'applied_ops',
  {
    familyId: familyRef(),
    opId: uuid('op_id').notNull(),
    deviceId: uuid('device_id').references(() => devices.id, { onDelete: 'set null' }),
    /** Revision, unter der die Op übernommen wurde (null: abgelehnt, Antwort bleibt gleich). */
    rev: bigint('rev', { mode: 'number' }),
    createdAt: createdAt(),
  },
  (t) => [primaryKey({ columns: [t.familyId, t.opId] }), index('applied_ops_created_idx').on(t.createdAt)],
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
    /** Geänderte Felder mit neuen Werten (leer bei Tombstone). */
    changes: jsonb('changes').$type<Record<string, unknown>>().notNull().default({}),
    authorId: uuid('author_id').references(() => users.id, { onDelete: 'set null' }),
    deviceId: uuid('device_id').references(() => devices.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
  },
  (t) => [
    primaryKey({ columns: [t.familyId, t.rev] }),
    index('change_log_entity_idx').on(t.familyId, t.entity, t.entityId),
  ],
);

export const events = pgTable(
  'events',
  {
    id: id(),
    familyId: familyRef(),
    title: text('title').notNull(),
    description: text('description'),
    location: text('location'),
    /** Zeitgebundene Termine: Zeitpunkt (UTC). Bei ganztägigen Terminen null, dann gelten starts_on/ends_on. */
    startsAt: timestamp('starts_at', { withTimezone: true }),
    endsAt: timestamp('ends_at', { withTimezone: true }),
    /** Ganztägige Termine sind Kalendertage ohne Uhrzeit und Zeitzone (ends_on einschließlich). */
    startsOn: date('starts_on', { mode: 'string' }),
    endsOn: date('ends_on', { mode: 'string' }),
    allDay: boolean('all_day').notNull().default(false),
    /** Wiederholung als RRULE-Text (RFC 5545). */
    rrule: text('rrule'),
    remindMinutes: integer('remind_minutes'),
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    index('events_family_start_idx').on(t.familyId, t.startsAt),
    index('events_family_start_on_idx').on(t.familyId, t.startsOn),
    index('events_family_rev_idx').on(t.familyId, t.rev),
    unique('events_family_id_uq').on(t.familyId, t.id),
    check(
      'events_time_kind_ck',
      sql`(${t.allDay} and ${t.startsOn} is not null and ${t.startsAt} is null and ${t.endsAt} is null)
        or (not ${t.allDay} and ${t.startsAt} is not null and ${t.startsOn} is null and ${t.endsOn} is null)`,
    ),
    check('events_end_on_ck', sql`${t.endsOn} is null or ${t.endsOn} >= ${t.startsOn}`),
  ],
);

/** Teilnehmer eines Termins: je Person eine Zeile mit Sync-Spalten (Hinzufügen/Entfernen konfliktfrei). */
export const eventAttendees = pgTable(
  'event_attendees',
  {
    id: id(),
    familyId: familyRef(),
    eventId: uuid('event_id').notNull(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.eventId], foreignColumns: [events.familyId, events.id] }).onDelete('cascade'),
    // eine aktive Zeile je Person und Termin; entfernte Teilnehmer bleiben als Tombstone stehen
    uniqueIndex('event_attendees_active_uq')
      .on(t.eventId, t.userId)
      .where(sql`${t.deletedAt} is null`),
    index('event_attendees_user_idx').on(t.userId),
    index('event_attendees_family_rev_idx').on(t.familyId, t.rev),
  ],
);

export const lists = pgTable(
  'lists',
  {
    id: id(),
    familyId: familyRef(),
    name: text('name').notNull(),
    kind: listKind('kind').notNull().default('custom'),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [index('lists_family_rev_idx').on(t.familyId, t.rev), unique('lists_family_id_uq').on(t.familyId, t.id)],
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
    position: integer('position').notNull().default(0),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.listId], foreignColumns: [lists.familyId, lists.id] }).onDelete('cascade'),
    index('list_items_list_idx').on(t.listId),
    index('list_items_family_rev_idx').on(t.familyId, t.rev),
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
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    emoji: text('emoji').notNull(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.messageId], foreignColumns: [messages.familyId, messages.id] }).onDelete('cascade'),
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
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    readAt: timestamp('read_at', { withTimezone: true }).notNull().defaultNow(),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.messageId], foreignColumns: [messages.familyId, messages.id] }).onDelete('cascade'),
    uniqueIndex('message_reads_message_user_uq').on(t.messageId, t.userId),
    index('message_reads_user_idx').on(t.userId),
    index('message_reads_family_rev_idx').on(t.familyId, t.rev),
  ],
);
