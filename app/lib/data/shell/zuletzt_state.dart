// Zustand von "Zuletzt benutzt" und den eingeklappten Gruppen der Seitenleiste: lokal je Gerät in `sync_meta` (nie Server), Lese- und Schreibfehler
// gelten nur bis zum Schließen der App. Änderungen warten, bis der gespeicherte Stand gelesen ist.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import 'zuletzt_logik.dart';

class ShellMerker {
  final List<String> zuletzt;
  final Set<String> gruppenZu;
  final bool geladen;
  const ShellMerker({this.zuletzt = const [], this.gruppenZu = const {}, this.geladen = false});
}

class ShellMerkerNotifier extends Notifier<ShellMerker> {
  int _generation = 0;
  Future<void> _gelesen = Future<void>.value();

  @override
  ShellMerker build() {
    final gen = ++_generation;
    _gelesen = _laden(gen);
    return const ShellMerker();
  }

  Future<void> _laden(int gen) async {
    String? z;
    String? g;
    try {
      final s = ref.read(feiertageSpeicherProvider);
      z = await s.lesen(schluessel: kZuletztSchluessel);
      g = await s.lesen(schluessel: kGruppenZuSchluessel);
    } catch (_) {
      z = g = null;
    }
    if (!ref.mounted || gen != _generation) return;
    state = ShellMerker(zuletzt: zuletztAusText(z), gruppenZu: gruppenZuAusText(g), geladen: true);
  }

  Future<void> _warten() async {
    if (!state.geladen) await _gelesen;
  }

  /// Merkt den Bereich als zuletzt benutzt.
  Future<void> merken(String id) async {
    final gen = _generation;
    await _warten();
    if (!ref.mounted || gen != _generation) return;
    final neu = zuletztMerken(state.zuletzt, id);
    if (neu.length == state.zuletzt.length && [for (var i = 0; i < neu.length; i++) neu[i] == state.zuletzt[i]].every((x) => x)) return;
    state = ShellMerker(zuletzt: neu, gruppenZu: state.gruppenZu, geladen: true);
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(zuletztAlsText(neu), schluessel: kZuletztSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  /// Klappt eine Gruppe der Seitenleiste ein oder aus.
  Future<void> gruppeUmschalten(String gruppe) async {
    final gen = _generation;
    await _warten();
    if (!ref.mounted || gen != _generation) return;
    final neu = {...state.gruppenZu};
    if (!neu.remove(gruppe)) neu.add(gruppe);
    state = ShellMerker(zuletzt: state.zuletzt, gruppenZu: neu, geladen: true);
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(gruppenZuAlsText(neu), schluessel: kGruppenZuSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final shellMerkerProvider = NotifierProvider<ShellMerkerNotifier, ShellMerker>(ShellMerkerNotifier.new);
