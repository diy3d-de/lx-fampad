// Home-Assistant-Anbindung: Päckchen öffnen (docs/HA-FORMAT.md). Sealed Box, strenges JSON, MAC in konstanter Zeit, Kanal/Datum/Stand streng, Stand-Text in Tausendstel (kaufmännisch gerundet,
// nie Gleitkomma). Die Logik läuft mit dem Fake der Kryptobausteine; gegen die echten libsodium-Bausteine und das Testmuster der Home-Assistant-Seite (docs/ingest-vektoren.json, mit Python/PyNaCl
// erzeugt) prüft der letzte Block (nur wo libsodium ladbar ist; in der CI Pflicht).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart' show utf8Bytes;
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/ingest/ingest_paket.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart' show kMaxStandMilli;

import 'support/fake_crypto.dart';

Uint8List _hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

Future<void> main() async {
  final fake = FakeCryptoProvider(seed: 7);
  final paar = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 9)));
  final geheimnis = Uint8List.fromList(List.generate(32, (i) => i * 3));

  /// Baut ein Päckchen wie die Gegenseite: Sealed Box über das JSON, MAC über die Felder.
  String paket({
    String kanal = 'strom_bezug',
    String d = '2026-10-26',
    Object t = 1793059140000,
    String stand = '2951.709566',
    String e = 'kWh',
    Object? v = 1,
    String? mac,
    Map<String, Object?> zusatz = const {},
    Uint8List? fuerSchluessel,
    Uint8List? macGeheimnis,
  }) {
    final m = mac ?? ingestMac(fake, macGeheimnis ?? geheimnis, kanal: kanal, d: d, t: t is int ? t : 0, stand: stand, einheit: e);
    final klar = jsonEncode({'v': v, 'kanal': kanal, 'd': d, 't': t, 'stand': stand, 'e': e, 'mac': m, ...zusatz});
    return base64.encode(fake.versiegeln(utf8Bytes(klar), fuerSchluessel ?? paar.oeffentlich));
  }

  PaketErgebnis oeffne(String box) => paketOeffnen(fake, box, oeffentlich: paar.oeffentlich, geheim: paar.geheim, geheimnis: geheimnis);

  group('Stand-Text in Tausendstel', () {
    test('Beispiele: drei Nachkommastellen bleiben, mehr werden kaufmännisch gerundet', () {
      expect(ingestStandInMilli('2951.709566'), 2951710);
      expect(ingestStandInMilli('2951.709499'), 2951709);
      expect(ingestStandInMilli('2951.7095'), 2951710); // halbe nach oben
      expect(ingestStandInMilli('0.0004'), 0);
      expect(ingestStandInMilli('0.0005'), 1);
      expect(ingestStandInMilli('12'), 12000);
      expect(ingestStandInMilli('12.5'), 12500);
      expect(ingestStandInMilli('0'), 0);
      expect(ingestStandInMilli('0.000000'), 0);
      expect(ingestStandInMilli('007'), 7000);
    });

    test('Übertrag über die Ganzzahl hinaus', () {
      expect(ingestStandInMilli('9.9996'), 10000);
      expect(ingestStandInMilli('999.999500'), 1000000);
    });

    test('nie Gleitkomma-Fehler: große Werte bleiben exakt', () {
      expect(ingestStandInMilli('1234567890.123456'), 1234567890123);
      expect(ingestStandInMilli('9999999999.999'), 9999999999999);
    });

    test('ungültige Formen', () {
      for (final s in ['', '-1', '-0.5', '+1', '1e3', '1E3', '1,5', '.5', '5.', '1.2345678', '1 2', 'abc', 'NaN', 'Infinity', '12345678901', '0x10', ' 1', '1 ', '1.-1']) {
        expect(ingestStandInMilli(s), isNull, reason: '"$s"');
      }
    });

    test('der größte darstellbare Wert ist genau der Höchstwert eines Zählerstands (mehr lässt die Form nicht zu)', () {
      expect(ingestStandInMilli('9999999999.9999'), kMaxStandMilli);
      expect(ingestStandInMilli('9999999999.999999'), kMaxStandMilli);
    });
  });

  group('Datum', () {
    test('nur echte Kalendertage', () {
      expect(ingestTagLesen('2026-10-26'), DateTime.utc(2026, 10, 26));
      expect(ingestTagLesen('2028-02-29'), DateTime.utc(2028, 2, 29));
      for (final s in ['2026-02-30', '2027-02-29', '2026-13-01', '2026-00-10', '2026-10-32', '26-10-26', '2026-1-1', '2026/10/26', '1999-12-31', '3000-01-01', '', '2026-10-26T00:00']) {
        expect(ingestTagLesen(s), isNull, reason: s);
      }
    });
  });

  group('Päckchen öffnen', () {
    test('ein gültiges Päckchen ergibt Kanal, Tag, Tausendstel, Zeit und Einheit', () {
      final r = oeffne(paket());
      expect(r.ok, isTrue);
      final w = r.wert!;
      expect(w.kanal, 'strom_bezug');
      expect(w.tag, DateTime.utc(2026, 10, 26));
      expect(w.milli, 2951710);
      expect(w.zeit, 1793059140000);
      expect(w.einheit, 'kWh');
    });

    test('zusätzliche Felder stören nicht (der MAC deckt nur die bekannten ab)', () {
      expect(oeffne(paket(zusatz: {'extra': 1})).ok, isTrue);
    });

    test('falscher MAC: nie eintragen', () {
      expect(oeffne(paket(mac: 'a' * 64)).fehler, PaketFehler.mac);
      expect(oeffne(paket(macGeheimnis: Uint8List(32))).fehler, PaketFehler.mac); // falsches Geheimnis
    });

    test('jede Änderung eines Feldes bricht den MAC', () {
      // gültiger MAC für andere Werte, ins Päckchen mit geändertem Feld gesetzt
      final macStandard = ingestMac(fake, geheimnis, kanal: 'strom_bezug', d: '2026-10-26', t: 1793059140000, stand: '2951.709566', einheit: 'kWh');
      for (final abw in [
        paket(mac: macStandard, kanal: 'strom_einspeisung'),
        paket(mac: macStandard, d: '2026-10-25'),
        paket(mac: macStandard, t: 1793059140001),
        paket(mac: macStandard, stand: '2951.709567'),
        paket(mac: macStandard, stand: '02951.709566'), // gleicher Wert, anderer Text: der MAC gilt für den Text
        paket(mac: macStandard, e: 'Wh'),
      ]) {
        expect(oeffne(abw).fehler, PaketFehler.mac);
      }
      expect(oeffne(paket(mac: macStandard)).ok, isTrue);
    });

    test('MAC in Großbuchstaben oder mit falscher Länge wird abgelehnt', () {
      final m = ingestMac(fake, geheimnis, kanal: 'strom_bezug', d: '2026-10-26', t: 1793059140000, stand: '2951.709566', einheit: 'kWh');
      expect(oeffne(paket(mac: m.toUpperCase())).fehler, PaketFehler.mac);
      expect(oeffne(paket(mac: m.substring(1))).fehler, PaketFehler.mac);
      expect(oeffne(paket(mac: '')).fehler, PaketFehler.mac);
    });

    test('Päckchen an einen anderen Postfach-Schlüssel oder zerstörte Box', () {
      final fremd = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 1)));
      expect(oeffne(paket(fuerSchluessel: fremd.oeffentlich)).fehler, PaketFehler.entschluesselung);
      final b = base64.decode(paket());
      b[30] ^= 1;
      expect(oeffne(base64.encode(b)).fehler, PaketFehler.entschluesselung);
      expect(oeffne(base64.encode(Uint8List(10))).fehler, PaketFehler.entschluesselung);
    });

    test('Kodierung', () {
      expect(oeffne('%%%').fehler, PaketFehler.kodierung);
      expect(oeffne('a').fehler, PaketFehler.kodierung); // unmögliche Länge
    });

    test('Format: kein JSON, keine Map, fehlende oder falsch typisierte Felder', () {
      String roh(String klar) => base64.encode(fake.versiegeln(utf8Bytes(klar), paar.oeffentlich));
      expect(oeffne(roh('kein json')).fehler, PaketFehler.format);
      expect(oeffne(roh('[1]')).fehler, PaketFehler.format);
      expect(oeffne(roh('{}')).fehler, PaketFehler.format);
      expect(oeffne(roh('{"v":1}')).fehler, PaketFehler.format);
      expect(oeffne(paket(t: 1.5)).fehler, PaketFehler.format);
      expect(oeffne(paket(t: '1793059140000')).fehler, PaketFehler.format);
      expect(oeffne(paket(v: '1')).fehler, PaketFehler.format);
      expect(oeffne(paket(e: '')).fehler, PaketFehler.format);
      expect(oeffne(paket(e: 'x' * 17)).fehler, PaketFehler.format);
      expect(oeffne(roh(String.fromCharCodes([0xff, 0xfe]))).fehler, PaketFehler.format);
    });

    test('Version, Kanal, Datum, Stand', () {
      expect(oeffne(paket(v: 2)).fehler, PaketFehler.version);
      expect(oeffne(paket(v: 0)).fehler, PaketFehler.version);
      for (final k in ['', 'Strom', 'strom-bezug', 'strom bezug', 'x' * 41, 'strom\n']) {
        expect(oeffne(paket(kanal: k)).fehler, PaketFehler.kanal, reason: k);
      }
      expect(oeffne(paket(kanal: 'x' * 40)).ok, isTrue);
      expect(oeffne(paket(d: '2026-02-30')).fehler, PaketFehler.datum);
      expect(oeffne(paket(d: '26.10.2026')).fehler, PaketFehler.datum);
      expect(oeffne(paket(t: -1)).fehler, PaketFehler.datum);
      for (final s in ['-3', '1e3', '1,5', '', 'abc', '1.1234567']) {
        expect(oeffne(paket(stand: s)).fehler, PaketFehler.stand, reason: s);
      }
    });

    test('Ein unlesbarer Stand in einem ECHTEN Päckchen (MAC stimmt) trägt die Angaben zur Anzeige; mit falschem MAC ist es nur ein MAC-Fehler ohne Angaben zum Wert', () {
      final echt = oeffne(paket(stand: '12345678901234'));
      expect(echt.fehler, PaketFehler.stand);
      expect(echt.ungueltigerStand!.kanal, 'strom_bezug');
      expect(echt.ungueltigerStand!.tag, DateTime.utc(2026, 10, 26));
      expect(echt.ungueltigerStand!.text, '12345678901234');
      expect(echt.ungueltigerStand!.einheit, 'kWh');
      final falsch = oeffne(paket(stand: '12345678901234', mac: 'f' * 64));
      expect(falsch.fehler, PaketFehler.mac);
      expect(falsch.ungueltigerStand, isNull);
      final fremd = oeffne(paket(stand: '12345678901234', macGeheimnis: Uint8List(32)));
      expect(fremd.fehler, PaketFehler.mac);
      expect(fremd.ungueltigerStand, isNull);
    });

    test('der Stand wird mit dem Text des Päckchens gerundet (nicht als Gleitkomma gelesen)', () {
      expect(oeffne(paket(stand: '1.0005')).wert!.milli, 1001);
      expect(oeffne(paket(stand: '1.0004')).wert!.milli, 1000);
    });
  });

  test('Prüfung der Texte in konstanter Zeit', () {
    expect(gleicherText('abc', 'abc'), isTrue);
    expect(gleicherText('abc', 'abd'), isFalse);
    expect(gleicherText('abc', 'ab'), isFalse);
  });

  // ------------------------------------------------------------------ echte Bausteine und Testmuster der Gegenseite

  final sodium = await echtesSodium();
  final skip = sodium == null ? 'libsodium ist hier nicht verfügbar (Build-Hook braucht einen C-Compiler)' : null;
  final datei = File('../docs/ingest-vektoren.json');

  group('Testmuster der Home-Assistant-Seite (docs/ingest-vektoren.json, echtes libsodium)', () {
    late CryptoProvider p;
    late Map<String, dynamic> v;
    setUp(() {
      p = sodium!;
      v = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;
    });


    test('das fertige Päckchen lässt sich öffnen: Klartext, MAC und Werte stimmen', () {
      final r = paketOeffnen(p, v['boxBase64'] as String, oeffentlich: _hex(v['oeffentlichHex'] as String), geheim: _hex(v['geheimHex'] as String), geheimnis: _hex(v['sHex'] as String));
      expect(r.fehler, isNull);
      final w = r.wert!;
      final klar = jsonDecode(v['klartext'] as String) as Map<String, dynamic>;
      expect(w.kanal, klar['kanal']);
      expect(w.tag, ingestTagLesen(klar['d'] as String));
      expect(w.zeit, klar['t']);
      expect(w.einheit, klar['e']);
      expect(w.milli, 2951710); // 2951.709566 kaufmännisch auf Tausendstel
    });

    test('der MAC der Gegenseite ist byte-gleich zu unserem (BLAKE2b-256 mit s als Schlüssel)', () {
      final klar = jsonDecode(v['klartext'] as String) as Map<String, dynamic>;
      final m = ingestMac(p, _hex(v['sHex'] as String), kanal: klar['kanal'] as String, d: klar['d'] as String, t: klar['t'] as int, stand: klar['stand'] as String, einheit: klar['e'] as String);
      expect(m, v['mac']);
      expect(m, klar['mac']);
    });

    test('ein verändertes Päckchen oder ein falsches Geheimnis wird abgelehnt', () {
      final geheim = _hex(v['geheimHex'] as String);
      final pub = _hex(v['oeffentlichHex'] as String);
      final b = base64.decode(v['boxBase64'] as String);
      b[40] ^= 1;
      expect(paketOeffnen(p, base64.encode(b), oeffentlich: pub, geheim: geheim, geheimnis: _hex(v['sHex'] as String)).fehler, PaketFehler.entschluesselung);
      expect(paketOeffnen(p, v['boxBase64'] as String, oeffentlich: pub, geheim: geheim, geheimnis: Uint8List(32)).fehler, PaketFehler.mac);
    });
  }, skip: skip ?? (datei.existsSync() ? null : 'docs/ingest-vektoren.json fehlt'));

  test('Eigene Päckchen mit echtem libsodium: bauen, öffnen, Fälschung ablehnen', () {
    final p = sodium!;
    final pa = p.boxPaarAusSeed(p.zufall(32));
    final s = p.zufall(32);
    final mac = ingestMac(p, s, kanal: 'solar_erzeugung', d: '2026-10-26', t: 1793059140000, stand: '12.3456', einheit: 'kWh');
    final box = base64.encode(p.versiegeln(utf8Bytes(jsonEncode({'v': 1, 'kanal': 'solar_erzeugung', 'd': '2026-10-26', 't': 1793059140000, 'stand': '12.3456', 'e': 'kWh', 'mac': mac})), pa.oeffentlich));
    final r = paketOeffnen(p, box, oeffentlich: pa.oeffentlich, geheim: pa.geheim, geheimnis: s);
    expect(r.wert!.milli, 12346);
    expect(paketOeffnen(p, box, oeffentlich: pa.oeffentlich, geheim: pa.geheim, geheimnis: p.zufall(32)).fehler, PaketFehler.mac);
  }, skip: skip);
}
