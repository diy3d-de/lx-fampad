// Tresor (Abschnitt 6m), Zwischenablage: Kopieren nur auf Klick; nach 30 Sekunden (und beim Sperren) wird die Zwischenablage geleert, ABER nur wenn noch genau der kopierte Text darin steht
// (nie etwas überschreiben, das die Person inzwischen selbst kopiert hat). Lässt sich die Zwischenablage nicht lesen (Browser ohne Erlaubnis, Android im Hintergrund), bleibt sie unberührt.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart' show systemChannelProvider;

/// Nach so langer Zeit wird eine kopierte Angabe aus der Zwischenablage entfernt.
const Duration kTresorZwischenablageFrist = Duration(seconds: 30);

class TresorZwischenablage {
  final Future<void> Function(String text, bool geheim) setzen;
  final Future<String?> Function() lesen;
  final Future<void> Function() leeren;
  final Duration frist;
  Timer? _timer;
  String? _inhalt;

  TresorZwischenablage({required this.setzen, required this.lesen, required this.leeren, this.frist = kTresorZwischenablageFrist});

  /// Kopiert [text] (auf ausdrücklichen Klick) und plant das Leeren.
  Future<void> kopieren(String text, {bool geheim = false}) async {
    await setzen(text, geheim);
    _inhalt = text;
    _timer?.cancel();
    _timer = Timer(frist, () => unawaited(sofortLeeren()));
  }

  /// Leert die Zwischenablage jetzt, wenn noch der zuletzt kopierte Text darin steht.
  Future<void> sofortLeeren() async {
    final t = _inhalt;
    _inhalt = null;
    _timer?.cancel();
    _timer = null;
    if (t == null) return;
    try {
      if (await lesen() == t) await leeren();
    } on Object {
      // nicht lesbar: nichts anfassen
    }
  }

  void verwerfen() {
    _timer?.cancel();
    _timer = null;
    _inhalt = null;
  }
}

final tresorZwischenablageProvider = Provider<TresorZwischenablage>((ref) {
  final kanal = ref.read(systemChannelProvider);
  final z = TresorZwischenablage(
    setzen: (text, geheim) async {
      // Android markiert den Text als vertraulich (keine Vorschau, kein Verlauf); sonst die normale Zwischenablage
      if (geheim && await kanal.geheimKopieren(text)) return;
      await Clipboard.setData(ClipboardData(text: text));
    },
    lesen: () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
    leeren: () => Clipboard.setData(const ClipboardData(text: '')),
  );
  ref.onDispose(z.verwerfen);
  return z;
});
