// Bausteine der Passkey-Sicherung (prf_sicherung.dart): fester Salt, Prüfung der PRF-Ausgabe, Ableitung des kek (nie die Ausgabe selbst), Blob-Format, Bindung an Person,
// Schlüsselversion und Passkey (AAD), Manipulation jedes Bytes, Known-Answer gegen libsodium. Läuft gegen den Fake und, wo verfügbar, gegen libsodium.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/domaenen.dart';
import 'package:lx_fampad/data/crypto/prf_sicherung.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';

import '../support/fake_crypto.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _ausgabe([int start = 1]) => Uint8List.fromList(List.generate(32, (i) => start + i));
Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));

Future<void> main() async {
  final varianten = await kryptoVarianten();
  final sodium = varianten.where((v) => v.$1 == 'libsodium').map((v) => v.$2).firstOrNull;

  test('Der Salt ist fest, 32 Byte und von der Textkonstante abgeleitet', () {
    final crypto = FakeCryptoProvider();
    expect(prfSalt(crypto), hasLength(32));
    expect(prfSalt(crypto), prfSalt(crypto));
    expect(prfSalt(crypto), crypto.hash(utf8Bytes(kPrfSaltText)));
    expect(kPrfSaltText, 'lx-fampad|prf-salt|v1');
    expect(kKontextPrfKek, 'lx-fampad|prf-kek|v1');
    expect(kDomaenePrfSicherung, 'lx-fampad|prfbackup|v3');
  });

  test('prfAusgabePruefen: nur genau 32 Byte und nicht nur Nullen', () {
    expect(prfAusgabePruefen(null), isNull);
    expect(prfAusgabePruefen(Uint8List(0)), isNull);
    expect(prfAusgabePruefen(Uint8List(31)..[0] = 1), isNull);
    expect(prfAusgabePruefen(Uint8List(33)..[0] = 1), isNull);
    expect(prfAusgabePruefen(Uint8List(32)), isNull, reason: 'nur Nullen');
    expect(prfAusgabePruefen(_ausgabe()), _ausgabe());
    expect(prfAusgabePruefen(Uint8List(32)..[31] = 1), isNotNull);
  });

  for (final (name, crypto) in varianten) {
    group('Passkey-Sicherung ($name)', () {
      const user = '11111111-1111-4111-8111-111111111111';
      const cred = 'Y3JlZC0xLWJlaXNwaWVs';

      test('kek: 32 Byte, deterministisch, weder gleich der Ausgabe noch gleich bei anderer Ausgabe', () {
        final a = PrfSchluessel.ausAusgabe(crypto, _ausgabe());
        final b = PrfSchluessel.ausAusgabe(crypto, _ausgabe());
        final c = PrfSchluessel.ausAusgabe(crypto, _ausgabe(2));
        expect(a.kek, hasLength(32));
        expect(a.kek, b.kek);
        expect(a.kek, isNot(c.kek));
        expect(a.kek, isNot(_ausgabe()), reason: 'die PRF-Ausgabe wird nie direkt als Schlüssel benutzt');
        expect(() => PrfSchluessel.ausAusgabe(crypto, Uint8List(31)), _fehler(CryptoFehlerArt.schluessel));
        a.loeschen();
        expect(a.kek.every((x) => x == 0), isTrue);
      });

      test('Blob: Format (v3, Version, Nonce, Chiffretext) und Rundreise', () {
        final s = Personenschluessel.erzeugen(crypto);
        final kek = PrfSchluessel.ausAusgabe(crypto, _ausgabe()).kek;
        final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: user, keyVersion: 5, credentialId: cred);
        final b = base64urlDekodieren(blob);
        expect(b, hasLength(1 + 4 + 24 + 64 + 16));
        expect(b[0], kPrfBlobVersion);
        expect(u32Lesen(b, 1), 5);
        // ein zweiter Blob desselben Schlüssels hat eine andere Nonce
        expect(PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: user, keyVersion: 5, credentialId: cred), isNot(blob));
        final offen = PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: kek, userId: user, keyVersion: 5, credentialId: cred);
        expect(offen.exportieren(), s.exportieren());
        expect(blob.contains(base64urlKodieren(s.exportieren())), isFalse);
      });

      test('Person, Schlüsselversion, Passkey und kek sind gebunden: jede Abweichung öffnet nicht', () {
        final s = Personenschluessel.erzeugen(crypto);
        final kek = PrfSchluessel.ausAusgabe(crypto, _ausgabe()).kek;
        final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: user, keyVersion: 5, credentialId: cred);
        PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: kek, userId: user, keyVersion: 5, credentialId: cred);
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: kek, userId: '22222222-2222-4222-8222-222222222222', keyVersion: 5, credentialId: cred), _fehler(CryptoFehlerArt.entschluesselung));
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: kek, userId: user, keyVersion: 6, credentialId: cred), _fehler(CryptoFehlerArt.entschluesselung));
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: kek, userId: user, keyVersion: 5, credentialId: 'anderer-passkey'), _fehler(CryptoFehlerArt.entschluesselung));
        final fremd = PrfSchluessel.ausAusgabe(crypto, _ausgabe(9)).kek;
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: fremd, userId: user, keyVersion: 5, credentialId: cred), _fehler(CryptoFehlerArt.entschluesselung));
      });

      test('Jedes Byte des Blobs wirkt: eine Änderung irgendwo lässt ihn scheitern', () {
        final s = Personenschluessel.erzeugen(crypto);
        final kek = PrfSchluessel.ausAusgabe(crypto, _ausgabe()).kek;
        final roh = base64urlDekodieren(PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: user, keyVersion: 5, credentialId: cred));
        for (var i = 0; i < roh.length; i++) {
          final kaputt = Uint8List.fromList(roh)..[i] ^= 0x01;
          expect(() => PrfSicherungBlob.oeffnen(crypto, blob: base64urlKodieren(kaputt), kek: kek, userId: user, keyVersion: 5, credentialId: cred), throwsA(isA<CryptoFehler>()), reason: 'Byte $i');
        }
      });

      test('Falsche Länge und andere Blob-Version werden erkannt', () {
        final kek = PrfSchluessel.ausAusgabe(crypto, _ausgabe()).kek;
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: base64urlKodieren(List.filled(50, 1)), kek: kek, userId: user, keyVersion: 1, credentialId: cred), _fehler(CryptoFehlerArt.format));
        final s = Personenschluessel.erzeugen(crypto);
        final roh = base64urlDekodieren(PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: user, keyVersion: 1, credentialId: cred));
        final v2 = Uint8List.fromList(roh)..[0] = 2;
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: base64urlKodieren(v2), kek: kek, userId: user, keyVersion: 1, credentialId: cred), _fehler(CryptoFehlerArt.version));
        expect(() => PrfSicherungBlob.oeffnen(crypto, blob: 'kein base64!', kek: kek, userId: user, keyVersion: 1, credentialId: cred), _fehler(CryptoFehlerArt.format));
      });

      test('pruefen: wahr nur bei richtigen öffentlichen Schlüsseln', () {
        final s = Personenschluessel.erzeugen(crypto);
        final andere = Personenschluessel.erzeugen(crypto);
        final kek = PrfSchluessel.ausAusgabe(crypto, _ausgabe()).kek;
        final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: user, keyVersion: 3, credentialId: cred);
        expect(PrfSicherungBlob.pruefen(crypto, blob: blob, kek: kek, userId: user, credentialId: cred, erwartet: s.oeffentlich(3)), isTrue);
        expect(PrfSicherungBlob.pruefen(crypto, blob: blob, kek: kek, userId: user, credentialId: cred, erwartet: andere.oeffentlich(3)), isFalse);
        expect(PrfSicherungBlob.pruefen(crypto, blob: blob, kek: kek, userId: user, credentialId: cred, erwartet: s.oeffentlich(4)), isFalse, reason: 'andere Version');
        expect(PrfSicherungBlob.pruefen(crypto, blob: blob, kek: kek, userId: user, credentialId: 'x', erwartet: s.oeffentlich(3)), isFalse);
      });
    });
  }

  group('Known-Answer (libsodium)', () {
    final skip = sodium == null ? 'libsodium nicht verfügbar' : null;

    test('Salt und kek: feste Werte (BLAKE2b-256)', () {
      final salt = prfSalt(sodium!);
      expect(_hex(salt), _katSalt);
      final kek = PrfSchluessel.ausAusgabe(sodium, _ausgabe()).kek;
      expect(_hex(kek), _katKek);
    }, skip: skip);

    test('Blob mit festem Schlüssel und Nonce öffnet auch nach Neustart (Format ist stabil)', () {
      final crypto = sodium!;
      final seeds = Uint8List.fromList(List.generate(64, (i) => i));
      final s = Personenschluessel.ausBytes(crypto, seeds);
      final kek = PrfSchluessel.ausAusgabe(crypto, _ausgabe()).kek;
      final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: s, kek: kek, userId: 'u', keyVersion: 1, credentialId: 'c');
      expect(PrfSicherungBlob.oeffnen(crypto, blob: blob, kek: kek, userId: 'u', keyVersion: 1, credentialId: 'c').exportieren(), seeds);
    }, skip: skip);
  });
}

// Werte aus libsodium (BLAKE2b-256 mit Schlüssel); bei einer Änderung der Konstanten in domaenen.dart ändert sich das Format: neue Version statt Anpassung.
const _katSalt = 'ff99f5d9c14e20dfef84177eb5183cf310e45905cb37666856a3f249dda45167';
const _katKek = '44691674e642a67d625074fb5376d21cf27602a5bb2996c8af6423cd0f753a3e';
