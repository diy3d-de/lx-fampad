// Android-Schlüsselspeicher (flutter_secure_storage, hier mit Fake): "nicht vorhanden" und "Fehler" sind getrennt, Lesen löscht nie selbst,
// Löschen aller Schlüssel geht über den Index (kein readAll).
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher_io.dart';

class _FakeSecure implements FlutterSecureStorage {
  final Map<String, String> daten = {};
  Object? leseFehler;
  final Set<String> loeschFehlerBei = {};
  int readAllAufrufe = 0;

  @override
  Future<String?> read({required String key, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    if (leseFehler != null) throw leseFehler!;
    return daten[key];
  }

  @override
  Future<void> write({required String key, required String? value, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    daten[key] = value!;
  }

  @override
  Future<void> delete({required String key, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    if (loeschFehlerBei.contains(key)) throw PlatformException(code: 'delete');
    daten.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    readAllAufrufe++;
    return {...daten};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SchluesselSpeicherFehler> _fehler(Future<Object?> f) async {
  try {
    await f;
  } on SchluesselSpeicherFehler catch (e) {
    return e;
  }
  throw StateError('kein SchluesselSpeicherFehler');
}

void main() {
  late _FakeSecure secure;
  late SecureSchluesselSpeicher speicher;
  setUp(() {
    secure = _FakeSecure();
    speicher = SecureSchluesselSpeicher(secure);
  });

  test('Roundtrip; fehlender Eintrag ist null (kein Fehler)', () async {
    expect(await speicher.lesen('e2ee.pk.a'), isNull);
    await speicher.schreiben('e2ee.pk.a', Uint8List.fromList([1, 2, 3]));
    expect(await speicher.lesen('e2ee.pk.a'), [1, 2, 3]);
  });

  test('vorübergehender Lesefehler (Keystore gesperrt, E/A) wirft und lässt den Eintrag unangetastet', () async {
    await speicher.schreiben('e2ee.pk.a', Uint8List.fromList([9]));
    for (final e in [PlatformException(code: 'Exception encountered', message: 'KeyStoreException: key not accessible'), StateError('E/A'), PlatformException(code: 'x')]) {
      secure.leseFehler = e;
      final f = await _fehler(speicher.lesen('e2ee.pk.a'));
      expect(f.dauerhaft, isFalse, reason: '$e');
    }
    secure.leseFehler = null;
    expect(await speicher.lesen('e2ee.pk.a'), [9], reason: 'nichts wurde gelöscht');
  });

  test('eindeutig dauerhafte Fehler (Entschlüsselung: BadPadding, AEADBadTag, MAC) gelten als dauerhaft, der Speicher löscht trotzdem nicht selbst', () async {
    await speicher.schreiben('e2ee.pk.a', Uint8List.fromList([9]));
    for (final text in ['javax.crypto.BadPaddingException: error', 'android.security.keystore.AEADBadTagException', 'Signature/MAC verification failed']) {
      secure.leseFehler = PlatformException(code: 'Exception encountered', message: text);
      expect((await _fehler(speicher.lesen('e2ee.pk.a'))).dauerhaft, isTrue, reason: text);
    }
    secure.leseFehler = null;
    expect(await speicher.lesen('e2ee.pk.a'), [9]);
  });

  test('beschädigter Eintrag (kein Base64url) ist dauerhaft unbrauchbar', () async {
    secure.daten['lx_fampad_e2ee.pk.a'] = '!!!kaputt!!!';
    expect((await _fehler(speicher.lesen('e2ee.pk.a'))).dauerhaft, isTrue);
  });

  test('alle Schlüssel löschen über den Index, ohne readAll; andere Einträge bleiben', () async {
    await speicher.schreiben('e2ee.pk.a', Uint8List.fromList([1]));
    await speicher.schreiben('e2ee.pk.b.alt', Uint8List.fromList([2]));
    await speicher.schreiben('e2ee.vertrauen.a', Uint8List.fromList([3]));
    await speicher.loescheMitPraefix('e2ee.pk.');
    expect(await speicher.lesen('e2ee.pk.a'), isNull);
    expect(await speicher.lesen('e2ee.pk.b.alt'), isNull);
    expect(await speicher.lesen('e2ee.vertrauen.a'), [3]);
    expect(secure.readAllAufrufe, 0);
  });

  test('Löschfehler: die übrigen werden trotzdem gelöscht, der erste Fehler geht weiter, der Rest bleibt im Index für den nächsten Versuch', () async {
    await speicher.schreiben('e2ee.pk.a', Uint8List.fromList([1]));
    await speicher.schreiben('e2ee.pk.b', Uint8List.fromList([2]));
    secure.loeschFehlerBei.add('lx_fampad_e2ee.pk.a');
    await expectLater(speicher.loescheMitPraefix('e2ee.pk.'), throwsA(isA<PlatformException>()));
    expect(await speicher.lesen('e2ee.pk.b'), isNull);
    expect(await speicher.lesen('e2ee.pk.a'), [1], reason: 'noch da');
    secure.loeschFehlerBei.clear();
    await speicher.loescheMitPraefix('e2ee.pk.');
    expect(await speicher.lesen('e2ee.pk.a'), isNull, reason: 'der zweite Versuch findet ihn über den Index');
  });

  test('einzelnes Löschen entfernt auch den Indexeintrag', () async {
    await speicher.schreiben('e2ee.pk.a', Uint8List.fromList([1]));
    await speicher.loeschen('e2ee.pk.a');
    expect(await speicher.lesen('e2ee.pk.a'), isNull);
    await speicher.loescheMitPraefix('e2ee.pk.');
  });
}
