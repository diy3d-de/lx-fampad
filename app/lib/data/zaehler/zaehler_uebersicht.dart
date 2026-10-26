// Zähler (Abschnitt 6l, Oberfläche): reine Zusammenfassung der gelesenen Zähler und Stände für die Anzeige, ohne Datenbank und ohne Oberfläche.
//
//  - Eine REIHE ist ein Zähler samt seiner Wechsel-Kette (alter -> neuer Zähler, `kette`): der Verbrauch läuft nahtlos weiter (`Verbrauchskurve.verkettet`).
//  - Eine KACHEL ist eine Reihe oder eine Gruppe mehrerer Reihen derselben Art mit gleichem Gruppennamen (z. B. drei Wasserzähler mit Summe).
// Alles rechnet mit den ganzen Zahlen der Logik (Tausendstel, Zehntausendstel, Cent); nichts wird geraten.
import '../ingest/ingest_logik.dart' show automatischFaellig, kAutomatischFaelligTage;
import '../medikamente/medikament_modelle.dart' show tagText;
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';
import 'zaehler_monate.dart';

/// Ein Zähler samt Kette seiner Vorgänger. [id] ist der jüngste Zähler der Kette.
class ZaehlerReihe {
  final String id;

  /// Die Zähler der Kette, ältester zuerst, [id] zuletzt.
  final List<String> ids;
  final ZaehlerInhalt inhalt;

  /// Alle Stände der Kette, nach Tag (am selben Tag gilt der zuletzt angelegte).
  final List<Stand> staende;
  final Verbrauchskurve kurve;

  /// Lücken zwischen den Zählern der Kette (dort gilt 0 Verbrauch).
  final int luecken;

  /// Eingabeart Monatswerte: die zusammengeführten Monatswerte der Reihe (aufsteigend nach Monat; je Monat einer). Bei Zählerständen leer.
  final List<MonatsWert> monatswerte;
  const ZaehlerReihe({required this.id, required this.ids, required this.inhalt, required this.staende, required this.kurve, this.luecken = 0, this.monatswerte = const []});

  bool get monatlich => inhalt.monatlich;

  /// Der Monatswert des jüngsten Monats (null ohne Werte oder bei Zählerständen).
  MonatsWert? get letzterMonat => monatswerte.isEmpty ? null : monatswerte.last;

  String get name => inhalt.name;
  bool get archiviert => inhalt.archiviert;
  Stand? get letzter => staende.isEmpty ? null : staende.last;
  ZaehlerArt get art => inhalt.art;
}

/// Baut die Reihen: [inhalte] sind die lesbaren Zähler (ID -> Inhalt), [staende] ihre Stände in der Reihenfolge der Anlage. Zähler ohne lesbaren Inhalt fehlen in der Kette still.
/// [monatswerte]: die Monatswerte je Zähler (nur für die Eingabeart Monatswerte; bei Zählerständen ignoriert, und umgekehrt zählen bei Monatswerte-Zählern Stände nie). [heute]: der
/// laufende Monat ist dann ein Zwischenstand bis heute (ohne Angabe zählt jeder Monat voll).
List<ZaehlerReihe> baueReihen(Map<String, ZaehlerInhalt> inhalte, Map<String, List<Stand>> staende, {Map<String, List<MonatsWert>> monatswerte = const {}, DateTime? heute}) {
  final juengste = <String>{for (final id in inhalte.keys) juengsterDerKette(id, inhalte)};
  final reihen = <ZaehlerReihe>[];
  for (final j in juengste) {
    final ketteIds = kette(j, inhalte);
    if (inhalte[j]!.monatlich) {
      final werte = monatswerteZusammenfuehren([for (final id in ketteIds) ...?monatswerte[id]]);
      reihen.add(ZaehlerReihe(id: j, ids: ketteIds, inhalt: inhalte[j]!, staende: const [], kurve: Verbrauchskurve.ausMonatswerten(werte, heute: heute), monatswerte: werte));
      continue;
    }
    final alle = <Stand>[for (final id in ketteIds) ...?staende[id]];
    final v = Verbrauchskurve.verkettet([for (final id in ketteIds) Verbrauchskurve.aus(staende[id] ?? const [])]);
    reihen.add(ZaehlerReihe(id: j, ids: ketteIds, inhalt: inhalte[j]!, staende: normalisiere(alle), kurve: v.kurve, luecken: v.luecken));
  }
  reihen.sort((a, b) {
    final c = a.art.index.compareTo(b.art.index);
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return reihen;
}

/// Eine Kachel der Übersicht: ein einzelner Zähler oder eine Gruppe (mindestens zwei Reihen derselben Art mit gleichem Gruppennamen).
class ZaehlerKachel {
  final String schluessel;
  final String titel;
  final ZaehlerArt art;
  final List<ZaehlerReihe> reihen;
  const ZaehlerKachel({required this.schluessel, required this.titel, required this.art, required this.reihen});

  bool get istGruppe => reihen.length > 1;
  ZaehlerReihe get erste => reihen.first;
  String get einheit => erste.inhalt.einheit;

  /// Alle Zähler der Kachel (auch die der Wechsel-Ketten) für "Alle ablesen".
  List<ZaehlerReihe> get zumAblesen => [for (final r in reihen) if (!r.archiviert) r];
}

/// Die Kacheln der nicht archivierten Reihen, nach Art und Name.
List<ZaehlerKachel> baueKacheln(List<ZaehlerReihe> reihen) {
  final gruppen = <String, List<ZaehlerReihe>>{};
  for (final r in reihen) {
    if (r.archiviert) continue;
    final g = r.inhalt.gruppe.trim().toLowerCase();
    if (g.isNotEmpty) (gruppen['g:${r.art.wire}:$g'] ??= []).add(r);
  }
  final out = <ZaehlerKachel>[];
  final schonGruppe = <String>{};
  for (final r in reihen) {
    if (r.archiviert) continue;
    final g = r.inhalt.gruppe.trim().toLowerCase();
    final key = 'g:${r.art.wire}:$g';
    if (g.isNotEmpty && (gruppen[key]?.length ?? 0) > 1) {
      if (schonGruppe.add(key)) out.add(ZaehlerKachel(schluessel: key, titel: r.inhalt.gruppe.trim(), art: r.art, reihen: gruppen[key]!));
    } else {
      out.add(ZaehlerKachel(schluessel: 'z:${r.id}', titel: r.name, art: r.art, reihen: [r]));
    }
  }
  return out;
}

// ---------------------------------------------------------------- Verbrauch einer Kachel

/// Verbrauch einer Kachel in [von, bis): bei einer Gruppe die Summe aller Zähler.
Verbrauch kachelVerbrauch(ZaehlerKachel k, DateTime von, DateTime bis) => gruppenSumme([for (final r in k.reihen) r.kurve.verbrauch(von, bis)]);

/// Verbrauch je Monat einer Kachel (Gruppe: Summe je Monat; vollständig nur, wenn jeder Zähler vollständig ist).
List<MonatsVerbrauch> kachelMonate(ZaehlerKachel k, DateTime von, DateTime bis) {
  final je = [for (final r in k.reihen) verbrauchJeMonat(r.kurve, von, bis)];
  if (je.isEmpty) return const [];
  return [
    for (var i = 0; i < je.first.length; i++)
      MonatsVerbrauch(je.first[i].jahr, je.first[i].monat, je.fold(0, (s, l) => s + l[i].milli), je.first[i].tage, je.every((l) => l[i].vollstaendig)),
  ];
}

/// Der jüngste vollständig abgedeckte Kalendermonat vor [heute] (höchstens 24 Monate zurück) mit dem Vorjahresmonat; null, wenn es keinen gibt.
class MonatsStand {
  final int jahr;
  final int monat;
  final int milli;
  final int? vorjahrMilli;
  const MonatsStand(this.jahr, this.monat, this.milli, this.vorjahrMilli);

  /// Veränderung in Prozent zum Vorjahresmonat (null ohne Vorjahreswert).
  double? get prozent => vorjahrMilli == null || vorjahrMilli! <= 0 ? null : (milli - vorjahrMilli!) * 100 / vorjahrMilli!;
}

MonatsStand? letzterVollerMonat(ZaehlerKachel k, DateTime heute) {
  for (var i = 1; i <= 24; i++) {
    final von = DateTime.utc(heute.year, heute.month - i, 1);
    final bis = DateTime.utc(von.year, von.month + 1, 1);
    final v = kachelVerbrauch(k, von, bis);
    if (!v.vollstaendig) continue;
    final vj = kachelVerbrauch(k, DateTime.utc(von.year - 1, von.month, 1), DateTime.utc(von.year - 1, von.month + 1, 1));
    return MonatsStand(von.year, von.month, v.milli, vj.vollstaendig ? vj.milli : null);
  }
  return null;
}

/// Prozent, ab denen der Verbrauch der Kachel als ungewöhnlich hoch gilt (die niedrigste gesetzte Schwelle der Zähler); null ohne Schwelle.
int? warnSchwelle(ZaehlerKachel k) {
  int? s;
  for (final r in k.reihen) {
    final w = r.inhalt.warnProzent;
    if (w != null && (s == null || w < s)) s = w;
  }
  return s;
}

/// Ist der letzte volle Monat ungewöhnlich hoch (mehr als die Warnschwelle über dem Vorjahresmonat)? Nur mit Schwelle und vollständigem Vorjahr, sonst nie.
bool ungewoehnlichHoch(ZaehlerKachel k, DateTime heute) {
  final s = warnSchwelle(k);
  final m = letzterVollerMonat(k, heute);
  final p = m?.prozent;
  return s != null && p != null && p > s;
}

// ---------------------------------------------------------------- Fälligkeit

/// Ablese-Fälligkeit einer Reihe (archivierte nie).
Faelligkeit reiheFaelligkeit(ZaehlerReihe r, DateTime heute) => r.archiviert
    ? const Faelligkeit(null, null, false)
    : r.monatlich
        ? monatswertFaellig(r.monatswerte, heute)
        : r.inhalt.automatisch
            ? automatischeFaelligkeit(r.letzter?.tag, heute)
            : ablesungFaellig(r.inhalt.ablesung, r.letzter?.tag, heute);

/// Automatische Quelle (Home Assistant): ein Ablese-Rhythmus entfällt, "Ablesen fällig" erscheint erst, wenn länger als [kAutomatischFaelligTage] Tage kein Wert kam.
Faelligkeit automatischeFaelligkeit(DateTime? letzterStand, DateTime heute) {
  if (!automatischFaellig(letzterStand, heute)) return const Faelligkeit(null, null, false);
  final seit = letzterStand!.add(const Duration(days: kAutomatischFaelligTage + 1));
  return Faelligkeit(seit, seit, true);
}

/// Die Reihen, die jetzt abgelesen werden sollen.
List<ZaehlerReihe> faelligeReihen(Iterable<ZaehlerReihe> reihen, DateTime heute) => [for (final r in reihen) if (reiheFaelligkeit(r, heute).faellig) r];

/// Kurzer Text zur Fälligkeit einer Kachel: Fällig, "Nächste: 01.11.", "Kein Rhythmus".
enum FaelligkeitsArt { faellig, aktuell, keinRhythmus }

({FaelligkeitsArt art, DateTime? termin}) kachelFaelligkeit(ZaehlerKachel k, DateTime heute) {
  DateTime? naechster;
  var rhythmus = false;
  for (final r in k.reihen) {
    final f = reiheFaelligkeit(r, heute);
    if ((r.inhalt.ablesung != null || r.monatlich || r.inhalt.automatisch) && !r.archiviert) rhythmus = true;
    if (f.faellig) return (art: FaelligkeitsArt.faellig, termin: f.naechsterTermin);
    if (f.naechsterTermin != null && (naechster == null || f.naechsterTermin!.isBefore(naechster))) naechster = f.naechsterTermin;
  }
  return rhythmus ? (art: FaelligkeitsArt.aktuell, termin: naechster) : (art: FaelligkeitsArt.keinRhythmus, termin: null);
}

/// "01.11." aus einem Tag.
String tagKurz(DateTime t) => '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.';

/// "01.11.2026".
String tagDeutsch(DateTime t) => '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';

/// "2026-11-01" -> "01.11.2026"; Unlesbares bleibt unverändert.
String datumTextDeutsch(String ymd) {
  final t = DateTime.tryParse(ymd);
  return t == null ? ymd : tagDeutsch(t);
}

String tagIso(DateTime t) => tagText(t);

// ---------------------------------------------------------------- Solar

/// Auswertung einer Erzeugungsreihe (Solar): Vorteil in der laufenden Abrechnungsperiode bis heute und Amortisation der Anlage.
class SolarAuswertung {
  final Zeitraum periode;
  final SolarErgebnis ergebnis;
  final Amortisation? amortisation;
  const SolarAuswertung(this.periode, this.ergebnis, this.amortisation);
}

/// Der Strompreis der Ersparnis steht im Preisverlauf des Erzeugungszählers selbst (Arbeitspreis); Eigenverbrauchsanteil, Einspeisevergütung und Anschaffungspreis ebenfalls dort.
SolarAuswertung solarAuswertung(ZaehlerReihe r, DateTime heute) {
  final p = abrechnungsperiode(heute, periodeMonat: r.inhalt.periodeMonat, periodeTag: r.inhalt.periodeTag);
  // Monatswerte enthalten den laufenden Monat bis einschließlich heute: der Zeitraum endet dann nach heute, sonst fehlt der Anteil des heutigen Tages
  final bisHeute = r.inhalt.monatlich ? heute.add(const Duration(days: 1)) : heute;
  final bis = bisHeute.isBefore(p.ende) ? (bisHeute.isBefore(p.start) ? p.start : bisHeute) : p.ende;
  final jahr = solarVorteil(r.inhalt, r.kurve, Zeitraum(p.start, bis), r.inhalt.preise);
  Amortisation? am;
  final kosten = r.inhalt.anlagenkosten;
  final erster = r.kurve.ersterTag;
  if (kosten != null && kosten > 0 && erster != null) {
    final seit = tagVonNummer(erster);
    final tage = tagNummer(heute) - erster;
    final gesamt = solarVorteil(r.inhalt, r.kurve, Zeitraum(seit, bisHeute), r.inhalt.preise).vorteilCent;
    final jahrVorteil = tage >= 365
        ? solarVorteil(r.inhalt, r.kurve, Zeitraum(heute.subtract(const Duration(days: 365)), heute), r.inhalt.preise).vorteilCent
        : (tage >= 30 ? rundenDiv(gesamt * 365, tage) : 0);
    am = amortisation(anlagenkostenCent: kosten, bisherCent: gesamt, proJahrCent: jahrVorteil);
  }
  return SolarAuswertung(p, jahr, am);
}

// ---------------------------------------------------------------- Vorschau eines neuen Standes

/// Was die Person beim Eintragen sofort sieht: letzter Stand davor, Verbrauch seitdem, Verbrauch je Tag und der Vorjahreswert je Tag (nur wenn bekannt).
class StandVorschau {
  final Stand? davor;
  final int? verbrauchMilli;
  final int? tage;
  final int? proTagMilli;
  final int? vorjahrProTagMilli;
  const StandVorschau({this.davor, this.verbrauchMilli, this.tage, this.proTagMilli, this.vorjahrProTagMilli});
}

StandVorschau standVorschau(ZaehlerReihe r, DateTime datum, int milli) {
  final d = DateTime.utc(datum.year, datum.month, datum.day);
  final davor = r.staende.where((s) => s.tag.isBefore(d)).lastOrNull;
  if (davor == null) return const StandVorschau();
  final tage = tagNummer(d) - tagNummer(davor.tag);
  if (milli < davor.milli) return StandVorschau(davor: davor, tage: tage);
  final v = milli - davor.milli;
  final pro = tage > 0 ? rundenDiv(v, tage) : null;
  int? vj;
  if (tage > 0) {
    final z = vorjahrVon(Zeitraum(davor.tag, d));
    final w = r.kurve.verbrauch(z.start, z.ende);
    if (w.vollstaendig) vj = rundenDiv(w.milli, tage);
  }
  return StandVorschau(davor: davor, verbrauchMilli: v, tage: tage, proTagMilli: pro, vorjahrProTagMilli: vj);
}
