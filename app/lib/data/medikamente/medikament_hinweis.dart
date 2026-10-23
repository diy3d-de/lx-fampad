// Tipp auf eine Medikamenten-Erinnerung (Nutzlast `medikament|<ID>`): die Shell öffnet die Medikamenten-Ansicht (nie ein Inhalt in der Nutzlast).
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Anforderung, die Medikamenten-Ansicht zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf.
class MedikamentOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final medikamentOeffnenProvider = NotifierProvider<MedikamentOeffnenAnforderung, int>(MedikamentOeffnenAnforderung.new);
