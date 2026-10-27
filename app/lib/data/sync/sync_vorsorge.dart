// Entitäten des Clients für Vorsorge und Impfungen (Gegenstück zu server/src/sync/entities/vorsorge.ts): Vorsorge-Profil und Vorsorge-Eintrag, beide Kinder der Medikamenten-Konversation.
// Beide tragen nur eine Hülle (`e1:` bzw. lokal `l1:` im Ausgang): Geburtsdatum, Name, Erledigt-Daten und Notiz stehen ausschließlich darin.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

/// Gemeinsame Teile von Profil und Eintrag.
abstract class VorsorgeEntitaetBasis extends SyncEntity {
  @override
  String get elternGeloescht => 'Der Plan wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Einträge vorhanden';

  /// Eine neue Zeile, die der Server wegen Mengenbegrenzung ablehnt, bleibt und wird später erneut gesendet (Gesundheitsdaten nie stillschweigend verlieren).
  @override
  bool get bleibtBeiLimit => true;

  @override
  bool get fehlerBleibtSichtbar => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['inhalt']) != null;
}

class VorsorgeProfilEntitaet extends VorsorgeEntitaetBasis {
  @override
  String get name => 'vorsorge_profil';

  Selectable<VorsorgeProfilZeile> _zeile(AppDatabase db, String id) => db.select(db.vorsorgeProfile)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie ein Inhalt: Hinweise sollen nichts Privates auf den Bildschirm bringen
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Das Profil';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.vorsorgeProfile).insert(
        VorsorgeProfileCompanion.insert(
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
    await (db.update(db.vorsorgeProfile)..where((t) => t.id.equals(id))).write(
      VorsorgeProfileCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.vorsorgeProfile)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.vorsorgeProfile)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.vorsorgeProfile).go();
}

class VorsorgeEintragEntitaet extends VorsorgeEntitaetBasis {
  @override
  String get name => 'vorsorge_eintrag';

  Selectable<VorsorgeEintragZeile> _zeile(AppDatabase db, String id) => db.select(db.vorsorgeEintraege)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Eintrag';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.vorsorgeEintraege).insert(
        VorsorgeEintraegeCompanion.insert(
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
    await (db.update(db.vorsorgeEintraege)..where((t) => t.id.equals(id))).write(
      VorsorgeEintraegeCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.vorsorgeEintraege)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.vorsorgeEintraege)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.vorsorgeEintraege).go();
}
