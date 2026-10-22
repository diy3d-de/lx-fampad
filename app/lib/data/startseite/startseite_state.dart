// Zustand "Startseite anpassen": gemerkte Reihenfolge und ausgeblendete Kacheln je Layout, lokal je Gerät in `sync_meta` (nie synchronisiert,
// kein Server, kein Schema). Gelesen und geschrieben wird über denselben Speicher wie die übrigen lokalen Anzeige-Einstellungen
// (`feiertageSpeicherProvider`). Lese- und Schreibfehler ergeben die Standardreihenfolge bzw. gelten nur bis zum Schließen der App.
//  - Änderungen warten, bis der gespeicherte Stand gelesen ist, und werden dann auf ihn angewendet (nie die gespeicherte Reihenfolge überschreiben).
//  - Ein Lesevorgang, den ein `invalidate` (Datenwipe) überholt hat, verwirft sein Ergebnis (Generationszähler).
//  - Nichts zu schreiben, wenn sich nichts ändert; "Zurücksetzen" löscht die Schlüssel, damit spätere Änderungen der Standardreihenfolge greifen.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import 'startseite_logik.dart';

abstract class StartseiteNotifier extends Notifier<StartAnordnung> {
  StartLayout get layout;
  int _generation = 0;
  Future<void> _gelesen = Future<void>.value();

  @override
  StartAnordnung build() {
    final gen = ++_generation;
    _gelesen = _laden(gen);
    // bis zum Lesen: Standard, aber noch nicht "geladen" (die Startseite zeichnet die Kacheln erst danach, damit nichts springt)
    return StartAnordnung.standard(layout);
  }

  Future<void> _laden(int gen) async {
    String? reihenfolge;
    String? ausgeblendet;
    try {
      final ablage = ref.read(feiertageSpeicherProvider);
      reihenfolge = await ablage.lesen(schluessel: layout.reihenfolgeSchluessel);
      ausgeblendet = await ablage.lesen(schluessel: layout.ausgeblendetSchluessel);
    } catch (_) {
      // nicht lesbar: Standardreihenfolge
      reihenfolge = null;
      ausgeblendet = null;
    }
    if (!ref.mounted || gen != _generation) return;
    state = StartAnordnung.aus(layout, reihenfolgeText: reihenfolge, ausgeblendetText: ausgeblendet);
  }

  Future<void> _speichern(StartAnordnung a) async {
    try {
      final ablage = ref.read(feiertageSpeicherProvider);
      await ablage.schreiben(kennungenAlsText(a.reihenfolge), schluessel: layout.reihenfolgeSchluessel);
      await ablage.schreiben(kennungenAlsText(a.ausgeblendet), schluessel: layout.ausgeblendetSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  /// Wendet [aenderung] auf den gespeicherten Stand an (wartet, falls er noch gelesen wird) und speichert, wenn sich etwas ändert.
  Future<void> _aendern(StartAnordnung Function(StartAnordnung) aenderung) async {
    final gen = _generation;
    if (!state.geladen) await _gelesen;
    if (!ref.mounted || gen != _generation) return;
    final neu = aenderung(state).kopie(geladen: true);
    if (gleicheAnordnung(neu, state)) return;
    state = neu;
    await _speichern(neu);
  }

  /// Setzt die neue Reihenfolge einer Teilmenge (die angezeigten Kacheln); alle anderen behalten ihre Plätze.
  Future<void> teilmengeOrdnen(List<String> teilNeu) => _aendern((a) => a.kopie(reihenfolge: teilmengeNeuOrdnen(a.reihenfolge, teilNeu)));

  /// Verschiebt [id] innerhalb der Teilmenge [teil] um [delta] Plätze.
  Future<void> schieben(List<String> teil, String id, int delta) => _aendern((a) => a.kopie(reihenfolge: verschiebeUm(a.reihenfolge, teil, id, delta)));

  /// Blendet eine Kachel ein oder aus (die Reihenfolge bleibt).
  Future<void> anzeigen(String id, bool an) {
    if (!layout.standard.contains(id)) return Future<void>.value();
    return _aendern((a) {
      final menge = {...a.ausgeblendet};
      an ? menge.remove(id) : menge.add(id);
      return a.kopie(ausgeblendet: menge);
    });
  }

  /// Standardreihenfolge, nichts ausgeblendet: die gespeicherten Werte werden gelöscht (spätere Änderungen der Standardreihenfolge greifen).
  /// Gibt den bisherigen Stand zurück (für "Rückgängig"); null, wenn nichts zu tun war.
  Future<StartAnordnung?> aufStandardSetzen() async {
    final gen = _generation;
    if (!state.geladen) await _gelesen;
    if (!ref.mounted || gen != _generation) return null;
    final alt = state;
    if (alt.istStandard(layout)) return null;
    state = StartAnordnung.standard(layout, geladen: true);
    try {
      final ablage = ref.read(feiertageSpeicherProvider);
      await ablage.loeschen(layout.reihenfolgeSchluessel);
      await ablage.loeschen(layout.ausgeblendetSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
    return alt;
  }

  /// Stellt einen früheren Stand wieder her ("Rückgängig" nach dem Zurücksetzen).
  Future<void> wiederherstellen(StartAnordnung alt) => _aendern((_) => alt);
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
