// Home-Assistant-Anbindung der Zähler: Zwischenablage für den Kopplungscode. Der Code enthält Zugang und Prüfgeheimnis, darum wird die Zwischenablage nach 60 Sekunden geleert, aber NUR,
// wenn noch genau dieser Text darin steht (nie etwas überschreiben, das die Person inzwischen selbst kopiert hat). Gleiche Mechanik wie im Tresor ([TresorZwischenablage]), eigene Frist.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart' show systemChannelProvider;
import '../tresor/tresor_zwischenablage.dart';

/// Nach so langer Zeit wird der kopierte Kopplungscode aus der Zwischenablage entfernt.
const Duration kIngestZwischenablageFrist = Duration(seconds: 60);

final ingestZwischenablageProvider = Provider<TresorZwischenablage>((ref) {
  final kanal = ref.read(systemChannelProvider);
  final z = TresorZwischenablage(
    setzen: (text, geheim) async {
      // Android markiert den Text als vertraulich (keine Vorschau, kein Verlauf); sonst die normale Zwischenablage
      if (geheim && await kanal.geheimKopieren(text)) return;
      await Clipboard.setData(ClipboardData(text: text));
    },
    lesen: () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
    leeren: () => Clipboard.setData(const ClipboardData(text: '')),
    frist: kIngestZwischenablageFrist,
  );
  ref.onDispose(z.verwerfen);
  return z;
});
