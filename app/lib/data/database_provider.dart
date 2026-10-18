import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// Lokale Datenbank; wird erst beim ersten Zugriff geöffnet.
/// Eigene Datei, damit UI-Code und Widget-Tests ohne erzeugten drift-Code (app_database.g.dart) übersetzbar bleiben.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
