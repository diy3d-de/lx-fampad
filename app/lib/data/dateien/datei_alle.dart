// Dateiablage (Abschnitt 6n), Oberfläche: alle Dateien der Familie (die die Person sehen darf) mit ihrer neuesten Fassung in EINEM Strom, für die Filter "Zuletzt", "Von mir" und "Offline",
// für die Startseiten-Kachel und für die Detailseite einer Datei. Liest nur die lokale Datenbank; die Regeln der Sicht stehen in `DateiRechte` (nur nach der Rolle).
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart';
import 'datei_repository.dart';
import 'transfer_dienst.dart';

final alleDateienProvider = StreamProvider<List<DateiEintrag>>((ref) {
  final repo = ref.watch(dateiRepositoryProvider);
  final db = repo.db;
  final q = db.select(db.dateien).join([leftOuterJoin(db.dateiVersionen, db.dateiVersionen.dateiId.equalsExp(db.dateien.id))]);
  return q.watch().map((rows) {
    final dateien = <String, DateiZeile>{};
    final nach = <String, List<DateiVersionZeile>>{};
    for (final r in rows) {
      final d = r.readTable(db.dateien);
      dateien[d.id] = d;
      final v = r.readTableOrNull(db.dateiVersionen);
      if (v != null) (nach[d.id] ??= []).add(v);
    }
    final rechte = repo.rechte;
    return [
      for (final d in dateien.values)
        if (rechte.darfSehen(d.audience))
          () {
            final l = nach[d.id] ?? const <DateiVersionZeile>[];
            DateiVersionZeile? neu;
            for (final v in l) {
              if (neu == null || v.nr > neu.nr) neu = v;
            }
            return DateiEintrag(d, neu, l.length);
          }(),
    ];
  });
});

/// Eine Datei nach ihrer ID (null: gibt es nicht (mehr) oder sie ist nicht sichtbar).
final dateiEintragProvider = Provider.family<AsyncValue<DateiEintrag?>, String>((ref, id) => ref.watch(alleDateienProvider).whenData((l) => l.where((e) => e.id == id).firstOrNull));

/// Blob-IDs aller Offline-Kopien dieses Geräts (Android; im Web immer leer).
final offlineBlobsProvider = StreamProvider<Set<String>>((ref) => ref.watch(dateiCacheDienstProvider).kopien().map((l) => {for (final z in l) z.blobId}));

/// Offline-Kopien dieses Geräts nach Blob-ID (Zeile mit Größe und Anheftung; Android).
final offlineKopienProvider = StreamProvider<Map<String, DateiCacheZeile>>((ref) => ref.watch(dateiCacheDienstProvider).kopien().map((l) => {for (final z in l) z.blobId: z}));
