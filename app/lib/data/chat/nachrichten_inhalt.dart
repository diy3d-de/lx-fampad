// Inhalt von Nachrichten (und Gruppennamen) in der Schnittstelle: für den Server ein undurchsichtiger Text, für die App eine Hülle mit
// Versionspräfix. Heute `p1:` + Klartext; mit der Ende-zu-Ende-Verschlüsselung (später) `e1:` + Base64-Chiffre. Alles, was Inhalte
// schreibt oder liest, geht über [NachrichtenInhalt]; die Oberfläche kennt nur [DekodierterInhalt] und seinen Zustand.
// Der Server prüft nur Länge und Zeichensatz (sync/entities/chat.ts), wertet nichts aus und zeigt nichts vor.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wie weit ein Inhalt lesbar ist.
enum InhaltStatus {
  /// Text liegt vor.
  bereit,

  /// Die Entschlüsselung läuft noch (Ende-zu-Ende, später).
  wirdEntschluesselt,

  /// Der Inhalt ist verschlüsselt oder stammt aus einer neueren App-Version, der passende Schlüssel fehlt (noch).
  nichtEntschluesselbar,
}

class DekodierterInhalt {
  final String text;
  final InhaltStatus status;
  const DekodierterInhalt(this.text, this.status);

  bool get lesbar => status == InhaltStatus.bereit;
}

/// Größte Nachricht in Zeichen (Klartext, vor dem Kodieren); der Server erlaubt mehr, damit die Hülle der Verschlüsselung Platz hat.
const kMaxNachrichtenZeichen = 4000;

/// Größter Gruppenname in Zeichen.
const kMaxChatNameZeichen = 60;

abstract class NachrichtenInhalt {
  /// Klartext -> Text der Schnittstelle.
  String kodieren(String text);

  /// Text der Schnittstelle -> lesbarer Inhalt (oder ein Zustand, warum nicht). Leer bleibt leer (z. B. Gruppe ohne Namen).
  DekodierterInhalt dekodieren(String wire);
}

/// Heutige Hülle: `p1:` + Klartext. `e1:` (verschlüsselt) und unbekannte Versionen gelten als nicht lesbar.
class KlartextHuelle implements NachrichtenInhalt {
  const KlartextHuelle();

  static const praefix = 'p1:';

  @override
  String kodieren(String text) => text.isEmpty ? '' : '$praefix$text';

  @override
  DekodierterInhalt dekodieren(String wire) {
    if (wire.isEmpty) return const DekodierterInhalt('', InhaltStatus.bereit);
    if (wire.startsWith(praefix)) return DekodierterInhalt(wire.substring(praefix.length), InhaltStatus.bereit);
    return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar);
  }
}

/// Austauschpunkt für die spätere Ende-zu-Ende-Verschlüsselung.
final nachrichtenInhaltProvider = Provider<NachrichtenInhalt>((ref) => const KlartextHuelle());
