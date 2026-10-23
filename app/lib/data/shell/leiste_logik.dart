// Untere Leiste mit "Mehr" (nur mobil, nur lokal je Gerät): reine Logik ohne Oberfläche und ohne Speicher.
//  - Der Seitenstapel behält ALLE Bereiche (Indizes wie `kTabs`); die Leiste zeigt nur [kLeistePlaetze] davon plus das feste Feld "Mehr".
//  - Gemerkt wird die Auswahl samt Reihenfolge als Text mit Kennungen (`leiste_bereiche` in `sync_meta`). Ungültiges (unbekannte Kennung,
//    doppelt, falsche Anzahl, "Start" fehlt) ergibt immer den Standard, nie eine halbe Auswahl.
//  - "Mehr" ist markiert, wenn der aktive Bereich nicht in der Leiste steht.
//  - Die Zahl am Feld "Mehr" ist die Summe der Hinweise aus Einträgen, die hinter "Mehr" liegen (siehe [MehrHinweise]).

/// Anzahl der Bereiche in der Leiste (dazu das feste Feld "Mehr").
const kLeistePlaetze = 4;

/// Schlüssel in `sync_meta`.
const kLeisteSchluessel = 'leiste_bereiche';

/// Der Dateien-Bereich ist noch nicht gebaut: ausgeblendet (mobil und Desktop). Auf `true` setzen, sobald er da ist.
const kDateienSichtbar = false;

/// Kennung eines Bereichs der Leiste (stabil, wird gespeichert) und sein Index im Seitenstapel (Reihenfolge von `kTabs`).
class LeisteBereich {
  final String id;
  final int tab;
  const LeisteBereich(this.id, this.tab);
}

/// Alle Bereiche, die in der Leiste stehen dürfen (Reihenfolge = Reihenfolge von `kTabs`; Dateien nur, wenn sichtbar).
const kLeisteBereiche = <LeisteBereich>[
  LeisteBereich('start', 0),
  LeisteBereich('kalender', 1),
  LeisteBereich('chat', 2),
  if (kDateienSichtbar) LeisteBereich('dateien', 3),
  LeisteBereich('listen', 4),
  LeisteBereich('aufgaben', 5),
];

/// Standard der Leiste (Tab-Indizes): Start, Kalender, Chat, Aufgaben.
const kLeisteStandard = <int>[0, 1, 2, 5];

/// Tab-Indizes aller wählbaren Bereiche.
List<int> get leisteWaehlbar => [for (final b in kLeisteBereiche) b.tab];

/// Ist [tab] ein Bereich des Seitenstapels, der mobil angezeigt werden darf (sonst Start)?
bool mobilerTabGueltig(int tab) => leisteWaehlbar.contains(tab);

String leisteKennung(int tab) => kLeisteBereiche.firstWhere((b) => b.tab == tab).id;

/// Text zum Speichern: Kennungen mit Komma.
String leisteAlsText(List<int> tabs) => tabs.map(leisteKennung).join(',');

/// Liest den gespeicherten Text; alles Ungültige ergibt [kLeisteStandard].
List<int> leisteAusText(String? text) {
  if (text == null || text.trim().isEmpty) return kLeisteStandard;
  final tabs = <int>[];
  for (final teil in text.split(',')) {
    final b = kLeisteBereiche.where((x) => x.id == teil.trim()).firstOrNull;
    if (b == null || tabs.contains(b.tab)) return kLeisteStandard;
    tabs.add(b.tab);
  }
  return leisteGueltig(tabs) ? tabs : kLeisteStandard;
}

/// Genau [kLeistePlaetze] verschiedene wählbare Bereiche, "Start" dabei.
bool leisteGueltig(List<int> tabs) {
  if (tabs.length != kLeistePlaetze || tabs.toSet().length != tabs.length) return false;
  if (!tabs.every(mobilerTabGueltig)) return false;
  return tabs.contains(0);
}

/// Bereiche hinter "Mehr" (die wählbaren, die nicht in der Leiste stehen), in der Reihenfolge von `kTabs`.
List<int> hinterMehr(List<int> leiste) => [for (final t in leisteWaehlbar) if (!leiste.contains(t)) t];

/// Ist "Mehr" in der Leiste markiert (der aktive Bereich steht nicht in der Leiste)?
bool mehrAktiv(int tab, List<int> leiste) => !leiste.contains(tab);

/// Position des aktiven Bereichs in der NavigationBar: Platz in der Leiste, sonst das Feld "Mehr" (letzte Stelle).
int leisteAuswahl(int tab, List<int> leiste) {
  final i = leiste.indexOf(tab);
  return i >= 0 ? i : kLeistePlaetze;
}

/// Verschiebt den Platz [index] um [delta] (-1 hoch, +1 runter); außerhalb des Bereichs bleibt alles.
List<int> leisteSchieben(List<int> leiste, int index, int delta) {
  final ziel = index + delta;
  if (index < 0 || index >= leiste.length || ziel < 0 || ziel >= leiste.length) return leiste;
  final neu = [...leiste];
  neu.insert(ziel, neu.removeAt(index));
  return neu;
}

/// Tauscht den Bereich auf Platz [index] gegen [neu] (muss hinter "Mehr" liegen). "Start" lässt sich nicht herausnehmen: dann bleibt alles.
List<int> leisteErsetzen(List<int> leiste, int index, int neu) {
  if (index < 0 || index >= leiste.length || leiste.contains(neu) || !mobilerTabGueltig(neu)) return leiste;
  if (leiste[index] == 0) return leiste;
  final liste = [...leiste];
  liste[index] = neu;
  return liste;
}

/// Zahlen für die Hinweise hinter "Mehr" (alles lokal berechnet, keine Server-Aufrufe).
class MehrHinweise {
  /// Offene Aufgaben (ohne Fristen), die überfällig oder in den nächsten 7 Tagen fällig sind, und davon die überfälligen.
  final int aufgaben;
  final int aufgabenUeberfaellig;

  /// Fristen, die abgelaufen oder in der Vorwarnzeit sind, und davon die abgelaufenen.
  final int fristen;
  final int fristenUeberfaellig;

  /// Fällige und verpasste Einnahmen heute aus den Plänen, die diese Person sehen darf (Medikamenten-Plan; liegt immer hinter "Mehr").
  final int medikamente;
  const MehrHinweise({this.aufgaben = 0, this.aufgabenUeberfaellig = 0, this.fristen = 0, this.fristenUeberfaellig = 0, this.medikamente = 0});

  /// Summe am Feld "Mehr": Fristen und Medikamente immer (sie liegen immer hinter "Mehr"), Aufgaben nur, wenn der Aufgaben-Bereich hinter "Mehr" liegt
  /// (steht er in der Leiste, sieht man ihn dort ohnehin).
  int summe(List<int> leiste) => fristen + medikamente + (leiste.contains(5) ? 0 : aufgaben);

  /// Ist darunter etwas Überfälliges (rotes Zeichen statt gelbem)?
  bool ueberfaellig(List<int> leiste) => fristenUeberfaellig > 0 || (!leiste.contains(5) && aufgabenUeberfaellig > 0);
}

/// Zeichen am Feld "Mehr" und an den Kacheln: Zahl über 9 als "9+".
String hinweisText(int n) => n > 9 ? '9+' : '$n';
