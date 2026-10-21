// ICS-Export: Serialisierung (Escaping, Faltung, Ganztag, Serie, Ausnahmen, Sommerzeit, Umlaute), Round-Trip mit dem Import-Parser und die Seite
// (Zeitraum, Anzahl, Speichern; 360 px, Textskala 1.0 und 1.5).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/ics_export.dart';
import 'package:lx_fampad/data/calendar/ics_parser.dart';
import 'package:lx_fampad/data/calendar/ics_speichern.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/harness.dart';

final _jetzt = DateTime.utc(2026, 10, 21, 8, 30);

Termin _t({
  String id = 'a1',
  String titel = 'Test',
  String ort = '',
  String beschreibung = '',
  bool ganz = false,
  DateTime? start,
  DateTime? ende,
  String? tzid = 'Europe/Berlin',
  String? startDate,
  String? endDate,
  String? rrule,
  int? erinnerung,
  String? uid,
}) => Termin(
  id: id,
  titel: titel,
  ort: ort,
  beschreibung: beschreibung,
  ganztaegig: ganz,
  startUtc: start,
  endUtc: ende,
  tzid: ganz ? null : tzid,
  startDate: startDate,
  endDate: endDate,
  rrule: rrule,
  erinnerungMin: erinnerung,
  icalUid: uid,
  audience: 'family',
  ownerId: 'user-1',
  createdAt: DateTime.utc(2026, 1, 1),
  rev: 1,
);

TerminAusnahme _a(String terminId, String key, {bool abgesagt = false, String? titel, String? start, String? ende, String? ort}) => TerminAusnahme(
  id: 'x-$key',
  terminId: terminId,
  originalStart: key,
  abgesagt: abgesagt,
  titel: titel,
  start: start,
  ende: ende,
  ort: ort,
  rev: 1,
);

String _export(List<Termin> t, [Map<String, List<TerminAusnahme>> a = const {}]) => icsErstellen(termine: t, ausnahmen: a, jetzt: _jetzt);
IcsErgebnis _zurueck(String text) => icsLesen(Uint8List.fromList(utf8.encode(text)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  group('Serialisierung', () {
    test('Rahmen: CRLF, PRODID, VTIMEZONE Europe/Berlin mit Sommerzeitregeln, DTSTAMP', () {
      final s = _export([_t(start: DateTime.utc(2026, 7, 1, 8), ende: DateTime.utc(2026, 7, 1, 9))]);
      expect(s, startsWith('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:$kIcsProdId\r\n'));
      expect(s, endsWith('END:VCALENDAR\r\n'));
      expect(s.replaceAll('\r\n', '').contains('\n'), isFalse);
      expect(
        s,
        contains(
          'TZID:Europe/Berlin\r\nBEGIN:DAYLIGHT\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nTZNAME:CEST\r\nDTSTART:19700329T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU',
        ),
      );
      expect(
        s,
        contains(
          'BEGIN:STANDARD\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nTZNAME:CET\r\nDTSTART:19701025T030000\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU',
        ),
      );
      expect(s, contains('DTSTAMP:20261021T083000Z'));
      expect(s, contains('DTSTART;TZID=Europe/Berlin:20260701T100000')); // Sommer: UTC+2
      expect(s, contains('DTEND;TZID=Europe/Berlin:20260701T110000'));
    });

    test('Winter- und Sommerzeit: dieselbe Wanduhr, anderer UTC-Zeitpunkt', () {
      final s = _export([
        _t(id: 'w', start: DateTime.utc(2026, 1, 15, 9), ende: DateTime.utc(2026, 1, 15, 10)),
        _t(id: 's', start: DateTime.utc(2026, 7, 15, 8), ende: DateTime.utc(2026, 7, 15, 9)),
      ]);
      expect('DTSTART;TZID=Europe/Berlin:20260115T100000'.allMatches(s), hasLength(1));
      expect('DTSTART;TZID=Europe/Berlin:20260715T100000'.allMatches(s), hasLength(1));
    });

    test('ohne Zeittermine kein VTIMEZONE; UID aus icalUid oder stabil aus der ID', () {
      final s = _export([
        _t(id: 'g1', ganz: true, startDate: '2026-12-24', endDate: '2026-12-25'),
        _t(id: 'g2', ganz: true, startDate: '2026-12-24', endDate: '2026-12-25', uid: 'abc@x.de'),
      ]);
      expect(s, isNot(contains('VTIMEZONE')));
      expect(s, contains('UID:g1@$kIcsUidDomain'));
      expect(s, contains('UID:abc@x.de'));
    });

    test('Ganztag: VALUE=DATE, Ende exklusiv; mehrtägig', () {
      final s = _export([_t(ganz: true, startDate: '2026-12-30', endDate: '2027-01-02')]);
      expect(s, contains('DTSTART;VALUE=DATE:20261230'));
      expect(s, contains('DTEND;VALUE=DATE:20270102'));
    });

    test('Escaping: Komma, Semikolon, Backslash, Zeilenumbruch', () {
      expect(icsMaskieren('a,b;c\\d\r\ne\nf'), r'a\,b\;c\\d\ne\nf');
      final s = _export([_t(titel: 'Eltern, Kinder; Oma', ort: 'Haus\\Hof', beschreibung: 'Zeile 1\nZeile 2', start: DateTime.utc(2026, 7, 1, 8))]);
      expect(s, contains(r'SUMMARY:Eltern\, Kinder\; Oma'));
      expect(s, contains(r'LOCATION:Haus\\Hof'));
      expect(s, contains(r'DESCRIPTION:Zeile 1\nZeile 2'));
    });

    test('Faltung: höchstens 75 Oktette je Zeile, UTF-8-Zeichen nie geteilt, Entfaltung ergibt die Zeile', () {
      final lang = 'Müller-Lüdenscheidt-Überraschungsfeier mit Äpfeln, Öl und 🎂🎂🎂 ' * 4;
      final s = _export([_t(titel: lang, start: DateTime.utc(2026, 7, 1, 8))]);
      for (final z in s.split('\r\n')) {
        expect(utf8.encode(z).length, lessThanOrEqualTo(75), reason: z);
      }
      expect(s.contains('\r\n '), isTrue);
      final entfaltet = s.replaceAll('\r\n ', '');
      expect(entfaltet, contains('SUMMARY:${icsMaskieren(lang)}'));
      expect(utf8.encode(icsFalten('X' * 200).split('\r\n').first).length, 75);
      // 4-Byte-Zeichen an der Kante: keine halbe Emoji-Folge
      final f = icsFalten('${'a' * 73}🎂');
      expect(f.split('\r\n').first, 'a' * 73);
      expect(icsBytes(s), isNotEmpty);
    });

    test('Serie: RRULE, EXDATE (abgesagt) und geändertes Vorkommen als eigenes VEVENT mit RECURRENCE-ID', () {
      final master = _t(
        id: 's1',
        titel: 'Turnen',
        ort: 'Halle',
        start: DateTime.utc(2026, 11, 3, 16),
        ende: DateTime.utc(2026, 11, 3, 17),
        rrule: 'FREQ=WEEKLY;BYDAY=TU',
        erinnerung: 15,
      );
      final s = _export(
        [master],
        {
          's1': [
            _a('s1', '2026-11-10T16:00:00Z', abgesagt: true),
            _a('s1', '2026-11-17T16:00:00Z', titel: 'Turnen (Fest)', start: '2026-11-17T17:00:00Z', ende: '2026-11-17T18:00:00Z'),
          ],
        },
      );
      expect(s, contains('RRULE:FREQ=WEEKLY;BYDAY=TU'));
      expect(s, contains('EXDATE;TZID=Europe/Berlin:20261110T170000'));
      expect(s, contains('RECURRENCE-ID;TZID=Europe/Berlin:20261117T170000'));
      expect(s, contains('DTSTART;TZID=Europe/Berlin:20261117T180000'));
      expect('BEGIN:VEVENT'.allMatches(s), hasLength(2));
      expect('UID:s1@$kIcsUidDomain'.allMatches(s), hasLength(2));
      expect(s, contains('BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Turnen\r\nTRIGGER:-PT15M\r\nEND:VALARM'));
    });

    test('Erinnerung 0 Minuten: TRIGGER:PT0S', () {
      expect(_export([_t(start: DateTime.utc(2026, 7, 1, 8), erinnerung: 0)]), contains('TRIGGER:PT0S'));
    });

    test('andere Zeitzone (New York): eigenes VTIMEZONE aus den Übergängen, Wanduhr in der Zone', () {
      final s = _export([_t(tzid: 'America/New_York', start: DateTime.utc(2026, 7, 1, 16), ende: DateTime.utc(2026, 7, 1, 17))]);
      expect(s, contains('TZID:America/New_York'));
      expect(s, contains('TZNAME:EDT'));
      expect(s, contains('TZOFFSETTO:-0400'));
      expect(s, contains('DTSTART;TZID=America/New_York:20260701T120000'));
    });
  });

  group('Zeitraum', () {
    final alt = _t(id: 'alt', start: DateTime.utc(2020, 5, 5, 8), ende: DateTime.utc(2020, 5, 5, 9));
    final neu = _t(id: 'neu', start: DateTime.utc(2026, 12, 5, 8), ende: DateTime.utc(2026, 12, 5, 9));
    final serie = _t(id: 'serie', start: DateTime.utc(2020, 1, 7, 8), ende: DateTime.utc(2020, 1, 7, 9), rrule: 'FREQ=WEEKLY');
    final beendet = _t(id: 'beendet', start: DateTime.utc(2020, 1, 7, 8), ende: DateTime.utc(2020, 1, 7, 9), rrule: 'FREQ=WEEKLY;COUNT=3');
    final alle = [alt, neu, serie, beendet];
    List<String> ids(IcsZeitraum z, {int? jahr}) =>
        termineFuerExport(termine: alle, ausnahmen: const {}, zeitraum: z, jahr: jahr, jetzt: _jetzt).map((t) => t.id).toList();

    test('alles, ab heute, Jahr', () {
      expect(ids(IcsZeitraum.alles), ['alt', 'neu', 'serie', 'beendet']);
      expect(ids(IcsZeitraum.abHeute), ['neu', 'serie']);
      expect(ids(IcsZeitraum.jahr, jahr: 2020), ['alt', 'serie', 'beendet']);
      expect(ids(IcsZeitraum.jahr, jahr: 2026), ['neu', 'serie']);
    });

    test('Dateiname mit Datum der Familienzeitzone', () {
      expect(icsExportDateiname(_jetzt), 'lx-familyhub-kalender-2026-10-21.ics');
      expect(icsExportDateiname(DateTime.utc(2026, 12, 31, 23, 30)), 'lx-familyhub-kalender-2027-01-01.ics');
    });
  });

  group('Round-Trip mit dem Import-Parser', () {
    test('Zeittermin, Ganztag, Serie über die Zeitumstellung, Ausnahmen, Geburtstag, Erinnerung, Sonderzeichen', () {
      final termine = [
        _t(
          id: '1',
          titel: 'Zahnarzt, Dr. Müller; 3. Stock',
          ort: 'Hauptstr. 5\\7',
          beschreibung: 'Karte mitbringen\nTel: 0123,456',
          start: DateTime.utc(2026, 11, 2, 8),
          ende: DateTime.utc(2026, 11, 2, 9, 30),
          erinnerung: 60,
          uid: 'zahn-1@x',
        ),
        _t(id: '2', titel: 'Urlaub', ganz: true, startDate: '2026-12-24', endDate: '2027-01-03'),
        _t(
          id: '3',
          titel: 'Turnen',
          start: DateTime.utc(2026, 3, 17, 16),
          ende: DateTime.utc(2026, 3, 17, 17),
          rrule: 'FREQ=WEEKLY;BYDAY=TU;COUNT=8',
          erinnerung: 15,
        ),
        _t(
          id: '4',
          titel: 'Max',
          ganz: true,
          startDate: '2000-05-17',
          endDate: '2000-05-18',
          rrule: 'FREQ=YEARLY',
          uid: 'lxfampad-geb-2018-5d1f7f0e-1111-4222-8333-444455556666',
        ),
        _t(id: '5', titel: 'Telko', tzid: 'America/New_York', start: DateTime.utc(2026, 7, 1, 16), ende: DateTime.utc(2026, 7, 1, 17)),
        _t(id: '6', titel: 'Ohne Ende', start: DateTime.utc(2026, 7, 2, 7)),
      ];
      final ausn = {
        '3': [
          _a('3', '2026-03-24T16:00:00Z', abgesagt: true),
          _a('3', '2026-03-31T15:00:00Z', titel: 'Turnen (Fest)', ort: 'Aula', start: '2026-03-31T16:00:00Z', ende: '2026-03-31T17:30:00Z'),
        ],
      };
      final e = _zurueck(_export(termine, ausn));
      expect(e.hinweise.where((h) => h.uebersprungen), isEmpty, reason: e.hinweise.join('; '));
      expect(e.termine, hasLength(6));
      IcsTermin von(String uid) => e.termine.firstWhere((t) => t.uid == uid);

      final z = von('zahn-1@x');
      expect(z.titel, 'Zahnarzt, Dr. Müller; 3. Stock');
      expect(z.ort, 'Hauptstr. 5\\7');
      expect(z.beschreibung, 'Karte mitbringen\nTel: 0123,456');
      expect(z.startUtc, DateTime.utc(2026, 11, 2, 8));
      expect(z.endUtc, DateTime.utc(2026, 11, 2, 9, 30));
      expect(z.tzid, 'Europe/Berlin');
      expect(z.erinnerungMin, 60);

      final u = von('2@$kIcsUidDomain');
      expect(u.ganztaegig, isTrue);
      expect([u.startDate, u.endDate], ['2026-12-24', '2027-01-03']);

      final s = von('3@$kIcsUidDomain');
      expect(s.rrule, 'FREQ=WEEKLY;BYDAY=TU;COUNT=8');
      expect(s.startUtc, DateTime.utc(2026, 3, 17, 16));
      expect(s.erinnerungMin, 15);
      expect(s.ausnahmen, hasLength(2));
      final abgesagt = s.ausnahmen.firstWhere((a) => a.abgesagt);
      expect(abgesagt.schluessel, '2026-03-24T16:00:00Z');
      final geaendert = s.ausnahmen.firstWhere((a) => !a.abgesagt);
      expect(geaendert.schluessel, '2026-03-31T15:00:00Z');
      expect(
        [geaendert.titel, geaendert.ort, geaendert.start, geaendert.ende],
        ['Turnen (Fest)', 'Aula', '2026-03-31T16:00:00Z', '2026-03-31T17:30:00Z'],
      );

      final g = von('lxfampad-geb-2018-5d1f7f0e-1111-4222-8333-444455556666');
      expect(g.rrule, 'FREQ=YEARLY');
      expect([g.ganztaegig, g.startDate, g.endDate], [true, '2000-05-17', '2000-05-18']);

      final ny = von('5@$kIcsUidDomain');
      expect(ny.tzid, 'America/New_York');
      expect(ny.startUtc, DateTime.utc(2026, 7, 1, 16));
      expect(ny.endUtc, DateTime.utc(2026, 7, 1, 17));

      expect(von('6@$kIcsUidDomain').startUtc, DateTime.utc(2026, 7, 2, 7));
    });

    test('Umlaute und Emoji in langen Texten überstehen Faltung und Entfaltung', () {
      const titel = 'Überraschungsfeier für Jürgen äöüß🎂 äöüß🎂 äöüß🎂 äöüß🎂 äöüß🎂 äöüß🎂 äöüß🎂 äöüß🎂';
      final e = _zurueck(
        _export([_t(titel: titel, beschreibung: '$titel\n$titel', start: DateTime.utc(2026, 7, 1, 8), ende: DateTime.utc(2026, 7, 1, 9))]),
      );
      expect(e.termine.single.titel, titel);
      expect(e.termine.single.beschreibung, '$titel\n$titel');
    });
  });

  group('Round-Trip: weitere Fälle', () {
    test('Serie mit UNTIL: Zeittermin (UTC) und Ganztag (DATE)', () {
      final e = _zurueck(
        _export([
          _t(id: 'u1', start: DateTime.utc(2026, 3, 17, 16), ende: DateTime.utc(2026, 3, 17, 17), rrule: 'FREQ=WEEKLY;UNTIL=20260428T215959Z'),
          _t(id: 'u2', ganz: true, startDate: '2026-03-17', endDate: '2026-03-18', rrule: 'FREQ=DAILY;UNTIL=20260320'),
        ]),
      );
      IcsTermin von(String id) => e.termine.firstWhere((t) => t.uid == '$id@$kIcsUidDomain');
      expect(von('u1').rrule, 'FREQ=WEEKLY;UNTIL=20260428T215959Z');
      expect(von('u2').rrule, 'FREQ=DAILY;UNTIL=20260320');
      expect(von('u2').ganztaegig, isTrue);
    });

    test('Ganztags-Serie mit EXDATE und RECURRENCE-ID als VALUE=DATE', () {
      final s = _export(
        [_t(id: 'g', titel: 'Putzdienst', ganz: true, startDate: '2026-11-02', endDate: '2026-11-03', rrule: 'FREQ=WEEKLY;COUNT=6')],
        {
          'g': [_a('g', '2026-11-09', abgesagt: true), _a('g', '2026-11-16', titel: 'Putzdienst (Oma)', start: '2026-11-17', ende: '2026-11-18')],
        },
      );
      expect(s, contains('EXDATE;VALUE=DATE:20261109'));
      expect(s, contains('RECURRENCE-ID;VALUE=DATE:20261116'));
      final t = _zurueck(s).termine.single;
      expect(t.ausnahmen, hasLength(2));
      expect(t.ausnahmen.firstWhere((a) => a.abgesagt).schluessel, '2026-11-09');
      final g = t.ausnahmen.firstWhere((a) => !a.abgesagt);
      expect([g.schluessel, g.titel, g.start, g.ende], ['2026-11-16', 'Putzdienst (Oma)', '2026-11-17', '2026-11-18']);
    });

    test('Nicht-Berlin-Zeitzone mit Serie über die Zeitumstellung (New York)', () {
      final e = _zurueck(
        _export(
          [
            _t(
              id: 'ny',
              tzid: 'America/New_York',
              start: DateTime.utc(2026, 10, 27, 14),
              ende: DateTime.utc(2026, 10, 27, 15),
              rrule: 'FREQ=WEEKLY;COUNT=4',
            ),
          ],
          {
            'ny': [_a('ny', '2026-11-10T15:00:00Z', abgesagt: true)],
          },
        ),
      );
      final t = e.termine.single;
      expect(t.tzid, 'America/New_York');
      expect(t.startUtc, DateTime.utc(2026, 10, 27, 14)); // 10 Uhr EDT
      expect(t.rrule, 'FREQ=WEEKLY;COUNT=4');
      expect(t.ausnahmen.single.schluessel, '2026-11-10T15:00:00Z'); // nach der Umstellung 10 Uhr EST = 15 Uhr UTC
    });

    test('doppelte icalUid: der zweite Termin bekommt die UID aus seiner ID, beide überleben den Import', () {
      final e = _zurueck(
        _export([
          _t(id: 'd1', titel: 'Eins', start: DateTime.utc(2026, 7, 1, 8), ende: DateTime.utc(2026, 7, 1, 9), uid: 'gleich@x'),
          _t(id: 'd2', titel: 'Zwei', start: DateTime.utc(2026, 7, 2, 8), ende: DateTime.utc(2026, 7, 2, 9), uid: 'gleich@x'),
        ]),
      );
      expect(e.termine.map((t) => t.uid).toSet(), {'gleich@x', 'd2@$kIcsUidDomain'});
      expect(e.termine.map((t) => t.titel).toSet(), {'Eins', 'Zwei'});
    });
  });

  group('Speichern', () {
    test('Web: Download liefert immer null und gilt als Erfolg; Android: null = abgebrochen', () {
      expect(icsSpeichernErfolg(null, web: true), isTrue);
      expect(icsSpeichernErfolg(null, web: false), isFalse);
      expect(icsSpeichernErfolg(Uri.parse('content://x/y.ics'), web: false), isTrue);
    });
  });

  group('Seite', () {
    for (final skala in [1.0, 1.5]) {
      testWidgets('Zeitraum, Anzahl, Speichern, 360 px, Textskala $skala', (tester) async {
        final env = await angemeldeteUmgebung();
        final jahr = DateTime.now().year;
        await env.db.into(env.db.termine).insert(_t(id: 'alt', titel: 'Alt', start: DateTime.utc(2020, 5, 5, 8), ende: DateTime.utc(2020, 5, 5, 9)));
        await env.db
            .into(env.db.termine)
            .insert(_t(id: 'neu', titel: 'Neu', start: DateTime.utc(jahr + 1, 5, 5, 8), ende: DateTime.utc(jahr + 1, 5, 5, 9)));
        String? name;
        Uint8List? bytes;
        env.extraOverrides.add(
          icsSpeichernProvider.overrideWithValue((n, b) async {
            name = n;
            bytes = b;
            return true;
          }),
        );
        await starteApp(tester, env, skala: skala);
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
        await warte(tester);
        await tester.tap(find.byTooltip('Mehr: Importieren, Exportieren'));
        await warte(tester);
        await tester.tap(find.text('Kalender exportieren'));
        await warte(tester);
        expect(find.text('2 Termine werden exportiert.'), findsOneWidget);
        pruefeLayout(tester, 'Export');
        await tester.tap(find.text('Ab heute'));
        await warte(tester);
        expect(find.text('1 Termin wird exportiert.'), findsOneWidget);
        await tester.tap(find.text('Ein Jahr'));
        await warte(tester);
        expect(find.text('Keine Termine im Zeitraum.'), findsOneWidget);
        pruefeLayout(tester, 'Jahr');
        await tester.tap(find.text('Alles'));
        await warte(tester);
        await tester.tap(find.textContaining('2 Termine exportieren'));
        await warte(tester, 10);
        expect(find.text('2 Termine gespeichert.'), findsOneWidget);
        expect(name, matches(RegExp(r'^lx-familyhub-kalender-\d{4}-\d{2}-\d{2}\.ics$')));
        final text = utf8.decode(bytes!);
        expect(text, contains('SUMMARY:Alt'));
        expect(text, contains('SUMMARY:Neu'));
      });
    }
  });
}
