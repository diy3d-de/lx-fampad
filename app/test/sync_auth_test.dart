// Sync und Anmeldung: Der Besitzer der lokalen Daten liegt in sync_meta (localDataOwnerProvider mit der echten Datenbank), Abmelden leert
// Listen, Ausgang und Sync-Zustand, ein Sitzungsverlust lässt sie stehen: nach erneuter Anmeldung derselben Person geht der Ausgang raus.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/lists/list_repository.dart';
import 'package:lx_fampad/data/sync_state.dart';

import 'support/fake_server.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FakeServer server({String id = fixIdAdmin}) => FakeServer()
    ..json('POST /auth/login/password', {'user': userJson(id: id), 'session': appSession()})
    ..json('GET /me', {...meJson(), 'user': userJson(id: id)})
    ..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'))
    ..on('GET /devices', (_) => fehler(401, 'unauthenticated'));

  Future<(TestUmgebung, ProviderContainer)> aufbau({String id = fixIdAdmin}) async {
    final env = TestUmgebung(server(id: id))
      ..besitzerInDb = true
      ..wiperEcht = true;
    final c = env.container();
    addTearDown(c.dispose);
    return (env, c);
  }

  Future<void> anmelden(ProviderContainer c) => c.read(authProvider.notifier).mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456');

  test('Anmelden merkt den Besitzer in sync_meta; ungesendete Änderungen überstehen einen Sitzungsverlust und gehen nach erneuter Anmeldung raus', () async {
    final (env, c) = await aufbau();
    await anmelden(c);
    expect(await env.db.besitzerLesen(), fixIdAdmin);
    final repo = c.read(listenRepositoryProvider);
    final id = await repo.listeAnlegen(name: 'Einkauf');
    await repo.eintragAnlegen(id, 'Milch');
    expect(await c.read(syncStoreProvider).offeneAnzahl(), 2);

    // Sitzung geht verloren (widerrufen/abgelaufen)
    await expectLater(c.read(apiProvider).geraete(), throwsA(isA<ApiException>()));
    expect(c.read(authProvider).status, AuthStatus.abgemeldet);
    expect(await c.read(syncStoreProvider).offeneAnzahl(), 2, reason: 'der Ausgang bleibt stehen');
    expect(await env.db.select(env.db.listen).get(), hasLength(1));

    // dieselbe Person meldet sich wieder an: Daten und Ausgang sind noch da, der Abgleich sendet sie
    await anmelden(c);
    expect(await c.read(syncStoreProvider).offeneAnzahl(), 2);
    final e = await c.read(syncEngineProvider).abgleichen();
    expect(e.ok, isTrue);
    expect(await c.read(syncStoreProvider).offeneAnzahl(), 0);
    expect(env.sync.zeilen.values.map((z) => z.entity).toSet(), {'list', 'list_item'});
  });

  test('eine ANDERE Person meldet sich an: Listen, Ausgang und Sync-Zustand werden vorher geleert, der neue Besitzer gemerkt', () async {
    final (env, c) = await aufbau(id: fixIdKind);
    await env.db.besitzerSetzen(fixIdAdmin);
    final store = c.read(syncStoreProvider);
    await store.aendern('list', 'l1', {'name': 'Annas Liste'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z'});
    await store.sinceRevSetzen(7);
    await anmelden(c);
    expect(await env.db.select(env.db.listen).get(), isEmpty);
    expect(await store.offeneAnzahl(), 0);
    expect(await store.sinceRev(), 0);
    expect(await env.db.besitzerLesen(), fixIdKind);
  });

  test('ausdrückliches Abmelden leert alles (auch den Besitzer), der Sync ist danach angehalten', () async {
    final (env, c) = await aufbau();
    env.server.json('POST /auth/logout', {});
    await anmelden(c);
    c.read(syncProvider.notifier).starten();
    final repo = c.read(listenRepositoryProvider);
    await repo.listeAnlegen(name: 'Einkauf');
    await c.read(authProvider.notifier).abmelden();
    expect(await env.db.select(env.db.listen).get(), isEmpty);
    expect(await c.read(syncStoreProvider).offeneAnzahl(), 0);
    expect(await env.db.besitzerLesen(), isNull);
    expect(c.read(syncProvider.notifier).aktiv, isFalse);
  });
}
