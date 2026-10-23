// Oberfläche der Eltern-Wiederherstellung: Kinder-Seite (erlauben, aktualisieren, zurücknehmen, Eltern um Hilfe bitten, Wartefrist) und Eltern-Seite (Kinder, Anfragen, übernehmen,
// Code eingeben, ablehnen); nur sichtbar mit Schalter des Servers und passender Rolle; Pille im Profil des Kindes. 360 px Breite, Textskala 1.0 und 1.5.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/eltern_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _mama = '44444444-4444-4444-8444-444444444444';
const _kind = fixIdAdmin;

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final FakeServer server;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.server, this.speicher);
}

(String, String) _schluessel(FakeCryptoProvider crypto, Uint8List seeds) {
  final box = crypto.boxPaarAusSeed(seeds.sublist(0, 32));
  final sign = crypto.signPaarAusSeed(seeds.sublist(32));
  return (base64urlKodieren(Uint8List.fromList(box.oeffentlich)), base64urlKodieren(Uint8List.fromList(sign.oeffentlich)));
}

/// Aufbau als Kind (Rolle child) oder als Elternteil (Rolle parent). [schluessel]: der Schlüssel liegt auf diesem Gerät.
Future<_Aufbau> _aufbau({required String rolle, bool schalter = true, bool schluessel = true}) async {
  final server = standardServer();
  server.json('GET /me', meJson(role: rolle, passkeys: 1, password: true, totp: true));
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de', rolle: rolle)
    ..person(_mama, 'Mama', email: 'mama@beispiel.de', rolle: 'parent')
    ..elternSchalter = schalter;
  final env = TestUmgebung(server);
  await env.angemeldet();
  final speicher = MemorySchluesselSpeicher();
  final crypto = FakeCryptoProvider();
  env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => crypto), schluesselSpeicherProvider.overrideWithValue(speicher)]);
  final seeds = Uint8List.fromList(List.generate(64, (i) => i + 1));
  if (schluessel) await speicher.schreiben(personenschluesselName(fixIdAdmin), seeds);
  final k = _schluessel(crypto, seeds);
  srv.setzeSchluessel(fixIdAdmin, enc: k.$1, sign: k.$2, version: 1);
  final m = _schluessel(crypto, Uint8List.fromList(List.generate(64, (i) => 100 + i)));
  srv.setzeSchluessel(_mama, enc: m.$1, sign: m.$2, version: 1);
  return _Aufbau(env, srv, server, speicher);
}

Future<void> _zurVerschluesselung(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Verschlüsselung');
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    testWidgets('Ohne Schalter des Servers gibt es nichts davon, auch nicht im Profil ($s)', (tester) async {
      final a = await _aufbau(rolle: 'child', schalter: false);
      await starteApp(tester, a.env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      expect(find.text('eltern-hilfe aktiv'), findsNothing);
      await tippeText(tester, 'Verschlüsselung');
      expect(find.text('Eltern-Wiederherstellung'), findsNothing);
      expect(find.text('Kindern helfen'), findsNothing);
      expect(a.server.anfragen('GET /me/guardian-escrow'), isEmpty);
    });

    testWidgets('Kind: erlauben (erst nach Zustimmung), Pille im Profil, aktualisieren und zurücknehmen ($s)', (tester) async {
      final a = await _aufbau(rolle: 'child');
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      expect(find.text('Eltern-Wiederherstellung'), findsOneWidget);
      expect(find.textContaining('aus · eltern helfen lassen'), findsOneWidget);
      pruefeLayout(tester, 'Verschlüsselung mit Eltern-Zeile');

      await tippeText(tester, 'Eltern-Wiederherstellung');
      expect(find.textContaining('Du erlaubst es einmal'), findsOneWidget);
      final knopf = find.widgetWithText(FilledButton, 'Eltern erlauben, mir zu helfen');
      expect(tester.widget<FilledButton>(knopf).onPressed, isNull, reason: 'ohne Zustimmung nicht');
      pruefeLayout(tester, 'Eltern-Wiederherstellung aus');
      await tippe(tester, find.byType(CheckboxListTile));
      expect(tester.widget<FilledButton>(knopf).onPressed, isNotNull);
      await tippe(tester, knopf);
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Deine Eltern (Mama) können dir jetzt helfen'), findsOneWidget);
      expect(a.srv.hinterlegungen[_kind]!.keys, [_mama]);
      expect(find.text('aktiv'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Hinterlegung aktualisieren'), findsOneWidget);
      pruefeLayout(tester, 'Eltern-Wiederherstellung aktiv');

      // Profil: Pille für das Kinder-Konto
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.text('eltern-hilfe aktiv'), findsOneWidget);
      pruefeLayout(tester, 'Profil mit Pille');

      // zurücknehmen: Rückfrage, dann aus
      await tippeText(tester, 'Verschlüsselung');
      await tippeText(tester, 'Eltern-Wiederherstellung');
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Zurücknehmen'));
      expect(find.text('Eltern-Wiederherstellung zurücknehmen?'), findsOneWidget);
      pruefeLayout(tester, 'Rückfrage');
      await tippe(tester, find.widgetWithText(TextButton, 'Zurücknehmen'));
      await warte(tester);
      expect(find.textContaining('zurückgenommen'), findsOneWidget);
      expect(a.srv.hinterlegungen[_kind] ?? {}, isEmpty);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.text('eltern-hilfe aktiv'), findsNothing);
    });

    testWidgets('Gerät ohne Schlüssel: Eltern um Hilfe bitten, Wartefrist wird erklärt, Abbrechen ($s)', (tester) async {
      final a = await _aufbau(rolle: 'child', schluessel: false);
      a.srv.hinterlegungEinspielen(_kind, _mama);
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      expect(find.text('Dieses Gerät ist nicht verbunden'), findsOneWidget);
      expect(find.text('Von meinen Eltern zurückholen'), findsOneWidget);
      pruefeLayout(tester, 'Gerät nicht verbunden mit Eltern-Knopf');
      await tippeText(tester, 'Von meinen Eltern zurückholen');
      expect(find.text('Meine Eltern um Hilfe bitten'), findsOneWidget);
      expect(find.text('Hinterlegung aktualisieren'), findsNothing, reason: 'ohne Schlüssel auf dem Gerät nichts zu aktualisieren');
      pruefeLayout(tester, 'Eltern um Hilfe bitten');
      await tippe(tester, find.widgetWithText(FilledButton, 'Meine Eltern um Hilfe bitten'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Deine Anfrage läuft. Deine Eltern wurden benachrichtigt'), findsOneWidget);
      expect(a.srv.anfrageZustaende(), ['pending']);
      pruefeLayout(tester, 'Anfrage läuft');
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Anfrage abbrechen'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(a.srv.anfrageZustaende(), ['cancelled']);
      expect(find.textContaining('Die Anfrage wurde abgebrochen'), findsWidgets);
      expect(find.text('Meine Eltern um Hilfe bitten'), findsOneWidget, reason: 'danach ist eine neue Anfrage möglich');
    });

    testWidgets('Gerät ohne Schlüssel und ohne Zustimmung: nur der Hinweis, kein Knopf zum Bitten ($s)', (tester) async {
      final a = await _aufbau(rolle: 'child', schluessel: false);
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      await tippeText(tester, 'Von meinen Eltern zurückholen');
      expect(find.textContaining('erst helfen, wenn du es vorher erlaubt hast'), findsOneWidget);
      expect(find.text('Meine Eltern um Hilfe bitten'), findsNothing);
      pruefeLayout(tester, 'Ohne Zustimmung');
    });

    Future<_Aufbau> elternAufbau({required String zustand, int bereitIn = 20, String? bearbeiter}) async {
      final a = await _aufbau(rolle: 'parent');
      final kind2 = '55555555-5555-4555-8555-555555555555';
      a.srv.person(kind2, 'Ben', rolle: 'child');
      a.srv.setzeSchluessel(kind2, enc: base64urlKodieren(List.filled(32, 3)), sign: base64urlKodieren(List.filled(32, 4)), version: 1);
      a.srv.hinterlegungEinspielen(kind2, fixIdAdmin);
      a.srv.anfrageEinspielen(kind2, zustand: zustand, bereitIn: bereitIn, elternId: bearbeiter);
      return a;
    }

    testWidgets('Elternteil: Kinder und Anfrage in der Wartefrist, noch nichts zu tun ($s)', (tester) async {
      final a = await elternAufbau(zustand: 'pending');
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      expect(find.text('Kindern helfen'), findsOneWidget);
      expect(find.text('1 anfrage offen'), findsOneWidget);
      expect(find.text('Eltern-Wiederherstellung'), findsNothing, reason: 'Erwachsene sehen die Kinder-Seite nicht');
      pruefeLayout(tester, 'Verschlüsselung mit Eltern-Hilfe-Zeile');
      await tippeText(tester, 'Kindern helfen');
      expect(find.text('Ben bittet um Hilfe'), findsOneWidget);
      expect(find.textContaining('Wartefrist bis'), findsOneWidget);
      expect(find.text('Anfrage übernehmen'), findsNothing, reason: 'vor Ablauf der Wartefrist nicht');
      pruefeLayout(tester, 'Anfrage wartet');
      // ablehnen geht immer
      await tippe(tester, find.widgetWithText(TextButton, 'Ablehnen'));
      await warte(tester);
      expect(a.srv.anfrageZustaende(), ['declined']);
    });

    testWidgets('Elternteil: nach der Wartefrist übernehmen; dann wartet es auf das Kind ($s)', (tester) async {
      final a = await elternAufbau(zustand: 'pending', bereitIn: -1);
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      await tippeText(tester, 'Kindern helfen');
      expect(find.textContaining('Sprich zuerst mit dem Kind'), findsOneWidget);
      pruefeLayout(tester, 'Anfrage bereit');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anfrage übernehmen'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(a.srv.anfrageZustaende(), ['challenged']);
      expect(find.textContaining('Du hast sie übernommen'), findsOneWidget);
      expect(find.textContaining('Du hast die Anfrage übernommen'), findsOneWidget);
      pruefeLayout(tester, 'Übernommen');
    });

    testWidgets('Elternteil: Code eingeben; ungültige Eingabe wird erklärt, ein nicht passender Code lehnt die Anfrage ab ($s)', (tester) async {
      final a = await elternAufbau(zustand: 'revealed', bearbeiter: fixIdAdmin);
      // dieses Gerät hat die Anfrage übernommen und dabei Verpflichtung und Zufallszahl festgehalten (Werte wie im Fake)
      await a.speicher.schreiben(
        elternUebernahmeName(fixIdAdmin, '00000000-0000-4000-8000-000000000001'),
        Uint8List.fromList(utf8.encode(jsonEncode({'commit': 'c' * 43, 'r': 'A' * 22, 'kind': '55555555-5555-4555-8555-555555555555', 'versuche': 0}))),
      );
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      await tippeText(tester, 'Kindern helfen');
      expect(find.text('Code des Kindes (8 Ziffern)'), findsOneWidget);
      pruefeLayout(tester, 'Code eingeben');
      await tippe(tester, find.widgetWithText(FilledButton, 'Freigeben'));
      await warte(tester);
      expect(find.textContaining('Bitte gib den 8-stelligen Code'), findsOneWidget);
      expect(a.srv.anfrageZustaende(), ['revealed'], reason: 'nichts freigegeben, nichts abgelehnt');
      await eingeben(tester, 'Code des Kindes (8 Ziffern)', '12345678');
      await tippe(tester, find.widgetWithText(FilledButton, 'Freigeben'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Die Angaben des Kindes passen nicht zusammen'), findsOneWidget);
      expect(a.srv.anfrageZustaende(), ['declined']);
      pruefeLayout(tester, 'Abgelehnt');
    });

    testWidgets('Elternteil: eine Anfrage, die ein anderes Elternteil bearbeitet, zeigt nur den Stand ($s)', (tester) async {
      final a = await elternAufbau(zustand: 'revealed', bearbeiter: _mama);
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      await tippeText(tester, 'Kindern helfen');
      expect(find.textContaining('Mama kümmert sich darum'), findsOneWidget);
      expect(find.text('Code des Kindes (8 Ziffern)'), findsNothing);
      pruefeLayout(tester, 'Anderes Elternteil bearbeitet');
    });

    testWidgets('Elternteil: Anfrage auf einem anderen Gerät übernommen (kein Vermerk hier): Freigeben erklärt es und gibt nichts frei ($s)', (tester) async {
      final a = await elternAufbau(zustand: 'revealed', bearbeiter: fixIdAdmin);
      await starteApp(tester, a.env, skala: skala);
      await _zurVerschluesselung(tester);
      await tippeText(tester, 'Kindern helfen');
      await eingeben(tester, 'Code des Kindes (8 Ziffern)', '12345678');
      await tippe(tester, find.widgetWithText(FilledButton, 'Freigeben'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('auf einem anderen Gerät übernommen'), findsOneWidget);
      expect(a.srv.anfrageZustaende(), ['revealed']);
      pruefeLayout(tester, 'Anderes Gerät');
    });
  }
}
