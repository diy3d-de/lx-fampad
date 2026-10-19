// Migration der lokalen Datenbank von Version 1 (Phase 0 bis 1b: sync_meta + leere outbox) auf Version 2 (Phase 1c: Listen, Einträge,
// Ausgang mit op_id). Der Besitzer der Daten (sync_meta) muss erhalten bleiben, sonst würde nach dem Update nicht erkannt, wem die Daten gehören.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('Version 1 -> 5: Besitzer bleibt, neue Tabellen sind da, Ausgang akzeptiert op_id', () async {
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
    expect(raw.select('PRAGMA user_version').single.values.first, 5);
  });

  test('Version 2 -> 5: Listen und Ausgang bleiben, Termin-Tabellen kommen dazu', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    // Schema der Version 2 (Phase 1c-1): erzeugt von der aktuellen Datenbank ohne die Termin-Tabellen
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    await db.into(db.listen).insert(ListenCompanion.insert(id: 'l1', name: 'Einkauf', createdAt: DateTime(2026, 10, 19)));
    await db.close();
    for (final t in ['termine', 'termin_teilnehmer', 'termin_ausnahmen', 'konversationen', 'nachrichten', 'lesestand']) {
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
    // die Indizes der neuen Tabellen sind auch beim Upgrade da (nicht nur bei einer frischen Datenbank)
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['termin_teilnehmer_termin_idx', 'termin_ausnahmen_termin_idx', 'list_items_list_idx', 'outbox_entity_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 5);
  });

  test('Version 3 -> 5: Listen, Termine und Ausgang bleiben, Chat-Tabellen und Indizes kommen dazu', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.into(db.outbox).insert(OutboxCompanion.insert(opId: 'op-1', op: 'upsert', entity: 'list', entityId: 'l1'));
    await db.into(db.termine).insert(TermineCompanion.insert(id: 't1', titel: 'Zahnarzt', createdAt: DateTime(2026, 10, 19)));
    await db.close();
    for (final t in ['konversationen', 'nachrichten', 'lesestand']) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 3');
    db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(db.close);
    expect(await db.besitzerLesen(), 'u1');
    expect((await db.select(db.termine).get()).single.titel, 'Zahnarzt');
    expect((await db.select(db.outbox).get()).single.opId, 'op-1');
    expect(await db.select(db.konversationen).get(), isEmpty);
    expect(await db.select(db.nachrichten).get(), isEmpty);
    expect(await db.select(db.lesestaende).get(), isEmpty);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'k1', art: 'family', createdAt: DateTime(2026, 10, 19)));
    final k = (await db.select(db.konversationen).get()).single;
    expect(k.teilnehmerJson, '[]');
    expect(k.titel, '');
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['nachrichten_konversation_idx', 'lesestand_konversation_idx', 'termin_teilnehmer_termin_idx']));
    expect(raw.select('PRAGMA user_version').single.values.first, 5);
  });

  test('Version 4 -> 5: Chat-Zeiten werden zu Millisekunden, der Abgleich beginnt neu, andere Daten bleiben', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    var db = AppDatabase(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await db.besitzerSetzen('u1');
    await db.metaSchreiben('sinceRev', '42');
    await db.into(db.listen).insert(ListenCompanion.insert(id: 'l1', name: 'Einkauf', createdAt: DateTime.fromMillisecondsSinceEpoch(1760000000000)));
    await db.close();
    // Stand der Version 4: Sekunden statt Millisekunden
    raw.execute("INSERT INTO konversationen (id, art, titel, teilnehmer, created_at, rev) VALUES ('k1', 'family', '', '[]', 1760000000, 3)");
    raw.execute("INSERT INTO nachrichten (id, konversation_id, text, created_at, bearbeitet_at, rev) VALUES ('n1', 'k1', 'p1:x', 1760000010, 1760000020, 4)");
    raw.execute("INSERT INTO lesestand (id, konversation_id, user_id, gelesen_bis, rev) VALUES ('s1', 'k1', 'u1', 1760000010, 5)");
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
    // Millisekunden bleiben erhalten
    await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: 'n2', konversationId: 'k1', inhalt: 'p1:y', createdAt: DateTime.fromMillisecondsSinceEpoch(1760000010123)));
    expect((await (db.select(db.nachrichten)..where((n) => n.id.equals('n2'))).getSingle()).createdAt.millisecondsSinceEpoch, 1760000010123);
    expect(raw.select('PRAGMA user_version').single.values.first, 5);
  });

  test('frische Datenbank: Version 5 mit allen Tabellen', () async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.besitzerSetzen('u1');
    final tabellen = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) r['name']];
    final indizes = [for (final r in raw.select("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']];
    expect(indizes, containsAll(['termin_teilnehmer_termin_idx', 'termin_ausnahmen_termin_idx', 'nachrichten_konversation_idx', 'lesestand_konversation_idx']));
    expect(tabellen, containsAll(['sync_meta', 'outbox', 'lists', 'list_items', 'termine', 'termin_teilnehmer', 'termin_ausnahmen', 'konversationen', 'nachrichten', 'lesestand']));
    expect(raw.select('PRAGMA user_version').single.values.first, 5);
  });

  test('erneutes Öffnen einer Version-5-Datenbank ändert nichts', () async {
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
