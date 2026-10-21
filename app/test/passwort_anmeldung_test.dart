// Anmeldung ohne Klartext-Passwort (PR 4): Wahl des Weges nach den Fähigkeiten des Servers, Umstellung legacy -> authKey beim Login, Schutz vor Herabstufung,
// Fehlerfälle, neues Passwort (authKey oder Klartext). Alles gegen den Fake-Server und den Fake-Krypto-Provider, ohne Netz.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/passwort_anmeldung.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/crypto/nfkc.dart';
import 'package:lx_fampad/data/crypto/pw_sicherung.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';

const _email = 'anna@beispiel.de';
const _pw = 'Zebra-Kamin-Orbit-Fluss-Lampe';

class _Aufbau {
  final FakeServer server;
  final MemoryTokenStore store;
  final FampadApi api;
  final CryptoProvider crypto;
  _Aufbau(this.server, this.store, this.api, this.crypto);

  PasswortAnmeldung get anmeldung => PasswortAnmeldung(api: api, store: store, krypto: () async => crypto);

  List<Map<String, dynamic>> get logins => [for (final r in server.anfragen('POST /auth/login/password')) r.json];
}

/// Fake-Server mit Fähigkeiten und Login: [konto] bestimmt, was der Server als gültig ansieht ('authkey', 'legacy' oder 'keins').
_Aufbau _aufbau({bool authKey = true, bool legacy = true, String konto = 'legacy', CryptoProvider? crypto}) {
  final c = crypto ?? FakeCryptoProvider(seed: 1);
  final server = FakeServer();
  if (authKey || !legacy) {
    server.json('GET /version', {
      'features': {'pwBackup': authKey, 'authKey': authKey, 'legacyPasswordLogin': legacy},
    });
  }
  server.on('POST /auth/login/password', (r) async {
    final j = r.json;
    if (j.containsKey('password') && !legacy) return fehler(403, 'legacy_login_disabled');
    if (konto == 'legacy' && j['password'] == _pw) return jsonAntwort({'user': userJson(), 'session': appSession()});
    if (konto == 'authkey' && j['authKey'] == await _erwarteterAuthKey(c)) return jsonAntwort({'user': userJson(), 'session': appSession()});
    return fehler(401, 'invalid_credentials');
  });
  server.on('POST /auth/kdf-params', (r) => jsonAntwort({'kdf': _kdfAntwort(r.json['email'] as String)}));
  final store = MemoryTokenStore();
  final client = ApiClient(client: server.client, store: store, web: false, base: 'https://familie.test', now: DateTime.now);
  final api = FampadApi(client, geraet: () async => null);
  return _Aufbau(server, store, api, c);
}

Map<String, dynamic> _kdfAntwort(String email) => {'id': 'argon2id-v1', 'memKiB': 65536, 'ops': 3, 'salt': base64urlKodieren(FakeE2eeServer.saltFuer(email))};

Future<PwSchluessel> _schluessel(CryptoProvider crypto, String email) async =>
    PwSchluessel.ausMaster(crypto, await crypto.pwhash(passwort: passwortBytes(_pw), salt: FakeE2eeServer.saltFuer(email), memKiB: 65536, ops: 3));

/// Der authKey, den ein Server mit gespeichertem Prüfwert für dieses Passwort erwartet (unabhängig von PasswortAnmeldung nachgerechnet).
Future<String> _erwarteterAuthKey(CryptoProvider crypto) async => base64urlKodieren((await _schluessel(crypto, _email)).authKey);

AnmeldeSender _sender(_Aufbau a, {String? code}) => ({passwort, authKey, upgradeAuthKey}) async {
  await a.api.passwortAnmelden(email: _email, passwort: passwort, authKey: authKey, upgradeAuthKey: upgradeAuthKey, totp: code ?? '123456');
};

void main() {
  group('Weg nach den Fähigkeiten des Servers', () {
    test('älterer Server ohne Angabe: Klartext wie bisher, kein kdf-params-Aufruf', () async {
      final a = _aufbau(authKey: false);
      await a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      expect(a.logins.single['password'], _pw);
      expect(a.logins.single.containsKey('authKey'), isFalse);
      expect(a.server.anfragen('POST /auth/kdf-params'), isEmpty);
    });

    test('Schalter aus (features.authKey false): Klartext, ohne Ableitung', () async {
      final a = _aufbau(authKey: false, legacy: true);
      a.server.json('GET /version', {
        'features': {'pwBackup': false, 'authKey': false, 'legacyPasswordLogin': true},
      });
      await a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      expect(a.logins.single['password'], _pw);
      expect(a.server.anfragen('POST /auth/kdf-params'), isEmpty);
    });

    test('Konto im authKey-Zustand: nur authKey wird gesendet, nie das Passwort; das Konto wird auf dem Gerät gemerkt', () async {
      final a = _aufbau(konto: 'authkey');
      await a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      expect(a.logins, hasLength(1));
      final j = a.logins.single;
      expect(j.containsKey('password'), isFalse);
      expect(j.containsKey('upgradeAuthKey'), isFalse);
      expect(j['authKey'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(jsonEncode(a.server.log.map((r) => r.body).toList()), isNot(contains(_pw)), reason: 'das Passwort steht in keiner Anfrage');
      expect(await a.store.istAuthKeyKonto(_email), isTrue);
      expect(await a.store.istAuthKeyKonto('ANNA@beispiel.de'), isTrue, reason: 'Schreibweise der E-Mail egal');
    });

    test('authKey ist nicht der kek und hängt von E-Mail (Salt) und Passwort ab', () async {
      final crypto = FakeCryptoProvider(seed: 1);
      final a = _aufbau(konto: 'authkey', crypto: crypto);
      await a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      final authKey = a.logins.single['authKey'] as String;
      final keys = await _schluessel(crypto, _email);
      expect(authKey, base64urlKodieren(keys.authKey));
      expect(authKey, isNot(base64urlKodieren(keys.kek)));
      final b = _aufbau(konto: 'authkey', crypto: crypto);
      await expectLater(
        b.anmeldung.anmelden(email: 'bruno@beispiel.de', passwort: _pw, senden: ({passwort, authKey, upgradeAuthKey}) => b.api.passwortAnmelden(email: 'bruno@beispiel.de', authKey: authKey, totp: '123456')),
        throwsA(isA<ApiException>()),
      );
      expect(b.logins.first['authKey'], isNot(authKey), reason: 'anderer Salt, anderer authKey');
    });
  });

  group('Umstellung legacy -> authKey', () {
    test('Konto noch im Altzustand: authKey wird wie ein falsches Passwort abgelehnt, danach Klartext mit upgradeAuthKey', () async {
      final a = _aufbau(konto: 'legacy');
      await a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      expect(a.logins, hasLength(2));
      expect(a.logins[0].containsKey('password'), isFalse, reason: 'der erste Versuch sendet nur den authKey');
      final zweiter = a.logins[1];
      expect(zweiter['password'], _pw);
      expect(zweiter['upgradeAuthKey'], a.logins[0]['authKey']);
      expect(zweiter.containsKey('authKey'), isFalse);
      expect(await a.store.istAuthKeyKonto(_email), isFalse, reason: 'gemerkt wird erst nach der ersten Anmeldung per authKey');
    });

    test('falsches Passwort: beide Versuche scheitern, der Fehler ist derselbe wie sonst', () async {
      final a = _aufbau(konto: 'legacy');
      await expectLater(
        a.anmeldung.anmelden(email: _email, passwort: 'falsch-falsch-falsch', senden: _sender(a)),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')),
      );
      expect(a.logins, hasLength(2));
    });

    test('bekanntes Konto auf diesem Gerät: keine Herabstufung, genau ein Versuch', () async {
      final a = _aufbau(konto: 'legacy');
      await a.store.merkeAuthKeyKonto(_email);
      await expectLater(
        a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a)),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')),
      );
      expect(a.logins, hasLength(1));
      expect(a.logins.single.containsKey('password'), isFalse);
      expect(jsonEncode(a.server.log.map((r) => r.body).toList()), isNot(contains(_pw)));
    });

    test('Stichtag (legacyPasswordLogin false): keine Wiederholung mit Klartext, auch auf einem unbekannten Gerät', () async {
      final a = _aufbau(legacy: false, konto: 'legacy');
      await expectLater(
        a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a)),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')),
      );
      expect(a.logins, hasLength(1));
      expect(a.logins.single.containsKey('password'), isFalse);
    });

    test('Sperre (429) und andere Fehler gehen unverändert nach oben, ohne Klartext-Wiederholung', () async {
      final a = _aufbau(konto: 'legacy');
      a.server.on('POST /auth/login/password', (_) => fehler(429, 'too_many_attempts', retryAfter: 30));
      await expectLater(
        a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a)),
        throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.zuVieleAnfragen)),
      );
      expect(a.logins, hasLength(1));
      a.server.log.clear();
      a.server.on('POST /auth/login/password', (_) => fehler(403, 'account_pending'));
      await expectLater(
        a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a)),
        throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.kontoWartet)),
      );
      expect(a.logins, hasLength(1));
    });

    test('Netzfehler beim Abruf der Parameter geht nach oben (kein stiller Wechsel zu Klartext)', () async {
      final a = _aufbau(konto: 'authkey');
      a.server.on('POST /auth/kdf-params', (_) => fehler(503, 'server_busy'));
      await expectLater(a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a)), throwsA(isA<ApiException>()));
      expect(a.logins, isEmpty);
    });
  });

  group('Ableitung nicht möglich', () {
    test('unbekanntes Verfahren des Servers: erlaubt und unbekannt -> Klartext; bekannt oder Stichtag -> Fehlermeldung statt Klartext', () async {
      final a = _aufbau(konto: 'legacy');
      a.server.on('POST /auth/kdf-params', (_) => jsonAntwort({'kdf': {'id': 'unbekannt', 'memKiB': 1, 'ops': 1, 'salt': 'AAAA'}}));
      await a.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      expect(a.logins.single['password'], _pw);

      final b = _aufbau(konto: 'legacy');
      b.server.on('POST /auth/kdf-params', (_) => jsonAntwort({'kdf': {'id': 'unbekannt', 'memKiB': 1, 'ops': 1, 'salt': 'AAAA'}}));
      await b.store.merkeAuthKeyKonto(_email);
      await expectLater(b.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(b)), throwsA(isA<CryptoFehler>()));
      expect(b.logins, isEmpty);

      final c = _aufbau(legacy: false, konto: 'legacy');
      c.server.on('POST /auth/kdf-params', (_) => jsonAntwort({'kdf': {'id': 'unbekannt', 'memKiB': 1, 'ops': 1, 'salt': 'AAAA'}}));
      await expectLater(c.anmeldung.anmelden(email: _email, passwort: _pw, senden: _sender(c)), throwsA(isA<CryptoFehler>()));
      expect(c.logins, isEmpty);
    });

    test('Bibliothek nicht verfügbar: wie oben, die Meldung enthält nie das Passwort', () async {
      final a = _aufbau(legacy: false, konto: 'legacy');
      final k = PasswortAnmeldung(api: a.api, store: a.store, krypto: () async => throw StateError('libsodium fehlt $_pw'));
      Object? fehler;
      try {
        await k.anmelden(email: _email, passwort: _pw, senden: _sender(a));
      } catch (e) {
        fehler = e;
      }
      expect(fehler, isA<CryptoFehler>());
      expect(fehler.toString(), isNot(contains(_pw)));
    });
  });

  group('Neues Passwort (einrichten, ändern, registrieren)', () {
    test('Server mit authKey: nur authKey, die Regelprüfung läuft vorher', () async {
      final a = _aufbau(konto: 'authkey');
      var geprueft = 0;
      final n = await a.anmeldung.neuesPasswort(_email, _pw, pruefenMitAuthKey: () => geprueft++);
      expect(n.klartext, isNull);
      expect(n.authKey, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(geprueft, 1);
      await expectLater(
        a.anmeldung.neuesPasswort(_email, _pw, pruefenMitAuthKey: () => throw const CryptoFehler(CryptoFehlerArt.format, 'zu schwach')),
        throwsA(isA<CryptoFehler>()),
      );
    });

    test('älterer Server: Klartext wie bisher, keine Regelprüfung der App (der Server prüft selbst)', () async {
      final a = _aufbau(authKey: false);
      var geprueft = 0;
      final n = await a.anmeldung.neuesPasswort(_email, _pw, pruefenMitAuthKey: () => geprueft++);
      expect(n.klartext, _pw);
      expect(n.authKey, isNull);
      expect(geprueft, 0);
    });

    test('Ableitung nicht möglich: Klartext nur solange der Server ihn noch annimmt und das Konto nicht gemerkt ist', () async {
      final a = _aufbau(konto: 'legacy');
      a.server.on('POST /auth/kdf-params', (_) => jsonAntwort({'kdf': {'id': 'unbekannt', 'memKiB': 1, 'ops': 1, 'salt': 'AAAA'}}));
      expect((await a.anmeldung.neuesPasswort(_email, _pw)).klartext, _pw);
      await a.store.merkeAuthKeyKonto(_email);
      await expectLater(a.anmeldung.neuesPasswort(_email, _pw), throwsA(isA<CryptoFehler>()));
    });
  });
}
