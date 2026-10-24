// Reine Wetter-Logik (ohne Oberfläche, ohne Netz): gefühlte Temperatur, Taupunkt, Trends, Vergleich Heute/Gestern, Wochenextreme, Regen je Stunde und die
// Bedingungen der lokalen Hinweise. Alles rechnet nur aus den Werten der Antwort des eigenen Servers (docs/API.md, Wetter).
import 'dart:math' as math;

import '../api/models.dart';

/// Gefühlte Temperatur in °C.
///
/// - Windchill bei T <= 10 °C und Wind > 4,8 km/h (Joint Action Group for Temperature Indices, Environment Canada/NWS 2001):
///   `13,12 + 0,6215 T - 11,37 v^0,16 + 0,3965 T v^0,16` (T in °C, v in km/h).
/// - Hitzeindex ab 27 °C und mindestens 40 % Feuchte (Rothfusz-Regression des US National Weather Service, in °F gerechnet):
///   `HI = -42,379 + 2,04901523 T + 10,14333127 R - 0,22475541 T R - 6,83783e-3 T^2 - 5,481717e-2 R^2 + 1,22874e-3 T^2 R + 8,5282e-4 T R^2 - 1,99e-6 T^2 R^2`
///   (T in °F, R in % relative Feuchte), danach zurück nach °C.
/// - sonst die Lufttemperatur. Ohne Temperatur: null; fehlen Wind bzw. Feuchte, gilt die jeweilige Formel nicht.
double? gefuehlteTemperatur({required double? temperatur, double? feuchte, double? windKmh}) {
  final t = temperatur;
  if (t == null) return null;
  if (t <= 10 && windKmh != null && windKmh > 4.8) {
    final v = math.pow(windKmh, 0.16).toDouble();
    return 13.12 + 0.6215 * t - 11.37 * v + 0.3965 * t * v;
  }
  if (t >= 27 && feuchte != null && feuchte >= 40) {
    final f = t * 9 / 5 + 32;
    final r = feuchte;
    final hi = -42.379 +
        2.04901523 * f +
        10.14333127 * r -
        0.22475541 * f * r -
        6.83783e-3 * f * f -
        5.481717e-2 * r * r +
        1.22874e-3 * f * f * r +
        8.5282e-4 * f * r * r -
        1.99e-6 * f * f * r * r;
    return (hi - 32) * 5 / 9;
  }
  return t;
}

/// Taupunkt in °C nach der Magnus-Formel (a = 17,62, b = 243,12 °C, gültig etwa -45 bis 60 °C):
/// `g = ln(R/100) + a T / (b + T)`, `Td = b g / (a - g)`. Null ohne Temperatur oder bei Feuchte <= 0 (ln nicht definiert).
double? taupunkt({required double? temperatur, required double? feuchte}) {
  if (temperatur == null || feuchte == null || feuchte <= 0 || feuchte > 100) return null;
  const a = 17.62;
  const b = 243.12;
  final g = math.log(feuchte / 100) + a * temperatur / (b + temperatur);
  return b * g / (a - g);
}

/// Richtung einer Veränderung.
enum TrendRichtung { steigt, faellt, stabil }

class Trend {
  final double delta;
  final TrendRichtung richtung;
  const Trend(this.delta, this.richtung);
}

/// Letzter Wert einer Stundenreihe innerhalb der letzten [maxAlt] Stunden (Index, Wert); null, wenn es keinen gibt.
(int, double)? letzterWert(List<double?> reihe, {int maxAlt = 2}) {
  for (var i = reihe.length - 1; i >= 0 && i >= reihe.length - maxAlt; i--) {
    final v = reihe[i];
    if (v != null) return (i, v);
  }
  return null;
}

/// Veränderung über [stunden] Stunden (Standard 3): letzter Wert (höchstens 2 Stunden alt) gegen den Wert [stunden] Stunden davor
/// (ersatzweise eine Stunde daneben, der nähere zuerst). Null, wenn ein Wert fehlt. [schwelle]: darunter gilt "stabil".
Trend? trendUeber(List<double?> reihe, {int stunden = 3, required double schwelle}) {
  final jetzt = letzterWert(reihe);
  if (jetzt == null) return null;
  final i = jetzt.$1;
  for (final dv in [0, -1, 1]) {
    final j = i - stunden + dv;
    if (j < 0 || j >= i) continue;
    final alt = reihe[j];
    if (alt == null) continue;
    final d = jetzt.$2 - alt;
    return Trend(d, d >= schwelle ? TrendRichtung.steigt : (d <= -schwelle ? TrendRichtung.faellt : TrendRichtung.stabil));
  }
  return null;
}

/// Temperaturtrend: ab 0,5 °C Unterschied in 3 Stunden steigt bzw. fällt sie, sonst stabil.
Trend? temperaturTrend(WetterStunden? s) => s == null ? null : trendUeber(s.temperatur, schwelle: 0.5);

/// Drucktrend: ab 1 hPa in 3 Stunden (Skala der Wetterdienste für "langsam steigend/fallend"), sonst stabil.
Trend? druckTrend(WetterStunden? s) => s == null ? null : trendUeber(s.druck, schwelle: 1);

String _zahl(double v, int stellen) => v.toStringAsFixed(stellen).replaceAll('.', ',');
String _vorzeichen(double v, int stellen) {
  final r = double.parse(v.toStringAsFixed(stellen));
  if (r == 0) return _zahl(0, stellen);
  return '${r > 0 ? '+' : '−'}${_zahl(r.abs(), stellen)}';
}

String trendPfeil(Trend t) => switch (t.richtung) { TrendRichtung.steigt => '▲', TrendRichtung.faellt => '▼', TrendRichtung.stabil => '►' };

/// Kurztext zur Anzeige, z. B. "▼ −0,8° in 3 h" oder "► stabil".
String trendTemperaturText(Trend t) => t.richtung == TrendRichtung.stabil ? '${trendPfeil(t)} stabil' : '${trendPfeil(t)} ${_vorzeichen(t.delta, 1)}° in 3 h';
String trendDruckText(Trend t) => t.richtung == TrendRichtung.stabil ? '${trendPfeil(t)} stabil' : '${trendPfeil(t)} ${_vorzeichen(t.delta, 0)} in 3 h';

/// Satz für Screenreader: "steigt um 0,8 Grad in 3 Stunden" bzw. "stabil".
String trendSprechtext(Trend t, String einheit) => switch (t.richtung) {
  TrendRichtung.stabil => 'stabil',
  TrendRichtung.steigt => 'steigt um ${_zahl(t.delta.abs(), einheit == 'hPa' ? 0 : 1)} ${einheit == 'Grad' ? 'Grad' : 'hPa'} in 3 Stunden',
  TrendRichtung.faellt => 'fällt um ${_zahl(t.delta.abs(), einheit == 'hPa' ? 0 : 1)} ${einheit == 'Grad' ? 'Grad' : 'hPa'} in 3 Stunden',
};

/// Kalendertag `JJJJ-MM-TT` einen Tag früher.
String tagDavor(String datum) {
  final d = DateTime.utc(int.parse(datum.substring(0, 4)), int.parse(datum.substring(5, 7)), int.parse(datum.substring(8, 10)));
  final v = d.subtract(const Duration(days: 1));
  String z(int n) => n.toString().padLeft(2, '0');
  return '${v.year.toString().padLeft(4, '0')}-${z(v.month)}-${z(v.day)}';
}

/// Kurzname des Wochentags zu `JJJJ-MM-TT`.
String wochentagKurz(String datum) {
  const namen = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  return namen[DateTime.utc(int.parse(datum.substring(0, 4)), int.parse(datum.substring(5, 7)), int.parse(datum.substring(8, 10))).weekday - 1];
}

/// Heutiger Kalendertag laut Antwort (die Sonnenzeiten des Servers beginnen mit heute in Europe/Berlin); ersatzweise der Tag des Geräts.
String heutigerTag(WetterDto dto, DateTime jetzt) {
  if (dto.sonne.isNotEmpty) return dto.sonne.first.datum;
  final l = jetzt.toLocal();
  String z(int n) => n.toString().padLeft(2, '0');
  return '${l.year.toString().padLeft(4, '0')}-${z(l.month)}-${z(l.day)}';
}

WetterTag? tagMitDatum(List<WetterTag> tage, String datum) {
  for (final t in tage) {
    if (t.datum == datum) return t;
  }
  return null;
}

/// Vergleich Heute gegen Gestern anhand der Tagesextreme; null, wenn heute fehlt.
class TagesVergleich {
  final WetterTag heute;
  final WetterTag? gestern;
  const TagesVergleich(this.heute, this.gestern);

  /// Mittel aus Tief und Hoch: heute mindestens 1 °C über/unter gestern = wärmer/kälter, sonst ähnlich; null ohne gestern.
  String? get vergleich {
    final g = gestern;
    if (g == null) return null;
    final d = (heute.min + heute.max) / 2 - (g.min + g.max) / 2;
    return d >= 1 ? 'heute wärmer' : (d <= -1 ? 'heute kälter' : 'ähnlich');
  }
}

TagesVergleich? tagesVergleich(WetterDto dto, DateTime jetzt) {
  final heute = heutigerTag(dto, jetzt);
  final h = tagMitDatum(dto.tage, heute);
  if (h == null) return null;
  return TagesVergleich(h, tagMitDatum(dto.tage, tagDavor(heute)));
}

/// Tiefster und höchster Tageswert der Woche (letzte 7 Tage) mit Tag; null ohne Tage. Bei Gleichstand gewinnt der jüngere Tag.
class Wochenextreme {
  final WetterTag tief;
  final WetterTag hoch;
  const Wochenextreme(this.tief, this.hoch);
}

Wochenextreme? wochenExtreme(List<WetterTag> tage) {
  if (tage.isEmpty) return null;
  var tief = tage.first;
  var hoch = tage.first;
  for (final t in tage) {
    if (t.min <= tief.min) tief = t;
    if (t.max >= hoch.max) hoch = t;
  }
  return Wochenextreme(tief, hoch);
}

/// Niederschlag je Stunde der letzten 24 Stunden (älteste zuerst, null = keine Messung); leer, wenn der Server keine Stundenreihen liefert oder
/// die Station keinen Regenmesser hat.
List<double?> regenLetzte24(WetterStunden? s) {
  if (s == null || s.regen.every((v) => v == null)) return const [];
  final n = s.laenge;
  return s.regen.sublist(n > 24 ? n - 24 : 0);
}

// ---- Hinweise -------------------------------------------------------------------------------------------------------------------------------------------

enum WetterHinweisArt { frost, regen, wind, hitze, druck }

/// Schwellen der Hinweise (docs/PROJEKTBESCHREIBUNG.md, Wetter).
const kFrostGrenze = 2.0; // °C, darunter
const kWindBoeenGrenze = 50.0; // km/h, darüber
const kHitzeGrenze = 30.0; // °C, darüber
const kDruckAbfallGrenze = 4.0; // hPa in 3 Stunden, mehr als

class WetterHinweis {
  final WetterHinweisArt art;

  /// Kurzer, neutraler Text ohne Ort und Koordinaten, z. B. "Frostwarnung: 1,4 °C".
  final String text;
  const WetterHinweis(this.art, this.text);
}

/// Welche Hinweise gelten gerade? Nur aus einer frischen Messung (nicht veraltet): ein alter Stand warnt nie. [erlaubt] = die eingeschalteten Arten.
List<WetterHinweis> aktiveHinweise(WetterDto? dto, Set<WetterHinweisArt> erlaubt) {
  final a = dto?.aktuell;
  if (dto == null || !dto.verfuegbar || a == null || a.veraltet) return const [];
  final r = <WetterHinweis>[];
  final t = a.temperatur;
  if (erlaubt.contains(WetterHinweisArt.frost) && t != null && t < kFrostGrenze) {
    r.add(WetterHinweis(WetterHinweisArt.frost, 'Frostwarnung: ${_zahl(t, 1)} °C'));
  }
  if (erlaubt.contains(WetterHinweisArt.regen) && (a.regen1h ?? 0) > 0 && _regenBeginnt(dto.stunden)) {
    r.add(const WetterHinweis(WetterHinweisArt.regen, 'Regen beginnt'));
  }
  final boeen = a.boeKmh;
  if (erlaubt.contains(WetterHinweisArt.wind) && boeen != null && boeen > kWindBoeenGrenze) {
    r.add(WetterHinweis(WetterHinweisArt.wind, 'Starker Wind: Böen bis ${boeen.round()} km/h'));
  }
  if (erlaubt.contains(WetterHinweisArt.hitze) && t != null && t > kHitzeGrenze) {
    r.add(WetterHinweis(WetterHinweisArt.hitze, 'Hitze: ${_zahl(t, 1)} °C'));
  }
  if (erlaubt.contains(WetterHinweisArt.druck)) {
    final d = druckTrend(dto.stunden);
    if (d != null && d.delta < -kDruckAbfallGrenze) {
      r.add(WetterHinweis(WetterHinweisArt.druck, 'Luftdruck fällt schnell: ${_vorzeichen(d.delta, 0)} hPa in 3 h'));
    }
  }
  return r;
}

/// Regen beginnt: die Stunde vor dem letzten Regenwert war trocken gemessen (0). Ohne Stundenreihen oder ohne Vorwert: nein (nie raten).
bool _regenBeginnt(WetterStunden? s) {
  if (s == null) return false;
  final k = letzterWert(s.regen, maxAlt: 3);
  if (k == null || k.$1 == 0) return false;
  final davor = s.regen[k.$1 - 1];
  return davor != null && davor == 0;
}
