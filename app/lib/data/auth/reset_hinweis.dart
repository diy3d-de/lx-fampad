// Hinweis nach einem Passwort-Reset: Was mit der Passwort-Sicherung des Schlüssels geschehen ist, in verständlichen Worten. Die Oberfläche (HomeShell) zeigt
// ihn einmal an; die Ereignisliste im Profil bleibt als dauerhafte Spur.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/e2ee_state.dart';
import '../push/sicherheits_pruefer.dart';

/// Text für die Person; null, wenn es nichts zu sagen gibt.
String? resetHinweisText(PwNachReset r) => switch (r) {
  PwNachReset.erneuert => 'Dein Passwort wurde zurückgesetzt. Deine Passwort-Sicherung ist mit dem neuen Passwort neu angelegt, dein Chat-Verlauf bleibt auf diesem Gerät lesbar.',
  PwNachReset.keinSchluesselAufGeraet =>
    'Dein Passwort wurde zurückgesetzt. Auf diesem Gerät fehlt dein Schlüssel, deshalb kannst du den bisherigen Chat-Verlauf hier noch nicht lesen. '
        'Mit deinem Wiederherstellungsschlüssel oder einem Gerät, auf dem du schon angemeldet warst, geht es sofort. Später kann der Verlauf auch von deinen Chat-Partnern freigegeben werden.',
  PwNachReset.fehlgeschlagen =>
    'Dein Passwort wurde zurückgesetzt. Die neue Passwort-Sicherung konnte nicht angelegt werden. Unter Profil > Verschlüsselung > Passwort-Sicherung kannst du sie mit „Sicherung erneuern“ neu anlegen. Deine Chats bleiben auf Geräten lesbar, die deinen Schlüssel haben.',
  PwNachReset.nichtNoetig => null,
};

/// Nutzlast der Sicherheitsbenachrichtigung (Tipp öffnet Profil > Sicherheitsereignisse).
const kSicherheitPayload = 'sicherheit';

/// Anforderung, die Sicherheitsereignisse zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf.
class SicherheitOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final sicherheitOeffnenProvider = NotifierProvider<SicherheitOeffnenAnforderung, int>(SicherheitOeffnenAnforderung.new);

class ResetHinweisController extends Notifier<String?> {
  @override
  String? build() => null;

  void setzen(String? text) => state = text;
}

/// Der noch nicht angezeigte Hinweis (null: keiner).
final resetHinweisProvider = NotifierProvider<ResetHinweisController, String?>(ResetHinweisController.new);

/// Nach dem Anmelden mit dem neuen Passwort: auf einem Gerät mit Schlüssel eine neue Passwort-Sicherung anlegen und der Person sagen, was geschehen ist.
/// Läuft im Hintergrund der Oberfläche; Fehler werden zum Hinweis, nie zur Ausnahme.
Future<void> sicherungNachReset(E2eeController e2ee, ResetHinweisController hinweis, String passwort, {SicherheitsPruefer? pruefer}) async {
  // der Reset, den die Person gerade selbst gemacht hat, ist für sie nichts Neues (kein Sicherheitshinweis dazu)
  await pruefer?.alsGesehenMarkieren();
  final r = await e2ee.sicherungNachResetErneuern(passwort);
  hinweis.setzen(resetHinweisText(r));
}
