// UX-Runde 1, Randfälle der QM-Abschlussprüfung: Breiten- und Textskalen-Matrix (Jetzt wichtig, Mehr-Blatt mit Suche, Zweispalter), Zweispalter nur im
// Desktop-Layout, Strg+K bei Fokus im Textfeld / offenem Dialog / offenem Editor, Rolle Kind (nie Zähler, Tresor, Medikamente, Vorsorge).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/startseite/jetzt_wichtig_logik.dart' show kJetztWichtigSchluessel;
import 'package:lx_fampad/data/shell/zuletzt_logik.dart' show kZuletztSchluessel;
import 'package:lx_fampad/features/calendar/calendar_state.dart' show heuteTag;
import 'package:lx_fampad/features/shell/desktop_shell.dart' show DesktopShellMarke;
import 'package:lx_fampad/features/shell/schnellwahl.dart' show Schnellwahl;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tasks/aufgabe_editor.dart';
import 'package:lx_fampad/widgets/liste_detail.dart';

import 'support/fake_server.dart' show fixIdAdmin;
import 'support/harness.dart';
import 'support/test_app.dart';

const _a1 = 'bbbbbbbb-1111-4111-8111-111111111111';
const _a2 = 'bbbbbbbb-2222-4222-8222-222222222222';
const _l1 = '11111111-1111-4111-8111-111111111111';

String _tag(int tage) {
  final h = heuteTag(TestUmgebung.testJetzt);
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

void _daten(TestUmgebung e) {
  e.sync.andereAendert('aufgabe', _a1, {'titel': 'Rechnung zahlen', 'faelligDate': _tag(-2), 'prioritaet': 0, 'assigneeId': fixIdAdmin, 'erledigtAt': null, 'wiederholung': null});
  e.sync.andereAendert('aufgabe', _a2, {'titel': 'Fahrrad reparieren', 'beschreibung': '', 'prioritaet': 0, 'assigneeId': fixIdAdmin, 'erledigtAt': null, 'wiederholung': null});
}

Future<(TestUmgebung, ProviderContainer)> _start(
  WidgetTester tester, {
  Size groesse = const Size(360, 900),
  double skala = 1.0,
  String rolle = 'admin',
  Map<String, String> gespeichert = const {},
}) async {
  final env = await angemeldeteUmgebung(role: rolle);
  env.speicher = MemoryFeiertageSpeicher('nein', {kJetztWichtigSchluessel: 'ja', ...gespeichert});
  _daten(env);
  final c = await starteApp(tester, env, groesse: groesse, skala: skala);
  return (env, c);
}

Future<void> _strgK(WidgetTester tester, {bool meta = false}) async {
  final taste = meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(taste);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(taste);
  await warte(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Matrix Breite x Textskala', () {
    for (final breite in [360.0, 700.0, 899.0, 900.0, 1280.0]) {
      for (final skala in [1.0, 1.5, 2.0]) {
        testWidgets('Startseite mit "Jetzt wichtig", $breite px, Skala $skala: kein Überlauf, Ziele >= 44 px, Zeile beschriftet', (tester) async {
          final h = tester.ensureSemantics();
          await _start(tester, groesse: Size(breite, 1000), skala: skala);
          expect(find.text('Jetzt wichtig'), findsOneWidget);
          expect(find.text('2 Tage überfällig'), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp('Überfällig: Rechnung zahlen')), findsOneWidget);
          final zeile = find.byKey(const ValueKey('jetzt:ueberfaellig:Rechnung zahlen'));
          expect(tester.getSize(zeile).height, greaterThanOrEqualTo(44));
          pruefeLayout(tester, 'Jetzt wichtig $breite/$skala');
          h.dispose();
        });
      }
    }

    // Mehr-Blatt gibt es nur im mobilen Layout (unter 900 px)
    for (final breite in [360.0, 700.0, 899.0]) {
      for (final skala in [1.0, 1.5, 2.0]) {
        testWidgets('Mehr-Blatt mit Suche, $breite px, Skala $skala: kein Überlauf, Suchfeld und Knopf zum Leeren bedienbar', (tester) async {
          final h = tester.ensureSemantics();
          await _start(tester, groesse: Size(breite, 900), skala: skala);
          await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
          await warte(tester);
          expect(find.byType(NavigationBar), findsOneWidget, reason: 'unter 900 px mobiles Layout');
          pruefeLayout(tester, 'Mehr-Blatt $breite/$skala');
          await tester.enterText(find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField)), 'xyz');
          await warte(tester);
          expect(find.text('Keinen Bereich gefunden.'), findsOneWidget);
          expect(find.byTooltip('Suche leeren'), findsOneWidget);
          pruefeLayout(tester, 'Mehr-Blatt leer $breite/$skala');
          h.dispose();
        });
      }
    }

    // Zweispalter: nur im Desktop-Layout (ab 900 px Fenster) UND nur bei ausreichend Inhaltsbreite; 700 und 899 px bleiben einspaltig
    for (final breite in [700.0, 899.0]) {
      testWidgets('Aufgaben bei $breite px (mobiles Layout): einspaltig, kein Leerzustand rechts, keine Desktop-Shell', (tester) async {
        await _start(tester, groesse: Size(breite, 900));
        await zumBereich(tester, 'Aufgaben');
        expect(find.byType(DesktopShellMarke), findsNothing);
        expect(find.text('Wähle links eine Aufgabe'), findsNothing);
        expect(find.text('Fahrrad reparieren'), findsOneWidget);
        pruefeLayout(tester, 'Aufgaben $breite');
      });

      testWidgets('Listen bei $breite px (mobiles Layout): einspaltig, keine Listenspalte', (tester) async {
        final env = await angemeldeteUmgebung();
        env.speicher = MemoryFeiertageSpeicher('nein', {});
        env.sync.andereAendert('liste', _l1, {'name': 'Einkauf', 'art': 'einkauf', 'audience': 'family', 'ownerId': fixIdAdmin});
        await starteApp(tester, env, groesse: Size(breite, 900));
        await zumBereich(tester, 'Listen');
        expect(find.byType(DesktopShellMarke), findsNothing);
        expect(find.textContaining('Wähle links'), findsNothing, reason: 'kein Leerzustand der rechten Spalte');
        pruefeLayout(tester, 'Listen $breite');
      });
    }

    testWidgets('Aufgaben bei 900 px (Desktop-Layout, Inhalt unter 700 px): Desktop-Shell, aber einspaltig', (tester) async {
      final (_, c) = await _start(tester, groesse: const Size(900, 900));
      c.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      await warte(tester);
      expect(find.byType(DesktopShellMarke), findsOneWidget);
      expect(find.text('Wähle links eine Aufgabe'), findsNothing);
      pruefeLayout(tester, 'Aufgaben 900');
    });

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Aufgaben-Zweispalter bei 1280 px, Skala $skala: Leerzustand mit Handlung, kein Überlauf, Ziele >= 44 px, Handlung beschriftet', (tester) async {
        final h = tester.ensureSemantics();
        final (_, c) = await _start(tester, groesse: const Size(1280, 1000), skala: skala);
        c.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
        await warte(tester);
        expect(find.byType(ListeDetail), findsOneWidget);
        expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Aufgabe hinzufügen'), findsOneWidget);
        pruefeLayout(tester, 'Zweispalter leer $skala');
        await tippe(tester, find.text('Fahrrad reparieren'));
        expect(find.byType(AufgabeEditor), findsOneWidget);
        pruefeLayout(tester, 'Zweispalter Editor $skala');
        h.dispose();
      });
    }
  });

  group('Strg+K', () {
    Future<ProviderContainer> editorOffen(WidgetTester tester) async {
      final (_, c) = await _start(tester, groesse: const Size(1280, 1000));
      c.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      await warte(tester);
      await tippe(tester, find.text('Fahrrad reparieren'));
      await tester.enterText(find.widgetWithText(TextField, 'Fahrrad reparieren'), 'Fahrrad reparieren und putzen');
      await tester.pump();
      return c;
    }

    testWidgets('bei Fokus in einem Textfeld des offenen Editors: Schnellwahl öffnet genau einmal, Esc bringt den Editor mit der Eingabe zurück', (tester) async {
      await editorOffen(tester);
      await _strgK(tester);
      expect(find.byType(Schnellwahl), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsNothing);
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Fahrrad reparieren und putzen'), findsWidgets, reason: 'keine verlorene Eingabe');
    });

    testWidgets('bei offener Schnellwahl: erneutes Strg+K (und Cmd+K) öffnet sie nicht doppelt; das Suchfeld behält seinen Text', (tester) async {
      await _start(tester, groesse: const Size(1280, 1000));
      await _strgK(tester);
      final feld = find.descendant(of: find.byType(Schnellwahl), matching: find.byType(TextField));
      await tester.enterText(feld, 'auf');
      await warte(tester);
      await _strgK(tester);
      await _strgK(tester, meta: true);
      expect(find.byType(Schnellwahl), findsOneWidget);
      expect(tester.widget<TextField>(feld).controller!.text, 'auf');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsNothing, reason: 'ein Esc genügt, es lag nur ein Fenster darüber');
    });

    testWidgets('bei offenem Editor und ungespeicherter Eingabe: Auswahl in der Schnellwahl wechselt den Bereich nur über die Rückfrage-Logik, kein Absturz', (tester) async {
      final c = await editorOffen(tester);
      await _strgK(tester);
      await tester.enterText(find.descendant(of: find.byType(Schnellwahl), matching: find.byType(TextField)), 'kalender');
      await warte(tester);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await warte(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Schnellwahl), findsNothing);
      // entweder blieb der Bereich (Rückfrage "Änderungen verwerfen?") oder er wechselte ohne Verlust der Eingabe
      final geblieben = c.read(shellTabProvider) == kAufgabenTab;
      if (geblieben) {
        expect(find.text('Fahrrad reparieren und putzen'), findsWidgets);
      }
    });

    testWidgets('mobil (kein Desktop-Layout): Strg+K tut nichts', (tester) async {
      await _start(tester, groesse: const Size(800, 900));
      await _strgK(tester);
      expect(find.byType(Schnellwahl), findsNothing);
    });
  });

  group('Rolle Kind', () {
    // Medikamente und Vorsorge sind für Kinder laut Konzept erlaubt (nur eigene Daten, kein Eintrag vorhanden); Zähler und Tresor nie
    const verboten = ['Zähler', 'Tresor'];

    testWidgets('mobil: Mehr-Blatt und Suche nach den verbotenen Bereichen zeigen nie einen Treffer; der leere Zustand sagt es und der Leeren-Knopf bringt die Gruppen zurück', (tester) async {
      await _start(tester, rolle: 'child');
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      for (final w in ['Zähler', 'Tresor']) {
        expect(find.descendant(of: find.byType(BottomSheet), matching: find.text(w)), findsNothing, reason: w);
      }
      final feld = find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField));
      for (final w in ['zähler', 'zaehler', 'tresor']) {
        await tester.enterText(feld, w);
        await warte(tester);
        expect(find.text('Keinen Bereich gefunden.'), findsOneWidget, reason: w);
        expect(find.byTooltip('Suche leeren'), findsOneWidget, reason: 'Handlung im leeren Zustand');
      }
      await tester.tap(find.byTooltip('Suche leeren'));
      await warte(tester);
      expect(find.text('Keinen Bereich gefunden.'), findsNothing);
      pruefeLayout(tester, 'Kind Mehr');
    });

    testWidgets('mobil: Zuletzt benutzt mit gemerkten verbotenen Bereichen zeigt Zähler und Tresor nie', (tester) async {
      await _start(tester, rolle: 'child', gespeichert: {kZuletztSchluessel: '["zaehler","tresor","medikamente","vorsorge"]'});
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      for (final w in ['Zähler', 'Tresor']) {
        expect(find.descendant(of: find.byType(BottomSheet), matching: find.text(w)), findsNothing, reason: w);
      }
    });

    testWidgets('mobil: Startseite und Jetzt wichtig des Kindes zeigen nie Zähler, Tresor (Medikamente/Vorsorge nur eigene Daten)', (tester) async {
      await _start(tester, rolle: 'child');
      expect(find.text('Jetzt wichtig'), findsOneWidget);
      for (final w in verboten) {
        expect(find.textContaining(w), findsNothing, reason: w);
      }
    });

    testWidgets('Desktop: Schnellwahl-Suche nach verbotenen Bereichen zeigt den leeren Zustand; Esc schließt; Startseite ohne verbotene Bereiche', (tester) async {
      await _start(tester, rolle: 'child', groesse: const Size(1280, 1000));
      for (final w in verboten) {
        expect(find.textContaining(w), findsNothing, reason: 'Seitenleiste/Startseite: $w');
      }
      await _strgK(tester);
      final feld = find.descendant(of: find.byType(Schnellwahl), matching: find.byType(TextField));
      for (final w in ['zähler', 'tresor']) {
        await tester.enterText(feld, w);
        await warte(tester);
        expect(find.text('Keinen Bereich gefunden.'), findsOneWidget, reason: w);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await warte(tester);
      expect(find.byType(Schnellwahl), findsNothing);
    });
  });
}
