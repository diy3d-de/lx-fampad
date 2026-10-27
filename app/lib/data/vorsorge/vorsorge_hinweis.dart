// Tipp auf eine Vorsorge-Erinnerung (Nutzlast `vorsorge`): die Shell öffnet den Bereich Vorsorge (nie ein Inhalt in der Nutzlast).
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Anforderung, den Bereich Vorsorge zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf.
class VorsorgeOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final vorsorgeOeffnenProvider = NotifierProvider<VorsorgeOeffnenAnforderung, int>(VorsorgeOeffnenAnforderung.new);
