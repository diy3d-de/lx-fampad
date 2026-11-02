// Hinweise auf neue und geänderte Termine anderer Personen (rein, ohne Datenbank und Plattform). Das Gerät erkennt lokal nach dem Abgleich, was
// die anderen Geräte der Familie neu angelegt oder verändert haben; nichts davon geht über den Server oder den Wecker (der Wecker enthält nie Inhalt).
//
// Grundlage ist ein Abdruck je Termin VOR dem Abgleich ([TerminStand]): eigene Änderungen stehen schon lokal in der Tabelle und sind darum im Abdruck
// enthalten, sie lösen nichts aus. Gemeldet wird nur, was die Antwort des Servers neu gebracht hat (Revision höher als zu Beginn des Laufs).
import '../app_database.dart';
import 'geburtstag.dart' show hatGeburtstagsMarke;

/// Nutzlast der Benachrichtigung: ein Tipp öffnet den Kalender.
const kTerminHinweisPayload = 'termine';

bool istTerminHinweisPayload(String? payload) => payload == kTerminHinweisPayload;

/// Stand eines Termins zu Beginn eines Abgleichs: Revision und Abdruck der Felder, die eine Meldung wert sind.
class TerminAbdruck {
  final int rev;
  final String abdruck;
  const TerminAbdruck(this.rev, this.abdruck);
}

typedef TerminStand = Map<String, TerminAbdruck>;

/// Abdruck der Felder, deren Änderung gemeldet wird (Titel, Ort, Zeit, Wiederholung). Farbe, Erinnerung und Beschreibung melden nichts.
String terminAbdruck(Termin t) => [
  t.titel,
  t.ort,
  t.ganztaegig ? '1' : '0',
  t.startUtc?.millisecondsSinceEpoch ?? '',
  t.endUtc?.millisecondsSinceEpoch ?? '',
  t.tzid ?? '',
  t.startDate ?? '',
  t.endDate ?? '',
  t.rrule ?? '',
].join('\u0001');

TerminStand terminStandAus(Iterable<Termin> termine) => {for (final t in termine) t.id: TerminAbdruck(t.rev, terminAbdruck(t))};

/// Ein gemeldeter Termin (der Titel wird nur gezeigt, wenn die Person es erlaubt hat).
class TerminTreffer {
  final String id;
  final String titel;
  final bool neu;
  const TerminTreffer(this.id, this.titel, {required this.neu});
}

/// Neue und geänderte Termine anderer Personen seit [vorher].
/// - nur Termine, deren Revision über [basisRev] liegt (der Lauf hat sie gebracht) und die sich gegenüber [vorher] wirklich verändert haben,
/// - nie eigene Termine ([ich] ist Besitzer), nie Geburtstage; Termine, die der Server der Person nicht zeigt, stehen gar nicht in [jetzt].
List<TerminTreffer> terminTreffer({required TerminStand vorher, required Iterable<Termin> jetzt, required String? ich, required int basisRev}) {
  if (ich == null) return const [];
  final out = <TerminTreffer>[];
  for (final t in jetzt) {
    if (t.ownerId == ich) continue;
    if (hatGeburtstagsMarke(t)) continue;
    if (t.rev <= basisRev) continue;
    final alt = vorher[t.id];
    if (alt == null) {
      out.add(TerminTreffer(t.id, t.titel, neu: true));
    } else if (t.rev > alt.rev && alt.abdruck != terminAbdruck(t)) {
      out.add(TerminTreffer(t.id, t.titel, neu: false));
    }
  }
  return out;
}

/// Text der Benachrichtigung: Überschrift und Zeile. [mitTitel]: der Titel eines einzelnen Termins darf erscheinen (Einstellung "Titel zeigen").
/// Mehrere Termine werden immer zu EINER Meldung zusammengefasst und nennen nur die Zahl.
({String titel, String text}) terminHinweisText(List<TerminTreffer> treffer, {required bool mitTitel}) {
  final neu = treffer.where((t) => t.neu).length;
  final geaendert = treffer.length - neu;
  if (treffer.length == 1) {
    final t = treffer.first;
    final kopf = t.neu ? 'Ein neuer Termin' : 'Ein Termin wurde geändert';
    final titel = t.titel.trim();
    return (titel: kopf, text: mitTitel && titel.isNotEmpty ? titel : 'Im Kalender ansehen');
  }
  final String kopf;
  if (geaendert == 0) {
    kopf = '$neu neue Termine';
  } else if (neu == 0) {
    kopf = '$geaendert Termine geändert';
  } else {
    kopf = '${treffer.length} Termine neu oder geändert';
  }
  return (titel: kopf, text: 'Im Kalender ansehen');
}

/// Neutraler Text für den Browser (nie Titel, Name oder Ort, auch nicht mit "Titel zeigen"; wie die Web-Erinnerungen).
String terminHinweisWebText(List<TerminTreffer> treffer) {
  final neu = treffer.where((t) => t.neu).length;
  final geaendert = treffer.length - neu;
  if (treffer.length == 1) return treffer.first.neu ? 'Kalender: Ein neuer Termin' : 'Kalender: Ein Termin wurde geändert';
  if (geaendert == 0) return 'Kalender: $neu neue Termine';
  if (neu == 0) return 'Kalender: $geaendert Termine geändert';
  return 'Kalender: ${treffer.length} Termine neu oder geändert';
}
