// Oberflächen mit authKey (PR 4): Anmeldung (360 px, Textskala 1.0/1.5), Passwort ändern mit und ohne Passwort-Sicherung, Passwort einrichten,
// Markierung "altes Passwort-Verfahren" in der Mitglieder-Ansicht. Nie geht das Passwort an den Server, solange dieser authKey kann.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _pwNeu = 'Zebra-Kamin-Orbit-Fluss-Lampe';

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final FakeServer server;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.server, this.speicher);

  String get alleAnfragen => jsonEncode(server.log.map((r) => r.body is Map ? r.body : null).toList());
}

Future<_Aufbau> _aufbau({bool authKey = true, bool mitSicherung = false, bool schluessel = true}) async {
  final server = standardServer();
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de')
    ..pwSchalter = authKey
    ..authKeySchalter = authKey;
  final env = TestUmgebung(server);
  await env.angemeldet();
  final speicher = MemorySchluesselSpeicher();
  env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()), schluesselSpeicherProvider.overrideWithValue(speicher)]);
  final crypto = FakeCryptoProvider();
  final pk = Uint8List.fromList(List.generate(64, (i) => i + 1));
  final box = crypto.boxPaarAusSeed(pk.sublist(0, 32));
  final sign = crypto.signPaarAusSeed(pk.sublist(32));
  srv.setzeSchluessel(
    fixIdAdmin,
    enc: base64urlKodieren(Uint8List.fromList(box.oeffentlich)),
    sign: base64urlKodieren(Uint8List.fromList(sign.oeffentlich)),
    version: 1,
  );
  if (schluessel) await speicher.schreiben(personenschluesselName(fixIdAdmin), pk);
  if (mitSicherung) srv.pwEinspielen(fixIdAdmin, base64urlKodieren(Uint8List.fromList(List.generate(160, (i) => i))), version: 1);
  return _Aufbau(env, srv, server, speicher);
}

Future<void> _zurPasswortSeite(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Passwort und Zwei-Faktor (TOTP)');
}

Future<void> _passwortAendern(WidgetTester tester, String pw) async {
  await tippeText(tester, 'Passwort ändern');
  await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', pw);
  await eingeben(tester, 'Passwort wiederholen', pw);
  await tippe(tester, find.widgetWithText(FilledButton, 'Passwort ändern'));
  await tester.pump(const Duration(milliseconds: 200));
  await warte(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    group('Passwort ändern mit authKey ($s)', () {
      testWidgets('ohne Passwort-Sicherung: nur der authKey geht an den Server, nie das Passwort', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _zurPasswortSeite(tester);
        await _passwortAendern(tester, _pwNeu);
        final anfrage = a.server.anfragen('POST /me/password/change').single.json;
        expect(anfrage.keys.toSet(), {'authKey'});
        expect(anfrage['authKey'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(a.alleAnfragen, isNot(contains(_pwNeu)));
        expect(find.text('Passwort geändert.'), findsOneWidget);
        pruefeLayout(tester, 'Passwort geändert');
      });

      testWidgets('mit Passwort-Sicherung und Schlüssel auf dem Gerät: Sicherung wird mit abgelegt, geprüft und gemeinsam mit dem Passwort gültig', (tester) async {
        final a = await _aufbau(mitSicherung: true);
        await starteApp(tester, a.env, skala: skala);
        await _zurPasswortSeite(tester);
        await _passwortAendern(tester, _pwNeu);
        final put = a.server.anfragen('PUT /me/key-backup-pw');
        expect(put, hasLength(1));
        final aenderung = a.server.anfragen('POST /me/password/change').single.json;
        expect(aenderung['authKey'], isA<String>());
        expect(aenderung['pwBackupId'], isA<String>());
        expect(a.server.anfragen('POST /me/key-backup-pw/verified'), isEmpty, reason: 'bestätigt wird mit dem Passwortwechsel, nicht einzeln');
        expect(a.srv.pwStand(fixIdAdmin).verifiziert, isTrue);
        expect(a.srv.pwStand(fixIdAdmin).blob, put.single.json['blob']);
        expect(a.alleAnfragen, isNot(contains(_pwNeu)));
        expect(find.textContaining('Passwort-Sicherung gehört jetzt zum neuen Passwort'), findsOneWidget);
        pruefeLayout(tester, 'Passwort mit Sicherung geändert');
      });

      testWidgets('Sicherung vorhanden, aber kein Schlüssel auf dem Gerät: Passwort ändert sich, Hinweis auf die veraltete Sicherung', (tester) async {
        final a = await _aufbau(mitSicherung: true, schluessel: false);
        await starteApp(tester, a.env, skala: skala);
        await _zurPasswortSeite(tester);
        await _passwortAendern(tester, _pwNeu);
        expect(a.server.anfragen('PUT /me/key-backup-pw'), isEmpty);
        expect(a.server.anfragen('POST /me/password/change').single.json.containsKey('pwBackupId'), isFalse);
        expect(find.textContaining('noch zum alten Passwort'), findsOneWidget);
        pruefeLayout(tester, 'veraltete Sicherung');
      });

      testWidgets('Schwaches Passwort wird auf dem Gerät abgelehnt (der Server kann es nicht prüfen), nichts wird gesendet', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _zurPasswortSeite(tester);
        await _passwortAendern(tester, 'passwortpasswort');
        expect(find.textContaining('zu leicht zu erraten'), findsOneWidget);
        expect(a.server.anfragen('POST /me/password/change'), isEmpty);
        pruefeLayout(tester, 'schwaches Passwort');
      });

      testWidgets('Server ohne authKey: Klartext wie bisher', (tester) async {
        final a = await _aufbau(authKey: false);
        await starteApp(tester, a.env, skala: skala);
        await _zurPasswortSeite(tester);
        await _passwortAendern(tester, 'ein-anderes-langes-passwort');
        expect(a.server.anfragen('POST /me/password/change').single.json, {'password': 'ein-anderes-langes-passwort'});
        expect(a.server.anfragen('POST /auth/kdf-params'), isEmpty);
      });

      testWidgets('Prüfung der neuen Sicherung scheitert: das Passwort bleibt unverändert', (tester) async {
        final a = await _aufbau(mitSicherung: true);
        a.srv.pwAbrufVerfaelschen = (b) => 'x$b';
        await starteApp(tester, a.env, skala: skala);
        await _zurPasswortSeite(tester);
        await _passwortAendern(tester, _pwNeu);
        expect(find.textContaining('Prüfung der Passwort-Sicherung ist fehlgeschlagen'), findsOneWidget);
        expect(a.server.anfragen('POST /me/password/change'), isEmpty);
        pruefeLayout(tester, 'Prüfung gescheitert');
      });
    });

    group('Anmeldung ($s)', () {
      FakeServer loginServer({required bool kontoMitAuthKey}) {
        final srv = FakeServer()
          ..json('GET /version', {
            'features': {'pwBackup': true, 'authKey': true, 'legacyPasswordLogin': true},
          })
          ..on('POST /auth/kdf-params', (r) => jsonAntwort({'kdf': {'id': 'argon2id-v1', 'memKiB': 65536, 'ops': 3, 'salt': base64urlKodieren(FakeE2eeServer.saltFuer(r.json['email'] as String))}}))
          ..json('GET /me', meJson())
          ..on('POST /auth/login/password', (r) {
            final ok = r.json.containsKey('authKey') ? kontoMitAuthKey : !kontoMitAuthKey && r.json['password'] == 'geheimes-passwort-123';
            return ok ? jsonAntwort({'user': userJson(), 'session': appSession()}) : fehler(401, 'invalid_credentials');
          });
        return srv;
      }

      Future<void> anmelden(WidgetTester tester) async {
        await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
        await eingeben(tester, 'Passwort', 'geheimes-passwort-123');
        await tippeText(tester, 'Weiter');
        await eingeben(tester, 'Code aus der Authenticator-App', '481234');
        await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
        await tester.pump(const Duration(milliseconds: 200));
        await warte(tester);
      }

      testWidgets('Konto mit authKey: ein Versuch, das Passwort steht in keiner Anfrage', (tester) async {
        final server = loginServer(kontoMitAuthKey: true);
        final env = TestUmgebung(server)..extraOverrides.add(cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()));
        await starteApp(tester, env, skala: skala);
        await anmelden(tester);
        final logins = server.anfragen('POST /auth/login/password');
        expect(logins, hasLength(1));
        expect(logins.single.json['authKey'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(logins.single.json.containsKey('password'), isFalse);
        expect(jsonEncode(server.log.map((r) => r.body is Map ? r.body : null).toList()), isNot(contains('geheimes-passwort-123')));
        expect(find.byType(NavigationBar), findsOneWidget);
      });

      testWidgets('Konto im Altzustand: wird beim Anmelden umgestellt, ohne dass die Person etwas merkt', (tester) async {
        final server = loginServer(kontoMitAuthKey: false);
        final env = TestUmgebung(server)..extraOverrides.add(cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()));
        await starteApp(tester, env, skala: skala);
        await anmelden(tester);
        final logins = server.anfragen('POST /auth/login/password');
        expect(logins, hasLength(2));
        expect(logins[1].json['password'], 'geheimes-passwort-123');
        expect(logins[1].json['upgradeAuthKey'], logins[0].json['authKey']);
        expect(find.byType(NavigationBar), findsOneWidget);
      });

      testWidgets('falsche Daten: die übliche Meldung, kein Hinweis auf den Zustand des Kontos', (tester) async {
        final server = loginServer(kontoMitAuthKey: true)..on('POST /auth/login/password', (_) => fehler(401, 'invalid_credentials', message: 'SERVER-INTERN'));
        final env = TestUmgebung(server)..extraOverrides.add(cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()));
        await starteApp(tester, env, skala: skala);
        await anmelden(tester);
        expect(find.textContaining('Die Anmeldung hat nicht geklappt'), findsOneWidget);
        expect(find.textContaining('SERVER-INTERN'), findsNothing);
        pruefeLayout(tester, 'Anmeldung: Fehler');
      });
    });

    group('Mitglieder-Ansicht ($s)', () {
      testWidgets('Admin sieht die Markierung "altes passwort-verfahren" nur bei legacy-Konten', (tester) async {
        final server = standardServer();
        server.json('GET /members/password-modes', {
          'legacyPasswordLogin': true,
          'modes': [
            {'userId': fixIdAdmin, 'mode': 'authkey'},
            {'userId': fixIdKind, 'mode': 'legacy'},
          ],
        });
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Mitglieder und Einladungen');
        expect(find.text('altes passwort-verfahren'), findsOneWidget, reason: 'nur Ben ist noch im Altzustand');
        pruefeLayout(tester, 'Mitglieder mit Markierung');
      });

      testWidgets('Längste Pillenzeile (Rolle, Familienrolle, Markierung, wartet) läuft nicht über', (tester) async {
        final server = standardServer();
        server.json('GET /members', {
          'members': [
            {...userJson(), 'familyRole': 'grosseltern'},
            {...userJson(id: fixIdKind, role: 'parent', name: 'Bernhard-Maximilian Langername', email: 'bernhard.maximilian.langername@beispiel.de'), 'familyRole': 'grosseltern'},
          ],
        });
        server.json('GET /members/password-modes', {
          'legacyPasswordLogin': true,
          'modes': [
            {'userId': fixIdAdmin, 'mode': 'legacy'},
            {'userId': fixIdKind, 'mode': 'legacy'},
          ],
        });
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Mitglieder und Einladungen');
        expect(find.text('altes passwort-verfahren'), findsNWidgets(2));
        pruefeLayout(tester, 'Mitglieder: längste Pillenzeile');
      });

      testWidgets('ohne Angebot des Servers (404) fehlt die Markierung, die Liste bleibt', (tester) async {
        final env = TestUmgebung(standardServer());
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Mitglieder und Einladungen');
        expect(find.textContaining('Ben'), findsWidgets);
        expect(find.text('altes passwort-verfahren'), findsNothing);
      });
    });
  }
}
