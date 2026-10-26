// Home-Assistant-Anbindung: Kopplungscode (docs/HA-FORMAT.md) bauen und streng lesen, Postfach-Schlüssel im Schlüsselspeicher.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/ingest/ingest_kopplung.dart';

import 'support/fake_crypto.dart';

const _token = 'fhi_TESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTES';

Uint8List _bytes(int start) => Uint8List.fromList([for (var i = 0; i < 32; i++) (start + i) & 255]);

IngestKopplung _k({String url = 'https://familyhub.lx-labs.dev', String token = _token, String name = 'Haus Keller'}) =>
    IngestKopplung(url: url, token: token, postfach: _bytes(1), geheimnis: _bytes(101), name: name);

String _codeAus(Map<String, Object?> json) => '$kKopplungPraefix${base64urlKodieren(utf8.encode(jsonEncode(json)))}';

Map<String, Object?> _gut() => {'v': 1, 'u': 'https://familyhub.lx-labs.dev', 't': _token, 'p': base64.encode(_bytes(1)), 's': base64.encode(_bytes(101)), 'n': 'Haus Keller'};

void main() {
  test('Hin und zurück: alle Felder kommen unverändert an, Umlaute im Namen bleiben', () {
    final k = _k(name: 'Haus Müller – Keller');
    final code = kopplungscodeBauen(k);
    expect(code, startsWith('FH1-'));
    expect(code.contains('='), isFalse); // base64url ohne Auffüllung
    final r = kopplungscodeLesen(code)!;
    expect(r.url, k.url);
    expect(r.token, k.token);
    expect(r.postfach, k.postfach);
    expect(r.geheimnis, k.geheimnis);
    expect(r.name, 'Haus Müller – Keller');
  });

  test('Der Inhalt des Codes ist genau das Format aus docs/HA-FORMAT.md', () {
    final json = jsonDecode(utf8.decode(base64urlDekodieren(kopplungscodeBauen(_k()).substring(4))));
    expect(json, {'v': 1, 'u': 'https://familyhub.lx-labs.dev', 't': _token, 'p': base64.encode(_bytes(1)), 's': base64.encode(_bytes(101)), 'n': 'Haus Keller'});
  });

  test('Leerzeichen am Rand werden toleriert, der Rest ist streng', () {
    expect(kopplungscodeLesen('  ${kopplungscodeBauen(_k())}\n'), isNotNull);
  });

  test('Kaputte Codes ergeben nie ein Ergebnis', () {
    final gut = kopplungscodeBauen(_k());
    final faelle = <String, String>{
      'leer': '',
      'ohne Präfix': gut.substring(4),
      'falsches Präfix': 'FH2-${gut.substring(4)}',
      'Kleinbuchstaben-Präfix': gut.replaceFirst('FH1-', 'fh1-'),
      'kein Base64': 'FH1-@@@@',
      'mit Auffüllung': '$gut=',
      'kein JSON': 'FH1-${base64urlKodieren(utf8.encode('kein json'))}',
      'JSON-Liste': 'FH1-${base64urlKodieren(utf8.encode('[1,2]'))}',
      'unbekannte Version': _codeAus({..._gut(), 'v': 2}),
      'Version als Text': _codeAus({..._gut(), 'v': '1'}),
      'http statt https': _codeAus({..._gut(), 'u': 'http://familyhub.lx-labs.dev'}),
      'mit Pfad': _codeAus({..._gut(), 'u': 'https://familyhub.lx-labs.dev/api/v1'}),
      'mit Zugangsdaten': _codeAus({..._gut(), 'u': 'https://a:b@familyhub.lx-labs.dev'}),
      'kein Token': _codeAus({..._gut(), 't': 'abc'}),
      'Token zu kurz': _codeAus({..._gut(), 't': 'fhi_kurz'}),
      'Schlüssel zu kurz': _codeAus({..._gut(), 'p': base64.encode(_bytes(1).sublist(0, 31))}),
      'Geheimnis kein Base64': _codeAus({..._gut(), 's': '%%%'}),
      'Schlüssel base64url statt Standard': _codeAus({..._gut(), 'p': base64Url.encode(Uint8List.fromList(List.filled(32, 251)))}),
      'Name leer': _codeAus({..._gut(), 'n': '  '}),
      'Name zu lang': _codeAus({..._gut(), 'n': 'x' * 41}),
      'Feld fehlt': _codeAus({..._gut()..remove('s')}),
      'zu lang': 'FH1-${'A' * 2100}',
    };
    for (final e in faelle.entries) {
      expect(kopplungscodeLesen(e.value), isNull, reason: e.key);
    }
  });

  test('Bauen weigert sich bei ungültigen Eingaben (es entsteht nie ein Code, den die Gegenseite ablehnen müsste)', () {
    expect(() => kopplungscodeBauen(_k(url: 'http://x.de')), throwsArgumentError);
    expect(() => kopplungscodeBauen(_k(url: 'https://x.de/')), throwsArgumentError); // Pfad: vorher mit kopplungsAdresse normalisieren
    expect(() => kopplungscodeBauen(_k(token: 'nope')), throwsArgumentError);
    expect(() => kopplungscodeBauen(_k(name: '')), throwsArgumentError);
    expect(() => kopplungscodeBauen(_k(name: 'x' * 41)), throwsArgumentError);
    expect(() => kopplungscodeBauen(IngestKopplung(url: 'https://x.de', token: _token, postfach: Uint8List(31), geheimnis: _bytes(1), name: 'a')), throwsArgumentError);
  });

  test('kopplungsAdresse: nur https, nur Rechner und Port', () {
    expect(kopplungsAdresse('https://familyhub.lx-labs.dev'), 'https://familyhub.lx-labs.dev');
    expect(kopplungsAdresse('https://familyhub.lx-labs.dev/'), 'https://familyhub.lx-labs.dev');
    expect(kopplungsAdresse('https://familyhub.lx-labs.dev/api/v1?x=1'), 'https://familyhub.lx-labs.dev');
    expect(kopplungsAdresse('https://familyhub.lx-labs.dev:8443/a'), 'https://familyhub.lx-labs.dev:8443');
    expect(kopplungsAdresse('https://familyhub.lx-labs.dev:443'), 'https://familyhub.lx-labs.dev');
    expect(kopplungsAdresse('http://localhost:8080'), isNull);
    expect(kopplungsAdresse('https://u:p@x.de'), isNull);
    expect(kopplungsAdresse(''), isNull);
    expect(kopplungsAdresse('kein url'), isNull);
  });

  test('Das Testmuster der Home-Assistant-Seite (docs/ingest-vektoren.json) wird gelesen und byte-gleich wieder gebaut', () {
    final f = File('../docs/ingest-vektoren.json');
    if (!f.existsSync()) {
      markTestSkipped('docs/ingest-vektoren.json fehlt');
      return;
    }
    final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final k = kopplungscodeLesen(v['kopplungscode'] as String)!;
    expect(k.postfach, base64.decode(v['oeffentlichBase64'] as String));
    expect(k.geheimnis, base64.decode(v['sBase64'] as String));
    expect(k.token, startsWith('fhi_'));
    expect(k.url, startsWith('https://'));
    expect(kopplungscodeBauen(k), v['kopplungscode']);
  });

  group('Postfach-Schlüssel im Schlüsselspeicher', () {
    test('erzeugen, ablegen, lesen; null nur, wenn es ihn nicht gibt', () async {
      final speicher = PostfachSpeicher(MemorySchluesselSpeicher());
      expect(await speicher.lesen('u1'), isNull);
      expect(await speicher.vorhanden('u1'), isFalse);
      final s = PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 1));
      await speicher.schreiben('u1', s);
      final r = (await speicher.lesen('u1'))!;
      expect(r.oeffentlich, s.oeffentlich);
      expect(r.geheim, s.geheim);
      expect(r.geheimnis, s.geheimnis);
      expect(await speicher.vorhanden('u1'), isTrue);
      expect(await speicher.lesen('u2'), isNull); // je Person getrennt
      await speicher.entfernen('u1');
      expect(await speicher.lesen('u1'), isNull);
    });

    test('ein beschädigter Eintrag ist ein Fehler, nie "kein Schlüssel"', () async {
      final sp = MemorySchluesselSpeicher();
      await sp.schreiben(postfachName('u1'), Uint8List(5));
      await expectLater(PostfachSpeicher(sp).lesen('u1'), throwsA(isA<SchluesselSpeicherFehler>()));
    });

    test('Name und Länge', () {
      expect(postfachName('abc'), 'ingest.postfach.abc');
      final s = PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 2));
      expect(s.toBytes().length, 96);
      expect(PostfachSchluessel.fromBytes(Uint8List(95)), isNull);
    });
  });
}
