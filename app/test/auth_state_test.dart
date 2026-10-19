// Auth-State: Start (GET /me), Anmeldearten, Abmelden (Token und lokale Daten), Sitzungsverlust, Warten auf Freigabe.
import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  group('Start bei Serverstörung wie bei fehlendem Netz', () {
    for (final (name, antwort) in <(String, http.Response Function())>[
      ('503 server_busy', () => fehler(503, 'server_busy', retryAfter: 5)),
      ('429 Zu viele Anfragen', () => fehler(429, 'rate_limited', retryAfter: 30)),
      ('500 interner Fehler', () => fehler(500, 'internal_error')),
      ('502 Fehlerseite von Caddy (HTML)', () => http.Response('<html><body>Bad Gateway</body></html>', 502)),
    ]) {
      test('$name: Android startet offline mit dem gespeicherten Profil', () async {
        final server = FakeServer()..on('GET /me', (_) => antwort());
        final env = TestUmgebung(server);
        await env.angemeldet();
        await env.store.writeProfile(userJson(role: 'child', name: 'Ben'));
        final c = env.container();
        addTearDown(c.dispose);
        await c.read(authProvider.notifier).start();
        final s = c.read(authProvider);
        expect(s.status, AuthStatus.angemeldet);
        expect(s.offline, isTrue);
        expect(s.user!.displayName, 'Ben');
        expect(await env.store.readTokens(), isNotNull, reason: 'die Sitzung ist nicht widerlegt');
      });
    }

    test('ohne gespeichertes Profil: Verbindungsfehler mit Hinweis statt Endlos-Spinner', () async {
      final server = FakeServer()..on('GET /me', (_) => fehler(503, 'server_busy'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      expect(c.read(authProvider).status, AuthStatus.verbindungsfehler);
      expect(c.read(authProvider).hinweis, isNotEmpty);
    });

    test('Web: Serverstörung beim Start ist ein Verbindungsfehler (es gibt keine lokale Sitzungsablage)', () async {
      final server = FakeServer()..on('GET /me', (_) => fehler(503, 'server_busy'));
      final env = TestUmgebung(server, web: true);
      await env.store.writeProfile(userJson());
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      expect(c.read(authProvider).status, AuthStatus.verbindungsfehler);
    });
  });

  group('Start ohne Endlos-Spinner', () {
    test('Der sichere Speicher wirft (PlatformException): kein Hängen, sondern Fehlerseite mit "Erneut versuchen"', () async {
      final env = TestUmgebung(FakeServer(), store: _KaputterSpeicher());
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      expect(c.read(authProvider).status, AuthStatus.verbindungsfehler);
      expect(c.read(authProvider).hinweis, isNotEmpty);
    });

    test('Unerwartete Antwort (kein Objekt) endet ebenfalls nicht im Spinner', () async {
      final server = FakeServer()..on('GET /me', (_) => jsonAntwort([1, 2]));
      final env = TestUmgebung(server);
      await env.angemeldet();
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      expect(c.read(authProvider).status, AuthStatus.verbindungsfehler);
    });

    test('Web, Erstbesuch ohne Sitzung: abgemeldet OHNE Hinweis "Sitzung abgelaufen"', () async {
      final server = FakeServer()..on('GET /me', (_) => fehler(401, 'unauthenticated'));
      final env = TestUmgebung(server, web: true);
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      final s = c.read(authProvider);
      expect(s.status, AuthStatus.abgemeldet);
      expect(s.hinweis, isNull);
    });
  });

  group('Abmelden', () {
    Future<(TestUmgebung, ProviderContainerLeser)> angemeldet(FakeServer server, {bool web = false}) async {
      final env = TestUmgebung(server, web: web);
      if (!web) await env.angemeldet();
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      expect(c.read(authProvider).status, AuthStatus.angemeldet);
      return (env, ProviderContainerLeser(c));
    }

    test('Web: Serverfehler -> NICHT als abgemeldet anzeigen, Fehler geworfen; Wiederholen klappt', () async {
      var kaputt = true;
      final server = FakeServer()
        ..json('GET /me', meJson(csrf: 'csrf-1'))
        ..on('POST /auth/logout', (_) => kaputt ? fehler(500, 'internal_error') : jsonAntwort({'ok': true}));
      final (env, l) = await angemeldet(server, web: true);
      await expectLater(l.auth.abmelden(), throwsA(isA<ApiException>()));
      expect(l.status, AuthStatus.angemeldet);
      expect(env.geloescht, 0);
      kaputt = false;
      final r = await l.auth.abmelden();
      expect(r.serverAbgemeldet, isTrue);
      expect(l.status, AuthStatus.abgemeldet);
      expect(env.geloescht, 1);
    });

    test('Web: Netzwerkfehler -> ebenfalls Fehler; "trotzdem lokal abmelden" ruft den Server nicht und meldet es im Ergebnis', () async {
      final server = FakeServer()
        ..json('GET /me', meJson(csrf: 'csrf-1'))
        ..on('POST /auth/logout', (_) async => throw TimeoutException('t'));
      final (env, l) = await angemeldet(server, web: true);
      await expectLater(l.auth.abmelden(), throwsA(isA<ApiException>().having((e) => e.istNetzwerk, 'netzwerk', isTrue)));
      expect(l.status, AuthStatus.angemeldet);
      final r = await l.auth.abmelden(nurLokal: true);
      expect(r.serverAbgemeldet, isFalse);
      expect(l.status, AuthStatus.abgemeldet);
      expect(env.geloescht, 1);
      expect(server.anfragen('POST /auth/logout'), hasLength(1), reason: 'nur der erste Versuch');
    });

    test('Android: offline wird toleriert, Token lokal gelöscht, Ergebnis sagt "Server nicht erreicht"', () async {
      final server = FakeServer()
        ..json('GET /me', meJson())
        ..on('POST /auth/logout', (_) async => throw TimeoutException('t'));
      final (env, l) = await angemeldet(server);
      final r = await l.auth.abmelden();
      expect(r.serverAbgemeldet, isFalse);
      expect(r.lokalSauber, isTrue);
      expect(await env.store.readTokens(), isNull);
      expect(await env.store.readProfile(), isNull);
      expect(env.geloescht, 1);
      expect(l.status, AuthStatus.abgemeldet);
    });

    test('Android: Serverfehler (500) wird ebenfalls toleriert', () async {
      final server = FakeServer()
        ..json('GET /me', meJson())
        ..on('POST /auth/logout', (_) => fehler(500, 'internal_error'));
      final (env, l) = await angemeldet(server);
      final r = await l.auth.abmelden();
      expect(r.serverAbgemeldet, isFalse);
      expect(await env.store.readTokens(), isNull);
      expect(l.status, AuthStatus.abgemeldet);
    });

    test('Die Sitzung ist auf dem Server schon beendet (401): gilt als abgemeldet, ohne Hinweis "abgelaufen"', () async {
      final server = FakeServer()
        ..json('GET /me', meJson())
        ..on('POST /auth/logout', (_) => fehler(401, 'unauthenticated'))
        ..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
      final (env, l) = await angemeldet(server);
      final r = await l.auth.abmelden();
      expect(r.serverAbgemeldet, isTrue);
      expect(l.status, AuthStatus.abgemeldet);
      expect(l.c.read(authProvider).hinweis, isNull);
      expect(env.geloescht, 1);
    });

    test('Wiper wirft: Zustand geht trotzdem auf abgemeldet, Token sind weg, Ergebnis meldet "nicht sauber"', () async {
      final server = FakeServer()
        ..json('GET /me', meJson())
        ..json('POST /auth/logout', {'ok': true});
      final (env, l) = await angemeldet(server);
      env.wiperFehler = true;
      final r = await l.auth.abmelden();
      expect(l.status, AuthStatus.abgemeldet);
      expect(await env.store.readTokens(), isNull);
      expect(r.serverAbgemeldet, isTrue);
      expect(r.lokalSauber, isFalse);
    });

    test('dieses Gerät aus der Geräteliste entfernt: lokal abmelden, Daten löschen', () async {
      final server = FakeServer()..json('GET /me', meJson());
      final (env, l) = await angemeldet(server);
      final r = await l.auth.dieseSitzungBeendet();
      expect(r.lokalSauber, isTrue);
      expect(l.status, AuthStatus.abgemeldet);
      expect(env.geloescht, 1);
      expect(await env.store.readTokens(), isNull);
    });
  });

  group('Lokale Daten: nur bei anderer Person oder ausdrücklichem Abmelden leeren', () {
    Future<(TestUmgebung, ProviderContainerLeser)> start(FakeServer server) async {
      final env = TestUmgebung(server);
      final c = env.container();
      addTearDown(c.dispose);
      return (env, ProviderContainerLeser(c));
    }

    FakeServer loginServer({String id = fixIdAdmin}) => FakeServer()
      ..json('POST /auth/login/password', {'user': userJson(id: id), 'session': appSession()})
      ..json('GET /me', {...meJson(), 'user': userJson(id: id)});

    test('erste Anmeldung: Besitzer wird gemerkt, nichts gelöscht', () async {
      final (env, l) = await start(loginServer());
      await l.auth.mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456');
      expect(env.geloescht, 0);
      expect(await env.owner.lesen(), fixIdAdmin);
    });

    test('Sitzungsverlust, dieselbe Person meldet sich wieder an: Daten bleiben (ungesendete Änderungen)', () async {
      final server = loginServer()..on('GET /devices', (_) => fehler(401, 'unauthenticated'))..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
      final (env, l) = await start(server);
      await l.auth.mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456');
      await expectLater(l.c.read(apiProvider).geraete(), throwsA(isA<ApiException>()));
      expect(l.status, AuthStatus.abgemeldet);
      expect(env.geloescht, 0);
      await l.auth.mitPasswortAnmelden(email: 'a@b.de', passwort: 'x', totp: '123456');
      expect(l.status, AuthStatus.angemeldet);
      expect(env.geloescht, 0, reason: 'dieselbe Person: nichts löschen');
    });

    test('Sitzungsverlust, eine ANDERE Person meldet sich an: Daten werden vorher geleert', () async {
      final (env, l) = await start(loginServer(id: fixIdKind));
      await env.owner.setzen(fixIdAdmin); // die lokalen Daten gehören Anna
      await l.auth.mitPasswortAnmelden(email: 'ben@b.de', passwort: 'x', totp: '123456');
      expect(env.geloescht, 1);
      expect(await env.owner.lesen(), fixIdKind);
      expect(l.status, AuthStatus.angemeldet);
    });

    test('Registrierung einer anderen Person leert ebenfalls', () async {
      final (env, l) = await start(FakeServer()..json('GET /me', {...meJson(), 'user': userJson(id: fixIdKind)}));
      await env.owner.setzen(fixIdAdmin);
      await l.auth.registrierungAbschliessen(
        RegistrationResult.fromJson({'member': userJson(id: fixIdKind), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()}),
      );
      expect(env.geloescht, 1);
    });

    test('Kann die Datenbank der anderen Person nicht geleert werden, wird die Anmeldung abgebrochen (keine fremden Daten sichtbar)', () async {
      final (env, l) = await start(loginServer(id: fixIdKind));
      await env.owner.setzen(fixIdAdmin);
      env.wiperFehler = true;
      await expectLater(l.auth.mitPasswortAnmelden(email: 'ben@b.de', passwort: 'x', totp: '123456'), throwsA(isA<StateError>()));
      expect(l.status, AuthStatus.abgemeldet);
      expect(await env.store.readTokens(), isNull);
    });

    test('Start mit Sitzung einer anderen Person als der Besitzer der Daten leert ebenfalls', () async {
      final server = FakeServer()..json('GET /me', {...meJson(), 'user': userJson(id: fixIdKind)});
      final (env, l) = await start(server);
      await env.angemeldet();
      await env.owner.setzen(fixIdAdmin);
      await l.auth.start();
      expect(env.geloescht, 1);
      expect(l.status, AuthStatus.angemeldet);
    });
  });

  group('späte Antworten', () {
    test('/me kommt erst nach dem Abmelden an: Zustand bleibt abgemeldet', () async {
      final freigabe = Completer<void>();
      var n = 0;
      final server = FakeServer()
        ..on('GET /me', (_) async {
          if (++n > 1) await freigabe.future;
          return jsonAntwort(meJson());
        })
        ..json('POST /auth/logout', {'ok': true});
      final env = TestUmgebung(server);
      await env.angemeldet();
      final c = env.container();
      addTearDown(c.dispose);
      final auth = c.read(authProvider.notifier);
      await auth.start();
      final spaet = auth.neuLaden();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await auth.abmelden();
      freigabe.complete();
      await spaet;
      expect(c.read(authProvider).status, AuthStatus.abgemeldet);
      expect(c.read(authProvider).user, isNull);
    });

    test('/me der alten Person kommt erst nach einem Personenwechsel an: überschreibt die neue Person nicht', () async {
      final freigabe = Completer<void>();
      var n = 0;
      final server = FakeServer()
        ..on('GET /me', (_) async {
          final k = ++n;
          if (k == 2) await freigabe.future; // das Neuladen der alten Person
          return jsonAntwort(k <= 2 ? meJson() : {...meJson(), 'user': userJson(id: fixIdKind, name: 'Ben', role: 'child')});
        })
        ..json('POST /auth/logout', {'ok': true})
        ..json('POST /auth/login/password', {'user': userJson(id: fixIdKind, name: 'Ben', role: 'child'), 'session': appSession(access: 'a2', refresh: 'r2')});
      final env = TestUmgebung(server);
      await env.angemeldet();
      final c = env.container();
      addTearDown(c.dispose);
      final auth = c.read(authProvider.notifier);
      await auth.start();
      final spaet = auth.neuLaden(); // Anna
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await auth.abmelden();
      await auth.mitPasswortAnmelden(email: 'ben@b.de', passwort: 'x', totp: '123456');
      expect(c.read(authProvider).user!.displayName, 'Ben');
      freigabe.complete();
      await spaet;
      expect(c.read(authProvider).user!.displayName, 'Ben', reason: 'die späte Antwort für Anna darf Ben nicht überschreiben');
      expect((await env.store.readProfile())!['displayName'], 'Ben');
    });
  });
}

class ProviderContainerLeser {
  final ProviderContainer c;
  ProviderContainerLeser(this.c);
  AuthController get auth => c.read(authProvider.notifier);
  AuthStatus get status => c.read(authProvider).status;
}

/// Sicherer Speicher, der bei jedem Zugriff scheitert (Keystore-Verlust u. ä.).
class _KaputterSpeicher extends MemoryTokenStore {
  @override
  Future<StoredTokens?> readTokens() async => throw PlatformException(code: 'keystore', message: 'BadPaddingException');
}
