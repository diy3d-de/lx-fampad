// Zähler: Oberfläche der Eingabeart "Monatswerte" (Balkonkraftwerk): Kachel, Monatswert eintragen (Monat, Vorjahr, Jahressumme, ersetzen, Zahlendreher), Verlauf mit Bearbeiten und
// Löschen, Einrichten mit Vorbelegung der Eingabeart; bei 360 px und Textskala 1.0/1.5/2.0. Kinder haben keinen Zugang. Daten über überschriebene Provider, Schreibwege über ein aufzeichnendes Repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart';
import 'package:lx_fampad/features/zaehler/zaehler_bericht_screen.dart';
import 'package:lx_fampad/features/zaehler/zaehler_monat_screen.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/harness.dart';
import 'support/zaehler_welt.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  late ZaehlerRepoAttrappe repo;
  late NotifierProvider<TestZaehlerDaten, ZaehlerDaten> daten;

  Future<ProviderContainer> start(WidgetTester tester, ZaehlerDaten d, {String role = 'admin', double skala = 1.0, bool zumBereichGehen = true}) async {
    repo = ZaehlerRepoAttrappe();
    daten = NotifierProvider<TestZaehlerDaten, ZaehlerDaten>(() => TestZaehlerDaten(d));
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
      zaehlerTestUhr,
      zaehlerDatenProvider.overrideWith((ref) => ref.watch(daten)),
      zaehlerRepositoryProvider.overrideWithValue(repo),
      zaehlerBerichtSpeichernProvider.overrideWithValue((name, bytes) async => true),
    ]);
    final c = await starteApp(tester, env, skala: skala, groesse: const Size(360, 800));
    if (zumBereichGehen) await zumBereich(tester, 'Zähler');
    return c;
  }

  ZaehlerDaten nurSolar({bool vormonat = true}) => datenAus([solarMonate(werte: monatsWerte(vormonatAuslassen: !vormonat))]);

  Future<void> oeffneMonat(WidgetTester tester) async => tippe(tester, find.widgetWithText(FilledButton, 'Monatswert eintragen'));

  group('Übersicht', () {
    testWidgets('Kachel: Erzeugung seit Jahresbeginn, Vormonat mit Vorjahr, Ersparnis; Knopf heißt Monatswert eintragen, nicht Stand', (tester) async {
      await start(tester, nurSolar());
      expect(find.text('Balkonkraftwerk'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Monatswert eintragen'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Stand eintragen'), findsNothing);
      expect(find.textContaining('seit 01.01.2026'), findsOneWidget);
      expect(find.textContaining('September'), findsWidgets); // letzter voller Monat
      expect(find.textContaining('Ersparnis ca.'), findsOneWidget);
      expect(find.textContaining('Noch kein Monatswert'), findsNothing);
      expect(find.textContaining('Nächste'), findsOneWidget);
      expect(find.textContaining('Zählerstand'), findsNothing);
      pruefeLayout(tester, 'Kachel Monatswerte');
    });

    testWidgets('fehlt der Vormonat: Hinweiskarte und Pille nennen den Monatswert, nicht das Ablesen', (tester) async {
      await start(tester, nurSolar(vormonat: false));
      expect(find.text('Wert fällig'), findsOneWidget);
      expect(find.textContaining('Erzeugung September fehlt'), findsOneWidget);
      expect(find.text('Eintragen'), findsOneWidget);
      expect(find.text('Ablesen'), findsNothing);
    });

    testWidgets('ohne Werte: Hinweis zum ersten Monatswert', (tester) async {
      await start(tester, datenAus([solarMonate(werte: const [])]));
      expect(find.textContaining('Trage den ersten Monatswert ein'), findsOneWidget);
      expect(find.text('Noch kein Monatswert'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: kein Überlauf', (tester) async {
        await start(tester, nurSolar(vormonat: false), skala: skala);
        pruefeLayout(tester, 'Übersicht Monatswerte $skala');
      });
    }
  });

  group('Monatswert eintragen', () {
    testWidgets('Vormonat ist vorbelegt, Vorjahresmonat und Jahressumme stehen da, Speichern schreibt Tausendstel', (tester) async {
      await start(tester, nurSolar(vormonat: false));
      await oeffneMonat(tester);
      expect(find.text('Monatswert'), findsOneWidget);
      expect(find.text('September 2026'), findsWidgets);
      await eingeben(tester, 'Erzeugung im Monat in kWh', '48,3');
      await warte(tester);
      expect(find.text('Vorjahresmonat'), findsOneWidget);
      expect(find.textContaining('Sep 2025'), findsOneWidget);
      expect(find.text('Summe 2026'), findsOneWidget);
      expect(find.text('Plausibel. Der Wert liegt im üblichen Bereich.'), findsOneWidget);
      pruefeLayout(tester, 'Monatswert plausibel');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.monatswertErfasst, hasLength(1));
      expect(repo.monatswertErfasst.single.id, zSolar);
      expect((repo.monatswertErfasst.single.jahr, repo.monatswertErfasst.single.monat, repo.monatswertErfasst.single.milli), (2026, 9, 48300));
    });

    testWidgets('schon ein Wert im Monat: Hinweis "ersetzen", Speichern erst nach Bestätigung', (tester) async {
      await start(tester, nurSolar());
      await oeffneMonat(tester);
      await eingeben(tester, 'Erzeugung im Monat in kWh', '55');
      await warte(tester);
      expect(find.textContaining('schon einen Wert'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNull);
      await tippe(tester, find.text('Ja, den vorhandenen Wert ersetzen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.monatswertErfasst.single.milli, 55000);
    });

    testWidgets('mehr als doppelt so hoch wie im Vorjahresmonat: Rückfrage "Stimmt der Wert?" (Zahlendreher), erst nach Bestätigung', (tester) async {
      await start(tester, nurSolar(vormonat: false));
      await oeffneMonat(tester);
      await eingeben(tester, 'Erzeugung im Monat in kWh', '480');
      await warte(tester);
      expect(find.textContaining('Stimmt der Wert?'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNull);
      await tippe(tester, find.text('Ich habe geprüft, der Wert stimmt'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.monatswertErfasst.single.milli, 480000);
    });

    testWidgets('Eingabe, die keine Zahl ist, oder über 100 000: Fehlertext, Speichern gesperrt', (tester) async {
      await start(tester, nurSolar(vormonat: false));
      await oeffneMonat(tester);
      await eingeben(tester, 'Erzeugung im Monat in kWh', '100001');
      await warte(tester);
      expect(find.textContaining('Gib den Wert als Zahl ein'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNull);
      await eingeben(tester, 'Erzeugung im Monat in kWh', '100000');
      await warte(tester);
      expect(find.textContaining('Gib den Wert als Zahl ein'), findsNothing);
    });

    testWidgets('Monatswahl: der laufende Monat ist ein Zwischenstand, die Auswahl reicht 24 Monate zurück und nie in die Zukunft', (tester) async {
      await start(tester, nurSolar(vormonat: false));
      await oeffneMonat(tester);
      await tippe(tester, find.byType(DropdownButtonFormField<int>));
      expect(find.textContaining('Oktober 2026 (laufend)'), findsOneWidget);
      expect(find.text('November 2026'), findsNothing);
      await tippe(tester, find.textContaining('Oktober 2026 (laufend)'));
      await eingeben(tester, 'Erzeugung im Monat in kWh', '12,4');
      await warte(tester);
      expect(find.textContaining('Zwischenstand'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern')); // der Zwischenstand braucht keine Bestätigung
      expect((repo.monatswertErfasst.single.monat, repo.monatswertErfasst.single.milli), (10, 12400));
    });

    testWidgets('Fehler beim Speichern: Meldung ohne Inhalt, die Seite bleibt', (tester) async {
      await start(tester, nurSolar(vormonat: false));
      repo.fehler = const StandUngueltig('Ein Monatswert kann nicht in der Zukunft liegen.');
      await oeffneMonat(tester);
      await eingeben(tester, 'Erzeugung im Monat in kWh', '10');
      await warte(tester);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Ein Monatswert kann nicht in der Zukunft liegen.'), findsOneWidget);
      expect(find.text('Monatswert'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala (mit Hinweisen)', (tester) async {
        await start(tester, nurSolar(), skala: skala);
        await oeffneMonat(tester);
        await eingeben(tester, 'Erzeugung im Monat in kWh', '480');
        await warte(tester);
        pruefeLayout(tester, 'Monatswert Skala $skala');
      });
    }
  });

  group('Verlauf', () {
    Future<void> oeffneVerlauf(WidgetTester tester) async => tippe(tester, find.bySemanticsLabel(RegExp(r'^Balkonkraftwerk\.')));

    testWidgets('Balken zeigen die Monatswerte direkt mit Vorjahr; Liste "letzte Werte" mit Bearbeiten (öffnet den Wert) und Löschen (mit Bestätigung)', (tester) async {
      await start(tester, nurSolar());
      await oeffneVerlauf(tester);
      expect(find.widgetWithText(FilledButton, 'Monatswert eintragen'), findsOneWidget);
      expect(find.text('2026 bisher'), findsOneWidget);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      expect(labelFinder('Letzte Werte'), findsOneWidget);
      await tippe(tester, find.byType(PopupMenuButton<String>).first);
      await tippe(tester, find.text('Bearbeiten'));
      expect(find.text('Monatswert'), findsOneWidget);
      expect(labelFinder('Ändern'), findsOneWidget);
      expect(find.textContaining('schon einen Wert'), findsNothing); // eigener Wert: keine Rückfrage
      await tippe(tester, find.byIcon(Icons.arrow_back).first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      await tippe(tester, find.byType(PopupMenuButton<String>).first);
      await tippe(tester, find.text('Löschen'));
      expect(find.text('Monatswert löschen?'), findsOneWidget);
      expect(repo.aufrufe, isEmpty);
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(repo.aufrufe.single, startsWith('monatswertLoeschen:$zSolar:2026-'));
    });

    testWidgets('Hochrechnung: fehlende Monate werden aus dem Vorjahr geschätzt und gekennzeichnet', (tester) async {
      await start(tester, nurSolar());
      await oeffneVerlauf(tester);
      expect(find.textContaining('Hochrechnung 2026'), findsOneWidget);
      expect(find.textContaining('geschätzt'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Verlauf bei 360 px und Textskala $skala', (tester) async {
        await start(tester, nurSolar(), skala: skala);
        await oeffneVerlauf(tester);
        pruefeLayout(tester, 'Verlauf Monatswerte $skala');
      });
    }
  });

  group('Zähler einrichten', () {
    Future<void> oeffneEditor(WidgetTester tester) async => tippe(tester, find.byTooltip('Zähler hinzufügen'));
    // AuswahlKnopf: das gewählte Feld ist als ausgewählt ausgezeichnet
    void gewaehlt(WidgetTester tester, String text, bool soll) {
      final knoten = tester.getSemantics(find.bySemanticsLabel(text).first);
      expect(knoten, soll ? isSemantics(isSelected: true) : isNot(isSemantics(isSelected: true)), reason: text);
    }

    testWidgets('Erzeugung: Eingabeart ist mit Monatswerte vorbelegt; kein Ablese-Rhythmus; Speichern legt den Zähler mit modus monat an', (tester) async {
      await start(tester, nurSolar());
      await oeffneEditor(tester);
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Garage Solar');
      await tippe(tester, find.text('Erzeugung (Solar) · kWh'));
      expect(labelFinder('Eingabeart'), findsOneWidget);
      expect(find.textContaining('Einen Zähler brauchst du dafür nicht'), findsOneWidget);
      expect(labelFinder('Ablese-rhythmus'), findsNothing);
      expect(find.textContaining('Am 1. jedes Monats um 9 Uhr'), findsOneWidget);
      expect(find.textContaining('Aktueller Zählerstand'), findsNothing);
      pruefeLayout(tester, 'Editor Monatswerte');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      final z = repo.angelegt.single;
      expect((z.modus, z.art, z.ablesung), (ZaehlerModus.monat, ZaehlerArt.erzeugung, null));
    });

    testWidgets('Strom: Zählerstand ist vorbelegt, Umschalten auf Monatswerte ist möglich (auch ohne Solar)', (tester) async {
      await start(tester, nurSolar());
      await oeffneEditor(tester);
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Strom Haus');
      await tippe(tester, find.text('Strom · kWh'));
      expect(labelFinder('Ablese-rhythmus'), findsOneWidget);
      gewaehlt(tester, 'Zählerstand', true);
      await tippe(tester, find.text('Monatswerte'));
      expect(labelFinder('Ablese-rhythmus'), findsNothing);
      expect(find.textContaining('Verbrauch je Monat direkt'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.modus, ZaehlerModus.monat);
      expect(repo.angelegt.single.ablesung, isNull);
    });

    testWidgets('Wechsel der Art stellt die Eingabeart auf den Standard der Art', (tester) async {
      await start(tester, nurSolar());
      await oeffneEditor(tester);
      await tippe(tester, find.text('Erzeugung (Solar) · kWh'));
      gewaehlt(tester, 'Monatswerte', true);
      await tippe(tester, find.text('Kaltwasser · m³'));
      gewaehlt(tester, 'Zählerstand', true);
      gewaehlt(tester, 'Monatswerte', false);
    });

    testWidgets('Bearbeiten eines Zählers mit Werten: die Eingabeart ist nicht mehr änderbar', (tester) async {
      await start(tester, nurSolar());
      await tippe(tester, find.bySemanticsLabel(RegExp(r'^Balkonkraftwerk\.')));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      await tippe(tester, find.text('Zähler bearbeiten'));
      expect(find.textContaining('lässt sich nicht mehr ändern'), findsOneWidget);
      expect(find.bySemanticsLabel('Zählerstand'), findsNothing); // die Auswahl ist nur noch Text
    });
  });

  group('Rollen', () {
    testWidgets('Kind: Monatswert eintragen führt nirgends hinein und schreibt nichts', (tester) async {
      await start(tester, nurSolar(), role: 'child', zumBereichGehen: false);
      final ctx = tester.element(find.byType(Scaffold).first);
      await monatswertEintragenOeffnen(ctx);
      await warte(tester);
      expect(find.text('Monatswert'), findsNothing);
      expect(repo.monatswertErfasst, isEmpty);
    });
  });
}
