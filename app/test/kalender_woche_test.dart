// Wochenansicht des Kalenders: reine Logik (Aufteilung über Mitternacht, Spuren überlappender Termine, Band, Sommerzeit-Wochen, Serien, abgesagte
// Vorkommen, Scroll-Ziel, gerundete Uhrzeit, Titel der Leiste) und Oberfläche (Raster, Tipp auf Block, Tageskopf und leere Stelle, Wochenwechsel, Jetzt-Linie,
// Kopfzeile, 360 px bei Textskala 1.0/1.5/2.0, Desktop mit Tagespanel). Die Oberflächen-Tests prüfen Reihenfolgen und Zugehörigkeit, keine festen Höhen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/monat_layout.dart' show BalkenArt, BalkenQuelle, kalenderwoche, wochenLayout;
import 'package:lx_fampad/data/calendar/woche_layout.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/kalender_leiste.dart' show kalenderTitel;
import 'package:lx_fampad/features/calendar/kalender_woche.dart';
import 'package:lx_fampad/features/calendar/termin_editor.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

DateTime _d(int j, int m, int t) => DateTime.utc(j, m, t);

String _id(int n) => 'aaaaaaaa-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Termin _termin(String id, String titel, String startUtc, String endUtc, {String? rrule}) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: false,
  startUtc: DateTime.parse(startUtc),
  endUtc: DateTime.parse(endUtc),
  tzid: 'Europe/Berlin',
  startDate: null,
  endDate: null,
  rrule: rrule,
  erinnerungMin: null,
  icalUid: null,
  audience: 'family',
  ownerId: null,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

Termin _ganz(String id, String titel, String start, String endExklusiv) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: true,
  startUtc: null,
  endUtc: null,
  tzid: null,
  startDate: start,
  endDate: endExklusiv,
  rrule: null,
  erinnerungMin: null,
  icalUid: null,
  audience: 'family',
  ownerId: null,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

/// Vorkommen der Woche ab [montag] (Wanduhr-Fenster, wie die Oberfläche es abfragt).
List<Vorkommen> _woche(DateTime montag, List<Termin> termine, {Map<String, List<TerminAusnahme>> ausnahmen = const {}}) => vorkommenImFenster(
  termine: termine,
  ausnahmen: ausnahmen,
  vonWand: montag,
  bisWand: DateTime.utc(montag.year, montag.month, montag.day + 7),
  jetzt: DateTime.utc(2026, 10, 19),
);

(int, int) _zeit(WochenBlock b) => (b.start, b.ende);

Map<String, dynamic> _zeitDaten(String titel, String startUtc, String endUtc, {String? rrule}) => {
  'titel': titel,
  'ganztaegig': false,
  'startUtc': startUtc,
  'endUtc': endUtc,
  'tzid': 'Europe/Berlin',
  'rrule': ?rrule,
  'ownerId': fixIdAdmin,
  'audience': 'family',
};

Map<String, dynamic> _ganzDaten(String titel, DateTime von, DateTime bisInklusive) => {
  'titel': titel,
  'ganztaegig': true,
  'startDate': tagText(von),
  'endDate': tagText(bisInklusive.add(const Duration(days: 1))),
  'ownerId': fixIdAdmin,
  'audience': 'family',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  // ---------------------------------------------------------------------------------------------- reine Logik

  group('zeitBloecke', () {
    final montag = _d(2027, 3, 8);

    test('Termin an einem Tag: Minuten seit 0:00, nicht offen', () {
      final b = zeitBloecke(montag, _woche(montag, [_termin('a', 'A', '2027-03-10T14:00:00Z', '2027-03-10T15:30:00Z')])).single; // 15:00 bis 16:30 MEZ
      expect(b.tag, 2);
      expect(_zeit(b), (900, 990));
      expect(b.vorneOffen || b.hintenOffen, isFalse);
      expect((b.spalte, b.spalten), (0, 1));
    });

    test('über Mitternacht: Teil bis 24:00 und Teil ab 0:00, mit offenen Rändern', () {
      final bs = zeitBloecke(montag, _woche(montag, [_termin('a', 'Nacht', '2027-03-12T21:00:00Z', '2027-03-13T01:00:00Z')])); // Fr 22:00 bis Sa 02:00
      expect(bs.map((b) => b.tag), [4, 5]);
      expect(_zeit(bs[0]), (1320, 1440));
      expect(bs[0].hintenOffen, isTrue);
      expect(bs[0].vorneOffen, isFalse);
      expect(_zeit(bs[1]), (0, 120));
      expect(bs[1].vorneOffen, isTrue);
      expect(bs[1].hintenOffen, isFalse);
    });

    test('Ende genau um 0 Uhr: kein Stück am Folgetag; Beginn Sonntag über den Wochenrand: nur der Teil der Woche', () {
      final bis = zeitBloecke(montag, _woche(montag, [_termin('a', 'A', '2027-03-10T21:00:00Z', '2027-03-10T23:00:00Z')])); // 22:00 bis 24:00
      expect(bis.map((b) => b.tag), [2]);
      expect(_zeit(bis.single), (1320, 1440));
      final sonntag = zeitBloecke(montag, _woche(montag, [_termin('a', 'A', '2027-03-14T22:00:00Z', '2027-03-15T01:00:00Z')])); // So 23:00 bis Mo 02:00
      expect(sonntag.map((b) => b.tag), [6], reason: 'der Teil am Montag danach gehört in die nächste Woche');
    });

    test('Termin der Vorwoche, der in die Woche hineinreicht, steht am Montag ab 0:00', () {
      final bs = zeitBloecke(montag, _woche(montag, [_termin('a', 'A', '2027-03-07T22:00:00Z', '2027-03-08T01:00:00Z')])); // So 23:00 bis Mo 02:00
      expect(bs.map((b) => b.tag), [0]);
      expect(_zeit(bs.single), (0, 120));
      expect(bs.single.vorneOffen, isTrue);
    });

    test('Termin ohne Dauer erscheint trotzdem', () {
      final bs = zeitBloecke(montag, _woche(montag, [_termin('a', 'A', '2027-03-10T09:00:00Z', '2027-03-10T09:00:00Z')]));
      expect(bs.map(_zeit), [(600, 600)]);
    });

    test('Ganztägige und Termine ab 24 Stunden gehören ins Band, nicht in die Blöcke; knapp unter 24 Stunden bleiben Blöcke', () {
      final liste = _woche(montag, [
        _ganz('g', 'Fest', '2027-03-10', '2027-03-11'),
        _termin('l', 'Lang', '2027-03-09T08:00:00Z', '2027-03-10T08:00:00Z'),
        _termin('k', 'Knapp', '2027-03-09T08:00:00Z', '2027-03-10T07:59:00Z'),
      ]);
      expect([for (final v in liste) (v.termin.id, gehoertInsBand(v))]..sort((a, b) => a.$1.compareTo(b.$1)), [('g', true), ('k', false), ('l', true)]);
      expect(zeitBloecke(montag, liste).map((b) => b.v.termin.id).toSet(), {'k'});
    });

    test('ganztägig: Ende exklusiv, das Band endet am letzten Tag (nicht am Folgetag)', () {
      final v = _woche(montag, [_ganz('g', 'Ferienhaus', '2027-03-11', '2027-03-14')]).single; // 11. bis 13.
      expect((v.ersterTag, v.letzterTag), (_d(2027, 3, 11), _d(2027, 3, 13)));
      final q = BalkenQuelle(id: 'g', text: 'Ferienhaus', farbe: kAccent, art: BalkenArt.termin, von: v.ersterTag, bis: v.letzterTag);
      final l = wochenLayout(montag: montag, quellen: [q], maxSpuren: 3).balken.single;
      expect((l.start, l.ende), (3, 5));
    });

    test('Überlappung: Gruppen teilen die Breite, danach geht es wieder volle Breite; kurze Termine belegen mindestens 30 Minuten', () {
      // 10:00-12:00, 11:00-13:00, 12:00-14:00 (A, B, C), danach 15:00-16:00 (D); alle MEZ = UTC + 1
      final bs = zeitBloecke(montag, _woche(montag, [
        _termin('a', 'A', '2027-03-10T09:00:00Z', '2027-03-10T11:00:00Z'),
        _termin('b', 'B', '2027-03-10T10:00:00Z', '2027-03-10T12:00:00Z'),
        _termin('c', 'C', '2027-03-10T11:00:00Z', '2027-03-10T13:00:00Z'),
        _termin('d', 'D', '2027-03-10T14:00:00Z', '2027-03-10T15:00:00Z'),
        _termin('e', 'E', '2027-03-10T16:00:00Z', '2027-03-10T16:10:00Z'), // 17:00 bis 17:10
        _termin('f', 'F', '2027-03-10T16:20:00Z', '2027-03-10T16:30:00Z'), // 17:20 bis 17:30, liegt in der 30-Minuten-Belegung von E
      ]));
      final spur = {for (final b in bs) b.v.termin.id: (b.spalte, b.spalten)};
      expect(spur['a'], (0, 2));
      expect(spur['b'], (1, 2));
      expect(spur['c'], (0, 2), reason: 'A ist um 12:00 zu Ende, C nimmt die erste freie Spur');
      expect(spur['d'], (0, 1));
      expect(spur['e'], (0, 2));
      expect(spur['f'], (1, 2));
    });

    test('drei gleichzeitige Termine: drei Spuren, gleiche Termine verschiedener Tage beeinflussen sich nicht', () {
      final bs = zeitBloecke(montag, _woche(montag, [
        _termin('a', 'A', '2027-03-10T09:00:00Z', '2027-03-10T10:00:00Z'),
        _termin('b', 'B', '2027-03-10T09:00:00Z', '2027-03-10T10:00:00Z'),
        _termin('c', 'C', '2027-03-10T09:00:00Z', '2027-03-10T10:00:00Z'),
        _termin('d', 'D', '2027-03-11T09:00:00Z', '2027-03-11T10:00:00Z'),
      ]));
      expect(bs.where((b) => b.tag == 2).map((b) => (b.spalte, b.spalten)).toSet(), {(0, 3), (1, 3), (2, 3)});
      expect(bs.singleWhere((b) => b.tag == 3).spalten, 1);
    });

    test('Sommerzeit-Ende (Woche vom 19.10.2026, Umstellung Sonntag 25.10. 03:00 -> 02:00): Uhrzeiten sind die der Wanduhr', () {
      final mo = _d(2026, 10, 19);
      final bs = zeitBloecke(mo, _woche(mo, [
        _termin('a', 'Früh', '2026-10-24T22:30:00Z', '2026-10-24T23:30:00Z'), // So 00:30 bis 01:30 MESZ
        _termin('b', 'Danach', '2026-10-25T02:00:00Z', '2026-10-25T03:00:00Z'), // So 03:00 bis 04:00 MEZ
        _termin('c', 'Montag', '2026-10-19T07:00:00Z', '2026-10-19T08:00:00Z'), // Mo 09:00 bis 10:00 MESZ
        _termin('d', 'Nach Umstellung', '2026-10-26T08:00:00Z', '2026-10-26T09:00:00Z'), // Mo 09:00 bis 10:00 MEZ
      ]));
      final nach = {for (final b in bs) b.v.termin.id: (b.tag, b.start, b.ende)};
      expect(nach['a'], (6, 30, 90));
      expect(nach['b'], (6, 180, 240));
      expect(nach['c'], (0, 540, 600));
      expect(bs.where((b) => b.v.termin.id == 'd'), isEmpty, reason: 'liegt in der Folgewoche');
    });

    test('Sommerzeit-Beginn (Woche vom 22.3.2027, Umstellung Sonntag 28.3. 02:00 -> 03:00): Nacht über die Umstellung wird geteilt', () {
      final mo = _d(2027, 3, 22);
      final bs = zeitBloecke(mo, _woche(mo, [
        _termin('a', 'Umstellung', '2027-03-27T22:00:00Z', '2027-03-28T01:30:00Z'), // Sa 23:00 bis So 03:30 MESZ
        _termin('b', 'Danach', '2027-03-28T01:30:00Z', '2027-03-28T02:30:00Z'), // So 03:30 bis 04:30 MESZ
        _termin('c', 'Mo', '2027-03-22T08:00:00Z', '2027-03-22T09:00:00Z'), // Mo 09:00 bis 10:00 MEZ
        _termin('d', 'Mo danach', '2027-03-29T07:00:00Z', '2027-03-29T08:00:00Z'), // Folgewoche
      ]));
      expect([for (final b in bs) if (b.v.termin.id == 'a') (b.tag, b.start, b.ende)], [(5, 1380, 1440), (6, 0, 210)]);
      expect([for (final b in bs) if (b.v.termin.id == 'b') (b.tag, b.start, b.ende)], [(6, 210, 270)]);
      expect([for (final b in bs) if (b.v.termin.id == 'c') (b.tag, b.start, b.ende)], [(0, 540, 600)]);
      expect(bs.where((b) => b.v.termin.id == 'd'), isEmpty);
    });

    test('Serie: jedes Vorkommen der Woche ein Block; abgesagtes fehlt; verschobenes steht am neuen Tag', () {
      final mo = _d(2027, 3, 8);
      final serie = _termin('s', 'Chor', '2027-03-03T17:00:00Z', '2027-03-03T18:00:00Z', rrule: 'FREQ=DAILY;COUNT=20'); // täglich 18:00 MEZ ab Mi 3.3.
      TerminAusnahme ausnahme(String original, {bool abgesagt = false, String? start, String? ende}) =>
          TerminAusnahme(id: 'x$original', terminId: 's', originalStart: original, abgesagt: abgesagt, titel: null, start: start, ende: ende, ort: null, rev: 1);
      final bs = zeitBloecke(
        mo,
        _woche(mo, [serie], ausnahmen: {
          's': [
            ausnahme('2027-03-10T17:00:00Z', abgesagt: true),
            ausnahme('2027-03-11T17:00:00Z', start: '2027-03-11T07:00:00Z', ende: '2027-03-11T08:00:00Z'), // Do: 08:00 bis 09:00
          ],
        }),
      );
      expect(bs.map((b) => b.tag).toList()..sort(), [0, 1, 3, 4, 5, 6], reason: 'Mittwoch abgesagt');
      expect(bs.singleWhere((b) => b.tag == 3).start, 480);
      expect(bs.singleWhere((b) => b.tag == 0).start, 1080);
    });
  });

  group('Hilfen', () {
    test('scrollZielMinute: heute eine Stunde vor jetzt, sonst vor dem frühesten Termin, sonst 7:00', () {
      WochenBlock b(int start) => WochenBlock(v: _woche(_d(2027, 3, 8), [_termin('a', 'A', '2027-03-10T09:00:00Z', '2027-03-10T10:00:00Z')]).single, tag: 2, start: start, ende: start + 60);
      expect(scrollZielMinute(bloecke: [b(900)], jetztMinute: 14 * 60 + 20), 13 * 60 + 20);
      expect(scrollZielMinute(bloecke: const [], jetztMinute: 30), 0);
      expect(scrollZielMinute(bloecke: [b(900), b(600)]), 570);
      expect(scrollZielMinute(bloecke: [b(10)]), 0);
      expect(scrollZielMinute(bloecke: const []), 420);
    });

    test('gerundeteMinute rundet auf 30 Minuten ab und bleibt im Tag', () {
      expect(gerundeteMinute(0), 0);
      expect(gerundeteMinute(14 * 60 + 29.9), 14 * 60);
      expect(gerundeteMinute(14 * 60 + 30), 14 * 60 + 30);
      expect(gerundeteMinute(23 * 60 + 59), 23 * 60 + 30);
      expect(gerundeteMinute(-12), 0);
      expect(gerundeteMinute(25 * 60), 23 * 60 + 30);
    });

    test('Titel der Leiste: mobil "KW 43 · Okt 2026", Desktop mit Zeitraum, auch über Monats- und Jahreswechsel', () {
      KalenderAuswahl a(DateTime t) => KalenderAuswahl(ansicht: KalenderAnsicht.woche, tag: t);
      expect(kalenderTitel(a(_d(2026, 10, 21)), breit: false), (haupt: 'KW 43 · Okt 2026', unter: null));
      expect(kalenderTitel(a(_d(2026, 10, 21)), breit: true), (haupt: 'KW 43 · 19.–25. Oktober 2026', unter: null));
      expect(kalenderTitel(a(_d(2026, 10, 28)), breit: true).haupt, 'KW 44 · 26. Oktober – 1. November 2026');
      expect(kalenderTitel(a(_d(2026, 10, 28)), breit: false).haupt, 'KW 44 · Okt 2026', reason: 'der Donnerstag (29.10.) bestimmt den Monat');
      expect(kalenderTitel(a(_d(2026, 12, 30)), breit: true).haupt, 'KW 53 · 28. Dezember 2026 – 3. Januar 2027');
      expect(kalenderTitel(a(_d(2026, 12, 30)), breit: false).haupt, 'KW 53 · Dez 2026');
    });
  });

  // ---------------------------------------------------------------------------------------------- Oberfläche

  Future<(TestUmgebung, ProviderContainer)> start(
    WidgetTester tester, {
    void Function(TestUmgebung env)? vorher,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    DateTime? tag,
  }) async {
    final env = await angemeldeteUmgebung();
    vorher?.call(env);
    final container = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width >= kDesktopBreakpoint) {
      container.read(shellTabProvider.notifier).waehlen(kTabs.indexWhere((t) => t.label == 'Kalender'));
    } else {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
    }
    await warte(tester);
    container.read(kalenderAuswahlProvider.notifier).ansicht(KalenderAnsicht.woche);
    if (tag != null) container.read(kalenderAuswahlProvider.notifier).tag(tag);
    await warte(tester);
    return (env, container);
  }

  Finder block(String id) => find.byWidgetPredicate((w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().startsWith('woche-block-$id|'));
  Finder blockAmTag(String id, int tag) => find.byWidgetPredicate((w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().startsWith('woche-block-$id|') && (w.key! as ValueKey).value.toString().endsWith('|$tag'));
  Finder kopf(DateTime t) => find.byKey(ValueKey('woche-kopf-${tagText(t)}'));
  Finder spalte(DateTime t) => find.byKey(ValueKey('woche-spalte-${tagText(t)}'));

  // Woche vom 8. bis 14.3.2027 (MEZ): zwei sich überlappende Termine am Mittwoch, Ganztägiges und Mehrtägiges im Band, eine Nacht über Mitternacht
  void demoWoche(TestUmgebung e) {
    e.sync.andereAendert('termin', _id(1), _zeitDaten('Schwimmen', '2027-03-10T14:00:00.000Z', '2027-03-10T15:00:00.000Z')); // 15:00 bis 16:00
    e.sync.andereAendert('termin', _id(2), _zeitDaten('Training', '2027-03-10T16:00:00.000Z', '2027-03-10T17:00:00.000Z')); // 17:00 bis 18:00
    e.sync.andereAendert('termin', _id(3), _zeitDaten('Einkauf', '2027-03-10T16:30:00.000Z', '2027-03-10T17:30:00.000Z')); // 17:30 bis 18:30
    e.sync.andereAendert('termin', _id(4), _zeitDaten('Nachtwache', '2027-03-12T21:00:00.000Z', '2027-03-13T01:00:00.000Z')); // Fr 22:00 bis Sa 02:00
    e.sync.andereAendert('termin', _id(5), _ganzDaten('Kita-Fest', _d(2027, 3, 11), _d(2027, 3, 11)));
    e.sync.andereAendert('termin', _id(6), _ganzDaten('Ferienhaus', _d(2027, 3, 12), _d(2027, 3, 14)));
  }

  testWidgets('Raster: Blöcke je Tag in zeitlicher Reihenfolge, Überlappung nebeneinander, Nacht in zwei Teilen, Band mit Balken', (tester) async {
    await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    final mittwoch = tester.getRect(kopf(_d(2027, 3, 10)));
    final schwimmen = tester.getRect(block(_id(1)));
    final training = tester.getRect(block(_id(2)));
    final einkauf = tester.getRect(block(_id(3)));
    expect(schwimmen.top, lessThan(training.top), reason: '15:00 liegt über 17:00');
    for (final r in [schwimmen, training, einkauf]) {
      expect(r.left, greaterThanOrEqualTo(mittwoch.left - 1), reason: 'in der Mittwochsspalte');
      expect(r.right, lessThanOrEqualTo(mittwoch.right + 1));
    }
    expect(einkauf.left, greaterThanOrEqualTo(training.right - 1), reason: 'überlappend: nebeneinander');
    expect(schwimmen.width, greaterThan(training.width), reason: 'ohne Überlappung volle Spaltenbreite');
    expect(blockAmTag(_id(4), 4), findsOneWidget);
    expect(blockAmTag(_id(4), 5), findsOneWidget);
    expect(tester.getRect(blockAmTag(_id(4), 4)).left, lessThan(tester.getRect(blockAmTag(_id(4), 5)).left));
    // Band: Ganztägiges und Mehrtägiges sind keine Blöcke, sondern Balken (Text im Band); Ferienhaus läuft über drei Spalten
    expect(block(_id(5)), findsNothing);
    expect(block(_id(6)), findsNothing);
    expect(find.text('Kita-Fest'), findsOneWidget);
    expect(find.text('Ferienhaus'), findsOneWidget);
    expect(tester.getRect(find.text('Ferienhaus')).left, greaterThanOrEqualTo(tester.getRect(kopf(_d(2027, 3, 12))).left - 1));
    // Kopf: sieben Tage, Kalenderwoche
    expect(find.text('KW 10'), findsOneWidget);
    for (var i = 8; i <= 14; i++) {
      expect(kopf(_d(2027, 3, i)), findsOneWidget);
    }
    pruefeLayout(tester, 'Woche');
  });

  testWidgets('Beim Öffnen steht der erste Termin im sichtbaren Bereich (ohne Termine: ab 7 Uhr), Kopfzeile bleibt ausgeklappt', (tester) async {
    final (_, container) = await start(
      tester,
      tag: _d(2027, 3, 10),
      vorher: (e) => e.sync.andereAendert('termin', _id(1), _zeitDaten('Spät', '2027-03-10T19:00:00.000Z', '2027-03-10T20:00:00.000Z')), // 20:00 bis 21:00
    );
    final r = tester.getRect(block(_id(1)));
    expect(r.top, greaterThan(0));
    expect(r.bottom, lessThan(800), reason: 'der Termin um 20 Uhr ist beim Öffnen sichtbar');
    expect(container.read(kalenderKopfEingeklapptProvider), isFalse);
  });

  testWidgets('Tipp auf einen Block öffnet das Detailblatt', (tester) async {
    await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    await tippe(tester, block(_id(1)));
    expect(find.text('Bearbeiten'), findsOneWidget);
    expect(find.text('Schwimmen'), findsWidgets);
  });

  testWidgets('Block hat eine Beschreibung für Screenreader (Titel, Tag, Zeit), Tageskopf nennt Datum und Termine', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    final label = tester.getSemantics(block(_id(1))).label;
    expect(label, allOf(contains('Schwimmen'), contains('15:00'), contains('16:00')));
    final tag = tester.getSemantics(kopf(_d(2027, 3, 10))).label;
    expect(tag, allOf(contains('Mittwoch, 10. März'), contains('3 Termine')));
    expect(tester.getSemantics(kopf(_d(2027, 3, 9))).label, contains('keine Termine'));
    handle.dispose();
  });

  testWidgets('Tipp auf den Tageskopf öffnet das Tagesblatt des Tages (mit "Termin"), ein Tipp auf einen Termin darin das Detailblatt', (tester) async {
    await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    await tippe(tester, kopf(_d(2027, 3, 11)));
    expect(find.text('Donnerstag, 11. März'), findsOneWidget);
    expect(find.text('Kita-Fest'), findsWidgets);
    pruefeLayout(tester, 'Tagesblatt');
    await tester.tapAt(const Offset(10, 10));
    await warte(tester);
    await tippe(tester, kopf(_d(2027, 3, 10)));
    expect(find.text('Mittwoch, 10. März'), findsOneWidget);
    await tippe(tester, find.text('Schwimmen').last);
    expect(find.text('Bearbeiten'), findsOneWidget);
  });

  testWidgets('Tipp und Lang-Tipp auf eine leere Stelle legen einen Termin mit Tag und auf 30 Minuten abgerundeter Uhrzeit an', (tester) async {
    await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    // 15:00 und 17:00 sichtbar machen (beim Öffnen steht das Raster am frühesten Termin der Woche, hier die Nacht ab 0:00)
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -500));
    await warte(tester);
    // Stundenhöhe aus zwei Blöcken (15:00 und 17:00 am Mittwoch), nicht als feste Zahl
    final stunde = (tester.getRect(block(_id(2))).top - tester.getRect(block(_id(1))).top) / 2;
    final y15 = tester.getRect(block(_id(1))).top;
    final dienstag = tester.getRect(spalte(_d(2027, 3, 9)));

    await tester.tapAt(Offset(dienstag.center.dx, y15 + stunde * 0.4)); // 15:24
    await warte(tester);
    var editor = tester.widget<TerminEditor>(find.byType(TerminEditor));
    expect((editor.tag, editor.startMinute), (_d(2027, 3, 9), 15 * 60));
    expect(find.text('Neuer Termin'), findsWidgets);
    Navigator.of(tester.element(find.byType(TerminEditor))).pop();
    await warte(tester);
    expect(find.byType(TerminEditor), findsNothing);

    await tester.longPressAt(Offset(dienstag.center.dx, y15 + stunde * 2.75)); // 17:45
    await warte(tester);
    editor = tester.widget<TerminEditor>(find.byType(TerminEditor));
    expect((editor.tag, editor.startMinute), (_d(2027, 3, 9), 17 * 60 + 30));
  });

  testWidgets('ohne Anlegen-Recht (onLeer null) gibt es keine Tipp-Fläche für leere Stellen', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WochenRaster(
            montag: _d(2027, 3, 8),
            heute: _d(2027, 3, 10),
            gewaehlt: _d(2027, 3, 10),
            bloecke: const [],
            band: const [],
            farbe: (_) => kAccent,
            jetzt: () => DateTime.utc(2027, 3, 10, 12),
            onTag: (_) {},
            onBlock: (_) {},
            onLeer: null,
            onWoche: (_) {},
          ),
        ),
      ),
    );
    expect(spalte(_d(2027, 3, 9)), findsNothing);
    expect(find.byKey(const ValueKey('woche-jetzt')), findsOneWidget, reason: 'die Linie der aktuellen Uhrzeit steht in der Woche mit heute');
  });

  testWidgets('Wochenwechsel: Pfeile, Heute und Wischen; Titel der Leiste folgt; die Auswahl bleibt am selben Wochentag', (tester) async {
    final (_, container) = await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    expect(find.text('KW 10 · März 2027'), findsOneWidget);
    expect(block(_id(1)), findsOneWidget);
    await tippe(tester, find.byTooltip('Nächste Woche'));
    expect(find.text('KW 11 · März 2027'), findsOneWidget);
    expect(block(_id(1)), findsNothing);
    expect(container.read(kalenderAuswahlProvider).tag, _d(2027, 3, 17));
    await tippe(tester, find.byTooltip('Vorherige Woche'));
    expect(block(_id(1)), findsOneWidget);
    // Wischen nach links = nächste Woche, nach rechts = vorherige
    await tester.fling(kopf(_d(2027, 3, 10)), const Offset(-250, 0), 1200);
    await warte(tester);
    expect(find.text('KW 11 · März 2027'), findsOneWidget);
    expect(find.text('KW 10 · März 2027'), findsNothing);
    await tester.fling(kopf(_d(2027, 3, 17)), const Offset(250, 0), 1200);
    await warte(tester);
    expect(find.text('KW 10 · März 2027'), findsOneWidget);
    await tippe(tester, find.byTooltip('Heute'));
    expect(container.read(kalenderAuswahlProvider).tag, heuteTag());
    expect(find.text('KW ${kalenderwoche(heuteTag())}'), findsOneWidget);
  });

  testWidgets('senkrechtes Scrollen im Raster wechselt die Woche nicht und klappt die Kopfzeile ein; Zurückscrollen klappt sie aus', (tester) async {
    final (_, container) = await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    expect(find.text('Kalender'), findsWidgets);
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -300));
    await warte(tester);
    expect(find.text('KW 10 · März 2027'), findsOneWidget);
    expect(container.read(kalenderKopfEingeklapptProvider), isTrue);
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 3000));
    await warte(tester);
    expect(container.read(kalenderKopfEingeklapptProvider), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('heute: die Linie der aktuellen Uhrzeit steht in der aktuellen Woche, in anderen nicht', (tester) async {
    await start(tester, tag: heuteTag());
    expect(find.byKey(const ValueKey('woche-jetzt')), findsOneWidget);
    await tippe(tester, find.byTooltip('Nächste Woche'));
    expect(find.byKey(const ValueKey('woche-jetzt')), findsNothing);
  });

  testWidgets('Sommerzeit 28.3.2027: Nacht über die Umstellung liegt am Samstag und Sonntag, der Termin danach am Sonntag', (tester) async {
    await start(
      tester,
      tag: _d(2027, 3, 24),
      vorher: (e) {
        e.sync.andereAendert('termin', _id(1), _zeitDaten('Umstellung', '2027-03-27T22:00:00.000Z', '2027-03-28T01:30:00.000Z'));
        e.sync.andereAendert('termin', _id(2), _zeitDaten('Danach', '2027-03-28T01:30:00.000Z', '2027-03-28T02:30:00.000Z'));
      },
    );
    expect(blockAmTag(_id(1), 5), findsOneWidget);
    expect(blockAmTag(_id(1), 6), findsOneWidget);
    expect(blockAmTag(_id(2), 6), findsOneWidget);
    expect(tester.getRect(blockAmTag(_id(1), 6)).top, lessThan(tester.getRect(blockAmTag(_id(2), 6)).top));
  });

  testWidgets('abgesagtes Vorkommen einer Serie fehlt, die übrigen Tage stehen da', (tester) async {
    await start(
      tester,
      tag: _d(2027, 3, 10),
      vorher: (e) {
        e.sync.andereAendert('termin', _id(1), _zeitDaten('Chor', '2027-03-03T17:00:00.000Z', '2027-03-03T18:00:00.000Z', rrule: 'FREQ=WEEKLY'));
        e.sync.andereAendert('termin_ausnahmen', 'cccccccc-1111-4111-8111-111111111111', {'terminId': _id(1), 'originalStart': '2027-03-10T17:00:00Z', 'abgesagt': true});
      },
    );
    expect(block(_id(1)), findsNothing, reason: 'das Vorkommen dieser Woche ist abgesagt');
    await tippe(tester, find.byTooltip('Nächste Woche'));
    expect(block(_id(1)), findsOneWidget);
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('360 px, Textskala $skala: viele Termine, Band mit Überlauf, Nacht und Überlappung ohne Layoutfehler', (tester) async {
      // Die (nicht für 2.0 ausgelegte, unveränderte) Startseite meldet beim Aufbau einen Überlauf: nur dieser bekannte Fall wird ausgenommen.
      final alt = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.toString().contains('RenderFlex overflowed') && d.toString().contains('home_screen.dart')) return;
        alt!(d);
      };
      addTearDown(() => FlutterError.onError = alt);
      await start(
        tester,
        skala: skala,
        tag: _d(2027, 3, 10),
        vorher: (e) {
          demoWoche(e);
          for (var i = 0; i < 5; i++) {
            e.sync.andereAendert('termin', _id(20 + i), _ganzDaten('Band $i mit einem sehr langen Titel', _d(2027, 3, 9), _d(2027, 3, 11)));
          }
          for (var i = 0; i < 4; i++) {
            e.sync.andereAendert('termin', _id(30 + i), _zeitDaten('Gleichzeitig $i mit langem Titel', '2027-03-11T09:00:00.000Z', '2027-03-11T09:20:00.000Z'));
          }
        },
      );
      expect(find.textContaining('+'), findsWidgets, reason: 'Überlauf des Bands als "+n"');
      expect(blockAmTag(_id(30), 3), findsOneWidget);
      pruefeLayout(tester, 'Woche, Skala $skala');
      await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -2000));
      await warte(tester);
      pruefeLayout(tester, 'Woche gescrollt, Skala $skala');
    });
  }

  testWidgets('Sieben Spalten bei 360 px sind gleich breit und passen in den Bildschirm; Kopf-Ziele mindestens 44 px', (tester) async {
    await start(tester, tag: _d(2027, 3, 10), vorher: demoWoche);
    final rects = [for (var i = 8; i <= 14; i++) tester.getRect(kopf(_d(2027, 3, i)))];
    for (final r in rects) {
      expect(r.width, closeTo(rects.first.width, 0.5));
      expect(r.width, greaterThanOrEqualTo(44));
      expect(r.height, greaterThanOrEqualTo(44));
    }
    expect(rects.first.left, greaterThan(0));
    expect(rects.last.right, lessThanOrEqualTo(360));
  });

  for (final breite in [1440.0, 1000.0]) {
    testWidgets('Desktop ($breite px): Titel mit Zeitraum, Zeit im Block, ${breite >= 1440 ? 'Tagespanel statt Sheet' : 'schmal: Tagesblatt'}, Kopfzeile nie eingeklappt', (tester) async {
      final (_, container) = await start(tester, groesse: Size(breite, 900), tag: _d(2027, 3, 10), vorher: demoWoche);
      expect(find.text('KW 10 · 8.–14. März 2027'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Neuer Termin'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.textContaining('15:00–16:00'), findsOneWidget, reason: 'Desktop: Zeit im Block');
      if (breite >= 1440) {
        expect(find.text('Mittwoch, 10. März'), findsOneWidget, reason: 'Panel zeigt den gewählten Tag');
        expect(find.text('Termin an diesem Tag'), findsOneWidget);
        await tippe(tester, kopf(_d(2027, 3, 11)));
        expect(find.text('Donnerstag, 11. März'), findsOneWidget);
        expect(find.text('Mittwoch, 10. März'), findsNothing);
      } else {
        expect(find.text('Termin an diesem Tag'), findsNothing);
        await tippe(tester, kopf(_d(2027, 3, 11)));
        expect(find.text('Donnerstag, 11. März'), findsOneWidget, reason: 'Tagesblatt');
      }
      await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -300));
      await warte(tester);
      expect(container.read(kalenderKopfEingeklapptProvider), isFalse);
      pruefeLayout(tester, 'Desktop');
    });
  }
}
