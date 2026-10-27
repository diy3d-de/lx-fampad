// Fristen-Oberfläche: Ansicht "Fristen" im Aufgaben-Tab (Ampel, Sortierung, Neue Frist), Editor (Vorlage, Pflichtangaben, Bearbeiten), Erledigen mit
// Folgefrist, Startseiten-Kachel (mobil und Desktop, nur mit dringender Frist); bei 360 px Breite und Textskala 1.0/1.5/2.0.
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tasks/frist_editor.dart';
import 'package:lx_fampad/features/tasks/fristen_anzeige.dart';
import 'package:lx_fampad/features/tasks/tasks_screen.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _f1 = 'cccccccc-1111-4111-8111-111111111111';
const _f2 = 'cccccccc-2222-4222-8222-222222222222';
const _f3 = 'cccccccc-3333-4333-8333-333333333333';
const _f4 = 'cccccccc-4444-4444-8444-444444444444';

String _tag(int tage) {
  final h = heuteTag();
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

Map<String, dynamic> _frist(String titel, {required int tage, int vorwarn = 30, int? monate = 12, bool erledigt = false}) => {
  'titel': titel,
  'faelligDate': _tag(tage),
  'frist': true,
  'fristMonate': monate,
  'erinnerungMin': vorwarn * 1440,
  'erledigtAt': erledigt ? DateTime.now().toUtc().toIso8601String() : null,
};

Future<void> tippeDirekt(WidgetTester tester, Finder f) async {
  await tester.tap(f.first);
  await warte(tester);
}

Future<void> zumTab(WidgetTester tester, String label) => zumBereich(tester, label);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', void Function(TestUmgebung env)? vorher, double skala = 1.0, String tab = 'Aufgaben', Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.add(echteUhr); // Daten dieser Datei entstehen relativ zur echten Uhr
    env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
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

  void seed(TestUmgebung e) {
    e.sync.andereAendert('aufgabe', _f1, _frist('Reisepass', tage: 200, vorwarn: 90));
    e.sync.andereAendert('aufgabe', _f2, _frist('TÜV', tage: 10));
    e.sync.andereAendert('aufgabe', _f3, _frist('Versicherung', tage: -5));
    e.sync.andereAendert('aufgabe', _f4, {'titel': 'Normale Aufgabe', 'faelligDate': _tag(1)});
  }

  testWidgets('Ansicht "Fristen": nur Fristen, nach Ablauf sortiert, Ampel-Text und Wiederholung; Aufgaben-Tab behält seine Kopfzeile', (tester) async {
    await start(tester, vorher: seed);
    expect(find.text('Normale Aufgabe'), findsOneWidget, reason: 'in "Offen" stehen Fristen und Aufgaben');
    await tippeText(tester, 'Fristen');
    expect(find.text('Normale Aufgabe'), findsNothing);
    final y = [for (final t in ['Versicherung', 'TÜV', 'Reisepass']) tester.getTopLeft(find.text(t)).dy];
    expect(y[0], lessThan(y[1]));
    expect(y[1], lessThan(y[2]));
    expect(find.textContaining('seit 5 Tagen überfällig'), findsOneWidget);
    expect(find.textContaining('in 10 Tagen'), findsOneWidget);
    expect(find.textContaining('in 7 Monaten'), findsOneWidget);
    expect(find.text('Jährlich'), findsNWidgets(3));
    expect(find.text('Neue Frist'), findsOneWidget);
    expect(find.text('Nach Fälligkeit'), findsNothing, reason: 'Fristen sind immer nach Ablauf sortiert');
    pruefeLayout(tester, 'Fristen');
  });

  testWidgets('Ansicht "Fristen" ohne Fristen: Leerzustand mit Hinweis', (tester) async {
    await start(tester);
    await tippeText(tester, 'Fristen');
    expect(find.text('Noch keine Fristen'), findsOneWidget);
    expect(find.text('Neue Frist'), findsOneWidget);
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Ansicht und Editor, Textskala $skala: keine Layoutfehler bei 360 px', (tester) async {
      await start(tester, vorher: seed, skala: skala, groesse: const Size(360, 900));
      await tippeText(tester, 'Fristen');
      pruefeLayout(tester, 'Fristen Liste');
      await tippe(tester, find.text('Neue Frist'));
      expect(find.byType(FristEditor), findsOneWidget);
      pruefeLayout(tester, 'Frist-Editor');
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -1500));
      await warte(tester);
      pruefeLayout(tester, 'Frist-Editor unten');
    });
  }

  testWidgets('Editor neu: Vorlage füllt Titel, Wiederholung und Vorwarnzeit vor; ohne Ablaufdatum wird nichts gespeichert', (tester) async {
    final env = await start(tester, groesse: const Size(360, 2400));
    await tippeText(tester, 'Fristen');
    await tippeDirekt(tester, find.text('Neue Frist'));
    await tippeDirekt(tester, find.text('Reisepass'));
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Titel')).controller!.text, 'Reisepass');
    await tippeDirekt(tester, find.text('Frist anlegen'));
    expect(find.text('Wähle das Ablaufdatum.'), findsOneWidget);
    expect(await dbAufgaben(env), isEmpty);
    await tippeDirekt(tester, find.text('Datum wählen'));
    await tippeDirekt(tester, find.text('OK'));
    await tippeDirekt(tester, find.text('Frist anlegen'));
    expect(find.byType(FristEditor), findsNothing);
    final a = (await dbAufgaben(env)).single;
    expect([a.titel, a.frist, a.fristMonate, a.erinnerungMin, a.faelligDate, a.wiederholung, a.audience], ['Reisepass', true, 120, 90 * 1440, _tag(0), null, 'family']);
    expect(find.text('Reisepass'), findsOneWidget);
  });

  testWidgets('Editor bearbeiten: Wiederholung und Vorwarnzeit ändern; Tippen auf eine Frist öffnet den Frist-Editor', (tester) async {
    final env = await start(tester, vorher: seed, groesse: const Size(360, 2400));
    await tippeText(tester, 'Fristen');
    await tippeDirekt(tester, find.text('TÜV'));
    expect(find.byType(FristEditor), findsOneWidget);
    expect(find.text('Frist bearbeiten'), findsOneWidget);
    await tippeDirekt(tester, find.text('Alle 2 Jahre'));
    await tippeDirekt(tester, find.text('60 Tage vorher'));
    await tippeDirekt(tester, find.text('Speichern'));
    expect(find.byType(FristEditor), findsNothing);
    final a = (await dbAufgaben(env)).firstWhere((x) => x.id == _f2);
    expect([a.fristMonate, a.erinnerungMin, a.frist], [24, 60 * 1440, true]);
  });

  testWidgets('Erledigen einer wiederkehrenden Frist legt die nächste an', (tester) async {
    final env = await start(tester, vorher: seed);
    await tippeText(tester, 'Fristen');
    await tippe(tester, find.byIcon(Icons.check_box_outline_blank).first); // Versicherung (ältester Ablauf)
    final alle = await dbAufgaben(env);
    final folge = alle.firstWhere((a) => a.titel == 'Versicherung' && a.erledigtAt == null);
    expect([folge.frist, folge.fristMonate, folge.erinnerungMin], [true, 12, 30 * 1440]);
    expect(DateTime.parse(folge.faelligDate!).isAfter(DateTime.parse(_tag(0))), isTrue);
    expect(find.text('Versicherung'), findsOneWidget);
  });

  testWidgets('Kind: sieht Fristen und darf eigene anlegen, fremde nur ansehen', (tester) async {
    await start(tester, role: 'child', vorher: seed);
    await tippeText(tester, 'Fristen');
    expect(find.text('Reisepass'), findsOneWidget);
    expect(find.text('Neue Frist'), findsOneWidget);
    await tippeDirekt(tester, find.text('Reisepass'));
    expect(find.text('Du darfst diese Frist ansehen, aber nicht ändern.'), findsOneWidget);
    expect(find.text('Speichern'), findsNothing);
  });

  testWidgets('Startseite mobil: Kachel "Fristen" zeigt dringende Fristen (ohne ruhige), Tippen öffnet die Ansicht "Fristen"', (tester) async {
    await start(tester, tab: 'Start', vorher: seed);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await warte(tester);
    expect(labelFinder('Fristen'), findsOneWidget);
    expect(find.byType(FristenStartKarte), findsOneWidget);
    Finder inKarte(String t) => find.descendant(of: find.byType(FristenStartKarte), matching: find.text(t));
    expect(inKarte('Versicherung'), findsOneWidget);
    expect(inKarte('TÜV'), findsOneWidget);
    expect(inKarte('Reisepass'), findsNothing, reason: 'noch nicht in der Vorwarnzeit (200 Tage, Vorwarnung 90)');
    await tippe(tester, inKarte('TÜV'));
    expect(find.byType(TasksScreen), findsOneWidget);
    expect(find.text('Normale Aufgabe'), findsNothing, reason: 'die Ansicht "Fristen" ist gewählt');
    expect(find.text('Reisepass'), findsOneWidget);
  });

  testWidgets('Startseite: ohne dringende Frist gibt es die Kachel nicht', (tester) async {
    await start(tester, tab: 'Start', vorher: (e) {
      e.sync.andereAendert('aufgabe', _f1, _frist('Reisepass', tage: 200, vorwarn: 90));
      e.sync.andereAendert('aufgabe', _f2, _frist('Alt', tage: -30, erledigt: true));
    });
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await warte(tester);
    expect(find.byType(FristenStartKarte), findsNothing);
    expect(labelFinder('Fristen'), findsNothing);
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Startseite mobil mit Kachel, Textskala $skala: keine Layoutfehler bei 360 px', (tester) async {
      await start(tester, tab: 'Start', vorher: seed, skala: skala);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      pruefeLayout(tester, 'Startseite mit Fristen');
    });
  }

  testWidgets('Desktop: Kachel "Fristen" im Raster, Tippen öffnet die Ansicht "Fristen"', (tester) async {
    await start(tester, tab: 'Start', groesse: const Size(1440, 900), vorher: seed);
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(labelFinder('Fristen'), findsOneWidget);
    await tippe(tester, find.descendant(of: find.byType(FristenStartKarte), matching: find.text('Versicherung')));
    expect(find.byType(TasksScreen), findsOneWidget);
    expect(find.text('Normale Aufgabe'), findsNothing);
  });
}
