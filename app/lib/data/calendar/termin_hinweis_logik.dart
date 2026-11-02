// Hinweise auf neue und geänderte Termine anderer Personen (rein, ohne Datenbank und Plattform). Das Gerät erkennt lokal nach dem Abgleich, was
// die anderen Geräte der Familie neu angelegt oder verändert haben; nichts davon geht über den Server oder den Wecker (der Wecker enthält nie Inhalt).
//
// Grundlage ist ein Abdruck je betroffenem Termin VOR dem Einarbeiten der Serverantwort (siehe termin_hinweis_dienst.dart). Der Abdruck umfasst die Felder des
// Termins UND seine Ausnahmen ("nur dieses Vorkommen"). Eigene Änderungen (Termine mit offenem oder im Lauf gesendetem Ausgang) lösen nichts aus.
import '../app_database.dart';
import 'geburtstag.dart' show hatGeburtstagsMarke;

/// Nutzlast der Benachrichtigung: ein Tipp öffnet den Kalender.
const kTerminHinweisPayload = 'termine';

bool istTerminHinweisPayload(String? payload) => payload == kTerminHinweisPayload;

/// Höchstzahl der Zeichen eines fremden Titels in der Benachrichtigung.
const kTerminHinweisTitelMax = 80;

/// Abdruck der Felder, deren Änderung gemeldet wird (Titel, Ort, Zeit, Wiederholung) samt allen Ausnahmen der Serie.
/// Farbe, Erinnerung und Beschreibung melden nichts.
String terminAbdruck(Termin t, Iterable<TerminAusnahme> ausnahmen) {
  final a = [for (final x in ausnahmen) [x.id, x.originalStart, x.abgesagt ? '1' : '0', x.titel ?? '', x.start ?? '', x.ende ?? '', x.ort ?? ''].join('\u0002')]..sort();
  return [
    t.titel,
    t.ort,
    t.ganztaegig ? '1' : '0',
    t.startUtc?.millisecondsSinceEpoch ?? '',
    t.endUtc?.millisecondsSinceEpoch ?? '',
    t.tzid ?? '',
    t.startDate ?? '',
    t.endDate ?? '',
    t.rrule ?? '',
    ...a,
  ].join('\u0001');
}

/// Ein gemeldeter Termin (der Titel wird nur gezeigt, wenn die Person es erlaubt hat).
class TerminTreffer {
  final String id;
  final String titel;
  final bool neu;
  final String? ownerId;

  /// Termin mit Wiederholungsregel (zum Zusammenfassen von "Serie gekürzt + neue Serie").
  final bool serie;
  const TerminTreffer(this.id, this.titel, {required this.neu, this.ownerId, this.serie = false});
}

/// Neue und geänderte Termine seit dem Stand [vorher] (Termin-ID -> Abdruck vorher, `null` = gab es lokal nicht).
/// [jetzt]: heutiger Stand der betroffenen Termine mit Abdruck; ein Termin, der fehlt (gelöscht, nicht mehr sichtbar), meldet nichts.
/// [eigene]: Termine, die diese Person selbst geändert hat (Ausgang): nie melden. Geburtstage melden nie.
/// Das Paar "alte Serie gekürzt + neue Serie" (gleicher Titel und Besitzer) ergibt EINEN Treffer.
List<TerminTreffer> terminTreffer({
  required Map<String, String?> vorher,
  required Map<String, ({Termin termin, String abdruck})> jetzt,
  required Set<String> eigene,
}) {
  final out = <TerminTreffer>[];
  for (final e in vorher.entries) {
    final j = jetzt[e.key];
    if (j == null || eigene.contains(e.key) || hatGeburtstagsMarke(j.termin)) continue;
    final t = j.termin;
    final serie = (t.rrule ?? '').isNotEmpty;
    if (e.value == null) {
      out.add(TerminTreffer(t.id, t.titel, neu: true, ownerId: t.ownerId, serie: serie));
    } else if (e.value != j.abdruck) {
      out.add(TerminTreffer(t.id, t.titel, neu: false, ownerId: t.ownerId, serie: serie));
    }
  }
  // "Dieses und folgende ändern": die alte Serie wird gekürzt, eine neue entsteht; für die Person ist das ein Termin
  return [
    for (final t in out)
      if (!(t.neu && t.serie && out.any((g) => !g.neu && g.serie && g.titel == t.titel && g.ownerId == t.ownerId))) t,
  ];
}

/// Unsichtbare Format- und Richtungszeichen (Bidi, Null-Breite, Zeilen-/Absatztrenner): fliegen aus einem fremden Titel ganz heraus (Steuerzeichen werden zu Leerraum).
bool _formatZeichen(int c) =>
    c == 0xad || c == 0x61c || c == 0x180e || (c >= 0x200b && c <= 0x200f) || (c >= 0x2028 && c <= 0x202e) || (c >= 0x2060 && c <= 0x206f) || c == 0xfeff || (c >= 0xfff9 && c <= 0xfffb);

/// Fremder Titel für die Benachrichtigung: ohne Steuer-, Format- und Richtungszeichen (Bidi), Leerraum zusammengezogen, höchstens
/// [kTerminHinweisTitelMax] Zeichen.
String terminHinweisTitel(String roh) {
  final s = String.fromCharCodes([for (final c in roh.runes) if (!_formatZeichen(c)) c < 0x20 || (c >= 0x7f && c <= 0x9f) ? 0x20 : c]).replaceAll(RegExp(r'\s+'), ' ').trim();
  final zeichen = s.runes.toList();
  if (zeichen.length <= kTerminHinweisTitelMax) return s;
  return '${String.fromCharCodes(zeichen.take(kTerminHinweisTitelMax - 1)).trimRight()}…';
}

/// Text der Benachrichtigung: Überschrift und Zeile. [mitTitel]: der Titel eines einzelnen Termins darf erscheinen (Einstellung "Titel zeigen").
/// Mehrere Termine werden immer zu EINER Meldung zusammengefasst und nennen nur die Zahl.
({String titel, String text}) terminHinweisText(List<TerminTreffer> treffer, {required bool mitTitel}) {
  final neu = treffer.where((t) => t.neu).length;
  final geaendert = treffer.length - neu;
  if (treffer.length == 1) {
    final t = treffer.first;
    final kopf = t.neu ? 'Ein neuer Termin' : 'Ein Termin wurde geändert';
    final titel = terminHinweisTitel(t.titel);
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

/// Neutraler Text auch für die öffentliche Version auf dem Sperrbildschirm und für den Browser (nie Titel, Name oder Ort).
String terminHinweisWebText(List<TerminTreffer> treffer) {
  final neu = treffer.where((t) => t.neu).length;
  final geaendert = treffer.length - neu;
  if (treffer.length == 1) return treffer.first.neu ? 'Kalender: Ein neuer Termin' : 'Kalender: Ein Termin wurde geändert';
  if (geaendert == 0) return 'Kalender: $neu neue Termine';
  if (neu == 0) return 'Kalender: $geaendert Termine geändert';
  return 'Kalender: ${treffer.length} Termine neu oder geändert';
}
