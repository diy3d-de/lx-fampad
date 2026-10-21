// Belegung einer Wochenzeile des Monatsrasters: mehrtägige Termine, Ferien und Feiertage als durchgehende Balken über die Tage (an den
// Wochenrändern abgeschnitten), eintägige Termine als kurze Balken; die Spuren (Zeilen unter der Tageszahl) werden von oben nach unten
// vergeben, passt nicht alles in die verfügbare Höhe, steht je Tag "+n" statt der letzten Spur. Reine Logik ohne Oberfläche (testbar).
// Tage sind wie überall im Kalender `DateTime.utc`-Markierungen der Familienzone.
import 'dart:ui' show Color;

import 'expansion.dart';

/// Art eines Balkens (bestimmt die Reihenfolge bei gleicher Länge: Ferien, Feiertage, Termine).
enum BalkenArt { ferien, feiertag, termin }

/// Ein Eintrag des Rasters über [von] bis [bis] (beide einschließlich).
class BalkenQuelle {
  final String id;
  final String text;
  final Color farbe;
  final BalkenArt art;
  final DateTime von;
  final DateTime bis;

  /// Das Vorkommen hinter einem Termin-Balken (null bei Ferien und Feiertagen).
  final Vorkommen? vorkommen;

  /// Sortierhilfe innerhalb gleicher Länge und gleichen Beginns (Uhrzeit, Titel).
  final String sortierung;
  const BalkenQuelle({required this.id, required this.text, required this.farbe, required this.art, required this.von, required this.bis, this.vorkommen, this.sortierung = ''});

  bool faelltAuf(DateTime tag) => !tag.isBefore(von) && !tag.isAfter(bis);
}

/// Ein sichtbarer Balken einer Woche: Spalten [start] bis [ende] (0 = Montag), Spur [spur] (0 = direkt unter der Tageszahl).
class WochenBalken {
  final BalkenQuelle quelle;
  final int start;
  final int ende;
  final int spur;

  /// Der Eintrag beginnt vor dieser Woche bzw. endet danach (Rand ohne Rundung).
  final bool vorneOffen;
  final bool hintenOffen;
  const WochenBalken({required this.quelle, required this.start, required this.ende, required this.spur, required this.vorneOffen, required this.hintenOffen});

  int get spanne => ende - start + 1;
}

class WochenLayout {
  final List<WochenBalken> balken;

  /// Je Spalte die Anzahl der Einträge, die nicht mehr Platz fanden ("+n").
  final List<int> mehr;

  /// Spuren mit Balken; die Spur danach (Nummer [spuren]) zeigt die "+n", falls [hatMehr].
  final int spuren;
  const WochenLayout({required this.balken, required this.mehr, required this.spuren});

  bool get hatMehr => mehr.any((n) => n > 0);
}

/// Verteilt die Einträge der Woche ab [montag] auf höchstens [maxSpuren] Spuren (inklusive der Spur für "+n").
/// Längere Einträge zuerst (durchgehende Balken liegen oben), bei gleicher Länge Ferien, Feiertage, dann Termine nach Beginn.
WochenLayout wochenLayout({required DateTime montag, required Iterable<BalkenQuelle> quellen, required int maxSpuren}) {
  final sonntag = DateTime.utc(montag.year, montag.month, montag.day + 6);
  final eintraege = <({BalkenQuelle q, int start, int ende})>[];
  for (final q in quellen) {
    if (q.bis.isBefore(montag) || q.von.isAfter(sonntag)) continue;
    final s = q.von.isBefore(montag) ? 0 : q.von.difference(montag).inDays;
    final e = q.bis.isAfter(sonntag) ? 6 : q.bis.difference(montag).inDays;
    eintraege.add((q: q, start: s, ende: e));
  }
  eintraege.sort((a, b) {
    final la = a.q.bis.difference(a.q.von).inDays;
    final lb = b.q.bis.difference(b.q.von).inDays;
    if (la != lb) return lb.compareTo(la);
    final s = a.start.compareTo(b.start);
    if (s != 0) return s;
    final art = a.q.art.index.compareTo(b.q.art.index);
    if (art != 0) return art;
    final t = a.q.sortierung.compareTo(b.q.sortierung);
    return t != 0 ? t : a.q.id.compareTo(b.q.id);
  });

  // Spuren vergeben: die erste Spur, in der alle Spalten des Eintrags frei sind
  final belegt = <List<bool>>[];
  final spur = <int>[];
  for (final e in eintraege) {
    var s = 0;
    for (;; s++) {
      if (s == belegt.length) belegt.add(List.filled(7, false));
      var frei = true;
      for (var c = e.start; c <= e.ende; c++) {
        if (belegt[s][c]) frei = false;
      }
      if (frei) break;
    }
    for (var c = e.start; c <= e.ende; c++) {
      belegt[s][c] = true;
    }
    spur.add(s);
  }

  final maxS = maxSpuren < 0 ? 0 : maxSpuren;
  final passt = belegt.length <= maxS;
  // Überlauf: die letzte Spur gehört den "+n"
  final sichtbar = passt ? belegt.length : (maxS - 1 < 0 ? 0 : maxS - 1);
  final balken = <WochenBalken>[];
  final mehr = List.filled(7, 0);
  for (var i = 0; i < eintraege.length; i++) {
    final e = eintraege[i];
    if (spur[i] < sichtbar) {
      balken.add(WochenBalken(quelle: e.q, start: e.start, ende: e.ende, spur: spur[i], vorneOffen: e.q.von.isBefore(montag), hintenOffen: e.q.bis.isAfter(sonntag)));
    } else {
      for (var c = e.start; c <= e.ende; c++) {
        mehr[c]++;
      }
    }
  }
  return WochenLayout(balken: balken, mehr: mehr, spuren: sichtbar);
}

/// Wie viele Spuren (Balkenzeilen) unter der Tageszahl in eine Wochenzeile der Höhe [zeilenHoehe] passen.
int spurenFuerHoehe(double zeilenHoehe, double tageszeile, double spur) => ((zeilenHoehe - tageszeile - 2) / spur).floor();

/// Ferien und Feiertage werden erst ab drei Spuren als Balken gezeichnet; darunter nähmen sie den Terminen den Platz und erscheinen nur als
/// Zellenfarbe (Tönung bzw. Streifen oben in der Zelle).
const kMinSpurenFuerHinweisbalken = 3;
bool hinweiseAlsBalken(int maxSpuren) => maxSpuren >= kMinSpurenFuerHinweisbalken;

/// ISO-Kalenderwoche (Woche mit dem Donnerstag im Jahr) eines Tages.
int kalenderwoche(DateTime tag) {
  final d = DateTime.utc(tag.year, tag.month, tag.day);
  final donnerstag = d.add(Duration(days: 4 - d.weekday));
  final jahresbeginn = DateTime.utc(donnerstag.year);
  return (donnerstag.difference(jahresbeginn).inDays ~/ 7) + 1;
}

/// Die Montage der Wochen, die ein Monat berührt (Montag der Woche des Ersten bis zur Woche des Letzten).
List<DateTime> wochenDesMonats(DateTime monat) {
  final erster = DateTime.utc(monat.year, monat.month);
  final naechster = DateTime.utc(monat.year, monat.month + 1);
  final montag = erster.subtract(Duration(days: erster.weekday - 1));
  final wochen = ((erster.weekday - 1 + naechster.difference(erster).inDays) / 7).ceil();
  return [for (var i = 0; i < wochen; i++) DateTime.utc(montag.year, montag.month, montag.day + 7 * i)];
}
