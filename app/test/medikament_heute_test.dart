// Medikamenten-Plan, Teil 2: reine Logik der Ansicht "Heute" (Tageszeiten, Zählung, Fälligkeit, bei Bedarf), der Warnungen (Vorrat, Rezept) und des 7-Tage-Verlaufs.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/medikamente/medikament_heute.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:lx_fampad/data/medikamente/medikament_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const _ich = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _kind = 'cccccccc-0000-4000-8000-00000000000c';

MedikamentInhalt _m(String name, {List<String> zeiten = const ['08:00'], Rhythmus rhythmus = const Rhythmus.taeglich(), double menge = 1, double? bestand, String? rezept, MedikamentZustand z = MedikamentZustand.aktiv}) => MedikamentInhalt(
  name: name,
  rhythmus: rhythmus,
  zeiten: rhythmus.festeZeiten ? zeiten : const [],
  menge: menge,
  beginn: '2026-10-01',
  bestand: bestand,
  bestandStand: bestand == null ? null : DateTime.utc(2026, 10, 23, 0, 0),
  rezeptDatum: rezept,
  zustand: z,
  zustandAb: z == MedikamentZustand.aktiv ? null : '2026-10-01',
);

var _n = 0;
MedEintrag _e(MedikamentInhalt m, {String subjekt = _ich, List<EinnahmeAnsicht> einnahmen = const [], DateTime? erstellt}) =>
    MedEintrag(MedikamentAnsicht(id: 'med${++_n}', konversationId: 'k', subjektId: subjekt, inhalt: m, erstelltAt: erstellt ?? DateTime.utc(2026, 10, 1)), einnahmen);

EinnahmeAnsicht _ein(String geplant, DateTime um, {EinnahmeStatus s = EinnahmeStatus.genommen}) =>
    EinnahmeAnsicht(id: 'e${++_n}', medikamentId: 'x', inhalt: EinnahmeInhalt(status: s, um: um, geplant: geplant), erstelltAt: um);

// Freitag, 23. Oktober 2026, 10:30 Uhr in Berlin (MESZ, UTC+2)
final _jetzt = DateTime.utc(2026, 10, 23, 8, 30);

void main() {
  tzdata.initializeTimeZones();

  test('Tageszeit nach Uhrzeit', () {
    expect(tageszeitVon('03:59'), Tageszeit.nachts);
    expect(tageszeitVon('04:00'), Tageszeit.morgens);
    expect(tageszeitVon('10:59'), Tageszeit.morgens);
    expect(tageszeitVon('11:00'), Tageszeit.mittags);
    expect(tageszeitVon('15:00'), Tageszeit.nachmittags);
    expect(tageszeitVon('18:00'), Tageszeit.abends);
    expect(tageszeitVon('22:00'), Tageszeit.nachts);
  });

  group('Heute', () {
    test('Gruppen nach Tageszeit, Zählung, fällig und verpasst', () {
      final blut = _e(_m('Blutdruck', zeiten: ['08:00', '20:00']), einnahmen: [_ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 12))]);
      final vit = _e(_m('Vitamin D', zeiten: ['06:00', '12:00']));
      final a = heuteAnsicht([blut, vit], _jetzt);
      expect([for (final g in a.gruppen) g.zeit], [Tageszeit.morgens, Tageszeit.mittags, Tageszeit.abends]);
      expect(a.gesamt, 4);
      expect(a.erledigt, 1);
      // 06:00 Vitamin D: verpasst (vor mehr als 2 h), 12:00 und 20:00: noch nicht fällig
      expect(a.faellig, 1);
      final morgens = a.gruppen.first.slots;
      expect(morgens.map((s) => s.zeit), ['06:00', '08:00']);
      expect(morgens.first.slot.status.name, 'verpasst');
      expect(nichtErledigtHeute([blut, vit], _jetzt), 3);
      expect(naechsterOffenerSlot([blut, vit], _jetzt)!.zeit, '06:00');
    });

    test('abgehakt: fällt aus Fälligkeit und Zähler, auch "übersprungen" gilt als erledigt', () {
      final m = _e(_m('A', zeiten: ['08:00', '10:00']), einnahmen: [_ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 6, 5)), _ein('2026-10-23T10:00', DateTime.utc(2026, 10, 23, 8, 0), s: EinnahmeStatus.uebersprungen)]);
      final a = heuteAnsicht([m], _jetzt);
      expect(a.erledigt, 2);
      expect(a.faellig, 0);
      expect(nichtErledigtHeute([m], _jetzt), 0);
      expect(naechsterOffenerSlot([m], _jetzt), isNull);
    });

    test('bei Bedarf steht getrennt, nur aktive; pausierte und beendete Pläne ergeben keine Slots', () {
      final bedarf = _e(_m('Nasenspray', rhythmus: const Rhythmus.bedarf()));
      final pause = _e(_m('Pause', z: MedikamentZustand.pausiert));
      final ende = _e(_m('Ende', z: MedikamentZustand.beendet));
      final a = heuteAnsicht([bedarf, pause, ende], _jetzt);
      expect(a.gruppen, isEmpty);
      expect(a.bedarf.map((e) => e.inhalt!.name), ['Nasenspray']);
      expect(a.gesamt, 0);
    });

    test('Wochentage und Intervall: nur an den passenden Tagen (Freitag = 5)', () {
      final mo = _e(_m('Mo', rhythmus: Rhythmus.wochentage({1})));
      final fr = _e(_m('Fr', rhythmus: Rhythmus.wochentage({5})));
      final alle2 = _e(_m('N2', rhythmus: Rhythmus.intervall(2, ab: '2026-10-21')));
      final alle2b = _e(_m('N2b', rhythmus: Rhythmus.intervall(2, ab: '2026-10-22')));
      final a = heuteAnsicht([mo, fr, alle2, alle2b], _jetzt);
      expect([for (final g in a.gruppen) ...g.slots.map((s) => s.eintrag.inhalt!.name)]..sort(), ['Fr', 'N2']);
    });

    test('nicht lesbare Pläne ergeben nichts (kein Inhalt, kein Absturz)', () {
      final kaputt = MedEintrag(MedikamentAnsicht(id: 'x', konversationId: 'k', subjektId: _ich, inhalt: null, hinweis: 'nicht lesbar', erstelltAt: DateTime.utc(2026)), const []);
      expect(heuteAnsicht([kaputt], _jetzt).leer, isTrue);
      expect(warnungen([kaputt], _jetzt), isEmpty);
    });
  });

  group('Warnungen', () {
    test('Vorrat: höchstens 7 Tage warnt, mehr nicht; Rezept: höchstens 14 Tage, abgelaufen auch', () {
      final knapp = _e(_m('Knapp', bestand: 6)); // 6 Stück bei 1 pro Tag
      final viel = _e(_m('Viel', bestand: 40));
      final ohne = _e(_m('Ohne'));
      expect(vorratWarnTage(knapp, _jetzt), inInclusiveRange(1, 7));
      expect(vorratWarnTage(viel, _jetzt), isNull);
      expect(vorratWarnTage(ohne, _jetzt), isNull);
      final naeher = _e(_m('R1', rezept: '2026-11-02'));
      final weit = _e(_m('R2', rezept: '2026-12-24'));
      final alt = _e(_m('R3', rezept: '2026-10-20'));
      expect(rezeptWarnTage(naeher, _jetzt), 10);
      expect(rezeptWarnTage(weit, _jetzt), isNull);
      expect(rezeptWarnTage(alt, _jetzt), -3);
      final w = warnungen([viel, knapp, naeher, weit, alt], _jetzt);
      expect([for (final x in w) x.art], [WarnArt.vorrat, WarnArt.rezept, WarnArt.rezept]);
      expect(w[1].tage, lessThan(w[2].tage + 100));
    });

    test('beendete Pläne warnen nicht (Rezept, Vorrat)', () {
      final e = _e(_m('X', bestand: 1, rezept: '2026-10-25', z: MedikamentZustand.beendet));
      expect(warnungen([e], _jetzt), isEmpty);
    });

    test('Texte', () {
      expect(vorratText(6), 'reicht noch 6 Tage');
      expect(vorratText(1), 'reicht noch 1 Tag');
      expect(vorratText(0), 'reicht nicht mehr für die nächste Einnahme');
      expect(rezeptText(10), 'läuft in 10 Tagen ab');
      expect(rezeptText(0), 'läuft heute ab');
      expect(rezeptText(-1), 'ist abgelaufen');
    });
  });

  group('Verlauf der letzten 7 Tage', () {
    test('genommen, verpasst, kein Plan, offen; Text zählt nur Tage mit Plan', () {
      // täglich um 08:00; genommen an 4 von den 6 vergangenen Tagen, heute 08:00 genommen
      final tage = ['2026-10-17', '2026-10-18', '2026-10-20', '2026-10-21', '2026-10-23'];
      final e = _e(_m('A'), einnahmen: [for (final t in tage) _ein('${t}T08:00', DateTime.parse('${t}T06:05:00Z'))]);
      final v = verlauf(e, _jetzt);
      expect(v.length, 7);
      expect(v.map((x) => x.stand.name), ['genommen', 'genommen', 'verpasst', 'genommen', 'genommen', 'verpasst', 'genommen']);
      expect(verlaufText(v), '5 von 7 Tagen genommen.');
    });

    test('heute noch offen zählt nicht; vor dem Beginn war nichts geplant', () {
      final e = _e(_m('A', zeiten: ['20:00']));
      final v = verlauf(e, _jetzt);
      expect(v.last.stand, VerlaufStand.offen);
      final spaet = MedikamentInhalt(name: 'B', zeiten: const ['08:00'], beginn: '2026-10-22');
      final v2 = verlauf(_e(spaet), _jetzt);
      expect(v2.take(5).every((x) => x.stand == VerlaufStand.keinPlan), isTrue);
      expect(verlaufText(verlauf(_e(MedikamentInhalt(name: 'C', zeiten: const ['20:00'], beginn: '2026-10-23')), _jetzt)), isNull);
    });
  });

  test('Kinder-Pläne erscheinen in der Heute-Ansicht mit ihrer Person (Filter macht die Oberfläche)', () {
    final k = _e(_m('Kind'), subjekt: _kind);
    final a = heuteAnsicht([k], _jetzt);
    expect(a.gruppen.single.slots.single.subjektId, _kind);
  });

  group('Neuer Plan: Slots vor dem Anlegen gibt es nicht', () {
    test('Anlegen um 15:00 mit 08:00 und 20:00: nur 20:00 ist heute offen, nichts verpasst oder fällig', () {
      final angelegt = DateTime.utc(2026, 10, 23, 13, 0); // 15:00 Berlin
      final jetzt = DateTime.utc(2026, 10, 23, 13, 30);
      final e = _e(_m('A', zeiten: ['08:00', '20:00'], bestand: 5), erstellt: angelegt);
      final a = heuteAnsicht([e], jetzt);
      expect(a.gesamt, 1);
      expect(a.gruppen.single.slots.single.zeit, '20:00');
      expect(a.faellig, 0, reason: 'kein Badge');
      expect(heuteSlots([e], jetzt).any((s) => s.slot.status.name == 'verpasst'), isFalse);
      expect(nichtErledigtHeute([e], jetzt), 1);
      // Verlauf: heute nur offen (20:00), nie "verpasst"
      expect(verlauf(e, jetzt).last.stand, VerlaufStand.offen);
      // Vorrat: der Slot 08:00 verbraucht nichts (5 Stück: 20:00 heute + 4 Tage à 1 ... mit 2 pro Tag ab morgen)
      final ohne = _e(_m('A', zeiten: ['08:00', '20:00'], bestand: 5), erstellt: DateTime.utc(2026, 10, 1));
      expect(vorratWarnTage(e, jetzt), isNotNull);
      expect(vorratWarnTage(e, jetzt)! >= vorratWarnTage(ohne, jetzt)!, isTrue);
    });

    test('Beginn über Mitternacht: angelegt 23:50, Slot 00:10 heute entfällt, 23:55 zählt', () {
      final angelegt = DateTime.utc(2026, 10, 23, 21, 50); // 23:50 Berlin
      final jetzt = DateTime.utc(2026, 10, 23, 21, 52);
      final e = _e(_m('A', zeiten: ['00:10', '23:55']), erstellt: angelegt);
      expect(heuteSlots([e], jetzt).map((s) => s.zeit), ['23:55']);
      // am nächsten Tag zählt 00:10 wieder
      final morgen = DateTime.utc(2026, 10, 23, 22, 30); // 00:30 Berlin am 24.
      expect(heuteSlots([e], morgen).map((s) => s.zeit), ['00:10', '23:55']);
    });

    test('Sommerzeit-Ende (25.10.2026): angelegt in der zweiten 02:xx-Stunde, Slot 02:15 (erste Stunde) entfällt, 03:00 zählt', () {
      final angelegt = DateTime.utc(2026, 10, 25, 1, 30); // 02:30 MEZ, nach der Umstellung
      final jetzt = DateTime.utc(2026, 10, 25, 1, 40);
      final e = _e(_m('A', zeiten: ['02:15', '03:00']), erstellt: angelegt);
      expect(heuteSlots([e], jetzt).map((s) => s.zeit), ['03:00']);
    });
  });
}
