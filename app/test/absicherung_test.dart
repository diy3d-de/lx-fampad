// P1 "Bin ich abgesichert?": die Ampel der eigenen Person. Reine Rechnung (dieselbe Vorschrift wie die Betreiber-Ansicht des Servers; unbekannt und ältere Server sind nie
// grün) und Oberfläche (Profil-Zeile, Startseiten-Karte nur wenn etwas zu tun ist, Seite mit den Wegen und dem nächsten Schritt; 360 px, Textskala 1.0 und 1.5; bei 2.0 läuft die Kachelreihe der Startseite (home_screen.dart, bestehend) über).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/crypto/absicherung.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

final _jetzt = DateTime.utc(2026, 10, 20, 8);

OeffentlicheSchluessel _schluessel() => OeffentlicheSchluessel(enc: Uint8List(32), sign: Uint8List(32), version: 1);

/// Zustand der Verschlüsselung, wie ihn `E2eeController.laden` baut (nur die Felder, die die Ampel braucht).
E2eeState _zustand(
  E2eeStatus status, {
  bool pw = false,
  bool rec = false,
  bool pwVeraltet = false,
  bool pwVerfuegbar = true,
  bool schluesselBeimServer = true,
}) => E2eeState(
  status: status,
  serverSchluessel: schluesselBeimServer ? _schluessel() : null,
  hatSicherung: rec,
  wiederherstellungAm: rec ? _jetzt : null,
  pwSicherungVerfuegbar: pwVerfuegbar,
  pwBestaetigtAm: pw ? _jetzt : null,
  pwSicherungVeraltet: pwVeraltet,
);

SchluesselWegeDto _wege({bool geraet = false, bool pw = false, bool rec = false, int geraete = 0}) =>
    SchluesselWegeDto(geraet: geraet, pwSicherung: pw, wiederherstellung: rec, geraeteMitSchluessel: geraete, archivAnzahl: 0);

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Rechnung', () {
    // Gerät (dieses, bereit), Passwort-Sicherung, Wiederherstellung -> Ampel: genau die Tabelle des Servers (`ampelOf`, betrieb-2a.test.ts)
    final tabelle = <(bool, bool, bool, AbsicherungAmpel)>[
      (false, false, false, AbsicherungAmpel.rot),
      (true, false, false, AbsicherungAmpel.gelb),
      (false, true, false, AbsicherungAmpel.rot),
      (false, false, true, AbsicherungAmpel.rot),
      (true, true, false, AbsicherungAmpel.gruen),
      (true, false, true, AbsicherungAmpel.gruen),
      (false, true, true, AbsicherungAmpel.gelb),
      (true, true, true, AbsicherungAmpel.gruen),
    ];
    for (final (geraet, pw, rec, erwartet) in tabelle) {
      test('Gerät=$geraet Passwort-Sicherung=$pw Wiederherstellung=$rec -> $erwartet', () {
        final a = bewerteAbsicherung(_zustand(geraet ? E2eeStatus.bereit : E2eeStatus.geraetNichtVerbunden, pw: pw, rec: rec));
        expect(a.ampel, erwartet);
        expect(a.wege, [geraet, pw, rec].where((x) => x).length);
        // grün nie ohne bestätigte Sicherung
        if (a.ampel == AbsicherungAmpel.gruen) expect(a.pwWeg || a.wiederherstellungWeg, isTrue);
      });
    }

    // Passkey-Sicherung (PRF): zählt mit der Passwort-Sicherung als EIN Weg (wie `ampelOf` des Servers)
    final prfTabelle = <(bool, bool, bool, bool, AbsicherungAmpel, int)>[
      // Gerät, Passwort, Passkey, Wiederherstellung -> Ampel, Wege
      (true, false, true, false, AbsicherungAmpel.gruen, 2),
      (true, true, true, false, AbsicherungAmpel.gruen, 2),
      (true, true, true, true, AbsicherungAmpel.gruen, 3),
      (true, false, false, false, AbsicherungAmpel.gelb, 1),
      (false, false, true, false, AbsicherungAmpel.rot, 1),
      (false, false, true, true, AbsicherungAmpel.gelb, 2),
      (false, true, true, false, AbsicherungAmpel.rot, 1),
    ];
    for (final (geraet, pw, prf, rec, erwartet, wege) in prfTabelle) {
      test('Passkey: Gerät=$geraet Passwort=$pw Passkey=$prf Wiederherstellung=$rec -> $erwartet ($wege Wege)', () {
        final base = _zustand(geraet ? E2eeStatus.bereit : E2eeStatus.geraetNichtVerbunden, pw: pw, rec: rec);
        final s = E2eeState(
          status: base.status,
          serverSchluessel: base.serverSchluessel,
          hatSicherung: base.hatSicherung,
          wiederherstellungAm: base.wiederherstellungAm,
          pwSicherungVerfuegbar: true,
          pwBestaetigtAm: base.pwBestaetigtAm,
          prfSicherungVerfuegbar: true,
          prfBestaetigtAm: prf ? _jetzt : null,
          prfCredentialIds: prf ? const ['cred-1'] : const [],
          prfSynchronisiert: prf,
        );
        final a = bewerteAbsicherung(s, hatPasskey: true);
        expect(a.ampel, erwartet);
        expect(a.wege, wege);
        expect(a.prfWeg, prf);
        if (a.ampel == AbsicherungAmpel.gruen) expect(a.pwWeg || a.prfWeg || a.wiederherstellungWeg, isTrue, reason: 'grün nie ohne bestätigte Sicherung');
      });
    }

    test('Passkey-Sicherung mit gerätegebundenem (nicht synchronisiertem) Passkey zählt NICHT als Weg und nie als bestätigte Sicherung', () {
      final s = E2eeState(
        status: E2eeStatus.bereit,
        serverSchluessel: _schluessel(),
        pwSicherungVerfuegbar: true,
        prfSicherungVerfuegbar: true,
        prfBestaetigtAm: _jetzt,
        prfCredentialIds: const ['cred-1'],
        prfSynchronisiert: false,
      );
      final a = bewerteAbsicherung(s, hatPasskey: true);
      expect(a.prfWeg, isFalse);
      expect(a.wege, 1, reason: 'nur dieses Gerät');
      expect(a.ampel, AbsicherungAmpel.gelb);
      expect(s.sicherungBestaetigt, isFalse, reason: 'für "Gerät abgeben" zählt die Passkey-Sicherung nie');
      expect(E2eeState(status: E2eeStatus.bereit, prfBestaetigtAm: _jetzt, prfCredentialIds: const ['c'], prfSynchronisiert: true).sicherungBestaetigt, isFalse);
    });

    test('Passkey-Sicherung: ohne bestätigte Kennung zählt sie nicht; nächster Schritt nur mit Passkey und Server-Schalter; veraltet = erneuern', () {
      E2eeState z({bool verfuegbar = true, bool veraltet = false, DateTime? am, List<String> ids = const []}) => E2eeState(
        status: E2eeStatus.bereit,
        serverSchluessel: _schluessel(),
        pwSicherungVerfuegbar: false,
        prfSicherungVerfuegbar: verfuegbar,
        prfSicherungVeraltet: veraltet,
        prfBestaetigtAm: am,
        prfCredentialIds: ids,
      );
      // Zeitpunkt ohne Kennung (oder umgekehrt) ist nie ein Weg
      expect(bewerteAbsicherung(z(am: _jetzt), hatPasskey: true).prfWeg, isFalse);
      expect(bewerteAbsicherung(z(ids: const ['x']), hatPasskey: true).prfWeg, isFalse);
      expect(bewerteAbsicherung(z(), hatPasskey: true).schritte, [AbsicherungSchritt.passkeySicherung, AbsicherungSchritt.wiederherstellungsschluessel]);
      expect(bewerteAbsicherung(z(), hatPasskey: false).schritte, [AbsicherungSchritt.wiederherstellungsschluessel], reason: 'ohne Passkey kein Angebot');
      expect(bewerteAbsicherung(z(verfuegbar: false), hatPasskey: true).schritte, [AbsicherungSchritt.wiederherstellungsschluessel], reason: 'ohne Server-Schalter kein Angebot');
      expect(bewerteAbsicherung(z(veraltet: true), hatPasskey: true).schritte.first, AbsicherungSchritt.passkeySicherungErneuern);
      // Nenner: die Sicherung durch Zugangsdaten zählt als dritter Weg, sobald es sie gibt
      expect(bewerteAbsicherung(z(), hatPasskey: true).wegeMoeglich, 3);
      expect(bewerteAbsicherung(z(verfuegbar: false), hatPasskey: false).wegeMoeglich, 2);
    });

    test('noch kein Schlüssel: rot, nächster Schritt "einrichten"', () {
      final a = bewerteAbsicherung(_zustand(E2eeStatus.keinSchluessel, schluesselBeimServer: false));
      expect(a.ampel, AbsicherungAmpel.rot);
      expect(a.schritte, [AbsicherungSchritt.einrichten]);
      expect(a.wort, 'Noch nicht abgesichert');
    });

    test('unklarer Stand ist nie grün und hat keine Schritte: laedt, nichtVerfuegbar', () {
      for (final st in [E2eeStatus.laedt, E2eeStatus.nichtVerfuegbar]) {
        final a = bewerteAbsicherung(_zustand(st, pw: true, rec: true), server: _wege(geraet: true, pw: true, rec: true));
        expect(a.ampel, AbsicherungAmpel.unbekannt);
        expect(a.schritte, isEmpty);
        expect(a.wort, 'Wird geprüft');
      }
    });

    test('älterer Server ohne die neuen Angaben (keine Zeitpunkte): nie grün, nie "gesichert"', () {
      // pwBestaetigtAm und wiederherstellungAm bleiben null, hatSicherung kann trotzdem stimmen
      final a = bewerteAbsicherung(E2eeState(status: E2eeStatus.bereit, hatSicherung: true, serverSchluessel: _schluessel()));
      expect(a.ampel, AbsicherungAmpel.gelb);
      expect(a.wiederherstellungWeg, isFalse);
    });

    test('veraltete Passwort-Sicherung zählt nicht und bietet "erneuern" an', () {
      final a = bewerteAbsicherung(_zustand(E2eeStatus.bereit, pw: true, pwVeraltet: true));
      expect(a.pwWeg, isFalse);
      expect(a.ampel, AbsicherungAmpel.gelb);
      expect(a.schritte, [AbsicherungSchritt.passwortSicherungErneuern, AbsicherungSchritt.wiederherstellungsschluessel]);
    });

    test('nächste Schritte: Passwort-Sicherung zuerst (ohne Zettel), ohne die Funktion gleich der Wiederherstellungsschlüssel', () {
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit)).schritte, [AbsicherungSchritt.passwortSicherung, AbsicherungSchritt.wiederherstellungsschluessel]);
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit, pwVerfuegbar: false)).schritte, [AbsicherungSchritt.wiederherstellungsschluessel]);
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit, pw: true)).schritte, isEmpty, reason: 'grün: nichts zu tun');
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit, rec: true)).schritte, isEmpty);
    });

    test('Gerät ohne Schlüssel: zuerst verbinden; Sicherungen anlegen geht nur mit dem Schlüssel', () {
      final a = bewerteAbsicherung(_zustand(E2eeStatus.geraetNichtVerbunden));
      expect(a.schritte, [AbsicherungSchritt.geraetVerbinden]);
      final b = bewerteAbsicherung(_zustand(E2eeStatus.abweichend, pw: true));
      expect(b.schritte, [AbsicherungSchritt.geraetNeuVerbinden]);
      expect(b.ampel, AbsicherungAmpel.rot, reason: 'nur eine Sicherung und kein Gerät mit dem Schlüssel');
    });

    test('ein anderes Gerät mit Schlüssel (laut Server) zählt nur, wenn dieses keinen hat; grün bleibt mit Hinweis zum Verbinden', () {
      final ohne = bewerteAbsicherung(_zustand(E2eeStatus.geraetNichtVerbunden, pw: true));
      expect(ohne.ampel, AbsicherungAmpel.rot);
      final mit = bewerteAbsicherung(_zustand(E2eeStatus.geraetNichtVerbunden, pw: true), server: _wege(geraet: true, geraete: 1));
      expect(mit.ampel, AbsicherungAmpel.gruen);
      expect(mit.schritte, [AbsicherungSchritt.geraetVerbinden], reason: 'abgesichert, aber hier fehlt der Schlüssel');
      // der Server kann nie mehr machen, als das Gerät selbst weiß: eine Sicherung, die die App nicht bestätigt sieht, zählt nicht
      final server = bewerteAbsicherung(_zustand(E2eeStatus.bereit), server: _wege(geraet: true, pw: true, rec: true));
      expect(server.ampel, AbsicherungAmpel.gelb, reason: 'ohne bestätigte Sicherung (laut Zustand der App) nie grün');
      // ein Schlüssel auf dem Server hat die Person nicht: keine Wege
      final keiner = bewerteAbsicherung(_zustand(E2eeStatus.keinSchluessel, schluesselBeimServer: false), server: _wege(geraet: true, pw: true, rec: true));
      expect(keiner.ampel, AbsicherungAmpel.rot);
    });

    test('Nenner "x von y Wegen": drei nur, wenn der Server die Passwort-Sicherung anbietet; ohne Schlüssel ein klarer Satz', () {
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit)).wegeMoeglich, 3);
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit, pwVerfuegbar: false)).wegeMoeglich, 2);
      final ohne = bewerteAbsicherung(_zustand(E2eeStatus.keinSchluessel, schluesselBeimServer: false));
      expect(ohne.hatSchluessel, isFalse);
      expect(ohne.erklaerung, startsWith('Du hast noch keinen Schlüssel.'));
      expect(bewerteAbsicherung(_zustand(E2eeStatus.bereit)).erklaerung, isNot(contains('keinen Schlüssel')));
    });

    test('Texte: jedes Wort und jeder Schritt hat feste deutsche Texte, nichts Technisches', () {
      for (final a in AbsicherungAmpel.values) {
        final s = AbsicherungsStatus(ampel: a, geraetWeg: true, pwWeg: true);
        expect(s.wort, isNotEmpty);
        expect(s.erklaerung, isNotEmpty);
      }
      for (final s in AbsicherungSchritt.values) {
        expect(schrittText(s), isNotEmpty);
        expect(schrittErklaerung(s), isNotEmpty);
      }
    });
  });

  group('Oberfläche', () {
    Future<({TestUmgebung env, FakeE2eeServer srv, ProviderContainer c})> start(WidgetTester tester, double skala, {bool pw = false, Size groesse = const Size(360, 800)}) async {
      final server = standardServer()
        ..json('POST /auth/logout', {'ok': true})
        ..json('POST /auth/logout-all', {'ok': true});
      final srv = FakeE2eeServer(server, standardId: fixIdAdmin)..person(fixIdAdmin, 'Anna');
      srv.pwSchalter = pw;
      final env = TestUmgebung(server)..wiperMitVerschluesselung = true;
      await env.angemeldet();
      env.extraOverrides.addAll([
        cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
        schluesselSpeicherProvider.overrideWithValue(MemorySchluesselSpeicher()),
      ]);
      final c = await starteApp(tester, env, skala: skala, groesse: groesse);
      await c.read(e2eeProvider.notifier).laden();
      await warte(tester);
      return (env: env, srv: srv, c: c);
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('Startseite: ohne Schlüssel rot mit Knopf "Nachrichten-Schutz einrichten"; Profil zeigt die Ampel mit Wort (360 px, Textskala $skala)', (tester) async {
        await start(tester, skala);
        expect(labelFinder('Absicherung'), findsOneWidget);
        expect(find.text('Noch nicht abgesichert'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Nachrichten-Schutz einrichten'), findsOneWidget);
        expect(find.textContaining('noch keinen Schlüssel'), findsOneWidget);
        pruefeLayout(tester, 'Startseite mit Absicherungs-Karte');
        // Profil: die Zeile ist immer da
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        // Hauptseite: nur die Zeile Sicherheit mit der Antwort der Ampel als Pille; die Ampel-Zeile selbst liegt auf der Seite Sicherheit
        expect(find.text('Sicherheit'), findsOneWidget);
        expect(find.text('Nein'), findsOneWidget);
        expect(find.text('Bin ich abgesichert?'), findsNothing);
        pruefeLayout(tester, 'Profil mit Sicherheits-Zeile');
        await tippeText(tester, 'Sicherheit');
        expect(find.text('Bin ich abgesichert?'), findsOneWidget);
        expect(find.text('Nein'), findsOneWidget);
        pruefeLayout(tester, 'Sicherheit mit Ampel-Zeile');
        await tippeText(tester, 'Bin ich abgesichert?');
        expect(labelFinder('Deine Wege'), findsOneWidget);
        expect(find.text('Wiederherstellungsschlüssel'), findsOneWidget);
        expect(find.text('Offen'), findsWidgets);
        pruefeLayout(tester, 'Absicherungs-Seite ohne Schlüssel');
      });
    }

    testWidgets('mit Schlüssel auf dem Gerät, ohne Sicherung: gelb; der Knopf führt zum Wiederherstellungsschlüssel; mit Sicherung grün und die Karte verschwindet', (tester) async {
      final a = await start(tester, 1.0);
      // Einrichten über den Controller (wie die Seite Verschlüsselung), dann die Startseite neu bewerten
      await a.c.read(e2eeProvider.notifier).einrichten();
      await warte(tester);
      expect(find.text('Einen Weg noch einrichten'), findsOneWidget);
      expect(find.textContaining('nur auf einem Gerät'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Wiederherstellungsschlüssel anlegen'), findsOneWidget);
      pruefeLayout(tester, 'gelb');
      // Sicherung liegt beim Server: grün, die Karte ist weg (die Startseite bleibt ruhig)
      a.srv.sicherungEinspielen(fixIdAdmin);
      await a.c.read(e2eeProvider.notifier).laden();
      await warte(tester);
      expect(labelFinder('Absicherung'), findsNothing);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      expect(find.text('Ja'), findsOneWidget);
      await tippeText(tester, 'Bin ich abgesichert?');
      expect(find.text('Alles gut abgesichert'), findsOneWidget);
      expect(find.textContaining('Es ist nichts zu tun'), findsOneWidget);
      expect(find.textContaining('Liegt beim Server seit'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Neuen Schlüssel und Notfallblatt erzeugen'), findsOneWidget);
      pruefeLayout(tester, 'grün');
    });

    testWidgets('der Knopf auf der Startseite öffnet den Wiederherstellungsschlüssel (mit Notfallblatt)', (tester) async {
      final a = await start(tester, 1.0);
      await a.c.read(e2eeProvider.notifier).einrichten();
      await warte(tester);
      await tippeText(tester, 'Wiederherstellungsschlüssel anlegen');
      expect(find.text('Notfallblatt speichern (PDF)'), findsOneWidget);
      expect(find.text('Wiederherstellungsschlüssel'), findsWidgets);
    });

    testWidgets('mit Passwort-Sicherung beim Server ist die Passwort-Sicherung der erste Schritt', (tester) async {
      final a = await start(tester, 1.0, pw: true);
      await a.c.read(e2eeProvider.notifier).einrichten();
      await warte(tester);
      expect(find.widgetWithText(FilledButton, 'Passwort-Sicherung anlegen'), findsOneWidget);
      await tippeText(tester, 'Einzelheiten');
      expect(labelFinder('Nächste Schritte'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Wiederherstellungsschlüssel anlegen'), findsOneWidget, reason: 'der zweite Weg steht als zweite Wahl daneben');
      expect(find.text('Passwort-Sicherung'), findsOneWidget);
      pruefeLayout(tester, 'Seite mit zwei Schritten');
    });

    testWidgets('älterer Server (kein /me/key-status): die App rechnet allein und zeigt trotzdem die Ampel', (tester) async {
      final a = await start(tester, 1.0);
      a.srv.keyStatusSchalter = false;
      await a.c.read(e2eeProvider.notifier).einrichten();
      await warte(tester);
      expect(find.text('Einen Weg noch einrichten'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Desktop-Breite: die Karte steht auch auf der Startseite des Desktop-Layouts', (tester) async {
      await start(tester, 1.0, groesse: const Size(1200, 900));
      expect(labelFinder('Absicherung'), findsOneWidget);
      expect(find.text('Noch nicht abgesichert'), findsWidgets);
    });
  });
}
