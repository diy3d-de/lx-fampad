// Known-Answer-Tests für die echten libsodium-Bausteine (SodiumCryptoProvider): RFC-8032-Testvektor für Ed25519, BLAKE2b-Leerwert und
// Gegenprüfung gegen eine unabhängige, reine Dart-Implementierung (Paket cryptography) für XChaCha20-Poly1305, X25519 und Ed25519.
// Läuft nur, wo libsodium geladen werden kann (CI: Pflicht, SODIUM_ERFORDERLICH=1; lokal unter Windows fehlt der C-Compiler für den Build-Hook).
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart' as cr;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';

import '../support/fake_crypto.dart';

Uint8List _hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String _tohex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final sodium = await echtesSodium();
  final skip = sodium == null ? 'libsodium ist hier nicht verfügbar (Build-Hook braucht einen C-Compiler)' : null;

  group('libsodium Known-Answer', () {
    late CryptoProvider p;
    setUp(() => p = sodium!);

    test('Ed25519: RFC 8032, Testvektor 1 (leere Nachricht)', () {
      final seed = _hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
      final paar = p.signPaarAusSeed(seed);
      expect(_tohex(paar.oeffentlich), 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
      final sig = p.signieren(Uint8List(0), paar.geheim);
      expect(
        _tohex(sig),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(p.signaturPruefen(Uint8List(0), sig, paar.oeffentlich), isTrue);
      expect(p.signaturPruefen(Uint8List.fromList([0]), sig, paar.oeffentlich), isFalse);
      final kaputt = Uint8List.fromList(sig)..[10] ^= 1;
      expect(p.signaturPruefen(Uint8List(0), kaputt, paar.oeffentlich), isFalse);
      expect(p.signaturPruefen(Uint8List(0), Uint8List(10), paar.oeffentlich), isFalse);
    });

    test('Ed25519: RFC 8032, Testvektor 2 (ein Byte 0x72)', () {
      final seed = _hex('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb');
      final paar = p.signPaarAusSeed(seed);
      expect(_tohex(paar.oeffentlich), '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c');
      expect(
        _tohex(p.signieren(_hex('72'), paar.geheim)),
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );
    });

    test('BLAKE2b-256: Leerwert; Schlüssel und Eingabe verändern das Ergebnis', () {
      expect(_tohex(p.hash(Uint8List(0))), '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8');
      final k1 = Uint8List.fromList(List.filled(32, 1));
      final k2 = Uint8List.fromList(List.filled(32, 2));
      final m = utf8Bytes('lx-fampad');
      expect(p.hash(m, schluessel: k1), p.hash(m, schluessel: k1));
      expect(p.hash(m, schluessel: k1), isNot(p.hash(m, schluessel: k2)));
      expect(p.hash(m, schluessel: k1), isNot(p.hash(m)));
      expect(p.hash(m, schluessel: k1, laenge: 64), hasLength(64));
    });

    test('XChaCha20-Poly1305: Gegenprüfung mit unabhängiger Implementierung (beide Richtungen)', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => 0x80 + i));
      final nonce = Uint8List.fromList(List.generate(24, (i) => 0x40 + i));
      final aad = _hex('50515253c0c1c2c3c4c5c6c7');
      final klar = utf8Bytes('Ladies and Gentlemen of the class of \'99: If I could offer you only one tip for the future, sunscreen would be it.');
      final ct = p.verschluesseln(schluessel: key, nonce: nonce, klartext: klar, zusatzdaten: aad);
      expect(ct.length, klar.length + 16);

      final algo = cr.Xchacha20.poly1305Aead();
      final box = cr.SecretBox(ct.sublist(0, ct.length - 16), nonce: nonce, mac: cr.Mac(ct.sublist(ct.length - 16)));
      expect(await algo.decrypt(box, secretKey: cr.SecretKey(key), aad: aad), klar);

      final fremd = await algo.encrypt(klar, secretKey: cr.SecretKey(key), nonce: nonce, aad: aad);
      expect(Uint8List.fromList([...fremd.cipherText, ...fremd.mac.bytes]), ct, reason: 'deterministisch und identisch');
      expect(p.entschluesseln(schluessel: key, nonce: nonce, chiffretext: Uint8List.fromList([...fremd.cipherText, ...fremd.mac.bytes]), zusatzdaten: aad), klar);
    });

    test('XChaCha20-Poly1305: falscher Schlüssel, Nonce, AAD und veränderter Text werden abgelehnt', () {
      final key = p.zufall(32), nonce = p.zufall(24), aad = utf8Bytes('kontext');
      final ct = p.verschluesseln(schluessel: key, nonce: nonce, klartext: utf8Bytes('geheim'), zusatzdaten: aad);
      Never fail() => throw StateError('nicht abgelehnt');
      void lehntAb(void Function() f) {
        try {
          f();
          fail();
        } on CryptoFehler catch (e) {
          expect(e.art, CryptoFehlerArt.entschluesselung);
        }
      }

      lehntAb(() => p.entschluesseln(schluessel: p.zufall(32), nonce: nonce, chiffretext: ct, zusatzdaten: aad));
      lehntAb(() => p.entschluesseln(schluessel: key, nonce: p.zufall(24), chiffretext: ct, zusatzdaten: aad));
      lehntAb(() => p.entschluesseln(schluessel: key, nonce: nonce, chiffretext: ct, zusatzdaten: utf8Bytes('anders')));
      lehntAb(() => p.entschluesseln(schluessel: key, nonce: nonce, chiffretext: ct));
      lehntAb(() => p.entschluesseln(schluessel: key, nonce: nonce, chiffretext: Uint8List.fromList(ct)..[0] ^= 1, zusatzdaten: aad));
      lehntAb(() => p.entschluesseln(schluessel: key, nonce: nonce, chiffretext: Uint8List(5), zusatzdaten: aad));
    });

    test('X25519: öffentlicher Schlüssel aus Seed = X25519(SHA-512(seed)[0..32]) (unabhängige Gegenprüfung)', () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i * 3 + 1));
      final paar = p.boxPaarAusSeed(seed);
      final sk = Uint8List.fromList(c.sha512.convert(seed).bytes.sublist(0, 32));
      expect(paar.geheim, sk);
      final fremd = await cr.X25519().newKeyPairFromSeed(sk);
      expect((await fremd.extractPublicKey()).bytes, paar.oeffentlich);
    });

    test('Ed25519: Gegenprüfung mit unabhängiger Implementierung', () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final paar = p.signPaarAusSeed(seed);
      final fremd = await cr.Ed25519().newKeyPairFromSeed(seed);
      expect((await fremd.extractPublicKey()).bytes, paar.oeffentlich);
      final m = utf8Bytes('Nachricht');
      final sig = await cr.Ed25519().sign(m, keyPair: fremd);
      expect(p.signaturPruefen(m, Uint8List.fromList(sig.bytes), paar.oeffentlich), isTrue);
      expect(sig.bytes, p.signieren(m, paar.geheim), reason: 'Ed25519 ist deterministisch');
    });

    test('Sealed Box: nur das passende Paar öffnet', () {
      final a = p.boxPaarAusSeed(p.zufall(32));
      final b = p.boxPaarAusSeed(p.zufall(32));
      final c1 = p.versiegeln(utf8Bytes('Epochenschlüssel'), a.oeffentlich);
      expect(p.versiegelungOeffnen(c1, a.oeffentlich, a.geheim), utf8Bytes('Epochenschlüssel'));
      expect(() => p.versiegelungOeffnen(c1, b.oeffentlich, b.geheim), throwsA(isA<CryptoFehler>()));
      expect(() => p.versiegelungOeffnen(c1, a.oeffentlich, b.geheim), throwsA(isA<CryptoFehler>()));
      expect(() => p.versiegelungOeffnen(Uint8List(10), a.oeffentlich, a.geheim), throwsA(isA<CryptoFehler>()));
    });

    test('Zufall: richtige Länge, zweimal verschieden', () {
      expect(p.zufall(32), hasLength(32));
      expect(p.zufall(32), isNot(p.zufall(32)));
    });

    test('falsche Längen werden als Fehler gemeldet, nicht als Absturz', () {
      expect(() => p.boxPaarAusSeed(Uint8List(31)), throwsA(isA<CryptoFehler>()));
      expect(() => p.signPaarAusSeed(Uint8List(33)), throwsA(isA<CryptoFehler>()));
      expect(() => p.verschluesseln(schluessel: Uint8List(31), nonce: Uint8List(24), klartext: Uint8List(1)), throwsA(isA<CryptoFehler>()));
      expect(() => p.verschluesseln(schluessel: Uint8List(32), nonce: Uint8List(12), klartext: Uint8List(1)), throwsA(isA<CryptoFehler>()));
    });
  }, skip: skip);
}
