// Desktop-Zweispalter für Aufgaben und Listen (ab 700 px Inhaltsbreite, also im Desktop-Layout): Liste links, Detail rechts, Leerzustand "nichts ausgewählt" mit
// Handlung, Editoren in der rechten Spalte (mit Rückfrage bei ungespeicherten Eingaben), mobil weiter Liste -> Detail als Vollseite.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tasks/aufgabe_editor.dart';
import 'package:lx_fampad/features/tasks/tasks_state.dart' show aufgabeOeffnenProvider;
import 'package:lx_fampad/widgets/liste_detail.dart';
import 'package:lx_fampad/widgets/ungespeichert_schutz.dart' show UngespeichertSchutz;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _a1 = 'bbbbbbbb-1111-4111-8111-111111111111';
const _a2 = 'bbbbbbbb-2222-4222-8222-222222222222';
const _l1 = '11111111-1111-4111-8111-111111111111';
const _l2 = '22222222-2222-4222-8222-222222222222';

Map<String, dynamic> _aufgabe(String titel) => {'titel': titel, 'beschreibung': '', 'prioritaet': 0, 'assigneeId': fixIdAdmin, 'erledigtAt': null, 'wiederholung': null};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, {required int tab, Size groesse = const Size(1280, 900), String role = 'admin', void Function(TestUmgebung e)? vorher}) async {
    final env = await angemeldeteUmgebung(role: role);
    env.speicher = MemoryFeiertageSpeicher('nein', {});
    vorher?.call(env);
    final c = await starteApp(tester, env, groesse: groesse);
    if (groesse.width >= 900) {
      c.read(shellTabProvider.notifier).waehlen(tab);
      await warte(tester);
    }
    return (env, c);
  }

  void aufgaben(TestUmgebung e) {
    e.sync.andereAendert('aufgabe', _a1, _aufgabe('Fahrrad reparieren'));
    e.sync.andereAendert('aufgabe', _a2, _aufgabe('Elternbrief unterschreiben'));
  }

  group('Aufgaben', () {
    testWidgets('ohne Auswahl: rechts der Leerzustand mit Handlung, links die Liste (nicht auf 720 px begrenzt)', (tester) async {
      await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Aufgabe hinzufügen'), findsOneWidget);
      expect(find.text('Fahrrad reparieren'), findsOneWidget);
      final liste = find.byType(ListeDetail);
      expect(tester.getSize(liste).width, greaterThan(kMaxContentWidthTest), reason: 'die 720-px-Begrenzung entfällt für diesen Bereich');
    });

    testWidgets('Tipp auf eine Aufgabe öffnet den Editor in der rechten Spalte, die Zeile ist gewählt; Zurück zeigt wieder den Leerzustand', (tester) async {
      await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Wähle links eine Aufgabe'), findsNothing);
      expect(tester.getTopLeft(find.byType(AufgabeEditor)).dx, greaterThanOrEqualTo(kListeSpaltenBreite), reason: 'der Editor liegt rechts neben der Liste, nicht über der ganzen Shell');
      expect(find.text('Elternbrief unterschreiben'), findsOneWidget, reason: 'die Liste bleibt sichtbar');
      expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true && (w.properties.label ?? '').startsWith('Fahrrad reparieren')), findsOneWidget);
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.byType(AufgabeEditor), findsNothing);
      expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true && (w.properties.label ?? '').startsWith('Fahrrad reparieren')), findsNothing);
    });

    testWidgets('Handlung im Leerzustand legt eine Aufgabe in der rechten Spalte an', (tester) async {
      final (env, _) = await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.widgetWithText(FilledButton, 'Aufgabe hinzufügen'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
      await eingeben(tester, 'Titel', 'Geschenk für Oma');
      await tippe(tester, find.widgetWithText(FilledButton, 'Aufgabe anlegen'));
      await warte(tester, 8);
      expect(find.byType(AufgabeEditor), findsNothing);
      expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
      expect((await env.db.select(env.db.aufgaben).get()).map((a) => a.titel), contains('Geschenk für Oma'));
    });

    testWidgets('ungespeicherte Eingaben: eine andere Aufgabe zu öffnen fragt erst nach, bei "Weiter bearbeiten" bleibt der Editor', (tester) async {
      await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      await tester.enterText(find.widgetWithText(TextField, 'Fahrrad reparieren'), 'Fahrrad reparieren und putzen');
      await tester.pump();
      expect(find.byType(UngespeichertSchutz), findsWidgets);
      await tippe(tester, find.text('Elternbrief unterschreiben'));
      expect(find.text('Änderungen verwerfen?'), findsOneWidget);
      await tippeText(tester, 'Weiter bearbeiten');
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Fahrrad reparieren und putzen'), findsWidgets);
    });

    testWidgets('Tippen auf eine Aufgaben-Erinnerung öffnet den Editor in der rechten Spalte', (tester) async {
      final (_, c) = await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      c.read(aufgabeOeffnenProvider.notifier).setzen(_a2);
      await warte(tester);
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(tester.getTopLeft(find.byType(AufgabeEditor)).dx, greaterThanOrEqualTo(kListeSpaltenBreite));
    });

    testWidgets('mobil (360 px): unverändert Liste, dann Editor als Vollseite, kein Leerzustand rechts', (tester) async {
      await start(tester, tab: kAufgabenTab, groesse: const Size(360, 800), vorher: aufgaben);
      await zumBereich(tester, 'Aufgaben');
      expect(find.text('Wähle links eine Aufgabe'), findsNothing);
      await tippe(tester, find.text('Fahrrad reparieren'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Elternbrief unterschreiben'), findsNothing, reason: 'Vollseite: die Liste liegt dahinter');
    });

    testWidgets('schmales Desktop-Fenster (900 px, Inhalt unter 700 px): eine Spalte wie mobil, der Editor öffnet als Unterseite', (tester) async {
      await start(tester, tab: kAufgabenTab, groesse: const Size(900, 900), vorher: aufgaben);
      expect(find.text('Wähle links eine Aufgabe'), findsNothing);
      await tippe(tester, find.text('Fahrrad reparieren'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
    });

    testWidgets('Tablet (800 px, mobiles Layout): kein Zweispalter, Liste dann Editor als Vollseite', (tester) async {
      await start(tester, tab: kAufgabenTab, groesse: const Size(800, 900), vorher: aufgaben);
      await zumBereich(tester, 'Aufgaben');
      expect(find.text('Wähle links eine Aufgabe'), findsNothing);
      await tippe(tester, find.text('Fahrrad reparieren'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Elternbrief unterschreiben'), findsNothing, reason: 'Vollseite: die Liste liegt dahinter');
    });

    testWidgets('Zurück (Android, Browser) schließt zuerst den Editor in der rechten Spalte und verlässt den Bereich nicht', (tester) async {
      final (_, c) = await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
      await tester.binding.handlePopRoute();
      await warte(tester);
      expect(find.byType(AufgabeEditor), findsNothing);
      expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
      expect(c.read(shellTabProvider), kAufgabenTab, reason: 'der Bereich bleibt');
    });

    testWidgets('Zurück mit ungespeicherten Eingaben fragt nach, statt zu verwerfen', (tester) async {
      await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      await tester.enterText(find.widgetWithText(TextField, 'Fahrrad reparieren'), 'Fahrrad reparieren und putzen');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await warte(tester);
      expect(find.text('Änderungen verwerfen?'), findsOneWidget);
      await tippeText(tester, 'Weiter bearbeiten');
      expect(find.byType(AufgabeEditor), findsOneWidget);
    });

    testWidgets('der Datensatz des offenen Editors wird gelöscht (z. B. von einem anderen Gerät): der Editor schließt sich', (tester) async {
      final (env, _) = await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      expect(find.byType(AufgabeEditor), findsOneWidget);
      await (env.db.delete(env.db.aufgaben)..where((t) => t.id.equals(_a1))).go();
      await warte(tester);
      expect(find.byType(AufgabeEditor), findsNothing);
      expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Editor selbst löschen: schließt genau einmal (die Liste und der Bereich bleiben)', (tester) async {
      final (env, c) = await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      await tippeText(tester, 'Aufgabe löschen');
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Löschen')));
      await warte(tester, 8);
      expect(find.byType(AufgabeEditor), findsNothing);
      expect(find.text('Elternbrief unterschreiben'), findsOneWidget, reason: 'kein zweites Pop: die Liste ist noch da');
      expect(c.read(shellTabProvider), kAufgabenTab);
      expect((await env.db.select(env.db.aufgaben).get()).map((a) => a.id), [_a2]);
    });

    testWidgets('Fenster wird schmaler, während der Editor mit Eingaben offen ist: der Editor bleibt (ganze Breite), nichts geht verloren', (tester) async {
      await start(tester, tab: kAufgabenTab, vorher: aufgaben);
      await tippe(tester, find.text('Fahrrad reparieren'));
      await tester.enterText(find.widgetWithText(TextField, 'Fahrrad reparieren'), 'Fahrrad reparieren und putzen');
      await tester.pump();
      tester.view.physicalSize = const Size(900, 900);
      await warte(tester);
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Fahrrad reparieren und putzen'), findsWidgets, reason: 'die Eingabe bleibt erhalten');
      tester.view.physicalSize = const Size(1280, 900);
      await warte(tester);
      expect(find.byType(AufgabeEditor), findsOneWidget);
      expect(find.text('Fahrrad reparieren und putzen'), findsWidgets);
      expect(find.text('Elternbrief unterschreiben'), findsOneWidget, reason: 'breit: die Liste ist wieder daneben');
    });

    testWidgets('Kind: darf eigene Aufgaben anlegen, der Leerzustand bietet die Handlung an', (tester) async {
      await start(tester, tab: kAufgabenTab, role: 'child', vorher: (e) {
        e.sync.andereAendert('aufgabe', _a1, {..._aufgabe('Zimmer saugen'), 'assigneeId': fixIdKind});
      });
      expect(find.text('Wähle links eine Aufgabe'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Aufgabe hinzufügen'), findsOneWidget);
    });
  });

  group('Listen', () {
    void listen(TestUmgebung e) {
      e.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
      e.sync.andereAendert('list', _l2, {'name': 'Packliste Urlaub', 'kind': 'packing', 'audience': 'family'});
      e.sync.andereAendert('list_item', '33333333-3333-4333-8333-000000000001', {'listId': _l1, 'text': 'Milch', 'position': 0});
      e.sync.andereAendert('list_item', '33333333-3333-4333-8333-000000000002', {'listId': _l2, 'text': 'Sonnencreme', 'position': 0});
    }

    testWidgets('links alle Listen mit offenen Einträgen, rechts die gewählte; Tipp wechselt die Liste', (tester) async {
      await start(tester, tab: kListenTab, vorher: listen);
      expect(find.byKey(const ValueKey('liste:$_l1')), findsOneWidget);
      expect(find.byKey(const ValueKey('liste:$_l2')), findsOneWidget);
      expect(find.text('Milch'), findsOneWidget);
      expect(find.text('Sonnencreme'), findsNothing);
      expect(tester.getTopLeft(find.text('Milch')).dx, greaterThan(kListeSpaltenBreite), reason: 'Einträge stehen in der rechten Spalte');
      await tester.tap(find.byKey(const ValueKey('liste:$_l2')));
      await warte(tester);
      expect(find.text('Sonnencreme'), findsOneWidget);
      expect(find.text('Milch'), findsNothing);
    });

    testWidgets('Tablet (800 px, mobiles Layout): keine Listenspalte', (tester) async {
      await start(tester, tab: kListenTab, groesse: const Size(800, 900), vorher: listen);
      await zumBereich(tester, 'Listen');
      expect(find.byKey(const ValueKey('liste:$_l1')), findsNothing);
      expect(find.text('Milch'), findsOneWidget);
    });

    testWidgets('mobil: weiter Reiter über der Liste, keine Listenspalte', (tester) async {
      await start(tester, tab: kListenTab, groesse: const Size(360, 800), vorher: listen);
      await zumBereich(tester, 'Listen');
      expect(find.byKey(const ValueKey('liste:$_l1')), findsNothing);
      expect(find.text('Milch'), findsOneWidget);
    });
  });
}

/// Frühere feste Höchstbreite des Inhalts (720 px) für die Gegenprobe.
const kMaxContentWidthTest = 720.0;
