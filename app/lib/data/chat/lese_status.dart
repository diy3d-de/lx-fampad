// Lesebestätigung an eigenen Nachrichten (Haken wie bei WhatsApp). Grundlage sind nur die bestehenden Lesestände der Teilnehmer
// (`lesestand`: je Person und Chat der Zeitpunkt der zuletzt gelesenen Nachricht); es gibt kein eigenes Protokoll und keine zusätzlichen Metadaten.
// Der Lesestand ist für die Teilnehmer des Chats sichtbar (Datenschutz-Entwurf), die Lesebestätigung lässt sich nicht abschalten.
import '../app_database.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/epochen.dart';

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

  /// Die Empfänger zum Sendezeitpunkt waren nicht ableitbar (Epoche unbekannt): es zählen nur Teilnehmer mit vorhandenem Lesestand; die Anzeige weist darauf hin.
  final bool geschaetzt;
  const LeseInfo(this.zustand, this.gelesenVon, this.empfaenger, {this.geschaetzt = false});

  bool get teilweise => zustand == LeseZustand.gesendet && gelesenVon.isNotEmpty;
}

/// Zustand einer eigenen Nachricht. [empfaenger] sind die anderen Teilnehmer (Direktchat/Gruppe: Teilnehmerliste, Familienchat: alle aktiven Mitglieder) ohne
/// die eigene Person, [gelesenBis] der Lesestand je Person. Gelesen heißt: der Lesestand der Person ist mindestens so neu wie die Nachricht. Ohne Empfänger
/// (allein im Chat) bleibt es bei "gesendet".
LeseInfo leseInfo({required Nachricht nachricht, required Set<String> empfaenger, required Map<String, DateTime> gelesenBis, bool geschaetzt = false}) {
  if (nachricht.rev <= 0) return LeseInfo(LeseZustand.wirdGesendet, const {}, empfaenger, geschaetzt: geschaetzt);
  final gelesen = {
    for (final p in empfaenger)
      if (gelesenBis[p] case final t? when !t.isBefore(nachricht.createdAt)) p,
  };
  final alle = empfaenger.isNotEmpty && gelesen.length == empfaenger.length;
  return LeseInfo(alle ? LeseZustand.gelesen : LeseZustand.gesendet, gelesen, empfaenger, geschaetzt: geschaetzt);
}

/// Personen je Epoche aus den signierten Mitgliederlisten (die Liste nennt, für wen der Schlüssel der Epoche verpackt wurde, also wer die Nachricht lesen konnte).
/// Nicht lesbare Listen fehlen.
Map<int, Set<String>> epochenEmpfaenger(Iterable<Epoche> epochen) {
  final out = <int, Set<String>>{};
  for (final e in epochen) {
    try {
      out[e.epoche] = {for (final m in SignierteMitgliederListe.dekodieren(e.mitglieder).liste.mitglieder) m.userId};
    } on CryptoFehler {
      // beschädigt: diese Epoche bleibt unbekannt
    }
  }
  return out;
}

/// Empfänger einer eigenen Nachricht zum Sendezeitpunkt: die Mitglieder der Epoche, mit der sie verschlüsselt ist, ohne die eigene Person. Ein später hinzugekommenes
/// Mitglied zählt so nicht mit (seine fehlende Lesebestätigung nimmt keine Haken zurück). Ist die Epoche nicht ableitbar, gilt [aktuell] eingeschränkt auf Personen
/// mit vorhandenem Lesestand ([gelesenBis]) und das Ergebnis ist [geschaetzt].
({Set<String> empfaenger, bool geschaetzt}) empfaengerZurNachricht({
  required int? epoche,
  required Map<int, Set<String>> epochen,
  required String ich,
  required Set<String> aktuell,
  required Map<String, DateTime> gelesenBis,
}) {
  final liste = epoche == null ? null : epochen[epoche];
  if (liste != null) return (empfaenger: {...liste}..remove(ich), geschaetzt: false);
  return (empfaenger: {for (final p in aktuell) if (gelesenBis.containsKey(p)) p}, geschaetzt: true);
}

