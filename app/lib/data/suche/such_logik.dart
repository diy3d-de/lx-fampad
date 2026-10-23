// Reine Suchlogik (ohne Datenbank, ohne Oberfläche): Normalisierung, Teilwort-Suche mit mehreren Wörtern, Treffer-Bereiche für die Hervorhebung,
// Ausschnitte. Alles läuft im Arbeitsspeicher auf Texten, die das Gerät ohnehin lokal hält; nichts wird gemerkt, gespeichert oder gesendet.

/// Ein hervorzuhebender Abschnitt im ORIGINALTEXT: [start] (einschließlich) bis [ende] (ausschließlich), in UTF-16-Einheiten.
class TextBereich {
  final int start;
  final int ende;
  const TextBereich(this.start, this.ende);

  @override
  bool operator ==(Object other) => other is TextBereich && other.start == start && other.ende == ende;

  @override
  int get hashCode => Object.hash(start, ende);

  @override
  String toString() => '[$start,$ende)';
}

/// Ersetzungen bei der Normalisierung: Kleinschreibung, übliche Akzente ohne Zeichen, ß = ss. Umlaute je nach Modus als Zweierfolge (ä = ae)
/// oder als Grundbuchstabe (ä = a); gesucht wird mit beiden (siehe [Suchtext]).
const _ersatz = <String, String>{
  'ß': 'ss',
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u',
  'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y',
};

const _umlauteE = <String, String>{'ä': 'ae', 'ö': 'oe', 'ü': 'ue'};
const _umlauteA = <String, String>{'ä': 'a', 'ö': 'o', 'ü': 'u'};

/// Normalisierter Text und die Zuordnung jeder normalisierten Stelle zurück zum Originaltext.
class NormText {
  final String norm;
  final List<int> _herkunft;
  NormText._(this.norm, this._herkunft);

  factory NormText(String original, {bool umlautAlsE = true}) {
    final umlaute = umlautAlsE ? _umlauteE : _umlauteA;
    final b = StringBuffer();
    final h = <int>[];
    for (var i = 0; i < original.length; i++) {
      final z = original[i].toLowerCase();
      final e = umlaute[z] ?? _ersatz[z] ?? z;
      for (var k = 0; k < e.length; k++) {
        b.write(e[k]);
        h.add(i);
      }
    }
    return NormText._(b.toString(), h);
  }

  /// Bereich der normalisierten Stellen [von, bis) im Originaltext (ganze Originalzeichen).
  TextBereich original(int von, int bis) => TextBereich(_herkunft[von], _herkunft[bis - 1] + 1);
}

/// Normalisiert nur den Text (Umlaute als ae/oe/ue).
String normalisiere(String s) => NormText(s).norm;

/// Ein Text, in dem Wörter gesucht werden: ein Wort gilt als gefunden, wenn es mit Umlauten als ae/oe/ue ODER als Grundbuchstabe passt
/// ("Äpfel" ist mit "äpfel", "aepfel" und "apfel" zu finden, "Baeckerei" mit "bäcker").
class Suchtext {
  final String original;
  late final NormText _e = NormText(original);
  late final NormText _a = NormText(original, umlautAlsE: false);
  Suchtext(this.original);

  /// Bereiche aller Vorkommen des (rohen) Wortes im Originaltext; null = kommt nicht vor.
  List<TextBereich>? wort(String roh) {
    for (final e in [true, false]) {
      final n = e ? _e : _a;
      final w = NormText(roh, umlautAlsE: e).norm;
      if (w.isEmpty) continue;
      var pos = n.norm.indexOf(w);
      if (pos < 0) continue;
      final b = <TextBereich>[];
      while (pos >= 0) {
        b.add(n.original(pos, pos + w.length));
        pos = n.norm.indexOf(w, pos + w.length);
      }
      return b;
    }
    return null;
  }
}

/// Zerlegt die Eingabe in Suchwörter (Leerraum trennt, klein geschrieben); leer, wenn nichts Suchbares eingegeben ist. Höchstens 8 Wörter.
List<String> suchWoerter(String eingabe) {
  final w = eingabe.toLowerCase().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  return w.length > 8 ? w.sublist(0, 8) : w;
}

/// Sucht alle [woerter] (jedes muss als Teilwort vorkommen, Reihenfolge egal) im [text]. null = mindestens ein Wort fehlt;
/// sonst die zusammengeführten Bereiche aller Vorkommen im Originaltext.
List<TextBereich>? finde(String text, List<String> woerter) {
  if (woerter.isEmpty) return null;
  final t = Suchtext(text);
  final bereiche = <TextBereich>[];
  for (final w in woerter) {
    final b = t.wort(w);
    if (b == null) return null;
    bereiche.addAll(b);
  }
  return zusammenfuehren(bereiche);
}

/// Prüft nur, ob alle Wörter vorkommen.
bool enthaeltAlle(String text, List<String> woerter) => finde(text, woerter) != null;

/// Sortiert Bereiche und fasst überlappende oder aneinanderstoßende zusammen.
List<TextBereich> zusammenfuehren(List<TextBereich> bereiche) {
  if (bereiche.isEmpty) return const [];
  final s = [...bereiche]..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.ende.compareTo(b.ende));
  final r = <TextBereich>[s.first];
  for (final b in s.skip(1)) {
    final l = r.last;
    if (b.start <= l.ende) {
      if (b.ende > l.ende) r[r.length - 1] = TextBereich(l.start, b.ende);
    } else {
      r.add(b);
    }
  }
  return r;
}

/// Ein Ausschnitt aus einem Text mit den Bereichen darin (bezogen auf [text]).
class Ausschnitt {
  final String text;
  final List<TextBereich> bereiche;
  const Ausschnitt(this.text, this.bereiche);
}

/// Kürzt [text] auf höchstens etwa [max] Zeichen rund um den ersten Treffer (mit "…" an den Schnittstellen). Zeilenumbrüche werden zu Leerzeichen
/// (gleiche Länge, die Bereiche bleiben gültig). Ohne Treffer: der Anfang.
Ausschnitt ausschnitt(String text, List<TextBereich> bereiche, {int max = 120}) {
  final flach = text.replaceAll(RegExp(r'[\r\n\t]'), ' ');
  if (flach.length <= max) return Ausschnitt(flach, bereiche);
  var von = 0;
  if (bereiche.isNotEmpty) {
    von = bereiche.first.start - (max ~/ 4);
    if (von < 0) von = 0;
  }
  var bis = von + max;
  if (bis > flach.length) {
    bis = flach.length;
    von = (bis - max).clamp(0, flach.length);
  }
  final vorn = von > 0 ? '…' : '';
  final hinten = bis < flach.length ? '…' : '';
  final teil = '$vorn${flach.substring(von, bis)}$hinten';
  final versatz = vorn.length - von;
  final neu = <TextBereich>[];
  for (final b in bereiche) {
    if (b.ende <= von || b.start >= bis) continue;
    final s = (b.start < von ? von : b.start) + versatz;
    final e = (b.ende > bis ? bis : b.ende) + versatz;
    neu.add(TextBereich(s, e));
  }
  return Ausschnitt(teil, neu);
}
