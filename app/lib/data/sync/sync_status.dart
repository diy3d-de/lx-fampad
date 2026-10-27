// Entität des Clients für den Familien-Status (Gegenstück zu server/src/sync/entities/status.ts, Abschnitt 6o): je Person genau eine Zeile mit fester ID,
// unverschlüsselt, mit optionalem Ablauf `bis`. Den Inhalt zeigt die App nie in Hinweisen oder im Log.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

class StatusEntitaet extends SyncEntity {
  @override
  String get name => 'status';

  @override
  bool kannAnlegen(Json fields) => _text(fields['userId']) != null && _text(fields['text']) != null;

  /// Je Person gibt es nur eine Zeile: ein abgelehntes Anlegen heißt "gibt es schon" (der Stand des Servers kommt mit dem Abgleich).
  @override
  bool get eindeutigBeiAnlage => true;

  /// Eine abgelehnte neue Zeile verschwindet ohne Hinweis; der Stand des Servers wird neu geladen.
  @override
  bool get abgelehntStill => true;

  @override
  String? stillHinweis(String code) => switch (code) {
    'limit_reached' => 'Du bist zu schnell. Bitte versuche es gleich noch einmal.',
    'forbidden' || 'invalid' => 'Dein Status konnte nicht gesetzt werden.',
    _ => null,
  };

  Selectable<FamilienStatusZeile> _zeile(AppDatabase db, String id) => db.select(db.familienStati)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Text
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Dein Status';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.familienStati).insert(
        FamilienStatiCompanion.insert(
          id: id,
          userId: _text(fields['userId']) ?? '',
          statusText: _text(fields['text']) ?? '',
          bis: Value(_zeit(fields['bis'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.familienStati)..where((t) => t.id.equals(id))).write(
      FamilienStatiCompanion(
        statusText: setze('text') ? Value(_text(fields['text']) ?? vorhanden.statusText) : const Value.absent(),
        bis: setze('bis') ? Value(_zeit(fields['bis'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.familienStati)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.familienStati).go();
}
