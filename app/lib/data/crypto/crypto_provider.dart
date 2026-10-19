// Schnittstelle zu den kryptografischen Bausteinen. Die App benutzt ausschließlich geprüfte libsodium-Funktionen
// (siehe sodium_crypto_provider.dart); eigene Primitive gibt es nicht. Die Schnittstelle trennt die Logik von der nativen
// Bibliothek: Tests können einen Fake einsetzen (test/support/fake_crypto.dart), echte Bausteine laufen in den Known-Answer-Tests.
import 'dart:typed_data';

/// Schlüsselpaar aus öffentlichem und geheimem Teil.
class SchluesselPaar {
  final Uint8List oeffentlich;
  final Uint8List geheim;
  const SchluesselPaar(this.oeffentlich, this.geheim);
}

abstract interface class CryptoProvider {
  /// Kryptografisch sichere Zufallsbytes.
  Uint8List zufall(int laenge);

  /// BLAKE2b (crypto_generichash), optional mit Schlüssel (16 bis 64 Byte) als Schlüsselableitung.
  Uint8List hash(Uint8List nachricht, {Uint8List? schluessel, int laenge = 32});

  /// X25519-Paar (crypto_box) aus einem 32-Byte-Seed; geheim = 32 Byte.
  SchluesselPaar boxPaarAusSeed(Uint8List seed);

  /// Ed25519-Paar (crypto_sign) aus einem 32-Byte-Seed; geheim = 64 Byte (Seed + öffentlicher Teil).
  SchluesselPaar signPaarAusSeed(Uint8List seed);

  /// Ed25519-Signatur, abgetrennt (64 Byte).
  Uint8List signieren(Uint8List nachricht, Uint8List geheimerSchluessel);

  bool signaturPruefen(Uint8List nachricht, Uint8List signatur, Uint8List oeffentlicherSchluessel);

  /// XChaCha20-Poly1305-IETF: Schlüssel 32 Byte, Nonce 24 Byte; Ergebnis = Chiffretext + 16 Byte Tag.
  Uint8List verschluesseln({required Uint8List schluessel, required Uint8List nonce, required Uint8List klartext, Uint8List? zusatzdaten});

  /// Wirft CryptoFehler (entschluesselung), wenn Schlüssel, Nonce, Zusatzdaten oder Chiffretext nicht passen.
  Uint8List entschluesseln({required Uint8List schluessel, required Uint8List nonce, required Uint8List chiffretext, Uint8List? zusatzdaten});

  /// Sealed Box (crypto_box_seal): anonym an einen öffentlichen X25519-Schlüssel verschlüsseln (für die Schlüsselverteilung in Phase 2).
  Uint8List versiegeln(Uint8List nachricht, Uint8List oeffentlicherSchluessel);

  Uint8List versiegelungOeffnen(Uint8List chiffretext, Uint8List oeffentlicherSchluessel, Uint8List geheimerSchluessel);
}
