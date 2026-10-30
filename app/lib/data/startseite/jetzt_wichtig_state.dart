// Schalter für den Block "Jetzt wichtig" (nur lokal je Gerät in `sync_meta`, Standard: an). Lese- und Schreibfehler ergeben den Standard bzw. gelten
// nur bis zum Schließen der App; eine Änderung wartet, bis der gespeicherte Stand gelesen ist.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import 'jetzt_wichtig_logik.dart';

class JetztWichtigAnNotifier extends Notifier<bool> {
  late Future<void> _bereit;
  int _generation = 0;

  @override
  bool build() {
    final gen = ++_generation;
    _bereit = _laden(gen);
    return true;
  }

  Future<void> _laden(int gen) async {
    var an = true;
    try {
      an = await ref.read(feiertageSpeicherProvider).lesen(schluessel: kJetztWichtigSchluessel) != 'nein';
    } catch (_) {
      // nicht lesbar: Standard
    }
    if (!ref.mounted || gen != _generation) return;
    state = an;
  }

  Future<void> setzen(bool an) async {
    final gen = _generation;
    await _bereit;
    if (!ref.mounted || gen != _generation) return;
    state = an;
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(an ? 'ja' : 'nein', schluessel: kJetztWichtigSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final jetztWichtigAnProvider = NotifierProvider<JetztWichtigAnNotifier, bool>(JetztWichtigAnNotifier.new);
