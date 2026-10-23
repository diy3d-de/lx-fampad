// Oberfläche der Verschlüsselung (Profil > Verschlüsselung): Einrichtung samt Wiederherstellungsschlüssel (verdecken und ganz eintippen), Status,
// Gerät verbinden, Warnung bei Schlüsselwechsel. 360 px Breite, Textskala 1.0 und 1.5, Touch-Ziele >= 44 px.
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

const _ben = fixIdKind;

String _key(int n) => base64urlKodieren(Uint8List.fromList(List.filled(32, n)));

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.speicher);
}

Future<_Aufbau> _aufbau({bool bensSchluessel = false}) async {
  final server = standardServer();
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna')
    ..person(_ben, 'Ben');
  if (bensSchluessel) srv.setzeSchluessel(_ben, enc: _key(1), sign: _key(2), version: 1);
  final env = TestUmgebung(server);
  await env.angemeldet();
  final speicher = MemorySchluesselSpeicher();
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
    schluesselSpeicherProvider.overrideWithValue(speicher),
  ]);
  return _Aufbau(env, srv, speicher);
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

    testWidgets('Einrichtung bis zur Sicherung, danach Status "Eingerichtet" ($s)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Nicht eingerichtet'), findsOneWidget);
      pruefeLayout(tester, 'Verschlüsselung: nicht eingerichtet');

      await tippeText(tester, 'Verschlüsselung einrichten');
      expect(find.text('Wiederherstellungsschlüssel'), findsWidgets);
      pruefeLayout(tester, 'Wiederherstellungsschlüssel');
      // 14 Gruppen sichtbar
      final gruppen = [
        for (final w in tester.widgetList<Text>(find.byType(Text)))
          if (RegExp(r'^[A-Z2-7]{4}$').hasMatch(w.data ?? '')) w.data!,
      ];
      expect(gruppen, hasLength(14));
      // Der Schlüssel ist sichtbar: noch keine Kontrolle; erst "notiert", dann verdeckt und ganz eintippen
      expect(find.byType(TextField), findsNothing);
      await tippeText(tester, 'Ich habe ihn notiert, weiter');
      final weiter = find.widgetWithText(FilledButton, 'Stimmt, jetzt sichern');
      expect(tester.widget<FilledButton>(weiter).onPressed, isNull);
      final feld = find.byType(TextField);
      expect(feld, findsOneWidget);
      // Falsche Eingabe lässt den Knopf gesperrt
      await tester.enterText(feld, 'ZZZZ');
      await tester.pump();
      expect(tester.widget<FilledButton>(weiter).onPressed, isNull);
      // der ganze Schlüssel, klein geschrieben
      await tester.enterText(feld, gruppen.join('-').toLowerCase());
      await tester.pump();
      expect(tester.widget<FilledButton>(weiter).onPressed, isNotNull);
      await tippe(tester, weiter);

      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.text('aktiv'), findsOneWidget, reason: 'die Sicherung liegt jetzt bestätigt beim Server');
      expect(find.textContaining('sicherung liegt beim server (seit '), findsOneWidget);
      expect(find.text('Neues Gerät verbinden'), findsOneWidget);
      expect(a.srv.gespeichert(fixIdAdmin).contains('"backup":null'), isFalse, reason: 'Sicherung liegt beim Server');
      expect(find.textContaining('// SICHERHEITSCODE'), findsOneWidget);
      pruefeLayout(tester, 'Verschlüsselung: eingerichtet');
    });

    testWidgets('Einrichtung: "Später sichern" lässt die Einrichtung ohne Sicherung stehen ($s)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Verschlüsselung einrichten');
      await tippeText(tester, 'Später sichern');
      await tippeText(tester, 'Später');
      expect(find.text('Eingerichtet'), findsOneWidget);
      expect(find.textContaining('keine sicherung · jetzt erzeugen'), findsOneWidget);
      expect(find.textContaining('Sicherung offen'), findsOneWidget, reason: 'sichtbare Markierung nach "Später sichern"');
      expect(find.text('aktiv'), findsNothing);
      pruefeLayout(tester, 'Verschlüsselung: ohne Sicherung');
    });

    testWidgets('Neues Gerät verbinden zeigt QR und Code ($s)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Verschlüsselung einrichten');
      await tippeText(tester, 'Später sichern');
      await tippeText(tester, 'Später');
      await tippeText(tester, 'Neues Gerät verbinden');
      expect(find.textContaining('noch '), findsOneWidget);
      final code = [
        for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText)))
          if (RegExp(r'^([A-Z2-7]{4}-){13}[A-Z2-7]{4}$').hasMatch(w.data ?? '')) w.data!,
      ];
      expect(code, hasLength(1));
      pruefeLayout(tester, 'Gerät verbinden: Anzeige');
      // 2 Minuten später ist der Code abgelaufen
      await tester.pump(const Duration(seconds: 125));
      expect(find.text('Der Code ist abgelaufen.'), findsOneWidget);
      pruefeLayout(tester, 'Gerät verbinden: abgelaufen');
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
    });

    testWidgets('Gerät ohne Schlüssel: verbinden per Code oder Wiederherstellungsschlüssel ($s)', (tester) async {
      final a = await _aufbau();
      a.srv.setzeSchluessel(fixIdAdmin, enc: _key(5), sign: _key(6), version: 1);
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Dieses Gerät ist nicht verbunden'), findsOneWidget);
      pruefeLayout(tester, 'Gerät nicht verbunden');
      // ohne Sicherung ist der Weg über den Wiederherstellungsschlüssel gesperrt
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Mit Wiederherstellungsschlüssel verbinden')).onPressed, isNull);

      await tippeText(tester, 'Mit anderem Gerät verbinden');
      pruefeLayout(tester, 'Gerät verbinden: Eingabe');
      await tippeText(tester, 'Mit Code verbinden');
      expect(find.textContaining('scanne den QR-Code oder gib den Code ein'), findsOneWidget);
      await eingeben(tester, 'Code (14 Gruppen)', 'ABCD-EFGH');
      await tippeText(tester, 'Mit Code verbinden');
      expect(find.textContaining('Länge'), findsOneWidget);
      pruefeLayout(tester, 'Gerät verbinden: Fehler');
    });

    testWidgets('Warnung bei Schlüsselwechsel einer Person: erst nach Bestätigung akzeptiert ($s)', (tester) async {
      final a = await _aufbau(bensSchluessel: true);
      // Dieses Gerät kennt Bens früheren Schlüssel
      await a.speicher.schreiben(
        'e2ee.vertrauen.$fixIdAdmin',
        utf8Bytes(jsonEncode({_ben: {'e': _key(9), 's': _key(8), 'v': 1}})),
      );
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      expect(find.text('Der Schlüssel von Ben hat sich geändert.'), findsOneWidget);
      pruefeLayout(tester, 'Warnung');
      await tippeText(tester, 'Neuen Schlüssel akzeptieren');
      expect(find.text('Neuen Schlüssel akzeptieren?'), findsOneWidget);
      pruefeLayout(tester, 'Warnung: Bestätigung');
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Neuen Schlüssel akzeptieren')));
      expect(find.text('Der Schlüssel von Ben hat sich geändert.'), findsNothing);
    });
  }

  for (final skala in [1.0, 1.5]) {
    testWidgets('Abmelden ohne Sicherung: nur der ruhige Hinweis, keine Warnung, kein "Erst sichern" (360 px, Textskala $skala)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Verschlüsselung einrichten');
      await tippeText(tester, 'Später sichern');
      await tippeText(tester, 'Später');
      await tippe(tester, find.byTooltip('Zurück'));
      await tippeText(tester, 'Abmelden');
      expect(find.textContaining('Dein Schlüssel bleibt auf diesem Gerät'), findsOneWidget);
      expect(find.textContaining('nicht gesichert'), findsNothing);
      expect(find.text('Erst sichern'), findsNothing);
      expect(find.text('Trotzdem abmelden'), findsNothing);
      pruefeLayout(tester, 'Abmelden-Dialog mit Hinweis');
      await tippeText(tester, 'Abbrechen');
      expect(a.env.geloescht, 0);
    });

    testWidgets('Abmelden mit Sicherung: derselbe ruhige Hinweis (360 px, Textskala $skala)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _zurSeite(tester);
      await tippeText(tester, 'Verschlüsselung einrichten');
      final gruppen = [
        for (final w in tester.widgetList<Text>(find.byType(Text)))
          if (RegExp(r'^[A-Z2-7]{4}$').hasMatch(w.data ?? '')) w.data!,
      ];
      await tippeText(tester, 'Ich habe ihn notiert, weiter');
      await tester.enterText(find.byType(TextField), gruppen.join('-'));
      await tester.pump();
      await tippe(tester, find.widgetWithText(FilledButton, 'Stimmt, jetzt sichern'));
      await tippe(tester, find.byTooltip('Zurück'));
      await tester.pump(const Duration(seconds: 6)); // Hinweisleiste (SnackBar) verdeckt sonst den Knopf
      await warte(tester);
      await tippeText(tester, 'Abmelden');
      expect(find.textContaining('Dein Schlüssel bleibt auf diesem Gerät'), findsOneWidget);
      expect(find.text('Erst sichern'), findsNothing);
      pruefeLayout(tester, 'Abmelden-Dialog mit Sicherung');
    });
  }

  testWidgets('Profil zeigt die Zeile "Verschlüsselung" mit Warnhinweis bei Schlüsselwechsel', (tester) async {
    final a = await _aufbau(bensSchluessel: true);
    await a.speicher.schreiben('e2ee.vertrauen.$fixIdAdmin', utf8Bytes(jsonEncode({_ben: {'e': _key(9), 's': _key(8), 'v': 1}})));
    await starteApp(tester, a.env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippeText(tester, 'Sicherheit');
    expect(find.text('Verschlüsselung'), findsOneWidget);
    expect(find.text('Warnung'), findsOneWidget);
    pruefeLayout(tester, 'Profil mit Warnung');
  });

  test('Personenschlüssel-Name enthält die Person', () {
    expect(personenschluesselName('abc'), 'e2ee.pk.abc');
  });
}
