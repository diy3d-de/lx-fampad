// Tests der Bausteine der Passwort-Sicherung: Known-Answer (libsodium und unabhängige reine Dart-Implementierung Argon2id aus dem Paket cryptography),
// Trennung der Teilschlüssel, Blob-Format, Manipulation, Normalisierung. Der Fake-Provider prüft nur die Logik (kein Argon2).
// Läuft gegen libsodium, wo verfügbar (CI: Pflicht, SODIUM_ERFORDERLICH=1).
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/nfkc.dart';
import 'package:lx_fampad/data/crypto/pw_sicherung.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';

import '../support/fake_crypto.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
Uint8List _salt() => Uint8List.fromList(List.generate(16, (i) => i));

Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));

Future<void> main() async {
  final varianten = await kryptoVarianten();
  final sodium = varianten.where((v) => v.$1 == 'libsodium').map((v) => v.$2).firstOrNull;
  final skipSodium = sodium == null ? 'libsodium nicht verfügbar' : null;

  group('Argon2id und Teilschlüssel (libsodium, Known-Answer)', () {
    test('Profil kdf1 ist festgeschrieben', () {
      expect(kKdf1, 1);
      expect(kKdf1MemKiB * 1024, 67108864); // = crypto_pwhash_argon2id_MEMLIMIT_INTERACTIVE
      expect(kKdf1Ops, 3);
    });

    test('pwhash kdf1: feste Eingabe -> feste Ausgabe, passt zur unabhängigen Dart-Implementierung', () async {
      final pw = passwortBytes('correct horse battery staple');
      final m = await sodium!.pwhash(passwort: pw, salt: _salt(), memKiB: kKdf1MemKiB, ops: kKdf1Ops);
      expect(_hex(m), '0d1a3c6523c8f06e4e0af9c515aa5b5448cfebd6838f2d52c3d8b6ef8ddc3c2e');
      final dart = await cr.Argon2id(memory: kKdf1MemKiB, parallelism: 1, iterations: kKdf1Ops, hashLength: 32).deriveKey(secretKey: cr.SecretKey(pw), nonce: _salt());
      expect(_hex(await dart.extractBytes()), _hex(m));
    }, skip: skipSodium, timeout: const Timeout(Duration(minutes: 3)));

    test('pwhash mit kleinem Aufwand: fester Wert (libsodium = reine Dart-Implementierung)', () async {
      final pw = passwortBytes('correct horse battery staple');
      final m = await sodium!.pwhash(passwort: pw, salt: _salt(), memKiB: 8192, ops: 2);
      expect(_hex(m), 'a891dd91a3d123add6ea78ceedcc94a7f1dc1e4ca480e57e6f240a113662ea2f');
    }, skip: skipSodium);

    test('Teilschlüssel aus dem Master: feste Werte, verschieden, unabhängig voneinander', () {
      final master = _unhex('0d1a3c6523c8f06e4e0af9c515aa5b5448cfebd6838f2d52c3d8b6ef8ddc3c2e');
      final k = PwSchluessel.ausMaster(sodium!, master);
      expect(_hex(k.authKey), 'f830d1dc4376b8c458fc37547b9553af0a04c84df41ed4f088dd5c52d90896bc');
      expect(_hex(k.kek), '3bc6bd820befb5f528bfcafdd958e0fecd2e17ceeaa02378703f6757ae07733c');
      expect(k.authKey, isNot(k.kek));
      // Trennung: der kek ist nicht aus dem authKey ableitbar (weder mit denselben Labels noch als einfacher Hash)
      expect(sodium.kdf(k.authKey, 'lx-fampad|kek|v2'), isNot(k.kek));
      expect(sodium.kdf(k.authKey, 'lx-fampad|auth|v2'), isNot(k.kek));
      expect(sodium.hash(k.authKey), isNot(k.kek));
      // Label ändert die Ausgabe, jeder andere Master ändert beide
      expect(sodium.kdf(master, 'lx-fampad|auth|v3'), isNot(k.authKey));
      final anders = PwSchluessel.ausMaster(sodium, Uint8List.fromList(master)..[0] ^= 1);
      expect(anders.authKey, isNot(k.authKey));
      expect(anders.kek, isNot(k.kek));
      expect(k.authKeyBase64, base64urlKodieren(k.authKey));
      expect(() => PwSchluessel.ausMaster(sodium, Uint8List(31)), _fehler(CryptoFehlerArt.schluessel));
    }, skip: skipSodium);

    test('pwhash prüft Parameter', () async {
      final pw = utf8Bytes('x');
      await expectLater(sodium!.pwhash(passwort: pw, salt: Uint8List(15), memKiB: 8192, ops: 2), _fehler(CryptoFehlerArt.schluessel));
      await expectLater(sodium.pwhash(passwort: pw, salt: _salt(), memKiB: 1, ops: 2), _fehler(CryptoFehlerArt.schluessel));
      await expectLater(sodium.pwhash(passwort: pw, salt: _salt(), memKiB: 8192, ops: 0), _fehler(CryptoFehlerArt.schluessel));
    }, skip: skipSodium);

    test('pwhash: anderes Passwort, anderer Salt, anderer Aufwand ergeben andere Ausgaben', () async {
      final a = await sodium!.pwhash(passwort: utf8Bytes('geheim-1'), salt: _salt(), memKiB: 8192, ops: 2);
      expect(await sodium.pwhash(passwort: utf8Bytes('geheim-1'), salt: _salt(), memKiB: 8192, ops: 2), a);
      expect(await sodium.pwhash(passwort: utf8Bytes('geheim-2'), salt: _salt(), memKiB: 8192, ops: 2), isNot(a));
      expect(await sodium.pwhash(passwort: utf8Bytes('geheim-1'), salt: Uint8List.fromList(_salt())..[0] = 9, memKiB: 8192, ops: 2), isNot(a));
      expect(await sodium.pwhash(passwort: utf8Bytes('geheim-1'), salt: _salt(), memKiB: 8192, ops: 3), isNot(a));
      expect(await sodium.pwhash(passwort: utf8Bytes('geheim-1'), salt: _salt(), memKiB: 16384, ops: 2), isNot(a));
    }, skip: skipSodium);
  });

  for (final (name, crypto) in varianten) {
    group('Passwort-Sicherung ($name)', () {
      late Personenschluessel schluessel;
      late PwKdfParams params;
      late PwSchluessel keys;
      late String blob;
      const userId = '11111111-1111-4111-8111-111111111111';
      setUp(() {
        schluessel = Personenschluessel.erzeugen(crypto);
        params = PwKdfParams.neu(crypto);
        keys = PwSchluessel.ausMaster(crypto, crypto.zufall(32));
        blob = PwSicherungBlob.erzeugen(crypto, schluessel: schluessel, kek: keys.kek, params: params, userId: userId, keyVersion: 3);
      });

      String blobMit(Uint8List b) => base64urlKodieren(b);
      void oeffnen(String b, {Uint8List? kek, String? user, int version = 3}) =>
          PwSicherungBlob.oeffnen(crypto, blob: b, kek: kek ?? keys.kek, userId: user ?? userId, keyVersion: version);

      test('Round-Trip: Seeds kommen unverändert zurück', () {
        final s = PwSicherungBlob.oeffnen(crypto, blob: blob, kek: keys.kek, userId: userId, keyVersion: 3);
        expect(s.exportieren(), schluessel.exportieren());
        expect(s.encOeffentlich, schluessel.encOeffentlich);
      });

      test('Format: Länge, Kopf, Felder, Salt aus den Parametern', () {
        final b = base64urlDekodieren(blob);
        expect(b.length, 1 + 1 + 4 + 4 + 4 + 16 + 24 + 64 + 16);
        expect(b[0], 2);
        expect(b[1], kKdf1);
        expect(u32Lesen(b, 2), 3);
        expect(u32Lesen(b, 6), kKdf1MemKiB);
        expect(u32Lesen(b, 10), kKdf1Ops);
        expect(Uint8List.sublistView(b, 14, 30), params.salt);
        expect(PwSicherungBlob.parameter(blob), params);
      });

      test('Zufall: zwei Blobs derselben Daten unterscheiden sich (Nonce), Salt der Parameter ist zufällig', () {
        final zweiter = PwSicherungBlob.erzeugen(crypto, schluessel: schluessel, kek: keys.kek, params: params, userId: userId, keyVersion: 3);
        expect(zweiter, isNot(blob));
        final salze = {for (var i = 0; i < 20; i++) PwKdfParams.neu(crypto).saltBase64};
        expect(salze, hasLength(20));
      });

      test('falscher kek (falsches Passwort), andere Person, andere keyVersion: Entschlüsselungsfehler', () {
        final fremd = PwSchluessel.ausMaster(crypto, crypto.zufall(32));
        expect(() => oeffnen(blob, kek: fremd.kek), _fehler(CryptoFehlerArt.entschluesselung));
        expect(() => oeffnen(blob, kek: keys.authKey), _fehler(CryptoFehlerArt.entschluesselung));
        expect(() => oeffnen(blob, user: '22222222-2222-4222-8222-222222222222'), _fehler(CryptoFehlerArt.entschluesselung));
        expect(() => oeffnen(blob, version: 4), _fehler(CryptoFehlerArt.entschluesselung));
      });

      test('Manipulation: jedes Byte des Blobs wirkt (Kopf, Parameter, Salt, Nonce, Chiffretext, Tag)', () {
        final original = base64urlDekodieren(blob);
        for (var i = 0; i < original.length; i++) {
          final kaputt = Uint8List.fromList(original)..[i] ^= 1;
          expect(() => oeffnen(blobMit(kaputt)), throwsA(isA<CryptoFehler>()), reason: 'Byte $i');
        }
      });

      test('Vertauschte oder geänderte Felder: Salt/Nonce vertauscht, abgeschnitten, verlängert, falsche Version', () {
        final b = base64urlDekodieren(blob);
        final getauscht = Uint8List.fromList(b)
          ..setRange(14, 30, b.sublist(30, 46))
          ..setRange(30, 46, b.sublist(14, 30));
        final faelle = <String, Uint8List>{
          'Salt/Nonce vertauscht': getauscht,
          'abgeschnitten': Uint8List.sublistView(b, 0, b.length - 1),
          'verlängert': Uint8List.fromList([...b, 0]),
          'nur Kopf': Uint8List.sublistView(b, 0, 14),
        };
        faelle.forEach((fall, bytes) {
          expect(() => oeffnen(blobMit(bytes)), throwsA(isA<CryptoFehler>()), reason: fall);
        });
        expect(() => oeffnen(blobMit(Uint8List.fromList(b)..[0] = 1)), _fehler(CryptoFehlerArt.version));
        expect(() => oeffnen(blobMit(Uint8List.fromList(b)..[1] = 2)), _fehler(CryptoFehlerArt.version));
        expect(() => oeffnen('AAAA'), _fehler(CryptoFehlerArt.format));
        expect(() => oeffnen('kein base64!'), _fehler(CryptoFehlerArt.format));
      });

      test('Parameter im Blob müssen genau dem Profil entsprechen (kein Herabsetzen durch den Server)', () {
        final b = base64urlDekodieren(blob);
        final schwach = Uint8List.fromList(b)..buffer.asByteData().setUint32(6, 8192, Endian.big);
        expect(() => PwSicherungBlob.parameter(blobMit(schwach)), _fehler(CryptoFehlerArt.format));
        final wenig = Uint8List.fromList(b)..buffer.asByteData().setUint32(10, 1, Endian.big);
        expect(() => PwSicherungBlob.parameter(blobMit(wenig)), _fehler(CryptoFehlerArt.format));
        expect(() => PwKdfParams(kdfId: 2, memKiB: kKdf1MemKiB, ops: kKdf1Ops, salt: params.salt), _fehler(CryptoFehlerArt.version));
        expect(() => PwKdfParams(kdfId: kKdf1, memKiB: kKdf1MemKiB, ops: kKdf1Ops, salt: Uint8List(8)), _fehler(CryptoFehlerArt.format));
      });

      test('AAD bindet den Salt: derselbe kek mit anderem Salt im Kopf öffnet nicht', () {
        final anderes = PwKdfParams.neu(crypto);
        final t = Uint8List.fromList(base64urlDekodieren(blob))..setRange(14, 30, anderes.salt);
        expect(() => oeffnen(blobMit(t)), _fehler(CryptoFehlerArt.entschluesselung));
      });

      test('Probe gegen die öffentlichen Schlüssel: nur wenn Öffnen UND Schlüssel stimmen', () {
        final erwartet = schluessel.oeffentlich(3);
        expect(PwSicherungBlob.pruefen(crypto, blob: blob, kek: keys.kek, userId: userId, erwartet: erwartet), isTrue);
        final fremderSchluessel = Personenschluessel.erzeugen(crypto).oeffentlich(3);
        expect(PwSicherungBlob.pruefen(crypto, blob: blob, kek: keys.kek, userId: userId, erwartet: fremderSchluessel), isFalse);
        final anderer = PwSchluessel.ausMaster(crypto, crypto.zufall(32)).kek;
        expect(PwSicherungBlob.pruefen(crypto, blob: blob, kek: anderer, userId: userId, erwartet: erwartet), isFalse);
        expect(PwSicherungBlob.pruefen(crypto, blob: blob, kek: keys.kek, userId: userId, erwartet: schluessel.oeffentlich(4)), isFalse);
        expect(PwSicherungBlob.pruefen(crypto, blob: 'kaputt', kek: keys.kek, userId: userId, erwartet: erwartet), isFalse);
      });

      test('Aus dem Passwort: gleiches Passwort öffnet (auch anders normalisiert), falsches nicht, leeres wird abgelehnt', () async {
        final p = PwKdfParams.neu(crypto);
        final k = await PwSchluessel.ausPasswort(crypto, passwort: 'Café Straße 12345', params: p);
        final b = PwSicherungBlob.erzeugen(crypto, schluessel: schluessel, kek: k.kek, params: p, userId: userId, keyVersion: 1);
        final s = await PwSicherungBlob.oeffnenMitPasswort(crypto, blob: b, passwort: 'Café Straße 12345', userId: userId, keyVersion: 1);
        expect(s.exportieren(), schluessel.exportieren());
        await expectLater(
          PwSicherungBlob.oeffnenMitPasswort(crypto, blob: b, passwort: 'Cafe Straße 12345', userId: userId, keyVersion: 1),
          _fehler(CryptoFehlerArt.entschluesselung),
        );
        await expectLater(PwSchluessel.ausPasswort(crypto, passwort: '', params: p), _fehler(CryptoFehlerArt.format));
      }, timeout: const Timeout(Duration(minutes: 3)));
    });
  }

  group('Passwort-Normalisierung (NFKC, eingeschränkt)', () {
    String n(String s) => _hex(nfkcCodepunkte(s).expand((c) => [c >> 8, c & 255]).toList());
    String r(List<int> cps) => _hex(cps.expand((c) => [c >> 8, c & 255]).toList());

    test('é zusammengesetzt = zerlegt (gleiche Bytes)', () {
      expect(passwortBytes('Café'), passwortBytes('Café'));
      expect(passwortNormalisiert('Café'), 'Café');
    });

    test('Werte wie die JS-Engine (NFKC): Ligaturen, Voll-/Halbbreite, Leerzeichen, Akzentketten', () {
      expect(n('ﬁsch'), r([0x66, 0x69, 0x73, 0x63, 0x68]));
      expect(n('ＡＢＣ１２３'), r([0x41, 0x42, 0x43, 0x31, 0x32, 0x33]));
      expect(n('a b'), r([0x61, 0x20, 0x62]));
      expect(n('a b'), r([0x61, 0x20, 0x62]));
      expect(n('Ǖ'), r([0x1d5]));
      expect(n('ǖ'), r([0x1d6]));
      expect(n('ﬃ'), r([0x66, 0x66, 0x69]));
      expect(n('½'), r([0x31, 0x2044, 0x32]));
      expect(n('…'), r([0x2e, 0x2e, 0x2e]));
      expect(n('ö ä ü'), r([0xf6, 0x20, 0xe4, 0x20, 0xfc]));
      expect(n('ǅ'), r([0x44, 0x17e]));
    });

    test('unverändert: ß, ASCII, andere Schriften; keine Kürzung von Leerzeichen am Rand', () {
      expect(passwortNormalisiert('Straße'), 'Straße');
      expect(passwortNormalisiert('ẞ'), 'ẞ');
      expect(passwortNormalisiert('Жж'), 'Жж');
      expect(passwortNormalisiert(' a b '), ' a b ');
      expect(passwortBytes('  x'), isNot(passwortBytes('x')));
      expect(passwortBytes(''), isEmpty);
    });

    test('Emoji (Surrogatpaare) bleiben erhalten', () {
      expect(passwortNormalisiert('pw \u{1F511}x'), 'pw \u{1F511}x');
    });
  });
}
