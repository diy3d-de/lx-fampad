// Stumm je Person und Distanzfilter: reine Logik (Lesen/Schreiben der lokalen Werte, Haversine-Filter) und der Speicher in sync_meta.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/database_provider.dart';
import 'package:lx_fampad/data/standort/standort_einstellungen.dart';
import 'package:lx_fampad/data/standort/standort_modelle.dart';
import 'package:lx_fampad/data/standort/standort_port.dart';

void main() {
  final jetzt = DateTime.utc(2026, 10, 20, 12);
  GeteiltePosition p(String id, {double? lat, double? lon}) =>
      GeteiltePosition(userId: id, shareId: 's-$id', endetAt: jetzt.add(const Duration(hours: 1)), breite: lat, laenge: lon, genauigkeit: 10, messzeit: lat == null ? null : jetzt);
  final ich = GeraetePosition(breite: 48.0, laenge: 11.0, zeit: jetzt);

  group('Stumm: Werte', () {
    test('Hin und zurück, sortiert; kaputte oder fremde Werte ergeben niemand', () {
      expect(stummAusWert(stummZuWert({'b', 'a'})), {'a', 'b'});
      expect(stummZuWert({'b', 'a'}), '["a","b"]');
      for (final w in [null, '', 'kaputt', '{"a":1}', '42']) {
        expect(stummAusWert(w), isEmpty, reason: '$w');
      }
      expect(stummAusWert('["a",3,"",null,"b"]'), {'a', 'b'});
    });
  });

  group('Distanzfilter', () {
    // 0,001 Grad Breite = rund 111 m
    final nah = p('nah', lat: 48.002, lon: 11.0); // ~222 m
    final mittel = p('mittel', lat: 48.03, lon: 11.0); // ~3,3 km
    final fern = p('fern', lat: 49.0, lon: 11.0); // ~111 km
    final ohne = p('ohne');

    test('ohne Filter oder ohne eigenen Standort bleibt alles stehen, nichts wird ausgeblendet', () {
      final alle = [nah, mittel, fern, ohne];
      expect(filterNachDistanz(alle, ich, DistanzFilter.alle).sichtbar, alle);
      final r = filterNachDistanz(alle, null, DistanzFilter.km1);
      expect(r.sichtbar, alle);
      expect(r.ausgeblendet, 0);
    });

    test('1, 5 und 25 km: nur wer innerhalb liegt; Einträge ohne Position fallen bei aktivem Filter weg und werden mitgezählt', () {
      final alle = [nah, mittel, fern, ohne];
      var r = filterNachDistanz(alle, ich, DistanzFilter.km1);
      expect(r.sichtbar.map((x) => x.userId), ['nah']);
      expect(r.ausgeblendet, 3);
      r = filterNachDistanz(alle, ich, DistanzFilter.km5);
      expect(r.sichtbar.map((x) => x.userId), ['nah', 'mittel']);
      r = filterNachDistanz(alle, ich, DistanzFilter.km25);
      expect(r.sichtbar.map((x) => x.userId), ['nah', 'mittel']);
      expect(r.ausgeblendet, 2);
    });

    test('Grenze: knapp innen zählt, knapp außen nicht (Haversine, Meter)', () {
      // Punkte auf demselben Längengrad, rund 990 m und 1100 m entfernt
      final innen = p('innen', lat: 48.0 + 990 / 111195, lon: 11.0);
      final aussen = p('aussen', lat: 48.0 + 1100 / 111195, lon: 11.0);
      final r = filterNachDistanz([innen, aussen], ich, DistanzFilter.km1);
      expect(r.sichtbar.map((x) => x.userId), ['innen']);
    });

    test('Werte und Beschriftungen', () {
      expect(distanzAusWert('km5'), DistanzFilter.km5);
      for (final w in [null, '', 'xyz']) {
        expect(distanzAusWert(w), DistanzFilter.alle);
      }
      expect(DistanzFilter.values.map((f) => f.label), ['Alle', 'unter 1 km', 'unter 5 km', 'unter 25 km']);
      expect(entfernungText(350), '350 m');
      expect(entfernungText(4200), '4,2 km');
    });
  });

  group('Speicher in sync_meta', () {
    late AppDatabase db;
    late ProviderContainer c;

    setUp(() {
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      c = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Future<void> geladen(ProviderContainer k) async {
      k.read(standortEinstellungenProvider);
      for (var i = 0; i < 100 && !k.read(standortEinstellungenProvider).geladen; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('Stumm und Filter werden lokal gemerkt und beim nächsten Start gelesen', () async {
      await geladen(c);
      expect(c.read(standortEinstellungenProvider).stumm, isEmpty);
      final n = c.read(standortEinstellungenProvider.notifier);
      await n.stummSetzen('u1', true);
      await n.stummSetzen('u2', true);
      await n.stummSetzen('u1', false);
      await n.distanzSetzen(DistanzFilter.km25);
      expect(await db.metaLesen(kStandortStummSchluessel), '["u2"]');
      expect(await db.metaLesen(kStandortDistanzSchluessel), 'km25');

      final c2 = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(c2.dispose);
      await geladen(c2);
      final e = c2.read(standortEinstellungenProvider);
      expect(e.istStumm('u2'), isTrue);
      expect(e.istStumm('u1'), isFalse);
      expect(e.distanz, DistanzFilter.km25);
    });
  });

  group('Gesamtlimit: Rechenvorschrift', () {
    test('frühestes Limit: je Anfrage 12 Stunden ab jetzt, insgesamt 24 Stunden ab Start', () {
      final start = DateTime.utc(2026, 10, 20, 8);
      expect(standortFruehestesLimit(beginn: start, jetzt: start), start.add(const Duration(hours: 12)));
      expect(standortFruehestesLimit(beginn: start, jetzt: start.add(const Duration(hours: 11))), start.add(const Duration(hours: 23)));
      expect(standortFruehestesLimit(beginn: start, jetzt: start.add(const Duration(hours: 13))), start.add(kStandortGesamtdauer));
      expect(standortGesamtlimitText(), 'Länger als 24 Stunden seit dem Start geht nicht. Starte danach neu.');
    });
  });
}
