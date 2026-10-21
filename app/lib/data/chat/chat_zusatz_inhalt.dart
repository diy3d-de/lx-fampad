// Klartext-Formate der Chat-Erweiterungen (Reaktionen, Umfragen, Stimmen). Der Server sieht nie etwas davon: Reaktion und Stimme liegen als e1-Hülle vor, die Umfrage steckt
// in der verschlüsselten Nachricht. Alles Folgende gilt für den Klartext NACH dem Entschlüsseln und ist bewusst streng und tolerant zugleich: unbekannte oder
// kaputte Inhalte werden übersprungen, nie angezeigt oder gerechnet.
//
//  - Reaktion:  `r1:` + ein Emoji (höchstens [kMaxEmojiEinheiten] UTF-16-Einheiten, keine Leer- und Steuerzeichen).
//  - Stimme:    `s1:` + durch Komma getrennte Optionsnummern (0-basiert), z. B. `s1:0,2`; keine Auswahl = die Stimme wird gelöscht, nie leer gespeichert.
//  - Umfrage:   eine ganz normale Chat-Nachricht mit mehrzeiligem Text, den ÄLTERE App-Versionen unverändert als Text zeigen (sie kennen keine Umfragen):
//                 📊 Umfrage: <Frage>
//                 • <Option 1>
//                 • <Option 2>
//                 Zum Abstimmen bitte die App aktualisieren.
//                 <U+2063>u1;m=1;e=<Ende als Millisekunden seit 1970, optional>
//               Die letzte Zeile (beginnt mit dem unsichtbaren Zeichen U+2063) trägt die Einstellungen: `m=1` Mehrfachauswahl, `e=` Ende.
import '../app_database.dart';

const kReaktionPraefix = 'r1:';
const kStimmePraefix = 's1:';

/// Auswahl der Schnellreaktionen (System-Emoji, keine Pakete oder Schriften aus dem Netz).
const kReaktionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Größte Länge eines Emojis (UTF-16-Einheiten; Familien-Emoji und Flaggen sind lang, normale Auswahl ist kurz).
const kMaxEmojiEinheiten = 16;

/// Umfrage: Grenzen der Eingabe.
const kMaxUmfrageFrage = 200;
const kMaxUmfrageOption = 60;
const kMinUmfrageOptionen = 2;
const kMaxUmfrageOptionen = 6;

const _umfrageKopf = '📊 Umfrage: ';
const _umfrageHinweis = 'Zum Abstimmen bitte die App aktualisieren.';
const _umfrageMarke = '⁣u1;';

/// Ein Emoji als Klartext einer Reaktion.
String reaktionKodieren(String emoji) => '$kReaktionPraefix$emoji';

bool _emojiGueltig(String e) {
  if (e.isEmpty || e.length > kMaxEmojiEinheiten) return false;
  for (final r in e.runes) {
    if (r <= 0x20 || (r >= 0x7f && r <= 0xa0) || r == 0x2028 || r == 0x2029) return false; // Leerzeichen, Steuer- und Zeilentrennzeichen
  }
  return true;
}

/// Das Emoji einer Reaktion; null bei jedem anderen oder ungültigen Inhalt.
String? reaktionLesen(String klartext) {
  if (!klartext.startsWith(kReaktionPraefix)) return null;
  final e = klartext.substring(kReaktionPraefix.length);
  return _emojiGueltig(e) ? e : null;
}

/// Gewählte Optionen als Klartext einer Stimme (aufsteigend, ohne Doppelte).
String stimmeKodieren(Iterable<int> optionen) => '$kStimmePraefix${(optionen.toSet().toList()..sort()).join(',')}';

/// Gewählte Optionen einer Stimme; null bei ungültigem Inhalt oder einer Nummer außerhalb von 0 bis [anzahl]-1. Bei Einzelwahl zählt nur genau eine Option.
Set<int>? stimmeLesen(String klartext, int anzahl, {required bool mehrfach}) {
  if (!klartext.startsWith(kStimmePraefix)) return null;
  final rest = klartext.substring(kStimmePraefix.length);
  if (rest.isEmpty) return null;
  final out = <int>{};
  for (final t in rest.split(',')) {
    final n = int.tryParse(t);
    if (n == null || n < 0 || n >= anzahl || '$n' != t) return null;
    out.add(n);
  }
  if (!mehrfach && out.length != 1) return null;
  return out;
}

/// Eine Umfrage (die Nachricht mit dem Format oben).
class Umfrage {
  final String frage;
  final List<String> optionen;
  final bool mehrfach;

  /// Ende (lokal); null = ohne Ende.
  final DateTime? ende;
  const Umfrage({required this.frage, required this.optionen, required this.mehrfach, this.ende});

  bool beendet(DateTime jetzt) => ende != null && !jetzt.isBefore(ende!);
}

String _einzeilig(String t) => t.replaceAll(RegExp(r'[\u0000-\u001f\u007f  ⁣]+'), ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();

/// Prüft eine Eingabe (Frage, Optionen). Liefert null, wenn alles passt, sonst einen deutschen Hinweis.
String? umfrageFehler(String frage, List<String> optionen) {
  final f = _einzeilig(frage);
  if (f.isEmpty) return 'Gib eine Frage ein.';
  if (f.length > kMaxUmfrageFrage) return 'Die Frage ist zu lang.';
  final o = [for (final x in optionen) _einzeilig(x)].where((x) => x.isNotEmpty).toList();
  if (o.length < kMinUmfrageOptionen) return 'Gib mindestens $kMinUmfrageOptionen Antworten ein.';
  if (o.length > kMaxUmfrageOptionen) return 'Es sind höchstens $kMaxUmfrageOptionen Antworten möglich.';
  if (o.any((x) => x.length > kMaxUmfrageOption)) return 'Eine Antwort ist zu lang.';
  if (o.map((x) => x.toLowerCase()).toSet().length != o.length) return 'Die Antworten müssen sich unterscheiden.';
  return null;
}

/// Klartext der Nachricht für eine Umfrage. Leere Antworten entfallen; ungültige Eingaben prüft [umfrageFehler] vorher.
String umfrageKodieren({required String frage, required List<String> optionen, required bool mehrfach, DateTime? ende}) {
  final o = [for (final x in optionen) _einzeilig(x)].where((x) => x.isNotEmpty);
  final marke = StringBuffer(_umfrageMarke)..write('m=${mehrfach ? 1 : 0}');
  if (ende != null) marke.write(';e=${ende.millisecondsSinceEpoch}');
  return [
    '$_umfrageKopf${_einzeilig(frage)}',
    for (final x in o) '• $x',
    _umfrageHinweis,
    marke.toString(),
  ].join('\n');
}

/// Liest eine Umfrage aus dem Klartext einer Nachricht; null, wenn die Nachricht keine (gültige) Umfrage ist.
Umfrage? umfrageLesen(String klartext) {
  if (!klartext.startsWith(_umfrageKopf)) return null;
  final zeilen = klartext.split('\n');
  if (zeilen.length < kMinUmfrageOptionen + 3) return null;
  final marke = zeilen.last;
  if (!marke.startsWith(_umfrageMarke) || zeilen[zeilen.length - 2] != _umfrageHinweis) return null;
  final frage = zeilen.first.substring(_umfrageKopf.length).trim();
  final optionen = <String>[];
  for (final z in zeilen.sublist(1, zeilen.length - 2)) {
    if (!z.startsWith('• ')) return null;
    optionen.add(z.substring(2).trim());
  }
  if (frage.isEmpty || optionen.length < kMinUmfrageOptionen || optionen.length > kMaxUmfrageOptionen || optionen.any((o) => o.isEmpty)) return null;
  var mehrfach = false;
  DateTime? ende;
  for (final teil in marke.substring(_umfrageMarke.length).split(';')) {
    final kv = teil.split('=');
    if (kv.length != 2) continue;
    if (kv[0] == 'm') mehrfach = kv[1] == '1';
    if (kv[0] == 'e') {
      final ms = int.tryParse(kv[1]);
      if (ms != null && ms > 0 && ms < 8640000000000000) ende = DateTime.fromMillisecondsSinceEpoch(ms);
    }
  }
  return Umfrage(frage: frage, optionen: optionen, mehrfach: mehrfach, ende: ende);
}

/// Kurzer Text einer Umfrage für Listen, Zitate und Vorschau.
String umfrageKurztext(Umfrage u) => '📊 ${u.frage}';

/// Eine Reaktion in der Anzeige: ein Emoji mit allen Personen, die es gewählt haben.
class ReaktionGruppe {
  final String emoji;
  final List<String> personen;
  final bool ich;
  const ReaktionGruppe({required this.emoji, required this.personen, required this.ich});
  int get anzahl => personen.length;
}

/// Gruppiert die lesbaren Reaktionen je Nachricht nach Emoji (die meistgewählten zuerst, bei Gleichstand nach erster Wahl). [inhalt] liefert den Klartext einer
/// Reaktion oder null, solange sie nicht lesbar ist (nicht lesbare werden übersprungen, nie als Platzhalter gezeigt).
Map<String, List<ReaktionGruppe>> gruppiereReaktionen(Iterable<Reaktion> zeilen, String? Function(Reaktion) inhalt, String? ich) {
  final nachNachricht = <String, Map<String, List<String>>>{};
  final sortiert = zeilen.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt) != 0 ? a.createdAt.compareTo(b.createdAt) : a.id.compareTo(b.id));
  for (final r in sortiert) {
    final klar = inhalt(r);
    final emoji = klar == null ? null : reaktionLesen(klar);
    if (emoji == null) continue;
    (nachNachricht[r.nachrichtId] ??= {}).putIfAbsent(emoji, () => []).add(r.userId);
  }
  return {
    for (final e in nachNachricht.entries)
      e.key: [
        for (final g in e.value.entries) ReaktionGruppe(emoji: g.key, personen: g.value, ich: ich != null && g.value.contains(ich)),
      ]..sort((a, b) => b.anzahl.compareTo(a.anzahl)),
  };
}

/// Stand einer Umfrage.
class UmfrageErgebnis {
  /// Personen je Option (Index), in der Reihenfolge der Stimmabgabe.
  final List<List<String>> waehler;

  /// Optionen, die die angemeldete Person gewählt hat.
  final Set<int> meine;

  /// Anzahl der Personen, die abgestimmt haben.
  final int abstimmende;
  const UmfrageErgebnis({required this.waehler, required this.meine, required this.abstimmende});

  int stimmen(int option) => waehler[option].length;
}

/// Wertet die Stimmen einer Umfrage aus. Eine Stimme zählt nur, wenn sie lesbar und gültig ist (Optionen im Bereich, bei Einzelwahl genau eine) und nicht NACH dem
/// Ende der Umfrage abgegeben oder geändert wurde (Zeit des Servers: [Stimme.geaendertAt], sonst Anlegen). [inhalt] liefert den Klartext oder null.
UmfrageErgebnis umfrageAuswerten(Umfrage u, Iterable<Stimme> stimmen, String? Function(Stimme) inhalt, String? ich) {
  final waehler = [for (final _ in u.optionen) <String>[]];
  final meine = <int>{};
  var abstimmende = 0;
  final sortiert = stimmen.toList()..sort((a, b) => (a.geaendertAt ?? a.createdAt).compareTo(b.geaendertAt ?? b.createdAt));
  for (final s in sortiert) {
    final zeit = s.geaendertAt ?? s.createdAt;
    if (u.ende != null && zeit.isAfter(u.ende!)) continue;
    final klar = inhalt(s);
    final auswahl = klar == null ? null : stimmeLesen(klar, u.optionen.length, mehrfach: u.mehrfach);
    if (auswahl == null) continue;
    abstimmende++;
    for (final o in auswahl) {
      waehler[o].add(s.userId);
    }
    if (ich != null && s.userId == ich) meine.addAll(auswahl);
  }
  return UmfrageErgebnis(waehler: waehler, meine: meine, abstimmende: abstimmende);
}
