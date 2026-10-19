// Gemeinsame Test-Hilfen: ein Fake-Server auf Basis von MockClient (keine echten Netzaufrufe) und Beispielantworten
// im Format von docs/API.md bzw. der echten Server-Antworten.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/token_store.dart';

class Req {
  final String method;
  final String path;
  final Map<String, String> headers;
  final Object? body;
  Req(this.method, this.path, this.headers, this.body);

  Map<String, dynamic> get json => body is Map<String, dynamic> ? body as Map<String, dynamic> : <String, dynamic>{};
  String get key => '$method $path';
}

typedef Handler = FutureOr<http.Response> Function(Req req);

http.Response jsonAntwort(Object body, {int status = 200, Map<String, String> headers = const {}}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

http.Response fehler(int status, String code, {String? message, int? retryAfter}) => jsonAntwort(
  {'error': code, 'message': message ?? 'Meldung des Servers, die die App nicht anzeigt'},
  status: status,
  headers: {if (retryAfter != null) 'retry-after': '$retryAfter'},
);

class FakeServer {
  final Map<String, Handler> routes = {};
  final List<Req> log = [];
  late final MockClient client = MockClient((request) async {
    final uri = request.url;
    Object? body;
    if (request.body.isNotEmpty) body = jsonDecode(request.body);
    final req = Req(request.method, uri.path.replaceFirst('/api/v1', ''), request.headers, body);
    log.add(req);
    final h = routes[req.key];
    if (h == null) return fehler(404, 'not_found');
    return await h(req);
  });

  void on(String methodPath, Handler h) => routes[methodPath] = h;

  void json(String methodPath, Object body, {int status = 200}) => routes[methodPath] = (_) => jsonAntwort(body, status: status);

  List<Req> anfragen(String methodPath) => log.where((r) => r.key == methodPath).toList();
}

// ---------------------------------------------------------------------------------------------------- Beispielantworten

const fixIdAdmin = '0f0e0d0c-0b0a-4908-8706-050403020100';
const fixIdKind = '11111111-2222-4333-8444-555555555555';
const fixDevice = '99999999-8888-4777-8666-555555555555';
const fixToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdE';

Map<String, dynamic> userJson({String id = fixIdAdmin, String role = 'admin', String status = 'active', String name = 'Anna', String? email = 'anna@beispiel.de'}) => {
  'id': id,
  'email': email,
  'displayName': name,
  'colorIndex': 3,
  'role': role,
  'status': status,
};

Map<String, dynamic> appSession({String access = 'access-1', String refresh = 'refresh-1', DateTime? accessBis, String deviceId = fixDevice}) => {
  'kind': 'app',
  'accessToken': access,
  'accessExpiresAt': (accessBis ?? DateTime.now().add(const Duration(minutes: 15))).toUtc().toIso8601String(),
  'refreshToken': refresh,
  'refreshExpiresAt': DateTime.now().add(const Duration(days: 90)).toUtc().toIso8601String(),
  'deviceId': deviceId,
};

Map<String, dynamic> webSession() => {
  'kind': 'web',
  'csrfToken': 'csrf-abc',
  'expiresAt': DateTime.now().add(const Duration(days: 30)).toUtc().toIso8601String(),
  'deviceId': fixDevice,
};

Map<String, dynamic> meJson({String role = 'admin', String status = 'active', int passkeys = 1, bool password = false, bool totp = false, String? csrf}) => {
  'user': userJson(role: role, status: status),
  'familyId': 'fa000000-0000-4000-8000-000000000001',
  'session': {'id': 's1', 'deviceId': fixDevice, 'stepUpAt': DateTime.now().toUtc().toIso8601String()},
  'csrfToken': ?csrf,
  'credentials': {'passkeys': passkeys, 'password': password, 'totp': totp},
  'recoveryCodesRemaining': 8,
};

List<String> codes() => [for (var i = 0; i < 10; i++) 'ABCD-EFGH-IJKL-${(1000 + i)}'];

Map<String, dynamic> einladungJson({String id = 'i1', String role = 'child', String status = 'open', bool pin = false, bool approval = false, bool reset = false}) => {
  'id': id,
  'role': role,
  'status': status,
  'createdAt': DateTime.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
  'expiresAt': DateTime.now().add(const Duration(hours: 23)).toUtc().toIso8601String(),
  'hasPin': pin,
  'requireApproval': approval,
  'reset': reset,
  'createdBy': fixIdAdmin,
  'usedBy': null,
};

Map<String, dynamic> neueEinladungJson({bool pin = true}) => {
  'invite': {
    'id': 'i-neu',
    'token': fixToken,
    'link': 'https://familie.lx-labs.dev/#/einladung/$fixToken',
    'pin': ?(pin ? '123456' : null),
    'expiresAt': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String(),
    'requireApproval': false,
  },
};

Map<String, dynamic> webauthnOptionen() => {
  'challenge': 'Y2hhbGxlbmdl',
  'rp': {'name': 'lx-familyhub', 'id': 'familie.lx-labs.dev'},
  'user': {'id': 'dXNlcg', 'name': 'anna@beispiel.de', 'displayName': 'Anna'},
  'pubKeyCredParams': [
    {'alg': -7, 'type': 'public-key'},
    {'alg': -257, 'type': 'public-key'},
  ],
  'timeout': 300000,
  'attestation': 'none',
  'excludeCredentials': [
    {'id': 'Y3JlZA', 'type': 'public-key'},
  ],
  'authenticatorSelection': {'residentKey': 'required', 'userVerification': 'required'},
};

/// Standard-Routen eines angemeldeten Admins (App-Sitzung), Basis für Widget-Tests.
FakeServer standardServer({String role = 'admin'}) {
  final s = FakeServer();
  s.json('GET /me', meJson(role: role, passkeys: 1, password: true, totp: true));
  s.json('GET /members', {
    'members': [
      userJson(),
      userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
      userJson(id: '22222222-3333-4444-8555-666666666666', role: 'child', status: 'pending', name: 'Oma', email: 'oma@beispiel.de'),
    ],
  });
  s.json('GET /invites', {
    'invites': [einladungJson(), einladungJson(id: 'i2', role: 'parent', status: 'expired', approval: true), einladungJson(id: 'i3', status: 'used')],
  });
  s.json('GET /devices', {
    'devices': [
      {'id': fixDevice, 'name': 'Pixel 9', 'platform': 'android', 'appVersion': '0.1.0', 'createdAt': DateTime.now().toUtc().toIso8601String(), 'lastSeenAt': DateTime.now().toUtc().toIso8601String(), 'current': true},
      {'id': 'dddddddd-0000-4000-8000-000000000002', 'name': 'Firefox auf Windows', 'platform': 'web', 'appVersion': null, 'createdAt': DateTime.now().toUtc().toIso8601String(), 'lastSeenAt': null, 'current': false},
    ],
  });
  s.json('GET /me/credentials', {
    'credentials': [
      {'id': 'c1', 'type': 'passkey', 'label': 'Pixel 9', 'createdAt': DateTime.now().toUtc().toIso8601String(), 'lastUsedAt': null},
    ],
  });
  return s;
}

/// Angemeldeter [ApiClient] mit Speicher im Arbeitsspeicher (App-Modus) für Unit-Tests.
Future<(ApiClient, MemoryTokenStore)> angemeldeterClient(
  FakeServer server, {
  DateTime Function()? now,
  DateTime? accessBis,
  bool web = false,
}) async {
  final store = MemoryTokenStore();
  final client = ApiClient(client: server.client, store: store, web: web, base: 'https://familie.test', now: now);
  if (!web) {
    await store.writeTokens(
      StoredTokens(
        accessToken: 'access-1',
        accessExpiresAt: accessBis ?? DateTime.now().add(const Duration(minutes: 15)),
        refreshToken: 'refresh-1',
        refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
        deviceId: fixDevice,
      ),
    );
  }
  return (client, store);
}
