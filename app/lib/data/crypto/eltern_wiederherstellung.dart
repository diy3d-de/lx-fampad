// Eltern-Wiederherstellung für Kinder (Projektbeschreibung 9a, "P1-Rest"): reine Bausteine auf geprüften libsodium-Funktionen (Sealed Box, Ed25519, BLAKE2b, SHA-256),
// keine eigenen Primitive. Der Server sieht nie Seeds: er speichert nur Sealed Boxes, Signaturen, die Verpflichtung, die Zufallszahl und den flüchtigen öffentlichen Schlüssel.
//
// Hinterlegung (Kind -> je Elternteil): Sealed Box der 64 Byte Seeds an den X25519-Schlüssel des Elternteils, signiert vom Kind (Ed25519):
//   signatur = Ed25519(kindSign, "lx-familyhub|escrow|v1" | gerahmt(kindId) | gerahmt(keyVersion) | gerahmt(elternId) | gerahmt(elternKeyVersion) | gerahmt(SHA-256(sealed)))
// Anfrage mit Verpflichtung (Kind): flüchtiges X25519-Paar T, Nonce n, commit = BLAKE2b-256("lx-familyhub|escrow-commit|v1" | gerahmt(T_pub) | gerahmt(n)).
// Kurzcode (beide Seiten rechnen ihn, das Elternteil vergleicht ihn mit dem, was das Kind nennt):
//   SAS = BLAKE2b-256("lx-familyhub|escrow-sas|v1" | gerahmt(T_pub) | gerahmt(n) | gerahmt(r) | gerahmt(anfrageId) | gerahmt(commit) | gerahmt(kindId) | gerahmt(elternId)),
//   die ersten 6 Byte (48 Bit) mod 10^8, achtstellig (Anzeige in zwei Vierergruppen). Beide Seiten rechnen NUR mit Werten, die sie beim Übernehmen bzw. Offenlegen selbst
//   festgehalten haben (commit und r beim Elternteil, r und Elternteil beim Kind): ändert der Server danach etwas, bricht die Seite ab (eltern_state.dart).
// Übergabe (Elternteil -> Kind): Sealed Box der Seeds an T_pub, signiert vom Elternteil:
//   signatur = Ed25519(elternSign, "lx-familyhub|escrow-release|v1" | gerahmt(anfrageId) | gerahmt(kindId) | gerahmt(keyVersion) | gerahmt(elternId) | gerahmt(elternKeyVersion) | gerahmt(SHA-256(sealed)) | gerahmt(T_pub))
// Alle Prüfungen gegen GEMERKTE (TOFU) Schlüssel, die dem Schlüssel des Servers gleichen; nie gegen einen vom Server nachgeladenen Schlüssel.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'domaenen.dart';
import 'schluessel.dart';

Uint8List _sha256(List<int> d) => Uint8List.fromList(c.sha256.convert(d).bytes);

CryptoFehler _signatur() => const CryptoFehler(CryptoFehlerArt.signatur, 'Die Signatur stimmt nicht: Die Angaben stammen nicht von der erwarteten Person.');

/// Eine Hinterlegung für ein Elternteil: die Sealed Box und die Signatur des Kindes (Base64url).
class HinterlegungEintrag {
  final String blob;
  final String sig;
  const HinterlegungEintrag(this.blob, this.sig);
}

/// Das flüchtige Paar des Kindes für eine Anfrage samt Nonce. Der geheime Teil bleibt auf dem Gerät des Kindes, bis die Anfrage endet.
class FluechtigesPaar {
  final Uint8List oeffentlich;
  final Uint8List geheim;
  final Uint8List nonce;
  FluechtigesPaar(this.oeffentlich, this.geheim, this.nonce);

  void loeschen() => loescheBytes(geheim);
}

class ElternKrypto {
  ElternKrypto._();

  static Uint8List _hinterlegungEingabe(String kindId, int keyVersion, String elternId, int elternVersion, Uint8List sealed) => signaturEingabe(kDomaeneHinterlegung, [
    utf8Bytes(kindId),
    u32Bytes(keyVersion),
    utf8Bytes(elternId),
    u32Bytes(elternVersion),
    _sha256(sealed),
  ]);

  static Uint8List _freigabeEingabe(String anfrageId, String kindId, int keyVersion, String elternId, int elternVersion, Uint8List sealed, Uint8List tempPub) =>
      signaturEingabe(kDomaeneFreigabe, [utf8Bytes(anfrageId), utf8Bytes(kindId), u32Bytes(keyVersion), utf8Bytes(elternId), u32Bytes(elternVersion), _sha256(sealed), tempPub]);

  // ------------------------------------------------------------ Hinterlegung

  /// Das Kind verpackt seinen Schlüssel für ein Elternteil. [eltern] ist der VERTRAUTE öffentliche Schlüssel des Elternteils (gemerkt und gleich dem des Servers).
  static HinterlegungEintrag hinterlegen(
    CryptoProvider crypto, {
    required Personenschluessel kind,
    required String kindId,
    required int keyVersion,
    required String elternId,
    required OeffentlicheSchluessel eltern,
  }) {
    final seeds = kind.exportieren();
    try {
      final sealed = crypto.versiegeln(seeds, eltern.enc);
      final sig = crypto.signieren(_hinterlegungEingabe(kindId, keyVersion, elternId, eltern.version, sealed), kind.signGeheim);
      return HinterlegungEintrag(base64urlKodieren(sealed), base64urlKodieren(sig));
    } finally {
      loescheBytes(seeds);
    }
  }

  /// Das Elternteil öffnet die Hinterlegung des Kindes: prüft die Signatur gegen den VERTRAUTEN Schlüssel des Kindes (Version und Schlüssel müssen stimmen), öffnet mit dem
  /// eigenen Schlüssel und gibt die 64 Byte Seeds zurück (der Aufrufer überschreibt sie nach Gebrauch). [elternVersion] ist die Version, für die verpackt wurde.
  static Uint8List hinterlegungOeffnen(
    CryptoProvider crypto, {
    required String blob,
    required String sig,
    required String kindId,
    required int keyVersion,
    required OeffentlicheSchluessel kindVertraut,
    required String elternId,
    required int elternVersion,
    required Personenschluessel elternSchluessel,
  }) {
    if (kindVertraut.version != keyVersion) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der gemerkte Schlüssel des Kindes gehört zu einer anderen Version als die Hinterlegung.');
    final sealed = base64urlDekodieren(blob);
    final signatur = base64urlDekodieren(sig);
    if (!crypto.signaturPruefen(_hinterlegungEingabe(kindId, keyVersion, elternId, elternVersion, sealed), signatur, kindVertraut.sign)) throw _signatur();
    final seeds = crypto.versiegelungOeffnen(sealed, elternSchluessel.encOeffentlich, elternSchluessel.encGeheim);
    if (seeds.length != 2 * kSchluesselLaenge) {
      loescheBytes(seeds);
      throw const CryptoFehler(CryptoFehlerArt.format, 'Die Hinterlegung ist beschädigt.');
    }
    return seeds;
  }

  // ------------------------------------------------------------ Verpflichtung und Kurzcode

  /// Neues flüchtiges Paar mit Nonce (16 Byte).
  static FluechtigesPaar fluechtigesPaar(CryptoProvider crypto) {
    final p = crypto.boxPaarAusSeed(crypto.zufall(32));
    return FluechtigesPaar(Uint8List.fromList(p.oeffentlich), Uint8List.fromList(p.geheim), crypto.zufall(16));
  }

  static Uint8List _verpflichtung(CryptoProvider crypto, Uint8List pub, Uint8List nonce) => crypto.hash(signaturEingabe(kDomaeneVerpflichtung, [pub, nonce]));

  /// Verpflichtung auf den flüchtigen Schlüssel (Base64url, 32 Byte): geht VOR der Zufallszahl des Elternteils an den Server.
  static String verpflichtung(CryptoProvider crypto, Uint8List pub, Uint8List nonce) => base64urlKodieren(_verpflichtung(crypto, pub, nonce));

  /// Passt der offengelegte Schlüssel samt Nonce zur Verpflichtung? (Das Elternteil prüft das, bevor es dem Kurzcode traut.)
  static bool verpflichtungPasst(CryptoProvider crypto, String commit, Uint8List pub, Uint8List nonce) {
    try {
      return gleicheBytes(base64urlDekodieren(commit), _verpflichtung(crypto, pub, nonce));
    } on CryptoFehler {
      return false;
    }
  }

  /// Achtstelliger Kurzcode aus flüchtigem Schlüssel, Nonce, Zufallszahl des Elternteils, Anfrage-Kennung, Verpflichtung sowie Kind und Elternteil.
  static String kurzcode(
    CryptoProvider crypto, {
    required Uint8List pub,
    required Uint8List nonce,
    required Uint8List challenge,
    required String anfrageId,
    required String commit,
    required String kindId,
    required String elternId,
  }) {
    final h = crypto.hash(signaturEingabe(kDomaeneKurzcode, [pub, nonce, challenge, utf8Bytes(anfrageId), utf8Bytes(commit), utf8Bytes(kindId), utf8Bytes(elternId)]));
    // 48 Bit (auch im Web innerhalb von 2^53), danach mod 10^8: der Rest ist vernachlässigbar ungleichmäßig
    final n = (u32Lesen(h, 0) * 65536 + ((h[4] << 8) | h[5])) % 100000000;
    return n.toString().padLeft(8, '0');
  }

  // ------------------------------------------------------------ Übergabe

  /// Das Elternteil gibt frei: öffnet seinen Eintrag und verpackt die Seeds an den offengelegten flüchtigen Schlüssel des Kindes (Sealed Box), signiert.
  /// [seeds] sind die geöffneten 64 Byte (der Aufrufer überschreibt sie danach).
  static HinterlegungEintrag freigeben(
    CryptoProvider crypto, {
    required Uint8List seeds,
    required String anfrageId,
    required String kindId,
    required int keyVersion,
    required String elternId,
    required Personenschluessel eltern,
    required int elternVersion,
    required Uint8List tempPub,
  }) {
    final sealed = crypto.versiegeln(seeds, tempPub);
    final sig = crypto.signieren(_freigabeEingabe(anfrageId, kindId, keyVersion, elternId, elternVersion, sealed, tempPub), eltern.signGeheim);
    return HinterlegungEintrag(base64urlKodieren(sealed), base64urlKodieren(sig));
  }

  /// Das Kind öffnet die Übergabe: prüft die Signatur gegen den VERTRAUTEN Schlüssel des Elternteils, öffnet mit dem flüchtigen geheimen Schlüssel und liefert den
  /// Personenschlüssel. Der Aufrufer vergleicht ihn mit dem Schlüssel des Servers, bevor er etwas übernimmt.
  static Personenschluessel freigabeOeffnen(
    CryptoProvider crypto, {
    required String blob,
    required String sig,
    required String anfrageId,
    required String kindId,
    required int keyVersion,
    required String elternId,
    required OeffentlicheSchluessel elternVertraut,
    required FluechtigesPaar paar,
  }) {
    final sealed = base64urlDekodieren(blob);
    final signatur = base64urlDekodieren(sig);
    if (!crypto.signaturPruefen(_freigabeEingabe(anfrageId, kindId, keyVersion, elternId, elternVertraut.version, sealed, paar.oeffentlich), signatur, elternVertraut.sign)) throw _signatur();
    final seeds = crypto.versiegelungOeffnen(sealed, paar.oeffentlich, paar.geheim);
    try {
      return Personenschluessel.ausBytes(crypto, seeds);
    } finally {
      loescheBytes(seeds);
    }
  }
}
