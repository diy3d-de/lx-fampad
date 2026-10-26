// Tagesbriefing: reine Logik (leerer Tag, mehrere Termine, Sommerzeit-Grenze, Rollen, Müll, Wetter, neutraler Text) und die Planung der Benachrichtigung am Morgen.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung;
import 'package:lx_fampad/data/muell/muell_modelle.dart';
import 'package:lx_fampad/data/tagesbriefing/briefing_erinnerung.dart';
import 'package:lx_fampad/data/tagesbriefing/briefing_logik.dart';
import 'package:lx_fampad/data/wetter/vorhersage_modelle.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const ich = 'u-ich';
const andere = 'u-andere';

/// Montag 19.10.2026 12:00 Uhr Berlin (Sommerzeit); die Umstellung auf Winterzeit ist am 25.10.2026.
final jetzt = DateTime.utc(2026, 10, 19, 10);

Termin termin(String id, {String titel = 'Zahnarzt', bool ganztaegig = false, String? start, String? ende, String? startDate, String? endDate}) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: ganztaegig,
  startUtc: start == null ? null : DateTime.parse(start),
  endUtc: ende == null ? null : DateTime.parse(ende),
  tzid: ganztaegig ? null : 'Europe/Berlin',
  startDate: startDate,
  endDate: endDate,
  rrule: null,
  erinnerungMin: null,
  icalUid: null,
  audience: 'family',
  ownerId: ich,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

KalenderDaten kal(List<Termin> t) => KalenderDaten(termine: t);

Aufgabe aufgabe(
  String id, {
  String? faellig,
  String? zustaendig,
  String? besitzer = ich,
  String audience = 'family',
  bool frist = false,
  int? erinnerungMin,
  DateTime? erledigt,
  String titel = 'Geheime Aufgabe',
}) => Aufgabe(
  id: id,
  titel: titel,
  beschreibung: '',
  faelligDate: faellig,
  prioritaet: 0,
  assigneeId: zustaendig,
  ownerId: besitzer,
  erledigtAt: erledigt,
  frist: frist,
  erinnerungMin: erinnerungMin,
  audience: audience,
  createdAt: DateTime.utc(2026, 1, 1),
  rev: 1,
);

Tagesbriefing bau({
  List<Termin> termine = const [],
  List<Aufgabe> aufgaben = const [],
  bool eltern = true,
  String? person = ich,
  DateTime? zeit,
  List<MuellTag>? muell,
  VorhersageTag? wetter,
}) => baueTagesbriefing(kalender: kal(termine), aufgaben: aufgaben, ich: person, elternRolle: eltern, jetzt: zeit ?? jetzt, muell: muell, wetter: wetter);

List<String> texte(Tagesbriefing b) => [for (final z in b.zeilen) z.text];

void main() {
  tzdata.initializeTimeZones();

  group('Termine', () {
    test('leerer Tag: nichts zu zeigen, kein neutraler Text', () {
      final b = bau();
      expect(b.zeilen, isEmpty);
      expect(b.hatInhalt, isFalse);
      expect(b.neutralerText, isNull);
    });

    test('ohne angemeldete Person ist alles leer', () {
      expect(bau(person: null, termine: [termin('t1', start: '2026-10-19T13:00:00Z', ende: '2026-10-19T14:00:00Z')]).zeilen, isEmpty);
    });

    test('ein Termin: Uhrzeit der Familienzone und Titel', () {
      final b = bau(termine: [termin('t1', start: '2026-10-19T13:30:00Z', ende: '2026-10-19T14:30:00Z')]);
      expect(texte(b), ['Heute steht 1 Termin an: 15:30 Uhr, Zahnarzt.']);
      expect(b.termine, 1);
    });

    test('mehrere Termine: Anzahl und der nächste mit Uhrzeit; Vergangenes zählt nicht', () {
      final b = bau(
        termine: [
          termin('t0', titel: 'Frühstück', start: '2026-10-19T06:00:00Z', ende: '2026-10-19T07:00:00Z'), // 08:00 bis 09:00 Berlin: vorbei
          termin('t1', titel: 'Elternabend', start: '2026-10-19T16:00:00Z', ende: '2026-10-19T17:00:00Z'),
          termin('t2', titel: 'Zahnarzt', start: '2026-10-19T12:15:00Z', ende: '2026-10-19T13:00:00Z'),
          termin('t3', titel: 'Morgen', start: '2026-10-20T08:00:00Z', ende: '2026-10-20T09:00:00Z'),
        ],
      );
      expect(texte(b), ['Heute stehen 2 Termine an. Der nächste ist um 14:15 Uhr: Zahnarzt.']);
      expect(b.termine, 2);
    });

    test('ganztägige Termine zählen den ganzen Tag; ein mehrtägiger zählt an jedem Tag', () {
      final b = bau(termine: [termin('t1', titel: 'Urlaub', ganztaegig: true, startDate: '2026-10-17', endDate: '2026-10-21')]);
      expect(texte(b), ['Heute steht 1 Termin an: Urlaub, ganztägig.']);
      final c = bau(termine: [termin('t1', titel: 'Urlaub', ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-21')]);
      expect(c.zeilen, isEmpty, reason: 'beginnt erst morgen');
    });

    test('Sommerzeit-Grenze: der 25.10.2026 hat 25 Stunden, gezählt wird nach der Wanduhr der Familienzone', () {
      // 25.10. 00:00 Berlin = 24.10. 22:00 UTC; die Uhr wird um 03:00 auf 02:00 zurückgestellt; 26.10. 00:00 Berlin = 25.10. 23:00 UTC
      final b = bau(
        zeit: DateTime.utc(2026, 10, 24, 22),
        termine: [
          termin('a', titel: 'Vorabend', start: '2026-10-24T21:00:00Z', ende: '2026-10-24T21:30:00Z'), // 23:00 am 24.10.: vorbei und anderer Tag
          termin('b', titel: 'Nachts', start: '2026-10-24T22:30:00Z', ende: '2026-10-24T23:00:00Z'), // 00:30 am 25.10.
          termin('c', titel: 'Spätabend', start: '2026-10-25T22:30:00Z', ende: '2026-10-25T22:45:00Z'), // 23:30 am 25.10. (Winterzeit)
          termin('d', titel: 'Nächster Tag', start: '2026-10-25T23:30:00Z', ende: '2026-10-26T00:00:00Z'), // 00:30 am 26.10.
        ],
      );
      expect(b.termine, 2);
      expect(texte(b).single, 'Heute stehen 2 Termine an. Der nächste ist um 00:30 Uhr: Nachts.');
    });
  });

  group('Aufgaben und Fristen', () {
    test('heute fällig und überfällig, Erledigtes und Fremdes zählen nicht', () {
      final b = bau(
        aufgaben: [
          aufgabe('a1', faellig: '2026-10-19'),
          aufgabe('a2', faellig: '2026-10-19', zustaendig: ich, besitzer: andere),
          aufgabe('a3', faellig: '2026-10-15'),
          aufgabe('a4', faellig: '2026-10-19', erledigt: DateTime.utc(2026, 10, 18)),
          aufgabe('a5', faellig: '2026-10-19', zustaendig: andere), // jemand anderem zugewiesen
          aufgabe('a6', faellig: '2026-10-25'), // nicht fällig
          aufgabe('a7'), // ohne Datum
        ],
      );
      expect(texte(b), ['Heute sind 2 Aufgaben fällig.', '1 Aufgabe ist überfällig.']);
      expect(b.aufgaben, 3);
    });

    test('Rollen: ein Kind sieht nie Eltern-Aufgaben und nie fremde Fristen, Eltern sehen die Fristen der Familie', () {
      final liste = [
        aufgabe('f1', faellig: '2026-10-10', frist: true, audience: 'parents', besitzer: andere), // Eltern-Frist
        aufgabe('f2', faellig: '2026-10-10', frist: true, besitzer: andere), // Familien-Frist einer anderen Person
        aufgabe('f3', faellig: '2026-10-25', frist: true, erinnerungMin: 14 * 1440, besitzer: andere),
        aufgabe('e1', faellig: '2026-10-19', audience: 'parents', zustaendig: ich), // Eltern-Aufgabe, dem Kind (versehentlich) zugewiesen
      ];
      final kind = bau(aufgaben: liste, eltern: false);
      expect(kind.zeilen, isEmpty);
      final eltern = bau(aufgaben: liste);
      expect(texte(eltern), ['Heute ist 1 Aufgabe fällig.', '2 Fristen sind überfällig.', '1 Frist läuft bald ab.']);
      expect(eltern.fristen, 3, reason: 'zwei überfällige (f1, f2) und eine bald ablaufende (f3)');
    });

    test('eine dem Kind zugewiesene Familien-Frist sieht auch das Kind', () {
      final b = bau(aufgaben: [aufgabe('f1', faellig: '2026-10-25', frist: true, erinnerungMin: 14 * 1440, zustaendig: ich, besitzer: andere)], eltern: false);
      expect(texte(b), ['1 Frist läuft bald ab.']);
    });

    test('weit entfernte Fristen und erledigte Fristen zählen nicht', () {
      final b = bau(aufgaben: [aufgabe('f1', faellig: '2027-03-01', frist: true, erinnerungMin: 7 * 1440), aufgabe('f2', faellig: '2026-10-01', frist: true, erledigt: DateTime.utc(2026, 10, 2))]);
      expect(b.zeilen, isEmpty);
    });
  });

  group('Müll und Wetter', () {
    final muell = [
      MuellTag(DateTime.utc(2026, 10, 19), [MuellArt.rest, MuellArt.gelb]),
      MuellTag(DateTime.utc(2026, 10, 20), [MuellArt.papier]),
      MuellTag(DateTime.utc(2026, 10, 27), [MuellArt.bio]),
    ];

    test('Abholung heute und morgen, sonst nichts; ohne Daten keine Zeile', () {
      expect(texte(bau(muell: muell)), ['Heute ist Müllabfuhr: Restabfall, Gelber Sack.', 'Morgen ist Müllabfuhr: Altpapier.']);
      expect(bau().zeilen, isEmpty);
      expect(bau(muell: [muell[2]]).zeilen, isEmpty);
    });

    test('Wetter allein ergibt kein Briefing, mit anderem Inhalt kommt es dazu', () {
      final tag = VorhersageTag(datum: DateTime(2026, 10, 19), min: 7.6, max: 15.5, regenMm: 3, regenProzent: 70, symbol: WetterSymbol.regen);
      final nur = bau(wetter: tag);
      expect(texte(nur), ['Heute werden es 8 bis 16 °C, Regen ist wahrscheinlich (70 %).']);
      expect(nur.hatInhalt, isFalse);
      final mit = bau(wetter: tag, aufgaben: [aufgabe('a1', faellig: '2026-10-19')]);
      expect(mit.hatInhalt, isTrue);
      expect(mit.zeilen.last.art, BriefingArt.wetter);
    });

    test('Regentexte: möglich, trocken, Temperatur gleich', () {
      String t(double min, double max, int? p, double mm) => briefingWetterText(VorhersageTag(datum: DateTime(2026, 10, 19), min: min, max: max, regenMm: mm, regenProzent: p, symbol: WetterSymbol.sonne));
      expect(t(-2, 3, 30, 0.2), 'Heute werden es -2 bis 3 °C, Regen ist möglich (30 %).');
      expect(t(10, 10.2, 0, 0), 'Heute werden es um 10 °C, es bleibt voraussichtlich trocken.');
      expect(t(10, 12, null, 2.5), 'Heute werden es 10 bis 12 °C, Regen ist wahrscheinlich.');
    });
  });

  group('Neutraler Text', () {
    test('nur Zahlen, nie Titel oder Namen', () {
      final b = bau(
        termine: [termin('t1', titel: 'Therapie bei Dr. Müller', start: '2026-10-19T13:00:00Z', ende: '2026-10-19T14:00:00Z'), termin('t2', titel: 'Sport', start: '2026-10-19T15:00:00Z', ende: '2026-10-19T16:00:00Z'), termin('t3', start: '2026-10-19T17:00:00Z', ende: '2026-10-19T18:00:00Z')],
        aufgaben: [aufgabe('a1', faellig: '2026-10-19'), aufgabe('a2', faellig: '2026-10-01'), aufgabe('f1', faellig: '2026-10-20', frist: true, erinnerungMin: 1440)],
      );
      expect(b.neutralerText, 'Heute: 3 Termine, 2 Aufgaben, 1 Frist');
      expect(b.neutralerText, isNot(contains('Therapie')));
      expect(b.neutralerText, isNot(contains('Geheime')));
    });

    test('Einzahl', () {
      expect(neutralerBriefingText(termine: 1, aufgaben: 1, fristen: 0), 'Heute: 1 Termin, 1 Aufgabe');
      expect(neutralerBriefingText(termine: 0, aufgaben: 0, fristen: 0), isNull);
    });
  });

  group('Benachrichtigung am Morgen', () {
    List<GeplanteErinnerung> plan(KalenderDaten d, {List<Aufgabe> aufgaben = const [], int minuten = 420, DateTime? zeit, int tage = 7}) =>
        planeBriefingErinnerungen(daten: d, aufgaben: aufgaben, ich: ich, elternRolle: true, minuten: minuten, jetzt: zeit ?? jetzt, tage: tage);

    test('je Tag mit Inhalt eine Benachrichtigung um 07:00 Familienzeit; leere Tage und vergangene Zeiten entfallen', () {
      final d = kal([
        termin('t1', start: '2026-10-19T13:00:00Z', ende: '2026-10-19T14:00:00Z'), // heute, aber 07:00 ist schon vorbei
        termin('t2', start: '2026-10-21T08:00:00Z', ende: '2026-10-21T09:00:00Z'),
        termin('t3', start: '2026-10-21T10:00:00Z', ende: '2026-10-21T11:00:00Z'),
      ]);
      final r = plan(d);
      expect(r, hasLength(1));
      expect(r.single.zeit, DateTime.utc(2026, 10, 21, 5)); // 07:00 Berlin (Sommerzeit) = 05:00 UTC
      expect(r.single.text, 'Heute: 2 Termine');
      expect(r.single.titel, 'Heute im Überblick');
      expect(r.single.payload, 'briefing');
      expect(istBriefingPayload(r.single.payload), isTrue);
      expect(istBriefingPayload('termin|x|y'), isFalse);
    });

    test('Text ist neutral: kein Titel, kein Name, auch nicht aus Aufgaben', () {
      final r = plan(
        kal([termin('t2', titel: 'Frauenarzt', start: '2026-10-20T08:00:00Z', ende: '2026-10-20T09:00:00Z')]),
        aufgaben: [aufgabe('a1', faellig: '2026-10-20', titel: 'Steuererklärung')],
      );
      expect(r.first.text, 'Heute: 1 Termin, 1 Aufgabe');
      expect(r.skip(1).every((e) => e.text == 'Heute: 1 Aufgabe'), isTrue, reason: 'die offene Aufgabe ist an den Folgetagen überfällig');
      for (final e in r) {
        expect(e.titel + e.text + e.payload, isNot(anyOf(contains('Frauenarzt'), contains('Steuer'))));
      }
    });

    test('Überfälliges wird an jedem folgenden Tag mitgezählt, die Zeit folgt der Wanduhr über die Zeitumstellung', () {
      final r = plan(kal(const []), aufgaben: [aufgabe('a1', faellig: '2026-10-15')], tage: 8);
      // heute 07:00 ist vorbei: 20. bis 26.10.
      expect(r, hasLength(7));
      expect(r.every((e) => e.text == 'Heute: 1 Aufgabe'), isTrue);
      expect(r.firstWhere((e) => e.zeit.day == 24).zeit, DateTime.utc(2026, 10, 24, 5)); // Sommerzeit
      expect(r.firstWhere((e) => e.zeit.day == 25).zeit, DateTime.utc(2026, 10, 25, 6)); // Winterzeit: 07:00 = 06:00 UTC
    });

    test('IDs sind stabil und je Tag verschieden; ungültige Zeit ergibt nichts', () {
      final a = plan(kal(const []), aufgaben: [aufgabe('a1', faellig: '2026-10-15')]);
      final b = plan(kal(const []), aufgaben: [aufgabe('a1', faellig: '2026-10-15')]);
      expect([for (final e in a) e.id], [for (final e in b) e.id]);
      expect({for (final e in a) e.id}.length, a.length);
      expect(plan(kal(const []), aufgaben: [aufgabe('a1', faellig: '2026-10-15')], minuten: 2000), isEmpty);
    });
  });
}
