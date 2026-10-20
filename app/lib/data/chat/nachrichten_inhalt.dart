// Inhalt von Nachrichten (und Gruppennamen) in der Schnittstelle: für den Server ein undurchsichtiger Text, für die App eine Hülle mit Versionspräfix.
//  - `e1:` + Base64url: Ende-zu-Ende verschlüsselte, signierte Nachricht (data/chat/chat_krypto.dart, Hülle in data/crypto/huelle.dart). Alle Chats sind so angelegt.
//  - `p1:` + Klartext: Gruppennamen (sichtbare Metadaten) und der Altbestand unverschlüsselter Chats. In einem verschlüsselten Chat gilt `p1:` NIE als lesbar.
//  - `l1:` + Klartext: nur lokal, im Ausgang einer noch nicht gesendeten Nachricht. Der Abgleich verschlüsselt sie vor dem Senden neu (mit der dann aktuellen
//    Epoche); der Server lehnt sie ab. Als Inhalt gilt sie nur für die noch nicht bestätigte eigene Nachricht auf diesem Gerät.
// Alles, was Inhalte schreibt oder liest, geht über [NachrichtenInhalt]; die Oberfläche kennt nur [DekodierterInhalt] und seinen Zustand.
// Der Server prüft nur Länge, Zeichensatz und Form (sync/entities/chat.ts), wertet nichts aus und zeigt nichts vor.
import '../app_database.dart';

export 'chat_krypto_state.dart' show nachrichtenInhaltProvider;

/// Wie weit ein Inhalt lesbar ist.
enum InhaltStatus {
  /// Text liegt vor.
  bereit,

  /// Die Entschlüsselung läuft noch.
  wirdEntschluesselt,

  /// Der Inhalt ist verschlüsselt oder stammt aus einer neueren App-Version, der passende Schlüssel fehlt (noch).
  nichtEntschluesselbar,
}

class DekodierterInhalt {
  final String text;
  final InhaltStatus status;

  /// Kurzer Grund, warum der Inhalt nicht lesbar ist ("warte auf Schlüssel", "Absender nicht bestätigt" ...); nie ein Inhalt.
  final String? hinweis;
  const DekodierterInhalt(this.text, this.status, {this.hinweis});

  bool get lesbar => status == InhaltStatus.bereit;
}

/// Größte Nachricht in Zeichen (Klartext, vor dem Kodieren). Zusätzlich gilt eine Grenze in UTF-8-Bytes (`kMaxNachrichtBytes`), damit die verschlüsselte
/// Hülle unter der Obergrenze des Servers bleibt.
const kMaxNachrichtenZeichen = 4000;

/// Größter Gruppenname in Zeichen.
const kMaxChatNameZeichen = 60;

abstract class NachrichtenInhalt {
  /// Klartext -> Text der Schnittstelle für Gruppennamen (`p1:`; Namen sind sichtbare Metadaten).
  String kodieren(String text);

  /// Text der Schnittstelle -> lesbarer Inhalt (nur `p1:`-Namen; Nachrichten gehen über [nachricht]). Leer bleibt leer (z. B. Gruppe ohne Namen).
  DekodierterInhalt dekodieren(String wire);

  /// Inhalt einer Nachricht. Verschlüsselte Nachrichten werden im Hintergrund geöffnet: bis dahin "wird entschlüsselt", danach der Text oder der Grund, warum
  /// nicht. Die Oberfläche baut sich neu auf, sobald sich etwas geändert hat (der Provider ändert sich).
  DekodierterInhalt nachricht(Nachricht n);
}

/// Namen und Klartext-Altbestand: `p1:` + Text. Verschlüsselte Nachrichten kann diese Hülle nicht lesen (die App benutzt [nachrichtenInhaltProvider]).
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

  @override
  DekodierterInhalt nachricht(Nachricht n) => dekodieren(n.inhalt);
}
