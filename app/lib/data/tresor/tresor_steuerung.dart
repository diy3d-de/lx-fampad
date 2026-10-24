// Hält die Teilnehmer der Tresor-Konversation aktuell (Abschnitt 6m): kommt ein Elternteil oder Admin dazu (neues Mitglied, Kind wird Elternteil), wechselt eine Rolle oder ändern sich die
// Mitglieder, nimmt dieses Gerät die betroffenen Personen über `TresorRepository.teilnehmerPflegen` auf (nur mit vertrauenswürdigem Schlüssel, nie Auto-Vertrauen), gibt ihnen dabei den
// Verlauf des Tresors automatisch frei (`verlaufTeilen: true`, wie bei Zählern und Medikamenten; nie ein Hinweis, der "Tresor" nennt) und rotiert bei Entfernten den Schlüssel.
// Läuft am Wurzel-Widget (app.dart) und NUR für Eltern und Admins; für Kinder tut es nichts und liest nichts. Nie zwei Läufe gleichzeitig, still: ein Fehler stört nichts und wird beim
// nächsten Auslöser wiederholt. Ohne Tresor-Konversation oder ohne Änderung ist ein Lauf billig (lokale Lesezugriffe).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../crypto/e2ee_state.dart';
import '../lists/members.dart';
import 'tresor_repository.dart';
import 'tresor_state.dart';

/// Rollen aller Mitglieder als Text, solange es eine Tresor-Konversation gibt und die Person Eltern/Admin ist (sonst leer: dann liest nichts die Mitgliederliste, kein Netzaufruf).
final tresorRollenProvider = Provider<String>((ref) {
  if (!ref.watch(tresorDarfProvider)) return '';
  final konv = ref.watch(tresorKonversationProvider);
  if (!(konv.value?.isNotEmpty ?? false)) return '';
  final m = ref.watch(mitgliederProvider);
  if (!m.hasValue) return '';
  return m.value!.map((u) => '${u.id}:${u.role.wire}:${u.status.name}').join(',');
});

final tresorSteuerungProvider = Provider<void>((ref) {
  var laeuft = false;
  var nochmal = false;

  Future<void> pflegen() async {
    if (laeuft) {
      nochmal = true;
      return;
    }
    laeuft = true;
    try {
      do {
        nochmal = false;
        if (!ref.mounted || ref.read(authProvider).user == null || !ref.read(tresorDarfProvider)) return;
        try {
          await ref.read(tresorRepositoryProvider).teilnehmerPflegen(verlaufTeilen: true);
        } on Object {
          // Zusatz: beim nächsten Auslöser erneut
        }
      } while (nochmal && ref.mounted);
    } finally {
      laeuft = false;
    }
  }

  void los() => unawaited(pflegen());

  ref.listen(tresorRollenProvider, (_, _) => los());
  ref.listen(tresorKonversationProvider, (_, _) => los());
  ref.listen(e2eeProvider.select((s) => s.mitglieder), (_, _) => los());
  ref.listen(authProvider.select((a) => (a.status, a.user?.id, a.user?.role)), (_, _) => los());
  Future.microtask(los);
});
