// Beitritt neuer Mitglieder (PR 6, "Auto-Vertrauen"): BAUSTEINE, noch in keinen Ablauf eingebunden (kein Server, keine Oberfläche, kein Schema, keine Änderung am
// Vertrauen: TOFU, Aufnahme-Abfrage und Warnung bei Schlüsseländerung verhalten sich genau wie vorher). Beschreibung und offene Entscheidungen:
// docs/PROJEKTBESCHREIBUNG.md, Abschnitt 9a "Verlauf freigeben, Wrap-ID v2 (PR 7) und Auto-Vertrauen für neue Mitglieder (PR 6, Bausteine)".
//
// Gedanke: Die einladende Admin-Person erzeugt zusammen mit dem Einladungslink ein [BeitrittsGeheimnis], das NUR im Fragment des Links steht (nie beim Server) und auf ihrem
// Gerät bleibt. Die eingeladene Person bildet damit, wenn sie ihren Schlüssel anlegt, einen Beitritts-MAC über ihren öffentlichen Schlüssel ([beitrittsMacBilden]) und legt ihn
// beim Server ab; nur wer den Link kennt, kann ihn bilden. Das Admin-Gerät erkennt den MAC ([beitrittsMacPasst]) und signiert eine [BeitrittsBestaetigung] mit dem Grund
// `join`. Andere Geräte prüfen sie mit [BeitrittsPruefung.pruefen] gegen einen Schlüssel des Bestätigers, den sie selbst gemerkt haben (nie einen vom Server).
//
// Was diese Bausteine NICHT entscheiden (Produktentscheidung der Familie, siehe Projektbeschreibung): wer bestätigen darf, was ein Gerät mit einer gültigen Bestätigung tut
// (Aufnahme-Abfrage überspringen?) und wie lange eine Bestätigung gilt. Eine Bestätigung ist nie ein Grund, eine Schlüssel-ÄNDERUNG einer bekannten Person ohne Warnung zu
// übernehmen; einen Grund `reset` gibt es nicht und er wird nie angenommen (nach einem Reset bleibt es beim Nachfragen).
import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'domaenen.dart';
import 'schluessel.dart';

/// Länge des Beitritts-Geheimnisses in Byte.
const int kBeitrittsGeheimnisLaenge = 32;

/// Der einzige Grund einer Beitritts-Bestätigung. Ein Reset (neuer Schlüssel einer bekannten Person) wird nie bestätigt.
const String kBeitrittsGrundJoin = 'join';

const int _bestaetigungVersion = 1;

CryptoFehler _format() => const CryptoFehler(CryptoFehlerArt.format, 'Die Beitritts-Bestätigung ist beschädigt.');

CryptoFehler _signatur() => const CryptoFehler(CryptoFehlerArt.signatur, 'Die Beitritts-Bestätigung konnte nicht bestätigt werden.');

/// Zufälliges Geheimnis im Fragment des Einladungslinks (nie beim Server, nie im Log).
class BeitrittsGeheimnis {
  final Uint8List _bytes;
  BeitrittsGeheimnis._(this._bytes);

  factory BeitrittsGeheimnis.erzeugen(CryptoProvider crypto) => BeitrittsGeheimnis._(Uint8List.fromList(crypto.zufall(kBeitrittsGeheimnisLaenge)));

  /// Streng: nur Base64url in kanonischer Form und genau [kBeitrittsGeheimnisLaenge] Byte.
  factory BeitrittsGeheimnis.dekodieren(String text) {
    final b = base64urlDekodieren(text);
    if (b.length != kBeitrittsGeheimnisLaenge) throw const CryptoFehler(CryptoFehlerArt.format, 'Das Beitritts-Geheimnis ist ungültig.');
    return BeitrittsGeheimnis._(b);
  }

  /// Für das Fragment des Links.
  String kodieren() => base64urlKodieren(_bytes);

  /// Überschreibt die Bytes (best effort).
  void loeschen() => loescheBytes(_bytes);
}

Uint8List _macEingabe(String userId, OeffentlicheSchluessel s) =>
    signaturEingabe(kDomaeneBeitrittMac, [utf8Bytes(userId), u32Bytes(s.version), s.enc, s.sign]);

/// Beitritts-MAC (BLAKE2b mit dem Geheimnis als Schlüssel) über Person, Schlüsselversion und beide öffentlichen Schlüssel; Base64url. Aus dem MAC folgt das Geheimnis nicht;
/// ohne das Geheimnis lässt sich für keinen anderen Schlüssel ein passender MAC bilden.
String beitrittsMacBilden(CryptoProvider crypto, {required BeitrittsGeheimnis geheimnis, required String userId, required OeffentlicheSchluessel schluessel}) {
  if (userId.isEmpty || schluessel.version < 1) throw _format();
  return base64urlKodieren(crypto.hash(_macEingabe(userId, schluessel), schluessel: geheimnis._bytes, laenge: 32));
}

/// Passt der abgelegte MAC (in konstanter Zeit) zu Geheimnis, Person und Schlüssel? Eine ungültige Form ist einfach "nein".
bool beitrittsMacPasst(CryptoProvider crypto, {required BeitrittsGeheimnis geheimnis, required String userId, required OeffentlicheSchluessel schluessel, required String mac}) {
  try {
    final soll = crypto.hash(_macEingabe(userId, schluessel), schluessel: geheimnis._bytes, laenge: 32);
    return gleicheBytes(soll, base64urlDekodieren(mac));
  } on CryptoFehler {
    return false;
  }
}

class _Leser {
  final Uint8List b;
  int p = 0;
  _Leser(this.b);

  int u32() {
    if (p + 4 > b.length) throw _format();
    final v = u32Lesen(b, p);
    p += 4;
    return v;
  }

  Uint8List feld() {
    final n = u32();
    if (n > b.length - p) throw _format();
    final out = Uint8List.sublistView(b, p, p + n);
    p += n;
    return out;
  }

  String text() {
    try {
      return utf8.decode(feld());
    } on FormatException {
      throw _format();
    }
  }

  void ende() {
    if (p != b.length) throw _format();
  }
}

/// Von einer bereits aufgenommenen Person (dem Bestätiger) signierte Aussage: "Die Person [mitgliedId] ist mit diesem Schlüssel über meine Einladung beigetreten" (Grund
/// `join`). Sie bindet Familie, Person, beide öffentlichen Schlüssel samt Version, den Bestätiger und den Grund; eine Bestätigung für einen anderen Schlüssel, eine andere
/// Person, eine andere Familie oder einen anderen Grund ist ungültig.
class BeitrittsBestaetigung {
  final String familienId;
  final String mitgliedId;
  final OeffentlicheSchluessel mitgliedSchluessel;
  final String bestaetigerId;
  final int bestaetigerKeyVersion;
  final Uint8List signatur;

  BeitrittsBestaetigung._({
    required this.familienId,
    required this.mitgliedId,
    required this.mitgliedSchluessel,
    required this.bestaetigerId,
    required this.bestaetigerKeyVersion,
    required this.signatur,
  });

  /// Der Grund: immer `join`.
  String get grund => kBeitrittsGrundJoin;

  Uint8List get _eingabe => signaturEingabe(kDomaeneBeitritt, [
    utf8Bytes(familienId),
    utf8Bytes(mitgliedId),
    u32Bytes(mitgliedSchluessel.version),
    mitgliedSchluessel.enc,
    mitgliedSchluessel.sign,
    utf8Bytes(bestaetigerId),
    u32Bytes(bestaetigerKeyVersion),
    utf8Bytes(kBeitrittsGrundJoin),
  ]);

  /// Signiert die Bestätigung mit dem Signaturschlüssel des Bestätigers (die Prüfung des MAC gegen das Geheimnis macht der Aufrufer vorher: [beitrittsMacPasst]).
  factory BeitrittsBestaetigung.erstellen(
    CryptoProvider crypto, {
    required String familienId,
    required String mitgliedId,
    required OeffentlicheSchluessel mitgliedSchluessel,
    required String bestaetigerId,
    required int bestaetigerKeyVersion,
    required Uint8List bestaetigerSignGeheim,
  }) {
    if (familienId.isEmpty || mitgliedId.isEmpty || bestaetigerId.isEmpty || bestaetigerKeyVersion < 1 || mitgliedSchluessel.version < 1) throw _format();
    if (mitgliedId == bestaetigerId) throw const CryptoFehler(CryptoFehlerArt.format, 'Niemand bestätigt sich selbst.');
    final ohne = BeitrittsBestaetigung._(
      familienId: familienId,
      mitgliedId: mitgliedId,
      mitgliedSchluessel: mitgliedSchluessel,
      bestaetigerId: bestaetigerId,
      bestaetigerKeyVersion: bestaetigerKeyVersion,
      signatur: Uint8List(0),
    );
    return BeitrittsBestaetigung._(
      familienId: familienId,
      mitgliedId: mitgliedId,
      mitgliedSchluessel: mitgliedSchluessel,
      bestaetigerId: bestaetigerId,
      bestaetigerKeyVersion: bestaetigerKeyVersion,
      signatur: crypto.signieren(ohne._eingabe, bestaetigerSignGeheim),
    );
  }

  /// Transportform (Base64url).
  String kodieren() => base64urlKodieren(verketten([
    [_bestaetigungVersion],
    gerahmt(utf8Bytes(familienId)),
    gerahmt(utf8Bytes(mitgliedId)),
    u32Bytes(mitgliedSchluessel.version),
    gerahmt(mitgliedSchluessel.enc),
    gerahmt(mitgliedSchluessel.sign),
    gerahmt(utf8Bytes(bestaetigerId)),
    u32Bytes(bestaetigerKeyVersion),
    gerahmt(utf8Bytes(kBeitrittsGrundJoin)),
    gerahmt(signatur),
  ]));

  /// Streng: andere Version, anderer Grund (auch `reset`), Reste oder falsche Längen sind Fehler.
  factory BeitrittsBestaetigung.dekodieren(String text) {
    final l = _Leser(base64urlDekodieren(text));
    if (l.b.isEmpty || l.b[0] != _bestaetigungVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Beitritts-Bestätigung stammt von einer neueren App-Version.');
    l.p = 1;
    final familie = l.text();
    final mitglied = l.text();
    final mitgliedVersion = l.u32();
    final enc = Uint8List.fromList(l.feld());
    final sign = Uint8List.fromList(l.feld());
    final bestaetiger = l.text();
    final bestaetigerVersion = l.u32();
    final grund = l.text();
    final sig = Uint8List.fromList(l.feld());
    l.ende();
    if (grund != kBeitrittsGrundJoin) throw const CryptoFehler(CryptoFehlerArt.format, 'Dieser Grund gilt nicht für das automatische Vertrauen.');
    if (familie.isEmpty || mitglied.isEmpty || bestaetiger.isEmpty || mitgliedVersion < 1 || bestaetigerVersion < 1 || mitglied == bestaetiger) throw _format();
    final OeffentlicheSchluessel schluessel;
    try {
      schluessel = OeffentlicheSchluessel(enc: enc, sign: sign, version: mitgliedVersion);
    } on CryptoFehler {
      throw _format();
    }
    return BeitrittsBestaetigung._(
      familienId: familie,
      mitgliedId: mitglied,
      mitgliedSchluessel: schluessel,
      bestaetigerId: bestaetiger,
      bestaetigerKeyVersion: bestaetigerVersion,
      signatur: sig,
    );
  }
}

/// Prüfregeln für eine [BeitrittsBestaetigung] (rein kryptografisch; was ein Gerät mit einer gültigen Bestätigung tut, ist eine Entscheidung der Familie).
class BeitrittsPruefung {
  /// Wirft [CryptoFehler], wenn die Bestätigung nicht gilt. Sie gilt nur, wenn ALLES passt:
  ///  - Familie und Person sind die erwarteten, und der Schlüssel samt Version ist genau der, den der Server jetzt für die Person liefert ([aktuellerSchluessel]):
  ///    eine Bestätigung für einen früheren oder anderen Schlüssel (zum Beispiel nach einem Reset) gilt nie;
  ///  - der Bestätiger ist eine andere Person als das neue Mitglied;
  ///  - [bestaetigerGemerkt] ist der Schlüssel des Bestätigers, den DIESES Gerät selbst gemerkt hat (nie einer vom Server) und trägt dieselbe Version wie in der
  ///    Bestätigung; die Signatur stimmt gegen ihn.
  /// Ob der Bestätiger selbst schon aufgenommen ist und ob die Person neu ist (kein Schlüsselwechsel einer bekannten Person), prüft der Aufrufer.
  static void pruefen(
    CryptoProvider crypto, {
    required BeitrittsBestaetigung bestaetigung,
    required String erwarteteFamilienId,
    required String erwarteteMitgliedId,
    required OeffentlicheSchluessel aktuellerSchluessel,
    required OeffentlicheSchluessel bestaetigerGemerkt,
  }) {
    if (bestaetigung.familienId != erwarteteFamilienId || bestaetigung.mitgliedId != erwarteteMitgliedId) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Die Beitritts-Bestätigung gehört nicht zu dieser Person.');
    }
    final m = bestaetigung.mitgliedSchluessel;
    if (m.version != aktuellerSchluessel.version || !m.gleichWie(aktuellerSchluessel)) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Die Beitritts-Bestätigung gilt für einen anderen Schlüssel.');
    }
    if (bestaetigung.bestaetigerId == bestaetigung.mitgliedId) throw _format();
    if (bestaetigerGemerkt.version != bestaetigung.bestaetigerKeyVersion) throw _signatur();
    if (!crypto.signaturPruefen(bestaetigung._eingabe, bestaetigung.signatur, bestaetigerGemerkt.sign)) throw _signatur();
  }
}
