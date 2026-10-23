// Medikamenten-Plan: Klartext-Formate, Slots je Tag (Rhythmen, Beginn/Ende, Pause), Stand eines Slots (offen, genommen, übersprungen, verpasst), nächste Einnahme und Vorrat.
// Reine Logik, auch über die Umstellung auf Sommer- und Winterzeit (die Uhrzeiten sind Wanduhr der Familienzeitzone Europe/Berlin).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/medikamente/medikament_logik.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

DateTime tag(String s) => tagLesen(s)!;

MedikamentInhalt med({
  String name = 'Ibuprofen',
  Rhythmus rhythmus = const Rhythmus.taeglich(),
  List<String> zeiten = const ['08:00', '20:00'],
  double menge = 1,
  String? beginn,
  String? ende,
  MedikamentZustand zustand = MedikamentZustand.aktiv,
  String? zustandAb,
  String? pauseBis,
  double? bestand,
  DateTime? stand,
  double? packung,
}) => MedikamentInhalt(
  name: name,
  rhythmus: rhythmus,
  zeiten: zeiten,
  menge: menge,
  beginn: beginn,
  ende: ende,
  zustand: zustand,
  zustandAb: zustandAb,
  pauseBis: pauseBis,
  bestand: bestand,
  bestandStand: bestand == null ? null : (stand ?? DateTime.utc(2026, 10, 1)),
  packung: packung,
);

var _n = 0;
EinnahmeAnsicht ein(String? geplant, DateTime um, {EinnahmeStatus status = EinnahmeStatus.genommen, double? menge, String? id}) {
  final i = EinnahmeInhalt(status: status, um: um, geplant: geplant, menge: menge);
  return EinnahmeAnsicht(id: id ?? 'e${++_n}', medikamentId: 'm', inhalt: i, erstelltAt: um);
}

void main() {
  tzdata.initializeTimeZones();

  group('Format Medikament (m1)', () {
    test('Roundtrip aller Felder', () {
      final m = MedikamentInhalt(
        name: 'Metformin',
        dosis: '500 mg',
        rhythmus: Rhythmus.wochentage({1, 3, 5}),
        zeiten: const ['07:30', '19:00'],
        menge: 0.5,
        beginn: '2026-10-01',
        ende: '2026-12-31',
        zustand: MedikamentZustand.pausiert,
        zustandAb: '2026-11-01',
        pauseBis: '2026-11-07',
        bestand: 28,
        bestandStand: DateTime.utc(2026, 10, 20, 8),
        packung: 30,
        rezeptDatum: '2026-09-15',
        notiz: 'nach dem Essen, mit Wasser',
      );
      final klar = medikamentKodieren(m);
      expect(klar, startsWith('m1:'));
      expect(medikamentLesen(klar), m);
      for (final r in [const Rhythmus.taeglich(), Rhythmus.intervall(3, ab: '2026-10-01'), Rhythmus.wochentage({7})]) {
        final x = med(rhythmus: r);
        expect(medikamentLesen(medikamentKodieren(x)), x);
      }
      final bedarf = med(rhythmus: const Rhythmus.bedarf(), zeiten: const []);
      expect(medikamentLesen(medikamentKodieren(bedarf)), bedarf);
    });

    test('ungültige Inhalte werden nie geschrieben', () {
      final schlecht = <MedikamentInhalt>[
        med(name: ''),
        med(name: '   '),
        med(name: 'x' * (kMaxNameZeichen + 1)),
        med(zeiten: const ['20:00', '08:00']), // nicht aufsteigend
        med(zeiten: const ['08:00', '08:00']), // doppelt
        med(zeiten: const ['25:00']),
        med(zeiten: const ['8:00']),
        med(zeiten: const []), // feste Zeiten ohne Uhrzeit
        med(rhythmus: const Rhythmus.bedarf()), // bei Bedarf mit Uhrzeiten
        med(menge: 0),
        med(menge: -1),
        med(menge: kMaxMenge + 1),
        med(menge: double.nan),
        med(beginn: '2026-13-01'),
        med(beginn: '2026-02-30'),
        med(beginn: '2026-12-01', ende: '2026-11-30'),
        med(rhythmus: Rhythmus.wochentage({})),
        med(rhythmus: Rhythmus.wochentage({0, 8})),
        med(rhythmus: Rhythmus.intervall(0, ab: '2026-10-01')),
        med(rhythmus: Rhythmus.intervall(400, ab: '2026-10-01')),
        med(rhythmus: Rhythmus.intervall(2, ab: 'morgen')),
        med(bestand: -1, stand: DateTime.utc(2026)),
        med(packung: 0),
        med(zeiten: [for (var i = 0; i < kMaxZeiten + 1; i++) '${(i + 8).toString().padLeft(2, '0')}:00']),
      ];
      for (final (i, m) in schlecht.indexed) {
        expect(m.gueltig, isFalse, reason: 'Fall $i');
        expect(() => medikamentKodieren(m), throwsArgumentError);
      }
      // zu groß
      expect(() => medikamentKodieren(med().kopie(notiz: 'n' * kMaxNotizZeichen).kopie(dosis: 'd' * kMaxDosisZeichen)), returnsNormally);
      expect(() => medikamentKodieren(med().kopie(notiz: 'n' * (kMaxNotizZeichen + 1))), throwsArgumentError);
    });

    test('Lesen: kaputt, falscher Typ, neuere oder fehlende Version, ungültige Werte ergeben null', () {
      final gut = medikamentKodieren(med());
      expect(medikamentLesen(gut), isNotNull);
      final json = jsonDecode(gut.substring(3)) as Map<String, dynamic>;
      String mit(Map<String, dynamic> aenderung) => 'm1:${jsonEncode({...json, ...aenderung})}';
      expect(medikamentLesen(''), isNull);
      expect(medikamentLesen('m1:'), isNull);
      expect(medikamentLesen('m1:{kaputt'), isNull);
      expect(medikamentLesen('m1:[]'), isNull);
      expect(medikamentLesen('n1:${gut.substring(3)}'), isNull);
      expect(medikamentLesen(gut.substring(3)), isNull);
      expect(medikamentLesen(mit({'v': 2})), isNull); // neuere Version: nicht lesbar, nie ein Teilinhalt
      expect(medikamentLesen(mit({'v': 0})), isNull);
      expect(medikamentLesen(mit({'v': '1'})), isNull);
      expect(medikamentLesen(mit({'name': 5})), isNull);
      expect(medikamentLesen(mit({'name': ''})), isNull);
      expect(medikamentLesen(mit({'menge': 'viel'})), isNull);
      expect(medikamentLesen(mit({'zeiten': 'morgens'})), isNull);
      expect(medikamentLesen(mit({'zeiten': ['08:00', 5]})), isNull);
      expect(medikamentLesen(mit({'rhythmus': {'art': 'x'}})), isNull);
      expect(medikamentLesen(mit({'rhythmus': 'täglich'})), isNull);
      expect(medikamentLesen(mit({'zustand': 'x'})), isNull);
      expect(medikamentLesen(mit({'beginn': 5})), isNull);
      expect(medikamentLesen(mit({'beginn': '1.10.2026'})), isNull);
      expect(medikamentLesen(mit({'bestand': 5})), isNull); // Bestand ohne Stichtag
      expect(medikamentLesen(mit({'bestand': 5, 'bestandStand': 'gestern'})), isNull);
      expect(medikamentLesen(mit({'packung': 0})), isNull);
      // Unbekannte Zusatzfelder (spätere App der gleichen Version) stören nicht
      expect(medikamentLesen(mit({'zukunft': true})), isNotNull);
    });
  });

  group('Format Einnahme (n1)', () {
    test('Roundtrip und Ungültiges', () {
      final e = EinnahmeInhalt(status: EinnahmeStatus.genommen, um: DateTime.utc(2026, 10, 20, 6, 10), geplant: '2026-10-20T08:00', menge: 0.5);
      expect(einnahmeLesen(einnahmeKodieren(e)), e);
      final ohne = EinnahmeInhalt(status: EinnahmeStatus.uebersprungen, um: DateTime.utc(2026, 10, 20));
      expect(einnahmeLesen(einnahmeKodieren(ohne)), ohne);
      for (final g in ['2026-10-20 08:00', '2026-10-20T8:00', '2026-10-20T24:00', '2026-02-30T08:00', 'x']) {
        expect(() => einnahmeKodieren(EinnahmeInhalt(status: EinnahmeStatus.genommen, um: DateTime.utc(2026), geplant: g)), throwsArgumentError, reason: g);
      }
      expect(() => einnahmeKodieren(EinnahmeInhalt(status: EinnahmeStatus.genommen, um: DateTime.utc(2026), menge: 0)), throwsArgumentError);
      expect(einnahmeLesen(''), isNull);
      expect(einnahmeLesen('n1:{}'), isNull);
      expect(einnahmeLesen('n1:{"v":2,"s":"g","um":"2026-10-20T00:00:00.000Z"}'), isNull);
      expect(einnahmeLesen('n1:{"v":1,"s":"x","um":"2026-10-20T00:00:00.000Z"}'), isNull);
      expect(einnahmeLesen('n1:{"v":1,"s":"g","um":"morgen"}'), isNull);
      expect(einnahmeLesen('n1:{"v":1,"s":"g","um":"2026-10-20T00:00:00.000Z","g":5}'), isNull);
      expect(einnahmeLesen('m1:{"v":1,"s":"g","um":"2026-10-20T00:00:00.000Z"}'), isNull);
    });
  });

  group('Slots je Tag', () {
    test('täglich: alle Uhrzeiten; bei Bedarf: nie', () {
      expect([for (final s in slotsAmTag(med(), tag('2026-10-23'))) s.schluessel], ['2026-10-23T08:00', '2026-10-23T20:00']);
      expect(slotsAmTag(med(rhythmus: const Rhythmus.bedarf(), zeiten: const []), tag('2026-10-23')), isEmpty);
    });

    test('Wochentage (1 = Montag)', () {
      final m = med(rhythmus: Rhythmus.wochentage({1, 3, 5}), zeiten: const ['09:00']);
      // 2026-10-19 ist ein Montag
      final tage = [for (var i = 0; i < 7; i++) slotsAmTag(m, tag('2026-10-19').add(Duration(days: i))).length];
      expect(tage, [1, 0, 1, 0, 1, 0, 0]);
      expect(slotsAmTag(med(rhythmus: Rhythmus.wochentage({7}), zeiten: const ['09:00']), tag('2026-10-25')), hasLength(1)); // Sonntag
    });

    test('Intervall: jeder N-te Tag ab dem Starttag, davor nichts, über Monats- und Jahreswechsel', () {
      final m = med(rhythmus: Rhythmus.intervall(3, ab: '2026-10-01'), zeiten: const ['08:00']);
      bool aktiv(String t) => slotsAmTag(m, tag(t)).isNotEmpty;
      expect(aktiv('2026-09-28'), isFalse);
      expect(aktiv('2026-10-01'), isTrue);
      expect(aktiv('2026-10-02'), isFalse);
      expect(aktiv('2026-10-04'), isTrue);
      expect(aktiv('2026-10-31'), isTrue); // 30 Tage = 10 x 3
      expect(aktiv('2026-11-03'), isTrue);
      expect(aktiv('2027-01-01'), isFalse); // 92 Tage nach dem 1.10.: 92 % 3 = 2
      expect(aktiv('2027-01-02'), isTrue); // 93 Tage
    });

    test('Intervall: Zählung nach Kalendertagen, nicht nach 24 Stunden (Umstellung auf Sommerzeit am 29.3.2026)', () {
      final m = med(rhythmus: Rhythmus.intervall(2, ab: '2026-03-27'), zeiten: const ['08:00']);
      final aktive = [for (var i = 0; i < 8; i++) if (slotsAmTag(m, tag('2026-03-27').add(Duration(days: i))).isNotEmpty) tagText(tag('2026-03-27').add(Duration(days: i)))];
      expect(aktive, ['2026-03-27', '2026-03-29', '2026-03-31', '2026-04-02']);
    });

    test('Beginn und Ende sind inklusive', () {
      final m = med(beginn: '2026-10-10', ende: '2026-10-12', zeiten: const ['08:00']);
      expect([for (final t in ['2026-10-09', '2026-10-10', '2026-10-11', '2026-10-12', '2026-10-13']) slotsAmTag(m, tag(t)).length], [0, 1, 1, 1, 0]);
    });

    test('Pause ab/bis (inklusive) und Beenden', () {
      final pause = med(zustand: MedikamentZustand.pausiert, zustandAb: '2026-10-10', pauseBis: '2026-10-12', zeiten: const ['08:00']);
      expect([for (final t in ['2026-10-09', '2026-10-10', '2026-10-12', '2026-10-13']) slotsAmTag(pause, tag(t)).length], [1, 0, 0, 1]);
      final ohneEnde = med(zustand: MedikamentZustand.pausiert, zustandAb: '2026-10-10', zeiten: const ['08:00']);
      expect([for (final t in ['2026-10-09', '2026-10-10', '2027-01-01']) slotsAmTag(ohneEnde, tag(t)).length], [1, 0, 0]);
      final beendet = med(zustand: MedikamentZustand.beendet, zustandAb: '2026-10-10', zeiten: const ['08:00']);
      expect([for (final t in ['2026-10-09', '2026-10-10', '2026-10-11']) slotsAmTag(beendet, tag(t)).length], [1, 0, 0]);
      expect(slotsAmTag(med(zustand: MedikamentZustand.beendet), tag('2026-10-09')), isEmpty); // ohne Datum: gilt immer
    });
  });

  group('Zeitpunkte über die Zeitumstellung', () {
    test('Sommerzeit 2026: 08:00 ist am 28.3. 07:00 UTC (MEZ), am 30.3. 06:00 UTC (MESZ); die ausgefallene 02:30 rutscht auf die Zeit danach', () {
      expect(const Slot('2026-03-28', '08:00').instant(), DateTime.utc(2026, 3, 28, 7));
      expect(const Slot('2026-03-30', '08:00').instant(), DateTime.utc(2026, 3, 30, 6));
      // 02:30 gibt es am 29.3. nicht (02:00 -> 03:00): der Zeitpunkt liegt nicht vor 01:00 UTC und nicht nach 02:00 UTC
      final i = const Slot('2026-03-29', '02:30').instant();
      expect(!i.isBefore(DateTime.utc(2026, 3, 29, 0, 30)) && !i.isAfter(DateTime.utc(2026, 3, 29, 1, 30)), isTrue, reason: '$i');
    });

    test('Winterzeit 2026: 08:00 ist am 24.10. 06:00 UTC (MESZ), am 26.10. 07:00 UTC (MEZ); die doppelte 02:30 liegt eindeutig in der Nacht', () {
      expect(const Slot('2026-10-24', '08:00').instant(), DateTime.utc(2026, 10, 24, 6));
      expect(const Slot('2026-10-26', '08:00').instant(), DateTime.utc(2026, 10, 26, 7));
      final i = const Slot('2026-10-25', '02:30').instant();
      expect(i == DateTime.utc(2026, 10, 25, 0, 30) || i == DateTime.utc(2026, 10, 25, 1, 30), isTrue, reason: '$i');
    });

    test('Der Tag des Zeitpunkts richtet sich nach der Familienzeitzone, nicht nach UTC', () {
      expect(familienTag(DateTime.utc(2026, 10, 23, 22, 30)), tag('2026-10-24')); // 00:30 MESZ am 24.
      expect(familienTag(DateTime.utc(2026, 10, 23, 21, 59)), tag('2026-10-23'));
      expect(familienTag(DateTime.utc(2026, 3, 28, 23, 30)), tag('2026-03-29')); // MEZ
      expect(familienTag(DateTime.utc(2026, 3, 29, 22, 30)), tag('2026-03-30')); // MESZ
    });

    test('Tagesplan an einem Umstellungstag hat genau so viele Slots wie Uhrzeiten, die Zeitpunkte sind aufsteigend', () {
      for (final t in ['2026-03-29', '2026-10-25']) {
        final m = med(zeiten: const ['02:30', '08:00', '20:00']);
        final slots = slotsAmTag(m, tag(t));
        expect(slots, hasLength(3));
        final z = [for (final s in slots) s.instant()];
        expect(z[0].isBefore(z[1]) && z[1].isBefore(z[2]), isTrue, reason: t);
      }
    });

    test('Verpasst-Grenze nutzt den echten Zeitpunkt (Sommerzeit: 08:00 MESZ = 06:00 UTC)', () {
      final s = const Slot('2026-07-01', '08:00');
      expect(slotStand(s, const [], DateTime.utc(2026, 7, 1, 7, 59)).status, SlotStatus.offen); // 09:59 MESZ
      expect(slotStand(s, const [], DateTime.utc(2026, 7, 1, 8, 1)).status, SlotStatus.verpasst); // 10:01 MESZ
    });
  });

  group('Stand eines Slots, nächste Einnahme, Verpasstes', () {
    final m = med(zeiten: const ['08:00', '20:00']);
    // 23.10.2026: MESZ (UTC+2): 08:00 = 06:00Z, 20:00 = 18:00Z
    final um8 = DateTime.utc(2026, 10, 23, 6);
    test('offen, genommen, übersprungen, verpasst', () {
      final einnahmen = [ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 5)), ein('2026-10-22T20:00', DateTime.utc(2026, 10, 22, 18), status: EinnahmeStatus.uebersprungen)];
      expect([for (final s in tagesplan(m, einnahmen, tag('2026-10-23'), DateTime.utc(2026, 10, 23, 7))) s.status], [SlotStatus.genommen, SlotStatus.offen]);
      expect([for (final s in tagesplan(m, einnahmen, tag('2026-10-22'), DateTime.utc(2026, 10, 23, 7))) s.status], [SlotStatus.verpasst, SlotStatus.uebersprungen]);
      // am Abend ohne Eintrag: 08:00 war genommen, 20:00 ist bis 22:00 offen, danach verpasst
      expect(tagesplan(m, einnahmen, tag('2026-10-23'), DateTime.utc(2026, 10, 23, 19, 59)).last.status, SlotStatus.offen); // 21:59
      expect(tagesplan(m, einnahmen, tag('2026-10-23'), DateTime.utc(2026, 10, 23, 20, 1)).last.status, SlotStatus.verpasst); // 22:01
      expect(tagesplan(m, einnahmen, tag('2026-10-23'), DateTime.utc(2026, 10, 23, 20, 1), verpasstNach: const Duration(hours: 5)).last.status, SlotStatus.offen);
    });

    test('mehrere Einträge zum selben Slot (zwei Geräte): genommen vor übersprungen, der früheste', () {
      final a = ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 30), status: EinnahmeStatus.uebersprungen, id: 'a');
      final b = ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 10), id: 'b');
      final c = ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 5), id: 'c');
      expect(einnahmeFuerSlot([a, b, c], const Slot('2026-10-23', '08:00'))!.id, 'c');
      expect(einnahmeFuerSlot([a, b], const Slot('2026-10-23', '08:00'))!.id, 'b');
      expect(einnahmeFuerSlot([a], const Slot('2026-10-23', '08:00'))!.id, 'a');
      expect(einnahmeFuerSlot([a, b], const Slot('2026-10-23', '20:00')), isNull);
      // nicht lesbare Einträge zählen nicht
      expect(einnahmeFuerSlot([EinnahmeAnsicht(id: 'x', medikamentId: 'm', inhalt: null, erstelltAt: um8)], const Slot('2026-10-23', '08:00')), isNull);
    });

    test('nächste Einnahme: erster offener Slot, erfasste und verpasste werden übersprungen', () {
      expect(naechsteEinnahme(m, const [], DateTime.utc(2026, 10, 23, 5))!.slot.schluessel, '2026-10-23T08:00'); // 07:00
      // 08:00 genommen: der nächste ist 20:00
      expect(naechsteEinnahme(m, [ein('2026-10-23T08:00', um8)], DateTime.utc(2026, 10, 23, 7))!.slot.schluessel, '2026-10-23T20:00');
      // 08:00 weit verpasst (13:00), 20:00 noch nicht fällig
      expect(naechsteEinnahme(m, const [], DateTime.utc(2026, 10, 23, 11))!.slot.schluessel, '2026-10-23T20:00');
      // nach dem letzten Slot geht es morgen weiter
      expect(naechsteEinnahme(m, [ein('2026-10-23T20:00', DateTime.utc(2026, 10, 23, 18)), ein('2026-10-23T08:00', um8)], DateTime.utc(2026, 10, 23, 19))!.slot.schluessel, '2026-10-24T08:00');
      // nur kurz nach Mitternacht: der Slot von gestern Abend ist noch offen (innerhalb von 2 Stunden)
      final spaet = med(zeiten: const ['23:30']);
      expect(naechsteEinnahme(spaet, const [], DateTime.utc(2026, 10, 23, 22, 30))!.slot.schluessel, '2026-10-23T23:30'); // 00:30 am 24. MESZ
    });

    test('keine nächste Einnahme: bei Bedarf, beendet, Ende des Plans erreicht', () {
      expect(naechsteEinnahme(med(rhythmus: const Rhythmus.bedarf(), zeiten: const []), const [], DateTime.utc(2026, 10, 23)), isNull);
      expect(naechsteEinnahme(med(zustand: MedikamentZustand.beendet, zustandAb: '2026-10-01'), const [], DateTime.utc(2026, 10, 23)), isNull);
      expect(naechsteEinnahme(med(ende: '2026-10-20'), const [], DateTime.utc(2026, 10, 23)), isNull);
    });

    test('pausiert: der Plan läuft nach dem Ende der Pause weiter', () {
      final p = med(zustand: MedikamentZustand.pausiert, zustandAb: '2026-10-23', pauseBis: '2026-10-25', zeiten: const ['08:00']);
      expect(naechsteEinnahme(p, const [], DateTime.utc(2026, 10, 23, 5))!.slot.schluessel, '2026-10-26T08:00');
    });

    test('verpasste Slots eines Zeitraums', () {
      final einnahmen = [ein('2026-10-21T08:00', DateTime.utc(2026, 10, 21, 6)), ein('2026-10-22T20:00', DateTime.utc(2026, 10, 22, 18))];
      final v = verpassteSlots(m, einnahmen, tag('2026-10-21'), tag('2026-10-23'), DateTime.utc(2026, 10, 23, 12));
      expect([for (final s in v) s.slot.schluessel], ['2026-10-21T20:00', '2026-10-22T08:00', '2026-10-23T08:00']);
    });
  });

  group('Vorrat', () {
    test('Verbrauch je Tag laut Plan', () {
      expect(verbrauchProTag(med()), 2);
      expect(verbrauchProTag(med(menge: 0.5)), 1);
      expect(verbrauchProTag(med(rhythmus: Rhythmus.wochentage({1, 4}))), closeTo(2 * 2 / 7, 1e-9));
      expect(verbrauchProTag(med(rhythmus: Rhythmus.intervall(2, ab: '2026-10-01'))), 1);
      expect(verbrauchProTag(med(rhythmus: const Rhythmus.bedarf(), zeiten: const [])), 0);
    });

    test('Bestand: Stichtag, nur genommene Mengen danach, je Slot einmal, nie unter 0', () {
      final stand = DateTime.utc(2026, 10, 20, 12);
      final m = med(bestand: 10, stand: stand, menge: 1);
      expect(bestandJetzt(m, const []), 10);
      final einnahmen = [
        ein('2026-10-20T08:00', DateTime.utc(2026, 10, 20, 6)), // vor dem Stichtag: zählt nicht
        ein('2026-10-20T20:00', DateTime.utc(2026, 10, 20, 18)), // 1
        ein('2026-10-20T20:00', DateTime.utc(2026, 10, 20, 18, 5)), // doppelt erfasst (zweites Gerät): zählt nicht noch einmal
        ein('2026-10-21T08:00', DateTime.utc(2026, 10, 21, 6), status: EinnahmeStatus.uebersprungen), // zählt nicht
        ein('2026-10-21T20:00', DateTime.utc(2026, 10, 21, 18), menge: 2), // 2
        ein(null, DateTime.utc(2026, 10, 22, 10)), // außer der Reihe: 1
        ein(null, DateTime.utc(2026, 10, 22, 11)), // und noch eine: 1
      ];
      expect(bestandJetzt(m, einnahmen), 10 - 1 - 2 - 1 - 1);
      expect(bestandJetzt(med(bestand: 1, stand: stand), einnahmen), 0);
      expect(bestandJetzt(med(), einnahmen), isNull);
    });

    test('Prognose: reicht noch N Tage (täglich zweimal, Bestand 5)', () {
      final m = med(bestand: 5, stand: DateTime.utc(2026, 10, 1));
      // heute 23.10. um 07:00 (MESZ 09:00?): jetzt = 05:00Z = 07:00 MESZ: beide Slots heute offen
      final p = vorratPrognose(m, const [], DateTime.utc(2026, 10, 23, 5));
      expect(p.bestand, 5);
      expect(p.tage, 2); // heute (2), morgen (2); übermorgen 08:00 ist der fünfte Slot -> 5 reichen für 2 Tage und einen Slot
      expect(p.leerAm, '2026-10-25');
      expect(p.keinVerbrauch, isFalse);
      // nachmittags: der Morgen-Slot ist verpasst (nicht erfasst), er verbraucht nichts mehr: 20:00 heute, 2 morgen, 2 übermorgen = 5
      final nachmittags = vorratPrognose(m, const [], DateTime.utc(2026, 10, 23, 13));
      expect(nachmittags.tage, 3);
      expect(nachmittags.leerAm, '2026-10-26');
      // Bestand 0: reicht nicht einmal für den nächsten Slot
      expect(vorratPrognose(med(bestand: 0, stand: DateTime.utc(2026, 10, 1)), const [], DateTime.utc(2026, 10, 23, 5)).tage, 0);
    });

    test('Prognose: Wochentage, Intervall, halbe Mengen', () {
      // Mo und Do je eine Tablette, Bestand 3, heute Freitag 23.10.: Mo 26., Do 29., Mo 2.11. -> der 4. ist der Do 5.11. (13 Tage)
      final wo = med(rhythmus: Rhythmus.wochentage({1, 4}), zeiten: const ['08:00'], bestand: 3, stand: DateTime.utc(2026, 10, 1));
      final p = vorratPrognose(wo, const [], DateTime.utc(2026, 10, 23, 5));
      expect(p.leerAm, '2026-11-05');
      expect(p.tage, 13);
      // alle 2 Tage ab 2026-10-23, Bestand 1: heute genommen werden muss, übermorgen leer
      final iv = med(rhythmus: Rhythmus.intervall(2, ab: '2026-10-23'), zeiten: const ['08:00'], bestand: 1, stand: DateTime.utc(2026, 10, 1));
      expect(vorratPrognose(iv, const [], DateTime.utc(2026, 10, 23, 5)).leerAm, '2026-10-25');
      // halbe Tabletten: 3 Stück = 6 Einnahmen zu je 0,5, einmal am Tag
      final halb = med(menge: 0.5, zeiten: const ['08:00'], bestand: 3, stand: DateTime.utc(2026, 10, 1));
      expect(vorratPrognose(halb, const [], DateTime.utc(2026, 10, 23, 5)).tage, 6);
    });

    test('Prognose: erfasste Einnahme heute verbraucht nichts mehr; Plan ohne Verbrauch und Plan, der vorher endet', () {
      final stand = DateTime.utc(2026, 10, 1);
      final m = med(zeiten: const ['08:00'], bestand: 2, stand: stand);
      final genommen = [ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 5))];
      // Bestand 2 minus die genommene heute = 1; heute nichts mehr offen, morgen 1 -> übermorgen leer
      final p = vorratPrognose(m, genommen, DateTime.utc(2026, 10, 23, 8));
      expect(p.bestand, 1);
      expect(p.leerAm, '2026-10-25');
      expect(p.tage, 2);
      expect(vorratPrognose(med(rhythmus: const Rhythmus.bedarf(), zeiten: const [], bestand: 5, stand: stand), const [], DateTime.utc(2026, 10, 23)).keinVerbrauch, isTrue);
      // der Plan endet am 24.10.: 2 Stück genügen bis zum Ende
      final kur = med(zeiten: const ['08:00'], ende: '2026-10-24', bestand: 2, stand: stand);
      final k = vorratPrognose(kur, const [], DateTime.utc(2026, 10, 23, 5));
      expect(k.leerAm, isNull);
      expect(k.reichtLange, isTrue);
      expect(vorratPrognose(med(), const [], DateTime.utc(2026, 10, 23)).bestand, isNull); // kein Bestand erfasst
    });

    test('Auffüllen: Bestand plus Packungen oder Stück, neuer Stichtag; ohne Packungsgröße nur Stück', () {
      final stand = DateTime.utc(2026, 10, 1);
      final m = med(zeiten: const ['08:00'], bestand: 3, stand: stand, packung: 30);
      final einnahmen = [ein('2026-10-02T08:00', DateTime.utc(2026, 10, 2, 6))];
      final jetzt = DateTime.utc(2026, 10, 23, 10);
      final neu = vorratAuffuellen(m, einnahmen, jetzt, packungen: 2);
      expect(neu.bestand, 3 - 1 + 60);
      expect(neu.bestandStand, jetzt);
      expect(medikamentLesen(medikamentKodieren(neu)), neu);
      expect(vorratAuffuellen(m, einnahmen, jetzt, stueck: 5).bestand, 3 - 1 + 5);
      expect(vorratAuffuellen(med(zeiten: const ['08:00']), const [], jetzt, stueck: 7).bestand, 7);
      expect(() => vorratAuffuellen(med(zeiten: const ['08:00']), const [], jetzt, packungen: 1), throwsArgumentError);
      // mit dem neuen Stichtag zählt die frühere Einnahme nicht mehr
      expect(bestandJetzt(neu, einnahmen), 62);
    });
  });
}
