// "Mehr" in der unteren Leiste (mobil): fünf Felder bei 360 px und Textskala 1.0/1.5/2.0, Blatt mit Einträgen je Verfügbarkeit, Aktiv-Markierung,
// Sprung von außen in einen Bereich hinter "Mehr", Badges, Seite "Untere Leiste" (Persistenz, Zurücksetzen, Start bleibt) und das unveränderte Desktop-Layout.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart' show WetterAktuell, WetterDto;
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/muell/muell_modelle.dart' show MuellDto;
import 'package:lx_fampad/data/muell/muell_state.dart';
import 'package:lx_fampad/data/shell/leiste_logik.dart';
import 'package:lx_fampad/data/tasks/aufgabe_logik.dart' show AufgabeFilter;
import 'package:lx_fampad/data/wetter/wetter_state.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart' show heuteTag;
import 'package:lx_fampad/features/lists/lists_screen.dart';
import 'package:lx_fampad/features/profile/anzeige_screen.dart';
import 'package:lx_fampad/features/profile/leiste_anpassen_screen.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';
import 'package:lx_fampad/features/shell/mehr_menue.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/standort/standort_screen.dart';
import 'package:lx_fampad/features/suche/such_screen.dart';
import 'package:lx_fampad/features/tasks/tasks_state.dart' show aufgabenAnsichtProvider;

import 'support/harness.dart';
import 'support/test_app.dart';

const _f1 = 'cccccccc-1111-4111-8111-111111111111';
const _a1 = 'bbbbbbbb-1111-4111-8111-111111111111';
const _a2 = 'bbbbbbbb-2222-4222-8222-222222222222';

String _tag(int tage) {
  final h = heuteTag();
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

Map<String, dynamic> _frist(String titel, {required int tage}) => {'titel': titel, 'faelligDate': _tag(tage), 'frist': true, 'fristMonate': 12, 'erinnerungMin': 30 * 1440, 'erledigtAt': null};

Map<String, dynamic> _aufgabe(String titel, {required int tage}) => {'titel': titel, 'faelligDate': _tag(tage), 'prioritaet': 0, 'assigneeId': null, 'erledigtAt': null, 'wiederholung': null};

class _FesterMuell extends MuellNotifier {
  @override
  MuellZustand build() => const MuellZustand(dto: MuellDto(verfuegbar: true), ablageGelesen: true);

  @override
  Future<void> aktualisieren() async {}
}

class _FestesWetter extends WetterNotifier {
  @override
  WetterZustand build() => WetterZustand(dto: WetterDto(verfuegbar: true, ort: 'Mainz', aktuell: WetterAktuell(gemessen: DateTime.now(), veraltet: false, temperatur: 12)));

  @override
  Future<void> aktualisieren() async {}
}

void main() {
  setUpAll(testVorbereiten);

  late MemoryFeiertageSpeicher speicher;

  Future<(TestUmgebung, ProviderContainer)> start(
    WidgetTester tester, {
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    Map<String, String> gespeichert = const {},
    bool muell = false,
    bool wetter = false,
    void Function(TestUmgebung env)? vorher,
  }) async {
    final env = await angemeldeteUmgebung();
    speicher = MemoryFeiertageSpeicher('nein', {...gespeichert});
    env.speicher = speicher;
    final List<Override> o = [if (muell) muellProvider.overrideWith(_FesterMuell.new), if (wetter) wetterProvider.overrideWith(_FestesWetter.new)];
    env.extraOverrides.addAll(o);
    vorher?.call(env);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    return (env, c);
  }

  Finder leiste() => find.byType(NavigationBar);
  int ausgewaehlt(WidgetTester tester) => tester.widget<NavigationBar>(leiste()).selectedIndex;
  Finder blatt() => find.byType(BottomSheet);
  Future<void> mehrOeffnen(WidgetTester tester) async {
    await tester.tap(find.descendant(of: leiste(), matching: find.text('Mehr')));
    await warte(tester);
  }

  List<String> kachelIds(WidgetTester tester) => [
    for (final w in tester.widgetList<InkWell>(find.descendant(of: blatt(), matching: find.byType(InkWell))))
      if (w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('mehr:')) (w.key! as ValueKey<String>).value.substring(5),
  ];

  group('Leiste mit fünf Feldern', () {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: Start, Kalender, Chat, Aufgaben, Mehr ohne Überlauf, Beschriftung einzeilig, Ziele >= 44 px', (tester) async {
        await start(tester, skala: skala);
        final destinations = tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label).toList();
        expect(destinations, ['Start', 'Kalender', 'Chat', 'Aufgaben', 'Mehr']);
        for (final label in destinations) {
          final p = find.descendant(of: leiste(), matching: find.text(label));
          expect(p, findsOneWidget, reason: label);
          final ro = tester.renderObject<RenderParagraph>(p);
          expect(ro.didExceedMaxLines, isFalse, reason: 'Label $label umgebrochen oder abgeschnitten');
          expect(ro.getMaxIntrinsicHeight(1000), lessThan(11 * skala * 1.6), reason: 'Label $label mehrzeilig');
          expect(ro.size.width, lessThanOrEqualTo(360 / 5 + 0.5), reason: 'Label $label breiter als sein Feld');
        }
        // jedes Feld der Leiste ist mindestens 44 px hoch und breit
        for (final e in find.byType(NavigationDestination).evaluate()) {
          final size = (e.renderObject! as RenderBox).size;
          expect(size.height, greaterThanOrEqualTo(44));
          expect(size.width, greaterThanOrEqualTo(44));
        }
        pruefeLayout(tester, 'Leiste mit Mehr, Skala $skala');
      });
    }

    testWidgets('Tooltip und Beschriftung für Screenreader: "Weitere Bereiche"', (tester) async {
      final h = tester.ensureSemantics();
      await start(tester);
      expect(find.byTooltip('Weitere Bereiche'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Mehr')), findsWidgets);
      h.dispose();
    });
  });

  group('Blatt', () {
    testWidgets('Mehr öffnet das Blatt und ändert den aktiven Bereich nicht', (tester) async {
      final (_, c) = await start(tester);
      expect(ausgewaehlt(tester), 0);
      await mehrOeffnen(tester);
      expect(blatt(), findsOneWidget);
      expect(ausgewaehlt(tester), 0, reason: 'Start bleibt markiert');
      expect(c.read(shellTabProvider), 0);
    });

    testWidgets('Standard: Listen, Fristen, Standort, Suche (kein Müll, kein Wetter ohne Server); Zeile Profil; keine Medikamente, keine Dateien', (tester) async {
      await start(tester);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'standort', 'suche']);
      for (final t in ['Listen', 'Fristen', 'Standort', 'Suche', 'Profil', 'Konto, Sicherheit, Einstellungen']) {
        expect(find.descendant(of: blatt(), matching: find.text(t)), findsOneWidget, reason: t);
      }
      for (final t in ['Müll', 'Wetter', 'Medikamente', 'Dateien']) {
        expect(find.descendant(of: blatt(), matching: find.text(t)), findsNothing, reason: t);
      }
    });

    testWidgets('Müll und Wetter erscheinen nur, wenn der Server sie anbietet (Reihenfolge: Bereiche, Fristen, Müll, Wetter, Standort, Suche)', (tester) async {
      await start(tester, muell: true, wetter: true);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'muell', 'wetter', 'standort', 'suche']);
    });

    testWidgets('nur Müll: ohne Wetter', (tester) async {
      await start(tester, muell: true);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'muell', 'standort', 'suche']);
    });

    testWidgets('eigene Leiste: die nicht gewählten Bereiche stehen im Blatt', (tester) async {
      await start(tester, gespeichert: {'leiste_bereiche': 'start,kalender,chat,listen'});
      expect(tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label), ['Start', 'Kalender', 'Chat', 'Listen', 'Mehr']);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['aufgaben', 'fristen', 'standort', 'suche']);
    });

    for (final skala in [1.0, 2.0]) {
      testWidgets('360 px, Textskala $skala: Blatt ohne Überlauf, Kacheln >= 44 px, scrollbar', (tester) async {
        await start(tester, skala: skala, muell: true, wetter: true);
        await mehrOeffnen(tester);
        expect(tester.takeException(), isNull);
        for (final id in ['listen', 'fristen', 'muell', 'wetter', 'standort', 'suche']) {
          final s = tester.getSize(find.byKey(ValueKey('mehr:$id')));
          expect(s.width, greaterThanOrEqualTo(44), reason: id);
          expect(s.height, greaterThanOrEqualTo(44), reason: id);
        }
        expect(find.descendant(of: blatt(), matching: find.byType(SingleChildScrollView)), findsOneWidget);
        // bis zur Zeile Profil scrollen und sie antippen können
        await tester.ensureVisible(find.text('Profil').last);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Kleines Fenster (360 x 480, Textskala 2.0): das Blatt scrollt bis zum Profil', (tester) async {
      await start(tester, skala: 2.0, groesse: const Size(360, 480), muell: true, wetter: true);
      await mehrOeffnen(tester);
      await tester.drag(find.descendant(of: blatt(), matching: find.byType(SingleChildScrollView)), const Offset(0, -400));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Profil').hitTestable(), findsOneWidget);
    });
  });

  group('Navigation', () {
    testWidgets('Listen im Blatt: schließt das Blatt, Listen sind aktiv und "Mehr" ist markiert', (tester) async {
      final (_, c) = await start(tester);
      await zumBereich(tester, 'Listen');
      expect(blatt(), findsNothing);
      expect(c.read(shellTabProvider), kListenTab);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, kListenTab);
      expect(find.byType(ListsScreen), findsOneWidget);
      expect(ausgewaehlt(tester), kLeistePlaetze, reason: 'Mehr markiert');
      // zurück zu einem Bereich der Leiste
      await tester.tap(find.descendant(of: leiste(), matching: find.text('Kalender')));
      await warte(tester);
      expect(ausgewaehlt(tester), 1);
    });

    testWidgets('Sprung von außen (Benachrichtigung, Widget, Karte) auf einen Bereich hinter Mehr: Listen sichtbar, Mehr markiert', (tester) async {
      final (_, c) = await start(tester);
      c.read(shellTabProvider.notifier).waehlen(kListenTab);
      await warte(tester);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, kListenTab);
      expect(ausgewaehlt(tester), kLeistePlaetze);
    });

    testWidgets('ein Bereich, der mobil nicht erlaubt ist (Dateien, Standort), zeigt die Startseite', (tester) async {
      final (_, c) = await start(tester);
      c.read(shellTabProvider.notifier).waehlen(kDateienTab);
      await warte(tester);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);
      expect(ausgewaehlt(tester), 0);
    });

    testWidgets('Fristen im Blatt: öffnet Aufgaben mit Filter "Fristen"; die Leiste markiert Aufgaben, nicht Mehr', (tester) async {
      final (_, c) = await start(tester);
      await zumBereich(tester, 'Fristen');
      expect(blatt(), findsNothing);
      expect(c.read(shellTabProvider), kAufgabenTab);
      expect(c.read(aufgabenAnsichtProvider).filter, AufgabeFilter.fristen);
      expect(ausgewaehlt(tester), 3);
    });

    testWidgets('Suche, Standort und Profil öffnen ihre Seite und schließen das Blatt', (tester) async {
      await start(tester);
      for (final (label, typ) in [('Suche', SuchScreen), ('Standort', StandortScreen), ('Profil', ProfileScreen)]) {
        await mehrOeffnen(tester);
        await tester.tap(find.descendant(of: blatt(), matching: find.text(label)));
        await warte(tester);
        expect(blatt(), findsNothing, reason: label);
        expect(find.byType(typ), findsOneWidget, reason: label);
        await zurueck(tester);
        await warte(tester);
        expect(find.byType(typ), findsNothing, reason: '$label zurück');
        expect(ausgewaehlt(tester), 0, reason: 'der Bereich bleibt unverändert');
      }
    });

    testWidgets('Müll im Blatt öffnet die Müll-Seite', (tester) async {
      await start(tester, muell: true);
      await mehrOeffnen(tester);
      await tester.tap(find.descendant(of: blatt(), matching: find.text('Müll')));
      await warte(tester);
      expect(blatt(), findsNothing);
      expect(find.text('Müll'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('Hinweise (Badges)', () {
    void daten(TestUmgebung e) {
      e.sync.andereAendert('aufgabe', _f1, _frist('Reisepass', tage: 10));
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Überfällig', tage: -3));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Morgen dran', tage: 1));
    }

    testWidgets('Standard (Aufgaben in der Leiste): Mehr zeigt nur die Fristen; die Kachel Fristen hat ihr gelbes Zeichen', (tester) async {
      await start(tester, vorher: daten);
      expect(find.descendant(of: leiste(), matching: find.text('1')), findsOneWidget, reason: 'eine Frist im Warnbereich');
      expect(find.byTooltip('Weitere Bereiche, 1 Hinweis'), findsOneWidget);
      await mehrOeffnen(tester);
      expect(find.descendant(of: find.byKey(const ValueKey('mehr:fristen')), matching: find.byType(HinweisZeichen)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('mehr:listen')), matching: find.byType(HinweisZeichen)), findsNothing);
    });

    testWidgets('Aufgaben hinter Mehr: Summe aus fälligen Aufgaben (überfällig und bald fällig) und Fristen; Zeichen rot bei Überfälligem', (tester) async {
      await start(tester, gespeichert: {'leiste_bereiche': 'start,kalender,chat,listen'}, vorher: daten);
      expect(find.byTooltip('Weitere Bereiche, 3 Hinweise'), findsOneWidget, reason: '2 Aufgaben (eine überfällig) + 1 Frist');
      final badge = tester.widget<Badge>(find.descendant(of: leiste(), matching: find.byType(Badge)).last);
      expect(badge.backgroundColor, kDanger);
      await mehrOeffnen(tester);
      final a = tester.widget<HinweisZeichen>(find.descendant(of: find.byKey(const ValueKey('mehr:aufgaben')), matching: find.byType(HinweisZeichen)));
      expect((a.zahl, a.ueberfaellig), (2, true));
      final f = tester.widget<HinweisZeichen>(find.descendant(of: find.byKey(const ValueKey('mehr:fristen')), matching: find.byType(HinweisZeichen)));
      expect((f.zahl, f.ueberfaellig), (1, false));
    });

    testWidgets('ohne Hinweise: kein Zeichen an Mehr', (tester) async {
      await start(tester);
      expect(find.descendant(of: leiste(), matching: find.byType(Badge)).evaluate().where((e) => (e.widget as Badge).isLabelVisible && (e.widget as Badge).label != null).length, 0);
      expect(find.byTooltip('Weitere Bereiche'), findsOneWidget);
    });
  });

  group('Seite "Untere Leiste"', () {
    Future<void> oeffnen(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Profil und Sicherheit').first);
      await warte(tester);
      await tester.scrollUntilVisible(find.text('Startseite und Anzeige'), 100, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('Startseite und Anzeige'));
      await warte(tester);
      await tester.scrollUntilVisible(find.text('Untere Leiste'), 100, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('Untere Leiste'));
      await warte(tester);
      expect(find.byType(LeisteAnpassenScreen), findsOneWidget);
    }

    testWidgets('Pfeile, Ersetzen, Persistenz in sync_meta und Wirkung auf die Leiste; Start bleibt', (tester) async {
      final (env, c) = await start(tester);
      await oeffnen(tester);
            // Start ist nicht ersetzbar (Schloss statt Auswahl)
      expect(find.byTooltip('Start bleibt in der Leiste'), findsOneWidget);
      expect(find.byTooltip('Start ersetzen'), findsNothing);
      // Aufgaben nach oben, dann durch Listen ersetzen
      await tester.tap(find.byTooltip('Aufgaben nach oben'));
      await warte(tester);
      expect(speicher.werte['leiste_bereiche'], 'start,kalender,aufgaben,chat');
      await tester.tap(find.byTooltip('Aufgaben ersetzen'));
      await warte(tester);
      await tester.tap(find.text('Listen').last);
      await warte(tester);
      expect(speicher.werte['leiste_bereiche'], 'start,kalender,listen,chat');
      // Zurück: die Leiste folgt
      await zurueck(tester);
      await zurueck(tester);
      await zurueck(tester);
      await warte(tester);
      expect(tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label), ['Start', 'Kalender', 'Listen', 'Chat', 'Mehr']);
      c.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      await warte(tester);
      expect(ausgewaehlt(tester), kLeistePlaetze, reason: 'Aufgaben liegen jetzt hinter Mehr');
    });

    testWidgets('Zurücksetzen stellt den Standard her und löscht den gemerkten Wert', (tester) async {
      final (_, _) = await start(tester, gespeichert: {'leiste_bereiche': 'start,listen,chat,kalender'});
      expect(tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label), ['Start', 'Listen', 'Chat', 'Kalender', 'Mehr']);
      await oeffnen(tester);
      await tester.tap(find.text('Zurücksetzen'));
      await warte(tester);
      expect(speicher.werte.containsKey('leiste_bereiche'), isFalse);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Zurücksetzen')).onPressed, isNull, reason: 'schon Standard');
    });

    testWidgets('360 px, Textskala 2.0: Seite ohne Überlauf, Ziele >= 44 px', (tester) async {
      await start(tester, skala: 2.0);
      await oeffnen(tester);
      pruefeLayout(tester, 'Untere Leiste, Skala 2.0');
    });
  });

  group('Desktop-Layout unverändert', () {
    testWidgets('1200 px: Seitenleiste mit allen Bereichen, kein Mehr, keine Navigationsleiste, keine Dateien', (tester) async {
      await start(tester, groesse: const Size(1200, 800));
      expect(leiste(), findsNothing);
      for (final t in ['Start', 'Kalender', 'Chat', 'Listen', 'Aufgaben', 'Standort']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      expect(find.text('Mehr'), findsNothing);
      expect(find.text('Dateien'), findsNothing);
    });

    testWidgets('Die Zeile "Untere Leiste" gibt es im Desktop-Layout nicht', (tester) async {
      await start(tester, groesse: const Size(1200, 800));
      unawaited(tester.state<NavigatorState>(find.byType(Navigator).last).push<void>(MaterialPageRoute(builder: (_) => const AnzeigeScreen())));
      await warte(tester);
      expect(find.text('Startseite anpassen'), findsWidgets);
      expect(find.text('Untere Leiste'), findsNothing);
    });
  });
}

/// Schließt die oberste Seite (wie die Zurück-Taste des Systems).
Future<void> zurueck(WidgetTester tester) async {
  await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
  await warte(tester);
}
