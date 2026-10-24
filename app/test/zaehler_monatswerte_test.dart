// Zähler: Eingabeart "Monatswerte" (z. B. Balkonkraftwerk). Formate (Rückwärtskompatibilität zu altem `z1:` ohne Modus, Monatswert `a1:` mit `v: 2`) und reine Logik
// (Summen, Periode über den Jahreswechsel, Vorjahr, Hochrechnung, Ersparnis, Plausibilität, Einmal je Monat, Fälligkeit, Erinnerungstage). Ganze Zahlen, keine Gleitkommafehler.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_monate.dart';
import 'package:lx_fampad/data/zaehler/zaehler_uebersicht.dart';

DateTime D(String s) => DateTime.parse('${s}T00:00:00Z');
MonatsWert M(int j, int m, num kwh, {int zeit = 0, String id = ''}) => MonatsWert(jahr: j, monat: m, milli: (kwh * 1000).round(), zeit: zeit, id: id);
ZaehlerInhalt _solar({ZaehlerModus modus = ZaehlerModus.monat, List<Preis> preise = const [], int? eigen, int? anlage}) =>
    ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Balkon', modus: modus, preise: preise, eigenverbrauchBp: eigen, anlagenkosten: anlage);

void main() {
  group('Formate', () {
    test('Standard-Modus wird nicht geschrieben; alter z1: ohne Modus ist ein Zähler im Modus Zählerstand', () {
      final z = ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Haus');
      expect(jsonDecode(zaehlerKodieren(z).substring(3)), isNot(contains('modus')));
      final alt = zaehlerLesen('z1:{"v":1,"art":"s","name":"Haus","einheit":"kWh","kosten":true}')!;
      expect(alt.modus, ZaehlerModus.stand);
      expect(alt.monatlich, isFalse);
      expect(zaehlerKodieren(alt), zaehlerKodieren(z)); // byte-gleich
    });

    test('Modus Monatswerte wird geschrieben und gelesen, unbekannter Modus ist nicht lesbar', () {
      final z = _solar();
      final klar = zaehlerKodieren(z);
      expect(jsonDecode(klar.substring(3))['modus'], 'monat');
      expect(zaehlerLesen(klar)!.modus, ZaehlerModus.monat);
      expect(zaehlerLesen('z1:{"v":1,"art":"e","name":"B","einheit":"kWh","kosten":true,"modus":"zukunft"}'), isNull);
    });

    test('Vorbelegung: Erzeugung = Monatswerte, sonst Zählerstand', () {
      expect(ZaehlerModus.standardFuer(ZaehlerArt.erzeugung), ZaehlerModus.monat);
      for (final a in ZaehlerArt.values.where((a) => a != ZaehlerArt.erzeugung)) {
        expect(ZaehlerModus.standardFuer(a), ZaehlerModus.stand);
      }
    });

    test('Monatswert: v 2 ohne Datum, Rundreise, Grenzen', () {
      final s = StandInhalt.monatswert(monat: '2026-09', milli: 123456, zeit: 1760000000000, notiz: 'Anker');
      final klar = standKodieren(s);
      final j = jsonDecode(klar.substring(3)) as Map;
      expect(j['v'], 2);
      expect(j.containsKey('d'), isFalse);
      expect(j['m'], '2026-09');
      expect(standLesen(klar), s);
      expect(standLesen(klar)!.istMonatswert, isTrue);
      // negativ, zu groß, kaputter Monat werden nie geschrieben
      expect(() => standKodieren(StandInhalt.monatswert(monat: '2026-09', milli: -1, zeit: 0)), throwsArgumentError);
      expect(() => standKodieren(StandInhalt.monatswert(monat: '2026-09', milli: kMaxMonatswertMilli + 1, zeit: 0)), throwsArgumentError);
      expect(() => standKodieren(StandInhalt.monatswert(monat: '2026-13', milli: 1, zeit: 0)), throwsArgumentError);
      expect(standKodieren(StandInhalt.monatswert(monat: '2026-09', milli: kMaxMonatswertMilli, zeit: 0)), isNotEmpty); // 100 000 kWh
    });

    test('Ältere App: v 2 ist für sie nicht lesbar (nie ein Zählerstand); neue App liest alte Stände weiter', () {
      // Verhalten der alten Prüfung: nur v 1 mit Datum
      final alt = standLesen('a1:{"v":1,"d":"2026-01-02","w":5000}')!;
      expect(alt.istMonatswert, isFalse);
      expect(alt.milli, 5000);
      expect(standLesen('a1:{"v":3,"m":"2026-01","w":1,"t":1}'), isNull); // künftige Version
      expect(standLesen('a1:{"v":2,"w":1,"t":1}'), isNull); // ohne Monat
      expect(standLesen('a1:{"v":2,"m":"2026-01","w":-1,"t":1}'), isNull);
    });

    test('Monat lesen und schreiben', () {
      expect(monatLesen('2026-02'), (jahr: 2026, monat: 2));
      expect(monatLesen('2026-2'), isNull);
      expect(monatLesen('1999-12'), isNull);
      expect(monatText(2026, 3), '2026-03');
    });
  });

  group('Einmal je Monat (Zusammenführen)', () {
    test('der zuletzt geschriebene gewinnt, bei Gleichstand die größte ID, Ergebnis aufsteigend', () {
      final r = monatswerteZusammenfuehren([
        M(2026, 5, 10, zeit: 5, id: 'b'),
        M(2026, 4, 7, zeit: 1, id: 'a'),
        M(2026, 5, 12, zeit: 9, id: 'a'),
        M(2026, 6, 3, zeit: 4, id: 'a'),
        M(2026, 6, 4, zeit: 4, id: 'b'),
      ]);
      expect(r.map((e) => (e.monat, e.milli)).toList(), [(4, 7000), (5, 12000), (6, 4000)]);
      // Reihenfolge der Eingabe egal
      final r2 = monatswerteZusammenfuehren([M(2026, 6, 4, zeit: 4, id: 'b'), M(2026, 6, 3, zeit: 4, id: 'a')]);
      expect(r2.single.milli, 4000);
    });
  });

  group('Kurve, Summen, Periode, Vorjahr', () {
    final werte = [for (var m = 1; m <= 12; m++) M(2025, m, 10.0 * m), for (var m = 1; m <= 3; m++) M(2026, m, 20.0 * m)];

    test('Monatssummen sind exakt die Eingaben, Jahressumme die Summe', () {
      final k = Verbrauchskurve.ausMonatswerten(werte);
      for (var m = 1; m <= 12; m++) {
        expect(k.verbrauch(DateTime.utc(2025, m, 1), DateTime.utc(2025, m + 1, 1)).milli, 10000 * m);
      }
      expect(k.verbrauch(D('2025-01-01'), D('2026-01-01')).milli, 780000);
      expect(k.verbrauch(D('2025-01-01'), D('2026-01-01')).vollstaendig, isTrue);
      expect(summeMonate(werte, 2025, 1, 2026, 1), 780000);
    });

    test('Periode über den Jahreswechsel (ab 1. Juli)', () {
      final k = Verbrauchskurve.ausMonatswerten(werte);
      final p = abrechnungsperiode(D('2026-02-10'), periodeMonat: 7, periodeTag: 1); // 2025-07-01 .. 2026-07-01
      // Juli..Dez 2025 = 10*(7+..+12)=570, Jan..Mar 2026 = 20+40+60=120; Apr-Jun fehlen
      final v = k.verbrauch(p.start, p.ende);
      expect(v.milli, 690000);
      expect(v.vollstaendig, isFalse); // Apr bis Jun 2026 fehlen: Ende der Kurve, nicht abgedeckt
      expect(v.abgedeckteTage, 274); // 184 + 90
    });

    test('Fehlende Monate in der Mitte: Lücke zählt 0 und ist nicht abgedeckt', () {
      final k = Verbrauchskurve.ausMonatswerten([M(2026, 1, 10), M(2026, 3, 30)]);
      final v = k.verbrauch(D('2026-01-01'), D('2026-04-01'));
      expect(v.milli, 40000);
      expect(v.abgedeckteTage, 31 + 31);
      expect(v.gesamtTage, 90);
      expect(v.vollstaendig, isFalse);
      final mo = verbrauchJeMonat(k, D('2026-01-01'), D('2026-04-01'));
      expect(mo.map((e) => (e.milli, e.vollstaendig)).toList(), [(10000, true), (0, false), (30000, true)]);
    });

    test('Vorjahresvergleich', () {
      final k = Verbrauchskurve.ausMonatswerten(werte);
      final v = vergleichVorjahr(k, Zeitraum(D('2026-01-01'), D('2027-01-01')), D('2026-04-01'));
      expect(v.aktuellMilli, 120000); // Jan bis Mar 2026
      expect(v.vorjahrMilli, 60000); // Jan bis Mar 2025: 10+20+30
      expect(v.prozent, 100);
      expect(v.vollstaendig, isTrue);
    });

    test('Laufender Monat ist ein Zwischenstand bis heute und nicht vollständig; die Zukunft zählt nie', () {
      final k = Verbrauchskurve.ausMonatswerten([M(2026, 9, 30), M(2026, 10, 12.4), M(2026, 11, 99)], heute: D('2026-10-24'));
      final okt = verbrauchJeMonat(k, D('2026-10-01'), D('2026-11-01')).single;
      expect(okt.milli, 12400);
      expect(okt.vollstaendig, isFalse);
      expect(k.verbrauch(D('2026-11-01'), D('2026-12-01')).milli, 0);
      expect(k.verbrauch(D('2026-09-01'), D('2026-10-01')).vollstaendig, isTrue);
    });

    test('Reihe: Modus Monatswerte rechnet aus den Monatswerten, Stände zählen dort nie', () {
      final id = 'solar';
      final reihen = baueReihen(
        {id: _solar()},
        {id: [Stand(D('2026-01-01'), 1000), Stand(D('2026-03-01'), 999999)]},
        monatswerte: {id: [M(2026, 1, 10, zeit: 1, id: 'a'), M(2026, 1, 11, zeit: 2, id: 'b')]},
        heute: D('2026-02-15'),
      );
      final r = reihen.single;
      expect(r.monatlich, isTrue);
      expect(r.staende, isEmpty);
      expect(r.monatswerte.single.milli, 11000);
      expect(kachelVerbrauch(baueKacheln(reihen).single, D('2026-01-01'), D('2026-02-01')).milli, 11000);
    });

    test('Reihe im Modus Zählerstand bleibt unverändert (Monatswerte werden ignoriert)', () {
      final reihen = baueReihen(
        {'z': _solar(modus: ZaehlerModus.stand)},
        {'z': [Stand(D('2026-01-01'), 1000), Stand(D('2026-02-01'), 4100)]},
        monatswerte: {'z': [M(2026, 1, 500)]},
      );
      expect(reihen.single.kurve.verbrauch(D('2026-01-01'), D('2026-02-01')).milli, 3100);
      expect(reihen.single.monatswerte, isEmpty);
    });
  });

  group('Hochrechnung', () {
    final periode = Zeitraum(D('2026-01-01'), D('2027-01-01'));

    test('fehlende Monate aus dem Vorjahresmonat, sonst aus dem Durchschnitt; laufender Monat ab dem 14. Tag hochgerechnet', () {
      final werte = [
        for (var m = 1; m <= 12; m++) M(2025, m, 10.0 * m),
        M(2026, 1, 15), M(2026, 2, 25), // März fehlt -> Vorjahr 30
        M(2026, 4, 45), M(2026, 5, 55), M(2026, 6, 65),
      ];
      final h = monatsHochrechnung(werte, periode, D('2026-07-20'))!; // Juli ohne Wert -> Vorjahr 70
      // bekannt 15+25+45+55+65 = 205; geschätzt: Mär 30, Jul 70, Aug..Dez 80+90+100+110+120 = 500
      expect(h.bekanntMilli, 205000);
      expect(h.prognoseMilli, 205000 + 30000 + 70000 + 500000);
      expect(h.bekannteMonate, 5);
      expect(h.geschaetzteMonate, 7);
    });

    test('ohne Vorjahr: Durchschnitt der bekannten vollen Monate; laufender Monat ab 14. Tag auf den Monat hochgerechnet', () {
      final werte = [M(2026, 1, 10), M(2026, 2, 20), M(2026, 3, 30), M(2026, 4, 9)];
      final h = monatsHochrechnung(werte, periode, D('2026-04-15'))!;
      // April: 9 kWh in 15 Tagen -> 18 kWh; Mai..Dez (8 Monate) je Durchschnitt 20
      expect(h.prognoseMilli, 10000 + 20000 + 30000 + 18000 + 8 * 20000);
      expect(h.geschaetzteMonate, 9);
    });

    test('laufender Monat vor dem 14. Tag: nie weniger als schon erreicht, Schätzung wie ein fehlender Monat', () {
      final werte = [M(2026, 1, 10), M(2026, 2, 10), M(2026, 3, 90)];
      final h = monatsHochrechnung(werte, periode, D('2026-03-05'))!;
      // März: Durchschnitt Jan/Feb = 10 < 90 erreicht -> 90; Apr..Dez 9 Monate je 10
      expect(h.prognoseMilli, 10000 + 10000 + 90000 + 9 * 10000);
    });

    test('keine Grundlage oder Periode zu Ende: null', () {
      expect(monatsHochrechnung(const [], periode, D('2026-06-01')), isNull);
      expect(monatsHochrechnung([M(2026, 6, 5)], periode, D('2026-06-05')), isNull); // laufender Monat vor dem 14. und nichts sonst
      expect(monatsHochrechnung([M(2026, 1, 5)], periode, D('2027-01-01')), isNull);
    });
  });

  group('Solar: Ersparnis und Amortisation', () {
    test('Summe x Eigenverbrauchsanteil x Strompreis laut Preisverlauf', () {
      final z = _solar(eigen: 8000, anlage: 50000, preise: [const Preis(ab: '2025-01-01', arbeitspreis: 3000), const Preis(ab: '2026-01-01', arbeitspreis: 4000)]);
      final k = Verbrauchskurve.ausMonatswerten([M(2025, 6, 100), M(2026, 6, 100)]);
      final a = solarVorteil(z, k, Zeitraum(D('2025-01-01'), D('2027-01-01')), z.preise);
      expect(a.erzeugtMilli, 200000);
      expect(a.eigenMilli, 160000); // 80 %
      // 80 kWh * 0,30 + 80 kWh * 0,40 = 56 EUR
      expect(a.ersparnisCent, 5600);
      final reihen = baueReihen({'s': z}, {}, monatswerte: {'s': [M(2025, 6, 100), M(2026, 6, 100)]}, heute: D('2026-10-24'));
      final s = solarAuswertung(reihen.single, D('2026-10-24'));
      expect(s.ergebnis.erzeugtMilli, 100000); // Kalenderjahr 2026
      expect(s.amortisation!.bisherCent, 5600);
      expect(s.amortisation!.amortisiert, isFalse);
    });
  });

  group('Solar: nur ein Preis, Beginn heute (der Fall aus dem Alltag)', () {
    test('der eine Preis gilt auch für die Monate davor, Eigenverbrauch deckt den ganzen laufenden Monat', () {
      final z = _solar(eigen: 10000, preise: [const Preis(ab: '2026-10-24', arbeitspreis: 3000)]);
      final werte = [M(2026, 8, 100), M(2026, 9, 100), M(2026, 10, 31)];
      final reihen = baueReihen({'s': z}, {}, monatswerte: {'s': werte}, heute: D('2026-10-24'));
      final s = solarAuswertung(reihen.single, D('2026-10-24'));
      expect(s.ergebnis.preisLuecke, isFalse);
      expect(s.ergebnis.erzeugtMilli, 231000);
      expect(s.ergebnis.eigenMilli, 231000, reason: 'auch der Anteil des heutigen Tages zählt, die Summe stimmt mit den Eingaben überein');
      expect(s.ergebnis.ersparnisCent, 6930); // 231 kWh * 0,30
    });
  });

  group('Plausibilität', () {
    final vorhanden = [M(2025, 6, 100, id: 'v'), M(2026, 5, 80, id: 'w')];
    final heute = D('2026-10-24');
    test('Zukunft blockiert, laufender Monat ist Zwischenstand', () {
      final z = pruefeMonatswert(jahr: 2026, monat: 11, milli: 1000, werte: vorhanden, heute: heute);
      expect(z.blockiert, isTrue);
      final l = pruefeMonatswert(jahr: 2026, monat: 10, milli: 1000, werte: vorhanden, heute: heute);
      expect(l.blockiert, isFalse);
      expect(l.hinweise, [MonatswertHinweis.zwischenstand]);
    });
    test('mehr als doppelt so hoch wie im Vorjahresmonat und über 50 kWh: Rückfrage', () {
      expect(pruefeMonatswert(jahr: 2026, monat: 6, milli: 201000, werte: vorhanden, heute: heute).hinweise, [MonatswertHinweis.hoeherAlsVorjahr]);
      expect(pruefeMonatswert(jahr: 2026, monat: 6, milli: 200000, werte: vorhanden, heute: heute).ok, isTrue); // genau das Doppelte: keine Rückfrage
      // kleine Werte schwanken stark: unter 50 kWh nie
      final klein = [M(2025, 6, 10)];
      expect(pruefeMonatswert(jahr: 2026, monat: 6, milli: 49000, werte: klein, heute: heute).ok, isTrue);
      // ohne Vorjahr nie
      expect(pruefeMonatswert(jahr: 2026, monat: 7, milli: 90000000, werte: vorhanden, heute: heute).ok, isTrue);
    });
    test('vorhandener Monat: ersetzen, außer der eigene Eintrag wird geändert', () {
      expect(pruefeMonatswert(jahr: 2026, monat: 5, milli: 80000, werte: vorhanden, heute: heute).hinweise, [MonatswertHinweis.ersetzt]);
      expect(pruefeMonatswert(jahr: 2026, monat: 5, milli: 80000, werte: vorhanden, heute: heute, ausser: 'w').ok, isTrue);
    });
  });

  group('Fälligkeit und Erinnerungstage', () {
    test('am Monatsersten ist der Vormonat fällig, bis er eingetragen ist', () {
      final f = monatswertFaellig([M(2026, 8, 5)], D('2026-10-02'));
      expect(f.faellig, isTrue);
      expect(f.naechsterTermin, D('2026-10-01'));
      final ok = monatswertFaellig([M(2026, 9, 5)], D('2026-10-02'));
      expect(ok.faellig, isFalse);
      expect(ok.naechsterTermin, D('2026-11-01'));
      expect(monatswertFaellig(const [], D('2026-10-02')).faellig, isTrue);
      expect(monatswertFaellig([M(2025, 12, 5)], D('2026-01-03')).faellig, isFalse); // Jahreswechsel
    });
    test('Erinnerungstage: Monatserste, an denen der Vormonat fehlt', () {
      final t = monatswertErinnerungstage([M(2026, 9, 1)], D('2026-10-24'), D('2027-01-10'));
      expect(t, [D('2026-11-01'), D('2026-12-01'), D('2027-01-01')]);
      expect(monatswertErinnerungstage([M(2026, 10, 1)], D('2026-10-24'), D('2026-12-10')), [D('2026-12-01')]);
    });
    test('Auswahl: laufender Monat und die 24 davor, Vormonat als Vorbelegung', () {
      final a = auswahlMonate(D('2026-01-15'));
      expect(a.length, 25);
      expect(a.first, (jahr: 2026, monat: 1));
      expect(a.last, (jahr: 2024, monat: 1));
      expect(vormonat(D('2026-01-15')), (jahr: 2025, monat: 12));
    });
  });
}
