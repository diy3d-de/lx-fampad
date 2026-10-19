// Lokale Datenbank (drift, SQLite; im Web WASM mit OPFS bzw. IndexedDB-Fallback).
// Enthält die lokale Kopie der Familiendaten (Listen und Einträge), den Ausgang (outbox) und den Sync-Zustand (sync_meta).
// Die Oberfläche liest und schreibt nur hier; der Abgleich mit dem Server läuft im Hintergrund (data/sync/).
// Die Datei app_database.g.dart wird erzeugt: dart run build_runner build
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Einfache Schlüssel-Wert-Ablage: `ownerUserId`, `sinceRev`, `deviceId`, `members` (zuletzt geladene Mitgliederliste).
class SyncMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Ausgang: lokale Änderungen, die noch nicht beim Server bestätigt sind. Jede Zeile ist eine Op des Sync-Protokolls.
@TableIndex(name: 'outbox_entity_idx', columns: {#entity, #entityId})
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Vom Client vergebene UUID: macht das Senden wiederholbar (der Server bestätigt dieselbe Op erneut, ohne sie noch einmal anzuwenden).
  TextColumn get opId => text().unique()();
  TextColumn get op => text()(); // upsert | delete
  TextColumn get entity => text()();
  TextColumn get entityId => text()();

  /// Geänderte Felder als JSON (Schnittstellenformat); bei delete leer.
  TextColumn get fieldsJson => text().withDefault(const Constant('{}'))();

  /// Revision des Datensatzes, auf der die Änderung aufbaut (0 = neu angelegt).
  IntColumn get baseRev => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Wann die Op zuletzt an den Server ging (null: noch nie). Gesendete Ops werden nicht mehr mit späteren Änderungen verschmolzen.
  DateTimeColumn get sentAt => dateTime().nullable()();
}

/// Listen (Einkauf, Packliste, eigene Listen).
@DataClassName('Liste')
class Listen extends Table {
  @override
  String get tableName => 'lists';

  TextColumn get id => text()();
  TextColumn get name => text()();

  /// shopping | packing | custom
  TextColumn get kind => text().withDefault(const Constant('custom'))();

  /// Wer sie sieht: parents | family | all (inklusive Gäste)
  TextColumn get audience => text().withDefault(const Constant('family'))();
  TextColumn get ownerId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  /// Revision des Servers, auf der der lokale Stand beruht (0: noch nicht synchronisiert).
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Einträge einer Liste. `position` ist eine Kommazahl: neue Position = Mittelwert der Nachbarn.
@DataClassName('Listeneintrag')
@TableIndex(name: 'list_items_list_idx', columns: {#listId})
class ListenEintraege extends Table {
  @override
  String get tableName => 'list_items';

  TextColumn get id => text()();
  TextColumn get listId => text()();
  TextColumn get inhalt => text().named('text')();
  TextColumn get assigneeId => text().nullable()();
  DateTimeColumn get doneAt => dateTime().nullable()();
  RealColumn get position => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [SyncMeta, Outbox, Listen, ListenEintraege])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Version 2 (Phase 1c): Fachtabellen für Listen, Ausgang mit op_id und sent_at.
  @override
  int get schemaVersion => 2;

  /// Migrationen nur vorwärts. Version 1 (Phase 0 bis 1b) kannte nur `sync_meta` (mit dem Besitzer der Daten) und eine nie
  /// benutzte `outbox` ohne op_id: der Besitzer bleibt erhalten, die leere Outbox wird neu angelegt.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.deleteTable('outbox');
        await m.createAll();
      }
    },
  );

  /// Leert alle Tabellen (Abmelden, Wechsel der Person): Fachdaten, Ausgang und Sync-Zustand. Neue Tabellen stehen automatisch in [allTables].
  Future<void> alleDatenLoeschen() => transaction(() async {
    for (final t in allTables) {
      await delete(t).go();
    }
  });

  static const _kBesitzer = 'ownerUserId';

  /// Benutzer-ID der Person, der die lokalen Daten gehören (liegt in sync_meta und verschwindet mit [alleDatenLoeschen]).
  Future<String?> besitzerLesen() => metaLesen(_kBesitzer);

  Future<void> besitzerSetzen(String userId) => metaSchreiben(_kBesitzer, userId);

  Future<String?> metaLesen(String key) async => (await (select(syncMeta)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> metaSchreiben(String key, String value) => into(syncMeta).insertOnConflictUpdate(SyncMetaCompanion.insert(key: key, value: value));

  Future<void> metaLoeschen(String key) => (delete(syncMeta)..where((t) => t.key.equals(key))).go();

  static QueryExecutor _openConnection() => driftDatabase(
    name: 'lx_fampad',
    // sqlite3.wasm und drift_worker.js liegen in web/ (keine CDN-Abrufe), Versionen siehe docs/VERSIONEN.md
    web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')),
  );
}
