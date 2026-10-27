// Migration der lokalen Datenbank von Version 1 (Phase 0 bis 1b: sync_meta + leere outbox) auf Version 2 (Phase 1c: Listen, Einträge,
// Ausgang mit op_id). Der Besitzer der Daten (sync_meta) muss erhalten bleiben, sonst würde nach dem Update nicht erkannt, wem die Daten gehören.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

/// Stellt den Stand vor Version 16 her (ohne Dateiablage): die sechs neuen Tabellen entfernen (die Indizes verschwinden mit ihnen).
void _vorSechzehn(Database raw) {
  for (final t in ['ordner', 'dateien', 'datei_versionen', 'tresor_anhaenge', 'transfers', 'datei_cache']) {
    raw.execute('DROP TABLE IF EXISTS $t');
  }
}

/// Stellt den Stand vor Version 13 her (ohne Medikamenten-Plan und ohne Zähler): die Tabellen und die Spalte `subjekt_id` der Konversationen entfernen.
void _vorDreizehn(Database raw) {
  _vorSechzehn(raw);
  raw.execute('DROP TABLE IF EXISTS tresor_eintraege');
  raw.execute('DROP TABLE IF EXISTS zaehler');
  raw.execute('DROP TABLE IF EXISTS zaehlerstaende');
  raw.execute('DROP TABLE IF EXISTS medikamente');
  raw.execute('DROP TABLE IF EXISTS einnahmen');
  if (raw.select("PRAGMA table_info('konversationen')").any((r) => r['name'] == 'subjekt_id')) raw.execute('ALTER TABLE konversationen DROP COLUMN subjekt_id');
}

void main() {
  test('Version 1 -> 19: Besitzer bleibt, neue Tabellen sind da, Ausgang akzeptiert op_id', () async {
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
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 2 -> 19: Listen und Ausgang bleiben, Termin-Tabellen kommen dazu', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    // Schema der Version 2 (Phase 1c-1): erzeugt von der aktuellen Datenbank ohne die Termin-Tabellen
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    await db.into(db.listen).insert(ListenCompanion.insert(id: 'l1', name: 'Einkauf', createdAt: DateTime(2026, 10, 19)));
    await db.close();
    for (final t in ['termine', 'termin_teilnehmer', 'termin_ausnahmen', 'konversationen', 'nachrichten', 'lesestand', 'konversation_epochen', 'epoche_wraps', 'aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 2');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.listen).get()).single.name, 'Einkauf');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(await db.select(db.termine).get(), isEmpty);
    expect(await db.select(db.terminTeilnehmer).get(), isEmpty);
    expect(await db.select(db.terminAusnahmen).get(), isEmpty);
    // die Indizes der neuen Tabellen sind auch beim Upgrade da (nicht nur bei einer frischen Datenbank)
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['termin_teilnehmer_termin_idx', 'termin_ausnahmen_termin_idx', 'list_items_list_idx', 'outbox_entity_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 2 -> 3: Sync-Fortschritt wird zurückgesetzt, übrige Meta-Werte und Ausgang bleiben', () async {
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
    for (final t in ['termine', 'termin_teilnehmer', 'termin_ausnahmen', 'konversationen', 'nachrichten', 'lesestand', 'konversation_epochen', 'epoche_wraps', 'aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
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

  test('Version 3 -> 19: Listen, Termine und Ausgang bleiben, Chat-Tabellen und Indizes kommen dazu', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('sinceRev', '500');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    await db.into(db.termine).insert(TermineCompanion.insert(id: 't1', titel: 'Zahnarzt', createdAt: DateTime(2026, 10, 19)));
    await db.close();
    for (final t in ['konversationen', 'nachrichten', 'lesestand', 'konversation_epochen', 'epoche_wraps', 'aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 3');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.termine).get()).single.titel, 'Zahnarzt');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(await db.metaLesen('sinceRev'), isNull, reason: 'Chat-Tabellen neu: Abgleich beginnt von vorn');
    expect(await db.select(db.konversationen).get(), isEmpty);
    expect(await db.select(db.nachrichten).get(), isEmpty);
    expect(await db.select(db.lesestaende).get(), isEmpty);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'family', createdAt: DateTime(2026, 10, 19)));
    final k = (await db.select(db.konversationen).get()).single;
    expect(k.teilnehmerJson, '[]');
    expect(k.titel, '');
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['nachrichten_konversation_idx', 'lesestand_konversation_idx', 'termin_teilnehmer_termin_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 4 -> 19: Chat-Zeiten werden zu Millisekunden, der Abgleich beginnt neu, andere Daten bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('sinceRev', '42');
    await db.into(db.listen).insert(ListenCompanion.insert(id: 'l1', name: 'Einkauf', createdAt: DateTime.fromMillisecondsSinceEpoch(1760000000000)));
    await db.close();
    // Stand der Version 4: Sekunden statt Millisekunden (rev 0: lokal neu und noch nicht gesendet, deshalb bleiben die Zeilen; bestätigte kämen mit dem Snapshot)
    raw.execute("INSERT INTO konversationen (id, art, titel, teilnehmer, created_at, rev) VALUES ('k1', 'family', '', '[]', 1760000000, 0)");
    raw.execute("INSERT INTO nachrichten (id, konversation_id, text, created_at, bearbeitet_at, rev) VALUES ('n1', 'k1', 'p1:x', 1760000010, 1760000020, 0)");
    raw.execute("INSERT INTO lesestand (id, konversation_id, user_id, gelesen_bis, rev) VALUES ('s1', 'k1', 'u1', 1760000010, 0)");
    // Stand der Version 4: ohne enc_version, ohne Epochen und Wraps
    raw.execute('ALTER TABLE konversationen DROP COLUMN enc_version');
    raw.execute('DROP TABLE konversation_epochen');
    raw.execute('DROP TABLE epoche_wraps');
    raw.execute('DROP TABLE aufgaben');
    raw.execute('DROP TABLE aufgabe_punkte');
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 4');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect((await db.select(db.nachrichten).getSingle()).createdAt.millisecondsSinceEpoch, 1760000010000);
    expect((await db.select(db.nachrichten).getSingle()).bearbeitetAt!.millisecondsSinceEpoch, 1760000020000);
    expect((await db.select(db.konversationen).getSingle()).createdAt.millisecondsSinceEpoch, 1760000000000);
    expect((await db.select(db.lesestaende).getSingle()).gelesenBis.millisecondsSinceEpoch, 1760000010000);
    expect(await db.metaLesen('sinceRev'), isNull, reason: 'neu abgleichen: die Zeiten kommen mit voller Auflösung vom Server');
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.listen).getSingle()).createdAt.millisecondsSinceEpoch, 1760000000000, reason: 'Listen bleiben in Sekunden');
    // Chats aus den Entwicklungsständen sind Klartext-Chats (p1), neue sind verschlüsselt (e1)
    expect((await db.select(db.konversationen).getSingle()).encVersion, 'p1');
    expect(await db.select(db.konversationEpochen).get(), isEmpty);
    expect(await db.select(db.epocheWraps).get(), isEmpty);
    // Millisekunden bleiben erhalten
    await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: 'n2', konversationId: 'k1', inhalt: 'p1:y', createdAt: DateTime.fromMillisecondsSinceEpoch(1760000010123)));
    expect((await (db.select(db.nachrichten)..where((n) => n.id.equals('n2'))).getSingle()).createdAt.millisecondsSinceEpoch, 1760000010123);
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 4 -> 19: auf dem Server gelöschte Chat-Zeilen (Geister) verschwinden, lokal neue (rev 0) bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    final t0 = DateTime.utc(2026, 10, 19, 9);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k-alt', art: 'group', createdAt: t0, rev: const Value(5)));
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k-neu', art: 'group', createdAt: t0));
    await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: 'n-alt', konversationId: 'k-alt', inhalt: 'p1:alt', createdAt: t0, rev: const Value(7)));
    await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: 'n-neu', konversationId: 'k-neu', inhalt: 'p1:neu', createdAt: t0));
    await db.metaSchreiben('sinceRev', '500');
    await db.close();
    // Schema der Version 4: ohne Verschlüsselungsspalte und ohne die Epochen-Tabellen
    raw.execute('ALTER TABLE konversationen DROP COLUMN enc_version');
    raw.execute('DROP TABLE konversation_epochen');
    raw.execute('DROP TABLE epoche_wraps');
    raw.execute('DROP TABLE aufgaben');
    raw.execute('DROP TABLE aufgabe_punkte');
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 4');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect([for (final k in await db.select(db.konversationen).get()) k.id], ['k-neu'], reason: 'die bestätigte Zeile kommt mit dem Snapshot zurück, gelöschte nie');
    expect([for (final n in await db.select(db.nachrichten).get()) n.id], ['n-neu']);
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.besitzerLesen(), 'u1');
  });

  test('Version 6 -> 19: Aufgaben-Tabellen kommen dazu, Sync-Fortschritt wird zurückgesetzt, Chat, Termine und Ausgang bleiben', () async {
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
    // Schema der Version 6 (E2EE Phase 2): ohne die Aufgaben-Tabellen
    for (final t in ['aufgaben', 'aufgabe_punkte']) {
      raw.execute('DROP TABLE $t');
    }
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 6');
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
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 7 -> 19: Sync-Fortschritt wird zurückgesetzt (Lesestände aller Teilnehmer), Daten und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'termin', entityId: 't1'));
    await db.close();
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 7');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 8 -> 19: Spalte fehler_code im Ausgang kommt dazu, die Chat-Tabellen auch, Ausgang und Daten bleiben, der Sync-Fortschritt wird zurückgesetzt', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'nachricht', entityId: 'n1'));
    await db.close();
    // Schema der Version 8: ohne fehler_code
    raw.execute('ALTER TABLE outbox DROP COLUMN fehler_code');
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 8');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    final op = (await db.select(db.outbox).get()).single;
    expect(op.opId, 'op-1');
    expect(op.fehlerCode, isNull);
    expect(await db.metaLesen('sinceRev'), isNull); // Version 10 legt Tabellen für neue Sync-Entitäten an: Reset
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    await (db.update(db.outbox)).write(const OutboxCompanion(fehlerCode: Value('forbidden')));
    expect((await db.select(db.outbox).get()).single.fehlerCode, 'forbidden');
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 9 -> 19: Tabellen für Reaktionen, Stimmen und Pins kommen dazu, der Sync-Fortschritt wird zurückgesetzt, Ausgang und Daten bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'family', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'nachricht', entityId: 'n1'));
    await db.close();
    for (final t in ['reaktionen', 'stimmen', 'pins']) {
      raw.execute('DROP TABLE $t');
    }
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 9');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.select(db.reaktionen).get(), isEmpty);
    expect(await db.select(db.stimmen).get(), isEmpty);
    expect(await db.select(db.pins).get(), isEmpty);
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(await db.select(db.konversationen).get(), hasLength(1));
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['reaktionen_konversation_idx', 'stimmen_konversation_idx', 'pins_konversation_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 10 -> 19: Spalte category an den Listeneinträgen kommt dazu, der Sync-Fortschritt wird zurückgesetzt, Einträge und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.listen).insert(ListenCompanion.insert(id: 'l1', name: 'Einkauf', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.listenEintraege).insert(ListenEintraegeCompanion.insert(id: 'i1', listId: 'l1', inhalt: 'Milch', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list_item', entityId: 'i1'));
    await db.close();
    raw.execute('ALTER TABLE list_items DROP COLUMN category');
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 10');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    final e = (await db.select(db.listenEintraege).get()).single;
    expect([e.inhalt, e.category], ['Milch', null]);
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 11 -> 19: Spalten frist und frist_monate an den Aufgaben kommen dazu, der Sync-Fortschritt wird zurückgesetzt, Aufgaben und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.aufgaben).insert(AufgabenCompanion.insert(id: 'a1', titel: 'Müll', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'aufgabe', entityId: 'a1'));
    await db.close();
    raw.execute('ALTER TABLE aufgaben DROP COLUMN frist');
    raw.execute('ALTER TABLE aufgaben DROP COLUMN frist_monate');
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 11');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    final a = (await db.select(db.aufgaben).get()).single;
    expect([a.titel, a.frist, a.fristMonate], ['Müll', false, null]);
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 12 -> 19: Medikamenten-Plan (Spalte subjekt_id, Tabellen medikamente und einnahmen mit Indizes) kommt dazu, der Sync-Fortschritt wird zurückgesetzt, Konversationen, Chat und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'group', createdAt: DateTime(2026, 10, 19), rev: const Value(3)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'konversation', entityId: 'k1'));
    await db.close();
    _vorDreizehn(raw);
    raw.execute('PRAGMA user_version = 12');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    final k = (await db.select(db.konversationen).get()).single;
    expect([k.id, k.art, k.subjektId, k.rev], ['k1', 'group', null, 3]);
    expect(await db.select(db.medikamente).get(), isEmpty);
    expect(await db.select(db.einnahmen).get(), isEmpty);
    // die neuen Tabellen sind benutzbar
    await db.into(db.medikamente).insert(MedikamenteCompanion.insert(id: 'm1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.einnahmen).insert(EinnahmenCompanion.insert(id: 'e1', konversationId: 'k1', medikamentId: 'm1', inhalt: 'e1:y', createdAt: DateTime(2026, 10, 19)));
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['medikamente_konversation_idx', 'einnahmen_medikament_idx', 'einnahmen_konversation_idx']));
    // Sync-Fortschritt zurückgesetzt (die Tabellen für neue Sync-Entitäten brauchen einen vollständigen Snapshot), alles Übrige bleibt
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 13 -> 19: Zähler (Tabellen zaehler und zaehlerstaende mit Indizes) kommen dazu, der Sync-Fortschritt wird zurückgesetzt, Medikamente, Konversationen und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'meds', subjektId: const Value('u1'), createdAt: DateTime(2026, 10, 19), rev: const Value(3)));
    await db.into(db.medikamente).insert(MedikamenteCompanion.insert(id: 'm1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'konversation', entityId: 'k1'));
    await db.close();
    _vorSechzehn(raw);
    raw.execute('DROP TABLE tresor_eintraege');
    raw.execute('DROP TABLE zaehler');
    raw.execute('DROP TABLE zaehlerstaende');
    raw.execute('PRAGMA user_version = 13');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect((await db.select(db.konversationen).get()).single.id, 'k1');
    expect(await db.select(db.medikamente).get(), hasLength(1));
    expect(await db.select(db.zaehler).get(), isEmpty);
    expect(await db.select(db.zaehlerstaende).get(), isEmpty);
    // die neuen Tabellen sind benutzbar
    await db.into(db.zaehler).insert(ZaehlerCompanion.insert(id: 'z1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.zaehlerstaende).insert(ZaehlerstaendeCompanion.insert(id: 's1', konversationId: 'k1', zaehlerId: 'z1', inhalt: 'e1:y', createdAt: DateTime(2026, 10, 19)));
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['zaehler_konversation_idx', 'zaehlerstaende_zaehler_idx', 'zaehlerstaende_konversation_idx']));
    // Sync-Fortschritt zurückgesetzt (die Tabellen für neue Sync-Entitäten brauchen einen vollständigen Snapshot), alles Übrige bleibt
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 14 -> 19: Tresor (Tabelle tresor_eintraege mit Index) kommt dazu, der Sync-Fortschritt wird zurückgesetzt, Zähler, Konversationen und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'zaehler', createdAt: DateTime(2026, 10, 19), rev: const Value(3)));
    await db.into(db.zaehler).insert(ZaehlerCompanion.insert(id: 'z1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'konversation', entityId: 'k1'));
    await db.close();
    _vorSechzehn(raw);
    raw.execute('DROP TABLE tresor_eintraege');
    raw.execute('PRAGMA user_version = 14');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect((await db.select(db.konversationen).get()).single.id, 'k1');
    expect(await db.select(db.zaehler).get(), hasLength(1));
    expect(await db.select(db.tresorEintraege).get(), isEmpty);
    // die neue Tabelle ist benutzbar
    await db.into(db.tresorEintraege).insert(TresorEintraegeCompanion.insert(id: 't1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 19)));
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, contains('tresor_eintraege_konversation_idx'));
    // Sync-Fortschritt zurückgesetzt (die Tabelle für eine neue Sync-Entität braucht einen vollständigen Snapshot), alles Übrige bleibt
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 15 -> 19: Dateiablage (Ordner, Dateien, Fassungen, Tresor-Anhänge mit Indizes, lokal Übertragungen und Offline-Kopien) kommt dazu, der Sync-Fortschritt wird zurückgesetzt, Tresor, Konversationen und Ausgang bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('deviceId', 'dev-1');
    await db.metaSchreiben('sinceRev', '500');
    await db.metaSchreiben('snapshotRev', '600');
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'tresor', createdAt: DateTime(2026, 10, 19), rev: const Value(3)));
    await db.into(db.tresorEintraege).insert(TresorEintraegeCompanion.insert(id: 't1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 19)));
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'konversation', entityId: 'k1'));
    await db.close();
    _vorSechzehn(raw);
    raw.execute('PRAGMA user_version = 15');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect((await db.select(db.konversationen).get()).single.id, 'k1');
    expect(await db.select(db.tresorEintraege).get(), hasLength(1));
    expect(await db.select(db.ordner).get(), isEmpty);
    expect(await db.select(db.dateien).get(), isEmpty);
    expect(await db.select(db.dateiVersionen).get(), isEmpty);
    expect(await db.select(db.tresorAnhaenge).get(), isEmpty);
    expect(await db.select(db.transfers).get(), isEmpty);
    expect(await db.select(db.dateiCache).get(), isEmpty);
    // die neuen Tabellen sind benutzbar
    final jetzt = DateTime(2026, 10, 24);
    await db.into(db.ordner).insert(OrdnerCompanion.insert(id: 'o1', name: 'Urlaub', createdAt: jetzt));
    await db.into(db.dateien).insert(DateienCompanion.insert(id: 'd1', name: 'a.txt', createdAt: jetzt));
    await db.into(db.dateiVersionen).insert(DateiVersionenCompanion.insert(id: 'v1', dateiId: 'd1', nr: 1, blobId: 'b1', createdAt: jetzt));
    await db.into(db.tresorAnhaenge).insert(TresorAnhaengeCompanion.insert(id: 'a1', konversationId: 'k1', blobId: 'b2', inhalt: 'e1:x', createdAt: jetzt));
    await db.into(db.transfers).insert(TransfersCompanion.insert(id: 'tr1', richtung: 'Hoch', art: 'datei', zustand: 'wartet', name: 'a.txt', createdAt: jetzt, aktualisiertAt: jetzt));
    await db.into(db.dateiCache).insert(DateiCacheCompanion.insert(blobId: 'b1', groesse: 5, name: 'a.txt', zuletztGenutzt: jetzt));
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['ordner_parent_idx', 'dateien_ordner_idx', 'datei_versionen_datei_idx', 'tresor_anhaenge_konversation_idx', 'transfers_zustand_idx']));
    // Sync-Fortschritt zurückgesetzt (Tabellen für neue Sync-Entitäten brauchen einen vollständigen Snapshot), alles Übrige bleibt
    expect(await db.metaLesen('sinceRev'), isNull);
    expect(await db.metaLesen('snapshotRev'), isNull);
    expect(await db.metaLesen('deviceId'), 'dev-1');
    expect(await db.besitzerLesen(), 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Abmelden leert auch die lokalen Tabellen der Dateiablage (alleDatenLoeschen)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final jetzt = DateTime(2026, 10, 24);
    await db.into(db.ordner).insert(OrdnerCompanion.insert(id: 'o1', name: 'x', createdAt: jetzt));
    await db.into(db.transfers).insert(TransfersCompanion.insert(id: 'tr1', richtung: 'Hoch', art: 'datei', zustand: 'wartet', name: 'a', createdAt: jetzt, aktualisiertAt: jetzt));
    await db.into(db.dateiCache).insert(DateiCacheCompanion.insert(blobId: 'b1', groesse: 5, name: 'a', zuletztGenutzt: jetzt));
    await db.alleDatenLoeschen();
    expect(await db.select(db.ordner).get(), isEmpty);
    expect(await db.select(db.transfers).get(), isEmpty);
    expect(await db.select(db.dateiCache).get(), isEmpty);
  });

  test('Version 16 -> 19: Termine behalten alles, farbe kommt dazu (null), Sync-Stand wird zurückgesetzt, Ausgang bleibt', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.into(db.termine).insert(TermineCompanion.insert(id: 't1', titel: 'Alt', createdAt: DateTime(2026, 1, 1), farbe: const Value(3)));
    await db.customStatement("INSERT INTO sync_meta (key, value) VALUES ('sinceRev', '42')");
    await db.customStatement("INSERT INTO sync_meta (key, value) VALUES ('snapshotRev', '40')");
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-17', op: 'delete', entity: 'list', entityId: 'l1'));
    await db.close();
    // Stand 16: Spalte weg
    raw.execute('ALTER TABLE termine DROP COLUMN farbe');
    raw.execute('PRAGMA user_version = 16');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    final t = await (db.select(db.termine)..where((x) => x.id.equals('t1'))).getSingle();
    expect(t.titel, 'Alt');
    expect(t.farbe, isNull);
    expect(raw.select("SELECT value FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')"), isEmpty, reason: 'Sync-Fortschritt zurückgesetzt, damit Farben anderer Geräte ankommen');
    expect(raw.select("SELECT value FROM sync_meta WHERE key = 'ownerUserId'").single['value'], 'u1', reason: 'Besitzer bleibt');
    expect(await db.select(db.outbox).get(), hasLength(1), reason: 'Ausgang bleibt');
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 17 -> 19: Familien-Status-Tabelle kommt dazu, Sync-Stand wird zurückgesetzt, Ausgang und Besitzer bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.customStatement("INSERT INTO sync_meta (key, value) VALUES ('sinceRev', '42')");
    await db.customStatement("INSERT INTO sync_meta (key, value) VALUES ('snapshotRev', '40')");
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-18', op: 'delete', entity: 'list', entityId: 'l1'));
    await db.close();
    // Stand 17: ohne Familien-Status
    raw.execute('DROP TABLE familien_status');
    raw.execute('PRAGMA user_version = 17');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.select(db.familienStati).get(), isEmpty);
    await db.into(db.familienStati).insert(FamilienStatiCompanion.insert(id: 's1', userId: 'u1', statusText: 'Beim Sport', createdAt: DateTime(2026, 10, 27)));
    expect((await db.select(db.familienStati).getSingle()).statusText, 'Beim Sport');
    expect(raw.select("SELECT value FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')"), isEmpty, reason: 'Sync-Fortschritt zurückgesetzt, damit vorhandene Stati ankommen');
    expect(raw.select("SELECT value FROM sync_meta WHERE key = 'ownerUserId'").single['value'], 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('Version 18 -> 19: Vorsorge-Tabellen kommen dazu, Sync-Stand wird zurückgesetzt, Ausgang und Besitzer bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.customStatement("INSERT INTO sync_meta (key, value) VALUES ('sinceRev', '42')");
    await db.customStatement("INSERT INTO sync_meta (key, value) VALUES ('snapshotRev', '40')");
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-19', op: 'delete', entity: 'list', entityId: 'l1'));
    await db.close();
    // Stand 18: ohne Vorsorge-Tabellen
    raw.execute('DROP TABLE vorsorge_profile');
    raw.execute('DROP TABLE vorsorge_eintraege');
    raw.execute('PRAGMA user_version = 18');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.select(db.vorsorgeProfile).get(), isEmpty);
    expect(await db.select(db.vorsorgeEintraege).get(), isEmpty);
    await db.into(db.vorsorgeEintraege).insert(VorsorgeEintraegeCompanion.insert(id: 'v1', konversationId: 'k1', inhalt: 'e1:x', createdAt: DateTime(2026, 10, 27)));
    expect(await db.select(db.vorsorgeEintraege).get(), hasLength(1));
    expect(raw.select("SELECT value FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')"), isEmpty, reason: 'Sync-Fortschritt zurückgesetzt, damit vorhandene Einträge ankommen');
    expect(raw.select("SELECT value FROM sync_meta WHERE key = 'ownerUserId'").single['value'], 'u1');
    expect(await db.select(db.outbox).get(), hasLength(1));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('frische Datenbank: Version 19 mit allen Tabellen', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.besitzerSetzen('u1');
    final tabellen = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) r['name']];
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['termin_teilnehmer_termin_idx', 'termin_ausnahmen_termin_idx', 'nachrichten_konversation_idx', 'lesestand_konversation_idx']));
    expect(tabellen, containsAll(['sync_meta', 'outbox', 'lists', 'list_items', 'termine', 'termin_teilnehmer', 'termin_ausnahmen', 'konversationen', 'nachrichten', 'lesestand', 'konversation_epochen', 'epoche_wraps', 'aufgaben', 'aufgabe_punkte', 'reaktionen', 'stimmen', 'pins', 'medikamente', 'einnahmen', 'zaehler', 'zaehlerstaende', 'tresor_eintraege', 'ordner', 'dateien', 'datei_versionen', 'tresor_anhaenge', 'transfers', 'datei_cache', 'familien_status', 'vorsorge_profile', 'vorsorge_eintraege']));
    expect(indizes, containsAll(['zaehler_konversation_idx', 'zaehlerstaende_zaehler_idx', 'zaehlerstaende_konversation_idx', 'tresor_eintraege_konversation_idx', 'konversation_epochen_idx', 'epoche_wraps_idx', 'aufgabe_punkte_aufgabe_idx', 'medikamente_konversation_idx', 'einnahmen_medikament_idx', 'einnahmen_konversation_idx', 'ordner_parent_idx', 'dateien_ordner_idx', 'datei_versionen_datei_idx', 'tresor_anhaenge_konversation_idx', 'transfers_zustand_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 19);
  });

  test('erneutes Öffnen einer Version-19-Datenbank ändert nichts', () async {
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
