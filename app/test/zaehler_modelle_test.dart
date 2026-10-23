// Zähler (Abschnitt 6l): Klartext-Formate und Festkomma. Ungültiges wird nie geschrieben, Kaputtes und Neueres ergibt beim Lesen null.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';

ZaehlerInhalt _strom({List<Preis>? preise}) => ZaehlerInhalt(
  art: ZaehlerArt.strom,
  name: 'Haushalt',
  nummer: '1ABC',
  notiz: 'Keller',
  periodeMonat: 3,
  periodeTag: 1,
  preise: preise ?? const [Preis(ab: '2024-01-01', arbeitspreis: 3456, grundgebuehrJahr: 12000, zaehlergebuehrJahr: 1500), Preis(ab: '2025-01-01', arbeitspreis: 3299)],
  abschlag: 8500,
  ablesung: const Ablesung.monatlich(1),
);

void main() {
  group('Festkomma', () {
    test('Eingaben in deutscher und englischer Schreibweise', () {
      expect(mengeParsen('1234,567'), 1234567);
      expect(mengeParsen('1.234,5'), 1234500);
      expect(mengeParsen('1.234.567'), 1234567000); // mehrere Punkte: Tausendertrenner
      expect(mengeParsen('12.5'), 12500); // ein Punkt: Dezimalzeichen
      expect(mengeParsen(' 7 '), 7000);
      expect(mengeParsen('0,001'), 1);
      expect(mengeParsen('5,500'), 5500);
      expect(mengeParsen('5,5000'), 5500); // überzählige Nullen sind harmlos
      expect(preisParsen('0,3456'), 3456);
      expect(preisParsen('0,34'), 3400);
      expect(geldParsen('85,5'), 8550);
      expect(geldParsen('120'), 12000);
    });

    test('Ungültiges ergibt null', () {
      for (final t in ['', 'abc', '-1', '1,2,3', '1,2345', '12,5x', ',5', '1e5', '99999999999999999']) {
        expect(mengeParsen(t), isNull, reason: t);
      }
      expect(geldParsen('1,234'), isNull);
    });

    test('Text ist das Gegenstück zum Lesen, ohne Gleitkomma', () {
      expect(mengeText(1234567), '1234,567');
      expect(mengeText(1), '0,001');
      expect(mengeText(0), '0,000');
      expect(mengeText(5500, kuerzen: true), '5,5');
      expect(mengeText(5000, kuerzen: true), '5');
      expect(preisText(3456), '0,3456');
      expect(geldText(8550), '85,50');
      expect(geldText(5), '0,05');
      for (final v in [0, 1, 999, 1000, 123456789]) {
        expect(mengeParsen(mengeText(v)), v);
      }
    });

    test('Rundung halbe nach oben, symmetrisch bei negativen Werten', () {
      expect(rundenDiv(5, 2), 3);
      expect(rundenDiv(4, 2), 2);
      expect(rundenDiv(1, 3), 0);
      expect(rundenDiv(2, 3), 1);
      expect(rundenDiv(-5, 2), -3);
      expect(rundenDiv(-1, 3), 0);
    });

    test('0,1 + 0,2 ist 0,3 (kein Gleitkomma-Fehler)', () {
      expect(mengeParsen('0,1')! + mengeParsen('0,2')!, mengeParsen('0,3'));
    });
  });

  group('Zähler: Kodieren und Lesen', () {
    test('Rundlauf mit allen Feldern', () {
      final z = _strom().kopie(eigenverbrauchBp: () => 6500, anlagenkosten: () => 1500000, einspeiseVerguetung: () => 810, vorgaenger: () => 'abc', archiviertAb: () => '2025-06-30', gruppe: 'Haus');
      final klar = zaehlerKodieren(z);
      expect(klar, startsWith(kPraefixZaehler));
      expect(zaehlerLesen(klar), z);
    });

    test('Ort und Warnschwelle: Rundlauf, nur gültige Werte', () {
      final z = _strom().kopie(ort: 'Waschkeller', warnProzent: () => 30);
      expect(zaehlerLesen(zaehlerKodieren(z)), z);
      expect(zaehlerLesen(zaehlerKodieren(z))!.ort, 'Waschkeller');
      expect(zaehlerLesen(zaehlerKodieren(z))!.warnProzent, 30);
      expect(zaehlerKodieren(_strom()), isNot(contains('"ort"'))); // ohne Wert kein Feld (ältere Apps lesen weiter)
      expect(() => zaehlerKodieren(_strom().kopie(warnProzent: () => 0)), throwsArgumentError);
      expect(() => zaehlerKodieren(_strom().kopie(ort: 'x' * 41)), throwsArgumentError);
    });

    test('Standardwerte der Art: Strom rechnet Kosten, Wasser nicht', () {
      expect(ZaehlerInhalt(art: ZaehlerArt.strom, name: 'a').kosten, isTrue);
      expect(ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'a').kosten, isFalse);
      expect(ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'a', kosten: true).kosten, isTrue);
      expect(ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'a').einheit, 'm³');
      expect(ZaehlerInhalt(art: ZaehlerArt.strom, name: 'a').einheit, 'kWh');
      expect(ZaehlerInhalt(art: ZaehlerArt.eigen, name: 'a', einheit: 'Stk').einheit, 'Stk');
    });

    test('Ungültiger Inhalt wird nie geschrieben', () {
      expect(() => zaehlerKodieren(ZaehlerInhalt(art: ZaehlerArt.strom, name: '  ')), throwsArgumentError);
      expect(() => zaehlerKodieren(ZaehlerInhalt(art: ZaehlerArt.strom, name: 'x' * 61)), throwsArgumentError);
      expect(() => zaehlerKodieren(ZaehlerInhalt(art: ZaehlerArt.eigen, name: 'x')), throwsArgumentError); // eigene Art ohne Einheit
      expect(() => zaehlerKodieren(_strom().kopie(periodeMonat: 13)), throwsArgumentError);
      expect(() => zaehlerKodieren(_strom().kopie(periodeTag: 0)), throwsArgumentError);
      expect(() => zaehlerKodieren(_strom().kopie(archiviertAb: () => '2025-13-01')), throwsArgumentError);
      expect(() => zaehlerKodieren(_strom().kopie(eigenverbrauchBp: () => 10001)), throwsArgumentError);
      expect(() => zaehlerKodieren(_strom().kopie(preise: [const Preis(ab: '2025-01-01'), const Preis(ab: '2024-01-01')])), throwsArgumentError); // nicht aufsteigend
      expect(() => zaehlerKodieren(_strom().kopie(preise: [const Preis(ab: '2025-01-01'), const Preis(ab: '2025-01-01')])), throwsArgumentError); // doppelt
      expect(() => zaehlerKodieren(_strom().kopie(preise: [for (var i = 0; i <= kMaxPreise; i++) Preis(ab: '${2000 + i}-01-01')])), throwsArgumentError);
      expect(() => zaehlerKodieren(_strom().kopie(notiz: 'x' * 301)), throwsArgumentError);
    });

    test('Kaputtes, Neueres und Fremdes ergibt null', () {
      final gut = jsonEncode(_strom().toJson());
      expect(zaehlerLesen('${kPraefixZaehler}nicht json'), isNull);
      expect(zaehlerLesen('a1:$gut'), isNull);
      expect(zaehlerLesen(''), isNull);
      final m = jsonDecode(gut) as Map<String, dynamic>;
      expect(zaehlerLesen('$kPraefixZaehler${jsonEncode({...m, 'v': kZaehlerFormat + 1})}'), isNull);
      expect(zaehlerLesen('$kPraefixZaehler${jsonEncode({...m, 'v': 0})}'), isNull);
      for (final kaputt in [
        {...m, 'art': 'q'},
        {...m, 'name': 5},
        {...m, 'kosten': 'ja'},
        {...m, 'pm': 0},
        {...m, 'abschlag': -1},
        {...m, 'abschlag': 1.5},
        {...m, 'preise': 'x'},
        {...m, 'preise': [{'ab': 'gestern', 'ap': 1}]},
        {...m, 'ablese': {'r': 'x', 't': 1}},
        {...m, 'vor': ''},
        {...m, 'arch': 'x'},
        {...m, 'eigen': 20000},
      ]) {
        expect(zaehlerLesen('$kPraefixZaehler${jsonEncode(kaputt)}'), isNull, reason: jsonEncode(kaputt));
      }
    });

    test('Voller Preisverlauf bleibt unter der Grenze des Klartexts', () {
      final z = _strom().kopie(preise: [for (var i = 0; i < kMaxPreise; i++) Preis(ab: '${2000 + i}-01-01', arbeitspreis: 3456, grundgebuehrJahr: 12000, zaehlergebuehrJahr: 1500)]);
      expect(utf8.encode(zaehlerKodieren(z)).length, lessThan(kMaxKlartextBytesZaehler));
    });
  });

  group('Zählerstand: Kodieren und Lesen', () {
    test('Rundlauf', () {
      const s = StandInhalt(datum: '2026-03-01', milli: 12345678, notiz: 'Zähler im Keller', marke: StandMarke.ende);
      expect(standLesen(standKodieren(s)), s);
      const o = StandInhalt(datum: '2026-03-01', milli: 0);
      expect(standLesen(standKodieren(o)), o);
    });

    test('Ungültig wird nie geschrieben, Kaputtes ergibt null', () {
      expect(() => standKodieren(const StandInhalt(datum: '2026-02-30', milli: 1)), throwsArgumentError);
      expect(() => standKodieren(const StandInhalt(datum: '2026-03-01', milli: -1)), throwsArgumentError);
      expect(() => standKodieren(StandInhalt(datum: '2026-03-01', milli: 1, notiz: 'x' * 121)), throwsArgumentError);
      expect(standLesen('$kPraefixStand{'), isNull);
      expect(standLesen('$kPraefixStand${jsonEncode({'v': 2, 'd': '2026-03-01', 'w': 1})}'), isNull);
      expect(standLesen('$kPraefixStand${jsonEncode({'v': 1, 'd': '2026-03-01', 'w': 1.5})}'), isNull);
      expect(standLesen('$kPraefixStand${jsonEncode({'v': 1, 'd': '2026-03-01', 'w': 1, 'k': 'q'})}'), isNull);
      expect(standLesen('$kPraefixZaehler${jsonEncode({'v': 1, 'd': '2026-03-01', 'w': 1})}'), isNull);
    });
  });

  test('Ablese-Rhythmus: Rundlauf und Grenzen', () {
    for (final a in [const Ablesung.monatlich(31), const Ablesung.jaehrlich(monat: 12, tag: 31)]) {
      expect(Ablesung.fromJson(a.toJson()), a);
    }
    expect(Ablesung.fromJson({'r': 'j', 't': 5}), isNull); // Jahresablesung braucht einen Monat
    expect(Ablesung.fromJson({'r': 'm', 't': 32}), isNull);
  });
}
