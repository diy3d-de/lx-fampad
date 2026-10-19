// PhasenClient (Android): Fehler beim Verbindungsaufbau sind von späteren Fehlern unterscheidbar, ohne den Meldungstext zu lesen.
// Echte Sockets auf 127.0.0.1 (plain test(), kein Widget-Test).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/http_client_io.dart';

void main() {
  late http.Client client;

  setUp(() => client = neuerHttpClient());
  tearDown(() => client.close());

  test('Verbindung abgelehnt (nichts hört am Port): VerbindungsaufbauFehler, also sicher vor dem Senden', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    Object? fehler;
    try {
      await client.post(Uri.parse('http://127.0.0.1:$port/api/v1/auth/refresh'), body: '{}');
    } catch (e) {
      fehler = e;
    }
    expect(fehler, isA<VerbindungsaufbauFehler>());
    expect(vorDemSenden(fehler!), isTrue);
  });

  test('Adresse nicht auflösbar: VerbindungsaufbauFehler', () async {
    Object? fehler;
    try {
      await client.get(Uri.parse('http://gibt-es-nicht.invalid/'));
    } catch (e) {
      fehler = e;
    }
    expect(fehler, isA<VerbindungsaufbauFehler>());
  });

  test('Der Server nimmt die Verbindung an und bricht ab, bevor er antwortet: ClientException, aber NICHT sicher vor dem Senden', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      await req.drain<void>();
      final socket = await req.response.detachSocket(writeHeaders: false);
      socket.destroy(); // Abbruch ohne Antwort
    });
    Object? fehler;
    try {
      await client.post(Uri.parse('http://127.0.0.1:${server.port}/x'), body: '{}');
    } catch (e) {
      fehler = e;
    }
    expect(fehler, isA<http.ClientException>());
    expect(fehler, isNot(isA<VerbindungsaufbauFehler>()));
    expect(vorDemSenden(fehler!), isFalse);
  });

  test('normale Antwort: Status, Kopfzeilen und Inhalt kommen unverändert an', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      req.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..headers.set('retry-after', '7')
        ..write(jsonEncode({'error': 'step_up_failed', 'echo': body, 'auth': req.headers.value('authorization')}));
      await req.response.close();
    });
    final res = await client.post(
      Uri.parse('http://127.0.0.1:${server.port}/x'),
      headers: {'authorization': 'Bearer abc', 'content-type': 'application/json'},
      body: '{"a":1}',
    );
    expect(res.statusCode, 401);
    expect(res.headers['retry-after'], '7');
    final d = jsonDecode(res.body) as Map<String, dynamic>;
    expect(d, {'error': 'step_up_failed', 'echo': '{"a":1}', 'auth': 'Bearer abc'});
  });

  test('Antwort-Zeitlimit ist getrennt: ein schweigender Server ergibt TimeoutException (unklar), nicht VerbindungsaufbauFehler', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      await req.drain<void>();
      // keine Antwort
    });
    Object? fehler;
    try {
      await client.get(Uri.parse('http://127.0.0.1:${server.port}/x')).timeout(const Duration(milliseconds: 300));
    } catch (e) {
      fehler = e;
    }
    expect(fehler, isA<TimeoutException>());
    expect(vorDemSenden(fehler!), isFalse);
  });
}
