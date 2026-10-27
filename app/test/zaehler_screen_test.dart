// Zähler (Teil 2): Oberfläche. Übersicht (Kacheln, Wasser-Gruppe mit Summe, Hinweis "Ablesen fällig"), Verlauf (Balken berühren, Tastatur, Zeitraum, Kosten, Stände ändern und löschen),
// Stand eintragen (Plausibilität, Bestätigung, Alle Wasserzähler nacheinander), Einrichten (Art, Rhythmus, Tarif, Solar mit Strompreis aus dem Stromzähler, Archivieren, Löschen, Wechsel),
// PDF-Bericht (Auswahl, Erzeugen); bei 360 px und Textskala 1.0/1.5/2.0. Rollen: Elternteil und Admin bedienen alles, ein Kind hat nichts davon (Menüpunkt, Seitenleiste, Kachel, Badge,
// Erinnerung, Deep-Link). Daten kommen über überschriebene Provider (kein Schlüsselmaterial), die Schreibwege über ein aufzeichnendes Repository.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/zaehler/zaehler_hinweis.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/zaehler/zaehler_anzeige.dart' show zaehlerFaelligProvider;
import 'package:lx_fampad/features/zaehler/zaehler_bericht_screen.dart';
import 'package:lx_fampad/features/zaehler/zaehler_diagramm.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/harness.dart';
import 'support/test_app.dart';
import 'support/zaehler_welt.dart';

class _Schalter extends Notifier<bool> {
  @override
  bool build() => true;
  void setzen(bool v) => state = v;
}

extension on ZaehlerDaten {
  ZaehlerDaten copyMitDarf(bool darf) => darf ? this : ZaehlerDaten(geladen: true, ich: ich);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  late ZaehlerRepoAttrappe repo;
  late NotifierProvider<TestZaehlerDaten, ZaehlerDaten> daten;
  late List<({String name, Uint8List bytes})> gespeichert;

  /// Strom (fällig: der letzte Stand liegt vor dem Solltermin), Wasser-Gruppe mit drei Zählern und Solar.
  ZaehlerDaten alle({bool stromFaellig = true}) {
    final st = monatsStaende();
    return datenAus([
      strom(staende: stromFaellig ? st.sublist(0, st.length - 1) : st),
      wasser(zKalt1, 'Kaltwasser Etage'),
      wasser(zKalt2, 'Kaltwasser Waschkeller', start: 50, proMonat: 2),
      wasser(zWarm, 'Warmwasser Etage', art: ZaehlerArt.warmwasser, start: 20, proMonat: 1),
      solar(),
    ]);
  }

  Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, ZaehlerDaten d, {String role = 'admin', double skala = 1.0, Size groesse = const Size(360, 800), bool zumBereichGehen = true}) async {
    repo = ZaehlerRepoAttrappe();
    gespeichert = [];
    daten = NotifierProvider<TestZaehlerDaten, ZaehlerDaten>(() => TestZaehlerDaten(d));
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
      zaehlerTestUhr,
      zaehlerDatenProvider.overrideWith((ref) => ref.watch(daten)),
      zaehlerRepositoryProvider.overrideWithValue(repo),
      zaehlerBerichtSpeichernProvider.overrideWithValue((name, bytes) async {
        gespeichert.add((name: name, bytes: Uint8List.fromList(bytes)));
        return true;
      }),
    ]);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (zumBereichGehen) {
      if (groesse.width >= kDesktopBreakpoint) {
        c.read(shellTabProvider.notifier).waehlen(kZaehlerTab);
        await warte(tester);
      } else {
        await zumBereich(tester, 'Zähler');
      }
    }
    return (env, c);
  }

  Future<void> oeffneVerlauf(WidgetTester tester, String titel) async {
    await tippe(tester, find.bySemanticsLabel(RegExp('^$titel\\.')));
  }

  group('Übersicht', () {
    testWidgets('Kacheln: Strom mit Fälligkeit, Wasser als Gruppe mit Summe und Einzelzählern, Solar mit Ersparnis', (tester) async {
      await start(tester, alle());
      expect(find.text('Zähler'), findsWidgets);
      expect(find.text('Strom'), findsWidgets);
      expect(find.text('Ablesen fällig'), findsWidgets);
      expect(find.textContaining('Strom: Ablesen am'), findsOneWidget);
      expect(find.text('Wasser Wohnung'), findsOneWidget); // die beiden Kaltwasserzähler; das Warmwasser steht allein (andere Art)
      expect(find.text('Warmwasser Etage'), findsOneWidget);
      expect(find.text('Balkonkraftwerk'), findsOneWidget);
      expect(find.text('Erzeugung'), findsOneWidget);
      expect(find.textContaining('Ersparnis ca.'), findsOneWidget);
      expect(find.textContaining('% der Anschaffung drin'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Stand eintragen'), findsOneWidget);
      expect(find.byTooltip('Bericht als PDF'), findsOneWidget);
      expect(find.byTooltip('Zähler hinzufügen'), findsOneWidget);
      pruefeLayout(tester, 'Übersicht');
    });

    testWidgets('Wasser: zwei Kaltwasserzähler einer Gruppe ergeben eine Kachel mit Summe, "Alle Wasserzähler ablesen" und den Einzelzählern', (tester) async {
      await start(tester, datenAus([wasser(zKalt1, 'Kaltwasser Etage'), wasser(zKalt2, 'Kaltwasser Waschkeller', start: 50, proMonat: 2)]));
      expect(find.text('Wasser Wohnung'), findsOneWidget);
      expect(find.text('Kaltwasser Etage'), findsOneWidget);
      expect(find.text('Kaltwasser Waschkeller'), findsOneWidget);
      expect(find.text('2 Zähler zusammen'), findsOneWidget);
      expect(find.text('Alle Wasserzähler ablesen'), findsOneWidget);
      // Summe des letzten vollen Monats: 3 + 2 = 5 m³
      expect(find.textContaining('5,0 m³'), findsWidgets);
      pruefeLayout(tester, 'Wasser-Gruppe');
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: kein Überlauf, Ziele mindestens 44 px', (tester) async {
        await start(tester, alle(), skala: skala);
        pruefeLayout(tester, 'Übersicht Skala $skala');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await warte(tester);
        pruefeLayout(tester, 'Übersicht unten Skala $skala');
      });
    }

    testWidgets('leerer Zustand: Hinweis und Knopf "Zähler einrichten", der den Editor öffnet', (tester) async {
      await start(tester, datenAus(const []));
      expect(find.text('Noch keine Zähler'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Zähler einrichten'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Zähler einrichten'));
      expect(find.text('Zähler einrichten'), findsWidgets);
      expect(find.widgetWithText(TextField, 'Name (zum Beispiel Strom Haus)'), findsOneWidget);
    });

    testWidgets('nicht lesbarer Zähler: Hinweis ohne Inhalt, kein Absturz', (tester) async {
      final kaputt = datenAus([strom()]);
      final d = ZaehlerDaten(
        geladen: true,
        ich: 'a',
        darf: true,
        eintraege: [...kaputt.eintraege, ZaehlerEintrag(ZaehlerAnsicht(id: 'x', konversationId: 'k', inhalt: null, hinweis: 'nicht lesbar', erstelltAt: DateTime.utc(2026)), const [])],
        reihen: kaputt.reihen,
        kacheln: kaputt.kacheln,
      );
      await start(tester, d);
      expect(find.textContaining('lässt sich gerade nicht lesen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Archivierte Zähler stehen unten und lassen sich wieder aktivieren', (tester) async {
      final z = ZaehlerBeispiel('arch', ZaehlerInhalt(art: ZaehlerArt.gas, name: 'Gas alt', archiviertAb: '2025-06-30'), monatsStaende(anzahl: 3));
      await start(tester, datenAus([strom(), z]));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await warte(tester);
      expect(labelFinder('Archiviert'), findsOneWidget);
      await tippe(tester, find.text('Aktivieren'));
      expect(repo.aufrufe, ['reaktivieren:arch']);
    });
  });

  group('Verlauf', () {
    testWidgets('Balken berühren zeigt Wert und Veränderung zum Vorjahr, Ziehen und Pfeiltasten wechseln den Balken', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      expect(find.byType(VerbrauchsDiagramm), findsOneWidget);
      // Vorgabe: der jüngste Monat mit Werten; jeder Monat verbraucht 300 kWh, im Vorjahr ebenso
      expect(find.text('300 kWh'), findsWidgets);
      final diagramm = find.byType(VerbrauchsDiagramm);
      final rect = tester.getRect(diagramm);
      // links tippen: der Januar
      await tester.tapAt(Offset(rect.left + rect.width * 0.04, rect.center.dy));
      await warte(tester);
      expect(find.textContaining('Januar'), findsOneWidget);
      // rechts tippen: der Dezember
      await tester.tapAt(Offset(rect.left + rect.width * 0.96, rect.center.dy));
      await warte(tester);
      expect(find.textContaining('Dezember'), findsOneWidget);
      // ziehen
      final g = await tester.startGesture(Offset(rect.left + rect.width * 0.04, rect.center.dy));
      await g.moveTo(Offset(rect.left + rect.width * 0.46, rect.center.dy));
      await warte(tester);
      expect(find.textContaining('Juni'), findsOneWidget);
      await g.up();
      await warte(tester);
      // Tastatur (Web): der Fokus liegt nach dem Tippen auf dem Diagramm
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await warte(tester);
      expect(find.textContaining('Mai'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await warte(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await warte(tester);
      expect(find.textContaining('Juli'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await warte(tester);
      expect(find.textContaining('Januar'), findsOneWidget);
      pruefeLayout(tester, 'Verlauf');
    });

    testWidgets('Zeitraum: zurückblättern, Vorjahr aus, Werte als Liste, Summen und Hochrechnung', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      const jahr = 2026;
      expect(find.text('$jahr'), findsOneWidget);
      expect(find.textContaining('Hochrechnung'), findsWidgets);
      await tippe(tester, find.byTooltip('Ein Jahr zurück'));
      expect(find.text('${jahr - 1}'), findsOneWidget);
      expect(find.text('3.600 kWh'), findsWidgets); // 12 Monate * 300
      expect(find.textContaining('Hochrechnung'), findsNothing); // abgeschlossenes Jahr
      await tippe(tester, find.text('Werte als Liste'));
      expect(find.textContaining('Januar ${jahr - 1}'), findsWidgets);
      await tippe(tester, find.text('Vorjahr zeigen'));
      expect(find.text('Ohne Vorjahr'), findsOneWidget);
      await tippe(tester, find.byTooltip('Ein Jahr weiter'));
      expect(find.text('$jahr'), findsOneWidget);
    });

    testWidgets('Kosten mit Tarif: Arbeit, Grund, Abschläge; Wasser (Kosten aus) zeigt keine', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tippe(tester, find.byTooltip('Ein Jahr zurück'));
      expect(find.text('Kosten'), findsWidgets);
      expect(find.textContaining('Arbeit 1.116 €'), findsOneWidget);
      expect(find.textContaining('Nachzahlung ca. 138,00 €'), findsOneWidget);
      await tippe(tester, find.byTooltip('Zurück'));
      await oeffneVerlauf(tester, 'Wasser Wohnung');
      expect(find.textContaining('Nachzahlung'), findsNothing);
      expect(find.text('Kosten bisher'), findsNothing);
    });

    testWidgets('Solar: Ersparnis, Eigenverbrauch und Anschaffung im Verlauf', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Balkonkraftwerk');
      expect(find.text('Eigenverbrauch'), findsOneWidget);
      expect(find.text('Eingespeist'), findsOneWidget);
      expect(find.text('Ersparnis'), findsOneWidget);
      expect(find.text('Anschaffung'), findsOneWidget);
    });

    testWidgets('Stände: letzte Stände mit Unterschied, Bearbeiten öffnet den Dialog, Löschen fragt nach', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      expect(labelFinder('Letzte Stände'), findsOneWidget);
      expect(find.textContaining('(+300)'), findsWidgets);
      await tippe(tester, find.byType(PopupMenuButton<String>).first);
      await tippe(tester, find.text('Bearbeiten'));
      expect(find.text('Stand ändern'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      await tippe(tester, find.byType(PopupMenuButton<String>).first);
      await tippe(tester, find.text('Löschen'));
      expect(find.text('Stand löschen?'), findsOneWidget);
      expect(repo.aufrufe, isEmpty);
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(repo.aufrufe.single, startsWith('standLoeschen:'));
    });

    testWidgets('Zähler-Umschalter wechselt zwischen den Kacheln', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tippe(tester, find.widgetWithText(FilledButton, 'Stand eintragen').evaluate().isEmpty ? find.text('Balkonkraftwerk') : find.text('Balkonkraftwerk'));
      expect(labelFinder('Erzeugung (Solar)'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Verlauf bei 360 px und Textskala $skala', (tester) async {
        await start(tester, alle(stromFaellig: false), skala: skala);
        await oeffneVerlauf(tester, 'Strom');
        pruefeLayout(tester, 'Verlauf Skala $skala');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
        await warte(tester);
        pruefeLayout(tester, 'Verlauf unten Skala $skala');
      });
    }
  });

  group('Stand eintragen', () {
    Future<void> oeffneStand(WidgetTester tester) async => tippe(tester, find.widgetWithText(FilledButton, 'Stand eintragen'));

    testWidgets('plausibler Stand: sofort Verbrauch und Pro Tag, Speichern schreibt in den Zähler (Tausendstel)', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneStand(tester);
      expect(find.text('Zählerstand'), findsOneWidget);
      await eingeben(tester, 'Zählerstand in kWh', '13.230,5');
      await warte(tester);
      expect(find.text('Plausibel. Der Verbrauch liegt im üblichen Bereich.'), findsOneWidget);
      expect(find.text('Verbrauch seitdem'), findsOneWidget);
      expect(find.text('Pro Tag'), findsOneWidget);
      pruefeLayout(tester, 'Stand plausibel');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.erfasst, hasLength(1));
      expect(repo.erfasst.single.id, zStrom);
      expect(repo.erfasst.single.milli, 13230500);
      expect(repo.erfasst.single.datum, heuteTag());
    });

    testWidgets('zu niedriger Stand: Zählerwechsel-Verdacht, Speichern erst nach Bestätigung', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneStand(tester);
      await eingeben(tester, 'Zählerstand in kWh', '100');
      await warte(tester);
      expect(find.textContaining('niedriger als der letzte'), findsOneWidget);
      expect(find.text('Zähler wurde gewechselt'), findsOneWidget);
      final speichern = find.widgetWithText(FilledButton, 'Speichern');
      expect(tester.widget<FilledButton>(speichern).onPressed, isNull);
      await tippe(tester, find.text('Ich habe geprüft, der Stand stimmt'));
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNotNull);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.erfasst.single.milli, 100000);
    });

    testWidgets('verdrehte Ziffern: ein Sprung weit über dem Üblichen wird gemeldet', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneStand(tester);
      await eingeben(tester, 'Zählerstand in kWh', '95000');
      await warte(tester);
      expect(find.textContaining('Haben sich Ziffern verdreht?'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNull);
    });

    testWidgets('Eingabe, die keine Zahl ist: Fehlertext, Speichern gesperrt', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneStand(tester);
      await eingeben(tester, 'Zählerstand in kWh', '1,2,3');
      await warte(tester);
      expect(find.textContaining('Gib den Stand als Zahl ein'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNull);
    });

    testWidgets('Zählerwahl: ein anderer Zähler wird abgefragt', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneStand(tester);
      await tippe(tester, find.bySemanticsLabel('Balkonkraftwerk'));
      await eingeben(tester, 'Zählerstand in kWh', '1630');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.erfasst.single.id, zSolar);
    });

    testWidgets('Alle Wasserzähler ablesen: die Zähler nacheinander, ein Datum, jeder Stand wird sofort gespeichert', (tester) async {
      await start(tester, datenAus([wasser(zKalt1, 'Kaltwasser Etage'), wasser(zKalt2, 'Kaltwasser Waschkeller', start: 50, proMonat: 2), wasser(zWarm, 'Warmwasser Etage', art: ZaehlerArt.warmwasser, start: 20, proMonat: 1)]));
      // die Gruppe "Wasser Wohnung" fasst alle drei zusammen (Kalt und Warm bilden je eine Gruppe, siehe Übersichtslogik): hier genügt die Kaltwasser-Gruppe
      await tippe(tester, find.text('Alle Wasserzähler ablesen').first);
      expect(labelFinder('Zähler 1 von 2'), findsOneWidget);
      expect(find.text('Kaltwasser Etage'), findsOneWidget);
      await eingeben(tester, 'Zählerstand in m³', '222,5');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern und weiter'));
      expect(repo.erfasst.single.id, zKalt1);
      expect(labelFinder('Zähler 2 von 2'), findsOneWidget);
      expect(find.text('Kaltwasser Waschkeller'), findsOneWidget);
      await eingeben(tester, 'Zählerstand in m³', '131,5');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.erfasst.map((e) => e.id), [zKalt1, zKalt2]);
      expect(repo.erfasst[0].datum, repo.erfasst[1].datum);
      expect(find.text('Zählerstand'), findsNothing); // zurück in der Übersicht
    });

    testWidgets('Fehler beim Speichern: Meldung ohne Inhalt, die Seite bleibt', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneStand(tester);
      await eingeben(tester, 'Zählerstand in kWh', '13240');
      repo.fehler = const StandUngueltig('Ein Zählerstand kann nicht in der Zukunft liegen.');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Ein Zählerstand kann nicht in der Zukunft liegen.'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Stand eintragen bei 360 px und Textskala $skala (mit Hinweisen)', (tester) async {
        await start(tester, alle(stromFaellig: false), skala: skala);
        await oeffneStand(tester);
        await eingeben(tester, 'Zählerstand in kWh', '100');
        await warte(tester);
        pruefeLayout(tester, 'Stand mit Hinweis Skala $skala');
      });
    }
  });

  group('Zähler einrichten', () {
    Future<void> oeffneEditor(WidgetTester tester) async => tippe(tester, find.byTooltip('Zähler hinzufügen'));

    testWidgets('Wasser neu: Name, Art, Rhythmus; Kosten sind standardmäßig aus; Speichern legt den Zähler an', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneEditor(tester);
      expect(find.text('Zähler einrichten'), findsWidgets);
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Kaltwasser Garten');
      await tippe(tester, find.text('Kaltwasser · m³'));
      await tippe(tester, find.text('Monatlich'));
      await tester.ensureVisible(find.byType(SwitchListTile).first);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Kosten rechnen')).value, isFalse);
      pruefeLayout(tester, 'Editor Wasser');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      final z = repo.angelegt.single;
      expect(z.art, ZaehlerArt.kaltwasser);
      expect(z.name, 'Kaltwasser Garten');
      expect(z.kosten, isFalse);
      expect(z.ablesung, const Ablesung.monatlich(1));
      expect(z.einheit, 'm³');
    });

    testWidgets('Strom neu: Kosten an, Preisstand hinzufügen (Arbeitspreis, Grund- und Zählergebühr), Abschlag, Warnschwelle, Startstand', (tester) async {
      await start(tester, datenAus(const []));
      await tippe(tester, find.widgetWithText(FilledButton, 'Zähler einrichten'));
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Strom Haus');
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Kosten rechnen')).value, isTrue);
      await tippe(tester, find.text('Preisstand hinzufügen'));
      expect(find.text('Der erste Preis gilt auch für frühere Zeiträume.'), findsOneWidget);
      expect(find.textContaining('Gilt ab 01.01.2026'), findsOneWidget, reason: 'der erste Preis beginnt vorbelegt am Jahresanfang, nicht heute');
      await eingeben(tester, 'Arbeitspreis in Euro je kWh', '0,31');
      await eingeben(tester, 'Grundgebühr in Euro im Jahr', '138');
      await eingeben(tester, 'Zählergebühr in Euro im Jahr', '24');
      await tippe(tester, find.text('Übernehmen'));
      expect(find.textContaining('0,31 € je kWh'), findsOneWidget);
      await eingeben(tester, 'Abschlag im Monat in Euro (optional)', '95');
      await tippe(tester, find.widgetWithText(SwitchListTile, 'Ungewöhnlich hohen Verbrauch melden'));
      await eingeben(tester, 'Aktueller Zählerstand in kWh (optional)', '48213,5');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      final z = repo.angelegt.single;
      expect(z.art, ZaehlerArt.strom);
      expect(z.preise.single.ab, '2026-01-01');
      expect(z.preise.single.arbeitspreis, 3100);
      expect(z.preise.single.grundgebuehrJahr, 13800);
      expect(z.preise.single.zaehlergebuehrJahr, 2400);
      expect(z.abschlag, 9500);
      expect(z.warnProzent, 30);
      expect(repo.erfasst.single.milli, 48213500);
      expect(repo.erfasst.single.id, 'neu1');
    });

    testWidgets('Solar: der Strompreis der Ersparnis wird aus dem ersten Stromzähler vorbelegt und ist änderbar', (tester) async {
      await start(tester, datenAus([strom()]));
      await oeffneEditor(tester);
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Balkonkraftwerk');
      await tippe(tester, find.text('Erzeugung (Solar) · kWh'));
      expect(labelFinder('Strompreis für die Ersparnis'), findsOneWidget);
      expect(find.textContaining('0,31 € je kWh'), findsOneWidget); // vorbelegt aus dem Stromzähler
      expect(find.textContaining('Grund '), findsNothing); // beim Solarzähler nur der Arbeitspreis
      expect(find.textContaining('Grund-'), findsNothing);
      // ändern: den Preisstand antippen
      await tippe(tester, find.textContaining('0,31 € je kWh'));
      await eingeben(tester, 'Arbeitspreis in Euro je kWh', '0,35');
      await tippe(tester, find.text('Übernehmen'));
      expect(find.textContaining('0,35 € je kWh'), findsOneWidget);
      await eingeben(tester, 'Anschaffungspreis der Anlage in Euro', '449');
      await eingeben(tester, 'Eigenverbrauch in Prozent', '80');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      final z = repo.angelegt.single;
      expect(z.art, ZaehlerArt.erzeugung);
      expect(z.preise.single.arbeitspreis, 3500);
      expect(z.anlagenkosten, 44900);
      expect(z.eigenverbrauchBp, 8000);
      expect(z.gruppe, '');
      pruefeLayout(tester, 'Editor Solar');
    });

    testWidgets('ohne Name oder mit unstimmigem Eigenverbrauch: Fehlertext, nichts wird geschrieben', (tester) async {
      await start(tester, datenAus(const []));
      await tippe(tester, find.widgetWithText(FilledButton, 'Zähler einrichten'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Gib dem Zähler einen Namen.'), findsOneWidget);
      expect(repo.angelegt, isEmpty);
    });

    testWidgets('Bearbeiten: Felder sind gefüllt; Gruppe, Ort und Abrechnungsperiode lassen sich ändern', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      await tippe(tester, find.text('Zähler bearbeiten').first);
      expect(find.widgetWithText(TextField, 'Name (zum Beispiel Strom Haus)'), findsOneWidget);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Name (zum Beispiel Strom Haus)')).controller!.text, 'Strom');
      await tippe(tester, find.text('Keller'));
      await tippe(tester, find.text('Eigene (ab Tag und Monat)'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Änderungen speichern'));
      final g = repo.geaendert.single;
      expect(g.id, zStrom);
      expect(g.inhalt.ort, 'Keller');
      expect(g.inhalt.periodeMonat, 3);
      expect(g.inhalt.preise, hasLength(1)); // der Tarif bleibt
    });

    testWidgets('Archivieren und Löschen fragen nach; Löschen empfiehlt das Archivieren', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      await tippe(tester, find.text('Zähler bearbeiten').first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2500));
      await warte(tester);
      await tippe(tester, find.text('Zähler endgültig löschen'));
      expect(find.text('Zähler endgültig löschen?'), findsOneWidget);
      expect(find.textContaining('Besser: archivieren'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(repo.aufrufe, isEmpty);
      await tippe(tester, find.textContaining('Archivieren (die Stände bleiben)'));
      expect(find.text('Zähler archivieren?'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Archivieren'));
      expect(repo.aufrufe, ['archivieren:$zStrom']);
    });

    testWidgets('Endgültig löschen: erst nach der Bestätigung', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      await tippe(tester, find.text('Zähler bearbeiten').first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2500));
      await warte(tester);
      await tippe(tester, find.text('Zähler endgültig löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Endgültig löschen'));
      expect(repo.aufrufe, ['loeschen:$zStrom']);
    });

    testWidgets('Zähler wechseln: Endstand und Startstand, der Verbrauch läuft weiter', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      await tippe(tester, find.text('Zähler bearbeiten').first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2500));
      await warte(tester);
      await tippe(tester, find.textContaining('Zähler wechseln'));
      expect(find.text('Zähler wechseln'), findsWidgets);
      // Endstand unter dem letzten Stand: abgelehnt
      await eingeben(tester, 'Endstand des alten Zählers in kWh', '10');
      await tippe(tester, find.widgetWithText(FilledButton, 'Wechseln'));
      expect(find.textContaining('Der Endstand darf nicht kleiner sein'), findsOneWidget);
      expect(repo.wechsel, isEmpty);
      await eingeben(tester, 'Endstand des alten Zählers in kWh', '13300');
      await eingeben(tester, 'Startstand des neuen Zählers in kWh', '0');
      await tippe(tester, find.widgetWithText(FilledButton, 'Wechseln'));
      expect(repo.wechsel.single, (id: zStrom, ende: 13300000, start: 0));
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Editor bei 360 px und Textskala $skala', (tester) async {
        await start(tester, alle(stromFaellig: false), skala: skala);
        await tippe(tester, find.byTooltip('Zähler hinzufügen'));
        pruefeLayout(tester, 'Editor Skala $skala');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
        await warte(tester);
        pruefeLayout(tester, 'Editor unten Skala $skala');
      });
    }
  });

  group('PDF-Bericht', () {
    testWidgets('Auswahl, Vorschau und Erzeugen: das PDF geht an den Speichern-Dialog, ohne Netz', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await tippe(tester, find.byTooltip('Bericht als PDF'));
      expect(find.text('Bericht'), findsWidgets);
      expect(labelFinder('Vorschau'), findsOneWidget);
      const jahr = 2026;
      await tippe(tester, find.byTooltip('Ein Jahr zurück'));
      expect(find.text('${jahr - 1}'), findsOneWidget);
      pruefeLayout(tester, 'Bericht');
      await tippe(tester, find.widgetWithText(FilledButton, 'PDF erstellen und speichern'));
      expect(gespeichert, hasLength(1));
      expect(gespeichert.single.name, 'zaehlerbericht.pdf');
      expect(String.fromCharCodes(gespeichert.single.bytes.sublist(0, 5)), '%PDF-');
      expect(find.textContaining('Der Bericht ist erstellt'), findsOneWidget);
    });

    testWidgets('ohne gewählten Zähler oder ohne Inhalt ist der Knopf gesperrt; eigener Zeitraum braucht beide Tage', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await tippe(tester, find.byTooltip('Bericht als PDF'));
      Finder knopf() => find.widgetWithText(FilledButton, 'PDF erstellen und speichern');
      expect(tester.widget<FilledButton>(knopf()).onPressed, isNotNull);
      await tippe(tester, find.text('Stände'));
      await tippe(tester, find.text('Verbrauch je Monat'));
      expect(tester.widget<FilledButton>(knopf()).onPressed, isNull);
      expect(find.textContaining('Wähle mindestens „Stände“'), findsOneWidget);
      await tippe(tester, find.text('Stände'));
      expect(tester.widget<FilledButton>(knopf()).onPressed, isNotNull);
      await tippe(tester, find.text('Eigener Zeitraum'));
      expect(tester.widget<FilledButton>(knopf()).onPressed, isNull);
      expect(find.text('Von wählen'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Bericht bei 360 px und Textskala $skala', (tester) async {
        await start(tester, alle(stromFaellig: false), skala: skala);
        await tippe(tester, find.byTooltip('Bericht als PDF'));
        pruefeLayout(tester, 'Bericht Skala $skala');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
        await warte(tester);
        pruefeLayout(tester, 'Bericht unten Skala $skala');
      });
    }

    testWidgets('Aus dem Verlauf vorgewählt: nur dieser Zähler', (tester) async {
      await start(tester, alle(stromFaellig: false));
      await oeffneVerlauf(tester, 'Strom');
      await tippe(tester, find.byTooltip('Bericht als PDF'));
      await tippe(tester, find.widgetWithText(FilledButton, 'PDF erstellen und speichern'));
      expect(gespeichert, hasLength(1));
    });
  });

  group('Rollen', () {
    testWidgets('Elternteil und Admin: Eintrag im Mehr-Blatt mit Zahl der fälligen Ablesungen', (tester) async {
      for (final rolle in ['parent', 'admin']) {
        await start(tester, alle(), role: rolle, zumBereichGehen: false);
        final leiste = find.byType(NavigationBar);
        await tester.tap(find.descendant(of: leiste, matching: find.text('Mehr')));
        await warte(tester);
        expect(find.byKey(const ValueKey('mehr:zaehler')), findsOneWidget, reason: rolle);
        expect(find.bySemanticsLabel(RegExp(r'^Zähler, 1 Hinweis')), findsOneWidget, reason: rolle);
        // das Feld "Mehr" trägt die Zahl mit (Strom ist fällig)
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    });

    testWidgets('Kind: kein Eintrag im Mehr-Blatt, nichts am Feld Mehr, keine Startseiten-Kachel', (tester) async {
      await start(tester, alle(), role: 'child', zumBereichGehen: false);
      expect(labelFinder('Ablesen fällig'), findsNothing);
      expect(find.textContaining('Zähler warten auf eine Ablesung'), findsNothing);
      expect(find.textContaining('Zähler wartet auf eine Ablesung'), findsNothing);
      final leiste = find.byType(NavigationBar);
      await tester.tap(find.descendant(of: leiste, matching: find.text('Mehr')));
      await warte(tester);
      expect(find.byKey(const ValueKey('mehr:zaehler')), findsNothing);
      expect(find.text('Zähler'), findsNothing);
      expect(find.byKey(const ValueKey('mehr:medikamente')), findsOneWidget); // das Blatt selbst ist da
    });

    testWidgets('Kind: Deep-Link, Erinnerung und Bereichswahl führen nirgends hinein', (tester) async {
      final (_, c) = await start(tester, alle(), role: 'child', zumBereichGehen: false);
      c.read(zaehlerOeffnenProvider.notifier).anfordern();
      await warte(tester);
      expect(find.text('Zähler'), findsNothing);
      expect(find.text('Noch keine Zähler'), findsNothing);
      expect(find.text('Strom'), findsNothing);
      // der Bereich der Desktop-Shell wird nie gewählt: wer ihn setzt, landet wieder auf der Startseite
      c.read(shellTabProvider.notifier).waehlen(kZaehlerTab);
      await warte(tester);
      expect(c.read(shellTabProvider), 0);
      expect(c.read(zaehlerDarfProvider), isFalse);
    });

    testWidgets('Desktop: Seitenleiste mit Eintrag Zähler (Admin) und ohne (Kind)', (tester) async {
      await start(tester, alle(), groesse: const Size(1200, 800), zumBereichGehen: false);
      expect(find.text('Zähler'), findsOneWidget); // der Eintrag der Seitenleiste
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await start(tester, alle(), role: 'child', groesse: const Size(1200, 800), zumBereichGehen: false);
      expect(find.text('Zähler'), findsNothing);
      expect(find.text('Medikamente'), findsWidgets);
    });

    testWidgets('Desktop: der Bereich zeigt die Übersicht', (tester) async {
      final (_, c) = await start(tester, alle(), groesse: const Size(1200, 800));
      expect(find.text('Balkonkraftwerk'), findsOneWidget);
      expect(c.read(shellTabProvider), kZaehlerTab);
      pruefeLayout(tester, 'Desktop Zähler');
    });

    testWidgets('Rollenwechsel zum Kind: Seitenleiste, Bereich und Mehr-Eintrag verschwinden, die Shell fällt auf die Startseite zurück', (tester) async {
      final darf = NotifierProvider<_Schalter, bool>(_Schalter.new);
      repo = ZaehlerRepoAttrappe();
      final env = await angemeldeteUmgebung();
      env.extraOverrides.addAll([
        erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
        zaehlerTestUhr,
        zaehlerDatenProvider.overrideWith((ref) => alle().copyMitDarf(ref.watch(darf))),
        zaehlerDarfProvider.overrideWith((ref) => ref.watch(darf)),
        zaehlerRepositoryProvider.overrideWithValue(repo),
      ]);
      final c = await starteApp(tester, env, groesse: const Size(1200, 800));
      c.read(shellTabProvider.notifier).waehlen(kZaehlerTab);
      await warte(tester);
      expect(find.text('Zähler'), findsWidgets);
      expect(find.text('Balkonkraftwerk'), findsOneWidget);
      // die Person wird zum Kind (die Rolle kommt vom Server, hier der Schalter)
      c.read(darf.notifier).setzen(false);
      await warte(tester);
      expect(c.read(shellTabProvider), 0);
      expect(find.text('Balkonkraftwerk'), findsNothing);
      expect(find.text('Zähler'), findsNothing);
      // und wieder zurück: der Eintrag ist wieder da
      c.read(darf.notifier).setzen(true);
      await warte(tester);
      expect(find.text('Zähler'), findsOneWidget);
    });

    testWidgets('Die Daten eines Kindes sind leer: der Datenanbieter liest für Kinder nichts (ohne Überschreibung)', (tester) async {
      final env = await angemeldeteUmgebung(role: 'child');
      final c = await starteApp(tester, env);
      final d = c.read(zaehlerDatenProvider);
      expect(d.darf, isFalse);
      expect(d.reihen, isEmpty);
      expect(d.eintraege, isEmpty);
      expect(c.read(zaehlerFaelligProvider), 0);
    });

    testWidgets('Startseiten-Kachel "Ablesen fällig": Eltern sehen sie nur, wenn etwas ansteht', (tester) async {
      await start(tester, alle(), role: 'parent', groesse: const Size(360, 2400), zumBereichGehen: false);
      expect(labelFinder('Ablesen fällig'), findsOneWidget);
      expect(find.textContaining('wartet auf eine Ablesung'), findsOneWidget);
      pruefeLayout(tester, 'Startseite mit Kachel');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await start(tester, alle(stromFaellig: false), role: 'parent', zumBereichGehen: false);
      expect(labelFinder('Ablesen fällig'), findsNothing);
    });
  });
}
