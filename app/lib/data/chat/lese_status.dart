// Lesebestätigung an eigenen Nachrichten (Haken wie bei WhatsApp). Grundlage sind nur die bestehenden Lesestände der Teilnehmer
// (`lesestand`: je Person und Chat der Zeitpunkt der zuletzt gelesenen Nachricht); es gibt kein eigenes Protokoll und keine zusätzlichen Metadaten.
// Der Lesestand ist für die Teilnehmer des Chats sichtbar (Datenschutz-Entwurf), die Lesebestätigung lässt sich nicht abschalten.
import '../app_database.dart';

enum LeseZustand {
  /// Noch nicht beim Server (Uhr).
  wirdGesendet,

  /// Beim Server angekommen (ein Haken).
  gesendet,

  /// Alle anderen Teilnehmer haben gelesen (zwei Haken).
  gelesen,
}

class LeseInfo {
  final LeseZustand zustand;

  /// Personen, die die Nachricht gelesen haben (nur Teilnehmer, ohne die eigene Person).
  final Set<String> gelesenVon;

  /// Alle anderen Teilnehmer.
  final Set<String> empfaenger;
  const LeseInfo(this.zustand, this.gelesenVon, this.empfaenger);

  bool get teilweise => zustand == LeseZustand.gesendet && gelesenVon.isNotEmpty;
}

/// Zustand einer eigenen Nachricht. [empfaenger] sind die anderen Teilnehmer (Direktchat/Gruppe: Teilnehmerliste, Familienchat: alle aktiven Mitglieder) ohne
/// die eigene Person, [gelesenBis] der Lesestand je Person. Gelesen heißt: der Lesestand der Person ist mindestens so neu wie die Nachricht. Ohne Empfänger
/// (allein im Chat) bleibt es bei "gesendet".
LeseInfo leseInfo({required Nachricht nachricht, required Set<String> empfaenger, required Map<String, DateTime> gelesenBis}) {
  if (nachricht.rev <= 0) return LeseInfo(LeseZustand.wirdGesendet, const {}, empfaenger);
  final gelesen = {
    for (final p in empfaenger)
      if (gelesenBis[p] case final t? when !t.isBefore(nachricht.createdAt)) p,
  };
  final alle = empfaenger.isNotEmpty && gelesen.length == empfaenger.length;
  return LeseInfo(alle ? LeseZustand.gelesen : LeseZustand.gesendet, gelesen, empfaenger);
}

