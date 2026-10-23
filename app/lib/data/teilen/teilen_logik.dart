// Teilen aus anderen Apps (Android, "Teilen mit lx-familyhub"): reine Logik für den angenommenen Text. Nur Text, nie Bilder oder Dateien. Der Text wird hart gekürzt, von
// Steuerzeichen befreit und für die Ziele (Listeneintrag, Aufgabe, Chat-Nachricht) in die jeweils erlaubte Form gebracht. Nichts davon wird protokolliert.

/// Längster angenommener Text in Zeichen (wie `MAX_TEILEN_ZEICHEN` in MainActivity.kt und die Obergrenze einer Chat-Nachricht).
const kMaxTeilenZeichen = 4000;

/// Obergrenzen der Ziele (wie am Server): Listeneintrag 500, Aufgabentitel 200, Aufgabennotiz 4000 Zeichen.
const kMaxEintragZeichen = 500;
const kMaxAufgabeTitelZeichen = 200;

/// Wohin der Text soll.
enum TeilenZiel { liste, aufgabe, nachricht }

/// Nimmt den rohen Text von Android: Steuerzeichen (außer Zeilenumbruch und Tab, ein Wagenrücklauf fällt weg) und unsichtbare Formatzeichen entfernen, hart auf
/// [kMaxTeilenZeichen] kürzen (nicht mitten in einem Zeichen), Ränder abschneiden. null = nichts Brauchbares (leer oder nur Leerraum).
String? teilenKuerzen(String? roh) {
  if (roh == null) return null;
  final t = String.fromCharCodes([
    for (final r in roh.runes)
      if (!_unerwuenscht(r)) r,
  ]).trim();
  if (t.isEmpty) return null;
  final zeichen = t.runes.toList();
  return zeichen.length > kMaxTeilenZeichen ? String.fromCharCodes(zeichen.take(kMaxTeilenZeichen)) : t;
}

/// Steuerzeichen (außer Zeilenumbruch und Tab), Nullbyte, Löschzeichen sowie unsichtbare Format- und Richtungszeichen (Zero-Width, Bidi-Steuerung, Byte-Order-Mark).
bool _unerwuenscht(int r) =>
    (r < 0x20 && r != 0x0a && r != 0x09) ||
    r == 0x7f ||
    (r >= 0x80 && r <= 0x9f) ||
    (r >= 0x200b && r <= 0x200f) ||
    (r >= 0x202a && r <= 0x202e) ||
    (r >= 0x2060 && r <= 0x2064) ||
    (r >= 0x2066 && r <= 0x2069) ||
    r == 0xfeff;

/// Ob die Kürzung auf [kMaxTeilenZeichen] gegriffen haben kann (der Text hat genau die Höchstlänge).
bool teilenWahrscheinlichGekuerzt(String text) => text.runes.length >= kMaxTeilenZeichen;

String _einzeilig(String t) => t.replaceAll(RegExp(r'\s+'), ' ').trim();

String _kuerze(String t, int max) {
  final z = t.runes.toList();
  return z.length <= max ? t : '${String.fromCharCodes(z.take(max - 1)).trimRight()}…';
}

/// Text für einen Listeneintrag: eine Zeile, höchstens [kMaxEintragZeichen].
String eintragsText(String text) => _kuerze(_einzeilig(text), kMaxEintragZeichen);

/// Vorschlag für den Aufgabentitel: die erste nicht leere Zeile, einzeilig, höchstens [kMaxAufgabeTitelZeichen].
String aufgabenTitel(String text) {
  final erste = text.split('\n').map(_einzeilig).firstWhere((z) => z.isNotEmpty, orElse: () => '');
  return _kuerze(erste, kMaxAufgabeTitelZeichen);
}

/// Notiz der Aufgabe: der ganze Text, wenn mehr als der Titel darin steht (mehrere Zeilen oder der Titel wurde gekürzt), sonst leer.
String aufgabenNotiz(String text, String titel) {
  final einzeilig = _einzeilig(text);
  if (!text.contains('\n') && einzeilig == titel) return '';
  return text;
}

/// Kurze Vorschau für die Auswahlseite (höchstens [max] Zeichen, mehrere Zeilen bleiben erhalten).
String teilenVorschau(String text, {int max = 280}) => _kuerze(text, max);
