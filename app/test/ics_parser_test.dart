// ICS-Parser: echte Exportformen (Google, Apple, Outlook mit Windows-Zeitzone, FamilyWall-Auszug), Serien mit EXDATE/RECURRENCE-ID, Erinnerung,
// Unfolding, Escapes, Umlaute/Emoji, kaputte und bösartige Dateien, Größen- und Anzahlgrenzen.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/ics_datei.dart';
import 'package:lx_fampad/data/calendar/ics_lesen_io.dart';
import 'package:lx_fampad/data/calendar/ics_parser.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
IcsErgebnis _text(String s) => icsLesen(_bytes(s));
IcsErgebnis _datei(String name) => icsLesen(File('test/fixtures/ics/$name').readAsBytesSync());

String _cal(String events) => 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$events\r\nEND:VCALENDAR\r\n';

IcsTermin _eins(String events) {
  final e = _text(_cal(events));
  expect(e.termine, hasLength(1), reason: e.hinweise.join('; '));
  return e.termine.single;
}

void main() {
  tzdata.initializeTimeZones();

  group('Google-Export', () {
    final e = _datei('google.ics');
    IcsTermin t(String uid) => e.termine.firstWhere((x) => x.uid == uid);

    test('Serie mit TZID, UNTIL in UTC, EXDATE, Escapes und Erinnerung', () {
      final s = t('3k2j4h5g6f7d8s9a@google.com');
      expect(s.titel, 'Kinderturnen');
      expect(s.ort, 'Sporthalle, Hauptstraße 5');
      expect(s.beschreibung, 'Mitbringen: Turnbeutel\nund Trinkflasche, bitte!');
      expect(s.tzid, 'Europe/Berlin');
      expect(s.startUtc, DateTime.utc(2026, 11, 3, 16)); // 17 Uhr MEZ
      expect(s.endUtc, DateTime.utc(2026, 11, 3, 17));
      expect(s.rrule, 'FREQ=WEEKLY;WKST=SU;UNTIL=20270105T225959Z;BYDAY=TU');
      expect(s.erinnerungMin, 30);
      final abgesagt = s.ausnahmen.where((a) => a.abgesagt).single;
      expect(abgesagt.schluessel, '2026-12-01T16:00:00Z');
    });

    test('RECURRENCE-ID wird zur Ausnahme mit geändertem Titel, Ort und Ende', () {
      final a = t('3k2j4h5g6f7d8s9a@google.com').ausnahmen.firstWhere((x) => !x.abgesagt);
      expect(a.schluessel, '2026-11-10T16:00:00Z');
      expect(a.titel, 'Kinderturnen (Sonderstunde)');
      expect(a.ort, 'Turnhalle Nord');
      expect(a.start, '2026-11-10T16:00:00Z');
      expect(a.ende, '2026-11-10T17:30:00Z'); // Dauer 1,5 Stunden statt 1
    });

    test('ganztägig: Ende exklusiv, Emoji bleibt', () {
      final g = t('weihnachten-2026@google.com');
      expect(g.ganztaegig, isTrue);
      expect([g.startDate, g.endDate], ['2026-12-24', '2026-12-27']);
      expect(g.titel, 'Weihnachten bei Oma 🎄');
      expect(g.startUtc, isNull);
      expect(g.tzid, isNull);
    });

    test('Geburtstag vor 2000 mit jährlicher Serie wird ins Jahr 2000 verschoben', () {
      final g = t('geburtstag-opa@google.com');
      expect(g.startDate, '2000-06-12');
      expect(g.endDate, '2000-06-13');
      expect(g.rrule, 'FREQ=YEARLY');
      expect(e.hinweise.any((h) => h.titel == 'Opa Geburtstag'), isTrue);
    });
  });

  test('Apple-Export: LF, Unfolding, Escapes, Teilnehmer/Organisator/Anhang/URL werden ignoriert, schwebend und UTC', () {
    final e = _datei('apple.ics');
    expect(e.termine, hasLength(3));
    final z = e.termine.first;
    expect(z.titel, 'Zahnarzt \\ Dr. Müller');
    expect(z.beschreibung, startsWith('Kontrolle; Termin lang'));
    expect(z.beschreibung, endsWith('Unfolding geprüft wird'));
    expect(z.startUtc, DateTime.utc(2026, 11, 5, 8, 30));
    expect(z.erinnerungMin, 60);
    final all = jsonEncode([for (final t in e.termine) [t.titel, t.ort, t.beschreibung, t.uid]]);
    expect(all, isNot(contains('mailto')));
    expect(all, isNot(contains('example.org')));
    final schwebend = e.termine[1];
    expect(schwebend.tzid, 'Europe/Berlin');
    expect(schwebend.startUtc, DateTime.utc(2026, 11, 6, 11));
    final utc = e.termine[2];
    expect(utc.startUtc, DateTime.utc(2026, 11, 7, 8));
    expect(utc.endUtc, DateTime.utc(2026, 11, 7, 9, 30)); // DURATION PT90M
    expect(utc.tzid, 'Europe/Berlin');
  });

  test('Outlook-Export: BOM, Windows-TZID, ganztägig, unbekannte Zone fällt auf Berlin mit Hinweis', () {
    final e = _datei('outlook.ics');
    expect(e.termine, hasLength(3));
    final m = e.termine.first;
    expect(m.titel, 'Teammeeting');
    expect(m.tzid, 'Europe/Berlin');
    expect(m.startUtc, DateTime.utc(2026, 11, 10, 13));
    expect(m.erinnerungMin, 15);
    expect(e.termine[1].ganztaegig, isTrue);
    expect(e.termine[2].startUtc, DateTime.utc(2026, 11, 12, 9));
    expect(e.hinweise.where((h) => h.text.contains('Mitteleuropaeische Spezialzeit')), hasLength(1));
  });

  test('Windows-Zonen werden auf IANA abgebildet', () {
    final t = _eins('BEGIN:VEVENT\r\nUID:w1\r\nDTSTART;TZID=Eastern Standard Time:20261110T100000\r\nDTEND;TZID=Eastern Standard Time:20261110T110000\r\nSUMMARY:NY\r\nEND:VEVENT');
    expect(t.tzid, 'America/New_York');
    expect(t.startUtc, DateTime.utc(2026, 11, 10, 15));
  });

  group('FamilyWall-Auszug', () {
    final e = _datei('familywall.ics');
    IcsTermin t(String uid) => e.termine.firstWhere((x) => x.uid == uid);

    test('VTIMEZONE mit historischen Regeln stört nicht; UID mit Schrägstrich bleibt', () {
      expect(e.termine, isNotEmpty);
      expect(e.termine.every((x) => x.uid.startsWith('event/')), isTrue);
      expect(e.abgeschnitten, isFalse);
    });

    test('Europe/Madrid bleibt als Zeitzone erhalten, Instant stimmt', () {
      final m = t('event/1011');
      expect(m.tzid, 'Europe/Madrid');
      expect(m.startUtc, DateTime.utc(2025, 8, 18, 5, 30)); // MESZ
    });

    test('Geburtstage: jährlich, ganztägig; gleichnamige mit verschiedener UID bleiben getrennt; EXDATE auf den Beginn', () {
      expect(t('event/1004').rrule, 'FREQ=YEARLY;INTERVAL=1;BYMONTH=2;BYMONTHDAY=23');
      expect(t('event/1005').titel, t('event/1006').titel);
      expect(t('event/1005').ausnahmen.single.schluessel, '2026-05-15');
      expect(t('event/1005').ausnahmen.single.abgesagt, isTrue);
      expect(t('event/1006').ausnahmen, isEmpty);
    });

    test('wöchentliche Serie mit UNTIL in UTC und EXDATE-Liste', () {
      final s = t('event/1007');
      expect(s.rrule, 'FREQ=WEEKLY;UNTIL=20260918T215959Z;INTERVAL=1;BYDAY=FR');
      expect(s.ausnahmen, hasLength(4));
      expect(s.ausnahmen.first.schluessel, '2026-02-13T10:30:00Z');
    });

    test('Dauer null bleibt Dauer null, Mitternachtsgrenze und mehrtägig stimmen', () {
      final n = t('event/1012');
      expect(n.endUtc, n.startUtc);
      final m = t('event/1014');
      expect(m.endUtc!.difference(m.startUtc!), const Duration(hours: 1));
      final z = t('event/1010');
      expect(z.endUtc!.isAfter(z.startUtc!), isTrue);
      expect(z.beschreibung, contains('● Buchungsnummer'));
    });

    test('Emoji, Umlaute und Escapes', () {
      expect(t('event/1009').titel, 'Geburtstag 40 🎂');
      expect(t('event/1010').ort, 'Flughafenstraße 100, 90411 Nürnberg');
      expect(t('event/1008').beschreibung, contains('Donnerstag, 06.08.2026\nim Raum'));
    });

    test('keine E-Mail-Adresse und keine Farbangabe landet in den Terminen', () {
      final alles = jsonEncode([for (final x in e.termine) [x.titel, x.ort, x.beschreibung]]);
      expect(alles, isNot(contains('@example.org')));
    });
  });

  group('Regeln und Randfälle', () {
    test('Stunden-Serie wird übersprungen, exotische Regel als Einzeltermin, abgesagte und kaputte Termine mit Grund', () {
      final e = _datei('kaputt.ics');
      expect(e.termine.map((t) => t.uid), ['ok-1', 'exot-1', 'unvollstaendig']);
      expect(e.termine[1].rrule, isNull);
      final weg = e.hinweise.where((h) => h.uebersprungen).map((h) => h.titel).toSet();
      expect(weg, containsAll(['Ohne Beginn', 'Kaputtes Datum', 'Stuendlich', 'Abgesagt']));
      expect(e.hinweise.any((h) => h.titel == 'Exotische Regel' && !h.uebersprungen), isTrue);
    });

    test('keine ICS-Datei -> Fehler', () {
      expect(() => _text('hallo welt'), throwsA(isA<IcsFehler>()));
      expect(() => icsLesen(Uint8List(0)), throwsA(isA<IcsFehler>()));
      expect(() => icsLesen(Uint8List.fromList(List.filled(256, 0xFF))), throwsA(isA<IcsFehler>()));
    });

    test('mehr als 5 MB -> Fehler; Strom wird beim Lesen abgebrochen', () async {
      expect(() => icsLesen(Uint8List(kIcsMaxBytes + 1)), throwsA(isA<IcsFehler>()));
      var geliefert = 0;
      Stream<Uint8List> quelle() async* {
        for (var i = 0; i < 100; i++) {
          geliefert++;
          yield Uint8List(1024 * 1024);
        }
      }

      await expectLater(leseBegrenzt(quelle()), throwsA(isA<IcsFehler>()));
      expect(geliefert, lessThan(10));
    });

    test('mehr als 5000 Termine: die ersten 5000 werden gelesen, Hinweis', () {
      final b = StringBuffer();
      for (var i = 0; i < 5100; i++) {
        b.write('BEGIN:VEVENT\r\nUID:u$i\r\nDTSTART:20261201T100000Z\r\nSUMMARY:T$i\r\nEND:VEVENT\r\n');
      }
      final e = _text(_cal(b.toString()));
      expect(e.termine, hasLength(5000));
      expect(e.abgeschnitten, isTrue);
      expect(e.hinweise.any((h) => h.titel == null && h.text.contains('5000')), isTrue);
    });

    test('bösartige Eingaben: tiefe Verschachtelung, endlose Zeile, ReDoS-artige Regel, Steuerzeichen', () {
      expect(() => _text(_cal('BEGIN:X\r\n' * 20)), throwsA(isA<IcsFehler>()));
      final lang = 'x' * 400000;
      final e = _text(_cal('BEGIN:VEVENT\r\nUID:a\r\nDTSTART:20261201T100000Z\r\nSUMMARY:$lang\r\nDESCRIPTION:${'y' * 90000}\r\n ${'z' * 90000}\r\nEND:VEVENT'));
      expect(e.termine.single.titel.length, lessThanOrEqualTo(200));
      expect(e.termine.single.beschreibung.length, lessThanOrEqualTo(4000));
      final sw = Stopwatch()..start();
      final r = _text(_cal('BEGIN:VEVENT\r\nUID:r\r\nDTSTART:20261201T100000Z\r\nRRULE:FREQ=DAILY;${'BYDAY=MO;' * 5000}\r\nSUMMARY:r\r\nEND:VEVENT'));
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(r.termine.single.rrule, isNull);
      final t = _eins('BEGIN:VEVENT\r\nUID:c\r\nDTSTART:20261201T100000Z\r\nSUMMARY:A${String.fromCharCode(0)}B${String.fromCharCode(7)}C<b>${String.fromCharCode(0x202E)}\r\nEND:VEVENT');
      expect(t.titel, 'ABC<b>');
    });

    test('Beschreibung über 4000 Zeichen wird gekürzt und im Hinweis ausgewiesen', () {
      final e = _text(_cal('BEGIN:VEVENT\r\nUID:d\r\nDTSTART:20261201T100000Z\r\nSUMMARY:Lang\r\nDESCRIPTION:${'ab ' * 3000}\r\nEND:VEVENT'));
      expect(e.termine.single.beschreibung.length, lessThanOrEqualTo(4000));
      expect(e.hinweise.any((h) => h.text.contains('4000')), isTrue);
    });

    test('Regel wird auf Servergrenzen gebracht', () {
      expect(_eins('BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20261201T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5000\r\nSUMMARY:a\r\nEND:VEVENT').rrule, 'FREQ=DAILY;COUNT=1000');
      expect(
        _eins('BEGIN:VEVENT\r\nUID:2\r\nDTSTART;TZID=Europe/Berlin:20261201T100000\r\nRRULE:FREQ=DAILY;UNTIL=20261231\r\nSUMMARY:a\r\nEND:VEVENT').rrule,
        'FREQ=DAILY;UNTIL=20261231T225959Z',
      );
      expect(
        _eins('BEGIN:VEVENT\r\nUID:3\r\nDTSTART;VALUE=DATE:20261201\r\nRRULE:FREQ=DAILY;UNTIL=20261231T225959Z\r\nSUMMARY:a\r\nEND:VEVENT').rrule,
        'FREQ=DAILY;UNTIL=20261231',
      );
      expect(_eins('BEGIN:VEVENT\r\nUID:4\r\nDTSTART:20261201T100000Z\r\nRRULE:FREQ=WEEKLY;BYSETPOS=1\r\nSUMMARY:a\r\nEND:VEVENT').rrule, isNull);
    });

    test('Erinnerung: nächster Wert, nach Beginn und absolut werden ignoriert', () {
      String alarm(String trigger) => 'BEGIN:VEVENT\r\nUID:e\r\nDTSTART:20261201T100000Z\r\nSUMMARY:a\r\nBEGIN:VALARM\r\n$trigger\r\nEND:VALARM\r\nEND:VEVENT';
      expect(_eins(alarm('TRIGGER:-PT10M')).erinnerungMin, 5);
      expect(_eins(alarm('TRIGGER:-P2D')).erinnerungMin, 1440);
      expect(_eins(alarm('TRIGGER:PT5M')).erinnerungMin, isNull);
      expect(_eins(alarm('TRIGGER;VALUE=DATE-TIME:20261201T090000Z')).erinnerungMin, isNull);
      expect(_eins(alarm('TRIGGER:-PT0S')).erinnerungMin, 0);
    });

    test('Termin ohne UID bekommt eine stabile Ersatz-UID; lange UID wird gehasht', () {
      const ev = 'BEGIN:VEVENT\r\nDTSTART;X-FOO="a:b;c":20261201T100000Z\r\nSUMMARY:Ohne\r\nEND:VEVENT';
      final a = _eins(ev), b = _eins(ev);
      expect(a.uid, b.uid);
      expect(a.uid, startsWith('fampad-ics-'));
      final l = _eins('BEGIN:VEVENT\r\nUID:${'u' * 400}\r\nDTSTART:20261201T100000Z\r\nSUMMARY:a\r\nEND:VEVENT');
      expect(l.uid.length, lessThanOrEqualTo(255));
    });

    test('Ende vor Beginn, ganztägig ohne Ende und mit DTEND == DTSTART werden korrigiert', () {
      final a = _eins('BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20261201T120000Z\r\nDTEND:20261201T100000Z\r\nSUMMARY:a\r\nEND:VEVENT');
      expect(a.endUtc, a.startUtc);
      final b = _eins('BEGIN:VEVENT\r\nUID:2\r\nDTSTART;VALUE=DATE:20261201\r\nDTEND;VALUE=DATE:20261201\r\nSUMMARY:a\r\nEND:VEVENT');
      expect([b.startDate, b.endDate], ['2026-12-01', '2026-12-02']);
      final c = _eins('BEGIN:VEVENT\r\nUID:3\r\nDTSTART;VALUE=DATE:20261201\r\nSUMMARY:a\r\nEND:VEVENT');
      expect(c.endDate, '2026-12-02');
    });

    test('Jahresgrenzen: Ausnahmen außerhalb 2000 bis 2199 entfallen mit Hinweis, ganztägiges Ende wird auf 31.12.2199 gekürzt', () {
      final e = _text(_cal('BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20261201T100000Z\r\nRRULE:FREQ=WEEKLY\r\nEXDATE:19990101T100000Z,20261208T100000Z\r\nSUMMARY:a\r\nEND:VEVENT\r\n'
          'BEGIN:VEVENT\r\nUID:1\r\nRECURRENCE-ID:22501201T100000Z\r\nDTSTART:22501201T110000Z\r\nSUMMARY:fern\r\nEND:VEVENT'));
      final t = e.termine.single;
      expect(t.ausnahmen.map((a) => a.schluessel), ['2026-12-08T10:00:00Z']);
      expect(e.hinweise.any((h) => h.text.contains('außerhalb der Jahre')), isTrue);
      final k = _text(_cal('BEGIN:VEVENT\r\nUID:2\r\nDTSTART;VALUE=DATE:21991230\r\nDTEND;VALUE=DATE:22000105\r\nSUMMARY:Ende\r\nEND:VEVENT\r\n'
          'BEGIN:VEVENT\r\nUID:3\r\nDTSTART;VALUE=DATE:21991231\r\nDTEND;VALUE=DATE:22000101\r\nSUMMARY:Letzter Tag\r\nEND:VEVENT'));
      final ende = k.termine.firstWhere((x) => x.uid == '2');
      expect(ende.endDate, '2199-12-31');
      expect(k.hinweise.any((h) => h.titel == 'Ende' && h.text.contains('gekürzt')), isTrue);
      final letzter = k.termine.where((x) => x.uid == '3');
      expect(letzter, isEmpty, reason: 'ein Tag am 31.12.2199 braucht das Ende 2200-01-01, das der Server ablehnt');
    });

    test('Emoji bleiben heil (❤️, 👨‍👩‍👧), Zero-Width-, Tag- und Variantenzeichen verschwinden', () {
      final t = _eins('BEGIN:VEVENT\r\nUID:e\r\nDTSTART:20261201T100000Z\r\nSUMMARY:❤️ 👨‍👩‍👧 a​b‍c⁠d؜e${String.fromCharCode(0xE0041)}f︎g 1️⃣\r\nEND:VEVENT');
      expect(t.titel, '❤️ 👨‍👩‍👧 abcdefg 1️⃣');
    });

    test('Entfalten auf Byte-Ebene: eine Faltung mitten in einem Mehrbyte-Zeichen zerstört es nicht', () {
      final b = BytesBuilder()
        ..add(utf8.encode('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:f\r\nDTSTART:20261201T100000Z\r\nSUMMARY:Gr'))
        ..add([0xC3])
        ..add(utf8.encode('\r\n '))
        ..add([0xBC, 0xC3])
        ..add(utf8.encode('\n \n\t'))
        ..add([0x9F])
        ..add(utf8.encode('e 🎂\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'));
      expect(icsLesen(b.takeBytes()).termine.single.titel, 'Grüße 🎂');
    });

    test('sehr viele verschiedene Eigenschaften je Termin werden gedeckelt, der Termin bleibt lesbar', () {
      final props = [for (var i = 0; i < 400; i++) 'X-P$i:v'].join('\r\n');
      final t = _eins('BEGIN:VEVENT\r\nUID:p\r\nDTSTART:20261201T100000Z\r\nSUMMARY:viele\r\n$props\r\nEND:VEVENT');
      expect(t.titel, 'viele');
    });

    test('Hinweisliste wird bei 5000 gekappt', () {
      final b = StringBuffer();
      for (var i = 0; i < 5000; i++) {
        b.write('BEGIN:VEVENT\r\nUID:c$i\r\nSTATUS:CANCELLED\r\nDTSTART:20261201T100000Z\r\nSUMMARY:T$i\r\nEND:VEVENT\r\n');
      }
      b.write('BEGIN:VEVENT\r\nUID:zuviel\r\nSUMMARY:x\r\nEND:VEVENT\r\n');
      final e = _text(_cal(b.toString()));
      expect(e.hinweise.length, lessThanOrEqualTo(kIcsMaxHinweise + 1));
      expect(e.hinweise.last.text, contains('weitere Hinweise'));
    });

    test('Serie mit Beginn in UTC wird in der Familienzone gerechnet, mit Hinweis', () {
      final e = _text(_cal('BEGIN:VEVENT\r\nUID:u\r\nDTSTART:20261003T080000Z\r\nDTEND:20261003T090000Z\r\nRRULE:FREQ=WEEKLY;UNTIL=20261231\r\nSUMMARY:UTC-Serie\r\nEND:VEVENT'));
      final t = e.termine.single;
      expect(t.tzid, 'Europe/Berlin');
      expect(t.startUtc, DateTime.utc(2026, 10, 3, 8));
      expect(t.rrule, 'FREQ=WEEKLY;UNTIL=20261231T225959Z');
      expect(e.hinweise.any((h) => h.text.contains('UTC')), isTrue);
    });

    test('EXDATE und RECURRENCE-ID ohne TZID nutzen die Zone des Beginns', () {
      final t = _eins('BEGIN:VEVENT\r\nUID:z\r\nDTSTART;TZID=America/New_York:20261201T100000\r\nDTEND;TZID=America/New_York:20261201T110000\r\n'
          'RRULE:FREQ=WEEKLY\r\nEXDATE:20261208T100000\r\nSUMMARY:NY-Serie\r\nEND:VEVENT');
      expect(t.ausnahmen.single.schluessel, '2026-12-08T15:00:00Z');
    });

    test('mehr als 500 EXDATE: gekürzt mit Hinweis', () {
      final tage = [for (var i = 0; i < 600; i++) DateTime.utc(2027, 1, 1).add(Duration(days: i))];
      final liste = tage.map((d) => '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}T100000Z').join(',');
      final e = _text(_cal('BEGIN:VEVENT\r\nUID:x\r\nDTSTART:20261201T100000Z\r\nRRULE:FREQ=DAILY\r\nEXDATE:$liste\r\nSUMMARY:x\r\nEND:VEVENT'));
      expect(e.termine.single.ausnahmen, hasLength(kIcsMaxAusnahmen));
      expect(e.hinweise.any((h) => h.text.contains('EXDATE')), isTrue);
    });

    test('Ersatz-UID berücksichtigt Ende und Beschreibung; lange UIDs werden nicht vor dem Hashen gekürzt', () {
      String ev(String extra) => 'BEGIN:VEVENT\r\nDTSTART:20261201T100000Z\r\nSUMMARY:Gleich\r\n$extra\r\nEND:VEVENT';
      expect(_eins(ev('DESCRIPTION:A')).uid, isNot(_eins(ev('DESCRIPTION:B')).uid));
      expect(_eins(ev('DTEND:20261201T110000Z')).uid, isNot(_eins(ev('DTEND:20261201T120000Z')).uid));
      String lang(String ende) => 'BEGIN:VEVENT\r\nUID:${'u' * 450}$ende\r\nDTSTART:20261201T100000Z\r\nSUMMARY:l\r\nEND:VEVENT';
      expect(_eins(lang('a')).uid, isNot(_eins(lang('b')).uid));
    });

    test('Zeit: 5000 Termine werden in angemessener Zeit gelesen (großzügige Grenze), auch im Hintergrund-Isolate', () async {
      final b = StringBuffer();
      for (var i = 0; i < 5000; i++) {
        b.write('BEGIN:VEVENT\r\nUID:z$i\r\nDTSTART;TZID=Europe/Berlin:20261201T100000\r\nDTEND;TZID=Europe/Berlin:20261201T110000\r\n'
            'RRULE:FREQ=WEEKLY;COUNT=10\r\nSUMMARY:Termin $i\r\nDESCRIPTION:${'Text ' * 40}\r\nEND:VEVENT\r\n');
      }
      final bytes = _bytes(_cal(b.toString()));
      final uhr = Stopwatch()..start();
      expect(icsLesen(bytes).termine, hasLength(5000));
      stdout.writeln('Parser: 5000 Termine in ${uhr.elapsedMilliseconds} ms (${(bytes.length / 1024).round()} KB)');
      expect(uhr.elapsed, lessThan(const Duration(seconds: 20)));
      final etappen = <double>[];
      expect((await icsLesenEtappen(bytes, fortschritt: etappen.add)).termine, hasLength(5000));
      expect(etappen, isNotEmpty);
      final isolate = await icsLesenImHintergrund(bytes, zonenDaten: File('assets/tz/latest.tzf').readAsBytesSync());
      expect(isolate.termine, hasLength(5000));
    });

    test('Datum außerhalb 2000 bis 2199 wird übersprungen', () {
      final e = _text(_cal('BEGIN:VEVENT\r\nUID:1\r\nDTSTART:22500101T100000Z\r\nSUMMARY:fern\r\nEND:VEVENT'));
      expect(e.termine, isEmpty);
      expect(e.hinweise.single.uebersprungen, isTrue);
    });
  });
}
