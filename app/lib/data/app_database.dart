// Lokale Datenbank (drift, SQLite; im Web WASM mit OPFS bzw. IndexedDB-Fallback).
// Enthält die lokale Kopie der Familiendaten (Listen, Einträge, Termine), den Ausgang (outbox) und den Sync-Zustand (sync_meta).
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

  /// Wer sie sieht: parents | family (frühere Werte "all" gelten als family)
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

/// Termine (Phase 1c-2a). Zeittermine: `startUtc`/`endUtc` + `tzid`; ganztägige: `startDate`/`endDate` (Text `YYYY-MM-DD`, Ende exklusiv).
@DataClassName('Termin')
class Termine extends Table {
  @override
  String get tableName => 'termine';

  TextColumn get id => text()();
  TextColumn get titel => text()();
  TextColumn get ort => text().withDefault(const Constant(''))();
  TextColumn get beschreibung => text().withDefault(const Constant(''))();
  BoolColumn get ganztaegig => boolean().withDefault(const Constant(false))();
  DateTimeColumn get startUtc => dateTime().nullable()();
  DateTimeColumn get endUtc => dateTime().nullable()();
  TextColumn get tzid => text().nullable()();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  TextColumn get rrule => text().nullable()();
  IntColumn get erinnerungMin => integer().nullable()();
  TextColumn get icalUid => text().nullable()();

  /// parents | family | all (wie bei Listen)
  TextColumn get audience => text().withDefault(const Constant('family'))();
  TextColumn get ownerId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Teilnehmer eines Termins: eine Zeile je Person.
@DataClassName('TerminTeilnehmerZeile')
@TableIndex(name: 'termin_teilnehmer_termin_idx', columns: {#terminId})
class TerminTeilnehmer extends Table {
  @override
  String get tableName => 'termin_teilnehmer';

  TextColumn get id => text()();
  TextColumn get terminId => text()();
  TextColumn get userId => text()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Ausnahmen einer Serie: eine Zeile je Vorkommen (`originalStart`: UTC-Zeitpunkt oder Tag), abgesagt oder mit Überschreibungen.
@DataClassName('TerminAusnahme')
@TableIndex(name: 'termin_ausnahmen_termin_idx', columns: {#terminId})
class TerminAusnahmen extends Table {
  @override
  String get tableName => 'termin_ausnahmen';

  TextColumn get id => text()();
  TextColumn get terminId => text()();
  TextColumn get originalStart => text()();
  BoolColumn get abgesagt => boolean().withDefault(const Constant(false))();
  TextColumn get titel => text().nullable()();
  TextColumn get start => text().nullable()();
  TextColumn get ende => text().nullable()();
  TextColumn get ort => text().nullable()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Zeitpunkt als Millisekunden (INTEGER). drift speichert DateTime sonst nur in ganzen Sekunden; im Chat entscheiden Millisekunden über Reihenfolge und
/// "ungelesen" (Server-Zeiten haben Millisekunden). Nur die Chat-Tabellen nutzen das; Listen und Kalender bleiben unverändert.
class MsDatumConverter extends TypeConverter<DateTime, int> {
  const MsDatumConverter();

  @override
  DateTime fromSql(int fromDb) => DateTime.fromMillisecondsSinceEpoch(fromDb);

  @override
  int toSql(DateTime value) => value.millisecondsSinceEpoch;
}

/// Konversationen des Chats (Phase 1c-3a): `art` family | direct | group. `titel` ist ein undurchsichtiger Text (Hülle mit Versionspräfix,
/// siehe data/chat/nachrichten_inhalt.dart). `teilnehmerJson`: sortierte Mitglieds-IDs als JSON-Liste (beim Familienchat leer).
@DataClassName('Konversation')
class Konversationen extends Table {
  @override
  String get tableName => 'konversationen';

  TextColumn get id => text()();
  TextColumn get art => text()();
  TextColumn get titel => text().withDefault(const Constant(''))();
  TextColumn get teilnehmerJson => text().named('teilnehmer').withDefault(const Constant('[]'))();
  TextColumn get ownerId => text().nullable()();

  /// Version der Inhaltshülle: `e1` Ende-zu-Ende verschlüsselt (Standard), `p1` Klartext (nur Altbestand; die App schreibt dort nicht mehr).
  TextColumn get encVersion => text().named('enc_version').withDefault(const Constant('e1'))();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Epochen einer verschlüsselten Konversation (E2EE Phase 2): `mitglieder` ist die vom Verteiler signierte Mitgliederliste (Base64url, undurchsichtig für
/// Server und Tabelle; geprüft wird sie nur von `ChatKrypto`). Keine Schlüssel: diese stecken in den Wraps, geöffnet werden sie nur im Arbeitsspeicher.
@DataClassName('Epoche')
@TableIndex(name: 'konversation_epochen_idx', columns: {#konversationId, #epoche})
class KonversationEpochen extends Table {
  @override
  String get tableName => 'konversation_epochen';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  IntColumn get epoche => integer()();
  TextColumn get mitglieder => text()();
  TextColumn get verteilerId => text().nullable()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Für eine Person verpackte Epochenschlüssel (E2EE Phase 2): Sealed Box plus Signatur des Verteilers, Base64url. Lokal liegen die der eigenen Person
/// (vom Server) und die selbst verteilten (bis zur Bestätigung); nur der Empfänger kann sie öffnen.
@DataClassName('EpocheWrapZeile')
@TableIndex(name: 'epoche_wraps_idx', columns: {#konversationId, #epoche})
class EpocheWraps extends Table {
  @override
  String get tableName => 'epoche_wraps';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  IntColumn get epoche => integer()();
  TextColumn get empfaengerId => text()();
  TextColumn get wrap => text()();
  TextColumn get verteilerId => text().nullable()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Nachrichten. `inhalt` ist der undurchsichtige Text der Schnittstelle (Klartext-Hülle `p1:…`, später verschlüsselt `e1:…`), lesbar nur über
/// `NachrichtenInhalt`. `rev` 0 heißt: noch nicht vom Server bestätigt ("wird gesendet").
@DataClassName('Nachricht')
@TableIndex(name: 'nachrichten_konversation_idx', columns: {#konversationId, #createdAt})
class Nachrichten extends Table {
  @override
  String get tableName => 'nachrichten';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get autorId => text().nullable()();
  TextColumn get inhalt => text().named('text')();
  TextColumn get antwortAuf => text().nullable()();
  IntColumn get bearbeitetAt => integer().map(const MsDatumConverter()).nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Lesestand der angemeldeten Person je Konversation (nur die eigene Zeile kommt vom Server): `gelesenBis` = Zeit der zuletzt gelesenen Nachricht.
@DataClassName('Lesestand')
@TableIndex(name: 'lesestand_konversation_idx', columns: {#konversationId})
class Lesestaende extends Table {
  @override
  String get tableName => 'lesestand';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get userId => text()();
  IntColumn get gelesenBis => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Aufgaben (Phase 1c-4a). Fälligkeit: ein Tag (`faelligDate`, Text `YYYY-MM-DD`) ODER ein Zeitpunkt (`faelligUtc` + `tzid`), beides leer = ohne.
@DataClassName('Aufgabe')
class Aufgaben extends Table {
  @override
  String get tableName => 'aufgaben';

  TextColumn get id => text()();
  TextColumn get titel => text()();
  TextColumn get beschreibung => text().withDefault(const Constant(''))();
  TextColumn get faelligDate => text().nullable()();
  DateTimeColumn get faelligUtc => dateTime().nullable()();
  TextColumn get tzid => text().nullable()();

  /// 0 keine, 1 niedrig, 2 mittel, 3 hoch
  IntColumn get prioritaet => integer().withDefault(const Constant(0))();
  TextColumn get assigneeId => text().nullable()();
  DateTimeColumn get erledigtAt => dateTime().nullable()();
  TextColumn get erledigtVon => text().nullable()();

  /// daily | weekly | monthly | null
  TextColumn get wiederholung => text().nullable()();

  /// Wunschtag des Monats (1 bis 31) bei monatlicher Wiederholung, bleibt in der Kette erhalten
  IntColumn get wiederholungTag => integer().nullable()();

  /// ID der Folgeaufgabe, die beim Erledigen entstand (abgeleitet oder, bei belegter ID, zufällig)
  TextColumn get folgeId => text().nullable()();
  IntColumn get erinnerungMin => integer().nullable()();

  /// parents | family (wie bei Listen)
  TextColumn get audience => text().withDefault(const Constant('family'))();
  TextColumn get ownerId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Unteraufgaben (Checkliste) einer Aufgabe; `position` wie bei Listeneinträgen.
@DataClassName('AufgabePunkt')
@TableIndex(name: 'aufgabe_punkte_aufgabe_idx', columns: {#aufgabeId})
class AufgabePunkte extends Table {
  @override
  String get tableName => 'aufgabe_punkte';

  TextColumn get id => text()();
  TextColumn get aufgabeId => text()();
  TextColumn get inhalt => text().named('text')();
  DateTimeColumn get doneAt => dateTime().nullable()();
  RealColumn get position => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [SyncMeta, Outbox, Listen, ListenEintraege, Termine, TerminTeilnehmer, TerminAusnahmen, Konversationen, Nachrichten, Lesestaende, KonversationEpochen, EpocheWraps, Aufgaben, AufgabePunkte])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Version 2 (Phase 1c): Fachtabellen für Listen, Ausgang mit op_id und sent_at. Version 3 (Phase 1c-2a): Termine, Teilnehmer, Ausnahmen.
  /// Version 4 (Phase 1c-3a): Chat (Konversationen, Nachrichten, Lesestand). Version 5: Chat-Zeiten in Millisekunden.
  /// Version 6 (E2EE Phase 2): `enc_version` der Konversationen, Epochen und Schlüssel-Wraps.
  /// Version 7 (Phase 1c-4a): Aufgaben und Unteraufgaben.
  @override
  int get schemaVersion => 7;

  /// Migrationen nur vorwärts. Version 1 (Phase 0 bis 1b) kannte nur `sync_meta` (mit dem Besitzer der Daten) und eine nie
  /// benutzte `outbox` ohne op_id: der Besitzer bleibt erhalten, die leere Outbox wird neu angelegt.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.deleteTable('outbox');
        await m.createAll();
      } else {
        if (from < 3) {
          await m.createTable(termine);
          await m.createTable(terminTeilnehmer);
          await m.createTable(terminAusnahmen);
          // createTable legt die @TableIndex-Indizes nicht mit an
          await m.createIndex(terminTeilnehmerTerminIdx);
          await m.createIndex(terminAusnahmenTerminIdx);
        }
        if (from < 4) {
          await m.createTable(konversationen);
          await m.createTable(nachrichten);
          await m.createTable(lesestaende);
          await m.createIndex(nachrichtenKonversationIdx);
          await m.createIndex(lesestandKonversationIdx);
        }
        if (from == 4) {
          // Sekunden -> Millisekunden; danach alles neu laden, damit die Zeiten die volle Auflösung des Servers haben
          await customStatement('UPDATE konversationen SET created_at = created_at * 1000');
          await customStatement('UPDATE nachrichten SET created_at = created_at * 1000, bearbeitet_at = bearbeitet_at * 1000');
          await customStatement('UPDATE lesestand SET gelesen_bis = gelesen_bis * 1000');
          await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
        }
        if (from < 6) {
          // Konversationen aus Version 4/5 (nur Entwicklungsstände, nie veröffentlicht) sind Klartext-Chats: p1. Frische Zeilen bekommen e1.
          if (from >= 4) await m.addColumn(konversationen, konversationen.encVersion);
          if (from >= 4) await customStatement("UPDATE konversationen SET enc_version = 'p1'");
          await m.createTable(konversationEpochen);
          await m.createTable(epocheWraps);
          await m.createIndex(konversationEpochenIdx);
          await m.createIndex(epocheWrapsIdx);
        }
        if (from < 7) {
          await m.createTable(aufgaben);
          await m.createTable(aufgabePunkte);
          await m.createIndex(aufgabePunkteAufgabeIdx);
        }
      }
      // Regel: Jeder Schritt, der Tabellen für Sync-Entitäten anlegt, setzt den Sync-Fortschritt zurück. Die ältere App hat Entitäten
      // ohne Definition übersprungen, ihren Cursor aber weitergerückt; ohne Reset kämen diese Datensätze nie an. sinceRev 0 holt einen
      // vollständigen Snapshot (Upsert; offene lokale Änderungen und der Ausgang bleiben). deviceId, ownerUserId, members bleiben.
      if (from < 6) {
        // Auch Zeilen, die der Server inzwischen gelöscht hat, würden sonst als Geister bleiben (der Snapshot ergänzt nur): die synchronisierten Chat-Tabellen werden
        // geleert, nur lokal neu angelegte, noch unbestätigte Zeilen (rev 0) bleiben, wie beim Neuaufbau im Sync (SyncStore._neuAufsetzen).
        if (from >= 4) {
          for (final tabelle in const ['nachrichten', 'lesestand', 'konversationen']) {
            await customStatement('DELETE FROM $tabelle WHERE rev > 0');
          }
        }
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from >= 6 && from < 7) {
        // Version 7 legt nur die Aufgaben-Tabellen an; ohne Reset kämen schon vorhandene Aufgaben nie an.
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
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

  /// Schlüssel mit dem Präfix (ohne die LIKE-Zeichen % und _, z. B. 'avatar:').
  Future<List<String>> metaSchluesselMit(String prefix) async => [for (final r in await (select(syncMeta)..where((t) => t.key.like('$prefix%'))).get()) r.key];

  Future<void> metaLoeschen(String key) => (delete(syncMeta)..where((t) => t.key.equals(key))).go();

  static QueryExecutor _openConnection() => driftDatabase(
    name: 'lx_fampad',
    // sqlite3.wasm und drift_worker.js liegen in web/ (keine CDN-Abrufe), Versionen siehe docs/VERSIONEN.md
    // zwei Engines (Oberfläche und Hintergrund-Start) können dieselbe Datei öffnen: kurz warten statt sofort "database is locked"
    native: DriftNativeOptions(setup: (db) => db.execute('PRAGMA busy_timeout = 5000')),
    web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')),
  );
}
