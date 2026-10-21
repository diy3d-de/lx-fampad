// P0 "Kein Datenverlust" (Oberfläche, Profil > Verschlüsselung): ehrliche Anzeige (grün nur mit bestätigter Sicherung beim Server, sonst gelb "offen"),
// "Gerät abgeben – alles löschen" (gesperrt ohne bestätigte Sicherung, Haken und getipptes Wort), Notfallbereich mit Checkliste, kein "Neuen Schlüssel erzeugen" auf
// der Seite "Gerät nicht verbunden", aufbewahrte alte Schlüssel (Quarantäne), Hinweis auf den Web-Speicher, Wiederherstellungsschlüssel verdecken und vollständig
// eintippen. 360 px, Textskala 1.0 und 1.5, Touch-Ziele 44 px, Semantics.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart' show EinstellungsZeile;
import 'package:lx_fampad/features/profile/wiederherstellungsschluessel_screen.dart';
import 'package:lx_fampad/features/profile/wort_bestaetigung.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

/// Schlüsselspeicher mit steuerbarer Antwort auf die Frage nach dem dauerhaften Browser-Speicher.
class _Speicher extends MemorySchluesselSpeicher {
  SpeicherDauer dauer = SpeicherDauer.nichtZutreffend;

  @override
  Future<SpeicherDauer> dauerhaftigkeit() async => dauer;
}

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final _Speicher speicher;
  _Aufbau(this.env, this.srv, this.speicher);
}

Future<_Aufbau> _aufbau({bool pwServer = false, SpeicherDauer dauer = SpeicherDauer.nichtZutreffend}) async {
  final server = standardServer()
    ..json('POST /auth/logout', {'ok': true})
    ..json('POST /auth/logout-all', {'ok': true});
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)..person(fixIdAdmin, 'Anna');
  srv.pwSchalter = pwServer;
  final env = TestUmgebung(server)..wiperMitVerschluesselung = true;
  await env.angemeldet();
  final speicher = _Speicher()..dauer = dauer;
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
    schluesselSpeicherProvider.overrideWithValue(speicher),
  ]);
  return _Aufbau(env, srv, speicher);
}

/// Einrichtung ohne Sicherung des Wiederherstellungsschlüssels ("Später sichern"), danach zurück im Profil.
Future<void> _einrichten(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Verschlüsselung');
  await tippeText(tester, 'Verschlüsselung einrichten');
  await tippeText(tester, 'Später sichern');
  await tippe(tester, find.widgetWithText(TextButton, 'Später'));
  await tippe(tester, find.byTooltip('Zurück'));
}

/// Von der Profilseite zur Seite "Verschlüsselung".
Future<void> _zurSeite(WidgetTester tester) async => tippeText(tester, 'Verschlüsselung');

/// Die App neu starten (der Zustand im Arbeitsspeicher geht verloren, der Schlüsselspeicher bleibt).
Future<void> _neustart(WidgetTester tester, _Aufbau a, double skala) async {
  await tester.pumpWidget(const SizedBox());
  await starteApp(tester, a.env, skala: skala);
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
}

/// Ein Semantics-Widget mit genau diesem Beschriftungstext (für Screenreader).
Finder _semantik(String label) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);

Future<bool> _schluesselDa(_Aufbau a) async => await a.speicher.lesen(personenschluesselName(fixIdAdmin)) != null;

TextButton _textKnopf(WidgetTester tester, String text) => tester.widget<TextButton>(find.widgetWithText(TextButton, text));

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    group('Ehrliche Anzeige ($s)', () {
      testWidgets('ohne bestätigte Sicherung: gelb "offen", nie "aktiv", sichtbare Markierung "Sicherung offen" (auch im Profil)', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        // Profil-Zeile "Verschlüsselung" (andere Zeilen des Profils dürfen "aktiv" sein)
        final zeile = find.ancestor(of: find.text('Verschlüsselung'), matching: find.byType(EinstellungsZeile));
        expect(find.descendant(of: zeile, matching: find.text('offen')), findsOneWidget);
        expect(find.descendant(of: zeile, matching: find.text('aktiv')), findsNothing);
        await _zurSeite(tester);
        expect(find.text('offen'), findsWidgets);
        expect(find.text('aktiv'), findsNothing);
        expect(find.textContaining('Sicherung offen: Beim Server liegt keine bestätigte Sicherung'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Jetzt sichern'), findsOneWidget);
        expect(find.textContaining('nicht gesichert'), findsNothing);
        expect(find.textContaining('keine sicherung · jetzt erzeugen'), findsOneWidget);
        expect(_semantik('Sicherung offen'), findsOneWidget);
        pruefeLayout(tester, 'Verschlüsselung ohne bestätigte Sicherung');
      });

      testWidgets('mit bestätigter Sicherung beim Server: grün "aktiv", "liegt beim server (seit …)", nie "gesichert"', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.sicherungEinspielen(fixIdAdmin);
        await _zurSeite(tester);
        expect(find.text('aktiv'), findsOneWidget);
        expect(find.textContaining('Sicherung offen'), findsNothing);
        expect(find.textContaining('sicherung liegt beim server (seit '), findsOneWidget);
        expect(find.textContaining('gesichert'), findsNothing);
        pruefeLayout(tester, 'Verschlüsselung mit bestätigter Sicherung');
      });

      testWidgets('älterer Server ohne die neuen Felder: nie "aktiv" (unbekannt ist nicht gesichert)', (tester) async {
        final a = await _aufbau();
        a.srv.neueFelder = false;
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.sicherungEinspielen(fixIdAdmin);
        await _zurSeite(tester);
        expect(find.text('aktiv'), findsNothing);
        expect(find.text('offen'), findsWidgets);
        expect(find.textContaining('Sicherung offen'), findsOneWidget);
        expect(find.textContaining('stand unbestätigt'), findsOneWidget);
      });

      testWidgets('Passwort-Sicherung: "liegt beim server (seit …)" ohne grüne Pille; ohne Server-Stand "server meldet keinen stand"', (tester) async {
        final a = await _aufbau(pwServer: true);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.pwEinspielen(fixIdAdmin, 'blob', version: a.srv.schluesselVersion(fixIdAdmin));
        await _zurSeite(tester);
        expect(find.textContaining('liegt beim server (seit '), findsWidgets);
        expect(find.text('aktiv'), findsOneWidget, reason: 'nur die Hauptzeile, nie die einzelne Sicherung');
        pruefeLayout(tester, 'Passwort-Sicherung liegt beim Server');
      });
    });

    group('Gerät abgeben ($s)', () {
      testWidgets('ohne bestätigte Sicherung gesperrt, mit Erklärung und dem Weg "Sicherung anlegen"; nichts wird gelöscht', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await _zurSeite(tester);
        expect(find.textContaining('Gesperrt: Beim Server liegt keine bestätigte Sicherung'), findsOneWidget);
        final knopf = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Gerät abgeben – alles löschen'));
        expect(knopf.onPressed, isNull);
        expect(find.widgetWithText(OutlinedButton, 'Sicherung anlegen'), findsOneWidget);
        await tester.tap(find.text('Gerät abgeben – alles löschen'), warnIfMissed: false);
        await warte(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(await _schluesselDa(a), isTrue);
        expect(a.srv.server.anfragen('POST /auth/logout'), isEmpty);
        pruefeLayout(tester, 'Gerät abgeben gesperrt');
      });

      testWidgets('Server nicht erreichbar: gesperrt ("Stand nicht prüfbar"), nie gesichert angenommen', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.sicherungEinspielen(fixIdAdmin);
        a.srv.server.on('GET /me/keys', (_) => fehler(500, 'server_error'));
        await _zurSeite(tester);
        // ohne Stand beim Server gibt es keinen Bereich "Gerät abgeben" mit Freigabe
        expect(find.text('Gerät abgeben – alles löschen'), findsNothing);
        expect(await _schluesselDa(a), isTrue);
      });

      testWidgets('mit bestätigter Sicherung: erst Haken und getipptes Wort, dann Schlüssel UND lokale Daten weg und abgemeldet', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.sicherungEinspielen(fixIdAdmin);
        await a.speicher.schreiben('e2ee.quarantaene.$fixIdAdmin.1700000000000', Uint8List.fromList([1, 2, 3]));
        await _zurSeite(tester);
        expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Gerät abgeben – alles löschen')).onPressed, isNotNull);
        await tippeText(tester, 'Gerät abgeben – alles löschen');
        expect(find.text('Gerät abgeben?'), findsOneWidget);
        expect(_textKnopf(tester, 'Gerät abgeben').onPressed, isNull, reason: 'noch kein Haken und kein Wort');
        pruefeLayout(tester, 'Gerät abgeben: Dialog');
        // nur das Wort, ohne Haken: noch gesperrt
        await tester.enterText(find.byType(TextField).last, 'löschen');
        await tester.pump();
        expect(_textKnopf(tester, 'Gerät abgeben').onPressed, isNull);
        // Haken, falsches Wort: gesperrt
        await tippe(tester, find.byType(CheckboxListTile));
        await tester.enterText(find.byType(TextField).last, 'loeschen');
        await tester.pump();
        expect(_textKnopf(tester, 'Gerät abgeben').onPressed, isNull);
        await tester.enterText(find.byType(TextField).last, ' Löschen ');
        await tester.pump();
        expect(_textKnopf(tester, 'Gerät abgeben').onPressed, isNotNull);
        await tippe(tester, find.widgetWithText(TextButton, 'Gerät abgeben'));
        expect(find.text('Willkommen zurück'), findsOneWidget);
        expect(a.env.geloescht, 1, reason: 'lokale Daten sind geleert');
        expect(a.srv.server.anfragen('POST /auth/logout'), hasLength(1));
        expect(await a.speicher.namenMitPraefix('e2ee.pk.$fixIdAdmin'), isEmpty);
        expect(await a.speicher.namenMitPraefix('e2ee.quarantaene.$fixIdAdmin.'), isEmpty);
        expect(a.srv.gespeichert(fixIdAdmin), contains('"backup":"'), reason: 'die Sicherung beim Server bleibt');
      });

      testWidgets('"Abbrechen" im Dialog löscht nichts', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.sicherungEinspielen(fixIdAdmin);
        await _zurSeite(tester);
        await tippeText(tester, 'Gerät abgeben – alles löschen');
        await tippe(tester, find.byType(CheckboxListTile));
        await tester.enterText(find.byType(TextField).last, 'löschen');
        await tester.pump();
        await tippeText(tester, 'Abbrechen');
        expect(find.byType(AlertDialog), findsNothing);
        expect(await _schluesselDa(a), isTrue);
        expect(a.env.geloescht, 0);
        expect(a.srv.server.anfragen('POST /auth/logout'), isEmpty);
      });
    });

    group('Notfallbereich und "Gerät nicht verbunden" ($s)', () {
      testWidgets('"Neuen Schlüssel erzeugen" nur hinter Checkliste (4 Haken) und getipptem Wort', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await _zurSeite(tester);
        await tippeText(tester, 'Neuen Schlüssel erzeugen …');
        expect(find.text('Neuen Schlüssel erzeugen?'), findsOneWidget);
        expect(find.byType(CheckboxListTile), findsNWidgets(4));
        expect(find.text('Ich habe keinen Wiederherstellungsschlüssel.'), findsOneWidget);
        expect(find.text('Ich habe kein anderes Gerät mit meinem Schlüssel.'), findsOneWidget);
        expect(find.text('Ich kenne kein Sicherungs-Passwort.'), findsOneWidget);
        expect(find.text('Alte Chats gehen unwiderruflich verloren.'), findsOneWidget);
        pruefeLayout(tester, 'Notfall-Checkliste');
        expect(_textKnopf(tester, 'Neuen Schlüssel erzeugen').onPressed, isNull);
        // drei von vier Haken und das richtige Wort: noch gesperrt
        for (var i = 0; i < 3; i++) {
          await tippe(tester, find.byType(CheckboxListTile).at(i));
        }
        await tester.enterText(find.byType(TextField).last, 'ersetzen');
        await tester.pump();
        expect(_textKnopf(tester, 'Neuen Schlüssel erzeugen').onPressed, isNull);
        await tippe(tester, find.byType(CheckboxListTile).at(3));
        expect(_textKnopf(tester, 'Neuen Schlüssel erzeugen').onPressed, isNotNull);
        // abbrechen: es ging nichts an den Server
        await tippeText(tester, 'Abbrechen');
        expect(a.srv.server.anfragen('PUT /me/keys'), isEmpty);
        expect(await _schluesselDa(a), isTrue);
      });

      testWidgets('Seite "Gerät nicht verbunden": kein "Neuen Schlüssel erzeugen", dafür die Wege zum Verbinden', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await a.speicher.loeschen(personenschluesselName(fixIdAdmin)); // ein anderes Gerät: der Schlüssel liegt nur woanders
        await _neustart(tester, a, skala);
        await _zurSeite(tester);
        expect(find.text('Dieses Gerät ist nicht verbunden'), findsOneWidget);
        expect(find.textContaining('Neuen Schlüssel erzeugen'), findsNothing);
        expect(find.text('// notfall'), findsNothing);
        expect(find.text('Mit anderem Gerät verbinden'), findsOneWidget);
        expect(find.text('Gerät abgeben – alles löschen'), findsNothing, reason: 'es liegt nichts zu löschen auf diesem Gerät');
        pruefeLayout(tester, 'Gerät nicht verbunden');
      });
    });

    group('Aufbewahrte alte Schlüssel ($s)', () {
      testWidgets('werden als "Alter Schlüssel auf diesem Gerät" gezeigt; Verwerfen nur mit getipptem Wort', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        final name = '${quarantaenePraefix(fixIdAdmin)}1700000000000';
        await a.speicher.schreiben(name, Uint8List.fromList([1, 2, 3]));
        await _zurSeite(tester);
        expect(find.textContaining('Alter Schlüssel auf diesem Gerät · seit '), findsOneWidget);
        expect(find.textContaining('nicht benutzt; du musst nichts tun'), findsOneWidget);
        pruefeLayout(tester, 'Quarantäne-Eintrag');
        await tippeText(tester, 'Verwerfen');
        expect(find.text('Alten Schlüssel verwerfen?'), findsOneWidget);
        expect(_textKnopf(tester, 'Endgültig verwerfen').onPressed, isNull);
        await tippeText(tester, 'Abbrechen');
        expect(await a.speicher.lesen(name), isNotNull, reason: 'abgebrochen: noch da');
        await tippeText(tester, 'Verwerfen');
        await tester.enterText(find.byType(TextField).last, 'löschen');
        await tester.pump();
        await tippe(tester, find.widgetWithText(TextButton, 'Endgültig verwerfen'));
        expect(await a.speicher.lesen(name), isNull);
        expect(find.textContaining('Alter Schlüssel auf diesem Gerät · seit '), findsNothing);
      });

      testWidgets('abweichender Schlüssel: "Neu verbinden" löscht ihn nicht, sondern bewahrt ihn auf', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        final lokal = await a.speicher.lesen(personenschluesselName(fixIdAdmin));
        final anderer = base64urlKodieren(Uint8List.fromList(List.filled(32, 7)));
        a.srv.setzeSchluessel(fixIdAdmin, enc: anderer, sign: anderer, version: 2);
        await _zurSeite(tester);
        expect(find.textContaining('Der bisherige Schlüssel wird dabei nicht gelöscht'), findsOneWidget);
        pruefeLayout(tester, 'Schlüssel weicht ab');
        await tippeText(tester, 'Dieses Gerät neu verbinden');
        expect(find.textContaining('nicht gelöscht'), findsWidgets);
        await tippe(tester, find.widgetWithText(TextButton, 'Neu verbinden'));
        expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
        final q = await a.speicher.namenMitPraefix(quarantaenePraefix(fixIdAdmin));
        expect(q, hasLength(1));
        expect(await a.speicher.lesen(q.single), lokal, reason: 'unverändert aufbewahrt');
        expect(find.textContaining('Alter Schlüssel auf diesem Gerät · seit '), findsOneWidget);
      });
    });

    group('Web-Speicher ($s)', () {
      testWidgets('Browser verweigert die dauerhafte Ablage: Hinweis; unbekannt: auch; gewährt oder Android: keiner', (tester) async {
        for (final (dauer, hinweis) in [
          (SpeicherDauer.verweigert, true),
          (SpeicherDauer.unbekannt, true),
          (SpeicherDauer.gewaehrt, false),
          (SpeicherDauer.nichtZutreffend, false),
        ]) {
          final a = await _aufbau(dauer: dauer);
          await tester.pumpWidget(const SizedBox());
          await starteApp(tester, a.env, skala: skala);
          await _einrichten(tester);
          await _zurSeite(tester);
          expect(find.textContaining('Der Browser darf diese Daten löschen'), hinweis ? findsOneWidget : findsNothing, reason: '$dauer');
          if (hinweis) {
            expect(find.textContaining('Installiere die App oder verbinde ein zweites Gerät'), findsOneWidget);
            pruefeLayout(tester, 'Browser-Hinweis');
          }
        }
      });
    });
  }

  group('Wiederherstellungsschlüssel: verdecken und vollständig eintippen (360 px)', () {
    final schluessel = Uint8List.fromList(List.generate(32, (i) => i * 7 + 3));

    Future<_Aufbau> zeigen(WidgetTester tester, double skala) async {
      final a = await _aufbau();
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = a.env.container();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: WiederherstellungsschluesselScreen(einrichtung: Einrichtung(Uint8List.fromList(schluessel), 1)),
          ),
        ),
      );
      await warte(tester);
      return a;
    }

    List<String> gruppen(WidgetTester tester) => [
      for (final e in find.byType(Text).evaluate())
        if (RegExp(r'^[A-Z2-7]{4}$').hasMatch((e.widget as Text).data ?? '')) (e.widget as Text).data!,
    ];

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Anzeige, dann verdeckt: die Kontrolle gelingt nur mit dem ganzen Schlüssel (Textskala $skala)', (tester) async {
        await zeigen(tester, skala);
        final angezeigt = gruppen(tester);
        expect(angezeigt, hasLength(14), reason: 'der Schlüssel ist zu sehen');
        expect(find.byType(TextField), findsNothing, reason: 'noch keine Kontrolle, solange er angezeigt wird');
        pruefeLayout(tester, 'Schlüssel sichtbar');
        await tippeText(tester, 'Ich habe ihn notiert, weiter');
        // verdeckt: keine Gruppe mehr zu sehen, stattdessen das Eingabefeld
        expect(gruppen(tester), isEmpty);
        expect(find.text('Der Schlüssel ist jetzt verdeckt.'), findsOneWidget);
        expect(_semantik('Der Schlüssel ist verdeckt'), findsOneWidget);
        final knopf = find.widgetWithText(FilledButton, 'Stimmt, jetzt sichern');
        expect(tester.widget<FilledButton>(knopf).onPressed, isNull);
        pruefeLayout(tester, 'Schlüssel verdeckt');
        // zwei Gruppen reichen nicht
        await tester.enterText(find.byType(TextField), angezeigt.take(2).join('-'));
        await tester.pump();
        expect(tester.widget<FilledButton>(knopf).onPressed, isNull);
        // der ganze Schlüssel mit einem Tippfehler: Hinweis, kein Weiter
        final falsch = [...angezeigt]..[5] = angezeigt[5] == 'AAAA' ? 'BBBB' : 'AAAA';
        await tester.enterText(find.byType(TextField), falsch.join('-'));
        await tester.pump();
        expect(tester.widget<FilledButton>(knopf).onPressed, isNull);
        expect(find.textContaining('Das stimmt noch nicht'), findsOneWidget);
        // richtig, auch klein geschrieben und mit Leerzeichen
        await tester.enterText(find.byType(TextField), angezeigt.join(' ').toLowerCase());
        await tester.pump();
        expect(tester.widget<FilledButton>(knopf).onPressed, isNotNull);
        expect(find.textContaining('Das stimmt noch nicht'), findsNothing);
        // nochmal ansehen: Eingabe weg, Schlüssel wieder da
        await tippeText(tester, 'Schlüssel nochmal ansehen');
        expect(gruppen(tester), angezeigt);
        await tippeText(tester, 'Ich habe ihn notiert, weiter');
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
        pruefeLayout(tester, 'Schlüssel wieder verdeckt');
      });
    }

    testWidgets('"Später sichern" bleibt möglich und sagt, dass die Sicherung offen bleibt', (tester) async {
      await zeigen(tester, 1.0);
      await tippeText(tester, 'Später sichern');
      expect(find.textContaining('als "offen" markiert'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Später'), findsOneWidget);
      pruefeLayout(tester, 'Später sichern');
    });
  });

  testWidgets('Bestätigung per Wort: Dialog mit vier Haken bei 360 px und Textskala 2.0, Touch-Ziele und Beschriftung', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool? ergebnis;
    await tester.pumpWidget(
      MaterialApp(
        builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)), child: w!),
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => ergebnis = await wortBestaetigen(
                  c,
                  titel: 'Neuen Schlüssel erzeugen?',
                  text: 'Das ist der letzte Ausweg.',
                  haken: const ['Ich habe keinen Wiederherstellungsschlüssel.', 'Ich habe kein anderes Gerät mit meinem Schlüssel.', 'Ich kenne kein Sicherungs-Passwort.', 'Alte Chats gehen unwiderruflich verloren.'],
                  wort: 'ersetzen',
                  knopf: 'Neuen Schlüssel erzeugen',
                ),
                child: const Text('los'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(4));
    expect(find.textContaining('"ersetzen" eintippen'), findsOneWidget);
    pruefeLayout(tester, 'Wort-Bestätigung 2.0');
    await tester.tapAt(const Offset(5, 5)); // neben den Dialog tippen schließt ihn (barrierDismissible), ohne zu bestätigen
    await tester.pumpAndSettle();
    expect(ergebnis, isFalse);
  });

  testWidgets('Einrichtung: ganzer Weg über die Oberfläche, danach liegt die Sicherung beim Server und die Seite zeigt "aktiv"', (tester) async {
    final a = await _aufbau();
    await starteApp(tester, a.env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippeText(tester, 'Verschlüsselung');
    await tippeText(tester, 'Verschlüsselung einrichten');
    final gruppen = [
      for (final e in find.byType(Text).evaluate())
        if (RegExp(r'^[A-Z2-7]{4}$').hasMatch((e.widget as Text).data ?? '')) (e.widget as Text).data!,
    ];
    expect(gruppen, hasLength(14));
    await tippeText(tester, 'Ich habe ihn notiert, weiter');
    await tester.enterText(find.byType(TextField), gruppen.join('-'));
    await tester.pump();
    await tippeText(tester, 'Stimmt, jetzt sichern');
    expect(find.textContaining('liegt jetzt als Sicherung beim Server'), findsOneWidget);
    expect(find.text('aktiv'), findsOneWidget);
    expect(find.textContaining('Sicherung offen'), findsNothing);
    expect(a.srv.server.anfragen('PUT /me/key-backup'), hasLength(1));
  });
}
