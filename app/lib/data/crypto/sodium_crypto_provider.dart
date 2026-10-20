// Echte Bausteine: libsodium über das Paket `sodium` (Sumo-Variante). Android/Desktop: native Bibliothek per Build-Hook,
// Web: selbst gehostete web/sodium.js (CSP: nur 'self', WASM eingebettet -> 'wasm-unsafe-eval').
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'crypto_fehler.dart';
import 'crypto_provider.dart';

class SodiumCryptoProvider implements CryptoProvider {
  final SodiumSumo _s;
  SodiumCryptoProvider(this._s);

  /// Lädt libsodium. Wirft [CryptoFehler] (bibliothek), wenn sie nicht verfügbar ist (z. B. sodium.js fehlt im Web).
  static Future<SodiumCryptoProvider> laden() async {
    try {
      return SodiumCryptoProvider(await SodiumSumoInit.init());
    } on Object {
      throw const CryptoFehler(CryptoFehlerArt.bibliothek, 'Die Verschlüsselung ist auf diesem Gerät nicht verfügbar.');
    }
  }

  /// Führt [f] mit einem geschützten Schlüssel aus und gibt ihn danach frei.
  T _mitSchluessel<T>(Uint8List bytes, T Function(SecureKey key) f) {
    final key = _s.secureCopy(bytes);
    try {
      return f(key);
    } finally {
      key.dispose();
    }
  }

  static const _intern = CryptoFehler(CryptoFehlerArt.bibliothek, 'Die Verschlüsselung hat einen Fehler gemeldet.');

  @override
  Uint8List zufall(int laenge) => _s.randombytes.buf(laenge);

  @override
  Uint8List hash(Uint8List nachricht, {Uint8List? schluessel, int laenge = 32}) {
    try {
      if (schluessel == null) return _s.crypto.genericHash(message: nachricht, outLen: laenge);
      return _mitSchluessel(schluessel, (k) => _s.crypto.genericHash(message: nachricht, outLen: laenge, key: k));
    } on SodiumException {
      throw _intern;
    }
  }

  @override
  SchluesselPaar boxPaarAusSeed(Uint8List seed) => _paar(seed, _s.crypto.box.seedKeyPair);

  @override
  SchluesselPaar signPaarAusSeed(Uint8List seed) => _paar(seed, _s.crypto.sign.seedKeyPair);

  SchluesselPaar _paar(Uint8List seed, KeyPair Function(SecureKey seed) erzeugen) {
    if (seed.length != 32) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    try {
      return _mitSchluessel(seed, (k) {
        final kp = erzeugen(k);
        try {
          return SchluesselPaar(Uint8List.fromList(kp.publicKey), kp.secretKey.extractBytes());
        } finally {
          kp.dispose();
        }
      });
    } on SodiumException {
      throw _intern;
    }
  }

  @override
  Uint8List signieren(Uint8List nachricht, Uint8List geheimerSchluessel) {
    try {
      return _mitSchluessel(geheimerSchluessel, (k) => _s.crypto.sign.detached(message: nachricht, secretKey: k));
    } on SodiumException {
      throw _intern;
    }
  }

  @override
  bool signaturPruefen(Uint8List nachricht, Uint8List signatur, Uint8List oeffentlicherSchluessel) {
    if (signatur.length != _s.crypto.sign.bytes || oeffentlicherSchluessel.length != _s.crypto.sign.publicKeyBytes) return false;
    try {
      return _s.crypto.sign.verifyDetached(message: nachricht, signature: signatur, publicKey: oeffentlicherSchluessel);
    } on SodiumException {
      return false;
    }
  }

  Aead get _aead => _s.crypto.aeadXChaCha20Poly1305IETF;

  @override
  Uint8List verschluesseln({required Uint8List schluessel, required Uint8List nonce, required Uint8List klartext, Uint8List? zusatzdaten}) {
    if (schluessel.length != _aead.keyBytes || nonce.length != _aead.nonceBytes) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssel- oder Nonce-Länge.');
    }
    try {
      return _mitSchluessel(schluessel, (k) => _aead.encrypt(message: klartext, nonce: nonce, key: k, additionalData: zusatzdaten));
    } on SodiumException {
      throw _intern;
    }
  }

  @override
  Uint8List entschluesseln({required Uint8List schluessel, required Uint8List nonce, required Uint8List chiffretext, Uint8List? zusatzdaten}) {
    if (schluessel.length != _aead.keyBytes || nonce.length != _aead.nonceBytes || chiffretext.length < _aead.aBytes) {
      throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    }
    try {
      return _mitSchluessel(schluessel, (k) => _aead.decrypt(cipherText: chiffretext, nonce: nonce, key: k, additionalData: zusatzdaten));
    } on SodiumException {
      throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    }
  }

  @override
  Uint8List versiegeln(Uint8List nachricht, Uint8List oeffentlicherSchluessel) {
    if (oeffentlicherSchluessel.length != _s.crypto.box.publicKeyBytes) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    try {
      return _s.crypto.box.seal(message: nachricht, publicKey: oeffentlicherSchluessel);
    } on SodiumException {
      throw _intern;
    }
  }

  @override
  Uint8List versiegelungOeffnen(Uint8List chiffretext, Uint8List oeffentlicherSchluessel, Uint8List geheimerSchluessel) {
    if (oeffentlicherSchluessel.length != _s.crypto.box.publicKeyBytes || chiffretext.length < _s.crypto.box.sealBytes) {
      throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    }
    try {
      return _mitSchluessel(geheimerSchluessel, (k) => _s.crypto.box.sealOpen(cipherText: chiffretext, publicKey: oeffentlicherSchluessel, secretKey: k));
    } on SodiumException {
      throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    }
  }
}
