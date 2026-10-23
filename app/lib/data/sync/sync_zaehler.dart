// Entitäten des Clients für die Zähler (Gegenstück zu server/src/sync/entities/zaehler.ts): Zähler (Kind der Zähler-Konversation) und Zählerstand (Kind eines Zählers). Beide
// tragen nur eine Hülle (`e1:` bzw. lokal `l1:` im Ausgang): Art, Name, Preise, Stand und Datum stehen ausschließlich darin.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

/// Gemeinsame Teile von Zähler und Zählerstand.
abstract class ZaehlerEntitaetBasis extends SyncEntity {
  @override
  String get elternGeloescht => 'Der Zähler wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Einträge vorhanden';

  /// Eine neue Zeile, die der Server wegen Mengenbegrenzung ablehnt, bleibt und wird später erneut gesendet (Zählerstände dürfen nicht verloren gehen).
  @override
  bool get bleibtBeiLimit => true;

  /// Eine abgelehnte neue Zeile bleibt mit Fehler stehen, statt still zu verschwinden (nie stillschweigend verlieren).
  @override
  bool get fehlerBleibtSichtbar => true;
}

class ZaehlerEntitaet extends ZaehlerEntitaetBasis {
  @override
  String get name => 'zaehler';

  @override
  List<KindLink> get kinder => const [KindLink('zaehlerstand', 'zaehlerId')];

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['inhalt']) != null;

  Selectable<ZaehlerZeile> _zeile(AppDatabase db, String id) => db.select(db.zaehler)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Name des Zählers: Hinweise sollen nichts Privates auf den Bildschirm bringen
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Zähler';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.zaehler).insert(
        ZaehlerCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          inhalt: _text(fields['inhalt']) ?? '',
          bearbeiterId: Value(_text(fields['bearbeiterId'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.zaehler)..where((t) => t.id.equals(id))).write(
      ZaehlerCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.zaehler)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.zaehler)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.zaehler).go();
}

class ZaehlerstandEntitaet extends ZaehlerEntitaetBasis {
  @override
  String get name => 'zaehlerstand';

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['zaehlerId']) != null && _text(fields['inhalt']) != null;

  Selectable<ZaehlerstandZeile> _zeile(AppDatabase db, String id) => db.select(db.zaehlerstaende)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Zählerstand';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.zaehlerstaende).insert(
        ZaehlerstaendeCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          zaehlerId: _text(fields['zaehlerId']) ?? '',
          inhalt: _text(fields['inhalt']) ?? '',
          bearbeiterId: Value(_text(fields['bearbeiterId'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.zaehlerstaende)..where((t) => t.id.equals(id))).write(
      ZaehlerstaendeCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.zaehlerstaende)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => switch (feld) {
    'zaehlerId' => [for (final r in await (db.select(db.zaehlerstaende)..where((t) => t.zaehlerId.equals(elternId))).get()) r.id],
    'konversationId' => [for (final r in await (db.select(db.zaehlerstaende)..where((t) => t.konversationId.equals(elternId))).get()) r.id],
    _ => const [],
  };

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.zaehlerstaende).go();
}
