// Anzahl der Geräte der angemeldeten Person (GET /devices) für die Fußzeile des Desktop-Layouts.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_error.dart';
import 'auth/auth_state.dart';

/// null, solange unbekannt oder der Server nicht erreichbar ist. Bleibt erhalten (kein Neuabruf beim Wechsel des Layouts), wird bei
/// anderer Person neu geholt und nach Änderungen an den Geräten mit `ref.invalidate(geraeteAnzahlProvider)` aufgefrischt.
final geraeteAnzahlProvider = FutureProvider<int?>((ref) async {
  ref.watch(authProvider.select((s) => s.user?.id));
  try {
    return (await ref.watch(apiProvider).geraete()).length;
  } on ApiException {
    return null;
  }
});
