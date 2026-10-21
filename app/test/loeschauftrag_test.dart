// Löschauftrag von "Gerät abgeben" (Löschen scheiterte): Er löscht beim nächsten Start nie still. Eine erneute Anmeldung derselben Person verwirft ihn, eine gespeicherte
// Sitzung dieser Person verhindert das Ausführen, nach 24 Stunden verfällt er (verworfen statt ausgeführt); ohne Anmeldung innerhalb der Frist wird gelöscht.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import 'support/fake_server.dart';
import 'support/test_app.dart';

const _anna = fixIdAdmin;
const _ben = '22222222-2222-4222-8222-222222222222';

Uint8List _marker(DateTime t) => utf8Bytes('${t.millisecondsSinceEpoch}');

/// Speicher mit dem Schlüssel von Anna (und optional Ben) und einem Löschauftrag für Anna.
Future<MemorySchluesselSpeicher> _speicher({DateTime? markerZeit, Uint8List? markerInhalt}) async {
  final s = MemorySchluesselSpeicher();
  await s.schreiben(personenschluesselName(_anna), Uint8List.fromList([1, 2, 3]));
  await s.schreiben(personenschluesselName(_ben), Uint8List.fromList([9]));
  await s.schreiben(loeschauftragName(_anna), markerInhalt ?? _marker(markerZeit ?? DateTime.now()));
  return s;
}

ProviderContainer _app(MemorySchluesselSpeicher speicher, {bool hookWirft = false}) {
  final server = FakeServer()
    ..json('POST /auth/login/password', {'user': userJson(), 'session': appSession()})
    ..json('GET /me', meJson());
  final env = TestUmgebung(server);
  env.extraOverrides.addAll([
    schluesselSpeicherProvider.overrideWithValue(speicher),
    sitzungBestaetigtProvider.overrideWith(
      (ref) => (userId) async {
        if (hookWirft) throw StateError('Hook kaputt');
        await loeschauftragVerwerfen(speicher, userId);
      },
    ),
  ]);
  final c = env.container();
  addTearDown(c.dispose);
  return c;
}

Future<bool> _schluesselDa(MemorySchluesselSpeicher s, String uid) async => await s.lesen(personenschluesselName(uid)) != null;
Future<bool> _markerDa(MemorySchluesselSpeicher s) async => (await s.namenMitPraefix('e2ee.loeschauftrag.')).isNotEmpty;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Löschfehler, dann Neuanmeldung derselben Person, dann App-Neustart: der Schlüssel bleibt', () async {
    final speicher = await _speicher();
    final c = _app(speicher);
    await c.read(authProvider.notifier).mitPasswortAnmelden(email: 'anna@beispiel.de', passwort: 'geheimes-passwort', totp: '123456');
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    expect(await _markerDa(speicher), isFalse, reason: 'die erfolgreiche Anmeldung hat den Auftrag verworfen');
    // App-Neustart: Es liegt kein Auftrag mehr, selbst ohne Wissen über die Sitzung
    await loeschauftraegeAbarbeiten(speicher);
    expect(await _schluesselDa(speicher, _anna), isTrue);
  });

  test('gültige Sitzung beim Start der App (GET /me) verwirft den Auftrag ebenfalls', () async {
    final speicher = await _speicher();
    final server = FakeServer()..json('GET /me', meJson());
    final env = TestUmgebung(server);
    await env.angemeldet();
    env.extraOverrides.addAll([
      schluesselSpeicherProvider.overrideWithValue(speicher),
      sitzungBestaetigtProvider.overrideWith((ref) => (userId) => loeschauftragVerwerfen(speicher, userId)),
    ]);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    expect(await _markerDa(speicher), isFalse);
    expect(await _schluesselDa(speicher, _anna), isTrue);
  });

  test('Anmeldung einer ANDEREN Person verwirft den Auftrag von Anna nicht', () async {
    final speicher = await _speicher();
    await loeschauftragVerwerfen(speicher, _ben); // gibt es nicht: nichts passiert
    expect(await _markerDa(speicher), isTrue);
  });

  test('ein Fehler im Hook stört die Anmeldung nicht', () async {
    final speicher = await _speicher();
    final c = _app(speicher, hookWirft: true);
    await c.read(authProvider.notifier).mitPasswortAnmelden(email: 'anna@beispiel.de', passwort: 'geheimes-passwort', totp: '123456');
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    expect(await _markerDa(speicher), isTrue, reason: 'bleibt; der Schutz gegen Löschen liegt dann bei Sitzungsprüfung und Frist');
  });

  test('Löschfehler, Neustart ohne Anmeldung (keine Sitzung): der Schlüssel wird gelöscht, andere Personen bleiben', () async {
    final speicher = await _speicher();
    await loeschauftraegeAbarbeiten(speicher, aktiveUserId: () async => null);
    expect(await _schluesselDa(speicher, _anna), isFalse);
    expect(await _schluesselDa(speicher, _ben), isTrue);
    expect(await _markerDa(speicher), isFalse);
  });

  test('gespeicherte Sitzung DIESER Person: nicht löschen, Auftrag verwerfen', () async {
    final speicher = await _speicher();
    await loeschauftraegeAbarbeiten(speicher, aktiveUserId: () async => _anna);
    expect(await _schluesselDa(speicher, _anna), isTrue);
    expect(await _markerDa(speicher), isFalse);
  });

  test('Sitzung einer ANDEREN Person: der Auftrag für Anna wird ausgeführt', () async {
    final speicher = await _speicher();
    await loeschauftraegeAbarbeiten(speicher, aktiveUserId: () async => _ben);
    expect(await _schluesselDa(speicher, _anna), isFalse);
    expect(await _schluesselDa(speicher, _ben), isTrue);
  });

  test('Sitzung nicht lesbar (Fehler): wie "keine Sitzung" (der Auftrag ist frisch und gilt)', () async {
    final speicher = await _speicher();
    await loeschauftraegeAbarbeiten(speicher, aktiveUserId: () async => throw StateError('Speicher kaputt'));
    expect(await _schluesselDa(speicher, _anna), isFalse);
  });

  test('abgelaufener Auftrag (älter als 24 Stunden) wird verworfen statt ausgeführt', () async {
    final jetzt = DateTime(2026, 10, 22, 12);
    final speicher = await _speicher(markerZeit: jetzt.subtract(kLoeschauftragFrist + const Duration(minutes: 1)));
    await loeschauftraegeAbarbeiten(speicher, jetzt: () => jetzt);
    expect(await _schluesselDa(speicher, _anna), isTrue);
    expect(await _markerDa(speicher), isFalse);
  });

  test('knapp innerhalb der Frist gilt der Auftrag noch', () async {
    final jetzt = DateTime(2026, 10, 22, 12);
    final speicher = await _speicher(markerZeit: jetzt.subtract(kLoeschauftragFrist - const Duration(minutes: 1)));
    await loeschauftraegeAbarbeiten(speicher, jetzt: () => jetzt);
    expect(await _schluesselDa(speicher, _anna), isFalse);
  });

  test('unlesbarer Inhalt oder Zeitpunkt in der Zukunft: verworfen, nie ausgeführt', () async {
    for (final inhalt in [Uint8List.fromList([1]), utf8Bytes('kaputt'), _marker(DateTime.now().add(const Duration(days: 3)))]) {
      final speicher = await _speicher(markerInhalt: inhalt);
      await loeschauftraegeAbarbeiten(speicher);
      expect(await _schluesselDa(speicher, _anna), isTrue);
      expect(await _markerDa(speicher), isFalse);
    }
  });

  test('der Marker enthält nur einen Zeitpunkt, keine Geheimnisse', () async {
    final speicher = MemorySchluesselSpeicher();
    await speicher.schreiben(loeschauftragName(_anna), _marker(DateTime.now()));
    final roh = await speicher.lesen(loeschauftragName(_anna));
    expect(int.tryParse(String.fromCharCodes(roh!)), isNotNull);
  });
}
