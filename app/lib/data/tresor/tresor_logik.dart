// Tresor (Abschnitt 6m): reine Logik ohne Datenbank, Schlüssel und Oberfläche: Suche, Zähler je Kategorie, Sortierung, Felder ordnen, Prüfung mit deutschen Meldungen.
//
// Suche: NUR innerhalb des geöffneten Tresors, im Speicher, über Titel, Feld-Bezeichnungen und NICHT geheime Werte (auch den Namen einer eigenen Kategorie). Geheime Werte und die Notiz
// (dort stehen oft Zugangsdaten) werden nie durchsucht, es gibt keinen Index, keine Persistenz und keinen Treffer aus dem Tresor in der globalen Suche.
import 'dart:convert';

import 'tresor_modelle.dart';

// ---------------------------------------------------------------- Sortierung und Zähler

String _schluessel(String s) => foldeText(s);

/// Kleinschreibung mit gefalteten deutschen Umlauten und ß (Suche und Sortierung ohne Rücksicht darauf): "Ärzte" findet "arzte" und "aerzte".
String foldeText(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    b.write(switch (r) {
      0xE4 => 'ae',
      0xF6 => 'oe',
      0xFC => 'ue',
      0xDF => 'ss',
      _ => String.fromCharCode(r),
    });
  }
  return b.toString();
}

/// Reihenfolge in der Liste: nach Kategorie (feste Reihenfolge, eigene zuletzt, unter sich nach Namen), dann nach Titel, am Ende nach [id] (stabil).
int tresorVergleich(TresorInhalt a, String idA, TresorInhalt b, String idB) {
  final k = a.kategorie.index.compareTo(b.kategorie.index);
  if (k != 0) return k;
  if (a.kategorie == TresorKategorie.eigene) {
    final n = _schluessel(a.kategorieName).compareTo(_schluessel(b.kategorieName));
    if (n != 0) return n;
  }
  final t = _schluessel(a.titel).compareTo(_schluessel(b.titel));
  return t != 0 ? t : idA.compareTo(idB);
}

/// Einträge sortiert nach [tresorVergleich] (Original bleibt unverändert).
List<T> tresorSortieren<T>(Iterable<T> eintraege, TresorInhalt Function(T) inhalt, String Function(T) id) => [...eintraege]..sort((a, b) => tresorVergleich(inhalt(a), id(a), inhalt(b), id(b)));

/// Wie viele Einträge je Kategorie (jede Kategorie kommt vor, auch mit 0).
Map<TresorKategorie, int> tresorKategorieZaehler(Iterable<TresorInhalt> eintraege) {
  final m = {for (final k in TresorKategorie.values) k: 0};
  for (final e in eintraege) {
    m[e.kategorie] = m[e.kategorie]! + 1;
  }
  return m;
}

/// Namen der eigenen Kategorien, die vorkommen (eindeutig, nach Namen sortiert): für die Auswahl beim Anlegen.
List<String> tresorEigeneKategorien(Iterable<TresorInhalt> eintraege) {
  final vorhanden = <String, String>{};
  for (final e in eintraege) {
    if (e.kategorie == TresorKategorie.eigene) vorhanden.putIfAbsent(_schluessel(e.kategorieName.trim()), () => e.kategorieName.trim());
  }
  final keys = vorhanden.keys.toList()..sort();
  return [for (final k in keys) vorhanden[k]!];
}

// ---------------------------------------------------------------- Suche

/// Welche Einträge passen zur Suche [anfrage]? Jedes Wort der Anfrage muss in Titel, Kategorie-Name, einer Feld-Bezeichnung oder einem nicht geheimen Wert vorkommen (Teilstring, ohne Rücksicht
/// auf Groß-/Kleinschreibung und Umlaute). Leere Anfrage: alle. Geheime Werte und die Notiz zählen nie.
List<T> tresorSuchen<T>(Iterable<T> eintraege, TresorInhalt Function(T) inhalt, String anfrage) {
  final woerter = [for (final w in _schluessel(anfrage).split(RegExp(r'\s+'))) if (w.isNotEmpty) w];
  if (woerter.isEmpty) return eintraege.toList();
  return [
    for (final e in eintraege)
      if (_passt(inhalt(e), woerter)) e,
  ];
}

bool _passt(TresorInhalt t, List<String> woerter) {
  final heu = _durchsuchbar(t);
  return woerter.every(heu.contains);
}

String _durchsuchbar(TresorInhalt t) {
  final teile = <String>[t.titel, t.kategorieAnzeige];
  for (final f in t.felder) {
    teile.add(f.bezeichnung);
    if (!f.geheim) teile.add(f.wert);
  }
  return _schluessel(teile.join('\n'));
}

// ---------------------------------------------------------------- Felder ordnen

/// Verschiebt das Feld an Stelle [von] an Stelle [nach] (Zielindex wie bei `ReorderableListView` NACH dem Herausnehmen, also 0 bis Länge-1). Ungültige Indizes ändern nichts.
List<TresorFeld> tresorFeldVerschieben(List<TresorFeld> felder, int von, int nach) {
  if (von < 0 || von >= felder.length || nach < 0 || nach >= felder.length || von == nach) return List.of(felder);
  final neu = List.of(felder);
  final f = neu.removeAt(von);
  neu.insert(nach, f);
  return neu;
}

/// Hängt ein Feld an (höchstens [kMaxTresorFelder]); bei Überschreitung unverändert.
List<TresorFeld> tresorFeldHinzu(List<TresorFeld> felder, TresorFeld neu) => felder.length >= kMaxTresorFelder ? List.of(felder) : [...felder, neu];

List<TresorFeld> tresorFeldEntfernen(List<TresorFeld> felder, int index) => [for (var i = 0; i < felder.length; i++) if (i != index) felder[i]];

List<TresorFeld> tresorFeldErsetzen(List<TresorFeld> felder, int index, TresorFeld neu) => [for (var i = 0; i < felder.length; i++) i == index ? neu : felder[i]];

/// Entfernt Felder, die ganz leer sind (weder Wert noch Bezeichnung): beim Speichern aus der Eingabemaske.
List<TresorFeld> tresorLeereFelderWeg(List<TresorFeld> felder) => [for (final f in felder) if (f.bezeichnung.trim().isNotEmpty || f.wert.isNotEmpty) f];

// ---------------------------------------------------------------- Prüfung

/// Was an einem Eintrag nicht stimmt (für die Meldung in der Eingabemaske).
enum TresorProblem {
  titelFehlt('Gib dem Eintrag einen Titel.'),
  titelZuLang('Der Titel ist zu lang ($kMaxTresorTitel Zeichen).'),
  kategorieNameFehlt('Gib deiner eigenen Kategorie einen Namen.'),
  kategorieNameZuLang('Der Name der Kategorie ist zu lang ($kMaxTresorKategorieName Zeichen).'),
  zuVieleFelder('Ein Eintrag hat höchstens $kMaxTresorFelder Felder.'),
  bezeichnungFehlt('Jedes Feld braucht eine Bezeichnung.'),
  bezeichnungZuLang('Eine Bezeichnung ist zu lang ($kMaxTresorBezeichnung Zeichen).'),
  wertZuLang('Ein Wert ist zu lang ($kMaxTresorWert Zeichen).'),
  notizZuLang('Die Notiz ist zu lang ($kMaxTresorNotiz Zeichen).'),
  zuGross('Der Eintrag ist zu groß. Kürze Werte oder Notiz.');

  final String meldung;
  const TresorProblem(this.meldung);
}

/// Alle Probleme eines Eintrags (leer: kann gespeichert werden). Stimmt mit [TresorInhalt.gueltig] und [tresorKodieren] überein.
List<TresorProblem> tresorProbleme(TresorInhalt t) {
  final p = <TresorProblem>[];
  if (t.titel.trim().isEmpty) p.add(TresorProblem.titelFehlt);
  if (t.titel.length > kMaxTresorTitel) p.add(TresorProblem.titelZuLang);
  if (t.kategorie == TresorKategorie.eigene) {
    if (t.kategorieName.trim().isEmpty) p.add(TresorProblem.kategorieNameFehlt);
    if (t.kategorieName.length > kMaxTresorKategorieName) p.add(TresorProblem.kategorieNameZuLang);
  }
  if (t.felder.length > kMaxTresorFelder) p.add(TresorProblem.zuVieleFelder);
  if (t.felder.any((f) => f.bezeichnung.trim().isEmpty)) p.add(TresorProblem.bezeichnungFehlt);
  if (t.felder.any((f) => f.bezeichnung.length > kMaxTresorBezeichnung)) p.add(TresorProblem.bezeichnungZuLang);
  if (t.felder.any((f) => f.wert.length > kMaxTresorWert)) p.add(TresorProblem.wertZuLang);
  if (t.notiz.length > kMaxTresorNotiz) p.add(TresorProblem.notizZuLang);
  if (p.isEmpty && !t.gueltig) p.add(TresorProblem.titelFehlt);
  if (p.isEmpty && utf8.encode('$kPraefixTresor${jsonEncode(t.toJson())}').length > kMaxKlartextBytesTresor) p.add(TresorProblem.zuGross);
  return p;
}
