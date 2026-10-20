// Lesebestätigung an eigenen Nachrichten (Haken wie bei WhatsApp). Grundlage sind nur die bestehenden Lesestände der Teilnehmer
// (`lesestand`: je Person und Chat der Zeitpunkt der zuletzt gelesenen Nachricht); es gibt kein eigenes Protokoll und keine zusätzlichen Metadaten.
// Der Lesestand ist für die Teilnehmer des Chats sichtbar (Datenschutz-Entwurf), die Lesebestätigung lässt sich nicht abschalten.
import '../app_database.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/epochen.dart';

enum LeseZustand {
  /// Noch nicht beim Server, noch nicht gesendet (offline oder in der Warteschlange; Uhr).
  wartet,

  /// Noch nicht beim Server, ein Sendeversuch läuft (Uhr).
  wirdGesendet,

  /// Seit mehr als [kHaengtNach] ohne Fortschritt (keine Verbindung, kein Schlüssel oder keine Antwort): sanfter Hinweis, die Nachricht geht nicht verloren.
  haengt,

  /// Der Server hat die Nachricht endgültig abgelehnt (Fehlersymbol, "Erneut senden" oder "Verwerfen").
  abgelehnt,

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
  /// Kurzer Grund-Code der Ablehnung (nie ein Inhalt), nur bei [LeseZustand.abgelehnt].
  final String? fehlerCode;
  const LeseInfo(this.zustand, this.gelesenVon, this.empfaenger, {this.geschaetzt = false, this.fehlerCode});

  /// Noch nicht beim Server bestätigt (wartet, wird gesendet, hängt oder abgelehnt).
  bool get ungesendet => switch (zustand) {
    LeseZustand.wartet || LeseZustand.wirdGesendet || LeseZustand.haengt || LeseZustand.abgelehnt => true,
    LeseZustand.gesendet || LeseZustand.gelesen => false,
  };

  bool get teilweise => zustand == LeseZustand.gesendet && gelesenVon.isNotEmpty;
}

/// Zustand einer eigenen Nachricht. [empfaenger] sind die anderen Teilnehmer (Direktchat/Gruppe: Teilnehmerliste, Familienchat: alle aktiven Mitglieder) ohne
/// die eigene Person, [gelesenBis] der Lesestand je Person. Gelesen heißt: der Lesestand der Person ist mindestens so neu wie die Nachricht. Ohne Empfänger
/// (allein im Chat) bleibt es bei "gesendet".
///
/// [ausgang] ist die noch offene Op dieser Nachricht (null: unbekannt, dann gilt "wird gesendet"), [jetzt] die Uhr für "hängt".
LeseInfo leseInfo({
  required Nachricht nachricht,
  required Set<String> empfaenger,
  required Map<String, DateTime> gelesenBis,
  bool geschaetzt = false,
  OutboxData? ausgang,
  DateTime? jetzt,
}) {
  if (nachricht.rev <= 0) {
    final z = ausgangZustand(ausgang, jetzt: jetzt ?? DateTime.now());
    return LeseInfo(z, const {}, empfaenger, geschaetzt: geschaetzt, fehlerCode: z == LeseZustand.abgelehnt ? ausgang?.fehlerCode : null);
  }
  final gelesen = {
    for (final p in empfaenger)
      if (gelesenBis[p] case final t? when !t.isBefore(nachricht.createdAt)) p,
  };
  final alle = empfaenger.isNotEmpty && gelesen.length == empfaenger.length;
  return LeseInfo(alle ? LeseZustand.gelesen : LeseZustand.gesendet, gelesen, empfaenger, geschaetzt: geschaetzt);
}

/// Nach dieser Zeit ohne Fortschritt gilt eine ungesendete Nachricht als "hängt".
const kHaengtNach = Duration(minutes: 2);

/// Zustand einer noch nicht bestätigten eigenen Nachricht aus ihrer Op im Ausgang: abgelehnt (Fehler-Code gesetzt), hängt (älter als [kHaengtNach]), sonst
/// wird gesendet (ein Sendeversuch ist unterwegs, `sentAt`) oder wartet (noch nie gesendet). Ohne Op: wird gesendet.
LeseZustand ausgangZustand(OutboxData? op, {required DateTime jetzt}) {
  if (op == null) return LeseZustand.wirdGesendet;
  if (op.fehlerCode != null) return LeseZustand.abgelehnt;
  if (jetzt.difference(op.createdAt) > kHaengtNach) return LeseZustand.haengt;
  return op.sentAt == null ? LeseZustand.wartet : LeseZustand.wirdGesendet;
}

/// Zeitpunkt, ab dem eine ungesendete Nachricht als "hängt" gilt (für das Planen einer Neuzeichnung); null, wenn sie schon hängt oder abgelehnt ist.
DateTime? haengtAb(OutboxData? op, DateTime jetzt) {
  if (op == null || op.fehlerCode != null) return null;
  final t = op.createdAt.add(kHaengtNach);
  return t.isAfter(jetzt) ? t : null;
}

/// Kurzer Grund einer Ablehnung für die Oberfläche (aus dem Code des Servers, nie ein Inhalt).
String ablehnungsGrund(String? code) => switch (code) {
  'forbidden' => 'Dazu fehlt dir die Berechtigung.',
  'not_found' => 'Der Chat ist für dich nicht (mehr) verfügbar.',
  'invalid' => 'Der Server hat die Nachricht nicht akzeptiert.',
  'invalid_reference' => 'Ein Verweis in der Nachricht ist ungültig.',
  'limit_reached' => 'Das Limit des Servers ist erreicht.',
  _ => 'Der Server hat die Nachricht abgelehnt.',
};

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

