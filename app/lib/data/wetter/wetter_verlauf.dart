// Daten des interaktiven Verlaufs (rein, ohne Oberfläche): Messgrößen, Zeiträume, Punkte aus den Stundenreihen, Hoch-/Tiefpunkt, Texte für die Anzeige
// und für Screenreader ("Tiefstwert 6,2 Grad um 05:00 Uhr"). Ältere Server liefern nur die Temperatur der letzten 24 Stunden (`verlauf`): dann gibt es nur
// diese Größe in diesem Zeitraum.
import '../api/models.dart';

enum WetterGroesse {
  temperatur('Temperatur', '°C', 'Grad', 1),
  feuchte('Feuchte', '%', 'Prozent', 0),
  druck('Druck', 'hPa', 'Hektopascal', 1),
  regen('Regen', 'mm', 'Millimeter', 1),
  wind('Wind', 'km/h', 'Kilometer pro Stunde', 0);

  final String bezeichnung;
  final String einheit;
  final String sprech;
  final int stellen;
  const WetterGroesse(this.bezeichnung, this.einheit, this.sprech, this.stellen);

  /// Regen wird als Balken gezeichnet, alles andere als Linie.
  bool get balken => this == WetterGroesse.regen;

  /// Reihe der Größe in den Stundenreihen.
  List<double?> reihe(WetterStunden s) => switch (this) {
    WetterGroesse.temperatur => s.temperatur,
    WetterGroesse.feuchte => s.feuchte,
    WetterGroesse.druck => s.druck,
    WetterGroesse.regen => s.regen,
    WetterGroesse.wind => s.wind,
  };
}

enum WetterZeitraum {
  h24(24, '24 Stunden'),
  t3(72, '3 Tage'),
  t7(168, '7 Tage');

  final int stunden;
  final String text;
  const WetterZeitraum(this.stunden, this.text);
}

class VerlaufPunkt {
  final DateTime zeit;
  final double? wert;
  const VerlaufPunkt(this.zeit, this.wert);
}

/// Gibt es für die Größe überhaupt Messwerte? Nur dann erscheint ihr Auswahl-Chip.
bool groesseHatDaten(WetterDto dto, WetterGroesse g) {
  final s = dto.stunden;
  if (s != null) return g.reihe(s).any((v) => v != null);
  return g == WetterGroesse.temperatur && dto.verlauf.length >= 2;
}

/// Punkte der Größe für den Zeitraum (älteste zuerst). Mit Stundenreihen die letzten [stunden] Stunden; ohne (älterer Server) die Temperatur der letzten 24 Stunden.
List<VerlaufPunkt> verlaufPunkte(WetterDto dto, WetterGroesse g, int stunden) {
  final s = dto.stunden;
  if (s != null) {
    final reihe = g.reihe(s);
    final n = reihe.length;
    final von = n > stunden ? n - stunden : 0;
    return [for (var i = von; i < n; i++) VerlaufPunkt(s.zeit(i), reihe[i])];
  }
  if (g == WetterGroesse.temperatur) return [for (final p in dto.verlauf) VerlaufPunkt(p.zeit, p.temperatur)];
  return const [];
}

/// Zeitraum-Chips: nur, wenn Stundenreihen da sind und mehr als ein Tag Daten (sonst gäbe es keinen Unterschied).
List<WetterZeitraum> verfuegbareZeitraeume(WetterDto dto) {
  final s = dto.stunden;
  if (s == null) return const [WetterZeitraum.h24];
  return WetterZeitraum.values;
}

/// Indizes des tiefsten und höchsten Werts (bei Gleichstand der jüngste); null ohne Werte.
({int tief, int hoch})? extremeIndizes(List<VerlaufPunkt> p) {
  int? tief;
  int? hoch;
  for (var i = 0; i < p.length; i++) {
    final v = p[i].wert;
    if (v == null) continue;
    if (tief == null || v <= p[tief].wert!) tief = i;
    if (hoch == null || v >= p[hoch].wert!) hoch = i;
  }
  return tief == null || hoch == null ? null : (tief: tief, hoch: hoch);
}

String zahlText(double v, int stellen) => v.toStringAsFixed(stellen).replaceAll('.', ',');

String wertText(WetterGroesse g, double? v) => v == null ? '–' : '${zahlText(v, g.stellen)} ${g.einheit}';

const _tageKurz = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const _tageLang = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];

String _z(int n) => n.toString().padLeft(2, '0');

/// Zeit für die Anzeige am Fadenkreuz: "05:00", bei mehreren Tagen mit Wochentag ("Do 05:00").
String verlaufZeitText(DateTime t, {required bool mitTag}) {
  final l = t.toLocal();
  final uhr = '${_z(l.hour)}:${_z(l.minute)}';
  return mitTag ? '${_tageKurz[l.weekday - 1]} $uhr' : uhr;
}

String _sprechZeit(DateTime t, bool mitTag) {
  final l = t.toLocal();
  final uhr = '${_z(l.hour)}:${_z(l.minute)} Uhr';
  return mitTag ? '${_tageLang[l.weekday - 1]} um $uhr' : 'um $uhr';
}

String _sprechWert(WetterGroesse g, double v) => '${zahlText(v, g.stellen)} ${g.sprech}';

/// Textzusammenfassung für Screenreader. Bei Regen Summe und stärkste Stunde, sonst Tief-, Höchst- und letzter Wert.
String verlaufZusammenfassung(WetterGroesse g, List<VerlaufPunkt> p, WetterZeitraum z) {
  final raum = switch (z) {
    WetterZeitraum.h24 => 'der letzten 24 Stunden',
    WetterZeitraum.t3 => 'der letzten 3 Tage',
    WetterZeitraum.t7 => 'der letzten 7 Tage',
  };
  final kopf = '${g.bezeichnung} $raum.';
  final e = extremeIndizes(p);
  if (e == null) return '$kopf Noch keine Messwerte.';
  final mitTag = z != WetterZeitraum.h24;
  if (g.balken) {
    final summe = p.fold<double>(0, (s, x) => s + (x.wert ?? 0));
    final st = p[e.hoch];
    if (st.wert! <= 0) return '$kopf Kein Niederschlag, Summe ${_sprechWert(g, summe)}.';
    return '$kopf Summe ${_sprechWert(g, summe)}. Stärkste Stunde ${_sprechWert(g, st.wert!)} ${_sprechZeit(st.zeit, mitTag)}.';
  }
  final letzter = p.lastWhere((x) => x.wert != null);
  return '$kopf Tiefstwert ${_sprechWert(g, p[e.tief].wert!)} ${_sprechZeit(p[e.tief].zeit, mitTag)}. '
      'Höchstwert ${_sprechWert(g, p[e.hoch].wert!)} ${_sprechZeit(p[e.hoch].zeit, mitTag)}. '
      'Zuletzt ${_sprechWert(g, letzter.wert!)}.';
}

/// Satz für einen einzelnen Punkt (Fadenkreuz) für Screenreader: "05:00 Uhr: 6,2 Grad".
String verlaufPunktSprechtext(WetterGroesse g, VerlaufPunkt p, {required bool mitTag}) {
  final zeit = _sprechZeit(p.zeit, mitTag);
  final v = p.wert;
  return v == null ? '$zeit: keine Messung' : '$zeit: ${_sprechWert(g, v)}';
}
