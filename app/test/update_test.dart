import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/features/update/update_service.dart';
import 'package:lx_fampad/features/update/versions.dart';

// Testschlüssel nur für diese Datei (feste Saat, damit der Test reproduzierbar ist). Er signiert nur Testmanifeste.
final _seed = List<int>.generate(32, (i) => i + 1);
final _otherSeed = List<int>.generate(32, (i) => 100 + i);
final _jetzt = DateTime.utc(2026, 10, 18, 12);
// Schlüssel-ID der Testmanifeste (die eingebaute ID ist solange "platzhalter", und dann wird nichts akzeptiert)
const _testKeyId = 'testschluessel';

Future<(Ed25519ManifestVerifier, SimpleKeyPair)> _schluessel(List<int> seed) async {
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await pair.extractPublicKey();
  return (Ed25519ManifestVerifier(pub.bytes), pair);
}

Future<String> _manifest(Map<String, Object?> payload, SimpleKeyPair key, {String? payloadText}) async {
  final text = payloadText ?? jsonEncode(payload);
  final sig = await Ed25519().sign(utf8.encode(text), keyPair: key);
  return jsonEncode({'payload': text, 'signature': base64Encode(sig.bytes)});
}

final gueltig = <String, Object?>{
  'packageName': kPackageName,
  'version': '0.2.0',
  'versionCode': 2,
  'minVersion': '0.1.0',
  'apk': 'dev-lx_labs-fampad-0.2.0.apk',
  'sha256': 'a' * 64,
  'size': 1234,
  'notes': 'Neu',
  'issuedAt': '2026-10-17T12:00:00Z',
  'keyId': _testKeyId,
};

Future<UpdateInfo> _parse(String json, ManifestVerifier v, {int code = 1, DateTime? jetzt}) =>
    parseManifest(json, verifier: v, installierteVersionCode: code, jetzt: jetzt ?? _jetzt, keyId: _testKeyId);

void main() {
  group('compareVersions', () {
    test('vergleicht numerisch statt als Text', () {
      expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('0.1.9', '0.2.0'), lessThan(0));
    });

    test('isVersion erkennt nur x.y.z', () {
      expect(isVersion('1.2.3'), isTrue);
      expect(isVersion('1.2'), isFalse);
      expect(isVersion('v1.2.3'), isFalse);
    });
  });

  group('Ed25519ManifestVerifier (echte Signaturen)', () {
    test('akzeptiert eine gültige Signatur', () async {
      final (v, key) = await _schluessel(_seed);
      final json = jsonDecode(await _manifest(gueltig, key)) as Map<String, dynamic>;
      expect(await v.verify(payload: json['payload'] as String, signature: json['signature'] as String), isTrue);
    });

    test('lehnt einen um ein Zeichen veränderten Payload ab', () async {
      final (v, key) = await _schluessel(_seed);
      final json = jsonDecode(await _manifest(gueltig, key)) as Map<String, dynamic>;
      final payload = (json['payload'] as String).replaceFirst('"versionCode":2', '"versionCode":3');
      expect(await v.verify(payload: payload, signature: json['signature'] as String), isFalse);
      // auch ein zusätzliches Leerzeichen zählt: geprüft wird genau der Text
      expect(await v.verify(payload: '${json['payload']} ', signature: json['signature'] as String), isFalse);
    });

    test('lehnt die Signatur eines anderen Schlüssels ab', () async {
      final (v, _) = await _schluessel(_seed);
      final (_, fremd) = await _schluessel(_otherSeed);
      final json = jsonDecode(await _manifest(gueltig, fremd)) as Map<String, dynamic>;
      expect(await v.verify(payload: json['payload'] as String, signature: json['signature'] as String), isFalse);
    });

    test('lehnt kaputte Signaturen ab (Länge, Base64, leer)', () async {
      final (v, key) = await _schluessel(_seed);
      final json = jsonDecode(await _manifest(gueltig, key)) as Map<String, dynamic>;
      final payload = json['payload'] as String;
      final sig = base64Decode(json['signature'] as String);
      expect(await v.verify(payload: payload, signature: base64Encode(sig.sublist(0, 63))), isFalse);
      expect(await v.verify(payload: payload, signature: base64Encode([...sig, 0])), isFalse);
      expect(await v.verify(payload: payload, signature: '%%%kein-base64'), isFalse);
      expect(await v.verify(payload: payload, signature: ''), isFalse);
    });

    test('lehnt einen Schlüssel falscher Länge ab', () async {
      final (_, key) = await _schluessel(_seed);
      final json = jsonDecode(await _manifest(gueltig, key)) as Map<String, dynamic>;
      expect(await Ed25519ManifestVerifier([1, 2, 3]).verify(payload: json['payload'] as String, signature: json['signature'] as String), isFalse);
    });

    test('prüft ein mit Node (tools/update-manifest.mjs) signiertes Manifest', () async {
      final fixture = jsonDecode(File('test/fixtures/node_manifest.json').readAsStringSync()) as Map<String, dynamic>;
      final v = Ed25519ManifestVerifier.base64(fixture['publicKey'] as String);
      final info = await parseManifest(
        jsonEncode(fixture['manifest']),
        verifier: v,
        installierteVersionCode: 1,
        jetzt: _jetzt,
        keyId: 'testschluessel',
      );
      expect(info.version, '0.2.0');
      expect(info.versionCode, 2);
      expect(info.size, 21);
      expect(info.notes, contains('ä ö ü'));
    });

    test('der eingebaute Platzhalter-Schlüssel ist kein Testschlüssel und akzeptiert nichts Fremdes', () async {
      final (_, key) = await _schluessel(_seed);
      final v = Ed25519ManifestVerifier.base64(kUpdatePublicKey);
      expect(v.publicKey.length, 32);
      await expectLater(_parse(await _manifest(gueltig, key), v), throwsException);
    });
  });

  group('parseManifest', () {
    late Ed25519ManifestVerifier verifier;
    late SimpleKeyPair key;
    setUp(() async => (verifier, key) = await _schluessel(_seed));

    test('liest ein gültiges, signiertes Manifest', () async {
      final info = await _parse(await _manifest(gueltig, key), verifier);
      expect(info.version, '0.2.0');
      expect(info.versionCode, 2);
      expect(info.apkUrl.path, endsWith('/android/dev-lx_labs-fampad-0.2.0.apk'));
      expect(info.pflichtFuer('0.0.9'), isTrue);
      expect(info.pflichtFuer('0.1.0'), isFalse);
    });

    test('lehnt ungültige Signatur ab', () async {
      final json = jsonDecode(await _manifest(gueltig, key)) as Map<String, dynamic>;
      json['signature'] = base64Encode(List.filled(64, 1));
      await expectLater(_parse(jsonEncode(json), verifier), throwsException);
    });

    test('Phase-0-Prüfer lehnt immer ab', () async {
      await expectLater(_parse(await _manifest(gueltig, key), const RejectingManifestVerifier()), throwsException);
    });

    test('liest den Payload erst nach der Signaturprüfung', () async {
      // kein JSON im Payload, aber falsche Signatur: es muss an der Signatur scheitern, nicht am Parsen
      final json = jsonEncode({'payload': 'kein json', 'signature': base64Encode(List.filled(64, 0))});
      await expectLater(_parse(json, verifier), throwsA(predicate((e) => '$e'.contains('Signatur'))));
    });

    test('lehnt fremden Paketnamen ab', () async {
      await expectLater(
        _parse(await _manifest({...gueltig, 'packageName': 'com.example.fremd'}, key), verifier),
        throwsA(predicate((e) => '$e'.contains('anderen App'))),
      );
    });

    test('lehnt fremde Schlüssel-ID ab', () async {
      await expectLater(_parse(await _manifest({...gueltig, 'keyId': 'alt'}, key), verifier), throwsException);
    });

    test('lehnt Manifest mit kleinerem versionCode als installiert ab (altes Manifest)', () async {
      await expectLater(
        _parse(await _manifest(gueltig, key), verifier, code: 3),
        throwsA(predicate((e) => '$e'.contains('älter'))),
      );
    });

    test('akzeptiert gleichen versionCode auch bei sehr altem Ausstellungsdatum (App ist aktuell)', () async {
      final alt = {...gueltig, 'issuedAt': '2024-01-01T00:00:00Z'};
      final info = await _parse(await _manifest(alt, key), verifier, code: 2);
      expect(info.versionCode, 2);
    });

    test('lehnt zu altes Manifest ab, wenn es ein Update anbietet', () async {
      final alt = {...gueltig, 'issuedAt': '2025-01-01T00:00:00Z'};
      await expectLater(_parse(await _manifest(alt, key), verifier), throwsA(predicate((e) => '$e'.contains('zu alt'))));
    });

    test('lehnt Ausstellungsdatum in der Zukunft ab, toleriert aber kleine Uhrabweichung', () async {
      final zukunft = {...gueltig, 'issuedAt': '2026-10-25T00:00:00Z'};
      await expectLater(_parse(await _manifest(zukunft, key), verifier), throwsException);
      final knapp = {...gueltig, 'issuedAt': '2026-10-18T18:00:00Z'};
      expect((await _parse(await _manifest(knapp, key), verifier)).versionCode, 2);
    });

    test('lehnt fremde APK-Adressen und Pfade ab', () async {
      for (final apk in ['https://evil.example/x.apk', '../x.apk', 'a/b.apk', 'x.exe']) {
        await expectLater(_parse(await _manifest({...gueltig, 'apk': apk}, key), verifier), throwsException, reason: apk);
      }
    });

    test('lehnt ungültige Prüfsumme, Version und versionCode ab', () async {
      for (final kaputt in [
        {'sha256': 'xyz'},
        {'version': 'neu'},
        {'versionCode': '2'},
        {'versionCode': 0},
        {'minVersion': 'alt'},
        {'issuedAt': 'gestern'},
        {'issuedAt': null},
      ]) {
        await expectLater(_parse(await _manifest({...gueltig, ...kaputt}, key), verifier), throwsException, reason: '$kaputt');
      }
    });

    test('begrenzt die Größe auf 1 Byte bis 200 MB', () async {
      for (final size in [0, -5, kMaxApkBytes + 1, '100', 1.5]) {
        await expectLater(_parse(await _manifest({...gueltig, 'size': size}, key), verifier), throwsException, reason: '$size');
      }
      expect((await _parse(await _manifest({...gueltig, 'size': kMaxApkBytes}, key), verifier)).size, kMaxApkBytes);
      expect((await _parse(await _manifest({...gueltig, 'size': 1}, key), verifier)).size, 1);
    });

    test('lehnt jedes Manifest hart ab, solange die Schlüssel-ID "platzhalter" ist', () async {
      final manifest = await _manifest({...gueltig, 'keyId': kPlatzhalterKeyId}, key);
      await expectLater(
        parseManifest(manifest, verifier: verifier, installierteVersionCode: 1, jetzt: _jetzt, keyId: kPlatzhalterKeyId),
        throwsA(predicate((e) => '$e'.contains('Platzhalter'))),
      );
    });

    test('mit eingebauter Platzhalter-ID (Stand vor dem ersten Release) wird nichts akzeptiert', () async {
      final manifest = await _manifest({...gueltig, 'keyId': kUpdateKeyId}, key);
      await expectLater(
        parseManifest(manifest, verifier: verifier, installierteVersionCode: 1, jetzt: _jetzt),
        throwsException,
      );
    }, skip: kUpdateKeyId != kPlatzhalterKeyId ? 'echter Schlüssel eingetragen' : false);

    test('lehnt unsigniertes Manifest ab', () async {
      await expectLater(_parse(jsonEncode(gueltig), verifier), throwsException);
    });
  });

  group('ServerVersion', () {
    test('liest /api/v1/version und erkennt Pflicht-Updates', () {
      final v = ServerVersion.fromJson({
        'service': 'lx-fampad',
        'protocolVersion': 1,
        'minProtocolVersion': 1,
        'minAppVersion': '0.3.0',
        'webVersion': 'abc',
      })!;
      expect(v.appZuAlt('0.2.9'), isTrue);
      expect(v.appZuAlt('0.3.0'), isFalse);
      expect(v.protokollZuAlt, isFalse);
      expect(v.webVersion, 'abc');
    });

    test('Protokoll zu alt, wenn der Server ein höheres Mindestprotokoll verlangt', () {
      final v = ServerVersion.fromJson({
        'protocolVersion': kProtocolVersion + 1,
        'minProtocolVersion': kProtocolVersion + 1,
        'minAppVersion': '0.1.0',
        'webVersion': null,
      })!;
      expect(v.protokollZuAlt, isTrue);
      expect(v.webVersion, isNull);
    });

    test('ignoriert unbrauchbare Antworten', () {
      expect(ServerVersion.fromJson(null), isNull);
      expect(ServerVersion.fromJson({'protocolVersion': 1}), isNull);
      expect(ServerVersion.fromJson({'protocolVersion': 1, 'minProtocolVersion': 1, 'minAppVersion': 'x'}), isNull);
    });
  });

  group('pruefeBasisAdressen', () {
    test('erlaubt Klartext nur im Debug-Modus', () {
      expect(() => pruefeBasisAdressen(debug: true, api: 'http://localhost:4400', releases: 'http://localhost/r'), returnsNormally);
      expect(() => pruefeBasisAdressen(debug: false, api: 'http://x', releases: 'https://x/r'), throwsStateError);
      expect(() => pruefeBasisAdressen(debug: false, api: 'https://x', releases: 'http://x/r'), throwsStateError);
      expect(() => pruefeBasisAdressen(debug: false, android: false, api: '', releases: 'https://x/r'), returnsNormally);
    });

    test('Android-Release ohne API_BASE wird abgelehnt (Web darf leer sein)', () {
      expect(() => pruefeBasisAdressen(debug: false, android: true, api: '', releases: 'https://x/r'), throwsStateError);
      expect(() => pruefeBasisAdressen(debug: false, android: true, api: 'https://x', releases: 'https://x/r'), returnsNormally);
      expect(() => pruefeBasisAdressen(debug: true, android: true, api: '', releases: 'http://x/r'), returnsNormally);
    });

    test('die eingebauten Standardwerte sind HTTPS', () {
      expect(() => pruefeBasisAdressen(debug: false, android: false), returnsNormally);
      expect(kDebugMode, isTrue); // Tests laufen im Debug-Modus
    });
  });
}
