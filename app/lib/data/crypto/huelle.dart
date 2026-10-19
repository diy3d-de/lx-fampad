// Versionierte Hülle für verschlüsselte, signierte Nachrichten (Chat in Phase 2). Binärformat, als Base64url (ohne Auffüllzeichen) abgelegt:
//
//   v (1) | alg (1) | epoch (4, BE) | sender_key_version (4, BE) | nonce (24) | signatur (64) | chiffretext (Klartext + 16 Byte Tag)
//
// v = 1, alg = 1: XChaCha20-Poly1305-IETF (Zufalls-Nonce) mit Ed25519-Signatur des Absenders.
// AAD (an den Chiffretext gebunden) = "conversation_id|message_id|sender_id|epoch|sender_key_version|v" (UTF-8).
// Signatur = Ed25519 über  'lx-familyhub|msg|v1' | len(aad) (u32) | aad | kopf | chiffretext  (Domänentrennung, Längenrahmen; domaenen.dart),
// mit kopf = v | alg | epoch | sender_key_version | nonce. Sie deckt also Kopf, Chiffretext und AAD ab (sonst könnte jedes Mitglied mit dem
// Gruppenschlüssel als eine andere Person schreiben). Beim Öffnen wird zuerst die Signatur geprüft, dann entschlüsselt.
// sender_key_version nennt die Version des Signaturschlüssels des Absenders: Der Empfänger prüft gegen genau diesen Schlüssel (aus dem
// TOFU-Speicher bzw. der Schlüsselhistorie des Servers), auch nach einem Schlüsselwechsel des Absenders.
// Nicht verborgen bleiben Länge und Metadaten (Konversation, Absender, Zeit liegen beim Server).
import 'dart:collection';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'domaenen.dart';
import 'schluessel.dart';

const int kHuelleVersion = 1;
const int kAlgXChaCha20Poly1305 = 1;
const int kNonceLaenge = 24;
const int kSignaturLaenge = 64;
const int kTagLaenge = 16;
const int _kopfLaenge = 1 + 1 + 4 + 4 + kNonceLaenge;

/// Kontext einer Nachricht; geht als AAD in die Verschlüsselung und in die Signatur ein.
class HuellenKontext {
  final String conversationId;
  final String messageId;
  final String senderId;
  final int epoch;

  /// Version des Signaturschlüssels des Absenders (key_version beim Server).
  final int senderKeyVersion;
  const HuellenKontext({required this.conversationId, required this.messageId, required this.senderId, required this.epoch, required this.senderKeyVersion});

  /// "conversation_id|message_id|sender_id|epoch|sender_key_version|v". Ein Trennzeichen in einer ID wäre mehrdeutig und wird abgelehnt.
  Uint8List aad(int version) {
    for (final t in [conversationId, messageId, senderId]) {
      if (t.isEmpty || t.contains('|')) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültiger Nachrichtenkontext.');
    }
    if (epoch < 0 || epoch > 0xFFFFFFFF || senderKeyVersion < 1 || senderKeyVersion > 0xFFFFFFFF) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültiger Nachrichtenkontext.');
    }
    return utf8Bytes('$conversationId|$messageId|$senderId|$epoch|$senderKeyVersion|$version');
  }
}

Uint8List _signaturEingabe(Uint8List aad, Uint8List kopf, Uint8List ct) => verketten([utf8Bytes(kDomaeneNachricht), u32Bytes(aad.length), aad, kopf, ct]);

class HuellenCodec {
  final CryptoProvider crypto;

  /// Zuletzt benutzte Nonces dieser Instanz. **Kein Garant**: Die Liste gilt nur im laufenden Prozess und für diese Instanz, kennt weder andere Geräte
  /// noch frühere Läufe und ist begrenzt. Die Sicherheit beruht auf 192-Bit-Zufalls-Nonces (XChaCha20); der Wächter fängt nur einen
  /// offensichtlich kaputten Zufallsgenerator innerhalb eines Laufs ab.
  final LinkedHashSet<String> _benutzt = LinkedHashSet<String>();
  static const int _merke = 8192;

  HuellenCodec(this.crypto);

  /// Liest die Version des Absender-Schlüssels aus der Hülle, ohne sie zu prüfen (damit der Empfänger den passenden Schlüssel besorgen kann).
  /// Die Angabe ist erst durch Signatur und AAD in [oeffnen] verbindlich.
  static int senderKeyVersionLesen(String huelle) {
    final bytes = base64urlDekodieren(huelle);
    if (bytes.length < _kopfLaenge + kSignaturLaenge + kTagLaenge) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Nachricht ist beschädigt.');
    return u32Lesen(bytes, 6);
  }

  /// Liest die Epoche aus der Hülle, ohne sie zu prüfen (damit der Empfänger den Epochenschlüssel besorgen kann). Verbindlich erst durch Signatur und AAD in [oeffnen].
  static int epocheLesen(String huelle) {
    final bytes = base64urlDekodieren(huelle);
    if (bytes.length < _kopfLaenge + kSignaturLaenge + kTagLaenge) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Nachricht ist beschädigt.');
    return u32Lesen(bytes, 2);
  }

  /// Verschlüsselt und signiert [klartext] mit dem Epochenschlüssel [schluessel] (32 Byte). [signGeheim] ist der Ed25519-Schlüssel des Absenders in
  /// der Version [kontext].senderKeyVersion.
  String versiegeln({required Uint8List schluessel, required Uint8List klartext, required HuellenKontext kontext, required Uint8List signGeheim}) {
    final nonce = crypto.zufall(kNonceLaenge);
    final merk = '${base64urlKodieren(crypto.hash(schluessel, laenge: 16))}.${base64urlKodieren(nonce)}';
    if (!_benutzt.add(merk)) throw const CryptoFehler(CryptoFehlerArt.nonce, 'Nonce darf nicht wiederverwendet werden.');
    if (_benutzt.length > _merke) _benutzt.remove(_benutzt.first);

    final aad = kontext.aad(kHuelleVersion);
    final kopf = verketten([
      [kHuelleVersion, kAlgXChaCha20Poly1305],
      u32Bytes(kontext.epoch),
      u32Bytes(kontext.senderKeyVersion),
      nonce,
    ]);
    final ct = crypto.verschluesseln(schluessel: schluessel, nonce: nonce, klartext: klartext, zusatzdaten: aad);
    final signatur = crypto.signieren(_signaturEingabe(aad, kopf, ct), signGeheim);
    return base64urlKodieren(verketten([kopf, signatur, ct]));
  }

  /// Prüft Signatur (gegen [sender], die Schlüsselversion muss zu Hülle und Kontext passen) und AAD, entschlüsselt dann.
  /// Wirft [CryptoFehler] (format, version, signatur, entschluesselung).
  Uint8List oeffnen({required Uint8List schluessel, required String huelle, required HuellenKontext kontext, required OeffentlicheSchluessel sender}) {
    final bytes = base64urlDekodieren(huelle);
    if (bytes.length < _kopfLaenge + kSignaturLaenge + kTagLaenge) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Nachricht ist beschädigt.');
    final v = bytes[0];
    final alg = bytes[1];
    if (v != kHuelleVersion || alg != kAlgXChaCha20Poly1305) {
      throw const CryptoFehler(CryptoFehlerArt.version, 'Diese Nachricht benötigt eine neuere App-Version.');
    }
    final epoch = u32Lesen(bytes, 2);
    final senderVersion = u32Lesen(bytes, 6);
    if (epoch != kontext.epoch || senderVersion != kontext.senderKeyVersion) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Nachricht ist beschädigt.');
    if (sender.version != senderVersion) {
      throw const CryptoFehler(CryptoFehlerArt.signatur, 'Der Absender hat die Nachricht mit einer anderen Schlüsselversion signiert.');
    }
    final kopf = Uint8List.sublistView(bytes, 0, _kopfLaenge);
    final nonce = Uint8List.sublistView(bytes, 10, _kopfLaenge);
    final signatur = Uint8List.sublistView(bytes, _kopfLaenge, _kopfLaenge + kSignaturLaenge);
    final ct = Uint8List.sublistView(bytes, _kopfLaenge + kSignaturLaenge);
    final aad = kontext.aad(v);
    if (!crypto.signaturPruefen(_signaturEingabe(aad, kopf, ct), signatur, sender.sign)) {
      throw const CryptoFehler(CryptoFehlerArt.signatur, 'Der Absender der Nachricht konnte nicht bestätigt werden.');
    }
    return crypto.entschluesseln(schluessel: schluessel, nonce: nonce, chiffretext: ct, zusatzdaten: aad);
  }
}
