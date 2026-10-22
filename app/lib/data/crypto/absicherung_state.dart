// Zustand der Absicherungs-Ampel ("Bin ich abgesichert?", absicherung.dart): verbindet den geladenen Zustand der Verschlüsselung mit den Wegen laut Server
// (`GET /me/key-status`). Der Server-Teil ist nur eine Ergänzung (andere Geräte, die einen Schlüssel melden); fehlt er (älterer Server, offline), rechnet die App
// mit dem, was sie selbst weiß, und zeigt nie mehr als das: grün gibt es nie ohne bestätigte Sicherung.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart' show SchluesselWegeDto;
import '../auth/auth_state.dart';
import 'absicherung.dart';
import 'e2ee_state.dart';

/// Wege laut Server; null bei unklarem Stand, älterem Server oder Fehler. Wird neu geholt, wenn sich Stand oder Sicherungen ändern.
final schluesselWegeProvider = FutureProvider.autoDispose<SchluesselWegeDto?>((ref) async {
  final eingeloggt = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet));
  // neu holen, wenn sich etwas ändert, das die Wege betrifft (Verbinden, neue Sicherung, Schlüsselwechsel)
  ref.watch(e2eeProvider.select((s) => (s.status, s.pwBestaetigtAm, s.wiederherstellungAm, s.pwSicherungVeraltet, s.serverSchluessel?.version)));
  final status = ref.read(e2eeProvider).status;
  if (!eingeloggt || status == E2eeStatus.laedt || status == E2eeStatus.nichtVerfuegbar) return null;
  try {
    return await ref.read(apiProvider).schluesselWege();
  } on ApiException {
    return null; // älterer Server (404), offline oder gestört: die App rechnet allein
  } on Object {
    return null;
  }
}, retry: (_, _) => null);

/// Die Ampel der eigenen Person.
final absicherungProvider = Provider<AbsicherungsStatus>((ref) {
  final s = ref.watch(e2eeProvider);
  final server = ref.watch(schluesselWegeProvider).value;
  return bewerteAbsicherung(s, server: server);
});
