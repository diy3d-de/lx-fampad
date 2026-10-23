// Zustand "Countdown auf der Startseite": Menge der Termin-IDs, lokal je Gerät in `sync_meta` (über `feiertageSpeicherProvider`).
// Änderungen warten, bis der gespeicherte Stand gelesen ist; Lese-/Schreibfehler gelten nur bis zum Schließen der App.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import 'countdown_logik.dart';

class CountdownTermine extends Notifier<Set<String>> {
  int _generation = 0;
  Future<void> _gelesen = Future<void>.value();
  bool _geladen = false;

  @override
  Set<String> build() {
    final gen = ++_generation;
    _geladen = false;
    _gelesen = _laden(gen);
    return <String>{};
  }

  Future<void> _laden(int gen) async {
    String? text;
    try {
      text = await ref.read(feiertageSpeicherProvider).lesen(schluessel: kCountdownSchluessel);
    } catch (_) {
      text = null;
    }
    if (!ref.mounted || gen != _generation) return;
    state = countdownIdsAusText(text);
    _geladen = true;
  }

  /// Schaltet den Countdown für [terminId] ein oder aus.
  Future<void> schalten(String terminId, bool an) async {
    final gen = _generation;
    if (!_geladen) await _gelesen;
    if (!ref.mounted || gen != _generation) return;
    final neu = {...state};
    an ? neu.add(terminId) : neu.remove(terminId);
    if (neu.length == state.length && neu.containsAll(state)) return;
    state = neu;
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(countdownIdsAlsText(neu), schluessel: kCountdownSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final countdownTermineProvider = NotifierProvider<CountdownTermine, Set<String>>(CountdownTermine.new);
