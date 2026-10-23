// Zähler (Teil 2): reine Zusammenfassung für die Oberfläche: Reihen mit Wechsel-Kette, Kacheln und Gruppen (Wasser mit Summe), Fälligkeit, letzter voller Monat mit Vorjahr,
// Warnschwelle, Solar-Auswertung, Vorschau eines neuen Standes und die deutschen Formate.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/zaehler/zaehler_format.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_uebersicht.dart';

DateTime t(int j, int m, int d) => DateTime.utc(j, m, d);

Stand s(int j, int m, int d, num wert) => Stand(t(j, m, d), (wert * 1000).round());

ZaehlerInhalt z(ZaehlerArt art, String name, {String gruppe = '', Ablesung? ablesung, String? vor, String? arch, int? warn, int pm = 1, int pt = 1}) =>
    ZaehlerInhalt(art: art, name: name, gruppe: gruppe, ablesung: ablesung, vorgaenger: vor, archiviertAb: arch, warnProzent: warn, periodeMonat: pm, periodeTag: pt);

void main() {
  group('Reihen und Kette', () {
    test('Zählerwechsel: die Kette läuft nahtlos weiter, die Reihe trägt den jüngsten Zähler', () {
      final reihen = baueReihen(
        {'alt': z(ZaehlerArt.strom, 'Strom alt', arch: '2026-03-01'), 'neu': z(ZaehlerArt.strom, 'Strom neu', vor: 'alt')},
        {
          'alt': [s(2026, 1, 1, 100), s(2026, 3, 1, 300)],
          'neu': [s(2026, 3, 1, 0), s(2026, 5, 1, 200)],
        },
      );
      expect(reihen, hasLength(1));
      final r = reihen.single;
      expect(r.id, 'neu');
      expect(r.ids, ['alt', 'neu']);
      expect(r.archiviert, isFalse);
      // 200 (alt) + 200 (neu) = 400 über die ganze Kette, ohne Sprung am Wechsel
      expect(r.kurve.verbrauch(t(2026, 1, 1), t(2026, 5, 1)).milli, 400000);
      expect(r.letzter!.milli, 200000);
    });

    test('Kacheln: gleiche Art und gleiche Gruppe ergeben eine Gruppe, ein einzelner Zähler bleibt allein, Archiviertes fehlt', () {
      final reihen = baueReihen(
        {
          'k1': z(ZaehlerArt.kaltwasser, 'Kaltwasser Etage', gruppe: 'Wasser Wohnung'),
          'k2': z(ZaehlerArt.kaltwasser, 'Kaltwasser Keller', gruppe: 'wasser wohnung'),
          'w1': z(ZaehlerArt.warmwasser, 'Warmwasser', gruppe: 'Wasser Wohnung'), // andere Art: eigene Kachel
          'st': z(ZaehlerArt.strom, 'Strom'),
          'alt': z(ZaehlerArt.gas, 'Gas alt', arch: '2025-01-01'),
        },
        {for (final id in ['k1', 'k2', 'w1', 'st', 'alt']) id: [s(2026, 1, 1, 0), s(2026, 2, 1, 10)]},
      );
      final k = baueKacheln(reihen);
      expect(k.map((x) => x.titel), ['Strom', 'Wasser Wohnung', 'Warmwasser']);
      final g = k.firstWhere((x) => x.istGruppe);
      expect(g.reihen.map((r) => r.id).toSet(), {'k1', 'k2'});
      expect(kachelVerbrauch(g, t(2026, 1, 1), t(2026, 2, 1)).milli, 20000); // Summe beider Zähler
      expect(reihen.where((r) => r.archiviert).map((r) => r.id), ['alt']);
    });

    test('Monate einer Gruppe sind die Summe der Zähler, unvollständig sobald einer fehlt', () {
      final reihen = baueReihen(
        {'k1': z(ZaehlerArt.kaltwasser, 'A', gruppe: 'W'), 'k2': z(ZaehlerArt.kaltwasser, 'B', gruppe: 'W')},
        {
          'k1': [s(2026, 1, 1, 0), s(2026, 2, 1, 10), s(2026, 3, 1, 20)],
          'k2': [s(2026, 1, 1, 0), s(2026, 2, 1, 5)], // endet früher
        },
      );
      final g = baueKacheln(reihen).single;
      final m = kachelMonate(g, t(2026, 1, 1), t(2026, 3, 1));
      expect(m[0].milli, 10000 + 5000);
      expect(m[0].vollstaendig, isTrue);
      expect(m[1].milli, 10000);
      expect(m[1].vollstaendig, isFalse);
    });
  });

  group('Letzter voller Monat und Warnschwelle', () {
    final heute = t(2026, 10, 24);

    test('Vorjahresvergleich des jüngsten vollständigen Monats', () {
      // September 2026: 300, September 2025: 100
      final stand = [s(2025, 9, 1, 0), s(2025, 10, 1, 100), s(2026, 9, 1, 1000), s(2026, 10, 1, 1300)];
      final k = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S')}, {'a': stand})).single;
      final m = letzterVollerMonat(k, heute);
      expect(m, isNotNull);
      expect(m!.monat, 9);
      expect(m.milli, 300000);
      expect(m.vorjahrMilli, 100000);
      expect(m.prozent, closeTo(200, 0.001));
    });

    test('ohne vollständigen Monat gibt es keinen Wert', () {
      final k = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S')}, {'a': [s(2026, 10, 2, 5)]})).single;
      expect(letzterVollerMonat(k, heute), isNull);
    });

    test('ungewöhnlich hoch nur mit Schwelle und vollständigem Vorjahr', () {
      // Okt 2024 bis Sep 2025: 100 je Monat, ab Okt 2025: 300 je Monat
      final alle = [for (var i = 0; i <= 24; i++) Stand(t(2024, 10 + i, 1), (i <= 12 ? 100 * i : 1200 + 300 * (i - 12)) * 1000)];
      final ohne = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S')}, {'a': alle})).single;
      expect(ungewoehnlichHoch(ohne, heute), isFalse); // keine Schwelle gesetzt
      final mit = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S', warn: 30)}, {'a': alle})).single;
      expect(warnSchwelle(mit), 30);
      expect(ungewoehnlichHoch(mit, heute), isTrue);
      final nurJahr = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S', warn: 30)}, {'a': alle.sublist(13)})).single;
      expect(ungewoehnlichHoch(nurJahr, heute), isFalse); // ohne Vorjahreswert nie
      final hoch = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S', warn: 500)}, {'a': alle})).single;
      expect(ungewoehnlichHoch(hoch, heute), isFalse); // unter der Schwelle
    });
  });

  group('Fälligkeit', () {
    final heute = t(2026, 10, 24);

    test('monatlich am 1.: ohne Stand seit dem 1. fällig, mit Stand nicht', () {
      final alt = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S', ablesung: const Ablesung.monatlich(1))}, {'a': [s(2026, 9, 20, 1)]})).single;
      expect(kachelFaelligkeit(alt, heute).art, FaelligkeitsArt.faellig);
      final neu = baueKacheln(baueReihen({'a': z(ZaehlerArt.strom, 'S', ablesung: const Ablesung.monatlich(1))}, {'a': [s(2026, 10, 2, 1)]})).single;
      final f = kachelFaelligkeit(neu, heute);
      expect(f.art, FaelligkeitsArt.aktuell);
      expect(f.termin, t(2026, 11, 1));
    });

    test('ohne Rhythmus nie fällig; archivierte nie; die Zahl zählt Reihen', () {
      final reihen = baueReihen(
        {
          'a': z(ZaehlerArt.strom, 'S', ablesung: const Ablesung.monatlich(1)),
          'b': z(ZaehlerArt.gas, 'G'),
          'c': z(ZaehlerArt.kaltwasser, 'W', ablesung: const Ablesung.monatlich(1), arch: '2026-01-01'),
          'd': z(ZaehlerArt.waerme, 'H', ablesung: const Ablesung.jaehrlich(monat: 1, tag: 1)),
        },
        {'a': [s(2026, 9, 1, 1)], 'b': [s(2026, 1, 1, 1)], 'c': [s(2026, 1, 1, 1)], 'd': [s(2026, 1, 2, 1)]},
      );
      expect(faelligeReihen(reihen, heute).map((r) => r.id), ['a']);
      expect(kachelFaelligkeit(baueKacheln(reihen).firstWhere((k) => k.titel == 'G'), heute).art, FaelligkeitsArt.keinRhythmus);
    });
  });

  group('Solar und Vorschau', () {
    test('Solar: Vorteil der Periode und Amortisation aus dem eigenen Strompreis', () {
      final heute = t(2026, 10, 24);
      final inhalt = ZaehlerInhalt(
        art: ZaehlerArt.erzeugung,
        name: 'Solar',
        preise: const [Preis(ab: '2020-01-01', arbeitspreis: 3000)], // 0,30 €
        eigenverbrauchBp: 5000,
        anlagenkosten: 100000, // 1000 €
      );
      // 100 kWh je Monat seit dem 1.1.2026
      final staende = [for (var m = 1; m <= 10; m++) Stand(t(2026, m, 1), 100000 * (m - 1))];
      final r = baueReihen({'s': inhalt}, {'s': staende}).single;
      final a = solarAuswertung(r, heute);
      expect(a.periode.start, t(2026, 1, 1));
      // bis zum 1.10. erzeugt: 900 kWh, davon 50 % = 450 kWh * 0,30 € = 135 €
      expect(a.ergebnis.erzeugtMilli, 900000);
      expect(a.ergebnis.eigenMilli, 450000);
      expect(a.ergebnis.ersparnisCent, 13500);
      expect(a.amortisation, isNotNull);
      expect(a.amortisation!.bisherCent, 13500);
      expect(a.amortisation!.amortisiert, isFalse);
    });

    test('Vorschau eines neuen Standes: Verbrauch seit dem letzten, je Tag, Vorjahr nur wenn bekannt', () {
      final r = baueReihen({'a': z(ZaehlerArt.strom, 'S')}, {'a': [s(2025, 9, 25, 100), s(2025, 10, 23, 400), s(2026, 9, 25, 47901), s(2026, 10, 1, 47950)]}).single;
      final v = standVorschau(r, t(2026, 10, 23), 48213000 ~/ 1000 * 1000);
      expect(v.davor!.tag, t(2026, 10, 1));
      expect(v.tage, 22);
      expect(v.verbrauchMilli, 48213000 - 47950000);
      expect(v.proTagMilli, rundenDiv(48213000 - 47950000, 22));
      // zu niedriger Stand: kein Verbrauch, aber der letzte Stand wird genannt
      final w = standVorschau(r, t(2026, 10, 23), 1000);
      expect(w.davor, isNotNull);
      expect(w.verbrauchMilli, isNull);
      // ohne früheren Stand nichts
      expect(standVorschau(r, t(2025, 1, 1), 5).davor, isNull);
    });
  });

  group('Formate', () {
    test('Stände, Verbrauch, Beträge und Prozent in deutscher Schreibweise', () {
      expect(standAnzeige(48213000), '48.213');
      expect(standAnzeige(47901500), '47.901,5');
      expect(verbrauchAnzeige(312000, 'kWh'), '312 kWh');
      expect(verbrauchAnzeige(5000, 'kWh'), '5,0 kWh');
      expect(verbrauchAnzeige(9400, 'm³'), '9,4 m³');
      expect(verbrauchAnzeige(1234567, 'm³'), '1.235 m³');
      expect(verbrauchAnzeige(312000, 'kWh', mitEinheit: false), '312');
      expect(euroAnzeige(104600), '1.046,00 €');
      expect(euroAnzeige(-9600), '-96,00 €');
      expect(euroKurz(9500), '95 €');
      expect(euroKurz(9550), '95,50 €');
      expect(preisAnzeige(3100), '0,31 €');
      expect(preisAnzeige(3456), '0,3456 €');
      expect(prozentAnzeige(12.4), '▲ 12 %');
      expect(prozentAnzeige(-8), '▼ 8 %');
      expect(prozentAnzeige(0.2), '± 0 %');
      expect(prozentAnzeige(null), '');
      expect(tagDeutsch(t(2026, 3, 5)), '05.03.2026');
      expect(datumTextDeutsch('2026-03-05'), '05.03.2026');
      expect(zeitraumText(Zeitraum(t(2025, 3, 1), t(2026, 3, 1))), '01.03.2025 bis 28.02.2026');
    });
  });
}
