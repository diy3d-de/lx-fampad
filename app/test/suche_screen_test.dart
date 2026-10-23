// Globale Suche (Oberfläche): Einstieg auf der Startseite (mobil und Desktop), Eingabe, gruppierte Treffer, Springen in die Bereiche, Layout bei
// 360 px und Textskala 1.5/2.0, Semantics der Zeilen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart' show kalenderAuswahlProvider;
import 'package:lx_fampad/features/lists/lists_screen.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/suche/such_screen.dart';
import 'package:lx_fampad/features/suche/such_einstieg.dart';
import 'package:lx_fampad/features/tasks/aufgabe_editor.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _l1 = '11111111-1111-4111-8111-111111111111';
const _a1 = 'bbbbbbbb-1111-4111-8111-111111111111';
const _t1 = 'aaaaaaaa-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  late ProviderContainer container;

  Future<TestUmgebung> start(WidgetTester tester, {double skala = 1.0, Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung();
    env.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
    env.sync.andereAendert('list_item', '22222222-2222-4222-8222-000000000001', {'listId': _l1, 'text': 'Äpfel und Birnen', 'position': 1});
    env.sync.andereAendert('aufgabe', _a1, {'titel': 'Äpfel pflücken', 'beschreibung': 'Leiter aus dem Keller', 'prioritaet': 0});
    env.sync.andereAendert('termin', _t1, {
      'titel': 'Apfelfest',
      'ort': 'Schulhof',
      'ganztaegig': true,
      'startDate': '2026-11-14',
      'endDate': '2026-11-15',
      'ownerId': fixIdAdmin,
      'audience': 'family',
    });
    container = await starteApp(tester, env, skala: skala, groesse: groesse);
    return env;
  }

  Future<void> suchen(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 300));
    await warte(tester);
  }

  testWidgets('Startseite mobil: Suchzeile öffnet die Suche, Treffer je Bereich (Umlaut-tolerant), Layout 360 px', (tester) async {
    await start(tester);
    expect(find.byType(SuchEinstieg), findsOneWidget);
    await tippe(tester, find.byType(SuchEinstieg));
    expect(find.byType(SuchScreen), findsOneWidget);
    expect(find.text('Wonach suchst du?'), findsOneWidget);
    await suchen(tester, 'apfel');
    expect(find.text('Termine · 1'.toUpperCase()), findsOneWidget);
    expect(find.text('Aufgaben · 1'.toUpperCase()), findsOneWidget);
    expect(find.text('Listeneinträge · 1'.toUpperCase()), findsOneWidget);
    pruefeLayout(tester, 'Suche mit Treffern');
    await suchen(tester, 'xyzxyz');
    expect(find.text('Nichts gefunden'), findsOneWidget);
    // Löschen-Knopf leert das Feld
    await tippe(tester, find.byTooltip('Eingabe löschen'));
    expect(find.text('Wonach suchst du?'), findsOneWidget);
  });

  testWidgets('Treffer antippen: Eintrag springt in die Liste, Aufgabe öffnet den Editor', (tester) async {
    await start(tester);
    await tippe(tester, find.byType(SuchEinstieg));
    await suchen(tester, 'apfel');
    await tippe(tester, semLabel('Listeneintrag: Äpfel und Birnen'));
    expect(find.byType(SuchScreen), findsNothing);
    expect(find.byType(ListsScreen), findsOneWidget);

    await zumStart(tester);
    await tippe(tester, find.byType(SuchEinstieg));
    await suchen(tester, 'pflücken');
    await tippe(tester, semLabel('Aufgabe: Äpfel pflücken'));
    expect(find.byType(AufgabeEditor), findsOneWidget);
  });

  testWidgets('Termin antippen wechselt in den Kalender auf den Tag des Termins', (tester) async {
    await start(tester);
    await tippe(tester, find.byType(SuchEinstieg));
    await suchen(tester, 'schulhof');
    await tippe(tester, semLabel('Termin: Apfelfest'));
    expect(find.byType(SuchScreen), findsNothing);
    expect(container.read(shellTabProvider), kKalenderTab);
    expect(container.read(kalenderAuswahlProvider).tag, DateTime.utc(2026, 11, 14));
  });

  for (final skala in [1.5, 2.0]) {
    testWidgets('Layout bei 360 px und Textskala $skala (leer, mit Treffern, ohne Treffer)', (tester) async {
      await start(tester, skala: skala);
      await tippe(tester, find.byType(SuchEinstieg));
      pruefeLayout(tester, 'Suche leer $skala');
      await suchen(tester, 'apfel');
      pruefeLayout(tester, 'Suche Treffer $skala');
      await suchen(tester, 'qqqq');
      pruefeLayout(tester, 'Suche leer-Ergebnis $skala');
    });
  }

  testWidgets('Desktop-Layout: Suchfeld in der Kopfzeile der Startseite öffnet die Suche im Inhaltsbereich', (tester) async {
    await start(tester, groesse: const Size(1200, 800));
    expect(find.byType(SuchEinstieg), findsOneWidget);
    await tippe(tester, find.byType(SuchEinstieg));
    expect(find.byType(SuchScreen), findsOneWidget);
    // Seitenleiste bleibt stehen
    expect(find.text('lx-familyhub'), findsOneWidget);
    await suchen(tester, 'apfel');
    await tippe(tester, semLabel('Listeneintrag: Äpfel und Birnen'));
    expect(find.byType(SuchScreen), findsNothing);
    expect(find.byType(ListsScreen), findsOneWidget);
  });

  test('Konstante: kListenTab ist der Listen-Tab', () {
    expect(kTabs[kListenTab].label, 'Listen');
  });
}

Future<void> zumStart(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Start')));
  await warte(tester);
}

/// Semantics-Knoten mit diesem Beginn der Beschriftung (ohne eingeschaltete Bedienhilfe-Baumprüfung).
Finder semLabel(String anfang) => find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith(anfang));
