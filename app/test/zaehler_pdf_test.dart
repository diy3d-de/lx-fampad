// Zähler (Teil 2): PDF-Bericht. Der Inhalt (Zähler, Zeitraum, Summen, Kosten) stimmt, die Abrechnungsperiode läuft JE ZÄHLER und über den Jahreswechsel, Gruppen werden summiert, lange Berichte
// laufen auf mehrere Seiten, Sonderzeichen sind maskiert, die Datei ist ein gültiges PDF (Kreuzverweistabelle zeigt auf die Objekte).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/zaehler/zaehler_bericht.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_pdf.dart';
import 'package:lx_fampad/data/zaehler/zaehler_uebersicht.dart';

final heute = DateTime.utc(2026, 10, 24);

List<Stand> monatlich(int vonJahr, int vonMonat, int anzahl, {double start = 1000, double proMonat = 300}) => [
  for (var i = 0; i < anzahl; i++) Stand(DateTime.utc(vonJahr, vonMonat + i, 1), ((start + proMonat * i) * 1000).round()),
];

List<ZaehlerKachel> kacheln(Map<String, ZaehlerInhalt> inhalte, Map<String, List<Stand>> staende) => baueKacheln(baueReihen(inhalte, staende));

Uint8List pdfFuer(List<ZaehlerKachel> k, BerichtWahl w) => zaehlerBerichtPdf(baueBericht(kacheln: k, wahl: w, heute: heute));

String text(Uint8List pdf) => pdfTextstuecke(pdf).join('\n');

void main() {
  const jahr2025 = BerichtWahl(zeitraum: BerichtZeitraum.kalenderjahr, jahr: 2025, kosten: true);

  test('Kalenderjahr: gültiges PDF, Zähler, Zeitraum und Gesamtverbrauch stehen drin', () {
    final k = kacheln({'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus', nummer: '1EMH0012345')}, {'a': monatlich(2024, 1, 30)});
    final pdf = pdfFuer(k, jahr2025);
    expect(pdf, isNotEmpty);
    expect(latin1.decode(pdf.sublist(0, 8)), startsWith('%PDF-1.4'));
    expect(latin1.decode(pdf.sublist(pdf.length - 6)), contains('%%EOF'));
    final t = text(pdf);
    expect(t, contains('Zählerbericht'));
    expect(t, contains('Strom Haus'));
    expect(t, contains('01.01.2025 bis 31.12.2025'));
    expect(t, contains('Zähler 1EMH0012345'));
    expect(t, contains('3.600 kWh')); // 12 Monate * 300
    expect(t, contains('Vorjahreszeitraum'));
    expect(t, contains('Erstellt am 24.10.2026'));
    expect(t, contains('Seite 1 von 1'));
    // Tabelle der Monate
    expect(t, contains('Januar 2025'));
    expect(t, contains('Dezember 2025'));
  });

  test('Kreuzverweistabelle: jeder Eintrag zeigt auf den Anfang seines Objekts', () {
    final k = kacheln({'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'S')}, {'a': monatlich(2024, 1, 30)});
    final s = latin1.decode(pdfFuer(k, jahr2025), allowInvalid: true);
    final start = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(s)!.group(1)!);
    expect(s.substring(start), startsWith('xref'));
    final eintraege = RegExp(r'(\d{10}) 00000 n ').allMatches(s.substring(start)).map((m) => int.parse(m.group(1)!)).toList();
    expect(eintraege, isNotEmpty);
    for (var i = 0; i < eintraege.length; i++) {
      expect(s.substring(eintraege[i]), startsWith('${i + 1} 0 obj'), reason: 'Objekt ${i + 1}');
    }
  });

  test('Abrechnungsperiode je Zähler: Strom März bis Februar über den Jahreswechsel, Wasser Kalenderjahr', () {
    final k = kacheln(
      {
        'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom', periodeMonat: 3, periodeTag: 1),
        'w': ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Wasser'),
      },
      {'a': monatlich(2024, 1, 30), 'w': monatlich(2024, 1, 30, start: 50, proMonat: 4)},
    );
    final letzte = text(pdfFuer(k, const BerichtWahl(zeitraum: BerichtZeitraum.letztePeriode, jahr: 2026)));
    expect(letzte, contains('01.03.2025 bis 28.02.2026')); // Strom
    expect(letzte, contains('01.01.2025 bis 31.12.2025')); // Wasser: die letzte abgeschlossene Periode ist das Kalenderjahr 2025
    final laufend = text(pdfFuer(k, const BerichtWahl(zeitraum: BerichtZeitraum.laufendePeriode, jahr: 2026)));
    expect(laufend, contains('01.03.2026 bis 28.02.2027'));
    expect(laufend, contains('01.01.2026 bis 31.12.2026'));
    // Gesamtverbrauch der Strom-Periode 2025/26: 12 * 300
    expect(letzte, contains('3.600 kWh'));
  });

  test('eigener Zeitraum: beide Tage einschließlich; ungültiger Zeitraum und leere Auswahl werfen', () {
    final k = kacheln({'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'S')}, {'a': monatlich(2025, 1, 12)});
    final w = BerichtWahl(zeitraum: BerichtZeitraum.eigen, jahr: 2025, von: DateTime.utc(2025, 2, 1), bis: DateTime.utc(2025, 4, 30));
    expect(text(pdfFuer(k, w)), contains('01.02.2025 bis 30.04.2025'));
    expect(text(pdfFuer(k, w)), contains('900 kWh')); // Feb, Mär, Apr: 3 * 300
    expect(() => pdfFuer(k, BerichtWahl(zeitraum: BerichtZeitraum.eigen, jahr: 2025, von: DateTime.utc(2025, 5, 1), bis: DateTime.utc(2025, 4, 1))), throwsArgumentError);
    expect(() => pdfFuer(k, const BerichtWahl(zeitraum: BerichtZeitraum.eigen, jahr: 2025)), throwsArgumentError);
    expect(() => pdfFuer(const [], jahr2025), throwsArgumentError);
  });

  test('Wasser-Gruppe: eine Summe, je Zähler eine Tabelle', () {
    final k = kacheln(
      {
        'k1': ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Kaltwasser Etage', gruppe: 'Wasser Wohnung'),
        'k2': ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Kaltwasser Keller', gruppe: 'Wasser Wohnung'),
        'k3': ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Kaltwasser Garten', gruppe: 'Wasser Wohnung'),
      },
      {
        'k1': monatlich(2024, 1, 30, start: 100, proMonat: 3),
        'k2': monatlich(2024, 1, 30, start: 10, proMonat: 1),
        'k3': monatlich(2024, 1, 30, start: 5, proMonat: 0.5),
      },
    );
    expect(k, hasLength(1));
    final t = text(pdfFuer(k, jahr2025));
    expect(t, contains('Wasser Wohnung'));
    expect(t, contains('Kaltwasser Etage'));
    expect(t, contains('Kaltwasser Keller'));
    expect(t, contains('Kaltwasser Garten'));
    // (3 + 1 + 0,5) * 12 = 54 m³
    expect(t, contains('54,0 m³'));
  });

  test('Kosten: Arbeit, Grund- und Zählergebühr anteilig, Abschläge und Nachzahlung stimmen', () {
    final k = kacheln(
      {
        'a': ZaehlerInhalt(
          art: ZaehlerArt.strom,
          name: 'Strom',
          preise: const [Preis(ab: '2020-01-01', arbeitspreis: 3100, grundgebuehrJahr: 13800, zaehlergebuehrJahr: 2400)],
          abschlag: 9500,
        ),
      },
      {'a': monatlich(2024, 1, 30)},
    );
    final t = text(pdfFuer(k, jahr2025));
    expect(t, contains('Kosten'));
    expect(t, contains('1.116,00 €')); // 3600 kWh * 0,31
    expect(t, contains('138,00 €')); // Grundgebühr (und der Saldo: 1278 - 1140)
    expect(t, contains('24,00 €'));
    expect(t, contains('1.278,00 €'));
    expect(t, contains('1.140,00 €')); // 12 Abschläge
    expect(t, contains('Nachzahlung 138,00 €'));
    // ohne Wunsch keine Kosten
    final ohne = text(pdfFuer(k, const BerichtWahl(zeitraum: BerichtZeitraum.kalenderjahr, jahr: 2025)));
    expect(ohne, isNot(contains('1.116,00 €')));
  });

  test('Solar: Ersparnis und Eigenverbrauch statt Kosten', () {
    final k = kacheln(
      {'s': ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Balkonkraftwerk', preise: const [Preis(ab: '2020-01-01', arbeitspreis: 3000)], eigenverbrauchBp: 5000)},
      {'s': monatlich(2024, 1, 30, start: 0, proMonat: 100)},
    );
    final t = text(pdfFuer(k, jahr2025));
    expect(t, contains('Ersparnis'));
    expect(t, contains('1.200 kWh')); // erzeugt
    expect(t, contains('600 kWh')); // Eigenverbrauch 50 %
    expect(t, contains('180,00 €')); // 600 kWh * 0,30
  });

  test('Auswahl "ohne Stände" und "ohne Vorjahr" lässt die Teile weg', () {
    final k = kacheln({'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'S')}, {'a': monatlich(2024, 1, 30)});
    final voll = text(pdfFuer(k, jahr2025));
    expect(voll, contains('Vorjahr'));
    final knapp = text(pdfFuer(k, const BerichtWahl(zeitraum: BerichtZeitraum.kalenderjahr, jahr: 2025, staende: false, vorjahr: false)));
    expect(knapp, isNot(contains('Vorjahr')));
    expect(knapp, isNot(contains('Stand kWh')));
    expect(knapp, contains('Verbrauch je Monat'));
  });

  test('lange Berichte laufen auf mehrere Seiten, jede Seite hat Fuß und Seitenzahl', () {
    final inhalte = {for (var i = 0; i < 5; i++) 'z$i': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Zähler $i')};
    final staende = {for (var i = 0; i < 5; i++) 'z$i': monatlich(2024, 1, 30)};
    final pdf = pdfFuer(kacheln(inhalte, staende), jahr2025);
    final s = latin1.decode(pdf, allowInvalid: true);
    final seiten = RegExp(r'/Type /Page /Parent').allMatches(s).length;
    expect(seiten, greaterThan(1));
    final t = text(pdf);
    for (var i = 1; i <= seiten; i++) {
      expect(t, contains('Seite $i von $seiten'));
    }
    expect(RegExp(r'Erstellt am 24\.10\.2026').allMatches(t).length, seiten);
  });

  test('Sonderzeichen in Namen sind maskiert und kommen unverändert zurück; Unbekanntes wird zu ?', () {
    final k = kacheln({'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: r'Strom (Haus) \ Büro 😀')}, {'a': monatlich(2024, 1, 30)});
    final pdf = pdfFuer(k, jahr2025);
    final t = text(pdf);
    expect(t, contains(r'Strom (Haus) \ Büro ?'));
  });

  test('Textbreite: Ziffern sind genau 0,556 em breit (rechtsbündige Zahlen)', () {
    expect(textBreite('1234', 10), closeTo(22.24, 0.001));
    expect(textBreite('1.234,5', 10), closeTo(5 * 5.56 + 2 * 2.78, 0.01), reason: 'fünf Ziffern, Punkt und Komma je 0,278 em');
    expect(umbrechenNachBreite('aaa bbb ccc ddd', 10, 40).length, greaterThan(1));
  });

  test('Unvollständiger Zeitraum wird gekennzeichnet', () {
    final k = kacheln({'a': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'S')}, {'a': monatlich(2025, 6, 4)});
    expect(text(pdfFuer(k, jahr2025)), contains('Hinweis: Für einen Teil des Zeitraums fehlen Ablesungen'));
  });
}
