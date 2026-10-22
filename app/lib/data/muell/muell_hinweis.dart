// Tipp auf eine Müll-Benachrichtigung (Erinnerung am Abend vor der Abholung oder "Abfuhrtermine 20XX sind da"): die Shell öffnet die Müll-Seite.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Anforderung, die Müll-Seite zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf.
class MuellOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final muellOeffnenProvider = NotifierProvider<MuellOeffnenAnforderung, int>(MuellOeffnenAnforderung.new);
