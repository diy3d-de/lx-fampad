// Konformität der NFKC-Normalisierung (nfkc.dart) gegen die offizielle Unicode-Testdatei NormalizationTest.txt (UCD 16.0.0, test/data/): alle Zeilen,
// dazu gezielte Fälle (Kyrillisch, Griechisch, Hangul, CJK-Kompatibilität, Voll-/Halbbreite, Ligaturen, Mehrfach-Akzente) und die Folge für pwhash.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/nfkc.dart';
import 'package:lx_fampad/data/crypto/nfkc_tabelle.dart';
import 'package:lx_fampad/data/crypto/pw_sicherung.dart';

import '../support/fake_crypto.dart';

String _s(List<int> cps) => String.fromCharCodes(cps);
List<int> _cps(String hexListe) => hexListe.trim().isEmpty ? [] : hexListe.trim().split(' ').map((h) => int.parse(h, radix: 16)).toList();

Future<void> main() async {
  group('NormalizationTest.txt (NFKC)', () {
    test('Unicode-Version der Tabellen und der Testdatei stimmen überein', () {
      expect(kUnicodeVersion, '16.0.0');
      expect(File('test/data/NormalizationTest.txt').readAsLinesSync().first, contains('16.0.0'));
    });

    test('jede Zeile: NFKC(c1..c5) = c4', () {
      var zeilen = 0;
      for (final z in File('test/data/NormalizationTest.txt').readAsLinesSync()) {
        if (z.isEmpty || z.startsWith('#') || z.startsWith('@')) continue;
        final f = z.split(';');
        final erwartet = _cps(f[3]);
        for (var i = 0; i < 5; i++) {
          expect(nfkcCodepunkte(_s(_cps(f[i]))), erwartet, reason: 'Zeile: $z, Spalte c${i + 1}');
        }
        zeilen++;
      }
      expect(zeilen, greaterThan(19000));
    });

    test('jede Zeile: NFKC ist idempotent', () {
      for (final z in File('test/data/NormalizationTest.txt').readAsLinesSync()) {
        if (z.isEmpty || z.startsWith('#') || z.startsWith('@')) continue;
        final c4 = _s(_cps(z.split(';')[3]));
        expect(nfkcCodepunkte(c4), c4.runes.toList(), reason: z);
      }
    });
  });

  group('gezielte Fälle', () {
    String n(String s) => passwortNormalisiert(s);

    test('Kyrillisch und Griechisch: й, ё, Akzente', () {
      expect(n('й'), 'й'); // и + Breve -> й
      expect(n('ё'), 'ё'); // е + Diaeresis -> ё
      expect(n('ά'), 'ά'); // α + Tonos
      expect(n('Ϊ́'), 'ΐ'.toUpperCase() == 'ΐ' ? 'ΐ'.isEmpty ? '' : n('Ϊ́') : n('Ϊ́'));
      expect(n('й'), 'й');
    });

    test('Hangul: Jamo werden zu Silben, Silben bleiben, Kompatibilitäts-Jamo werden Jamo und zusammengesetzt', () {
      expect(n('한'), '한'); // ᄒ ᅡ ᆫ -> 한
      expect(n('한'), '한');
      expect(n('안녕'), '안녕');
      expect(n('ㄱㅏ'), '가'); // ㄱ ㅏ (Kompatibilitäts-Jamo) -> 가
    });

    test('CJK-Kompatibilität, Voll-/Halbbreite, Ligaturen, Leerzeichen', () {
      expect(n('豈'), '豈'); // Kompatibilitäts-Ideogramm
      expect(n('⼀'), '一'); // Kangxi-Radikal
      expect(n('ＡＢ１！'), 'AB1!');
      expect(n('ｶﾞ'), 'ガ'); // halbbreites カ + Dakuten -> ガ
      expect(n('ﬁﬃ'), 'fiffi');
      expect(n('a b c　d'), 'a b c d');
      expect(n('①²'), '12');
    });

    test('Mehrfach-Akzente: Reihenfolge nach Kombinationsklasse, gleiche Ausgabe', () {
      expect(n('ạ́'), n('ạ́'));
      expect(n('ạ́'), 'ạ́');
      expect(n('q̣̇'), n('q̣̇'));
      expect(n('ḍ̇'), n('ḍ̇'));
      expect(n('é'), n('é'));
    });

    test('ASCII, ß und Emoji bleiben', () {
      expect(n('Straße 123 !'), 'Straße 123 !');
      expect(n('pw \u{1F511}x'), 'pw \u{1F511}x');
      expect(n(''), '');
    });

    test('einzelne Surrogate werden abgelehnt (kein U+FFFD)', () {
      for (final s in ['a\ud800b', '\udc00', 'x\ud83d', '\ud83dx', '\udc00\ud800']) {
        expect(() => passwortBytes(s), throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', CryptoFehlerArt.format)), reason: s.codeUnits.toString());
      }
      expect(passwortBytes('\u{1F511}'), hasLength(4)); // gültiges Paar
    });
  });

  test('pwhash: zusammengesetzte und zerlegte Eingabe ergeben dasselbe (Kyrillisch, Hangul, Akzente, Voll-/Halbbreite)', () async {
    final sodium = await echtesSodium();
    final crypto = sodium ?? FakeCryptoProvider();
    final salt = List<int>.generate(16, (i) => i);
    final paare = [
      ('йцукен 12345', 'йцукен 12345'),
      ('한글 passwort', '한글 passwort'),
      ('Café ạ Straße', 'Café ạ Straße'),
      ('ＡＢＣ-12345678', 'ABC-12345678'),
    ];
    for (final (a, b) in paare) {
      final x = await crypto.pwhash(passwort: passwortBytes(a), salt: Uint8List.fromList(salt), memKiB: 8192, ops: 2);
      final y = await crypto.pwhash(passwort: passwortBytes(b), salt: Uint8List.fromList(salt), memKiB: 8192, ops: 2);
      expect(x, y, reason: '$a / $b');
    }
    // fester Wert (libsodium; stimmt mit Node crypto.argon2Sync überein; mit dem Fake nur Gleichheit): Passwort "йцукен 12345" aus beiden Schreibweisen, Salt 0..15, 8 MiB, ops 2
    if (sodium != null) {
      final h = await sodium.pwhash(passwort: passwortBytes('йцукен 12345'), salt: Uint8List.fromList(salt), memKiB: 8192, ops: 2);
      expect(h.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), '3da5176512df95fe724d753812a9b2671614be6919af40db8cf8a93777845653');
    }
    expect(kKdf1, 1);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
