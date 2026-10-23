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
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../../data/auth/reset_hinweis.dart' show sicherheitOeffnenProvider;
import '../../data/betrieb/betrieb_hinweis.dart' show betriebOeffnenProvider;
import '../../data/standort/standort_hinweis.dart' show standortOeffnenProvider;
import '../../data/medikamente/medikament_hinweis.dart' show medikamentOeffnenProvider;
import '../../data/medikamente/medikament_state.dart' show medDatenProvider;
import '../../data/muell/muell_hinweis.dart' show muellOeffnenProvider;
import '../../data/zaehler/zaehler_hinweis.dart' show zaehlerOeffnenProvider;
import '../../data/zaehler/zaehler_state.dart' show zaehlerDatenProvider;
import '../../data/muell/muell_state.dart' show muellProvider;
import '../shell/shell_tab.dart';
import '../tasks/tasks_state.dart' show aufgabeOeffnenProvider;
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
  dienst.beiAufgabeGeoeffnet = (id) {
    // erst den Bereich wählen, dann den Editor anfordern (die Shell schließt beim Wechsel nur die schon offenen Seiten)
    ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
    ref.read(aufgabeOeffnenProvider.notifier).setzen(id);
  };
  dienst.beiStandortGeoeffnet = () => ref.read(standortOeffnenProvider.notifier).anfordern();
  dienst.beiSicherheitGeoeffnet = () => ref.read(sicherheitOeffnenProvider.notifier).anfordern();
  dienst.beiBetriebGeoeffnet = () => ref.read(betriebOeffnenProvider.notifier).anfordern();
  dienst.beiMedikamentGeoeffnet = () => ref.read(medikamentOeffnenProvider.notifier).anfordern();
  dienst.beiZaehlerGeoeffnet = () => ref.read(zaehlerOeffnenProvider.notifier).anfordern();
  dienst.beiMuellGeoeffnet = () => ref.read(muellOeffnenProvider.notifier).anfordern();
  void los() => unawaited(dienst.abgleichen());
  // Abfuhrtermine (Abend vor der Abholung, nur Eltern/Admins): neue Daten oder Einstellungen -> Fenster neu berechnen
  ref.listen(muellProvider.select((z) => z.stand), (_, _) => dienst.entprellt());
  ref.listen(kalenderDatenProvider, (_, _) => dienst.entprellt());
  ref.listen(aufgabenProvider, (_, _) => dienst.entprellt());
  // Einnahme-Erinnerungen: neue Pläne, abgehakte Einnahmen oder eine fertige Entschlüsselung -> Fenster neu berechnen (ein abgehakter Slot nimmt seine Alarme mit)
  ref.listen(medDatenProvider, (alt, neu) {
    // nur wenn sich etwas für die Erinnerungen ändern kann: Pläne vorhanden (oder eben weggefallen) oder die Daten sind erst jetzt geladen; ohne Pläne löst nichts einen Abgleich aus
    if (neu.geladen != (alt?.geladen ?? false) || neu.eintraege.isNotEmpty || (alt?.eintraege.isNotEmpty ?? false)) dienst.entprellt();
  });
  // Ablese-Erinnerungen der Zähler (nur Eltern und Admins; für alle anderen ändert sich nie etwas): neue Stände, Zähler oder eine fertige Entschlüsselung -> Fenster neu berechnen
  ref.listen(zaehlerDatenProvider, (alt, neu) {
    if (neu.geladen != (alt?.geladen ?? false) || neu.reihen.isNotEmpty || (alt?.reihen.isNotEmpty ?? false)) dienst.entprellt();
  });
  ref.listen(erinnerungEinstellungenProvider, (_, _) => los());
  // (die Rolle gehört dazu: ein Rollenwechsel ändert, wer Müll-Erinnerungen bekommt)
  ref.listen(authProvider.select((a) => (a.status, a.user?.id, a.user?.role, a.hinweis)), (_, _) => los());
  // Rückkehr (auch aus den Systemeinstellungen): Erlaubnis neu lesen, damit Anzeigen und Planung ohne Neustart nachziehen
  final lebenszyklus = AppLifecycleListener(
    onResume: () {
      ref.invalidate(erinnerungStatusProvider);
      ref.invalidate(erinnerungDiagnoseProvider);
      los();
    },
  );
  ref.onDispose(lebenszyklus.dispose);
  Future.microtask(los);
});
