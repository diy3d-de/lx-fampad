// Mitgliederliste: lädt nach gelungenem Abgleich und bei Rückkehr in die App neu (höchstens alle 60 s), behält bei Fehlern den Zwischenstand.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/avatar/avatar_foto.dart';
import 'package:lx_fampad/data/lists/members.dart';
import 'package:lx_fampad/data/sync_state.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late TestUmgebung env;
  late ProviderContainer c;
  late DateTime jetzt;

  Future<void> bis(bool Function() bedingung, String grund) async {
    for (var i = 0; i < 100; i++) {
      if (bedingung()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Zeitüberschreitung: $grund');
  }

  setUp(() async {
    jetzt = DateTime(2026, 10, 19, 12);
    final server = standardServer();
    env = await angemeldeteUmgebung(server: server);
    env.extraOverrides.add(mitgliederUhrProvider.overrideWithValue(() => jetzt));
    c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    c.listen(mitgliederAktualisierungProvider, (_, _) {});
    c.listen(mitgliederProvider, (_, _) {});
    expect((await c.read(mitgliederProvider.future)).map((u) => u.displayName), hasLength(2));
    c.read(syncProvider.notifier).starten();
    await bis(() => c.read(syncProvider).letzterAbgleich != null, 'erster Abgleich');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  void neuesMitglied() => env.server.json('GET /members', {
    'members': [
      userJson(),
      userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
      userJson(id: '33333333-4444-4555-8666-777777777777', role: 'child', name: 'Lena', email: 'lena@beispiel.de'),
    ],
  });

  int anzahl() => c.read(mitgliederProvider).value?.length ?? 0;

  test('neues Mitglied erscheint nach einem Abgleich, ohne Neustart', () async {
    neuesMitglied();
    jetzt = jetzt.add(const Duration(seconds: 61));
    await c.read(syncProvider.notifier).synchronisieren(manuell: true);
    await bis(() => anzahl() == 3, 'Mitglied nach Abgleich');
  });

  test('geänderte Profilbild-Version kommt mit dem Abgleich an; ein Verbindungsfehler-Merker für Fotos wird dabei gelöscht (erneuter Versuch)', () async {
    final speicher = c.read(avatarSpeicherProvider);
    speicher.fehlversuche['$fixIdKind:1'] = DateTime.now();
    env.server.json('GET /members', {
      'members': [
        userJson(),
        {...userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'), 'avatar': {'kind': 'photo', 'version': 2}},
      ],
    });
    jetzt = jetzt.add(const Duration(seconds: 61));
    await c.read(syncProvider.notifier).synchronisieren(manuell: true);
    await bis(() => c.read(mitgliederProvider).value?.any((u) => u.avatar?.version == 2) ?? false, 'neue Bildversion');
    expect(speicher.fehlversuche, isEmpty);
  });

  test('Rückkehr in die App lädt neu, aber höchstens alle 60 Sekunden', () async {
    neuesMitglied();
    final n0 = env.server.anfragen('GET /members').length;
    // Die Drosselung beginnt mit dem ersten Laden; das Fenster ist noch nicht abgelaufen
    jetzt = jetzt.add(const Duration(seconds: 61));
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await bis(() => anzahl() == 3, 'Mitglied nach Rückkehr');
    final n1 = env.server.anfragen('GET /members').length;
    expect(n1, greaterThan(n0));
    // zweite Rückkehr kurz danach: keine weitere Anfrage
    jetzt = jetzt.add(const Duration(seconds: 10));
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(env.server.anfragen('GET /members').length, n1);
  });

  test('Hinweis des Servers (members_changed) lädt neu, auch innerhalb der 60 Sekunden; zu frühe Hinweise werden gebündelt nachgeholt', () async {
    neuesMitglied();
    jetzt = jetzt.add(const Duration(seconds: 6));
    c.read(mitgliederHinweisProvider.notifier).hinweis();
    await bis(() => anzahl() == 3, 'Mitglied nach Hinweis');
    final n1 = env.server.anfragen('GET /members').length;
    // zwei Hinweise kurz nach der Ladung: eine einzige weitere Ladung nach dem Mindestabstand
    c.read(mitgliederHinweisProvider.notifier).hinweis();
    c.read(mitgliederHinweisProvider.notifier).hinweis();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(env.server.anfragen('GET /members').length, n1);
    await Future<void>.delayed(const Duration(seconds: 5, milliseconds: 300));
    expect(env.server.anfragen('GET /members').length, n1 + 1);
  });

  test('Fehler beim Laden: der Zwischenstand bleibt', () async {
    neuesMitglied();
    jetzt = jetzt.add(const Duration(seconds: 61));
    await c.read(syncProvider.notifier).synchronisieren(manuell: true);
    await bis(() => anzahl() == 3, 'Mitglied nach Abgleich');
    env.server.json('GET /members', {'error': 'kaputt'}, status: 500);
    jetzt = jetzt.add(const Duration(seconds: 61));
    await c.read(syncProvider.notifier).synchronisieren(manuell: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(anzahl(), 3);
  });
}
