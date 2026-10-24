// Zähler (Teil 2): Ablese-Erinnerungen. Reine Planung (neutral, 09:00 am Ablesetag, ein Alarm je Tag, nichts für archivierte oder abgelesene, nur mit Daten und Recht) und der Dienst
// (nur Eltern und Admins, eigener Schalter, ohne geladene Daten wird nichts angefasst, Tipp öffnet die Übersicht ohne Inhalt in der Nutzlast).
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/zaehler/zaehler_erinnerung.dart';
import 'package:lx_fampad/data/zaehler/zaehler_hinweis.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart' show MonatsWert, Stand;
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart';
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/harness.dart' show angemeldeteUmgebung;
import 'support/test_app.dart';
import 'support/zaehler_welt.dart';

// Montag, 19. Oktober 2026, 07:00 Uhr in Berlin
final jetzt = DateTime.utc(2026, 10, 19, 5);

Stand st(int j, int m, int d, num w) => Stand(DateTime.utc(j, m, d), (w * 1000).round());

ZaehlerBeispiel monatlichAm(int tag, {List<Stand>? staende, String id = zStrom, ZaehlerArt art = ZaehlerArt.strom, String? archiviert}) => ZaehlerBeispiel(
  id,
  ZaehlerInhalt(art: art, name: 'Zähler $tag', ablesung: Ablesung.monatlich(tag), archiviertAb: archiviert),
  staende ?? [st(2026, 9, 10, 100)],
);

List<DateTime> zeiten(List<dynamic> l) => [for (final e in l) e.zeit as DateTime];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  group('Planung', () {
    test('monatlich am 5.: Alarme am 5.11. und 5.12. um 09:00 Berlin, Text neutral, Nutzlast ohne Inhalt', () {
      final p = planeZaehlerErinnerungen(daten: datenAus([monatlichAm(5)]), jetzt: jetzt);
      expect(p, hasLength(2));
      expect(wandUhr(p[0].zeit, familienOrt), DateTime.utc(2026, 11, 5, 9));
      expect(wandUhr(p[1].zeit, familienOrt), DateTime.utc(2026, 12, 5, 9));
      for (final x in p) {
        expect(x.titel, kZaehlerTitel);
        expect(x.text, kZaehlerErinnerungText);
        expect(x.payload, kZaehlerPayload);
        expect('${x.titel}${x.text}${x.payload}'.contains(RegExp('Strom|Wasser|Gas|kWh|Stand|Zähler 5|100', caseSensitive: false)), isFalse, reason: 'nichts über Art oder Stand');
      }
      expect(istZaehlerPayload(p.first.payload), isTrue);
      expect(istZaehlerPayload('zaehler|abc'), isFalse);
      expect(istZaehlerPayload(null), isFalse);
    });

    test('der Alarm von heute entfällt, wenn 09:00 schon vorbei ist, und bleibt, wenn sie noch kommt', () {
      // 19.10., 09:00 liegt nach 07:00: noch da
      expect(planeZaehlerErinnerungen(daten: datenAus([monatlichAm(19)]), jetzt: jetzt).first.zeit, DateTime.utc(2026, 10, 19, 7));
      // 10:00 Berlin: vorbei
      final spaet = DateTime.utc(2026, 10, 19, 8);
      expect(wandUhr(planeZaehlerErinnerungen(daten: datenAus([monatlichAm(19)]), jetzt: spaet).first.zeit, familienOrt).month, 11);
    });

    test('mehrere Zähler am selben Tag ergeben einen Alarm', () {
      final p = planeZaehlerErinnerungen(daten: datenAus([monatlichAm(5), monatlichAm(5, id: zKalt1, art: ZaehlerArt.kaltwasser)]), jetzt: jetzt);
      expect(p, hasLength(2)); // 5.11. und 5.12., nicht doppelt
      expect(p.map((x) => x.id).toSet(), hasLength(2));
    });

    test('schon abgelesen seit dem Solltermin: kein Alarm für diesen Tag (Jahresablesung), der nächste bleibt', () {
      final z = ZaehlerBeispiel(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'S', ablesung: const Ablesung.jaehrlich(monat: 10, tag: 25)), [st(2026, 10, 25, 1)]);
      final p = planeZaehlerErinnerungen(daten: datenAus([z]), jetzt: jetzt);
      expect(p, hasLength(1));
      expect(wandUhr(p.single.zeit, familienOrt), DateTime.utc(2027, 10, 25, 9)); // innerhalb von 400 Tagen
    });

    test('archivierte Zähler und Zähler ohne Rhythmus erinnern nie', () {
      expect(planeZaehlerErinnerungen(daten: datenAus([monatlichAm(5, archiviert: '2026-01-01')]), jetzt: jetzt), isEmpty);
      expect(planeZaehlerErinnerungen(daten: datenAus([strom(ablesung: null)]), jetzt: jetzt), isEmpty);
    });

    test('ohne Recht, ohne geladene Daten oder ohne Zähler: nichts', () {
      expect(planeZaehlerErinnerungen(daten: datenAus([monatlichAm(5)], darf: false), jetzt: jetzt), isEmpty);
      expect(planeZaehlerErinnerungen(daten: datenAus([monatlichAm(5)], geladen: false), jetzt: jetzt), isEmpty);
      expect(planeZaehlerErinnerungen(daten: datenAus(const []), jetzt: jetzt), isEmpty);
    });

    test('Horizont: monatlich 75 Tage, Jahresablesung 400 Tage; stabile IDs; die Termine am 31. fallen in kurzen Monaten auf den letzten Tag', () {
      final p = planeZaehlerErinnerungen(daten: datenAus([monatlichAm(1)]), jetzt: jetzt);
      expect(p.length, inInclusiveRange(2, 3));
      expect(p.last.zeit.isBefore(jetzt.add(const Duration(days: 76))), isTrue);
      final p2 = planeZaehlerErinnerungen(daten: datenAus([monatlichAm(1)]), jetzt: jetzt);
      expect([for (final x in p) x.id], [for (final x in p2) x.id]);
      final ende = ablesetermine(const Ablesung.monatlich(31), DateTime.utc(2026, 2, 1), DateTime.utc(2026, 4, 30));
      expect(ende, [DateTime.utc(2026, 2, 28), DateTime.utc(2026, 3, 31), DateTime.utc(2026, 4, 30)]);
    });
  });

  group('Monatswerte', () {
    ZaehlerBeispiel solarOkt({bool oktober = false, String? archiviert}) => ZaehlerBeispiel(
      zSolar,
      ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Balkon', modus: ZaehlerModus.monat, archiviertAb: archiviert),
      const [],
      [
        MonatsWert(jahr: 2026, monat: 8, milli: 30000, id: 'a'),
        MonatsWert(jahr: 2026, monat: 9, milli: 40000, id: 'b'),
        if (oktober) MonatsWert(jahr: 2026, monat: 10, milli: 5000, id: 'c'),
      ],
    );

    test('am Monatsersten um 09:00 Berlin, solange der Vormonat fehlt; derselbe neutrale Text', () {
      final p = planeZaehlerErinnerungen(daten: datenAus([solarOkt()]), jetzt: jetzt);
      expect([for (final x in p) wandUhr(x.zeit, familienOrt)], [DateTime.utc(2026, 11, 1, 9), DateTime.utc(2026, 12, 1, 9), DateTime.utc(2027, 1, 1, 9)]);
      for (final x in p) {
        expect(x.titel, kZaehlerTitel);
        expect(x.text, kZaehlerErinnerungText);
        expect(x.payload, kZaehlerPayload);
      }
    });

    test('ist der Vormonat schon eingetragen, entfällt dieser Alarm; archivierte erinnern nie; Zählerstand-Zähler am selben Tag ergeben nur einen Alarm', () {
      final p = planeZaehlerErinnerungen(daten: datenAus([solarOkt(oktober: true)]), jetzt: jetzt);
      expect([for (final x in p) wandUhr(x.zeit, familienOrt).month], [12, 1]);
      expect(planeZaehlerErinnerungen(daten: datenAus([solarOkt(archiviert: '2026-09-30')]), jetzt: jetzt), isEmpty);
      final beide = planeZaehlerErinnerungen(daten: datenAus([solarOkt(), monatlichAm(1)]), jetzt: jetzt);
      expect(beide.where((x) => wandUhr(x.zeit, familienOrt).day == 1 && wandUhr(x.zeit, familienOrt).month == 12), hasLength(1));
    });
  });

  group('Dienst', () {
    late TestUmgebung env;
    late FakeErinnerungPort port;
    late MemoryErinnerungSpeicher speicher;
    late ProviderContainer c;
    late NotifierProvider<TestZaehlerDaten, ZaehlerDaten> testDaten;

    Future<void> bis(bool Function() bedingung, {String grund = 'Bedingung'}) async {
      for (var i = 0; i < 100; i++) {
        if (bedingung()) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('Zeitüberschreitung: $grund');
    }

    Future<void> ruhe() async {
      var n = -1;
      for (var i = 0; i < 20 && n != port.planungen.length + port.geloescht; i++) {
        n = port.planungen.length + port.geloescht;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }

    List<String> zAlarme() => [for (final x in port.letzte ?? const []) if (istZaehlerPayload(x.payload)) x.titel];

    Future<void> starten({required ZaehlerDaten daten, String rolle = 'admin'}) async {
      env = await angemeldeteUmgebung(role: rolle);
      port = FakeErinnerungPort();
      speicher = MemoryErinnerungSpeicher();
      testDaten = NotifierProvider<TestZaehlerDaten, ZaehlerDaten>(() => TestZaehlerDaten(daten));
      env.extraOverrides.addAll([
        erinnerungPortProvider.overrideWithValue(port),
        erinnerungSpeicherProvider.overrideWithValue(speicher),
        erinnerungUhrProvider.overrideWithValue(() => jetzt),
        erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
        erinnerungWiederholenProvider.overrideWithValue(const Duration(milliseconds: 150)),
        zaehlerDatenProvider.overrideWith((ref) => ref.watch(testDaten)),
      ]);
      c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      c.listen(erinnerungSteuerungProvider, (_, _) {});
      await bis(() => port.planungen.isNotEmpty || port.geloescht > 0, grund: 'erste Planung');
      await ruhe();
    }

    test('Admin und Elternteil bekommen die Alarme; der Schalter "Zähler-Erinnerungen" nimmt sie weg (Standard an)', () async {
      await starten(daten: datenAus([monatlichAm(5)]));
      expect(zAlarme(), hasLength(2));
      expect(c.read(erinnerungEinstellungenProvider).zaehlerAn, isTrue);
      await c.read(erinnerungEinstellungenProvider.notifier).zaehlerAnSetzen(false);
      await bis(() => zAlarme().isEmpty, grund: 'Alarme weg');
      await c.read(erinnerungEinstellungenProvider.notifier).zaehlerAnSetzen(true);
      await bis(() => zAlarme().length == 2, grund: 'Alarme wieder da');
    });

    test('Elternteil: ebenfalls', () async {
      await starten(daten: datenAus([monatlichAm(5)]), rolle: 'parent');
      expect(zAlarme(), hasLength(2));
    });

    test('Kind: nie ein Alarm, auch wenn Daten da wären (der Dienst liest sie gar nicht)', () async {
      await starten(daten: datenAus([monatlichAm(5)]), rolle: 'child');
      expect(zAlarme(), isEmpty);
      expect((port.letzte ?? const []).any((x) => istZaehlerPayload(x.payload)), isFalse);
    });

    test('Daten noch nicht geladen: der Dienst rührt die Zähler-Alarme nicht an (kein leeres Fenster, das Alarme löscht)', () async {
      await starten(daten: datenAus([monatlichAm(5)]));
      final n = port.planungen.length;
      final g = port.geloescht;
      c.read(testDaten.notifier).setzen(datenAus(const [], geladen: false));
      await ruhe();
      expect(port.planungen.length, n);
      expect(port.geloescht, g);
      expect(zAlarme(), hasLength(2), reason: 'die alten Alarme bleiben stehen');
      c.read(testDaten.notifier).setzen(datenAus([monatlichAm(5)]));
      await ruhe();
      expect(zAlarme(), hasLength(2));
    });

    test('der Tipp auf eine Zähler-Erinnerung öffnet die Übersicht (Anforderung hochgezählt, ohne Inhalt)', () async {
      await starten(daten: datenAus([monatlichAm(5)]));
      final vorher = c.read(zaehlerOeffnenProvider);
      port.tippe(kZaehlerPayload);
      await bis(() => c.read(zaehlerOeffnenProvider) == vorher + 1, grund: 'Anforderung');
      port.tippe('zaehler|fremd'); // keine gültige Nutzlast: nichts
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(zaehlerOeffnenProvider), vorher + 1);
    });
  });
}
