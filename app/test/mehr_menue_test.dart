// "Mehr" in der unteren Leiste (mobil): fünf Felder bei 360 px und Textskala 1.0/1.5/2.0, Blatt mit Einträgen je Verfügbarkeit, Aktiv-Markierung,
// Sprung von außen in einen Bereich hinter "Mehr", Badges, Seite "Untere Leiste" (Persistenz, Zurücksetzen, Start bleibt) und das unveränderte Desktop-Layout.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/vorsorge/vorsorge_anzeige.dart' show vorsorgeHinweisProvider;
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart' show WetterAktuell, WetterDto;
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/muell/muell_modelle.dart' show MuellDto;
import 'package:lx_fampad/data/muell/muell_state.dart';
import 'package:lx_fampad/data/shell/leiste_logik.dart';
import 'package:lx_fampad/data/shell/zuletzt_logik.dart';
import 'package:lx_fampad/data/tasks/aufgabe_logik.dart' show AufgabeFilter;
import 'package:lx_fampad/data/wetter/wetter_state.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart' show heuteTag;
import 'package:lx_fampad/features/lists/lists_screen.dart';
import 'package:lx_fampad/features/profile/anzeige_screen.dart';
import 'package:lx_fampad/features/profile/leiste_anpassen_screen.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';
import 'package:lx_fampad/features/shell/mehr_menue.dart';
import 'package:lx_fampad/features/shell/schnellwahl.dart';
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
  final h = heuteTag(TestUmgebung.testJetzt);
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
    String rolle = 'admin',
    void Function(TestUmgebung env)? vorher,
  }) async {
    final env = await angemeldeteUmgebung(role: rolle);
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
    testWidgets('Symbol und Beschriftung der Kacheln sitzen mittig, nicht links', (tester) async {
      await start(tester);
      await mehrOeffnen(tester);
      final kachel = find.byKey(const ValueKey('mehr:listen'));
      expect(kachel, findsOneWidget);
      final mitte = tester.getCenter(kachel).dx;
      final symbol = tester.getCenter(find.descendant(of: kachel, matching: find.byType(Icon))).dx;
      final text = tester.getCenter(find.descendant(of: kachel, matching: find.text('Listen'))).dx;
      expect((symbol - mitte).abs(), lessThan(2), reason: 'Symbol mittig');
      expect((text - mitte).abs(), lessThan(2), reason: 'Beschriftung mittig');
    });

    testWidgets('Mehr öffnet das Blatt und ändert den aktiven Bereich nicht', (tester) async {
      final (_, c) = await start(tester);
      expect(ausgewaehlt(tester), 0);
      await mehrOeffnen(tester);
      expect(blatt(), findsOneWidget);
      expect(ausgewaehlt(tester), 0, reason: 'Start bleibt markiert');
      expect(c.read(shellTabProvider), 0);
    });

    testWidgets('Standard: Gruppen Familie, Zuhause, Ablage (kein Müll, kein Wetter ohne Server); Zeile Profil; keine Dateien', (tester) async {
      await start(tester);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'standort', 'zaehler', 'medikamente', 'vorsorge', 'tresor', 'suche']);
      for (final t in ['Listen', 'Fristen', 'Standort', 'Suche', 'Profil', 'Konto, Sicherheit, Einstellungen']) {
        expect(find.descendant(of: blatt(), matching: find.text(t)), findsOneWidget, reason: t);
      }
      for (final t in ['Müll', 'Wetter', 'Dateien']) {
        expect(find.descendant(of: blatt(), matching: find.text(t)), findsNothing, reason: t);
      }
    });

    testWidgets('Müll und Wetter erscheinen nur, wenn der Server sie anbietet (Reihenfolge innerhalb der Gruppen)', (tester) async {
      await start(tester, muell: true, wetter: true);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'standort', 'muell', 'wetter', 'zaehler', 'medikamente', 'vorsorge', 'tresor', 'suche']);
    });

    testWidgets('nur Müll: ohne Wetter', (tester) async {
      await start(tester, muell: true);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'standort', 'muell', 'zaehler', 'medikamente', 'vorsorge', 'tresor', 'suche']);
    });

    testWidgets('eigene Leiste: die nicht gewählten Bereiche stehen im Blatt', (tester) async {
      await start(tester, gespeichert: {'leiste_bereiche': 'start,kalender,chat,listen'});
      expect(tester.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label), ['Start', 'Kalender', 'Chat', 'Listen', 'Mehr']);
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['aufgaben', 'fristen', 'standort', 'zaehler', 'medikamente', 'vorsorge', 'tresor', 'suche']);
    });

    for (final skala in [1.0, 2.0]) {
      testWidgets('360 px, Textskala $skala: Blatt ohne Überlauf, Kacheln >= 44 px, scrollbar', (tester) async {
        await start(tester, skala: skala, muell: true, wetter: true);
        await mehrOeffnen(tester);
        expect(tester.takeException(), isNull);
        for (final id in ['listen', 'fristen', 'standort', 'muell', 'wetter', 'zaehler', 'medikamente', 'vorsorge', 'tresor', 'suche']) {
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

  group('Gruppen', () {
    List<String> ueberschriften() => [
      for (final g in MehrGruppe.values)
        if (find.descendant(of: blatt(), matching: labelFinder(g.label)).evaluate().isNotEmpty) g.label,
    ];

    testWidgets('Eltern: drei Überschriften, Einträge liegen in ihrer Gruppe, Reihenfolge von oben nach unten', (tester) async {
      await start(tester, muell: true, wetter: true);
      await mehrOeffnen(tester);
      expect(ueberschriften(), ['Familie', 'Zuhause', 'Ablage']);
      double y(String t) => tester.getTopLeft(find.descendant(of: blatt(), matching: find.text(t))).dy;
      expect(y('Familie'), lessThan(y('Listen')));
      expect(y('Standort'), lessThan(y('Zuhause')));
      expect(y('Zuhause'), lessThan(y('Müll')));
      expect(y('Medikamente'), lessThan(y('Ablage')));
      expect(y('Ablage'), lessThan(y('Tresor')));
    });

    testWidgets('Kind: kein Zähler, kein Tresor; die Gruppe Ablage bleibt mit der Suche', (tester) async {
      await start(tester, rolle: 'child');
      await mehrOeffnen(tester);
      expect(kachelIds(tester), ['listen', 'fristen', 'standort', 'medikamente', 'vorsorge', 'suche']);
      expect(ueberschriften(), ['Familie', 'Zuhause', 'Ablage']);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: Überschriften und Kacheln ohne Überlauf', (tester) async {
        await start(tester, skala: skala, muell: true, wetter: true);
        await mehrOeffnen(tester);
        expect(tester.takeException(), isNull);
        expect(ueberschriften(), ['Familie', 'Zuhause', 'Ablage']);
      });
    }
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

    testWidgets('Vorsorge: Zahl der fälligen Einträge, rot bei Überfälligem, in der Summe; Text nur "n Hinweise", nie Name oder Art', (tester) async {
      await start(tester, vorher: (e) => e.extraOverrides.add(vorsorgeHinweisProvider.overrideWithValue((offen: 2, ueberfaellig: 1))));
      expect(find.byTooltip('Weitere Bereiche, 2 Hinweise'), findsOneWidget);
      await mehrOeffnen(tester);
      final z = tester.widget<HinweisZeichen>(find.descendant(of: find.byKey(const ValueKey('mehr:vorsorge')), matching: find.byType(HinweisZeichen)));
      expect((z.zahl, z.ueberfaellig), (2, true));
      expect(find.bySemanticsLabel('Vorsorge, 2 Hinweise, Überfälliges dabei'), findsOneWidget);
    });

    testWidgets('Vorsorge ohne fällige Einträge: kein Zeichen am Eintrag; Wetter, Standort, Tresor, Suche nie mit Zahl', (tester) async {
      await start(tester);
      await mehrOeffnen(tester);
      for (final id in ['vorsorge', 'standort', 'tresor', 'suche', 'wetter', 'dateien']) {
        expect(find.descendant(of: find.byKey(ValueKey('mehr:$id')), matching: find.byType(HinweisZeichen)), findsNothing, reason: id);
      }
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

  group('Desktop-Seitenleiste in Gruppen', () {
    testWidgets('dieselben Einträge in derselben Reihenfolge wie das Blatt, mit Fristen und Suche', (tester) async {
      final h = tester.ensureSemantics();
      await start(tester, groesse: const Size(1200, 1400), muell: true, wetter: true);
      // Überschriften sind MonoLabel-Text, Einträge die Beschriftung der Bedienhilfe
      double y(String t) => tester.getTopLeft(const {'Familie', 'Zuhause', 'Ablage'}.contains(t) ? labelFinder(t).first : find.bySemanticsLabel(t).first).dy;
      final reihe = ['Start', 'Kalender', 'Chat', 'Familie', 'Listen', 'Aufgaben', 'Fristen', 'Standort', 'Zuhause', 'Müll', 'Wetter', 'Zähler', 'Medikamente', 'Ablage', 'Tresor', 'Suche'];
      for (var i = 1; i < reihe.length; i++) {
        expect(y(reihe[i]), greaterThan(y(reihe[i - 1])), reason: '${reihe[i - 1]} vor ${reihe[i]}');
      }
      h.dispose();
    });

    testWidgets('Fristen stellt den Filter ein und wählt Aufgaben; Suche öffnet im Inhaltsbereich', (tester) async {
      final (_, c) = await start(tester, groesse: const Size(1200, 1400));
      await tester.tap(find.bySemanticsLabel('Fristen'));
      await warte(tester);
      expect(c.read(shellTabProvider), kAufgabenTab);
      expect(c.read(aufgabenAnsichtProvider).filter, AufgabeFilter.fristen);
      await tester.tap(find.bySemanticsLabel('Suche'));
      await warte(tester);
      expect(find.byType(SuchScreen), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
    });

    testWidgets('Kind: kein Zähler, kein Tresor in der Seitenleiste', (tester) async {
      await start(tester, groesse: const Size(1200, 1400), rolle: 'child');
      expect(find.bySemanticsLabel('Zähler'), findsNothing);
      expect(find.bySemanticsLabel('Tresor'), findsNothing);
      expect(find.bySemanticsLabel('Suche'), findsWidgets);
    });
  });

  group('Auffindbarkeit: Suche und Zuletzt benutzt (mobil), Gruppen und Schnellwahl (Desktop)', () {
    test('Logik: Merken (neueste zuerst, ohne Doppelte, begrenzt), Lesen defekter Werte, Namenssuche mit Umlaut-Toleranz', () {
      expect(zuletztMerken(['a', 'b', 'c'], 'c'), ['c', 'a', 'b']);
      expect(zuletztMerken([for (var i = 0; i < kZuletztMax; i++) 'x$i'], 'neu'), hasLength(kZuletztMax));
      expect(zuletztAusText(null), isEmpty);
      expect(zuletztAusText('kaputt{'), isEmpty);
      expect(zuletztAusText('["a","a",3,"b"]'), ['a', 'b']);
      expect(zuletztSichtbar(['a', 'weg', 'b', 'c', 'd'], {'a', 'b', 'c', 'd'}), ['a', 'b', 'c']);
      expect(gruppenZuAusText('["Familie"]'), {'Familie'});
      expect(gruppenZuAusText('nein'), isEmpty);
      expect(bereichPasst('Zähler', 'zae'), isTrue);
      expect(bereichPasst('Zähler', 'zä'), isTrue);
      expect(bereichPasst('Zähler', 'za'), isTrue);
      expect(bereichPasst('Medikamente', 'frist'), isFalse);
      expect(bereichPasst('Medikamente', ''), isTrue);
    });

    testWidgets('Blatt: Suchfeld filtert nur die Bereichsnamen, leere Treffer sagen es, Löschen bringt die Gruppen zurück', (tester) async {
      await start(tester);
      await mehrOeffnen(tester);
      expect(find.descendant(of: blatt(), matching: find.text('Zuletzt benutzt')), findsNothing, reason: 'noch nichts benutzt');
      await tester.enterText(find.descendant(of: blatt(), matching: find.byType(TextField)), 'frist');
      await warte(tester);
      expect(kachelIds(tester), ['fristen']);
      expect(find.text('Familie'), findsNothing, reason: 'bei der Suche keine Gruppen');
      await tester.enterText(find.descendant(of: blatt(), matching: find.byType(TextField)), 'xyz');
      await warte(tester);
      expect(find.text('Keinen Bereich gefunden.'), findsOneWidget);
      await tester.tap(find.byTooltip('Suche leeren'));
      await warte(tester);
      expect(kachelIds(tester), contains('listen'));
      expect(find.text('Familie'), findsWidgets);
    });

    testWidgets('Zuletzt benutzt: nach dem Öffnen eines Bereichs steht er als Chip im Blatt und wird lokal gemerkt', (tester) async {
      await start(tester);
      await mehrOeffnen(tester);
      await tester.tap(find.byKey(const ValueKey('mehr:fristen')));
      await warte(tester);
      expect(speicher.werte[kZuletztSchluessel], '["fristen"]');
      await mehrOeffnen(tester);
      expect(find.text('Zuletzt benutzt'), findsOneWidget);
      expect(find.byKey(const ValueKey('zuletzt:fristen')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('zuletzt:fristen'))).height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(const ValueKey('zuletzt:fristen')));
      await warte(tester);
      expect(blatt(), findsNothing);
    });

    testWidgets('Gemerkter Wert eines nicht (mehr) vorhandenen Bereichs erscheint nicht', (tester) async {
      await start(tester, gespeichert: {kZuletztSchluessel: '["gibtesnicht","tresor"]'}, rolle: 'child');
      await mehrOeffnen(tester);
      expect(find.text('Zuletzt benutzt'), findsNothing, reason: 'Tresor gibt es für Kinder nie');
    });

    testWidgets('Blatt bei 360 px und Textskala 2.0 ohne Überlauf, Chips bedienbar', (tester) async {
      await start(tester, skala: 2.0, gespeichert: {kZuletztSchluessel: '["fristen","listen","standort"]'});
      await mehrOeffnen(tester);
      expect(find.byKey(const ValueKey('zuletzt:fristen')), findsOneWidget);
      pruefeLayout(tester, 'Mehr-Blatt mit Zuletzt benutzt, Skala 2.0');
    });

    testWidgets('Desktop: Gruppe einklappen blendet die Einträge aus (der gewählte bleibt), der Zustand wird lokal gemerkt', (tester) async {
      final h = tester.ensureSemantics();
      final (_, c) = await start(tester, groesse: const Size(1200, 1400));
      expect(find.bySemanticsLabel('Standort'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Familie').first);
      await warte(tester);
      expect(find.bySemanticsLabel('Standort'), findsNothing);
      expect(find.bySemanticsLabel('Listen'), findsNothing);
      expect(speicher.werte[kGruppenZuSchluessel], '["Familie"]');
      // der gewählte Bereich einer eingeklappten Gruppe bleibt sichtbar
      c.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      await warte(tester);
      expect(find.bySemanticsLabel('Aufgaben'), findsWidgets);
      expect(find.bySemanticsLabel('Standort'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Familie').first);
      await warte(tester);
      expect(find.bySemanticsLabel('Standort'), findsOneWidget);
      h.dispose();
    });

    testWidgets('Desktop: Strg+K öffnet die Schnellwahl, Eingabe filtert die Namen, Enter öffnet den Bereich; Esc schließt', (tester) async {
      final (_, c) = await start(tester, groesse: const Size(1200, 1400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsOneWidget);
      await tester.enterText(find.descendant(of: find.byType(Schnellwahl), matching: find.byType(TextField)), 'aufg');
      await warte(tester);
      expect(find.byKey(const ValueKey('schnellwahl:aufgaben')), findsOneWidget);
      expect(find.byKey(const ValueKey('schnellwahl:standort')), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsNothing);
      expect(c.read(shellTabProvider), kAufgabenTab);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsNothing);
    });

    testWidgets('Desktop: "Bereich suchen" in der Seitenleiste öffnet die Schnellwahl; Kinder sehen dort keinen Zähler und keinen Tresor', (tester) async {
      final (_, c) = await start(tester, groesse: const Size(1200, 1400), rolle: 'child');
      await tester.tap(find.text('Bereich suchen'));
      await warte(tester);
      expect(find.byType(Schnellwahl), findsOneWidget);
      expect(find.byKey(const ValueKey('schnellwahl:zaehler')), findsNothing);
      expect(find.byKey(const ValueKey('schnellwahl:tresor')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await warte(tester);
      await tester.tap(find.byKey(const ValueKey('schnellwahl:listen')));
      await warte(tester);
      expect(c.read(shellTabProvider), kListenTab);
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
