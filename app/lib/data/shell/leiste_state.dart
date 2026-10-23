// Zustand der unteren Leiste (nur mobil): gemerkte Auswahl lokal je Gerät in `sync_meta` (Schlüssel `leiste_bereiche`), nie synchronisiert.
// Lesefehler und ungültige Werte ergeben den Standard; Schreibfehler gelten nur bis zum Schließen der App.
// Änderungen warten, bis der gespeicherte Stand gelesen ist; ein Lesevorgang, den ein `invalidate` überholt hat, verwirft sein Ergebnis.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import 'leiste_logik.dart';

class LeisteZustand {
  /// Tab-Indizes der Bereiche in der Leiste (immer [kLeistePlaetze] gültige).
  final List<int> tabs;
  final bool geladen;
  const LeisteZustand(this.tabs, {this.geladen = false});

  bool get istStandard => tabs.length == kLeisteStandard.length && [for (var i = 0; i < tabs.length; i++) tabs[i] == kLeisteStandard[i]].every((x) => x);
}

class LeisteNotifier extends Notifier<LeisteZustand> {
  int _generation = 0;
  Future<void> _gelesen = Future<void>.value();

  @override
  LeisteZustand build() {
    final gen = ++_generation;
    _gelesen = _laden(gen);
    return const LeisteZustand(kLeisteStandard);
  }

  Future<void> _laden(int gen) async {
    String? text;
    try {
      text = await ref.read(feiertageSpeicherProvider).lesen(schluessel: kLeisteSchluessel);
    } catch (_) {
      text = null;
    }
    if (!ref.mounted || gen != _generation) return;
    state = LeisteZustand(leisteAusText(text), geladen: true);
  }

  Future<void> _aendern(List<int> Function(List<int>) aenderung) async {
    final gen = _generation;
    if (!state.geladen) await _gelesen;
    if (!ref.mounted || gen != _generation) return;
    final neu = aenderung(state.tabs);
    if (!leisteGueltig(neu)) return;
    final gleich = neu.length == state.tabs.length && [for (var i = 0; i < neu.length; i++) neu[i] == state.tabs[i]].every((x) => x);
    if (gleich) return;
    state = LeisteZustand(neu, geladen: true);
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(leisteAlsText(neu), schluessel: kLeisteSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  Future<void> schieben(int index, int delta) => _aendern((t) => leisteSchieben(t, index, delta));

  Future<void> ersetzen(int index, int neuerTab) => _aendern((t) => leisteErsetzen(t, index, neuerTab));

  /// Standard: der gespeicherte Wert wird gelöscht (spätere Änderungen des Standards greifen).
  Future<void> aufStandardSetzen() async {
    final gen = _generation;
    if (!state.geladen) await _gelesen;
    if (!ref.mounted || gen != _generation) return;
    state = const LeisteZustand(kLeisteStandard, geladen: true);
    try {
      await ref.read(feiertageSpeicherProvider).loeschen(kLeisteSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final leisteProvider = NotifierProvider<LeisteNotifier, LeisteZustand>(LeisteNotifier.new);
