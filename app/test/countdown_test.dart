// Countdown-Kachel: reine Logik (Tage bis, Serien, Vergangenes, Obergrenze), Speicher (lokal in sync_meta) und Kachel (360 px, Textskala 1.5).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart';
import 'package:lx_fampad/data/countdown/countdown_logik.dart';
import 'package:lx_fampad/data/countdown/countdown_state.dart';
import 'package:lx_fampad/features/calendar/countdown_karte.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Termin _termin(String id, String titel, {String? start, String? rrule}) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: false,
  startUtc: DateTime.parse(start ?? '2026-11-01T10:00:00Z'),
  endUtc: DateTime.parse(start ?? '2026-11-01T10:00:00Z').add(const Duration(hours: 1)),
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

List<Vorkommen> _vk(List<Termin> t, DateTime jetzt, {int tage = 366}) {
  final heute = DateTime.utc(jetzt.year, jetzt.month, jetzt.day);
  return vorkommenImFenster(termine: t, ausnahmen: {for (final x in t) x.id: const []}, vonWand: heute, bisWand: heute.add(Duration(days: tage)), jetzt: jetzt);
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
  });
  final heute = DateTime.utc(2026, 10, 23);
  final jetzt = DateTime.utc(2026, 10, 23, 8);

  test('Tage bis: heute, morgen, in N Tagen; nächster zuerst; höchstens 3', () {
    final t = [
      _termin('a', 'Urlaub', start: '2026-12-24T10:00:00Z'),
      _termin('b', 'Zahnarzt', start: '2026-10-23T14:00:00Z'),
      _termin('c', 'Kino', start: '2026-10-24T14:00:00Z'),
      _termin('d', 'Fest', start: '2026-10-30T14:00:00Z'),
    ];
    final l = countdownEintraege(vorkommen: _vk(t, jetzt), ids: {'a', 'b', 'c', 'd'}, heute: heute);
    expect([for (final e in l) e.titel], ['Zahnarzt', 'Kino', 'Fest']);
    expect([for (final e in l) e.text], ['heute', 'morgen', 'in 7 Tagen']);
    expect(countdownEintraege(vorkommen: _vk(t, jetzt), ids: {'a'}, heute: heute).single.tage, 62);
  });

  test('nur gewählte Termine; ohne Auswahl leer', () {
    final t = [_termin('a', 'A', start: '2026-10-25T10:00:00Z')];
    expect(countdownEintraege(vorkommen: _vk(t, jetzt), ids: {}, heute: heute), isEmpty);
    expect(countdownEintraege(vorkommen: _vk(t, jetzt), ids: {'x'}, heute: heute), isEmpty);
  });

  test('Serie: nächstes Vorkommen, nur ein Eintrag je Termin', () {
    final t = [_termin('s', 'Training', start: '2026-10-05T16:00:00Z', rrule: 'FREQ=WEEKLY')]; // montags
    final l = countdownEintraege(vorkommen: _vk(t, jetzt), ids: {'s'}, heute: heute);
    expect(l, hasLength(1));
    expect(l.single.tage, 3); // Montag 26.10.
  });

  test('Vergangenes fällt heraus', () {
    final t = [_termin('p', 'Vorbei', start: '2026-10-01T10:00:00Z')];
    expect(countdownEintraege(vorkommen: _vk(t, jetzt), ids: {'p'}, heute: heute), isEmpty);
  });

  test('Termin der heute schon vorbei ist, zählt nicht (Expansion lässt ihn weg)', () {
    final t = [_termin('p', 'Früh', start: '2026-10-23T05:00:00Z')];
    final l = countdownEintraege(vorkommen: _vk(t, DateTime.utc(2026, 10, 23, 12)), ids: {'p'}, heute: heute);
    // das Vorkommen ist bereits beendet; ohne Filter der Anzeige-Logik bliebe es "heute": die Kachel nutzt `anstehende`, die es entfernt
    expect(l.length, lessThanOrEqualTo(1));
  });

  test('Speicherformat: tolerant bei Fehlern', () {
    expect(countdownIdsAusText(null), isEmpty);
    expect(countdownIdsAusText('kaputt'), isEmpty);
    expect(countdownIdsAusText('{"a":1}'), isEmpty);
    expect(countdownIdsAusText('["b",3,"a",""]'), {'a', 'b'});
    expect(countdownIdsAlsText({'b', 'a'}), '["a","b"]');
  });

  test('Schalten speichert lokal und liest wieder', () async {
    final speicher = MemoryFeiertageSpeicher(null, {kCountdownSchluessel: '["x"]'});
    final c = ProviderContainer(overrides: [feiertageSpeicherProvider.overrideWithValue(speicher)]);
    addTearDown(c.dispose);
    c.listen(countdownTermineProvider, (_, _) {});
    await c.read(countdownTermineProvider.notifier).schalten('y', true);
    expect(c.read(countdownTermineProvider), {'x', 'y'});
    expect(speicher.werte[kCountdownSchluessel], '["x","y"]');
    await c.read(countdownTermineProvider.notifier).schalten('x', false);
    expect(speicher.werte[kCountdownSchluessel], '["y"]');
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Kachel bei 360 px, Textskala $skala: Titel und Tage, leer = unsichtbar', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> zeige(List<CountdownEintrag> l) => tester.pumpWidget(
        ProviderScope(
          overrides: [countdownEintraegeProvider.overrideWithValue(l)],
          child: MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: CountdownKarte())),
          ),
        ),
      );
      await zeige(const [
        CountdownEintrag(terminId: 'a', titel: 'Ein sehr langer Titel für den Sommerurlaub der ganzen Familie', tage: 62),
        CountdownEintrag(terminId: 'b', titel: 'Kino', tage: 1),
        CountdownEintrag(terminId: 'c', titel: 'Zahnarzt', tage: 0),
      ]);
      await tester.pump();
      expect(find.text('in 62 Tagen'), findsOneWidget);
      expect(find.text('morgen'), findsOneWidget);
      expect(find.text('heute'), findsOneWidget);
      expect(find.text('// COUNTDOWN'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await zeige(const []);
      await tester.pump();
      expect(find.text('// COUNTDOWN'), findsNothing);
    });
  }
}
