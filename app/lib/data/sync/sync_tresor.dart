// Entität des Clients für den Tresor (Gegenstück zu server/src/sync/entities/tresor.ts): der Tresor-Eintrag (Kind der Tresor-Konversation). Er trägt nur eine Hülle (`e1:` bzw. lokal
// `l1:` im Ausgang): Kategorie, Titel, Felder und Notiz stehen ausschließlich darin.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

class TresorEintragEntitaet extends SyncEntity {
  @override
  String get name => 'tresor_eintrag';

  @override
  String get elternGeloescht => 'Der Tresor wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Einträge vorhanden';

  /// Eine neue Zeile, die der Server wegen Mengenbegrenzung ablehnt, bleibt und wird später erneut gesendet (Einträge dürfen nicht verloren gehen).
  @override
  bool get bleibtBeiLimit => true;

  /// Eine abgelehnte neue Zeile bleibt mit Fehler stehen, statt still zu verschwinden (nie stillschweigend verlieren).
  @override
  bool get fehlerBleibtSichtbar => true;

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['inhalt']) != null;

  Selectable<TresorEintragZeile> _zeile(AppDatabase db, String id) => db.select(db.tresorEintraege)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Titel: Hinweise sollen nichts Privates auf den Bildschirm bringen
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Eintrag';

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.tresorEintraege).insert(
        TresorEintraegeCompanion.insert(
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
    await (db.update(db.tresorEintraege)..where((t) => t.id.equals(id))).write(
      TresorEintraegeCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.tresorEintraege)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.tresorEintraege)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.tresorEintraege).go();
}
