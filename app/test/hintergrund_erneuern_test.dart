// Hintergrund-Client (refreshErlaubt: false + hintergrundErneuern: true): erneuert ein abgelaufenes Zugangstoken genau einmal, und zwei Clients auf
// derselben Token-Ablage (Hintergrund-Engine und App) lösen das Refresh-Token nie doppelt ein. Echter ApiClient gegen den Fake-Server.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/token_store.dart';

import 'support/fake_server.dart';

const _kurz = Duration(milliseconds: 5);

StoredTokens _tokens({required String access, required String refresh, required DateTime accessBis}) => StoredTokens(
  accessToken: access,
  accessExpiresAt: accessBis,
  refreshToken: refresh,
  refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
  deviceId: fixDevice,
);

ApiClient _client(FakeServer s, MemoryTokenStore store, {bool hintergrund = true, Duration dauer = const Duration(seconds: 30)}) => ApiClient(
  client: s.client,
  store: store,
  web: false,
  base: 'https://familie.test',
  refreshErlaubt: !hintergrund,
  hintergrundErneuern: hintergrund,
  sperreDauer: dauer,
  sperreAbstand: _kurz,
);

/// Server mit echter Rotation: ein Refresh-Token gilt genau einmal, jede Wiederverwendung wäre ein Familien-Widerruf.
FakeServer _server({Duration verzoegerung = Duration.zero}) {
  final eingeloest = <String>[];
  return FakeServer()
    ..on('POST /auth/refresh', (r) async {
      final t = r.json['refreshToken'] as String;
      if (eingeloest.contains(t) || t != 'refresh-1') return fehler(401, 'invalid_token');
      eingeloest.add(t);
      if (verzoegerung > Duration.zero) await Future<void>.delayed(verzoegerung);
      return jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')});
    })
    ..json('GET /me', meJson());
}

Future<MemoryTokenStore> _abgelaufen() async {
  final store = MemoryTokenStore();
  await store.writeTokens(_tokens(access: 'access-1', refresh: 'refresh-1', accessBis: DateTime.now().subtract(const Duration(minutes: 1))));
  return store;
}

Matcher _kind(ApiErrorKind k) => throwsA(isA<ApiException>().having((e) => e.kind, 'kind', k));

void main() {
  test('abgelaufen: genau ein Refresh, danach läuft die Anfrage mit dem neuen Token', () async {
    final server = _server();
    final store = await _abgelaufen();
    final c = _client(server, store);
    await c.get('/me');
    await c.get('/me');
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    expect(server.anfragen('GET /me').map((r) => r.headers['authorization']), everyElement('Bearer access-2'));
    expect((await store.readTokens())!.refreshToken, 'refresh-2');
    expect(await store.readErneuerungsSperre(), isNull, reason: 'Sperre wieder frei');
  });

  test('ohne hintergrundErneuern bleibt es beim alten Verhalten: kein Refresh, zugangAbgelaufen', () async {
    final server = _server();
    final store = await _abgelaufen();
    final c = ApiClient(client: server.client, store: store, web: false, base: 'https://familie.test', refreshErlaubt: false);
    await expectLater(c.get('/me'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'access_expired')));
    expect(server.log, isEmpty);
  });

  test('Refresh abgelehnt: ehrlicher Fehler (nichtAngemeldet), kein zweiter Versuch im selben Lauf', () async {
    final server = FakeServer()
      ..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'))
      ..json('GET /me', meJson());
    final store = await _abgelaufen();
    final c = _client(server, store);
    for (var i = 0; i < 3; i++) {
      await expectLater(c.get('/me'), _kind(ApiErrorKind.nichtAngemeldet));
    }
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    expect(server.anfragen('GET /me'), isEmpty);
  });

  test('Netzfehler beim Erneuern: Verbindungsfehler, Token unangetastet, kein Wiederholen', () async {
    final server = FakeServer()
      ..on('POST /auth/refresh', (_) async => throw VerbindungsaufbauFehler('kein Netz'))
      ..json('GET /me', meJson());
    final store = await _abgelaufen();
    final c = _client(server, store);
    await expectLater(c.get('/me'), _kind(ApiErrorKind.netzwerk));
    await expectLater(c.get('/me'), _kind(ApiErrorKind.netzwerk));
    expect((await store.readTokens())!.refreshToken, 'refresh-1');
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    expect(await store.readErneuerungsSperre(), isNull);
  });

  test('401 trotz gültiger Uhr: einmal erneuern und wiederholen, nie öfter', () async {
    var me = 0;
    final server = _server()
      ..on('GET /me', (r) {
        me++;
        return r.headers['authorization'] == 'Bearer access-2' ? jsonAntwort(meJson()) : fehler(401, 'invalid_token');
      });
    final store = MemoryTokenStore();
    await store.writeTokens(_tokens(access: 'access-1', refresh: 'refresh-1', accessBis: DateTime.now().add(const Duration(minutes: 10))));
    await _client(server, store).get('/me');
    expect(me, 2);
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
  });

  test('zwei Clients, gleiche Ablage, gleichzeitig: genau ein Refresh am Server, beide enden mit dem neuen Token', () async {
    final server = _server(verzoegerung: const Duration(milliseconds: 60));
    final store = await _abgelaufen();
    final a = _client(server, store);
    final b = _client(server, store, hintergrund: false); // die App
    await Future.wait([a.get('/me'), b.get('/me')]);
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    expect(server.anfragen('GET /me').map((r) => r.headers['authorization']), everyElement('Bearer access-2'));
    expect((await store.readTokens())!.refreshToken, 'refresh-2');
    expect(await store.readErneuerungsSperre(), isNull);
  });

  test('die andere Seite hat schon erneuert (Cache veraltet): neue Token übernehmen, kein Refresh', () async {
    final server = _server();
    final store = await _abgelaufen();
    final a = _client(server, store);
    expect(await a.hatGespeicherteToken(), isTrue); // Cache mit refresh-1
    await store.writeTokens(_tokens(access: 'access-9', refresh: 'refresh-9', accessBis: DateTime.now().add(const Duration(minutes: 14))));
    await a.zugangErneuern();
    await a.get('/me');
    expect(server.anfragen('POST /auth/refresh'), isEmpty);
    expect(server.anfragen('GET /me').single.headers['authorization'], 'Bearer access-9');
    expect((await store.readTokens())!.refreshToken, 'refresh-9');
  });

  test('fremde Sperre läuft, die andere Seite erneuert: warten, dann deren Token übernehmen', () async {
    final server = _server();
    final store = await _abgelaufen();
    await store.writeErneuerungsSperre(ErneuerungsSperre('anderer', DateTime.now().add(const Duration(seconds: 20))));
    final a = _client(server, store);
    final lauf = a.get('/me');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // die andere Seite ist fertig: neue Token zuerst, dann die Sperre frei
    await store.writeTokens(_tokens(access: 'access-9', refresh: 'refresh-9', accessBis: DateTime.now().add(const Duration(minutes: 14))));
    await store.clearErneuerungsSperre('anderer');
    await lauf;
    expect(server.anfragen('POST /auth/refresh'), isEmpty);
    expect(server.anfragen('GET /me').single.headers['authorization'], 'Bearer access-9');
  });

  test('abgelaufene Sperre einer abgestürzten Seite wird übernommen', () async {
    final server = _server();
    final store = await _abgelaufen();
    await store.writeErneuerungsSperre(ErneuerungsSperre('tot', DateTime.now().subtract(const Duration(seconds: 5))));
    await _client(server, store).get('/me');
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    expect(await store.readErneuerungsSperre(), isNull);
  });

  test('Sperre, die nie frei wird: Verbindungsfehler nach Ablauf der Wartefrist, Token unangetastet', () async {
    final server = _server();
    final store = await _abgelaufen();
    await store.writeErneuerungsSperre(ErneuerungsSperre('haengt', DateTime.now().add(const Duration(hours: 1))));
    final c = _client(server, store, dauer: const Duration(milliseconds: 50));
    await expectLater(c.get('/me'), _kind(ApiErrorKind.netzwerk));
    expect(server.anfragen('POST /auth/refresh'), isEmpty);
    expect((await store.readTokens())!.refreshToken, 'refresh-1');
  });

  test('Ablehnung, weil jemand anderes inzwischen erneuert hat: dessen Token bleiben, keine Abmeldung', () async {
    final store = await _abgelaufen();
    final server = FakeServer()
      ..on('POST /auth/refresh', (_) async {
        // die andere Seite schreibt ihre Token, während unsere Anfrage läuft, und der Server lehnt unser (verbrauchtes) Token ab
        await store.writeTokens(_tokens(access: 'access-9', refresh: 'refresh-9', accessBis: DateTime.now().add(const Duration(minutes: 14))));
        return fehler(401, 'invalid_token');
      })
      ..json('GET /me', meJson());
    final c = _client(server, store);
    var verloren = false;
    c.onSessionLost = (_) => verloren = true;
    await c.get('/me');
    expect(verloren, isFalse);
    expect((await store.readTokens())!.refreshToken, 'refresh-9');
    expect(server.anfragen('GET /me').single.headers['authorization'], 'Bearer access-9');
  });

  test('ein neueres Token in der Ablage wird nie überschrieben', () async {
    final store = await _abgelaufen();
    final server = _server();
    await _client(server, store).get('/me');
    expect((await store.readTokens())!.refreshToken, 'refresh-2');
    // ein späterer Lauf mit gültigem Token erneuert nichts und lässt die Ablage in Ruhe
    await store.writeTokens(_tokens(access: 'access-7', refresh: 'refresh-7', accessBis: DateTime.now().add(const Duration(minutes: 14))));
    await _client(server, store).get('/me');
    expect(server.anfragen('POST /auth/refresh'), hasLength(1));
    expect((await store.readTokens())!.refreshToken, 'refresh-7');
  });
}
