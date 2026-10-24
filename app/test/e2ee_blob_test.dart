// E2EE-Blob (Abschnitt 6n): Verschlüsseln und Entschlüsseln einer Datei mit secretstream über den CryptoProvider (Fake immer, libsodium wo verfügbar: in der CI Pflicht). Geprüft: Round-Trip über die
// Blockgrenzen (64 KiB), Größenformel und Grenze `maxE2eeBytes`, Manipulation, Kürzen, Anhängen, Vertauschen und falscher Schlüssel werden erkannt, Schlüssel je Datei zufällig, kein Klartext im Chiffretext.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/dateien/e2ee_blob.dart';

import 'support/fake_crypto.dart';

Uint8List bytes(int n, [int seed = 7]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 131 + seed + (i >> 8)) & 255]);

bool gleich(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> main() async {
  for (final (name, crypto) in await kryptoVarianten()) {
    group('E2EE-Blob ($name)', () {
      final helfer = E2eeBlobHelfer(crypto);

      test('Round-Trip über die Blockgrenzen: 1 Byte, knapp unter, genau und knapp über einem Block, mehrere Blöcke', () async {
        for (final n in [1, 100, 65535, 65536, 65537, 131072, 3 * 65536 + 5, 1024 * 1024]) {
          final klar = bytes(n);
          final b = await helfer.verschluesseln(klar);
          expect(b.groesse, e2eeGroesse(n), reason: 'Größe bei $n Byte');
          expect(b.chiffretext[0], kE2eeFormat);
          expect(b.schluessel, hasLength(32));
          expect(b.sha256, sha256Hex(b.chiffretext));
          final zurueck = await helfer.entschluesseln(chiffretext: b.chiffretext, schluessel: b.schluessel, erwarteteSha256: b.sha256);
          expect(gleich(zurueck, klar), isTrue, reason: '$n Byte');
        }
      });

      test('eine leere Datei hat genau einen leeren Schlussblock und kommt leer zurück', () async {
        final b = await helfer.verschluesseln(Uint8List(0));
        expect(b.groesse, e2eeGroesse(0));
        expect(b.groesse, 1 + 24 + 17);
        expect(await helfer.entschluesseln(chiffretext: b.chiffretext, schluessel: b.schluessel), isEmpty);
      });

      test('der Schlüssel ist je Datei zufällig; gleicher Inhalt ergibt anderen Chiffretext; der Klartext steht nicht darin', () async {
        final klar = Uint8List.fromList(List.generate(2000, (i) => 'GEHEIMNIS-GEHEIMNIS'.codeUnitAt(i % 19)));
        final a = await helfer.verschluesseln(klar);
        final b = await helfer.verschluesseln(klar);
        expect(a.schluessel, isNot(b.schluessel));
        expect(a.chiffretext, isNot(b.chiffretext));
        expect(a.sha256, isNot(b.sha256));
        final text = String.fromCharCodes(a.chiffretext);
        expect(text.contains('GEHEIMNIS'), isFalse);
      });

      test('falscher Schlüssel, veränderter Block, veränderte Kopfzeile, falsches Format: alles wird erkannt', () async {
        final klar = bytes(3 * 65536 + 100);
        final b = await helfer.verschluesseln(klar);
        final falsch = Uint8List.fromList(b.schluessel)..[0] ^= 1;
        await expectLater(helfer.entschluesseln(chiffretext: b.chiffretext, schluessel: falsch), throwsA(isA<CryptoFehler>()));
        for (final pos in [1, 10, 26, 100, 65536, 2 * 65536 + 500, b.chiffretext.length - 1, b.chiffretext.length - 20]) {
          final kaputt = Uint8List.fromList(b.chiffretext)..[pos] ^= 0x40;
          await expectLater(helfer.entschluesseln(chiffretext: kaputt, schluessel: b.schluessel), throwsA(isA<CryptoFehler>()), reason: 'Byte $pos');
        }
        final format = Uint8List.fromList(b.chiffretext)..[0] = 2;
        await expectLater(helfer.entschluesseln(chiffretext: format, schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
      });

      test('Kürzen (auch um einen ganzen Block), Anhängen und Abschneiden bis auf die Kopfzeile werden erkannt', () async {
        final klar = bytes(3 * 65536);
        final b = await helfer.verschluesseln(klar);
        final voll = 65536 + 17;
        // ein ganzer (letzter) Block fehlt: der vorletzte trägt nicht das Schlusszeichen
        final gekuerzt = Uint8List.sublistView(b.chiffretext, 0, b.chiffretext.length - voll);
        await expectLater(helfer.entschluesseln(chiffretext: gekuerzt, schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
        // ein Byte fehlt
        await expectLater(helfer.entschluesseln(chiffretext: Uint8List.sublistView(b.chiffretext, 0, b.chiffretext.length - 1), schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
        // etwas angehängt
        await expectLater(helfer.entschluesseln(chiffretext: Uint8List.fromList([...b.chiffretext, 1, 2, 3]), schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
        await expectLater(helfer.entschluesseln(chiffretext: Uint8List.fromList([...b.chiffretext, ...List.filled(40, 9)]), schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
        // nur die Kopfzeile
        await expectLater(helfer.entschluesseln(chiffretext: Uint8List.sublistView(b.chiffretext, 0, 25), schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
        await expectLater(helfer.entschluesseln(chiffretext: Uint8List(0), schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
      });

      test('vertauschte Blöcke werden erkannt', () async {
        final b = await helfer.verschluesseln(bytes(3 * 65536 + 10));
        final c = Uint8List.fromList(b.chiffretext);
        const start = 1 + 24;
        const block = 65536 + 17;
        final eins = c.sublist(start, start + block);
        final zwei = c.sublist(start + block, start + 2 * block);
        c.setRange(start, start + block, zwei);
        c.setRange(start + block, start + 2 * block, eins);
        await expectLater(helfer.entschluesseln(chiffretext: c, schluessel: b.schluessel), throwsA(isA<CryptoFehler>()));
      });

      test('Prüfsumme der Bytes: eine falsche wird vor dem Entschlüsseln erkannt', () async {
        final b = await helfer.verschluesseln(bytes(500));
        await expectLater(helfer.entschluesseln(chiffretext: b.chiffretext, schluessel: b.schluessel, erwarteteSha256: 'ab' * 32), throwsA(isA<CryptoFehler>()));
        expect(await helfer.entschluesseln(chiffretext: b.chiffretext, schluessel: b.schluessel, erwarteteSha256: b.sha256.toUpperCase()), hasLength(500));
      });

      test('Schlüssel falscher Länge werden abgelehnt', () async {
        await expectLater(helfer.verschluesseln(bytes(10), schluessel: Uint8List(16)), throwsA(isA<CryptoFehler>()));
        final b = await helfer.verschluesseln(bytes(10));
        await expectLater(helfer.entschluesseln(chiffretext: b.chiffretext, schluessel: Uint8List(31)), throwsA(isA<CryptoFehler>()));
      });

      test('der Schlüssel lässt sich überschreiben', () async {
        final b = await helfer.verschluesseln(bytes(10));
        b.schluesselVergessen();
        expect(b.schluessel.every((x) => x == 0), isTrue);
      });
    });
  }

  group('Größen', () {
    test('Overhead: Format, Kopfzeile und 17 Byte je Block', () {
      expect(e2eeGroesse(0), 42);
      expect(e2eeGroesse(1), 43);
      expect(e2eeGroesse(65536), 1 + 24 + 65536 + 17);
      expect(e2eeGroesse(65537), 1 + 24 + 65537 + 34);
    });

    test('größter Klartext zu `maxE2eeBytes`: die Grenze passt genau, 100 MB passen mit Overhead hinein', () {
      const max = 105906176; // 100 MB + 1 MiB
      final n = e2eeKlartextMax(max);
      expect(e2eeGroesse(n), lessThanOrEqualTo(max));
      expect(e2eeGroesse(n + 1), greaterThan(max));
      expect(n, greaterThan(104857600)); // 100 MB Klartext passen
      expect(e2eeKlartextMax(10), 0);
      expect(e2eeKlartextMax(42), 0);
      expect(e2eeKlartextMax(43), 1);
      expect(e2eeKlartextMax(e2eeGroesse(65536)), 65536);
      expect(e2eeKlartextMax(e2eeGroesse(65536) - 1), 65535);
    });

    test('100 MB: 1600 Blöcke zu je 17 Byte plus Format und Kopfzeile', () {
      expect(e2eeGroesse(104857600), 104857600 + 25 + 17 * 1600);
    });
  });
}
