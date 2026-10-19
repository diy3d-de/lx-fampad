import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';
import 'auth/auth_state.dart';

/// Lokale Datenbank; wird erst beim ersten Zugriff geöffnet.
/// Eigene Datei, damit UI-Code und Widget-Tests ohne erzeugten drift-Code (app_database.g.dart) übersetzbar bleiben.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Besitzer der lokalen Daten, gespeichert in der Datenbank selbst (siehe auth_state.dart, "Lokale Daten und Sitzungsverlust").
class DatenbankBesitzer implements LocalDataOwner {
  final AppDatabase _db;
  DatenbankBesitzer(this._db);

  @override
  Future<String?> lesen() => _db.besitzerLesen();

  @override
  Future<void> setzen(String userId) => _db.besitzerSetzen(userId);
}
