// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), reine Entscheidungslogik ohne Datenbank, Netz und Oberfläche.
//
//  - Zuordnung: ein Kanal gehört zu dem nicht archivierten Zähler, dessen Quelle ihn nennt.
//  - Entscheidung je Wert (ein Wert je Kanal und Tag, Stand zum Tagesbeginn):
//      vorhanden  = für diesen Zähler gibt es an diesem Tag schon einen Stand (von Hand oder automatisch): nichts überschreiben, quittieren
//      eintragen  = unauffällig: als Zählerstand eintragen
//      pruefen    = auffällig: der Person vorlegen (Stand kleiner als der davor oder höher als ein späterer; Sprung)
//    Ein Stand kleiner als der davor wird IMMER vorgelegt (Zähler getauscht oder Home Assistant zurückgesetzt, so etwas trägt die App nie von selbst ein); der Sprung nur, wenn der
//    Zähler "Prüfen vor dem Eintragen" hat und es mindestens drei Tage Verlauf gibt: Tagesverbrauch mehr als das Zehnfache des Medians der letzten 30 Tage UND mehr als 20 Einheiten.
// Alles auf ganzen Zahlen (Tausendstel), keine Gleitkommazahl. Kalendertage rechnen über `tagNummer` (keine Sommerzeit-Fehler).
import '../zaehler/zaehler_logik.dart';
import '../zaehler/zaehler_modelle.dart';

/// Ab wie vielen vorhandenen Tagen der Sprung geprüft wird.
const int kSprungMindestTage = 3;

/// Fenster für den Median des Tagesverbrauchs.
const int kSprungFensterTage = 30;

/// Faktor und Mindestwert (20 Einheiten = 20 000 Tausendstel) des Sprungs.
const int kSprungFaktor = 10;
const int kSprungMindestMilli = 20000;

/// Nach wie vielen Tagen ohne Wert ein automatischer Zähler als "Ablesen fällig" gilt.
const int kAutomatischFaelligTage = 3;

/// Der Zähler, an den ein Kanal liefert.
class IngestZiel {
  final String zaehlerId;
  final ZaehlerInhalt inhalt;
  const IngestZiel(this.zaehlerId, this.inhalt);
}

/// Kanal -> Zähler. Archivierte Zähler und nicht lesbare fehlen. Haben mehrere Zähler denselben Kanal, gewinnt der mit der kleinsten ID (stabil, nie zufällig); die Oberfläche
/// warnt davor ([doppelteKanaele]).
Map<String, IngestZiel> kanalZuordnung(Map<String, ZaehlerInhalt> zaehler) {
  final ids = zaehler.keys.toList()..sort();
  final out = <String, IngestZiel>{};
  for (final id in ids) {
    final z = zaehler[id]!;
    final q = z.quelle;
    if (q == null || z.archiviert || z.monatlich) continue;
    out.putIfAbsent(q.kanal, () => IngestZiel(id, z));
  }
  return out;
}

/// Kanäle, die doppelt belegt sind: (1) mehr als ein nicht archivierter Zähler beansprucht sie, oder (2) für einen Zähler mit dem Kanal liegen für denselben Tag mehrere automatische
/// Stände vor ([mitDoppeltenTagen], siehe [zaehlerMitDoppeltenAutoTagen]): zwei Abholgeräte oder zwei Verbindungen liefern dieselben Werte.
Set<String> doppelteKanaele(Map<String, ZaehlerInhalt> zaehler, {Set<String> mitDoppeltenTagen = const {}}) {
  final zaehlt = <String, int>{};
  final doppeltBeliefert = <String>{};
  for (final e in zaehler.entries) {
    final q = e.value.quelle;
    if (q == null || e.value.archiviert) continue;
    zaehlt[q.kanal] = (zaehlt[q.kanal] ?? 0) + 1;
    if (mitDoppeltenTagen.contains(e.key)) doppeltBeliefert.add(q.kanal);
  }
  return {for (final e in zaehlt.entries) if (e.value > 1) e.key, ...doppeltBeliefert};
}

/// Die Zähler (IDs), für die mindestens ein Tag mehrere automatische Stände (Herkunft Home Assistant) hat: das ist nur möglich, wenn zwei Geräte oder Verbindungen denselben Zähler
/// beliefert haben. [automatischeTage]: je Zähler die Tage seiner automatischen Einträge (einer je Eintrag, also mit Wiederholungen). Reine Zählung, keine Werte.
Set<String> zaehlerMitDoppeltenAutoTagen(Map<String, Iterable<DateTime>> automatischeTage) {
  final out = <String>{};
  for (final e in automatischeTage.entries) {
    final gesehen = <int>{};
    for (final t in e.value) {
      if (!gesehen.add(tagNummer(t))) {
        out.add(e.key);
        break;
      }
    }
  }
  return out;
}

/// Nach so vielen Tagen löscht der Server ein Päckchen, das niemand abholt (Aufbewahrung höchstens 30 Tage).
const int kPaketAufbewahrungTage = 30;

/// Ab diesem Alter (Tage) weist die Oberfläche darauf hin, dass ein Päckchen bald gelöscht wird.
const int kPaketLoeschHinweisTage = 25;

/// Wie viele Tage ein beim Server wartendes Päckchen noch bleibt, wenn es [kPaketLoeschHinweisTage] oder mehr Tage alt ist; sonst null (kein Hinweis, auch ohne bekannten Empfang).
int? paketLoeschInTagen(DateTime? empfangen, DateTime jetzt) {
  if (empfangen == null) return null;
  final alter = jetzt.difference(empfangen).inDays;
  if (alter < kPaketLoeschHinweisTage) return null;
  final rest = kPaketAufbewahrungTage - alter;
  return rest < 0 ? 0 : rest;
}

/// "Wird in 3 Tagen vom Server gelöscht".
String paketLoeschText(int tage) => tage <= 0 ? 'Wird heute oder morgen vom Server gelöscht' : (tage == 1 ? 'Wird in 1 Tag vom Server gelöscht' : 'Wird in $tage Tagen vom Server gelöscht');

enum IngestAktion { eintragen, vorhanden, pruefen }

/// Warum ein Wert zur Prüfung vorgelegt wird.
enum PruefGrund {
  kleiner,
  hoeherAlsSpaeter,
  sprung,

  /// Der Stand ist keine gültige Zahl (zum Beispiel mehr als 10 Stellen), das Päckchen aber echt (der MAC stimmt): nie von selbst eintragen oder löschen, nur auf ausdrückliche Entscheidung verwerfen.
  ungueltig,
}

class IngestEntscheidung {
  final IngestAktion aktion;
  final PruefGrund? grund;

  /// Zur Anzeige der Prüfliste: der letzte Stand davor (Tausendstel) und der übliche Tagesverbrauch (Median, Tausendstel; null: nicht berechnet) bzw. der Tagesverbrauch dieses Werts.
  final int? davorMilli;
  final int? tagesVerbrauchMilli;
  final int? ueblichMilli;
  const IngestEntscheidung(this.aktion, {this.grund, this.davorMilli, this.tagesVerbrauchMilli, this.ueblichMilli});
}

/// Median ganzer Zahlen (bei gerader Anzahl der gerundete Mittelwert der beiden mittleren). Leere Liste: 0.
int medianMilli(List<int> werte) {
  if (werte.isEmpty) return 0;
  final s = [...werte]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : rundenDiv(s[n ~/ 2 - 1] + s[n ~/ 2], 2);
}

/// Tagesverbräuche aus den Ständen der letzten [kSprungFensterTage] Tage vor [tag]: je Paar aufeinanderfolgender Stände der Verbrauch je Tag (gerundet).
List<int> tagesVerbraeuche(List<Stand> bestehende, DateTime tag) {
  final n = normalisiere(bestehende).where((s) => tagNummer(s.tag) < tagNummer(tag)).toList();
  final von = tagNummer(tag) - kSprungFensterTage;
  final raten = <int>[];
  for (var i = 1; i < n.length; i++) {
    final a = n[i - 1];
    final b = n[i];
    if (tagNummer(a.tag) < von) continue;
    final tage = tagNummer(b.tag) - tagNummer(a.tag);
    if (tage <= 0 || b.milli < a.milli) continue;
    raten.add(rundenDiv(b.milli - a.milli, tage));
  }
  return raten;
}

/// Entscheidet über einen Wert. [bestehende]: alle bisherigen Stände des Zählers (auch die der Zähler davor in der Kette sind nicht nötig, der Wert gilt für den Zähler selbst).
/// [pruefen]: der Schalter "Prüfen vor dem Eintragen" des Zählers.
IngestEntscheidung entscheide({required List<Stand> bestehende, required DateTime tag, required int milli, required bool pruefen}) {
  final t = tagNummer(tag);
  final n = normalisiere(bestehende);
  if (n.any((s) => tagNummer(s.tag) == t)) return const IngestEntscheidung(IngestAktion.vorhanden);
  final davor = n.where((s) => tagNummer(s.tag) < t).lastOrNull;
  final danach = n.where((s) => tagNummer(s.tag) > t).firstOrNull;
  if (davor != null && milli < davor.milli) return IngestEntscheidung(IngestAktion.pruefen, grund: PruefGrund.kleiner, davorMilli: davor.milli);
  if (danach != null && milli > danach.milli) return IngestEntscheidung(IngestAktion.pruefen, grund: PruefGrund.hoeherAlsSpaeter, davorMilli: davor?.milli);
  if (pruefen && davor != null) {
    final raten = tagesVerbraeuche(bestehende, tag);
    // "weniger als 3 vorhandene Tage": nur die Prüfung "kleiner" (siehe oben). Zählt die Tage mit Stand im Fenster.
    final tageImFenster = n.where((s) => tagNummer(s.tag) < t && tagNummer(s.tag) >= t - kSprungFensterTage).length;
    if (tageImFenster >= kSprungMindestTage && raten.isNotEmpty) {
      final tage = t - tagNummer(davor.tag);
      final rate = rundenDiv(milli - davor.milli, tage);
      final median = medianMilli(raten);
      if (rate > kSprungMindestMilli && rate > kSprungFaktor * median) {
        return IngestEntscheidung(IngestAktion.pruefen, grund: PruefGrund.sprung, davorMilli: davor.milli, tagesVerbrauchMilli: rate, ueblichMilli: median);
      }
    }
  }
  return const IngestEntscheidung(IngestAktion.eintragen);
}

/// "Ablesen fällig" bei einer automatischen Quelle: erst, wenn es schon Stände gibt und seit mehr als [kAutomatischFaelligTage] Tagen kein neuer kam (vorher wartet die Verbindung
/// noch auf ihren ersten Wert, das ist kein Versäumnis der Person).
bool automatischFaellig(DateTime? letzterStand, DateTime heute) =>
    letzterStand != null && tagNummer(heute) - tagNummer(letzterStand) > kAutomatischFaelligTage;
