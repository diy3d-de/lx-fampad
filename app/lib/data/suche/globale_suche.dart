// Globale Suche über die lokalen Daten (Termine, Aufgaben, Listen, Listeneinträge). Rein und ohne Server: Eingabe sind die Zeilen der lokalen
// Datenbank (was dort liegt, hat der Abgleich schon nach Rechten gefiltert), Ausgabe sind Treffer je Bereich mit Hervorhebung. Geburtstage
// (Termine mit Marke) und Ferien/Feiertage (nur Anzeige, keine Daten) sind nicht dabei; Chat, Standort und Schlüssel ebenfalls nicht.
import '../app_database.dart';
import '../calendar/expansion.dart' show tagAusText;
import '../calendar/geburtstag.dart' show hatGeburtstagsMarke;
import '../calendar/zeitzonen.dart';
import 'such_logik.dart';

/// Höchstzahl der gezeigten Treffer je Bereich.
const kSucheMaxJeBereich = 20;

/// Kürzeste Eingabe, ab der gesucht wird (Zeichen nach der Normalisierung).
const kSucheMinZeichen = 2;

enum SuchBereich { termine, aufgaben, listen, eintraege }

/// Ein Treffer: [titel] ist der Haupttext (mit [titelBereiche]), [zusatz] eine Zeile darunter (Ort, Liste ...), [auszug] der getroffene Teil
/// einer Beschreibung oder Notiz, wenn der Titel allein nicht alle Wörter enthält.
class SuchTreffer {
  final SuchBereich bereich;
  final String id;

  /// Bei Listeneinträgen die Liste des Eintrags.
  final String? listId;
  final String titel;
  final List<TextBereich> titelBereiche;
  final String zusatz;
  final Ausschnitt? auszug;

  /// Im Titel steht mindestens ein Suchwort (solche Treffer stehen vor reinen Beschreibungs-Treffern).
  final bool imTitel;

  /// Sortierhilfe und Anzeige: Beginn bzw. Fälligkeit (Wanduhr der Familienzone); null = ohne.
  final DateTime? datum;
  final bool erledigt;
  const SuchTreffer({
    required this.bereich,
    required this.id,
    this.listId,
    required this.titel,
    this.titelBereiche = const [],
    this.zusatz = '',
    this.auszug,
    this.imTitel = true,
    this.datum,
    this.erledigt = false,
  });
}

/// Treffer einer Gruppe: die ersten [kSucheMaxJeBereich], dazu die Gesamtzahl.
class SuchGruppe {
  final SuchBereich bereich;
  final List<SuchTreffer> treffer;
  final int gesamt;
  const SuchGruppe(this.bereich, this.treffer, this.gesamt);

  int get weitere => gesamt - treffer.length;
}

class SuchErgebnis {
  final List<SuchGruppe> gruppen;
  const SuchErgebnis(this.gruppen);

  static const leer = SuchErgebnis([]);

  bool get istLeer => gruppen.isEmpty;
  int get gesamt => gruppen.fold(0, (s, g) => s + g.gesamt);
  SuchGruppe? gruppe(SuchBereich b) => gruppen.where((g) => g.bereich == b).firstOrNull;
}

DateTime? _wand(DateTime? instant) {
  if (instant == null) return null;
  return zeitzonenBereit() ? wandUhr(instant.toUtc(), familienOrt) : instant.toUtc();
}

/// Beginn eines Termins als Kalendertag bzw. Wanduhrzeit der Familienzone (UTC-Markierung); null, wenn keine Zeit vorliegt.
DateTime? terminBeginn(Termin t) => t.ganztaegig ? tagAusText(t.startDate) : _wand(t.startUtc);

/// Bewertet einen Datensatz: jedes Wort muss in irgendeinem Feld (Titel oder weitere Felder) vorkommen. Ergebnis: Bereiche im Titel und der erste
/// getroffene Auszug aus einem weiteren Feld; null = kein Treffer.
({List<TextBereich> titel, Ausschnitt? auszug, bool imTitel})? _bewerte(String titel, List<String> weitere, List<String> woerter) {
  final alle = [titel, ...weitere];
  final texte = alle.map(Suchtext.new).toList();
  for (final w in woerter) {
    if (!texte.any((t) => t.wort(w) != null)) return null;
  }
  List<TextBereich> bereicheIn(int i) => zusammenfuehren([for (final w in woerter) ...?texte[i].wort(w)]);

  final imTitel = bereicheIn(0);
  Ausschnitt? auszug;
  for (var i = 1; i < alle.length; i++) {
    final b = bereicheIn(i);
    if (b.isNotEmpty) {
      auszug = ausschnitt(alle[i], b, max: 100);
      break;
    }
  }
  return (titel: imTitel, auszug: auszug, imTitel: imTitel.isNotEmpty);
}

SuchGruppe? _gruppe(SuchBereich b, List<SuchTreffer> t) {
  if (t.isEmpty) return null;
  t.sort((x, y) {
    if (x.imTitel != y.imTitel) return x.imTitel ? -1 : 1;
    if (x.erledigt != y.erledigt) return x.erledigt ? 1 : -1;
    final dx = x.datum;
    final dy = y.datum;
    if (dx != null && dy != null && dx != dy) return dx.compareTo(dy);
    if ((dx == null) != (dy == null)) return dx == null ? 1 : -1;
    return x.titel.toLowerCase().compareTo(y.titel.toLowerCase());
  });
  return SuchGruppe(b, t.take(kSucheMaxJeBereich).toList(), t.length);
}

/// Sucht in den lokalen Daten. Zu kurze oder leere Eingabe: leeres Ergebnis. Einträge von Listen, die lokal nicht (mehr) vorhanden sind, zählen nicht.
SuchErgebnis sucheGlobal({
  required String eingabe,
  required List<Termin> termine,
  required List<Aufgabe> aufgaben,
  required List<Liste> listen,
  required List<Listeneintrag> eintraege,
}) {
  final woerter = suchWoerter(eingabe);
  if (woerter.isEmpty || normalisiere(eingabe).trim().length < kSucheMinZeichen) return SuchErgebnis.leer;

  final tT = <SuchTreffer>[];
  for (final t in termine) {
    if (hatGeburtstagsMarke(t)) continue;
    final r = _bewerte(t.titel, [t.ort, t.beschreibung], woerter);
    if (r == null) continue;
    tT.add(SuchTreffer(
      bereich: SuchBereich.termine,
      id: t.id,
      titel: t.titel,
      titelBereiche: r.titel,
      zusatz: t.ort.trim(),
      auszug: r.auszug,
      imTitel: r.imTitel,
      datum: terminBeginn(t),
    ));
  }

  final tA = <SuchTreffer>[];
  for (final a in aufgaben) {
    final r = _bewerte(a.titel, [a.beschreibung], woerter);
    if (r == null) continue;
    tA.add(SuchTreffer(
      bereich: SuchBereich.aufgaben,
      id: a.id,
      titel: a.titel,
      titelBereiche: r.titel,
      auszug: r.auszug,
      imTitel: r.imTitel,
      datum: a.faelligDate != null ? tagAusText(a.faelligDate) : _wand(a.faelligUtc),
      erledigt: a.erledigtAt != null,
    ));
  }

  final tL = <SuchTreffer>[];
  for (final l in listen) {
    final r = _bewerte(l.name, const [], woerter);
    if (r == null) continue;
    tL.add(SuchTreffer(bereich: SuchBereich.listen, id: l.id, titel: l.name, titelBereiche: r.titel));
  }

  final namen = {for (final l in listen) l.id: l.name};
  final tE = <SuchTreffer>[];
  for (final e in eintraege) {
    final liste = namen[e.listId];
    if (liste == null) continue;
    final r = _bewerte(e.inhalt, const [], woerter);
    if (r == null) continue;
    tE.add(SuchTreffer(bereich: SuchBereich.eintraege, id: e.id, listId: e.listId, titel: e.inhalt, titelBereiche: r.titel, zusatz: liste, erledigt: e.doneAt != null));
  }

  return SuchErgebnis([
    ?_gruppe(SuchBereich.termine, tT),
    ?_gruppe(SuchBereich.aufgaben, tA),
    ?_gruppe(SuchBereich.listen, tL),
    ?_gruppe(SuchBereich.eintraege, tE),
  ]);
}
