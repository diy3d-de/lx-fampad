// Dateiablage, Zustand (Abschnitt 6n): Gating über `GET /version` (`features.files`), Fortsetzen nach dem Start, Wiper beim Abmelden (Übertragungen enden, Cache und Teil-Dateien weg, Tabellen leer),
// Speichern (Systemdialog/Browser), Vorschau-Zwischenspeicher mit Obergrenzen und die Vorschaubilder der echten Bildverarbeitung (ohne EXIF, höchstens 256 KiB).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/dateien/blob_lader.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/dateien/datei_logik.dart';
import 'package:lx_fampad/data/dateien/datei_modelle.dart';
import 'package:lx_fampad/data/dateien/datei_ort.dart';
import 'package:lx_fampad/data/dateien/datei_ort_io.dart';
import 'package:lx_fampad/data/dateien/datei_speichern.dart';
import 'package:lx_fampad/data/dateien/datei_state.dart';
import 'package:lx_fampad/data/dateien/datei_vorschau.dart';
import 'package:lx_fampad/data/dateien/transfer_dienst.dart';
import 'package:lx_fampad/data/dateien/transfer_modelle.dart';

import 'support/datei_welt.dart';
import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Uint8List bytes(int n, [int seed = 1]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 255]);

/// Ein PNG in der gegebenen Größe mit Rauschen (kaum komprimierbar) oder Farbverlauf.
Future<Uint8List> testBild(int b, int h, {bool rauschen = false}) async {
  final rekorder = ui.PictureRecorder();
  final canvas = ui.Canvas(rekorder);
  if (rauschen) {
    final pixel = Uint8List(b * h * 4);
    var x = 12345;
    for (var i = 0; i < pixel.length; i += 4) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      pixel[i] = x & 255;
      pixel[i + 1] = (x >> 8) & 255;
      pixel[i + 2] = (x >> 16) & 255;
      pixel[i + 3] = 255;
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixel, b, h, ui.PixelFormat.rgba8888, c.complete);
    canvas.drawImage(await c.future, ui.Offset.zero, ui.Paint());
  } else {
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, b.toDouble(), h.toDouble()), ui.Paint()..shader = ui.Gradient.linear(ui.Offset.zero, ui.Offset(b.toDouble(), h.toDouble()), const [Color(0xFFFF0000), Color(0xFF0000FF)]));
  }
  final bild = await rekorder.endRecording().toImage(b, h);
  return (await bild.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<(int, int)> pngMasse(Uint8List png) async {
  final c = await ui.instantiateImageCodec(png);
  final f = await c.getNextFrame();
  return (f.image.width, f.image.height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(testVorbereiten);

  group('Gating über GET /version', () {
    Future<(ProviderContainer, TestUmgebung)> start(WidgetTester tester, {Object? features, bool offline = false, int? status, String rolle = 'admin'}) async {
      final server = standardServer(role: rolle);
      server.on('GET /version', (_) {
        if (offline) throw http.ClientException('offline');
        if (status != null) return fehler(status, 'not_found');
        return jsonAntwort({'service': 'lx-fampad', 'features': ?features});
      });
      final env = TestUmgebung(server);
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      await env.angemeldet();
      final c = await starteApp(tester, env);
      return (c, env);
    }

    testWidgets('Server meldet features.files: der Bereich ist verfügbar, die Antwort wird lokal gemerkt', (tester) async {
      final (c, env) = await start(tester, features: {'files': true});
      expect(await c.read(dateienVerfuegbarProvider.future), isTrue);
      expect(await env.db.metaLesen(kDateienVerfuegbarSchluessel), '1');
    });

    for (final (titel, features, status) in <(String, Object?, int?)>[
      ('features.files = false', {'files': false}, null),
      ('ein Server ohne das Feld files', {'pwBackup': true}, null),
      ('ein älterer Server ohne features', null, null),
      ('404 auf /version', null, 404),
    ]) {
      testWidgets('nicht verfügbar: $titel', (tester) async {
        final (c, env) = await start(tester, features: features, status: status);
        expect(await tester.runAsync(() => c.read(dateienVerfuegbarProvider.future)), isFalse);
        if (status == null) expect(await env.db.metaLesen(kDateienVerfuegbarSchluessel), '0');
      });
    }

    testWidgets('offline gilt die zuletzt bekannte Antwort: der Bereich bleibt sichtbar, wenn der Server ihn zuletzt anbot', (tester) async {
      final (c, env) = await start(tester, features: {'files': true});
      expect(await tester.runAsync(() => c.read(dateienVerfuegbarProvider.future)), isTrue);
      env.server.on('GET /version', (_) => throw http.ClientException('offline'));
      c.invalidate(dateienVerfuegbarProvider);
      expect(await tester.runAsync(() => c.read(dateienVerfuegbarProvider.future)), isTrue);
    });

    testWidgets('offline und nie gefragt: nicht verfügbar', (tester) async {
      final (c, _) = await start(tester, offline: true);
      expect(await tester.runAsync(() => c.read(dateienVerfuegbarProvider.future)), isFalse);
    });

    testWidgets('ohne Anmeldung: nicht verfügbar', (tester) async {
      final server = standardServer();
      server.json('GET /version', {'service': 'lx-fampad', 'features': {'files': true}});
      final env = TestUmgebung(server); // keine Tokens
      final c = ProviderContainer(overrides: env.overrides);
      addTearDown(c.dispose);
      expect(await tester.runAsync(() => c.read(dateienVerfuegbarProvider.future)), isFalse);
    });

    testWidgets('Rechte der Oberfläche: Kind', (tester) async {
      final (c, _) = await start(tester, features: {'files': true}, rolle: 'child');
      expect(c.read(dateiRechteProvider).erwachsen, isFalse);
      expect(c.read(dateiRechteProvider).darfAnlegen('parents'), isFalse);
    });

    testWidgets('Rechte der Oberfläche: Elternteil', (tester) async {
      final (c, _) = await start(tester, features: {'files': true}, rolle: 'parent');
      expect(c.read(dateiRechteProvider).erwachsen, isTrue);
      expect(c.read(dateiRechteProvider).darfAnlegen('parents'), isTrue);
    });

    testWidgets('Nutzung und Kontingent-Anzeige aus `GET /files/usage`', (tester) async {
      final server = standardServer();
      server.json('GET /version', {'service': 'lx-fampad', 'features': {'files': true}});
      server.json('GET /files/usage', {'usedBytes': 5368709120, 'reservedBytes': 0, 'quotaBytes': 10737418240, 'maxFileBytes': 104857600, 'maxE2eeBytes': 105906176, 'chunkBytes': 4194304});
      final env = TestUmgebung(server);
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      await env.angemeldet();
      final c = await starteApp(tester, env);
      final halter = c.listen(dateiNutzungProvider, (_, _) {});
      addTearDown(halter.close);
      final n = await tester.runAsync(() => c.read(dateiNutzungProvider.future));
      expect(n!.belegtBytes, 5368709120);
      expect(c.read(kontingentAnzeigeProvider)!.text, '5 GB von 10 GB belegt');
    });
  });

  group('Fortsetzen nach dem Start und Wiper', () {
    Future<TransferZeile> lauf(WidgetTester tester, {required bool an}) async {
      final server = standardServer();
      server.json('GET /version', {'service': 'lx-fampad', 'features': {'files': an}});
      server.json('GET /files/usage', {'usedBytes': 0, 'reservedBytes': 0, 'quotaBytes': 10737418240, 'maxFileBytes': 104857600, 'maxE2eeBytes': 105906176, 'chunkBytes': 4194304});
      final env = TestUmgebung(server);
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      env.besitzerInDb = true;
      await env.angemeldet();
      final jetzt = DateTime.now();
      await env.db.into(env.db.transfers).insert(
        TransfersCompanion.insert(id: 't1', richtung: 'Hoch', art: 'datei', zustand: 'laeuft', name: 'a.bin', groesse: const Value(1000), blobId: const Value('00000001-0000-4000-8000-000000000000'), createdAt: jetzt, aktualisiertAt: jetzt),
      );
      await starteApp(tester, env);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      return (await env.db.select(env.db.transfers).get()).single;
    }

    testWidgets('liegengebliebene Übertragungen kommen nach dem Start wieder in die Schlange (ohne Quelle: Datei wählen)', (tester) async {
      expect((await lauf(tester, an: true)).zustandTyp, TransferZustand.dateiNoetig);
    });

    testWidgets('ohne Dateiablage auf dem Server passiert nichts', (tester) async {
      expect((await lauf(tester, an: false)).zustandTyp, TransferZustand.laeuft);
    });

    testWidgets('Abmelden (echter Wiper): Übertragungen enden, Offline-Kopien und Teil-Dateien sind weg, die Tabellen leer, der Dienst entsteht neu', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('wiper_test_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on Object {
          // schon weg
        }
      });
      final server = standardServer();
      server.json('GET /version', {'service': 'lx-fampad', 'features': {'files': false}});
      final env = TestUmgebung(server)..wiperEcht = true;
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      env.besitzerInDb = true;
      env.dateiOrt = DateiOrtIo(() async => Directory('${tmp.path}/cache'));
      await env.angemeldet();
      final c = await starteApp(tester, env);
      final ort = c.read(dateiOrtProvider);
      await tester.runAsync(() async {
        await ort.anhaengen((await ort.pfad('b1'))!, bytes(10));
        await ort.anhaengen((await ort.pfad('b2.teil'))!, bytes(10));
        final jetzt = DateTime.now();
        await env.db.into(env.db.dateiCache).insert(DateiCacheCompanion.insert(blobId: 'b1', groesse: 10, name: 'a.txt', zuletztGenutzt: jetzt));
        await env.db.into(env.db.transfers).insert(TransfersCompanion.insert(id: 't1', richtung: 'runter', art: 'runter', zustand: 'wartet', name: 'a', blobId: const Value('b2'), createdAt: jetzt, aktualisiertAt: jetzt));
      });
      final vorher = c.read(transferDienstProvider);
      await tester.runAsync(() => c.read(localDataWiperProvider)());
      await tester.runAsync(() async {
        expect(await env.db.select(env.db.dateiCache).get(), isEmpty);
        expect(await env.db.select(env.db.transfers).get(), isEmpty);
        expect(await ort.existiert('${tmp.path}/cache/b1'), isFalse);
        expect(Directory('${tmp.path}/cache').existsSync(), isFalse);
      });
      expect(identical(c.read(transferDienstProvider), vorher), isFalse); // ein frischer Dienst, der alte ist beendet
    });
  });

  group('Speichern', () {
    test('Systemdialog: abgebrochen heißt false; im Web gilt der Aufruf als Erfolg', () {
      expect(speichernErfolg(null, web: false), isFalse);
      expect(speichernErfolg(Uri.parse('content://x'), web: false), isTrue);
      expect(speichernErfolg(null, web: true), isTrue);
    });

    test('Bytes und Cache-Dateien gehen an den Systemdialog; eine fehlende Datei ergibt false', () async {
      final tmp = Directory.systemTemp.createTempSync('speichern_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final ort = DateiOrtIo(() async => Directory('${tmp.path}/c'));
      final gespeichert = <(String, int, String?)>[];
      final s = DateiSpeichernDienst(ort: ort, adresse: (b) => 'https://familie.test/api/v1/files/blobs/$b', bytes: (n, b, m) async {
        gespeichert.add((n, b.length, m));
        return true;
      });
      expect(await s.bytes('a.pdf', bytes(7), mime: 'application/pdf'), isTrue);
      final p = (await ort.pfad('b1'))!;
      await ort.anhaengen(p, bytes(20));
      expect(await s.ausPfad(p, 'b.txt', mime: 'text/plain'), isTrue);
      expect(await s.ausPfad('${tmp.path}/gibt-es-nicht', 'x'), isFalse);
      expect(gespeichert, [('a.pdf', 7, 'application/pdf'), ('b.txt', 20, 'text/plain')]);
      final kein = DateiSpeichernDienst(ort: const KeinDateiOrt(), adresse: (b) => b, bytes: (n, b, m) async => true);
      expect(await kein.ausPfad('x', 'x'), isFalse);
    });

    test('Web: große Dateien laden über eine normale Navigation auf die Adresse (nie blob:, nie ein Token in der Adresse); auf Android nie', () {
      final adressen = <(String, String)>[];
      bool laden(String a, String n) {
        adressen.add((a, n));
        return true;
      }

      final web = DateiSpeichernDienst(ort: const KeinDateiOrt(), adresse: (b) => 'https://familie.test/api/v1/files/blobs/$b', browserLaden: laden, web: true);
      expect(web.imBrowser('0000-blob', 'Urlaub.pdf'), isTrue);
      expect(adressen.single.$1, 'https://familie.test/api/v1/files/blobs/0000-blob');
      expect(adressen.single.$1, isNot(contains('blob:')));
      expect(adressen.single.$1, isNot(contains('token')));
      final android = DateiSpeichernDienst(ort: const KeinDateiOrt(), adresse: (b) => b, browserLaden: laden, web: false);
      expect(android.imBrowser('x', 'y'), isFalse);
      expect(adressen, hasLength(1));
    });
  });

  group('Vorschau-Zwischenspeicher', () {
    late FakeServer server;
    late FakeDateien welt;
    late ApiClient api;

    setUp(() async {
      server = FakeServer();
      welt = FakeDateien(server, FakeSyncServer());
      final tokens = MemoryTokenStore();
      await tokens.writeTokens(StoredTokens(accessToken: 'person-mama', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'r', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: 'g'));
      welt.rollen['person-mama'] = Role.parent;
      api = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test');
    });

    String thumb(String id, int n) {
      welt.blobs[id] = FakeBlob(id, 'server', 'thumb', 'image/png', n, 'person-mama')
        ..zustand = 'claimed'
        ..daten.add(bytes(n));
      return id;
    }

    test('lädt mit der Anmeldung (kein Token in der Adresse), merkt sich das Bild und liefert es ohne zweiten Abruf', () async {
      final c = VorschauCache(BlobLader(api));
      thumb('00000001-0000-4000-8000-000000000000', 500);
      final a = await c.holen('00000001-0000-4000-8000-000000000000');
      expect(a, hasLength(500));
      expect((await c.holen('00000001-0000-4000-8000-000000000000'))!.length, 500);
      expect(server.anfragen('GET /files/blobs/00000001-0000-4000-8000-000000000000'), hasLength(1));
      expect(server.log.single.headers['authorization'], 'Bearer person-mama');
    });

    test('gleichzeitige Anfragen teilen sich einen Abruf; ein Fehler (404) ergibt null und bleibt nicht im Speicher', () async {
      final c = VorschauCache(BlobLader(api));
      thumb('00000001-0000-4000-8000-000000000000', 100);
      final r = await Future.wait([c.holen('00000001-0000-4000-8000-000000000000'), c.holen('00000001-0000-4000-8000-000000000000')]);
      expect(r.every((x) => x != null), isTrue);
      expect(server.anfragen('GET /files/blobs/00000001-0000-4000-8000-000000000000'), hasLength(1));
      expect(await c.holen('00000002-0000-4000-8000-000000000000'), isNull);
      expect(c.anzahl, 1);
    });

    test('Obergrenzen: höchstens so viele Bilder und Byte; die am längsten nicht gezeigten fliegen zuerst heraus', () async {
      final c = VorschauCache(BlobLader(api), maxAnzahl: 3, maxBytes: 1000);
      final ids = [for (var i = 1; i <= 5; i++) thumb('0000000$i-0000-4000-8000-000000000000', 300)];
      await c.holen(ids[0]);
      await c.holen(ids[1]);
      await c.holen(ids[2]); // 900 Byte
      await c.holen(ids[0]); // ids[0] rückt ans Ende
      await c.holen(ids[3]); // über 1000 Byte: ids[1] (am längsten nicht gezeigt) fliegt heraus
      expect(c.bytes, lessThanOrEqualTo(1000));
      server.log.clear();
      await c.holen(ids[0]);
      expect(server.log, isEmpty); // noch da
      await c.holen(ids[1]);
      expect(server.log, hasLength(1)); // musste neu geladen werden
    });

    test('ein zu großes Vorschaubild (über 256 KiB) wird nie übernommen', () async {
      final c = VorschauCache(BlobLader(api));
      thumb('00000009-0000-4000-8000-000000000000', 300000);
      expect(await c.holen('00000009-0000-4000-8000-000000000000'), isNull);
    });
  });

  group('Vorschaubilder (echte Bildverarbeitung)', () {
    testWidgets('quadratisch auf höchstens 512 Pixel, als PNG neu kodiert (ohne EXIF/GPS), höchstens 256 KiB', (tester) async {
      await tester.runAsync(() async {
        final gross = await testBild(1600, 900);
        final t = (await standardThumbErzeuger(gross))!;
        expect(t.length, lessThanOrEqualTo(kMaxThumbBytes));
        expect(t.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
        final m = await pngMasse(t);
        expect(m.$1, m.$2); // quadratisch
        expect(m.$1, lessThanOrEqualTo(512));
        expect(m.$1, 512);
        // kleines Bild wird nicht vergrößert
        final klein = (await standardThumbErzeuger(await testBild(200, 120)))!;
        expect((await pngMasse(klein)).$1, 120);
      });
    });

    testWidgets('EXIF fällt weg: aus einem JPEG mit EXIF-Drehung entsteht ein PNG ohne jede Metadaten', (tester) async {
      await tester.runAsync(() async {
        final jpeg = File('test/fixtures/links_rot_rechts_blau_exif6.jpg').readAsBytesSync();
        expect(String.fromCharCodes(jpeg.sublist(0, 400)).contains('Exif'), isTrue);
        final t = (await standardThumbErzeuger(jpeg))!;
        expect(t.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
        // ein PNG der Engine trägt keinen eXIf-Chunk
        expect(String.fromCharCodes(t).contains('eXIf'), isFalse);
        expect(String.fromCharCodes(t).contains('Exif'), isFalse);
        expect(mimeAusKopf(t), 'image/png');
      });
    });

    testWidgets('kein Bild, zu groß, zu klein: kein Vorschaubild (null) statt eines Fehlers', (tester) async {
      await tester.runAsync(() async {
        expect(await standardThumbErzeuger(bytes(1000)), isNull);
        expect(await standardThumbErzeuger(Uint8List(0)), isNull);
        expect(await standardThumbErzeuger(await testBild(30, 30)), isNull); // unter 64 Pixel
      });
    });

    testWidgets('Rauschen ist schwer zu komprimieren: das Ergebnis bleibt trotzdem unter 256 KiB (oder es gibt keins)', (tester) async {
      await tester.runAsync(() async {
        final t = await standardThumbErzeuger(await testBild(1200, 1200, rauschen: true));
        if (t != null) expect(t.length, lessThanOrEqualTo(kMaxThumbBytes));
      });
    });
  });
}
