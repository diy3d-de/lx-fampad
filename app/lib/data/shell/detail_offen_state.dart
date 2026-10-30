// Ist im Zweispalter (Aufgaben) rechts gerade ein Detail offen? Die Desktop-Shell braucht das für "Zurück" (Android, Browser): erst das Detail schließen, dann den Bereich
// verlassen. Nur Arbeitsspeicher, nichts wird gespeichert.
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DetailOffenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setzen(bool offen) {
    if (state != offen) state = offen;
  }
}

final detailOffenProvider = NotifierProvider<DetailOffenNotifier, bool>(DetailOffenNotifier.new);
