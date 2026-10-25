// Termin-Farben (reine Logik): je Termin optional EINE von 11 Farben mit festem Namen (Index 0 bis 10, `Termin.farbe`).
// Ohne Farbe gilt wie bisher die Personenfarbe. Der Farbfilter ist reine Anzeige (lokal), er verändert nie Termine,
// und Termine ohne Farbe blendet er nie aus.
import 'package:flutter/painting.dart';

import '../../constants.dart';

/// Anzahl der Termin-Farben.
int get kTerminFarbenAnzahl => kTerminFarben.length;

/// Ist [index] eine gültige Farbnummer (0 bis 10)?
bool terminFarbeGueltig(int? index) => index != null && index >= 0 && index < kTerminFarben.length;

/// Auf eine gültige Nummer bringen: alles Unbekannte (auch von neueren Apps) gilt als keine Farbe.
int? terminFarbeNummer(int? index) => terminFarbeGueltig(index) ? index : null;

/// Name der Farbe ("Familie" …), null ohne gültige Farbe.
String? terminFarbeName(int? index) => terminFarbeGueltig(index) ? kTerminFarben[index!].name : null;

/// Farbwert, null ohne gültige Farbe.
Color? terminFarbeWert(int? index) => terminFarbeGueltig(index) ? kTerminFarben[index!].farbe : null;

/// Die Farbe für Balken und Punkte: die Termin-Farbe, sonst der Rückfall (Personenfarbe).
Color terminFarbeOderRueckfall(int? index, Color rueckfall) => terminFarbeWert(index) ?? rueckfall;

/// Farbfilter: [aus] enthält die ausgeblendeten Farbnummern. Ohne (gültige) Farbe wird nie ausgeblendet.
bool passtZumFarbFilter(int? farbe, Set<int> aus) => !terminFarbeGueltig(farbe) || !aus.contains(farbe);

/// Zahl der Termine je Farbnummer (ohne gültige Farbe nicht gezählt).
Map<int, int> zaehleFarben(Iterable<int?> farben) {
  final m = <int, int>{};
  for (final f in farben) {
    if (terminFarbeGueltig(f)) m[f!] = (m[f] ?? 0) + 1;
  }
  return m;
}

/// Speicherform des Filters in `sync_meta` (kommagetrennte Nummern der ausgeblendeten Farben, leer = alle an).
String farbFilterAlsText(Set<int> aus) => (aus.where(terminFarbeGueltig).toList()..sort()).join(',');

Set<int> farbFilterAusText(String? text) {
  if (text == null || text.isEmpty) return {};
  return {for (final p in text.split(',')) if (int.tryParse(p.trim()) case final n? when terminFarbeGueltig(n)) n};
}
