// Zähler (Abschnitt 6l): Rechenlogik der Eingabeart "Monatswerte" (reine Logik, ganze Zahlen). Die Summen, der Vorjahresvergleich, Kosten und Solar-Ersparnis laufen über die
// Verbrauchskurve aus Monatswerten (`Verbrauchskurve.ausMonatswerten`: jeder Monat verteilt seinen Wert auf seine Tage, Monats- und Jahressummen sind darum exakt die Eingaben); hier
// stehen nur die Teile, die es bei Zählerständen nicht gibt: Hochrechnung mit fehlenden Monaten, Plausibilität eines Monatswerts, Fälligkeit und Erinnerungstage.
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';

/// Der Wert für einen Monat (null: keiner eingetragen).
MonatsWert? monatswertFuer(Iterable<MonatsWert> werte, int jahr, int monat) {
  for (final w in werte) {
    if (w.jahr == jahr && w.monat == monat) return w;
  }
  return null;
}

/// Summe der Werte der Monate in [von, bis) (Kalendermonate, die ganz oder teilweise im Zeitraum liegen zählen ganz: Monatswerte kennen keine Tage).
int summeMonate(Iterable<MonatsWert> werte, int vonJahr, int vonMonat, int bisJahr, int bisMonat) {
  final a = vonJahr * 12 + vonMonat - 1;
  final b = bisJahr * 12 + bisMonat - 1; // ausschließlich
  var s = 0;
  for (final w in werte) {
    if (w.monatsIndex >= a && w.monatsIndex < b) s += w.milli;
  }
  return s;
}

/// Hochrechnung einer laufenden Periode aus Monatswerten: bekannte Monate zählen mit ihrem Wert; der laufende Monat (nur Zwischenstand) wird ab dem 14. Tag auf den ganzen Monat
/// hochgerechnet; fehlende, laufende (vor dem 14.) und kommende Monate werden aus dem Vorjahresmonat geschätzt, sonst aus dem Durchschnitt der bekannten vollen Monate der Periode.
class MonatsHochrechnung {
  final int prognoseMilli;

  /// Summe der eingetragenen Werte der Periode (inkl. Zwischenstand).
  final int bekanntMilli;

  /// Monate der Periode mit eingetragenem vollem Wert.
  final int bekannteMonate;

  /// Monate, die geschätzt sind (aus Vorjahresmonat oder Durchschnitt) bzw. hochgerechnet (laufender Monat).
  final int geschaetzteMonate;
  const MonatsHochrechnung(this.prognoseMilli, this.bekanntMilli, this.bekannteMonate, this.geschaetzteMonate);
}

/// null, wenn die Periode zu Ende ist oder es keine Grundlage gibt (kein einziger voller Monat und kein Zwischenstand ab dem 14. Tag).
MonatsHochrechnung? monatsHochrechnung(Iterable<MonatsWert> werte, Zeitraum periode, DateTime heute) {
  final h = DateTime.utc(heute.year, heute.month, heute.day);
  if (!h.isBefore(periode.ende)) return null;
  final liste = werte.toList();
  final aktuellerMonat = h.year * 12 + h.month - 1;
  final monate = <({int jahr, int monat})>[];
  var cur = DateTime.utc(periode.start.year, periode.start.month, 1);
  while (cur.isBefore(periode.ende)) {
    monate.add((jahr: cur.year, monat: cur.month));
    cur = DateTime.utc(cur.year, cur.month + 1, 1);
  }
  // Durchschnitt der bekannten vollen (vergangenen) Monate der Periode
  var summeVoll = 0;
  var anzahlVoll = 0;
  for (final m in monate) {
    final w = monatswertFuer(liste, m.jahr, m.monat);
    if (w != null && m.jahr * 12 + m.monat - 1 < aktuellerMonat) {
      summeVoll += w.milli;
      anzahlVoll++;
    }
  }
  var prognose = 0;
  var bekannt = 0;
  var geschaetzt = 0;
  var grundlage = anzahlVoll > 0;
  for (final m in monate) {
    final idx = m.jahr * 12 + m.monat - 1;
    final w = monatswertFuer(liste, m.jahr, m.monat);
    if (w != null) bekannt += w.milli;
    if (w != null && idx < aktuellerMonat) {
      prognose += w.milli;
      continue;
    }
    int? schaetzung;
    if (w != null && idx == aktuellerMonat && h.day >= 14) {
      schaetzung = rundenDiv(w.milli * tageImMonat(m.jahr, m.monat), h.day);
      grundlage = true;
    } else {
      final vj = monatswertFuer(liste, m.jahr - 1, m.monat);
      if (vj != null) {
        schaetzung = vj.milli;
      } else if (anzahlVoll > 0) {
        schaetzung = rundenDiv(summeVoll, anzahlVoll);
      }
    }
    if (schaetzung == null) continue; // keine Grundlage für diesen Monat: zählt nichts
    if (w != null && idx == aktuellerMonat && schaetzung < w.milli) schaetzung = w.milli; // nie weniger als schon erreicht
    prognose += schaetzung;
    geschaetzt++;
  }
  if (!grundlage) return null;
  final voll = monate.where((m) => monatswertFuer(liste, m.jahr, m.monat) != null && m.jahr * 12 + m.monat - 1 < aktuellerMonat).length;
  return MonatsHochrechnung(prognose, bekannt, voll, geschaetzt);
}

// ---------------------------------------------------------------- Plausibilität

enum MonatswertHinweis {
  /// Der Monat liegt in der Zukunft (blockiert).
  zukunft,

  /// Für den Monat gibt es schon einen Wert (er wird ersetzt).
  ersetzt,

  /// Der Wert ist mehr als doppelt so hoch wie im Vorjahresmonat (und über [kMonatswertSprungAb]): Zahlendreher?
  hoeherAlsVorjahr,

  /// Der laufende Monat ist nur ein Zwischenstand.
  zwischenstand,
}

/// Ab diesem Wert (Tausendstel, 50 Einheiten) wird der Vergleich mit dem Vorjahresmonat überhaupt geprüft (kleine Werte schwanken stark).
const int kMonatswertSprungAb = 50000;

class MonatswertPlausibilitaet {
  final List<MonatswertHinweis> hinweise;
  const MonatswertPlausibilitaet(this.hinweise);
  bool get ok => hinweise.isEmpty;
  bool get blockiert => hinweise.contains(MonatswertHinweis.zukunft);

  /// Hinweise, die die Person bestätigen muss (ohne den bloßen Zwischenstand-Hinweis).
  bool get bestaetigung => hinweise.contains(MonatswertHinweis.ersetzt) || hinweise.contains(MonatswertHinweis.hoeherAlsVorjahr);
}

/// Prüft einen Monatswert gegen die vorhandenen [werte] und den Kalendertag [heute]. [ausser]: der Eintrag, der gerade geändert wird, zählt nicht als "schon vorhanden".
MonatswertPlausibilitaet pruefeMonatswert({required int jahr, required int monat, required int milli, required Iterable<MonatsWert> werte, required DateTime heute, String? ausser}) {
  final h = <MonatswertHinweis>[];
  final idx = jahr * 12 + monat - 1;
  final jetzt = heute.year * 12 + heute.month - 1;
  if (idx > jetzt) h.add(MonatswertHinweis.zukunft);
  final vorhanden = werte.where((w) => w.id != ausser || ausser == null).where((w) => w.jahr == jahr && w.monat == monat);
  if (vorhanden.isNotEmpty) h.add(MonatswertHinweis.ersetzt);
  if (idx == jetzt) h.add(MonatswertHinweis.zwischenstand);
  final vj = monatswertFuer(werte, jahr - 1, monat);
  if (idx < jetzt && vj != null && vj.milli > 0 && milli > kMonatswertSprungAb && milli > 2 * vj.milli) h.add(MonatswertHinweis.hoeherAlsVorjahr);
  return MonatswertPlausibilitaet(h);
}

// ---------------------------------------------------------------- Fälligkeit und Erinnerung

/// Fälligkeit im Modus Monatswerte: Am Monatsersten ist der Wert des Vormonats fällig, bis er eingetragen ist. Ein Zähler ohne jeden Wert ist (wie ein Zähler ohne Stand) fällig.
Faelligkeit monatswertFaellig(Iterable<MonatsWert> werte, DateTime heute) {
  final h = DateTime.utc(heute.year, heute.month, heute.day);
  final dieser = DateTime.utc(h.year, h.month, 1);
  final vor = DateTime.utc(h.year, h.month - 1, 1);
  final faellig = monatswertFuer(werte, vor.year, vor.month) == null;
  return Faelligkeit(dieser, faellig ? dieser : DateTime.utc(h.year, h.month + 1, 1), faellig);
}

/// Die Monatsersten in [von, bis] (Tage, einschließlich), an denen "Monatswert eintragen" ansteht und der Wert des Vormonats noch fehlt.
List<DateTime> monatswertErinnerungstage(Iterable<MonatsWert> werte, DateTime von, DateTime bis) {
  final out = <DateTime>[];
  for (var m = 0; m < 30; m++) {
    final t = DateTime.utc(von.year, von.month + m, 1);
    if (t.isAfter(bis)) break;
    if (t.isBefore(von)) continue;
    final vor = DateTime.utc(t.year, t.month - 1, 1);
    if (monatswertFuer(werte, vor.year, vor.month) != null) continue;
    out.add(t);
  }
  return out;
}

/// Die wählbaren Monate beim Eintragen: der laufende Monat und die 24 davor, neuester zuerst (nie ein Monat in der Zukunft).
List<({int jahr, int monat})> auswahlMonate(DateTime heute, {int anzahl = 24}) => [
  for (var i = 0; i <= anzahl; i++) (jahr: DateTime.utc(heute.year, heute.month - i, 1).year, monat: DateTime.utc(heute.year, heute.month - i, 1).month),
];

/// Der Vormonat von [heute] (Vorbelegung beim Eintragen).
({int jahr, int monat}) vormonat(DateTime heute) {
  final t = DateTime.utc(heute.year, heute.month - 1, 1);
  return (jahr: t.year, monat: t.month);
}
