// Verdrahtung der Terminerinnerungen mit der Oberfläche: Auslöser für den Abgleich und die Navigation beim Tippen auf eine Benachrichtigung
// (Kalender, Monatsansicht, der Tag des Termins). Der Provider wird vom Wurzel-Widget (app.dart) beobachtet; dort wird er nie pausiert
// (Beobachter hinter einer geöffneten Seite pausiert Riverpod 3), sodass Änderungen auch bei offenen Einstellungen oder Editoren ankommen.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart';
import '../../data/erinnerungen/erinnerung_einstellungen.dart';
import '../shell/shell_tab.dart';
import 'calendar_state.dart';

/// Hält den Dienst am Laufen: löst den Abgleich bei Start, bei Änderung der Termine (entprellt, auch durch Sync und ICS-Import), bei
/// geänderten Einstellungen, bei An-/Abmelden und bei der Rückkehr in die App aus. Beim Abmelden löscht der Dienst alle Erinnerungen.
final erinnerungSteuerungProvider = Provider<void>((ref) {
  final dienst = ref.watch(erinnerungDienstProvider);
  if (!dienst.port.verfuegbar) return; // Web und andere Plattformen: keine Erinnerungen, nichts beobachten
  dienst.beiGeoeffnet = (ziel) {
    ref.read(kalenderAuswahlProvider.notifier)
      ..ansicht(KalenderAnsicht.monat)
      ..tag(ziel.tag);
    ref.read(shellTabProvider.notifier).waehlen(kKalenderTab);
  };
  void los() => unawaited(dienst.abgleichen());
  ref.listen(kalenderDatenProvider, (_, _) => dienst.entprellt());
  ref.listen(erinnerungEinstellungenProvider, (_, _) => los());
  ref.listen(authProvider.select((a) => (a.status, a.user?.id, a.hinweis)), (_, _) => los());
  final lebenszyklus = AppLifecycleListener(onResume: los);
  ref.onDispose(lebenszyklus.dispose);
  Future.microtask(los);
});
