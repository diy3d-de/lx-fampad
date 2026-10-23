// Listen und Einträge für die Oberfläche: liest aus der lokalen Datenbank (Streams) und schreibt Änderungen sofort lokal
// (in Tabelle und Ausgang). Der Abgleich mit dem Server läuft im Hintergrund; hier wartet nichts auf das Netz.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';

/// Wer eine Liste sieht.
enum ListenSicht {
  parents('parents', 'Nur Eltern'),
  family('family', 'Familie');

  final String wire;
  final String label;
  const ListenSicht(this.wire, this.label);

  /// Unbekannte Werte (auch das frühere "all" = auch Gäste) gelten als Familie.
  static ListenSicht von(String wire) => values.firstWhere((s) => s.wire == wire, orElse: () => ListenSicht.family);
}

/// Art einer Liste.
enum ListenArt {
  shopping('shopping', 'Einkauf'),
  packing('packing', 'Packliste'),
  custom('custom', 'Eigene Liste'),
  template('template', 'Vorlage');

  final String wire;
  final String label;
  const ListenArt(this.wire, this.label);

  static ListenArt von(String wire) => values.firstWhere((s) => s.wire == wire, orElse: () => ListenArt.custom);

  /// Einkaufslisten und Vorlagen: Einträge mit Kategorie nach Supermarkt-Gang.
  bool get mitKategorien => this == shopping || this == template;
}

/// Sortierung der Einträge: offene zuerst nach Position, erledigte unten (zuletzt erledigte zuerst).
List<Listeneintrag> sortiereEintraege(List<Listeneintrag> alle) {
  final offen = alle.where((e) => e.doneAt == null).toList()
    ..sort((a, b) {
      final p = a.position.compareTo(b.position);
      if (p != 0) return p;
      final t = a.createdAt.compareTo(b.createdAt);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  final erledigt = alle.where((e) => e.doneAt != null).toList()..sort((a, b) => b.doneAt!.compareTo(a.doneAt!));
  return [...offen, ...erledigt];
}

class ListenRepository {
  final AppDatabase db;
  final SyncStore store;

  /// Person, die gerade angemeldet ist (Besitzer neuer Listen, solange der Server es noch nicht bestätigt hat).
  final String? Function() ich;

  /// Wird nach jeder lokalen Änderung aufgerufen (stößt den entprellten Abgleich an).
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  ListenRepository({
    required this.db,
    required this.store,
    required this.ich,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  Stream<List<Liste>> listen() => (db.select(db.listen)..orderBy([(l) => OrderingTerm.asc(l.createdAt), (l) => OrderingTerm.asc(l.id)])).watch();

  Stream<List<Listeneintrag>> eintraege(String listId) => (db.select(db.listenEintraege)..where((e) => e.listId.equals(listId))).watch();

  /// Alle Einträge (für die Startseite).
  Stream<List<Listeneintrag>> alleEintraege() => db.select(db.listenEintraege).watch();

  // ------------------------------------------------------------------ Listen

  Future<String> listeAnlegen({required String name, ListenArt art = ListenArt.shopping, ListenSicht sicht = ListenSicht.family}) async {
    final id = _neueId();
    await store.aendern(
      'list',
      id,
      {'name': name.trim(), 'kind': art.wire, 'audience': sicht.wire},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()},
    );
    beiAenderung();
    return id;
  }

  Future<void> listeUmbenennen(String id, String name) => _aendern('list', id, {'name': name.trim()});

  Future<void> listeSicht(String id, ListenSicht sicht) => _aendern('list', id, {'audience': sicht.wire});

  Future<void> listeLoeschen(String id) async {
    await store.loeschen('list', id);
    beiAenderung();
  }

  // ------------------------------------------------------------------ Einträge

  /// Neuer Eintrag oben in der Liste (Position kleiner als alle offenen).
  Future<String> eintragAnlegen(String listId, String text, {String? zugewiesen, String? kategorie}) async {
    final id = _neueId();
    final kleinste = db.listenEintraege.position.min();
    final zeile =
        await (db.selectOnly(db.listenEintraege)
              ..addColumns([kleinste])
              ..where(db.listenEintraege.listId.equals(listId) & db.listenEintraege.doneAt.isNull()))
            .getSingle();
    final oben = zeile.read(kleinste);
    await store.aendern(
      'list_item',
      id,
      {'listId': listId, 'text': text.trim(), 'position': oben == null ? 0.0 : oben - 1, 'assigneeId': ?zugewiesen, 'category': ?kategorie},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt())},
    );
    beiAenderung();
    return id;
  }

  Future<void> eintragErledigt(String id, bool erledigt) => _aendern('list_item', id, {'doneAt': erledigt ? zeitFuerServer(_jetzt()) : null});

  Future<void> eintragText(String id, String text) => _aendern('list_item', id, {'text': text.trim()});

  Future<void> eintragZuweisen(String id, String? userId) => _aendern('list_item', id, {'assigneeId': userId});

  /// Kategorie ändern; `null` setzt auf "Sonstiges" (kein Wert) zurück.
  Future<void> eintragKategorie(String id, String? kategorie) => _aendern('list_item', id, {'category': kategorie});

  Future<void> eintragVerschieben(String id, double position) => _aendern('list_item', id, {'position': position});

  Future<void> eintragLoeschen(String id) async {
    await store.loeschen('list_item', id);
    beiAenderung();
  }

  /// Speichert die Einträge einer Liste (ohne Erledigt-Stand, Zuständigkeit und Position der Liste) als neue Vorlage mit der Freigabe der Liste.
  /// Liefert die ID der Vorlage; eine leere Liste ergibt keine Vorlage (null).
  Future<String?> alsVorlageSpeichern(Liste liste, {String? name}) async {
    final eintraege = sortiereEintraege(await (db.select(db.listenEintraege)..where((e) => e.listId.equals(liste.id))).get());
    if (eintraege.isEmpty) return null;
    final vorlageId = _neueId();
    final jetzt = zeitFuerServer(_jetzt());
    final n = (name ?? '${liste.name} (Vorlage)').trim();
    await store.aendernMehrere([
      SyncAenderung('list', vorlageId, {'name': n.length > 100 ? n.substring(0, 100) : n, 'kind': ListenArt.template.wire, 'audience': liste.audience},
          nurLokal: {'createdAt': jetzt, 'ownerId': ich()}),
      for (var i = 0; i < eintraege.length; i++)
        SyncAenderung(
          'list_item',
          _neueId(),
          {'listId': vorlageId, 'text': eintraege[i].inhalt, 'position': i.toDouble(), 'category': ?eintraege[i].category},
          nurLokal: {'createdAt': jetzt},
        ),
    ]);
    beiAenderung();
    return vorlageId;
  }

  /// Übernimmt die Einträge einer Vorlage (ohne Erledigt-Stand) in [listId]; Namen, die dort schon offen sind, werden übersprungen.
  /// Liefert die Zahl der neuen Einträge.
  Future<int> ausVorlageUebernehmen(String listId, String vorlageId) async {
    final vorlage = sortiereEintraege(await (db.select(db.listenEintraege)..where((e) => e.listId.equals(vorlageId))).get());
    final offen = {
      for (final e in await (db.select(db.listenEintraege)..where((e) => e.listId.equals(listId) & e.doneAt.isNull())).get()) e.inhalt.trim().toLowerCase(),
    };
    final neu = [for (final e in vorlage) if (offen.add(e.inhalt.trim().toLowerCase())) e];
    if (neu.isEmpty) return 0;
    final kleinste = db.listenEintraege.position.min();
    final zeile =
        await (db.selectOnly(db.listenEintraege)
              ..addColumns([kleinste])
              ..where(db.listenEintraege.listId.equals(listId) & db.listenEintraege.doneAt.isNull()))
            .getSingle();
    final start = (zeile.read(kleinste) ?? 0) - neu.length;
    final jetzt = zeitFuerServer(_jetzt());
    await store.aendernMehrere([
      for (var i = 0; i < neu.length; i++)
        SyncAenderung(
          'list_item',
          _neueId(),
          {'listId': listId, 'text': neu[i].inhalt, 'position': start + i.toDouble(), 'category': ?neu[i].category},
          nurLokal: {'createdAt': jetzt},
        ),
    ]);
    beiAenderung();
    return neu.length;
  }

  Future<void> _aendern(String entity, String id, Map<String, dynamic> felder) async {
    await store.aendern(entity, id, felder);
    beiAenderung();
  }
}

final listenRepositoryProvider = Provider<ListenRepository>((ref) {
  return ListenRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});

final listenProvider = StreamProvider.autoDispose<List<Liste>>((ref) => ref.watch(listenRepositoryProvider).listen());

final eintraegeProvider = StreamProvider.autoDispose.family<List<Listeneintrag>, String>(
  (ref, listId) => ref.watch(listenRepositoryProvider).eintraege(listId),
);

final alleEintraegeProvider = StreamProvider.autoDispose<List<Listeneintrag>>((ref) => ref.watch(listenRepositoryProvider).alleEintraege());

/// Die in der Listen-Ansicht gewählte Liste (null: die erste).
class GewaehlteListe extends Notifier<String?> {
  @override
  String? build() => null;

  void waehlen(String? id) => state = id;
}

final gewaehlteListeProvider = NotifierProvider<GewaehlteListe, String?>(GewaehlteListe.new);
