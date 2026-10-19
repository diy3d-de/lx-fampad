// Auth-State: Start (GET /me), Anmeldearten, Abmelden (Token und lokale Daten), Sitzungsverlust, Warten auf Freigabe.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/passkey_service.dart';

import 'support/fake_server.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Start ohne gespeicherte Token (App): abgemeldet, kein Netzaufruf', () async {
    final server = FakeServer();
    final env = TestUmgebung(server);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.abgemeldet);
    expect(server.log, isEmpty);
  });

  test('Start mit Token: GET /me, Zustand angemeldet mit Rolle und Zugängen, Profil für den Offline-Start gespeichert', () async {
    final server = FakeServer()..json('GET /me', meJson(role: 'parent', passkeys: 2));
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    final s = c.read(authProvider);
    expect(s.status, AuthStatus.angemeldet);
    expect(s.rolle, Role.parent);
    expect(s.darfEinladen, isTrue);
    expect(s.istAdmin, isFalse);
    expect(s.me!.passkeys, 2);
    expect((await env.store.readProfile())!['displayName'], 'Anna');
  });

  test('Start im Web: Cookie-Sitzung, CSRF-Token aus /me wird für ändernde Aufrufe benutzt', () async {
    final server = FakeServer()
      ..json('GET /me', meJson(csrf: 'csrf-vom-start'))
      ..json('PATCH /me', {'ok': true});
    final env = TestUmgebung(server, web: true);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    await c.read(apiProvider).profilAendern(anzeigename: 'Anni');
    expect(server.anfragen('PATCH /me').single.headers['x-csrf-token'], 'csrf-vom-start');
    expect(await env.store.readTokens(), isNull, reason: 'im Web liegen keine Token im Speicher');
  });

  test('Start: 401 -> abgemeldet', () async {
    final server = FakeServer()..on('GET /me', (_) => fehler(401, 'unauthenticated'));
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    final s = c.read(authProvider);
    expect(s.status, AuthStatus.abgemeldet);
    expect(s.hinweis, contains('abgelaufen'));
    expect(await env.store.readTokens(), isNull);
  });

  test('Start: Konto wartet auf Freigabe (403 account_pending) -> wartend', () async {
    final server = FakeServer()..on('GET /me', (_) => fehler(403, 'account_pending'));
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.wartend);
  });

  test('Start: /me meldet Status pending -> wartend', () async {
    final server = FakeServer()..json('GET /me', meJson(role: 'guest', status: 'pending'));
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.wartend);
    expect(c.read(authProvider).user!.displayName, 'Anna');
  });

  test('Start ohne Verbindung: mit gespeichertem Profil offline angemeldet, sonst Verbindungsfehler', () async {
    final server = FakeServer();
    // ohne Profil
    var env = TestUmgebung(FakeServer()..on('GET /me', (_) async => throw TimeoutException('t')));
    await env.angemeldet();
    var c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.verbindungsfehler);
    expect(c.read(authProvider).hinweis, isNotEmpty);

    // mit Profil
    env = TestUmgebung(server);
    await env.angemeldet();
    await env.store.writeProfile(userJson(role: 'child', name: 'Ben'));
    server.on('GET /me', (_) async => throw TimeoutException('t'));
    c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    final s = c.read(authProvider);
    expect(s.status, AuthStatus.angemeldet);
    expect(s.offline, isTrue);
    expect(s.user!.displayName, 'Ben');
  });

  test('Passwort-Anmeldung speichert die Token, sendet Gerätedaten und client=app', () async {
    final server = FakeServer()
      ..json('POST /auth/login/password', {'user': userJson(), 'session': appSession()})
      ..json('GET /me', meJson());
    final env = TestUmgebung(server);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).mitPasswortAnmelden(email: 'anna@beispiel.de', passwort: 'geheimes-passwort', totp: '123456');
    final anfrage = server.anfragen('POST /auth/login/password').single;
    expect(anfrage.json['client'], 'app');
    expect(anfrage.json['totp'], '123456');
    expect(anfrage.json.containsKey('recoveryCode'), isFalse);
    // Gerät: Name, Plattform (im Test liefert der Kanal keinen Namen -> Standard)
    expect((anfrage.json['device'] as Map)['platform'], 'android');
    expect((anfrage.json['device'] as Map)['name'], isNotEmpty);
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    final t = (await env.store.readTokens())!;
    expect((t.accessToken, t.refreshToken, t.deviceId), ('access-1', 'refresh-1', fixDevice));
  });

  test('Anmeldung im Web: client=web, kein Gerät, keine Token im Speicher, CSRF aus der Sitzung', () async {
    final server = FakeServer()
      ..json('POST /auth/login/password', {'user': userJson(), 'session': webSession()})
      ..json('GET /me', meJson(csrf: 'csrf-abc'))
      ..json('POST /invites', neueEinladungJson());
    final env = TestUmgebung(server, web: true);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456');
    final anfrage = server.anfragen('POST /auth/login/password').single;
    expect(anfrage.json['client'], 'web');
    expect(anfrage.json.containsKey('device'), isFalse);
    expect(await env.store.readTokens(), isNull);
    await c.read(apiProvider).einladungErstellen(rolle: Role.child, stunden: 24, pin: false);
    expect(server.anfragen('POST /invites').single.headers['x-csrf-token'], 'csrf-abc');
  });

  test('Wiederherstellungscode: Passwort-Anmeldung mit recoveryCode statt totp, und reiner Code-Weg', () async {
    final server = FakeServer()
      ..json('POST /auth/login/password', {'user': userJson(), 'session': appSession()})
      ..json('POST /auth/login/recovery', {'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 7})
      ..json('GET /me', meJson());
    final env = TestUmgebung(server);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', wiederherstellungscode: 'AAAA-BBBB-CCCC-DDDD');
    final a = server.anfragen('POST /auth/login/password').single;
    expect(a.json['recoveryCode'], 'AAAA-BBBB-CCCC-DDDD');
    expect(a.json.containsKey('totp'), isFalse);

    await c.read(authProvider.notifier).mitWiederherstellungscodeAnmelden(email: 'a@b.de', code: 'AAAA-BBBB-CCCC-EEEE');
    expect(server.anfragen('POST /auth/login/recovery').single.json['code'], 'AAAA-BBBB-CCCC-EEEE');
  });

  test('Passkey-Anmeldung: Optionen holen, Passkey bestätigen, Antwort senden', () async {
    final server = FakeServer()
      ..json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc', 'rpId': 'familie.lx-labs.dev', 'userVerification': 'required'}})
      ..json('POST /auth/login/passkey/verify', {'user': userJson(), 'session': appSession()})
      ..json('GET /me', meJson());
    final env = TestUmgebung(server);
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).mitPasskeyAnmelden();
    expect(env.passkeys.bestaetigt, 1);
    final v = server.anfragen('POST /auth/login/passkey/verify').single;
    expect(v.json['challengeId'], 'c-1');
    expect((v.json['response'] as Map)['id'], 'cred-1');
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
  });

  test('Passkey abgebrochen: Fehler mit Hinweis, keine Anmeldung, kein Serveraufruf zum Prüfen', () async {
    final server = FakeServer()..json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc'}});
    final env = TestUmgebung(server);
    env.passkeys.fehler = const PasskeyException(PasskeyFehler.abgebrochen, 'Abgebrochen.');
    final c = env.container();
    addTearDown(c.dispose);
    await expectLater(c.read(authProvider.notifier).mitPasskeyAnmelden(), throwsA(isA<PasskeyException>()));
    expect(server.anfragen('POST /auth/login/passkey/verify'), isEmpty);
    expect(c.read(authProvider).status, isNot(AuthStatus.angemeldet));
  });

  test('Anmeldung eines noch nicht freigegebenen Kontos -> Zustand wartend', () async {
    final server = FakeServer()..on('POST /auth/login/password', (_) => fehler(403, 'account_pending'));
    final env = TestUmgebung(server);
    final c = env.container();
    addTearDown(c.dispose);
    await expectLater(
      c.read(authProvider.notifier).mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456'),
      throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.kontoWartet)),
    );
    expect(c.read(authProvider).status, AuthStatus.wartend);
    c.read(authProvider.notifier).zurAnmeldung();
    expect(c.read(authProvider).status, AuthStatus.abgemeldet);
  });

  test('Falsche Anmeldedaten bleiben abgemeldet und lösen keinen Sitzungsverlust-Hinweis aus', () async {
    final server = FakeServer()..on('POST /auth/login/password', (_) => fehler(401, 'invalid_credentials'));
    final env = TestUmgebung(server);
    final c = env.container();
    addTearDown(c.dispose);
    c.read(authProvider.notifier).zurAnmeldung();
    await expectLater(
      c.read(authProvider.notifier).mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')),
    );
    expect(c.read(authProvider).status, AuthStatus.abgemeldet);
    expect(c.read(authProvider).hinweis, isNull);
  });

  test('Registrierung abschließen: aktiv -> angemeldet mit Token; pending -> wartend ohne Token', () async {
    final server = FakeServer()..json('GET /me', meJson());
    var env = TestUmgebung(server);
    var c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).registrierungAbschliessen(
      RegistrationResult.fromJson({'member': userJson(), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()}),
    );
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    expect(await env.store.readTokens(), isNotNull);

    env = TestUmgebung(server);
    c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).registrierungAbschliessen(
      RegistrationResult.fromJson({'member': userJson(role: 'guest', status: 'pending'), 'status': 'pending', 'recoveryCodes': codes()}),
    );
    expect(c.read(authProvider).status, AuthStatus.wartend);
    expect(await env.store.readTokens(), isNull);
  });

  test('Abmelden: Server-Aufruf, Token weg, lokale Daten gelöscht (Hook), Zustand abgemeldet', () async {
    final server = FakeServer()
      ..json('GET /me', meJson())
      ..json('POST /auth/logout', {'ok': true});
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await c.read(authProvider.notifier).abmelden();
    expect(server.anfragen('POST /auth/logout'), hasLength(1));
    expect(await env.store.readTokens(), isNull);
    expect(await env.store.readProfile(), isNull);
    expect(env.geloescht, 1);
    expect(c.read(authProvider).status, AuthStatus.abgemeldet);
  });

  test('Überall abmelden ruft logout-all; Serverfehler (offline) verhindern das lokale Abmelden nicht', () async {
    final server = FakeServer()
      ..json('GET /me', meJson())
      ..on('POST /auth/logout-all', (_) async => throw TimeoutException('t'));
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await c.read(authProvider.notifier).abmelden(ueberall: true);
    expect(server.anfragen('POST /auth/logout-all'), hasLength(1));
    expect(await env.store.readTokens(), isNull);
    expect(env.geloescht, 1);
    expect(c.read(authProvider).status, AuthStatus.abgemeldet);
  });

  test('Sitzungsverlust mitten in der Nutzung (401 nach Widerruf) führt zur Anmeldung; lokale Daten bleiben (Sync-Ausgang)', () async {
    final server = FakeServer()
      ..json('GET /me', meJson())
      ..on('GET /devices', (_) => fehler(401, 'unauthenticated'))
      ..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
    final env = TestUmgebung(server);
    await env.angemeldet();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(authProvider).status, AuthStatus.angemeldet);
    await expectLater(c.read(apiProvider).geraete(), throwsA(isA<ApiException>()));
    final s = c.read(authProvider);
    expect(s.status, AuthStatus.abgemeldet);
    expect(s.hinweis, contains('abgelaufen'));
    expect(env.geloescht, 0, reason: 'unsynchronisierte Änderungen gehen bei einem Sitzungsverlust nicht verloren');
  });

  test('Die App erkennt das Ende der Sitzung nach unsicherem Refresh mit passendem Hinweis', () async {
    final server = FakeServer()
      ..json('GET /me', meJson())
      ..on('POST /auth/refresh', (_) async => throw TimeoutException('t'));
    final env = TestUmgebung(server);
    await env.store.writeTokens(
      StoredTokens(
        accessToken: 'a',
        accessExpiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        refreshToken: 'r',
        refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
        deviceId: fixDevice,
      ),
    );
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    final s = c.read(authProvider);
    expect(s.status, AuthStatus.abgemeldet);
    expect(s.hinweis, contains('Verbindung brach'));
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
  });
}
