// Tresor (Abschnitt 6m), Sperre: der Tresor ist beim Öffnen gesperrt. Entsperrt wird nur nach einer frischen Bestätigung der Person (Step-up, siehe features/tresor/tresor_bausteine.dart),
// es gibt KEIN eigenes Passwort, keine PIN und kein gespeichertes Geheimnis. Danach sperrt er sich selbst nach [kTresorAutoSperre] ohne Eingabe im Tresor und beim Wechsel der App in den
// Hintergrund (`tresorLebenszyklusProvider`); jede Sperre leert den Zustand im Speicher (entschlüsselte Einträge, Suchtext, Zwischenablage), Unterseiten des Tresors schließen sich
// (`TresorSeite`). Abmelden, Personenwechsel und Rollenverlust bauen den Zustand neu auf (= gesperrt). Es wird nie ein Schlüssel angefasst oder gelöscht.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import 'tresor_state.dart';
import 'tresor_zwischenablage.dart';

/// Wie lange der Tresor ohne Eingabe entsperrt bleibt.
const Duration kTresorAutoSperre = Duration(minutes: 2);

class TresorSperreZustand {
  /// Bis wann der Tresor entsperrt bleibt, wenn nichts mehr eingegeben wird (null = gesperrt).
  final DateTime? bis;
  const TresorSperreZustand({this.bis});

  bool get entsperrt => bis != null;
}

/// Dauer der Auto-Sperre (Tests ersetzen sie).
final tresorAutoSperreProvider = Provider<Duration>((ref) => kTresorAutoSperre);

/// Uhr der Anzeige "entsperrt bis" (Tests ersetzen sie).
final tresorJetztProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class TresorSperre extends Notifier<TresorSperreZustand> {
  Timer? _timer;
  var _systemDialoge = 0;

  /// Läuft gerade ein Dialog des Systems (Dateiauswahl, Speichern)? Auf Android schickt er die App kurz in den Hintergrund: das sperrt den Tresor dann nicht (die Frist der Auto-Sperre läuft weiter).
  bool get systemDialogOffen => _systemDialoge > 0;

  /// Führt [f] (einen Dialog des Systems) aus, ohne dass der Wechsel in den Hintergrund sperrt. Die Auto-Sperre bleibt aktiv; danach beginnt ihre Frist neu.
  Future<T> mitSystemDialog<T>(Future<T> Function() f) async {
    _systemDialoge++;
    aktivitaet();
    try {
      return await f();
    } finally {
      _systemDialoge--;
      aktivitaet();
    }
  }

  @override
  TresorSperreZustand build() {
    // Person oder Rolle ändern sich (Abmelden, Personenwechsel, Rollenverlust): der Zustand beginnt neu, also gesperrt
    ref.watch(authProvider.select((a) => a.user?.id));
    ref.watch(tresorDarfProvider);
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    return const TresorSperreZustand();
  }

  DateTime _ende() => ref.read(tresorJetztProvider)().add(ref.read(tresorAutoSperreProvider));

  void _timerNeu() {
    _timer?.cancel();
    _timer = Timer(ref.read(tresorAutoSperreProvider), sperren);
  }

  /// Entsperrt (nur nach bestandener Bestätigung aufrufen). Rolle ohne Zugriff: nie.
  void entsperren() {
    if (!ref.read(tresorDarfProvider) || ref.read(authProvider).user == null) return;
    state = TresorSperreZustand(bis: _ende());
    _timerNeu();
  }

  /// Eine Eingabe im Tresor: die Frist beginnt von vorn. Die Anzeige "bis" wird nur bei einer anderen Minute neu gesetzt (kein Neuaufbau je Fingertipp).
  void aktivitaet() {
    if (!state.entsperrt) return;
    _timerNeu();
    final neu = _ende();
    final alt = state.bis!;
    if (neu.minute != alt.minute || neu.hour != alt.hour || neu.difference(alt).abs() > const Duration(minutes: 1)) state = TresorSperreZustand(bis: neu);
  }

  /// Sperrt sofort: leert den Zustand im Speicher und die Zwischenablage (falls der Inhalt noch von hier stammt).
  void sperren() {
    _timer?.cancel();
    _timer = null;
    final war = state.entsperrt;
    state = const TresorSperreZustand();
    if (war) unawaited(ref.read(tresorZwischenablageProvider).sofortLeeren());
  }
}

final tresorSperreProvider = NotifierProvider<TresorSperre, TresorSperreZustand>(TresorSperre.new);

/// Sperrt beim Wechsel der App in den Hintergrund (am Wurzel-Widget beobachtet, damit es auch gilt, wenn der Tresor gerade nicht zu sehen ist).
final tresorLebenszyklusProvider = Provider<void>((ref) {
  final l = AppLifecycleListener(
    onStateChange: (s) {
      if (s != AppLifecycleState.hidden && s != AppLifecycleState.paused && s != AppLifecycleState.detached) return;
      final sperre = ref.read(tresorSperreProvider.notifier);
      if (!sperre.systemDialogOffen) sperre.sperren();
    },
  );
  ref.onDispose(l.dispose);
});
