// Anmeldung mit Passkey und automatisches Verbinden mit der Passkey-Sicherung (PRF): nur mit Zustimmung ("Das ist mein eigenes Gerät"); dieselbe Geste der Anmeldung liefert die
// PRF-Ausgabe; ohne Zustimmung, ohne PRF-Unterstützung oder bei einem Fehler der Erweiterung läuft die Anmeldung wie bisher. 360 px, Textskala 1.0 und 1.5.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/prf_sicherung.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/passkey_service.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Uint8List _prf() => Uint8List.fromList(List.generate(32, (i) => i + 5));
final _seeds = Uint8List.fromList(List.generate(64, (i) => 100 + i));

class _Aufbau {
  final TestUmgebung env;
  final FakeServer server;
  final FakeE2eeServer srv;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.server, this.srv, this.speicher);
}

Future<_Aufbau> _aufbau({bool sicherung = true}) async {
  final crypto = FakeCryptoProvider();
  final server = FakeServer();
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de')
    ..prfSchalter = true;
  final box = crypto.boxPaarAusSeed(_seeds.sublist(0, 32));
  final sign = crypto.signPaarAusSeed(_seeds.sublist(32));
  srv.setzeSchluessel(fixIdAdmin, enc: base64urlKodieren(box.oeffentlich), sign: base64urlKodieren(sign.oeffentlich), version: 1);
  if (sicherung) {
    final kek = PrfSchluessel.ausAusgabe(crypto, _prf()).kek;
    final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: Personenschluessel.ausBytes(crypto, _seeds), kek: kek, userId: fixIdAdmin, keyVersion: 1, credentialId: 'cred-1');
    srv.prfEinspielen(fixIdAdmin, 'cred-1', blob, version: 1);
  }
  server
    ..json('POST /auth/login/passkey/options', {'challengeId': 'login-1', 'options': {'challenge': 'AAAA', 'rpId': 'familyhub.lx-labs.dev'}})
    ..json('POST /auth/login/passkey/verify', {'user': userJson(), 'session': appSession()})
    ..json('GET /me', meJson())
    ..json('GET /me/security-events', {'events': <Object>[]});
  final env = TestUmgebung(server);
  env.passkeys.prfAusgabe = _prf();
  final speicher = MemorySchluesselSpeicher();
  env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => crypto), schluesselSpeicherProvider.overrideWithValue(speicher)]);
  return _Aufbau(env, server, srv, speicher);
}

Future<void> _passkeyAnmelden(WidgetTester tester) async {
  await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey anmelden'));
  await warte(tester, 12);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    testWidgets('mit Zustimmung: dieselbe Geste meldet an und verbindet das Gerät mit dem Schlüssel; der Hinweis bietet "Gerät abgeben" an (360 px, Textskala $skala)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _passkeyAnmelden(tester);
      expect(a.env.passkeys.mitPrfBestaetigt, 1, reason: 'eine Geste: die Anmeldung liefert die PRF-Ausgabe');
      expect(a.env.passkeys.bestaetigt, 0);
      expect(a.server.anfragen('POST /auth/login/passkey/verify'), hasLength(1));
      expect(a.server.anfragen('GET /me/key-backup-prf'), hasLength(1));
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), _seeds);
      expect(find.textContaining('Dieses Gerät ist mit deinem Schlüssel verbunden'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Gerät abgeben'), findsOneWidget);
      // die PRF-Ausgabe verlässt das Gerät nie: nicht in der Anmeldeantwort an den Server
      for (final r in a.server.anfragen('POST /auth/login/passkey/verify')) {
        expect(r.body, isNot(contains(base64urlKodieren(_prf()))));
      }
      pruefeLayout(tester, 'nach Anmeldung mit Passkey und Verbinden');
    });
  }

  testWidgets('ohne Zustimmung: normale Anmeldung ohne PRF, die Sicherung wird nie geöffnet', (tester) async {
    final a = await _aufbau();
    await starteApp(tester, a.env);
    await tippe(tester, find.widgetWithText(CheckboxListTile, 'Das ist mein eigenes Gerät – Schlüssel hier speichern'));
    await _passkeyAnmelden(tester);
    expect(a.env.passkeys.mitPrfBestaetigt, 0);
    expect(a.env.passkeys.bestaetigt, 1);
    expect(a.server.anfragen('GET /me/key-backup-prf'), isEmpty);
    expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Ohne Server-Schalter für die Passkey-Sicherung fragt die Anmeldung die PRF-Erweiterung nie mit, auch mit Zustimmung', (tester) async {
    final a = await _aufbau();
    a.srv.prfSchalter = false;
    await starteApp(tester, a.env);
    await _passkeyAnmelden(tester);
    expect(a.env.passkeys.mitPrfBestaetigt, 0);
    expect(a.env.passkeys.bestaetigt, 1);
    expect(a.server.anfragen('GET /me/key-backup-prf'), isEmpty);
    expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('PRF nicht unterstützt: die Anmeldung gelingt, es wird nichts geöffnet, kein Hinweis', (tester) async {
    final a = await _aufbau();
    a.env.passkeys.prfAusgabe = null;
    await starteApp(tester, a.env);
    await _passkeyAnmelden(tester);
    expect(a.server.anfragen('POST /auth/login/passkey/verify'), hasLength(1));
    expect(a.server.anfragen('GET /me/key-backup-prf'), isEmpty);
    expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
    expect(find.textContaining('mit deinem Schlüssel verbunden'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Die Erweiterung scheitert aus einem allgemeinen Grund: einmal ohne PRF wiederholt, die Anmeldung gelingt', (tester) async {
    final a = await _aufbau();
    a.env.passkeys.prfFehler = const PasskeyException(PasskeyFehler.sonstiges, 'Der Passkey konnte nicht verwendet werden.');
    await starteApp(tester, a.env);
    await _passkeyAnmelden(tester);
    expect(a.env.passkeys.bestaetigt, 1);
    expect(a.server.anfragen('POST /auth/login/passkey/verify'), hasLength(1));
    expect(a.server.anfragen('GET /me/key-backup-prf'), isEmpty);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Abbruch des Passkey-Dialogs wird nicht wiederholt (kein zweiter Dialog)', (tester) async {
    final a = await _aufbau();
    a.env.passkeys.prfFehler = const PasskeyException(PasskeyFehler.abgebrochen, 'Abgebrochen.');
    await starteApp(tester, a.env);
    await _passkeyAnmelden(tester);
    expect(a.env.passkeys.bestaetigt, 0);
    expect(a.server.anfragen('POST /auth/login/passkey/verify'), isEmpty);
    expect(find.widgetWithText(FilledButton, 'Mit Passkey anmelden'), findsOneWidget);
  });

  testWidgets('Passkey ohne Passkey-Sicherung: stumm, kein Abruf, die Absicherungs-Karte zeigt den nächsten Schritt', (tester) async {
    final a = await _aufbau(sicherung: false);
    await starteApp(tester, a.env);
    await _passkeyAnmelden(tester);
    expect(a.server.anfragen('GET /me/key-backup-prf'), isEmpty, reason: 'ohne bestätigte Sicherung kein protokollierter Abruf');
    expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
