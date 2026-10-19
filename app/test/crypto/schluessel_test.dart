// Personenschlüssel, Sicherheitscode und Vertrauen beim ersten Sehen (TOFU).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/sicherheitscode.dart';
import 'package:lx_fampad/data/crypto/vertrauen.dart';

import '../support/fake_crypto.dart';

OeffentlicheSchluessel _key(int n, {int version = 1}) =>
    OeffentlicheSchluessel(enc: Uint8List.fromList(List.filled(32, n)), sign: Uint8List.fromList(List.filled(32, n + 100)), version: version);

Future<void> main() async {
  for (final (name, crypto) in await kryptoVarianten()) {
    group('Personenschlüssel ($name)', () {
      test('erzeugen, exportieren (64 Byte), wieder einlesen: gleiche öffentliche Schlüssel', () {
        final pk = Personenschluessel.erzeugen(crypto);
        final bytes = pk.exportieren();
        expect(bytes, hasLength(64));
        final zurueck = Personenschluessel.ausBytes(crypto, bytes);
        expect(zurueck.encOeffentlich, pk.encOeffentlich);
        expect(zurueck.signOeffentlich, pk.signOeffentlich);
        expect(pk.encOeffentlich, hasLength(32));
        expect(pk.signOeffentlich, hasLength(32));
        expect(pk.signGeheim, hasLength(64));
        expect(pk.oeffentlich(4).version, 4);
      });

      test('zwei Schlüssel sind verschieden; falsche Länge wird abgelehnt', () {
        expect(Personenschluessel.erzeugen(crypto).encOeffentlich, isNot(Personenschluessel.erzeugen(crypto).encOeffentlich));
        expect(() => Personenschluessel.ausBytes(crypto, Uint8List(63)), throwsA(isA<CryptoFehler>()));
      });

      test('Signatur- und Verschlüsselungsschlüssel sind unabhängig', () {
        final pk = Personenschluessel.erzeugen(crypto);
        expect(pk.encOeffentlich, isNot(pk.signOeffentlich));
      });

      test('Sealed Box: nur der Besitzer des X25519-Schlüssels öffnet (Phase 2: Gruppenschlüssel)', () {
        final a = Personenschluessel.erzeugen(crypto);
        final nachricht = utf8Bytes('Epochenschlüssel');
        final c = crypto.versiegeln(nachricht, a.encOeffentlich);
        expect(crypto.versiegelungOeffnen(c, a.encOeffentlich, a.encGeheim), nachricht);
      });
    });
  }

  group('OeffentlicheSchluessel', () {
    test('Base64url-Roundtrip und strenge Prüfung', () {
      final k = _key(7, version: 2);
      final zurueck = OeffentlicheSchluessel.ausBase64(enc: k.encBase64, sign: k.signBase64, version: 2);
      expect(zurueck.gleichWie(k), isTrue);
      expect(zurueck.version, 2);
      expect(() => OeffentlicheSchluessel.ausBase64(enc: 'kurz', sign: k.signBase64, version: 1), throwsA(isA<CryptoFehler>()));
      expect(() => OeffentlicheSchluessel.ausBase64(enc: '${k.encBase64}=', sign: k.signBase64, version: 1), throwsA(isA<CryptoFehler>()));
    });

    test('Version zählt nicht zur Identität', () {
      expect(_key(1, version: 1).gleichWie(_key(1, version: 5)), isTrue);
      expect(_key(1).gleichWie(_key(2)), isFalse);
    });
  });

  group('Sicherheitscode', () {
    final mitglieder = [MitgliedSchluessel('u-b', _key(2)), MitgliedSchluessel('u-a', _key(1)), MitgliedSchluessel('u-c', _key(3))];

    test('stabil: feste Schlüssel ergeben immer denselben Code (Known-Answer)', () {
      // Wert festgeschrieben (unabhängig mit Node nachgerechnet): eine Änderung am Verfahren würde alle bisher verglichenen Codes entwerten
      expect(familienSicherheitscode(mitglieder), '75996 98870 03651 22295 03371 91943');
      expect(personenSicherheitscode(MitgliedSchluessel('u-a', _key(1))), '71655 11116 89162 61256');
    });

    test('Format: 6 Gruppen zu 5 Ziffern, Person: 4 Gruppen', () {
      expect(familienSicherheitscode(mitglieder), matches(RegExp(r'^(\d{5} ){5}\d{5}$')));
      expect(personenSicherheitscode(mitglieder.first), matches(RegExp(r'^(\d{5} ){3}\d{5}$')));
    });

    test('unabhängig von der Reihenfolge der Liste', () {
      expect(familienSicherheitscode(mitglieder.reversed.toList()), familienSicherheitscode(mitglieder));
    });

    test('ändert sich bei jedem Schlüsselwechsel, bei neuem Mitglied und bei anderer Zuordnung; Version zählt nicht', () {
      final basis = familienSicherheitscode(mitglieder);
      expect(familienSicherheitscode([mitglieder[0], mitglieder[1], MitgliedSchluessel('u-c', _key(9))]), isNot(basis));
      expect(familienSicherheitscode([...mitglieder, MitgliedSchluessel('u-d', _key(4))]), isNot(basis));
      expect(familienSicherheitscode([MitgliedSchluessel('u-b', _key(1)), MitgliedSchluessel('u-a', _key(2)), mitglieder[2]]), isNot(basis));
      expect(familienSicherheitscode([MitgliedSchluessel('u-b', _key(2, version: 9)), mitglieder[1], mitglieder[2]]), basis);
    });

    test('leere Liste ergibt leeren Text', () => expect(familienSicherheitscode([]), ''));
  });

  group('Vertrauen beim ersten Sehen (TOFU)', () {
    late MemorySchluesselSpeicher speicher;
    VertrauensPruefer pruefer([MemorySchluesselSpeicher? s]) => VertrauensPruefer(s ?? speicher, eigeneUserId: 'ich');

    setUp(() => speicher = MemorySchluesselSpeicher());

    test('erster Schlüssel wird gemerkt, keine Warnung; gleicher Schlüssel später ebenfalls keine', () async {
      expect(await pruefer().pruefen({'anna': _key(1)}), isEmpty);
      expect(await pruefer().pruefen({'anna': _key(1, version: 1)}), isEmpty);
    });

    test('Schlüsselwechsel: deutliche Warnung, der neue Schlüssel wird NICHT übernommen und warnt weiter', () async {
      await pruefer().pruefen({'anna': _key(1)});
      for (var i = 0; i < 3; i++) {
        final w = await pruefer().pruefen({'anna': _key(2, version: 2)});
        expect(w, hasLength(1));
        expect(w.single.userId, 'anna');
        expect(w.single.aktuell!.version, 2);
        expect(w.single.gemerkt.version, 1);
      }
    });

    test('erst nach Bestätigung gilt der neue Schlüssel', () async {
      await pruefer().pruefen({'anna': _key(1)});
      final w = (await pruefer().pruefen({'anna': _key(2, version: 2)})).single;
      await pruefer().akzeptieren('anna', w.aktuell);
      expect(await pruefer().pruefen({'anna': _key(2, version: 2)}), isEmpty);
      // ein weiterer Wechsel warnt wieder
      expect(await pruefer().pruefen({'anna': _key(3, version: 3)}), hasLength(1));
    });

    test('ein bestätigter Wechsel behält die früheren Schlüssel: Signaturen aus der Zeit davor lassen sich weiter prüfen (nur vom Gerät gemerkt)', () async {
      await pruefer().pruefen({'anna': _key(1)});
      final w2 = (await pruefer().pruefen({'anna': _key(2, version: 2)})).single;
      await pruefer().akzeptieren('anna', w2.aktuell);
      final w3 = (await pruefer().pruefen({'anna': _key(3, version: 3)})).single;
      await pruefer().akzeptieren('anna', w3.aktuell);
      expect((await pruefer().gemerkterSchluessel('anna'))!.version, 3);
      expect((await pruefer().gemerkterSchluessel('anna', version: 3))!.version, 3);
      for (final v in [1, 2]) {
        final k = await pruefer().gemerkterSchluessel('anna', version: v);
        expect(k!.version, v);
        expect(k.gleichWie(_key(v, version: v)), isTrue, reason: 'genau der damals bestätigte Schlüssel');
      }
      expect(await pruefer().gemerkterSchluessel('anna', version: 7), isNull, reason: 'eine nie bestätigte Version gibt es nicht');
      // dieselbe Bestätigung noch einmal verdoppelt nichts, und die Historie überlebt das nächste Prüfen
      await pruefer().akzeptieren('anna', w3.aktuell);
      expect(await pruefer().pruefen({'anna': _key(3, version: 3)}), isEmpty);
      expect((await pruefer().gemerkterSchluessel('anna', version: 1))!.version, 1);
      // Person verschwindet aus der Familie: der Eintrag bleibt als "entfernt" erhalten (alte Signaturen und Wraps bleiben prüfbar)
      expect(await pruefer().pruefen({}), isEmpty);
      expect((await pruefer().gemerkterSchluessel('anna', version: 1))!.version, 1);
      expect((await pruefer().gemerkterSchluessel('anna'))!.version, 3);
      // taucht sie mit demselben Schlüssel wieder auf, gibt es keine Warnung; mit einem anderen die normale Warnung
      expect(await pruefer().pruefen({'anna': _key(3, version: 3)}), isEmpty);
      await pruefer().pruefen({});
      final w = await pruefer().pruefen({'anna': _key(9, version: 4)});
      expect(w, hasLength(1));
      expect(w.single.rueckfall, isFalse);
    });

    test('Schlüsselversion sinkt nie: ein Rückfall auf eine ältere Version wird als Rückfall gewarnt und lässt sich nicht akzeptieren', () async {
      await pruefer().pruefen({'anna': _key(1)});
      final w2 = (await pruefer().pruefen({'anna': _key(2, version: 2)})).single;
      await pruefer().akzeptieren('anna', w2.aktuell);
      final w = (await pruefer().pruefen({'anna': _key(1)})).single;
      expect(w.rueckfall, isTrue);
      await expectLater(pruefer().akzeptieren('anna', w.aktuell), throwsA(isA<CryptoFehler>()));
      expect((await pruefer().gemerkterSchluessel('anna'))!.version, 2);
    });

    test('verschwundener Schlüssel warnt ebenfalls; Bestätigung vergisst den alten', () async {
      await pruefer().pruefen({'anna': _key(1)});
      final w = (await pruefer().pruefen({'anna': null})).single;
      expect(w.aktuell, isNull);
      await pruefer().akzeptieren('anna', null);
      expect(await pruefer().pruefen({'anna': null}), isEmpty);
    });

    test('Person ohne Schlüssel beim ersten Sehen: nichts zu merken; später gesehener Schlüssel wird gemerkt', () async {
      expect(await pruefer().pruefen({'ben': null}), isEmpty);
      expect(await pruefer().pruefen({'ben': _key(5)}), isEmpty);
      expect(await pruefer().pruefen({'ben': _key(6)}), hasLength(1));
    });

    test('die eigene Person wird nicht geprüft; mehrere Personen unabhängig', () async {
      await pruefer().pruefen({'ich': _key(1), 'anna': _key(2), 'ben': _key(3)});
      final w = await pruefer().pruefen({'ich': _key(9), 'anna': _key(2), 'ben': _key(4)});
      expect(w.map((x) => x.userId), ['ben']);
    });

    test('Gemerktes überlebt einen Neustart (Speicher), ein Konto kennt die Merkliste eines anderen nicht', () async {
      await pruefer().pruefen({'anna': _key(1)});
      expect(await pruefer().pruefen({'anna': _key(2)}), hasLength(1), reason: 'gleiche Ablage, neue Instanz');
      final anderes = VertrauensPruefer(speicher, eigeneUserId: 'zweite-person');
      expect(await anderes.pruefen({'anna': _key(2)}), isEmpty, reason: 'eigene Merkliste je Konto');
    });

    test('beschädigte Ablage wird wie leer behandelt', () async {
      await speicher.schreiben('e2ee.vertrauen.ich', utf8Bytes('{kaputt'));
      expect(await pruefer().pruefen({'anna': _key(1)}), isEmpty);
      expect(await pruefer().pruefen({'anna': _key(2)}), hasLength(1));
      await speicher.schreiben('e2ee.vertrauen.ich', Uint8List.fromList(utf8.encode('[1,2]')));
      expect(await pruefer().pruefen({'anna': _key(1)}), isEmpty);
    });

    test('Sicherheitscode des gemerkten Schlüssels passt zum Personen-Code', () async {
      await pruefer().pruefen({'anna': _key(1)});
      final w = await pruefer().pruefen({'anna': _key(2)});
      expect(VertrauensPruefer.codeVon('anna', w.single.gemerkt), personenSicherheitscode(MitgliedSchluessel('anna', _key(1))));
    });
  });

  group('Schlüsselspeicher im Arbeitsspeicher', () {
    test('lesen, schreiben, löschen, Präfix löschen; Kopien statt Verweise', () async {
      final s = MemorySchluesselSpeicher();
      final bytes = Uint8List.fromList([1, 2, 3]);
      await s.schreiben('e2ee.pk.a', bytes);
      await s.schreiben('e2ee.vertrauen.a', bytes);
      bytes[0] = 99;
      expect((await s.lesen('e2ee.pk.a'))![0], 1);
      await s.loescheMitPraefix('e2ee.pk.');
      expect(await s.lesen('e2ee.pk.a'), isNull);
      expect(await s.lesen('e2ee.vertrauen.a'), isNotNull);
      await s.loeschen('e2ee.vertrauen.a');
      expect(await s.lesen('e2ee.vertrauen.a'), isNull);
    });
  });
}
