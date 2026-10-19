// ApiClient: CSRF-Header (Web), Bearer + Refresh (App), Serialisierung der Erneuerung, Verhalten bei Netzfehlern,
// Fehlerabbildung auf verständliche Meldungen. Alles gegen einen Fake-Server, keine echten Netzaufrufe.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';

import 'support/fake_server.dart';

void main() {
  group('Web (Cookie + CSRF)', () {
    test('ändernde Anfragen senden X-CSRF-Token, GET und Bearer nicht', () async {
      final server = FakeServer()
        ..json('GET /me', meJson(csrf: 'csrf-neu'))
        ..json('POST /invites', neueEinladungJson())
        ..json('PATCH /me', {'ok': true})
        ..json('DELETE /devices/x', {'ok': true});
      final (client, _) = await angemeldeterClient(server, web: true);
      client.csrfSetzen('csrf-abc');

      await client.get('/me');
      await client.post('/invites', {'role': 'child'});
      await client.patch('/me', {'displayName': 'Anna'});
      await client.delete('/devices/x');

      expect(server.anfragen('GET /me').single.headers.containsKey('x-csrf-token'), isFalse);
      for (final k in ['POST /invites', 'PATCH /me', 'DELETE /devices/x']) {
        expect(server.anfragen(k).single.headers['x-csrf-token'], 'csrf-abc', reason: k);
      }
      expect(server.log.every((r) => !r.headers.containsKey('authorization')), isTrue);
    });

    test('Anmeldung ohne Sitzung sendet kein CSRF-Token, 401 dort ist kein Sitzungsverlust', () async {
      final server = FakeServer()..on('POST /auth/login/password', (_) => fehler(401, 'invalid_credentials'));
      final (client, _) = await angemeldeterClient(server, web: true);
      client.csrfSetzen('csrf-abc');
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;

      await expectLater(
        client.post('/auth/login/password', {'email': 'a@b.de'}, false),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')),
      );
      expect(server.log.single.headers.containsKey('x-csrf-token'), isFalse);
      expect(verloren, isFalse);
    });

    test('401 an geschützter Stelle meldet den Sitzungsverlust', () async {
      final server = FakeServer()..on('GET /me', (_) => fehler(401, 'unauthenticated'));
      final (client, _) = await angemeldeterClient(server, web: true);
      SessionLostReason? grund;
      client.onSessionLost = (g) => grund = g;
      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
      expect(grund, SessionLostReason.abgelaufen);
    });

    test('Im Web wird nichts im Token-Speicher abgelegt', () async {
      final server = FakeServer();
      final (client, store) = await angemeldeterClient(server, web: true);
      await client.sitzungUebernehmen(SessionDto.fromJson(webSession()));
      expect(await store.readTokens(), isNull);
    });
  });

  group('App (Bearer + Refresh)', () {
    test('sendet das Access-Token als Bearer-Header, ohne CSRF', () async {
      final server = FakeServer()..json('GET /me', meJson());
      final (client, _) = await angemeldeterClient(server);
      await client.get('/me');
      expect(server.log.single.headers['authorization'], 'Bearer access-1');
      expect(server.log.single.headers.containsKey('x-csrf-token'), isFalse);
    });

    test('ohne gespeicherte Token: kein Netzaufruf, nichtAngemeldet', () async {
      final server = FakeServer();
      final client = ApiClient(client: server.client, store: MemoryTokenStore(), web: false, base: 'https://familie.test');
      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
      expect(server.log, isEmpty);
    });

    test('abgelaufenes Access-Token wird vor dem Aufruf erneuert und das neue Paar gespeichert', () async {
      final server = FakeServer()
        ..on('POST /auth/refresh', (r) {
          expect(r.json, {'refreshToken': 'refresh-1', 'deviceId': fixDevice});
          return jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')});
        })
        ..json('GET /me', meJson());
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      await client.get('/me');

      expect(server.log.map((r) => r.key), ['POST /auth/refresh', 'GET /me']);
      expect(server.anfragen('GET /me').single.headers['authorization'], 'Bearer access-2');
      final t = (await store.readTokens())!;
      expect((t.accessToken, t.refreshToken), ('access-2', 'refresh-2'));
    });

    test('gleichzeitige Aufrufe teilen sich genau EINE Erneuerung (Refresh-Token wird nie doppelt eingelöst)', () async {
      final freigabe = Completer<void>();
      final eingeloest = <String>[];
      final server = FakeServer()
        ..on('POST /auth/refresh', (r) async {
          eingeloest.add(r.json['refreshToken'] as String);
          await freigabe.future; // Antwort verzögern, damit alle anderen Aufrufer eintreffen
          return jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')});
        })
        ..json('GET /me', meJson())
        ..json('GET /devices', {'devices': []})
        ..json('GET /members', {'members': []});
      final (client, _) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));

      final aufrufe = [client.get('/me'), client.get('/devices'), client.get('/members'), client.get('/me'), client.get('/devices')];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      freigabe.complete();
      await Future.wait(aufrufe);

      expect(eingeloest, ['refresh-1'], reason: 'genau ein Refresh mit dem alten Token');
      expect(server.anfragen('POST /auth/refresh'), hasLength(1));
      // alle fünf Aufrufe liefen mit dem NEUEN Access-Token
      for (final r in server.log.where((r) => r.method == 'GET')) {
        expect(r.headers['authorization'], 'Bearer access-2');
      }
    });

    test('401 trotz gültig geglaubtem Token: einmal erneuern und wiederholen', () async {
      var versuche = 0;
      final server = FakeServer()
        ..on('GET /me', (r) {
          versuche++;
          return r.headers['authorization'] == 'Bearer access-2' ? jsonAntwort(meJson()) : fehler(401, 'unauthenticated');
        })
        ..json('POST /auth/refresh', {'session': appSession(access: 'access-2', refresh: 'refresh-2')});
      final (client, _) = await angemeldeterClient(server);
      await client.get('/me');
      expect(versuche, 2);
      expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    });

    test('Refresh abgelehnt (401): Sitzung verworfen, Token gelöscht, Rückruf abgelaufen', () async {
      final server = FakeServer()..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      SessionLostReason? grund;
      client.onSessionLost = (g) => grund = g;
      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
      expect(grund, SessionLostReason.abgelaufen);
      expect(await store.readTokens(), isNull);
      expect(server.anfragen('GET /me'), isEmpty);
    });

    test('Zeitüberschreitung beim Refresh: NICHT wiederholen, Sitzung verwerfen (Token könnte schon eingelöst sein)', () async {
      final server = FakeServer()..on('POST /auth/refresh', (_) async => throw TimeoutException('keine Antwort'));
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      SessionLostReason? grund;
      client.onSessionLost = (g) => grund = g;

      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'refresh_unsure')));
      expect(grund, SessionLostReason.unsicher);
      expect(await store.readTokens(), isNull);
      expect(server.anfragen('POST /auth/refresh'), hasLength(1), reason: 'kein blindes Wiederholen');
    });

    test('Abbruch mitten in der Übertragung beim Refresh: ebenfalls verwerfen statt wiederholen', () async {
      final server = FakeServer()..on('POST /auth/refresh', (_) async => throw http.ClientException('Connection reset by peer'));
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'refresh_unsure')));
      expect(await store.readTokens(), isNull);
      expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    });

    test('Kein Netz vor dem Senden (Adresse nicht auflösbar): Token bleiben, später erneut versuchen', () async {
      var offline = true;
      final server = FakeServer()
        ..on('POST /auth/refresh', (_) async {
          if (offline) throw VerbindungsaufbauFehler('Failed host lookup: familie.test');
          return jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')});
        })
        ..json('GET /me', meJson());
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;

      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.istNetzwerk, 'netzwerk', isTrue)));
      expect(verloren, isFalse);
      expect((await store.readTokens())!.refreshToken, 'refresh-1');

      offline = false;
      await client.get('/me');
      expect((await store.readTokens())!.refreshToken, 'refresh-2');
    });

    test('429 beim Refresh: Token bleiben erhalten', () async {
      final server = FakeServer()..on('POST /auth/refresh', (_) => fehler(429, 'rate_limited', retryAfter: 12));
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      await expectLater(client.get('/me'), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.zuVieleAnfragen)));
      expect(await store.readTokens(), isNotNull);
    });

    test('abgelaufenes Refresh-Token: ohne Netzaufruf abmelden', () async {
      final server = FakeServer();
      final store = MemoryTokenStore();
      await store.writeTokens(
        StoredTokens(
          accessToken: 'a',
          accessExpiresAt: DateTime.now().subtract(const Duration(days: 1)),
          refreshToken: 'r',
          refreshExpiresAt: DateTime.now().subtract(const Duration(days: 1)),
          deviceId: fixDevice,
        ),
      );
      final client = ApiClient(client: server.client, store: store, web: false, base: 'https://familie.test');
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;
      await expectLater(client.get('/me'), throwsA(isA<ApiException>()));
      expect(verloren, isTrue);
      expect(server.log, isEmpty);
    });
  });

  group('401-Fachcodes und Sitzungswechsel', () {
    test('step_up_failed (401 mit Fachcode): keine Erneuerung, kein zweiter Versuch, die Sitzung bleibt', () async {
      final server = FakeServer()..on('POST /auth/step-up/code', (_) => fehler(401, 'step_up_failed'));
      final (client, store) = await angemeldeterClient(server);
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;
      await expectLater(
        client.post('/auth/step-up/code', {'totp': '123456'}),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'step_up_failed').having((e) => e.kind, 'kind', ApiErrorKind.sonstiges)),
      );
      expect(server.anfragen('POST /auth/step-up/code'), hasLength(1), reason: 'ein zweiter Versuch zählte doppelt gegen die Sperre');
      expect(server.anfragen('POST /auth/refresh'), isEmpty);
      expect(verloren, isFalse);
      expect((await store.readTokens())!.refreshToken, 'refresh-1');
    });

    test('andere 401-Fachcodes (invalid_credentials) und 401 ohne Code (Proxy-Seite) erneuern nicht und beenden die Sitzung nicht', () async {
      for (final antwort in [fehler(401, 'invalid_credentials'), http.Response('<html>Unauthorized</html>', 401)]) {
        final server = FakeServer()..on('GET /x', (_) => antwort);
        final (client, store) = await angemeldeterClient(server);
        var verloren = false;
        client.onSessionLost = (_) => verloren = true;
        await expectLater(client.get('/x'), throwsA(isA<ApiException>()));
        expect(server.anfragen('GET /x'), hasLength(1));
        expect(server.anfragen('POST /auth/refresh'), isEmpty);
        expect(verloren, isFalse);
        expect(await store.readTokens(), isNotNull);
      }
    });

    test('401 invalid_token: einmal erneuern und wiederholen', () async {
      var n = 0;
      final server = FakeServer()
        ..on('GET /me', (r) => ++n == 1 ? fehler(401, 'invalid_token') : jsonAntwort(meJson()))
        ..json('POST /auth/refresh', {'session': appSession(access: 'access-2', refresh: 'refresh-2')});
      final (client, _) = await angemeldeterClient(server);
      await client.get('/me');
      expect(n, 2);
      expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    });

    test('Abmelden während einer Erneuerung: das Ergebnis wird verworfen, die Token werden nicht zurückgeschrieben', () async {
      final freigabe = Completer<void>();
      final server = FakeServer()
        ..on('POST /auth/refresh', (_) async {
          await freigabe.future;
          return jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')});
        })
        ..json('GET /me', meJson());
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;
      final aufruf = client.get('/me');
      final erwartet = expectLater(aufruf, throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await client.sitzungVerwerfen(); // Person meldet sich ab
      freigabe.complete();
      await erwartet;
      expect(await store.readTokens(), isNull, reason: 'abgemeldet bleibt abgemeldet');
      expect(verloren, isFalse);
      expect(server.anfragen('GET /me'), isEmpty);
    });

    test('Eine alte Erneuerung, die erst nach einer neuen Anmeldung scheitert, beendet die neue Sitzung nicht', () async {
      final freigabe = Completer<void>();
      final server = FakeServer()
        ..on('POST /auth/refresh', (_) async {
          await freigabe.future;
          return fehler(401, 'invalid_token');
        })
        ..json('GET /me', meJson());
      final (client, store) = await angemeldeterClient(server, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;
      final aufruf = client.get('/me');
      final erwartet = expectLater(aufruf, throwsA(isA<ApiException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await client.sitzungUebernehmen(SessionDto.fromJson(appSession(access: 'neu-a', refresh: 'neu-r'))); // Personenwechsel
      freigabe.complete();
      await erwartet;
      expect(verloren, isFalse);
      expect((await store.readTokens())!.refreshToken, 'neu-r');
    });

    test('Eine späte 401-Antwort einer alten Sitzung beendet die neue Sitzung nicht (Web)', () async {
      final freigabe = Completer<void>();
      final server = FakeServer()
        ..on('GET /me', (_) async {
          await freigabe.future;
          return fehler(401, 'unauthenticated');
        });
      final (client, _) = await angemeldeterClient(server, web: true);
      var verloren = false;
      client.onSessionLost = (_) => verloren = true;
      final erwartet = expectLater(client.get('/me'), throwsA(isA<ApiException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await client.sitzungUebernehmen(SessionDto.fromJson(webSession()));
      freigabe.complete();
      await erwartet;
      expect(verloren, isFalse);
    });
  });

  group('Fehlerabbildung', () {
    Future<ApiException> fehlerVon(http.Response Function(Req) h, {bool auth = false}) async {
      final server = FakeServer()..on('POST /x', h);
      final (client, _) = await angemeldeterClient(server, web: true);
      try {
        await client.post('/x', {}, auth);
      } on ApiException catch (e) {
        return e;
      }
      fail('Fehler erwartet');
    }

    test('429 mit Retry-After: Wartehinweis mit Sekunden', () async {
      final e = await fehlerVon((_) => fehler(429, 'rate_limited', retryAfter: 30));
      expect(e.kind, ApiErrorKind.zuVieleAnfragen);
      expect(e.retryAfter, const Duration(seconds: 30));
      expect(e.message, contains('30 Sekunden'));
    });

    test('too_many_attempts (Sperre nach Fehlversuchen) ist ebenfalls ein Wartehinweis', () async {
      final e = await fehlerVon((_) => fehler(429, 'too_many_attempts', retryAfter: 60));
      expect(e.kind, ApiErrorKind.zuVieleAnfragen);
      expect(e.message, contains('60 Sekunden'));
    });

    test('503 server_busy', () async {
      final e = await fehlerVon((_) => fehler(503, 'server_busy', retryAfter: 5));
      expect(e.kind, ApiErrorKind.serverBusy);
      expect(e.message, contains('ausgelastet'));
      expect(e.retryAfter, const Duration(seconds: 5));
    });

    test('403 step_up_required', () async {
      final e = await fehlerVon((_) => fehler(403, 'step_up_required'));
      expect(e.istStepUp, isTrue);
    });

    test('403 account_pending', () async {
      final e = await fehlerVon((_) => fehler(403, 'account_pending'));
      expect(e.kind, ApiErrorKind.kontoWartet);
      expect(e.message, contains('Freigabe'));
    });

    test('bekannte Codes liefern feste deutsche Texte, nie die Meldung des Servers', () async {
      for (final (status, code) in [
        (401, 'invalid_credentials'),
        (400, 'invite_invalid'),
        (400, 'weak_password'),
        (400, 'invalid_code'),
        (409, 'last_admin'),
        (409, 'last_credential'),
        (409, 'no_passkey'),
        (409, 'passkey_exists'),
        (409, 'not_pending'),
        (409, 'cannot_remove_self'),
        (409, 'invite_not_open'),
        (403, 'forbidden'),
        (403, 'csrf_invalid'),
      ]) {
        final e = await fehlerVon((_) => fehler(status, code, message: 'INTERN: SELECT * FROM users'));
        expect(e.message, isNot(contains('INTERN')), reason: code);
        expect(e.message, isNotEmpty, reason: code);
        expect(e.message, isNot('Das ist so gerade nicht möglich.'), reason: 'Code $code braucht einen eigenen Text');
        expect(e.code, code);
      }
    });

    test('unbekannter Code und 500: allgemeine Meldung ohne Interna', () async {
      final e = await fehlerVon((_) => fehler(500, 'irgendwas_neues', message: 'Stacktrace at Foo.bar'));
      expect(e.message, 'Auf dem Server ist ein Fehler aufgetreten. Bitte versuche es später erneut.');
    });

    test('kein JSON im Fehlerfall (z. B. Proxy-Seite) wird sauber abgefangen', () async {
      final e = await fehlerVon((_) => http.Response('<html>Bad Gateway</html>', 502));
      expect(e.status, 502);
      expect(e.message, isNot(contains('html')));
    });

    test('Netzwerkfehler und Zeitüberschreitung', () async {
      final server = FakeServer()
        ..on('GET /a', (_) async => throw http.ClientException('Connection refused'))
        ..on('GET /b', (_) async => throw TimeoutException('x'));
      final (client, _) = await angemeldeterClient(server, web: true);
      await expectLater(client.get('/a'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network')));
      await expectLater(client.get('/b'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'timeout')));
    });

    test('Erfolgsantwort, die kein Objekt ist, ist ein Protokollfehler', () async {
      final server = FakeServer()..on('GET /liste', (_) => jsonAntwort([1, 2]));
      final (client, _) = await angemeldeterClient(server, web: true);
      await expectLater(client.get('/liste'), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.protokoll)));
    });
  });

  test('vorDemSenden entscheidet nach dem Typ der Ausnahme, nie nach dem Text', () {
    expect(vorDemSenden(VerbindungsaufbauFehler('irgendein Text')), isTrue);
    // gleicher Text wie ein Verbindungsfehler, aber kein VerbindungsaufbauFehler: unklarer Ausgang
    expect(vorDemSenden(http.ClientException('Failed host lookup: x')), isFalse);
    expect(vorDemSenden(http.ClientException('Connection refused')), isFalse);
    expect(vorDemSenden(http.ClientException('Connection reset by peer')), isFalse);
    expect(vorDemSenden(http.ClientException('Connection closed before full header was received')), isFalse);
    expect(vorDemSenden(TimeoutException('x')), isFalse);
    expect(vorDemSenden(StateError('x')), isFalse);
  });
}
