// Standort teilen, Verschlüsselung: Freigabe-Wrap und Positions-Pakete. Der Server als Angreifer: Umlenken, Austauschen, Wiederholen, Fälschen.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/standort/standort_krypto.dart';

import 'support/fake_crypto.dart';

const _share = 's0000000-0000-4000-8000-000000000001';
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

PaketAblehnung? _ablehnung(void Function() f) {
  try {
    f();
  } on StandortPaketAbgelehnt catch (e) {
    return e.grund;
  }
  return null;
}

Future<void> main() async {
  for (final (name, crypto) in await kryptoVarianten()) {
    group('Standort teilen, Verschlüsselung ($name)', () {
      late Personenschluessel anna; // Senderin, Schlüsselversion 3
      late Personenschluessel ben; // Empfänger, Schlüsselversion 2
      late Personenschluessel cora; // Angreiferin
      const annaV = 3;
      const benV = 2;
      final jetzt = DateTime.utc(2026, 10, 20, 12);
      late StandortSender sender;

      setUp(() {
        anna = Personenschluessel.erzeugen(crypto);
        ben = Personenschluessel.erzeugen(crypto);
        cora = Personenschluessel.erzeugen(crypto);
        sender = StandortSender.neu(crypto, shareId: _share, ichId: _anna, meineKeyVersion: annaV, signGeheim: anna.signGeheim, endsAtMs: jetzt.add(const Duration(hours: 1)).millisecondsSinceEpoch);
      });

      String wrapFuerBen({StandortSender? s}) => (s ?? sender).wrapFuer(_ben, ben.oeffentlich(benV)).kodieren();

      StandortEmpfaenger annehmen({String? wrap, String shareId = _share, String vonId = _anna, String ich = _ben, int ichV = benV, Personenschluessel? mein, OeffentlicheSchluessel? absender, DateTime? zeit}) => StandortEmpfaenger.annehmen(
        crypto,
        wrapText: wrap ?? wrapFuerBen(),
        erwarteteShareId: shareId,
        erwarteterSenderId: vonId,
        ichId: ich,
        meinSchluessel: mein ?? ben,
        meineKeyVersion: ichV,
        sender: absender ?? anna.oeffentlich(annaV),
        jetzt: zeit ?? jetzt,
      );

      String paket({double lat = 48.1372, double lon = 11.5755, double? g = 12.5, DateTime? t, DateTime? messung}) => sender.paket(breite: lat, laenge: lon, genauigkeit: g, jetzt: t ?? jetzt, messzeit: messung);

      test('Hin und zurück: Freigabe und Position kommen unverändert an', () {
        final e = annehmen();
        final p = e.oeffnen(paket(), jetzt: jetzt);
        expect(p.breite, 48.1372);
        expect(p.laenge, 11.5755);
        expect(p.genauigkeit, 12.5);
        expect(p.seq, 1);
        expect(p.zeit.toUtc(), jetzt);
        expect(p.freigabeEnde.toUtc(), jetzt.add(const Duration(hours: 1)));
        // ohne Genauigkeit
        expect(e.oeffnen(paket(g: null), jetzt: jetzt).genauigkeit, isNull);
      });

      test('Wrap: für jemand anderen bestimmt, falsche Schlüsselversion, andere Freigabe oder anderer Absender werden abgelehnt', () {
        final fuerBen = wrapFuerBen();
        expect(_art(() => annehmen(wrap: fuerBen, ich: _cora, mein: cora)), CryptoFehlerArt.format);
        expect(_art(() => annehmen(wrap: fuerBen, ichV: benV + 1)), CryptoFehlerArt.format);
        expect(_art(() => annehmen(shareId: 's0000000-0000-4000-8000-000000000002')), CryptoFehlerArt.format);
        expect(_art(() => annehmen(vonId: _cora)), CryptoFehlerArt.format);
      });

      test('Wrap: ein Fremder (Server) kann keinen Wrap unterschieben; nur der gemerkte Schlüssel des Absenders zählt', () {
        final fremd = StandortSender.neu(crypto, shareId: _share, ichId: _anna, meineKeyVersion: annaV, signGeheim: cora.signGeheim, endsAtMs: jetzt.add(const Duration(hours: 1)).millisecondsSinceEpoch);
        expect(_art(() => annehmen(wrap: wrapFuerBen(s: fremd))), CryptoFehlerArt.signatur);
        // anderer gemerkter Schlüssel (Schlüsselwechsel nicht bestätigt)
        expect(_art(() => annehmen(absender: anna.oeffentlich(annaV + 1))), CryptoFehlerArt.signatur);
        expect(_art(() => annehmen(absender: cora.oeffentlich(annaV))), CryptoFehlerArt.signatur);
      });

      test('Wrap: ein verändertes Byte (auch in der Sealed Box) bricht die Signatur; Müll und neuere Version werden erkannt', () {
        final bytes = base64urlDekodieren(wrapFuerBen());
        for (final i in [5, bytes.length ~/ 2, bytes.length - 70, bytes.length - 3]) {
          final kopie = Uint8List.fromList(bytes)..[i] ^= 1;
          expect(_art(() => annehmen(wrap: base64urlKodieren(kopie))), isNotNull, reason: 'Byte $i');
        }
        expect(_art(() => annehmen(wrap: base64urlKodieren(bytes.sublist(0, 10)))), CryptoFehlerArt.format);
        expect(_art(() => annehmen(wrap: base64urlKodieren([...bytes, 0]))), CryptoFehlerArt.format);
        final neuer = Uint8List.fromList(bytes)..[0] = 9;
        expect(_art(() => annehmen(wrap: base64urlKodieren(neuer))), CryptoFehlerArt.version);
      });

      test('Wrap: abgelaufene oder unsinnig lange Freigaben werden abgelehnt', () {
        expect(_art(() => annehmen(zeit: jetzt.add(const Duration(hours: 2)))), CryptoFehlerArt.format);
        final zuLang = StandortSender.neu(crypto, shareId: _share, ichId: _anna, meineKeyVersion: annaV, signGeheim: anna.signGeheim, endsAtMs: jetzt.add(const Duration(days: 3)).millisecondsSinceEpoch);
        expect(_art(() => annehmen(wrap: wrapFuerBen(s: zuLang))), CryptoFehlerArt.format);
      });

      test('Paket: Wiederholung (gleiche oder kleinere Sequenznummer) wird abgelehnt, höhere nur in Reihenfolge angenommen', () {
        final e = annehmen();
        final p1 = paket();
        final p2 = paket();
        final p3 = paket();
        e.oeffnen(p2, jetzt: jetzt);
        expect(_ablehnung(() => e.oeffnen(p1, jetzt: jetzt)), PaketAblehnung.wiederholt);
        expect(_ablehnung(() => e.oeffnen(p2, jetzt: jetzt)), PaketAblehnung.wiederholt);
        expect(e.oeffnen(p3, jetzt: jetzt).seq, 3);
        expect(e.hoechsteSeq, 3);
      });

      test('Paket: nach dem Ablauf wird es verworfen; Messzeit und Ablauf in der Zukunft ebenfalls', () {
        final e = annehmen();
        final p = paket();
        expect(_ablehnung(() => e.oeffnen(p, jetzt: jetzt.add(kStandortPaketGueltigkeit + const Duration(seconds: 1)))), PaketAblehnung.abgelaufen);
        // der Zähler wurde dabei nicht verbraucht: das Paket gilt kurz davor noch
        expect(e.oeffnen(p, jetzt: jetzt.add(const Duration(minutes: 9))).seq, 1);
        // Messung deutlich in der Zukunft (Uhr des Absenders geht vor)
        expect(_ablehnung(() => e.oeffnen(paket(messung: jetzt.add(const Duration(hours: 2))), jetzt: jetzt)), PaketAblehnung.zukunft);
        // Ablauf auf Vorrat (Paket "aus der Zukunft")
        expect(_ablehnung(() => e.oeffnen(paket(t: jetzt.add(const Duration(hours: 1))), jetzt: jetzt)), PaketAblehnung.zukunft);
        // eine ältere Messung ist erlaubt (die Anzeige nennt das echte Alter)
        final alt = e.oeffnen(paket(messung: jetzt.subtract(const Duration(minutes: 30))), jetzt: jetzt);
        expect(jetzt.difference(alt.zeit), const Duration(minutes: 30));
      });

      test('Paket: anderer Absender, andere Freigabe oder anderer Schlüssel ergeben nichts (Signatur, AAD)', () {
        final e = annehmen();
        final p = paket();
        // ein Mitglied mit dem Sitzungsschlüssel kann nicht als Anna schreiben: sonst fehlt ihre Signatur
        final bytes = base64urlDekodieren(p);
        final fremdSigniert = Uint8List.fromList(bytes)..setRange(29, 93, crypto.signieren(Uint8List.fromList([1, 2, 3]), cora.signGeheim));
        expect(_art(() => e.oeffnen(base64urlKodieren(fremdSigniert), jetzt: jetzt)), CryptoFehlerArt.signatur);
        // Paket einer anderen Freigabe (eigener Sitzungsschlüssel): Signatur gültig, aber AAD und Schlüssel passen nicht
        final andere = StandortSender.neu(crypto, shareId: 's0000000-0000-4000-8000-000000000009', ichId: _anna, meineKeyVersion: annaV, signGeheim: anna.signGeheim, endsAtMs: jetzt.add(const Duration(hours: 1)).millisecondsSinceEpoch);
        final fremdesPaket = andere.paket(breite: 1, laenge: 2, jetzt: jetzt);
        expect(_art(() => e.oeffnen(fremdesPaket, jetzt: jetzt)), isNotNull);
        // ein anderer Schlüsselversions-Eintrag im Kopf
        final v = Uint8List.fromList(bytes)..[4] ^= 1;
        expect(_art(() => e.oeffnen(base64urlKodieren(v), jetzt: jetzt)), CryptoFehlerArt.signatur);
        // jedes verfälschte Byte wird erkannt
        for (final i in [0, 10, 40, bytes.length - 1]) {
          final k = Uint8List.fromList(bytes)..[i] ^= 1;
          expect(_art(() => e.oeffnen(base64urlKodieren(k), jetzt: jetzt)), isNotNull, reason: 'Byte $i');
        }
        // unverfälscht geht es
        expect(e.oeffnen(p, jetzt: jetzt).seq, 1);
      });

      test('Paket: ein Dritter (Cora) ohne Sitzungsschlüssel kann nichts lesen; ihr Wrap ist nicht für Ben', () {
        final e = annehmen();
        final eCora = StandortSender.neu(crypto, shareId: _share, ichId: _anna, meineKeyVersion: annaV, signGeheim: cora.signGeheim, endsAtMs: jetzt.add(const Duration(hours: 1)).millisecondsSinceEpoch);
        // Cora kennt den Sitzungsschlüssel nicht und baut ein eigenes Paket mit eigener Signatur
        expect(_art(() => e.oeffnen(eCora.paket(breite: 1, laenge: 1, jetzt: jetzt), jetzt: jetzt)), CryptoFehlerArt.signatur);
      });

      test('Paket: Wertebereich und Form werden geprüft', () {
        final e = annehmen();
        expect(_art(() => e.oeffnen(paket(lat: 91), jetzt: jetzt)), CryptoFehlerArt.format);
        expect(_art(() => e.oeffnen(paket(lon: -181), jetzt: jetzt)), CryptoFehlerArt.format);
        expect(_art(() => e.oeffnen(paket(g: -1), jetzt: jetzt)), CryptoFehlerArt.format);
        expect(_art(() => e.oeffnen('', jetzt: jetzt)), CryptoFehlerArt.format);
        expect(_art(() => e.oeffnen('AAAA', jetzt: jetzt)), CryptoFehlerArt.format);
        expect(e.hoechsteSeq, 0, reason: 'abgelehnte Pakete verbrauchen die Sequenznummer nicht');
      });

      test('Paket: das Ende der Freigabe darf der Absender verlängern, aber nie über die Höchstdauer', () {
        final e = annehmen();
        sender.verlaengern(jetzt.add(const Duration(hours: 5)).millisecondsSinceEpoch);
        expect(e.oeffnen(paket(), jetzt: jetzt).freigabeEnde.toUtc(), jetzt.add(const Duration(hours: 5)));
        sender.verlaengern(jetzt.add(const Duration(days: 30)).millisecondsSinceEpoch);
        expect(e.oeffnen(paket(), jetzt: jetzt).freigabeEnde.toUtc(), jetzt.add(kStandortMaxDauer));
      });

      test('Der Klartext der Position steht nicht im Paket; jedes Paket hat eine neue Nonce', () {
        final p1 = paket(lat: 48.1372, lon: 11.5755);
        final p2 = paket(lat: 48.1372, lon: 11.5755);
        expect(p1, isNot(p2));
        final bytes = base64urlDekodieren(p1);
        expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('48.1372')));
        expect(bytes.sublist(5, 29), isNot(base64urlDekodieren(p2).sublist(5, 29)));
      });
    });
  }
}
