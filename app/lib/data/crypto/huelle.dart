// Versionierte Hülle für verschlüsselte, signierte Nachrichten (Chat in Phase 2). Binärformat, als Base64url (ohne Auffüllzeichen) abgelegt:
//
//   v (1 Byte) | alg (1 Byte) | epoch (4 Byte, BE) | nonce (24 Byte) | signatur (64 Byte) | chiffretext (Klartext + 16 Byte Tag)
//
// v = 1, alg = 1: XChaCha20-Poly1305-IETF (Zufalls-Nonce) mit Ed25519-Signatur des Absenders.
// AAD (an den Chiffretext gebunden) = "conversation_id|message_id|sender_id|epoch|v" (UTF-8).
// Die Signatur deckt Kopf (v, alg, epoch, nonce), Chiffretext UND AAD ab: ohne sie könnte jedes Mitglied mit dem Gruppenschlüssel
// als eine andere Person schreiben. Beim Öffnen wird zuerst die Signatur geprüft, dann entschlüsselt.
// Nicht verborgen bleiben Länge und Metadaten (Konversation, Absender, Zeit liegen beim Server).
import 'dart:collection';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';

const int kHuelleVersion = 1;
const int kAlgXChaCha20Poly1305 = 1;
const int kNonceLaenge = 24;
const int kSignaturLaenge = 64;
const int kTagLaenge = 16;
const int _kopfLaenge = 1 + 1 + 4 + kNonceLaenge;

/// Kontext einer Nachricht; geht als AAD in die Verschlüsselung und in die Signatur ein.
class HuellenKontext {
  final String conversationId;
  final String messageId;
  final String senderId;
  final int epoch;
  const HuellenKontext({required this.conversationId, required this.messageId, required this.senderId, required this.epoch});

  /// "conversation_id|message_id|sender_id|epoch|v". Ein Trennzeichen in einer ID wäre mehrdeutig und wird abgelehnt.
  Uint8List aad(int version) {
    for (final t in [conversationId, messageId, senderId]) {
      if (t.isEmpty || t.contains('|')) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültiger Nachrichtenkontext.');
    }
    if (epoch < 0 || epoch > 0xFFFFFFFF) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültiger Nachrichtenkontext.');
    return utf8Bytes('$conversationId|$messageId|$senderId|$epoch|$version');
  }
}

class HuellenCodec {
  final CryptoProvider crypto;

  /// Zuletzt benutzte Nonces (Schutz gegen einen kaputten Zufallsgenerator: dieselbe Nonce mit demselben Schlüssel wäre fatal).
  final LinkedHashSet<String> _benutzt = LinkedHashSet<String>();
  static const int _merke = 8192;

  HuellenCodec(this.crypto);

  /// Verschlüsselt und signiert [klartext] mit dem Epochenschlüssel [schluessel] (32 Byte). [signGeheim] ist der Ed25519-Schlüssel des Absenders.
  String versiegeln({required Uint8List schluessel, required Uint8List klartext, required HuellenKontext kontext, required Uint8List signGeheim}) {
    final nonce = crypto.zufall(kNonceLaenge);
    final merk = '${base64urlKodieren(crypto.hash(schluessel, laenge: 16))}.${base64urlKodieren(nonce)}';
    if (!_benutzt.add(merk)) throw const CryptoFehler(CryptoFehlerArt.nonce, 'Nonce darf nicht wiederverwendet werden.');
    if (_benutzt.length > _merke) _benutzt.remove(_benutzt.first);

    final aad = kontext.aad(kHuelleVersion);
    final kopf = verketten([
      [kHuelleVersion, kAlgXChaCha20Poly1305],
      u32Bytes(kontext.epoch),
      nonce,
    ]);
    final ct = crypto.verschluesseln(schluessel: schluessel, nonce: nonce, klartext: klartext, zusatzdaten: aad);
    final signatur = crypto.signieren(verketten([kopf, ct, aad]), signGeheim);
    return base64urlKodieren(verketten([kopf, signatur, ct]));
  }

  /// Prüft Signatur (gegen [senderSignOeffentlich]) und AAD, entschlüsselt dann. Wirft [CryptoFehler] (format, version, signatur, entschluesselung).
  Uint8List oeffnen({required Uint8List schluessel, required String huelle, required HuellenKontext kontext, required Uint8List senderSignOeffentlich}) {
    final bytes = base64urlDekodieren(huelle);
    if (bytes.length < _kopfLaenge + kSignaturLaenge + kTagLaenge) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Nachricht ist beschädigt.');
    final v = bytes[0];
    final alg = bytes[1];
    if (v != kHuelleVersion || alg != kAlgXChaCha20Poly1305) {
      throw const CryptoFehler(CryptoFehlerArt.version, 'Diese Nachricht benötigt eine neuere App-Version.');
    }
    final epoch = u32Lesen(bytes, 2);
    if (epoch != kontext.epoch) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Nachricht ist beschädigt.');
    final kopf = Uint8List.sublistView(bytes, 0, _kopfLaenge);
    final nonce = Uint8List.sublistView(bytes, 6, _kopfLaenge);
    final signatur = Uint8List.sublistView(bytes, _kopfLaenge, _kopfLaenge + kSignaturLaenge);
    final ct = Uint8List.sublistView(bytes, _kopfLaenge + kSignaturLaenge);
    final aad = kontext.aad(v);
    if (!crypto.signaturPruefen(verketten([kopf, ct, aad]), signatur, senderSignOeffentlich)) {
      throw const CryptoFehler(CryptoFehlerArt.signatur, 'Der Absender der Nachricht konnte nicht bestätigt werden.');
    }
    return crypto.entschluesseln(schluessel: schluessel, nonce: nonce, chiffretext: ct, zusatzdaten: aad);
  }
}
