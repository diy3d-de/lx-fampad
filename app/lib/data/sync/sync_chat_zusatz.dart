// Entitäten des Clients für die Chat-Erweiterungen (Gegenstück zu server/src/sync/entities/chat-zusatz.ts): Reaktionen, Stimmen (Umfragen) und Pins.
// Sie hängen an einer Nachricht und werden mit ihr gelöscht. Der Inhalt von Reaktion und Stimme ist eine e1-Hülle (lokal im Ausgang `l1:`), nie Klartext beim Server.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

/// Gemeinsame Teile von Reaktion, Stimme und Pin.
abstract class ChatZusatzEntitaet extends SyncEntity {
  @override
  String get elternGeloescht => 'Die Nachricht wurde gelöscht.';

  /// Je Person und Nachricht gibt es nur eine Zeile: ein abgelehntes Anlegen heißt "gibt es schon" (der Stand des Servers kommt mit dem Abgleich).
  @override
  bool get eindeutigBeiAnlage => true;

  /// Eine abgelehnte neue Zeile (Nachricht inzwischen gelöscht, Pin-Grenze, Rechte) verschwindet ohne Hinweis; der Stand des Servers wird neu geladen.
  @override
  bool get abgelehntStill => true;

  /// Nachricht gelöscht oder schon vorhanden (anderes Gerät): ohne Hinweis; Grenzen und Rechte: ein kurzer Hinweis, nie ein Inhalt.
  @override
  String? stillHinweis(String code) => switch (code) {
    'limit_reached' => 'Du bist zu schnell. Bitte versuche es gleich noch einmal.',
    'forbidden' || 'invalid' => 'Das ging nicht: Die Grenze ist erreicht (höchstens 5 angeheftete Nachrichten) oder dir fehlt das Recht dazu.',
    _ => null,
  };
}

class ReaktionEntitaet extends ChatZusatzEntitaet {
  @override
  String get name => 'reaktion';

  @override
  bool kannAnlegen(Json fields) =>
      _text(fields['konversationId']) != null && _text(fields['nachrichtId']) != null && _text(fields['userId']) != null && _text(fields['inhalt']) != null;

  Selectable<Reaktion> _zeile(AppDatabase db, String id) => db.select(db.reaktionen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Inhalt
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Die Reaktion';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.reaktionen).insert(
        ReaktionenCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          nachrichtId: _text(fields['nachrichtId']) ?? '',
          userId: _text(fields['userId']) ?? '',
          inhalt: _text(fields['inhalt']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.reaktionen)..where((t) => t.id.equals(id))).write(
      ReaktionenCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.reaktionen)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => switch (feld) {
    'nachrichtId' => [for (final r in await (db.select(db.reaktionen)..where((t) => t.nachrichtId.equals(elternId))).get()) r.id],
    'konversationId' => [for (final r in await (db.select(db.reaktionen)..where((t) => t.konversationId.equals(elternId))).get()) r.id],
    _ => const [],
  };

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.reaktionen).go();
}

class StimmeEntitaet extends ChatZusatzEntitaet {
  @override
  String get name => 'stimme';

  @override
  bool kannAnlegen(Json fields) =>
      _text(fields['konversationId']) != null && _text(fields['nachrichtId']) != null && _text(fields['userId']) != null && _text(fields['inhalt']) != null;

  Selectable<Stimme> _zeile(AppDatabase db, String id) => db.select(db.stimmen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Die Stimme';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.stimmen).insert(
        StimmenCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          nachrichtId: _text(fields['nachrichtId']) ?? '',
          userId: _text(fields['userId']) ?? '',
          inhalt: _text(fields['inhalt']) ?? '',
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          geaendertAt: Value(_zeit(fields['geaendertAt'])),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.stimmen)..where((t) => t.id.equals(id))).write(
      StimmenCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        geaendertAt: setze('geaendertAt') ? Value(_zeit(fields['geaendertAt'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.stimmen)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => switch (feld) {
    'nachrichtId' => [for (final r in await (db.select(db.stimmen)..where((t) => t.nachrichtId.equals(elternId))).get()) r.id],
    'konversationId' => [for (final r in await (db.select(db.stimmen)..where((t) => t.konversationId.equals(elternId))).get()) r.id],
    _ => const [],
  };

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.stimmen).go();
}

class PinEntitaet extends ChatZusatzEntitaet {
  @override
  String get name => 'pin';

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['nachrichtId']) != null;

  Selectable<ChatPin> _zeile(AppDatabase db, String id) => db.select(db.pins)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Die Anheftung';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.pins).insert(
        PinsCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          nachrichtId: _text(fields['nachrichtId']) ?? '',
          gepinntVon: Value(_text(fields['gepinntVon'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.pins)..where((t) => t.id.equals(id))).write(
      PinsCompanion(
        gepinntVon: setze('gepinntVon') ? Value(_text(fields['gepinntVon'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.pins)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => switch (feld) {
    'nachrichtId' => [for (final r in await (db.select(db.pins)..where((t) => t.nachrichtId.equals(elternId))).get()) r.id],
    'konversationId' => [for (final r in await (db.select(db.pins)..where((t) => t.konversationId.equals(elternId))).get()) r.id],
    _ => const [],
  };

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.pins).go();
}
