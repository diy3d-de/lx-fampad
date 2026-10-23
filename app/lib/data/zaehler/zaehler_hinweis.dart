// Tipp auf eine Zähler-Erinnerung (Nutzlast `zaehler`, ohne jeden Inhalt): die Shell öffnet die Zähler-Übersicht, aber nur für Eltern und Admins.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Anforderung, die Zähler-Übersicht zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf und prüft die Rolle.
class ZaehlerOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final zaehlerOeffnenProvider = NotifierProvider<ZaehlerOeffnenAnforderung, int>(ZaehlerOeffnenAnforderung.new);
