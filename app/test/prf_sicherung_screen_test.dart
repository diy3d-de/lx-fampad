// Oberfläche der Passkey-Sicherung (Profil > Verschlüsselung): nur sichtbar, wenn der Server sie anbietet UND die Person einen Passkey hat; Anlegen mit zwei Passkey-Gesten,
// "nicht unterstützt" ohne Veränderung, Fehlerfall, Gerät ohne Schlüssel verbindet mit dem Passkey, Absicherungs-Seite. 360 px Breite, Textskala 1.0 und 1.5.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/prf_sicherung.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Uint8List _prf() => Uint8List.fromList(List.generate(32, (i) => i + 3));

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final FakeServer server;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.server, this.speicher);
}

Future<_Aufbau> _aufbau({bool schalter = true, bool schluessel = true, int passkeys = 1}) async {
  final server = standardServer();
  server.json('GET /me', meJson(passkeys: passkeys, password: true, totp: true));
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de')
    ..prfSchalter = schalter;
  final env = TestUmgebung(server);
  env.passkeys.prfAusgabe = _prf();
  await env.angemeldet();
  final speicher = MemorySchluesselSpeicher();
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
    schluesselSpeicherProvider.overrideWithValue(speicher),
  ]);
  if (schluessel) {
    final crypto = FakeCryptoProvider();
    final pk = Uint8List.fromList(List.generate(64, (i) => i + 1));
    await speicher.schreiben(personenschluesselName(fixIdAdmin), pk);
    final s = _schluessel(crypto, pk);
    srv.setzeSchluessel(fixIdAdmin, enc: s.$1, sign: s.$2, version: 1);
  }
  return _Aufbau(env, srv, server, speicher);
}

(String, String) _schluessel(FakeCryptoProvider crypto, Uint8List seeds) {
  final box = crypto.boxPaarAusSeed(seeds.sublist(0, 32));
  final sign = crypto.signPaarAusSeed(seeds.sublist(32));
  return (base64urlKodieren(Uint8List.fromList(box.oeffentlich)), base64urlKodieren(Uint8List.fromList(sign.oeffentlich)));
}

Future<void> _zurSeite(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Verschlüsselung');
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    testWidgets('Ohne Schalter des Servers oder ohne Passkey gibt es keine Passkey-Sicherung ($s)', (tester) async {
      final a = await _aufbau(schalter: false);
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.text('Passkey-Sicherung'), findsNothing);
      pruefeLayout(tester, 'Verschlüsselung ohne Passkey-Sicherung');
    });

    testWidgets('Person ohne Passkey: die Zeile bleibt unsichtbar ($s)', (tester) async {
      final a = await _aufbau(passkeys: 0);
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.text('Passkey-Sicherung'), findsNothing);
    });

    testWidgets('Anlegen: zwei Gesten, danach "liegt beim server" und bestätigt ($s)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Passkey-Sicherung'), findsOneWidget);
      expect(find.textContaining('nicht gesichert · jetzt einrichten'), findsWidgets);
      pruefeLayout(tester, 'Verschlüsselung mit Passkey-Zeile');

      await tippeText(tester, 'Passkey-Sicherung');
      expect(find.text('Mit Passkey sichern'), findsOneWidget);
      expect(find.textContaining('zweimal mit deinem Passkey'), findsOneWidget);
      pruefeLayout(tester, 'Passkey-Sicherung anlegen');
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey sichern'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);

      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.textContaining('liegt beim server (seit '), findsWidgets);
      expect(a.srv.prfStand(fixIdAdmin, 'cred-1').verifiziert, isTrue);
      expect(a.env.passkeys.mitPrfBestaetigt, 2);
      expect(a.server.anfragen('POST /me/key-backup-prf/verified'), hasLength(1));
      pruefeLayout(tester, 'Verschlüsselung nach Anlegen');
    });

    testWidgets('PRF wird nicht unterstützt: ehrlicher Hinweis, nichts verändert ($s)', (tester) async {
      final a = await _aufbau();
      a.env.passkeys.prfAusgabe = null;
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Passkey-Sicherung');
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey sichern'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('unterstützt diese Funktion auf diesem Gerät nicht'), findsOneWidget);
      expect(a.server.anfragen('PUT /me/key-backup-prf'), isEmpty);
      pruefeLayout(tester, 'Passkey-Sicherung: nicht unterstützt');
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.textContaining('nicht gesichert · jetzt einrichten'), findsWidgets);
    });

    testWidgets('Prüfung scheitert: Fehlermeldung, nichts gilt als gesichert ($s)', (tester) async {
      final a = await _aufbau();
      a.srv.prfAbrufVerfaelschen = (b) => 'x$b';
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Passkey-Sicherung');
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey sichern'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Prüfung der Passkey-Sicherung ist fehlgeschlagen'), findsOneWidget);
      expect(a.srv.prfStand(fixIdAdmin, 'cred-1').verifiziert, isFalse);
      expect(a.server.anfragen('POST /me/key-backup-prf/verified'), isEmpty);
      pruefeLayout(tester, 'Passkey-Sicherung: Fehler');
    });

    testWidgets('Gerät ohne Schlüssel: mit Passkey verbinden ($s)', (tester) async {
      final a = await _aufbau(schluessel: false);
      // ein anderes Gerät hat den Schlüssel eingerichtet und die Passkey-Sicherung angelegt
      final seeds = Uint8List.fromList(List.generate(64, (i) => 200 - i));
      final crypto = FakeCryptoProvider();
      final k = _schluessel(crypto, seeds);
      a.srv.setzeSchluessel(fixIdAdmin, enc: k.$1, sign: k.$2, version: 1);
      final kek = PrfSchluessel.ausAusgabe(crypto, _prf()).kek;
      final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: Personenschluessel.ausBytes(crypto, seeds), kek: kek, userId: fixIdAdmin, keyVersion: 1, credentialId: 'cred-1');
      a.srv.prfEinspielen(fixIdAdmin, 'cred-1', blob, version: 1);

      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Dieses Gerät ist nicht verbunden'), findsOneWidget);
      expect(find.text('Mit Passkey verbinden'), findsOneWidget);
      pruefeLayout(tester, 'Gerät nicht verbunden mit Passkey-Knopf');

      // falscher Passkey (andere Ausgabe): nichts passiert
      a.env.passkeys.prfAusgabe = Uint8List.fromList(List.generate(32, (i) => 99 - i));
      await tippeText(tester, 'Mit Passkey verbinden');
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey verbinden'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Dieser Passkey öffnet die Sicherung nicht'), findsOneWidget);
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
      pruefeLayout(tester, 'Mit Passkey verbinden: falscher Passkey');

      a.env.passkeys.prfAusgabe = _prf();
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey verbinden'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), seeds);
    });

    testWidgets('Absicherung: die Passkey-Sicherung wird als nächster Schritt angeboten und zählt danach als Weg ($s)', (tester) async {
      final a = await _aufbau();
      a.srv.keyStatusSchalter = true;
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippeText(tester, 'Bin ich abgesichert?');
      expect(find.text('Passkey-Sicherung anlegen'), findsOneWidget);
      expect(find.text('Passkey-Sicherung'), findsOneWidget);
      pruefeLayout(tester, 'Absicherung mit Passkey-Schritt');
      await tippeText(tester, 'Passkey-Sicherung anlegen');
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Passkey sichern'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(a.srv.prfStand(fixIdAdmin, 'cred-1').verifiziert, isTrue);
      expect(find.textContaining('bestätigt seit'), findsWidgets);
      expect(find.text('Passkey-Sicherung anlegen'), findsNothing);
      pruefeLayout(tester, 'Absicherung nach Passkey-Sicherung');
    });
  }
}
