// Termin-Farben in der Oberfläche: Farbwahl im Editor (Layout bei 360 px und Textskala 1.0, 1.5, 2.0), Anzeige in Agenda, Monat und Detail,
// Rückfall auf die Personenfarbe, Avatar der Person, Farbfilter im Filter-Blatt (lokal, Termine ohne Farbe bleiben immer sichtbar).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher, kKalenderAnsichtSchluessel;
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/termin_editor.dart' show FarbWahl;
import 'package:lx_fampad/ui/widgets.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _t1 = 'cccccccc-1111-4111-8111-111111111111';
const _t2 = 'cccccccc-2222-4222-8222-222222222222';
const _t3 = 'cccccccc-3333-4333-8333-333333333333';

final _filterKnopf = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Filter und Anzeige'));

String _zeit(int tage, int stunde) {
  final heute = heuteTag();
  return instantAusWand(DateTime.utc(heute.year, heute.month, heute.day + tage, stunde), familienOrt).toIso8601String();
}

Map<String, dynamic> _termin(String titel, {int? farbe, int tage = 1, int stunde = 10, String? owner}) => {
  'titel': titel,
  'ort': '',
  'ganztaegig': false,
  'startUtc': _zeit(tage, stunde),
  'endUtc': _zeit(tage, stunde + 1),
  'tzid': 'Europe/Berlin',
  'ownerId': owner ?? fixIdAdmin,
  'audience': 'family',
  'farbe': farbe,
};

/// Balken (Container mit fester Farbe) in der Farbe [c].
Finder _balken(Color c) => find.byWidgetPredicate((w) => w is Container && w.color == c);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', void Function(TestUmgebung env)? vorher, double skala = 1.0, String tab = 'Kalender'}) async {
    final env = await angemeldeteUmgebung(role: role);
    vorher?.call(env);
    await starteApp(tester, env, skala: skala);
    await zumBereich(tester, tab);
    return env;
  }

  testWidgets('Agenda: Termin mit Farbe zeigt Balken in der Termin-Farbe und die Person als Avatar; ohne Farbe die Personenfarbe ohne Avatar', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('termin', _t1, _termin('Rufdienst-Woche', farbe: 10));
      e.sync.andereAendert('termin', _t2, _termin('Ohne Farbe', stunde: 14));
    });
    expect(find.text('Rufdienst-Woche'), findsOneWidget);
    expect(find.text('Ohne Farbe'), findsOneWidget);
    expect(_balken(personColor(3)), findsOneWidget, reason: 'Anna hat Personenfarbe 3: nur der Termin ohne Farbe');
    expect(_balken(personColor(3)), findsOneWidget, reason: 'Anna hat Personenfarbe 3: nur der Termin ohne Farbe');
    // Avatar nur am Termin mit Farbe (zusätzlich zum Profil-Knopf oben)
    final karte = find.ancestor(of: find.text('Rufdienst-Woche'), matching: find.byType(LxCard));
    expect(find.descendant(of: karte, matching: find.byType(PersonAvatar)), findsOneWidget);
    final karteOhne = find.ancestor(of: find.text('Ohne Farbe'), matching: find.byType(LxCard));
    expect(find.descendant(of: karteOhne, matching: find.byType(PersonAvatar)), findsNothing);
    pruefeLayout(tester, 'Agenda mit Farben');
  });

  testWidgets('Detail: Zeile "Farbe" mit Name; ohne Farbe keine Zeile', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('termin', _t1, _termin('Mit Farbe', farbe: 3));
      e.sync.andereAendert('termin', _t2, _termin('Ohne Farbe', stunde: 14));
    });
    await tippeText(tester, 'Mit Farbe');
    expect(find.text('Farbe: Arzt'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await warte(tester);
    await tippeText(tester, 'Ohne Farbe');
    expect(find.textContaining('Farbe:'), findsNothing);
  });

  testWidgets('Monat: Balken in der Termin-Farbe', (tester) async {
    await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _termin('Heute-Termin', tage: 0, stunde: 22, farbe: 10)));
    await tippeText(tester, 'Monat');
    expect(find.text('Heute-Termin'), findsOneWidget);
    expect(tester.takeException(), isNull);
    pruefeLayout(tester, 'Monat mit Farbe');
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Editor (Textskala $skala): Farbwahl mit "Keine" und elf Farben, Wahl wird gespeichert; Layout', (tester) async {
      final env = await start(tester, skala: skala);
      await tippe(tester, find.byTooltip('Neuer Termin'));
      expect(find.byType(FarbWahl), findsOneWidget);
      expect(find.bySemanticsLabel('Farbe: keine, Personenfarbe'), findsOneWidget);
      for (final f in kTerminFarben) {
        expect(find.bySemanticsLabel('Farbe ${f.name}'), findsOneWidget, reason: f.name);
      }
      pruefeLayout(tester, 'Editor Farbwahl');
      await eingeben(tester, 'Titel', 'Bereitschaft');
      await tippe(tester, find.bySemanticsLabel('Farbe Rufdienst'));
      pruefeLayout(tester, 'Editor nach Farbwahl');
      await tippeText(tester, 'Termin anlegen');
      await warte(tester, 10);
      final t = (await env.db.select(env.db.termine).get()).single;
      expect(t.farbe, 10);
      await warte(tester, 30);
      expect(env.sync.zeilen.values.where((z) => z.entity == 'termin').single.fields['farbe'], 10);
    });
  }

  testWidgets('Editor: bestehende Farbe ist vorbelegt, "Keine" entfernt sie', (tester) async {
    final env = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _termin('Training', farbe: 4)));
    await tippeText(tester, 'Training');
    await tippeText(tester, 'Bearbeiten');
    final sel = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Farbe Sport' && w.properties.selected == true);
    expect(sel, findsOneWidget);
    await tippe(tester, find.bySemanticsLabel('Farbe: keine, Personenfarbe'));
    await tippeText(tester, 'Speichern');
    await warte(tester, 8);
    expect((await env.db.select(env.db.termine).get()).single.farbe, isNull);
  });

  testWidgets('Filter: Farben ausblenden, Termine ohne Farbe bleiben; Zahlen, Alle aus/an, lokal gemerkt', (tester) async {
    final speicher = MemoryFeiertageSpeicher('nein', {kKalenderAnsichtSchluessel: 'agenda'});
    final env = await start(tester, vorher: (e) {
      e.speicher = speicher;
      e.sync.andereAendert('termin', _t1, _termin('Sporttermin', farbe: 4));
      e.sync.andereAendert('termin', _t2, _termin('Arzttermin', farbe: 3, stunde: 12));
      e.sync.andereAendert('termin', _t3, _termin('Ohne Farbe', stunde: 14));
    });
    expect(find.text('Sporttermin'), findsOneWidget);
    await tippe(tester, _filterKnopf);
    expect(find.text('Farben'.toLowerCase()), findsNothing);
    expect(labelFinder('Farben'), findsOneWidget);
    expect(find.text('Rufdienst'), findsOneWidget);
    await tippe(tester, find.widgetWithText(SwitchListTile, 'Sport'));
    expect(find.byTooltip('Filter und Anzeige, 3 aktiv'), findsOneWidget, reason: 'ein Farbfilter zählt als einer (Feiertage/Ferien sind im Test aus)');
    await tippeText(tester, 'Fertig');
    expect(find.text('Sporttermin'), findsNothing);
    expect(find.text('Arzttermin'), findsOneWidget);
    expect(find.text('Ohne Farbe'), findsOneWidget);
    expect(await speicher.lesen(schluessel: kFarbenAusSchluessel), '4');
    // Alle aus: nur Termine ohne Farbe bleiben
    await tippe(tester, _filterKnopf);
    await tippeText(tester, 'Alle aus');
    await tippeText(tester, 'Fertig');
    expect(find.text('Arzttermin'), findsNothing);
    expect(find.text('Ohne Farbe'), findsOneWidget);
    // Alle an
    await tippe(tester, _filterKnopf);
    await tippeText(tester, 'Alle an');
    await tippeText(tester, 'Fertig');
    expect(find.text('Sporttermin'), findsOneWidget);
    expect(find.text('Arzttermin'), findsOneWidget);
    expect(await speicher.lesen(schluessel: kFarbenAusSchluessel), '');
    // der Filter hat nie einen Termin verändert
    expect((await env.db.select(env.db.termine).get()).map((t) => t.farbe).toSet(), {4, 3, null});
    pruefeLayout(tester, 'Filter');
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Filter-Blatt (Textskala $skala): Layout und Touch-Ziele', (tester) async {
      await start(tester, skala: skala, vorher: (e) => e.sync.andereAendert('termin', _t1, _termin('Sporttermin', farbe: 4)));
      await tippe(tester, _filterKnopf);
      expect(labelFinder('Farben'), findsOneWidget);
      pruefeLayout(tester, 'Filter-Blatt');
    });
  }

  testWidgets('Gemerkter Filter wird beim Start gelesen', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('termin', _t1, _termin('Sporttermin', farbe: 4));
      e.sync.andereAendert('termin', _t2, _termin('Ohne Farbe', stunde: 14));
    });
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    await container.read(farbenAusProvider.notifier).umschalten(4);
    expect(container.read(farbenAusProvider), {4});
    await warte(tester);
    expect(find.text('Sporttermin'), findsNothing);
    expect(find.text('Ohne Farbe'), findsOneWidget);
  });
}
