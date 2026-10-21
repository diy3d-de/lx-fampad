// Verdrahtung des Startbildschirm-Widgets "Heute" (Android) mit der Oberfläche: Auslöser für die Zusammenfassung (Termine, Aufgaben, Listen,
// Einstellungen, An-/Abmelden, Rückkehr in die App) und die Navigation beim Tippen auf das Widget. Wie die Erinnerungen am Wurzel-Widget (app.dart)
// beobachtet, damit Änderungen auch bei geöffneten Seiten ankommen.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/heute_widget/heute_widget_dienst.dart';
import '../../data/heute_widget/heute_widget_einstellungen.dart';
import '../../data/heute_widget/heute_widget_port.dart';
import '../../data/lists/list_repository.dart';
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../calendar/calendar_state.dart';
import '../shell/shell_tab.dart';

/// Öffnet den Bereich, auf den das Widget zeigt (nur bekannte Ziele, nur wenn die Person angemeldet ist).
void widgetZielOeffnen(Ref ref, String ziel) {
  if (!kWidgetZiele.contains(ziel)) return;
  if (ref.read(authProvider).status != AuthStatus.angemeldet) return;
  final tab = ref.read(shellTabProvider.notifier);
  switch (ziel) {
    case 'kalender':
      ref.read(kalenderAuswahlProvider.notifier)
        ..ansicht(KalenderAnsicht.agenda)
        ..tag(heuteTag());
      tab.waehlen(kKalenderTab);
    case 'aufgaben':
      tab.waehlen(kAufgabenTab);
    case 'listen':
      final id = ref.read(heuteWidgetEinstellungenProvider).liste;
      if (id != null) ref.read(gewaehlteListeProvider.notifier).waehlen(id);
      tab.waehlen(kListenTab);
  }
}

final heuteWidgetSteuerungProvider = Provider<void>((ref) {
  final dienst = ref.watch(heuteWidgetDienstProvider);
  final port = dienst.port;
  if (!port.verfuegbar) return; // Web und andere Plattformen: kein Widget, nichts beobachten
  void los() => dienst.entprellt();
  ref.listen(kalenderDatenProvider, (_, _) => los());
  ref.listen(aufgabenProvider, (_, _) => los());
  ref.listen(listenProvider, (_, _) => los());
  ref.listen(alleEintraegeProvider, (_, _) => los());
  ref.listen(heuteWidgetEinstellungenProvider, (_, _) => los());
  ref.listen(authProvider.select((a) => (a.status, a.user?.id)), (_, _) => unawaited(dienst.abgleichen()));
  final ziele = port.ziele.listen((z) => widgetZielOeffnen(ref, z));
  ref.onDispose(ziele.cancel);
  // Rückkehr in die App: neu abgleichen (z. B. nach einem Tageswechsel)
  final lebenszyklus = AppLifecycleListener(onResume: () => unawaited(dienst.abgleichen()));
  ref.onDispose(lebenszyklus.dispose);
  Future.microtask(() async {
    await dienst.abgleichen();
    // Start per Tipp auf das Widget: erst öffnen, wenn die Sitzung geprüft ist (die Oberfläche steht dann)
    final start = await port.startZiel();
    if (start != null) {
      if (ref.read(authProvider).status == AuthStatus.angemeldet) {
        widgetZielOeffnen(ref, start);
      } else {
        late final ProviderSubscription<AuthStatus> sub;
        sub = ref.listen(authProvider.select((a) => a.status), (_, s) {
          if (s == AuthStatus.angemeldet) {
            widgetZielOeffnen(ref, start);
            sub.close();
          } else if (s == AuthStatus.abgemeldet) {
            sub.close();
          }
        });
      }
    }
  });
});
