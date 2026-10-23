// Entitäten des Clients für den Medikamenten-Plan (Gegenstück zu server/src/sync/entities/medikamente.ts): Medikament (Kind der Medikamenten-Konversation) und Einnahme
// (Kind eines Medikaments). Beide tragen nur eine Hülle (`e1:` bzw. lokal `l1:` im Ausgang): Name, Dosis, Rhythmus, Zeitpunkte und Status stehen ausschließlich darin.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

/// Gemeinsame Teile von Medikament und Einnahme.
abstract class MedikamentEntitaetBasis extends SyncEntity {
  @override
  String get elternGeloescht => 'Das Medikament oder der Plan wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Einträge vorhanden';

  /// Eine neue Zeile, die der Server wegen Mengenbegrenzung ablehnt, bleibt und wird später erneut gesendet (Einnahmen dürfen nicht verloren gehen).
  @override
  bool get bleibtBeiLimit => true;

  /// Eine abgelehnte neue Zeile bleibt mit Fehler stehen, statt still zu verschwinden (Gesundheitsdaten: nie stillschweigend verlieren).
  @override
  bool get fehlerBleibtSichtbar => true;
}

class MedikamentEntitaet extends MedikamentEntitaetBasis {
  @override
  String get name => 'medikament';

  @override
  List<KindLink> get kinder => const [KindLink('einnahme', 'medikamentId')];

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['inhalt']) != null;

  Selectable<MedikamentZeile> _zeile(AppDatabase db, String id) => db.select(db.medikamente)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Name des Medikaments: Hinweise sollen nichts Privates auf den Bildschirm bringen
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Das Medikament';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.medikamente).insert(
        MedikamenteCompanion.insert(
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
    await (db.update(db.medikamente)..where((t) => t.id.equals(id))).write(
      MedikamenteCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.medikamente)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.medikamente)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.medikamente).go();
}

class EinnahmeEntitaet extends MedikamentEntitaetBasis {
  @override
  String get name => 'einnahme';

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['medikamentId']) != null && _text(fields['inhalt']) != null;

  Selectable<EinnahmeZeile> _zeile(AppDatabase db, String id) => db.select(db.einnahmen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Die Einnahme';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.einnahmen).insert(
        EinnahmenCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          medikamentId: _text(fields['medikamentId']) ?? '',
          inhalt: _text(fields['inhalt']) ?? '',
          bearbeiterId: Value(_text(fields['bearbeiterId'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.einnahmen)..where((t) => t.id.equals(id))).write(
      EinnahmenCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.einnahmen)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => switch (feld) {
    'medikamentId' => [for (final r in await (db.select(db.einnahmen)..where((t) => t.medikamentId.equals(elternId))).get()) r.id],
    'konversationId' => [for (final r in await (db.select(db.einnahmen)..where((t) => t.konversationId.equals(elternId))).get()) r.id],
    _ => const [],
  };

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.einnahmen).go();
}
