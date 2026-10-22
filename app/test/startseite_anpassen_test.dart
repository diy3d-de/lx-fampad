// Startseite anpassen: Kacheln verschieben (Handy: gedrückt halten und ziehen, Desktop-Raster: ziehen), Seite "Startseite anpassen" mit
// Pfeilen und Schaltern, Speichern und Laden (lokal in sync_meta, getrennt je Layout), Fehler des Speichers, 360 px bei Textskala 1.5, Semantics.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction, SemanticsNode;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart' show localDataWiperProvider;
import 'package:lx_fampad/data/calendar/feiertage.dart' show FeiertageSpeicher, MemoryFeiertageSpeicher, kFeiertageSchluessel;
import 'package:lx_fampad/data/startseite/startseite_logik.dart';
import 'package:lx_fampad/data/startseite/startseite_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/home/startseite_anpassen_screen.dart';
import 'package:lx_fampad/features/home/startseite_anpassen_zeile.dart';
import 'package:lx_fampad/features/home/startseite_verfuegbar.dart';
import 'package:lx_fampad/features/home/startseite_widgets.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  const mKey = 'startseite_reihenfolge_mobil';
  const mAus = 'startseite_ausgeblendet_mobil';
  const dKey = 'startseite_reihenfolge_desktop';

  Future<ProviderContainer> start(
    WidgetTester tester, {
    MemoryFeiertageSpeicher? speicher,
    Size groesse = const Size(360, 800),
    double skala = 1.0,
    FeiertageSpeicher? eigener,
    List<Override> ueberschreibungen = const [],
  }) async {
    final env = await angemeldeteUmgebung();
    env.speicher = eigener ?? speicher ?? MemoryFeiertageSpeicher('nein');
    env.extraOverrides.addAll(ueberschreibungen);
    return starteApp(tester, env, groesse: groesse, skala: skala);
  }

  /// Obere Kante des Labels einer Kachel (die Beschriftungen stehen in Großbuchstaben).
  double oben(WidgetTester tester, String label) => tester.getTopLeft(find.text(label.toUpperCase())).dy;

  /// Reihenfolge der gefundenen Beschriftungen von oben nach unten.
  List<String> folge(WidgetTester tester, List<String> labels) {
    final l = [for (final x in labels) if (find.text(x.toUpperCase()).evaluate().isNotEmpty) x];
    l.sort((a, b) => oben(tester, a).compareTo(oben(tester, b)));
    return l;
  }

  /// Gedrückt halten, dann ziehen und loslassen (Handy: langes Drücken; Maus: gedrückt halten).
  Future<void> ziehe(WidgetTester tester, Offset von, Offset nach, {int schritte = 14}) async {
    final g = await tester.startGesture(von);
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 1; i <= schritte; i++) {
      await g.moveTo(von + (nach - von) * (i / schritte));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pump(const Duration(milliseconds: 200));
    await g.up();
    await warte(tester);
  }

  const mobilLabels = ['// einkaufsliste', '// als nächstes', '// aufgaben', '// standort'];

  group('Handy-Startseite', () {
    testWidgets('Standardreihenfolge und die Zeile "Startseite anpassen"', (tester) async {
      await start(tester);
      expect(folge(tester, mobilLabels), mobilLabels);
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Startseite anpassen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Aufgaben gedrückt halten und über die Einkaufsliste ziehen: neue Reihenfolge, gespeichert, nach Neustart wieder da', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: speicher);
      final von = tester.getCenter(find.text('// AUFGABEN'));
      final nach = Offset(von.dx, tester.getTopLeft(find.text('// EINKAUFSLISTE')).dy - 6);
      await ziehe(tester, von, nach);
      expect(folge(tester, mobilLabels), ['// aufgaben', '// einkaufsliste', '// als nächstes', '// standort']);
      // Geburtstage (ohne Treffer), Müll und Wetter (nicht verfügbar) werden nicht gezeichnet und behalten ihren Platz in der Liste
      expect(kennungenAusText(speicher.werte[mKey]), ['schnellzugriff', 'aufgaben', 'einkauf', 'geburtstage', 'termine', 'muell', 'wetter', 'standort']);
      // der Desktop-Schlüssel bleibt unberührt
      expect(speicher.werte.containsKey(dKey), isFalse);
      // Neustart mit demselben Speicher
      await tester.pumpWidget(const SizedBox());
      await start(tester, speicher: speicher);
      expect(folge(tester, mobilLabels), ['// aufgaben', '// einkaufsliste', '// als nächstes', '// standort']);
    });

    testWidgets('ein Tipp auf eine Kachel öffnet sie weiterhin (kein Ziehen)', (tester) async {
      await start(tester);
      await tester.tap(find.text('// AUFGABEN'));
      await warte(tester);
      expect(find.text('// AUFGABEN'), findsNothing); // Aufgaben-Tab statt Startseite
    });

    testWidgets('normales Wischen über eine Kachel scrollt die Seite und ordnet nichts um', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: speicher, groesse: const Size(360, 500));
      final vorher = oben(tester, '// EINKAUFSLISTE');
      await tester.drag(find.text('// EINKAUFSLISTE'), const Offset(0, -150));
      await warte(tester);
      expect(oben(tester, '// EINKAUFSLISTE'), lessThan(vorher - 100)); // die Seite hat gescrollt
      expect(speicher.werte.containsKey(mKey), isFalse);
      expect(folge(tester, mobilLabels), mobilLabels.take(3));
    });

    testWidgets('gespeicherte Reihenfolge mit Unbekanntem und fehlenden Kacheln: unbekannt weg, neue ans Ende', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein', {mKey: '["standort","gibt-es-nicht","aufgaben"]'});
      await start(tester, speicher: speicher);
      // übrige Kacheln kommen in Standardreihenfolge hinter die gemerkten
      expect(folge(tester, mobilLabels), ['// standort', '// aufgaben', '// einkaufsliste', '// als nächstes']);
    });

    testWidgets('ausgeblendete Kacheln fehlen auf der Startseite', (tester) async {
      await start(tester, speicher: MemoryFeiertageSpeicher('nein', {mAus: '["aufgaben","unbekannt"]'}));
      expect(find.text('// AUFGABEN'), findsNothing);
      expect(find.text('// EINKAUFSLISTE'), findsOneWidget);
    });

    testWidgets('defekter gespeicherter Wert: Standardreihenfolge', (tester) async {
      await start(tester, speicher: MemoryFeiertageSpeicher('nein', {mKey: '{kaputt', mAus: '17'}));
      expect(folge(tester, mobilLabels), mobilLabels);
    });

    testWidgets('Speicher nicht lesbar und nicht schreibbar: Standardreihenfolge, Ändern gilt bis zum Schließen', (tester) async {
      final c = await start(tester, eigener: _KaputterSpeicher());
      expect(folge(tester, mobilLabels), mobilLabels);
      await c.read(startseiteMobilProvider.notifier).schieben(['einkauf', 'termine', 'aufgaben', 'standort'], 'aufgaben', -2);
      await warte(tester);
      expect(folge(tester, mobilLabels), ['// aufgaben', '// einkaufsliste', '// als nächstes', '// standort']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('die Kacheln erscheinen erst, wenn der gespeicherte Stand gelesen ist (kein Sprung)', (tester) async {
      final env = await angemeldeteUmgebung();
      final langsam = _LangsamerSpeicher({mKey: '["standort"]'});
      env.speicher = langsam;
      await starteApp(tester, env);
      // zum ersten Bild war der Speicher noch nicht fertig: nichts gezeichnet, also auch keine Standard-Reihenfolge, die dann springt
      expect(find.text('// STANDORT'), findsNothing);
      langsam.freigeben();
      await warte(tester);
      expect(folge(tester, mobilLabels).first, '// standort');
    });
  });

  test('Daten leeren (Abmelden mit Datenwipe): die gemerkte Reihenfolge ist weg, die nächste Person erbt sie nicht', () async {
    final speicher = MemoryFeiertageSpeicher('nein', {mKey: '["standort"]', mAus: '["aufgaben"]'});
    final env = TestUmgebung(FakeServer())
      ..speicher = speicher
      ..wiperEcht = true;
    final c = env.container();
    addTearDown(c.dispose);
    c.listen(startseiteMobilProvider, (_, _) {});
    await pumpEventQueue();
    expect(c.read(startseiteMobilProvider).ausgeblendet, {'aufgaben'});
    expect(c.read(startseiteMobilProvider).reihenfolge.first, 'standort');
    speicher.werte.clear(); // wie sync_meta nach dem Leeren der Datenbank
    await c.read(localDataWiperProvider)();
    await pumpEventQueue();
    expect(c.read(startseiteMobilProvider).reihenfolge, StartLayout.mobil.standard);
    expect(c.read(startseiteMobilProvider).ausgeblendet, isEmpty);
  });

  group('Seite "Startseite anpassen" (Handy)', () {
    // hoch genug, dass alle Zeilen der (lazy gebauten) Liste da sind; die Layout-Tests nehmen die echte Handyhöhe
    Future<ProviderContainer> oeffnen(WidgetTester tester, {MemoryFeiertageSpeicher? speicher, double skala = 1.0, Size groesse = const Size(360, 1800)}) async {
      final c = await start(tester, speicher: speicher, skala: skala, groesse: groesse);
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Startseite anpassen'));
      await warte(tester);
      return c;
    }

    testWidgets('listet die Kacheln (auch die leeren) mit fester Warnkarte oben; ohne Müll und Wetter', (tester) async {
      await oeffnen(tester);
      expect(find.byType(StartseiteAnpassenScreen), findsOneWidget);
      expect(find.text('Startseite anpassen'), findsOneWidget);
      expect(find.text('Bin ich abgesichert?'), findsOneWidget);
      expect(find.text('fest'), findsOneWidget);
      for (final id in ['schnellzugriff', 'einkauf', 'termine', 'geburtstage', 'aufgaben', 'standort']) {
        expect(find.byKey(ValueKey('an:$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('an:muell')), findsNothing);
      expect(find.byKey(const ValueKey('an:wetter')), findsNothing);
      expect(find.text('gerade nichts anzuzeigen'), findsOneWidget); // Geburtstage ohne Termine
    });

    testWidgets('Pfeil runter und hoch ordnen um, speichern, die Pfeile an den Enden sind aus', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await oeffnen(tester, speicher: speicher);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('hoch:schnellzugriff'))).onPressed, isNull);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('runter:standort'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('runter:schnellzugriff')));
      await warte(tester);
      expect(kennungenAusText(speicher.werte[mKey]), ['einkauf', 'schnellzugriff', 'termine', 'geburtstage', 'aufgaben', 'muell', 'wetter', 'standort']);
      await tester.tap(find.byKey(const ValueKey('hoch:standort')));
      await warte(tester);
      // Müll und Wetter (nicht angeboten) bleiben auf ihren Plätzen, Standort und Aufgaben tauschen die ihren
      expect(kennungenAusText(speicher.werte[mKey]), ['einkauf', 'schnellzugriff', 'termine', 'geburtstage', 'standort', 'muell', 'wetter', 'aufgaben']);
    });

    testWidgets('Schalter blendet aus und wieder ein; Zurücksetzen stellt Standard her; Fertig schließt', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      final c = await oeffnen(tester, speicher: speicher);
      await tester.tap(find.byKey(const ValueKey('an:standort')));
      await warte(tester);
      expect(kennungenAusText(speicher.werte[mAus]), ['standort']);
      expect(find.text('ausgeblendet'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('runter:schnellzugriff')));
      await warte(tester);
      await tester.tap(find.text('Zurücksetzen'));
      await warte(tester);
      expect(c.read(startseiteMobilProvider).ausgeblendet, isEmpty);
      expect(c.read(startseiteMobilProvider).reihenfolge, StartLayout.mobil.standard);
      // die gespeicherten Werte werden gelöscht (nicht durch die Standardlisten ersetzt)
      expect(speicher.werte.containsKey(mKey), isFalse);
      expect(speicher.werte.containsKey(mAus), isFalse);
      await tester.tap(find.byKey(const ValueKey('an:standort')));
      await warte(tester);
      await tester.tap(find.byKey(const ValueKey('an:standort')));
      await warte(tester);
      await tester.tap(find.text('Fertig'));
      await warte(tester);
      expect(find.byType(StartseiteAnpassenScreen), findsNothing);
      expect(find.text('// STANDORT'), findsOneWidget);
    });

    testWidgets('Ausblenden wirkt auf der Startseite dahinter, Einblenden bringt die Kachel an ihre Stelle zurück', (tester) async {
      await oeffnen(tester);
      await tester.tap(find.byKey(const ValueKey('an:aufgaben')));
      await warte(tester);
      await tester.tap(find.text('Fertig'));
      await warte(tester);
      expect(find.text('// AUFGABEN'), findsNothing);
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Startseite anpassen'));
      await warte(tester);
      await tester.tap(find.byKey(const ValueKey('an:aufgaben')));
      await warte(tester);
      await tester.tap(find.text('Fertig'));
      await warte(tester);
      expect(folge(tester, mobilLabels), mobilLabels);
    });

    testWidgets('über das Profil erreichbar', (tester) async {
      await start(tester);
      await tester.tap(find.byTooltip('Profil und Sicherheit'));
      await warte(tester);
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Startseite anpassen'));
      await warte(tester);
      expect(find.byType(StartseiteAnpassenScreen), findsOneWidget);
    });

    testWidgets('Ziehen am Griff ordnet um', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await oeffnen(tester, speicher: speicher);
      final griff = find.descendant(of: find.byKey(const ValueKey('eintrag:standort')), matching: find.byIcon(Icons.drag_indicator));
      final von = tester.getCenter(griff);
      final ziel = tester.getCenter(find.descendant(of: find.byKey(const ValueKey('eintrag:einkauf')), matching: find.byIcon(Icons.drag_indicator)));
      final g = await tester.startGesture(von);
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(von + (Offset(von.dx, ziel.dy - 10) - von) * (i / 12));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await g.up();
      await warte(tester);
      expect(kennungenAusText(speicher.werte[mKey]), ['schnellzugriff', 'standort', 'einkauf', 'termine', 'geburtstage', 'muell', 'wetter', 'aufgaben']);
    });

    testWidgets('Semantics: Pfeile nennen Kachel, Position und Richtung', (tester) async {
      final handle = tester.ensureSemantics();
      await oeffnen(tester);
      expect(find.bySemanticsLabel('Kachel Einkaufsliste, Position 2 von 6, nach oben verschieben'), findsOneWidget);
      expect(find.bySemanticsLabel('Kachel Einkaufsliste, Position 2 von 6, nach unten verschieben'), findsOneWidget);
      expect(find.bySemanticsLabel('Kachel Standort anzeigen'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Bin ich abgesichert\\? Bleibt fest oben')), findsOneWidget);
      handle.dispose();
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('360 px, Textskala $skala: keine Layoutfehler, Touch-Ziele mindestens 44 px', (tester) async {
        await oeffnen(tester, skala: skala, groesse: const Size(360, 800));
        pruefeLayout(tester, 'Startseite anpassen');
        await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -600));
        await warte(tester);
        pruefeLayout(tester, 'Startseite anpassen (unten)');
      });
    }
  });

  group('Startseite 360 px, Textskala 1.5', () {
    testWidgets('Startseite mit Kacheln und Anpassen-Zeile: keine Layoutfehler', (tester) async {
      await start(tester, skala: 1.5);
      pruefeLayout(tester, 'Startseite');
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 200, scrollable: find.byType(Scrollable).first);
      pruefeLayout(tester, 'Startseite unten');
      expect(tester.getSize(find.byType(StartseiteAnpassenZeile)).height, greaterThanOrEqualTo(44));
    });

    testWidgets('Ziehen mit Textskala 1.5 funktioniert ebenso', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: speicher, skala: 1.5);
      final von = tester.getCenter(find.text('// ALS NÄCHSTES'));
      final nach = Offset(von.dx, tester.getTopLeft(find.text('// EINKAUFSLISTE')).dy - 6);
      await ziehe(tester, von, nach);
      expect(kennungenAusText(speicher.werte[mKey]), ['schnellzugriff', 'termine', 'einkauf', 'geburtstage', 'aufgaben', 'muell', 'wetter', 'standort']);
      expect(tester.takeException(), isNull);
    });
  });

  group('Desktop-Raster', () {
    const gross = Size(1440, 1500);
    const rasterLabels = ['// heute & morgen', '// chat · familie', '// einkaufsliste', '// zuletzt geteilt', '// aufgaben', '// familie & orte', '// standort'];

    testWidgets('Standardreihenfolge, Zeile "Startseite anpassen" unter dem Raster', (tester) async {
      await start(tester, groesse: gross);
      expect(folge(tester, rasterLabels).toSet(), rasterLabels.toSet());
      expect(oben(tester, '// heute & morgen'), lessThan(oben(tester, '// zuletzt geteilt')));
      expect(find.text('Startseite anpassen'), findsOneWidget);
      expect(oben(tester, '// standort'), lessThan(tester.getTopLeft(find.text('Startseite anpassen')).dy));
    });

    testWidgets('Kachel ziehen: Zielstelle als Lücke, Ablegen sortiert um und speichert nur den Desktop-Schlüssel', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: speicher, groesse: gross);
      final von = tester.getCenter(find.text('// AUFGABEN'));
      final ziel = tester.getCenter(find.text('// HEUTE & MORGEN')) + const Offset(0, 60);
      final g = await tester.startGesture(von);
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(von + (ziel - von) * (i / 12));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 100));
      // während des Ziehens: gestrichelte Lücke, die gehobene Kachel folgt dem Zeiger
      expect(find.byType(StartseiteLuecke), findsOneWidget);
      expect(find.byType(StartseiteGehoben), findsOneWidget);
      await g.up();
      await warte(tester);
      expect(find.byType(StartseiteLuecke), findsNothing);
      // auch nicht angezeigte Kacheln (Müll, Wetter) behalten ihren Eintrag
      expect(kennungenAusText(speicher.werte[dKey]), ['aufgaben', 'termine', 'chat', 'einkauf', 'dateien', 'familie', 'standort', 'muell', 'wetter']);
      expect(speicher.werte.containsKey(mKey), isFalse);
      expect(oben(tester, '// aufgaben'), lessThanOrEqualTo(oben(tester, '// heute & morgen')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('am unteren Rand des Fensters scrollt die Seite beim Ziehen mit', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: speicher, groesse: const Size(1440, 600));
      final scroll = tester.state<ScrollableState>(find.descendant(of: find.byType(DesktopHome), matching: find.byType(Scrollable)).first);
      expect(scroll.position.pixels, 0);
      final von = tester.getCenter(find.text('// HEUTE & MORGEN'));
      final g = await tester.startGesture(von);
      await tester.pump(const Duration(milliseconds: 700));
      await g.moveTo(von + const Offset(30, 60));
      await tester.pump(const Duration(milliseconds: 40));
      await g.moveTo(Offset(von.dx, 590));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(scroll.position.pixels, greaterThan(150));
      await g.up();
      await warte(tester);
      // abgelegt wurde dort, wo der Zeiger nach dem Mitscrollen steht (weiter hinten), nicht am alten Platz
      final r = kennungenAusText(speicher.werte[dKey])!;
      expect(r.indexOf('termine'), greaterThanOrEqualTo(3));
      expect(r.toSet(), StartLayout.desktop.standard.toSet());
      expect(tester.takeException(), isNull);
    });

    testWidgets('neu gestartet: gespeicherte Reihenfolge und ausgeblendete Kacheln gelten', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein', {dKey: '["standort","chat"]', 'startseite_ausgeblendet_desktop': '["dateien"]'});
      await start(tester, speicher: speicher, groesse: gross);
      expect(find.text('// ZULETZT GETEILT'), findsNothing);
      expect(oben(tester, '// standort'), lessThanOrEqualTo(oben(tester, '// chat · familie')));
      expect(oben(tester, '// chat · familie'), lessThanOrEqualTo(oben(tester, '// heute & morgen')));
    });

    testWidgets('ein Klick auf eine Kachel öffnet sie weiterhin', (tester) async {
      await start(tester, groesse: gross);
      await tester.tap(find.text('// STANDORT'));
      await warte(tester);
      expect(find.text('// MEIN STANDORT'), findsOneWidget);
    });

    testWidgets('Anpassen-Seite im Desktop: im Inhaltsbereich, mit Seitenleiste; Schalter blendet die Kachel aus', (tester) async {
      final speicher = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: speicher, groesse: gross);
      await tester.tap(find.text('Startseite anpassen'));
      await warte(tester);
      expect(find.byType(StartseiteAnpassenScreen), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget); // Seitenleiste bleibt
      expect(find.byKey(const ValueKey('an:dateien')), findsOneWidget);
      expect(find.byKey(const ValueKey('an:schnellzugriff')), findsNothing); // gehört zur Handy-Liste
      // breit: Pfeile in derselben Zeile (kein Positionstext der schmalen Variante)
      expect(find.textContaining('position'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('an:dateien')));
      await warte(tester);
      expect(kennungenAusText(speicher.werte['startseite_ausgeblendet_desktop']), ['dateien']);
      await tester.tap(find.text('Fertig'));
      await warte(tester);
      expect(find.byType(StartseiteAnpassenScreen), findsNothing);
      expect(find.text('// ZULETZT GETEILT'), findsNothing);
      pruefeLayout(tester, 'Desktop nach Anpassen');
    });
  });

  testWidgets('Desktop 1200 px, Textskala 1.5: Raster ohne Layoutfehler', (tester) async {
    await start(tester, groesse: const Size(1200, 2400), skala: 1.5);
    expect(tester.takeException(), isNull);
    // die Zellenhöhe wächst mit der Textskala (300 * 1.5) und alle Kacheln bleiben im Raster
    for (final z in find.byType(LongPressDraggable<String>).evaluate()) {
      expect(tester.getSize(find.byWidget(z.widget)).height, 450);
    }
    expect(find.byType(LongPressDraggable<String>), findsNWidgets(7));
  });

  group('Änderungen und Laden', () {
    test('eine Änderung vor dem Ende des Lesens überschreibt den gespeicherten Stand nicht, sondern wird darauf angewendet', () async {
      final langsam = _LangsamerSpeicher({mKey: '["standort","aufgaben"]'});
      final env = TestUmgebung(FakeServer())..speicher = langsam;
      final c = env.container();
      addTearDown(c.dispose);
      c.listen(startseiteMobilProvider, (_, _) {});
      final n = c.read(startseiteMobilProvider.notifier);
      expect(c.read(startseiteMobilProvider).geladen, isFalse);
      final f = n.anzeigen('einkauf', false); // der Speicher liefert noch nichts
      await pumpEventQueue();
      expect(c.read(startseiteMobilProvider).geladen, isFalse, reason: 'die Änderung wartet');
      langsam.freigeben();
      await f;
      await pumpEventQueue();
      final a = c.read(startseiteMobilProvider);
      expect(a.reihenfolge.take(2), ['standort', 'aufgaben']);
      expect(a.ausgeblendet, {'einkauf'});
      expect(kennungenAusText(langsam.werte[mKey])!.take(2), ['standort', 'aufgaben']);
      expect(kennungenAusText(langsam.werte[mAus]), ['einkauf']);
    });

    test('ein Lesevorgang, den ein invalidate (Datenwipe) überholt hat, verwirft sein Ergebnis', () async {
      final sp = _HandgesteuerterSpeicher();
      final env = TestUmgebung(FakeServer())..speicher = sp;
      final c = env.container();
      addTearDown(c.dispose);
      c.listen(startseiteMobilProvider, (_, _) {});
      await pumpEventQueue();
      expect(sp.offen, hasLength(1)); // erster Lesevorgang wartet (Wert: nichts gespeichert)
      sp.werte[mKey] = '["standort"]'; // inzwischen gespeichert
      c.invalidate(startseiteMobilProvider);
      c.read(startseiteMobilProvider);
      await pumpEventQueue();
      expect(sp.offen, hasLength(2));
      await sp.lasse(1); // neuer Lesevorgang: Reihenfolge
      await sp.lasse(2); // ... und Ausgeblendete
      expect(c.read(startseiteMobilProvider).reihenfolge.first, 'standort');
      await sp.lasse(0); // der alte kommt zu spät und darf nichts überschreiben
      await sp.lasse(3);
      expect(c.read(startseiteMobilProvider).reihenfolge.first, 'standort');
      expect(c.read(startseiteMobilProvider).geladen, isTrue);
    });

    test('eine Änderung ohne Wirkung schreibt nichts', () async {
      final sp = _ZaehlenderSpeicher();
      final env = TestUmgebung(FakeServer())..speicher = sp;
      final c = env.container();
      addTearDown(c.dispose);
      c.listen(startseiteMobilProvider, (_, _) {});
      await pumpEventQueue();
      final n = c.read(startseiteMobilProvider.notifier);
      await n.teilmengeOrdnen(StartLayout.mobil.standard);
      await n.anzeigen('standort', true);
      await n.schieben(StartLayout.mobil.standard, 'schnellzugriff', -1);
      expect(sp.schreibvorgaenge, 0);
      await n.anzeigen('standort', false);
      expect(sp.schreibvorgaenge, 2);
    });
  });

  testWidgets('beide Layouts sind früh gelesen: auf dem Handy ist auch der Desktop-Zustand schon geladen (kein leeres Raster beim Wechsel über 900 px)', (tester) async {
    final c = await start(tester);
    expect(c.read(startseiteMobilProvider).geladen, isTrue);
    expect(c.read(startseiteDesktopProvider).geladen, isTrue);
  });

  group('Kachel erscheint oder verschwindet während des Ziehens', () {
    testWidgets('Handy: Kachel wird aus- und wieder eingeblendet, während gezogen wird: keine Ausnahme, Liste bleibt stimmig', (tester) async {
      final c = await start(tester, groesse: const Size(360, 1400));
      final von = tester.getCenter(find.text('// AUFGABEN'));
      final g = await tester.startGesture(von);
      await tester.pump(const Duration(milliseconds: 700));
      await g.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 100));
      await c.read(startseiteMobilProvider.notifier).anzeigen('standort', false);
      await tester.pump(const Duration(milliseconds: 100));
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 100));
      await g.up();
      await warte(tester);
      expect(find.text('// STANDORT'), findsNothing);
      await c.read(startseiteMobilProvider.notifier).anzeigen('standort', true);
      await warte(tester);
      expect(find.text('// STANDORT'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(folge(tester, mobilLabels).toSet(), mobilLabels.toSet());
    });

    testWidgets('Desktop: die gezogene Kachel verschwindet: der Zug endet ohne Lücke, ohne Ausnahme und ohne Ablegen', (tester) async {
      final sp = _ZaehlenderSpeicher();
      final c = await start(tester, eigener: sp, groesse: const Size(1440, 1500));
      final g = await tester.startGesture(tester.getCenter(find.text('// AUFGABEN')));
      await tester.pump(const Duration(milliseconds: 700));
      await g.moveBy(const Offset(-200, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StartseiteLuecke), findsOneWidget);
      final davor = sp.schreibvorgaenge;
      await c.read(startseiteDesktopProvider.notifier).anzeigen('aufgaben', false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StartseiteLuecke), findsNothing);
      await g.up();
      await warte(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('// AUFGABEN'), findsNothing);
      expect(sp.schreibvorgaenge, davor + 2, reason: 'nur das Ausblenden wurde gespeichert, das Ablegen schreibt nichts');
      expect(find.byType(StartseiteLuecke), findsNothing);
    });

    testWidgets('Desktop: eine zweite Kachel kann nicht gleichzeitig gezogen werden', (tester) async {
      await start(tester, groesse: const Size(1440, 1500));
      final g1 = await tester.startGesture(tester.getCenter(find.text('// AUFGABEN')), pointer: 1);
      await tester.pump(const Duration(milliseconds: 700));
      await g1.moveBy(const Offset(-50, 0));
      final g2 = await tester.startGesture(tester.getCenter(find.text('// HEUTE & MORGEN')), pointer: 2);
      await tester.pump(const Duration(milliseconds: 700));
      await g2.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StartseiteGehoben), findsOneWidget);
      await g2.up();
      await g1.up();
      await warte(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('Desktop: Ablegen, Abbrechen, bedingte Kachel in der Mitte', () {
    const gross = Size(1440, 1500);
    const seitenleiste = Offset(60, 700);
    const reihe = ['// heute & morgen', '// chat · familie', '// einkaufsliste', '// zuletzt geteilt', '// aufgaben'];

    Future<TestGesture> zieheZu(WidgetTester tester, String von, String zu) async {
      final anfang = tester.getCenter(find.text(von));
      final ziel = tester.getCenter(find.text(zu)) + const Offset(0, 60);
      final g = await tester.startGesture(anfang);
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(anfang + (ziel - anfang) * (i / 12));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 100));
      return g;
    }

    testWidgets('Loslassen außerhalb (Seitenleiste): es gilt die zuletzt angezeigte Zielstelle', (tester) async {
      final sp = MemoryFeiertageSpeicher('nein');
      await start(tester, speicher: sp, groesse: gross);
      final g = await zieheZu(tester, '// AUFGABEN', '// HEUTE & MORGEN');
      await g.moveTo(seitenleiste);
      await tester.pump(const Duration(milliseconds: 100));
      await g.up();
      await warte(tester);
      expect(kennungenAusText(sp.werte[dKey])!.take(2), ['aufgaben', 'termine']);
      expect(find.byType(StartseiteLuecke), findsNothing);
    });

    testWidgets('Esc bricht den Zug ab: nichts wird gespeichert, die Reihenfolge bleibt', (tester) async {
      final sp = _ZaehlenderSpeicher();
      await start(tester, eigener: sp, groesse: gross);
      final davor = folge(tester, reihe);
      final g = await zieheZu(tester, '// AUFGABEN', '// HEUTE & MORGEN');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
      await g.up();
      await warte(tester);
      expect(sp.schreibvorgaenge, 0);
      expect(folge(tester, reihe), davor);
      expect(find.byType(StartseiteLuecke), findsNothing);
    });

    testWidgets('an Ort und Stelle loslassen: keine Änderung, nichts wird geschrieben', (tester) async {
      final sp = _ZaehlenderSpeicher();
      await start(tester, eigener: sp, groesse: gross);
      final von = tester.getCenter(find.text('// AUFGABEN'));
      await ziehe(tester, von, von + const Offset(6, 6), schritte: 3);
      expect(sp.schreibvorgaenge, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('eine nicht angezeigte Kachel mitten im Raster behält ihren Platz in der gespeicherten Liste', (tester) async {
      final sp = MemoryFeiertageSpeicher('nein');
      final angeboten = {...StartLayout.desktop.standard}..remove('einkauf');
      await start(
        tester,
        speicher: sp,
        groesse: gross,
        ueberschreibungen: [desktopVerfuegbarProvider.overrideWith((ref) => KachelVerfuegbarkeit(angeboten: angeboten))],
      );
      expect(find.text('// EINKAUFSLISTE'), findsNothing);
      final g = await zieheZu(tester, '// AUFGABEN', '// HEUTE & MORGEN');
      await g.up();
      await warte(tester);
      expect(kennungenAusText(sp.werte[dKey]), ['aufgaben', 'termine', 'einkauf', 'chat', 'dateien', 'familie', 'standort', 'muell', 'wetter']);
    });
  });

  group('Zurücksetzen mit Rückgängig', () {
    testWidgets('Zurücksetzen meldet sich mit Rückgängig und stellt den alten Stand wieder her; danach ist der Knopf aus', (tester) async {
      final sp = MemoryFeiertageSpeicher('nein', {mKey: '["standort","aufgaben"]', mAus: '["einkauf"]'});
      final c = await start(tester, speicher: sp, groesse: const Size(360, 1800));
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Startseite anpassen'));
      await warte(tester);
      expect(find.textContaining('nur für die Handy-Ansicht dieses Geräts'), findsOneWidget);
      final alt = c.read(startseiteMobilProvider);
      await tester.tap(find.text('Zurücksetzen'));
      await warte(tester);
      expect(find.text('Zurückgesetzt'), findsOneWidget);
      expect(c.read(startseiteMobilProvider).istStandard(StartLayout.mobil), isTrue);
      expect(sp.werte.containsKey(mKey), isFalse);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Zurücksetzen')).onPressed, isNull);
      await tester.tap(find.text('Rückgängig'));
      await warte(tester);
      expect(c.read(startseiteMobilProvider).reihenfolge, alt.reihenfolge);
      expect(c.read(startseiteMobilProvider).ausgeblendet, {'einkauf'});
      expect(kennungenAusText(sp.werte[mKey])!.take(2), ['standort', 'aufgaben']);
      expect(kennungenAusText(sp.werte[mAus]), ['einkauf']);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Zurücksetzen')).onPressed, isNotNull);
    });

    testWidgets('bei Standard ist der Knopf aus', (tester) async {
      await start(tester, groesse: const Size(360, 1800));
      await tester.scrollUntilVisible(find.text('Startseite anpassen'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Startseite anpassen'));
      await warte(tester);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Zurücksetzen')).onPressed, isNull);
    });

    testWidgets('solange der gespeicherte Stand gelesen wird, zeigt die Seite einen Ladezustand und keine Bedienelemente', (tester) async {
      final env = await angemeldeteUmgebung();
      env.speicher = _LangsamerSpeicher({});
      await starteApp(tester, env);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push<void>(StartseiteAnpassenScreen.route()));
      await warte(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('an:einkauf')), findsNothing);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Zurücksetzen')).onPressed, isNull);
    });
  });

  group('Semantics der Startseite', () {
    testWidgets('Kacheln der Handy-Liste bieten Verschieben als Aktion für Screenreader an und bleiben als Schaltfläche benannt', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester);
      final aktionen = <String>[];
      void gehe(SemanticsNode n) {
        for (final id in n.getSemanticsData().customSemanticsActionIds ?? const <int>[]) {
          aktionen.add(CustomSemanticsAction.getAction(id)?.label ?? '');
        }
        n.visitChildren((k) {
          gehe(k);
          return true;
        });
      }

      gehe(tester.renderObject(find.byType(CustomScrollView).first).owner!.semanticsOwner!.rootSemanticsNode!);
      expect(aktionen.where((a) => a.toLowerCase().contains('unten')), isNotEmpty);
      expect(aktionen.where((a) => a.toLowerCase().contains('oben')), isNotEmpty);
      expect(find.bySemanticsLabel(RegExp('Einkaufsliste, noch keine Liste')), findsOneWidget);
      handle.dispose();
    });
  });

  group('Kacheln-Kennungen', () {
    test('jede Kennung des Handys und des Desktops hat einen Titel', () {
      for (final l in StartLayout.values) {
        for (final k in l.kacheln) {
          expect(k.titel, isNotEmpty);
        }
      }
    });

  });

}

class _KaputterSpeicher extends MemoryFeiertageSpeicher {
  @override
  Future<String?> lesen({String schluessel = kFeiertageSchluessel}) async => throw StateError('nicht lesbar');

  @override
  Future<void> schreiben(String w, {String schluessel = kFeiertageSchluessel}) async => throw StateError('nicht schreibbar');
}

/// Zählt die Schreibvorgänge.
class _ZaehlenderSpeicher extends MemoryFeiertageSpeicher {
  int schreibvorgaenge = 0;

  @override
  Future<void> schreiben(String w, {String schluessel = kFeiertageSchluessel}) async {
    schreibvorgaenge++;
    await super.schreiben(w, schluessel: schluessel);
  }
}

/// Jeder Lesevorgang wartet, bis der Test ihn mit [lasse] freigibt; geliefert wird der Wert vom Zeitpunkt des Aufrufs.
class _HandgesteuerterSpeicher extends MemoryFeiertageSpeicher {
  final offen = <(Completer<String?>, String?)>[];

  @override
  Future<String?> lesen({String schluessel = kFeiertageSchluessel}) {
    final c = Completer<String?>();
    offen.add((c, werte[schluessel]));
    return c.future;
  }

  Future<void> lasse(int i) async {
    offen[i].$1.complete(offen[i].$2);
    await pumpEventQueue();
  }
}

/// Liefert die Werte erst nach [freigeben] (Lesen dauert).
class _LangsamerSpeicher extends MemoryFeiertageSpeicher {
  final Map<String, String> _daten;
  final _tor = Completer<void>();
  _LangsamerSpeicher(this._daten);

  void freigeben() => _tor.complete();

  @override
  Future<String?> lesen({String schluessel = kFeiertageSchluessel}) async {
    await _tor.future;
    return _daten[schluessel];
  }
}
