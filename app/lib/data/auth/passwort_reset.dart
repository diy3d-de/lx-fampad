// Passwort zurücksetzen (PR 4b der vereinfachten Schlüsselverwaltung; Projektbeschreibung 9a). Drei Wege, alle nur mit abgeleitetem authKey (das neue Passwort
// verlässt das Gerät nie):
//   1. Link des Admins einlösen: PIN (falls verlangt), neues Passwort und ein Code des vorhandenen Authenticators (der zweite Faktor bleibt Pflicht);
//   2. "Passwort vergessen?" mit einem der Notfall-Codes;
//   3. "Passwort vergessen?" mit einem Passkey.
// Nie mit dem Authenticator allein. Der Server berührt dabei keinen Schlüssel: Die Passwort-Sicherung des Personenschlüssels wird dort nur als veraltet
// markiert (nie gelöscht); der alte Weg (Wiederherstellungsschlüssel, QR) gilt unverändert. Auf einem Gerät mit Schlüssel legt die App danach selbst eine
// neue Sicherung an (E2eeController.sicherungNachResetErneuern).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/fampad_api.dart';
import '../api/models.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/pw_regeln.dart';
import '../passkey_service.dart';
import 'auth_state.dart';
import 'passwort_anmeldung.dart';

/// Wirft eine Meldung statt Klartext zu senden: Das Zurücksetzen gibt es nur mit authKey.
const _fehlerKeinAuthKey = CryptoFehler(
  CryptoFehlerArt.version,
  'Der Server bietet das Zurücksetzen des Passworts gerade nicht an. Bitte versuche es später noch einmal oder aktualisiere die App.',
);

class PasswortReset {
  final FampadApi api;
  final PasswortAnmeldung anmeldung;
  final PasskeyService passkeys;
  const PasswortReset({required this.api, required this.anmeldung, required this.passkeys});

  /// Leitet den authKey des neuen Passworts ab. Die Regeln für Stärke und Kontodaten gelten auf dem Gerät (der Server sieht das Passwort nie).
  Future<String> _authKey(String email, String passwort, {String? anzeigename}) async {
    final neu = await anmeldung.neuesPasswort(
      email,
      passwort,
      pruefenMitAuthKey: () {
        final probleme = passwortPruefen(passwort, email: email, anzeigename: anzeigename);
        if (probleme.isNotEmpty) throw CryptoFehler(CryptoFehlerArt.format, probleme.first.meldung);
      },
    );
    return neu.authKey ?? (throw _fehlerKeinAuthKey);
  }

  /// Link des Admins: neues Passwort und Code des Authenticators. Gibt das Ergebnis wie eine Registrierung zurück (Sitzung inbegriffen, keine neuen Notfall-Codes).
  Future<RegistrationResult> einladungEinloesen({
    required String token,
    String? pin,
    required String email,
    String? anzeigename,
    required String passwort,
    required String code,
  }) async {
    final authKey = await _authKey(email, passwort, anzeigename: anzeigename);
    final challenge = await api.passwortResetStart(token: token, pin: pin, authKey: authKey);
    final r = await api.passwortResetFertig(challengeId: challenge, code: code);
    await anmeldung.merkeKonto(email);
    return r;
  }

  /// "Passwort vergessen?" mit einem Notfall-Code (der Code wird dabei verbraucht).
  Future<LoginResult> vergessenMitCode({required String email, required String code, required String passwort}) async {
    final authKey = await _authKey(email, passwort);
    final r = await api.passwortVergessenMitCode(email: email, code: code, authKey: authKey);
    await anmeldung.merkeKonto(email);
    return r;
  }

  /// "Passwort vergessen?" mit einem Passkey.
  Future<LoginResult> vergessenMitPasskey({required String email, required String passwort}) async {
    final authKey = await _authKey(email, passwort);
    final ch = await api.passkeyAnmeldeOptionen();
    final antwort = await passkeys.bestaetigen(ch.options);
    final r = await api.passwortVergessenMitPasskey(challengeId: ch.challengeId, antwort: antwort, authKey: authKey, email: email);
    await anmeldung.merkeKonto(email);
    return r;
  }
}


final passwortResetProvider = Provider<PasswortReset>(
  (ref) => PasswortReset(api: ref.watch(apiProvider), anmeldung: ref.watch(passwortAnmeldungProvider), passkeys: ref.watch(passkeyServiceProvider)),
);
