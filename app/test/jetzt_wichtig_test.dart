// Block "Jetzt wichtig" auf der Startseite: reine Logik (Überfälliges, Heutiges, Müll, Obergrenze, Rollen), Oberfläche mobil und Desktop (Symbol UND Text,
// Tipp öffnet den Bereich, Schalter), und dass die Standard-Reihenfolge und gemerkte Listen der Kacheln unverändert gelten.
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher, feiertageSpeicherProvider;
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/muell/muell_modelle.dart';
import 'package:lx_fampad/data/startseite/jetzt_wichtig_logik.dart';
import 'package:lx_fampad/data/startseite/jetzt_wichtig_state.dart';
import 'package:lx_fampad/data/startseite/startseite_logik.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart' show heuteTag;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart' show fixIdAdmin;
import 'support/harness.dart';
import 'support/test_app.dart';

const ich = 'u-ich';

/// Montag 19.10.2026 12:00 Uhr Berlin (Sommerzeit).
final jetzt = DateTime.utc(2026, 10, 19, 10);

Termin termin(String id, {String titel = 'Zahnarzt', String? start, String? ende}) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: false,
  startUtc: DateTime.parse(start!),
  endUtc: DateTime.parse(ende!),
  tzid: 'Europe/Berlin',
  startDate: null,
  endDate: null,
  rrule: null,
  erinnerungMin: null,
  icalUid: null,
  audience: 'family',
  ownerId: ich,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

Aufgabe aufgabe(String id, String titel, {String? faellig, String audience = 'family', bool frist = false, DateTime? erledigt, String? zustaendig}) => Aufgabe(
  id: id,
  titel: titel,
  beschreibung: '',
  faelligDate: faellig,
  prioritaet: 0,
  assigneeId: zustaendig,
  ownerId: ich,
  erledigtAt: erledigt,
  frist: frist,
  erinnerungMin: null,
  audience: audience,
  createdAt: DateTime.utc(2026, 1, 1),
  rev: 1,
);

JetztWichtig bau({List<Termin> termine = const [], List<Aufgabe> aufgaben = const [], bool eltern = true, String? person = ich, List<MuellTag>? muell}) =>
    baueJetztWichtig(kalender: KalenderDaten(termine: termine), aufgaben: aufgaben, ich: person, elternRolle: eltern, jetzt: jetzt, muell: muell);

List<String> texte(JetztWichtig b) => [for (final z in b.zeilen) '${z.art.name}|${z.text}|${z.zusatz}'];

String _tag(int tage) {
  final h = heuteTag(TestUmgebung.testJetzt);
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

void main() {
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  group('Logik', () {
    test('leer: nichts zu zeigen; ohne angemeldete Person ebenfalls', () {
      expect(bau().hatInhalt, isFalse);
      expect(bau(person: null, aufgaben: [aufgabe('a', 'X', faellig: '2026-10-01')]).hatInhalt, isFalse);
    });

    test('Überfälliges zuerst (Ältestes oben, mit Wort "überfällig"), dann Termine, heute fällige Aufgaben, Müll', () {
      final b = bau(
        aufgaben: [
          aufgabe('a1', 'Rechnung zahlen', faellig: '2026-10-17'),
          aufgabe('a2', 'Zeitung abbestellen', faellig: '2026-10-18'),
          aufgabe('a3', 'Blumen gießen', faellig: '2026-10-19'),
          aufgabe('a4', 'Später', faellig: '2026-10-25'),
          aufgabe('a5', 'Erledigt', faellig: '2026-10-10', erledigt: DateTime.utc(2026, 10, 11)),
        ],
        termine: [termin('t1', start: '2026-10-19T13:30:00Z', ende: '2026-10-19T14:30:00Z'), termin('t0', titel: 'Vorbei', start: '2026-10-19T06:00:00Z', ende: '2026-10-19T07:00:00Z')],
        muell: [MuellTag(DateTime.utc(2026, 10, 20), const [MuellArt.bio])],
      );
      expect(texte(b), [
        'ueberfaellig|Rechnung zahlen|2 Tage überfällig',
        'ueberfaellig|Zeitung abbestellen|1 Tag überfällig',
        'termin|Zahnarzt|15:30',
        'aufgabe|Blumen gießen|heute fällig',
        'muell|Bioabfall morgen|Müll',
      ]);
      expect(b.gesamt, 5);
      expect(b.weitere, 0);
      expect(b.zeilen.where((z) => z.dringend).length, 2);
    });

    test('überfällige Frist zählt, eine ruhige Frist nicht; mehr als fünf ergeben "+ n weitere"', () {
      final b = bau(
        aufgaben: [
          aufgabe('f1', 'Reisepass', faellig: '2026-10-01', frist: true),
          aufgabe('f2', 'TÜV', faellig: '2027-05-01', frist: true),
          for (var i = 0; i < 6; i++) aufgabe('a$i', 'Alt $i', faellig: '2026-10-1${i + 1 > 9 ? 9 : i + 1}'),
        ],
      );
      expect(b.zeilen, hasLength(kJetztWichtigMax));
      expect(b.zeilen.first.text, 'Reisepass');
      expect(b.gesamt, 7);
      expect(b.weitere, 2);
      expect(texte(b).any((t) => t.contains('TÜV')), isFalse);
    });

    test('Sicht "nur Eltern": ein Kind sieht die Aufgabe nie, ein Elternteil schon', () {
      final liste = [aufgabe('p', 'Steuer', faellig: '2026-10-01', audience: 'parents')];
      expect(bau(aufgaben: liste, eltern: false).hatInhalt, isFalse);
      expect(bau(aufgaben: liste, eltern: true).hatInhalt, isTrue);
    });

    test('Müll heute und morgen, aber nicht übermorgen', () {
      final b = bau(muell: [MuellTag(DateTime.utc(2026, 10, 19), const [MuellArt.rest]), MuellTag(DateTime.utc(2026, 10, 21), const [MuellArt.bio])]);
      expect(b.zeilen, hasLength(1));
      expect(b.zeilen.single.text, endsWith('heute'));
    });
  });

  test('nie Chat, Standort, Zähler, Tresor, Medikamente, Vorsorge, Dateien oder Schlüssel: der Block bindet nur Termine, Aufgaben und Müll ein', () {
    final verboten = RegExp(r"import '[^']*(chat|standort|zaehler|tresor|medikament|vorsorge|dateien|crypto|ingest)[^']*'");
    for (final pfad in ['lib/data/startseite/jetzt_wichtig_logik.dart', 'lib/data/startseite/jetzt_wichtig_state.dart', 'lib/features/home/jetzt_wichtig_block.dart']) {
      final treffer = verboten.allMatches(File(pfad).readAsStringSync()).map((m) => m.group(0)).toList();
      expect(treffer, isEmpty, reason: pfad);
    }
  });

  group('Standard-Reihenfolge und gemerkte Listen', () {
    test('der Block ist eine feste Zeile über den Kacheln: keine neue Kennung in der Kachel-Liste, gemerkte Listen bleiben gültig', () {
      for (final l in StartLayout.values) {
        expect(l.standard.any((id) => id.contains('jetzt')), isFalse, reason: 'fest oben, nicht verschiebbar und nicht in der gemerkten Reihenfolge');
      }
      const gemerkt = ['aufgaben', 'einkauf', 'unbekannt'];
      expect(vollstaendigeReihenfolge(StartLayout.mobil.standard, gemerkt).take(2), ['aufgaben', 'einkauf']);
    });
  });

  group('Oberfläche', () {
    Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, {Size groesse = const Size(360, 900), String an = 'ja', void Function(TestUmgebung e)? vorher}) async {
      final env = await angemeldeteUmgebung();
      env.speicher = MemoryFeiertageSpeicher('nein', {kJetztWichtigSchluessel: an});
      vorher?.call(env);
      final c = await starteApp(tester, env, groesse: groesse);
      return (env, c);
    }

    void daten(TestUmgebung e) {
      e.sync.andereAendert('aufgabe', 'bbbbbbbb-1111-4111-8111-111111111111', {'titel': 'Rechnung zahlen', 'faelligDate': _tag(-2), 'prioritaet': 0, 'assigneeId': fixIdAdmin, 'erledigtAt': null, 'wiederholung': null});
    }

    testWidgets('mobil: Überfälliges mit Wort und Symbol, steht über den Kacheln, Tipp öffnet Aufgaben', (tester) async {
      final h = tester.ensureSemantics();
      final (_, c) = await start(tester, vorher: daten);
      expect(find.text('Jetzt wichtig'), findsOneWidget);
      expect(find.text('Rechnung zahlen'), findsWidgets);
      expect(find.text('2 Tage überfällig'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsWidgets, reason: 'Symbol neben dem Wort, nie nur Farbe');
      expect(find.bySemanticsLabel(RegExp('Überfällig: Rechnung zahlen, 2 Tage überfällig')), findsOneWidget);
      final zeile = find.byKey(const ValueKey('jetzt:ueberfaellig:Rechnung zahlen'));
      expect(tester.getSize(zeile).height, greaterThanOrEqualTo(44));
      expect(tester.getTopLeft(find.text('Jetzt wichtig')).dy, lessThan(tester.getTopLeft(labelFinder('Als nächstes')).dy));
      await tester.tap(zeile);
      await warte(tester);
      expect(c.read(shellTabProvider), kAufgabenTab);
      h.dispose();
    });

    testWidgets('Schalter aus oder nichts zu tun: kein Block', (tester) async {
      await start(tester, an: 'nein', vorher: daten);
      expect(find.text('Jetzt wichtig'), findsNothing);
      await start(tester);
      expect(find.text('Jetzt wichtig'), findsNothing, reason: 'ohne Aufgaben, Termine und Müll nichts zu zeigen');
    });

    testWidgets('Desktop: Block steht auch auf der Desktop-Startseite', (tester) async {
      await start(tester, groesse: const Size(1280, 1000), vorher: daten);
      expect(find.text('Jetzt wichtig'), findsOneWidget);
    });

    testWidgets('mobil bei Textskala 2.0: Zeilen umbrechen, kein Überlauf', (tester) async {
      final env = await angemeldeteUmgebung();
      env.speicher = MemoryFeiertageSpeicher('nein', {kJetztWichtigSchluessel: 'ja'});
      daten(env);
      await starteApp(tester, env, skala: 2.0);
      expect(find.text('Jetzt wichtig'), findsOneWidget);
      pruefeLayout(tester, 'Jetzt wichtig, Skala 2.0');
    });

    test('Schalter wird lokal gemerkt und gelesen', () async {
      final speicher = MemoryFeiertageSpeicher('nein', {});
      final c = ProviderContainer(overrides: [feiertageSpeicherProvider.overrideWithValue(speicher)]);
      addTearDown(c.dispose);
      expect(c.read(jetztWichtigAnProvider), isTrue);
      await c.read(jetztWichtigAnProvider.notifier).setzen(false);
      expect(speicher.werte[kJetztWichtigSchluessel], 'nein');
      expect(c.read(jetztWichtigAnProvider), isFalse);
    });
  });
}
