// Oberfläche der Passwort-Sicherung (Profil > Verschlüsselung > Passwort-Sicherung): nur sichtbar, wenn der Server sie anbietet; Passwort mit
// Mindeststärke und Bestätigung, Vorschlag, Anlegen mit Prüfung, Fehlerfall; Gerät ohne Schlüssel verbindet mit Passwort.
// 360 px Breite, Textskala 1.0 und 1.5, Touch-Ziele >= 44 px.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/pw_sicherung.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/wortliste.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _pw = 'Zebra-Kamin-Orbit-Fluss-Lampe';

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final FakeServer server;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.server, this.speicher);
}

Future<_Aufbau> _aufbau({bool schalter = true, bool schluessel = true}) async {
  final server = standardServer();
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de')
    ..pwSchalter = schalter;
  final env = TestUmgebung(server);
  await env.angemeldet();
  final speicher = MemorySchluesselSpeicher();
  final zufall = Random(5);
  final woerter = {for (var i = 0; i < 400; i++) String.fromCharCodes(List.generate(7, (_) => 97 + zufall.nextInt(26)))}.toList();
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
    schluesselSpeicherProvider.overrideWithValue(speicher),
    wortlisteProvider.overrideWith((ref) async => woerter),
  ]);
  if (schluessel) {
    // bestehender Stand: Schlüssel auf dem Gerät und beim Server
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

    testWidgets('Ohne Schalter des Servers gibt es keine Passwort-Sicherung ($s)', (tester) async {
      final a = await _aufbau(schalter: false);
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.text('Passwort-Sicherung'), findsNothing);
      pruefeLayout(tester, 'Verschlüsselung ohne Passwort-Sicherung');
    });

    testWidgets('Passwort wählen: Regeln, Bestätigung, Vorschlag, Anlegen und Prüfen ($s)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Passwort-Sicherung'), findsOneWidget);
      expect(find.textContaining('nicht gesichert · jetzt einrichten'), findsOneWidget);
      pruefeLayout(tester, 'Verschlüsselung mit Zeile');

      await tippeText(tester, 'Passwort-Sicherung');
      pruefeLayout(tester, 'Passwort-Sicherung leer');
      final knopf = find.widgetWithText(FilledButton, 'Sicherung anlegen und prüfen');
      expect(tester.widget<FilledButton>(knopf).onPressed, isNull);

      // zu kurz
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'kurz');
      expect(find.textContaining('mindestens 12 Zeichen'), findsOneWidget);
      expect(tester.widget<FilledButton>(knopf).onPressed, isNull);
      pruefeLayout(tester, 'Passwort-Sicherung: Regelhinweis');

      // enthält Kontodaten
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'anna@beispiel.de-123');
      expect(find.textContaining('E-Mail-Adresse oder deinen Namen'), findsOneWidget);

      // gültig, aber Bestätigung fehlt oder weicht ab
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', _pw);
      expect(tester.widget<FilledButton>(knopf).onPressed, isNull);
      await eingeben(tester, 'Passwort wiederholen', '${_pw}x');
      expect(find.text('Die beiden Passwörter sind nicht gleich.'), findsOneWidget);
      expect(tester.widget<FilledButton>(knopf).onPressed, isNull);
      pruefeLayout(tester, 'Passwort-Sicherung: Bestätigung falsch');

      // Vorschlag füllt beide Felder und zeigt ihn
      await tippeText(tester, 'Passwort vorschlagen');
      final felder = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(felder[0].controller!.text, felder[1].controller!.text);
      expect(felder[0].controller!.text.split('-'), hasLength(5));
      expect(felder[0].obscureText, isFalse, reason: 'der Vorschlag wird sichtbar, damit man ihn notieren kann');
      expect(tester.widget<FilledButton>(knopf).onPressed, isNotNull);
      pruefeLayout(tester, 'Passwort-Sicherung: Vorschlag');

      // bewusst eigenes Passwort und anlegen
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', _pw);
      await eingeben(tester, 'Passwort wiederholen', _pw);
      await tippe(tester, knopf);
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);

      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.textContaining('liegt beim server (seit '), findsOneWidget, reason: 'der Stand beim Server zählt, nicht ein "geprüft" auf diesem Gerät');
      expect(find.textContaining('neues passwort wählen'), findsOneWidget);
      expect(a.srv.pwStand(fixIdAdmin).verifiziert, isTrue);
      expect(a.server.anfragen('POST /me/key-backup-pw/verified'), hasLength(1));
      pruefeLayout(tester, 'Verschlüsselung nach Anlegen');
    });

    testWidgets('Prüfung scheitert: Fehlermeldung, nichts gilt als gesichert ($s)', (tester) async {
      final a = await _aufbau();
      a.srv.pwAbrufVerfaelschen = (b) => 'x$b';
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Passwort-Sicherung');
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', _pw);
      await eingeben(tester, 'Passwort wiederholen', _pw);
      await tippe(tester, find.widgetWithText(FilledButton, 'Sicherung anlegen und prüfen'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);

      expect(find.textContaining('Prüfung der Passwort-Sicherung ist fehlgeschlagen'), findsOneWidget);
      expect(a.srv.pwStand(fixIdAdmin).verifiziert, isFalse);
      expect(a.server.anfragen('POST /me/key-backup-pw/verified'), isEmpty);
      pruefeLayout(tester, 'Passwort-Sicherung: Fehler');
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.textContaining('nicht gesichert · jetzt einrichten'), findsOneWidget);
    });

    testWidgets('Gerät ohne Schlüssel: mit Passwort verbinden ($s)', (tester) async {
      final a = await _aufbau(schluessel: false);
      // anderes Gerät hat den Schlüssel eingerichtet und die Passwort-Sicherung angelegt
      final seeds = Uint8List.fromList(List.generate(64, (i) => 200 - i));
      final crypto = FakeCryptoProvider();
      final k = _schluessel(crypto, seeds);
      a.srv.setzeSchluessel(fixIdAdmin, enc: k.$1, sign: k.$2, version: 1);
      // Blob direkt mit den echten Bausteinen erzeugen
      final geraetA = await _blobFuer(crypto, seeds, 'anna@beispiel.de', _pw);
      a.srv.pwEinspielen(fixIdAdmin, geraetA, version: 1);

      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Dieses Gerät ist nicht verbunden'), findsOneWidget);
      pruefeLayout(tester, 'Gerät nicht verbunden mit Passwort-Knopf');
      await tippeText(tester, 'Mit Passwort verbinden');
      await eingeben(tester, 'Passwort der Sicherung', 'Falsch-Falsch-Falsch-Falsch');
      await tippe(tester, find.widgetWithText(FilledButton, 'Verbinden'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.text('Das Passwort passt nicht zu deiner Sicherung.'), findsOneWidget);
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
      pruefeLayout(tester, 'Mit Passwort verbinden: falsch');

      await eingeben(tester, 'Passwort der Sicherung', _pw);
      await tippe(tester, find.widgetWithText(FilledButton, 'Verbinden'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), seeds);
    });

    testWidgets('Nach Passwort-Reset: veraltete Sicherung, Hinweis, Alternativen, Öffnen mit altem Passwort ($s)', (tester) async {
      final a = await _aufbau(schluessel: false);
      final seeds = Uint8List.fromList(List.generate(64, (i) => 200 - i));
      final crypto = FakeCryptoProvider();
      final k = _schluessel(crypto, seeds);
      a.srv.setzeSchluessel(fixIdAdmin, enc: k.$1, sign: k.$2, version: 1);
      a.srv.pwEinspielen(fixIdAdmin, await _blobFuer(crypto, seeds, 'anna@beispiel.de', _pw), version: 1);
      a.srv.passwortZurueckgesetzt(fixIdAdmin);

      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Mit Passwort verbinden');
      expect(find.textContaining('Dein Anmelde-Passwort wurde zurückgesetzt. Deine alte Passwort-Sicherung funktioniert noch'), findsOneWidget);
      final verbinden = find.widgetWithText(FilledButton, 'Verbinden');
      expect(tester.widget<FilledButton>(verbinden).onPressed, isNull, reason: 'leeres Feld');
      await eingeben(tester, 'Passwort der Sicherung', 'Neues-Anmelde-Passwort-Wolke-Baum');
      expect(tester.widget<FilledButton>(verbinden).onPressed, isNotNull);
      expect(find.text('Mit anderem Gerät verbinden'), findsOneWidget);
      pruefeLayout(tester, 'Mit Passwort verbinden: veraltete Sicherung');

      await tippe(tester, verbinden);
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('alten Passwort-Sicherung'), findsOneWidget);
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
      pruefeLayout(tester, 'Mit Passwort verbinden: falsches Passwort bei veralteter Sicherung');

      await eingeben(tester, 'Passwort der Sicherung', _pw);
      await tippe(tester, find.widgetWithText(FilledButton, 'Verbinden'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), seeds);
      expect(find.text('Passwort-Sicherung'), findsWidgets, reason: 'danach wird das Erneuern angeboten');
    });
  }
}

/// Erzeugt den Blob, den ein anderes Gerät angelegt hätte (Salt wie ihn der Fake-Server für die E-Mail nennt).
Future<String> _blobFuer(FakeCryptoProvider crypto, Uint8List seeds, String email, String passwort) async {
  final params = PwKdfParams(kdfId: kKdf1, memKiB: kKdf1MemKiB, ops: kKdf1Ops, salt: FakeE2eeServer.saltFuer(email));
  final keys = await PwSchluessel.ausPasswort(crypto, passwort: passwort, params: params);
  return PwSicherungBlob.erzeugen(crypto, schluessel: Personenschluessel.ausBytes(crypto, seeds), kek: keys.kek, params: params, userId: fixIdAdmin, keyVersion: 1);
}
