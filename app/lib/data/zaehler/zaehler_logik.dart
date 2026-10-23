// Zähler (Abschnitt 6l): reine Rechenlogik ohne Datenbank und ohne Oberfläche, mit ganzen Zahlen (Festkomma, siehe zaehler_modelle.dart: Stände in Tausendstel, Preise in
// Zehntausendstel Euro, Beträge in Cent). Es gibt keinen Gleitkomma-Fehler: jede Summe ist exakt, gerundet wird nur am Ende je Bestandteil (halbe Cent nach oben).
//
// Zeitmodell: Alles läuft auf Kalendertagen (UTC-Mitternacht, wie `tagLesen`). Ein Stand gilt für den BEGINN seines Tages. Zwischen zwei Ständen wird der Verbrauch gleichmäßig
// (linear) auf die Tage [Tag des ersten Standes, Tag des zweiten Standes) verteilt; der Verbrauch eines Zeitraums [von, bis) ist der Unterschied der so entstehenden
// Verbrauchskurve an den beiden Grenzen. Das gilt auch bei unregelmäßigem Ablesen und macht Monats- und Jahressummen widerspruchsfrei (die Monate einer Periode ergeben
// genau die Summe der Periode). Ein Stand, der kleiner ist als der vorige, zählt als 0 Verbrauch (Zählerwechsel oder Tippfehler; [Verbrauchskurve.ruecksprunege] zählt sie).
import '../medikamente/medikament_modelle.dart' show tagLesen, tagText;
import 'zaehler_modelle.dart';

const int _tagMs = 86400000;

/// Tagnummer (Tage seit 1970-01-01) eines Kalendertags.
int tagNummer(DateTime tag) => DateTime.utc(tag.year, tag.month, tag.day).millisecondsSinceEpoch ~/ _tagMs;

DateTime tagVonNummer(int n) => DateTime.fromMillisecondsSinceEpoch(n * _tagMs, isUtc: true);

DateTime _tag(DateTime t) => DateTime.utc(t.year, t.month, t.day);

int tageImMonat(int jahr, int monat) => DateTime.utc(jahr, monat + 1, 0).day;

/// Der Tag [tag] im Monat, in kurzen Monaten der letzte Tag (31. -> 30./28./29.).
DateTime tagImMonat(int jahr, int monat, int tag) => DateTime.utc(jahr, monat, tag > tageImMonat(jahr, monat) ? tageImMonat(jahr, monat) : tag);

// ---------------------------------------------------------------- Zeitraum und Abrechnungsperiode

/// Ein Zeitraum von Kalendertagen: [start] einschließlich, [ende] ausschließlich.
class Zeitraum {
  final DateTime start;
  final DateTime ende;
  Zeitraum(DateTime start, DateTime ende) : start = _tag(start), ende = _tag(ende);

  int get tage => tagNummer(ende) - tagNummer(start);
  bool enthaelt(DateTime tag) {
    final n = tagNummer(tag);
    return n >= tagNummer(start) && n < tagNummer(ende);
  }

  @override
  bool operator ==(Object other) => other is Zeitraum && other.start == start && other.ende == ende;

  @override
  int get hashCode => Object.hash(start, ende);

  @override
  String toString() => '${tagText(start)} bis ${tagText(ende)}';
}

/// Die Abrechnungsperiode, die [tag] enthält: ein Jahr ab dem [periodeTag]. [periodeMonat] (Standard 1.1. = Kalenderjahr). Beginnt eine Periode an einem Tag, den es im Monat
/// nicht gibt (31. oder 29. Februar), ist es der letzte Tag des Monats. Über den Jahreswechsel (z. B. ab 1. März) liegt der Beginn im Vorjahr.
Zeitraum abrechnungsperiode(DateTime tag, {int periodeMonat = 1, int periodeTag = 1}) {
  final t = _tag(tag);
  var start = tagImMonat(t.year, periodeMonat, periodeTag);
  if (start.isAfter(t)) start = tagImMonat(t.year - 1, periodeMonat, periodeTag);
  return Zeitraum(start, tagImMonat(start.year + 1, periodeMonat, periodeTag));
}

/// Die Periode davor bzw. danach.
Zeitraum periodeDavor(Zeitraum p, {int periodeMonat = 1, int periodeTag = 1}) => abrechnungsperiode(p.start.subtract(const Duration(days: 1)), periodeMonat: periodeMonat, periodeTag: periodeTag);
Zeitraum periodeDanach(Zeitraum p, {int periodeMonat = 1, int periodeTag = 1}) => abrechnungsperiode(p.ende, periodeMonat: periodeMonat, periodeTag: periodeTag);

/// Bezeichnung einer Periode: "2025" (Kalenderjahr) oder "2025/26" (beginnt im Laufe eines Jahres).
String periodenBezeichnung(Zeitraum p, {int periodeMonat = 1, int periodeTag = 1}) =>
    periodeMonat == 1 && periodeTag == 1 ? '${p.start.year}' : '${p.start.year}/${((p.start.year + 1) % 100).toString().padLeft(2, '0')}';

/// Derselbe Zeitraum ein Jahr früher (29. Februar -> 28. Februar).
Zeitraum vorjahrVon(Zeitraum z) => Zeitraum(_einJahrZurueck(z.start), _einJahrZurueck(z.ende));

DateTime _einJahrZurueck(DateTime t) => tagImMonat(t.year - 1, t.month, t.day);

// ---------------------------------------------------------------- Stände und Verbrauchskurve

/// Ein Stand an einem Tag (Tausendstel der Einheit).
class Stand {
  final DateTime tag;
  final int milli;
  final StandMarke? marke;
  Stand(DateTime tag, this.milli, {this.marke}) : tag = _tag(tag);

  @override
  String toString() => '${tagText(tag)}: $milli';
}

/// Stände nach Tag sortiert; mehrere am selben Tag: der LETZTE der übergebenen Liste gilt (Aufrufer reichen sie in der Reihenfolge der Anlage ein).
List<Stand> normalisiere(Iterable<Stand> staende) {
  final liste = staende.toList();
  final nachTag = <int, Stand>{};
  for (final s in liste) {
    nachTag[tagNummer(s.tag)] = s;
  }
  return [for (final k in (nachTag.keys.toList()..sort())) nachTag[k]!];
}

/// Der Verbrauch eines Zeitraums. [abgedeckteTage] sind die Tage, für die es Stände gibt; [vollstaendig], wenn der ganze Zeitraum abgedeckt ist.
class Verbrauch {
  final int milli;
  final int abgedeckteTage;
  final int gesamtTage;
  const Verbrauch(this.milli, this.abgedeckteTage, this.gesamtTage);
  bool get vollstaendig => gesamtTage > 0 && abgedeckteTage == gesamtTage;
  static const leer = Verbrauch(0, 0, 0);

  @override
  String toString() => 'Verbrauch($milli, $abgedeckteTage/$gesamtTage)';
}

/// Die kumulierte Verbrauchskurve eines Zählers: je Stand (Tag, bisheriger Verbrauch), dazwischen linear.
class Verbrauchskurve {
  final List<({int tag, int c})> punkte;

  /// Wie oft ein Stand kleiner war als der vorige (0 Verbrauch angenommen).
  final int ruecksprunege;
  const Verbrauchskurve._(this.punkte, this.ruecksprunege);

  static const leer = Verbrauchskurve._([], 0);

  factory Verbrauchskurve.aus(Iterable<Stand> staende) {
    final n = normalisiere(staende);
    if (n.isEmpty) return leer;
    final p = <({int tag, int c})>[(tag: tagNummer(n.first.tag), c: 0)];
    var rueck = 0;
    for (var i = 1; i < n.length; i++) {
      final delta = n[i].milli - n[i - 1].milli;
      if (delta < 0) rueck++;
      p.add((tag: tagNummer(n[i].tag), c: p.last.c + (delta < 0 ? 0 : delta)));
    }
    return Verbrauchskurve._(p, rueck);
  }

  bool get istLeer => punkte.isEmpty;
  int? get ersterTag => punkte.isEmpty ? null : punkte.first.tag;
  int? get letzterTag => punkte.isEmpty ? null : punkte.last.tag;

  /// Kumulierter Verbrauch am Beginn des Tages [tag] (null außerhalb der Stände). Linear zwischen zwei Ständen, auf ganze Tausendstel gerundet.
  int? bei(int tag) {
    if (punkte.isEmpty || tag < punkte.first.tag || tag > punkte.last.tag) return null;
    var lo = 0;
    var hi = punkte.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (punkte[mid].tag <= tag) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final a = punkte[lo];
    if (a.tag == tag || lo == punkte.length - 1) return a.c;
    final b = punkte[lo + 1];
    return a.c + rundenDiv((b.c - a.c) * (tag - a.tag), b.tag - a.tag);
  }

  /// Verbrauch im Zeitraum [von, bis): nur der Teil, den die Stände abdecken (siehe [Verbrauch.vollstaendig]).
  Verbrauch verbrauch(DateTime von, DateTime bis) {
    final v = tagNummer(von);
    final b = tagNummer(bis);
    if (b <= v) return Verbrauch.leer;
    if (punkte.isEmpty) return Verbrauch(0, 0, b - v);
    final a = v < punkte.first.tag ? punkte.first.tag : v;
    final e = b > punkte.last.tag ? punkte.last.tag : b;
    if (e <= a) return Verbrauch(0, 0, b - v);
    return Verbrauch(bei(e)! - bei(a)!, e - a, b - v);
  }

  /// Eine Kurve, die nach beiden Seiten mit gleichbleibender Tagesrate bis [von] bzw. [bis] fortgesetzt ist (Prognose): [beobachtetMilli] über [beobachteteTage] ergibt die Rate.
  Verbrauchskurve erweitert(DateTime von, DateTime bis, {required int beobachtetMilli, required int beobachteteTage}) {
    if (punkte.isEmpty || beobachteteTage <= 0) return this;
    final p = [...punkte];
    final v = tagNummer(von);
    final b = tagNummer(bis);
    if (b > p.last.tag) p.add((tag: b, c: p.last.c + rundenDiv(beobachtetMilli * (b - p.last.tag), beobachteteTage)));
    if (v < p.first.tag) p.insert(0, (tag: v, c: p.first.c - rundenDiv(beobachtetMilli * (p.first.tag - v), beobachteteTage)));
    return Verbrauchskurve._(p, ruecksprunege);
  }

  /// Mehrere Kurven hintereinander (Zählerwechsel-Kette, ältester Zähler zuerst): der Verbrauch läuft nahtlos weiter. Beginnt der nächste Zähler am Tag des Endes des vorigen,
  /// schließen sie lückenlos aneinander; liegt dazwischen eine Lücke, gilt dort 0 Verbrauch ([luecken] zählt sie).
  static ({Verbrauchskurve kurve, int luecken}) verkettet(Iterable<Verbrauchskurve> kurven) {
    final p = <({int tag, int c})>[];
    var rueck = 0;
    var luecken = 0;
    for (final k in kurven) {
      if (k.punkte.isEmpty) continue;
      rueck += k.ruecksprunege;
      final offset = p.isEmpty ? 0 : p.last.c;
      if (p.isNotEmpty && k.punkte.first.tag > p.last.tag) luecken++;
      for (final pt in k.punkte) {
        final neu = (tag: pt.tag, c: offset + pt.c);
        if (p.isNotEmpty && p.last.tag == neu.tag) {
          // gleicher Tag (Endstand des alten und Startstand des neuen Zählers): ein Punkt
          p[p.length - 1] = (tag: neu.tag, c: neu.c > p.last.c ? neu.c : p.last.c);
        } else if (p.isNotEmpty && pt.tag < p.last.tag) {
          luecken++; // Überlappung: wird nicht verrechnet
        } else {
          p.add(neu);
        }
      }
    }
    return (kurve: Verbrauchskurve._(p, rueck), luecken: luecken);
  }
}

// ---------------------------------------------------------------- Auswertungen

/// Verbrauch je Kalendermonat in [von, bis); der erste und der letzte Monat können angeschnitten sein ([tage] sind die Tage im Zeitraum, [vollstaendig] nur bei vollständiger Abdeckung).
class MonatsVerbrauch {
  final int jahr;
  final int monat;
  final int milli;
  final int tage;
  final bool vollstaendig;
  const MonatsVerbrauch(this.jahr, this.monat, this.milli, this.tage, this.vollstaendig);

  @override
  String toString() => '$jahr-$monat: $milli ($tage Tage${vollstaendig ? '' : ', unvollständig'})';
}

List<MonatsVerbrauch> verbrauchJeMonat(Verbrauchskurve k, DateTime von, DateTime bis) {
  final out = <MonatsVerbrauch>[];
  var cur = _tag(von);
  final ende = _tag(bis);
  while (cur.isBefore(ende)) {
    final naechster = DateTime.utc(cur.year, cur.month + 1, 1);
    final bisTag = naechster.isAfter(ende) ? ende : naechster;
    final v = k.verbrauch(cur, bisTag);
    out.add(MonatsVerbrauch(cur.year, cur.month, v.milli, v.gesamtTage, v.vollstaendig));
    cur = naechster;
  }
  return out;
}

/// Summe mehrerer Verbräuche (Wasser-Gruppe: alle Zähler laufen gleichzeitig; [vollstaendig] nur, wenn jeder vollständig ist).
Verbrauch gruppenSumme(Iterable<Verbrauch> verbraeuche) {
  var milli = 0;
  int? abgedeckt;
  var gesamt = 0;
  for (final v in verbraeuche) {
    milli += v.milli;
    if (abgedeckt == null || v.abgedeckteTage < abgedeckt) abgedeckt = v.abgedeckteTage; // abgedeckt ist nur, was ALLE Zähler abdecken
    if (v.gesamtTage > gesamt) gesamt = v.gesamtTage;
  }
  if (abgedeckt == null) return Verbrauch.leer;
  return Verbrauch(milli, abgedeckt, gesamt);
}

/// Vergleich einer Periode mit demselben Kalenderzeitraum des Vorjahres. Läuft die Periode noch, werden beide nur bis [heute] (bzw. dem Vorjahrestag) verglichen.
class Vergleich {
  final Zeitraum aktuell;
  final Zeitraum vorjahr;
  final int aktuellMilli;
  final int vorjahrMilli;
  final bool vollstaendig;
  const Vergleich(this.aktuell, this.vorjahr, this.aktuellMilli, this.vorjahrMilli, this.vollstaendig);

  int get differenzMilli => aktuellMilli - vorjahrMilli;

  /// Veränderung gegenüber dem Vorjahr in Prozent (null ohne Vorjahreswert).
  double? get prozent => vorjahrMilli <= 0 ? null : differenzMilli * 100 / vorjahrMilli;
}

Vergleich vergleichVorjahr(Verbrauchskurve k, Zeitraum periode, DateTime heute) {
  final h = _tag(heute);
  final bis = h.isBefore(periode.ende) ? (h.isBefore(periode.start) ? periode.start : h) : periode.ende;
  final aktuell = Zeitraum(periode.start, bis);
  final vj = vorjahrVon(aktuell);
  final a = k.verbrauch(aktuell.start, aktuell.ende);
  final v = k.verbrauch(vj.start, vj.ende);
  return Vergleich(aktuell, vj, a.milli, v.milli, a.vollstaendig && v.vollstaendig);
}

/// Hochrechnung des Verbrauchs einer laufenden Periode auf die ganze Periode (gleichbleibende Rate der bisher abgedeckten Tage; Jahreszeiten werden nicht berücksichtigt).
class Hochrechnung {
  final int prognoseMilli;
  final int beobachtetMilli;
  final int beobachteteTage;
  final int periodenTage;
  const Hochrechnung(this.prognoseMilli, this.beobachtetMilli, this.beobachteteTage, this.periodenTage);
}

/// null, wenn die Periode schon zu Ende ist oder es noch keine [mindestTage] Tage Beobachtung gibt (eine Hochrechnung aus wenigen Tagen wäre Zufall).
Hochrechnung? hochrechnung(Verbrauchskurve k, Zeitraum periode, DateTime heute, {int mindestTage = 14}) {
  final h = _tag(heute);
  if (!h.isBefore(periode.ende)) return null;
  final v = k.verbrauch(periode.start, h.isBefore(periode.start) ? periode.start : h);
  if (v.abgedeckteTage < mindestTage) return null;
  return Hochrechnung(rundenDiv(v.milli * periode.tage, v.abgedeckteTage), v.milli, v.abgedeckteTage, periode.tage);
}

// ---------------------------------------------------------------- Kosten

/// Preisstand an einem Tag (der letzte mit `ab` <= Tag), null davor.
Preis? preisAm(List<Preis> preise, DateTime tag) {
  final t = tagText(_tag(tag));
  Preis? p;
  for (final e in preise) {
    if (e.ab.compareTo(t) <= 0) {
      p = e;
    } else {
      break;
    }
  }
  return p;
}

/// Teile der Kosten eines Zeitraums, in Cent.
class KostenTeile {
  final int verbrauchMilli;
  final int verbrauchCent;
  final int grundCent;
  final int zaehlerCent;

  /// Ein Teil des Zeitraums (oder des Verbrauchs) liegt vor dem ersten Preisstand: dort fehlen Kosten.
  final bool preisLuecke;
  const KostenTeile(this.verbrauchMilli, this.verbrauchCent, this.grundCent, this.zaehlerCent, this.preisLuecke);

  int get gesamtCent => verbrauchCent + grundCent + zaehlerCent;
}

/// Segmente [von, bis) mit je einem Preisstand (null = kein Preis) im Zeitraum.
List<({DateTime von, DateTime bis, Preis? preis})> _segmente(List<Preis> preise, Zeitraum z) {
  final grenzen = <DateTime>[z.start];
  for (final p in preise) {
    final t = p.abTag;
    if (t != null && t.isAfter(z.start) && t.isBefore(z.ende)) grenzen.add(t);
  }
  grenzen.add(z.ende);
  return [
    for (var i = 0; i + 1 < grenzen.length; i++)
      if (grenzen[i].isBefore(grenzen[i + 1])) (von: grenzen[i], bis: grenzen[i + 1], preis: preisAm(preise, grenzen[i])),
  ];
}

/// Kosten für [zeitraum] bei [preise] und der Verbrauchskurve [k]. Der Arbeitspreis gilt je Preisstand für den darin liegenden Verbrauch; die Jahresgebühren (Grund und Zähler) werden
/// anteilig auf Tage verteilt: Tage im Zeitraum / [bezugsTage] (Tage der ganzen Abrechnungsperiode, damit eine volle Periode genau eine Jahresgebühr kostet, auch im Schaltjahr).
KostenTeile kostenFuerZeitraum(List<Preis> preise, Verbrauchskurve k, Zeitraum zeitraum, {required int bezugsTage}) {
  var verbrauchMilli = 0;
  var ap7 = 0; // Summe Tausendstel * Zehntausendstel Euro (= 10^-7 Euro)
  var gg = 0; // Summe Cent * Tage
  var zg = 0;
  var luecke = false;
  for (final s in _segmente(preise, zeitraum)) {
    final v = k.verbrauch(s.von, s.bis);
    verbrauchMilli += v.milli;
    final tage = tagNummer(s.bis) - tagNummer(s.von);
    if (s.preis == null) {
      luecke = true;
      continue;
    }
    ap7 += v.milli * s.preis!.arbeitspreis;
    gg += s.preis!.grundgebuehrJahr * tage;
    zg += s.preis!.zaehlergebuehrJahr * tage;
  }
  final bezug = bezugsTage <= 0 ? 1 : bezugsTage;
  return KostenTeile(verbrauchMilli, rundenDiv(ap7, 100000), rundenDiv(gg, bezug), rundenDiv(zg, bezug), luecke);
}

/// Abschlagsmonate einer Periode: ganze Monate ab Beginn bis [bis] (für eine laufende Periode die bereits vergangenen, für eine abgeschlossene alle).
int monateImZeitraum(Zeitraum periode, DateTime bis) {
  final ende = _tag(bis).isAfter(periode.ende) ? periode.ende : _tag(bis);
  var n = 0;
  while (true) {
    final naechster = DateTime.utc(periode.start.year, periode.start.month + n + 1, 1);
    final stichtag = tagImMonat(naechster.year, naechster.month, periode.start.day);
    if (stichtag.isAfter(ende)) return n;
    n++;
    if (n >= 120) return n;
  }
}

/// Auswertung einer Abrechnungsperiode: bisher angefallene Kosten, bei einer laufenden Periode zusätzlich die Prognose für die ganze Periode, die Abschläge und die voraussichtliche
/// Nach- (positiv) oder Rückzahlung (negativ).
class PeriodenKosten {
  final Zeitraum periode;
  final bool laufend;
  final KostenTeile bisher;

  /// Nur bei laufender Periode mit genug Beobachtung.
  final KostenTeile? prognose;

  /// Gezahlte Abschläge bisher (ganze Monate) bzw. in der ganzen Periode; null ohne Abschlag.
  final int? abschlaegeBisherCent;
  final int? abschlaegeGesamtCent;

  /// Nachzahlung (positiv) bzw. Rückzahlung (negativ): bei abgeschlossener Periode tatsächlich, sonst voraussichtlich (aus der Prognose). Null ohne Abschlag oder ohne Prognose.
  final int? saldoCent;
  const PeriodenKosten({required this.periode, required this.laufend, required this.bisher, this.prognose, this.abschlaegeBisherCent, this.abschlaegeGesamtCent, this.saldoCent});

  /// Die Kosten der ganzen Periode (abgeschlossen: tatsächlich, laufend: Prognose, sonst null).
  KostenTeile? get ganzePeriode => laufend ? prognose : bisher;
}

PeriodenKosten periodenKosten(ZaehlerInhalt z, Verbrauchskurve k, Zeitraum periode, DateTime heute) {
  final h = _tag(heute);
  final laufend = h.isBefore(periode.ende);
  final bis = laufend ? (h.isBefore(periode.start) ? periode.start : h) : periode.ende;
  final bisher = kostenFuerZeitraum(z.preise, k, Zeitraum(periode.start, bis), bezugsTage: periode.tage);
  KostenTeile? prognose;
  if (laufend) {
    final v = k.verbrauch(periode.start, bis);
    if (v.abgedeckteTage >= 14) {
      final erweitert = k.erweitert(periode.start, periode.ende, beobachtetMilli: v.milli, beobachteteTage: v.abgedeckteTage);
      prognose = kostenFuerZeitraum(z.preise, erweitert, periode, bezugsTage: periode.tage);
    }
  }
  final monateBisher = monateImZeitraum(periode, bis);
  final monateGesamt = monateImZeitraum(periode, periode.ende);
  final abschlag = z.abschlag;
  final bisherAbschlag = abschlag == null ? null : abschlag * monateBisher;
  final gesamtAbschlag = abschlag == null ? null : abschlag * monateGesamt;
  final ganz = laufend ? prognose : bisher;
  return PeriodenKosten(
    periode: periode,
    laufend: laufend,
    bisher: bisher,
    prognose: prognose,
    abschlaegeBisherCent: bisherAbschlag,
    abschlaegeGesamtCent: gesamtAbschlag,
    saldoCent: ganz == null || gesamtAbschlag == null ? null : ganz.gesamtCent - gesamtAbschlag,
  );
}

// ---------------------------------------------------------------- Solar

/// Vorteil einer Photovoltaik-Anlage in einem Zeitraum: Erzeugung (Zähler der Art Erzeugung), davon Eigenverbrauch (Anteil) ersetzt Strom zum Strompreis, der Rest wird eingespeist.
class SolarErgebnis {
  final int erzeugtMilli;
  final int eigenMilli;
  final int einspeiseMilli;

  /// Gesparte Stromkosten durch Eigenverbrauch und Einspeisevergütung, in Cent.
  final int ersparnisCent;
  final int verguetungCent;
  final bool preisLuecke;
  const SolarErgebnis(this.erzeugtMilli, this.eigenMilli, this.einspeiseMilli, this.ersparnisCent, this.verguetungCent, this.preisLuecke);

  int get vorteilCent => ersparnisCent + verguetungCent;
}

/// [strompreise]: Preisverlauf des Stroms (nur der Arbeitspreis zählt). Fehlt der Eigenverbrauchsanteil am Zähler, gilt 100 %.
SolarErgebnis solarVorteil(ZaehlerInhalt erzeugung, Verbrauchskurve k, Zeitraum zeitraum, List<Preis> strompreise) {
  final bp = erzeugung.eigenverbrauchBp ?? 10000;
  var erzeugt = 0;
  var eigen = 0;
  var sparen7 = 0;
  var luecke = false;
  for (final s in _segmente(strompreise, zeitraum)) {
    final v = k.verbrauch(s.von, s.bis).milli;
    erzeugt += v;
    final e = rundenDiv(v * bp, 10000);
    eigen += e;
    if (s.preis == null) {
      luecke = true;
      continue;
    }
    sparen7 += e * s.preis!.arbeitspreis;
  }
  final einspeise = erzeugt - eigen;
  final verg = erzeugung.einspeiseVerguetung;
  return SolarErgebnis(erzeugt, eigen, einspeise, rundenDiv(sparen7, 100000), verg == null ? 0 : rundenDiv(einspeise * verg, 100000), luecke);
}

/// Wann sich die Anlage bezahlt gemacht hat.
class Amortisation {
  final int anlagenkostenCent;
  final int bisherCent;
  final int proJahrCent;

  const Amortisation(this.anlagenkostenCent, this.bisherCent, this.proJahrCent);

  bool get amortisiert => bisherCent >= anlagenkostenCent;
  int get restCent => amortisiert ? 0 : anlagenkostenCent - bisherCent;

  /// Anteil bezahlt in Prozent (0..100).
  double get prozent => anlagenkostenCent <= 0 ? 100 : (bisherCent * 100 / anlagenkostenCent).clamp(0, 100).toDouble();

  /// Jahre bis zur Amortisation bei dem bisherigen Jahresvorteil (null: schon amortisiert oder kein Vorteil).
  double? get restJahre => amortisiert || proJahrCent <= 0 ? null : restCent / proJahrCent;
}

/// [bisherCent]: gesamter Vorteil seit dem ersten Stand; [proJahrCent]: Vorteil der letzten 12 Monate (oder hochgerechnet).
Amortisation amortisation({required int anlagenkostenCent, required int bisherCent, required int proJahrCent}) => Amortisation(anlagenkostenCent, bisherCent, proJahrCent);

// ---------------------------------------------------------------- Plausibilität

enum StandHinweis {
  /// Datum liegt in der Zukunft (blockiert).
  zukunft,

  /// Am selben Tag gibt es schon einen Stand.
  datumDoppelt,

  /// Der Stand ist kleiner als der vorige: Zählerwechsel oder Tippfehler.
  niedriger,

  /// Der Stand ist größer als ein späterer vorhandener (Einfügen in die Vergangenheit).
  hoeherAlsSpaeterer,

  /// Der Verbrauch seit dem vorigen Stand ist ein Vielfaches des Üblichen (verdrehte Ziffern?).
  sprung,
}

class Plausibilitaet {
  final List<StandHinweis> hinweise;
  const Plausibilitaet(this.hinweise);

  bool get ok => hinweise.isEmpty;

  /// Nur ein Datum in der Zukunft verbietet das Speichern; alles andere ist ein Hinweis, den die Person bestätigen kann.
  bool get blockiert => hinweise.contains(StandHinweis.zukunft);

  /// Verdacht auf Zählerwechsel (der Stand fällt).
  bool get wechselVerdacht => hinweise.contains(StandHinweis.niedriger);
}

/// Prüft einen neuen (oder geänderten) Stand gegen die vorhandenen [bestehende] (ohne den geänderten selbst). [sprungFaktor]: ab dem Wievielfachen des üblichen Tagesverbrauchs
/// ein Sprung gemeldet wird. Das Übliche ist die Rate aus allen bisherigen Ständen; ohne Verlauf (weniger als zwei Stände) gibt es keine Sprungprüfung.
Plausibilitaet pruefeStand({required DateTime datum, required int milli, required Iterable<Stand> bestehende, required DateTime heute, int sprungFaktor = 10}) {
  final d = _tag(datum);
  final n = normalisiere(bestehende);
  final h = <StandHinweis>[];
  if (tagNummer(d) > tagNummer(heute)) h.add(StandHinweis.zukunft);
  if (n.any((s) => s.tag == d)) h.add(StandHinweis.datumDoppelt);
  final davor = n.where((s) => s.tag.isBefore(d)).lastOrNull;
  final danach = n.where((s) => s.tag.isAfter(d)).firstOrNull;
  if (davor != null && milli < davor.milli) h.add(StandHinweis.niedriger);
  if (danach != null && milli > danach.milli) h.add(StandHinweis.hoeherAlsSpaeterer);
  if (davor != null && milli >= davor.milli) {
    final verlauf = n.where((s) => !s.tag.isAfter(davor.tag)).toList();
    if (verlauf.length >= 2) {
      final tageGesamt = tagNummer(verlauf.last.tag) - tagNummer(verlauf.first.tag);
      final gesamt = Verbrauchskurve.aus(verlauf).verbrauch(verlauf.first.tag, verlauf.last.tag).milli;
      final tage = tagNummer(d) - tagNummer(davor.tag);
      if (tageGesamt > 0 && gesamt > 0 && tage > 0) {
        // erwartet = Rate * Tage; Sprung, wenn der echte Zuwachs das sprungFaktor-Fache übersteigt (auf ganzen Zahlen, ohne Gleitkomma)
        final zuwachs = milli - davor.milli;
        if (zuwachs * tageGesamt > sprungFaktor * gesamt * tage) h.add(StandHinweis.sprung);
      }
    }
  }
  return Plausibilitaet(h);
}

// ---------------------------------------------------------------- Ablese-Fälligkeit

/// Wann der Zähler zuletzt hätte abgelesen werden sollen und ob es nun fällig ist.
class Faelligkeit {
  /// Letzter Solltermin bis heute (null: noch keiner, z. B. kein Rhythmus).
  final DateTime? letzterTermin;

  /// Nächster Solltermin: bei fälliger Ablesung der letzte, sonst der kommende.
  final DateTime? naechsterTermin;

  /// Seit dem letzten Solltermin wurde nicht abgelesen.
  final bool faellig;
  const Faelligkeit(this.letzterTermin, this.naechsterTermin, this.faellig);
}

/// [letzterStand]: Tag der jüngsten Ablesung (null: nie abgelesen: sofort fällig).
Faelligkeit ablesungFaellig(Ablesung? a, DateTime? letzterStand, DateTime heute) {
  if (a == null) return const Faelligkeit(null, null, false);
  final h = _tag(heute);
  DateTime termin(int jahr, int monat) => tagImMonat(jahr, monat, a.tag);
  DateTime letzter;
  DateTime kommend;
  if (a.art == AblesungArt.monatlich) {
    final dieser = termin(h.year, h.month);
    if (!dieser.isAfter(h)) {
      letzter = dieser;
      kommend = termin(h.year, h.month + 1);
    } else {
      kommend = dieser;
      letzter = termin(h.year, h.month - 1);
    }
  } else {
    final dieser = termin(h.year, a.monat);
    if (!dieser.isAfter(h)) {
      letzter = dieser;
      kommend = termin(h.year + 1, a.monat);
    } else {
      kommend = dieser;
      letzter = termin(h.year - 1, a.monat);
    }
  }
  final faellig = letzterStand == null || _tag(letzterStand).isBefore(letzter);
  return Faelligkeit(letzter, faellig ? letzter : kommend, faellig);
}

// ---------------------------------------------------------------- Kette und Gruppe

/// Die Zähler der Kette von [id] (ältester Vorgänger zuerst, [id] zuletzt). Zyklen und fehlende Vorgänger enden die Kette still.
List<String> kette(String id, Map<String, ZaehlerInhalt> alle) {
  final out = <String>[id];
  var cur = alle[id]?.vorgaenger;
  while (cur != null && alle.containsKey(cur) && !out.contains(cur) && out.length < 50) {
    out.insert(0, cur);
    cur = alle[cur]?.vorgaenger;
  }
  return out;
}

/// Der jüngste Zähler einer Kette (der keinen Nachfolger hat), ausgehend von irgendeinem Mitglied.
String juengsterDerKette(String id, Map<String, ZaehlerInhalt> alle) {
  var cur = id;
  for (var i = 0; i < 50; i++) {
    final nachfolger = alle.entries.where((e) => e.value.vorgaenger == cur && e.key != cur).map((e) => e.key).firstOrNull;
    if (nachfolger == null) return cur;
    cur = nachfolger;
  }
  return cur;
}

/// Zähler einer Gruppe (gleiche Art, gleicher Gruppenname ohne Rücksicht auf Groß- und Kleinschreibung); leer für Zähler ohne Gruppe.
List<String> gruppenMitglieder(String id, Map<String, ZaehlerInhalt> alle) {
  final z = alle[id];
  final g = z?.gruppe.trim().toLowerCase() ?? '';
  if (z == null || g.isEmpty) return const [];
  return [for (final e in alle.entries) if (e.value.art == z.art && e.value.gruppe.trim().toLowerCase() == g) e.key]..sort();
}

/// Tagesdatum aus Text (`YYYY-MM-DD`), sonst null (Hilfe für die Oberfläche).
DateTime? zaehlerTag(String? text) => tagLesen(text);
