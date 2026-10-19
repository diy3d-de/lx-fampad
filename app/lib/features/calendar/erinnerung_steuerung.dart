// Verdrahtung der Terminerinnerungen mit der Oberfläche (HomeShell beobachtet den Provider): Auslöser für den Abgleich und die
// Navigation beim Tippen auf eine Benachrichtigung (Kalender, Monatsansicht, der Tag des Termins).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart';
import '../../data/erinnerungen/erinnerung_einstellungen.dart';
import '../shell/shell_tab.dart';
import 'calendar_state.dart';

/// Hält den Dienst am Laufen, solange die angemeldete Oberfläche besteht: löst den Abgleich bei Start, bei jeder Änderung der Termine
/// (auch durch den Sync), bei geänderten Einstellungen und bei der Rückkehr in die App aus und entfernt beim Abmelden alle Erinnerungen.
final erinnerungSteuerungProvider = Provider<void>((ref) {
  final dienst = ref.watch(erinnerungDienstProvider);
  dienst.beiGeoeffnet = (ziel) {
    ref.read(kalenderAuswahlProvider.notifier)
      ..ansicht(KalenderAnsicht.monat)
      ..tag(ziel.tag);
    ref.read(shellTabProvider.notifier).waehlen(kKalenderTab);
  };
  void los() => unawaited(dienst.abgleichen());
  ref.listen(kalenderDatenProvider, (_, _) => los());
  ref.listen(erinnerungEinstellungenProvider, (_, _) => los());
  ref.listen(authProvider, (alt, neu) {
    if (alt?.angemeldet == true && neu.status == AuthStatus.abgemeldet && neu.hinweis == null) {
      // ausdrückliches Abmelden (bei Sitzungsverlust bleiben Daten und Erinnerungen erhalten)
      unawaited(dienst.alleEntfernen());
    } else {
      los();
    }
  });
  final lebenszyklus = AppLifecycleListener(onResume: los);
  ref.onDispose(lebenszyklus.dispose);
  Future.microtask(los);
});
