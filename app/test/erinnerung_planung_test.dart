// Terminerinnerungen, reine Planungslogik (ohne Plugin): Serien, Sommerzeit, Ausnahmen, Absagen, ganztägig, Fenstergröße, Vergangenes,
// Betroffene Person, Inhalt/Payload, stabile IDs, Änderung und Löschen.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const ich = 'u-ich';

/// "Jetzt" der Tests: Montag 19.10.2026 12:00 Uhr Berlin (Sommerzeit, UTC+2), die Umstellung auf Winterzeit ist am 25.10.2026.
final jetzt = DateTime.utc(2026, 10, 19, 10);

Termin termin({
  String id = 't1',
  String titel = 'Zahnarzt',
  String ort = '',
  bool ganztaegig = false,
  String? startUtc,
  String? endUtc,
  String? startDate,
  String? endDate,
  String? rrule,
  int? erinnerungMin = 15,
  String? ownerId = ich,
}) => Termin(
  id: id,
  titel: titel,
  ort: ort,
  beschreibung: '',
  ganztaegig: ganztaegig,
  startUtc: startUtc == null ? null : DateTime.parse(startUtc),
  endUtc: endUtc == null ? null : DateTime.parse(endUtc),
  tzid: ganztaegig ? null : 'Europe/Berlin',
  startDate: startDate,
  endDate: endDate,
  rrule: rrule,
  erinnerungMin: erinnerungMin,
  icalUid: null,
  audience: 'family',
  ownerId: ownerId,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

TerminAusnahme ausnahme(String terminId, String original, {bool abgesagt = false, String? titel, String? start, String? ende}) =>
    TerminAusnahme(id: 'a-$original', terminId: terminId, originalStart: original, abgesagt: abgesagt, titel: titel, start: start, ende: ende, ort: null, rev: 1);

KalenderDaten daten(List<Termin> termine, {List<TerminAusnahme> ausnahmen = const [], Map<String, List<String>> teilnehmer = const {}}) {
  final a = <String, List<TerminAusnahme>>{};
  for (final x in ausnahmen) {
    a.putIfAbsent(x.terminId, () => []).add(x);
  }
  return KalenderDaten(
    termine: termine,
    ausnahmen: a,
    teilnehmer: {
      for (final e in teilnehmer.entries) e.key: [for (final u in e.value) TerminTeilnehmerZeile(id: '${e.key}-$u', terminId: e.key, userId: u, rev: 1)],
    },
  );
}

List<GeplanteErinnerung> plane(KalenderDaten d, {DateTime? zeit, int max = kErinnerungFenster, String? person = ich}) =>
    planeErinnerungen(daten: d, ich: person, jetzt: zeit ?? jetzt, maxAnzahl: max);

void main() {
  tzdata.initializeTimeZones();

  group('Einzeltermine', () {
    test('Zeittermin: Beginn minus Vorlaufzeit, Inhalt mit Zeit und Ort', () {
      // Dienstag 20.10. 14:30 Uhr Berlin = 12:30 UTC, 15 Minuten vorher
      final r = plane(daten([termin(startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z', ort: 'Praxis Dr. Meyer')]));
      expect(r, hasLength(1));
      expect(r.single.zeit, DateTime.utc(2026, 10, 20, 12, 15));
      expect(r.single.titel, 'Zahnarzt');
      expect(r.single.text, 'Heute, 14:30 · Praxis Dr. Meyer');
      expect(r.single.payload, 'termin|t1|2026-10-20');
    });

    test('Text sagt "Morgen" bzw. nennt Wochentag und Datum, wenn die Erinnerung früher kommt', () {
      final morgen = plane(daten([termin(startUtc: '2026-10-21T08:00:00Z', endUtc: '2026-10-21T09:00:00Z', erinnerungMin: 1440)]));
      expect(morgen.single.text, 'Morgen, 10:00');
      final woche = plane(daten([termin(startUtc: '2026-10-29T08:00:00Z', endUtc: '2026-10-29T09:00:00Z', erinnerungMin: 10080)]));
      expect(woche.single.zeit, DateTime.utc(2026, 10, 22, 8)); // 29.10. 09:00 Berlin (Winterzeit) = 08:00 UTC; eine Woche = 168 Stunden, absolut
      expect(woche.single.text, 'Do, 29. Okt, 09:00');
    });

    test('alle Auswahlwerte des Editors werden geplant (inkl. 0 = zur Startzeit)', () {
      for (final m in [0, 5, 15, 30, 60, 1440, 10080]) {
        final r = plane(daten([termin(startUtc: '2026-11-20T08:00:00Z', endUtc: '2026-11-20T09:00:00Z', erinnerungMin: m)]));
        expect(r, hasLength(1), reason: '$m Minuten');
        expect(r.single.zeit, DateTime.utc(2026, 11, 20, 8).subtract(Duration(minutes: m)));
      }
    });

    test('keine Erinnerung (null) und negative Werte planen nichts', () {
      expect(plane(daten([termin(startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z', erinnerungMin: null)])), isEmpty);
      expect(plane(daten([termin(startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z', erinnerungMin: -5)])), isEmpty);
    });

    test('Vergangenes wird übersprungen, auch wenn der Termin selbst noch bevorsteht', () {
      // Beginn in 10 Minuten, aber 15 Minuten Vorlauf: Zeitpunkt der Erinnerung liegt schon hinter uns
      expect(plane(daten([termin(startUtc: '2026-10-19T10:10:00Z', endUtc: '2026-10-19T11:00:00Z')])), isEmpty);
      // gestern
      expect(plane(daten([termin(startUtc: '2026-10-18T10:10:00Z', endUtc: '2026-10-18T11:00:00Z')])), isEmpty);
      // knapp danach: 20 Minuten bis zum Beginn, 15 Minuten Vorlauf
      expect(plane(daten([termin(startUtc: '2026-10-19T10:20:00Z', endUtc: '2026-10-19T11:00:00Z')])), hasLength(1));
    });

    test('ohne Person (nicht angemeldet) gibt es nichts', () {
      expect(plane(daten([termin(startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z')]), person: null), isEmpty);
    });
  });

  group('Betroffene Person', () {
    final fremd = termin(ownerId: 'u-anderer', startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z');

    test('fremder Termin ohne mich als Teilnehmer: keine Erinnerung', () {
      expect(plane(daten([fremd])), isEmpty);
      expect(plane(daten([fremd], teilnehmer: {'t1': ['u-dritter']})), isEmpty);
    });

    test('als Teilnehmer: Erinnerung', () {
      expect(plane(daten([fremd], teilnehmer: {'t1': ['u-dritter', ich]})), hasLength(1));
    });

    test('eigener Termin: Erinnerung, auch mit anderen Teilnehmern', () {
      expect(plane(daten([termin(startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z')], teilnehmer: {'t1': ['u-dritter']})), hasLength(1));
    });
  });

  group('Serien', () {
    // Dienstags 10:00 Uhr Berlin: 20.10. (Sommerzeit, 08:00 UTC), danach Winterzeit (10:00 = 09:00 UTC)
    final serie = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=WEEKLY;BYDAY=TU', erinnerungMin: 60);

    test('jedes Vorkommen erinnert in der Wanduhrzeit; über die Zeitumstellung bleibt es 10 Uhr', () {
      final r = plane(daten([serie]), max: 3);
      expect(r.map((e) => e.zeit).toList(), [
        DateTime.utc(2026, 10, 20, 7), // 09:00 Berlin (CEST)
        DateTime.utc(2026, 10, 27, 8), // 09:00 Berlin (CET)
        DateTime.utc(2026, 11, 3, 8),
      ]);
      expect(r.map((e) => e.text).toSet(), {'Heute, 10:00'});
    });

    test('Vorkommen haben verschiedene IDs, dieselbe Planung ergibt dieselben IDs', () {
      final a = plane(daten([serie]), max: 5);
      final b = plane(daten([serie]), max: 5);
      expect(a.map((e) => e.id).toSet(), hasLength(5));
      expect(a.map((e) => e.id).toList(), b.map((e) => e.id).toList());
      expect(a.every((e) => e.id >= kErinnerungIdMin && e.id <= 0x7fffffff), isTrue);
    });

    test('abgesagtes Vorkommen erscheint nicht', () {
      final r = plane(daten([serie], ausnahmen: [ausnahme('t1', '2026-10-27T09:00:00Z', abgesagt: true)]), max: 3);
      expect(r.map((e) => e.zeit).toList(), [DateTime.utc(2026, 10, 20, 7), DateTime.utc(2026, 11, 3, 8), DateTime.utc(2026, 11, 10, 8)]);
    });

    test('verschobenes Vorkommen erinnert zur neuen Zeit, mit geändertem Titel', () {
      final r = plane(
        daten([serie], ausnahmen: [ausnahme('t1', '2026-10-27T09:00:00Z', start: '2026-10-27T13:00:00Z', ende: '2026-10-27T14:00:00Z', titel: 'Zahnarzt (später)')]),
        max: 2,
      );
      expect(r[1].zeit, DateTime.utc(2026, 10, 27, 12));
      expect(r[1].titel, 'Zahnarzt (später)');
      expect(r[1].text, 'Heute, 14:00');
    });

    test('Serie mit COUNT endet, UNTIL begrenzt', () {
      final c = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY;COUNT=3', erinnerungMin: 0);
      expect(plane(daten([c])), hasLength(3));
      final u = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY;UNTIL=20261022T235959Z', erinnerungMin: 0);
      expect(plane(daten([u])), hasLength(3));
    });

    test('jährliche Serie (Geburtstag) wird im Horizont gefunden', () {
      final g = termin(ganztaegig: true, startDate: '2020-06-12', endDate: '2020-06-13', rrule: 'FREQ=YEARLY', erinnerungMin: 1440);
      final r = plane(daten([g]));
      expect(r, hasLength(1));
      expect(r.single.zeit, DateTime.utc(2027, 6, 11, 7)); // 1 Tag vor dem 12.6.2027, 09:00 Berlin (CEST)
    });
  });

  group('Ganztägige Termine', () {
    test('Zur Startzeit = 09:00 Uhr am Tag; 1 Tag vorher = 09:00 Uhr am Vortag', () {
      final t0 = plane(daten([termin(ganztaegig: true, startDate: '2026-10-22', endDate: '2026-10-23', erinnerungMin: 0)]));
      expect(t0.single.zeit, DateTime.utc(2026, 10, 22, 7)); // 09:00 CEST
      expect(t0.single.text, 'Heute, ganztägig');
      final t1 = plane(daten([termin(ganztaegig: true, startDate: '2026-10-22', endDate: '2026-10-23', erinnerungMin: 1440)]));
      expect(t1.single.zeit, DateTime.utc(2026, 10, 21, 7));
      expect(t1.single.text, 'Morgen, ganztägig');
    });

    test('Winterzeit: 09:00 Uhr ist 08:00 UTC', () {
      final r = plane(daten([termin(ganztaegig: true, startDate: '2026-11-10', endDate: '2026-11-11', erinnerungMin: 0)]));
      expect(r.single.zeit, DateTime.utc(2026, 11, 10, 8));
    });

    test('mehrtägig: nur am ersten Tag; heute um 09:00 schon vorbei: übersprungen', () {
      final r = plane(daten([termin(ganztaegig: true, startDate: '2026-10-19', endDate: '2026-10-22', erinnerungMin: 0)])); // jetzt = 12:00
      expect(r, isEmpty);
      final morgen = plane(daten([termin(ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-23', erinnerungMin: 0)]));
      expect(morgen, hasLength(1));
    });

    test('wöchentliche ganztägige Serie über die Zeitumstellung bleibt 09:00 Uhr', () {
      final r = plane(daten([termin(ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-21', rrule: 'FREQ=WEEKLY', erinnerungMin: 0)]), max: 2);
      expect(r[0].zeit, DateTime.utc(2026, 10, 20, 7));
      expect(r[1].zeit, DateTime.utc(2026, 10, 27, 8));
    });
  });

  group('Fenster', () {
    final taeglich = termin(startUtc: '2026-10-20T08:00:00Z', endUtc: '2026-10-20T09:00:00Z', rrule: 'FREQ=DAILY', erinnerungMin: 15);

    test('höchstens kErinnerungFenster, zeitlich sortiert, beginnend mit der nächsten', () {
      final r = plane(daten([taeglich]));
      expect(r, hasLength(kErinnerungFenster));
      expect(r.first.zeit, DateTime.utc(2026, 10, 20, 7, 45));
      for (var i = 1; i < r.length; i++) {
        expect(r[i].zeit.isAfter(r[i - 1].zeit), isTrue);
      }
    });

    test('mehrere Termine: das Fenster zählt über alle zusammen', () {
      final zweiter = termin(id: 't2', titel: 'Training', startUtc: '2026-10-20T15:00:00Z', endUtc: '2026-10-20T16:00:00Z', rrule: 'FREQ=DAILY', erinnerungMin: 15);
      final r = plane(daten([taeglich, zweiter]), max: 10);
      expect(r, hasLength(10));
      expect(r.map((e) => e.titel).toSet(), {'Zahnarzt', 'Training'});
      expect(r.where((e) => e.titel == 'Zahnarzt'), hasLength(5));
    });

    test('maxAnzahl 0 plant nichts', () {
      expect(plane(daten([taeglich]), max: 0), isEmpty);
    });
  });

  group('Änderung und Löschen', () {
    test('Zeit geändert: neue Zeit, die alte ID fällt aus der Planung (wird beim Angleichen gelöscht); gelöscht oder Erinnerung entfernt: nicht mehr in der Planung', () {
      final alt = plane(daten([termin(startUtc: '2026-10-20T12:30:00Z', endUtc: '2026-10-20T13:30:00Z')]));
      final neu = plane(daten([termin(startUtc: '2026-10-20T14:30:00Z', endUtc: '2026-10-20T15:30:00Z')]));
      expect(neu.map((e) => e.id), isNot(contains(alt.single.id))); // Schlüssel des Vorkommens ist sein Beginn
      expect(neu.single.zeit, isNot(alt.single.zeit));
      expect(alt.single.gleich(neu.single), isFalse);
      expect(plane(daten(const [])), isEmpty);
      expect(plane(daten([termin(startUtc: '2026-10-20T14:30:00Z', endUtc: '2026-10-20T15:30:00Z', erinnerungMin: null)])), isEmpty);
    });
  });

  group('Payload', () {
    test('Rundlauf und Ablehnung falscher Formate', () {
      final p = erinnerungPayload('abc', DateTime.utc(2026, 10, 20));
      final g = erinnerungPayloadLesen(p)!;
      expect(g.terminId, 'abc');
      expect(g.tag, DateTime.utc(2026, 10, 20));
      for (final falsch in [null, '', 'x|y|z', 'termin||2026-10-20', 'termin|abc|20.10.2026', 'termin|abc', 'termin|a|2026-10-20|x']) {
        expect(erinnerungPayloadLesen(falsch), isNull, reason: '$falsch');
      }
    });
  });
}
