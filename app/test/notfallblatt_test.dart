// P1 Notfallblatt: das PDF (gültiger Aufbau, Schlüssel und Anleitung stehen drauf, Sonderzeichen werden maskiert), und die Oberfläche (Knopf nur solange der Schlüssel
// sichtbar ist, speichert nur auf Klick, nichts im Log, Arbeitsspeicher wird überschrieben, Fehler nennt den Schlüssel nie; 360 px, Textskala 1.5 und 2.0).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/notfallblatt.dart';
import 'package:lx_fampad/data/crypto/wiederherstellung.dart';
import 'package:lx_fampad/features/profile/wiederherstellungsschluessel_screen.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user);
}

final _schluessel = Uint8List.fromList(List.generate(32, (i) => i * 7 + 3));

/// Die Bytes als Text (Latin-1: jedes Byte ein Zeichen), zum Suchen im PDF.
String _text(Uint8List b) => latin1.decode(b);

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Notfallblatt-PDF', () {
    final gruppen = Wiederherstellung.gruppen(_schluessel);
    late Uint8List pdf;
    late String s;
    setUp(() {
      pdf = notfallblattPdf(gruppen: gruppen, name: 'Anna Äpfel (Mama)', datum: DateTime(2026, 10, 22));
      s = _text(pdf);
    });

    test('ist ein gültiges PDF: Kopf, Ende und Verweistabelle zeigt auf jedes Objekt', () {
      expect(s.startsWith('%PDF-1.4\n'), isTrue);
      expect(s.trimRight().endsWith('%%EOF'), isTrue);
      final start = int.parse(RegExp(r'startxref\n(\d+)\n').firstMatch(s)!.group(1)!);
      expect(s.substring(start).startsWith('xref\n'), isTrue);
      final eintraege = RegExp(r'(\d{10}) (\d{5}) ([nf]) \n').allMatches(s.substring(start)).toList();
      final n = int.parse(RegExp(r'xref\n0 (\d+)\n').firstMatch(s)!.group(1)!);
      expect(eintraege, hasLength(n));
      expect(eintraege.first.group(3), 'f');
      for (var i = 1; i < n; i++) {
        final stelle = int.parse(eintraege[i].group(1)!);
        expect(s.substring(stelle).startsWith('$i 0 obj\n'), isTrue, reason: 'Objekt $i');
      }
      expect(s, contains('/Size $n'));
      // die Länge des Inhaltsstroms stimmt
      final laenge = int.parse(RegExp(r'/Length (\d+) >>\nstream\n').firstMatch(s)!.group(1)!);
      final von = s.indexOf('stream\n') + 7;
      expect(s.substring(von + laenge, von + laenge + '\nendstream'.length), '\nendstream');
    });

    test('der Schlüssel steht in Gruppen auf dem Blatt, dazu die Kurzanleitung und eine Zeile zum Eintragen', () {
      for (final g in gruppen) {
        expect(s, contains(g));
      }
      expect(gruppen, hasLength(14));
      expect(s, contains('Notfallblatt'));
      expect(s, contains('22.10.2026'));
      for (final (titel, text) in kNotfallblattAnleitung) {
        expect(s, contains(_text(Uint8List.fromList(_cp1252(titel)))));
        expect(text, isNotEmpty);
      }
      // die Wege in der Anleitung gibt es in der App
      expect(s, contains('Verschlüsselung'));
      expect(s, contains('Mit Wiederherstellungsschl'));
      expect(s, contains('Abgelegt am'));
    });

    test('Umlaute stehen als Windows-1252-Bytes, Klammern und Backslash im Namen werden maskiert, Fremdes wird "?"', () {
      expect(pdf.contains(0xE4), isTrue); // ä
      expect(pdf.contains(0xFC), isTrue); // ü
      expect(s, contains('Anna Äpfel \\(Mama\\)'));
      final komisch = _text(notfallblattPdf(gruppen: gruppen, name: r'A\B (x) 😀', datum: DateTime(2026, 1, 2)));
      expect(komisch, contains(r'A\\B \(x\) ?'));
      expect(komisch, isNot(contains('😀')));
    });

    test('nur Standardschriften, keine Verweise ins Netz, keine Skripte', () {
      expect(s, contains('/BaseFont /Helvetica'));
      expect(s, contains('/BaseFont /Courier-Bold'));
      for (final verboten in ['/URI', '/JavaScript', '/JS', 'http://', 'https://', '/Launch', '/EmbeddedFile']) {
        expect(s, isNot(contains(verboten)), reason: verboten);
      }
      // familie.lx-labs.dev steht ohne Schema (kein anklickbarer Link) als Text in der Anleitung
      expect(s, contains('familie.lx-labs.dev'));
    });

    test('Zeilen passen auf die Seite: Umbruch auf höchstens 86 Zeichen, Schlüssel in Sieben-Gruppen-Zeilen', () {
      for (final (_, text) in kNotfallblattAnleitung) {
        for (final z in umbrechen(text, 86)) {
          expect(z.length, lessThanOrEqualTo(86));
        }
        expect(umbrechen(text, 86).join(' '), text.replaceAll(RegExp(r'\s+'), ' ').trim());
      }
      // zwei Zeilen Schlüssel: 7 Gruppen zu 4 Zeichen, getrennt durch zwei Leerzeichen (Courier 17 pt: 12,0 pt je Zeichen, Breite 7*4+6*2 = 40 Zeichen = 480 pt < 487 pt)
      final zeile = gruppen.sublist(0, 7).join('  ');
      expect(zeile.length * 17 * 0.6, lessThan(595 - 2 * 54));
      expect(s, contains(zeile));
    });

    test('ändert der Schlüssel, ändert sich das Blatt; zwei Aufrufe mit denselben Daten sind gleich', () {
      final anders = notfallblattPdf(gruppen: Wiederherstellung.gruppen(Uint8List.fromList(List.filled(32, 9))), name: 'Anna', datum: DateTime(2026, 10, 22));
      expect(_text(anders), isNot(contains('${gruppen.first}  ')));
      final gleich = notfallblattPdf(gruppen: gruppen, name: 'Anna Äpfel (Mama)', datum: DateTime(2026, 10, 22));
      expect(gleich, pdf);
    });
  });

  group('Oberfläche des Wiederherstellungsschlüssels', () {
    Future<List<(String, Uint8List)>> zeigen(WidgetTester tester, double skala, {Future<bool> Function(String, Uint8List)? speichern}) async {
      final gespeichert = <(String, Uint8List)>[];
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      kanalMocken();
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(() => _FesterAuth(UserDto.fromJson(userJson(id: fixIdAdmin, name: 'Anna', email: 'anna@beispiel.de')))),
          notfallblattSpeichernProvider.overrideWithValue((name, bytes) async {
            gespeichert.add((name, Uint8List.fromList(bytes))); // Kopie: Die Oberfläche überschreibt ihre Bytes nach dem Speichern
            return speichern == null ? true : speichern(name, bytes);
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: WiederherstellungsschluesselScreen(einrichtung: Einrichtung(Uint8List.fromList(_schluessel), 1)),
          ),
        ),
      );
      await warte(tester);
      return gespeichert;
    }

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Knopf speichert das Blatt nur auf Klick, mit Hinweis zum Löschen (360 px, Textskala $skala)', (tester) async {
        final gespeichert = await zeigen(tester, skala);
        expect(find.text('Notfallblatt speichern (PDF)'), findsOneWidget);
        expect(gespeichert, isEmpty, reason: 'ohne Klick wird nichts gespeichert');
        pruefeLayout(tester, 'Anzeige mit Notfallblatt');
        await tippeText(tester, 'Notfallblatt speichern (PDF)');
        expect(gespeichert, hasLength(1));
        expect(gespeichert.single.$1, kNotfallblattDateiname);
        expect(kNotfallblattDateiname, isNot(contains('anna')), reason: 'kein Name im Dateinamen');
        final pdf = _text(gespeichert.single.$2);
        for (final g in Wiederherstellung.gruppen(_schluessel)) {
          expect(pdf, contains(g));
        }
        expect(pdf, contains('Anna'));
        expect(find.textContaining('Notfallblatt gespeichert'), findsOneWidget);
        // der Hinweis nennt den Schlüssel nie
        for (final g in Wiederherstellung.gruppen(_schluessel)) {
          expect(find.textContaining(g), findsNWidgets(1), reason: 'die Gruppe steht nur im Schlüsselfeld, nicht im Hinweis');
        }
        pruefeLayout(tester, 'nach dem Speichern');
      });
    }

    testWidgets('verdeckt gibt es keinen Knopf: die Kontrolle bleibt eine echte Kontrolle', (tester) async {
      await zeigen(tester, 1.0);
      await tippeText(tester, 'Ich habe ihn notiert, weiter');
      expect(find.text('Notfallblatt speichern (PDF)'), findsNothing);
      await tippeText(tester, 'Schlüssel nochmal ansehen');
      expect(find.text('Notfallblatt speichern (PDF)'), findsOneWidget);
    });

    testWidgets('Abbruch im Speichern-Dialog: kein "gespeichert"; ein Fehler nennt den Schlüssel nie', (tester) async {
      var versuche = 0;
      final gespeichert = await zeigen(tester, 1.0, speichern: (_, _) async {
        versuche++;
        if (versuche == 1) return false; // abgebrochen
        throw StateError('Schlüssel ${Wiederherstellung.anzeigen(_schluessel)} im Fehlertext'); // ein Fehler darf nie in der Anzeige landen
      });
      await tippeText(tester, 'Notfallblatt speichern (PDF)');
      expect(find.textContaining('Notfallblatt gespeichert'), findsNothing);
      await tippeText(tester, 'Notfallblatt speichern (PDF)');
      expect(gespeichert, hasLength(2));
      expect(find.textContaining('ließ sich nicht speichern'), findsOneWidget);
      expect(find.textContaining('im Fehlertext'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Windows-1252 für die Umlaute der Testtexte (wie im Erzeuger).
List<int> _cp1252(String s) => [
  for (final r in s.runes)
    if (r == 0x201E) 0x84 else if (r == 0x201C) 0x93 else if (r == 0x201D) 0x94 else if (r < 0x100) r else 0x3F,
];
