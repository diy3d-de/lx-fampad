// Reine Logik der Vorhersage und der amtlichen Warnungen: Veraltung (nie als aktuell zeigen), Auswahl der Warnungen, Namen und Texte, Spannbalken.
// Keine Netzwerk- oder Oberflächen-Abhängigkeit; die Farbe einer Stufe kommt aus `constants.dart`.
import 'dart:ui' show Color;

import '../../constants.dart';
import 'vorhersage_modelle.dart';

/// Eine Vorhersage, die älter ist, gilt als veraltet (so auch der Server); bei einem Offline-Stand rechnet die App selbst nach.
const kVorhersageVeraltetNach = Duration(hours: 12);

/// Warnungen werden alle 10 Minuten geholt; ab einer Stunde ohne frischen Stand gelten sie nicht mehr als aktuell.
const kWarnungenVeraltetNach = Duration(hours: 1);

bool vorhersageVeraltet(VorhersageTeil t, DateTime jetzt) => t.veraltet || jetzt.difference(t.aktualisiert) > kVorhersageVeraltetNach;

bool warnungenVeraltet(WarnungenTeil t, DateTime jetzt) => t.veraltet || jetzt.difference(t.aktualisiert) > kWarnungenVeraltetNach;

String stufeName(int stufe) => switch (stufe) {
  1 => 'Wetterwarnung',
  2 => 'Markante Wetterwarnung',
  3 => 'Unwetterwarnung',
  _ => 'Extreme Unwetterwarnung',
};

Color warnFarbe(int stufe) => switch (stufe) {
  1 => kWarn,
  2 => kWarnOrange,
  3 => kDanger,
  _ => kWarnViolett,
};

/// Warnungen, die noch gelten (nicht beendet), höchste Stufe zuerst; [minStufe] filtert nach unten. Mit [nurFrisch] nur aus einem frischen Stand, sonst leer.
List<WetterWarnung> geltendeWarnungen(WarnungenTeil? teil, DateTime jetzt, {int minStufe = 1, bool nurFrisch = true}) {
  if (teil == null || (nurFrisch && warnungenVeraltet(teil, jetzt))) return const [];
  final l = [
    for (final w in teil.items)
      if (w.stufe >= minStufe && (w.bis == null || w.bis!.isAfter(jetzt))) w,
  ];
  l.sort((a, b) {
    final c = b.stufe.compareTo(a.stufe);
    return c != 0 ? c : a.von.compareTo(b.von);
  });
  return l;
}

/// Startseite: nur amtliche Warnungen ab Stufe 2 ("markant") aus einem frischen Stand.
List<WetterWarnung> startseitenWarnungen(VorhersageDto? dto, DateTime jetzt) => geltendeWarnungen(dto?.warnungen, jetzt, minStufe: 2);

const _wochentage = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

String wochentagKurz(DateTime d) => _wochentage[d.weekday - 1];

String _zwei(int n) => n.toString().padLeft(2, '0');
String uhrText(DateTime t) => '${_zwei(t.hour)}:${_zwei(t.minute)}';

int _tageBis(DateTime d, DateTime jetzt) => DateTime(d.year, d.month, d.day).difference(DateTime(jetzt.year, jetzt.month, jetzt.day)).inDays;

String tagName(DateTime datum, DateTime jetzt) => switch (_tageBis(datum, jetzt)) {
  0 => 'Heute',
  1 => 'Morgen',
  _ => wochentagKurz(datum),
};

/// Zeitraum einer Warnung in kurzen Worten, z. B. "heute 08:00 bis 18:00 Uhr" oder "Sa 21:00 bis So 09:00 Uhr".
String warnZeitraum(WetterWarnung w, DateTime jetzt) {
  String tag(DateTime d) {
    final n = _tageBis(d, jetzt);
    return n == 0 ? 'heute' : (n == 1 ? 'morgen' : wochentagKurz(d));
  }

  final bis = w.bis;
  if (bis == null) return '${tag(w.von)} ab ${uhrText(w.von)} Uhr';
  if (!w.von.isAfter(jetzt)) return 'bis ${tag(bis)} ${uhrText(bis)} Uhr';
  final gleicherTag = w.von.year == bis.year && w.von.month == bis.month && w.von.day == bis.day;
  return gleicherTag ? '${tag(w.von)} ${uhrText(w.von)} bis ${uhrText(bis)} Uhr' : '${tag(w.von)} ${uhrText(w.von)} bis ${tag(bis)} ${uhrText(bis)} Uhr';
}

/// Die nächsten bis zu [anzahl] Stunden ab der laufenden Stunde.
List<VorhersageStunde> naechsteStunden(List<VorhersageStunde> alle, DateTime jetzt, {int anzahl = 24}) {
  final start = DateTime(jetzt.year, jetzt.month, jetzt.day, jetzt.hour);
  final l = [
    for (final s in alle)
      if (!s.zeit.isBefore(start)) s,
  ]..sort((a, b) => a.zeit.compareTo(b.zeit));
  return l.length > anzahl ? l.sublist(0, anzahl) : l;
}

/// Tage ab heute (vergangene fallen weg), höchstens 7.
List<VorhersageTag> kommendeTage(List<VorhersageTag> alle, DateTime jetzt) {
  final heute = DateTime(jetzt.year, jetzt.month, jetzt.day);
  final l = [
    for (final t in alle)
      if (!t.datum.isBefore(heute)) t,
  ]..sort((a, b) => a.datum.compareTo(b.datum));
  return l.length > 7 ? l.sublist(0, 7) : l;
}

/// Lage des Spannbalkens eines Tages in der gemeinsamen Skala aller Tage (Anteile 0..1; mindestens eine sichtbare Breite).
({double links, double breite}) spannBalken(VorhersageTag t, double skalaMin, double skalaMax) {
  final spanne = skalaMax - skalaMin;
  if (spanne <= 0) return (links: 0, breite: 1);
  final links = ((t.min - skalaMin) / spanne).clamp(0.0, 0.94);
  final breite = ((t.max - t.min) / spanne).clamp(0.06, 1.0 - links);
  return (links: links, breite: breite);
}

String _komma(double v, int s) => v.toStringAsFixed(s).replaceAll('.', ',');

String gradText(double v) => '${v.round()}°';
String mmText(double v) => v < 0.05 ? '0 mm' : '${_komma(v, 1)} mm';

/// Zeile unter dem Tag: Regenwahrscheinlichkeit, Menge, Wind (nur vorhandene Angaben).
String tagDetailText(VorhersageTag t) {
  final wind = t.windKmh;
  final boe = t.boeKmh;
  final teile = <String>[
    if (t.regenProzent != null) 'Regen ${t.regenProzent} %',
    if (t.regenMm >= 0.05) mmText(t.regenMm),
    if (wind != null) 'Wind $wind km/h${boe != null && boe >= wind + 15 ? ', Böen $boe' : ''}',
  ];
  return teile.join(' · ');
}

/// Satz für Screenreader zu einem Tag.
String tagSemantik(VorhersageTag t, DateTime jetzt) {
  final detail = tagDetailText(t);
  return '${tagName(t.datum, jetzt)}, ${t.symbol.text}, Tiefstwert ${t.min.round()} Grad, Höchstwert ${t.max.round()} Grad${detail.isEmpty ? '' : ', $detail'}';
}

/// Stand der Vorhersage in einem Satz ("Stand 14:20"; veraltet mit Hinweis).
String vorhersageStand(VorhersageTeil t, DateTime jetzt) {
  final a = t.aktualisiert;
  final heute = a.year == jetzt.year && a.month == jetzt.month && a.day == jetzt.day;
  final zeit = heute ? uhrText(a) : '${_zwei(a.day)}.${_zwei(a.month)}. ${uhrText(a)}';
  return vorhersageVeraltet(t, jetzt) ? 'Stand $zeit · veraltet' : 'Stand $zeit';
}
