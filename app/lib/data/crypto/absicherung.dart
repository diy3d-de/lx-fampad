// "Bin ich abgesichert?" (P1): die Schlüssel-Ampel für die eigene Person. Rechenvorschrift wie in der Betreiber-Ansicht (Server `ampelOf`): Grün gibt es nur mit mindestens
// zwei unabhängigen Wegen zum Schlüssel, darunter ein Gerät mit dem aktuellen Schlüssel, also nie ohne mindestens eine BESTÄTIGTE Sicherung. Die Wege sind:
//   - Gerät: dieses Gerät hat den passenden Schlüssel (Status "bereit"), oder ein anderes Gerät hat es dem Server gemeldet (nur wenn dieses Gerät keinen hat);
//   - Passwort-Sicherung: beim Server bestätigt (Round-Trip geprüft) und nicht veraltet;
//   - Passkey-Sicherung (PRF): ebenso bestätigt; sie zählt mit der Passwort-Sicherung als EIN Weg ("Sicherung durch Zugangsdaten", wie auf dem Server);
//   - Wiederherstellungsschlüssel: Sicherung zur aktuellen Schlüsselversion beim Server (sie wird in der App nur nach dem Abtippen des Schlüssels abgelegt).
// Unbekanntes ist nie grün: solange der Stand geladen wird oder nicht lesbar ist, heißt die Ampel "unbekannt" (neutral), und ein älterer Server ohne die neuen Angaben
// gilt als "nicht bestätigt". Die Ampel steht immer mit einem Wort da (nie allein durch Farbe) und nennt den nächsten Schritt.
import '../api/models.dart' show SchluesselWegeDto;
import 'e2ee_state.dart';

enum AbsicherungAmpel { gruen, gelb, rot, unbekannt }

/// Was die Person als Nächstes tun kann (die Oberfläche macht daraus Knöpfe).
enum AbsicherungSchritt {
  /// Es gibt noch keinen Schlüssel: Nachrichten-Schutz einrichten.
  einrichten,

  /// Das Gerät hat den Schlüssel nicht: verbinden (Passwort, QR, Wiederherstellungsschlüssel).
  geraetVerbinden,

  /// Der Schlüssel auf dem Gerät passt nicht zum Konto: neu verbinden (der alte bleibt aufbewahrt).
  geraetNeuVerbinden,

  /// Passwort-Sicherung anlegen.
  passwortSicherung,

  /// Die Passwort-Sicherung ist veraltet (nach einem Passwort-Reset): erneuern.
  passwortSicherungErneuern,

  /// Passkey-Sicherung anlegen (PRF) bzw. nach einem Schlüsselwechsel erneuern.
  passkeySicherung,
  passkeySicherungErneuern,

  /// Wiederherstellungsschlüssel anlegen und bestätigen (dazu das Notfallblatt).
  wiederherstellungsschluessel,
}

class AbsicherungsStatus {
  final AbsicherungAmpel ampel;

  /// Gerät mit passendem Schlüssel (dieses oder ein anderes, vom Server gemeldet).
  final bool geraetWeg;
  final bool pwWeg;

  /// Bestätigte Passkey-Sicherung (zählt mit [pwWeg] als ein Weg).
  final bool prfWeg;
  final bool wiederherstellungWeg;

  /// Nur zur Anzeige: Anzahl der Geräte, die dem Server einen passenden Schlüssel melden (null: nicht bekannt).
  final int? geraeteMitSchluessel;

  /// Seit wann die Sicherungen bestätigt beim Server liegen (für die Anzeige).
  final DateTime? pwSeit;
  final DateTime? prfSeit;
  final DateTime? wiederherstellungSeit;

  /// Die Passwort-Sicherung gibt es auf diesem Server (sonst bleibt der Weg unsichtbar und wird nie verlangt).
  final bool pwVerfuegbar;

  /// Die Passkey-Sicherung wird angeboten (Server-Schalter UND die Person hat einen Passkey).
  final bool prfAngeboten;

  /// Die Person hat überhaupt einen Schlüssel (laut Server).
  final bool hatSchluessel;

  /// Reihenfolge = Wichtigkeit; leer bei unbekannt und bei grün auf einem verbundenen Gerät.
  final List<AbsicherungSchritt> schritte;
  const AbsicherungsStatus({
    required this.ampel,
    this.geraetWeg = false,
    this.pwWeg = false,
    this.prfWeg = false,
    this.wiederherstellungWeg = false,
    this.geraeteMitSchluessel,
    this.pwSeit,
    this.prfSeit,
    this.wiederherstellungSeit,
    this.pwVerfuegbar = false,
    this.prfAngeboten = false,
    this.hatSchluessel = true,
    this.schritte = const [],
  });

  int get wege => [geraetWeg, pwWeg || prfWeg, wiederherstellungWeg].where((w) => w).length;

  /// Wie viele Wege es auf diesem Server überhaupt gibt (die Sicherung durch Zugangsdaten nur, wenn er Passwort- oder Passkey-Sicherung anbietet): der Nenner in "x von y Wegen".
  int get wegeMoeglich => pwVerfuegbar || prfAngeboten || prfWeg ? 3 : 2;

  /// Der wichtigste nächste Schritt (null bei grün und unbekannt).
  AbsicherungSchritt? get naechster => schritte.isEmpty ? null : schritte.first;

  /// Ein Wort für die Pille.
  String get wort => switch (ampel) {
    AbsicherungAmpel.gruen => 'Alles gut abgesichert',
    AbsicherungAmpel.gelb => 'Einen Weg noch einrichten',
    AbsicherungAmpel.rot => 'Noch nicht abgesichert',
    AbsicherungAmpel.unbekannt => 'Wird geprüft',
  };

  /// Kurzform als Antwort auf die Frage "Bin ich abgesichert?" (schmale Pille in der Profilzeile).
  String get antwort => switch (ampel) {
    AbsicherungAmpel.gruen => 'Ja',
    AbsicherungAmpel.gelb => 'Teilweise',
    AbsicherungAmpel.rot => 'Nein',
    AbsicherungAmpel.unbekannt => 'Wird geprüft',
  };

  /// Die Erklärung in einem Satz (Karte, Zeile, Screenreader).
  String get erklaerung => switch (ampel) {
    AbsicherungAmpel.gruen => 'Dein Schlüssel ist auf $wege Wegen erhalten: auch wenn ein Gerät ausfällt, kommst du an deinen Chat-Verlauf.',
    AbsicherungAmpel.gelb => wege == 1 && geraetWeg
        ? 'Dein Schlüssel liegt nur auf einem Gerät. Geht es verloren, ist dein Chat-Verlauf weg. Lege eine Sicherung an.'
        : 'Du hast Sicherungen, aber auf diesem Gerät fehlt dein Schlüssel. Verbinde es, damit du deine Chats lesen kannst.',
    AbsicherungAmpel.rot => !hatSchluessel
        ? 'Du hast noch keinen Schlüssel. Ohne ihn kannst du keine Chats lesen oder schreiben.'
        : wege == 0
        ? 'Dein Schlüssel ist nirgends gesichert. Geht ein Gerät verloren, ist dein Chat-Verlauf nicht mehr lesbar.'
        : 'Es gibt nur eine Sicherung und kein Gerät mit deinem Schlüssel. Verbinde dieses Gerät oder lege eine zweite Sicherung an.',
    AbsicherungAmpel.unbekannt => 'Der Stand deiner Sicherung ist gerade nicht bekannt.',
  };
}

/// Text zu einem Schritt (Knopf).
String schrittText(AbsicherungSchritt s) => switch (s) {
  AbsicherungSchritt.einrichten => 'Nachrichten-Schutz einrichten',
  AbsicherungSchritt.geraetVerbinden => 'Dieses Gerät verbinden',
  AbsicherungSchritt.geraetNeuVerbinden => 'Gerät neu verbinden',
  AbsicherungSchritt.passwortSicherung => 'Passwort-Sicherung anlegen',
  AbsicherungSchritt.passwortSicherungErneuern => 'Passwort-Sicherung erneuern',
  AbsicherungSchritt.passkeySicherung => 'Passkey-Sicherung anlegen',
  AbsicherungSchritt.passkeySicherungErneuern => 'Passkey-Sicherung erneuern',
  AbsicherungSchritt.wiederherstellungsschluessel => 'Wiederherstellungsschlüssel anlegen',
};

/// Kurze Begründung zu einem Schritt (unter dem Knopf).
String schrittErklaerung(AbsicherungSchritt s) => switch (s) {
  AbsicherungSchritt.einrichten => 'Ohne Schlüssel kannst du keine Chats lesen oder schreiben.',
  AbsicherungSchritt.geraetVerbinden => 'Mit deinem Passwort, einem anderen Gerät oder deinem Wiederherstellungsschlüssel.',
  AbsicherungSchritt.geraetNeuVerbinden => 'Der Schlüssel auf diesem Gerät passt nicht zu deinem Konto. Der alte bleibt aufbewahrt.',
  AbsicherungSchritt.passwortSicherung => 'Dein Passwort öffnet dann auf jedem neuen Gerät automatisch deinen Schlüssel. Kein Zettel nötig.',
  AbsicherungSchritt.passwortSicherungErneuern => 'Seit dem Zurücksetzen deines Passworts passt die Sicherung nicht mehr zu deinem Passwort.',
  AbsicherungSchritt.passkeySicherung => 'Dein Zugang ohne Passwort (Passkey) öffnet dann auf einem neuen Gerät deinen Schlüssel: Fingerabdruck oder PIN genügen, kein Zettel nötig.',
  AbsicherungSchritt.passkeySicherungErneuern => 'Dein Schlüssel wurde gewechselt, die bisherige Passkey-Sicherung gehört zum alten Schlüssel.',
  AbsicherungSchritt.wiederherstellungsschluessel => 'Ein Schlüssel zum Aufschreiben oder Ausdrucken (Notfallblatt): dein Weg zurück, wenn alles andere weg ist.',
};

/// Bewertet den Stand. [s] ist der geladene Zustand der Verschlüsselung (GET /me/keys und der lokale Schlüsselspeicher), [server] die Wege laut `GET /me/key-status`
/// (null: nicht geladen oder älterer Server). Der Server zählt nur dort, wo dieses Gerät keinen Schlüssel hat (ein anderes Gerät meldet ihn).
AbsicherungsStatus bewerteAbsicherung(E2eeState s, {SchluesselWegeDto? server, bool hatPasskey = false}) {
  if (s.status == E2eeStatus.laedt || s.status == E2eeStatus.nichtVerfuegbar) return const AbsicherungsStatus(ampel: AbsicherungAmpel.unbekannt);
  final hatSchluessel = s.serverSchluessel != null;
  final pw = hatSchluessel && s.pwBestaetigtAm != null && !s.pwSicherungVeraltet;
  // die Passkey-Sicherung zählt nur, wenn der Passkey synchronisiert ist (auf anderen Geräten verfügbar): sonst ginge sie mit diesem Gerät verloren
  final prf = hatSchluessel && s.prfBestaetigtAm != null && s.prfCredentialIds.isNotEmpty && s.prfSynchronisiert;
  final rec = hatSchluessel && s.hatSicherung && s.wiederherstellungAm != null;
  final geraet = hatSchluessel && (s.status == E2eeStatus.bereit || (server?.geraet ?? false));
  final n = [geraet, pw || prf, rec].where((w) => w).length;
  final AbsicherungAmpel ampel;
  if (!hatSchluessel || n == 0) {
    ampel = AbsicherungAmpel.rot;
  } else if (n >= 2 && geraet) {
    ampel = AbsicherungAmpel.gruen;
  } else if (n == 1) {
    ampel = geraet ? AbsicherungAmpel.gelb : AbsicherungAmpel.rot;
  } else {
    ampel = AbsicherungAmpel.gelb; // zwei Sicherungen, aber kein Gerät mit dem Schlüssel
  }
  final schritte = <AbsicherungSchritt>[];
  // dieses Gerät: ohne passenden Schlüssel hilft auch eine grüne Ampel nicht beim Lesen der Chats hier
  switch (s.status) {
    case E2eeStatus.keinSchluessel:
      schritte.add(AbsicherungSchritt.einrichten);
    case E2eeStatus.geraetNichtVerbunden:
      schritte.add(AbsicherungSchritt.geraetVerbinden);
    case E2eeStatus.abweichend:
      schritte.add(AbsicherungSchritt.geraetNeuVerbinden);
    case E2eeStatus.bereit || E2eeStatus.laedt || E2eeStatus.nichtVerfuegbar:
      break;
  }
  // Sicherungen lassen sich nur auf einem Gerät mit passendem Schlüssel anlegen (sie brauchen ihn); bei grün gibt es nichts mehr zu tun
  if (ampel != AbsicherungAmpel.gruen && s.status == E2eeStatus.bereit) {
    final prfAngeboten = s.prfSicherungVerfuegbar && hatPasskey;
    if (!pw && !prf) {
      if (s.pwSicherungVerfuegbar) schritte.add(s.pwSicherungVeraltet ? AbsicherungSchritt.passwortSicherungErneuern : AbsicherungSchritt.passwortSicherung);
      if (prfAngeboten) schritte.add(s.prfSicherungVeraltet ? AbsicherungSchritt.passkeySicherungErneuern : AbsicherungSchritt.passkeySicherung);
    }
    if (!rec) schritte.add(AbsicherungSchritt.wiederherstellungsschluessel);
  }
  return AbsicherungsStatus(
    ampel: ampel,
    geraetWeg: geraet,
    pwWeg: pw,
    prfWeg: prf,
    wiederherstellungWeg: rec,
    geraeteMitSchluessel: server?.geraeteMitSchluessel,
    pwSeit: pw ? s.pwBestaetigtAm : null,
    prfSeit: prf ? s.prfBestaetigtAm : null,
    wiederherstellungSeit: rec ? s.wiederherstellungAm : null,
    pwVerfuegbar: s.pwSicherungVerfuegbar,
    prfAngeboten: s.prfSicherungVerfuegbar && hatPasskey,
    hatSchluessel: hatSchluessel,
    schritte: schritte,
  );
}
