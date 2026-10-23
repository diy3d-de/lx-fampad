// Suchlogik: Normalisierung (Umlaute, Groß-/Kleinschreibung), Teilwörter, mehrere Wörter, Hervorhebung, Ausschnitte, globale Suche (Gruppen, Obergrenze,
// Geburtstage ausgeschlossen, Rangfolge).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/suche/globale_suche.dart';
import 'package:lx_fampad/data/suche/such_logik.dart';

Termin _termin(String id, String titel, {String ort = '', String beschreibung = '', String? uid, bool ganztaegig = true, String start = '2026-11-01'}) => Termin(
  id: id,
  titel: titel,
  ort: ort,
  beschreibung: beschreibung,
  ganztaegig: ganztaegig,
  startUtc: ganztaegig ? null : DateTime.parse(start),
  endUtc: null,
  tzid: null,
  startDate: ganztaegig ? start : null,
  endDate: null,
  rrule: null,
  erinnerungMin: null,
  icalUid: uid,
  audience: 'family',
  ownerId: null,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

Aufgabe _aufgabe(String id, String titel, {String beschreibung = '', bool erledigt = false}) => Aufgabe(
  id: id,
  titel: titel,
  beschreibung: beschreibung,
  faelligDate: null,
  faelligUtc: null,
  tzid: null,
  prioritaet: 0,
  assigneeId: null,
  erledigtAt: erledigt ? DateTime.utc(2026, 10, 2) : null,
  erledigtVon: null,
  wiederholung: null,
  wiederholungTag: null,
  folgeId: null,
  erinnerungMin: null,
  audience: 'family',
  ownerId: null,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

Liste _liste(String id, String name) => Liste(id: id, name: name, kind: 'custom', audience: 'family', ownerId: null, createdAt: DateTime.utc(2026, 10, 1), rev: 1);

Listeneintrag _eintrag(String id, String listId, String text, {bool erledigt = false}) =>
    Listeneintrag(id: id, listId: listId, inhalt: text, assigneeId: null, doneAt: erledigt ? DateTime.utc(2026, 10, 2) : null, category: null, position: 0, createdAt: DateTime.utc(2026, 10, 1), rev: 1);

void main() {
  group('Normalisierung', () {
    test('Kleinschreibung, Umlaute und ß', () {
      expect(normalisiere('Äpfel ÖL Über Straße'), 'aepfel oel ueber strasse');
    });

    test('ä findet ae und ae findet ä', () {
      expect(enthaeltAlle('Bäckerei', suchWoerter('baecker')), isTrue);
      expect(enthaeltAlle('Baeckerei', suchWoerter('bäcker')), isTrue);
      expect(enthaeltAlle('Fußball', suchWoerter('fussball')), isTrue);
      expect(enthaeltAlle('Äpfel', suchWoerter('apfel')), isTrue);
      expect(enthaeltAlle('Äpfel', suchWoerter('aepfel')), isTrue);
      expect(enthaeltAlle('Äpfel', suchWoerter('Äpfel')), isTrue);
    });

    test('Teilwörter und mehrere Wörter in beliebiger Reihenfolge', () {
      expect(enthaeltAlle('Zahnarzt Termin Kind', suchWoerter('arzt')), isTrue);
      expect(enthaeltAlle('Zahnarzt Termin Kind', suchWoerter('kind zahn')), isTrue);
      expect(enthaeltAlle('Zahnarzt Termin Kind', suchWoerter('zahn auto')), isFalse);
    });

    test('Leere Eingabe und Leerraum ergeben keine Wörter, höchstens 8 Wörter', () {
      expect(suchWoerter('   '), isEmpty);
      expect(suchWoerter('a b c d e f g h i j'), hasLength(8));
    });
  });

  group('Bereiche', () {
    test('Bereiche liegen im Originaltext, auch bei Umlauten', () {
      final b = finde('Große Bäckerei', suchWoerter('baecker'))!;
      expect(b, [const TextBereich(6, 12)]);
      expect('Große Bäckerei'.substring(b.first.start, b.first.ende), 'Bäcker');
    });

    test('Mehrere Vorkommen, überlappende Bereiche werden zusammengeführt', () {
      final b = finde('abcabc', suchWoerter('ab bc'))!;
      expect(b.first.start, 0);
      expect(zusammenfuehren(const [TextBereich(0, 3), TextBereich(2, 5), TextBereich(7, 8)]), const [TextBereich(0, 5), TextBereich(7, 8)]);
    });

    test('Ausschnitt kürzt um den Treffer, Bereiche bleiben gültig', () {
      final text = '${'x' * 200}Zielwort${'y' * 200}';
      final b = finde(text, suchWoerter('zielwort'))!;
      final a = ausschnitt(text, b, max: 60);
      expect(a.text.length, lessThanOrEqualTo(62));
      expect(a.text.startsWith('…'), isTrue);
      expect(a.text.endsWith('…'), isTrue);
      expect(a.text.substring(a.bereiche.first.start, a.bereiche.first.ende), 'Zielwort');
    });

    test('Zeilenumbrüche werden zu Leerzeichen, Länge bleibt', () {
      final a = ausschnitt('eins\nzwei', const [TextBereich(5, 9)]);
      expect(a.text, 'eins zwei');
      expect(a.bereiche.single, const TextBereich(5, 9));
    });
  });

  group('Globale Suche', () {
    final termine = [
      _termin('t1', 'Zahnarzt', ort: 'Praxis Müller'),
      _termin('t2', 'Elternabend', beschreibung: 'Bitte den Zahnarzt-Bonus mitbringen'),
      _termin('t3', 'Max', uid: 'lxfampad-geb-2015-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    ];
    final aufgaben = [_aufgabe('a1', 'Zahnarzt anrufen'), _aufgabe('a2', 'Müll rausbringen', beschreibung: 'Zahnarzt-Zettel wegwerfen', erledigt: true)];
    final listen = [_liste('l1', 'Einkauf'), _liste('l2', 'Zahnpflege')];
    final eintraege = [_eintrag('e1', 'l1', 'Zahnpasta'), _eintrag('e2', 'verwaist', 'Zahnbürste')];

    SuchErgebnis suche(String s) => sucheGlobal(eingabe: s, termine: termine, aufgaben: aufgaben, listen: listen, eintraege: eintraege);

    test('Gruppen nach Bereich, Titel-Treffer vor Beschreibungs-Treffern', () {
      final e = suche('zahnarzt');
      expect(e.gruppe(SuchBereich.termine)!.treffer.map((t) => t.id), ['t1', 't2']);
      expect(e.gruppe(SuchBereich.termine)!.treffer.last.imTitel, isFalse);
      expect(e.gruppe(SuchBereich.termine)!.treffer.last.auszug, isNotNull);
      expect(e.gruppe(SuchBereich.aufgaben)!.treffer.map((t) => t.id), ['a1', 'a2']);
      expect(e.gruppe(SuchBereich.aufgaben)!.treffer.last.erledigt, isTrue);
      expect(e.gruppe(SuchBereich.listen), isNull);
    });

    test('Umlaut-tolerant über Ort, Listen und Einträge; verwaiste Einträge zählen nicht', () {
      expect(suche('mueller').gruppe(SuchBereich.termine)!.treffer.single.id, 't1');
      final z = suche('zahn');
      expect(z.gruppe(SuchBereich.listen)!.treffer.single.id, 'l2');
      expect(z.gruppe(SuchBereich.eintraege)!.treffer.single.id, 'e1');
      expect(z.gruppe(SuchBereich.eintraege)!.treffer.single.zusatz, 'Einkauf');
    });

    test('Geburtstage (Termine mit Marke) werden nicht gefunden', () {
      expect(suche('max').gruppe(SuchBereich.termine), isNull);
    });

    test('Zu kurze oder leere Eingabe ergibt nichts', () {
      expect(suche('').istLeer, isTrue);
      expect(suche('z').istLeer, isTrue);
      expect(suche('   ').istLeer, isTrue);
    });

    test('Obergrenze je Bereich mit Gesamtzahl', () {
      final viele = [for (var i = 0; i < 45; i++) _aufgabe('x$i', 'Zahnarzt Nr $i')];
      final e = sucheGlobal(eingabe: 'zahnarzt', termine: const [], aufgaben: viele, listen: const [], eintraege: const []);
      final g = e.gruppe(SuchBereich.aufgaben)!;
      expect(g.treffer, hasLength(kSucheMaxJeBereich));
      expect(g.gesamt, 45);
      expect(g.weitere, 25);
    });
  });
}
