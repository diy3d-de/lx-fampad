// Daten des interaktiven Verlaufs: Größen mit Daten, Zeiträume, Punkte, Hoch-/Tiefpunkt, Texte und die Zusammenfassung für Screenreader.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/wetter/wetter_verlauf.dart';

WetterStunden _s(int n, {double? Function(int)? t, double? Function(int)? regen, double? Function(int)? wind}) {
  List<double?> r(double? Function(int)? f) => [for (var i = 0; i < n; i++) f?.call(i)];
  return WetterStunden(von: DateTime(2026, 10, 17, 13), temperatur: r(t), feuchte: r(null), druck: r(null), regen: r(regen), wind: r(wind), boeen: r(null), richtung: r(null));
}

WetterDto _dto(WetterStunden? s, {List<WetterPunkt> verlauf = const []}) => WetterDto(verfuegbar: true, ort: 'X', stunden: s, verlauf: verlauf);

void main() {
  test('Chips nur für Größen mit Daten', () {
    final d = _dto(_s(168, t: (i) => 5.0 + i % 3, wind: (i) => i == 100 ? 12.0 : null));
    expect(WetterGroesse.values.where((g) => groesseHatDaten(d, g)), [WetterGroesse.temperatur, WetterGroesse.wind]);
    expect(groesseHatDaten(_dto(_s(168)), WetterGroesse.temperatur), isFalse);
  });

  test('älterer Server: nur Temperatur und nur 24 Stunden', () {
    final d = _dto(null, verlauf: [WetterPunkt(DateTime(2026, 10, 24, 8), 5), WetterPunkt(DateTime(2026, 10, 24, 9), 6)]);
    expect(groesseHatDaten(d, WetterGroesse.temperatur), isTrue);
    expect(groesseHatDaten(d, WetterGroesse.regen), isFalse);
    expect(verfuegbareZeitraeume(d), [WetterZeitraum.h24]);
    expect(verlaufPunkte(d, WetterGroesse.temperatur, 168), hasLength(2));
    expect(verlaufPunkte(d, WetterGroesse.regen, 24), isEmpty);
    expect(groesseHatDaten(_dto(null), WetterGroesse.temperatur), isFalse);
    expect(verfuegbareZeitraeume(_dto(_s(168, t: (i) => 1.0))), WetterZeitraum.values);
  });

  test('Punkte: die letzten N Stunden, älteste zuerst, Lücken bleiben null', () {
    final d = _dto(_s(168, t: (i) => i == 150 ? null : i.toDouble()));
    final p = verlaufPunkte(d, WetterGroesse.temperatur, 24);
    expect(p, hasLength(24));
    expect(p.first.wert, 144);
    expect(p.last.wert, 167);
    expect(p[6].wert, isNull);
    expect(p.first.zeit, DateTime(2026, 10, 17, 13).add(const Duration(hours: 144)));
    expect(verlaufPunkte(d, WetterGroesse.temperatur, 72), hasLength(72));
    expect(verlaufPunkte(d, WetterGroesse.temperatur, 168), hasLength(168));
    expect(verlaufPunkte(_dto(_s(10, t: (i) => 1.0 * i)), WetterGroesse.temperatur, 168), hasLength(10)); // weniger Daten als Zeitraum
  });

  test('Hoch- und Tiefpunkt (bei Gleichstand der jüngste), Lücken ignoriert, ohne Werte null', () {
    final p = [for (final v in [5.0, null, 2.0, 9.0, 2.0, 9.0, 4.0]) VerlaufPunkt(DateTime(2026), v)];
    final e = extremeIndizes(p)!;
    expect(e.tief, 4);
    expect(e.hoch, 5);
    expect(extremeIndizes([VerlaufPunkt(DateTime(2026), null)]), isNull);
    expect(extremeIndizes(const []), isNull);
  });

  test('Texte: Komma, Einheit, Zeit mit Wochentag erst bei mehreren Tagen', () {
    expect(wertText(WetterGroesse.temperatur, 6.24), '6,2 °C');
    expect(wertText(WetterGroesse.druck, 1013.3), '1013,3 hPa');
    expect(wertText(WetterGroesse.feuchte, 71.4), '71 %');
    expect(wertText(WetterGroesse.regen, null), '–');
    final t = DateTime(2026, 10, 22, 5); // Donnerstag
    expect(verlaufZeitText(t, mitTag: false), '05:00');
    expect(verlaufZeitText(t, mitTag: true), 'Do 05:00');
  });

  test('Zusammenfassung für Screenreader: Tiefstwert 6,2 Grad um 05:00 Uhr', () {
    // 24 Stunden bis 24.10. 12:00 lokal; Tiefpunkt um 05:00, Hochpunkt um 14:00 des Vortags
    final ende = DateTime(2026, 10, 24, 12);
    final punkte = [
      for (var i = 0; i < 24; i++) VerlaufPunkt(ende.subtract(Duration(hours: 23 - i)), 9.0),
    ];
    final idx5 = punkte.indexWhere((p) => p.zeit.hour == 5);
    final idx14 = punkte.indexWhere((p) => p.zeit.hour == 14);
    punkte[idx5] = VerlaufPunkt(punkte[idx5].zeit, 6.2);
    punkte[idx14] = VerlaufPunkt(punkte[idx14].zeit, 12.1);
    final text = verlaufZusammenfassung(WetterGroesse.temperatur, punkte, WetterZeitraum.h24);
    expect(text, contains('Temperatur der letzten 24 Stunden'));
    expect(text, contains('Tiefstwert 6,2 Grad um 05:00 Uhr'));
    expect(text, contains('Höchstwert 12,1 Grad um 14:00 Uhr'));
    expect(text, contains('Zuletzt 9,0 Grad'));
    final mehrtage = verlaufZusammenfassung(WetterGroesse.temperatur, punkte, WetterZeitraum.t3);
    expect(mehrtage, contains('der letzten 3 Tage'));
    expect(mehrtage, contains(RegExp('Tiefstwert 6,2 Grad (Freitag|Samstag) um 05:00 Uhr')));
    expect(verlaufZusammenfassung(WetterGroesse.wind, [VerlaufPunkt(ende, null)], WetterZeitraum.h24), contains('Noch keine Messwerte'));
  });

  test('Zusammenfassung Regen: Summe und stärkste Stunde, trocken, Wind mit Einheit', () {
    final ende = DateTime(2026, 10, 24, 12);
    final nass = [for (var i = 0; i < 4; i++) VerlaufPunkt(ende.subtract(Duration(hours: 3 - i)), [0.0, 0.5, 1.5, 0.0][i])];
    final t = verlaufZusammenfassung(WetterGroesse.regen, nass, WetterZeitraum.h24);
    expect(t, contains('Summe 2,0 Millimeter'));
    expect(t, contains('Stärkste Stunde 1,5 Millimeter um 11:00 Uhr'));
    final trocken = [for (var i = 0; i < 3; i++) VerlaufPunkt(ende.subtract(Duration(hours: i)), 0.0)];
    expect(verlaufZusammenfassung(WetterGroesse.regen, trocken, WetterZeitraum.h24), contains('Kein Niederschlag'));
    final wind = [VerlaufPunkt(ende, 14.0), VerlaufPunkt(ende.add(const Duration(hours: 1)), 20.0)];
    expect(verlaufZusammenfassung(WetterGroesse.wind, wind, WetterZeitraum.h24), contains('Höchstwert 20 Kilometer pro Stunde'));
    expect(verlaufPunktSprechtext(WetterGroesse.temperatur, VerlaufPunkt(ende, 6.2), mitTag: false), 'um 12:00 Uhr: 6,2 Grad');
    expect(verlaufPunktSprechtext(WetterGroesse.temperatur, VerlaufPunkt(ende, null), mitTag: false), contains('keine Messung'));
  });
}
