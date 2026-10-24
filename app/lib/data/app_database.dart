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

  /// Kurzer Grund-Code (z. B. `forbidden`), wenn der Server die Op endgültig abgelehnt hat und sie als Fehler im Ausgang bleibt (nur neue Chat-Nachrichten,
  /// nie ein Inhalt). Solche Ops werden nicht mehr gesendet, bis die Person "Erneut senden" wählt oder sie verwirft.
  TextColumn get fehlerCode => text().nullable()();
}

/// Listen (Einkauf, Packliste, eigene Listen).
@DataClassName('Liste')
class Listen extends Table {
  @override
  String get tableName => 'lists';

  TextColumn get id => text()();
  TextColumn get name => text()();

  /// shopping | packing | custom | template (Vorlage für Einkaufslisten)
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

  /// Kategorie nach Supermarkt-Gang (Kennung, null = Sonstiges; unbekannte Werte toleriert die Oberfläche).
  TextColumn get category => text().nullable()();
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

  /// Nur Art `meds` (Medikamenten-Plan, Abschnitt 6k): die Person, um deren Medikamente es geht; sonst leer.
  TextColumn get subjektId => text().named('subjekt_id').nullable()();

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

/// Reaktion einer Person auf eine Nachricht (je Person und Nachricht eine, feste ID). `inhalt` ist die Hülle der Schnittstelle (`e1:` bzw. lokal `l1:` im Ausgang), lesbar nur
/// über `NachrichtenInhalt.zusatz`.
@DataClassName('Reaktion')
@TableIndex(name: 'reaktionen_konversation_idx', columns: {#konversationId})
class Reaktionen extends Table {
  @override
  String get tableName => 'reaktionen';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get nachrichtId => text()();
  TextColumn get userId => text()();
  TextColumn get inhalt => text()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Stimme einer Person zu einer Umfrage-Nachricht (je Person und Umfrage eine, feste ID). `geaendertAt` setzt der Server (Stimmen nach dem Ende einer Umfrage zählen nicht).
@DataClassName('Stimme')
@TableIndex(name: 'stimmen_konversation_idx', columns: {#konversationId})
class Stimmen extends Table {
  @override
  String get tableName => 'stimmen';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get nachrichtId => text()();
  TextColumn get userId => text()();
  TextColumn get inhalt => text()();
  IntColumn get geaendertAt => integer().map(const MsDatumConverter()).nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Angeheftete Nachricht (je Nachricht eine, feste ID); kein Inhalt, nur der Bezug.
@DataClassName('ChatPin')
@TableIndex(name: 'pins_konversation_idx', columns: {#konversationId})
class Pins extends Table {
  @override
  String get tableName => 'pins';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get nachrichtId => text()();
  TextColumn get gepinntVon => text().nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Medikament (Medikamenten-Plan, Abschnitt 6k), Kind der Medikamenten-Konversation (`konversationen.art = 'meds'`). `inhalt` ist die Hülle der Schnittstelle (`e1:` bzw. lokal `l1:`
/// im Ausgang), lesbar nur über `NachrichtenInhalt.zusatz` (Art `m`); `bearbeiterId` ist die Person, die den Inhalt zuletzt geschrieben und signiert hat.
@DataClassName('MedikamentZeile')
@TableIndex(name: 'medikamente_konversation_idx', columns: {#konversationId})
class Medikamente extends Table {
  @override
  String get tableName => 'medikamente';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get inhalt => text()();
  TextColumn get bearbeiterId => text().nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Einnahme-Eintrag (Medikamenten-Protokoll), Kind eines Medikaments; Hülle wie beim Medikament (Art `n`). Der Server löscht Einträge nach 120 Tagen.
@DataClassName('EinnahmeZeile')
@TableIndex(name: 'einnahmen_medikament_idx', columns: {#medikamentId})
@TableIndex(name: 'einnahmen_konversation_idx', columns: {#konversationId})
class Einnahmen extends Table {
  @override
  String get tableName => 'einnahmen';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get medikamentId => text()();
  TextColumn get inhalt => text()();
  TextColumn get bearbeiterId => text().nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Zähler (Abschnitt 6l), Kind der Zähler-Konversation (`konversationen.art = 'zaehler'`). `inhalt` ist die Hülle der Schnittstelle (`e1:` bzw. lokal `l1:` im Ausgang), lesbar nur
/// über `NachrichtenInhalt.zusatz` (Art `z`); `bearbeiterId` ist die Person, die den Inhalt zuletzt geschrieben und signiert hat.
@DataClassName('ZaehlerZeile')
@TableIndex(name: 'zaehler_konversation_idx', columns: {#konversationId})
class Zaehler extends Table {
  @override
  String get tableName => 'zaehler';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get inhalt => text()();
  TextColumn get bearbeiterId => text().nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Zählerstand (Abschnitt 6l), Kind eines Zählers; Hülle wie beim Zähler (Art `a`). Dauerhaft: der Server löscht nie von selbst.
@DataClassName('ZaehlerstandZeile')
@TableIndex(name: 'zaehlerstaende_zaehler_idx', columns: {#zaehlerId})
@TableIndex(name: 'zaehlerstaende_konversation_idx', columns: {#konversationId})
class Zaehlerstaende extends Table {
  @override
  String get tableName => 'zaehlerstaende';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get zaehlerId => text()();
  TextColumn get inhalt => text()();
  TextColumn get bearbeiterId => text().nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
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

  /// Familien-Frist (Fristen-Tracker): Ablaufdatum in der Fälligkeit, Vorwarnzeit in `erinnerungMin`
  BoolColumn get frist => boolean().withDefault(const Constant(false))();

  /// Wiederholung der Frist alle N Monate (12 = jährlich), null = einmalig
  IntColumn get fristMonate => integer().nullable()();

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

/// Tresor-Eintrag (Abschnitt 6m), Kind der Tresor-Konversation (`konversationen.art = 'tresor'`). `inhalt` ist die Hülle der Schnittstelle (`e1:` bzw. lokal `l1:` im Ausgang), lesbar nur
/// über `NachrichtenInhalt.zusatz` (Art `t`); `bearbeiterId` ist die Person, die den Inhalt zuletzt geschrieben und signiert hat. Kategorie, Titel, Felder und Notiz stehen nur darin.
@DataClassName('TresorEintragZeile')
@TableIndex(name: 'tresor_eintraege_konversation_idx', columns: {#konversationId})
class TresorEintraege extends Table {
  @override
  String get tableName => 'tresor_eintraege';

  TextColumn get id => text()();
  TextColumn get konversationId => text()();
  TextColumn get inhalt => text()();
  TextColumn get bearbeiterId => text().nullable()();
  IntColumn get createdAt => integer().map(const MsDatumConverter())();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [SyncMeta, Outbox, Listen, ListenEintraege, Termine, TerminTeilnehmer, TerminAusnahmen, Konversationen, Nachrichten, Lesestaende, KonversationEpochen, EpocheWraps, Aufgaben, AufgabePunkte, Reaktionen, Stimmen, Pins, Medikamente, Einnahmen, Zaehler, Zaehlerstaende, TresorEintraege])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Version 2 (Phase 1c): Fachtabellen für Listen, Ausgang mit op_id und sent_at. Version 3 (Phase 1c-2a): Termine, Teilnehmer, Ausnahmen.
  /// Version 4 (Phase 1c-3a): Chat (Konversationen, Nachrichten, Lesestand). Version 5: Chat-Zeiten in Millisekunden.
  /// Version 6 (E2EE Phase 2): `enc_version` der Konversationen, Epochen und Schlüssel-Wraps.
  /// Version 7 (Phase 1c-4a): Aufgaben und Unteraufgaben.
  /// Version 8: Lesestände aller Teilnehmer (Lesebestätigung); der Server liefert sie erst jetzt, darum einmal neu abgleichen.
  /// Version 9: `fehlerCode` im Ausgang (abgelehnte Chat-Nachrichten bleiben als Fehler sichtbar); nur eine Spalte, kein Sync-Reset.
  @override
  int get schemaVersion => 15;

  /// Version 10: Chat-Erweiterungen (Reaktionen, Stimmen, Pins) mit Sync-Reset.
  /// Version 11: `category` an Listeneinträgen (Einkauf nach Gang) mit Sync-Reset, damit vorhandene Kategorien ankommen.
  /// Version 12: `frist` und `frist_monate` an Aufgaben (Fristen-Tracker) mit Sync-Reset, damit vorhandene Werte ankommen.
  /// Version 13: Medikamenten-Plan (`subjekt_id` an Konversationen, Tabellen `medikamente` und `einnahmen`) mit Sync-Reset.
  /// Version 14: Zähler (Tabellen `zaehler` und `zaehlerstaende`) mit Sync-Reset.
  /// Version 15: Tresor (Tabelle `tresor_eintraege`) mit Sync-Reset.

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
        if (from < 9) {
          // nur eine Spalte (kein Sync-Reset); nur anlegen, wenn sie fehlt (erneuter Lauf nach einem abgebrochenen Update)
          final spalten = await customSelect("PRAGMA table_info('outbox')").get();
          if (!spalten.any((r) => r.read<String>('name') == 'fehler_code')) await m.addColumn(outbox, outbox.fehlerCode);
        }
        if (from < 10) {
          await m.createTable(reaktionen);
          await m.createTable(stimmen);
          await m.createTable(pins);
          await m.createIndex(reaktionenKonversationIdx);
          await m.createIndex(stimmenKonversationIdx);
          await m.createIndex(pinsKonversationIdx);
        }
        if (from < 11) {
          // nur anlegen, wenn sie fehlt (erneuter Lauf nach einem abgebrochenen Update)
          final spalten = await customSelect("PRAGMA table_info('list_items')").get();
          if (!spalten.any((r) => r.read<String>('name') == 'category')) await m.addColumn(listenEintraege, listenEintraege.category);
        }
        if (from < 12 && from >= 7) {
          // nur anlegen, wenn sie fehlt (erneuter Lauf nach einem abgebrochenen Update); Version < 7 legt die Tabelle schon mit den Spalten an
          final spalten = await customSelect("PRAGMA table_info('aufgaben')").get();
          if (!spalten.any((r) => r.read<String>('name') == 'frist')) await m.addColumn(aufgaben, aufgaben.frist);
          if (!spalten.any((r) => r.read<String>('name') == 'frist_monate')) await m.addColumn(aufgaben, aufgaben.fristMonate);
        }
        if (from < 13) {
          // Spalte nur anlegen, wenn sie fehlt (erneuter Lauf nach einem abgebrochenen Update; Version < 4 legt die Tabelle schon mit der Spalte an)
          final spalten = await customSelect("PRAGMA table_info('konversationen')").get();
          if (!spalten.any((r) => r.read<String>('name') == 'subjekt_id')) await m.addColumn(konversationen, konversationen.subjektId);
          await m.createTable(medikamente);
          await m.createTable(einnahmen);
          await m.createIndex(medikamenteKonversationIdx);
          await m.createIndex(einnahmenMedikamentIdx);
          await m.createIndex(einnahmenKonversationIdx);
        }
        if (from < 14) {
          await m.createTable(zaehler);
          await m.createTable(zaehlerstaende);
          await m.createIndex(zaehlerKonversationIdx);
          await m.createIndex(zaehlerstaendeZaehlerIdx);
          await m.createIndex(zaehlerstaendeKonversationIdx);
        }
        if (from < 15) {
          await m.createTable(tresorEintraege);
          await m.createIndex(tresorEintraegeKonversationIdx);
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
      if (from == 7) {
        // Version 8 ändert keine Tabelle: bis jetzt kamen nur die eigenen Lesestände, die der anderen Teilnehmer fehlen sonst bis zu ihrer nächsten Änderung.
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from < 10) {
        // Version 10 legt die Tabellen für Reaktionen, Stimmen und Pins an; ohne Reset kämen schon vorhandene nie an (Regel oben).
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from < 11) {
        // Version 11 fügt dem Eintrag ein synchronisiertes Feld hinzu; ohne Reset kämen schon vorhandene Kategorien nie an (Regel oben).
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from < 12) {
        // Version 12 fügt der Aufgabe synchronisierte Felder hinzu; ohne Reset kämen schon vorhandene Fristen nie an (Regel oben).
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from < 13) {
        // Version 13 legt Tabellen für neue Sync-Entitäten an (Medikamente, Einnahmen) und eine Spalte an Konversationen; ohne Reset kämen schon vorhandene nie an (Regel oben).
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from < 14) {
        // Version 14 legt Tabellen für neue Sync-Entitäten an (Zähler, Zählerstände); ohne Reset kämen schon vorhandene nie an (Regel oben).
        await customStatement("DELETE FROM sync_meta WHERE key IN ('sinceRev', 'snapshotRev')");
      }
      if (from < 15) {
        // Version 15 legt eine Tabelle für eine neue Sync-Entität an (Tresor-Einträge); ohne Reset kämen schon vorhandene nie an (Regel oben).
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
