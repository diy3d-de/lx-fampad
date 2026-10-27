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
  smallint,
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
export const listKind = pgEnum('list_kind', ['shopping', 'packing', 'custom', 'template']);
/** Wer eine Liste oder einen Termin sehen darf: nur Eltern/Admins oder die ganze Familie (Eingaben alter Apps mit "all" werden auf "family" abgebildet). */
export const listAudience = pgEnum('list_audience', ['parents', 'family']);
/** Art einer Konversation: der Familienchat (genau einer je Familie), ein Direktchat (zwei Personen) oder eine Gruppe. */
export const konversationArt = pgEnum('konversation_art', ['family', 'direct', 'group', 'meds', 'zaehler', 'tresor']);

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
    /**
     * Soft-Delete (P1): Zeitpunkt, an dem ein Admin die Person aus der Familie genommen hat. Dann ist auch `disabled_at` gesetzt (kein Login, nicht in den Listen);
     * Schlüssel, Sicherungen, Archiv und Anmeldedaten bleiben bis zum endgültigen Löschen (Aufräum-Job nach `REMOVED_RETENTION_DAYS`) oder bis zur Wiederherstellung.
     */
    removedAt: timestamp('removed_at', { withTimezone: true }),
    /** Wer entfernt hat (ohne Fremdschlüssel: der Eintrag überlebt das Löschen des Admin-Kontos; Zuordnung steht außerdem im Audit). */
    removedBy: uuid('removed_by'),
    /**
     * Letzte Änderung der Anmeldedaten durch die Person selbst (Passkey/Passwort hinzufügen, ändern, entfernen, Wiederherstellungscodes neu). Sitzungen, die danach
     * innerhalb von 24 h entstehen, erben die Sperrfrist destruktiver Schlüssel-Aktionen (Herkunft `access_change`): ein frisch angelegter Zugang hebelt sie nicht aus.
     * Registrierung und Passwort-Reset setzen es nicht.
     */
    accessChangedAt: timestamp('access_changed_at', { withTimezone: true }),
    /** Benutzerbild: null = keines (Initialen), 'preset' = Platzhalter aus avatar_preset, 'photo' = Foto in user_avatars. */
    avatarKind: text('avatar_kind'),
    avatarPreset: text('avatar_preset'),
    /** Zählt jede Änderung des Benutzerbilds hoch (Cache-Schlüssel und ETag der Apps). */
    avatarVersion: integer('avatar_version').notNull().default(0),
  },
  (t) => [
    uniqueIndex('users_email_lower_uq').on(sql`lower(${t.email})`),
    // Soft-Delete: wer entfernt ist, ist immer auch gesperrt (kein Login, keine Listen)
    check('users_removed_ck', sql`${t.removedAt} is null or ${t.disabledAt} is not null`),
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
 * E2EE: Archiv der Wiederherstellungssicherungen (nur anhängend, nie gelöscht außer mit dem Konto). Ein Schlüsselwechsel verschiebt die bisherige
 * `key_backups`-Zeile hierher (`reason = 'rotation'`), ein Ersetzen durch einen anderen Blob zur selben key_version legt die alte Zeile hier ab
 * (`reason = 'replaced'`): so zerstört weder ein Angreifer mit einer geliehenen Sitzung noch ein Versehen den einzigen Weg zum alten Schlüssel
 * (und damit zum alten Chat-Verlauf). Lesen nur die eigene Person (Step-up, protokolliert): `GET /me/key-backups/archive[/:id]`.
 */
export const keyBackupArchive = pgTable(
  'key_backup_archive',
  {
    id: id(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull().default('recovery'),
    blob: text('blob').notNull(),
    keyVersion: integer('key_version').notNull(),
    reason: text('reason').notNull(),
    /** Wann die archivierte Sicherung ursprünglich angelegt bzw. zuletzt geändert wurde. */
    backupCreatedAt: timestamp('backup_created_at', { withTimezone: true }).notNull(),
    backupUpdatedAt: timestamp('backup_updated_at', { withTimezone: true }).notNull(),
    archivedAt: timestamp('archived_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('key_backup_archive_user_idx').on(t.userId, t.archivedAt),
    check('key_backup_archive_kind_ck', sql`${t.kind} in ('recovery')`),
    check('key_backup_archive_reason_ck', sql`${t.reason} in ('rotation', 'replaced')`),
    check('key_backup_archive_version_ck', sql`${t.keyVersion} >= 1`),
  ],
);

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
    state: text('state').notNull().default('pending'),
    /** Erst nach der Round-Trip-Probe der App gesetzt. */
    verifiedAt: timestamp('verified_at', { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('key_backups_pw_current_uq').on(t.userId).where(sql`${t.state} in ('active', 'stale')`),
    // höchstens eine noch nicht bestätigte (pending) Sicherung je Person; die bisherige aktuelle bleibt bis zur Bestätigung unberührt
    uniqueIndex('key_backups_pw_pending_uq').on(t.userId).where(sql`${t.state} = 'pending'`),
    index('key_backups_pw_user_idx').on(t.userId),
    check('key_backups_pw_state_ck', sql`${t.state} in ('pending', 'active', 'stale', 'superseded')`),
    check('key_backups_pw_size_ck', sql`length(${t.blob}) between 96 and 4096 and ${t.keyVersion} >= 1`),
    // festes Profil: kein Herabsetzen der Kosten über den Server (Untergrenze auch in der App)
    check('key_backups_pw_kdf_ck', sql`${t.kdfId} in ('argon2id-v1') and ${t.memKib} >= 65536 and ${t.ops} >= 3 and ${t.saltGeneration} >= 1`),
  ],
);

/**
 * E2EE (Passkey-Sicherung, Schalter E2EE_PRF_BACKUP): der Personenschlüssel, verpackt mit einem Schlüssel aus der PRF-Ausgabe EINES Passkeys (WebAuthn-PRF,
 * `hmac-secret`). Der Server sieht die PRF-Ausgabe nie; der Blob ist für ihn undurchsichtig, `credential_id` ist die öffentliche Kennung des Passkeys. Je Person und Passkey
 * höchstens eine aktuelle (`active`/`stale`) und je Person höchstens eine unbestätigte (`pending`) Zeile; Zeilen werden nie gelöscht (ersetzt = `superseded`,
 * nach Schlüsselwechsel `stale`), bleiben über das Archiv erreichbar. Keine Fremdschlüssel auf die Anmeldedaten: ein gelöschter Passkey lässt die Zeile liegen.
 */
export const keyBackupsPrf = pgTable(
  'key_backups_prf',
  {
    id: id(),
    userId: uuid('user_id').notNull(),
    familyId: familyRef(),
    credentialId: text('credential_id').notNull(),
    blob: text('blob').notNull(),
    keyVersion: integer('key_version').notNull(),
    state: text('state').notNull().default('pending'),
    /** Erst nach der Round-Trip-Probe der App gesetzt. */
    verifiedAt: timestamp('verified_at', { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('key_backups_prf_current_uq').on(t.userId, t.credentialId).where(sql`${t.state} in ('active', 'stale')`),
    uniqueIndex('key_backups_prf_pending_uq').on(t.userId).where(sql`${t.state} = 'pending'`),
    index('key_backups_prf_user_idx').on(t.userId),
    check('key_backups_prf_state_ck', sql`${t.state} in ('pending', 'active', 'stale', 'superseded')`),
    check('key_backups_prf_size_ck', sql`length(${t.blob}) between 96 and 4096 and ${t.keyVersion} >= 1 and length(${t.credentialId}) between 1 and 1024`),
  ],
);

/**
 * E2EE (Eltern-Wiederherstellung für Kinder, Schalter E2EE_PARENT_RECOVERY): die Seeds des Kindes, je Elternteil als Sealed Box an dessen Schlüssel verpackt und vom Kind
 * signiert (beides für den Server undurchsichtig). Nur mit Zustimmung des Kindes; Zurücknehmen löscht die Zeilen. `stale`: der Schlüssel des Kindes wurde seither gewechselt
 * (der Eintrag enthält den alten Schlüssel und wird nicht mehr angeboten).
 */
export const guardianEscrows = pgTable(
  'guardian_escrows',
  {
    id: id(),
    familyId: familyRef(),
    childId: uuid('child_id').notNull(),
    guardianId: uuid('guardian_id').notNull(),
    /** Schlüsselversion des Kindes, deren Seeds im Blob stehen. */
    keyVersion: integer('key_version').notNull(),
    /** Schlüsselversion des Elternteils, an dessen X25519-Schlüssel verpackt wurde. */
    guardianKeyVersion: integer('guardian_key_version').notNull(),
    blob: text('blob').notNull(),
    sig: text('sig').notNull(),
    state: text('state').notNull().default('active'),
    /** Zeitpunkt der ersten Zustimmung des Kindes. */
    consentAt: timestamp('consent_at', { withTimezone: true }).notNull().defaultNow(),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.childId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.guardianId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    // je Kind und Elternteil höchstens EINE gültige (aktive oder veraltete) Hinterlegung; ersetzte (`superseded`) und zurückgenommene (`revoked`) bleiben bis zur Löschfrist liegen
    uniqueIndex('guardian_escrows_current_uq').on(t.childId, t.guardianId).where(sql`${t.state} in ('active', 'stale')`),
    index('guardian_escrows_guardian_idx').on(t.guardianId),
    check('guardian_escrows_state_ck', sql`${t.state} in ('active', 'stale', 'superseded', 'revoked')`),
    check('guardian_escrows_size_ck', sql`length(${t.blob}) between 64 and 2048 and length(${t.sig}) between 64 and 256 and ${t.keyVersion} >= 1 and ${t.guardianKeyVersion} >= 1`),
    check('guardian_escrows_self_ck', sql`${t.childId} <> ${t.guardianId}`),
  ],
);

/**
 * E2EE (Eltern-Wiederherstellung): eine Anfrage des Kindes. Zustände: `pending` (Verpflichtung abgelegt, Wartefrist läuft), `challenged` (ein Elternteil hat die Zufallszahl
 * gesendet), `revealed` (das Kind hat den flüchtigen Schlüssel offengelegt), `released` (das Elternteil hat die Übergabe abgelegt), danach `done` (vom Kind abgeholt, Blob gelöscht)
 * oder `cancelled`/`declined`/`expired`. Je Kind höchstens eine offene Anfrage. Die Übergabedaten (`release_*`) sind für den Server undurchsichtig und verschwinden mit dem Ende.
 */
export const guardianRecoveries = pgTable(
  'guardian_recoveries',
  {
    id: id(),
    familyId: familyRef(),
    childId: uuid('child_id').notNull(),
    state: text('state').notNull().default('pending'),
    keyVersion: integer('key_version').notNull(),
    /** BLAKE2b über flüchtigen öffentlichen Schlüssel und Nonce (Verpflichtung, Base64url). */
    commit: text('commit').notNull(),
    readyAt: timestamp('ready_at', { withTimezone: true }).notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    guardianId: uuid('guardian_id'),
    challenge: text('challenge'),
    revealPub: text('reveal_pub'),
    revealNonce: text('reveal_nonce'),
    releaseBlob: text('release_blob'),
    releaseSig: text('release_sig'),
    /** Gerät des Kindes, das die Anfrage gestellt hat: nur dieses Gerät offenbart den flüchtigen Schlüssel, holt die Übergabe und schließt ab (null: Sitzung ohne Gerät). */
    deviceId: uuid('device_id'),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.childId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('guardian_recoveries_open_uq').on(t.childId).where(sql`${t.state} in ('pending', 'challenged', 'revealed', 'released')`),
    index('guardian_recoveries_child_idx').on(t.childId, t.createdAt),
    check('guardian_recoveries_state_ck', sql`${t.state} in ('pending', 'challenged', 'revealed', 'released', 'done', 'cancelled', 'declined', 'expired')`),
    check('guardian_recoveries_size_ck', sql`length(${t.commit}) between 32 and 128 and ${t.keyVersion} >= 1`),
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
    /** Passkey: `multiDevice` (synchronisiert/gesichert) oder `singleDevice` (an ein Gerät gebunden), zuletzt bei der Registrierung oder Anmeldung gemeldet; null = unbekannt. */
    deviceType: text('device_type'),
    /** Passkey: Backup-Status laut Authenticator (BS-Flag), null = unbekannt. */
    backedUp: boolean('backed_up'),
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

/**
 * Anmeldung mit abgeleitetem `authKey` statt Klartext-Passwort (Schalter E2EE_PW_BACKUP): Prüfwert zum Passwort-Eintrag in `credentials`.
 * Gespeichert wird nie der authKey, sondern nur ein HMAC-SHA256 (Schlüssel aus AUTH_SECRET_KEY, an die Person gebunden). Die Zeile hängt
 * am Passwort-Eintrag: wird der ersetzt (Passwort ändern) oder entfernt, gilt der Prüfwert nicht mehr. Konten ohne Zeile sind im
 * Zustand "legacy" (nur Klartext-Anmeldung), mit Zeile im Zustand "authkey". `salt_generation` hält fest, mit welchem Salt abgeleitet wurde.
 */
export const passwordAuthkeys = pgTable(
  'password_authkeys',
  {
    credentialId: uuid('credential_id')
      .primaryKey()
      .references(() => credentials.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    authHash: text('auth_hash').notNull(),
    kdfId: text('kdf_id').notNull().default('argon2id-v1'),
    saltGeneration: integer('salt_generation').notNull().default(1),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('password_authkeys_user_idx').on(t.userId),
    check('password_authkeys_hash_ck', sql`length(${t.authHash}) = 64`),
    check('password_authkeys_kdf_ck', sql`${t.kdfId} in ('argon2id-v1') and ${t.saltGeneration} >= 1`),
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
    /**
     * `standard`: neues Konto bzw. vollständiges Zurücksetzen (alle Anmeldedaten werden neu eingerichtet).
     * `password_reset`: nur neues Passwort für ein bestehendes Konto; TOTP, Passkeys und Wiederherstellungs-Codes bleiben (der zweite Faktor ist Pflicht).
     */
    kind: text('kind').notNull().default('standard'),
  },
  (t) => [
    index('invites_family_idx').on(t.familyId),
    check('invites_pin_attempts_ck', sql`${t.pinAttempts} >= 0`),
    check('invites_kind_ck', sql`${t.kind} in ('standard', 'password_reset') and (${t.kind} = 'standard' or ${t.userId} is not null)`),
  ],
);

/**
 * Sicherheitsereignisse einer Person, die sie selbst sehen soll (Passwort-Reset angefordert oder durchgeführt). Nur anhängen, ohne
 * Inhalte und ohne IP; `via` sagt, auf welchem Weg (Admin-Link, Wiederherstellungscode, Passkey), `actor_id` wer es ausgelöst hat.
 */
export const securityEvents = pgTable(
  'security_events',
  {
    id: id(),
    familyId: familyRef(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    via: text('via').notNull(),
    actorId: uuid('actor_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    /** Um wen es geht, wenn nicht um die Person selbst (Hinweis an die Familie: "Zugang von <Name> zurückgesetzt"); sonst null. */
    subjectId: uuid('subject_id').references(() => users.id, { onDelete: 'set null' }),
  },
  (t) => [
    index('security_events_user_idx').on(t.userId, t.createdAt),
    check(
      'security_events_kind_ck',
      sql`${t.kind} in ('password_reset_requested', 'password_reset_done', 'account_reset_requested', 'key_rotated', 'key_backup_replaced', 'key_backup_read', 'key_backup_pw_read', 'key_backup_archive_read', 'recovery_code_login', 'key_transfer_created', 'key_transfer_claimed', 'member_account_reset', 'key_backup_prf_read', 'guardian_escrow_set', 'guardian_escrow_removed', 'guardian_recovery_requested', 'guardian_recovery_asked', 'guardian_recovery_challenged', 'guardian_recovery_released', 'guardian_recovery_ended', 'key_backup_prf_set')`,
    ),
    check('security_events_via_ck', sql`${t.via} in ('admin', 'recovery_code', 'passkey', 'password')`),
  ],
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
    /**
     * Vom Gerät gemeldeter Schlüsselstand (Betreiber-Ampel, `PUT /me/device-key`): 0 = "dieses Gerät hat keinen Schlüssel", n >= 1 = "dieses Gerät hat Schlüsselversion n",
     * null = nie gemeldet (alte App). Nur eine öffentliche Angabe, nie Schlüsselmaterial; sie stammt vom Gerät selbst und ist kein Beweis.
     */
    keyVersion: integer('key_version'),
    keyReportedAt: timestamp('key_reported_at', { withTimezone: true }),
  },
  (t) => [
    index('devices_user_idx').on(t.userId),
    check('devices_key_version_ck', sql`${t.keyVersion} is null or ${t.keyVersion} >= 0`),
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
    /** Wetter-Hinweise per Wecker: Bitmaske der Arten, die dieses Gerät will (weather/alerts.ts, 0 = aus; Bit i = Art i). Nur "Gerät will Art X", nie Inhalte. */
    weatherKinds: integer('weather_kinds').notNull().default(0),
    /** Wann je Art zuletzt ein Wetter-Wecker an dieses Gerät ging (Entprellung, `{art: Millisekunden}`). */
    weatherSent: jsonb('weather_sent').$type<Record<string, number>>().notNull().default({}),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.deviceId], foreignColumns: [devices.familyId, devices.id] }).onDelete('cascade'),
    unique('push_endpoints_topic_uq').on(t.topic),
    check('push_endpoints_weather_kinds_ck', sql`${t.weatherKinds} between 0 and 31`),
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
    /**
     * Herkunft der Sitzung: `login` (Passkey, Passwort + TOTP) oder `recovery_code` / `password_reset` (Zugang über einen einzelnen Wiederherstellungscode
     * bzw. einen Passwort-Reset) oder `access_change` (Anmeldung kurz nach einer Änderung der Anmeldedaten, `origin_at` = diese Änderung). Solche Sitzungen dürfen destruktive Schlüssel-Aktionen erst nach `origin_at` + 24 h (Fehler `destructive_locked`).
     * Eine Rotation des Refresh-Tokens übernimmt beide Werte unverändert.
     */
    origin: text('origin').notNull().default('login'),
    originAt: timestamp('origin_at', { withTimezone: true }),
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
    check('sessions_origin_ck', sql`${t.origin} in ('login', 'recovery_code', 'password_reset', 'access_change')`),
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
 * Betreiber des Servers (Dashboard "Betrieb", docs/PROJEKTBESCHREIBUNG.md Abschnitt 9b): ein Konto-Flag, das NUR die Server-CLI
 * (`operator.js grant|revoke`) setzt, nie eine Route. Es gilt ausschließlich für die Betreiber-Routen unter /api/v1/admin;
 * Rechte der Familie hängen weiterhin nur an `memberships.role`. Die Zeile verschwindet mit dem Konto.
 */
export const operators = pgTable('operators', {
  userId: uuid('user_id')
    .primaryKey()
    .references(() => users.id, { onDelete: 'cascade' }),
  grantedAt: timestamp('granted_at', { withTimezone: true }).notNull().defaultNow(),
  /** Wer es gesetzt hat: immer 'cli' (kein Weg über die Oberfläche). */
  grantedBy: text('granted_by').notNull().default('cli'),
  /** Betreiber-Schalter "Warnungen" (Push-Wecker ohne Inhalt bei Betriebsproblemen, `PUT /admin/warnings`); Standard an. */
  alertsEnabled: boolean('alerts_enabled').notNull().default(true),
});

/**
 * Zustand der Betreiber-Warnungen je Familie und Art (`operator/monitor.ts`): der Prüfer (Takt alle 5 Minuten) merkt sich hier, welche Warnung gerade
 * aktiv ist und wann zuletzt gewarnt wurde. So gibt es nach einem Neustart keine Wiederholung und je Art höchstens alle 6 Stunden einen Wecker.
 * `kind` ist eine feste Art (cert, backup, database, ntfy, disk, logins) oder `key:<Personen-ID>`. Nie Inhalte, nur Zustand und Zeiten.
 */
export const operatorAlertState = pgTable(
  'operator_alert_state',
  {
    familyId: familyRef(),
    kind: text('kind').notNull(),
    active: boolean('active').notNull().default(false),
    /** Seit wann die Warnung aktiv ist (null, solange sie nicht aktiv ist). */
    since: timestamp('since', { withTimezone: true }),
    lastNotifiedAt: timestamp('last_notified_at', { withTimezone: true }),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.familyId, t.kind] }), check('operator_alert_state_kind_ck', sql`length(${t.kind}) between 1 and 60`)],
);

/**
 * Tägliche Messpunkte der Betreiber-Ansicht (Paket 3, `operator/metrics.ts`): je Familie und Tag (UTC) eine Zeile mit NUR Zahlen: aktive Personen und Geräte in den letzten 7 und
 * 30 Tagen, Zähler des Tages (Abgleiche, Fehler, Rate-Limit-Treffer; der Prüfer addiert sie alle 5 Minuten) und Größen (Datenbank, Dateiablage). Nie Inhalte, Titel, Namen oder IDs.
 * Aufbewahrung 400 Tage (Aufräum-Job). Die Zähler gelten für den Server (eine Familie je Server) und werden der ersten Familie des Prüflaufs zugerechnet.
 */
export const operatorMetrics = pgTable(
  'operator_metrics',
  {
    familyId: familyRef(),
    day: date('day', { mode: 'string' }).notNull(),
    activePersons7: integer('active_persons_7').notNull().default(0),
    activePersons30: integer('active_persons_30').notNull().default(0),
    activeDevices7: integer('active_devices_7').notNull().default(0),
    activeDevices30: integer('active_devices_30').notNull().default(0),
    syncRuns: integer('sync_runs').notNull().default(0),
    syncErrors: integer('sync_errors').notNull().default(0),
    rateLimited: integer('rate_limited').notNull().default(0),
    dbBytes: bigint('db_bytes', { mode: 'number' }),
    filesBytes: bigint('files_bytes', { mode: 'number' }),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.familyId, t.day] }),
    check(
      'operator_metrics_nonneg_ck',
      sql`${t.activePersons7} >= 0 and ${t.activePersons30} >= 0 and ${t.activeDevices7} >= 0 and ${t.activeDevices30} >= 0 and ${t.syncRuns} >= 0 and ${t.syncErrors} >= 0 and ${t.rateLimited} >= 0 and (${t.dbBytes} is null or ${t.dbBytes} >= 0) and (${t.filesBytes} is null or ${t.filesBytes} >= 0)`,
    ),
  ],
);

/**
 * Betreiber-Einstellungen je Familie (Paket 2b, `operator/settings.ts`): genau eine Zeile je Familie, wird beim ersten Schalten angelegt.
 * Wartungsmodus (sperrt Schreib-Ops, Sync und neue Anmeldungen mit 503 "maintenance"; optional mit automatischem Ende) und Familienhinweis
 * (kurzer reiner Text mit optionalem Ablauf, den die App als Banner zeigt). Nie Geheimnisse; der Hinweistext steht nur hier, nicht im Audit-Log.
 */
export const operatorSettings = pgTable(
  'operator_settings',
  {
    familyId: uuid('family_id')
      .primaryKey()
      .references((): AnyPgColumn => families.id, { onDelete: 'cascade' }),
    maintenanceActive: boolean('maintenance_active').notNull().default(false),
    maintenanceSince: timestamp('maintenance_since', { withTimezone: true }),
    /** Automatisches Ende (Sicherung gegen "vergessen auszuschalten"); null = bis der Betreiber ausschaltet. */
    maintenanceUntil: timestamp('maintenance_until', { withTimezone: true }),
    maintenanceBy: uuid('maintenance_by').references(() => users.id, { onDelete: 'set null' }),
    noticeText: text('notice_text'),
    noticeExpiresAt: timestamp('notice_expires_at', { withTimezone: true }),
    /** Version des Hinweises (Zeitpunkt des Setzens): die App merkt sich daran, welchen Hinweis eine Person schon weggeklickt hat. */
    noticeSetAt: timestamp('notice_set_at', { withTimezone: true }),
    noticeSetBy: uuid('notice_set_by').references(() => users.id, { onDelete: 'set null' }),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    check('operator_settings_notice_ck', sql`${t.noticeText} is null or (length(${t.noticeText}) between 1 and 280 and ${t.noticeSetAt} is not null)`),
    check('operator_settings_maintenance_ck', sql`not ${t.maintenanceActive} or ${t.maintenanceSince} is not null`),
  ],
);

/**
 * Kurzlebige WebAuthn-Challenges und Registrierungszustände (Passkey-/Passwort-Einrichtung): einmal einlösbar,
 * wenige Minuten gültig, werden beim Einlösen gelöscht (DELETE ... RETURNING) und vom Aufräum-Job bereinigt.
 */
export const webauthnChallenges = pgTable(
  'webauthn_challenges',
  {
    id: id(),
    /** login | register_passkey | register_password | reset_password | add_passkey | add_password | step_up */
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
    /** Termin-Farbe: Index 0 bis 10 in der festen Farbliste der App (null: keine, die App zeigt dann die Personenfarbe). */
    farbe: smallint('farbe'),
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
    check('termine_erinnerung_ck', sql`${t.erinnerungMin} is null or ${t.erinnerungMin} between -1 and 40320`),
    check('termine_farbe_ck', sql`${t.farbe} is null or ${t.farbe} between 0 and 10`),
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
    /** Kategorie nach Supermarkt-Gang (Kennung aus LIST_CATEGORIES, NULL = Sonstiges). */
    category: text('category'),
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
    /** Familien-Frist (Ablaufdatum mit Vorwarnzeit in `erinnerung_min`); alte Apps zeigen sie als normale Aufgabe. */
    frist: boolean('frist').notNull().default(false),
    /** Wiederholung der Frist alle N Monate (12 = jährlich); leer = einmalig. Der Client legt beim Erledigen die nächste an. */
    fristMonate: integer('frist_monate'),
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
    check('aufgaben_erinnerung_ck', sql`${t.erinnerungMin} is null or ${t.erinnerungMin} between 0 and 525600`),
    check('aufgaben_frist_monate_ck', sql`${t.fristMonate} is null or ${t.fristMonate} between 1 and 120`),
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
    /** Nur Art `meds` (Medikamenten-Plan, Abschnitt 6k): die Person, um deren Medikamente es geht (unveränderlich); sonst null. */
    subjektId: uuid('subjekt_id'),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.subjektId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    index('konversationen_subjekt_idx')
      .on(t.familyId, t.subjektId)
      .where(sql`${t.subjektId} is not null`),
    check('konversationen_subjekt_ck', sql`(${t.art}::text = 'meds') = (${t.subjektId} is not null)`),
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
        or (${t.art} = 'group' and cardinality(${t.teilnehmer}) between 2 and 20)
        or (${t.art}::text = 'meds' and cardinality(${t.teilnehmer}) between 1 and 20)
        or (${t.art}::text = 'zaehler' and cardinality(${t.teilnehmer}) between 1 and 20)
        or (${t.art}::text = 'tresor' and cardinality(${t.teilnehmer}) between 1 and 20)`,
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
 * Familien-Status (Abschnitt 6o): je Person genau ein kurzer, unverschlüsselter Status ("Beim Sport") mit optionalem Ablauf `bis`. Feste ID aus der Person
 * (`statusId`), Sicht für die ganze Familie, schreiben und löschen nur die Person selbst. Abgelaufene Stati zeigt die App nie (sie rechnet gegen die Uhr).
 */
export const familienStatus = pgTable(
  'familien_status',
  {
    id: id(),
    familyId: familyRef(),
    userId: uuid('user_id').notNull(),
    text: text('text').notNull(),
    bis: timestamp('bis', { withTimezone: true }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.userId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    uniqueIndex('familien_status_active_uq')
      .on(t.familyId, t.userId)
      .where(sql`${t.deletedAt} is null`),
    index('familien_status_family_rev_idx').on(t.familyId, t.rev),
    index('familien_status_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
  ],
);

/**
 * Medikamenten-Plan (Abschnitt 6k): ein Medikament einer Person, Kind der Medikamenten-Konversation (`konversationen.art = 'meds'`). `inhalt` ist eine Ende-zu-Ende
 * verschlüsselte, signierte e1-Hülle (Name, Dosis, Rhythmus, Uhrzeiten, Vorrat, Notizen, Rezeptdatum, Zustand): der Server sieht nur Struktur und Größe.
 * `bearbeiter_id` ist die Person, die den Inhalt zuletzt geschrieben (und signiert) hat.
 */
export const medikamente = pgTable(
  'medikamente',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('medikamente_family_id_uq').on(t.familyId, t.id),
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('medikamente_konversation_idx').on(t.familyId, t.konversationId),
    index('medikamente_family_rev_idx').on(t.familyId, t.rev),
    index('medikamente_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('medikamente_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('medikamente_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 16384`),
  ],
);

/**
 * Einnahme-Eintrag (Medikamenten-Protokoll, Abschnitt 6k): Kind eines Medikaments. `inhalt` ist eine e1-Hülle (geplanter Zeitpunkt, Zeitpunkt der Einnahme, Status, Menge).
 * Der Server löscht Einträge nach 120 Tagen (nach `created_at`, Serverzeit; Wartungsjob sync/meds.ts).
 */
export const einnahmen = pgTable(
  'einnahmen',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    medikamentId: uuid('medikament_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.medikamentId], foreignColumns: [medikamente.familyId, medikamente.id] }).onDelete('cascade'),
    index('einnahmen_medikament_idx').on(t.familyId, t.medikamentId),
    index('einnahmen_konversation_idx').on(t.familyId, t.konversationId),
    index('einnahmen_family_rev_idx').on(t.familyId, t.rev),
    index('einnahmen_created_idx').on(t.familyId, t.createdAt),
    index('einnahmen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('einnahmen_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('einnahmen_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 2048`),
  ],
);

/** Vorsorge-Profil (Abschnitt 6p): je Person genau eines (feste ID aus der Konversation), Kind der Medikamenten-Konversation `meds`. `inhalt` ist eine e1-Hülle (Geburtsdatum, Geschlecht optional). */
export const vorsorgeProfile = pgTable(
  'vorsorge_profile',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('vorsorge_profile_konversation_idx').on(t.familyId, t.konversationId),
    index('vorsorge_profile_family_rev_idx').on(t.familyId, t.rev),
    index('vorsorge_profile_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('vorsorge_profile_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('vorsorge_profile_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 2048`),
  ],
);

/** Vorsorge-/Impf-Eintrag (Abschnitt 6p): Kind der Medikamenten-Konversation `meds`. `inhalt` ist eine e1-Hülle (Vorlage oder Name, Art, Erledigt-Daten, Vorlauf, Notiz). Keine automatische Löschung. */
export const vorsorgeEintraege = pgTable(
  'vorsorge_eintraege',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('vorsorge_eintraege_konversation_idx').on(t.familyId, t.konversationId),
    index('vorsorge_eintraege_family_rev_idx').on(t.familyId, t.rev),
    index('vorsorge_eintraege_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('vorsorge_eintraege_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('vorsorge_eintraege_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 8192`),
  ],
);

/**
 * Zähler (Abschnitt 6l): ein Zähler des Haushalts (Strom, Wasser, Gas, ...), Kind der Zähler-Konversation (`konversationen.art = 'zaehler'`, eine je Familie, nur Eltern und
 * Admins als Teilnehmer). `inhalt` ist eine Ende-zu-Ende verschlüsselte, signierte e1-Hülle (Art, Name, Einheit, Preise, Periode, ...): der Server sieht nur Struktur und Größe.
 */
export const zaehler = pgTable(
  'zaehler',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('zaehler_family_id_uq').on(t.familyId, t.id),
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('zaehler_konversation_idx').on(t.familyId, t.konversationId),
    index('zaehler_family_rev_idx').on(t.familyId, t.rev),
    index('zaehler_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('zaehler_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('zaehler_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 16384`),
  ],
);

/** Zählerstand (Abschnitt 6l): Kind eines Zählers, `inhalt` eine e1-Hülle (Datum, Stand, Notiz). Dauerhaft (keine automatische Löschung). */
export const zaehlerstaende = pgTable(
  'zaehlerstaende',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    zaehlerId: uuid('zaehler_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.zaehlerId], foreignColumns: [zaehler.familyId, zaehler.id] }).onDelete('cascade'),
    index('zaehlerstaende_zaehler_idx').on(t.familyId, t.zaehlerId),
    index('zaehlerstaende_konversation_idx').on(t.familyId, t.konversationId),
    index('zaehlerstaende_family_rev_idx').on(t.familyId, t.rev),
    index('zaehlerstaende_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('zaehlerstaende_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('zaehlerstaende_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 2048`),
  ],
);

/**
 * Tresor (Abschnitt 6m): ein Eintrag des gemeinsamen Eltern-Tresors (WLAN, Versicherung, Ausweis, Arzt, Notfall-Infos, ...), Kind der Tresor-Konversation (`konversationen.art = 'tresor'`,
 * eine je Familie, nur Eltern und Admins als Teilnehmer). `inhalt` ist eine Ende-zu-Ende verschlüsselte, signierte e1-Hülle (Kategorie, Titel, Felder, Notiz): der Server sieht nur Struktur
 * und Größe. Grenze 24576 Zeichen der Hülle = 16000 Byte Klartext.
 */
export const tresorEintraege = pgTable(
  'tresor_eintraege',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    inhalt: text('inhalt').notNull(),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('tresor_eintraege_family_id_uq').on(t.familyId, t.id),
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('tresor_eintraege_konversation_idx').on(t.familyId, t.konversationId),
    index('tresor_eintraege_family_rev_idx').on(t.familyId, t.rev),
    index('tresor_eintraege_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('tresor_eintraege_bearbeiter_idx')
      .on(t.familyId, t.bearbeiterId, t.createdAt)
      .where(sql`${t.bearbeiterId} is not null`),
    check('tresor_eintraege_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 24576`),
  ],
);

/**
 * Dateiablage (Dateien-Bereich, Abschnitt 6n). Ordner: `parent_id` verweist auf einen anderen Ordner derselben Familie (leer = oberste Ebene); die Zugehörigkeit prüft der Server
 * (Zyklus, Tiefe, Freigabe), bewusst ohne Fremdschlüssel: ein bereinigter Tombstone des Elternordners darf nie am Kind hängen.
 */
export const ordner = pgTable(
  'ordner',
  {
    id: id(),
    familyId: familyRef(),
    parentId: uuid('parent_id'),
    name: text('name').notNull(),
    audience: listAudience('audience').notNull().default('family'),
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('ordner_family_id_uq').on(t.familyId, t.id),
    index('ordner_parent_idx').on(t.familyId, t.parentId),
    index('ordner_family_rev_idx').on(t.familyId, t.rev),
    index('ordner_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('ordner_name_len_ck', sql`char_length(${t.name}) <= 200`),
  ],
);

/** Datei: Name, Ablageort (Ordner) und Freigabe; der Inhalt steht in den unveränderlichen Fassungen (`datei_versionen`). */
export const dateien = pgTable(
  'dateien',
  {
    id: id(),
    familyId: familyRef(),
    ordnerId: uuid('ordner_id'),
    name: text('name').notNull(),
    audience: listAudience('audience').notNull().default('family'),
    ownerId: uuid('owner_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('dateien_family_id_uq').on(t.familyId, t.id),
    index('dateien_ordner_idx').on(t.familyId, t.ordnerId),
    index('dateien_family_rev_idx').on(t.familyId, t.rev),
    index('dateien_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    index('dateien_owner_idx')
      .on(t.familyId, t.ownerId)
      .where(sql`${t.ownerId} is not null`),
    check('dateien_name_len_ck', sql`char_length(${t.name}) <= 200`),
  ],
);

/** Unveränderliche Fassung einer Datei: verweist auf einen Blob (und optional ein Vorschaubild); Größe, Typ und Prüfsumme setzt der Server aus dem beanspruchten Blob. */
export const dateiVersionen = pgTable(
  'datei_versionen',
  {
    id: id(),
    familyId: familyRef(),
    dateiId: uuid('datei_id').notNull(),
    nr: integer('nr').notNull(),
    blobId: uuid('blob_id').notNull(),
    thumbBlobId: uuid('thumb_blob_id'),
    size: bigint('size', { mode: 'number' }).notNull().default(0),
    mime: text('mime'),
    sha256: text('sha256'),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('datei_versionen_family_id_uq').on(t.familyId, t.id),
    unique('datei_versionen_nr_uq').on(t.familyId, t.dateiId, t.nr),
    foreignKey({ columns: [t.familyId, t.dateiId], foreignColumns: [dateien.familyId, dateien.id] }).onDelete('cascade'),
    index('datei_versionen_datei_idx').on(t.familyId, t.dateiId),
    index('datei_versionen_family_rev_idx').on(t.familyId, t.rev),
    index('datei_versionen_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('datei_versionen_nr_ck', sql`${t.nr} between 1 and 9999`),
    check('datei_versionen_size_ck', sql`${t.size} >= 0`),
  ],
);

/**
 * Anhang eines Tresor-Eintrags: ein Ende-zu-Ende verschlüsselter Blob (Modus `e2ee`). `inhalt` ist eine e1-Hülle (Name, Typ, Dateischlüssel, Zuordnung zum Eintrag); der Server
 * sieht nur die Blob-ID und die Größe. Kind der Tresor-Konversation und erbt ihre Teilnehmer-Sicht.
 */
export const tresorAnhaenge = pgTable(
  'tresor_anhaenge',
  {
    id: id(),
    familyId: familyRef(),
    konversationId: uuid('konversation_id').notNull(),
    blobId: uuid('blob_id').notNull(),
    inhalt: text('inhalt').notNull(),
    size: bigint('size', { mode: 'number' }).notNull().default(0),
    bearbeiterId: uuid('bearbeiter_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    unique('tresor_anhaenge_family_id_uq').on(t.familyId, t.id),
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    index('tresor_anhaenge_konversation_idx').on(t.familyId, t.konversationId),
    index('tresor_anhaenge_family_rev_idx').on(t.familyId, t.rev),
    index('tresor_anhaenge_tombstone_idx')
      .on(t.familyId, t.rev)
      .where(sql`${t.deletedAt} is not null`),
    check('tresor_anhaenge_inhalt_len_ck', sql`char_length(${t.inhalt}) <= 4096`),
    check('tresor_anhaenge_size_ck', sql`${t.size} >= 0`),
  ],
);

/**
 * Blobs der Dateiablage (nicht synchronisiert; die Datei liegt unter FILES_DIR/blobs/<2 Hex>/<id>). Die ID ist zugleich die ID des Uploads.
 *  - `server`: der Server hat die Datei (AES-256-GCM, 64-KiB-Blöcke) verschlüsselt abgelegt; `dek_wrap` ist der mit dem abgeleiteten Schlüssel `files/wrap/v<kid>` verpackte Dateischlüssel.
 *  - `e2ee`: der Client lieferte schon verschlüsselte Bytes; der Server speichert sie undurchsichtig (kein Schlüssel, kein Name, kein Typ), `sha256` gilt den übertragenen Bytes.
 * `ready` = fertig hochgeladen, noch von keinem Datensatz beansprucht (nur die hochladende Person sieht ihn); `claimed` = ein Sync-Datensatz (`claim_entity`, `claim_id`) hat ihn beansprucht.
 */
export const dateiBlob = pgTable(
  'datei_blob',
  {
    id: uuid('id').primaryKey(),
    familyId: familyRef(),
    uploaderId: uuid('uploader_id').references(() => users.id, { onDelete: 'set null' }),
    modus: text('modus').notNull(),
    kind: text('kind').notNull(),
    /** Größe des Inhalts (Modus server: Klartext, Modus e2ee: übertragene Bytes); zählt für das Kontingent. */
    size: bigint('size', { mode: 'number' }).notNull(),
    /** Größe der Datei auf dem Datenträger. */
    diskSize: bigint('disk_size', { mode: 'number' }).notNull(),
    sha256: text('sha256').notNull(),
    mime: text('mime'),
    dekWrap: bytea('dek_wrap'),
    kid: integer('kid'),
    state: text('state').notNull().default('ready'),
    claimEntity: text('claim_entity'),
    claimId: uuid('claim_id'),
    createdAt: createdAt(),
    claimedAt: timestamp('claimed_at', { withTimezone: true }),
    /** Seit wann niemand den Blob mehr braucht (Karenz bis zum Löschen der Datei). */
    orphanedAt: timestamp('orphaned_at', { withTimezone: true }),
  },
  (t) => [
    unique('datei_blob_family_id_uq').on(t.familyId, t.id),
    index('datei_blob_family_state_idx').on(t.familyId, t.state),
    index('datei_blob_claim_idx').on(t.claimEntity, t.claimId),
    index('datei_blob_orphan_idx')
      .on(t.orphanedAt)
      .where(sql`${t.orphanedAt} is not null`),
    check('datei_blob_modus_ck', sql`${t.modus} in ('server', 'e2ee')`),
    check('datei_blob_kind_ck', sql`${t.kind} in ('datei', 'thumb', 'opak')`),
    check('datei_blob_state_ck', sql`${t.state} in ('ready', 'claimed')`),
    check('datei_blob_size_ck', sql`${t.size} >= 0 and ${t.diskSize} >= 0`),
    check('datei_blob_key_ck', sql`(${t.modus} = 'server' and ${t.dekWrap} is not null and ${t.kid} is not null) or (${t.modus} = 'e2ee' and ${t.dekWrap} is null and ${t.kid} is null)`),
    check('datei_blob_claim_ck', sql`(${t.state} = 'claimed') = (${t.claimEntity} is not null and ${t.claimId} is not null)`),
  ],
);

/** Laufender Upload (tus, Staging unter FILES_DIR/tmp/<id>.part); die ID wird zur Blob-ID. `aborted`-Zeilen bleiben bis zum Aufräumen (24 h) für die Mengenbegrenzung stehen. */
export const dateiUpload = pgTable(
  'datei_upload',
  {
    id: uuid('id').primaryKey(),
    familyId: familyRef(),
    uploaderId: uuid('uploader_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    modus: text('modus').notNull(),
    kind: text('kind').notNull(),
    /** Vom Client genannter Typ (nur im Modus server, geprüft gegen die Magic-Bytes). */
    declaredMime: text('declared_mime'),
    length: bigint('length', { mode: 'number' }).notNull(),
    offset: bigint('offset', { mode: 'number' }).notNull().default(0),
    status: text('status').notNull().default('open'),
    createdAt: createdAt(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  },
  (t) => [
    unique('datei_upload_family_id_uq').on(t.familyId, t.id),
    index('datei_upload_uploader_idx').on(t.uploaderId, t.createdAt),
    index('datei_upload_family_status_idx').on(t.familyId, t.status),
    check('datei_upload_modus_ck', sql`${t.modus} in ('server', 'e2ee')`),
    check('datei_upload_kind_ck', sql`${t.kind} in ('datei', 'thumb', 'opak')`),
    check('datei_upload_status_ck', sql`${t.status} in ('open', 'finalizing', 'done', 'aborted')`),
    check('datei_upload_len_ck', sql`${t.length} >= 0 and ${t.offset} >= 0 and ${t.offset} <= ${t.length}`),
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
    // Wrap-ID v2 (Migration 0024): Schlüsselversion des Empfängers, für die der Wrap verpackt ist (öffentliche Zahl, nichts Geheimes). null = Altbestand und
    // Wraps älterer Apps (ID v1, ohne Version); der Server liest nichts aus dem undurchsichtigen Wrap selbst
    keyVersion: integer('key_version'),
    createdAt: createdAt(),
    ...syncColumns(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.konversationId], foreignColumns: [konversationen.familyId, konversationen.id] }).onDelete('cascade'),
    foreignKey({ columns: [t.familyId, t.empfaengerId], foreignColumns: [memberships.familyId, memberships.userId] }).onDelete('cascade'),
    // Wraps ohne Version (Altbestand, ID v1): je (Konversation, Epoche, Empfänger) genau eine lebende Zeile. Wraps MIT Version (ID v2) enthalten den Verteiler in ihrer
    // ID: je Verteiler eine Zeile, mehrere Verteiler dürfen dieselbe Epoche für dieselbe Version verpacken (niemand kann den Platz eines anderen belegen)
    uniqueIndex('epoche_wraps_uq')
      .on(t.familyId, t.konversationId, t.epoche, t.empfaengerId)
      .where(sql`${t.deletedAt} is null and ${t.keyVersion} is null`),
    check('epoche_wraps_key_version_ck', sql`${t.keyVersion} is null or ${t.keyVersion} between 1 and 1000000`),
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

/**
 * Wetter (Netatmo, nur Server): genau eine Zeile (id = 1) mit den Zugangsdaten des Betreibers. Alles ist mit dem Hauptschlüssel
 * verschlüsselt (KeyRing, Zweck "weather"), nie im Klartext; geschrieben nur über die Kommandozeile (cli/weather-setup.ts) und die
 * Token-Rotation des Wetter-Dienstes. Kein Familienbezug: die Station gehört dem Betreiber des Servers, nicht einer Familie.
 */
export const weatherCredentials = pgTable(
  'weather_credentials',
  {
    id: integer('id').primaryKey().default(1),
    clientIdEnc: text('client_id_enc').notNull(),
    clientSecretEnc: text('client_secret_enc').notNull(),
    refreshTokenEnc: text('refresh_token_enc').notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
    lastOkAt: timestamp('last_ok_at', { withTimezone: true }),
    lastErrorAt: timestamp('last_error_at', { withTimezone: true }),
    /** Kurzer Code des letzten Fehlers (keine Inhalte der Antwort). */
    lastErrorCode: text('last_error_code'),
    /** Gesetzt bei `invalid_grant`: kein Abruf mehr, bis die Zugangsdaten neu eingegeben werden. */
    disabledAt: timestamp('disabled_at', { withTimezone: true }),
    /** Fehlschläge in Folge seit dem letzten Erfolg (Betreiber-Ansicht, Paket 3); nur die Zahl, nie ein Text. */
    errorCount: integer('error_count').notNull().default(0),
  },
  (t) => [check('weather_credentials_single_ck', sql`${t.id} = 1`)],
);

/** Eigene Zwischenspeicherung der Messwerte der Station (Verlauf, Min/Max); Zeilen älter als 7 Tage werden gelöscht. */
export const weatherSamples = pgTable(
  'weather_samples',
  {
    /** Zeitpunkt der Messung der Station (nicht des Abrufs). */
    ts: timestamp('ts', { withTimezone: true }).primaryKey(),
    temperature: doublePrecision('temperature'),
    humidity: doublePrecision('humidity'),
    pressure: doublePrecision('pressure'),
    rain1h: doublePrecision('rain_1h'),
    rain24h: doublePrecision('rain_24h'),
    windKmh: doublePrecision('wind_kmh'),
    gustKmh: doublePrecision('gust_kmh'),
    windAngle: doublePrecision('wind_angle'),
  },
);

/** Zustand der Wetter-Hinweise je Art (Wetter-Dienst): gilt die Bedingung gerade (mit Hysterese)? Ein Neustart des Dienstes schickt so keinen Wecker doppelt. */
export const weatherAlertState = pgTable('weather_alert_state', {
  kind: text('kind').primaryKey(),
  active: boolean('active').notNull(),
  changedAt: timestamp('changed_at', { withTimezone: true }).notNull().defaultNow(),
});

/**
 * Vorhersage und amtliche Warnungen (nur der Wetter-Dienst schreibt, `GET /weather/forecast` liest): je Art (`forecast`, `alerts`) eine Zeile mit dem
 * bereits streng ausgewerteten Ergebnis (nur Zahlen, feste Codes, gekürzte Texte; nie Koordinaten oder Rohantworten). `fetched_at` = letzter Erfolg.
 */
export const weatherForecast = pgTable(
  'weather_forecast',
  {
    kind: text('kind').primaryKey(),
    data: jsonb('data').notNull(),
    fetchedAt: timestamp('fetched_at', { withTimezone: true }),
    lastErrorAt: timestamp('last_error_at', { withTimezone: true }),
    /** Kurzer Code des letzten Fehlers (nie Inhalte der Antwort). */
    lastErrorCode: text('last_error_code'),
    errorCount: integer('error_count').notNull().default(0),
  },
  (t) => [check('weather_forecast_kind_ck', sql`${t.kind} in ('forecast', 'alerts')`)],
);

/** Abfallarten (feste Liste; unbekannte Namen der Quelle landen unter `sonst`). Dieselben Codes verwendet die App. */
export const WASTE_KINDS = ['rest', 'bio', 'gelb', 'papier', 'gruen', 'sonder', 'sperr', 'baum', 'sonst'] as const;
export type WasteKind = (typeof WASTE_KINDS)[number];

/**
 * Abfuhrtermine: nur der Abfuhr-Dienst (cli/waste-poller.ts) schreibt, `GET /waste` liest für alle Mitglieder der Familie.
 * Gespeichert werden nur Tag und Art (nie Straße, UID, Beschreibung oder Ort der Quelle). Kein Sync, keine Revisionen.
 */
export const wasteEvents = pgTable(
  'waste_events',
  {
    familyId: familyRef(),
    day: date('day', { mode: 'string' }).notNull(),
    kind: text('kind').notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.familyId, t.day, t.kind] }),
    check('waste_events_kind_ck', sql`${t.kind} in ('rest', 'bio', 'gelb', 'papier', 'gruen', 'sonder', 'sperr', 'baum', 'sonst')`),
  ],
);

/** Stand je Kalenderjahr: geladen, noch nicht verfügbar (leere oder ungültige Antwort) oder Abruffehler; nur feste Fehlercodes, nie Texte der Quelle. */
export const wasteYears = pgTable(
  'waste_years',
  {
    familyId: familyRef(),
    year: integer('year').notNull(),
    status: text('status').notNull(),
    eventCount: integer('event_count').notNull().default(0),
    /** Erstmals geladen (bleibt bei späteren Aktualisierungen). */
    loadedAt: timestamp('loaded_at', { withTimezone: true }),
    lastCheckedAt: timestamp('last_checked_at', { withTimezone: true }),
    /** Kurzer Code des letzten fehlgeschlagenen Abrufs (z. B. `http_403`, `network`, `empty`). */
    errorCode: text('error_code'),
  },
  (t) => [
    primaryKey({ columns: [t.familyId, t.year] }),
    check('waste_years_status_ck', sql`${t.status} in ('loaded', 'unavailable', 'error')`),
    check('waste_years_year_ck', sql`${t.year} between 2000 and 2200`),
  ],
);

/** Zustand je Familie: „Jetzt prüfen“ (Admin) setzt `check_requested_at`, der Abfuhr-Dienst holt es ab; `last_request_at` begrenzt die Häufigkeit. */
export const wasteState = pgTable('waste_state', {
  familyId: familyRef().primaryKey(),
  checkRequestedAt: timestamp('check_requested_at', { withTimezone: true }),
  lastRequestAt: timestamp('last_request_at', { withTimezone: true }),
  lastCheckAt: timestamp('last_check_at', { withTimezone: true }),
});

/**
 * Einwurf (Home Assistant, Zähler-Postfach): Token zum Einwerfen. Gespeichert wird nur der SHA-256 des Tokens (nie der Klartext).
 * Das Token authentifiziert ausschließlich `POST /ingest/zaehler`. Widerrufen wird nur markiert, nie gelöscht.
 */
export const ingestTokens = pgTable(
  'ingest_tokens',
  {
    id: id(),
    familyId: familyRef(),
    name: text('name').notNull(),
    tokenHash: text('token_hash').notNull(),
    createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
    createdAt: createdAt(),
    lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
    revokedAt: timestamp('revoked_at', { withTimezone: true }),
  },
  (t) => [unique('ingest_tokens_family_id_unique').on(t.familyId, t.id), unique('ingest_tokens_hash_unique').on(t.tokenHash), check('ingest_tokens_name_ck', sql`char_length(${t.name}) between 1 and 40`)],
);

/**
 * Einwurf: kurzlebige Weitergabe des Postfach-Schlüssels an ein weiteres Gerät derselben Person (Mehrgeräte-Abholen). Wie `key_transfers`: nur der Hash der Suchkennung,
 * der Blob ist mit einem Einmalgeheimnis verschlüsselt, das der Server nie sieht. Höchstens eine je Person, einmal einlösbar (DELETE ... RETURNING), 2 Minuten gültig.
 */
export const ingestPostfachTransfers = pgTable(
  'ingest_postfach_transfers',
  {
    userId: uuid('user_id')
      .primaryKey()
      .references(() => users.id, { onDelete: 'cascade' }),
    lookupHash: text('lookup_hash').notNull().unique(),
    blob: text('blob').notNull(),
    createdAt: createdAt(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  },
  (t) => [check('ingest_postfach_transfers_blob_ck', sql`char_length(${t.blob}) between 32 and 1024`)],
);

/**
 * Postfach: undurchsichtige Päckchen (libsodium Sealed Box, vom Server nie geöffnet oder ausgewertet). `k` ist der Eindeutigkeitsschlüssel des Clients
 * (je Token einmal). `seq` ordnet die Päckchen stabil für das seitenweise Abholen. Aufbewahrung höchstens 30 Tage.
 */
export const ingestInbox = pgTable(
  'ingest_inbox',
  {
    id: id(),
    seq: bigint('seq', { mode: 'number' }).generatedAlwaysAsIdentity().notNull(),
    familyId: familyRef(),
    tokenId: uuid('token_id').notNull(),
    k: text('k').notNull(),
    box: bytea('box').notNull(),
    receivedAt: timestamp('received_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    foreignKey({ columns: [t.familyId, t.tokenId], foreignColumns: [ingestTokens.familyId, ingestTokens.id], name: 'ingest_inbox_token_fk' }).onDelete('cascade'),
    unique('ingest_inbox_token_k_unique').on(t.tokenId, t.k),
    unique('ingest_inbox_seq_unique').on(t.seq),
    index('ingest_inbox_family_seq_idx').on(t.familyId, t.seq),
    index('ingest_inbox_received_idx').on(t.receivedAt),
    check('ingest_inbox_k_ck', sql`char_length(${t.k}) between 1 and 64`),
    check('ingest_inbox_box_ck', sql`octet_length(${t.box}) between 1 and 1024`),
  ],
);
