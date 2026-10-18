import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_familienzentrale/features/update/update_service.dart';
import 'package:lx_familienzentrale/features/update/versions.dart';

class _Accepting implements ManifestVerifier {
  @override
  bool verify({required String payload, required String signature}) => signature == 'ok';
}

String manifest(Map<String, Object?> payload, {String signature = 'ok'}) =>
    jsonEncode({'payload': jsonEncode(payload), 'signature': signature});

final gueltig = {
  'version': '0.2.0',
  'minVersion': '0.1.0',
  'apk': 'lx-familienzentrale-0.2.0.apk',
  'sha256': 'a' * 64,
  'size': 1234,
  'notes': 'Neu',
};

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

  group('parseManifest', () {
    test('liest ein gültiges, signiertes Manifest', () {
      final info = parseManifest(manifest(gueltig), verifier: _Accepting());
      expect(info.version, '0.2.0');
      expect(info.apkUrl.path, endsWith('/android/lx-familienzentrale-0.2.0.apk'));
      expect(info.pflichtFuer('0.0.9'), isTrue);
      expect(info.pflichtFuer('0.1.0'), isFalse);
    });

    test('lehnt ungültige Signatur ab', () {
      expect(() => parseManifest(manifest(gueltig, signature: 'falsch'), verifier: _Accepting()), throwsException);
    });

    test('Phase-0-Prüfer lehnt immer ab', () {
      expect(() => parseManifest(manifest(gueltig), verifier: const RejectingManifestVerifier()), throwsException);
    });

    test('lehnt fremde APK-Adressen und Pfade ab', () {
      for (final apk in ['https://evil.example/x.apk', '../x.apk', 'a/b.apk', 'x.exe']) {
        expect(() => parseManifest(manifest({...gueltig, 'apk': apk}), verifier: _Accepting()), throwsException, reason: apk);
      }
    });

    test('lehnt ungültige Prüfsumme und Version ab', () {
      expect(() => parseManifest(manifest({...gueltig, 'sha256': 'xyz'}), verifier: _Accepting()), throwsException);
      expect(() => parseManifest(manifest({...gueltig, 'version': 'neu'}), verifier: _Accepting()), throwsException);
    });

    test('lehnt unsigniertes Manifest ab', () {
      expect(() => parseManifest(jsonEncode(gueltig), verifier: _Accepting()), throwsException);
    });
  });
}
