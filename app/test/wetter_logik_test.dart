// Reine Wetter-Logik: gefühlte Temperatur, Taupunkt, Trends, Vergleich Heute/Gestern, Wochenextreme, Regen je Stunde, Hinweise; Modell (tolerant, ältere Server).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/wetter/wetter_logik.dart';

WetterStunden _stunden({
  List<double?>? t,
  List<double?>? druck,
  List<double?>? regen,
  int n = 24,
}) {
  List<double?> leer() => List<double?>.filled(n, null);
  return WetterStunden(
    von: DateTime.utc(2026, 10, 23, 13),
    temperatur: t ?? leer(),
    feuchte: leer(),
    druck: druck ?? leer(),
    regen: regen ?? leer(),
    wind: leer(),
    boeen: leer(),
    richtung: leer(),
  );
}

WetterDto _dto({
  double? temp,
  double? feuchte,
  double? wind,
  double? boeen,
  double? regen1h,
  bool veraltet = false,
  WetterStunden? stunden,
  List<WetterTag> tage = const [],
  List<WetterSonne> sonne = const [],
}) => WetterDto(
  verfuegbar: true,
  ort: 'X',
  aktuell: WetterAktuell(gemessen: DateTime.utc(2026, 10, 24, 12), veraltet: veraltet, temperatur: temp, feuchte: feuchte, windKmh: wind, boeKmh: boeen, regen1h: regen1h),
  stunden: stunden,
  tage: tage,
  sonne: sonne,
);

void main() {
  group('gefühlte Temperatur', () {
    test('Windchill bei höchstens 10 °C und Wind über 4,8 km/h (-5 °C, 20 km/h ergibt etwa -11,5 °C)', () {
      expect(gefuehlteTemperatur(temperatur: -5, windKmh: 20), closeTo(-11.55, 0.1));
      expect(gefuehlteTemperatur(temperatur: 10, windKmh: 30)!, lessThan(10));
    });
    test('kein Windchill über 10 °C, bei Wind bis 4,8 km/h oder ohne Wind', () {
      expect(gefuehlteTemperatur(temperatur: 12, windKmh: 20), 12);
      expect(gefuehlteTemperatur(temperatur: 5, windKmh: 4.8), 5);
      expect(gefuehlteTemperatur(temperatur: 5), 5);
    });
    test('Hitzeindex ab 27 °C und 40 % Feuchte (32 °C bei 70 %: etwa 41 °C)', () {
      final hi = gefuehlteTemperatur(temperatur: 32, feuchte: 70)!;
      expect(hi, inInclusiveRange(39.5, 42.5));
      expect(gefuehlteTemperatur(temperatur: 35, feuchte: 50)!, inInclusiveRange(40, 44));
    });
    test('kein Hitzeindex unter 27 °C oder unter 40 % Feuchte; ohne Temperatur null', () {
      expect(gefuehlteTemperatur(temperatur: 26.9, feuchte: 80), 26.9);
      expect(gefuehlteTemperatur(temperatur: 30, feuchte: 39), 30);
      expect(gefuehlteTemperatur(temperatur: 30), 30);
      expect(gefuehlteTemperatur(temperatur: null, feuchte: 50, windKmh: 20), isNull);
    });
  });

  group('Taupunkt (Magnus)', () {
    test('20 °C bei 50 % ergibt etwa 9,3 °C; bei 100 % gleich der Temperatur', () {
      expect(taupunkt(temperatur: 20, feuchte: 50), closeTo(9.3, 0.1));
      expect(taupunkt(temperatur: 20, feuchte: 100), closeTo(20, 0.01));
      expect(taupunkt(temperatur: 0, feuchte: 100), closeTo(0, 0.01));
      expect(taupunkt(temperatur: -5, feuchte: 80), closeTo(-7.9, 0.2));
    });
    test('ohne Wert oder mit unmöglicher Feuchte null', () {
      expect(taupunkt(temperatur: null, feuchte: 50), isNull);
      expect(taupunkt(temperatur: 5, feuchte: null), isNull);
      expect(taupunkt(temperatur: 5, feuchte: 0), isNull);
      expect(taupunkt(temperatur: 5, feuchte: 101), isNull);
    });
  });

  group('Trend über 3 Stunden', () {
    List<double?> reihe(Map<int, double> werte, {int n = 24}) => [for (var i = 0; i < n; i++) werte[i]];
    test('Temperatur: steigt, fällt, stabil (Schwelle 0,5 °C)', () {
      var t = temperaturTrend(_stunden(t: reihe({23: 12.0, 20: 11.0})))!;
      expect(t.richtung, TrendRichtung.steigt);
      expect(t.delta, closeTo(1.0, 1e-9));
      expect(trendTemperaturText(t), '▲ +1,0° in 3 h');
      t = temperaturTrend(_stunden(t: reihe({23: 10.0, 20: 10.8})))!;
      expect(t.richtung, TrendRichtung.faellt);
      expect(trendTemperaturText(t), '▼ −0,8° in 3 h');
      t = temperaturTrend(_stunden(t: reihe({23: 10.3, 20: 10.0})))!;
      expect(t.richtung, TrendRichtung.stabil);
      expect(trendTemperaturText(t), '► stabil');
      expect(trendSprechtext(t, 'Grad'), 'stabil');
    });
    test('Druck: ab 1 hPa; Sprechtext', () {
      final t = druckTrend(_stunden(druck: reihe({23: 1011.0, 20: 1009.0})))!;
      expect(t.richtung, TrendRichtung.steigt);
      expect(trendDruckText(t), '▲ +2 in 3 h');
      expect(trendSprechtext(t, 'hPa'), 'steigt um 2 hPa in 3 Stunden');
      expect(druckTrend(_stunden(druck: reihe({23: 1010.0, 20: 1010.5})))!.richtung, TrendRichtung.stabil);
    });
    test('nimmt den letzten Wert der letzten 2 Stunden und den Nachbarn, wenn genau 3 Stunden davor fehlen; sonst null', () {
      expect(temperaturTrend(_stunden(t: reihe({22: 12.0, 19: 10.0})))!.delta, closeTo(2.0, 1e-9));
      expect(temperaturTrend(_stunden(t: reihe({22: 12.0, 18: 10.0})))!.delta, closeTo(2.0, 1e-9)); // Nachbar-Stunde
      expect(temperaturTrend(_stunden(t: reihe({23: 12.0}))), isNull);
      expect(temperaturTrend(_stunden(t: reihe({15: 12.0, 12: 10.0}))), isNull); // letzter Wert zu alt
      expect(temperaturTrend(null), isNull);
    });
  });

  group('Vergleich Heute/Gestern und Woche', () {
    final tage = [
      const WetterTag('2026-10-20', 1.9, 9.0),
      const WetterTag('2026-10-21', 3.0, 15.2),
      const WetterTag('2026-10-22', 4.0, 11.0),
      const WetterTag('2026-10-23', 4.8, 13.5),
      const WetterTag('2026-10-24', 6.2, 12.1),
    ];
    final jetzt = DateTime(2026, 10, 24, 14);
    test('heutiger Tag aus den Sonnenzeiten des Servers, sonst vom Gerät; Tag davor und Wochentag', () {
      expect(heutigerTag(_dto(sonne: const [WetterSonne('2026-10-24', '07:21', '17:57')]), DateTime(2030)), '2026-10-24');
      expect(heutigerTag(_dto(), jetzt), '2026-10-24');
      expect(tagDavor('2026-03-01'), '2026-02-28');
      expect(tagDavor('2026-01-01'), '2025-12-31');
      expect(wochentagKurz('2026-10-24'), 'Sa');
      expect(wochentagKurz('2026-10-19'), 'Mo');
    });
    test('Heute gegen Gestern mit Einordnung', () {
      final v = tagesVergleich(_dto(tage: tage), jetzt)!;
      expect(v.heute.min, 6.2);
      expect(v.gestern!.max, 13.5);
      expect(v.vergleich, 'ähnlich'); // Mitte 9,15 gegen 9,15
      final warm = tagesVergleich(_dto(tage: [const WetterTag('2026-10-23', 0, 4), const WetterTag('2026-10-24', 4, 10)]), jetzt)!;
      expect(warm.vergleich, 'heute wärmer');
      final kalt = tagesVergleich(_dto(tage: [const WetterTag('2026-10-23', 4, 10), const WetterTag('2026-10-24', 0, 4)]), jetzt)!;
      expect(kalt.vergleich, 'heute kälter');
      expect(tagesVergleich(_dto(tage: [const WetterTag('2026-10-24', 1, 2)]), jetzt)!.vergleich, isNull);
      expect(tagesVergleich(_dto(tage: [const WetterTag('2026-10-23', 1, 2)]), jetzt), isNull);
      expect(tagesVergleich(_dto(), jetzt), isNull);
    });
    test('Wochenextreme mit Tag', () {
      final w = wochenExtreme(tage)!;
      expect(w.tief.datum, '2026-10-20');
      expect(w.tief.min, 1.9);
      expect(w.hoch.datum, '2026-10-21');
      expect(w.hoch.max, 15.2);
      expect(wochentagKurz(w.tief.datum), 'Di');
      expect(wochenExtreme(const []), isNull);
    });
  });

  group('Regen je Stunde', () {
    test('letzte 24 Stunden, null bleibt null; ohne Regenmesser oder ohne Stundenreihen leer', () {
      final r = List<double?>.generate(48, (i) => i == 47 ? 0.4 : (i.isEven ? 0.0 : null));
      final l = regenLetzte24(_stunden(regen: r, n: 48));
      expect(l, hasLength(24));
      expect(l.last, 0.4);
      expect(l.first, 0.0);
      expect(l[1], isNull);
      expect(regenLetzte24(_stunden()), isEmpty);
      expect(regenLetzte24(null), isEmpty);
      expect(regenLetzte24(_stunden(regen: [0, 0.1], n: 2)), hasLength(2));
    });
  });

  group('Hinweise', () {
    const alle = {...WetterHinweisArt.values};
    test('Frost unter 2 °C, nicht bei genau 2 °C', () {
      final h = aktiveHinweise(_dto(temp: 1.4), alle);
      expect(h.map((e) => e.art), [WetterHinweisArt.frost]);
      expect(h.single.text, 'Frostwarnung: 1,4 °C');
      expect(aktiveHinweise(_dto(temp: 2.0), alle), isEmpty);
      expect(aktiveHinweise(_dto(temp: -3.0), alle).single.text, 'Frostwarnung: -3,0 °C');
    });
    test('Hitze über 30 °C, nicht bei genau 30 °C', () {
      expect(aktiveHinweise(_dto(temp: 31.2), alle).single.text, 'Hitze: 31,2 °C');
      expect(aktiveHinweise(_dto(temp: 30.0), alle), isEmpty);
    });
    test('Starker Wind: Böen über 50 km/h', () {
      expect(aktiveHinweise(_dto(boeen: 62), alle).single.text, 'Starker Wind: Böen bis 62 km/h');
      expect(aktiveHinweise(_dto(boeen: 50), alle), isEmpty);
      expect(aktiveHinweise(_dto(wind: 70), alle), isEmpty); // nur Böen zählen
    });
    test('Regen beginnt nur, wenn die Stunde davor trocken gemessen war', () {
      List<double?> r(Map<int, double> m) => [for (var i = 0; i < 24; i++) m[i]];
      expect(aktiveHinweise(_dto(regen1h: 0.3, stunden: _stunden(regen: r({22: 0.0, 23: 0.3}))), alle).single.text, 'Regen beginnt');
      expect(aktiveHinweise(_dto(regen1h: 0.3, stunden: _stunden(regen: r({22: 0.5, 23: 0.3}))), alle), isEmpty); // regnet schon
      expect(aktiveHinweise(_dto(regen1h: 0.3, stunden: _stunden(regen: r({23: 0.3}))), alle), isEmpty); // Vorwert unbekannt: nie raten
      expect(aktiveHinweise(_dto(regen1h: 0.3), alle), isEmpty); // ältere Server ohne Stundenreihen
      expect(aktiveHinweise(_dto(regen1h: 0, stunden: _stunden(regen: r({22: 0.0, 23: 0.0}))), alle), isEmpty);
    });
    test('Druckabfall: mehr als 4 hPa in 3 Stunden', () {
      List<double?> d(double jetzt, double davor) => [for (var i = 0; i < 24; i++) i == 23 ? jetzt : (i == 20 ? davor : null)];
      final h = aktiveHinweise(_dto(stunden: _stunden(druck: d(1005.0, 1009.6))), alle);
      expect(h.single.art, WetterHinweisArt.druck);
      expect(h.single.text, 'Luftdruck fällt schnell: −5 hPa in 3 h');
      expect(aktiveHinweise(_dto(stunden: _stunden(druck: d(1006.0, 1010.0))), alle), isEmpty); // genau 4: nicht mehr als 4
      expect(aktiveHinweise(_dto(stunden: _stunden(druck: d(1012.0, 1005.0))), alle), isEmpty); // steigt
    });
    test('nur eingeschaltete Arten; veralteter oder fehlender Stand warnt nie', () {
      expect(aktiveHinweise(_dto(temp: 1.0, boeen: 80), {WetterHinweisArt.wind}).single.art, WetterHinweisArt.wind);
      expect(aktiveHinweise(_dto(temp: 1.0), const {}), isEmpty);
      expect(aktiveHinweise(_dto(temp: 1.0, veraltet: true), alle), isEmpty);
      expect(aktiveHinweise(null, alle), isEmpty);
      expect(aktiveHinweise(const WetterDto(verfuegbar: false), alle), isEmpty);
      expect(aktiveHinweise(const WetterDto(verfuegbar: true), alle), isEmpty);
    });
    test('mehrere Hinweise gleichzeitig; Texte enthalten nie Ort oder Koordinaten', () {
      final h = aktiveHinweise(_dto(temp: 1.0, boeen: 80), alle);
      expect(h.map((e) => e.art), [WetterHinweisArt.frost, WetterHinweisArt.wind]);
      for (final e in h) {
        expect(e.text.contains('X'), isFalse);
        expect(e.text, isNot(matches(RegExp(r'\d{2}\.\d{3}'))));
      }
    });
  });

  group('Modell (WetterDto)', () {
    Map<String, dynamic> basis() => {
      'available': true,
      'place': 'Westerburg',
      'current': {'measuredAt': '2026-10-24T12:00:00Z', 'stale': false, 'temperature': 11.4},
      'series': <Object>[],
      'min24h': null,
      'max24h': null,
    };

    test('ältere Server ohne neue Felder funktionieren', () {
      final dto = WetterDto.fromJson(basis());
      expect(dto.stunden, isNull);
      expect(dto.tage, isEmpty);
      expect(dto.sonne, isEmpty);
      expect(dto.aktuell!.temperatur, 11.4);
    });

    test('liest Stundenreihen, Tage und Sonne; ungültige Teile fallen weg, null bleibt null', () {
      final dto = WetterDto.fromJson({
        ...basis(),
        'hourly': {
          'from': '2026-10-17T13:00:00.000Z',
          'stepSec': 3600,
          'temperature': [5.0, null, 6.5, 'x', double.nan],
          'humidity': [80, 81],
          'pressure': null,
          'rain': [0, 0.4, null],
        },
        'days': [
          {'date': '2026-10-23', 'min': 4.8, 'max': 13.5},
          {'date': 'kaputt', 'min': 1, 'max': 2},
          {'date': '2026-10-24', 'min': 6.2},
        ],
        'sun': [
          {'date': '2026-10-24', 'sunrise': '2026-10-24T07:52:00+02:00', 'sunset': '2026-10-24T18:01:00+02:00'},
          {'date': '2026-10-25', 'sunrise': null, 'sunset': 'x'},
          'kaputt',
        ],
      });
      final s = dto.stunden!;
      expect(s.laenge, 5);
      expect(s.temperatur, [5.0, null, 6.5, null, null]);
      expect(s.feuchte, [80.0, 81.0, null, null, null]);
      expect(s.druck.every((v) => v == null), isTrue);
      expect(s.regen, [0.0, 0.4, null, null, null]);
      expect(s.wind, hasLength(5));
      expect(s.zeit(2), DateTime.utc(2026, 10, 17, 15));
      expect(dto.tage.map((t) => t.datum), ['2026-10-23']);
      expect(dto.sonne, hasLength(2));
      expect(dto.sonne.first.aufgang, '07:52');
      expect(dto.sonne.first.untergang, '18:01');
      expect(dto.sonne.last.aufgang, isNull);
      expect(dto.sonne.last.untergang, isNull);
    });

    test('unbrauchbare Stundenreihen ergeben null; zu lange werden abgeschnitten', () {
      expect(WetterDto.fromJson({...basis(), 'hourly': 'x'}).stunden, isNull);
      expect(WetterDto.fromJson({...basis(), 'hourly': {'from': 'kaputt', 'temperature': [1]}}).stunden, isNull);
      expect(WetterDto.fromJson({...basis(), 'hourly': {'from': '2026-10-17T13:00:00Z', 'temperature': <Object>[]}}).stunden, isNull);
      final lang = WetterDto.fromJson({...basis(), 'hourly': {'from': '2026-10-17T13:00:00Z', 'temperature': List<double>.filled(5000, 1)}});
      expect(lang.stunden!.laenge, 192);
    });
  });
}
