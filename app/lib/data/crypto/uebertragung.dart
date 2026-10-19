// Übertragung des Personenschlüssels auf ein neues Gerät derselben Person (QR oder Code zum Abtippen).
//
// Das vorhandene Gerät erzeugt ein 32-Byte-Einmalgeheimnis S. Daraus leitet es zwei unabhängige Werte ab: eine Suchkennung (geht an den
// Server) und einen Verpackungsschlüssel (bleibt auf den Geräten). Der Personenschlüssel wird damit verschlüsselt und als kurzlebiger Blob
// (2 Minuten, einmal einlösbar) über den Server gereicht. S selbst sieht der Server nie: es steht nur im QR bzw. im Code, den das neue Gerät
// einliest. Das neue Gerät löst mit der Suchkennung ein und entschlüsselt mit S.
//
// QR-Inhalt: "LXK1:" + 56 Zeichen (ohne Bindestriche). Zum Abtippen: dieselben 56 Zeichen in 14 Vierergruppen (Prüfsumme wie beim Wiederherstellungsschlüssel).
// Blob (Base64url): v (1 Byte) | nonce (24 Byte) | chiffretext (64 Byte + 16 Byte Tag); AAD = "lx-fampad|key-transfer|v1|user_id|key_version".
import 'dart:typed_data';

import 'bytes.dart';
import 'code32.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'schluessel.dart';

const String _zweckAnzeige = 'lx-fampad|uebertragung|v1';
const String _zweckSuche = 'lx-fampad|e2ee|transfer-lookup|v1';
const String _zweckSchluessel = 'lx-fampad|e2ee|transfer-key|v1';
const String kQrPraefix = 'LXK1:';
const int _blobVersion = 1;
const int _nonce = 24;

/// Was das vorhandene Gerät bereitstellt: [geheimnis] nur in QR/Code, [suchkennung] und [blob] zum Server.
class UebertragungsAngebot {
  final Uint8List geheimnis;
  final String suchkennung;
  final String blob;
  const UebertragungsAngebot({required this.geheimnis, required this.suchkennung, required this.blob});
}

class Uebertragung {
  static Uint8List _ableiten(CryptoProvider crypto, String zweck, Uint8List geheimnis) => crypto.hash(utf8Bytes(zweck), schluessel: geheimnis);

  static Uint8List _aad(String userId, int keyVersion) => utf8Bytes('lx-fampad|key-transfer|v1|$userId|$keyVersion');

  /// Suchkennung (Base64url, 32 Byte) für den Server; lässt keinen Rückschluss auf das Geheimnis zu.
  static String suchkennung(CryptoProvider crypto, Uint8List geheimnis) => base64urlKodieren(_ableiten(crypto, _zweckSuche, geheimnis));

  static UebertragungsAngebot anbieten(CryptoProvider crypto, {required Personenschluessel schluessel, required String userId, required int keyVersion}) {
    final geheimnis = crypto.zufall(kGeheimnisLaenge);
    final nonce = crypto.zufall(_nonce);
    final ct = crypto.verschluesseln(
      schluessel: _ableiten(crypto, _zweckSchluessel, geheimnis),
      nonce: nonce,
      klartext: schluessel.exportieren(),
      zusatzdaten: _aad(userId, keyVersion),
    );
    return UebertragungsAngebot(
      geheimnis: geheimnis,
      suchkennung: suchkennung(crypto, geheimnis),
      blob: base64urlKodieren(verketten([
        [_blobVersion],
        nonce,
        ct,
      ])),
    );
  }

  /// QR-Text (kompakt).
  static String qrText(Uint8List geheimnis) => '$kQrPraefix${Code32.kodieren(geheimnis, _zweckAnzeige, gruppiert: false)}';

  /// Code zum Abtippen (14 Vierergruppen).
  static String codeText(Uint8List geheimnis) => Code32.kodieren(geheimnis, _zweckAnzeige);

  /// Liest QR-Text oder abgetippten Code; wirft [CryptoFehler] (format/pruefsumme).
  static Uint8List geheimnisLesen(String eingabe) {
    var text = eingabe.trim();
    if (text.toUpperCase().startsWith(kQrPraefix)) text = text.substring(kQrPraefix.length);
    return Code32.dekodieren(text, _zweckAnzeige);
  }

  /// Entschlüsselt den eingelösten Blob mit dem Geheimnis aus dem QR; [userId] und [keyVersion] müssen zur Antwort des Servers passen.
  static Personenschluessel oeffnen(CryptoProvider crypto, {required String blob, required Uint8List geheimnis, required String userId, required int keyVersion}) {
    final bytes = base64urlDekodieren(blob);
    if (bytes.length < 1 + _nonce + 2 * kSchluesselLaenge + 16) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Übertragung ist beschädigt.');
    if (bytes[0] != _blobVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Übertragung stammt von einer neueren App-Version.');
    final klartext = crypto.entschluesseln(
      schluessel: _ableiten(crypto, _zweckSchluessel, geheimnis),
      nonce: Uint8List.sublistView(bytes, 1, 1 + _nonce),
      chiffretext: Uint8List.sublistView(bytes, 1 + _nonce),
      zusatzdaten: _aad(userId, keyVersion),
    );
    try {
      return Personenschluessel.ausBytes(crypto, klartext);
    } finally {
      loescheBytes(klartext);
    }
  }
}
