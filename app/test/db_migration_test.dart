// Migration der lokalen Datenbank von Version 1 (Phase 0 bis 1b: sync_meta + leere outbox) auf Version 2 (Phase 1c: Listen, Einträge,
// Ausgang mit op_id). Der Besitzer der Daten (sync_meta) muss erhalten bleiben, sonst würde nach dem Update nicht erkannt, wem die Daten gehören.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('Version 1 -> 4: Besitzer bleibt, neue Tabellen sind da, Ausgang akzeptiert op_id', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    // genau das Schema der Version 1
    raw.execute('CREATE TABLE sync_meta (key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (key));');
    raw.execute(
      "CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL, entity TEXT NOT NULL, entity_id TEXT NOT NULL, fields_json TEXT NOT NULL DEFAULT '{}', base_rev INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)));",
    );
    raw.execute("INSERT INTO sync_meta (key, value) VALUES ('ownerUserId', 'u-alt');");
    raw.execute('PRAGMA user_version = 1;');

    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    expect(await db.besitzerLesen(), 'u-alt');
    expect(await db.select(db.listen).get(), isEmpty);
    expect(await db.select(db.listenEintraege).get(), isEmpty);
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(raw.select('PRAGMA user_version').single.values.first, 4);
  });

  test('Version 2 -> 4: Listen und Ausgang bleiben, Termin- und Aufgaben-Tabellen kommen dazu', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    // Schema der Version 2 (Phase 1c-1): erzeugt von der aktuellen Datenbank ohne die Termin-Tabellen
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    await db.into(db.listen).insert(ListenCompanion.insert(id: 'l1', name: 'Einkauf', createdAt: DateTime(2026, 10, 19)));
    await db.close();
    for (final t in ['termine', 'termin_teilnehmer', 'termin_ausnahmen', 'aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 2');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.listen).get()).single.name, 'Einkauf');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(await db.select(db.termine).get(), isEmpty);
    expect(await db.select(db.terminTeilnehmer).get(), isEmpty);
    expect(await db.select(db.terminAusnahmen).get(), isEmpty);
    expect(await db.select(db.aufgaben).get(), isEmpty);
    expect(await db.select(db.aufgabePunkte).get(), isEmpty);
    // die Indizes der neuen Tabellen sind auch beim Upgrade da (nicht nur bei einer frischen Datenbank)
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['termin_teilnehmer_termin_idx', 'termin_ausnahmen_termin_idx', 'aufgabe_punkte_aufgabe_idx', 'list_items_list_idx', 'outbox_entity_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 4);
  });

  test('Version 2 -> 4: Sync-Fortschritt wird zurückgesetzt, übrige Meta-Werte und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('members', '[]');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    await db.close();
    for (final t in ['termine', 'termin_teilnehmer', 'termin_ausnahmen', 'aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 2');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.metaLesen('members'), '[]');
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
  });

  test('frische Datenbank: Version 4 mit allen Tabellen', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.besitzerSetzen('u1');
    final tabellen = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) r['name']];
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['termin_teilnehmer_termin_idx', 'termin_ausnahmen_termin_idx']));
    expect(tabellen, containsAll(['sync_meta', 'outbox', 'lists', 'list_items', 'termine', 'termin_teilnehmer', 'termin_ausnahmen', 'aufgaben', 'aufgabe_punkte']));
    expect(raw.select('PRAGMA user_version').single.values.first, 4);
  });

  test('Version 3 -> 4: Aufgaben-Tabellen kommen dazu, Sync-Fortschritt wird zurückgesetzt, Termine und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'termin', entityId: 't1'));
    await db.into(db.termine).insert(TermineCompanion.insert(id: 't1', titel: 'Zahnarzt', createdAt: DateTime(2026, 10, 19)));
    await db.close();
    // Schema der Version 3 (Phase 1c-2a): ohne die Aufgaben-Tabellen
    for (final t in ['aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 3');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.metaLesen('sinceRev'), isNull); // vollständiger Snapshot holt die Aufgaben, die die ältere App übersprungen hat
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.termine).get()).single.titel, 'Zahnarzt');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(await db.select(db.aufgaben).get(), isEmpty);
    await db.into(db.aufgaben).insert(AufgabenCompanion.insert(id: 'a1', titel: 'Müll', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.aufgabePunkte).insert(AufgabePunkteCompanion.insert(id: 'p1', aufgabeId: 'a1', inhalt: 'Tonne', createdAt: DateTime(2026, 10, 19)));
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, contains('aufgabe_punkte_aufgabe_idx'));
    expect(raw.select('PRAGMA user_version').single.values.first, 4);
  });

  test('erneutes Öffnen einer Version-4-Datenbank ändert nichts', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'delete', entity: 'list', entityId: 'l1'));
    await db.close();
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
  });
}
