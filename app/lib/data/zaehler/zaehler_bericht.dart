// Zähler (Abschnitt 6l): Inhalt des PDF-Berichts als reine Daten, getrennt vom PDF-Aufbau (zaehler_pdf.dart), damit er sich prüfen lässt. Alle Werte sind schon als deutscher Text
// formatiert. Der Bericht entsteht nur lokal auf dem Gerät, nur auf ausdrücklichen Wunsch, nur im Arbeitsspeicher und wird nie geloggt oder gesendet.
//
// Zeitraum: Kalenderjahr, Abrechnungsperiode (JE ZÄHLER die eigene: Strom z. B. März bis Februar, Wasser Kalenderjahr; die laufende oder die letzte abgeschlossene) oder ein eigener Zeitraum.
// Inhalt je Zähler oder Gruppe: Stände (mit Verbrauch seit dem vorigen Stand und Vorjahr), Verbrauch je Monat (Tabelle und Balken), Gesamtverbrauch mit Vorjahresvergleich, optional Kosten.
import 'zaehler_format.dart';
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';
import 'zaehler_uebersicht.dart';

enum BerichtZeitraum { kalenderjahr, laufendePeriode, letztePeriode, eigen }

/// Was in den Bericht kommt.
class BerichtWahl {
  final BerichtZeitraum zeitraum;

  /// Kalenderjahr (nur bei [BerichtZeitraum.kalenderjahr]).
  final int jahr;

  /// Eigener Zeitraum, beide Tage einschließlich (nur bei [BerichtZeitraum.eigen]).
  final DateTime? von;
  final DateTime? bis;
  final bool staende;
  final bool monate;
  final bool vorjahr;
  final bool kosten;
  const BerichtWahl({required this.zeitraum, required this.jahr, this.von, this.bis, this.staende = true, this.monate = true, this.vorjahr = true, this.kosten = false});

  /// Ein eigener Zeitraum braucht beide Tage und Beginn <= Ende.
  bool get gueltig => zeitraum != BerichtZeitraum.eigen || (von != null && bis != null && !bis!.isBefore(von!));
}

/// Der Zeitraum eines Zählers (eigene Abrechnungsperiode, wenn gewählt).
Zeitraum berichtZeitraumFuer(BerichtWahl w, ZaehlerInhalt z, DateTime heute) {
  switch (w.zeitraum) {
    case BerichtZeitraum.kalenderjahr:
      return Zeitraum(DateTime.utc(w.jahr, 1, 1), DateTime.utc(w.jahr + 1, 1, 1));
    case BerichtZeitraum.laufendePeriode:
      return abrechnungsperiode(heute, periodeMonat: z.periodeMonat, periodeTag: z.periodeTag);
    case BerichtZeitraum.letztePeriode:
      return periodeDavor(abrechnungsperiode(heute, periodeMonat: z.periodeMonat, periodeTag: z.periodeTag), periodeMonat: z.periodeMonat, periodeTag: z.periodeTag);
    case BerichtZeitraum.eigen:
      return Zeitraum(w.von!, w.bis!.add(const Duration(days: 1)));
  }
}

class BerichtStandZeile {
  final String datum;
  final String stand;
  final String verbrauch;
  final String vorjahr;
  final String vermerk;
  const BerichtStandZeile(this.datum, this.stand, this.verbrauch, this.vorjahr, this.vermerk);
}

class BerichtMonatZeile {
  final String monat;
  final String verbrauch;
  final String vorjahr;
  final String veraenderung;
  final int? milli;
  final int? vorjahrMilli;
  final bool teilweise;
  const BerichtMonatZeile(this.monat, this.verbrauch, this.vorjahr, this.veraenderung, this.milli, this.vorjahrMilli, this.teilweise);
}

/// Die Stände eines einzelnen Zählers (bei einer Gruppe je Mitglied eine Tabelle).
class BerichtTabelle {
  final String titel;
  final String? nummer;
  final List<BerichtStandZeile> zeilen;
  const BerichtTabelle(this.titel, this.nummer, this.zeilen);
}

/// Ein Abschnitt je Zähler oder Gruppe.
class BerichtAbschnitt {
  final String titel;
  final String art;
  final String zeitraum;
  final String? nummer;
  final String einheit;
  final List<BerichtTabelle> tabellen;
  final List<BerichtMonatZeile> monate;
  final String gesamt;
  final String? vorjahrGesamt;
  final String? vorjahrVeraenderung;
  final bool unvollstaendig;

  /// Alle Zähler des Abschnitts haben die Eingabeart Monatswerte: statt der Stände steht die Tabelle der Monatswerte (mit Summe und Vorjahr).
  final bool monatswerte;

  /// "Erzeugung" bei einer Anlage, sonst "Verbrauch".
  final String wort;

  /// Kosten oder Ersparnis als Zeilen (Bezeichnung, Wert); leer, wenn nicht gewählt oder kein Tarif.
  final List<(String, String)> kosten;
  final String kostenTitel;
  const BerichtAbschnitt({
    required this.titel,
    required this.art,
    required this.zeitraum,
    required this.nummer,
    required this.einheit,
    required this.tabellen,
    required this.monate,
    required this.gesamt,
    this.vorjahrGesamt,
    this.vorjahrVeraenderung,
    this.unvollstaendig = false,
    this.monatswerte = false,
    this.wort = 'Verbrauch',
    this.kosten = const [],
    this.kostenTitel = 'Kosten',
  });
}

class BerichtDaten {
  final String erstellt;
  final BerichtWahl wahl;
  final List<BerichtAbschnitt> abschnitte;
  const BerichtDaten(this.erstellt, this.wahl, this.abschnitte);
}

String _veraenderung(int milli, int? vorjahr) {
  if (vorjahr == null || vorjahr <= 0) return '';
  final p = (milli - vorjahr) * 100 / vorjahr;
  final r = p.abs().round();
  return r == 0 ? '0 %' : '${p > 0 ? '+' : '-'}$r %';
}

BerichtAbschnitt _abschnitt(ZaehlerKachel k, BerichtWahl w, DateTime heute) {
  final erste = k.erste;
  final z = berichtZeitraumFuer(w, erste.inhalt, heute);
  final vj = vorjahrVon(z);
  final einheit = k.einheit;
  final tabellen = <BerichtTabelle>[];
  final nurMonatswerte = k.reihen.every((r) => r.monatlich);
  if (w.staende) {
    for (final r in k.reihen) {
      if (r.monatlich) continue; // Monatswerte haben keine Stände: sie stehen in der Monatstabelle
      final zeilen = <BerichtStandZeile>[];
      Stand? davor;
      for (final s in r.staende) {
        if (s.tag.isBefore(z.start)) {
          davor = s;
          continue;
        }
        if (!s.tag.isBefore(z.ende)) break;
        String verbrauch = '–';
        String vorjahr = '–';
        if (davor != null) {
          final v = r.kurve.verbrauch(davor.tag, s.tag);
          if (v.abgedeckteTage > 0) verbrauch = verbrauchAnzeige(v.milli, '', mitEinheit: false);
          if (w.vorjahr) {
            final zz = vorjahrVon(Zeitraum(davor.tag, s.tag));
            final vv = r.kurve.verbrauch(zz.start, zz.ende);
            if (vv.vollstaendig && vv.gesamtTage > 0) vorjahr = verbrauchAnzeige(vv.milli, '', mitEinheit: false);
          }
        }
        zeilen.add(BerichtStandZeile(tagDeutsch(s.tag), standAnzeige(s.milli), verbrauch, w.vorjahr ? vorjahr : '', s.marke == StandMarke.ende ? 'Endstand (Zählerwechsel)' : (s.marke == StandMarke.start ? 'Startstand (Zählerwechsel)' : '')));
        davor = s;
      }
      tabellen.add(BerichtTabelle(r.name, r.inhalt.nummer.isEmpty ? null : r.inhalt.nummer, zeilen));
    }
  }
  final monate = <BerichtMonatZeile>[];
  if (w.monate || (nurMonatswerte && w.staende)) {
    final aktuell = kachelMonate(k, z.start, z.ende);
    final vorher = kachelMonate(k, vj.start, vj.ende);
    for (var i = 0; i < aktuell.length; i++) {
      final m = aktuell[i];
      final hat = m.tage > 0 && (m.vollstaendig || m.milli > 0);
      final v = i < vorher.length && vorher[i].tage > 0 && (vorher[i].vollstaendig || vorher[i].milli > 0) ? vorher[i].milli : null;
      monate.add(BerichtMonatZeile(
        '${monatName(m.monat)} ${m.jahr}',
        hat ? verbrauchAnzeige(m.milli, '', mitEinheit: false) : '–',
        w.vorjahr && v != null ? verbrauchAnzeige(v, '', mitEinheit: false) : '',
        w.vorjahr && hat && v != null ? _veraenderung(m.milli, v) : '',
        hat ? m.milli : null,
        w.vorjahr ? v : null,
        !m.vollstaendig,
      ));
    }
  }
  final gesamt = kachelVerbrauch(k, z.start, z.ende);
  final vorGesamt = kachelVerbrauch(k, vj.start, vj.ende);
  final kosten = <(String, String)>[];
  var kostenTitel = 'Kosten';
  final einzel = k.istGruppe ? null : erste;
  if (w.kosten && einzel != null && einzel.inhalt.kosten && einzel.inhalt.preise.isNotEmpty) {
    if (einzel.art == ZaehlerArt.erzeugung) {
      kostenTitel = 'Ersparnis';
      final s = solarVorteil(einzel.inhalt, einzel.kurve, z, einzel.inhalt.preise);
      kosten.add(('Erzeugung', verbrauchAnzeige(s.erzeugtMilli, einheit)));
      kosten.add(('Eigenverbrauch', verbrauchAnzeige(s.eigenMilli, einheit)));
      kosten.add(('Eingespeist', verbrauchAnzeige(s.einspeiseMilli, einheit)));
      kosten.add(('Ersparnis durch Eigenverbrauch', euroAnzeige(s.ersparnisCent)));
      if (s.verguetungCent > 0) kosten.add(('Einspeisevergütung', euroAnzeige(s.verguetungCent)));
      kosten.add(('Vorteil gesamt', euroAnzeige(s.vorteilCent)));
    } else {
      final p = periodenKosten(einzel.inhalt, einzel.kurve, z, heute);
      final b = p.bisher;
      kosten.add(('Arbeit (Verbrauch)', euroAnzeige(b.verbrauchCent)));
      kosten.add(('Grundgebühr', euroAnzeige(b.grundCent)));
      if (b.zaehlerCent > 0) kosten.add(('Zählergebühr', euroAnzeige(b.zaehlerCent)));
      kosten.add((p.laufend ? 'Kosten bisher' : 'Kosten gesamt', '${euroAnzeige(b.gesamtCent)}${b.preisLuecke ? ' (für einen Teil fehlt der Preis)' : ''}'));
      if (p.laufend && p.prognose != null) kosten.add(('Hochrechnung auf die Periode', euroAnzeige(p.prognose!.gesamtCent)));
      final ab = p.laufend ? p.abschlaegeBisherCent : p.abschlaegeGesamtCent;
      if (ab != null) kosten.add(('Abschläge', euroAnzeige(ab)));
      if (p.saldoCent != null) kosten.add((p.laufend ? 'Voraussichtlich' : 'Saldo', p.saldoCent! >= 0 ? 'Nachzahlung ${euroAnzeige(p.saldoCent!)}' : 'Rückzahlung ${euroAnzeige(-p.saldoCent!)}'));
    }
  }
  return BerichtAbschnitt(
    titel: k.titel,
    art: k.art.anzeige,
    zeitraum: zeitraumText(z),
    nummer: k.istGruppe ? null : (erste.inhalt.nummer.isEmpty ? null : erste.inhalt.nummer),
    einheit: einheit,
    tabellen: tabellen,
    monate: monate,
    gesamt: verbrauchAnzeige(gesamt.milli, einheit),
    vorjahrGesamt: w.vorjahr && vorGesamt.abgedeckteTage > 0 ? verbrauchAnzeige(vorGesamt.milli, einheit) : null,
    vorjahrVeraenderung: w.vorjahr && gesamt.abgedeckteTage > 0 && vorGesamt.vollstaendig ? _veraenderung(gesamt.milli, vorGesamt.milli) : null,
    unvollstaendig: !gesamt.vollstaendig,
    monatswerte: nurMonatswerte,
    wort: k.art == ZaehlerArt.erzeugung ? 'Erzeugung' : 'Verbrauch',
    kosten: kosten,
    kostenTitel: kostenTitel,
  );
}

/// Der Bericht für [kacheln] (die gewählten Zähler und Gruppen). Ohne gültige Wahl wirft die Funktion [ArgumentError].
BerichtDaten baueBericht({required List<ZaehlerKachel> kacheln, required BerichtWahl wahl, required DateTime heute}) {
  if (!wahl.gueltig) throw ArgumentError('Ungültiger Zeitraum');
  if (kacheln.isEmpty) throw ArgumentError('Kein Zähler gewählt');
  return BerichtDaten(tagDeutsch(heute), wahl, [for (final k in kacheln) _abschnitt(k, wahl, heute)]);
}

/// Dateiname des Berichts (ohne Namen oder Kennungen).
const String kZaehlerBerichtDateiname = 'zaehlerbericht.pdf';
