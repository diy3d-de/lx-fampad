// Automatisches Verbinden nach der Anmeldung mit Passwort (P1: ein Passwort für Anmeldung und Sicherung). Der Ablauf selbst steht in
// E2eeController.automatischVerbinden; hier nur der Hinweis für die Person (ein kurzer Hinweis, kein Dialog) und der Anstoß aus der Anmeldeseite.
// Das Passwort wird hier nur durchgereicht, nie gemerkt oder geloggt. Nach der Anmeldung mit Passkey macht das [automatischMitPasskey] (die PRF-Ausgabe der Anmeldung öffnet die
// Passkey-Sicherung, siehe prf_state.dart); ohne Sicherung bleibt der Weg über Wiederherstellungsschlüssel, Passwort-Sicherung oder anderes Gerät.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'e2ee_state.dart';
import 'prf_state.dart';

/// Text für die Person; null, wenn es nichts zu sagen gibt (nichts zu tun oder keine Sicherung: die Absicherungs-Karte zeigt den nächsten Schritt).
String? autoVerbindenText(AutoVerbinden r) => switch (r) {
  AutoVerbinden.verbunden => 'Dieses Gerät ist mit deinem Schlüssel verbunden. Dein Chat-Verlauf ist hier lesbar.',
  AutoVerbinden.veraltet =>
    'Dein Passwort wurde zurückgesetzt, deshalb passt deine Passwort-Sicherung nicht mehr zum Passwort. Verbinde dieses Gerät mit deinem Wiederherstellungsschlüssel oder einem Gerät, auf dem du schon angemeldet warst.',
  AutoVerbinden.passwortPasstNicht =>
    'Dein Passwort öffnet die Passwort-Sicherung nicht (sie wurde mit einem anderen Passwort angelegt). Verbinde dieses Gerät unter Profil > Verschlüsselung.',
  AutoVerbinden.passkeyPasstNicht =>
    'Dein Passkey öffnet die Passkey-Sicherung nicht (er wurde vermutlich neu angelegt). Verbinde dieses Gerät unter Profil > Verschlüsselung mit deinem Wiederherstellungsschlüssel oder einem anderen Gerät.',
  AutoVerbinden.fehlgeschlagen => 'Dieses Gerät konnte nicht automatisch mit deinem Schlüssel verbunden werden. Du kannst es unter Profil > Verschlüsselung selbst verbinden. Es wurde nichts verändert.',
  AutoVerbinden.nichtNoetig || AutoVerbinden.keineSicherung => null,
};


/// Der Hinweis nach dem automatischen Verbinden: Text und, nach einem Verbinden, das Angebot "Gerät abgeben / Schlüssel entfernen" (Weg zurück auf einem fremden oder geliehenen Gerät).
class AutoVerbindenHinweis {
  final String text;
  final bool abgebenAnbieten;
  const AutoVerbindenHinweis(this.text, {this.abgebenAnbieten = false});
}

class AutoVerbindenHinweisController extends Notifier<AutoVerbindenHinweis?> {
  @override
  AutoVerbindenHinweis? build() => null;

  void setzen(AutoVerbindenHinweis? hinweis) => state = hinweis;
}

/// Der noch nicht angezeigte Hinweis (null: keiner); die Shell zeigt ihn kurz und leert ihn.
final autoVerbindenHinweisProvider = NotifierProvider<AutoVerbindenHinweisController, AutoVerbindenHinweis?>(AutoVerbindenHinweisController.new);

/// Nach der Anmeldung mit Passwort UND Zustimmung der Person ("Das ist mein eigenes Gerät"): Gerät ohne Schlüssel mit der Passwort-Sicherung verbinden und sagen, was geschehen ist. Wirft nie.
Future<AutoVerbinden> automatischVerbinden(E2eeController e2ee, AutoVerbindenHinweisController hinweis, String passwort) async {
  final AutoVerbinden r;
  try {
    r = await e2ee.automatischVerbinden(passwort);
  } on Object {
    hinweis.setzen(AutoVerbindenHinweis(autoVerbindenText(AutoVerbinden.fehlgeschlagen)!));
    return AutoVerbinden.fehlgeschlagen;
  }
  final text = autoVerbindenText(r);
  hinweis.setzen(text == null ? null : AutoVerbindenHinweis(text, abgebenAnbieten: r == AutoVerbinden.verbunden));
  return r;
}

/// Nach der Anmeldung mit Passkey UND Zustimmung der Person ("Das ist mein eigenes Gerät"): Gerät ohne Schlüssel mit der Passkey-Sicherung verbinden (die PRF-Ausgabe der Anmeldung
/// öffnet sie, keine zweite Geste) und sagen, was geschehen ist. Wirft nie.
Future<AutoVerbinden> automatischMitPasskey(
  PrfSteuerung prf,
  AutoVerbindenHinweisController hinweis, {
  required String credentialId,
  required Uint8List ausgabe,
}) async {
  final AutoVerbinden r = await prf.automatischVerbinden(credentialId: credentialId, prfAusgabe: ausgabe);
  final text = autoVerbindenText(r);
  hinweis.setzen(text == null ? null : AutoVerbindenHinweis(text, abgebenAnbieten: r == AutoVerbinden.verbunden));
  return r;
}
