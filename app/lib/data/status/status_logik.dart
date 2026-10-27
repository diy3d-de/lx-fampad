// Familien-Status (Abschnitt 6o): reine Logik ohne Oberfläche und ohne Speicher.
//  - Je Person ein kurzer Text (höchstens 60 Zeichen, ohne Steuer- und unsichtbare Zeichen, wie auf dem Server) und ein optionales Ende `bis`.
//  - Ob ein Status gilt, rechnet nur diese Datei gegen die Uhr: abgelaufene werden nirgends gezeigt, aber nicht gelöscht.
//  - Ablauf-Auswahl in der Wanduhr der Familienzeitzone (Europe/Berlin); der Server erlaubt höchstens 7 Tage.
import '../calendar/zeitzonen.dart';

const kStatusMaxZeichen = 60;

/// Weiter als so viele Tage in die Zukunft darf das Ende nicht liegen (Server: `STATUS_MAX_TAGE`).
const kStatusMaxTage = 7;

/// Schnellauswahl im Editor.
const kStatusVorschlaege = <String>['Beim Sport', 'Unterwegs', 'Lernen', 'Bitte nicht stören', 'Bei der Arbeit', 'Krank'];

/// Ein Status einer Person (nur das, was die Anzeige braucht).
class StatusEintrag {
  final String userId;
  final String text;

  /// Ende; null = ohne Ende (bis die Person ihn löscht).
  final DateTime? bis;
  const StatusEintrag({required this.userId, required this.text, this.bis});

  @override
  bool operator ==(Object other) => other is StatusEintrag && other.userId == userId && other.text == text && other.bis == bis;

  @override
  int get hashCode => Object.hash(userId, text, bis);
}

/// Gilt ein Status mit Ende [bis] zum Zeitpunkt [jetzt]? Ohne Ende immer; zum Ende selbst nicht mehr.
bool statusGilt(DateTime? bis, DateTime jetzt) => bis == null || bis.isAfter(jetzt);

/// Nur die geltenden Stati (ohne leeren Text), jede Person höchstens einmal, in der Reihenfolge der Eingabe.
List<StatusEintrag> geltendeStati(Iterable<StatusEintrag> alle, DateTime jetzt) {
  final gesehen = <String>{};
  return [
    for (final s in alle)
      if (s.text.trim().isNotEmpty && statusGilt(s.bis, jetzt) && gesehen.add(s.userId)) s,
  ];
}

/// Steuer-, Format- und Trennzeichen (Zeilenumbruch, Nullbreite, Richtungsmarken ...): wie auf dem Server nicht erlaubt.
bool _unzulaessig(int c) =>
    c <= 0x1f ||
    (c >= 0x7f && c <= 0x9f) ||
    c == 0xad ||
    c == 0x61c ||
    c == 0x180e ||
    (c >= 0x200b && c <= 0x200f) ||
    (c >= 0x2028 && c <= 0x202e) ||
    (c >= 0x2060 && c <= 0x206f) ||
    c == 0xfeff ||
    (c >= 0xfff9 && c <= 0xfffb);

/// Der Text, wie er gespeichert wird (ohne Leerraum an den Rändern), oder null, wenn er nicht gültig ist (leer, zu lang, unzulässige Zeichen).
/// Die Länge zählt wie auf dem Server in UTF-16-Einheiten.
String? statusTextPruefen(String eingabe) {
  final t = eingabe.trim();
  if (t.isEmpty || t.length > kStatusMaxZeichen) return null;
  if (t.runes.any(_unzulaessig)) return null;
  return t;
}

/// Wählbare Enden im Editor.
enum StatusAblauf {
  einStunde('In 1 Stunde'),
  dreiStunden('In 3 Stunden'),
  heuteAbend('Heute Abend, 22 Uhr'),
  morgenFrueh('Morgen früh, 7 Uhr'),
  ohneEnde('Ohne Ende, bis ich ihn lösche');

  final String label;
  const StatusAblauf(this.label);

  /// Das Ende ab [jetzt]; null = ohne Ende (und für [heuteAbend] nach 21 Uhr: dann gibt es die Auswahl nicht, siehe [statusAblaufOptionen]).
  DateTime? ende(DateTime jetzt) {
    switch (this) {
      case StatusAblauf.einStunde:
        return jetzt.add(const Duration(hours: 1));
      case StatusAblauf.dreiStunden:
        return jetzt.add(const Duration(hours: 3));
      case StatusAblauf.heuteAbend:
        final w = wandUhr(jetzt, familienOrt);
        return instantAusWand(DateTime.utc(w.year, w.month, w.day, 22), familienOrt);
      case StatusAblauf.morgenFrueh:
        // der nächste 7-Uhr-Zeitpunkt, der mindestens eine Stunde entfernt liegt (nachts also schon "heute früh")
        final w = wandUhr(jetzt, familienOrt);
        var tag = DateTime.utc(w.year, w.month, w.day, 7);
        var t = instantAusWand(tag, familienOrt);
        if (t.difference(jetzt) < const Duration(hours: 1)) {
          tag = DateTime.utc(w.year, w.month, w.day + 1, 7);
          t = instantAusWand(tag, familienOrt);
        }
        return t;
      case StatusAblauf.ohneEnde:
        return null;
    }
  }
}

/// Die zu [jetzt] sinnvollen Auswahlen: "Heute Abend" nur, wenn es noch mindestens eine Stunde bis 22 Uhr sind.
List<StatusAblauf> statusAblaufOptionen(DateTime jetzt) => [
  for (final a in StatusAblauf.values)
    if (a != StatusAblauf.heuteAbend || a.ende(jetzt)!.difference(jetzt) >= const Duration(hours: 1)) a,
];

const _wochentage = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

String _zwei(int n) => n.toString().padLeft(2, '0');

/// "bis 18:00", "bis morgen 07:00" oder "bis Mi 18:00" (Wanduhr der Familienzeitzone); ohne Ende: "ohne Ende".
String statusBisText(DateTime? bis, DateTime jetzt) {
  if (bis == null) return 'ohne Ende';
  final e = wandUhr(bis, familienOrt);
  final h = wandUhr(jetzt, familienOrt);
  final uhr = '${_zwei(e.hour)}:${_zwei(e.minute)}';
  final tage = DateTime.utc(e.year, e.month, e.day).difference(DateTime.utc(h.year, h.month, h.day)).inDays;
  if (tage <= 0) return 'bis $uhr';
  if (tage == 1) return 'bis morgen $uhr';
  return 'bis ${_wochentage[e.weekday - 1]} $uhr';
}
