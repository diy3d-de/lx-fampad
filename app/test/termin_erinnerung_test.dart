// Erinnerung eines Termins: null = nie gesetzt, -1 = bewusst keine; nirgends wird -1 als Minuten gerechnet.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/ics_export.dart';
import 'package:lx_fampad/data/calendar/termin_erinnerung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'erinnerung_nachtrag_test.dart' show jetzt, termin;

void main() {
  tzdata.initializeTimeZones();

  test('Anzeige: -1 und null sind "keine", Werte >= 0 bleiben', () {
    expect(erinnerungMinuten(null), isNull);
    expect(erinnerungMinuten(-1), isNull);
    expect(erinnerungMinuten(0), 0);
    expect(erinnerungMinuten(60), 60);
  });

  test('Speichern: Auswahl gewinnt; "Keine" = -1; ein bestehender Termin ohne Wahl bleibt null', () {
    expect(erinnerungSpeichern(60), 60);
    expect(erinnerungSpeichern(null), -1);
    expect(erinnerungSpeichern(null, neu: false, bisher: null), isNull);
    expect(erinnerungSpeichern(null, neu: false, bisher: -1), -1);
    expect(erinnerungSpeichern(null, neu: false, bisher: 15), -1, reason: 'bewusst von 15 auf Keine');
    expect(erinnerungSpeichern(15, neu: false, bisher: null), 15);
  });

  test('Planung: -1 plant nichts, 60 plant eine Stunde vorher, null nichts', () {
    for (final (wert, erwartet) in <(int?, int)>[(-1, 0), (null, 0), (60, 1)]) {
      final d = KalenderDaten(termine: [termin('a', erinnerung: wert, owner: 'u-ich')]);
      expect(planeErinnerungen(daten: d, ich: 'u-ich', jetzt: jetzt).where((e) => e.id != kAuslaufHinweisPlanId), hasLength(erwartet), reason: '$wert');
    }
  });

  test('ICS-Export: -1 schreibt kein VALARM', () {
    final t = termin('a', erinnerung: -1);
    final ics = icsErstellen(termine: [t], ausnahmen: const {}, jetzt: jetzt);
    expect(ics, isNot(contains('VALARM')));
    final mit = icsErstellen(termine: [termin('b', erinnerung: 60)], ausnahmen: const {}, jetzt: jetzt);
    expect(mit, contains('TRIGGER:-PT60M'));
  });
}
