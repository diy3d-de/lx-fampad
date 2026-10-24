// Entitäten des Clients für die Dateiablage (Gegenstück zu server/src/sync/entities/dateien.ts und tresor-anhang.ts, Abschnitt 6n): Ordner, Datei, Fassung (`datei_version`, unveränderlich)
// und verschlüsselter Tresor-Anhang. Die Bytes liegen nicht im Sync (Blob-Schicht, tus-Upload); die Fassung und der Anhang nennen nur die Upload-ID (`blobId`), die der Server beim Anlegen
// atomar beansprucht. Ordner → Datei → Fassung hängen wie im Server-Register aneinander: `ordner` hat nur als Elternteil-Beziehung (selbstbezüglich) den Ordner, ein Ordner wird NUR leer
// gelöscht (die App löscht von unten nach oben, `DateiRepository`), eine Datei trägt ihre Fassungen als Kinder (Löschen mit Kaskade), der Anhang ist Kind der Tresor-Konversation.
import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';

DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _text(Object? v) => v is String ? v : null;
int? _int(Object? v) => v is int ? v : null;

class OrdnerEntitaet extends SyncEntity {
  @override
  String get name => 'ordner';

  @override
  String get elternGeloescht => 'Der übergeordnete Ordner wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Ordner vorhanden';

  @override
  bool kannAnlegen(Json fields) => _text(fields['name']) != null;

  Selectable<OrdnerZeile> _zeile(AppDatabase db, String id) => db.select(db.ordner)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.name;
    return n == null ? null : 'Ordner „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.ordner).insert(
        OrdnerCompanion.insert(
          id: id,
          parentId: Value(_text(fields['parentId'])),
          name: _text(fields['name']) ?? '',
          audience: Value(_text(fields['audience']) ?? 'family'),
          ownerId: Value(_text(fields['ownerId'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.ordner)..where((t) => t.id.equals(id))).write(
      OrdnerCompanion(
        parentId: setze('parentId') ? Value(_text(fields['parentId'])) : const Value.absent(),
        name: setze('name') ? Value(_text(fields['name']) ?? vorhanden.name) : const Value.absent(),
        audience: setze('audience') ? Value(_text(fields['audience']) ?? vorhanden.audience) : const Value.absent(),
        ownerId: setze('ownerId') ? Value(_text(fields['ownerId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.ordner)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.ordner).go();
}

class DateiEntitaet extends SyncEntity {
  @override
  String get name => 'datei';

  @override
  List<KindLink> get kinder => const [KindLink('datei_version', 'dateiId')];

  @override
  String get elternGeloescht => 'Der Ordner wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Dateien vorhanden';

  @override
  bool kannAnlegen(Json fields) => _text(fields['name']) != null;

  Selectable<DateiZeile> _zeile(AppDatabase db, String id) => db.select(db.dateien)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  @override
  Future<String?> anzeigename(AppDatabase db, String id) async {
    final n = (await _zeile(db, id).getSingleOrNull())?.name;
    return n == null ? null : 'Datei „$n“';
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.dateien).insert(
        DateienCompanion.insert(
          id: id,
          ordnerId: Value(_text(fields['ordnerId'])),
          name: _text(fields['name']) ?? '',
          audience: Value(_text(fields['audience']) ?? 'family'),
          ownerId: Value(_text(fields['ownerId'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    await (db.update(db.dateien)..where((t) => t.id.equals(id))).write(
      DateienCompanion(
        ordnerId: setze('ordnerId') ? Value(_text(fields['ordnerId'])) : const Value.absent(),
        name: setze('name') ? Value(_text(fields['name']) ?? vorhanden.name) : const Value.absent(),
        audience: setze('audience') ? Value(_text(fields['audience']) ?? vorhanden.audience) : const Value.absent(),
        ownerId: setze('ownerId') ? Value(_text(fields['ownerId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.dateien)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.dateien).go();
}

class DateiVersionEntitaet extends SyncEntity {
  @override
  String get name => 'datei_version';

  @override
  String get elternGeloescht => 'Die Datei wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Die Datei hat zu viele Fassungen';

  /// Die Nummer einer Fassung ist je Datei eindeutig: ein abgelehntes Anlegen mit `not_found` heißt "Nummer schon vergeben" (ein anderes Gerät war schneller), nicht "gelöscht".
  @override
  bool get eindeutigBeiAnlage => true;

  @override
  String get ungueltigerVerweis => 'Der hochgeladene Inhalt ist nicht mehr gültig';

  @override
  bool kannAnlegen(Json fields) => _text(fields['dateiId']) != null && _int(fields['nr']) != null && _text(fields['blobId']) != null;

  Selectable<DateiVersionZeile> _zeile(AppDatabase db, String id) => db.select(db.dateiVersionen)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie ein Dateiname in Hinweisen
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Die neue Fassung';

  /// Wird ein neues Anlegen abgelehnt, merkt das die Übertragung (lokale Tabelle `transfers`): Nummer belegt (`nr_belegt`, der Inhalt ist hochgeladen und frei: nur die Fassung neu
  /// anlegen) oder Upload nicht mehr gültig (`invalid_reference`: neu hochladen). Andere Codes werden unverändert als Fehlercode festgehalten.
  @override
  Future<void> nachAblehnung(AppDatabase db, OutboxData op, String code) async {
    if (op.op != 'upsert' || op.baseRev != 0) return;
    final kurz = code == 'not_found' ? 'nr_belegt' : (RegExp(r'^[a-z_]{1,40}$').hasMatch(code) ? code : 'unbekannt');
    await (db.update(db.transfers)..where((t) => t.versionId.equals(op.entityId) & t.zustand.isIn(const ['fertig', 'abschliessen']))).write(TransfersCompanion(zustand: const Value('fehler'), fehlerCode: Value(kurz)));
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.dateiVersionen).insert(
        DateiVersionenCompanion.insert(
          id: id,
          dateiId: _text(fields['dateiId']) ?? '',
          nr: _int(fields['nr']) ?? 1,
          blobId: _text(fields['blobId']) ?? '',
          thumbBlobId: Value(_text(fields['thumbBlobId'])),
          size: Value(_int(fields['size']) ?? 0),
          mime: Value(_text(fields['mime'])),
          sha256: Value(_text(fields['sha256'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    // unveränderlich: nur die Werte, die der Server setzt, und die Revision ändern sich
    await (db.update(db.dateiVersionen)..where((t) => t.id.equals(id))).write(
      DateiVersionenCompanion(
        size: setze('size') && _int(fields['size']) != null ? Value(_int(fields['size'])!) : const Value.absent(),
        mime: setze('mime') ? Value(_text(fields['mime'])) : const Value.absent(),
        sha256: setze('sha256') ? Value(_text(fields['sha256'])) : const Value.absent(),
        thumbBlobId: setze('thumbBlobId') ? Value(_text(fields['thumbBlobId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.dateiVersionen)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'dateiId'
      ? const []
      : [for (final r in await (db.select(db.dateiVersionen)..where((t) => t.dateiId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.dateiVersionen).go();
}

class TresorAnhangEntitaet extends SyncEntity {
  @override
  String get name => 'tresor_anhang';

  @override
  String get elternGeloescht => 'Der Tresor wurde gelöscht.';

  @override
  String get grenzeErreicht => 'Es sind zu viele Anhänge vorhanden';

  @override
  String get ungueltigerVerweis => 'Der hochgeladene Inhalt ist nicht mehr gültig';

  @override
  bool kannAnlegen(Json fields) => _text(fields['konversationId']) != null && _text(fields['blobId']) != null && _text(fields['inhalt']) != null;

  Selectable<TresorAnhangZeile> _zeile(AppDatabase db, String id) => db.select(db.tresorAnhaenge)..where((t) => t.id.equals(id));

  @override
  Future<int?> rev(AppDatabase db, String id) async => (await _zeile(db, id).getSingleOrNull())?.rev;

  // nie der Name der Datei
  @override
  Future<String?> anzeigename(AppDatabase db, String id) async => await _zeile(db, id).getSingleOrNull() == null ? null : 'Der Anhang';

  @override
  Future<void> nachAblehnung(AppDatabase db, OutboxData op, String code) async {
    if (op.op != 'upsert' || op.baseRev != 0) return;
    final kurz = RegExp(r'^[a-z_]{1,40}$').hasMatch(code) ? code : 'unbekannt';
    await (db.update(db.transfers)..where((t) => t.versionId.equals(op.entityId) & t.zustand.isIn(const ['fertig', 'abschliessen']))).write(TransfersCompanion(zustand: const Value('fehler'), fehlerCode: Value(kurz)));
  }

  @override
  Future<void> schreiben(AppDatabase db, String id, Json fields, {int? rev, Set<String> ueberspringen = const {}}) async {
    final vorhanden = await _zeile(db, id).getSingleOrNull();
    bool setze(String f) => fields.containsKey(f) && !ueberspringen.contains(f);
    if (vorhanden == null) {
      await db.into(db.tresorAnhaenge).insert(
        TresorAnhaengeCompanion.insert(
          id: id,
          konversationId: _text(fields['konversationId']) ?? '',
          blobId: _text(fields['blobId']) ?? '',
          inhalt: _text(fields['inhalt']) ?? '',
          size: Value(_int(fields['size']) ?? 0),
          bearbeiterId: Value(_text(fields['bearbeiterId'])),
          createdAt: _zeit(fields['createdAt']) ?? DateTime.now(),
          rev: Value(rev ?? 0),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    // unveränderlich: nur die vom Server gesetzten Werte und die Revision (und der Inhalt, wenn die lokale Hülle `l1:` durch die `e1:` des Servers ersetzt wird)
    await (db.update(db.tresorAnhaenge)..where((t) => t.id.equals(id))).write(
      TresorAnhaengeCompanion(
        inhalt: setze('inhalt') ? Value(_text(fields['inhalt']) ?? vorhanden.inhalt) : const Value.absent(),
        size: setze('size') && _int(fields['size']) != null ? Value(_int(fields['size'])!) : const Value.absent(),
        bearbeiterId: setze('bearbeiterId') ? Value(_text(fields['bearbeiterId'])) : const Value.absent(),
        createdAt: setze('createdAt') && _zeit(fields['createdAt']) != null ? Value(_zeit(fields['createdAt'])!) : const Value.absent(),
        rev: rev != null ? Value(rev) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> entfernen(AppDatabase db, String id) => (db.delete(db.tresorAnhaenge)..where((t) => t.id.equals(id))).go();

  @override
  Future<List<String>> kindIds(AppDatabase db, String feld, String elternId) async => feld != 'konversationId'
      ? const []
      : [for (final r in await (db.select(db.tresorAnhaenge)..where((t) => t.konversationId.equals(elternId))).get()) r.id];

  @override
  Future<void> leeren(AppDatabase db) => db.delete(db.tresorAnhaenge).go();
}
