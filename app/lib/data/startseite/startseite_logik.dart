// Startseite anpassen: Kacheln verschieben und ausblenden. Reine Logik ohne Oberfläche und ohne Speicher.
//  - Jede Kachel hat eine stabile Kennung (String). Gemerkt wird die Reihenfolge ALLER bekannten Kacheln und die Menge der ausgeblendeten,
//    getrennt je Layout (Handy-Liste und Desktop-Raster haben verschiedene Kacheln).
//  - Beim Laden: unbekannte Kennungen fallen weg, fehlende (später dazugekommene) Kacheln kommen ans Ende.
//  - Bedingte Kacheln (Müll, Wetter, Geburtstage ohne Treffer) behalten ihre gemerkte Stelle, auch wenn sie gerade nicht angezeigt werden:
//    verschoben wird immer nur die Teilmenge der sichtbaren Kacheln, die übrigen bleiben auf ihren Plätzen ([teilmengeNeuOrdnen]).
//  - Fest oben stehen (nicht in dieser Liste, nicht verschiebbar, nicht ausblendbar): Update-Hinweis und die Warnkarte "Bin ich abgesichert?".
import 'dart:convert';


enum StartLayout {
  mobil,
  desktop;

  /// Schlüssel in `sync_meta` (nur lokal je Gerät, nie synchronisiert).
  String get reihenfolgeSchluessel => 'startseite_reihenfolge_$name';
  String get ausgeblendetSchluessel => 'startseite_ausgeblendet_$name';

  List<StartKachel> get kacheln => this == StartLayout.mobil ? kMobilKacheln : kDesktopKacheln;
  List<String> get standard => [for (final k in kacheln) k.id];

  /// Anzeigename des Layouts in den Texten der Oberfläche.
  String get anzeigename => this == StartLayout.mobil ? 'Handy-Ansicht' : 'Desktop-Ansicht';
}

class StartKachel {
  final String id;
  final String titel;

  /// Kurze Beschreibung für die Anpassen-Seite (Mono, klein).
  final String hinweis;
  const StartKachel(this.id, this.titel, this.hinweis);
}

/// Kacheln der Handy-Startseite in der Standardreihenfolge.
const kMobilKacheln = <StartKachel>[
  StartKachel('schnellzugriff', 'Schnellzugriff', 'termin, eintrag, foto, datei'),
  StartKachel('einkauf', 'Einkaufsliste', 'offene einträge'),
  StartKachel('termine', 'Als nächstes', 'die nächsten termine'),
  StartKachel('geburtstage', 'Geburtstage', 'erscheint nur, wenn einer ansteht'),
  StartKachel('aufgaben', 'Aufgaben', 'überfällig und bald fällig'),
  StartKachel('muell', 'Müll', 'nächste abholung'),
  StartKachel('wetter', 'Wetter', 'deine wetterstation'),
  StartKachel('standort', 'Standort', 'standort teilen'),
  StartKachel('countdown', 'Countdown', 'erscheint nur mit gewähltem termin'),
  StartKachel('fristen', 'Fristen', 'erscheint nur, wenn eine frist bald abläuft'),
  StartKachel('medikamente', 'Medikamente', 'erscheint nur mit offenen einnahmen'),
  StartKachel('zaehler', 'Ablesen fällig', 'nur für eltern, erscheint nur, wenn etwas ansteht'),
];

/// Kacheln des Desktop-Rasters in der Standardreihenfolge.
const kDesktopKacheln = <StartKachel>[
  StartKachel('termine', 'Heute und morgen', 'termine'),
  StartKachel('chat', 'Chat', 'letzte nachrichten'),
  StartKachel('einkauf', 'Einkaufsliste', 'offene einträge'),
  // "Zuletzt geteilt": nur wenn der Server die Dateiablage meldet (startseite_verfuegbar.dart)
  StartKachel('dateien', 'Zuletzt geteilt', 'erscheint nur mit der dateiablage'),
  StartKachel('aufgaben', 'Aufgaben', 'offene aufgaben'),
  StartKachel('familie', 'Familie & Orte', 'mitglieder'),
  StartKachel('standort', 'Standort', 'standort teilen'),
  StartKachel('muell', 'Müll', 'nächste abholung'),
  StartKachel('wetter', 'Wetter', 'deine wetterstation'),
  StartKachel('countdown', 'Countdown', 'erscheint nur mit gewähltem termin'),
  StartKachel('fristen', 'Fristen', 'erscheint nur, wenn eine frist bald abläuft'),
  StartKachel('medikamente', 'Medikamente', 'erscheint nur mit offenen einnahmen'),
  StartKachel('zaehler', 'Ablesen fällig', 'nur für eltern, erscheint nur, wenn etwas ansteht'),
];

/// Welche Kacheln es gerade gibt: [angeboten] (Feature ist da, erscheint in der Anpassen-Seite) und davon [leer] (gerade nichts zu zeigen,
/// z. B. Geburtstage ohne Treffer: nicht gezeichnet, aber auf der Anpassen-Seite aufgeführt).
class KachelVerfuegbarkeit {
  final Set<String> angeboten;
  final Set<String> leer;
  const KachelVerfuegbarkeit({required this.angeboten, this.leer = const {}});

  /// Alles da (für Tests und als Anfangswert).
  factory KachelVerfuegbarkeit.alle(StartLayout l) => KachelVerfuegbarkeit(angeboten: {...l.standard});

  @override
  bool operator ==(Object other) => other is KachelVerfuegbarkeit && _gleich(other.angeboten, angeboten) && _gleich(other.leer, leer);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(angeboten), Object.hashAllUnordered(leer));
}

bool _gleich(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// Gemerkte Reihenfolge mit der Standardliste zusammenführen: nur bekannte Kennungen (einmal), fehlende ans Ende in Standardreihenfolge.
/// [gemerkt] null (nichts gespeichert oder nicht lesbar) ergibt die Standardreihenfolge.
List<String> vollstaendigeReihenfolge(List<String> standard, Iterable<String>? gemerkt) {
  final bekannt = standard.toSet();
  final out = <String>[];
  for (final id in gemerkt ?? const <String>[]) {
    if (bekannt.contains(id) && !out.contains(id)) out.add(id);
  }
  for (final id in standard) {
    if (!out.contains(id)) out.add(id);
  }
  return out;
}

/// Ausgeblendete Kennungen auf die bekannten beschränken.
Set<String> bekannteAusgeblendete(List<String> standard, Iterable<String>? gemerkt) => {
  for (final id in gemerkt ?? const <String>[])
    if (standard.contains(id)) id,
};

/// Die gezeichneten Kacheln in gemerkter Reihenfolge: angeboten, nicht leer, nicht ausgeblendet.
List<String> sichtbareKacheln({required List<String> reihenfolge, required KachelVerfuegbarkeit verfuegbar, required Set<String> ausgeblendet}) => [
  for (final id in reihenfolge)
    if (verfuegbar.angeboten.contains(id) && !verfuegbar.leer.contains(id) && !ausgeblendet.contains(id)) id,
];

/// Die auf der Anpassen-Seite aufgeführten Kacheln (angeboten, auch ausgeblendete) in gemerkter Reihenfolge.
List<String> angeboteneKacheln({required List<String> reihenfolge, required KachelVerfuegbarkeit verfuegbar}) => [
  for (final id in reihenfolge)
    if (verfuegbar.angeboten.contains(id)) id,
];

/// Setzt die Teilmenge [teilNeu] (neue Reihenfolge einiger Kennungen aus [voll]) in [voll] ein: Die Plätze der Teilmenge bleiben, nur ihre
/// Besetzung folgt der neuen Reihenfolge; alle anderen Kennungen (gerade nicht angezeigte, ausgeblendete) bleiben unverändert auf ihren Plätzen.
/// Kennungen in [teilNeu], die [voll] nicht kennt, werden ignoriert; fehlen Kennungen der Teilmenge, behalten diese ihren Platz.
List<String> teilmengeNeuOrdnen(List<String> voll, List<String> teilNeu) {
  final vorhanden = voll.toSet();
  final neu = <String>[
    for (final id in teilNeu)
      if (vorhanden.contains(id)) id,
  ];
  final menge = neu.toSet();
  if (menge.length != neu.length) return List.of(voll); // doppelte Kennung: nichts ändern
  var i = 0;
  return [for (final id in voll) menge.contains(id) ? neu[i++] : id];
}

/// [id] um [delta] Plätze innerhalb von [teil] verschieben (die Reihenfolge der angezeigten Kacheln), begrenzt auf Anfang und Ende;
/// ergibt die neue vollständige Reihenfolge. Unbekannte Kennung: unverändert.
List<String> verschiebeUm(List<String> voll, List<String> teil, String id, int delta) {
  final von = teil.indexOf(id);
  if (von < 0) return List.of(voll);
  final nach = (von + delta).clamp(0, teil.length - 1);
  if (nach == von) return List.of(voll);
  final neu = List.of(teil)..removeAt(von);
  neu.insert(nach, id);
  return teilmengeNeuOrdnen(voll, neu);
}

/// Liste von Kennungen als Text für `sync_meta` (JSON-Array von Strings).
String kennungenAlsText(Iterable<String> ids) => jsonEncode(ids.toList());

/// Liest eine gespeicherte Kennungsliste; fehlender oder defekter Wert ergibt null (dann gilt die Standardreihenfolge).
List<String>? kennungenAusText(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final j = jsonDecode(text);
    if (j is! List) return null;
    return [
      for (final e in j)
        if (e is String) e,
    ];
  } catch (_) {
    return null;
  }
}

/// Gemerkter Stand eines Layouts: vollständige Reihenfolge, ausgeblendete Kacheln und ob die gespeicherten Werte schon gelesen sind.
class StartAnordnung {
  final List<String> reihenfolge;
  final Set<String> ausgeblendet;
  final bool geladen;
  const StartAnordnung({required this.reihenfolge, this.ausgeblendet = const {}, this.geladen = false});

  factory StartAnordnung.standard(StartLayout l, {bool geladen = false}) => StartAnordnung(reihenfolge: l.standard, geladen: geladen);

  /// Aus den gespeicherten Texten (null = nichts gespeichert oder nicht lesbar).
  factory StartAnordnung.aus(StartLayout l, {String? reihenfolgeText, String? ausgeblendetText}) => StartAnordnung(
    reihenfolge: vollstaendigeReihenfolge(l.standard, kennungenAusText(reihenfolgeText)),
    ausgeblendet: bekannteAusgeblendete(l.standard, kennungenAusText(ausgeblendetText)),
    geladen: true,
  );

  /// Standardreihenfolge und nichts ausgeblendet.
  bool istStandard(StartLayout l) => ausgeblendet.isEmpty && _listeGleich(reihenfolge, l.standard);

  StartAnordnung kopie({List<String>? reihenfolge, Set<String>? ausgeblendet, bool? geladen}) =>
      StartAnordnung(reihenfolge: reihenfolge ?? this.reihenfolge, ausgeblendet: ausgeblendet ?? this.ausgeblendet, geladen: geladen ?? this.geladen);
}

bool _listeGleich(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Gleiche Reihenfolge und gleiche ausgeblendete Kacheln (für "nichts geändert, nichts schreiben").
bool gleicheAnordnung(StartAnordnung a, StartAnordnung b) => _listeGleich(a.reihenfolge, b.reihenfolge) && _gleich(a.ausgeblendet, b.ausgeblendet);
