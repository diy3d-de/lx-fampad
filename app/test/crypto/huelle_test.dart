// Hülle (verschlüsselte, signierte Nachricht): Roundtrip, falsche AAD/Signatur/Schlüssel, Nonce-Wiederverwendung, Formfehler.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/huelle.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';

import '../support/fake_crypto.dart';

const _kontext = HuellenKontext(conversationId: 'c0000000-0000-4000-8000-000000000001', messageId: 'm0000000-0000-4000-8000-000000000002', senderId: 'u0000000-0000-4000-8000-000000000003', epoch: 7);

CryptoFehlerArt? _art(void Function() f) {
  try {
    f();
  } on CryptoFehler catch (e) {
    return e.art;
  }
  return null;
}

Future<void> main() async {
  for (final (name, crypto) in await kryptoVarianten()) {
    group('Hülle ($name)', () {
      late HuellenCodec codec;
      late Personenschluessel absender;
      late Personenschluessel anderer;
      late Uint8List epochenSchluessel;
      final klartext = utf8Bytes('Hallo Familie, wer holt Oma ab? Ä ö ü ß 🚗');

      setUp(() {
        codec = HuellenCodec(crypto);
        absender = Personenschluessel.erzeugen(crypto);
        anderer = Personenschluessel.erzeugen(crypto);
        epochenSchluessel = crypto.zufall(32);
      });

      String versiegeln({Uint8List? text, HuellenKontext kontext = _kontext, Personenschluessel? von}) => codec.versiegeln(
        schluessel: epochenSchluessel,
        klartext: text ?? klartext,
        kontext: kontext,
        signGeheim: (von ?? absender).signGeheim,
      );

      Uint8List oeffnen(String h, {HuellenKontext kontext = _kontext, Uint8List? schluessel, Uint8List? sender}) => codec.oeffnen(
        schluessel: schluessel ?? epochenSchluessel,
        huelle: h,
        kontext: kontext,
        senderSignOeffentlich: sender ?? absender.signOeffentlich,
      );

      HuellenKontext mit({String? conv, String? msg, String? sender, int? epoch}) => HuellenKontext(
        conversationId: conv ?? _kontext.conversationId,
        messageId: msg ?? _kontext.messageId,
        senderId: sender ?? _kontext.senderId,
        epoch: epoch ?? _kontext.epoch,
      );

      test('Roundtrip, Format und Größe', () {
        final h = versiegeln();
        expect(oeffnen(h), klartext);
        final bytes = base64urlDekodieren(h);
        expect(bytes[0], 1, reason: 'Version');
        expect(bytes[1], 1, reason: 'Verfahren');
        expect(u32Lesen(bytes, 2), 7, reason: 'Epoche');
        expect(bytes.length, 1 + 1 + 4 + 24 + 64 + klartext.length + 16);
        expect(h, isNot(contains('=')));
      });

      test('leerer Klartext und große Nachricht', () {
        expect(oeffnen(versiegeln(text: Uint8List(0))), isEmpty);
        final gross = Uint8List.fromList(List.generate(100000, (i) => i & 255));
        expect(oeffnen(versiegeln(text: gross)), gross);
      });

      test('gleiche Nachricht ergibt jedes Mal andere Hülle (frische Nonce)', () {
        expect(versiegeln(), isNot(versiegeln()));
      });

      test('falsche AAD wird abgelehnt: jede Komponente des Kontexts', () {
        final h = versiegeln();
        // Signatur UND Chiffretext hängen an der AAD: Die Signatur schlägt zuerst an
        expect(_art(() => oeffnen(h, kontext: mit(conv: 'c-anders'))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(h, kontext: mit(msg: 'm-anders'))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(h, kontext: mit(sender: 'u-anders'))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(h, kontext: mit(epoch: 8))), CryptoFehlerArt.format, reason: 'Epoche steht im Kopf und muss passen');
      });

      test('AAD ist an den Chiffretext gebunden, auch wenn jemand die Signatur selbst neu erzeugt', () {
        // Ein Mitglied mit dem Gruppenschlüssel schreibt in einer anderen Konversation: eigene Signatur, aber die AAD passt nicht zum Chiffretext
        final h = versiegeln();
        final bytes = base64urlDekodieren(h);
        final kopf = Uint8List.sublistView(bytes, 0, 30);
        final ct = Uint8List.sublistView(bytes, 94);
        final neueAad = mit(conv: 'c-anders').aad(1);
        final sig = crypto.signieren(verketten([kopf, ct, neueAad]), absender.signGeheim);
        final umgeschrieben = base64urlKodieren(verketten([kopf, sig, ct]));
        expect(_art(() => oeffnen(umgeschrieben, kontext: mit(conv: 'c-anders'))), CryptoFehlerArt.entschluesselung);
      });

      test('falsche Signatur: anderer Absender, veränderte Signatur, Chiffretext, Kopf', () {
        final h = versiegeln();
        expect(_art(() => oeffnen(h, sender: anderer.signOeffentlich)), CryptoFehlerArt.signatur, reason: 'als andere Person ausgegeben');
        // wirklich von einer anderen Person signiert (hat den Gruppenschlüssel, aber nicht den Signaturschlüssel des Absenders)
        expect(_art(() => oeffnen(versiegeln(von: anderer))), CryptoFehlerArt.signatur);
        for (final stelle in [3, 10, 30, 31, 60, 93, 94, 100, base64urlDekodieren(h).length - 1]) {
          final bytes = base64urlDekodieren(h);
          bytes[stelle] ^= 0x01;
          expect(_art(() => oeffnen(base64urlKodieren(bytes))), isNotNull, reason: 'Bit an Stelle $stelle');
        }
      });

      test('falscher Epochenschlüssel: Entschlüsselung scheitert (Signatur stimmt)', () {
        final h = versiegeln();
        expect(_art(() => oeffnen(h, schluessel: crypto.zufall(32))), CryptoFehlerArt.entschluesselung);
      });

      test('Nonce-Wiederverwendung wird abgelehnt', () {
        final festes = FakeCryptoProvider(konstant: true);
        final c2 = HuellenCodec(festes);
        final pk = Personenschluessel.erzeugen(festes);
        final schluessel = Uint8List(32);
        c2.versiegeln(schluessel: schluessel, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim);
        expect(
          _art(() => c2.versiegeln(schluessel: schluessel, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim)),
          CryptoFehlerArt.nonce,
        );
        // mit einem anderen Schlüssel ist dieselbe Nonce kein Problem
        c2.versiegeln(schluessel: Uint8List(32)..[0] = 1, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim);
      });

      test('Formfehler: zu kurz, ungültige Kodierung, unbekannte Version/Verfahren', () {
        expect(_art(() => oeffnen('')), CryptoFehlerArt.format);
        expect(_art(() => oeffnen('abc')), CryptoFehlerArt.format);
        expect(_art(() => oeffnen('ungültig!')), CryptoFehlerArt.format);
        expect(_art(() => oeffnen('${versiegeln()}=')), CryptoFehlerArt.format);
        final bytes = base64urlDekodieren(versiegeln());
        final v2 = Uint8List.fromList(bytes)..[0] = 2;
        final alg2 = Uint8List.fromList(bytes)..[1] = 2;
        expect(_art(() => oeffnen(base64urlKodieren(v2))), CryptoFehlerArt.version);
        expect(_art(() => oeffnen(base64urlKodieren(alg2))), CryptoFehlerArt.version);
      });

      test('Kontext: Trennzeichen und leere IDs sind unzulässig', () {
        expect(_art(() => versiegeln(kontext: mit(conv: 'a|b'))), CryptoFehlerArt.format);
        expect(_art(() => versiegeln(kontext: mit(msg: ''))), CryptoFehlerArt.format);
        expect(_art(() => versiegeln(kontext: mit(epoch: -1))), CryptoFehlerArt.format);
      });

      test('AAD-Aufbau: conversation_id|message_id|sender_id|epoch|v', () {
        expect(String.fromCharCodes(_kontext.aad(1)), 'c0000000-0000-4000-8000-000000000001|m0000000-0000-4000-8000-000000000002|u0000000-0000-4000-8000-000000000003|7|1');
      });
    });
  }
}
