// Passkeys (WebAuthn) über das Paket `passkeys` (Corbado): Android per Credential Manager, Web per Browser-API
// (web/passkeys-bundle.js, selbst gehostet). Die Server-Optionen (SimpleWebAuthn-JSON) gehen unverändert hinein, die Antwort
// kommt als WebAuthn-JSON heraus. Alle Fehler werden zu [PasskeyException] mit klarer Meldung und Weg zu Passwort + TOTP.
import 'dart:convert';

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

/// Antwort einer Passkey-Bestätigung samt dem Ergebnis der PRF-Erweiterung (Passkey-Sicherung, Projektbeschreibung 9a).
class PasskeyMitPrf {
  /// AuthenticationResponseJSON für den Server (ohne die PRF-Ausgabe: sie verlässt das Gerät nie).
  final Map<String, dynamic> antwort;

  /// Kennung des benutzten Passkeys (Base64url, wie der Server sie führt).
  final String credentialId;

  /// Die 32 Byte der PRF-Ausgabe oder null, wenn der Passkey-Speicher PRF nicht unterstützt (oder nichts Brauchbares lieferte). Nie loggen, nie senden.
  final Uint8List? prf;
  const PasskeyMitPrf({required this.antwort, required this.credentialId, required this.prf});
}

abstract class PasskeyService {
  /// Gibt es auf diesem Gerät/Browser überhaupt Passkey-Unterstützung?
  Future<bool> verfuegbar();

  /// Passkey anlegen. [optionen] sind die Registrierungsoptionen des Servers; Rückgabe: RegistrationResponseJSON.
  Future<Map<String, dynamic>> erstellen(Map<String, dynamic> optionen);

  /// Mit Passkey bestätigen. [optionen] sind die Anmeldeoptionen des Servers; Rückgabe: AuthenticationResponseJSON.
  Future<Map<String, dynamic>> bestaetigen(Map<String, dynamic> optionen);

  /// Wie [bestaetigen], zusätzlich mit der PRF-Erweiterung (fester [salt], 32 Byte): die Ausgabe liegt im Ergebnis ([PasskeyMitPrf.prf]; null, wenn nicht
  /// unterstützt). Mit [nurCredentialId] bietet das Gerät nur diesen Passkey an (für die zweite Probe derselben Sicherung).
  Future<PasskeyMitPrf> bestaetigenMitPrf(Map<String, dynamic> optionen, {required Uint8List salt, String? nurCredentialId});
}

/// Liest die PRF-Ausgabe aus den Ergebnissen der Client-Erweiterungen (`prf.results.first`, Base64url). null bei jeder Abweichung (nie ein Fehler).
Uint8List? prfAusgabeAus(Map<Object?, Object?>? ergebnisse) {
  try {
    final prf = ergebnisse?['prf'];
    if (prf is! Map) return null;
    final results = prf['results'];
    if (results is! Map) return null;
    final first = results['first'];
    if (first is! String || first.isEmpty) return null;
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(first)));
  } on Object {
    return null;
  }
}

/// Kennung eines Passkeys in der Form des Servers: Base64url ohne Füllzeichen (manche Plattformen liefern sie mit `=`).
String passkeyKennung(String id) => id.replaceAll('=', '');

/// Die Antwort für den Server ohne die PRF-Ausgabe: sie verlässt das Gerät nie, auch dann nicht, wenn das Paket die Erweiterungs-Ergebnisse (je nach Version oder
/// Plattform) in `toJson()` mitgibt. Eine Antwort ohne Ergebnisse bleibt unverändert; sonst bleibt `clientExtensionResults` (ohne `prf`) stehen.
Map<String, dynamic> antwortOhnePrf(Map<String, dynamic> antwort) {
  final e = antwort['clientExtensionResults'];
  if (e is! Map || !e.containsKey('prf')) return antwort;
  return {
    ...antwort,
    'clientExtensionResults': {for (final k in e.entries) if (k.key != 'prf') k.key: k.value},
  };
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
  Future<PasskeyMitPrf> bestaetigenMitPrf(Map<String, dynamic> optionen, {required Uint8List salt, String? nurCredentialId}) async {
    try {
      final norm = normalisiereOptionen(optionen);
      if (nurCredentialId != null && norm['allowCredentials'] is List) {
        norm['allowCredentials'] = [for (final c in norm['allowCredentials'] as List) if (c is Map && passkeyKennung('${c['id']}') == passkeyKennung(nurCredentialId)) c];
      }
      norm['extensions'] = {
        ...(norm['extensions'] is Map<String, dynamic> ? norm['extensions'] as Map<String, dynamic> : const <String, dynamic>{}),
        'prf': {
          'eval': {'first': base64Url.encode(salt).replaceAll('=', '')},
        },
      };
      final req = AuthenticateRequestType.fromJson(norm, mediation: MediationType.Optional, preferImmediatelyAvailableCredentials: false);
      final res = await _a.authenticate(req);
      // das Paket verwirft die Erweiterungs-Ergebnisse in toJson(): die PRF-Ausgabe steht nur im Objekt
      return PasskeyMitPrf(antwort: antwortOhnePrf(res.toJson()), credentialId: passkeyKennung(res.id), prf: prfAusgabeAus(res.clientExtensionResults));
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
