// Aufgaben-Oberfläche: Liste, Filter, Sortierung, schnelles Anlegen und Abhaken, Editor (neu, bearbeiten, Unteraufgaben, Wiederholung),
// Löschen mit Rückfrage, Rechte der Kinder, Startseiten-Karten, Desktop-Seitenleiste; bei 360 px Breite und Textskala 1.0 und 1.5.
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/lists/list_dialogs.dart' show AuswahlKnopf;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tasks/aufgabe_editor.dart';
import 'package:lx_fampad/features/tasks/tasks_screen.dart';
import 'package:lx_fampad/widgets/kopfzeile.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _a1 = 'bbbbbbbb-1111-4111-8111-111111111111';
const _a2 = 'bbbbbbbb-2222-4222-8222-222222222222';
const _a3 = 'bbbbbbbb-3333-4333-8333-333333333333';
const _a4 = 'bbbbbbbb-4444-4444-8444-444444444444';

String _tag(int tage) {
  final h = heuteTag();
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

Map<String, dynamic> _aufgabe(String titel, {int? tage, int prio = 0, String? zu, String? owner, bool erledigt = false, String? wdh}) => {
  'titel': titel,
  'faelligDate': tage == null ? null : _tag(tage),
  'prioritaet': prio,
  'assigneeId': zu,
  'ownerId': ?owner,
  'erledigtAt': erledigt ? DateTime.now().toUtc().toIso8601String() : null,
  'wiederholung': wdh,
};

/// Tippt direkt (ohne ensureVisible des Test-Helfers: im Editor verschiebt es den Inhalt unter dem Zeiger weg, nachdem ein Textfeld Fokus hat).
Future<void> tippeDirekt(WidgetTester tester, Finder f) async {
  await tester.tap(f.first);
  await warte(tester);
}

Future<void> zumTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  await warte(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', void Function(TestUmgebung env)? vorher, double skala = 1.0, String tab = 'Aufgaben', Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung(role: role);
    vorher?.call(env);
    final container = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width >= kDesktopBreakpoint) {
      container.read(shellTabProvider.notifier).waehlen(kTabs.indexWhere((t) => t.label == tab));
      await warte(tester);
    } else {
      await zumTab(tester, tab);
    }
    return env;
  }

  Future<List<Aufgabe>> dbAufgaben(TestUmgebung e) => (e.db.select(e.db.aufgaben)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  testWidgets('Tab "Aufgaben" mit Kopfzeile und Leerzustand', (tester) async {
    await start(tester);
    expect(find.byType(TasksScreen), findsOneWidget);
    expect(find.text('Aufgaben'), findsWidgets);
    expect(find.text('Noch keine Aufgaben'), findsOneWidget);
    expect(find.byType(TabKopfzeile), findsOneWidget);
    pruefeLayout(tester, 'Leerzustand');
  });

  testWidgets('Liste: Standard "Offen" nach Fälligkeit, Überfälliges markiert, Priorität und Person sichtbar; Erledigte erst unter "Erledigt"', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Später', tage: 3));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Gestern vergessen', tage: -1, prio: 3, zu: fixIdKind));
      e.sync.andereAendert('aufgabe', _a3, _aufgabe('Ohne Datum'));
      e.sync.andereAendert('aufgabe', _a4, _aufgabe('Schon fertig', tage: 0, erledigt: true));
    });
    expect(find.text('Schon fertig'), findsNothing);
    final y = [for (final t in ['Gestern vergessen', 'Später', 'Ohne Datum']) tester.getTopLeft(find.text(t)).dy];
    expect(y[0], lessThan(y[1]));
    expect(y[1], lessThan(y[2]));
    expect(find.textContaining('überfällig · gestern'), findsOneWidget);
    expect(find.text('hoch'), findsOneWidget);
    expect(find.text('3 offen · 1 erledigt'), findsOneWidget);
    pruefeLayout(tester, 'Liste');
    await tippeText(tester, 'Erledigt');
    expect(find.text('Schon fertig'), findsOneWidget);
    expect(find.text('Später'), findsNothing);
    await tippeText(tester, 'Alle');
    expect(find.text('Schon fertig'), findsOneWidget);
    expect(find.text('Später'), findsOneWidget);
    // erledigte unten
    expect(tester.getTopLeft(find.text('Schon fertig')).dy, greaterThan(tester.getTopLeft(find.text('Ohne Datum')).dy));
  });

  testWidgets('Sortierung nach Priorität, Filter "Meine" und je Person', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Niedrig früh', tage: 0, prio: 1, zu: fixIdAdmin));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Hoch spät', tage: 5, prio: 3, zu: fixIdKind));
      e.sync.andereAendert('aufgabe', _a3, _aufgabe('Mittel', tage: 2, prio: 2, zu: fixIdKind));
    });
    expect(tester.getTopLeft(find.text('Niedrig früh')).dy, lessThan(tester.getTopLeft(find.text('Hoch spät')).dy));
    await tippeText(tester, 'Nach Priorität');
    expect(tester.getTopLeft(find.text('Hoch spät')).dy, lessThan(tester.getTopLeft(find.text('Mittel')).dy));
    expect(tester.getTopLeft(find.text('Mittel')).dy, lessThan(tester.getTopLeft(find.text('Niedrig früh')).dy));
    await tippeText(tester, 'Meine');
    expect(find.text('Niedrig früh'), findsOneWidget);
    expect(find.text('Hoch spät'), findsNothing);
    await tippeText(tester, 'Offen');
    await tippeText(tester, 'Alle Personen');
    await tippeText(tester, 'Ben');
    expect(find.text('Niedrig früh'), findsNothing);
    expect(find.text('Hoch spät'), findsOneWidget);
    expect(find.text('Mittel'), findsOneWidget);
    pruefeLayout(tester, 'Person gefiltert');
  });

  testWidgets('Schnell anlegen: Titel eintippen, Plus: lokal sofort in der Liste und im Ausgang; leere Eingabe tut nichts', (tester) async {
    final env = await start(tester);
    await tippe(tester, find.byTooltip('Aufgabe hinzufügen'));
    expect(await dbAufgaben(env), isEmpty);
    await tester.enterText(find.widgetWithText(TextField, 'Neue Aufgabe'), 'Milch kaufen');
    await tippe(tester, find.byTooltip('Aufgabe hinzufügen'));
    expect(find.text('Milch kaufen'), findsOneWidget);
    final a = (await dbAufgaben(env)).single;
    expect([a.titel, a.erledigtAt, a.ownerId], ['Milch kaufen', null, fixIdAdmin]);
    expect(await env.db.select(env.db.outbox).get(), isNotEmpty);
  });

  testWidgets('Abhaken: verschwindet aus "Offen", Zeit und Person gesetzt; wiederkehrende Aufgabe legt die nächste an', (tester) async {
    final env = await start(tester, vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Tonne', tage: 0, wdh: 'weekly'));
    });
    expect(find.text('Tonne'), findsOneWidget);
    await tippe(tester, find.byIcon(Icons.check_box_outline_blank));
    final alle = await dbAufgaben(env);
    expect(alle, hasLength(2));
    expect(alle.where((a) => a.erledigtAt != null).single.erledigtVon, fixIdAdmin);
    final folge = alle.firstWhere((a) => a.erledigtAt == null);
    expect([folge.titel, folge.faelligDate, folge.wiederholung], ['Tonne', _tag(7), 'weekly']);
    expect(find.text('Tonne'), findsOneWidget); // nur die Folgeaufgabe ist noch offen
    expect(find.textContaining('wöchentlich'), findsOneWidget);
    // Zurücksetzen unter "Erledigt"
    await tippeText(tester, 'Erledigt');
    await tippe(tester, find.byIcon(Icons.check_box));
    expect((await dbAufgaben(env)).where((a) => a.erledigtAt != null), isEmpty);
  });

  testWidgets('Editor: neue Aufgabe mit Fälligkeit, Priorität, Zuständigen, Unteraufgaben und Wiederholung', (tester) async {
    final env = await start(tester, groesse: const Size(360, 1800)); // hoch: alles ohne Scrollen erreichbar
    await tippeDirekt(tester, find.byTooltip('Aufgabe mit Details anlegen'));
    expect(find.byType(AufgabeEditor), findsOneWidget);
    expect(find.text('Für eine Wiederholung braucht die Aufgabe ein Fälligkeitsdatum.'), findsOneWidget);
    await tippeDirekt(tester, find.text('Aufgabe anlegen'));
    expect(find.text('Gib der Aufgabe einen Titel.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Zimmer aufräumen');
    await tippeDirekt(tester, find.text('Morgen'));
    await tippeDirekt(tester, find.text('Hoch'));
    await tippeDirekt(tester, find.text('Ben'));
    await tippeDirekt(tester, find.text('Wöchentlich'));
    await tester.enterText(find.widgetWithText(TextField, 'Unteraufgabe hinzufügen'), 'Bett machen');
    await tippeDirekt(tester, find.byTooltip('Unteraufgabe hinzufügen').first);
    await tester.enterText(find.widgetWithText(TextField, 'Unteraufgabe hinzufügen'), 'Staub saugen'); // ohne Plus: geht beim Speichern nicht verloren
    pruefeLayout(tester, 'Editor neu');
    await tippeDirekt(tester, find.text('Aufgabe anlegen'));
    expect(find.byType(AufgabeEditor), findsNothing);
    final a = (await dbAufgaben(env)).single;
    expect([a.titel, a.faelligDate, a.prioritaet, a.assigneeId, a.wiederholung, a.audience], ['Zimmer aufräumen', _tag(1), 3, fixIdKind, 'weekly', 'family']);
    final punkte = await env.db.select(env.db.aufgabePunkte).get();
    expect(punkte.map((p) => p.inhalt).toList()..sort(), ['Bett machen', 'Staub saugen']);
    expect(find.text('Zimmer aufräumen'), findsOneWidget);
    expect(find.text('0/2'), findsOneWidget);
  });

  testWidgets('Editor: Fälligkeit mit Uhrzeit wird als UTC mit Zeitzone gespeichert', (tester) async {
    final env = await start(tester, groesse: const Size(360, 1800)); // hoch: alles ohne Scrollen erreichbar
    await tippeDirekt(tester, find.byTooltip('Aufgabe mit Details anlegen'));
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Anrufen');
    await tippeDirekt(tester, find.text('Heute'));
    await tippeDirekt(tester, find.byType(Switch));
    await tippeDirekt(tester, find.text('Aufgabe anlegen'));
    final a = (await dbAufgaben(env)).single;
    expect(a.faelligDate, isNull);
    expect(a.faelligUtc, isNotNull);
    expect(a.tzid, 'Europe/Berlin');
  });

  testWidgets('Editor: Aufgabe bearbeiten (Felder gefüllt, nur Änderung gespeichert), Unteraufgabe entfernen, Löschen mit Rückfrage', (tester) async {
    final env = await start(tester, groesse: const Size(360, 1800), vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Altes Fahrrad', tage: 2, prio: 2));
      e.sync.andereAendert('aufgabe_punkt', 'cccccccc-1111-4111-8111-111111111111', {'aufgabeId': _a1, 'text': 'Reifen', 'position': 0});
    });
    await tippeDirekt(tester, find.text('Altes Fahrrad'));
    expect(find.byType(AufgabeEditor), findsOneWidget);
    expect(find.text('Altes Fahrrad'), findsOneWidget);
    expect(find.text('Reifen'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Neues Fahrrad');
    await tippeDirekt(tester, find.byTooltip('Unteraufgabe entfernen'));
    await tippeDirekt(tester, find.text('Speichern'));
    final a = (await dbAufgaben(env)).single;
    expect([a.titel, a.prioritaet, a.faelligDate], ['Neues Fahrrad', 2, _tag(2)]);
    expect(await env.db.select(env.db.aufgabePunkte).get(), isEmpty);
    // löschen: erst Rückfrage, Abbrechen behält die Aufgabe
    await tippeDirekt(tester, find.text('Neues Fahrrad'));
    await tippeDirekt(tester, find.text('Aufgabe löschen'));
    expect(find.text('Aufgabe „Neues Fahrrad“ löschen?'), findsOneWidget);
    await tippeDirekt(tester, find.text('Abbrechen'));
    expect(await dbAufgaben(env), hasLength(1));
    await tippeDirekt(tester, find.text('Aufgabe löschen'));
    await tippeDirekt(tester, find.widgetWithText(FilledButton, 'Löschen'));
    expect(find.byType(AufgabeEditor), findsNothing);
    expect(await dbAufgaben(env), isEmpty);
    expect(find.text('Noch keine Aufgaben'), findsOneWidget);
  });

  testWidgets('Wischen nach links löscht erst nach Rückfrage', (tester) async {
    final env = await start(tester, vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Wegwerfen'));
    });
    await tester.drag(find.text('Wegwerfen'), const Offset(-300, 0));
    await warte(tester);
    expect(find.text('Aufgabe „Wegwerfen“ löschen?'), findsOneWidget);
    await tippeText(tester, 'Abbrechen');
    expect(find.text('Wegwerfen'), findsOneWidget);
    expect(await dbAufgaben(env), hasLength(1));
    await tester.drag(find.text('Wegwerfen'), const Offset(-300, 0));
    await warte(tester);
    await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
    expect(find.text('Wegwerfen'), findsNothing);
    expect(await dbAufgaben(env), isEmpty);
  });

  testWidgets('Kind: eigene Aufgaben änderbar, fremde nur ansehen (Haken gesperrt, Editor schreibgeschützt); Eltern-Aufgaben unsichtbar (Server)', (tester) async {
    final env = await start(tester, role: 'child', vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Meine Aufgabe', owner: fixIdAdmin));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Von Mama', owner: fixIdKind));
    });
    expect(find.text('Meine Aufgabe'), findsOneWidget);
    expect(find.text('Von Mama'), findsOneWidget);
    // Haken der fremden Aufgabe: nichts passiert
    await tippe(tester, find.byIcon(Icons.check_box_outline_blank).last);
    expect((await dbAufgaben(env)).where((a) => a.erledigtAt != null), isEmpty);
    await tippeText(tester, 'Von Mama');
    expect(find.text('Du darfst diese Aufgabe ansehen, aber nicht ändern.'), findsOneWidget);
    expect(find.text('Speichern'), findsNothing);
    expect(find.text('Aufgabe löschen'), findsNothing);
    expect(find.text('Sichtbar für'.toUpperCase()), findsNothing);
    await tippe(tester, find.byTooltip('Zurück'));
    await tippeText(tester, 'Meine Aufgabe');
    expect(find.text('Speichern'), findsOneWidget);
    expect(find.text('// sichtbar für'.toUpperCase()), findsNothing, reason: 'Kinder ändern die Freigabe nicht');
    pruefeLayout(tester, 'Editor Kind');
  });

  testWidgets('Eltern sehen die Freigabe im Editor', (tester) async {
    await start(tester);
    await tippe(tester, find.byTooltip('Aufgabe mit Details anlegen'));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
    await warte(tester);
    expect(find.text('// sichtbar für'.toUpperCase()), findsOneWidget);
    expect(find.widgetWithText(AuswahlKnopf, 'Nur Eltern'), findsOneWidget);
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Layout 360 px, Textskala $skala: lange Titel, alle Angaben, Filterzeilen, Editor, Dashboard', (tester) async {
      await start(tester, skala: skala, vorher: (e) {
        e.sync.andereAendert('aufgabe', _a1, _aufgabe('Ein sehr langer Titel einer Aufgabe, die über mehrere Zeilen läuft und trotzdem passen muss', tage: -2, prio: 3, zu: fixIdKind, wdh: 'weekly'));
        e.sync.andereAendert('aufgabe_punkt', 'cccccccc-1111-4111-8111-111111111111', {'aufgabeId': _a1, 'text': 'Eins', 'position': 0});
        e.sync.andereAendert('aufgabe', _a2, _aufgabe('Kurz', tage: 0, prio: 1, zu: fixIdAdmin));
        e.sync.andereAendert('aufgabe', _a3, _aufgabe('Erledigt', erledigt: true));
      });
      pruefeLayout(tester, 'Liste');
      await tippeText(tester, 'Alle');
      pruefeLayout(tester, 'Liste alle');
      await tippeText(tester, 'Nach Priorität');
      pruefeLayout(tester, 'Liste Priorität');
      await tippe(tester, find.byTooltip('Aufgabe mit Details anlegen'));
      pruefeLayout(tester, 'Editor');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await warte(tester);
      pruefeLayout(tester, 'Editor unten');
      await tippe(tester, find.byTooltip('Zurück'));
      await zumTab(tester, 'Start');
      pruefeLayout(tester, 'Start');
      expect(find.text('// aufgaben'.toUpperCase()), findsOneWidget);
    });
  }

  testWidgets('Kind: zugewiesene Aufgabe der Eltern kann abgehakt werden (Haken bedienbar, Unteraufgaben-Häkchen wirken sofort), sonst bleibt sie schreibgeschützt', (tester) async {
    final env = await start(tester, role: 'child', groesse: const Size(360, 1400), vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Zimmer saugen', zu: fixIdAdmin, owner: fixIdKind));
      e.sync.andereAendert('aufgabe_punkt', 'cccccccc-1111-4111-8111-111111111111', {'aufgabeId': _a1, 'text': 'Teppich', 'position': 0});
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Nicht meine', zu: fixIdKind, owner: fixIdKind));
    });
    // Editor: Hinweis "zugewiesen", Felder gesperrt, Unteraufgabe abhakbar
    await tippeText(tester, 'Zimmer saugen');
    expect(find.textContaining('Diese Aufgabe ist dir zugewiesen'), findsOneWidget);
    expect(find.text('Speichern'), findsNothing);
    expect(find.text('Aufgabe löschen'), findsNothing);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Titel')).enabled, isFalse);
    await tippe(tester, find.byIcon(Icons.check_box_outline_blank));
    final punkt = (await env.db.select(env.db.aufgabePunkte).get()).single;
    expect(punkt.doneAt, isNotNull);
    await tippe(tester, find.byTooltip('Zurück'));
    // Liste: die zugewiesene Aufgabe lässt sich abhaken, die fremde nicht
    final haken = find.byIcon(Icons.check_box_outline_blank);
    expect(haken, findsNWidgets(2));
    await tippe(tester, haken.first);
    final alle = await dbAufgaben(env);
    expect(alle.where((a) => a.erledigtAt != null).map((a) => a.id), [_a1]);
    expect(alle.singleWhere((a) => a.id == _a1).erledigtVon, fixIdAdmin);
    final op = (await env.db.select(env.db.outbox).get()).where((o) => o.entity == 'aufgabe' && o.entityId == _a1).map((o) => o.fieldsJson).join();
    expect(op, isNot(contains('erledigtVon')));
    pruefeLayout(tester, 'Kind zugewiesen');
  });

  testWidgets('Editor: Warnung, wenn die zuständige Person (Kind) eine nur für Eltern sichtbare Aufgabe nicht sehen darf', (tester) async {
    await start(tester, groesse: const Size(360, 1800));
    await tippeDirekt(tester, find.byTooltip('Aufgabe mit Details anlegen'));
    expect(find.textContaining('nur für Eltern sichtbar'), findsNothing);
    await tippeDirekt(tester, find.text('Ben'));
    await tippeDirekt(tester, find.text('Nur Eltern'));
    expect(find.textContaining('Die Aufgabe ist nur für Eltern sichtbar, die zuständige Person ist ein Kind'), findsOneWidget);
    await tippeDirekt(tester, find.text('Familie'));
    expect(find.textContaining('nur für Eltern sichtbar'), findsNothing);
  });

  testWidgets('Erledigt-Ansicht: "Erledigte löschen" mit Rückfrage; Schnell-Anlegen dort wechselt auf "Offen"', (tester) async {
    final env = await start(tester, vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Fertig 1', erledigt: true));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Fertig 2', erledigt: true));
      e.sync.andereAendert('aufgabe', _a3, _aufgabe('Offen 1'));
    });
    expect(find.textContaining('Erledigte löschen'), findsNothing);
    await tippeText(tester, 'Erledigt');
    expect(find.text('Erledigte löschen (2)'), findsOneWidget);
    await tippeText(tester, 'Erledigte löschen (2)');
    expect(find.text('2 erledigte Aufgaben löschen?'), findsOneWidget);
    await tippeText(tester, 'Abbrechen');
    expect(await dbAufgaben(env), hasLength(3));
    await tester.enterText(find.widgetWithText(TextField, 'Neue Aufgabe'), 'Neu im Erledigt-Filter');
    await tippe(tester, find.byTooltip('Aufgabe hinzufügen'));
    expect(find.text('Neu im Erledigt-Filter'), findsOneWidget, reason: 'zurück auf Offen: die neue Aufgabe ist sichtbar');
    await tippeText(tester, 'Erledigt');
    await tippeText(tester, 'Erledigte löschen (2)');
    await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
    expect((await dbAufgaben(env)).map((a) => a.titel).toSet(), {'Offen 1', 'Neu im Erledigt-Filter'});
  });

  testWidgets('Wischen: die Zeile ist sofort weg, auch bevor die Datenbank nachzieht', (tester) async {
    final env = await start(tester, vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Weg 1'));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Bleibt'));
    });
    await tester.drag(find.text('Weg 1'), const Offset(-300, 0));
    await warte(tester);
    await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
    expect(find.text('Weg 1'), findsNothing);
    expect(find.text('Bleibt'), findsOneWidget);
    expect((await dbAufgaben(env)).map((a) => a.titel), ['Bleibt']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Viele Aufgaben: die Liste baut nur sichtbare Zeilen (lazy)', (tester) async {
    await start(tester, vorher: (e) {
      for (var i = 0; i < 200; i++) {
        e.sync.andereAendert('aufgabe', 'dddddddd-0000-4000-8000-${i.toString().padLeft(12, '0')}', _aufgabe('Aufgabe $i', tage: i));
      }
    });
    final gebaut = find.byIcon(Icons.check_box_outline_blank).evaluate().length;
    expect(gebaut, greaterThan(3));
    expect(gebaut, lessThan(40), reason: 'nicht alle 200 Zeilen sind gebaut');
    expect(find.text('200 offen · 0 erledigt'), findsOneWidget);
  });

  testWidgets('Sechs Navigationsziele bei 360 px und Textskala 1.5: kein Label abgeschnitten, Touch-Ziele >= 44 px', (tester) async {
    await start(tester, skala: 1.5, tab: 'Start');
    for (final t in kTabs) {
      final p = find.descendant(of: find.byType(NavigationBar), matching: find.text(t.label));
      expect(p, findsOneWidget, reason: t.label);
      final ro = tester.renderObject<RenderParagraph>(p);
      expect(ro.didExceedMaxLines, isFalse, reason: 'Label ${t.label} abgeschnitten');
      expect(ro.size.width, lessThanOrEqualTo(360 / kTabs.length + 0.5), reason: 'Label ${t.label} breiter als sein Ziel');
    }
    pruefeLayout(tester, 'Sechs Tabs');
  });

  testWidgets('Startseite mobil: Karte "Aufgaben" zeigt Überfälliges und bald Fälliges, Tippen öffnet den Bereich', (tester) async {
    await start(tester, tab: 'Start', vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Überfällig', tage: -3));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Morgen dran', tage: 1));
      e.sync.andereAendert('aufgabe', _a3, _aufgabe('Irgendwann'));
      e.sync.andereAendert('aufgabe', _a4, _aufgabe('Nächsten Monat', tage: 40));
    });
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await warte(tester);
    expect(find.text('Überfällig'), findsOneWidget);
    expect(find.text('Morgen dran'), findsOneWidget);
    expect(find.text('Irgendwann'), findsNothing);
    expect(find.text('Nächsten Monat'), findsNothing);
    expect(find.textContaining('überfällig · '), findsOneWidget);
    await tippe(tester, find.text('Morgen dran'));
    expect(find.byType(TasksScreen), findsOneWidget);
  });

  testWidgets('Desktop: "Aufgaben" in der Seitenleiste ist aktiv, Startseiten-Karte mit echten Aufgaben, Tippen öffnet den Bereich', (tester) async {
    await start(tester, tab: 'Start', groesse: const Size(1440, 900), vorher: (e) {
      e.sync.andereAendert('aufgabe', _a1, _aufgabe('Steuererklärung', tage: -1, prio: 3));
      e.sync.andereAendert('aufgabe', _a2, _aufgabe('Garage aufräumen'));
    });
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(find.text('Steuererklärung'), findsOneWidget);
    expect(find.text('Garage aufräumen'), findsOneWidget);
    expect(find.text('2 offen · 1 überfällig'), findsOneWidget);
    expect(find.text('Aufgaben kommen in einer späteren Phase.'), findsNothing);
    await tippe(tester, find.text('Steuererklärung'));
    expect(find.byType(TasksScreen), findsOneWidget);
    // Seitenleiste: Eintrag ist ein echter Tab (kein "bald")
    await tippe(tester, find.text('Start').first);
    await tippe(tester, find.text('Aufgaben').first);
    expect(find.byType(TasksScreen), findsOneWidget);
  });

  testWidgets('Desktop: leere Startseiten-Karte "Aufgaben"', (tester) async {
    await start(tester, tab: 'Start', groesse: const Size(1440, 900));
    expect(find.text('Noch keine Aufgaben'), findsWidgets);
    expect(find.text('Lege im Bereich Aufgaben die erste an.'), findsOneWidget);
  });
}
