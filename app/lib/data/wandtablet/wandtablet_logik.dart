// Wandtablet-Modus: reine Logik ohne Oberfläche und ohne Speicher (Auswahl und Reihenfolge der Blöcke, Spalten, Dimm-Zeitfenster,
// Einbrenn-Schutz, Texte). Alle Uhrzeiten sind Wanduhr der Familienzone (Europe/Berlin), wie überall in der App.
import '../app_database.dart';
import '../calendar/expansion.dart';
import '../calendar/zeitzonen.dart';
import '../tasks/aufgabe_logik.dart';

/// Hinweis beim Start des Modus (kurz eingeblendet) und Beschriftung der Ausstiegsaktion.
const kWandHinweisBeenden = 'Zum Beenden gedrückt halten';

/// Einbrenn-Schutz: alle [kWandVerschiebeMinuten] Minuten rückt der Inhalt auf den nächsten Punkt (wenige Pixel).
const kWandVerschiebeMinuten = 5;
const _verschiebePunkte = <(int, int)>[(0, 0), (4, 2), (-3, 5), (5, -4), (-5, -2), (2, -6), (-4, 4), (6, 3), (-2, -5)];

/// Größter Betrag der Verschiebung in Pixeln (je Achse).
const kWandVerschiebeMax = 6;

/// Nachts (Wanduhr 22 bis unter 6 Uhr) ist die Anzeige gedimmt, wenn "Nachts dimmen" an ist.
const kWandNachtVon = 22;
const kWandNachtBis = 6;

/// Wie stark die Fläche nachts abgedunkelt wird (Deckkraft der Hintergrundfarbe über dem Inhalt).
const kWandNachtDeckkraft = 0.6;

DateTime wandJetzt(DateTime jetzt) => wandUhr(jetzt.toUtc(), familienOrt);

bool istNacht(DateTime jetzt) {
  final h = wandJetzt(jetzt).hour;
  return h >= kWandNachtVon || h < kWandNachtBis;
}

/// Deckkraft der Abdunklung: 0 am Tag oder ohne "Nachts dimmen".
double dimmDeckkraft(DateTime jetzt, {required bool dimmen}) => dimmen && istNacht(jetzt) ? kWandNachtDeckkraft : 0;

/// Verschiebung des Inhalts in Pixeln: wechselt alle [kWandVerschiebeMinuten] Minuten auf den nächsten von neun festen Punkten (höchstens
/// [kWandVerschiebeMax] Pixel je Achse); deterministisch aus der Zeit, damit zwei Aufrufe in demselben Zeitfenster dasselbe ergeben.
({int dx, int dy}) verschiebung(DateTime jetzt) {
  final schritt = jetzt.toUtc().millisecondsSinceEpoch ~/ (kWandVerschiebeMinuten * 60000);
  final p = _verschiebePunkte[schritt % _verschiebePunkte.length];
  return (dx: p.$1, dy: p.$2);
}

/// "HH:mm" der Wanduhr.
String wandUhrText(DateTime jetzt) {
  final w = wandJetzt(jetzt);
  return '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
}

/// Hinweis bei fehlender Verbindung: "Offline seit 14:32" (heute), "Offline seit 12.10. 14:32" (früher), ohne bekannten Abgleich nur "Offline".
String offlineText(DateTime? letzterAbgleich, DateTime jetzt) {
  if (letzterAbgleich == null) return 'Offline';
  final a = wandJetzt(letzterAbgleich);
  final h = wandJetzt(jetzt);
  final zeit = wandUhrText(letzterAbgleich);
  if (a.year == h.year && a.month == h.month && a.day == h.day) return 'Offline seit $zeit';
  return 'Offline seit ${a.day}.${a.month}. $zeit';
}

/// Die Blöcke der Anzeige. Termine und Aufgaben gibt es immer, die übrigen nur, wenn es etwas zu zeigen gibt.
enum WandBlock { termine, aufgaben, fristen, countdown, muell, wetter, einkauf }

/// Reihenfolge der sichtbaren Blöcke (fest, nicht einstellbar).
List<WandBlock> sichtbareBloecke({bool fristen = false, bool countdown = false, bool muell = false, bool wetter = false, bool einkauf = false}) => [
  WandBlock.termine,
  WandBlock.aufgaben,
  if (fristen) WandBlock.fristen,
  if (countdown) WandBlock.countdown,
  if (muell) WandBlock.muell,
  if (wetter) WandBlock.wetter,
  if (einkauf) WandBlock.einkauf,
];

/// Anzahl der Spalten zur Breite: ab 1200 px drei, ab 900 px zwei, darunter eine (scrollend).
int wandSpalten(double breite) => breite >= 1200 ? 3 : (breite >= 900 ? 2 : 1);

/// Verteilt die Blöcke auf [spalten] Spalten: die Termine stehen allein in der ersten Spalte (der größte Block), die übrigen reihum auf die
/// weiteren; mit einer Spalte stehen alle untereinander. Leere Spalten gibt es nie.
List<List<WandBlock>> verteileSpalten(List<WandBlock> bloecke, int spalten) {
  if (spalten <= 1 || bloecke.length <= 1) return [bloecke];
  final out = List.generate(spalten, (_) => <WandBlock>[]);
  out[0].add(bloecke.first);
  var i = 0;
  for (final b in bloecke.skip(1)) {
    out[1 + i % (spalten - 1)].add(b);
    i++;
  }
  return [
    for (final s in out)
      if (s.isNotEmpty) s,
  ];
}

/// Teilt die Vorkommen in "heute" (beginnt heute oder früher und läuft noch) und "morgen"; die Reihenfolge bleibt.
({List<Vorkommen> heute, List<Vorkommen> morgen}) teileHeuteMorgen(List<Vorkommen> liste, DateTime heute) {
  final h = <Vorkommen>[];
  final m = <Vorkommen>[];
  for (final v in liste) {
    (v.ersterTag.isAfter(heute) ? m : h).add(v);
  }
  return (heute: h, morgen: m);
}

/// Aufgaben für die Anzeige: offen und heute fällig oder überfällig, nach Fälligkeit (nur Titel werden gezeigt).
List<Aufgabe> wandAufgaben(List<Aufgabe> alle, DateTime jetzt) => sortiereAufgaben([
  for (final a in alle)
    if (!istErledigt(a) && (istHeuteFaellig(a, jetzt) || istUeberfaellig(a, jetzt))) a,
], AufgabeSortierung.faelligkeit);
