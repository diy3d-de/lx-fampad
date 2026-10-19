// Terminserien: Expansion mit rrule + timezone (Wanduhrzeit der Zeitzone, Sommerzeit), Ausnahmen, Deckel, ganztägige Termine, Regel-Bausteine.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/wiederholung.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Termin termin({
  String id = 't1',
  String titel = 'Training',
  bool ganztaegig = false,
  String? startUtc,
  String? endUtc,
  String? tzid = 'Europe/Berlin',
  String? startDate,
  String? endDate,
  String? rrule,
}) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: ganztaegig,
  startUtc: startUtc == null ? null : DateTime.parse(startUtc),
  endUtc: endUtc == null ? null : DateTime.parse(endUtc),
  tzid: ganztaegig ? null : tzid,
  startDate: startDate,
  endDate: endDate,
  rrule: rrule,
  erinnerungMin: null,
  icalUid: null,
  audience: 'family',
  ownerId: null,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

TerminAusnahme ausnahme(String terminId, String original, {bool abgesagt = false, String? titel, String? start, String? ende, String? ort}) => TerminAusnahme(
  id: 'a-$original',
  terminId: terminId,
  originalStart: original,
  abgesagt: abgesagt,
  titel: titel,
  start: start,
  ende: ende,
  ort: ort,
  rev: 1,
);

DateTime tag(int y, int m, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, m, d, h, mi);

List<Vorkommen> expandiere(Termin t, DateTime von, DateTime bis, {List<TerminAusnahme> ausnahmen = const [], DateTime? jetzt}) => vorkommenImFenster(
  termine: [t],
  ausnahmen: {t.id: ausnahmen},
  vonWand: von,
  bisWand: bis,
  jetzt: jetzt ?? DateTime.utc(2026, 10, 19),
);

void main() {
  tzdata.initializeTimeZones(); // vor den group-Rümpfen, die Zeitzonen schon beim Aufbau brauchen

  group('Zeitzonen-Umrechnung', () {
    test('Wanduhr <-> Zeitpunkt in Europe/Berlin (Sommer- und Winterzeit)', () {
      expect(wandUhr(DateTime.utc(2026, 7, 1, 8), familienOrt), tag(2026, 7, 1, 10));
      expect(wandUhr(DateTime.utc(2026, 12, 1, 8), familienOrt), tag(2026, 12, 1, 9));
      expect(instantAusWand(tag(2026, 7, 1, 10), familienOrt), DateTime.utc(2026, 7, 1, 8));
      expect(instantAusWand(tag(2026, 12, 1, 9), familienOrt), DateTime.utc(2026, 12, 1, 8));
    });

    test('unbekannte Zeitzone fällt auf die Familienzeitzone zurück', () {
      expect(ortFuer('Mars/Olympus').name, kFamilienZone);
      expect(ortFuer(null).name, kFamilienZone);
    });
  });

  group('einfache Termine', () {
    test('Zeittermin erscheint am richtigen Tag in der Familienzone (UTC-Zeit am Vorabend)', () {
      // 23:30 UTC am 20.10. = 01:30 Uhr am 21.10. in Berlin (Sommerzeit)
      final t = termin(startUtc: '2026-10-20T23:30:00Z', endUtc: '2026-10-21T00:30:00Z');
      final v = expandiere(t, tag(2026, 10, 21), tag(2026, 10, 22));
      expect(v, hasLength(1));
      expect(v.single.startWand, tag(2026, 10, 21, 1, 30));
      expect(v.single.ersterTag, tag(2026, 10, 21));
      expect(expandiere(t, tag(2026, 10, 20), tag(2026, 10, 21)), isEmpty);
    });

    test('mehrtägiger Termin erscheint an jedem Tag, ein Ende um 0 Uhr zählt nicht zum Folgetag', () {
      final t = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-22T08:00:00Z'); // 10 Uhr bis 10 Uhr (Berlin)
      final v = expandiere(t, tag(2026, 10, 1), tag(2026, 11, 1));
      final tage = nachTagen(v, tag(2026, 10, 1), tag(2026, 10, 31));
      expect(tage.keys.toList()..sort(), [tag(2026, 10, 20), tag(2026, 10, 21), tag(2026, 10, 22)]);
      final bis0 = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T22:00:00Z'); // endet 0 Uhr am 21.
      expect(nachTagen(expandiere(bis0, tag(2026, 10, 1), tag(2026, 11, 1)), tag(2026, 10, 1), tag(2026, 10, 31)).keys, [tag(2026, 10, 20)]);
    });

    test('ganztägig: Ende exklusiv', () {
      final t = termin(ganztaegig: true, startDate: '2026-12-24', endDate: '2026-12-27');
      final v = expandiere(t, tag(2026, 12, 1), tag(2027, 1, 1)).single;
      expect(v.letzterTag, tag(2026, 12, 26));
      expect(v.faelltAuf(tag(2026, 12, 27)), isFalse);
      expect(v.faelltAuf(tag(2026, 12, 24)), isTrue);
    });
  });

  group('Serien', () {
    test('wöchentlich bleibt über die Zeitumstellung zur gleichen Wanduhrzeit (Sommerzeit-Test)', () {
      // Dienstag 20.10.2026 10:00 Berlin (CEST) = 08:00 UTC; Umstellung am 25.10.2026
      final t = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=WEEKLY;BYDAY=TU');
      final v = expandiere(t, tag(2026, 10, 1), tag(2026, 11, 20));
      expect(v.map((e) => e.startWand).toList(), [
        tag(2026, 10, 20, 10),
        tag(2026, 10, 27, 10),
        tag(2026, 11, 3, 10),
        tag(2026, 11, 10, 10),
        tag(2026, 11, 17, 10),
      ]);
      expect(v[0].startUtc, DateTime.utc(2026, 10, 20, 8));
      expect(v[1].startUtc, DateTime.utc(2026, 10, 27, 9)); // nach der Umstellung: 10 Uhr Berlin = 09:00 UTC
      expect(v[1].endeWand, tag(2026, 10, 27, 11));
      expect(v[1].schluessel, '2026-10-27T09:00:00Z');
    });

    test('Frühling: Serie über den Beginn der Sommerzeit (29.3.2026)', () {
      final t = termin(startUtc: '2026-03-24T09:00:00Z', endUtc: '2026-03-24T10:00:00Z', rrule: 'FREQ=WEEKLY'); // 10 Uhr CET
      final v = expandiere(t, tag(2026, 3, 20), tag(2026, 4, 20), jetzt: DateTime.utc(2026, 3, 1));
      expect(v.map((e) => e.startWand.hour).toSet(), {10});
      expect(v.map((e) => e.startUtc.hour).toList(), [9, 8, 8, 8]);
    });

    test('Termin zu einer Uhrzeit, die es bei der Umstellung nicht gibt (02:30 am 29.3.2026), rutscht nach vorn', () {
      final t = termin(startUtc: '2026-03-28T01:30:00Z', endUtc: '2026-03-28T02:30:00Z', rrule: 'FREQ=DAILY;COUNT=3'); // 02:30 CET
      final v = expandiere(t, tag(2026, 3, 27), tag(2026, 4, 2), jetzt: DateTime.utc(2026, 3, 1));
      expect(v, hasLength(3));
      expect(v[1].startWand, tag(2026, 3, 29, 3, 30)); // 02:30 gibt es nicht
      expect(v[2].startWand, tag(2026, 3, 30, 2, 30));
    });

    test('Zeitzone des Termins gilt: New York bleibt 9 Uhr Ortszeit, in Berlin verschiebt sich die Anzeige', () {
      // 9 Uhr in New York, EDT = 13:00 UTC; Berlin ist bis 25.10. bei +2 (15 Uhr), New York stellt erst am 1.11. um
      final t = termin(tzid: 'America/New_York', startUtc: '2026-10-20T13:00:00Z', endUtc: '2026-10-20T14:00:00Z', rrule: 'FREQ=WEEKLY;BYDAY=TU');
      final v = expandiere(t, tag(2026, 10, 15), tag(2026, 11, 12));
      expect(v.map((e) => e.startUtc.hour).toList(), [13, 13, 14, 14]); // 3.11. EST: 9 Uhr = 14:00 UTC
      expect(v.map((e) => e.startWand.hour).toList(), [15, 14, 15, 15]); // Berlin: 27.10. CET (14), 3.11. CET (15)
    });

    test('monatlich am letzten Freitag, jährlich, täglich mit Intervall', () {
      final monat = termin(startUtc: '2026-10-30T16:00:00Z', endUtc: '2026-10-30T17:00:00Z', rrule: 'FREQ=MONTHLY;BYDAY=-1FR');
      expect(expandiere(monat, tag(2026, 10, 1), tag(2027, 2, 1)).map((e) => e.startWand.day).toList(), [30, 27, 25, 29]);
      final jahr = termin(ganztaegig: true, startDate: '2026-12-24', endDate: '2026-12-25', rrule: 'FREQ=YEARLY');
      expect(expandiere(jahr, tag(2026, 1, 1), tag(2029, 1, 1)).map((e) => e.startWand.year).toList(), [2026, 2027, 2028]);
      final alle3 = termin(ganztaegig: true, startDate: '2026-10-01', endDate: '2026-10-02', rrule: 'FREQ=DAILY;INTERVAL=3');
      expect(expandiere(alle3, tag(2026, 10, 1), tag(2026, 10, 12)).map((e) => e.startWand.day).toList(), [1, 4, 7, 10]);
    });

    test('COUNT und UNTIL (UTC bei Zeitterminen, Datum bei ganztägigen) begrenzen die Serie', () {
      final count = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY;COUNT=3');
      expect(expandiere(count, tag(2026, 10, 1), tag(2027, 1, 1)), hasLength(3));
      // UNTIL 22.10. 08:00 UTC = 10:00 Berlin: das Vorkommen am 22.10. um 10:00 zählt noch
      final bis = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY;UNTIL=20261022T080000Z');
      expect(expandiere(bis, tag(2026, 10, 1), tag(2027, 1, 1)).map((e) => e.startWand.day).toList(), [20, 21, 22]);
      final bisTag = termin(ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-21', rrule: 'FREQ=DAILY;UNTIL=20261022');
      expect(expandiere(bisTag, tag(2026, 10, 1), tag(2027, 1, 1)), hasLength(3));
      final bisTagZeit = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY;UNTIL=20261022');
      expect(expandiere(bisTagZeit, tag(2026, 10, 1), tag(2027, 1, 1)), hasLength(3));
    });

    test('Deckel: höchstens 1000 Vorkommen und Horizont 5 Jahre; kaputte Regeln werden zum Einzeltermin', () {
      final t = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY');
      // 20 Jahre abfragen: Horizont 5 Jahre ab "heute" (19.10.2026) begrenzt, Deckel 1000 greift davor nicht (5 Jahre = rund 1826 Tage -> 1000)
      final v = expandiere(t, tag(2026, 1, 1), tag(2046, 1, 1));
      expect(v.length, kMaxVorkommen);
      // Horizont: Fenster hinter dem Horizont ergibt nichts
      expect(expandiere(t, tag(2032, 1, 1), tag(2033, 1, 1)), isEmpty);
      final kaputt = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=SECONDLY');
      expect(expandiere(kaputt, tag(2026, 10, 1), tag(2026, 11, 1)), hasLength(1));
      final muell = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'quatsch');
      expect(expandiere(muell, tag(2026, 10, 1), tag(2026, 11, 1)), hasLength(1));
    });

    test('Rechenlast: unerfüllbare Regel, sehr alte Serie und wiederholte Abfragen bleiben schnell und liefern das Richtige', () {
      final sw = Stopwatch()..start();
      // 30. Februar gibt es nie (der Server lehnt die Regel ab; aus anderen Quellen könnte sie kommen)
      final nie = termin(ganztaegig: true, startDate: '2026-02-01', endDate: '2026-02-02', rrule: 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30');
      expect(expandiere(nie, tag(2026, 1, 1), tag(2031, 1, 1)).length, lessThanOrEqualTo(1));
      // tägliche Serie seit 2002: das Fenster liegt 24 Jahre hinter dem Beginn
      final alt = termin(ganztaegig: true, startDate: '2002-01-01', endDate: '2002-01-02', rrule: 'FREQ=DAILY;INTERVAL=3');
      final v = expandiere(alt, tag(2026, 10, 19), tag(2026, 10, 26));
      // Tage seit 1.1.2002 teilbar durch 3
      for (final x in v) {
        expect(x.startWand.difference(DateTime.utc(2002, 1, 1)).inDays % 3, 0, reason: '${x.startWand}');
      }
      expect(v, isNotEmpty);
      // wöchentlich mit Wochentagen, 20 Jahre alt: die Wochentage stimmen
      final woche = termin(startUtc: '2006-10-17T08:00:00Z', endUtc: '2006-10-17T09:00:00Z', rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH');
      final w = expandiere(woche, tag(2026, 10, 19), tag(2026, 11, 20));
      expect(w.every((x) => x.startWand.weekday == DateTime.tuesday || x.startWand.weekday == DateTime.thursday), isTrue);
      expect(w.map((x) => x.startWand.hour).toSet(), {10});
      // gleiche Abfrage noch einmal (Zwischenspeicher) liefert dasselbe
      expect(expandiere(woche, tag(2026, 10, 19), tag(2026, 11, 20)).map((x) => x.startWand).toList(), w.map((x) => x.startWand).toList());
      expect(sw.elapsedMilliseconds, lessThan(10000));
    });

    test('Serie, die vor dem Fenster begann, liefert die Vorkommen im Fenster (alte Serie, Fenster weit hinten)', () {
      final t = termin(startUtc: '2024-01-02T09:00:00Z', endUtc: '2024-01-02T10:00:00Z', rrule: 'FREQ=WEEKLY;BYDAY=TU');
      final v = expandiere(t, tag(2026, 10, 19), tag(2026, 10, 26));
      expect(v, hasLength(1));
      expect(v.single.startWand, tag(2026, 10, 20, 10));
    });
  });

  group('Ausnahmen', () {
    final serie = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=WEEKLY;BYDAY=TU');

    test('abgesagt blendet das Vorkommen aus, die übrigen bleiben', () {
      final v = expandiere(serie, tag(2026, 10, 1), tag(2026, 11, 11), ausnahmen: [ausnahme('t1', '2026-10-27T09:00:00Z', abgesagt: true)]);
      expect(v.map((e) => e.startWand.day).toList(), [20, 3, 10]);
    });

    test('Überschreibung von Titel, Ort, Beginn: Dauer bleibt, Schlüssel bleibt der ursprüngliche', () {
      final v = expandiere(
        serie,
        tag(2026, 10, 1),
        tag(2026, 11, 10),
        ausnahmen: [ausnahme('t1', '2026-10-27T09:00:00Z', titel: 'Sondertraining', ort: 'Halle', start: '2026-10-28T15:00:00Z')],
      );
      final ge = v.singleWhere((e) => e.geaendert);
      expect(ge.titel, 'Sondertraining');
      expect(ge.ort, 'Halle');
      expect(ge.startUtc, DateTime.utc(2026, 10, 28, 15));
      expect(ge.startWand, tag(2026, 10, 28, 16)); // CET
      expect(ge.endeWand, tag(2026, 10, 28, 17)); // Dauer 1 Stunde bleibt
      expect(ge.schluessel, '2026-10-27T09:00:00Z');
    });

    test('ganztägige Serie: Ausnahme verschiebt auf einen anderen Tag', () {
      final t = termin(ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-21', rrule: 'FREQ=WEEKLY');
      final v = expandiere(t, tag(2026, 10, 1), tag(2026, 11, 11), ausnahmen: [ausnahme('t1', '2026-10-27', start: '2026-10-29')]);
      expect(v.map((e) => e.startWand.day).toList(), [20, 29, 3, 10]);
      expect(v[1].endeWand, tag(2026, 10, 30));
    });

    test('Ausnahme mit leeren Überschreibungen ändert nichts (zurückgesetzt)', () {
      final v = expandiere(serie, tag(2026, 10, 20), tag(2026, 10, 30), ausnahmen: [ausnahme('t1', '2026-10-27T09:00:00Z')]);
      expect(v, hasLength(2));
      expect(v.any((e) => e.geaendert), isFalse);
    });
  });

  group('Wiederholung (Oberfläche <-> RRULE)', () {
    final berlin = ortFuer(kFamilienZone);
    String? regel(Wiederholung w, {DateTime? start, bool ganztaegig = false}) => w.zuRrule(startTag: start ?? tag(2026, 10, 20), ganztaegig: ganztaegig, ort: berlin);

    test('Bausteine', () {
      expect(regel(Wiederholung.keine), isNull);
      expect(regel(const Wiederholung(art: WdhArt.taeglich)), 'FREQ=DAILY');
      expect(regel(const Wiederholung(art: WdhArt.woechentlich, intervall: 2, wochentage: {3, 1})), 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE');
      expect(regel(const Wiederholung(art: WdhArt.woechentlich)), 'FREQ=WEEKLY;BYDAY=TU'); // Wochentag des Beginns
      expect(regel(const Wiederholung(art: WdhArt.monatlich)), 'FREQ=MONTHLY;BYMONTHDAY=20');
      expect(regel(const Wiederholung(art: WdhArt.monatlich, modus: MonatsModus.wochentag)), 'FREQ=MONTHLY;BYDAY=3TU');
      expect(regel(const Wiederholung(art: WdhArt.monatlich, modus: MonatsModus.wochentag), start: tag(2026, 10, 29)), 'FREQ=MONTHLY;BYDAY=-1TH');
      expect(regel(const Wiederholung(art: WdhArt.jaehrlich, ende: WdhEnde.anzahl, anzahl: 5)), 'FREQ=YEARLY;COUNT=5');
      expect(regel(Wiederholung(art: WdhArt.taeglich, ende: WdhEnde.bis, bis: tag(2026, 12, 31))), 'FREQ=DAILY;UNTIL=20261231T225959Z'); // 23:59:59 CET
      expect(regel(Wiederholung(art: WdhArt.taeglich, ende: WdhEnde.bis, bis: tag(2026, 7, 31))), 'FREQ=DAILY;UNTIL=20260731T215959Z'); // CEST
      expect(regel(Wiederholung(art: WdhArt.taeglich, ende: WdhEnde.bis, bis: tag(2026, 12, 31)), ganztaegig: true), 'FREQ=DAILY;UNTIL=20261231');
    });

    test('Hin und zurück', () {
      for (final (r, start) in [
        ('FREQ=DAILY', tag(2026, 10, 20)),
        ('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE', tag(2026, 10, 20)),
        ('FREQ=MONTHLY;BYMONTHDAY=20;COUNT=12', tag(2026, 10, 20)),
        ('FREQ=MONTHLY;BYDAY=-1TH', tag(2026, 10, 29)),
        ('FREQ=YEARLY;UNTIL=20301231T225959Z', tag(2026, 10, 20)),
      ]) {
        final w = Wiederholung.ausRrule(r, ganztaegig: false, ort: berlin);
        expect(w.eigeneRegel, isNull, reason: r);
        expect(w.zuRrule(startTag: start, ganztaegig: false, ort: berlin), r);
      }
    });

    test('Fremde Regeln bleiben unverändert erhalten', () {
      for (final r in ['FREQ=MONTHLY;BYDAY=MO;BYSETPOS=-1', 'FREQ=YEARLY;BYMONTH=12;BYMONTHDAY=24', 'FREQ=WEEKLY;WKST=MO', 'quatsch']) {
        final w = Wiederholung.ausRrule(r, ganztaegig: false, ort: berlin);
        expect(w.eigeneRegel, r);
        expect(w.zuRrule(startTag: tag(2026, 10, 20), ganztaegig: false, ort: berlin), r);
        expect(w.wiederholt, isTrue);
      }
    });

    test('Regel-Rundlauf: negative Monatstage, Listen und nicht zum Beginn passende Monatsregeln bleiben eigene Regeln', () {
      for (final (r, start) in [
        ('FREQ=MONTHLY;BYDAY=-1MO', tag(2026, 10, 20)), // Beginn ist ein Dienstag: nicht abbildbar
        ('FREQ=MONTHLY;BYDAY=2MO', tag(2026, 10, 20)),
        ('FREQ=MONTHLY;BYMONTHDAY=-1', tag(2026, 10, 31)),
        ('FREQ=MONTHLY;BYMONTHDAY=15', tag(2026, 10, 20)),
        ('FREQ=MONTHLY;BYMONTHDAY=1,15', tag(2026, 10, 1)),
      ]) {
        final w = Wiederholung.ausRrule(r, ganztaegig: false, ort: ortFuer(kFamilienZone), startTag: start);
        expect(w.eigeneRegel, r, reason: r);
        expect(w.zuRrule(startTag: start, ganztaegig: false, ort: ortFuer(kFamilienZone)), r, reason: 'unverändert gespeichert');
      }
      // passende bleiben abbildbar
      for (final (r, start) in [('FREQ=MONTHLY;BYDAY=-1TH', tag(2026, 10, 29)), ('FREQ=MONTHLY;BYDAY=3TU', tag(2026, 10, 20)), ('FREQ=MONTHLY;BYMONTHDAY=20', tag(2026, 10, 20))]) {
        expect(Wiederholung.ausRrule(r, ganztaegig: false, ort: ortFuer(kFamilienZone), startTag: start).eigeneRegel, isNull, reason: r);
      }
    });

    test('Wochentage wandern mit dem Beginn (F1); leere Auswahl, andere Arten und eigene Regeln bleiben', () {
      const w = Wiederholung(art: WdhArt.woechentlich, wochentage: {2, 4}); // Di, Do
      expect(w.wochentageNachStart(tag(2026, 10, 20), tag(2026, 10, 21)).wochentage, {3, 4}); // Beginn Di -> Mi
      expect(w.wochentageNachStart(tag(2026, 10, 20), tag(2026, 10, 22)).wochentage, {4}); // Di -> Do: Do war schon dabei
      expect(w.wochentageNachStart(tag(2026, 10, 20), tag(2026, 10, 27)).wochentage, {2, 4}); // gleicher Wochentag
      expect(w.wochentageNachStart(tag(2026, 10, 19), tag(2026, 10, 21)).wochentage, {2, 3, 4}); // Mo war nicht dabei: neuer kommt hinzu
      expect(const Wiederholung(art: WdhArt.woechentlich).wochentageNachStart(tag(2026, 10, 20), tag(2026, 10, 21)).wochentage, isEmpty);
      expect(const Wiederholung(art: WdhArt.taeglich).wochentageNachStart(tag(2026, 10, 20), tag(2026, 10, 21)).wochentage, isEmpty);
    });

    test('Serie kürzen: UNTIL eine Sekunde vor dem Vorkommen, COUNT entfällt', () {
      expect(
        regelBis('FREQ=WEEKLY;BYDAY=TU;COUNT=10', ganztaegig: false, startUtc: DateTime.utc(2026, 10, 27, 9), tag: tag(2026, 10, 27)),
        'FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T085959Z',
      );
      expect(regelBis('FREQ=DAILY;UNTIL=20301231', ganztaegig: true, startUtc: DateTime.utc(2026, 10, 27), tag: tag(2026, 10, 27)), 'FREQ=DAILY;UNTIL=20261026');
      expect(regelAnzahl('FREQ=DAILY;COUNT=7'), 7);
      expect(regelMitAnzahl('FREQ=DAILY;COUNT=7', 3), 'FREQ=DAILY;COUNT=3');
    });

    test('Beschreibung', () {
      expect(const Wiederholung(art: WdhArt.woechentlich, intervall: 2, wochentage: {1, 3}).beschreibung(), 'Alle 2 Wochen (Mo, Mi)');
      expect(const Wiederholung(art: WdhArt.taeglich, ende: WdhEnde.anzahl, anzahl: 4).beschreibung(), 'Täglich, 4-mal');
      expect(Wiederholung.keine.beschreibung(), 'Einmalig');
    });

    test('Schlüssel eines Zeitpunkts passt zum Server (ohne Millisekunden)', () {
      expect(zeitSchluessel(DateTime.utc(2026, 10, 27, 9)), '2026-10-27T09:00:00Z');
      expect(tagText(tag(2026, 3, 5)), '2026-03-05');
    });
  });
}
