// Token-Speicher (flutter_secure_storage mit Mock) und Passkey-Hilfen (Optionen normalisieren, Fehler abbilden).
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:passkeys/exceptions.dart' as pk;
import 'package:passkeys/types.dart' show AuthenticateRequestType, RegisterRequestType;

import 'support/fake_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureTokenStore', () {
    final tokens = StoredTokens(
      accessToken: 'a',
      accessExpiresAt: DateTime.utc(2026, 10, 18, 12),
      refreshToken: 'r',
      refreshExpiresAt: DateTime.utc(2027, 1, 16),
      deviceId: fixDevice,
    );

    test('speichert und liest Token, Geräte-ID und Profil', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final s = SecureTokenStore();
      expect(await s.readTokens(), isNull);
      await s.writeTokens(tokens);
      await s.writeProfile(userJson());
      final t = (await s.readTokens())!;
      expect((t.accessToken, t.refreshToken, t.deviceId), ('a', 'r', fixDevice));
      expect(t.accessExpiresAt, DateTime.utc(2026, 10, 18, 12));
      expect(await s.readDeviceId(), fixDevice);
      expect((await s.readProfile())!['displayName'], 'Anna');
    });

    test('Abmelden löscht Token und Profil, die Geräte-ID bleibt als Hinweis', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final s = SecureTokenStore();
      await s.writeTokens(tokens);
      await s.writeProfile(userJson());
      await s.clearTokens();
      expect(await s.readTokens(), isNull);
      expect(await s.readProfile(), isNull);
      expect(await s.readDeviceId(), fixDevice);
    });

    test('beschädigte Einträge werden ignoriert statt abzustürzen', () async {
      FlutterSecureStorage.setMockInitialValues({'lx_fampad_tokens': '{kaputt', 'lx_fampad_profile': 'nope'});
      final s = SecureTokenStore();
      expect(await s.readTokens(), isNull);
      expect(await s.readProfile(), isNull);
      FlutterSecureStorage.setMockInitialValues({'lx_fampad_tokens': '{"a":1}'});
      expect(await SecureTokenStore().readTokens(), isNull);
    });
  });

  group('SecureTokenStore bei Keystore-Fehlern', () {
    test('PlatformException beim Lesen (z. B. BadPaddingException): Eintrag gelöscht, null, kein Absturz', () async {
      final kaputt = _KaputterKeystore();
      final s = SecureTokenStore(kaputt);
      expect(await s.readTokens(), isNull);
      expect(await s.readProfile(), isNull);
      expect(kaputt.geloescht, containsAll(['lx_fampad_tokens', 'lx_fampad_profile']));
      expect(await s.readDeviceId(), isNull);
    });

    test('auch wenn das Löschen scheitert, kommt null zurück', () async {
      final s = SecureTokenStore(_KaputterKeystore(loeschenScheitert: true));
      expect(await s.readTokens(), isNull);
    });

    test('Abmelden versucht beide Einträge zu löschen, auch wenn der erste Fehler wirft', () async {
      final kaputt = _KaputterKeystore(loeschenScheitert: true);
      await expectLater(SecureTokenStore(kaputt).clearTokens(), throwsA(isA<PlatformException>()));
      expect(kaputt.versuche, ['lx_fampad_tokens', 'lx_fampad_profile']);
    });
  });

  group('Passkey-Optionen', () {
    test('Server-Optionen (SimpleWebAuthn) werden vom Paket verstanden, auch ohne transports', () {
      final req = RegisterRequestType.fromJson(normalisiereOptionen(webauthnOptionen()));
      expect(req.relyingParty.id, 'familyhub.lx-labs.dev');
      expect(req.user.name, 'anna@beispiel.de');
      expect(req.excludeCredentials.single.id, 'Y3JlZA');
      expect(req.excludeCredentials.single.transports, isEmpty);
      expect(req.authSelectionType!.userVerification, 'required');
      expect(req.attestation, 'none');
    });

    test('Anmeldeoptionen ohne allowCredentials (auffindbare Passkeys)', () {
      final req = AuthenticateRequestType.fromJson(
        normalisiereOptionen({'challenge': 'YWJj', 'rpId': 'familyhub.lx-labs.dev', 'userVerification': 'required', 'timeout': 60000}),
      );
      expect(req.relyingPartyId, 'familyhub.lx-labs.dev');
      expect(req.allowCredentials, isNull);
      expect(req.userVerification, 'required');
    });

    test('Anmeldeoptionen mit allowCredentials (Step-up: nur eigene Passkeys)', () {
      final req = AuthenticateRequestType.fromJson(
        normalisiereOptionen({
          'challenge': 'YWJj',
          'rpId': 'familyhub.lx-labs.dev',
          'allowCredentials': [
            {'id': 'Y3JlZA', 'type': 'public-key', 'transports': ['internal', 'hybrid']},
          ],
        }),
      );
      expect(req.allowCredentials!.single.transports, ['internal', 'hybrid']);
    });

    test('die Eingabe wird nicht verändert', () {
      final o = webauthnOptionen();
      normalisiereOptionen(o);
      expect((o['excludeCredentials'] as List).single, {'id': 'Y3JlZA', 'type': 'public-key'});
    });
  });

  group('Passkey-Fehler', () {
    test('Abbruch: abgebrochen, ohne Fehlerton', () {
      final e = passkeyFehlerAbbilden(pk.PasskeyAuthCancelledException());
      expect(e.abgebrochen, isTrue);
      expect(e.message, contains('Abgebrochen'));
    });

    test('Google Play-Dienste oder Google-Konto fehlen: Weg zu Passwort und Code', () {
      for (final x in <Object>[pk.MissingGoogleSignInException(), pk.SyncAccountNotAvailableException()]) {
        final e = passkeyFehlerAbbilden(x);
        expect(e.art, PasskeyFehler.googleDienste);
        expect(e.message, contains('Google Play-Dienste'));
        expect(e.message, contains('Passwort mit Code'));
      }
    });

    test('kein Passkey-Support', () {
      final e = passkeyFehlerAbbilden(pk.DeviceNotSupportedException());
      expect(e.art, PasskeyFehler.nichtUnterstuetzt);
      expect(e.message, contains('Passwort mit Code'));
    });

    test('kein Passkey auf dem Gerät, schon vorhanden, Domain nicht verknüpft', () {
      expect(passkeyFehlerAbbilden(pk.NoCredentialsAvailableException()).art, PasskeyFehler.keinPasskey);
      expect(passkeyFehlerAbbilden(pk.ExcludeCredentialsCanNotBeRegisteredException()).art, PasskeyFehler.schonVorhanden);
      final d = passkeyFehlerAbbilden(pk.DomainNotAssociatedException('x'));
      expect(d.art, PasskeyFehler.domain);
      expect(d.message, contains('Digital Asset Links'));
    });

    test('Unbekanntes: allgemeine Meldung ohne Interna', () {
      final e = passkeyFehlerAbbilden(StateError('java.lang.NullPointerException at Foo'));
      expect(e.art, PasskeyFehler.sonstiges);
      expect(e.message, isNot(contains('NullPointer')));
      expect(e.message, contains('Passwort mit Code'));
    });
  });
}

/// FlutterSecureStorage, dessen Lesen mit einer PlatformException scheitert (Keystore-Schlüssel nicht mehr nutzbar).
class _KaputterKeystore extends Fake implements FlutterSecureStorage {
  final bool loeschenScheitert;
  final geloescht = <String>[];
  final versuche = <String>[];
  _KaputterKeystore({this.loeschenScheitert = false});

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    if (invocation.memberName == #read) return Future<String?>.error(PlatformException(code: 'Exception encountered', message: 'BadPaddingException'));
    if (invocation.memberName == #delete) {
      versuche.add(key ?? '');
      if (loeschenScheitert) return Future<void>.error(PlatformException(code: 'delete'));
      geloescht.add(key ?? '');
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
