// tus-Client (Abschnitt 6n) gegen den Fake-Server der Dateiablage: Anlegen mit Metadaten, Abschnitte von höchstens 4 MiB, Fortsetzen über HEAD nach einem Abbruch, Versatz (409), die Fehlercodes des
// Servers (413, 422, 423, 429, 503 finalize_failed, 507, 404) und Abbrechen. Dateiinhalte und Namen erscheinen nie in Meldungen.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/dateien/tus_client.dart';
import 'package:lx_fampad/data/dateien/upload_quelle.dart';

import 'support/datei_welt.dart';
import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

Uint8List bytes(int n, [int seed = 1]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 255]);

const mib4 = 4194304;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeServer server;
  late FakeDateien welt;
  late TusClient tus;
  final pausen = <Duration>[];

  setUp(() async {
    server = FakeServer();
    welt = FakeDateien(server, FakeSyncServer());
    final tokens = MemoryTokenStore();
    await tokens.writeTokens(StoredTokens(accessToken: 'person-mama', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'r', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: 'g1'));
    welt.rollen['person-mama'] = Role.parent;
    pausen.clear();
    tus = TusClient(ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test'), schlaf: (d) async => pausen.add(d));
  });

  group('Anlegen und Hochladen', () {
    test('OPTIONS nennt die größte Übertragung', () async {
      expect(await tus.maxGroesse(), welt.maxE2eeBytes);
    });

    test('Anlegen: Länge und Metadaten (base64) gehen mit, die Upload-ID ist die Blob-ID', () async {
      final id = await tus.anlegen(laenge: 5000, metadaten: {'modus': 'server', 'kind': 'datei', 'mime': 'text/plain'});
      expect(welt.blobs[id]!.laenge, 5000);
      expect(welt.blobs[id]!.mime, 'text/plain');
      expect(welt.blobs[id]!.modus, 'server');
      final r = server.anfragen('POST /uploads').single;
      expect(r.headers['tus-resumable'], '1.0.0');
      expect(r.headers['authorization'], 'Bearer person-mama');
      expect(r.headers['upload-metadata'], contains('modus ${base64.encode(utf8.encode('server'))}'));
      expect(RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$').hasMatch(id), isTrue);
      expect(TusClient.metadatenKopf({'a': 'ä'}), 'a ${base64.encode(utf8.encode('ä'))}');
    });

    test('9 MiB: Abschnitte von 4 MiB, 4 MiB und dem Rest; Ergebnis mit Blob-ID und SHA-256 des Servers; Fortschritt wächst', () async {
      final daten = bytes(2 * mib4 + 12345);
      final id = await tus.anlegen(laenge: daten.length, metadaten: {'modus': 'server'});
      final stand = <int>[];
      final r = await tus.hochladen(id, UploadQuelle.ausBytes(daten), fortschritt: stand.add);
      expect(welt.patchLaengen, [mib4, mib4, 12345]);
      expect(stand, [mib4, 2 * mib4, daten.length]);
      expect(r.blobId, id);
      expect(r.sha256, c.sha256.convert(daten).toString());
      expect(welt.blobs[id]!.zustand, 'ready');
      expect(welt.blobs[id]!.bytes, daten);
      // jede Anfrage trägt Offset und Content-Type
      final patches = server.anfragen('PATCH /uploads/$id');
      expect(patches.map((p) => p.headers['upload-offset']), ['0', '$mib4', '${2 * mib4}']);
      expect(patches.first.headers['content-type'], 'application/offset+octet-stream');
    });

    test('genau ein Abschnitt: eine Datei von exakt 4 MiB braucht EINEN Abschnitt, 4 MiB + 1 zwei', () async {
      for (final (laenge, erwartet) in [(mib4, [mib4]), (mib4 + 1, [mib4, 1]), (1, [1])]) {
        welt.patchLaengen.clear();
        final id = await tus.anlegen(laenge: laenge);
        await tus.hochladen(id, UploadQuelle.ausBytes(bytes(laenge)));
        expect(welt.patchLaengen, erwartet, reason: '$laenge Byte');
      }
    });

    test('eine größere Abschnittsgröße als 4 MiB wird auf 4 MiB begrenzt, eine kleinere gilt', () async {
      final t = TusClient(tus.api, abschnitt: 10 * mib4);
      expect(t.abschnitt, mib4);
      final klein = TusClient(tus.api, abschnitt: 1000);
      final id = await klein.anlegen(laenge: 2500);
      await klein.hochladen(id, UploadQuelle.ausBytes(bytes(2500)));
      expect(welt.patchLaengen, [1000, 1000, 500]);
    });

    test('eine leere Datei wird gar nicht erst angelegt', () async {
      await expectLater(tus.anlegen(laenge: 0), throwsA(isA<TusFehler>().having((e) => e.folge, 'folge', TusFolge.aufgeben)));
      expect(server.anfragen('POST /uploads'), isEmpty);
    });

    test('HEAD nennt Stand und Länge', () async {
      final id = await tus.anlegen(laenge: 100);
      final s = await tus.status(id);
      expect((s.offset, s.laenge, s.fertig), (0, 100, false));
      await tus.hochladen(id, UploadQuelle.ausBytes(bytes(100)));
      expect((await tus.status(id)).fertig, isTrue);
    });
  });

  group('Fortsetzen', () {
    test('nach einem Verbindungsabbruch fragt HEAD den Stand ab, der Upload macht dort weiter (nichts wird doppelt gesendet)', () async {
      final daten = bytes(2 * mib4 + 500);
      final id = await tus.anlegen(laenge: daten.length);
      // der zweite Abschnitt scheitert mit einem Abbruch der Verbindung
      var n = 0;
      welt.einspritzen((r) => r.method == 'PATCH' && ++n == 2, (r) => throw http.ClientException('Abbruch'));
      await expectLater(tus.hochladen(id, UploadQuelle.ausBytes(daten)), throwsA(isA<TusFehler>().having((e) => e.folge, 'folge', TusFolge.spaeter).having((e) => e.code, 'code', 'network')));
      expect(welt.blobs[id]!.offset, mib4);
      final s = await tus.status(id);
      expect(s.offset, mib4);
      final r = await tus.hochladen(id, UploadQuelle.ausBytes(daten), ab: s.offset);
      expect(r.sha256, c.sha256.convert(daten).toString());
      expect(welt.blobs[id]!.bytes, daten);
      expect(welt.patchLaengen, [mib4, mib4, 500]); // der abgebrochene Abschnitt kam nie an
    });

    test('falscher Versatz (409): der Client richtet sich nach dem Stand des Servers', () async {
      final daten = bytes(mib4 + 1000);
      final id = await tus.anlegen(laenge: daten.length);
      await tus.hochladen(id, UploadQuelle.ausBytes(daten.sublist(0, mib4)).let((q) => _Kuerzer(q, daten.length)), ab: 0).catchError((Object _) => const TusErgebnis('', null)); // erster Abschnitt kommt an
      expect(welt.blobs[id]!.offset, mib4);
      // der Client glaubt, er stehe bei 0: der Server meldet 409 mit seinem Stand, der Client macht bei 4 MiB weiter
      final r = await tus.hochladen(id, UploadQuelle.ausBytes(daten), ab: 0);
      expect(welt.blobs[id]!.bytes, daten);
      expect(r.blobId, id);
    });

    test('ein dauerhaft falscher Versatz endet nach wenigen Versuchen mit einem Fehler (keine Endlosschleife)', () async {
      final id = await tus.anlegen(laenge: 100);
      welt.einspritzen((r) => r.method == 'PATCH', (r) => http.Response(jsonEncode({'error': 'offset_mismatch'}), 409, headers: {'upload-offset': '0', 'tus-resumable': '1.0.0'}), mal: 50);
      await expectLater(tus.hochladen(id, UploadQuelle.ausBytes(bytes(100))), throwsA(isA<TusFehler>().having((e) => e.status, 'status', 409)));
      expect(server.anfragen('PATCH /uploads/$id').length, lessThanOrEqualTo(7));
    });

    test('ein Upload, der nur noch abzuschließen ist, wird mit einem leeren PATCH abgeschlossen', () async {
      final daten = bytes(5000);
      final id = await tus.anlegen(laenge: daten.length);
      // der Abschluss scheitert einmal mit 503 finalize_failed: der Upload bleibt abschließbar
      welt.einspritzen((r) => r.method == 'PATCH' && r.body is Uint8List && (r.body as Uint8List).isNotEmpty, (r) => http.Response(jsonEncode({'error': 'finalize_failed'}), 503, headers: {'tus-resumable': '1.0.0'}));
      // der Fake legt die Bytes bei dieser Einspritzung nicht ab: erst eine zweite Übertragung stellt den Stand her
      welt.blobs[id]!.daten.add(daten);
      final r = await tus.hochladen(id, UploadQuelle.ausBytes(daten), ab: 0);
      expect(welt.blobs[id]!.zustand, 'ready');
      expect(r.blobId, id);
    });
  });

  group('Fehlercodes des Servers', () {
    Future<TusFehler> fehlerBei(Future<Object?> Function() f) async {
      try {
        await f();
      } on TusFehler catch (e) {
        return e;
      }
      fail('es wurde kein TusFehler geworfen');
    }

    test('413 file_too_large: endgültig, verständliche Meldung ohne Servertext', () async {
      final e = await fehlerBei(() => tus.anlegen(laenge: welt.maxDateiBytes + 1, metadaten: {'modus': 'server'}));
      expect((e.code, e.folge, e.status), ('file_too_large', TusFolge.aufgeben, 413));
      expect(e.meldung, contains('größer als erlaubt'));
      expect(e.meldung, isNot(contains('Text des Servers')));
    });

    test('413 quota_exceeded: endgültig (Speicher voll)', () async {
      welt.kontingent = 1000;
      final e = await fehlerBei(() => tus.anlegen(laenge: 2000));
      expect((e.code, e.folge), ('quota_exceeded', TusFolge.aufgeben));
      expect(e.meldung, contains('Speicher'));
    });

    test('507 insufficient_storage: endgültig', () async {
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'insufficient_storage'}), 507));
      final e = await fehlerBei(() => tus.anlegen(laenge: 10));
      expect((e.code, e.folge), ('insufficient_storage', TusFolge.aufgeben));
    });

    test('422 mime_mismatch: endgültig, der Server hat nichts abgelegt', () async {
      final id = await tus.anlegen(laenge: 100, metadaten: {'modus': 'server', 'mime': 'image/png'});
      final e = await fehlerBei(() => tus.hochladen(id, UploadQuelle.ausBytes(bytes(100))));
      expect((e.status, e.folge), (422, TusFolge.aufgeben));
      expect(welt.blobs.containsKey(id), isFalse);
    });

    test('423 locked: kurz warten und weiter (höchstens drei Mal)', () async {
      final id = await tus.anlegen(laenge: 100);
      welt.einspritzen((r) => r.method == 'PATCH', (r) => http.Response(jsonEncode({'error': 'locked'}), 423), mal: 2);
      final r = await tus.hochladen(id, UploadQuelle.ausBytes(bytes(100)));
      expect(r.blobId, id);
      expect(pausen, hasLength(2));
      // dauerhaft gesperrt: nach drei Wiederholungen ein Fehler "später"
      final id2 = await tus.anlegen(laenge: 100);
      welt.einspritzen((r) => r.method == 'PATCH', (r) => http.Response(jsonEncode({'error': 'locked'}), 423), mal: 20);
      final e = await fehlerBei(() => tus.hochladen(id2, UploadQuelle.ausBytes(bytes(100))));
      expect((e.status, e.folge), (423, TusFolge.spaeter));
    });

    test('429 mit Retry-After: später, mit der Wartezeit des Servers', () async {
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'too_many_uploads'}), 429, headers: {'retry-after': '42'}));
      final e = await fehlerBei(() => tus.anlegen(laenge: 10));
      expect((e.code, e.folge, e.warte), ('too_many_uploads', TusFolge.spaeter, const Duration(seconds: 42)));
    });

    test('503 finalize_failed beim letzten Abschnitt: der Client schließt erneut ab', () async {
      final daten = bytes(3000);
      final id = await tus.anlegen(laenge: daten.length);
      var erster = true;
      // das letzte Byte kommt an, die Antwort ist 503: ein leeres PATCH schließt ab (der Fake schließt beim ersten Mal wirklich ab)
      welt.einspritzen(
        (r) => r.method == 'PATCH' && erster && r.body is Uint8List && (r.body as Uint8List).isNotEmpty,
        (r) {
          erster = false;
          welt.blobs[id]!.daten.add(r.body as Uint8List);
          return http.Response(jsonEncode({'error': 'finalize_failed'}), 503, headers: {'tus-resumable': '1.0.0'});
        },
      );
      welt.einspritzen((r) => r.method == 'PATCH' && r.body == null, (r) {
        final b = welt.blobs[id]!;
        b
          ..zustand = 'ready'
          ..sha256 = c.sha256.convert(b.bytes).toString();
        return http.Response('', 204, headers: {'tus-resumable': '1.0.0', 'upload-offset': '${b.laenge}', 'upload-blob-id': id, 'upload-sha256': b.sha256!});
      });
      final r = await tus.hochladen(id, UploadQuelle.ausBytes(daten));
      expect(r.blobId, id);
      expect(r.sha256, c.sha256.convert(daten).toString());
    });

    test('503 server_busy und 5xx: später mit Wartezeit; Wartung als eigener Code', () async {
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'server_busy'}), 503, headers: {'retry-after': '5'}));
      var e = await fehlerBei(() => tus.anlegen(laenge: 10));
      expect((e.code, e.folge, e.warte), ('server_busy', TusFolge.spaeter, const Duration(seconds: 5)));
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'maintenance'}), 503));
      e = await fehlerBei(() => tus.anlegen(laenge: 10));
      expect((e.code, e.folge), ('maintenance', TusFolge.spaeter));
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response('Bad Gateway', 502));
      e = await fehlerBei(() => tus.anlegen(laenge: 10));
      expect(e.folge, TusFolge.spaeter);
    });

    test('404: der Upload ist beim Server weg (24 Stunden), er wird neu begonnen', () async {
      final e = await fehlerBei(() => tus.status('00000000-0000-4000-8000-000000000000'));
      expect((e.status, e.folge), (404, TusFolge.neuBeginnen));
    });

    test('Netzfehler: später, ohne Text des Systems', () async {
      welt.einspritzen((r) => r.method == 'POST', (r) => throw http.ClientException('SocketException: secret.host'));
      final e = await fehlerBei(() => tus.anlegen(laenge: 10));
      expect((e.code, e.folge), ('network', TusFolge.spaeter));
      expect(e.meldung, isNot(contains('secret')));
    });

    test('eine abgelaufene Sitzung bleibt ein Fehler der Sitzung (kein Upload-Fehler)', () async {
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'unauthenticated'}), 401, headers: {'content-type': 'application/json'}));
      // web: Cookie-Sitzung ohne Token: 401 mit Sitzungscode wird zu nichtAngemeldet
      final webClient = TusClient(ApiClient(client: server.client, store: MemoryTokenStore(), web: true, base: 'https://familie.test'));
      await expectLater(webClient.anlegen(laenge: 10), throwsA(isA<Exception>().having((e) => e.toString(), 'text', contains('401'))));
    });
  });

  group('Abbrechen', () {
    test('der Abbruch wirkt zwischen zwei Abschnitten; DELETE räumt den Upload beim Server auf', () async {
      final daten = bytes(3 * mib4);
      final id = await tus.anlegen(laenge: daten.length);
      final abbruch = AbbruchToken();
      await expectLater(tus.hochladen(id, UploadQuelle.ausBytes(daten), abbruch: abbruch, fortschritt: (o) => abbruch.abbrechen()), throwsA(isA<TusAbgebrochen>()));
      expect(welt.blobs[id]!.offset, mib4); // nur der erste Abschnitt
      await tus.abbrechen(id);
      expect(welt.blobs.containsKey(id), isFalse);
      await tus.abbrechen(id); // schon weg (404): kein Fehler
    });

    test('ein schon beanspruchter Upload bleibt: 409 upload_claimed ist kein Fehler', () async {
      final id = await tus.anlegen(laenge: 10);
      await tus.hochladen(id, UploadQuelle.ausBytes(bytes(10)));
      welt.blobs[id]!.zustand = 'claimed';
      await tus.abbrechen(id);
      expect(welt.blobs.containsKey(id), isTrue);
    });
  });
}

/// Eine Quelle, die kürzer liefert, als sie angibt: so endet der Upload nach dem ersten Abschnitt (Hilfe für den Versatz-Test).
class _Kuerzer implements UploadQuelle {
  final UploadQuelle _q;
  @override
  final int laenge;
  _Kuerzer(this._q, this.laenge);
  @override
  Future<Uint8List> lies(int von, int bis) async {
    if (von >= _q.laenge) throw StateError('Ende der Quelle');
    return _q.lies(von, bis);
  }

  @override
  Future<void> schliessen() => _q.schliessen();
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
