// Reine Logik der Einkaufsliste: Kategorien nach Supermarkt-Gang, Vorschlag aus dem Namen, Gruppierung und "Zuletzt gekauft".
// Keine Datenbank, kein Netz: alles rechnet auf den lokalen Einträgen.
import '../app_database.dart';
import 'list_repository.dart';

/// Kategorie eines Eintrags. Die Reihenfolge der Werte ist der typische Gang durch den Supermarkt.
enum EinkaufKategorie {
  obstGemuese('obst_gemuese', 'Obst und Gemüse'),
  brotBackwaren('brot_backwaren', 'Brot und Backwaren'),
  milchKuehlregal('milch_kuehlregal', 'Milch und Kühlregal'),
  fleischFisch('fleisch_fisch', 'Fleisch und Fisch'),
  tiefkuehl('tiefkuehl', 'Tiefkühl'),
  vorratKonserven('vorrat_konserven', 'Vorrat und Konserven'),
  getraenke('getraenke', 'Getränke'),
  haushaltDrogerie('haushalt_drogerie', 'Haushalt und Drogerie'),
  sonstiges('sonstiges', 'Sonstiges');

  final String wire;
  final String label;
  const EinkaufKategorie(this.wire, this.label);

  /// `null` und unbekannte Kennungen (neuere Apps) gelten als "Sonstiges".
  static EinkaufKategorie von(String? wire) => values.firstWhere((k) => k.wire == wire, orElse: () => EinkaufKategorie.sonstiges);
}

/// Kleine Stichwort-Tabelle (Kleinschreibung): Teilwort des Namens -> Kategorie. Ein Stichwort mit Leerzeichen am Rand passt nur auf ein ganzes Wort.
const Map<EinkaufKategorie, List<String>> _stichworte = {
  EinkaufKategorie.obstGemuese: [
    'apfel', 'äpfel', 'banane', 'birne', 'orange', 'zitrone', 'traube', 'erdbeere', 'beere', 'melone', 'kiwi', 'mango', 'avocado',
    'tomate', 'gurke', 'paprika', 'zwiebel', 'knoblauch', 'kartoffel', 'karotte', 'möhre', 'salat', 'spinat', 'brokkoli', 'blumenkohl',
    'zucchini', 'pilz', 'champignon', 'lauch', 'kohl', 'radieschen', 'ingwer', 'kräuter', 'petersilie', 'basilikum', 'obst', 'gemüse',
  ],
  EinkaufKategorie.brotBackwaren: ['brot', 'brötchen', 'semmel', 'toast', 'croissant', 'laugen', 'kuchen', 'baguette', 'zwieback', 'knäcke'],
  EinkaufKategorie.milchKuehlregal: [
    'milch', 'butter', 'käse', 'joghurt', 'quark', 'sahne', 'schmand', ' ei ', 'eier', 'margarine', 'mozzarella',
    'parmesan', 'pudding', 'skyr', 'wurst', 'schinken', 'salami', 'aufschnitt', 'hummus',
  ],
  EinkaufKategorie.fleischFisch: ['fleisch', 'hähnchen', 'hühnchen', 'pute', 'hack', 'steak', 'schnitzel', 'lachs', 'fisch', 'thunfisch', 'garnele', 'bratwurst', 'speck'],
  EinkaufKategorie.tiefkuehl: ['tiefkühl', 'pizza', 'pommes', ' eis ', 'fischstäbchen', 'gefrorene'],
  EinkaufKategorie.vorratKonserven: [
    'nudel', 'spaghetti', 'reis', 'mehl', 'zucker', 'salz', 'pfeffer', ' öl ', 'olivenöl', 'essig', 'konserve', 'dose', 'bohnen', 'linsen', 'müsli',
    'haferflocken', 'cornflakes', 'marmelade', 'honig', 'nutella', 'schokolade', 'kekse', 'chips', 'nüsse', 'soße', 'sauce', 'ketchup',
    'senf', 'suppe', 'kaffee', ' tee ', 'kakao', 'backpulver', 'passierte',
  ],
  EinkaufKategorie.getraenke: ['wasser', 'saft', 'limo', 'cola', 'bier', 'wein', 'sekt', 'sprudel', 'schorle', 'getränk'],
  EinkaufKategorie.haushaltDrogerie: [
    'toilettenpapier', 'klopapier', 'küchenrolle', 'spülmittel', 'waschmittel', 'spülmaschine', 'müllbeutel', 'müllsack', 'zahnpasta',
    'zahnbürste', 'shampoo', 'duschgel', 'seife', 'deo', 'taschentücher', 'windeln', 'batterie', 'glühbirne', 'schwamm', 'reiniger',
    'frischhaltefolie', 'alufolie', 'backpapier', 'creme', 'tampon',
  ],
};

String _norm(String s) => s.trim().toLowerCase();

/// Schlägt aus dem Namen eine Kategorie vor: erst die Stichwort-Tabelle (längstes passendes Stichwort gewinnt), sonst die zuletzt für
/// denselben Namen (ohne Groß-/Kleinschreibung) gewählte Kategorie aus [vorhandene], sonst "Sonstiges".
EinkaufKategorie schlageKategorieVor(String name, {Iterable<Listeneintrag> vorhandene = const []}) {
  final norm = _norm(name);
  if (norm.isEmpty) return EinkaufKategorie.sonstiges;
  final n = ' $norm ';
  EinkaufKategorie? treffer;
  var laenge = 0;
  for (final eintrag in _stichworte.entries) {
    for (final w in eintrag.value) {
      if (n.contains(w) && w.trim().length > laenge) {
        treffer = eintrag.key;
        laenge = w.trim().length;
      }
    }
  }
  if (treffer != null) return treffer;
  final gleiche = vorhandene.where((e) => e.category != null && _norm(e.inhalt) == norm).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return gleiche.isEmpty ? EinkaufKategorie.sonstiges : EinkaufKategorie.von(gleiche.first.category);
}

/// Eine Gruppe offener Einträge einer Kategorie.
class KategorieGruppe {
  final EinkaufKategorie kategorie;
  final List<Listeneintrag> eintraege;
  const KategorieGruppe(this.kategorie, this.eintraege);
}

/// Offene Einträge nach Kategorie in Gang-Reihenfolge; leere Kategorien entfallen, innerhalb einer Gruppe gilt die Sortierung der Liste.
List<KategorieGruppe> gruppiereOffene(List<Listeneintrag> alle) {
  final offen = sortiereEintraege(alle).where((e) => e.doneAt == null).toList();
  return [
    for (final k in EinkaufKategorie.values)
      if (offen.any((e) => EinkaufKategorie.von(e.category) == k)) KategorieGruppe(k, [for (final e in offen) if (EinkaufKategorie.von(e.category) == k) e]),
  ];
}

/// Erledigte Einträge (zuletzt erledigte zuerst), für den Bereich unter den Gruppen.
List<Listeneintrag> erledigteEintraege(List<Listeneintrag> alle) => sortiereEintraege(alle).where((e) => e.doneAt != null).toList();

/// Vorschlag "Zuletzt gekauft".
class Kaufvorschlag {
  final String name;
  final EinkaufKategorie kategorie;
  final int anzahl;
  const Kaufvorschlag(this.name, this.kategorie, this.anzahl);
}

/// Vorschläge aus bereits abgehakten Einträgen der Familie. [eingabe] filtert (Teilwort, ohne Groß-/Kleinschreibung; leer: nichts);
/// Namen, die in [offeneNamen] schon auf der Liste stehen, entfallen. Häufigste zuerst, bei Gleichstand der zuletzt abgehakte;
/// Duplikate nach Name (ohne Groß-/Kleinschreibung) zusammengefasst, Name und Kategorie vom jüngsten Eintrag, höchstens [max].
List<Kaufvorschlag> zuletztGekauft(Iterable<Listeneintrag> alle, String eingabe, {Set<String> offeneNamen = const {}, int max = 8}) {
  final q = _norm(eingabe);
  if (q.isEmpty) return const [];
  final offen = {for (final n in offeneNamen) _norm(n)};
  final je = <String, List<Listeneintrag>>{};
  for (final e in alle) {
    if (e.doneAt == null) continue;
    final k = _norm(e.inhalt);
    if (k.isEmpty || !k.contains(q) || offen.contains(k)) continue;
    (je[k] ??= []).add(e);
  }
  final liste = <({Listeneintrag neuester, int anzahl})>[];
  for (final gruppe in je.values) {
    gruppe.sort((a, b) => b.doneAt!.compareTo(a.doneAt!));
    liste.add((neuester: gruppe.first, anzahl: gruppe.length));
  }
  liste.sort((a, b) {
    final c = b.anzahl.compareTo(a.anzahl);
    if (c != 0) return c;
    final t = b.neuester.doneAt!.compareTo(a.neuester.doneAt!);
    return t != 0 ? t : a.neuester.inhalt.compareTo(b.neuester.inhalt);
  });
  return [for (final x in liste.take(max)) Kaufvorschlag(x.neuester.inhalt, EinkaufKategorie.von(x.neuester.category), x.anzahl)];
}
