// Entitäten-Register des Clients (Gegenstück zu server/src/sync/registry.ts): Jede synchronisierte Tabelle meldet sich hier mit
// ihrem Namen in der Schnittstelle, ihren untergeordneten Entitäten und dem Schreiben/Entfernen von Zeilen an. Store und
// Service arbeiten nur über diese Beschreibung; ein neuer Fachbereich (Termine, Aufgaben, ...) trägt sich in [syncEntities] ein.
import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_chat_zusatz.dart';

/// Untergeordnete Entität: Zeilen von [entity], deren Feld [field] auf die ID des Elternteils zeigt, hängen an ihm (Löschen, Sichtbarkeit).
class KindLink {
  final String entity;
  final String field;
  const KindLink(this.entity, this.field);
}

abstract class SyncEntity {
  /// Name in der Schnittstelle (`entity` einer Op).
  String get name;
  List<KindLink> get kinder => const [];

  /// Reichen diese Felder, um die Zeile neu anzulegen? Ändert die Oberfläche eine Zeile, die es lokal nicht (mehr) gibt (z. B. weil sie
  /// gerade anderswo gelöscht wurde), entsteht keine Teilzeile.
  bool kannAnlegen(Json fields);

  /// Revision des Servers, auf der die lokale Zeile beruht (null: Zeile gibt es nicht; 0: noch nicht synchronisiert).
  Future<int?> rev(AppDatabase db, String id);

  /// Kurzer Name für Hinweise ("Liste „Einkauf“"); null, wenn es die Zeile nicht gibt.
  Future<String?> anzeigename(AppDatabase db, String id);

  /// Legt die Zeile an oder ändert die genannten Felder (Schnittstellenformat). Felder in [ueberspringen] bleiben unberührt
  /// (lokale Änderungen, die noch nicht bestätigt sind). [rev] ersetzt die Revision, wenn angegeben.
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}});

  Future<void> entfernen(AppDatabase db, String id);

  /// IDs der Zeilen dieser Entität, deren Feld [feld] auf [elternId] zeigt (nur für Entitäten mit Elternteil).
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => const [];

  Future<void> leeren(AppDatabase db);

  /// Texte für Hinweise bei abgelehnten Änderungen ("Die Liste wurde gelöscht" / "Die Liste ist voll").
  String get elternGeloescht => 'Die Liste wurde gelöscht.';
  String get grenzeErreicht => 'Die Liste ist voll';

  /// Teilnehmer und Ausnahmen sind je Ziel nur einmal erlaubt: ein abgelehntes Anlegen mit `not_found` heißt dann "gibt es schon" (der Stand
  /// des Servers kommt mit dem Abgleich), nicht "wurde gelöscht".
  bool get eindeutigBeiAnlage => false;

  /// Eine abgelehnte NEUE Zeile dieser Entität ist kein Fehler, sondern Teil des Normalfalls (der erste Schreiber gewinnt, z. B. bei einer gleichzeitigen
  /// Rotation des Epochenschlüssels): die lokale Kopie entfällt ohne Hinweis und der Stand des Servers wird neu geladen.
  bool get abgelehntStill => false;

  /// Eigener Hinweistext, wenn der Server das Anlegen dieser Zeile ablehnt (`not_found`, `deleted`, `forbidden`, `parent_deleted`); die Zeile ist
  /// zu diesem Zeitpunkt noch lokal da. null = die üblichen Texte, leerer Text = kein Hinweis.
  Future<String?> ablehnungsHinweis(AppDatabase db, String id, String code) async => null;

  /// Bei `limit_reached` (Mengenbegrenzung des Servers) bleibt eine neue Zeile erhalten und wird später erneut gesendet, statt zu verschwinden.
  bool get bleibtBeiLimit => false;

  /// Eine endgültig abgelehnte NEUE Zeile dieser Entität bleibt lokal und im Ausgang als Fehler stehen (mit Grund-Code), statt zu verschwinden: die Person
  /// entscheidet über "Erneut senden" oder "Verwerfen" (heute nur Chat-Nachrichten).
  bool get fehlerBleibtSichtbar => false;
}

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;
int? _int(Object? v) => v is int ? v : null;

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// Zeitpunkt in der Schnittstelle (UTC, ISO-8601 mit Millisekunden).
String zeitFuerServer(DateTime t) => _iso(t);

class ListenEntitaet extends SyncEntity {
  @override
  String get name => 'list';

  @override
  List<KindLink> get kinder => const [KindLink('list_item', 'listId')];

  @override
  bool kannAnlegen(Json fields) => _text(fields['name']) != null;

  Selectable<Liste> _zeile(AppDatabase db, String id) => db.select(db.listen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.name;
    return n == null ? null : 'Liste „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.listen).insert(
        ListenCompanion.insert(
          id: id,
          name: _text(fields['name']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          kind: Value(_text(fields['kind']) ?? 'custom'),
          audience: Value(_text(fields['audience']) ?? 'family'),
          ownerId: Value(_text(fields['ownerId'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.listen)..where((t) => t.id.equals(id))).write(
      ListenCompanion(
        name: setze('name') ? Value(_text(fields['name']) ?? vorhanden.name) : const Value.absent(),
        kind: setze('kind') ? Value(_text(fields['kind']) ?? vorhanden.kind) : const Value.absent(),
        audience: setze('audience') ? Value(_text(fields['audience']) ?? vorhanden.audience) : const Value.absent(),
        ownerId: setze('ownerId') ? Value(_text(fields['ownerId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.listen)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.listen).go();
}

class ListenEintraegeEntitaet extends SyncEntity {
  @override
  String get name => 'list_item';

  @override
  bool kannAnlegen(Json fields) => _text(fields['listId']) != null && _text(fields['text']) != null;

  Selectable<Listeneintrag> _zeile(AppDatabase db, String id) => db.select(db.listenEintraege)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.inhalt;
    return n == null ? null : 'Eintrag „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    double? zahl(Object? v) => v is num ? v.toDouble() : null;
    if (vorhanden == null) {
      await db.into(db.listenEintraege).insert(
        ListenEintraegeCompanion.insert(
          id: id,
          listId: _text(fields['listId']) ?? '',
          inhalt: _text(fields['text']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          assigneeId: Value(_text(fields['assigneeId'])),
          doneAt: Value(_zeit(fields['doneAt'])),
          position: Value(zahl(fields['position']) ?? 0),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.listenEintraege)..where((t) => t.id.equals(id))).write(
      ListenEintraegeCompanion(
        listId: setze('listId') && _text(fields['listId']) != null ? Value(_text(fields['listId'])!) : const Value.absent(),
        inhalt: setze('text') ? Value(_text(fields['text']) ?? vorhanden.inhalt) : const Value.absent(),
        assigneeId: setze('assigneeId') ? Value(_text(fields['assigneeId'])) : const Value.absent(),
        doneAt: setze('doneAt') ? Value(_zeit(fields['doneAt'])) : const Value.absent(),
        position: setze('position') ? Value(zahl(fields['position']) ?? vorhanden.position) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.listenEintraege)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'listId'
      ? const []
      : [for (final r in await (db.select(db.listenEintraege)..where((t) => t.listId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.listenEintraege).go();
}

class TermineEntitaet extends SyncEntity {
  @override
  String get name => 'termin';

  @override
  List<KindLink> get kinder => const [KindLink('termin_teilnehmer', 'terminId'), KindLink('termin_ausnahmen', 'terminId')];

  @override
  String get elternGeloescht => 'Der Termin wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es gibt zu viele Termine';

  @override
  bool kannAnlegen(Json fields) => _text(fields['titel']) != null && (fields['startUtc'] != null || fields['startDate'] != null);

  Selectable<Termin> _zeile(AppDatabase db, String id) => db.select(db.termine)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.titel;
    return n == null ? null : 'Termin „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.termine).insert(
        TermineCompanion.insert(
          id: id,
          titel: _text(fields['titel']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          ort: Value(_text(fields['ort']) ?? ''),
          beschreibung: Value(_text(fields['beschreibung']) ?? ''),
          ganztaegig: Value(_bool(fields['ganztaegig']) ?? false),
          startUtc: Value(_zeit(fields['startUtc'])),
          endUtc: Value(_zeit(fields['endUtc'])),
          tzid: Value(_text(fields['tzid'])),
          startDate: Value(_text(fields['startDate'])),
          endDate: Value(_text(fields['endDate'])),
          rrule: Value(_text(fields['rrule'])),
          erinnerungMin: Value(_int(fields['erinnerungMin'])),
          icalUid: Value(_text(fields['icalUid'])),
          audience: Value(_text(fields['audience']) ?? 'family'),
          ownerId: Value(_text(fields['ownerId'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.termine)..where((t) => t.id.equals(id))).write(
      TermineCompanion(
        titel: setze('titel') ? Value(_text(fields['titel']) ?? vorhanden.titel) : const Value.absent(),
        ort: setze('ort') ? Value(_text(fields['ort']) ?? '') : const Value.absent(),
        beschreibung: setze('beschreibung') ? Value(_text(fields['beschreibung']) ?? '') : const Value.absent(),
        ganztaegig: setze('ganztaegig') ? Value(_bool(fields['ganztaegig']) ?? vorhanden.ganztaegig) : const Value.absent(),
        startUtc: setze('startUtc') ? Value(_zeit(fields['startUtc'])) : const Value.absent(),
        endUtc: setze('endUtc') ? Value(_zeit(fields['endUtc'])) : const Value.absent(),
        tzid: setze('tzid') ? Value(_text(fields['tzid'])) : const Value.absent(),
        startDate: setze('startDate') ? Value(_text(fields['startDate'])) : const Value.absent(),
        endDate: setze('endDate') ? Value(_text(fields['endDate'])) : const Value.absent(),
        rrule: setze('rrule') ? Value(_text(fields['rrule'])) : const Value.absent(),
        erinnerungMin: setze('erinnerungMin') ? Value(_int(fields['erinnerungMin'])) : const Value.absent(),
        icalUid: setze('icalUid') ? Value(_text(fields['icalUid'])) : const Value.absent(),
        audience: setze('audience') ? Value(_text(fields['audience']) ?? vorhanden.audience) : const Value.absent(),
        ownerId: setze('ownerId') ? Value(_text(fields['ownerId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.termine)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.termine).go();
}

class TerminTeilnehmerEntitaet extends SyncEntity {
  @override
  String get name => 'termin_teilnehmer';

  @override
  String get elternGeloescht => 'Der Termin wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Der Termin hat zu viele Teilnehmer';

  @override
  bool get eindeutigBeiAnlage => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['terminId']) != null && _text(fields['userId']) != null;

  Selectable<TerminTeilnehmerZeile> _zeile(AppDatabase db, String id) => db.select(db.terminTeilnehmer)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Teilnehmer';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    if (vorhanden == null) {
      await db.into(db.terminTeilnehmer).insert(
        TerminTeilnehmerCompanion.insert(id: id, terminId: _text(fields['terminId']) ?? '', userId: _text(fields['userId']) ?? '', rev: Value(rev ?? 0)),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    // terminId und userId sind unveränderlich
    if (rev != null) await (db.update(db.terminTeilnehmer)..where((t) => t.id.equals(id))).write(TerminTeilnehmerCompanion(rev: Value(rev)));
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.terminTeilnehmer)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'terminId'
      ? const []
      : [for (final r in await (db.select(db.terminTeilnehmer)..where((t) => t.terminId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.terminTeilnehmer).go();
}

class TerminAusnahmenEntitaet extends SyncEntity {
  @override
  String get name => 'termin_ausnahmen';

  @override
  String get elternGeloescht => 'Der Termin wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Die Serie hat zu viele Ausnahmen';

  @override
  bool get eindeutigBeiAnlage => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['terminId']) != null && _text(fields['originalStart']) != null;

  Selectable<TerminAusnahme> _zeile(AppDatabase db, String id) => db.select(db.terminAusnahmen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Ausnahme eines Termins';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.terminAusnahmen).insert(
        TerminAusnahmenCompanion.insert(
          id: id,
          terminId: _text(fields['terminId']) ?? '',
          originalStart: _text(fields['originalStart']) ?? '',
          abgesagt: Value(_bool(fields['abgesagt']) ?? false),
          titel: Value(_text(fields['titel'])),
          start: Value(_text(fields['start'])),
          ende: Value(_text(fields['ende'])),
          ort: Value(_text(fields['ort'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.terminAusnahmen)..where((t) => t.id.equals(id))).write(
      TerminAusnahmenCompanion(
        abgesagt: setze('abgesagt') ? Value(_bool(fields['abgesagt']) ?? vorhanden.abgesagt) : const Value.absent(),
        titel: setze('titel') ? Value(_text(fields['titel'])) : const Value.absent(),
        start: setze('start') ? Value(_text(fields['start'])) : const Value.absent(),
        ende: setze('ende') ? Value(_text(fields['ende'])) : const Value.absent(),
        ort: setze('ort') ? Value(_text(fields['ort'])) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.terminAusnahmen)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'terminId'
      ? const []
      : [for (final r in await (db.select(db.terminAusnahmen)..where((t) => t.terminId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.terminAusnahmen).go();
}

List<String>? _liste(Object? v) => v is List ? [for (final x in v) if (x is String) x] : null;

/// Konversation des Chats. Direkt- und Gruppenchats sehen nur ihre Teilnehmer (der Server liefert nichts anderes); verliert die Person die
/// Sicht, kommt ein `hidden`-Tombstone und der Store entfernt die Konversation samt Nachrichten und Lesestand.
class KonversationEntitaet extends SyncEntity {
  @override
  String get name => 'konversation';

  @override
  List<KindLink> get kinder => const [KindLink('nachricht', 'konversationId'), KindLink('lesestand', 'konversationId'), KindLink('epoche', 'konversationId'), KindLink('epoche_wrap', 'konversationId'), KindLink('reaktion', 'konversationId'), KindLink('stimme', 'konversationId'), KindLink('pin', 'konversationId')];

  @override
  String get elternGeloescht => 'Der Chat wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es gibt zu viele Chats';

  /// Familienchat und Direktchat gibt es je Familie bzw. Paar nur einmal.
  @override
  bool get eindeutigBeiAnlage => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['art']) != null;

  Selectable<Konversation> _zeile(AppDatabase db, String id) => db.select(db.konversationen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Chat';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.konversationen).insert(
        KonversationenCompanion.insert(
          id: id,
          art: _text(fields['art']) ?? 'group',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          titel: Value(_text(fields['titel']) ?? ''),
          teilnehmerJson: Value(jsonEncode(_liste(fields['teilnehmer']) ?? const <String>[])),
          ownerId: Value(_text(fields['ownerId'])),
          encVersion: Value(_text(fields['encVersion']) ?? 'e1'),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.konversationen)..where((t) => t.id.equals(id))).write(
      KonversationenCompanion(
        titel: setze('titel') ? Value(_text(fields['titel']) ?? '') : const Value.absent(),
        teilnehmerJson: setze('teilnehmer') && _liste(fields['teilnehmer']) != null ? Value(jsonEncode(_liste(fields['teilnehmer']))) : const Value.absent(),
        ownerId: setze('ownerId') ? Value(_text(fields['ownerId'])) : const Value.absent(),
        encVersion: setze('encVersion') && _text(fields['encVersion']) != null ? Value(_text(fields['encVersion'])!) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.konversationen)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.konversationen).go();
}

class NachrichtEntitaet extends SyncEntity {
  @override
  String get name => 'nachricht';

  @override
  List<KindLink> get kinder => const [KindLink('reaktion', 'nachrichtId'), KindLink('stimme', 'nachrichtId'), KindLink('pin', 'nachrichtId')];

  @override
  String get elternGeloescht => 'Der Chat wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Du hast zu schnell viele Nachrichten gesendet';

  @override
  bool get bleibtBeiLimit => true;

  @override
  bool get fehlerBleibtSichtbar => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['text']) != null;

  Selectable<Nachricht> _zeile(AppDatabase db, String id) => db.select(db.nachrichten)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Inhalt: Hinweise sollen nichts Privates auf den Bildschirm bringen
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Die Nachricht';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.nachrichten).insert(
        NachrichtenCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          inhalt: _text(fields['text']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          autorId: Value(_text(fields['autorId'])),
          antwortAuf: Value(_text(fields['antwortAuf'])),
          bearbeitetAt: Value(_zeit(fields['bearbeitetAt'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.nachrichten)..where((t) => t.id.equals(id))).write(
      NachrichtenCompanion(
        inhalt: setze('text') ? Value(_text(fields['text']) ?? vorhanden.inhalt) : const Value.absent(),
        autorId: setze('autorId') ? Value(_text(fields['autorId'])) : const Value.absent(),
        antwortAuf: setze('antwortAuf') ? Value(_text(fields['antwortAuf'])) : const Value.absent(),
        bearbeitetAt: setze('bearbeitetAt') ? Value(_zeit(fields['bearbeitetAt'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.nachrichten)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.nachrichten)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.nachrichten).go();
}

class LesestandEntitaet extends SyncEntity {
  @override
  String get name => 'lesestand';

  @override
  String get elternGeloescht => 'Der Chat wurde gelöscht.';

  /// Eine Zeile je Person und Chat: ein abgelehntes Anlegen heißt "gibt es schon" (der Stand des Servers kommt mit dem Abgleich).
  @override
  bool get eindeutigBeiAnlage => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['userId']) != null && _zeit(fields['gelesenBis']) != null;

  Selectable<Lesestand> _zeile(AppDatabase db, String id) => db.select(db.lesestaende)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Lesestand';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.lesestaende).insert(
        LesestaendeCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          userId: _text(fields['userId']) ?? '',
          gelesenBis: _zeit(fields['gelesenBis']) ?? DateTime.fromMillisecondsSinceEpoch(0),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.lesestaende)..where((t) => t.id.equals(id))).write(
      LesestaendeCompanion(
        gelesenBis: setze('gelesenBis') && _zeit(fields['gelesenBis']) != null ? Value(_zeit(fields['gelesenBis'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.lesestaende)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.lesestaende)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.lesestaende).go();
}

class EpocheEntitaet extends SyncEntity {
  @override
  String get name => 'epoche';

  @override
  String get elternGeloescht => 'Der Chat wurde gelöscht.';

  /// Je Konversation und Epoche gibt es nur eine: wer zu spät kommt (gleichzeitige Rotation), übernimmt die des Gewinners.
  @override
  bool get eindeutigBeiAnlage => true;

  @override
  bool get abgelehntStill => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _int(fields['epoche']) != null && _text(fields['mitglieder']) != null;

  Selectable<Epoche> _zeile(AppDatabase db, String id) => db.select(db.konversationEpochen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Schlüssel';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    if (vorhanden == null) {
      await db.into(db.konversationEpochen).insert(
        KonversationEpochenCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          epoche: _int(fields['epoche']) ?? 0,
          mitglieder: _text(fields['mitglieder']) ?? '',
          verteilerId: Value(_text(fields['verteilerId'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    // Epochen sind unveränderlich: nur Revision und (vom Server gesetzter) Verteiler
    await (db.update(db.konversationEpochen)..where((t) => t.id.equals(id))).write(
      KonversationEpochenCompanion(
        verteilerId: fields.containsKey('verteilerId') ? Value(_text(fields['verteilerId'])) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.konversationEpochen)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.konversationEpochen)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.konversationEpochen).go();
}

class EpocheWrapEntitaet extends SyncEntity {
  @override
  String get name => 'epoche_wrap';

  @override
  String get elternGeloescht => 'Der Chat wurde gelöscht.';

  @override
  bool get eindeutigBeiAnlage => true;

  @override
  bool get abgelehntStill => true;

  /// Ein Wrap geht nicht verloren, wenn der Server wegen der Rate kurz ablehnt: er kommt mit neuer op_id wieder in den Ausgang.
  @override
  bool get bleibtBeiLimit => true;

  @override
  String get grenzeErreicht => 'Zu viele Schlüssel auf einmal';

  @override
  bool kannAnlegen(Json fields) =>
      _text(fields['konversationId']) != null && _int(fields['epoche']) != null && _text(fields['empfaengerId']) != null && _text(fields['wrap']) != null;

  Selectable<EpocheWrapZeile> _zeile(AppDatabase db, String id) => db.select(db.epocheWraps)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Schlüssel';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    if (vorhanden == null) {
      await db.into(db.epocheWraps).insert(
        EpocheWrapsCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          epoche: _int(fields['epoche']) ?? 0,
          empfaengerId: _text(fields['empfaengerId']) ?? '',
          wrap: _text(fields['wrap']) ?? '',
          verteilerId: Value(_text(fields['verteilerId'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.epocheWraps)..where((t) => t.id.equals(id))).write(
      EpocheWrapsCompanion(
        verteilerId: fields.containsKey('verteilerId') ? Value(_text(fields['verteilerId'])) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.epocheWraps)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.epocheWraps)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.epocheWraps).go();
}

class AufgabenEntitaet extends SyncEntity {
  @override
  String get name => 'aufgabe';

  @override
  List<KindLink> get kinder => const [KindLink('aufgabe_punkt', 'aufgabeId')];

  @override
  String get elternGeloescht => 'Die Aufgabe wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es gibt zu viele Aufgaben';

  /// Wird eine Folgeaufgabe abgelehnt (ihre ID war schon belegt, gelöscht oder nicht erlaubt), ist das kein Löschen auf einem anderen Gerät.
  @override
  Future<String?> ablehnungsHinweis(AppDatabase db, String id, String code) async {
    if (code != 'not_found' && code != 'deleted' && code != 'forbidden') return null;
    final vorlage = await (db.select(db.aufgaben)..where((t) => t.folgeId.equals(id))).getSingleOrNull();
    if (vorlage == null) return null;
    return 'Die nächste Aufgabe der Wiederholung „${vorlage.titel}“ konnte nicht angelegt werden. Hake sie zurück und wieder ab, dann versucht die App es erneut.';
  }

  @override
  bool kannAnlegen(Json fields) => _text(fields['titel']) != null;

  Selectable<Aufgabe> _zeile(AppDatabase db, String id) => db.select(db.aufgaben)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.titel;
    return n == null ? null : 'Aufgabe „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.aufgaben).insert(
        AufgabenCompanion.insert(
          id: id,
          titel: _text(fields['titel']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          beschreibung: Value(_text(fields['beschreibung']) ?? ''),
          faelligDate: Value(_text(fields['faelligDate'])),
          faelligUtc: Value(_zeit(fields['faelligUtc'])),
          tzid: Value(_text(fields['tzid'])),
          prioritaet: Value(_int(fields['prioritaet']) ?? 0),
          assigneeId: Value(_text(fields['assigneeId'])),
          erledigtAt: Value(_zeit(fields['erledigtAt'])),
          erledigtVon: Value(_text(fields['erledigtVon'])),
          wiederholung: Value(_text(fields['wiederholung'])),
          wiederholungTag: Value(_int(fields['wiederholungTag'])),
          folgeId: Value(_text(fields['folgeId'])),
          erinnerungMin: Value(_int(fields['erinnerungMin'])),
          audience: Value(_text(fields['audience']) ?? 'family'),
          ownerId: Value(_text(fields['ownerId'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.aufgaben)..where((t) => t.id.equals(id))).write(
      AufgabenCompanion(
        titel: setze('titel') ? Value(_text(fields['titel']) ?? vorhanden.titel) : const Value.absent(),
        beschreibung: setze('beschreibung') ? Value(_text(fields['beschreibung']) ?? '') : const Value.absent(),
        faelligDate: setze('faelligDate') ? Value(_text(fields['faelligDate'])) : const Value.absent(),
        faelligUtc: setze('faelligUtc') ? Value(_zeit(fields['faelligUtc'])) : const Value.absent(),
        tzid: setze('tzid') ? Value(_text(fields['tzid'])) : const Value.absent(),
        prioritaet: setze('prioritaet') ? Value(_int(fields['prioritaet']) ?? 0) : const Value.absent(),
        assigneeId: setze('assigneeId') ? Value(_text(fields['assigneeId'])) : const Value.absent(),
        erledigtAt: setze('erledigtAt') ? Value(_zeit(fields['erledigtAt'])) : const Value.absent(),
        erledigtVon: setze('erledigtVon') ? Value(_text(fields['erledigtVon'])) : const Value.absent(),
        wiederholung: setze('wiederholung') ? Value(_text(fields['wiederholung'])) : const Value.absent(),
        wiederholungTag: setze('wiederholungTag') ? Value(_int(fields['wiederholungTag'])) : const Value.absent(),
        folgeId: setze('folgeId') ? Value(_text(fields['folgeId'])) : const Value.absent(),
        erinnerungMin: setze('erinnerungMin') ? Value(_int(fields['erinnerungMin'])) : const Value.absent(),
        audience: setze('audience') ? Value(_text(fields['audience']) ?? vorhanden.audience) : const Value.absent(),
        ownerId: setze('ownerId') ? Value(_text(fields['ownerId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.aufgaben)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.aufgaben).go();
}

class AufgabePunkteEntitaet extends SyncEntity {
  @override
  String get name => 'aufgabe_punkt';

  @override
  String get elternGeloescht => 'Die Aufgabe wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Die Aufgabe hat zu viele Unteraufgaben';

  /// Unteraufgaben einer abgelehnten Folgeaufgabe: der Hinweis steht schon bei der Aufgabe selbst.
  @override
  Future<String?> ablehnungsHinweis(AppDatabase db, String id, String code) async {
    if (code != 'not_found' && code != 'parent_deleted') return null;
    final z = await (db.select(db.aufgabePunkte)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (z == null) return '';
    return await (db.select(db.aufgaben)..where((t) => t.id.equals(z.aufgabeId))).getSingleOrNull() == null ? '' : null;
  }

  @override
  bool kannAnlegen(Json fields) => _text(fields['aufgabeId']) != null && _text(fields['text']) != null;

  Selectable<AufgabePunkt> _zeile(AppDatabase db, String id) => db.select(db.aufgabePunkte)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.inhalt;
    return n == null ? null : 'Unteraufgabe „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    double? zahl(Object? v) => v is num ? v.toDouble() : null;
    if (vorhanden == null) {
      await db.into(db.aufgabePunkte).insert(
        AufgabePunkteCompanion.insert(
          id: id,
          aufgabeId: _text(fields['aufgabeId']) ?? '',
          inhalt: _text(fields['text']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          doneAt: Value(_zeit(fields['doneAt'])),
          position: Value(zahl(fields['position']) ?? 0),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.aufgabePunkte)..where((t) => t.id.equals(id))).write(
      AufgabePunkteCompanion(
        inhalt: setze('text') ? Value(_text(fields['text']) ?? vorhanden.inhalt) : const Value.absent(),
        doneAt: setze('doneAt') ? Value(_zeit(fields['doneAt'])) : const Value.absent(),
        position: setze('position') ? Value(zahl(fields['position']) ?? vorhanden.position) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.aufgabePunkte)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'aufgabeId'
      ? const []
      : [for (final r in await (db.select(db.aufgabePunkte)..where((t) => t.aufgabeId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.aufgabePunkte).go();
}

/// Alle synchronisierten Entitäten des Clients.
final Map<String, SyncEntity> syncEntities = {
  for (final e in <SyncEntity>[
    ListenEntitaet(),
    ListenEintraegeEntitaet(),
    TermineEntitaet(),
    TerminTeilnehmerEntitaet(),
    TerminAusnahmenEntitaet(),
    KonversationEntitaet(),
    NachrichtEntitaet(),
    LesestandEntitaet(),
    EpocheEntitaet(),
    EpocheWrapEntitaet(),
    AufgabenEntitaet(),
    AufgabePunkteEntitaet(),
    ReaktionEntitaet(),
    StimmeEntitaet(),
    PinEntitaet(),
  ])
    e.name: e,
};
