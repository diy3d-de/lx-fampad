// Lokale Datenbank (drift, SQLite; im Web WASM mit OPFS bzw. IndexedDB-Fallback).
// Phase 0: nur die Tabellen für den Sync-Zustand und die Outbox; Fachtabellen kommen in Phase 1.
// Die Datei app_database.g.dart wird erzeugt: dart run build_runner build
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Einfache Schlüssel-Wert-Ablage (z. B. `sinceRev`, `deviceId`).
class SyncMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Ausgang: lokale Änderungen, die noch nicht beim Server angekommen sind.
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get op => text()(); // upsert | delete
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get fieldsJson => text().withDefault(const Constant('{}'))();
  IntColumn get baseRev => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [SyncMeta, Outbox])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 1;

  /// Leert alle Tabellen (beim Abmelden). Phase 1c hängt hier die Fachtabellen ein, sie stehen in [allTables].
  Future<void> alleDatenLoeschen() => transaction(() async {
    for (final t in allTables) {
      await delete(t).go();
    }
  });

  static const _kBesitzer = 'ownerUserId';

  /// Benutzer-ID der Person, der die lokalen Daten gehören (liegt in sync_meta und verschwindet mit [alleDatenLoeschen]).
  Future<String?> besitzerLesen() async =>
      (await (select(syncMeta)..where((t) => t.key.equals(_kBesitzer))).getSingleOrNull())?.value;

  Future<void> besitzerSetzen(String userId) =>
      into(syncMeta).insertOnConflictUpdate(SyncMetaCompanion.insert(key: _kBesitzer, value: userId));

  static QueryExecutor _openConnection() => driftDatabase(
        name: 'lx_fampad',
        // sqlite3.wasm und drift_worker.js liegen in web/ (keine CDN-Abrufe), Versionen siehe docs/VERSIONEN.md
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      );
}
