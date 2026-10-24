// Tresor (Abschnitt 6m): reine Logik. Suche nur im Speicher über Titel, Bezeichnungen und NICHT geheime Werte (geheime Werte und die Notiz nie), Zähler, Sortierung, Felder ordnen, Prüfung.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/tresor/tresor_logik.dart';
import 'package:lx_fampad/data/tresor/tresor_modelle.dart';

TresorInhalt _e(String titel, TresorKategorie k, {List<TresorFeld> felder = const [], String notiz = '', String kn = ''}) => TresorInhalt(kategorie: k, kategorieName: kn, titel: titel, felder: felder, notiz: notiz);

void main() {
  final wlan = _e('WLAN Zuhause', TresorKategorie.haushalt, felder: const [
    TresorFeld(bezeichnung: 'Netzname', wert: 'FamilieNetz'),
    TresorFeld(bezeichnung: 'Passwort', wert: 'Sonne-Mond-4711', geheim: true),
  ], notiz: 'Gästenetz: gast-2026');
  final arzt = _e('Kinderärztin Dr. Müller', TresorKategorie.notfall, felder: const [TresorFeld(bezeichnung: 'Person', wert: 'Emil'), TresorFeld(bezeichnung: 'Telefon', wert: '06131 4711')]);
  final ausweis = _e('Reisepass Mama', TresorKategorie.dokumente, felder: const [TresorFeld(bezeichnung: 'Nummer', wert: 'C01X00T47', geheim: true)]);
  final auto = _e('Kfz-Schein', TresorKategorie.eigene, kn: 'Auto');
  final alle = [wlan, arzt, ausweis, auto];
  List<TresorInhalt> suche(String q) => tresorSuchen(alle, (e) => e, q);

  group('Suche', () {
    test('leere Anfrage ergibt alle', () {
      expect(suche(''), alle);
      expect(suche('   '), alle);
    });

    test('findet Titel, Bezeichnung, nicht geheime Werte und den Namen der eigenen Kategorie, ohne Rücksicht auf Groß-/Kleinschreibung und Umlaute', () {
      expect(suche('wlan'), [wlan]);
      expect(suche('NETZNAME'), [wlan]);
      expect(suche('familienetz'), [wlan]);
      expect(suche('kinderaerztin'), [arzt]);
      expect(suche('Kinderärztin'), [arzt]);
      expect(suche('mueller'), [arzt]);
      expect(suche('06131'), [arzt]);
      expect(suche('emil'), [arzt]);
      expect(suche('auto'), [auto]);
      expect(suche('Notfall'), [arzt]);
    });

    test('mehrere Wörter müssen alle vorkommen (in beliebiger Reihenfolge)', () {
      expect(suche('wlan netzname'), [wlan]);
      expect(suche('netzname wlan'), [wlan]);
      expect(suche('wlan telefon'), isEmpty);
    });

    test('geheime Werte und die Notiz werden NIE durchsucht', () {
      expect(suche('Sonne-Mond'), isEmpty);
      expect(suche('4711'), [arzt]); // nur der nicht geheime Wert des Arztes, nicht das Passwort
      expect(suche('C01X00T47'), isEmpty);
      expect(suche('gast-2026'), isEmpty);
      expect(suche('Gästenetz'), isEmpty);
      // die Bezeichnung eines geheimen Felds ist dagegen durchsuchbar (kein Geheimnis)
      expect(suche('passwort'), [wlan]);
      expect(suche('nummer'), [ausweis]);
    });

    test('ohne Treffer: leer; arbeitet auf beliebigen Elementen (Ansichten)', () {
      expect(suche('gibtesnicht'), isEmpty);
      final paare = [('a', wlan), ('b', arzt)];
      expect(tresorSuchen(paare, (p) => p.$2, 'wlan').map((p) => p.$1), ['a']);
    });
  });

  group('Zähler und Sortierung', () {
    test('Zähler je Kategorie, jede kommt vor', () {
      final z = tresorKategorieZaehler(alle);
      expect(z[TresorKategorie.haushalt], 1);
      expect(z[TresorKategorie.notfall], 1);
      expect(z[TresorKategorie.dokumente], 1);
      expect(z[TresorKategorie.eigene], 1);
      expect(z[TresorKategorie.zugang], 0);
      expect(tresorKategorieZaehler(const []).values, everyElement(0));
    });

    test('Sortierung: Kategorie-Reihenfolge, dann Titel ohne Rücksicht auf Umlaute und Groß-/Kleinschreibung, am Ende die ID', () {
      final liste = [('3', _e('zebra', TresorKategorie.zugang)), ('2', _e('Ärzte', TresorKategorie.zugang)), ('1', _e('Wasser', TresorKategorie.notfall)), ('4', _e('Ärzte', TresorKategorie.zugang))];
      final s = tresorSortieren(liste, (e) => e.$2, (e) => e.$1);
      expect(s.map((e) => e.$1), ['1', '2', '4', '3']);
      // Original unverändert
      expect(liste.first.$1, '3');
    });

    test('eigene Kategorien: nach Namen, eindeutig und ohne Rücksicht auf Groß-/Kleinschreibung', () {
      final l = [_e('a', TresorKategorie.eigene, kn: 'Zeug'), _e('b', TresorKategorie.eigene, kn: 'auto'), _e('c', TresorKategorie.eigene, kn: 'Auto'), _e('d', TresorKategorie.haushalt)];
      expect(tresorEigeneKategorien(l), ['auto', 'Zeug']);
      expect(tresorEigeneKategorien(const []), isEmpty);
      final s = tresorSortieren(l, (e) => e, (e) => e.titel);
      expect(s.map((e) => e.titel), ['d', 'b', 'c', 'a']);
    });
  });

  group('Felder ordnen', () {
    const a = TresorFeld(bezeichnung: 'A');
    const b = TresorFeld(bezeichnung: 'B');
    const c = TresorFeld(bezeichnung: 'C');
    List<String> n(List<TresorFeld> f) => [for (final x in f) x.bezeichnung];

    test('verschieben (Ziel nach dem Herausnehmen), ungültige Indizes ändern nichts', () {
      expect(n(tresorFeldVerschieben(const [a, b, c], 0, 2)), ['B', 'C', 'A']);
      expect(n(tresorFeldVerschieben(const [a, b, c], 2, 0)), ['C', 'A', 'B']);
      expect(n(tresorFeldVerschieben(const [a, b, c], 1, 1)), ['A', 'B', 'C']);
      expect(n(tresorFeldVerschieben(const [a, b, c], -1, 1)), ['A', 'B', 'C']);
      expect(n(tresorFeldVerschieben(const [a, b, c], 0, 3)), ['A', 'B', 'C']);
      expect(n(tresorFeldVerschieben(const [], 0, 0)), isEmpty);
    });

    test('hinzufügen (höchstens 20), entfernen, ersetzen; die Eingabe bleibt unverändert', () {
      const eingabe = [a, b];
      expect(n(tresorFeldHinzu(eingabe, c)), ['A', 'B', 'C']);
      expect(eingabe, hasLength(2));
      final voll = [for (var i = 0; i < kMaxTresorFelder; i++) TresorFeld(bezeichnung: 'F$i')];
      expect(tresorFeldHinzu(voll, c), hasLength(kMaxTresorFelder));
      expect(n(tresorFeldEntfernen(const [a, b, c], 1)), ['A', 'C']);
      expect(n(tresorFeldEntfernen(const [a, b, c], 7)), ['A', 'B', 'C']);
      expect(tresorFeldErsetzen(const [a, b], 1, c)[1], c);
    });

    test('leere Felder (weder Bezeichnung noch Wert) fallen beim Speichern weg', () {
      const leer = TresorFeld(bezeichnung: '  ');
      expect(n(tresorLeereFelderWeg(const [a, leer, TresorFeld(bezeichnung: '', wert: 'x')])), ['A', '']);
    });
  });

  group('Prüfung', () {
    test('ein gültiger Eintrag hat keine Probleme', () => expect(tresorProbleme(wlan), isEmpty));

    test('jedes Problem mit deutscher Meldung', () {
      expect(tresorProbleme(_e('', TresorKategorie.zugang)), [TresorProblem.titelFehlt]);
      expect(tresorProbleme(_e('x' * 81, TresorKategorie.zugang)), [TresorProblem.titelZuLang]);
      expect(tresorProbleme(_e('x', TresorKategorie.eigene)), [TresorProblem.kategorieNameFehlt]);
      expect(tresorProbleme(_e('x', TresorKategorie.zugang, felder: const [TresorFeld(bezeichnung: ' ')])), [TresorProblem.bezeichnungFehlt]);
      expect(tresorProbleme(_e('x', TresorKategorie.zugang, felder: [for (var i = 0; i < 21; i++) TresorFeld(bezeichnung: 'F$i')])), [TresorProblem.zuVieleFelder]);
      expect(tresorProbleme(_e('x', TresorKategorie.zugang, notiz: 'n' * 4001)), [TresorProblem.notizZuLang]);
      expect(tresorProbleme(_e('x', TresorKategorie.zugang, felder: [TresorFeld(bezeichnung: 'b', wert: 'w' * 1001)])), [TresorProblem.wertZuLang]);
      final zuGross = _e('x', TresorKategorie.zugang, notiz: '€' * 4000, felder: [for (var i = 0; i < 6; i++) TresorFeld(bezeichnung: 'F$i', wert: '€' * 1000)]);
      expect(tresorProbleme(zuGross), [TresorProblem.zuGross]);
      for (final p in TresorProblem.values) {
        expect(p.meldung, isNotEmpty);
      }
    });

    test('stimmt mit gueltig und Kodieren überein', () {
      for (final e in [wlan, _e('', TresorKategorie.zugang), _e('x', TresorKategorie.eigene)]) {
        expect(tresorProbleme(e).isEmpty, e.gueltig);
      }
    });
  });
}
