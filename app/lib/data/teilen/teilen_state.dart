// Zustand "Text zum Teilen" (nur Arbeitsspeicher): der von einer anderen App geteilte Text wartet hier, bis die angemeldete Person gewählt hat, wohin er soll. Nicht angemeldet:
// er bleibt liegen und wird nach der Anmeldung angeboten. Abmelden, Personenwechsel und Abbrechen verwerfen ihn (nie auf der Platte, nie im Log, nie am Server vorbei in den Chat).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'teilen_logik.dart';

class TeilenText extends Notifier<String?> {
  @override
  String? build() => null;

  /// Ein neuer Text von außen (roh; wird gekürzt und bereinigt). Unbrauchbares ersetzt einen schon wartenden Text nicht.
  void eingegangen(String? roh) {
    final t = teilenKuerzen(roh);
    if (t != null) state = t;
  }

  void verwerfen() => state = null;
}

final teilenProvider = NotifierProvider<TeilenText, String?>(TeilenText.new);
