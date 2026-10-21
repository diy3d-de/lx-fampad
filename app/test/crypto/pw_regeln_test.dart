// Tests der Passwort-Regeln, des Vorschlags und der Wortliste (kein Argon2, läuft auch mit dem Fake).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/pw_regeln.dart';
import 'package:lx_fampad/data/crypto/wortliste.dart';

import '../support/fake_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PasswortProblem> p(String pw) => passwortPruefen(pw, email: 'anna.beispiel@example.org', anzeigename: 'Anna Beispiel');

  group('passwortPruefen', () {
    test('gute Passwörter bestehen', () {
      expect(p('dunkel-kirsche-brot-lampe-fluss'), isEmpty);
      expect(p('Mein Hund frisst gern Käse 42!'), isEmpty);
      expect(p('abandon-ability-able-about-above'), isEmpty);
      expect(p(r'x7#Qm9$vLp2!Rt'), isEmpty);
    });

    test('Mindestlänge 12 Zeichen (nach Normalisierung, in Zeichen statt Bytes)', () {
      expect(p('elf-zeichen'), contains(PasswortProblem.zuKurz)); // 11
      expect(p('zwoelf-zeich'), isNot(contains(PasswortProblem.zuKurz))); // 12
      expect(p('äöüäöüäöüäö'), contains(PasswortProblem.zuKurz)); // 11 Zeichen, aber 22 Byte
      final e = String.fromCharCode(0x301); // zerlegtes é: e + Akzent
      expect(p('Cafe${e}Cafe${e}Cafe$e'), isNot(contains(PasswortProblem.zuKurz))); // 12 Zeichen nach NFC
      expect(p('Cafe${e}Cafe${e}Caf'), contains(PasswortProblem.zuKurz)); // 11
      expect(p(''), contains(PasswortProblem.zuKurz));
    });

    test('E-Mail und Anzeigename (auch Teile, unabhängig von Groß-/Kleinschreibung und Trennzeichen)', () {
      expect(p('anna.beispiel@example.org'), contains(PasswortProblem.enthaeltKontodaten));
      expect(p('ANNABEISPIEL-xyz-rot-baum'), contains(PasswortProblem.enthaeltKontodaten));
      expect(p('mein-beispiel-ist-gut-123'), contains(PasswortProblem.enthaeltKontodaten));
      expect(p('anna-und-so-weiter-sagt-mir'), contains(PasswortProblem.enthaeltKontodaten)); // "Anna" ist als Namensteil (4 Zeichen) enthalten
      expect(p('dunkel-kirsche-brot-lampe'), isNot(contains(PasswortProblem.enthaeltKontodaten)));
    });

    test('Verbotsliste: Wort selbst oder Wort macht mindestens die Hälfte aus', () {
      expect(p('passwort1234'), contains(PasswortProblem.zuHaeufig));
      expect(p('Passwort123456'), contains(PasswortProblem.zuHaeufig));
      expect(p('qwertzuiopas'), contains(PasswortProblem.zuHaeufig));
      expect(p('Familienzentrale'), contains(PasswortProblem.zuHaeufig));
      expect(p('mein passwort ist wirklich sehr lang und gut'), isNot(contains(PasswortProblem.zuHaeufig)));
    });

    test('einfache Muster: Zahlen-/Buchstabenfolgen, Wiederholungen', () {
      expect(p('123456789012'), contains(PasswortProblem.einfachesMuster));
      expect(p('987654321098'), contains(PasswortProblem.einfachesMuster));
      expect(p('abcdefghijkl'), contains(PasswortProblem.einfachesMuster));
      expect(p('aaaaaaaaaaaa'), contains(PasswortProblem.einfachesMuster));
      expect(p('abababababab'), contains(PasswortProblem.einfachesMuster));
      expect(p('x7Kq9x7Kq9x7Kq9'), contains(PasswortProblem.einfachesMuster));
      expect(p('wxyz-12-kirsche-mond'), isNot(contains(PasswortProblem.einfachesMuster)));
      expect(p('123-baum-456-haus'), isNot(contains(PasswortProblem.einfachesMuster)));
    });

    test('Wort mit Ziffern/Jahr und Kürzel wird abgelehnt (Sommer2026!ab), längere Sätze nicht', () {
      expect(p('Sommer2026!ab'), contains(PasswortProblem.zuHaeufig));
      expect(p('Winter-2025-xy'), contains(PasswortProblem.zuHaeufig));
      expect(p('Sommer2026 am Strand mit Eis'), isNot(contains(PasswortProblem.zuHaeufig)));
    });

    test('einzelne Surrogate: ungueltigeZeichen statt Absturz', () {
      expect(p('abc${String.fromCharCode(0xd800)}defghijklmn'), [PasswortProblem.ungueltigeZeichen]);
    });

    test('ohne Kontodaten und mit Sonderfällen keine Ausnahme', () {
      expect(passwortPruefen('dunkel-kirsche-brot-lampe'), isEmpty);
      expect(passwortPruefen('dunkel-kirsche-brot-lampe', email: '', anzeigename: ' '), isEmpty);
      expect(passwortPruefen('dunkel-kirsche-brot-lampe', email: 'kein-at-zeichen'), isEmpty);
      for (final pr in PasswortProblem.values) {
        expect(pr.meldung, isNotEmpty);
      }
    });
  });

  group('Wortliste und Vorschlag', () {
    test('Wortliste: 2048 verschiedene Wörter, Kleinbuchstaben, kein Kommentar', () async {
      final w = await ladeWortliste();
      expect(w, hasLength(2048));
      expect(w.toSet(), hasLength(2048));
      expect(w.every((x) => RegExp(r'^[a-z]{3,8}$').hasMatch(x)), isTrue);
      expect(w.first, 'abandon');
      expect(w.last, 'zoo');
    });

    test('Wortliste: Kopf nennt Quelle und Lizenz (Datei auf Platte)', () {
      final kopf = File('assets/crypto/wortliste.txt').readAsLinesSync().takeWhile((z) => z.startsWith('#')).join('\n');
      expect(kopf, contains('BIP-39'));
      expect(kopf, contains('MIT'));
    });

    test('Vorschlag: 5 Wörter, getrennt, jedes aus der Liste, besteht die eigene Prüfung', () async {
      final w = await ladeWortliste();
      final crypto = FakeCryptoProvider();
      for (var i = 0; i < 50; i++) {
        final v = passwortVorschlag(crypto, w);
        final teile = v.split('-');
        expect(teile, hasLength(5));
        expect(teile.every(w.contains), isTrue);
        expect(passwortPruefen(v), isEmpty, reason: v);
      }
      expect(passwortVorschlag(crypto, w, anzahl: 3, trenner: ' ').split(' '), hasLength(3));
    });

    test('Vorschlag: verschieden, gleichverteilt (keine Verzerrung durch Modulo), 55 Bit', () async {
      final w = await ladeWortliste();
      final crypto = FakeCryptoProvider(seed: 7);
      final vorschlaege = {for (var i = 0; i < 200; i++) passwortVorschlag(crypto, w)};
      expect(vorschlaege, hasLength(200));
      // Verteilung über eine Liste, die kein Teiler von 65536 ist (1000 Wörter): jedes Wort wird getroffen, keines weicht stark ab
      final liste = [for (var i = 0; i < 1000; i++) 'w$i'];
      final zaehler = <String, int>{};
      for (var i = 0; i < 20000; i++) {
        for (final t in passwortVorschlag(crypto, liste, anzahl: 5).split('-')) {
          zaehler[t] = (zaehler[t] ?? 0) + 1;
        }
      }
      expect(zaehler, hasLength(1000));
      const mittel = 100000 / 1000;
      expect(zaehler.values.every((v) => v > mittel * 0.6 && v < mittel * 1.4), isTrue);
      expect(passwortVorschlagBits(2048), closeTo(55, 1e-9));
    });

    test('Vorschlag: unbrauchbare Listen werden abgelehnt', () {
      expect(() => passwortVorschlag(FakeCryptoProvider(), ['a', 'b']), throwsArgumentError);
    });
  });
}
