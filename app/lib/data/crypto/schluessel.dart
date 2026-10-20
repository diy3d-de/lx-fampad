// Personenschlüssel: Jede Person hat EIN Schlüsselpaar-Set (X25519 für Sealed Boxes, Ed25519 für Signaturen), das alle ihre Geräte teilen.
// Der geheime Teil besteht aus zwei 32-Byte-Seeds (zusammen 64 Byte); alles Weitere wird daraus abgeleitet. Er verlässt das Gerät nur
// verschlüsselt (Schlüsselsicherung mit dem Wiederherstellungsschlüssel, Übertragung auf ein neues Gerät per QR).
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';

const int kSchluesselLaenge = 32;

/// Öffentliche Schlüssel einer Person samt Versionszähler des Servers (`keyVersion`, steigt bei jedem Schlüsselwechsel).
class OeffentlicheSchluessel {
  final Uint8List enc;
  final Uint8List sign;
  final int version;

  OeffentlicheSchluessel({required Uint8List enc, required Uint8List sign, required this.version})
    : enc = Uint8List.fromList(enc),
      sign = Uint8List.fromList(sign) {
    if (enc.length != kSchluesselLaenge || sign.length != kSchluesselLaenge) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    }
  }

  /// Aus den Feldern der Server-Antwort (Base64url); wirft [CryptoFehler] bei ungültiger Form.
  factory OeffentlicheSchluessel.ausBase64({required String enc, required String sign, required int version}) =>
      OeffentlicheSchluessel(enc: base64urlDekodieren(enc), sign: base64urlDekodieren(sign), version: version);

  String get encBase64 => base64urlKodieren(enc);
  String get signBase64 => base64urlKodieren(sign);

  /// Gleiche Schlüssel (die Version zählt nicht zur Identität).
  bool gleichWie(OeffentlicheSchluessel other) => gleicheBytes(enc, other.enc) && gleicheBytes(sign, other.sign);
}

class Personenschluessel {
  final Uint8List _encSeed;
  final Uint8List _signSeed;
  final Uint8List _encGeheim;
  final Uint8List _signGeheim;
  final Uint8List encOeffentlich;
  final Uint8List signOeffentlich;

  Personenschluessel._(this._encSeed, this._signSeed, this._encGeheim, this._signGeheim, this.encOeffentlich, this.signOeffentlich);

  /// Neues zufälliges Schlüsselset.
  factory Personenschluessel.erzeugen(CryptoProvider crypto) => Personenschluessel._ausSeeds(crypto, crypto.zufall(kSchluesselLaenge), crypto.zufall(kSchluesselLaenge));

  /// Aus den 64 exportierten Bytes ([exportieren]).
  factory Personenschluessel.ausBytes(CryptoProvider crypto, Uint8List bytes) {
    if (bytes.length != 2 * kSchluesselLaenge) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    return Personenschluessel._ausSeeds(crypto, Uint8List.sublistView(bytes, 0, kSchluesselLaenge), Uint8List.sublistView(bytes, kSchluesselLaenge));
  }

  factory Personenschluessel._ausSeeds(CryptoProvider crypto, Uint8List encSeed, Uint8List signSeed) {
    final box = crypto.boxPaarAusSeed(encSeed);
    final sign = crypto.signPaarAusSeed(signSeed);
    return Personenschluessel._(
      Uint8List.fromList(encSeed),
      Uint8List.fromList(signSeed),
      box.geheim,
      sign.geheim,
      Uint8List.fromList(box.oeffentlich),
      Uint8List.fromList(sign.oeffentlich),
    );
  }

  /// Der geheime Teil als 64 Byte (Seeds). Nur für die verschlüsselte Ablage, Sicherung und Übertragung.
  Uint8List exportieren() => verketten([_encSeed, _signSeed]);

  /// Geheimer X25519-Schlüssel (für Sealed Boxes in Phase 2).
  Uint8List get encGeheim => _encGeheim;

  /// Geheimer Ed25519-Schlüssel (64 Byte, für Signaturen).
  Uint8List get signGeheim => _signGeheim;

  OeffentlicheSchluessel oeffentlich(int version) => OeffentlicheSchluessel(enc: encOeffentlich, sign: signOeffentlich, version: version);

  /// Überschreibt die geheimen Bytes (best effort).
  void loeschen() {
    loescheBytes(_encSeed);
    loescheBytes(_signSeed);
    loescheBytes(_encGeheim);
    loescheBytes(_signGeheim);
  }
}
