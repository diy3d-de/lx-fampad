// Home-Assistant-Anbindung der Zähler: kleine reine Hilfen für die Anzeige (ohne Netz, ohne Datenbank, ohne Oberfläche).
import '../zaehler/zaehler_logik.dart' show tagNummer;
import '../zaehler/zaehler_modelle.dart' show ZaehlerArt, ZaehlerInhalt;
import '../zaehler/zaehler_state.dart' show ZaehlerEintrag;
import '../zaehler/zaehler_uebersicht.dart';
import 'ingest_logik.dart' show doppelteKanaele, zaehlerMitDoppeltenAutoTagen;

/// Die drei festen Kanäle der Home-Assistant-Integration (docs/HA-FORMAT.md) mit Anzeigename und der Zählerart, zu der sie passen. Home Assistant schickt nur kWh: Strom und Solar.
const List<({String kanal, String label, ZaehlerArt art})> kHaKanaele = [
  (kanal: 'strom_bezug', label: 'Strom Bezug', art: ZaehlerArt.strom),
  (kanal: 'strom_einspeisung', label: 'Strom Einspeisung', art: ZaehlerArt.strom),
  (kanal: 'solar_erzeugung', label: 'Solar Erzeugung', art: ZaehlerArt.erzeugung),
];

/// Liefert Home Assistant Werte für diese Zählerart? Nur Strom und Solar (kWh); Wasser, Gas und Wärme bekämen nie einen Wert.
bool haLiefertFuer(ZaehlerArt a) => a == ZaehlerArt.strom || a == ZaehlerArt.erzeugung;

/// Anzeigename eines Kanals (unbekannte Kanäle zeigen ihre Kennung).
String haKanalLabel(String kanal) {
  for (final k in kHaKanaele) {
    if (k.kanal == kanal) return k.label;
  }
  return kanal;
}

/// Der Kanal, der zu einer Zählerart am besten passt (Vorbelegung im Editor).
String? haStandardKanal(ZaehlerArt a) => switch (a) {
  ZaehlerArt.strom => 'strom_bezug',
  ZaehlerArt.erzeugung => 'solar_erzeugung',
  _ => null,
};

/// Der jüngste Stand unter den nicht archivierten Zählern mit automatischer Quelle (Zähler und Tag), sonst null. Damit sieht auch ein Gerät ohne Postfach-Schlüssel (zweites Elternteil),
/// ob Werte ankommen: die Stände sind für alle Eltern lesbar.
({String name, DateTime tag})? letzterAutomatischerStand(Iterable<ZaehlerReihe> reihen) {
  ({String name, DateTime tag})? best;
  for (final r in reihen) {
    if (r.archiviert || !r.inhalt.automatisch) continue;
    final t = r.letzter?.tag;
    if (t == null) continue;
    if (best == null || tagNummer(t) > tagNummer(best.tag)) best = (name: r.name, tag: t);
  }
  return best;
}

/// Seit wie vielen vollen Tagen kein Stand mehr kam (null: noch nie einer).
int? tageOhneWert(ZaehlerReihe r, DateTime heute) {
  final t = r.letzter?.tag;
  return t == null ? null : tagNummer(heute) - tagNummer(t);
}

/// "seit 4 Tagen" / "seit gestern".
String seitTagenText(int tage) => tage <= 1 ? 'seit gestern' : 'seit $tage Tagen';

/// Zähler mit Quelle, für die ein Tag mehrere automatische Stände hat (zwei Abholgeräte oder zwei Verbindungen liefern denselben Kanal), und die betroffenen Kanäle. Reine Zählung über die
/// lesbaren Einträge, keine Werte; archivierte Zähler zählen nicht.
({List<String> zaehler, Set<String> kanaele}) doppeltBelieferte(Iterable<ZaehlerEintrag> eintraege) {
  final inhalte = <String, ZaehlerInhalt>{};
  final tage = <String, List<DateTime>>{};
  final namen = <String, String>{};
  for (final e in eintraege) {
    final i = e.inhalt;
    if (i == null || i.quelle == null || i.archiviert) continue;
    inhalte[e.id] = i;
    namen[e.id] = i.name;
    tage[e.id] = [
      for (final s in e.staende)
        if (s.inhalt != null && s.inhalt!.automatisch && !s.inhalt!.istMonatswert && s.inhalt!.tag != null) s.inhalt!.tag!,
    ];
  }
  final ids = zaehlerMitDoppeltenAutoTagen(tage);
  final namenListe = [for (final id in ids) namen[id]!]..sort();
  return (zaehler: namenListe, kanaele: doppelteKanaele(inhalte, mitDoppeltenTagen: ids));
}
