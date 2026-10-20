// Übertragung des Personenschlüssels auf ein neues Gerät: Kryptografie des Blobs (Einmaligkeit, Ablauf und Personenbindung des Servers
// prüfen die Server-Tests und e2ee_controller_test.dart).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/uebertragung.dart';

import '../support/fake_crypto.dart';

CryptoFehlerArt? _art(void Function() f) {
  try {
    f();
  } on CryptoFehler catch (e) {
    return e.art;
  }
  return null;
}

const _uid = 'u0000000-0000-4000-8000-000000000003';

Future<void> main() async {
  for (final (name, crypto) in await kryptoVarianten()) {
    group('Übertragung ($name)', () {
      late Personenschluessel pk;
      late UebertragungsAngebot angebot;

      setUp(() {
        pk = Personenschluessel.erzeugen(crypto);
        angebot = Uebertragung.anbieten(crypto, schluessel: pk, userId: _uid, keyVersion: 2);
      });

      test('Roundtrip über QR-Text und über abgetippten Code', () {
        for (final eingabe in [Uebertragung.qrText(angebot.geheimnis), Uebertragung.codeText(angebot.geheimnis), Uebertragung.codeText(angebot.geheimnis).toLowerCase()]) {
          final geheimnis = Uebertragung.geheimnisLesen(eingabe);
          expect(geheimnis, angebot.geheimnis);
          expect(Uebertragung.suchkennung(crypto, geheimnis), angebot.suchkennung);
          final neu = Uebertragung.oeffnen(crypto, blob: angebot.blob, geheimnis: geheimnis, userId: _uid, keyVersion: 2);
          expect(neu.exportieren(), pk.exportieren());
        }
      });

      test('QR-Text hat Präfix und keine Bindestriche; Code besteht aus 14 Gruppen', () {
        expect(Uebertragung.qrText(angebot.geheimnis), matches(RegExp(r'^LXK1:[A-Z2-7]{56}$')));
        expect(Uebertragung.codeText(angebot.geheimnis), matches(RegExp(r'^([A-Z2-7]{4}-){13}[A-Z2-7]{4}$')));
      });

      test('der Server sieht nur Suchkennung und Blob: beide verraten das Geheimnis nicht', () {
        final kennung = base64urlDekodieren(angebot.suchkennung);
        expect(kennung, hasLength(32));
        expect(kennung, isNot(angebot.geheimnis));
        final text = '${angebot.suchkennung}${angebot.blob}';
        expect(text.contains(base64urlKodieren(angebot.geheimnis)), isFalse);
        // verschiedene Angebote -> verschiedene Kennungen
        expect(Uebertragung.anbieten(crypto, schluessel: pk, userId: _uid, keyVersion: 2).suchkennung, isNot(angebot.suchkennung));
      });

      test('falsches Geheimnis, falsche Person, falsche Schlüsselversion, veränderter Blob', () {
        final falsch = crypto.zufall(32);
        expect(_art(() => Uebertragung.oeffnen(crypto, blob: angebot.blob, geheimnis: falsch, userId: _uid, keyVersion: 2)), CryptoFehlerArt.entschluesselung);
        expect(_art(() => Uebertragung.oeffnen(crypto, blob: angebot.blob, geheimnis: angebot.geheimnis, userId: 'u-anders', keyVersion: 2)), CryptoFehlerArt.entschluesselung);
        expect(_art(() => Uebertragung.oeffnen(crypto, blob: angebot.blob, geheimnis: angebot.geheimnis, userId: _uid, keyVersion: 3)), CryptoFehlerArt.entschluesselung);
        final b = base64urlDekodieren(angebot.blob);
        b[30] ^= 1;
        expect(_art(() => Uebertragung.oeffnen(crypto, blob: base64urlKodieren(b), geheimnis: angebot.geheimnis, userId: _uid, keyVersion: 2)), CryptoFehlerArt.entschluesselung);
        expect(_art(() => Uebertragung.oeffnen(crypto, blob: 'abc', geheimnis: angebot.geheimnis, userId: _uid, keyVersion: 2)), CryptoFehlerArt.format);
        final v2 = Uint8List.fromList(base64urlDekodieren(angebot.blob))..[0] = 2;
        expect(_art(() => Uebertragung.oeffnen(crypto, blob: base64urlKodieren(v2), geheimnis: angebot.geheimnis, userId: _uid, keyVersion: 2)), CryptoFehlerArt.version);
      });

      test('Tippfehler im Code werden erkannt', () {
        final roh = Uebertragung.codeText(angebot.geheimnis).replaceAll('-', '');
        final falsch = '${roh.substring(0, 20)}${roh[20] == 'A' ? 'B' : 'A'}${roh.substring(21)}';
        expect(_art(() => Uebertragung.geheimnisLesen(falsch)), CryptoFehlerArt.pruefsumme);
        expect(_art(() => Uebertragung.geheimnisLesen('LXK1:ABC')), CryptoFehlerArt.format);
        expect(_art(() => Uebertragung.geheimnisLesen('')), CryptoFehlerArt.format);
      });

      test('blob und Suchkennung passen in die Grenzen des Servers', () {
        expect(angebot.blob.length, lessThanOrEqualTo(1024));
        expect(angebot.suchkennung, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      });
    });
  }
}
