// Zustand "Startseite anpassen": gemerkte Reihenfolge und ausgeblendete Kacheln je Layout, lokal je Gerät in `sync_meta` (nie synchronisiert,
// kein Server, kein Schema). Gelesen und geschrieben wird über denselben Speicher wie die übrigen lokalen Anzeige-Einstellungen
// (`feiertageSpeicherProvider`). Lese- und Schreibfehler ergeben die Standardreihenfolge bzw. gelten nur bis zum Schließen der App.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import 'startseite_logik.dart';

abstract class StartseiteNotifier extends Notifier<StartAnordnung> {
  StartLayout get layout;
  bool _geaendert = false;

  @override
  StartAnordnung build() {
    _geaendert = false;
    unawaited(_laden());
    // bis zum Lesen: Standard, aber noch nicht "geladen" (die Startseite zeichnet die Kacheln erst danach, damit nichts springt)
    return StartAnordnung.standard(layout);
  }

  Future<void> _laden() async {
    String? reihenfolge;
    String? ausgeblendet;
    try {
      final speicher = ref.read(feiertageSpeicherProvider);
      reihenfolge = await speicher.lesen(schluessel: layout.reihenfolgeSchluessel);
      ausgeblendet = await speicher.lesen(schluessel: layout.ausgeblendetSchluessel);
    } catch (_) {
      // nicht lesbar: Standardreihenfolge
      reihenfolge = null;
      ausgeblendet = null;
    }
    if (!ref.mounted) return;
    // hat die Person schon etwas geändert, gewinnt das; sonst gilt der gelesene Stand
    state = _geaendert ? state.kopie(geladen: true) : StartAnordnung.aus(layout, reihenfolgeText: reihenfolge, ausgeblendetText: ausgeblendet);
  }

  Future<void> _speichern() async {
    try {
      final speicher = ref.read(feiertageSpeicherProvider);
      await speicher.schreiben(kennungenAlsText(state.reihenfolge), schluessel: layout.reihenfolgeSchluessel);
      await speicher.schreiben(kennungenAlsText(state.ausgeblendet), schluessel: layout.ausgeblendetSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  void _setze(StartAnordnung neu) {
    _geaendert = true;
    state = neu.kopie(geladen: true);
    unawaited(_speichern());
  }

  /// Setzt die neue Reihenfolge einer Teilmenge (die angezeigten Kacheln); alle anderen behalten ihre Plätze.
  void teilmengeOrdnen(List<String> teilNeu) => _setze(state.kopie(reihenfolge: teilmengeNeuOrdnen(state.reihenfolge, teilNeu)));

  /// Verschiebt [id] innerhalb der Teilmenge [teil] um [delta] Plätze.
  void schieben(List<String> teil, String id, int delta) => _setze(state.kopie(reihenfolge: verschiebeUm(state.reihenfolge, teil, id, delta)));

  /// Blendet eine Kachel ein oder aus (die Reihenfolge bleibt).
  void anzeigen(String id, bool an) {
    if (!layout.standard.contains(id)) return;
    final menge = {...state.ausgeblendet};
    if (an) {
      menge.remove(id);
    } else {
      menge.add(id);
    }
    _setze(state.kopie(ausgeblendet: menge));
  }

  /// Standardreihenfolge, nichts ausgeblendet.
  void zuruecksetzen() => _setze(StartAnordnung.standard(layout, geladen: true));
}

class StartseiteMobilNotifier extends StartseiteNotifier {
  @override
  StartLayout get layout => StartLayout.mobil;
}

class StartseiteDesktopNotifier extends StartseiteNotifier {
  @override
  StartLayout get layout => StartLayout.desktop;
}

final startseiteMobilProvider = NotifierProvider<StartseiteMobilNotifier, StartAnordnung>(StartseiteMobilNotifier.new);
final startseiteDesktopProvider = NotifierProvider<StartseiteDesktopNotifier, StartAnordnung>(StartseiteDesktopNotifier.new);

NotifierProvider<StartseiteNotifier, StartAnordnung> startseiteProvider(StartLayout l) =>
    l == StartLayout.mobil ? startseiteMobilProvider : startseiteDesktopProvider;
