// Meldung an den Server, WELCHE Wetter-Hinweisarten dieses Gerät per Wecker haben will (`PUT /me/weather-alerts`, nur die Namen der fünf festen Arten,
// leer = aus). Der Server speichert nur "Gerät will Art X" am Push-Endpunkt dieses Geräts; nie Standort, Messwerte oder Inhalte gehen dorthin.
//
// Wann: nach dem Start/der Anmeldung, bei jeder Änderung der Schalter und wenn der Push-Endpunkt (wieder) angemeldet ist. Nie, wenn der Server das Wetter
// nicht anbietet, Push nicht eingerichtet ist oder die App im Browser läuft (kein Push). Fehler sind still: der nächste Anlass (Start, Schalter) sendet erneut.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../push/push_state.dart';
import 'wetter_hinweise.dart';
import 'wetter_logik.dart' show WetterHinweisArt;
import 'wetter_state.dart';

/// Server-Namen der Arten (feste Liste, wie `ALERT_KINDS` im Server).
List<String> wetterArtNamen(Iterable<WetterHinweisArt> arten) => [for (final a in WetterHinweisArt.values) if (arten.contains(a)) a.name];

class WetterMeldung extends Notifier<void> {
  /// Zuletzt erfolgreich gemeldeter Stand je Person ("id|frost,wind"); überlebt den Neuaufbau, geht mit dem Prozess verloren (dann wird beim Start neu gemeldet).
  String? _gemeldet;

  @override
  void build() {
    if (kIsWeb) return;
    final user = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet ? s.user?.id : null));
    final einst = ref.watch(wetterHinweisEinstellungenProvider);
    final push = ref.watch(pushProvider.select((p) => p.angemeldet));
    if (user == null) _gemeldet = null;
    if (user == null || !einst.geladen || !push) return;
    // erst hier und nicht früher: wetterProvider holt beim Anlegen sofort das Wetter, und die Benachrichtigung nach dem Abruf (wetterHinweisSteuerungProvider) hört erst zu,
    // wenn die Einstellungen gelesen sind; ein früheres Anlegen würde den ersten Abruf an ihr vorbeilaufen lassen
    final verfuegbar = ref.watch(wetterProvider.select((w) => w.dto?.verfuegbar ?? false));
    if (!verfuegbar) return;
    final arten = wetterArtNamen(einst.an);
    final schluessel = '$user|${arten.join(',')}';
    if (schluessel == _gemeldet) return;
    // ohne je etwas gemeldet zu haben ist "nichts gewünscht" der Stand des Servers
    if (_gemeldet == null && arten.isEmpty) return;
    unawaited(_melden(schluessel, arten));
  }

  Future<void> _melden(String schluessel, List<String> arten) async {
    try {
      await ref.read(apiProvider).wetterHinweiseMelden(arten);
      _gemeldet = schluessel;
    } on ApiException {
      // offline, kein Endpunkt (409) oder Wetter am Server aus: der nächste Anlass versucht es erneut
    } on Object {
      // ein Zusatz: nie etwas anderes stören
    }
  }
}

final wetterMeldungProvider = NotifierProvider<WetterMeldung, void>(WetterMeldung.new);
