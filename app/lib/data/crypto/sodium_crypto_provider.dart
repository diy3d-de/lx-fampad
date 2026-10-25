// Echte Bausteine: libsodium über das Paket `sodium` (Sumo-Variante). Android/Desktop: native Bibliothek per Build-Hook,
// Web: selbst gehostete web/sodium.js (CSP: nur 'self', WASM eingebettet -> 'wasm-unsafe-eval').
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'bytes.dart';
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

  /// Argon2id (crypto_pwhash_argon2id) im Isolate: Auf Android/Desktop blockiert die Rechnung (64 MiB) die Oberfläche nicht. Im Web führt `runIsolated`
  /// den Rückruf im Hauptthread aus (sodium.js hat keinen Worker): die Oberfläche steht dort während der Rechnung (Messwerte: Projektbeschreibung 9a).
  @override
  Future<Uint8List> pwhash({required Uint8List passwort, required Uint8List salt, required int memKiB, required int ops}) async {
    final pw = _s.crypto.pwhash;
    final mem = memKiB * 1024;
    if (salt.length != pw.saltBytes || ops < pw.opsLimitMin || ops > pw.opsLimitMax || mem < pw.memLimitMin || mem > pw.memLimitMax) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Parameter der Schlüsselableitung.');
    }
    final eingabe = Int8List.fromList(passwort);
    final sodium = _s;
    try {
      final key = await sodium.runIsolated(
        (_, _) => sodium.crypto.pwhash.callRaw(
          outLen: 32,
          password: eingabe,
          salt: salt,
          opsLimit: ops,
          memLimit: mem,
          alg: CryptoPwhashAlgorithm.argon2id13,
        ),
      );
      try {
        return key.extractBytes();
      } finally {
        key.dispose();
      }
    } on SodiumException {
      throw _intern;
    } finally {
      eingabe.fillRange(0, eingabe.length, 0);
    }
  }

  @override
  Uint8List kdf(Uint8List master, String kontext, {int laenge = 32}) => hash(utf8Bytes(kontext), schluessel: master, laenge: laenge);

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

  @override
  Future<Uint8List> stromVerschluesseln({required Uint8List schluessel, required Uint8List klartext, int blockBytes = 65536}) async {
    final ss = _s.crypto.secretStream;
    if (schluessel.length != ss.keyBytes || blockBytes < 1) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssel- oder Blocklänge.');
    final key = _s.secureCopy(schluessel);
    try {
      // jeder Block ausdrücklich getaggt: der letzte als FINAL (auch bei leerem Klartext genau ein leerer FINAL-Block)
      final bloecke = <SecretStreamPlainMessage>[];
      var pos = 0;
      do {
        final ende = pos + blockBytes < klartext.length ? pos + blockBytes : klartext.length;
        bloecke.add(SecretStreamPlainMessage(Uint8List.sublistView(klartext, pos, ende), tag: ende >= klartext.length ? SecretStreamMessageTag.finalPush : SecretStreamMessageTag.message));
        pos = ende;
      } while (pos < klartext.length);
      final raus = BytesBuilder(copy: false);
      await for (final m in ss.pushEx(messageStream: Stream.fromIterable(bloecke), key: key)) {
        raus.add(m.message);
      }
      return raus.takeBytes();
    } on Object {
      throw _intern;
    } finally {
      key.dispose();
    }
  }

  @override
  Future<Uint8List> stromEntschluesseln({required Uint8List schluessel, required Uint8List chiffretext, int blockBytes = 65536}) async {
    const fehler = CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    final ss = _s.crypto.secretStream;
    final kopf = ss.headerBytes;
    final block = blockBytes + ss.aBytes;
    // Kopfzeile plus mindestens ein (auch leerer) Block
    if (schluessel.length != ss.keyBytes || blockBytes < 1 || chiffretext.length < kopf + ss.aBytes) throw fehler;
    final key = _s.secureCopy(schluessel);
    try {
      final stuecke = <SecretStreamCipherMessage>[SecretStreamCipherMessage(Uint8List.sublistView(chiffretext, 0, kopf))];
      for (var pos = kopf; pos < chiffretext.length; pos += block) {
        final ende = pos + block < chiffretext.length ? pos + block : chiffretext.length;
        stuecke.add(SecretStreamCipherMessage(Uint8List.sublistView(chiffretext, pos, ende)));
      }
      final raus = BytesBuilder(copy: false);
      var istFinal = false;
      // ein FINAL-Block muss der letzte sein (der Strom endet danach); ein Strom ohne FINAL-Block wirft (gekürzt)
      await for (final m in ss.pullEx(cipherStream: Stream.fromIterable(stuecke), key: key)) {
        if (istFinal) throw fehler;
        raus.add(m.message);
        if (m.tag == SecretStreamMessageTag.finalPush) istFinal = true;
      }
      if (!istFinal) throw fehler;
      return raus.takeBytes();
    } on Object {
      throw fehler;
    } finally {
      key.dispose();
    }
  }
}
