// Passkeys (WebAuthn) über das Paket `passkeys` (Corbado): Android per Credential Manager, Web per Browser-API
// (web/passkeys-bundle.js, selbst gehostet). Die Server-Optionen (SimpleWebAuthn-JSON) gehen unverändert hinein, die Antwort
// kommt als WebAuthn-JSON heraus. Alle Fehler werden zu [PasskeyException] mit klarer Meldung und Weg zu Passwort + TOTP.
import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/exceptions.dart' as pk;
import 'package:passkeys/types.dart';

enum PasskeyFehler {
  abgebrochen,
  nichtUnterstuetzt,
  googleDienste,
  keinPasskey,
  schonVorhanden,
  domain,
  zeit,
  sonstiges,
}

class PasskeyException implements Exception {
  final PasskeyFehler art;
  final String message;
  const PasskeyException(this.art, this.message);

  /// Nutzer hat selbst abgebrochen: keine Fehlermeldung nötig, nur ein Hinweis.
  bool get abgebrochen => art == PasskeyFehler.abgebrochen;

  @override
  String toString() => 'PasskeyException($art)';
}

abstract class PasskeyService {
  /// Gibt es auf diesem Gerät/Browser überhaupt Passkey-Unterstützung?
  Future<bool> verfuegbar();

  /// Passkey anlegen. [optionen] sind die Registrierungsoptionen des Servers; Rückgabe: RegistrationResponseJSON.
  Future<Map<String, dynamic>> erstellen(Map<String, dynamic> optionen);

  /// Mit Passkey bestätigen. [optionen] sind die Anmeldeoptionen des Servers; Rückgabe: AuthenticationResponseJSON.
  Future<Map<String, dynamic>> bestaetigen(Map<String, dynamic> optionen);
}

/// Das Paket verlangt bei Anmeldedaten ein `transports`-Feld; der Server lässt es bei manchen Einträgen weg.
Map<String, dynamic> normalisiereOptionen(Map<String, dynamic> optionen) {
  List<dynamic>? fix(Object? liste) {
    if (liste is! List) return null;
    return [
      for (final e in liste)
        if (e is Map<String, dynamic>)
          {
            ...e,
            'type': e['type'] ?? 'public-key',
            'transports': e['transports'] is List ? [for (final t in e['transports'] as List) '$t'] : <String>[],
          },
    ];
  }

  final kopie = Map<String, dynamic>.of(optionen);
  final ex = fix(optionen['excludeCredentials']);
  if (ex != null) kopie['excludeCredentials'] = ex;
  final al = fix(optionen['allowCredentials']);
  if (al != null) kopie['allowCredentials'] = al;
  return kopie;
}

const _hinweisPasswort = 'Du kannst stattdessen Passwort mit Code nutzen.';

/// Übersetzt Fehler des Pakets in verständliche Meldungen.
PasskeyException passkeyFehlerAbbilden(Object e) {
  if (e is PasskeyException) return e;
  if (e is pk.PasskeyAuthCancelledException) {
    return const PasskeyException(PasskeyFehler.abgebrochen, 'Abgebrochen. Du kannst es erneut versuchen.');
  }
  if (e is pk.MissingGoogleSignInException || e is pk.SyncAccountNotAvailableException) {
    return const PasskeyException(
      PasskeyFehler.googleDienste,
      'Auf diesem Gerät fehlen Google Play-Dienste oder ein Google-Konto für Passkeys. $_hinweisPasswort',
    );
  }
  if (e is pk.DeviceNotSupportedException || e is pk.PasskeyUnsupportedException) {
    return const PasskeyException(PasskeyFehler.nichtUnterstuetzt, 'Dieses Gerät oder dieser Browser unterstützt keine Passkeys. $_hinweisPasswort');
  }
  if (e is pk.NoCreateOptionException) {
    return const PasskeyException(
      PasskeyFehler.googleDienste,
      'Auf diesem Gerät ist kein Speicher für Passkeys eingerichtet (z. B. der Google Passwortmanager). $_hinweisPasswort',
    );
  }
  if (e is pk.NoCredentialsAvailableException) {
    return const PasskeyException(
      PasskeyFehler.keinPasskey,
      'Auf diesem Gerät wurde kein passender Passkey gefunden. Melde dich mit Passwort und Code an oder nutze ein anderes Gerät.',
    );
  }
  if (e is pk.ExcludeCredentialsCanNotBeRegisteredException) {
    return const PasskeyException(PasskeyFehler.schonVorhanden, 'Für dieses Gerät gibt es schon einen Passkey.');
  }
  if (e is pk.DomainNotAssociatedException) {
    return const PasskeyException(
      PasskeyFehler.domain,
      'Die App ist für Passkeys noch nicht mit der Domain verknüpft (Digital Asset Links). Bitte den Betreiber informieren. $_hinweisPasswort',
    );
  }
  if (e is pk.TimeoutException) {
    return const PasskeyException(PasskeyFehler.zeit, 'Das hat zu lange gedauert. Bitte versuche es noch einmal.');
  }
  return const PasskeyException(PasskeyFehler.sonstiges, 'Der Passkey konnte nicht verwendet werden. $_hinweisPasswort');
}

class CorbadoPasskeyService implements PasskeyService {
  PasskeyAuthenticator? _auth;
  PasskeyAuthenticator get _a => _auth ??= PasskeyAuthenticator();

  @override
  Future<bool> verfuegbar() async {
    try {
      final av = _a.getAvailability();
      final a = kIsWeb ? await av.web() : await av.android();
      return a.hasPasskeySupport;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> erstellen(Map<String, dynamic> optionen) async {
    try {
      final req = RegisterRequestType.fromJson(normalisiereOptionen(optionen));
      final res = await _a.register(req);
      return res.toJson();
    } on pk.AuthenticatorException catch (e) {
      throw passkeyFehlerAbbilden(e);
    } on FormatException {
      throw const PasskeyException(PasskeyFehler.sonstiges, 'Der Server hat unerwartete Passkey-Angaben gesendet.');
    } on TypeError {
      throw const PasskeyException(PasskeyFehler.sonstiges, 'Der Server hat unerwartete Passkey-Angaben gesendet.');
    } catch (e) {
      throw passkeyFehlerAbbilden(e);
    }
  }

  @override
  Future<Map<String, dynamic>> bestaetigen(Map<String, dynamic> optionen) async {
    try {
      final req = AuthenticateRequestType.fromJson(
        normalisiereOptionen(optionen),
        mediation: MediationType.Optional,
        preferImmediatelyAvailableCredentials: false,
      );
      final res = await _a.authenticate(req);
      return res.toJson();
    } on pk.AuthenticatorException catch (e) {
      throw passkeyFehlerAbbilden(e);
    } on FormatException {
      throw const PasskeyException(PasskeyFehler.sonstiges, 'Der Server hat unerwartete Passkey-Angaben gesendet.');
    } on TypeError {
      throw const PasskeyException(PasskeyFehler.sonstiges, 'Der Server hat unerwartete Passkey-Angaben gesendet.');
    } catch (e) {
      throw passkeyFehlerAbbilden(e);
    }
  }
}
