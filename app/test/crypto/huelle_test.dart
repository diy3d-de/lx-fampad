// Hülle (verschlüsselte, signierte Nachricht): Roundtrip, falsche AAD/Signatur/Schlüssel/Schlüsselversion, alter Schlüssel nach Rotation,
// Domänentrennung, Nonce-Wiederverwendung, Formfehler.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/domaenen.dart';
import 'package:lx_fampad/data/crypto/huelle.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';

import '../support/fake_crypto.dart';

const _kontext = HuellenKontext(
  conversationId: 'c0000000-0000-4000-8000-000000000001',
  messageId: 'm0000000-0000-4000-8000-000000000002',
  senderId: 'u0000000-0000-4000-8000-000000000003',
  epoch: 7,
  senderKeyVersion: 2,
);

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

      OeffentlicheSchluessel pub(Personenschluessel k, [int version = 2]) => k.oeffentlich(version);

      String versiegeln({Uint8List? text, HuellenKontext kontext = _kontext, Personenschluessel? von}) => codec.versiegeln(
        schluessel: epochenSchluessel,
        klartext: text ?? klartext,
        kontext: kontext,
        signGeheim: (von ?? absender).signGeheim,
      );

      Uint8List oeffnen(String h, {HuellenKontext kontext = _kontext, Uint8List? schluessel, OeffentlicheSchluessel? sender}) => codec.oeffnen(
        schluessel: schluessel ?? epochenSchluessel,
        huelle: h,
        kontext: kontext,
        sender: sender ?? pub(absender),
      );

      HuellenKontext mit({String? conv, String? msg, String? sender, int? epoch, int? version, String? antwort}) => HuellenKontext(
        antwortAuf: antwort,
        conversationId: conv ?? _kontext.conversationId,
        messageId: msg ?? _kontext.messageId,
        senderId: sender ?? _kontext.senderId,
        epoch: epoch ?? _kontext.epoch,
        senderKeyVersion: version ?? _kontext.senderKeyVersion,
      );

      test('Roundtrip, Format und Größe', () {
        final h = versiegeln();
        expect(oeffnen(h), klartext);
        final bytes = base64urlDekodieren(h);
        expect(bytes[0], 1, reason: 'Version');
        expect(bytes[1], 1, reason: 'Verfahren');
        expect(u32Lesen(bytes, 2), 7, reason: 'Epoche');
        expect(u32Lesen(bytes, 6), 2, reason: 'Schlüsselversion des Absenders');
        expect(bytes.length, 1 + 1 + 4 + 4 + 24 + 64 + klartext.length + 16);
        expect(h, isNot(contains('=')));
        expect(HuellenCodec.senderKeyVersionLesen(h), 2);
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
        expect(_art(() => oeffnen(h, kontext: mit(conv: 'c-anders'))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(h, kontext: mit(msg: 'm-anders'))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(h, kontext: mit(sender: 'u-anders'))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(h, kontext: mit(epoch: 8))), CryptoFehlerArt.format, reason: 'Epoche steht im Kopf und muss passen');
        expect(_art(() => oeffnen(h, kontext: mit(version: 3), sender: pub(absender, 3))), CryptoFehlerArt.format, reason: 'Schlüsselversion steht im Kopf und muss passen');
      });

      test('AAD ist an den Chiffretext gebunden, auch wenn jemand die Signatur selbst neu erzeugt', () {
        // Ein Mitglied mit dem Gruppenschlüssel schreibt in einer anderen Konversation: eigene Signatur, aber die AAD passt nicht zum Chiffretext
        final h = versiegeln();
        final bytes = base64urlDekodieren(h);
        final kopf = Uint8List.sublistView(bytes, 0, 34);
        final ct = Uint8List.sublistView(bytes, 98);
        final neueAad = mit(conv: 'c-anders').aad(1);
        final sig = crypto.signieren(verketten([utf8Bytes(kDomaeneNachricht), u32Bytes(neueAad.length), neueAad, kopf, ct]), absender.signGeheim);
        final umgeschrieben = base64urlKodieren(verketten([kopf, sig, ct]));
        expect(_art(() => oeffnen(umgeschrieben, kontext: mit(conv: 'c-anders'))), CryptoFehlerArt.entschluesselung);
      });

      test('falsche Signatur: anderer Absender, veränderte Signatur, Chiffretext, Kopf', () {
        final h = versiegeln();
        expect(_art(() => oeffnen(h, sender: pub(anderer))), CryptoFehlerArt.signatur, reason: 'als andere Person ausgegeben');
        expect(_art(() => oeffnen(versiegeln(von: anderer))), CryptoFehlerArt.signatur);
        for (final stelle in [3, 7, 12, 34, 35, 70, 97, 98, 100, base64urlDekodieren(h).length - 1]) {
          final bytes = base64urlDekodieren(h);
          bytes[stelle] ^= 0x01;
          expect(_art(() => oeffnen(base64urlKodieren(bytes))), isNotNull, reason: 'Bit an Stelle $stelle');
        }
      });

      test('Schlüsselversion: falsche Version wird abgelehnt, auch mit passendem Schlüssel; Hüllen-Version lässt sich nicht umschreiben', () {
        final h = versiegeln();
        // der Empfänger hat zu Version 1 einen anderen Schlüssel: Version passt nicht zur Hülle
        expect(_art(() => oeffnen(h, sender: pub(absender, 1))), CryptoFehlerArt.signatur);
        // Angreifer schreibt die Version im Kopf um und passt den Kontext an: Signatur und AAD decken sie ab
        final bytes = base64urlDekodieren(h);
        bytes[9] = 1;
        expect(_art(() => oeffnen(base64urlKodieren(bytes), kontext: mit(version: 1), sender: pub(absender, 1))), CryptoFehlerArt.signatur);
        expect(_art(() => versiegeln(kontext: mit(version: 0))), CryptoFehlerArt.format);
      });

      test('alter Schlüssel nach Rotation: Nachricht in Version 1 bleibt mit dem damaligen Schlüssel prüfbar, nicht mit dem neuen', () {
        final alt = absender; // Version 1
        final neu = Personenschluessel.erzeugen(crypto); // Version 2 nach der Rotation
        final vor = versiegeln(kontext: mit(version: 1), von: alt);
        final nach = versiegeln(kontext: mit(version: 2), von: neu);
        // Empfänger kennt beide Versionen (aktuell: gemerkt, alt: aus der Historie)
        expect(oeffnen(vor, kontext: mit(version: 1), sender: alt.oeffentlich(1)), klartext);
        expect(oeffnen(nach, kontext: mit(version: 2), sender: neu.oeffentlich(2)), klartext);
        // mit dem jeweils anderen Schlüssel oder der falschen Version scheitert beides
        expect(_art(() => oeffnen(vor, kontext: mit(version: 1), sender: neu.oeffentlich(1))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(vor, kontext: mit(version: 1), sender: neu.oeffentlich(2))), CryptoFehlerArt.signatur);
        expect(_art(() => oeffnen(nach, kontext: mit(version: 2), sender: alt.oeffentlich(2))), CryptoFehlerArt.signatur);
        // der Empfänger liest die Version aus der Hülle, um den passenden Schlüssel zu holen
        expect(HuellenCodec.senderKeyVersionLesen(vor), 1);
        expect(HuellenCodec.senderKeyVersionLesen(nach), 2);
      });

      test('Domänentrennung: eine Nachrichten-Signatur gilt nicht als Wrap- oder Mitgliederlisten-Signatur und umgekehrt', () {
        final h = versiegeln();
        final bytes = base64urlDekodieren(h);
        final signatur = Uint8List.sublistView(bytes, 34, 98);
        final aad = _kontext.aad(1);
        final kopf = Uint8List.sublistView(bytes, 0, 34);
        final ct = Uint8List.sublistView(bytes, 98);
        final nachrichtEingabe = verketten([utf8Bytes(kDomaeneNachricht), u32Bytes(aad.length), aad, kopf, ct]);
        expect(crypto.signaturPruefen(nachrichtEingabe, signatur, absender.signOeffentlich), isTrue);
        for (final domaene in [kDomaeneWrap, kDomaeneMitglieder]) {
          expect(crypto.signaturPruefen(verketten([utf8Bytes(domaene), u32Bytes(aad.length), aad, kopf, ct]), signatur, absender.signOeffentlich), isFalse);
        }
        // Längenrahmen: dieselben Bytes ohne Rahmen ergeben keine gültige Signatur
        expect(crypto.signaturPruefen(verketten([utf8Bytes(kDomaeneNachricht), aad, kopf, ct]), signatur, absender.signOeffentlich), isFalse);
        expect(kDomaeneNachricht, 'lx-familyhub|msg|v1');
        expect(kDomaeneWrap, 'lx-familyhub|wrap|v1');
        expect(kDomaeneMitglieder, 'lx-familyhub|members|v1');
      });

      test('falscher Epochenschlüssel: Entschlüsselung scheitert (Signatur stimmt)', () {
        final h = versiegeln();
        expect(_art(() => oeffnen(h, schluessel: crypto.zufall(32))), CryptoFehlerArt.entschluesselung);
      });

      test('Nonce-Wächter fängt einen kaputten Zufallsgenerator ab (kein Garant, nur innerhalb einer Instanz)', () {
        final festes = FakeCryptoProvider(konstant: true);
        final c2 = HuellenCodec(festes);
        final pk = Personenschluessel.erzeugen(festes);
        final schluessel = Uint8List(32);
        c2.versiegeln(schluessel: schluessel, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim);
        expect(_art(() => c2.versiegeln(schluessel: schluessel, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim)), CryptoFehlerArt.nonce);
        // mit einem anderen Schlüssel ist dieselbe Nonce kein Problem
        c2.versiegeln(schluessel: Uint8List(32)..[0] = 1, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim);
        // eine neue Instanz kennt die früheren Nonces nicht: der Wächter ist kein Garant
        HuellenCodec(festes).versiegeln(schluessel: schluessel, klartext: klartext, kontext: _kontext, signGeheim: pk.signGeheim);
      });

      test('Formfehler: zu kurz, ungültige Kodierung, unbekannte Version/Verfahren', () {
        expect(_art(() => oeffnen('')), CryptoFehlerArt.format);
        expect(_art(() => oeffnen('abc')), CryptoFehlerArt.format);
        expect(_art(() => oeffnen('ungültig!')), CryptoFehlerArt.format);
        expect(_art(() => oeffnen('${versiegeln()}=')), CryptoFehlerArt.format);
        expect(_art(() => HuellenCodec.senderKeyVersionLesen('abc')), CryptoFehlerArt.format);
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

      test('AAD-Aufbau: conversation_id|message_id|sender_id|epoch|sender_key_version|reply_to|v', () {
        expect(
          String.fromCharCodes(_kontext.aad(1)),
          'c0000000-0000-4000-8000-000000000001|m0000000-0000-4000-8000-000000000002|u0000000-0000-4000-8000-000000000003|7|2||1',
        );
        expect(String.fromCharCodes(mit(antwort: 'q0000000-0000-4000-8000-000000000009').aad(1)), endsWith('|7|2|q0000000-0000-4000-8000-000000000009|1'));
      });

      test('Antwort-Bezug ist an Chiffretext und Signatur gebunden: der Server kann ihn nicht umhängen, weglassen oder erfinden', () {
        final h = versiegeln(kontext: mit(antwort: 'q0000000-0000-4000-8000-000000000009'));
        expect(oeffnen(h, kontext: mit(antwort: 'q0000000-0000-4000-8000-000000000009')), isNotEmpty);
        for (final falsch in [null, 'q0000000-0000-4000-8000-00000000000a']) {
          expect(_art(() => oeffnen(h, kontext: mit(antwort: falsch))), CryptoFehlerArt.signatur);
        }
        expect(_art(() => oeffnen(versiegeln(), kontext: mit(antwort: 'q0000000-0000-4000-8000-000000000009'))), CryptoFehlerArt.signatur);
        expect(_art(() => versiegeln(kontext: mit(antwort: 'a|b'))), CryptoFehlerArt.format);
      });
    });
  }
}
