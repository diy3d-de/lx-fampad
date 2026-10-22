// Bausteine der Eltern-Wiederherstellung (eltern_wiederherstellung.dart): Hinterlegung (Sealed Box + Signatur des Kindes), Verpflichtung auf den flüchtigen Schlüssel, Kurzcode,
// Übergabe (Sealed Box + Signatur des Elternteils). Jede Bindung (Person, Version, Anfrage, Schlüssel) wird einzeln verletzt und muss scheitern. Fake und libsodium.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/domaenen.dart';
import 'package:lx_fampad/data/crypto/eltern_wiederherstellung.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';

import '../support/fake_crypto.dart';

const _kind = '11111111-1111-4111-8111-111111111111';
const _papa = '22222222-2222-4222-8222-222222222222';
const _anfrage = '33333333-3333-4333-8333-333333333333';

Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));
String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final varianten = await kryptoVarianten();
  final sodium = varianten.where((v) => v.$1 == 'libsodium').map((v) => v.$2).firstOrNull;

  test('Die Domänenpräfixe sind fest und verschieden', () {
    final alle = [kDomaeneHinterlegung, kDomaeneFreigabe, kDomaeneVerpflichtung, kDomaeneKurzcode, kDomaeneWrap, kDomaeneMitglieder, kDomaeneNachricht];
    expect(alle.toSet(), hasLength(alle.length));
    expect(kDomaeneHinterlegung, 'lx-familyhub|escrow|v1');
    expect(kDomaeneFreigabe, 'lx-familyhub|escrow-release|v1');
    expect(kDomaeneVerpflichtung, 'lx-familyhub|escrow-commit|v1');
    expect(kDomaeneKurzcode, 'lx-familyhub|escrow-sas|v1');
  });

  for (final (name, crypto) in varianten) {
    group('Eltern-Wiederherstellung ($name)', () {
      late Personenschluessel kind;
      late Personenschluessel papa;
      late OeffentlicheSchluessel kindOeff;
      late OeffentlicheSchluessel papaOeff;

      setUp(() {
        kind = Personenschluessel.erzeugen(crypto);
        papa = Personenschluessel.erzeugen(crypto);
        kindOeff = kind.oeffentlich(3);
        papaOeff = papa.oeffentlich(2);
      });

      HinterlegungEintrag hinterlegen() => ElternKrypto.hinterlegen(crypto, kind: kind, kindId: _kind, keyVersion: 3, elternId: _papa, eltern: papaOeff);

      Uint8List oeffnen(HinterlegungEintrag e, {String? blob, String? sig, String? kindId, int? keyVersion, OeffentlicheSchluessel? kindVertraut, String? elternId, int? elternVersion, Personenschluessel? eltern}) =>
          ElternKrypto.hinterlegungOeffnen(
            crypto,
            blob: blob ?? e.blob,
            sig: sig ?? e.sig,
            kindId: kindId ?? _kind,
            keyVersion: keyVersion ?? 3,
            kindVertraut: kindVertraut ?? kindOeff,
            elternId: elternId ?? _papa,
            elternVersion: elternVersion ?? 2,
            elternSchluessel: eltern ?? papa,
          );

      test('Hinterlegung: das Elternteil öffnet sie und erhält genau die Seeds des Kindes; der Blob enthält sie nicht im Klartext', () {
        final e = hinterlegen();
        expect(oeffnen(e), kind.exportieren());
        if (name == 'libsodium') expect(base64urlDekodieren(e.blob), hasLength(64 + 48), reason: 'Sealed Box: 64 Byte Seeds + 48 Byte Overhead');
        expect(base64urlDekodieren(e.sig), hasLength(64));
        expect(e.blob.contains(base64urlKodieren(kind.exportieren())), isFalse);
        // zwei Hinterlegungen desselben Schlüssels unterscheiden sich (frischer ephemerer Schlüssel der Sealed Box)
        expect(hinterlegen().blob, isNot(e.blob));
      });

      test('Hinterlegung: jede Bindung wird einzeln verletzt und scheitert (Kind, Version, Elternteil, Schlüssel, Signatur, Blob)', () {
        final e = hinterlegen();
        expect(() => oeffnen(e, kindId: _papa), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnen(e, keyVersion: 4, kindVertraut: kind.oeffentlich(4)), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnen(e, keyVersion: 4), _fehler(CryptoFehlerArt.schluessel), reason: 'gemerkter Schlüssel gehört zu einer anderen Version');
        expect(() => oeffnen(e, elternId: _kind), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnen(e, elternVersion: 9), _fehler(CryptoFehlerArt.signatur));
        // fremder (nicht gemerkter) Schlüssel des Kindes: die Signatur passt nicht
        final fremd = Personenschluessel.erzeugen(crypto).oeffentlich(3);
        expect(() => oeffnen(e, kindVertraut: fremd), _fehler(CryptoFehlerArt.signatur));
        // anderes Elternteil kann nicht öffnen (Signatur ist gültig, die Sealed Box nicht an dessen Schlüssel)
        final mama = Personenschluessel.erzeugen(crypto);
        expect(() => oeffnen(e, eltern: mama), throwsA(isA<CryptoFehler>()));
        // jedes Byte von Blob und Signatur zählt
        final blob = base64urlDekodieren(e.blob);
        for (var i = 0; i < blob.length; i += 7) {
          final k = Uint8List.fromList(blob)..[i] ^= 1;
          expect(() => oeffnen(e, blob: base64urlKodieren(k)), throwsA(isA<CryptoFehler>()), reason: 'Blob Byte $i');
        }
        final sg = base64urlDekodieren(e.sig);
        for (var i = 0; i < sg.length; i += 5) {
          final k = Uint8List.fromList(sg)..[i] ^= 1;
          expect(() => oeffnen(e, sig: base64urlKodieren(k)), throwsA(isA<CryptoFehler>()), reason: 'Signatur Byte $i');
        }
      });

      test('Verpflichtung: passt nur zu genau diesem Schlüssel und dieser Nonce', () {
        final p = ElternKrypto.fluechtigesPaar(crypto);
        final c = ElternKrypto.verpflichtung(crypto, p.oeffentlich, p.nonce);
        expect(base64urlDekodieren(c), hasLength(32));
        expect(ElternKrypto.verpflichtungPasst(crypto, c, p.oeffentlich, p.nonce), isTrue);
        final anders = ElternKrypto.fluechtigesPaar(crypto);
        expect(ElternKrypto.verpflichtungPasst(crypto, c, anders.oeffentlich, p.nonce), isFalse);
        expect(ElternKrypto.verpflichtungPasst(crypto, c, p.oeffentlich, anders.nonce), isFalse);
        expect(ElternKrypto.verpflichtungPasst(crypto, 'kein base64!', p.oeffentlich, p.nonce), isFalse);
        expect(p.nonce, hasLength(16));
        expect(p.oeffentlich, hasLength(32));
        p.loeschen();
        expect(p.geheim.every((x) => x == 0), isTrue);
      });

      test('Kurzcode: acht Ziffern, deterministisch, hängt von jeder Eingabe ab (auch Verpflichtung, Kind und Elternteil)', () {
        final p = ElternKrypto.fluechtigesPaar(crypto);
        final r = crypto.zufall(16);
        final commit = ElternKrypto.verpflichtung(crypto, p.oeffentlich, p.nonce);
        String code(Uint8List pub, Uint8List nonce, Uint8List ch, String id, {String? cm, String? kind, String? eltern}) =>
            ElternKrypto.kurzcode(crypto, pub: pub, nonce: nonce, challenge: ch, anfrageId: id, commit: cm ?? commit, kindId: kind ?? _kind, elternId: eltern ?? _papa);
        final c = code(p.oeffentlich, p.nonce, r, _anfrage);
        expect(c, matches(RegExp(r'^\d{8}$')));
        expect(code(p.oeffentlich, p.nonce, r, _anfrage), c);
        final q = ElternKrypto.fluechtigesPaar(crypto);
        // verschiedene Eingaben ergeben (bis auf Zufallstreffer 1:10^8) verschiedene Codes
        final andere = {
          code(q.oeffentlich, p.nonce, r, _anfrage),
          code(p.oeffentlich, q.nonce, r, _anfrage),
          code(p.oeffentlich, p.nonce, crypto.zufall(16), _anfrage),
          code(p.oeffentlich, p.nonce, r, _anfrage.replaceAll('3', '4')),
          code(p.oeffentlich, p.nonce, r, _anfrage, cm: ElternKrypto.verpflichtung(crypto, q.oeffentlich, q.nonce)),
          code(p.oeffentlich, p.nonce, r, _anfrage, kind: _papa),
          code(p.oeffentlich, p.nonce, r, _anfrage, eltern: _kind),
        };
        expect(andere.where((x) => x == c), isEmpty);
        expect(andere.length, 7);
        // führende Nullen bleiben
        final viele = [for (var i = 0; i < 300; i++) code(p.oeffentlich, p.nonce, crypto.zufall(16), _anfrage)];
        expect(viele.every((x) => x.length == 8), isTrue);
        expect(viele.toSet().length, greaterThan(250), reason: 'gleichmäßig genug verteilt');
      });

      test('Übergabe: das Kind öffnet sie mit seinem flüchtigen Schlüssel und erhält den Personenschlüssel; jede Bindung wird einzeln verletzt', () {
        final p = ElternKrypto.fluechtigesPaar(crypto);
        final f = ElternKrypto.freigeben(crypto, seeds: kind.exportieren(), anfrageId: _anfrage, kindId: _kind, keyVersion: 3, elternId: _papa, eltern: papa, elternVersion: 2, tempPub: p.oeffentlich);
        Personenschluessel oeffnenKind(
          {String? blob, String? sig, String? anfrage, String? kindId, int? keyVersion, String? elternId, OeffentlicheSchluessel? vertraut, FluechtigesPaar? paar}) =>
            ElternKrypto.freigabeOeffnen(
              crypto,
              blob: blob ?? f.blob,
              sig: sig ?? f.sig,
              anfrageId: anfrage ?? _anfrage,
              kindId: kindId ?? _kind,
              keyVersion: keyVersion ?? 3,
              elternId: elternId ?? _papa,
              elternVertraut: vertraut ?? papaOeff,
              paar: paar ?? p,
            );
        expect(oeffnenKind().exportieren(), kind.exportieren());
        expect(() => oeffnenKind(anfrage: '44444444-4444-4444-8444-444444444444'), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnenKind(kindId: _papa), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnenKind(keyVersion: 4), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnenKind(elternId: _kind), _fehler(CryptoFehlerArt.signatur));
        expect(() => oeffnenKind(vertraut: papa.oeffentlich(5)), _fehler(CryptoFehlerArt.signatur), reason: 'andere Schlüsselversion des Elternteils');
        expect(() => oeffnenKind(vertraut: Personenschluessel.erzeugen(crypto).oeffentlich(2)), _fehler(CryptoFehlerArt.signatur), reason: 'nicht der gemerkte Schlüssel');
        // ein anderes flüchtiges Paar (z. B. vom Server untergeschoben) kann weder die Signatur noch die Sealed Box bestehen
        final fremdesPaar = ElternKrypto.fluechtigesPaar(crypto);
        expect(() => oeffnenKind(paar: fremdesPaar), throwsA(isA<CryptoFehler>()));
        final blob = base64urlDekodieren(f.blob);
        for (var i = 0; i < blob.length; i += 9) {
          final k = Uint8List.fromList(blob)..[i] ^= 1;
          expect(() => oeffnenKind(blob: base64urlKodieren(k)), throwsA(isA<CryptoFehler>()), reason: 'Blob Byte $i');
        }
      });

      test('Ein Server, der den flüchtigen Schlüssel austauscht, scheitert an der Verpflichtung (Elternteil) und an der Signatur (Kind)', () {
        final echt = ElternKrypto.fluechtigesPaar(crypto);
        final commit = ElternKrypto.verpflichtung(crypto, echt.oeffentlich, echt.nonce);
        final unterschoben = ElternKrypto.fluechtigesPaar(crypto);
        // das Elternteil sieht den unterschobenen Schlüssel: die Verpflichtung des Kindes passt nicht dazu
        expect(ElternKrypto.verpflichtungPasst(crypto, commit, unterschoben.oeffentlich, unterschoben.nonce), isFalse);
        expect(ElternKrypto.verpflichtungPasst(crypto, commit, unterschoben.oeffentlich, echt.nonce), isFalse);
        // verpackt das Elternteil trotzdem an den falschen Schlüssel, öffnet das Kind die Übergabe nicht
        final f = ElternKrypto.freigeben(crypto, seeds: kind.exportieren(), anfrageId: _anfrage, kindId: _kind, keyVersion: 3, elternId: _papa, eltern: papa, elternVersion: 2, tempPub: unterschoben.oeffentlich);
        expect(
          () => ElternKrypto.freigabeOeffnen(crypto, blob: f.blob, sig: f.sig, anfrageId: _anfrage, kindId: _kind, keyVersion: 3, elternId: _papa, elternVertraut: papaOeff, paar: echt),
          throwsA(isA<CryptoFehler>()),
        );
      });
    });
  }

  group('Known-Answer (libsodium)', () {
    final skip = sodium == null ? 'libsodium nicht verfügbar' : null;

    test('Verpflichtung und Kurzcode: feste Werte (das Format ist Teil des Protokolls)', () {
      final c = sodium!;
      final pub = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List.generate(16, (i) => 100 + i));
      final ch = Uint8List.fromList(List.generate(16, (i) => 200 + i));
      expect(_hex(base64urlDekodieren(ElternKrypto.verpflichtung(c, pub, nonce))), _katVerpflichtung);
      final commit = ElternKrypto.verpflichtung(c, pub, nonce);
      expect(ElternKrypto.kurzcode(c, pub: pub, nonce: nonce, challenge: ch, anfrageId: _anfrage, commit: commit, kindId: _kind, elternId: _papa), _katKurzcode);
    }, skip: skip);
  });
}

const _katVerpflichtung = 'd1609aa995188653a57f40031da76dc92278b0f04913030ffb4acd14293b1094';
const _katKurzcode = '63858157';
