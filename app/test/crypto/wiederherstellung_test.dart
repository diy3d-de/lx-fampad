// Wiederherstellungsschlüssel: Anzeige (Base32 mit Prüfsumme), Sicherung des Personenschlüssels, richtiger/falscher Schlüssel.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/code32.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/uebertragung.dart';
import 'package:lx_fampad/data/crypto/wiederherstellung.dart';

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
  group('Anzeige und Prüfsumme', () {
    final wk = Uint8List.fromList(List.generate(32, (i) => i * 8 + 1));

    test('14 Vierergruppen aus A-Z und 2-7, Roundtrip', () {
      final text = Wiederherstellung.anzeigen(wk);
      expect(text, matches(RegExp(r'^([A-Z2-7]{4}-){13}[A-Z2-7]{4}$')));
      expect(Wiederherstellung.lesen(text), wk);
      expect(Wiederherstellung.gruppen(wk), hasLength(kCodeGruppen));
    });

    test('Eingabe tolerant: Kleinbuchstaben, Leerzeichen, fehlende Bindestriche, 0/1/8 als O/I/B', () {
      final text = Wiederherstellung.anzeigen(wk);
      expect(Wiederherstellung.lesen(text.toLowerCase()), wk);
      expect(Wiederherstellung.lesen(text.replaceAll('-', ' ')), wk);
      expect(Wiederherstellung.lesen(text.replaceAll('-', '')), wk);
      expect(Wiederherstellung.lesen('  $text\n'), wk);
      // Verwechslungen, die es im Alphabet nicht gibt, werden gelesen wie gemeint
      final mitNullen = text.replaceAll('O', '0').replaceAll('I', '1').replaceAll('B', '8');
      expect(Wiederherstellung.lesen(mitNullen), wk);
    });

    test('jeder einzelne Tippfehler wird durch die Prüfsumme erkannt', () {
      final roh = Wiederherstellung.anzeigen(wk).replaceAll('-', '');
      for (var i = 0; i < roh.length; i++) {
        final ersatz = roh[i] == 'A' ? 'B' : 'A';
        final falsch = '${roh.substring(0, i)}$ersatz${roh.substring(i + 1)}';
        expect(_art(() => Wiederherstellung.lesen(falsch)), anyOf(CryptoFehlerArt.pruefsumme, CryptoFehlerArt.format), reason: 'Stelle $i');
      }
    });

    test('falsche Länge, ungültige Zeichen, Vertauschen zweier Zeichen', () {
      final roh = Wiederherstellung.anzeigen(wk).replaceAll('-', '');
      expect(_art(() => Wiederherstellung.lesen('')), CryptoFehlerArt.format);
      expect(_art(() => Wiederherstellung.lesen(roh.substring(1))), CryptoFehlerArt.format);
      expect(_art(() => Wiederherstellung.lesen('$roh''A')), CryptoFehlerArt.format);
      expect(_art(() => Wiederherstellung.lesen('${roh.substring(0, 5)}!${roh.substring(6)}')), CryptoFehlerArt.format);
      final a = roh[10], b = roh[11];
      if (a != b) {
        expect(_art(() => Wiederherstellung.lesen('${roh.substring(0, 10)}$b$a${roh.substring(12)}')), CryptoFehlerArt.pruefsumme);
      }
    });

    test('Übertragungscode ist kein Wiederherstellungsschlüssel (Verwendungszweck in der Prüfsumme)', () {
      final code = Uebertragung.codeText(wk);
      expect(_art(() => Wiederherstellung.lesen(code)), CryptoFehlerArt.pruefsumme);
      expect(_art(() => Uebertragung.geheimnisLesen(Wiederherstellung.anzeigen(wk))), CryptoFehlerArt.pruefsumme);
    });

    test('Base32 ohne Reststücke: 35 Byte ergeben genau 56 Zeichen', () {
      expect(Code32.kodieren(wk, 'x', gruppiert: false), hasLength(56));
    });

    test('Probe: der vollständig eingetippte Schlüssel zählt, unabhängig von Schreibweise und Trennern; Teile, Tippfehler und Fremdes nicht', () {
      final z = Wiederherstellung.anzeigen(wk);
      expect(Wiederherstellung.stimmt(wk, z), isTrue);
      expect(Wiederherstellung.stimmt(wk, z.toLowerCase()), isTrue);
      expect(Wiederherstellung.stimmt(wk, ' ${z.replaceAll('-', ' ')} '), isTrue);
      final g = Wiederherstellung.gruppen(wk);
      expect(Wiederherstellung.stimmt(wk, g.take(2).join('-')), isFalse, reason: 'nur zwei Gruppen reichen nicht');
      expect(Wiederherstellung.stimmt(wk, ''), isFalse);
      expect(Wiederherstellung.stimmt(wk, z.replaceFirst(z[0], z[0] == 'A' ? 'B' : 'A')), isFalse, reason: 'ein Tippfehler (Prüfsumme)');
      final fremd = Uint8List.fromList([for (final b in wk) b ^ 1]);
      expect(Wiederherstellung.stimmt(wk, Wiederherstellung.anzeigen(fremd)), isFalse, reason: 'ein anderer, gültiger Schlüssel');
    });
  });

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Sicherung des Personenschlüssels ($name)', () {
      late Personenschluessel pk;
      late Uint8List wk;
      late String blob;

      setUp(() {
        pk = Personenschluessel.erzeugen(crypto);
        wk = Wiederherstellung.neuerSchluessel(crypto);
        blob = Wiederherstellung.sicherungErstellen(crypto, schluessel: pk, wiederherstellungsschluessel: wk, userId: _uid, keyVersion: 3);
      });

      test('richtiger Schlüssel: Personenschlüssel und Schlüsselversion kommen zurück', () {
        final s = Wiederherstellung.sicherungOeffnen(crypto, blob: blob, wiederherstellungsschluessel: wk, userId: _uid);
        expect(s.keyVersion, 3);
        expect(s.schluessel.exportieren(), pk.exportieren());
        expect(s.schluessel.encOeffentlich, pk.encOeffentlich);
        expect(s.schluessel.signOeffentlich, pk.signOeffentlich);
      });

      test('Blob ist undurchsichtig, kompakt und enthält den Schlüssel nicht im Klartext', () {
        final bytes = base64urlDekodieren(blob);
        expect(bytes.length, 1 + 4 + 24 + 64 + 16);
        expect(blob.length, lessThan(2048));
        final geheim = pk.exportieren();
        expect(String.fromCharCodes(bytes).contains(String.fromCharCodes(geheim.sublist(0, 16))), isFalse);
      });

      test('falscher Wiederherstellungsschlüssel wird abgelehnt', () {
        final falsch = Wiederherstellung.neuerSchluessel(crypto);
        expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: blob, wiederherstellungsschluessel: falsch, userId: _uid)), CryptoFehlerArt.entschluesselung);
        final einBitAnders = Uint8List.fromList(wk)..[0] ^= 1;
        expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: blob, wiederherstellungsschluessel: einBitAnders, userId: _uid)), CryptoFehlerArt.entschluesselung);
      });

      test('Sicherung gehört zu Person und Schlüsselversion (AAD)', () {
        expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: blob, wiederherstellungsschluessel: wk, userId: 'u-anders')), CryptoFehlerArt.entschluesselung);
        // Version im Blob umschreiben: die AAD passt nicht mehr
        final bytes = base64urlDekodieren(blob);
        bytes[4] = 9;
        expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: base64urlKodieren(bytes), wiederherstellungsschluessel: wk, userId: _uid)), CryptoFehlerArt.entschluesselung);
      });

      test('veränderter oder beschädigter Blob', () {
        final bytes = base64urlDekodieren(blob);
        for (final i in [10, 40, bytes.length - 1]) {
          final b = Uint8List.fromList(bytes)..[i] ^= 1;
          expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: base64urlKodieren(b), wiederherstellungsschluessel: wk, userId: _uid)), CryptoFehlerArt.entschluesselung);
        }
        expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: 'abc', wiederherstellungsschluessel: wk, userId: _uid)), CryptoFehlerArt.format);
        final v2 = Uint8List.fromList(bytes)..[0] = 2;
        expect(_art(() => Wiederherstellung.sicherungOeffnen(crypto, blob: base64urlKodieren(v2), wiederherstellungsschluessel: wk, userId: _uid)), CryptoFehlerArt.version);
      });

      test('zwei Sicherungen desselben Schlüssels unterscheiden sich (Zufalls-Nonce)', () {
        expect(Wiederherstellung.sicherungErstellen(crypto, schluessel: pk, wiederherstellungsschluessel: wk, userId: _uid, keyVersion: 3), isNot(blob));
      });
    });
  }
}
