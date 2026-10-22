// Beitritts-Bausteine (PR 6, noch nicht verdrahtet): Geheimnis im Link-Fragment, MAC über den Schlüssel einer neuen Person, signierte Bestätigung mit Grund `join`.
// Der Server als Angreifer: anderer Schlüssel, andere Person, andere Familie, Bestätigung nach einem Reset, Bestätiger ohne gemerkten Schlüssel, Grund `reset`, Selbstbestätigung.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/beitritt.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';

import '../support/fake_crypto.dart';

const _familie = 'f0000000-0000-4000-8000-00000000000f';
const _admin = 'a0000000-0000-4000-8000-00000000000a';
const _neu = 'e0000000-0000-4000-8000-00000000000e';

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
    group('Beitritt ($name)', () {
      late Personenschluessel adminPk; // einladende Person, Version 4
      late Personenschluessel neuPk; // eingeladene Person, Version 1
      late BeitrittsGeheimnis geheimnis;
      const adminV = 4;

      OeffentlicheSchluessel neuOeff({int v = 1}) => neuPk.oeffentlich(v);

      setUp(() {
        adminPk = Personenschluessel.erzeugen(crypto);
        neuPk = Personenschluessel.erzeugen(crypto);
        geheimnis = BeitrittsGeheimnis.erzeugen(crypto);
      });

      BeitrittsBestaetigung bestaetigung({String familie = _familie, String mitglied = _neu, OeffentlicheSchluessel? schluessel, String von = _admin, int vonV = adminV, Personenschluessel? signiert}) =>
          BeitrittsBestaetigung.erstellen(
            crypto,
            familienId: familie,
            mitgliedId: mitglied,
            mitgliedSchluessel: schluessel ?? neuOeff(),
            bestaetigerId: von,
            bestaetigerKeyVersion: vonV,
            bestaetigerSignGeheim: (signiert ?? adminPk).signGeheim,
          );

      void pruefen(BeitrittsBestaetigung b, {String familie = _familie, String mitglied = _neu, OeffentlicheSchluessel? aktuell, OeffentlicheSchluessel? gemerkt}) =>
          BeitrittsPruefung.pruefen(
            crypto,
            bestaetigung: b,
            erwarteteFamilienId: familie,
            erwarteteMitgliedId: mitglied,
            aktuellerSchluessel: aktuell ?? neuOeff(),
            bestaetigerGemerkt: gemerkt ?? adminPk.oeffentlich(adminV),
          );

      test('Geheimnis: 32 Byte, Base64url ohne Auffüllzeichen, Hin- und Rückweg, streng, zwei Geheimnisse unterscheiden sich', () {
        final text = geheimnis.kodieren();
        expect(text, hasLength(43));
        expect(text, isNot(contains('=')));
        expect(BeitrittsGeheimnis.dekodieren(text).kodieren(), text);
        expect(BeitrittsGeheimnis.erzeugen(crypto).kodieren(), isNot(text));
        for (final schlecht in ['', 'kurz', '$text=', '${text}A', text.substring(1), '$text!', ' $text']) {
          expect(_art(() => BeitrittsGeheimnis.dekodieren(schlecht)), CryptoFehlerArt.format, reason: '"$schlecht"');
        }
      });

      test('MAC: nur mit dem Geheimnis zu bilden, bindet Person, Schlüssel und Version; ein anderes Geheimnis oder eine andere Eingabe passt nie', () {
        final mac = beitrittsMacBilden(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff());
        expect(base64urlDekodieren(mac), hasLength(32));
        expect(beitrittsMacBilden(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff()), mac, reason: 'deterministisch');
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff(), mac: mac), isTrue);
        // anderes Geheimnis (wer den Link nicht kennt), andere Person, anderer Schlüssel, andere Version
        expect(beitrittsMacPasst(crypto, geheimnis: BeitrittsGeheimnis.erzeugen(crypto), userId: _neu, schluessel: neuOeff(), mac: mac), isFalse);
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _admin, schluessel: neuOeff(), mac: mac), isFalse);
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: Personenschluessel.erzeugen(crypto).oeffentlich(1), mac: mac), isFalse);
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff(v: 2), mac: mac), isFalse);
        // nur ein Teil des Schlüssels getauscht (Verschlüsselungs- oder Signaturschlüssel)
        final fremd = Personenschluessel.erzeugen(crypto);
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: OeffentlicheSchluessel(enc: fremd.encOeffentlich, sign: neuPk.signOeffentlich, version: 1), mac: mac), isFalse);
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: OeffentlicheSchluessel(enc: neuPk.encOeffentlich, sign: fremd.signOeffentlich, version: 1), mac: mac), isFalse);
        // unlesbare MACs sind einfach "nein" (kein Fehler, kein Orakel)
        for (final schlecht in ['', 'x', '!!', '$mac=', '${mac}A', mac.substring(1)]) {
          expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff(), mac: schlecht), isFalse, reason: '"$schlecht"');
        }
        // jedes Zeichen des MAC zählt
        for (var i = 0; i < mac.length; i++) {
          final c = mac[i] == 'A' ? 'B' : 'A';
          expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff(), mac: mac.replaceRange(i, i + 1, c)), isFalse, reason: 'Zeichen $i');
        }
        expect(_art(() => beitrittsMacBilden(crypto, geheimnis: geheimnis, userId: '', schluessel: neuOeff())), CryptoFehlerArt.format);
      });

      test('Bestätigung: Hin- und Rückweg, Grund ist immer join, die Prüfung gelingt mit dem gemerkten Schlüssel des Bestätigers', () {
        final b = bestaetigung();
        expect(b.grund, 'join');
        final text = b.kodieren();
        expect(text, isNot(contains('=')));
        final b2 = BeitrittsBestaetigung.dekodieren(text);
        expect(b2.kodieren(), text);
        expect(b2.familienId, _familie);
        expect(b2.mitgliedId, _neu);
        expect(b2.mitgliedSchluessel.version, 1);
        expect(b2.bestaetigerId, _admin);
        expect(b2.bestaetigerKeyVersion, adminV);
        pruefen(b2);
      });

      test('Bestätigung: Familie, Person, Schlüssel, Version und Bestätiger sind in der Signatur; nichts davon lässt sich austauschen', () {
        final b = bestaetigung();
        expect(_art(() => pruefen(b, familie: 'f1111111-0000-4000-8000-00000000000f')), CryptoFehlerArt.format, reason: 'andere Familie');
        expect(_art(() => pruefen(b, mitglied: _admin)), CryptoFehlerArt.format, reason: 'andere Person');
        // der Server liefert inzwischen einen anderen Schlüssel (Reset, Schlüsselwechsel): die alte Bestätigung gilt nie für den neuen
        final reset = Personenschluessel.erzeugen(crypto);
        expect(_art(() => pruefen(b, aktuell: reset.oeffentlich(2))), CryptoFehlerArt.format, reason: 'neuer Schlüssel nach einem Reset');
        expect(_art(() => pruefen(b, aktuell: neuOeff(v: 2))), CryptoFehlerArt.format, reason: 'dieselben Schlüssel, aber andere Version');
        expect(_art(() => pruefen(b, aktuell: OeffentlicheSchluessel(enc: reset.encOeffentlich, sign: neuPk.signOeffentlich, version: 1))), CryptoFehlerArt.format);
        // ein anderer signiert (Angreifer ohne den Schlüssel des Bestätigers) oder der gemerkte Schlüssel gehört nicht zum Bestätiger
        final angreifer = Personenschluessel.erzeugen(crypto);
        expect(_art(() => pruefen(bestaetigung(signiert: angreifer))), CryptoFehlerArt.signatur, reason: 'falscher Signierer');
        expect(_art(() => pruefen(b, gemerkt: angreifer.oeffentlich(adminV))), CryptoFehlerArt.signatur, reason: 'gemerkter Schlüssel ist ein anderer');
        // der gemerkte Schlüssel trägt eine andere Version als die Bestätigung nennt
        expect(_art(() => pruefen(b, gemerkt: adminPk.oeffentlich(adminV + 1))), CryptoFehlerArt.signatur, reason: 'andere Version des Bestätigers');
        // Bytes verändert: jede Stelle der Transportform wirkt (Zeichen vertauschen bricht Form oder Signatur)
        final text = b.kodieren();
        for (var i = 0; i < text.length; i += 7) {
          final c = text[i] == 'A' ? 'B' : 'A';
          final kaputt = text.replaceRange(i, i + 1, c);
          final art = _art(() => pruefen(BeitrittsBestaetigung.dekodieren(kaputt)));
          expect(art, isNotNull, reason: 'Zeichen $i');
        }
      });

      test('Selbstbestätigung gibt es nicht: niemand bestätigt sich selbst', () {
        expect(_art(() => bestaetigung(von: _neu)), CryptoFehlerArt.format);
        // gleiche Person als Bestätiger in einer von Hand gebauten Transportform wird beim Einlesen abgelehnt
        final raw = base64urlDekodieren(bestaetigung().kodieren());
        final i = _suche(raw, _neu.codeUnits);
        final j = _suche(raw, _admin.codeUnits);
        expect(i, greaterThan(0));
        expect(j, greaterThan(i));
        final selbst = Uint8List.fromList(raw)..setRange(j, j + _admin.length, _neu.codeUnits);
        expect(_art(() => BeitrittsBestaetigung.dekodieren(base64urlKodieren(selbst))), CryptoFehlerArt.format);
      });

      test('Grund: nur join; ein anderer Grund (reset) oder eine andere Version wird nie angenommen', () {
        final raw = base64urlDekodieren(bestaetigung().kodieren());
        // "join" im Rahmen durch "rst!" gleicher Länge ersetzen (Grund reset kennt dieses Format nicht)
        final i = _suche(raw, [0x6a, 0x6f, 0x69, 0x6e]);
        expect(i, greaterThan(0));
        final reset = Uint8List.fromList(raw)..setRange(i, i + 4, [0x72, 0x73, 0x74, 0x21]);
        expect(_art(() => BeitrittsBestaetigung.dekodieren(base64urlKodieren(reset))), CryptoFehlerArt.format);
        final neuere = Uint8List.fromList(raw)..[0] = 2;
        expect(_art(() => BeitrittsBestaetigung.dekodieren(base64urlKodieren(neuere))), CryptoFehlerArt.version);
        expect(_art(() => BeitrittsBestaetigung.dekodieren('kaputt!')), CryptoFehlerArt.format);
        expect(_art(() => BeitrittsBestaetigung.dekodieren(base64urlKodieren(Uint8List(0)))), anyOf(CryptoFehlerArt.format, CryptoFehlerArt.version));
        // Reste hinter der Signatur sind ein Formatfehler
        expect(_art(() => BeitrittsBestaetigung.dekodieren(base64urlKodieren([...raw, 0]))), CryptoFehlerArt.format);
        // abgeschnitten
        expect(_art(() => BeitrittsBestaetigung.dekodieren(base64urlKodieren(raw.sublist(0, raw.length - 3)))), CryptoFehlerArt.format);
      });

      test('Domänen sind getrennt: eine Signatur der Bestätigung ist kein Wrap, keine Liste, keine Nachricht und der MAC keine Signatur', () {
        final b = bestaetigung();
        // dieselben Bytes unter einem anderen Domänenpräfix signiert/geprüft ergeben nie ein gültiges Paar
        expect(b.signatur, hasLength(64));
        final mac = beitrittsMacBilden(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff());
        expect(base64urlDekodieren(mac).length, isNot(64), reason: 'ein MAC (32 Byte) ist keine Signatur (64 Byte)');
        // die Signatur lässt sich nicht als MAC ausgeben und umgekehrt
        expect(beitrittsMacPasst(crypto, geheimnis: geheimnis, userId: _neu, schluessel: neuOeff(), mac: base64urlKodieren(b.signatur)), isFalse);
      });
    });
  }

  group('Known-Answer (libsodium)', () {
    test('Beitritts-MAC mit festem Geheimnis und festen Schlüsseln (BLAKE2b mit Schlüssel, Domäne lx-familyhub|join-mac|v1)', () async {
      final crypto = await echtesSodium();
      if (crypto == null) return; // ohne native Bibliothek (lokal unter Windows) übersprungen; in der CI Pflicht (SODIUM_ERFORDERLICH=1)
      final geheimnis = BeitrittsGeheimnis.dekodieren(base64urlKodieren(List.generate(32, (i) => i)));
      final schluessel = OeffentlicheSchluessel(enc: Uint8List.fromList(List.generate(32, (i) => 100 + i)), sign: Uint8List.fromList(List.generate(32, (i) => 200 - i)), version: 3);
      expect(beitrittsMacBilden(crypto, geheimnis: geheimnis, userId: _neu, schluessel: schluessel), 'qmQjt8bRQD82OIk5yH7tN6O0Vw3eeTKCOgJDsExoY5c');
    });
  });
}

int _suche(Uint8List heuhaufen, List<int> nadel) {
  for (var i = 0; i + nadel.length <= heuhaufen.length; i++) {
    var gleich = true;
    for (var j = 0; j < nadel.length; j++) {
      if (heuhaufen[i + j] != nadel[j]) {
        gleich = false;
        break;
      }
    }
    if (gleich) return i;
  }
  return -1;
}
