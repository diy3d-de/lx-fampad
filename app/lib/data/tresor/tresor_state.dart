// Tresor (Abschnitt 6m), Zustand: wer den Tresor sehen darf und die verborgene Konversation (für die Teilnehmerpflege). Noch keine Oberfläche.
//
// Zugriff NUR für Eltern und Admins (Rolle `admin`/`parent` der angemeldeten Person; der Server erzwingt dieselbe Regel). Kinder: nichts, kein Lesen der Tabellen, kein Menüpunkt, keine Spur.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show Role;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/chat_repository.dart' show ChatArt;
import '../database_provider.dart';

/// Darf die angemeldete Person den Tresor sehen (Rolle Elternteil oder Admin)? Rein nach der Rolle der Sitzung, nie nach Familienrolle oder Betreiber-Flag.
bool darfRolleTresor(Role? rolle) => rolle == Role.admin || rolle == Role.parent;

final tresorDarfProvider = Provider<bool>((ref) => darfRolleTresor(ref.watch(authProvider.select((a) => a.user?.role))));

/// Die verborgene Tresor-Konversation (nur für die Teilnehmerpflege; ohne sie gibt es nichts zu pflegen).
final tresorKonversationProvider = StreamProvider<List<Konversation>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.konversationen)..where((k) => k.art.equals(ChatArt.tresor.wire))).watch();
});
