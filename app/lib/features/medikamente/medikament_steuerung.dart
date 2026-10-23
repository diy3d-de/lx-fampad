// Hält die Teilnehmer der Medikamenten-Konversationen aktuell (Abschnitt 6k): kommt ein Elternteil oder Admin dazu, wechselt eine Rolle oder ändern sich die Mitglieder, nimmt dieses Gerät die
// betroffenen Personen über `MedikamentRepository.alleTeilnehmerPflegen` auf (nur mit vertrauenswürdigem Schlüssel, nie Auto-Vertrauen) und rotiert bei Entfernten den Schlüssel. Läuft am
// Wurzel-Widget (app.dart), nie zwei Läufe gleichzeitig (ein Auslöser während eines Laufs ergibt genau einen weiteren), still: ein Fehler stört nichts und wird beim nächsten Auslöser
// wiederholt. Ohne Änderung ist ein Lauf billig (lokale Lesezugriffe). Nie ein Titel oder Name in einem Hinweis.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/medikamente/medikament_repository.dart';
import '../../data/medikamente/medikament_state.dart';

final medikamentSteuerungProvider = Provider<void>((ref) {
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
        if (!ref.mounted || ref.read(authProvider).user == null) return;
        try {
          await ref.read(medikamentRepositoryProvider).alleTeilnehmerPflegen();
        } on Object {
          // Zusatz: beim nächsten Auslöser erneut
        }
      } while (nochmal && ref.mounted);
    } finally {
      laeuft = false;
    }
  }

  void los() => unawaited(pflegen());

  // Ändern sich die Mitglieder oder Rollen, ändert sich medDatenProvider (er liest die Mitgliederliste nur, wenn es Pläne gibt: wer keine hat, löst keinen Netzaufruf aus)
  ref.listen(medDatenProvider.select((d) => d.personen.map((u) => '${u.id}:${u.role.wire}').join(',')), (_, _) => los());
  ref.listen(medsKonversationenProvider, (_, _) => los());
  ref.listen(e2eeProvider.select((s) => s.mitglieder), (_, _) => los());
  ref.listen(authProvider.select((a) => (a.status, a.user?.id, a.user?.role)), (_, _) => los());
  Future.microtask(los);
});
