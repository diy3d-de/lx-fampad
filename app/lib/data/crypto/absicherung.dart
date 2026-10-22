// "Bin ich abgesichert?" (P1): die Schlüssel-Ampel für die eigene Person. Rechenvorschrift wie in der Betreiber-Ansicht (Server `ampelOf`): Grün gibt es nur mit mindestens
// zwei unabhängigen Wegen zum Schlüssel, darunter ein Gerät mit dem aktuellen Schlüssel, also nie ohne mindestens eine BESTÄTIGTE Sicherung. Die Wege sind:
//   - Gerät: dieses Gerät hat den passenden Schlüssel (Status "bereit"), oder ein anderes Gerät hat es dem Server gemeldet (nur wenn dieses Gerät keinen hat);
//   - Passwort-Sicherung: beim Server bestätigt (Round-Trip geprüft) und nicht veraltet;
//   - Wiederherstellungsschlüssel: Sicherung zur aktuellen Schlüsselversion beim Server (sie wird in der App nur nach dem Abtippen des Schlüssels abgelegt).
// Unbekanntes ist nie grün: solange der Stand geladen wird oder nicht lesbar ist, heißt die Ampel "unbekannt" (neutral), und ein älterer Server ohne die neuen Angaben
// gilt als "nicht bestätigt". Die Ampel steht immer mit einem Wort da (nie allein durch Farbe) und nennt den nächsten Schritt.
import '../api/models.dart' show SchluesselWegeDto;
import 'e2ee_state.dart';

enum AbsicherungAmpel { gruen, gelb, rot, unbekannt }

/// Was die Person als Nächstes tun kann (die Oberfläche macht daraus Knöpfe).
enum AbsicherungSchritt {
  /// Es gibt noch keinen Schlüssel: Verschlüsselung einrichten.
  einrichten,

  /// Das Gerät hat den Schlüssel nicht: verbinden (Passwort, QR, Wiederherstellungsschlüssel).
  geraetVerbinden,

  /// Der Schlüssel auf dem Gerät passt nicht zum Konto: neu verbinden (der alte bleibt aufbewahrt).
  geraetNeuVerbinden,

  /// Passwort-Sicherung anlegen.
  passwortSicherung,

  /// Die Passwort-Sicherung ist veraltet (nach einem Passwort-Reset): erneuern.
  passwortSicherungErneuern,

  /// Wiederherstellungsschlüssel anlegen und bestätigen (dazu das Notfallblatt).
  wiederherstellungsschluessel,
}

class AbsicherungsStatus {
  final AbsicherungAmpel ampel;

  /// Gerät mit passendem Schlüssel (dieses oder ein anderes, vom Server gemeldet).
  final bool geraetWeg;
  final bool pwWeg;
  final bool wiederherstellungWeg;

  /// Nur zur Anzeige: Anzahl der Geräte, die dem Server einen passenden Schlüssel melden (null: nicht bekannt).
  final int? geraeteMitSchluessel;

  /// Seit wann die Sicherungen bestätigt beim Server liegen (für die Anzeige).
  final DateTime? pwSeit;
  final DateTime? wiederherstellungSeit;

  /// Die Passwort-Sicherung gibt es auf diesem Server (sonst bleibt der Weg unsichtbar und wird nie verlangt).
  final bool pwVerfuegbar;

  /// Reihenfolge = Wichtigkeit; leer bei unbekannt und bei grün auf einem verbundenen Gerät.
  final List<AbsicherungSchritt> schritte;
  const AbsicherungsStatus({
    required this.ampel,
    this.geraetWeg = false,
    this.pwWeg = false,
    this.wiederherstellungWeg = false,
    this.geraeteMitSchluessel,
    this.pwSeit,
    this.wiederherstellungSeit,
    this.pwVerfuegbar = false,
    this.schritte = const [],
  });

  int get wege => [geraetWeg, pwWeg, wiederherstellungWeg].where((w) => w).length;

  /// Der wichtigste nächste Schritt (null bei grün und unbekannt).
  AbsicherungSchritt? get naechster => schritte.isEmpty ? null : schritte.first;

  /// Ein Wort für die Pille.
  String get wort => switch (ampel) {
    AbsicherungAmpel.gruen => 'abgesichert',
    AbsicherungAmpel.gelb => 'teilweise',
    AbsicherungAmpel.rot => 'nicht abgesichert',
    AbsicherungAmpel.unbekannt => 'unbekannt',
  };

  /// Kurzform als Antwort auf die Frage "Bin ich abgesichert?" (schmale Pille in der Profilzeile).
  String get antwort => switch (ampel) {
    AbsicherungAmpel.gruen => 'ja',
    AbsicherungAmpel.gelb => 'teilweise',
    AbsicherungAmpel.rot => 'nein',
    AbsicherungAmpel.unbekannt => 'unbekannt',
  };

  /// Die Erklärung in einem Satz (Karte, Zeile, Screenreader).
  String get erklaerung => switch (ampel) {
    AbsicherungAmpel.gruen => 'Dein Schlüssel ist auf $wege Wegen erhalten: auch wenn ein Gerät ausfällt, kommst du an deinen Chat-Verlauf.',
    AbsicherungAmpel.gelb => wege == 1 && geraetWeg
        ? 'Dein Schlüssel liegt nur auf einem Gerät. Geht es verloren, ist dein Chat-Verlauf weg. Lege eine Sicherung an.'
        : 'Du hast Sicherungen, aber auf diesem Gerät fehlt dein Schlüssel. Verbinde es, damit du deine Chats lesen kannst.',
    AbsicherungAmpel.rot => wege == 0
        ? 'Dein Schlüssel ist nirgends gesichert. Geht ein Gerät verloren, ist dein Chat-Verlauf nicht mehr lesbar.'
        : 'Es gibt nur eine Sicherung und kein Gerät mit deinem Schlüssel. Verbinde dieses Gerät oder lege eine zweite Sicherung an.',
    AbsicherungAmpel.unbekannt => 'Der Stand deiner Sicherung ist gerade nicht bekannt.',
  };
}

/// Text zu einem Schritt (Knopf).
String schrittText(AbsicherungSchritt s) => switch (s) {
  AbsicherungSchritt.einrichten => 'Verschlüsselung einrichten',
  AbsicherungSchritt.geraetVerbinden => 'Dieses Gerät verbinden',
  AbsicherungSchritt.geraetNeuVerbinden => 'Gerät neu verbinden',
  AbsicherungSchritt.passwortSicherung => 'Passwort-Sicherung anlegen',
  AbsicherungSchritt.passwortSicherungErneuern => 'Passwort-Sicherung erneuern',
  AbsicherungSchritt.wiederherstellungsschluessel => 'Wiederherstellungsschlüssel anlegen',
};

/// Kurze Begründung zu einem Schritt (unter dem Knopf).
String schrittErklaerung(AbsicherungSchritt s) => switch (s) {
  AbsicherungSchritt.einrichten => 'Ohne Schlüssel kannst du keine Chats lesen oder schreiben.',
  AbsicherungSchritt.geraetVerbinden => 'Mit deinem Passwort, einem anderen Gerät oder deinem Wiederherstellungsschlüssel.',
  AbsicherungSchritt.geraetNeuVerbinden => 'Der Schlüssel auf diesem Gerät passt nicht zu deinem Konto. Der alte bleibt aufbewahrt.',
  AbsicherungSchritt.passwortSicherung => 'Dein Passwort öffnet dann auf jedem neuen Gerät automatisch deinen Schlüssel. Kein Zettel nötig.',
  AbsicherungSchritt.passwortSicherungErneuern => 'Seit dem Zurücksetzen deines Passworts passt die Sicherung nicht mehr zu deinem Passwort.',
  AbsicherungSchritt.wiederherstellungsschluessel => 'Ein Schlüssel zum Aufschreiben oder Ausdrucken (Notfallblatt): dein Weg zurück, wenn alles andere weg ist.',
};

/// Bewertet den Stand. [s] ist der geladene Zustand der Verschlüsselung (GET /me/keys und der lokale Schlüsselspeicher), [server] die Wege laut `GET /me/key-status`
/// (null: nicht geladen oder älterer Server). Der Server zählt nur dort, wo dieses Gerät keinen Schlüssel hat (ein anderes Gerät meldet ihn).
AbsicherungsStatus bewerteAbsicherung(E2eeState s, {SchluesselWegeDto? server}) {
  if (s.status == E2eeStatus.laedt || s.status == E2eeStatus.nichtVerfuegbar) return const AbsicherungsStatus(ampel: AbsicherungAmpel.unbekannt);
  final hatSchluessel = s.serverSchluessel != null;
  final pw = hatSchluessel && s.pwBestaetigtAm != null && !s.pwSicherungVeraltet;
  final rec = hatSchluessel && s.hatSicherung && s.wiederherstellungAm != null;
  final geraet = hatSchluessel && (s.status == E2eeStatus.bereit || (server?.geraet ?? false));
  final n = [geraet, pw, rec].where((w) => w).length;
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
    if (s.pwSicherungVerfuegbar && !pw) schritte.add(s.pwSicherungVeraltet ? AbsicherungSchritt.passwortSicherungErneuern : AbsicherungSchritt.passwortSicherung);
    if (!rec) schritte.add(AbsicherungSchritt.wiederherstellungsschluessel);
  }
  return AbsicherungsStatus(
    ampel: ampel,
    geraetWeg: geraet,
    pwWeg: pw,
    wiederherstellungWeg: rec,
    geraeteMitSchluessel: server?.geraeteMitSchluessel,
    pwSeit: pw ? s.pwBestaetigtAm : null,
    wiederherstellungSeit: rec ? s.wiederherstellungAm : null,
    pwVerfuegbar: s.pwSicherungVerfuegbar,
    schritte: schritte,
  );
}
