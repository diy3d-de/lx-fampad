// Medikamenten-Plan, Teil 2: Planung der Einnahme-Erinnerungen (rein) und ihre Anbindung an den Erinnerungsdienst (gemeinsames Fenster, Schalter, Abgleich nach Abhaken).
// Verbindlich: lokal, neutraler Text (nie Name von Medikament, Dosis oder Person, auch nicht bei Kindern), genau eine erneute Erinnerung nach 15 Minuten solange nicht abgehakt, keine weitere Eskalation.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/medikamente/medikament_erinnerung.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:lx_fampad/data/medikamente/medikament_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const _ich = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _kind = 'cccccccc-0000-4000-8000-00000000000c';
const _uuid = 'dddddddd-0000-4000-8000-00000000000d';

var _n = 0;
String _id() => 'dddddddd-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}';

MedEintrag _e(MedikamentInhalt m, {String subjekt = _ich, List<EinnahmeAnsicht> einnahmen = const [], String? id}) =>
    MedEintrag(MedikamentAnsicht(id: id ?? _id(), konversationId: 'k', subjektId: subjekt, inhalt: m, erstelltAt: DateTime.utc(2026, 10, 1)), einnahmen);

MedikamentInhalt _m(String name, {List<String> zeiten = const ['08:00'], Rhythmus rhythmus = const Rhythmus.taeglich(), MedikamentZustand z = MedikamentZustand.aktiv, String beginn = '2026-10-01'}) => MedikamentInhalt(
  name: name,
  dosis: 'GeheimeDosis 5 mg',
  rhythmus: rhythmus,
  zeiten: rhythmus.festeZeiten ? zeiten : const [],
  beginn: beginn,
  zustand: z,
  zustandAb: z == MedikamentZustand.aktiv ? null : '2026-10-01',
);

EinnahmeAnsicht _ein(String geplant, DateTime um) => EinnahmeAnsicht(id: _id(), medikamentId: 'x', inhalt: EinnahmeInhalt(status: EinnahmeStatus.genommen, um: um, geplant: geplant), erstelltAt: um);

MedDaten _daten(List<MedEintrag> e, {String ich = _ich}) => MedDaten(geladen: true, ich: ich, ichRolle: Role.parent, eintraege: e);

List<GeplanteErinnerung> _plan(MedDaten d, DateTime jetzt, {int tage = 2}) => planeMedikamentErinnerungen(medDaten: d, jetzt: jetzt, tage: tage)..sort((a, b) => a.zeit.compareTo(b.zeit));

// Freitag, 23. Oktober 2026, 07:00 Uhr in Berlin (MESZ = UTC+2)
final _morgens = DateTime.utc(2026, 10, 23, 5, 0);

void main() {
  tzdata.initializeTimeZones();

  test('täglich: Alarm und genau eine Nachfass-Erinnerung nach 15 Minuten je Slot', () {
    final p = _plan(_daten([_e(_m('A', zeiten: ['08:00', '20:00']))]), _morgens, tage: 1);
    expect(p.map((x) => x.zeit), [DateTime.utc(2026, 10, 23, 6, 0), DateTime.utc(2026, 10, 23, 6, 15), DateTime.utc(2026, 10, 23, 18, 0), DateTime.utc(2026, 10, 23, 18, 15)]);
  });

  test('Text immer neutral: nie Name, Dosis oder Person; Kinder-Pläne mit "Zeit für Medikamente"; Nutzlast nur mit ID', () {
    final eigen = _e(_m('Blutdrucktablette'), id: _uuid);
    final kind = _e(_m('Nasenspray', zeiten: ['09:00']), subjekt: _kind);
    final p = _plan(_daten([eigen, kind]), _morgens, tage: 1);
    expect(p, hasLength(4));
    for (final x in p) {
      final alles = '${x.titel} ${x.text} ${x.payload}'.toLowerCase();
      for (final tabu in ['blutdruck', 'nasenspray', 'geheimedosis', 'mg', 'anna', 'kind']) {
        expect(alles.contains(tabu), isFalse, reason: '"$tabu" darf nie in der Erinnerung stehen: $alles');
      }
      expect(istMedikamentPayload(x.payload), isTrue);
    }
    expect(p.where((x) => x.titel == kMedTitelEigen), hasLength(2));
    expect(p.where((x) => x.titel == kMedTitelKind), hasLength(2));
    expect(kMedTitelEigen, 'Zeit für deine Medikamente');
    expect(kMedTitelKind, 'Zeit für Medikamente');
    expect(p.first.payload, 'medikament|$_uuid');
  });

  test('Kind-Plan auf dem Gerät eines Elternteils: Alarme für das Kind (Eltern planen für die Kinder-Pläne)', () {
    final p = _plan(_daten([_e(_m('K'), subjekt: _kind)]), _morgens, tage: 1);
    expect(p, hasLength(2));
    expect(p.every((x) => x.titel == kMedTitelKind), isTrue);
  });

  test('mehrere Medikamente zur selben Zeit und Person ergeben EINE Erinnerung', () {
    final p = _plan(_daten([_e(_m('A')), _e(_m('B')), _e(_m('C'))]), _morgens, tage: 1);
    expect(p, hasLength(2));
  });

  test('Eltern-Gerät: eigener und Kind-Slot zur selben Zeit sind zwei Erinnerungen (getrennte Personen)', () {
    final p = _plan(_daten([_e(_m('A')), _e(_m('B'), subjekt: _kind)]), _morgens, tage: 1);
    expect(p, hasLength(4));
    expect(p.map((x) => x.id).toSet(), hasLength(4));
  });

  test('abgehakt: der Slot hat keine Alarme mehr (auch nicht die Nachfass-Erinnerung); die anderen bleiben', () {
    final m = _m('A', zeiten: ['08:00', '20:00']);
    final e = _e(m, einnahmen: [_ein('2026-10-23T08:00', DateTime.utc(2026, 10, 23, 5, 59))]);
    final p = _plan(_daten([e]), DateTime.utc(2026, 10, 23, 5, 59), tage: 1);
    expect(p.map((x) => x.zeit), [DateTime.utc(2026, 10, 23, 18, 0), DateTime.utc(2026, 10, 23, 18, 15)]);
  });

  test('nach dem Alarm, vor der Nachfass-Zeit und nicht abgehakt: nur noch die Nachfass-Erinnerung; danach keine weitere Eskalation', () {
    final e = _e(_m('A'));
    // 08:05 Uhr (06:05 UTC): Alarm vorbei, Nachfass 08:15 steht an
    expect(_plan(_daten([e]), DateTime.utc(2026, 10, 23, 6, 5), tage: 1).map((x) => x.zeit), [DateTime.utc(2026, 10, 23, 6, 15)]);
    // 08:16: nichts mehr (kein dritter Alarm)
    expect(_plan(_daten([e]), DateTime.utc(2026, 10, 23, 6, 16), tage: 1), isEmpty);
  });

  test('Wochentage, Intervall, bei Bedarf, pausiert, beendet', () {
    final mo = _e(_m('Mo', rhythmus: Rhythmus.wochentage({1}))); // Montag: heute (Freitag) nicht, am 26.
    final fr = _e(_m('Fr', rhythmus: Rhythmus.wochentage({5}), zeiten: ['09:00']));
    final alle2 = _e(_m('N', rhythmus: Rhythmus.intervall(2, ab: '2026-10-22'), zeiten: ['10:00'])); // 22., 24., ...
    final bedarf = _e(_m('B', rhythmus: const Rhythmus.bedarf()));
    final pause = _e(_m('P', z: MedikamentZustand.pausiert, zeiten: ['11:00']));
    final ende = _e(_m('E', z: MedikamentZustand.beendet, zeiten: ['12:00']));
    final p = _plan(_daten([mo, fr, alle2, bedarf, pause, ende]), _morgens, tage: 3); // 23., 24., 25.
    final zeiten = p.map((x) => x.zeit).toList();
    expect(zeiten, [
      DateTime.utc(2026, 10, 23, 7, 0), // Fr 09:00
      DateTime.utc(2026, 10, 23, 7, 15),
      DateTime.utc(2026, 10, 24, 8, 0), // N alle 2 Tage: Samstag 10:00 (MESZ)
      DateTime.utc(2026, 10, 24, 8, 15),
    ]);
  });

  test('Sommerzeit-Ende: Uhrzeit bleibt Wanduhr (08:00 vor und nach dem 25.10.2026)', () {
    final p = _plan(_daten([_e(_m('A'))]), DateTime.utc(2026, 10, 24, 5, 0), tage: 3);
    final alarme = p.where((x) => x.zeit.minute == 0).map((x) => x.zeit).toList();
    expect(alarme, [DateTime.utc(2026, 10, 24, 6, 0), DateTime.utc(2026, 10, 25, 7, 0), DateTime.utc(2026, 10, 26, 7, 0)]);
  });

  test('Fenster-Grenze: mit anderen Erinnerungen im gemeinsamen Fenster nach Zeit sortiert; über 300 kommt der Hinweis "laufen aus"', () {
    final med = _plan(_daten([_e(_m('A', zeiten: ['08:00', '12:00', '16:00', '20:00']))]), _morgens, tage: 5);
    expect(med, hasLength(40));
    final alle = planeErinnerungen(daten: const KalenderDaten(), ich: _ich, jetzt: _morgens, zusatz: med);
    expect(alle, hasLength(40));
    expect([for (var i = 1; i < alle.length; i++) alle[i - 1].zeit.compareTo(alle[i].zeit) <= 0].every((b) => b), isTrue);
    final eng = planeErinnerungen(daten: const KalenderDaten(), ich: _ich, jetzt: _morgens, zusatz: med, maxAnzahl: 10);
    expect(eng, hasLength(11));
    expect(eng.last.id, kAuslaufHinweisPlanId);
  });

  test('ohne geladene Daten oder ohne Person nichts (kein Alarm aus einem Halbwissen)', () {
    expect(planeMedikamentErinnerungen(medDaten: const MedDaten(ich: _ich), jetzt: _morgens), isEmpty);
    expect(planeMedikamentErinnerungen(medDaten: MedDaten(geladen: true, eintraege: [_e(_m('A'))]), jetzt: _morgens), isEmpty);
  });

  test('nicht lesbare Pläne ergeben keine Erinnerung', () {
    final kaputt = MedEintrag(MedikamentAnsicht(id: _id(), konversationId: 'k', subjektId: _ich, inhalt: null, erstelltAt: DateTime.utc(2026)), const []);
    expect(_plan(_daten([kaputt]), _morgens), isEmpty);
  });

  test('Nutzlast: nur medikament|<UUID>', () {
    expect(istMedikamentPayload('medikament|$_uuid'), isTrue);
    expect(istMedikamentPayload('medikament|Blutdruck'), isFalse);
    expect(istMedikamentPayload('medikament'), isFalse);
    expect(istMedikamentPayload('termin|$_uuid|2026-10-23'), isFalse);
    expect(istMedikamentPayload(null), isFalse);
  });
}
