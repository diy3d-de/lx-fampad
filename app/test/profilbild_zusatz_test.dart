// Benutzerbild, Korrekturrunde: Dateikopf und Speicherbomben, EXIF-Drehung, Zurück/Dispose, Cache-Pflege, Abmelden während des Abrufs,
// Admin setzt Bild zurück.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/avatar/avatar_foto.dart';
import 'package:lx_fampad/data/avatar/bild_aufbereiten.dart';
import 'package:lx_fampad/data/avatar/bild_kopf.dart';
import 'package:lx_fampad/data/lists/members.dart';
import 'package:lx_fampad/features/admin/admin_screen.dart';
import 'package:lx_fampad/features/profile/profilbild_screen.dart';

import 'profilbild_test.dart' show testBild, pngMasse;
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Map<String, dynamic> _me(Map<String, dynamic>? avatar) {
  final me = meJson();
  if (avatar != null) (me['user'] as Map<String, dynamic>)['avatar'] = avatar;
  return me;
}

Uint8List _pngKopf(int b, int h) {
  final d = ByteData(33);
  for (final (i, v) in [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].indexed) {
    d.setUint8(i, v);
  }
  d.setUint32(8, 13);
  for (final (i, v) in 'IHDR'.codeUnits.indexed) {
    d.setUint8(12 + i, v);
  }
  d.setUint32(16, b);
  d.setUint32(20, h);
  return d.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Dateikopf und Schutz vor Speicherbomben', () {
    test('Maße aus PNG-, JPEG- und WebP-Kopf; animiertes WebP und Fremdes sind kein Bild', () {
      final png = bildMasse(_pngKopf(640, 480))!;
      expect((png.mime, png.breite, png.hoehe), ('image/png', 640, 480));
      final jpg = bildMasse(File('test/fixtures/links_rot_rechts_blau_ohne_exif.jpg').readAsBytesSync())!;
      expect((jpg.mime, jpg.breite, jpg.hoehe), ('image/jpeg', 200, 100));
      final webp = Uint8List(30)
        ..setAll(0, 'RIFF'.codeUnits)
        ..setAll(8, 'WEBPVP8L'.codeUnits);
      webp[20] = 0x2f;
      ByteData.sublistView(webp).setUint32(21, (299 & 0x3fff) | ((199 & 0x3fff) << 14), Endian.little);
      expect(bildMasse(webp)!.breite, 300);
      final vp8x = Uint8List(30)
        ..setAll(0, 'RIFF'.codeUnits)
        ..setAll(8, 'WEBPVP8X'.codeUnits);
      vp8x[20] = 0x02;
      expect(bildMasse(vp8x), isNull);
      expect(bildMasse(Uint8List.fromList(utf8.encode('GIF89a-und-mehr-als-dreissig-bytes-lang'))), isNull);
    });

    test('kleine Datei mit behaupteten 30000 x 30000 Pixeln wird VOR dem Dekodieren abgelehnt', () async {
      final fake = _pngKopf(30000, 30000);
      expect(fake.length, lessThan(100));
      await expectLater(bildAufbereiten(fake), throwsA(isA<BildFehler>().having((e) => e.meldung, 'm', contains('zu viele Pixel'))));
      await expectLater(bildAufbereiten(_pngKopf(6001, 100)), throwsA(isA<BildFehler>()));
      await expectLater(bildAufbereiten(_pngKopf(5900, 5900)), throwsA(isA<BildFehler>())); // 34,8 Megapixel
    });

    test('extreme Seitenverhältnisse (Kurzkante unter 64 px) werden abgelehnt', () async {
      await expectLater(bildAufbereiten(_pngKopf(4000, 40)), throwsA(isA<BildFehler>().having((e) => e.meldung, 'm', contains('zu schmal'))));
      await expectLater(bildAufbereiten(_pngKopf(63, 500)), throwsA(isA<BildFehler>()));
    });
  });

  group('EXIF-Drehung', () {
    Future<(int, int, int)> pixel(Uint8List png, int x, int y) async {
      final c = await ui.instantiateImageCodec(png);
      final bild = (await c.getNextFrame()).image;
      final d = (await bild.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final i = (y * bild.width + x) * 4;
      return (d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2));
    }

    testWidgets('Foto mit EXIF-Drehung 6 (Hochformat): oben rot, unten blau, so wie die Person es sieht', (tester) async {
      await tester.runAsync(() async {
        final r = await bildAufbereiten(File('test/fixtures/links_rot_rechts_blau_exif6.jpg').readAsBytesSync());
        expect(await pngMasse(r.bytes), (100, 100));
        expect((await pixel(r.bytes, 50, 8)).$1, greaterThan(200)); // oben rot
        expect((await pixel(r.bytes, 50, 92)).$3, greaterThan(200)); // unten blau
      });
    });

    testWidgets('Foto ohne EXIF bleibt unverändert: links rot, rechts blau', (tester) async {
      await tester.runAsync(() async {
        final r = await bildAufbereiten(File('test/fixtures/links_rot_rechts_blau_ohne_exif.jpg').readAsBytesSync());
        expect((await pixel(r.bytes, 8, 50)).$1, greaterThan(200));
        expect((await pixel(r.bytes, 92, 50)).$3, greaterThan(200));
      });
    });

    testWidgets('detailreiches Foto: Hinweis-Flag "verkleinert", wenn die Kante unter 512 liegt', (tester) async {
      await tester.runAsync(() async {
        final r = await bildAufbereiten(await testBild(900, 900, rauschen: true), zielBytes: 200 * 1024);
        expect(r.verkleinert, isTrue);
      });
    });
  });

  group('Rückweg, Cache und Admin', () {
    testWidgets('Zurück ist während des Speicherns gesperrt; danach schließt der Bildschirm ohne Fehler', (tester) async {
      final server = standardServer();
      server.json('GET /me', _me(null));
      final env = await angemeldeteUmgebung(server: server);
      final frei = Completer<void>();
      server.on('PUT /me/avatar', (_) async {
        await frei.future;
        return jsonAntwort({'avatar': {'kind': 'preset', 'id': 'V01', 'version': 1}});
      });
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Profilbild ändern'));
      await tippe(tester, find.bySemanticsLabel('Platzhalter Vater: Kurzhaar, Hemd'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Übernehmen'));
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.byType(ProfilbildScreen), findsOneWidget);
      frei.complete();
      await warte(tester);
      expect(find.byType(ProfilbildScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('404 löscht die lokale Kopie; Verbindungsfehler lässt sie stehen und ruft 60 s nicht erneut ab', (tester) async {
      final server = FakeServer();
      server.on('GET /members/$fixIdKind/avatar', (_) => fehler(404, 'not_found'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await env.db.metaSchreiben('avatar:$fixIdKind', '1:AAAA');
      final c = env.container();
      addTearDown(c.dispose);
      final k2 = (userId: fixIdKind, version: 2);
      final s2 = c.listen(avatarFotoProvider(k2), (_, _) {});
      expect(await c.read(avatarFotoProvider(k2).future), isNull);
      s2.close();
      await tester.pump(Duration.zero);
      expect(await env.db.metaLesen('avatar:$fixIdKind'), isNull);

      await env.db.metaSchreiben('avatar:$fixIdKind', '1:AAAA');
      server.on('GET /members/$fixIdKind/avatar', (_) => throw http.ClientException('offline'));
      final k3 = (userId: fixIdKind, version: 3);
      final s3 = c.listen(avatarFotoProvider(k3), (_, _) {});
      expect(await c.read(avatarFotoProvider(k3).future), isNotNull); // altes Foto bleibt sichtbar
      s3.close();
      await tester.pump(Duration.zero);
      final s3b = c.listen(avatarFotoProvider(k3), (_, _) {});
      expect(await c.read(avatarFotoProvider(k3).future), isNotNull);
      expect(server.anfragen('GET /members/$fixIdKind/avatar'), hasLength(2)); // 404 + genau ein Verbindungsfehler
      expect(await env.db.metaLesen('avatar:$fixIdKind'), '1:AAAA');
      s3b.close();
      await tester.pump(Duration.zero);
    });

    testWidgets('Abmelden während des Abrufs: das späte Foto wird nicht mehr gespeichert', (tester) async {
      late Uint8List png;
      await tester.runAsync(() async => png = await testBild(32, 32));
      final server = standardServer();
      final frei = Completer<void>();
      server.on('GET /members/$fixIdKind/avatar', (_) async {
        await frei.future;
        return http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
      });
      final env = await angemeldeteUmgebung(server: server);
      final c = await starteApp(tester, env);
      final sub = c.listen(avatarFotoProvider((userId: fixIdKind, version: 1)), (_, _) {});
      addTearDown(sub.close);
      await warte(tester);
      await c.read(authProvider.notifier).abmelden(nurLokal: true);
      await warte(tester);
      frei.complete();
      await warte(tester);
      expect(await env.db.metaLesen('avatar:$fixIdKind'), isNull);
    });

    testWidgets('Mitgliederliste räumt Fotos entfernter Mitglieder weg', (tester) async {
      final env = await angemeldeteUmgebung();
      await env.db.metaSchreiben('avatar:$fixIdKind', '1:AAAA');
      await env.db.metaSchreiben('avatar:gone-1234', '1:AAAA');
      final c = env.container();
      addTearDown(c.dispose);
      final sub = c.listen(mitgliederProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(mitgliederProvider.future);
      expect(await env.db.metaLesen('avatar:gone-1234'), isNull);
      expect(await env.db.metaLesen('avatar:$fixIdKind'), isNotNull);
    });

    testWidgets('Admin setzt das Bild eines Mitglieds zurück (Bestätigung, DELETE)', (tester) async {
      final server = standardServer();
      final ben = userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de')..['avatar'] = {'kind': 'preset', 'id': 'K07', 'version': 2};
      server.json('GET /members', {
        'members': [userJson(), ben],
      });
      server.on('DELETE /members/$fixIdKind/avatar', (_) => jsonAntwort({'ok': true}));
      final env = await angemeldeteUmgebung(server: server);
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      expect(find.byType(AdminScreen), findsOneWidget);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippe(tester, find.text('Profilbild zurücksetzen'));
      await tippe(tester, find.widgetWithText(TextButton, 'Zurücksetzen'));
      expect(server.anfragen('DELETE /members/$fixIdKind/avatar'), hasLength(1));
      pruefeLayout(tester, 'Admin nach Bild-Reset');
    });
  });
}
