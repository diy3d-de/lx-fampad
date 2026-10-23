// Wandtablet-Modus: reine Logik (Blöcke und Spalten, Dimm-Fenster, Verschiebung, Texte, Aufgabenauswahl, Heute/Morgen) und Speicher der Einstellungen.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart';
import 'package:lx_fampad/data/wandtablet/wandtablet_einstellungen.dart';
import 'package:lx_fampad/data/wandtablet/wandtablet_logik.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

Aufgabe _a(String id, {String? tag, DateTime? utc, DateTime? erledigt}) => Aufgabe(
  id: id,
  frist: false,
  titel: 'Aufgabe $id',
  beschreibung: '',
  faelligDate: tag,
  faelligUtc: utc,
  tzid: utc == null ? null : 'Europe/Berlin',
  prioritaet: 0,
  assigneeId: null,
  erledigtAt: erledigt,
  erledigtVon: null,
  wiederholung: null,
  erinnerungMin: null,
  audience: 'family',
  ownerId: null,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

Vorkommen _v(String id, DateTime startWand, {bool ganztaegig = false}) => Vorkommen(
  termin: Termin(
    id: id,
    titel: id,
    ort: '',
    beschreibung: '',
    ganztaegig: ganztaegig,
    startUtc: startWand,
    endUtc: startWand.add(const Duration(hours: 1)),
    tzid: 'Europe/Berlin',
    startDate: null,
    endDate: null,
    rrule: null,
    erinnerungMin: null,
    icalUid: null,
    audience: 'family',
    ownerId: null,
    createdAt: DateTime.utc(2026, 10, 1),
    rev: 1,
  ),
  schluessel: id,
  ganztaegig: ganztaegig,
  startWand: startWand,
  endeWand: startWand.add(const Duration(hours: 1)),
  startUtc: startWand,
  titel: id,
  ort: '',
  geaendert: false,
  serie: false,
  originalStartWand: startWand,
  originalEndeWand: startWand.add(const Duration(hours: 1)),
  originalStartUtc: startWand,
);

void main() {
  tzdata.initializeTimeZones();

  group('Blöcke und Spalten', () {
    test('Termine und Aufgaben immer, der Rest nur bei Inhalt, feste Reihenfolge', () {
      expect(sichtbareBloecke(), [WandBlock.termine, WandBlock.aufgaben]);
      expect(sichtbareBloecke(einkauf: true, wetter: true, muell: true, countdown: true, fristen: true), WandBlock.values);
      expect(sichtbareBloecke(wetter: true, fristen: true), [WandBlock.termine, WandBlock.aufgaben, WandBlock.fristen, WandBlock.wetter]);
    });

    test('Spaltenzahl nach Breite: 1 bis 899, 2 ab 900, 3 ab 1200', () {
      expect([for (final b in [360.0, 899.0, 900.0, 1024.0, 1199.0, 1200.0, 1280.0]) wandSpalten(b)], [1, 1, 2, 2, 2, 3, 3]);
    });

    test('Verteilung: Termine allein in Spalte 1, Rest reihum, keine leeren Spalten', () {
      final alle = sichtbareBloecke(einkauf: true, wetter: true, muell: true, countdown: true, fristen: true);
      expect(verteileSpalten(alle, 3), [
        [WandBlock.termine],
        [WandBlock.aufgaben, WandBlock.countdown, WandBlock.wetter],
        [WandBlock.fristen, WandBlock.muell, WandBlock.einkauf],
      ]);
      expect(verteileSpalten(alle, 2), [
        [WandBlock.termine],
        [WandBlock.aufgaben, WandBlock.fristen, WandBlock.countdown, WandBlock.muell, WandBlock.wetter, WandBlock.einkauf],
      ]);
      expect(verteileSpalten(alle, 1), [alle]);
      expect(verteileSpalten(sichtbareBloecke(), 3), [
        [WandBlock.termine],
        [WandBlock.aufgaben],
      ]);
      expect(verteileSpalten(const [WandBlock.termine], 3), [
        [WandBlock.termine],
      ]);
    });
  });

  group('Dimmen und Einbrenn-Schutz', () {
    // Winter: Berlin = UTC+1
    test('Nacht ist 22 bis unter 6 Uhr Wanduhr der Familienzone', () {
      expect(istNacht(DateTime.utc(2026, 1, 15, 20, 59)), isFalse); // 21:59
      expect(istNacht(DateTime.utc(2026, 1, 15, 21, 0)), isTrue); // 22:00
      expect(istNacht(DateTime.utc(2026, 1, 16, 4, 59)), isTrue); // 05:59
      expect(istNacht(DateTime.utc(2026, 1, 16, 5, 0)), isFalse); // 06:00
      expect(istNacht(DateTime.utc(2026, 1, 15, 11, 0)), isFalse);
    });

    test('Sommerzeit: dieselbe Wanduhr, andere UTC-Zeit', () {
      expect(istNacht(DateTime.utc(2026, 7, 15, 19, 59)), isFalse); // 21:59 MESZ
      expect(istNacht(DateTime.utc(2026, 7, 15, 20, 0)), isTrue); // 22:00 MESZ
    });

    test('Abdunklung nur mit Schalter und nachts', () {
      final nacht = DateTime.utc(2026, 1, 15, 23);
      final tag = DateTime.utc(2026, 1, 15, 11);
      expect(dimmDeckkraft(nacht, dimmen: true), kWandNachtDeckkraft);
      expect(dimmDeckkraft(nacht, dimmen: false), 0);
      expect(dimmDeckkraft(tag, dimmen: true), 0);
    });

    test('Verschiebung: stabil im Fenster, wechselt alle 5 Minuten, höchstens 6 Pixel, mehrere Punkte', () {
      final t0 = DateTime.utc(2026, 10, 23, 10, 0);
      expect(verschiebung(t0), verschiebung(t0.add(const Duration(minutes: 4, seconds: 59))));
      expect(verschiebung(t0), isNot(verschiebung(t0.add(const Duration(minutes: 5)))));
      final punkte = <({int dx, int dy})>{};
      for (var i = 0; i < 40; i++) {
        final v = verschiebung(t0.add(Duration(minutes: 5 * i)));
        expect(v.dx.abs() <= kWandVerschiebeMax && v.dy.abs() <= kWandVerschiebeMax, isTrue);
        punkte.add(v);
      }
      expect(punkte.length, greaterThanOrEqualTo(8));
    });
  });

  group('Texte', () {
    test('Uhr in der Familienzone', () => expect(wandUhrText(DateTime.utc(2026, 1, 15, 8, 5)), '09:05'));

    test('Offline seit: heute mit Uhrzeit, früher mit Datum, ohne Abgleich nur "Offline"', () {
      final jetzt = DateTime.utc(2026, 10, 23, 12);
      expect(offlineText(DateTime.utc(2026, 10, 23, 10, 32), jetzt), 'Offline seit 12:32');
      expect(offlineText(DateTime.utc(2026, 10, 12, 13, 2), jetzt), 'Offline seit 12.10. 15:02');
      expect(offlineText(null, jetzt), 'Offline');
    });
  });

  group('Auswahl', () {
    final jetzt = DateTime.utc(2026, 10, 23, 8); // 10:00 Berlin
    test('Aufgaben: heute fällig und überfällig, nicht erledigt, nicht später; nach Fälligkeit (Ältestes zuerst)', () {
      final l = wandAufgaben([
        _a('spaeter', tag: '2026-10-24'),
        _a('heute', tag: '2026-10-23'),
        _a('alt', tag: '2026-10-20'),
        _a('ohne'),
        _a('fertig', tag: '2026-10-23', erledigt: DateTime.utc(2026, 10, 23)),
        _a('zeitHeute', utc: DateTime.utc(2026, 10, 23, 15)),
        _a('zeitVorbei', utc: DateTime.utc(2026, 10, 23, 5)),
      ], jetzt);
      expect([for (final a in l) a.id], ['alt', 'heute', 'zeitVorbei', 'zeitHeute']);
    });

    test('Heute und morgen: laufende und heutige zu heute, spätere zu morgen, Reihenfolge bleibt', () {
      final heute = DateTime.utc(2026, 10, 23);
      final t = teileHeuteMorgen([
        _v('a', DateTime.utc(2026, 10, 23, 9)),
        _v('b', DateTime.utc(2026, 10, 22, 23)), // über Mitternacht, beginnt gestern
        _v('c', DateTime.utc(2026, 10, 24, 8)),
        _v('d', DateTime.utc(2026, 10, 24), ganztaegig: true),
      ], heute);
      expect([for (final v in t.heute) v.schluessel], ['a', 'b']);
      expect([for (final v in t.morgen) v.schluessel], ['c', 'd']);
    });
  });

  group('Einstellungen (lokal in sync_meta)', () {
    ProviderContainer container(MemoryFeiertageSpeicher s) {
      final c = ProviderContainer(overrides: [feiertageSpeicherProvider.overrideWithValue(s)]);
      addTearDown(c.dispose);
      return c;
    }

    test('Standard: Autostart aus, Dimmen an, keine Liste; erst nach dem Lesen "geladen"', () async {
      final c = container(MemoryFeiertageSpeicher());
      c.listen(wandtabletEinstellungenProvider, (_, _) {});
      expect(c.read(wandtabletEinstellungenProvider).geladen, isFalse);
      await Future<void>.delayed(Duration.zero);
      final e = c.read(wandtabletEinstellungenProvider);
      expect((e.geladen, e.autostart, e.dimmen, e.liste), (true, false, true, null));
    });

    test('Schalter bleiben gemerkt (neuer Container liest sie wieder)', () async {
      final s = MemoryFeiertageSpeicher();
      final c = container(s);
      c.listen(wandtabletEinstellungenProvider, (_, _) {});
      final n = c.read(wandtabletEinstellungenProvider.notifier);
      await n.autostartSetzen(true);
      await n.dimmenSetzen(false);
      await n.listeSetzen('liste-1');
      expect(s.werte[kWandAutostartSchluessel], 'ja');
      expect(s.werte[kWandDimmenSchluessel], 'nein');
      final c2 = container(s);
      c2.listen(wandtabletEinstellungenProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      final e = c2.read(wandtabletEinstellungenProvider);
      expect((e.autostart, e.dimmen, e.liste), (true, false, 'liste-1'));
      await c2.read(wandtabletEinstellungenProvider.notifier).listeSetzen(null);
      expect(s.werte.containsKey(kWandListeSchluessel), isFalse);
    });

    test('Änderung vor dem Lesen wartet auf den gespeicherten Stand und überschreibt ihn nicht', () async {
      final s = MemoryFeiertageSpeicher(null, {kWandDimmenSchluessel: 'nein', kWandListeSchluessel: 'x'});
      final c = container(s);
      c.listen(wandtabletEinstellungenProvider, (_, _) {});
      await c.read(wandtabletEinstellungenProvider.notifier).autostartSetzen(true);
      final e = c.read(wandtabletEinstellungenProvider);
      expect((e.autostart, e.dimmen, e.liste), (true, false, 'x'));
    });
  });
}
