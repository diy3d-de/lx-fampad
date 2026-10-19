// Entitäten-Register des Clients (Gegenstück zu server/src/sync/registry.ts): Jede synchronisierte Tabelle meldet sich hier mit
// ihrem Namen in der Schnittstelle, ihren untergeordneten Entitäten und dem Schreiben/Entfernen von Zeilen an. Store und
// Service arbeiten nur über diese Beschreibung; ein neuer Fachbereich (Termine, Aufgaben, ...) trägt sich in [syncEntities] ein.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';

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
}

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;

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

/// Alle synchronisierten Entitäten des Clients.
final Map<String, SyncEntity> syncEntities = {
  for (final e in <SyncEntity>[ListenEntitaet(), ListenEintraegeEntitaet()]) e.name: e,
};
