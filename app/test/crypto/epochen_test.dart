// Phase-2-Bausteine: signierter Epochenschlüssel-Wrap und signierte Mitgliederliste. Der Server als Angreifer: Unterschieben, Umleiten, Mitglieder einschleusen.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/epochen.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/vertrauen.dart';

import '../support/fake_crypto.dart';

const _conv = 'c0000000-0000-4000-8000-000000000001';
const _anna = 'a0000000-0000-4000-8000-00000000000a';
const _ben = 'b0000000-0000-4000-8000-00000000000b';
const _cora = 'c0000000-0000-4000-8000-00000000000c';

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
    group('Epochenschlüssel-Verteilung ($name)', () {
      late Personenschluessel anna; // Verteiler, Key-Version 3
      late Personenschluessel ben; // Empfänger, Key-Version 2
      late Personenschluessel cora; // Angreifer/Mitglied
      late Uint8List epochenKey;
      const annaV = 3;
      const benV = 2;

      setUp(() {
        anna = Personenschluessel.erzeugen(crypto);
        ben = Personenschluessel.erzeugen(crypto);
        cora = Personenschluessel.erzeugen(crypto);
        epochenKey = crypto.zufall(32);
      });

      EpochenWrap wrap({int epoch = 5, String conv = _conv, String an = _ben, OeffentlicheSchluessel? empf, Personenschluessel? von, int vonV = annaV, String vonId = _anna}) =>
          EpochenVerteiler.wrapErstellen(
            crypto,
            epochenschluessel: epochenKey,
            conversationId: conv,
            epoch: epoch,
            empfaengerId: an,
            empfaenger: empf ?? ben.oeffentlich(benV),
            verteilerId: vonId,
            verteilerKeyVersion: vonV,
            verteilerSignGeheim: (von ?? anna).signGeheim,
          );

      MitgliederListe liste({int epoch = 5, List<MitgliedEintrag>? m}) =>
          MitgliederListe.erstellen(conversationId: _conv, epoch: epoch, mitglieder: m ?? [const MitgliedEintrag(_ben, benV), const MitgliedEintrag(_anna, annaV)]);

      SignierteMitgliederListe signiert({MitgliederListe? l, Personenschluessel? von, int vonV = annaV, String vonId = _anna}) => EpochenVerteiler.listeSignieren(
        crypto,
        liste: l ?? liste(),
        verteilerId: vonId,
        verteilerKeyVersion: vonV,
        verteilerSignGeheim: (von ?? anna).signGeheim,
      );

      Uint8List uebernehmen({EpochenWrap? w, SignierteMitgliederListe? l, int epoch = 5, String conv = _conv, String ich = _ben, int ichV = benV, OeffentlicheSchluessel? verteiler, Iterable<MitgliedEintrag>? erwartet}) =>
          EpochenEmpfaenger.uebernehmen(
            crypto,
            wrap: w ?? wrap(),
            liste: l ?? signiert(),
            erwarteteConversationId: conv,
            erwarteteEpoche: epoch,
            ichId: ich,
            meinSchluessel: ben,
            meineKeyVersion: ichV,
            verteiler: verteiler ?? anna.oeffentlich(annaV),
            erwarteteMitglieder: erwartet,
          );

      test('Roundtrip: Empfänger bekommt den Epochenschlüssel', () {
        expect(uebernehmen(), epochenKey);
        expect(uebernehmen(erwartet: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, benV)]), epochenKey);
      });

      test('Transportform: kodieren und dekodieren ergibt dasselbe, Beschädigungen werden abgelehnt', () {
        final w = wrap();
        final l = signiert();
        final w2 = EpochenWrap.dekodieren(w.kodieren());
        final l2 = SignierteMitgliederListe.dekodieren(l.kodieren());
        expect(uebernehmen(w: w2, l: l2), epochenKey);
        expect(_art(() => EpochenWrap.dekodieren('abc')), isNotNull);
        expect(_art(() => SignierteMitgliederListe.dekodieren('abc')), isNotNull);
        expect(_art(() => EpochenWrap.dekodieren('')), CryptoFehlerArt.format);
        final bytes = base64urlDekodieren(w.kodieren());
        expect(_art(() => EpochenWrap.dekodieren(base64urlKodieren(bytes.sublist(0, bytes.length - 3)))), CryptoFehlerArt.format);
        expect(_art(() => EpochenWrap.dekodieren(base64urlKodieren([...bytes, 0]))), CryptoFehlerArt.format);
        final v2 = Uint8List.fromList(bytes)..[0] = 2;
        expect(_art(() => EpochenWrap.dekodieren(base64urlKodieren(v2))), CryptoFehlerArt.version);
      });

      test('Server schiebt eine fremde Sealed Box ohne gültige Signatur unter: abgelehnt', () {
        // Der Server kennt den öffentlichen Schlüssel von Ben und verpackt einen eigenen Epochenschlüssel
        final falscherKey = crypto.zufall(32);
        final fremdeBox = crypto.versiegeln(falscherKey, ben.encOeffentlich);
        final w = wrap();
        final untergeschoben = EpochenWrap(
          conversationId: w.conversationId,
          epoch: w.epoch,
          empfaengerId: w.empfaengerId,
          empfaengerKeyVersion: w.empfaengerKeyVersion,
          verteilerId: w.verteilerId,
          verteilerKeyVersion: w.verteilerKeyVersion,
          versiegelt: fremdeBox,
          signatur: w.signatur, // die Signatur der echten Box: passt nicht zum Hash der fremden
        );
        expect(_art(() => uebernehmen(w: untergeschoben)), CryptoFehlerArt.signatur);
        final ohneSignatur = EpochenWrap(
          conversationId: w.conversationId,
          epoch: w.epoch,
          empfaengerId: w.empfaengerId,
          empfaengerKeyVersion: w.empfaengerKeyVersion,
          verteilerId: w.verteilerId,
          verteilerKeyVersion: w.verteilerKeyVersion,
          versiegelt: fremdeBox,
          signatur: Uint8List(64),
        );
        expect(_art(() => uebernehmen(w: ohneSignatur)), CryptoFehlerArt.signatur);
      });

      test('ein anderes Mitglied signiert als Anna: abgelehnt (Signatur gegen den gemerkten Schlüssel von Anna)', () {
        expect(_art(() => uebernehmen(w: wrap(von: cora))), CryptoFehlerArt.signatur);
        expect(_art(() => uebernehmen(l: signiert(von: cora))), CryptoFehlerArt.signatur);
        // Cora gibt sich offen als Verteiler aus: dann ist ihr Schlüssel nicht der gemerkte
        expect(_art(() => uebernehmen(w: wrap(von: cora, vonId: _cora), l: signiert(von: cora, vonId: _cora))), CryptoFehlerArt.signatur, reason: 'Verteiler-Schlüssel ist der von Anna');
      });

      test('Umlenken: Wrap in andere Konversation, Epoche, an andere Person oder Schlüsselversion wird abgelehnt', () {
        expect(_art(() => uebernehmen(w: wrap(conv: 'c-anders'))), CryptoFehlerArt.format);
        expect(_art(() => uebernehmen(w: wrap(epoch: 4))), CryptoFehlerArt.format);
        expect(_art(() => uebernehmen(w: wrap(an: _cora))), CryptoFehlerArt.format);
        expect(_art(() => uebernehmen(ichV: 9)), CryptoFehlerArt.format);
        expect(_art(() => uebernehmen(epoch: 6)), CryptoFehlerArt.format);
        expect(_art(() => uebernehmen(conv: 'c-anders')), CryptoFehlerArt.format);
        // Felder im Wrap umschreiben (Signatur deckt sie ab)
        final w = wrap();
        final umgeschrieben = EpochenWrap(
          conversationId: w.conversationId,
          epoch: w.epoch,
          empfaengerId: _cora,
          empfaengerKeyVersion: w.empfaengerKeyVersion,
          verteilerId: w.verteilerId,
          verteilerKeyVersion: w.verteilerKeyVersion,
          versiegelt: w.versiegelt,
          signatur: w.signatur,
        );
        expect(_art(() => EpochenEmpfaenger.wrapOeffnen(crypto, wrap: umgeschrieben, erwarteteConversationId: _conv, erwarteteEpoche: 5, ichId: _cora, meinSchluessel: ben, meineKeyVersion: benV, verteiler: anna.oeffentlich(annaV))), CryptoFehlerArt.signatur);
      });

      test('Wrap für eine veraltete Schlüsselversion des Empfängers oder Verteilers wird abgelehnt', () {
        expect(_art(() => uebernehmen(verteiler: anna.oeffentlich(annaV + 1))), CryptoFehlerArt.signatur, reason: 'gemerkter Verteiler-Schlüssel hat eine andere Version');
        expect(_art(() => uebernehmen(w: wrap(vonV: 2), l: signiert(vonV: 2))), CryptoFehlerArt.signatur);
      });

      test('Mitgliederliste: Server schleust ein Mitglied ein oder lässt eines weg (Liste neu signieren kann er nicht)', () {
        final echt = signiert();
        // eingeschleust: Liste enthält zusätzlich Cora, Signatur der echten Liste
        final eingeschleust = SignierteMitgliederListe(
          liste: liste(m: [const MitgliedEintrag(_ben, benV), const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_cora, 1)]),
          verteilerId: echt.verteilerId,
          verteilerKeyVersion: echt.verteilerKeyVersion,
          signatur: echt.signatur,
        );
        expect(_art(() => uebernehmen(l: eingeschleust)), CryptoFehlerArt.signatur);
        // andere Schlüsselversion eines Mitglieds
        final umgedeutet = SignierteMitgliederListe(
          liste: liste(m: [const MitgliedEintrag(_ben, benV), const MitgliedEintrag(_anna, 9)]),
          verteilerId: echt.verteilerId,
          verteilerKeyVersion: echt.verteilerKeyVersion,
          signatur: echt.signatur,
        );
        expect(_art(() => uebernehmen(l: umgedeutet)), CryptoFehlerArt.signatur);
        // Liste einer anderen Epoche/Konversation
        expect(_art(() => uebernehmen(l: signiert(l: liste(epoch: 4)))), CryptoFehlerArt.format);
      });

      test('Mitgliederliste ohne den Empfänger (oder mit anderer Schlüsselversion) wird nicht übernommen', () {
        expect(_art(() => uebernehmen(l: signiert(l: liste(m: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_cora, 1)])))), CryptoFehlerArt.format);
        expect(_art(() => uebernehmen(l: signiert(l: liste(m: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, 7)])))), CryptoFehlerArt.format);
      });

      test('erwartete Mitglieder: Abweichung der Liste von der eigenen Sicht der Konversation wird abgelehnt', () {
        final mitCora = signiert(l: liste(m: [const MitgliedEintrag(_ben, benV), const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_cora, 1)]));
        expect(_art(() => uebernehmen(l: mitCora, erwartet: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, benV)])), CryptoFehlerArt.format);
        expect(uebernehmen(l: mitCora, erwartet: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, benV), const MitgliedEintrag(_cora, 1)]), epochenKey);
        expect(_art(() => uebernehmen(erwartet: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, benV + 1)])), CryptoFehlerArt.format);
      });

      test('Wrap und Liste müssen vom selben Verteiler stammen', () {
        expect(_art(() => uebernehmen(l: signiert(von: cora, vonId: _cora), verteiler: cora.oeffentlich(1))), CryptoFehlerArt.signatur);
      });

      test('Mitgliederliste ist kanonisch: sortiert, ohne Doppelte', () {
        final l = liste(m: [const MitgliedEintrag(_cora, 1), const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, benV)]);
        expect(l.mitglieder.map((m) => m.userId), [_anna, _ben, _cora]);
        expect(_art(() => liste(m: [const MitgliedEintrag(_anna, 1), const MitgliedEintrag(_anna, 2)])), CryptoFehlerArt.format);
        expect(_art(() => liste(m: [const MitgliedEintrag(_anna, 0)])), CryptoFehlerArt.format);
        // dieselbe Menge in anderer Reihenfolge ergibt dieselbe Signatureingabe
        final s1 = signiert(l: liste(m: [const MitgliedEintrag(_ben, benV), const MitgliedEintrag(_anna, annaV)]));
        final s2 = signiert(l: liste(m: [const MitgliedEintrag(_anna, annaV), const MitgliedEintrag(_ben, benV)]));
        expect(s1.kodieren(), s2.kodieren());
      });

      test('Domänentrennung: eine Wrap-Signatur ist keine Mitgliederlisten-Signatur', () {
        final w = wrap();
        final l = signiert();
        final listeMitWrapSignatur = SignierteMitgliederListe(liste: l.liste, verteilerId: l.verteilerId, verteilerKeyVersion: l.verteilerKeyVersion, signatur: w.signatur);
        expect(_art(() => uebernehmen(l: listeMitWrapSignatur)), CryptoFehlerArt.signatur);
        final wrapMitListenSignatur = EpochenWrap(
          conversationId: w.conversationId,
          epoch: w.epoch,
          empfaengerId: w.empfaengerId,
          empfaengerKeyVersion: w.empfaengerKeyVersion,
          verteilerId: w.verteilerId,
          verteilerKeyVersion: w.verteilerKeyVersion,
          versiegelt: w.versiegelt,
          signatur: l.signatur,
        );
        expect(_art(() => uebernehmen(w: wrapMitListenSignatur)), CryptoFehlerArt.signatur);
      });

      test('falscher Empfänger-Schlüssel öffnet die Sealed Box nicht', () {
        expect(
          _art(() => EpochenEmpfaenger.wrapOeffnen(crypto, wrap: wrap(), erwarteteConversationId: _conv, erwarteteEpoche: 5, ichId: _ben, meinSchluessel: cora, meineKeyVersion: benV, verteiler: anna.oeffentlich(annaV))),
          CryptoFehlerArt.entschluesselung,
        );
      });

      test('Epochenschlüssel hat genau 32 Byte', () {
        expect(
          _art(() => EpochenVerteiler.wrapErstellen(crypto, epochenschluessel: Uint8List(16), conversationId: _conv, epoch: 1, empfaengerId: _ben, empfaenger: ben.oeffentlich(1), verteilerId: _anna, verteilerKeyVersion: 1, verteilerSignGeheim: anna.signGeheim)),
          CryptoFehlerArt.schluessel,
        );
      });

      group('mit Vertrauen (TOFU-Speicher)', () {
        late VertrauensPruefer vertrauen;
        setUp(() => vertrauen = VertrauensPruefer(MemorySchluesselSpeicher(), eigeneUserId: _ben));

        Future<Uint8List> mitVertrauen({EpochenWrap? w, SignierteMitgliederListe? l}) => EpochenEmpfaenger.uebernehmenMitVertrauen(
          crypto,
          vertrauen: vertrauen,
          wrap: w ?? wrap(),
          liste: l ?? signiert(),
          erwarteteConversationId: _conv,
          erwarteteEpoche: 5,
          ichId: _ben,
          meinSchluessel: ben,
          meineKeyVersion: benV,
        );

        test('bekannter Verteiler: Schlüssel kommt aus dem TOFU-Speicher, nicht vom Server', () async {
          await vertrauen.pruefen({_anna: anna.oeffentlich(annaV)});
          expect(await mitVertrauen(), epochenKey);
        });

        test('unbekannter Verteiler wird abgelehnt', () async {
          await expectLater(mitVertrauen(), throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', CryptoFehlerArt.schluessel)));
        });

        test('Server unterschiebt einen anderen Schlüssel für Anna: Signatur passt nicht zum gemerkten', () async {
          await vertrauen.pruefen({_anna: anna.oeffentlich(annaV)});
          // Cora (oder der Server) signiert im Namen von Anna mit eigenem Schlüssel
          await expectLater(
            mitVertrauen(w: wrap(von: cora), l: signiert(von: cora)),
            throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', CryptoFehlerArt.signatur)),
          );
        });
      });
    });
  }
}
