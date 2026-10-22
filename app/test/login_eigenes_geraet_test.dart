// P1: Automatisches Verbinden nach der Anmeldung nur mit Zustimmung ("Das ist mein eigenes Gerät – Schlüssel hier speichern"): Standard an auf Android (hier im Test),
// aus im Browser; ohne Haken keine Abfrage der Passwort-Sicherung; nach dem Verbinden bietet der Hinweis "Gerät abgeben" an. 360 px, Textskala 1.0 und 1.5.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/auto_verbinden.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Future<({TestUmgebung env, FakeServer server})> _aufbau() async {
  final server = FakeServer();
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de')
    ..pwSchalter = true
    ..authKeySchalter = false;
  // der Server kennt einen Schlüssel der Person und eine bestätigte Passwort-Sicherung; ihr Inhalt ist hier ein Platzhalter (Öffnen scheitert, der Abruf zählt)
  srv.setzeSchluessel(fixIdAdmin, enc: base64urlKodieren(Uint8List(32)), sign: base64urlKodieren(Uint8List(32)), version: 1);
  srv.pwEinspielen(fixIdAdmin, base64urlKodieren(Uint8List.fromList(List.generate(160, (i) => i))), version: 1);
  server
    ..json('POST /auth/login/password', {'user': userJson(), 'session': appSession()})
    ..json('GET /me', meJson())
    ..json('GET /me/security-events', {'events': <Object>[]});
  final env = TestUmgebung(server);
  env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()), schluesselSpeicherProvider.overrideWithValue(MemorySchluesselSpeicher())]);
  return (env: env, server: server);
}

Future<void> _anmelden(WidgetTester tester) async {
  await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
  await eingeben(tester, 'Passwort', 'geheimes-passwort-123');
  await tippeText(tester, 'Weiter');
  await eingeben(tester, 'Code aus der Authenticator-App', '481234');
  await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
  await warte(tester, 12);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    testWidgets('Die Option steht auf der Anmeldeseite, ist auf Android vorbelegt und erklärt sich (360 px, Textskala $skala)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      final haken = find.widgetWithText(CheckboxListTile, 'Das ist mein eigenes Gerät – Schlüssel hier speichern');
      expect(haken, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(haken).value, isTrue, reason: 'Android: Standard an (im Browser aus)');
      expect(find.textContaining('Auf einem fremden oder gemeinsam genutzten Gerät nicht anhaken'), findsOneWidget);
      pruefeLayout(tester, 'Anmeldeseite mit Option');
    });
  }

  testWidgets('mit Haken: nach der Anmeldung wird die Passwort-Sicherung abgerufen (Verbinden versucht), der Hinweis nennt nie das Passwort', (tester) async {
    final a = await _aufbau();
    await starteApp(tester, a.env);
    await _anmelden(tester);
    expect(a.server.anfragen('GET /me/key-backup-pw'), isNotEmpty, reason: 'zugestimmt: das Gerät versucht, sich zu verbinden');
    expect(find.textContaining('geheimes-passwort-123'), findsNothing);
  });

  testWidgets('nach dem Verbinden: der Hinweis erklärt den Weg zurück und führt mit "Gerät abgeben" zur Verschlüsselung; andere Hinweise bieten es nicht an', (tester) async {
    final env = await angemeldeteUmgebung();
    env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()), schluesselSpeicherProvider.overrideWithValue(MemorySchluesselSpeicher())]);
    final c = await starteApp(tester, env);
    c.read(autoVerbindenHinweisProvider.notifier).setzen(const AutoVerbindenHinweis('Dieses Gerät ist mit deinem Schlüssel verbunden.', abgebenAnbieten: true));
    await warte(tester);
    expect(find.textContaining('Ist das nicht dein eigenes Gerät? Dann gib es unter „Gerät abgeben“ wieder ab.'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Gerät abgeben'), findsOneWidget);
    pruefeLayout(tester, 'Hinweis mit Gerät abgeben');
    await tippe(tester, find.widgetWithText(SnackBarAction, 'Gerät abgeben'));
    expect(find.text('Verschlüsselung'), findsWidgets);
    expect(find.textContaining('Mit einem persönlichen Schlüssel'), findsOneWidget);
    // ein Hinweis ohne Verbinden (z. B. fehlgeschlagen) bietet das Abgeben nicht an
    Navigator.of(tester.element(find.textContaining('Mit einem persönlichen Schlüssel'))).pop();
    await warte(tester);
    c.read(autoVerbindenHinweisProvider.notifier).setzen(const AutoVerbindenHinweis('Dieses Gerät konnte nicht automatisch mit deinem Schlüssel verbunden werden.'));
    await warte(tester);
    expect(find.widgetWithText(SnackBarAction, 'Gerät abgeben'), findsNothing);
  });

  testWidgets('ohne Haken: kein Abruf der Passwort-Sicherung, kein Hinweis, der manuelle Weg bleibt', (tester) async {
    final a = await _aufbau();
    await starteApp(tester, a.env);
    await tippe(tester, find.widgetWithText(CheckboxListTile, 'Das ist mein eigenes Gerät – Schlüssel hier speichern'));
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await _anmelden(tester);
    expect(a.server.anfragen('POST /auth/login/password'), hasLength(1));
    expect(a.server.anfragen('GET /me/key-backup-pw'), isEmpty, reason: 'ohne Zustimmung wird die Sicherung nie automatisch geöffnet');
    expect(find.textContaining('automatisch mit deinem Schlüssel verbunden'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
