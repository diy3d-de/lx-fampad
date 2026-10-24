// Zähler (Abschnitt 6l): reine Rechenlogik. Alles mit ganzen Zahlen (Stände in Tausendstel, Preise in Zehntausendstel Euro, Beträge in Cent), Tage statt Uhrzeiten.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';

DateTime D(String s) => DateTime.parse('${s}T00:00:00Z');
Stand S(String tag, int milli, {StandMarke? marke}) => Stand(D(tag), milli, marke: marke);
Zeitraum Z(String von, String bis) => Zeitraum(D(von), D(bis));

ZaehlerInhalt _z({List<Preis> preise = const [], int? abschlag, ZaehlerArt art = ZaehlerArt.strom, int? eigen, int? einsp, String gruppe = '', String? vorgaenger}) =>
    ZaehlerInhalt(art: art, name: 'Z', preise: preise, abschlag: abschlag, eigenverbrauchBp: eigen, einspeiseVerguetung: einsp, gruppe: gruppe, vorgaenger: vorgaenger);

void main() {
  group('Verbrauch aus Standdifferenzen', () {
    test('gleichmäßig auf Tage umgelegt, auch bei unregelmäßigem Ablesen', () {
      final k = Verbrauchskurve.aus([S('2026-01-15', 100000), S('2026-03-01', 145000)]); // 45 Tage, 1000 je Tag
      expect(k.verbrauch(D('2026-01-15'), D('2026-03-01')).milli, 45000);
      expect(k.verbrauch(D('2026-01-15'), D('2026-02-01')).milli, 17000);
      expect(k.verbrauch(D('2026-02-01'), D('2026-03-01')).milli, 28000);
      expect(k.verbrauch(D('2026-01-20'), D('2026-01-21')).milli, 1000);
      expect(k.verbrauch(D('2026-01-15'), D('2026-03-01')).vollstaendig, isTrue);
    });

    test('nur der abgedeckte Teil zählt, der Rest ist als unvollständig gekennzeichnet', () {
      final k = Verbrauchskurve.aus([S('2026-01-15', 100000), S('2026-03-01', 145000)]);
      final v = k.verbrauch(D('2026-01-01'), D('2026-03-01'));
      expect(v.milli, 45000);
      expect(v.abgedeckteTage, 45);
      expect(v.gesamtTage, 59);
      expect(v.vollstaendig, isFalse);
      final davor = k.verbrauch(D('2025-12-01'), D('2026-01-10'));
      expect([davor.milli, davor.abgedeckteTage], [0, 0]);
      final danach = k.verbrauch(D('2026-04-01'), D('2026-05-01'));
      expect([danach.milli, danach.abgedeckteTage, danach.gesamtTage], [0, 0, 30]);
    });

    test('leere Kurve und leerer Zeitraum', () {
      expect(Verbrauchskurve.leer.verbrauch(D('2026-01-01'), D('2026-02-01')).abgedeckteTage, 0);
      expect(Verbrauchskurve.leer.istLeer, isTrue);
      final k = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-02-01', 100)]);
      expect(k.verbrauch(D('2026-01-10'), D('2026-01-10')), same(Verbrauch.leer));
      expect(k.verbrauch(D('2026-01-10'), D('2026-01-05')), same(Verbrauch.leer));
      // ein einzelner Stand ergibt keinen Verbrauch
      final eins = Verbrauchskurve.aus([S('2026-01-01', 5)]);
      expect(eins.verbrauch(D('2026-01-01'), D('2026-02-01')).abgedeckteTage, 0);
    });

    test('Rundung: die Teile ergeben immer genau die Summe', () {
      final k = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-01-04', 1000)]); // 333,33 je Tag
      expect(k.bei(tagNummer(D('2026-01-02'))), 333);
      expect(k.bei(tagNummer(D('2026-01-03'))), 667);
      final teile = [for (var t = 1; t < 4; t++) k.verbrauch(D('2026-01-0$t'), D('2026-01-0${t + 1}')).milli];
      expect(teile, [333, 334, 333]);
      expect(teile.reduce((a, b) => a + b), 1000);
    });

    test('Monatsverbrauch: Summe der Monate = Verbrauch der Periode, auch bei unregelmäßigen Ständen', () {
      final k = Verbrauchskurve.aus([S('2025-01-05', 1000), S('2025-02-17', 50000), S('2025-05-02', 120000), S('2025-09-30', 190000), S('2026-01-03', 260000)]);
      final monate = verbrauchJeMonat(k, D('2025-01-05'), D('2026-01-03'));
      expect(monate, hasLength(13));
      final summe = monate.fold<int>(0, (a, m) => a + m.milli);
      expect(summe, k.verbrauch(D('2025-01-05'), D('2026-01-03')).milli);
      expect(summe, 259000);
      expect(monate.first.tage, 27); // angeschnittener erster Monat
      expect(monate.last.tage, 2);
      expect(monate.every((m) => m.vollstaendig), isTrue);
      // der Monat Februar 2025 (28 Tage)
      final feb = monate.firstWhere((m) => m.monat == 2 && m.jahr == 2025);
      expect(feb.tage, 28);
    });

    test('Monate vor dem ersten Stand sind unvollständig', () {
      final k = Verbrauchskurve.aus([S('2026-02-10', 0), S('2026-04-10', 6000)]);
      final m = verbrauchJeMonat(k, D('2026-01-01'), D('2026-05-01'));
      expect(m.map((e) => e.vollstaendig), [false, false, true, false, false].sublist(0, 4));
      expect(m[0].milli, 0);
      expect(m.last.vollstaendig, isFalse); // April: ab dem 10. nicht mehr abgedeckt
    });

    test('Stand niedriger als der vorige: kein negativer Verbrauch, der Rücksprung wird gezählt', () {
      final k = Verbrauchskurve.aus([S('2026-01-01', 100000), S('2026-02-01', 50000), S('2026-03-01', 60000)]);
      expect(k.ruecksprunege, 1);
      expect(k.verbrauch(D('2026-01-01'), D('2026-03-01')).milli, 10000);
      expect(k.verbrauch(D('2026-01-01'), D('2026-02-01')).milli, 0);
    });

    test('zwei Stände am selben Tag: der zuletzt angelegte gilt', () {
      final n = normalisiere([S('2026-01-01', 10), S('2026-01-05', 20), S('2026-01-01', 15)]);
      expect(n.map((s) => '${tagNummer(s.tag)}:${s.milli}'), ['${tagNummer(D('2026-01-01'))}:15', '${tagNummer(D('2026-01-05'))}:20']);
    });

    test('Eingabereihenfolge ist egal', () {
      final a = Verbrauchskurve.aus([S('2026-03-01', 300), S('2026-01-01', 100), S('2026-02-01', 200)]);
      expect(a.verbrauch(D('2026-01-01'), D('2026-03-01')).milli, 200);
    });

    test('Tage hängen nicht von Zeitzone und Sommerzeit ab', () {
      expect(tagNummer(DateTime(2026, 3, 29, 23, 30)), tagNummer(D('2026-03-29')));
      expect(tagNummer(D('2026-03-30')) - tagNummer(D('2026-03-28')), 2);
      expect(tagNummer(D('2026-10-26')) - tagNummer(D('2026-10-24')), 2);
    });
  });

  group('Abrechnungsperiode', () {
    test('Kalenderjahr', () {
      final p = abrechnungsperiode(D('2026-07-15'));
      expect(p, Z('2026-01-01', '2027-01-01'));
      expect(p.tage, 365);
      expect(abrechnungsperiode(D('2026-01-01')), p);
      expect(abrechnungsperiode(D('2026-12-31')), p);
      expect(periodenBezeichnung(p), '2026');
    });

    test('ab 1. März, über den Jahreswechsel', () {
      final p = abrechnungsperiode(D('2026-01-15'), periodeMonat: 3);
      expect(p, Z('2025-03-01', '2026-03-01'));
      expect(abrechnungsperiode(D('2026-03-01'), periodeMonat: 3), Z('2026-03-01', '2027-03-01'));
      expect(abrechnungsperiode(D('2026-02-28'), periodeMonat: 3), p);
      expect(periodenBezeichnung(p, periodeMonat: 3), '2025/26');
      expect(periodenBezeichnung(Z('2099-03-01', '2100-03-01'), periodeMonat: 3), '2099/00');
    });

    test('Schaltjahr: 366 Tage in der Periode, die den 29. Februar enthält', () {
      expect(abrechnungsperiode(D('2024-02-29'), periodeMonat: 3).tage, 366);
      expect(abrechnungsperiode(D('2024-03-01'), periodeMonat: 3).tage, 365);
      expect(abrechnungsperiode(D('2024-06-01')).tage, 366);
      expect(abrechnungsperiode(D('2025-06-01')).tage, 365);
    });

    test('Beginn am 29. Februar oder 31.: in kurzen Monaten der letzte Tag', () {
      expect(abrechnungsperiode(D('2025-02-28'), periodeMonat: 2, periodeTag: 29), Z('2025-02-28', '2026-02-28'));
      expect(abrechnungsperiode(D('2025-02-27'), periodeMonat: 2, periodeTag: 29), Z('2024-02-29', '2025-02-28'));
      expect(abrechnungsperiode(D('2026-03-01'), periodeMonat: 2, periodeTag: 29), Z('2026-02-28', '2027-02-28'));
      expect(abrechnungsperiode(D('2026-05-15'), periodeMonat: 4, periodeTag: 31), Z('2026-04-30', '2027-04-30'));
    });

    test('Periode davor und danach schließen lückenlos an', () {
      final p = abrechnungsperiode(D('2026-01-15'), periodeMonat: 3);
      final davor = periodeDavor(p, periodeMonat: 3);
      final danach = periodeDanach(p, periodeMonat: 3);
      expect(davor.ende, p.start);
      expect(danach.start, p.ende);
      expect(davor, Z('2024-03-01', '2025-03-01'));
      expect(danach, Z('2026-03-01', '2027-03-01'));
      expect(p.enthaelt(D('2025-03-01')), isTrue);
      expect(p.enthaelt(D('2026-03-01')), isFalse);
    });

    test('Vorjahreszeitraum (29. Februar wird zum 28.)', () {
      expect(vorjahrVon(Z('2025-01-01', '2026-01-01')), Z('2024-01-01', '2025-01-01'));
      expect(vorjahrVon(Z('2024-02-29', '2024-03-31')), Z('2023-02-28', '2023-03-31'));
    });
  });

  group('Vorjahresvergleich und Hochrechnung', () {
    // 2024: 1000 je Tag (366 Tage), 2025: 1100 je Tag (365 Tage)
    final k = Verbrauchskurve.aus([S('2024-01-01', 0), S('2025-01-01', 366000), S('2026-01-01', 767500)]);

    test('abgeschlossene Periode gegen das Vorjahr', () {
      final v = vergleichVorjahr(k, Z('2025-01-01', '2026-01-01'), D('2026-02-01'));
      expect([v.aktuellMilli, v.vorjahrMilli, v.differenzMilli], [401500, 366000, 35500]);
      expect(v.prozent, closeTo(9.699, 0.001));
      expect(v.vollstaendig, isTrue);
    });

    test('laufende Periode: beide nur bis heute', () {
      final v = vergleichVorjahr(k, Z('2025-01-01', '2026-01-01'), D('2025-07-01'));
      expect(v.aktuell, Z('2025-01-01', '2025-07-01'));
      expect(v.aktuellMilli, 199100);
      expect(v.vorjahr, Z('2024-01-01', '2024-07-01'));
      expect(v.vorjahrMilli, 182000);
    });

    test('ohne Vorjahreswerte: keine Prozent, unvollständig', () {
      final v = vergleichVorjahr(k, Z('2024-01-01', '2025-01-01'), D('2025-02-01'));
      expect(v.vorjahrMilli, 0);
      expect(v.prozent, isNull);
      expect(v.vollstaendig, isFalse);
    });

    test('Hochrechnung aufs Jahr aus der bisherigen Rate', () {
      final kk = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-04-01', 90000)]);
      final h = hochrechnung(kk, Z('2026-01-01', '2027-01-01'), D('2026-04-01'))!;
      expect(h.prognoseMilli, 365000);
      expect([h.beobachtetMilli, h.beobachteteTage, h.periodenTage], [90000, 90, 365]);
    });

    test('Hochrechnung bei Beginn nach dem Periodenstart nutzt nur die abgedeckten Tage', () {
      final kk = Verbrauchskurve.aus([S('2026-01-11', 0), S('2026-04-01', 80000)]);
      final h = hochrechnung(kk, Z('2026-01-01', '2027-01-01'), D('2026-04-01'))!;
      expect(h.beobachteteTage, 80);
      expect(h.prognoseMilli, 365000);
    });

    test('keine Hochrechnung bei zu kurzer Beobachtung oder abgeschlossener Periode', () {
      final kk = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-01-10', 9000)]);
      expect(hochrechnung(kk, Z('2026-01-01', '2027-01-01'), D('2026-01-10')), isNull);
      expect(hochrechnung(kk, Z('2026-01-01', '2027-01-01'), D('2026-01-10'), mindestTage: 9), isNotNull);
      expect(hochrechnung(k, Z('2025-01-01', '2026-01-01'), D('2026-01-01')), isNull);
    });
  });

  group('Kosten', () {
    final jahr2025 = Z('2025-01-01', '2026-01-01');
    // 10 Einheiten je Tag: 3650 Einheiten im Jahr
    final stetig = Verbrauchskurve.aus([S('2025-01-01', 0), S('2026-01-01', 3650000)]);

    test('Arbeitspreis, Grund- und Zählergebühr für eine volle Periode', () {
      final preise = [const Preis(ab: '2025-01-01', arbeitspreis: 3000, grundgebuehrJahr: 12000, zaehlergebuehrJahr: 1200)];
      final t = kostenFuerZeitraum(preise, stetig, jahr2025, bezugsTage: 365);
      expect(t.verbrauchMilli, 3650000);
      expect(t.verbrauchCent, 109500); // 3650 kWh * 0,30 EUR
      expect(t.grundCent, 12000);
      expect(t.zaehlerCent, 1200);
      expect(t.gesamtCent, 122700);
      expect(t.preisLuecke, isFalse);
    });

    test('Schaltjahr: eine volle Periode kostet genau eine Jahresgebühr', () {
      final p = Z('2024-01-01', '2025-01-01');
      final k = Verbrauchskurve.aus([S('2024-01-01', 0), S('2025-01-01', 3660000)]);
      final t = kostenFuerZeitraum([const Preis(ab: '2024-01-01', arbeitspreis: 3000, grundgebuehrJahr: 12000, zaehlergebuehrJahr: 1200)], k, p, bezugsTage: p.tage);
      expect(p.tage, 366);
      expect([t.grundCent, t.zaehlerCent], [12000, 1200]);
    });

    test('Preisverlauf: alte Zeiträume mit altem Preis, Gebühren anteilig auf Tage', () {
      final preise = [
        const Preis(ab: '2025-01-01', arbeitspreis: 3000, grundgebuehrJahr: 12000),
        const Preis(ab: '2025-07-01', arbeitspreis: 4000, grundgebuehrJahr: 24000),
      ];
      final t = kostenFuerZeitraum(preise, stetig, jahr2025, bezugsTage: 365);
      // 181 Tage * 10 * 0,30 + 184 Tage * 10 * 0,40 = 543 + 736 EUR
      expect(t.verbrauchCent, 127900);
      // (12000 * 181 + 24000 * 184) / 365
      expect(t.grundCent, 18049);
      // nur das erste Halbjahr: alter Preis
      final h1 = kostenFuerZeitraum(preise, stetig, Z('2025-01-01', '2025-07-01'), bezugsTage: 365);
      expect(h1.verbrauchCent, 54300);
      expect(h1.grundCent, 5951); // 12000 * 181 / 365
    });

    test('vor dem ersten Preisstand gilt der erste Preis rückwirkend, keine Lücke', () {
      final preise = [const Preis(ab: '2025-03-01', arbeitspreis: 3000)];
      final t = kostenFuerZeitraum(preise, stetig, jahr2025, bezugsTage: 365);
      expect(t.preisLuecke, isFalse);
      expect(t.verbrauchCent, 109500); // 365 Tage * 10 * 0,30, auch vor dem 1. März
      expect(t.verbrauchMilli, 3650000);
    });

    test('ohne Preise keine Kosten, aber eine Lücke', () {
      final t = kostenFuerZeitraum(const [], stetig, jahr2025, bezugsTage: 365);
      expect([t.gesamtCent, t.preisLuecke], [0, true]);
    });

    test('Preis am Tag: der letzte mit Beginn bis zu diesem Tag', () {
      final preise = [const Preis(ab: '2024-01-01', arbeitspreis: 1), const Preis(ab: '2025-01-01', arbeitspreis: 2)];
      expect(preisAm(preise, D('2023-12-31'))!.arbeitspreis, 1, reason: 'vor dem ersten Preis gilt der erste rückwirkend');
      expect(preisAm(const [], D('2023-12-31')), isNull);
      expect(preisAm(preise, D('2024-01-01'))!.arbeitspreis, 1);
      expect(preisAm(preise, D('2024-12-31'))!.arbeitspreis, 1);
      expect(preisAm(preise, D('2025-01-01'))!.arbeitspreis, 2);
    });

    test('abgeschlossene Periode: Abschläge und Nachzahlung', () {
      final z = _z(preise: [const Preis(ab: '2025-01-01', arbeitspreis: 3000, grundgebuehrJahr: 12000, zaehlergebuehrJahr: 1200)], abschlag: 10000);
      final k = periodenKosten(z, stetig, jahr2025, D('2026-02-01'));
      expect(k.laufend, isFalse);
      expect(k.prognose, isNull);
      expect(k.ganzePeriode!.gesamtCent, 122700);
      expect(k.abschlaegeGesamtCent, 120000); // 12 Monate
      expect(k.saldoCent, 2700); // Nachzahlung
    });

    test('Rückzahlung bei zu hohen Abschlägen (negativer Saldo)', () {
      final z = _z(preise: [const Preis(ab: '2025-01-01', arbeitspreis: 3000)], abschlag: 12000);
      final k = periodenKosten(z, stetig, jahr2025, D('2026-02-01'));
      expect(k.saldoCent, 109500 - 144000);
    });

    test('ohne Abschlag kein Saldo', () {
      final k = periodenKosten(_z(preise: [const Preis(ab: '2025-01-01', arbeitspreis: 3000)]), stetig, jahr2025, D('2026-02-01'));
      expect([k.abschlaegeGesamtCent, k.saldoCent], [null, null]);
    });

    test('laufende Periode: bisher, Prognose für die ganze Periode und voraussichtliche Nachzahlung', () {
      final z = _z(preise: [const Preis(ab: '2026-01-01', arbeitspreis: 3000, grundgebuehrJahr: 12000)], abschlag: 10000);
      final k = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-04-01', 900000)]);
      final p = periodenKosten(z, k, Z('2026-01-01', '2027-01-01'), D('2026-04-01'));
      expect(p.laufend, isTrue);
      expect(p.bisher.verbrauchCent, 27000);
      expect(p.bisher.grundCent, 2959); // 12000 * 90 / 365
      expect(p.prognose!.verbrauchMilli, 3650000);
      expect(p.prognose!.gesamtCent, 109500 + 12000);
      expect(p.abschlaegeBisherCent, 30000); // drei Monate
      expect(p.abschlaegeGesamtCent, 120000);
      expect(p.saldoCent, 1500);
      expect(p.ganzePeriode, same(p.prognose));
    });

    test('laufende Periode ohne genug Beobachtung: keine Prognose, kein Saldo', () {
      final z = _z(preise: [const Preis(ab: '2026-01-01', arbeitspreis: 3000)], abschlag: 10000);
      final k = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-01-05', 4000)]);
      final p = periodenKosten(z, k, Z('2026-01-01', '2027-01-01'), D('2026-01-05'));
      expect(p.prognose, isNull);
      expect(p.saldoCent, isNull);
      expect(p.bisher.verbrauchCent, 120); // 4 Einheiten * 0,30 EUR
    });

    test('Prognose mit Preiswechsel mitten in der Periode', () {
      final z = _z(preise: [const Preis(ab: '2026-01-01', arbeitspreis: 3000), const Preis(ab: '2026-07-01', arbeitspreis: 4000)]);
      final k = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-04-01', 900000)]);
      final p = periodenKosten(z, k, Z('2026-01-01', '2027-01-01'), D('2026-04-01'));
      // 181 Tage * 10 * 0,30 + 184 Tage * 10 * 0,40
      expect(p.prognose!.verbrauchCent, 127900);
    });

    test('Abschlagsmonate: ganze Monate ab Periodenbeginn', () {
      final p = Z('2026-01-01', '2027-01-01');
      expect(monateImZeitraum(p, D('2026-01-31')), 0);
      expect(monateImZeitraum(p, D('2026-02-01')), 1);
      expect(monateImZeitraum(p, D('2026-12-31')), 11);
      expect(monateImZeitraum(p, D('2027-01-01')), 12);
      expect(monateImZeitraum(p, D('2030-01-01')), 12); // nie mehr als die Periode
      expect(monateImZeitraum(Z('2026-03-01', '2027-03-01'), D('2027-03-01')), 12);
      expect(monateImZeitraum(Z('2026-04-30', '2027-04-30'), D('2027-04-30')), 12); // Beginn am 31. -> letzter Tag
    });
  });

  group('Solar-Ersparnis und Amortisation', () {
    final jahr = Z('2025-01-01', '2026-01-01');
    final erzeugt = Verbrauchskurve.aus([S('2025-01-01', 0), S('2026-01-01', 1000000)]); // 1000 kWh
    final strom = [const Preis(ab: '2025-01-01', arbeitspreis: 3000)];

    test('Erzeugung x Eigenverbrauchsanteil x Strompreis, dazu die Einspeisevergütung', () {
      final e = _z(art: ZaehlerArt.erzeugung, eigen: 6000, einsp: 800);
      final s = solarVorteil(e, erzeugt, jahr, strom);
      expect([s.erzeugtMilli, s.eigenMilli, s.einspeiseMilli], [1000000, 600000, 400000]);
      expect(s.ersparnisCent, 18000); // 600 kWh * 0,30
      expect(s.verguetungCent, 3200); // 400 kWh * 0,08
      expect(s.vorteilCent, 21200);
      expect(s.preisLuecke, isFalse);
    });

    test('ohne Angabe gilt 100 Prozent Eigenverbrauch, ohne Vergütung keine Einnahme', () {
      final s = solarVorteil(_z(art: ZaehlerArt.erzeugung), erzeugt, jahr, strom);
      expect([s.eigenMilli, s.einspeiseMilli, s.ersparnisCent, s.verguetungCent], [1000000, 0, 30000, 0]);
    });

    test('Strompreis mit Verlauf, der erste Preis gilt auch rückwirkend', () {
      final e = _z(art: ZaehlerArt.erzeugung, eigen: 10000);
      final verlauf = [const Preis(ab: '2025-01-01', arbeitspreis: 3000), const Preis(ab: '2025-07-01', arbeitspreis: 4000)];
      final s = solarVorteil(e, erzeugt, jahr, verlauf);
      // 1000 kWh gleichmäßig: 181/365 zum alten (0,30), 184/365 zum neuen Preis (0,40): ca. 350,41 EUR
      expect(s.ersparnisCent, 35041);
      // nur ein Preis mit Beginn mitten im Jahr: er gilt auch für die Monate davor (kein Ergebnis 0, keine Lücke)
      final nurEiner = solarVorteil(e, erzeugt, jahr, [const Preis(ab: '2025-07-01', arbeitspreis: 4000)]);
      expect(nurEiner.preisLuecke, isFalse);
      expect(nurEiner.ersparnisCent, 40000); // 1000 kWh * 0,40
      // ganz ohne Preis bleibt es eine Lücke mit Ersparnis 0
      final keiner = solarVorteil(e, erzeugt, jahr, const []);
      expect([keiner.preisLuecke, keiner.ersparnisCent], [true, 0]);
    });

    test('Amortisation: Rest, Jahre und Prozent', () {
      final a = amortisation(anlagenkostenCent: 1500000, bisherCent: 21200, proJahrCent: 21200);
      expect(a.amortisiert, isFalse);
      expect(a.restCent, 1478800);
      expect(a.restJahre, closeTo(69.75, 0.01));
      expect(a.prozent, closeTo(1.41, 0.01));
    });

    test('schon amortisiert oder ohne Jahresvorteil', () {
      final fertig = amortisation(anlagenkostenCent: 1000, bisherCent: 1600, proJahrCent: 100);
      expect([fertig.amortisiert, fertig.restCent, fertig.restJahre, fertig.prozent], [true, 0, null, 100.0]);
      expect(amortisation(anlagenkostenCent: 1000, bisherCent: 0, proJahrCent: 0).restJahre, isNull);
      expect(amortisation(anlagenkostenCent: 0, bisherCent: 0, proJahrCent: 0).amortisiert, isTrue);
    });
  });

  group('Plausibilität eines Standes', () {
    final bestehende = [S('2026-01-01', 100000), S('2026-02-01', 130000)]; // 30000 in 31 Tagen
    final heute = D('2026-03-15');
    Plausibilitaet pruefen(String tag, int milli, {List<Stand>? b, int faktor = 10}) => pruefeStand(datum: D(tag), milli: milli, bestehende: b ?? bestehende, heute: heute, sprungFaktor: faktor);

    test('ein üblicher Stand ist unauffällig', () {
      expect(pruefen('2026-03-01', 160000).ok, isTrue);
      expect(pruefen('2026-03-15', 165000).ok, isTrue);
    });

    test('niedriger als der vorige: Verdacht auf Zählerwechsel', () {
      final p = pruefen('2026-03-01', 100000);
      expect(p.hinweise, contains(StandHinweis.niedriger));
      expect(p.wechselVerdacht, isTrue);
      expect(p.blockiert, isFalse);
      expect(pruefen('2026-03-01', 130000).ok, isTrue); // gleicher Stand: kein Verbrauch, kein Hinweis
    });

    test('Sprung: ein Vielfaches des Üblichen', () {
      expect(pruefen('2026-03-01', 1300000).hinweise, contains(StandHinweis.sprung));
      // verdrehte Ziffern 130000 -> 310000: bei Faktor 10 noch im Rahmen, bei Faktor 5 ein Sprung
      expect(pruefen('2026-03-01', 310000).ok, isTrue);
      expect(pruefen('2026-03-01', 310000, faktor: 5).hinweise, contains(StandHinweis.sprung));
    });

    test('lange Pause: der erwartete Zuwachs wächst mit den Tagen', () {
      // 270000 in 42 Tagen bei üblichen 30000 je 31 Tage: das 6,6-Fache
      expect(pruefen('2026-03-15', 400000).ok, isTrue);
      expect(pruefen('2026-03-15', 400000, faktor: 3).hinweise, contains(StandHinweis.sprung));
    });

    test('Datum in der Zukunft blockiert', () {
      final p = pruefen('2026-04-01', 170000);
      expect(p.blockiert, isTrue);
      expect(pruefen('2026-03-15', 170000).blockiert, isFalse); // heute ist erlaubt
    });

    test('derselbe Tag wie ein vorhandener Stand', () {
      expect(pruefen('2026-02-01', 131000).hinweise, contains(StandHinweis.datumDoppelt));
    });

    test('Einfügen in die Vergangenheit: höher als ein späterer Stand', () {
      expect(pruefen('2026-01-15', 140000).hinweise, contains(StandHinweis.hoeherAlsSpaeterer));
      expect(pruefen('2026-01-15', 110000).ok, isTrue);
    });

    test('ohne Verlauf (weniger als zwei Stände oder kein Verbrauch) keine Sprungprüfung', () {
      expect(pruefen('2026-03-01', 999999999, b: [S('2026-01-01', 100000)]).ok, isTrue);
      expect(pruefen('2026-03-01', 999999999, b: const []).ok, isTrue);
      expect(pruefen('2026-03-01', 500000, b: [S('2026-01-01', 100), S('2026-02-01', 100)]).ok, isTrue); // bisher kein Verbrauch: nichts, woran man messen könnte
    });
  });

  group('Ablese-Fälligkeit', () {
    test('monatlich am Tag X', () {
      const a = Ablesung.monatlich(1);
      var f = ablesungFaellig(a, D('2026-03-01'), D('2026-03-15'));
      expect([f.faellig, f.letzterTermin, f.naechsterTermin], [false, D('2026-03-01'), D('2026-04-01')]);
      f = ablesungFaellig(a, D('2026-02-20'), D('2026-03-15'));
      expect([f.faellig, f.naechsterTermin], [true, D('2026-03-01')]);
      f = ablesungFaellig(a, D('2026-02-20'), D('2026-03-01')); // am Stichtag selbst
      expect(f.faellig, isTrue);
      f = ablesungFaellig(a, D('2026-03-01'), D('2026-03-01'));
      expect(f.faellig, isFalse);
      f = ablesungFaellig(a, null, D('2026-03-15')); // nie abgelesen
      expect(f.faellig, isTrue);
    });

    test('vor dem Termin des Monats gilt der vom Vormonat', () {
      const a = Ablesung.monatlich(20);
      final f = ablesungFaellig(a, D('2026-02-21'), D('2026-03-10'));
      expect([f.letzterTermin, f.naechsterTermin, f.faellig], [D('2026-02-20'), D('2026-03-20'), false]);
      expect(ablesungFaellig(a, D('2026-02-19'), D('2026-03-10')).faellig, isTrue);
      // Jahreswechsel
      final j = ablesungFaellig(a, D('2025-12-25'), D('2026-01-10'));
      expect([j.letzterTermin, j.naechsterTermin, j.faellig], [D('2025-12-20'), D('2026-01-20'), false]);
    });

    test('Tag 31 in kurzen Monaten: der letzte Tag', () {
      const a = Ablesung.monatlich(31);
      final f = ablesungFaellig(a, D('2026-01-31'), D('2026-02-28'));
      expect([f.letzterTermin, f.naechsterTermin, f.faellig], [D('2026-02-28'), D('2026-02-28'), true]); // fällig: der nächste Termin ist der versäumte
      final ok = ablesungFaellig(a, D('2026-02-28'), D('2026-02-28'));
      expect([ok.faellig, ok.naechsterTermin], [false, D('2026-03-31')]);
    });

    test('Jahresablesung', () {
      const a = Ablesung.jaehrlich(monat: 12, tag: 31);
      var f = ablesungFaellig(a, D('2025-12-31'), D('2026-03-15'));
      expect([f.faellig, f.letzterTermin, f.naechsterTermin], [false, D('2025-12-31'), D('2026-12-31')]);
      f = ablesungFaellig(a, D('2025-12-30'), D('2026-03-15'));
      expect([f.faellig, f.naechsterTermin], [true, D('2025-12-31')]);
      f = ablesungFaellig(a, D('2026-12-31'), D('2026-12-31'));
      expect(f.faellig, isFalse);
      expect(ablesungFaellig(a, D('2025-12-31'), D('2026-12-31')).faellig, isTrue); // am Stichtag mit dem Stand vom Vorjahr
      f = ablesungFaellig(a, D('2025-12-31'), D('2027-01-01'));
      expect(f.faellig, isTrue);
      const feb = Ablesung.jaehrlich(monat: 2, tag: 29);
      f = ablesungFaellig(feb, D('2026-01-01'), D('2026-03-01'));
      expect([f.letzterTermin, f.naechsterTermin], [D('2026-02-28'), D('2026-02-28')]);
      f = ablesungFaellig(feb, D('2026-02-28'), D('2026-03-01'));
      expect([f.faellig, f.naechsterTermin], [false, D('2027-02-28')]);
    });

    test('ohne Rhythmus nie fällig', () {
      final f = ablesungFaellig(null, null, D('2026-03-15'));
      expect([f.faellig, f.letzterTermin, f.naechsterTermin], [false, null, null]);
    });
  });

  group('Zählerwechsel-Kette und Gruppen', () {
    // alter Zähler: 500000 -> 651000 (151 Tage, 1000 je Tag); neuer Zähler startet am Wechseltag bei 0
    final alt = Verbrauchskurve.aus([S('2026-01-01', 500000), S('2026-06-01', 651000, marke: StandMarke.ende)]);
    final neu = Verbrauchskurve.aus([S('2026-06-01', 0, marke: StandMarke.start), S('2026-12-01', 183000)]);

    test('der Verbrauch läuft nahtlos weiter', () {
      final r = Verbrauchskurve.verkettet([alt, neu]);
      expect(r.luecken, 0);
      expect(r.kurve.verbrauch(D('2026-01-01'), D('2026-12-01')).milli, 334000);
      expect(r.kurve.verbrauch(D('2026-01-01'), D('2026-12-01')).vollstaendig, isTrue);
      // über die Wechselstelle hinweg
      expect(r.kurve.verbrauch(D('2026-05-25'), D('2026-06-08')).milli, 14000);
      final monate = verbrauchJeMonat(r.kurve, D('2026-05-01'), D('2026-08-01'));
      expect(monate.map((m) => m.milli), [31000, 30000, 31000]);
    });

    test('Kosten über die Kette mit den Preisen des neuen Zählers', () {
      final r = Verbrauchskurve.verkettet([alt, neu]);
      final t = kostenFuerZeitraum([const Preis(ab: '2026-01-01', arbeitspreis: 3000)], r.kurve, Z('2026-01-01', '2026-12-01'), bezugsTage: 365);
      expect(t.verbrauchCent, 10020); // 334 * 0,30
    });

    test('mit Lücke zwischen den Zählern: dort 0 Verbrauch, die Lücke wird gezählt', () {
      final spaet = Verbrauchskurve.aus([S('2026-06-11', 0), S('2026-12-01', 173000)]);
      final r = Verbrauchskurve.verkettet([alt, spaet]);
      expect(r.luecken, 1);
      expect(r.kurve.verbrauch(D('2026-06-01'), D('2026-06-11')).milli, 0);
      expect(r.kurve.verbrauch(D('2026-01-01'), D('2026-12-01')).milli, 324000);
    });

    test('leere Kurven in der Kette werden übersprungen', () {
      final r = Verbrauchskurve.verkettet([Verbrauchskurve.leer, alt, Verbrauchskurve.leer]);
      expect(r.kurve.verbrauch(D('2026-01-01'), D('2026-06-01')).milli, 151000);
      expect(Verbrauchskurve.verkettet(const []).kurve.istLeer, isTrue);
    });

    test('Kette und jüngster Zähler (Zyklen und fehlende Glieder enden still)', () {
      final alle = {'a': _z(), 'b': _z(vorgaenger: 'a'), 'c': _z(vorgaenger: 'b'), 'x': _z(vorgaenger: 'fehlt')};
      expect(kette('c', alle), ['a', 'b', 'c']);
      expect(kette('a', alle), ['a']);
      expect(kette('x', alle), ['x']);
      expect(juengsterDerKette('a', alle), 'c');
      expect(juengsterDerKette('c', alle), 'c');
      final zyklus = {'a': _z(vorgaenger: 'b'), 'b': _z(vorgaenger: 'a')};
      expect(kette('a', zyklus).length, 2);
      expect(juengsterDerKette('a', zyklus), isNotEmpty);
    });

    test('Wasser-Gruppe: gleiche Art und gleicher Name, ohne Rücksicht auf Groß- und Kleinschreibung', () {
      final alle = {
        'k1': _z(art: ZaehlerArt.kaltwasser, gruppe: 'Haus'),
        'k2': _z(art: ZaehlerArt.kaltwasser, gruppe: ' haus '),
        'w1': _z(art: ZaehlerArt.warmwasser, gruppe: 'Haus'),
        'k3': _z(art: ZaehlerArt.kaltwasser, gruppe: 'Garten'),
        'k4': _z(art: ZaehlerArt.kaltwasser),
      };
      expect(gruppenMitglieder('k1', alle), ['k1', 'k2']);
      expect(gruppenMitglieder('w1', alle), ['w1']);
      expect(gruppenMitglieder('k4', alle), isEmpty);
      expect(gruppenMitglieder('unbekannt', alle), isEmpty);
    });

    test('Summe der Gruppe: drei Wasserzähler gleichzeitig', () {
      final a = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-02-01', 3100)]).verbrauch(D('2026-01-01'), D('2026-02-01'));
      final b = Verbrauchskurve.aus([S('2026-01-01', 0), S('2026-02-01', 6200)]).verbrauch(D('2026-01-01'), D('2026-02-01'));
      final c = Verbrauchskurve.aus([S('2026-01-15', 0), S('2026-02-01', 1700)]).verbrauch(D('2026-01-01'), D('2026-02-01'));
      final s = gruppenSumme([a, b, c]);
      expect(s.milli, 3100 + 6200 + 1700);
      expect(s.vollstaendig, isFalse); // c deckt nur 17 Tage ab
      expect(gruppenSumme([a, b]).vollstaendig, isTrue);
      expect(gruppenSumme(const []), same(Verbrauch.leer));
    });
  });
}
