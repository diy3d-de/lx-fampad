// Hält die Teilnehmer der Zähler-Konversation aktuell (Abschnitt 6l): kommt ein Elternteil oder Admin dazu (neues Mitglied, Kind wird Elternteil), wechselt eine Rolle oder ändern sich die
// Mitglieder, nimmt dieses Gerät die betroffenen Personen über `ZaehlerRepository.teilnehmerPflegen` auf (nur mit vertrauenswürdigem Schlüssel, nie Auto-Vertrauen), gibt ihnen dabei
// den Verlauf der Zähler automatisch frei (`verlaufTeilen: true`, wie beim Medikamenten-Plan; nie ein Hinweis, der "Zähler" nennt) und rotiert bei Entfernten den Schlüssel.
// Läuft am Wurzel-Widget (app.dart) und NUR für Eltern und Admins; für Kinder tut es nichts und liest nichts. Nie zwei Läufe gleichzeitig (ein Auslöser während eines Laufs ergibt genau
// einen weiteren), still: ein Fehler stört nichts und wird beim nächsten Auslöser wiederholt. Ohne Änderung ist ein Lauf billig (lokale Lesezugriffe).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/lists/members.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';

/// Rollen aller Mitglieder als Text, solange es eine Zähler-Konversation gibt und die Person Eltern/Admin ist (sonst leer: dann liest nichts die Mitgliederliste, kein Netzaufruf).
final zaehlerRollenProvider = Provider<String>((ref) {
  if (!ref.watch(zaehlerDarfProvider)) return '';
  final konv = ref.watch(zaehlerKonversationProvider);
  if (!(konv.value?.isNotEmpty ?? false)) return '';
  final m = ref.watch(mitgliederProvider);
  if (!m.hasValue) return '';
  return m.value!.map((u) => '${u.id}:${u.role.wire}:${u.status.name}').join(',');
});

final zaehlerSteuerungProvider = Provider<void>((ref) {
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
        if (!ref.mounted || ref.read(authProvider).user == null || !ref.read(zaehlerDarfProvider)) return;
        try {
          await ref.read(zaehlerRepositoryProvider).teilnehmerPflegen(verlaufTeilen: true);
        } on Object {
          // Zusatz: beim nächsten Auslöser erneut
        }
      } while (nochmal && ref.mounted);
    } finally {
      laeuft = false;
    }
  }

  void los() => unawaited(pflegen());

  ref.listen(zaehlerRollenProvider, (_, _) => los());
  ref.listen(zaehlerKonversationProvider, (_, _) => los());
  ref.listen(e2eeProvider.select((s) => s.mitglieder), (_, _) => los());
  ref.listen(authProvider.select((a) => (a.status, a.user?.id, a.user?.role)), (_, _) => los());
  Future.microtask(los);
});
