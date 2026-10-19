// Benutzerbild: Bild verkleinern (Testbild), Auswahl und Fehlerfälle im Bildschirm "Profilbild ändern", Anzeige (Platzhalter, Foto,
// Offline-Zwischenspeicher, Fehler -> Initialen), Modell tolerant. 360 px, Textskala 1.0/1.5, Touch-Ziele.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/constants.dart' show personColor;
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/avatar/avatar_vorlagen.dart';
import 'package:lx_fampad/data/avatar/bild_aufbereiten.dart';
import 'package:lx_fampad/data/avatar/bild_datei.dart';
import 'package:lx_fampad/features/auth/auth_widgets.dart' show MeldungsBox;
import 'package:lx_fampad/features/profile/profilbild_screen.dart';
import 'package:lx_fampad/ui/widgets.dart';
import 'package:lx_fampad/widgets/benutzer_avatar.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

/// Ein PNG in der gegebenen Größe: Farbverlauf (viele Farben) oder, mit [rauschen], Zufallspixel (kaum komprimierbar).
Future<Uint8List> testBild(int b, int h, {bool rauschen = false}) async {
  final rekorder = ui.PictureRecorder();
  final canvas = ui.Canvas(rekorder);
  if (rauschen) {
    final zufall = Random(7);
    final pixel = Uint8List(b * h * 4);
    for (var i = 0; i < pixel.length; i += 4) {
      pixel[i] = zufall.nextInt(256);
      pixel[i + 1] = zufall.nextInt(256);
      pixel[i + 2] = zufall.nextInt(256);
      pixel[i + 3] = 255;
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixel, b, h, ui.PixelFormat.rgba8888, c.complete);
    canvas.drawImage(await c.future, ui.Offset.zero, ui.Paint());
  } else {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, b.toDouble(), h.toDouble()),
      ui.Paint()..shader = ui.Gradient.linear(ui.Offset.zero, ui.Offset(b.toDouble(), h.toDouble()), const [Color(0xFFFF0000), Color(0xFF0000FF)]),
    );
  }
  final bild = await rekorder.endRecording().toImage(b, h);
  final daten = await bild.toByteData(format: ui.ImageByteFormat.png);
  return daten!.buffer.asUint8List();
}

Future<(int, int)> pngMasse(Uint8List png) async {
  final c = await ui.instantiateImageCodec(png);
  final f = await c.getNextFrame();
  return (f.image.width, f.image.height);
}

bool istPng(Uint8List b) => b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47;

BildDatei dateiAus(Uint8List b, {int? laenge, String name = 'foto.png'}) => BildDatei(name: name, laenge: laenge ?? b.length, bytes: Stream.value(b));

Map<String, dynamic> _meMitAvatar(Map<String, dynamic>? avatar) {
  final me = meJson();
  if (avatar != null) (me['user'] as Map<String, dynamic>)['avatar'] = avatar;
  return me;
}

/// Wartet (echte Zeit, die Bildverarbeitung läuft im Engine-Thread) bis [f] sichtbar ist, höchstens 30 s.
Future<void> wartebis(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 300 && f.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
}

/// Das Anzeige-Bild kommt skaliert (ResizeImage um das MemoryImage).
ImageProvider? _ohneResize(ImageProvider? i) => i is ResizeImage ? i.imageProvider : i;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modell', () {
    test('Bild-Metadaten: Platzhalter, Foto, fehlend und Unbekanntes ergeben nie einen Fehler', () {
      Map<String, dynamic> mit(Object? a) => {...userJson(), 'avatar': ?a};
      expect(UserDto.fromJson(userJson()).avatar, isNull);
      expect(UserDto.fromJson(mit({'kind': 'preset', 'id': 'V01', 'version': 3})).avatar, const AvatarDto.vorlage('V01', 3));
      expect(UserDto.fromJson(mit({'kind': 'photo', 'version': 5})).avatar, const AvatarDto.foto(5));
      expect(UserDto.fromJson(mit({'kind': 'video', 'version': 1})).avatar, isNull);
      expect(UserDto.fromJson(mit({'kind': 'preset'})).avatar, isNull);
      expect(UserDto.fromJson(mit('kaputt')).avatar, isNull);
      // Rundlauf (Profil im Zwischenspeicher)
      final u = UserDto.fromJson(mit({'kind': 'photo', 'version': 2}));
      expect(UserDto.fromJson(u.toJson()).avatar, const AvatarDto.foto(2));
    });

    test('alle zehn Platzhalter haben eine Datei und eine eindeutige Kennung', () {
      expect(kAvatarVorlagen.map((v) => v.id).toSet(), {'V01', 'V08', 'V12', 'M01', 'M08', 'M13', 'K07', 'K08', 'K12', 'K13'});
      expect(avatarVorlage('K12')?.name, 'Teenager, Kopfhörer');
      expect(avatarVorlage('X99'), isNull);
    });
  });

  group('Bild verkleinern', () {
    testWidgets('großes Querformat wird quadratisch auf 512 x 512 geschnitten und als PNG neu kodiert', (tester) async {
      await tester.runAsync(() async {
        final quelle = await testBild(1600, 900);
        final r = await bildAufbereiten(quelle);
        expect(istPng(r.bytes), isTrue);
        expect(r.kante, 512);
        expect(await pngMasse(r.bytes), (512, 512));
        expect(r.bytes.length, lessThan(kAvatarZielBytes));
        expect(r.mime, 'image/png');
      });
    });

    testWidgets('Hochformat wird ebenfalls quadratisch; kleine Bilder werden nicht vergrößert', (tester) async {
      await tester.runAsync(() async {
        expect(await pngMasse((await bildAufbereiten(await testBild(700, 1500))).bytes), (512, 512));
        final klein = await bildAufbereiten(await testBild(120, 80));
        expect(await pngMasse(klein.bytes), (80, 80));
      });
    });

    testWidgets('schwer komprimierbares Foto wird kleiner gerechnet, bis es unter das Byte-Ziel passt', (tester) async {
      await tester.runAsync(() async {
        final rauschen = await testBild(900, 900, rauschen: true);
        final r = await bildAufbereiten(rauschen, zielBytes: 200 * 1024);
        expect(r.bytes.length, lessThanOrEqualTo(200 * 1024));
        expect(r.kante, lessThan(512));
        expect(r.kante, greaterThanOrEqualTo(192));
        // aussichtslos: auch die kleinste Kante bleibt über dem Ziel
        await expectLater(bildAufbereiten(rauschen, zielBytes: 1000), throwsA(isA<BildFehler>()));
      });
    });

    testWidgets('kein Bild, leere und zu große Dateien ergeben verständliche Meldungen', (tester) async {
      await tester.runAsync(() async {
        await expectLater(
          bildAufbereiten(Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>'))),
          throwsA(isA<BildFehler>().having((e) => e.meldung, 'meldung', contains('JPEG, PNG oder WebP'))),
        );
        await expectLater(bildAufbereiten(Uint8List(0)), throwsA(isA<BildFehler>()));
        await expectLater(
          bildAufbereiten(Uint8List(kAvatarQuelleMaxBytes + 1)),
          throwsA(isA<BildFehler>().having((e) => e.meldung, 'meldung', contains('10 MB'))),
        );
      });
    });

    test('Quelldatei: Größenprüfung vor dem Laden (laenge) und beim Lesen (Strom)', () async {
      final eins = Uint8List(1024);
      expect((await bildDateiLesen(dateiAus(eins))).length, 1024);
      await expectLater(bildDateiLesen(dateiAus(eins, laenge: 11 * 1024 * 1024)), throwsA(isA<BildFehler>()));
      // Größe unbekannt: der Strom wird bei der Grenze abgebrochen, ohne alles zu lesen
      var gelesen = 0;
      final strom = () async* {
        for (var i = 0; i < 100; i++) {
          gelesen++;
          yield Uint8List(1024 * 1024);
        }
      }();
      await expectLater(
        bildDateiLesen(BildDatei(name: 'x', bytes: strom)),
        throwsA(isA<BildFehler>().having((e) => e.meldung, 'meldung', contains('10 MB'))),
      );
      expect(gelesen, lessThanOrEqualTo(12));
    });
  });

  group('Bildschirm "Profilbild ändern"', () {
    Future<(TestUmgebung, FakeServer)> umgebung({Map<String, dynamic>? avatar, BildDatei? datei, Object? dateiFehler}) async {
      final server = standardServer();
      server.json('GET /me', _meMitAvatar(avatar));
      final env = await angemeldeteUmgebung(server: server);
      if (datei != null || dateiFehler != null) {
        env.extraOverrides.add(bildDateiWaehlerProvider.overrideWithValue(() async => dateiFehler != null ? throw dateiFehler : datei));
      }
      return (env, server);
    }

    Future<void> oeffne(WidgetTester tester, TestUmgebung env, {double skala = 1.0}) async {
      await starteApp(tester, env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Profilbild ändern'));
      expect(find.byType(ProfilbildScreen), findsOneWidget);
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('Layout: Platzhalter- und Foto-Reiter ohne Überlauf (360 px, Textskala $skala)', (tester) async {
        final (env, _) = await umgebung();
        await oeffne(tester, env, skala: skala);
        pruefeLayout(tester, 'Profilbild Platzhalter');
        // alle zehn Platzhalter sind als Knöpfe mit Beschriftung da
        for (final v in kAvatarVorlagen) {
          expect(find.bySemanticsLabel('Platzhalter ${v.gruppe.label}: ${v.name}'), findsOneWidget, reason: v.id);
        }
        await tippe(tester, find.text('Eigenes Foto'));
        pruefeLayout(tester, 'Profilbild Foto');
        expect(find.text('Foto auswählen'), findsWidgets);
      });
    }

    testWidgets('Platzhalter wählen und übernehmen: PUT mit der Kennung, danach neu laden und zurück', (tester) async {
      final (env, server) = await umgebung();
      server.on('PUT /me/avatar', (_) => jsonAntwort({'avatar': {'kind': 'preset', 'id': 'M13', 'version': 2}}));
      await oeffne(tester, env);
      // ohne Auswahl ist "Übernehmen" gesperrt
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Übernehmen')).onPressed, isNull);
      // Bild entfernen gibt es erst, wenn eines gesetzt ist
      expect(find.text('Bild entfernen'), findsNothing);
      server.json('GET /me', _meMitAvatar({'kind': 'preset', 'id': 'M13', 'version': 2}));
      await tippe(tester, find.bySemanticsLabel('Platzhalter Mutter: Seitenzopf, Brille'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Übernehmen'));
      final put = server.anfragen('PUT /me/avatar');
      expect(put, hasLength(1));
      expect(put.single.json, {'preset': 'M13'});
      expect(find.byType(ProfilbildScreen), findsNothing);
      expect(find.text('Profilbild gespeichert.'), findsOneWidget);
      // die Profilseite zeigt jetzt die Zeichnung
      final bilder = tester.widgetList<Image>(find.byType(Image)).map((i) => i.image).whereType<AssetImage>().map((a) => a.assetName);
      expect(bilder, contains(avatarVorlage('M13')!.asset));
    });

    testWidgets('aktueller Platzhalter ist vorausgewählt; Entfernen sendet DELETE und die Initialen kehren zurück', (tester) async {
      final (env, server) = await umgebung(avatar: {'kind': 'preset', 'id': 'V08', 'version': 4});
      server.on('DELETE /me/avatar', (_) => jsonAntwort({'ok': true}));
      await oeffne(tester, env);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Übernehmen')).onPressed, isNotNull);
      server.json('GET /me', _meMitAvatar(null));
      await tippe(tester, find.text('Bild entfernen'));
      expect(server.anfragen('DELETE /me/avatar'), hasLength(1));
      expect(find.byType(ProfilbildScreen), findsNothing);
      expect(find.textContaining('Profilbild entfernt'), findsOneWidget);
    });

    testWidgets('eigenes Foto: auswählen, zuschneiden, Vorschau, hochladen (PNG-Bytes, Content-Type), nur das kleine Ergebnis', (tester) async {
      late Uint8List quelle;
      await tester.runAsync(() async => quelle = await testBild(2400, 1600));
      final (env, server) = await umgebung(datei: dateiAus(quelle, name: 'urlaub.png'));
      server.on('PUT /me/avatar', (_) => jsonAntwort({'avatar': {'kind': 'photo', 'version': 1}}));
      await oeffne(tester, env);
      await tippe(tester, find.text('Eigenes Foto'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Foto auswählen').first);
      await wartebis(tester, find.text('urlaub.png'));
      await warte(tester);
      expect(find.text('urlaub.png'), findsOneWidget);
      expect(find.textContaining('512 x 512'), findsOneWidget);
      expect(find.textContaining('Standortdaten sind entfernt'), findsOneWidget);
      pruefeLayout(tester, 'Foto gewählt');
      server.json('GET /me', _meMitAvatar({'kind': 'photo', 'version': 1}));
      await tippe(tester, find.widgetWithText(FilledButton, 'Übernehmen'));
      final put = server.anfragen('PUT /me/avatar');
      expect(put, hasLength(1));
      expect(put.single.headers['content-type'], 'image/png');
      final gesendet = put.single.body as Uint8List;
      expect(istPng(gesendet), isTrue);
      expect(gesendet.length, lessThan(kAvatarZielBytes));
      expect(gesendet.length, lessThan(quelle.length ~/ 1)); // nicht das Original
      expect(find.byType(ProfilbildScreen), findsNothing);
      await tester.pump(const Duration(minutes: 2)); // offene Zeitgeber des Abgleichs auslaufen lassen
    });

    testWidgets('Foto über 10 MB: verständliche Meldung, nichts wird hochgeladen', (tester) async {
      final (env, server) = await umgebung(datei: dateiAus(Uint8List(10), laenge: 25 * 1024 * 1024, name: 'riesig.jpg'));
      await oeffne(tester, env);
      await tippe(tester, find.text('Eigenes Foto'));
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Foto auswählen').first);
      expect(find.textContaining('größer als 10 MB'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Übernehmen')).onPressed, isNull);
      expect(server.anfragen('PUT /me/avatar'), isEmpty);
      pruefeLayout(tester, 'zu großes Foto');
    });

    testWidgets('Datei ist kein Bild (z. B. SVG): verständliche Meldung statt Absturz', (tester) async {
      final svg = Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="5" height="5"></svg>'));
      final (env, server) = await umgebung(datei: dateiAus(svg, name: 'bild.svg'));
      await oeffne(tester, env);
      await tippe(tester, find.text('Eigenes Foto'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Foto auswählen').first);
      await wartebis(tester, find.textContaining('JPEG, PNG oder WebP'));
      await warte(tester);
      expect(find.textContaining('JPEG, PNG oder WebP'), findsOneWidget);
      expect(server.anfragen('PUT /me/avatar'), isEmpty);
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('Abbruch der Dateiauswahl ist kein Fehler', (tester) async {
      final (env, _) = await umgebung();
      env.extraOverrides.add(bildDateiWaehlerProvider.overrideWithValue(() async => null));
      await oeffne(tester, env);
      await tippe(tester, find.text('Eigenes Foto'));
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Foto auswählen').first);
      expect(find.byType(MeldungsBox), findsNothing);
      expect(find.textContaining('nicht geklappt'), findsNothing);
    });

    testWidgets('Serverfehler beim Übernehmen (zu groß, Verbindung): deutsche Meldung, Bildschirm bleibt', (tester) async {
      final (env, server) = await umgebung();
      server.on('PUT /me/avatar', (_) => fehler(413, 'payload_too_large'));
      await oeffne(tester, env);
      await tippe(tester, find.bySemanticsLabel('Platzhalter Vater: Kurzhaar, Hemd'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Übernehmen'));
      expect(find.byType(ProfilbildScreen), findsOneWidget);
      expect(find.textContaining('Meldung des Servers'), findsNothing); // nie Servertexte
      expect(find.textContaining('zu groß'), findsWidgets);
      server.on('PUT /me/avatar', (_) => throw http.ClientException('offline'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Übernehmen'));
      expect(find.byType(ProfilbildScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Anzeige', () {
    final foto = AvatarDto.foto(3);
    UserDto person({AvatarDto? avatar}) => UserDto(
      id: fixIdKind,
      email: null,
      displayName: 'Ben',
      colorIndex: 2,
      role: Role.child,
      status: MemberStatus.active,
      avatar: avatar,
    );

    Future<void> zeige(WidgetTester tester, TestUmgebung env, UserDto u, {double size = 40}) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = env.container();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(home: Scaffold(body: Center(child: BenutzerAvatar(user: u, size: size)))),
        ),
      );
      await warte(tester);
    }

    ImageProvider? bildDerAnzeige(WidgetTester tester) {
      final bilder = tester.widgetList<Image>(find.byType(Image));
      return bilder.isEmpty ? null : bilder.first.image;
    }

    testWidgets('ohne Bild: Initialen in der Personenfarbe', (tester) async {
      final env = TestUmgebung(FakeServer());
      await zeige(tester, env, person());
      expect(find.text('BE'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('Platzhalter: Zeichnung als Asset auf der vollen Personenfarbe', (tester) async {
      final env = TestUmgebung(FakeServer());
      await zeige(tester, env, person(avatar: const AvatarDto.vorlage('K12', 1)));
      expect((bildDerAnzeige(tester) as AssetImage).assetName, avatarVorlage('K12')!.asset);
      final deko = tester.widget<Container>(find.descendant(of: find.byType(PersonAvatar), matching: find.byType(Container)).first).decoration as BoxDecoration;
      expect(deko.color, personColor(2));
    });

    testWidgets('unbekannte Platzhalter-Kennung (neuere Server-Version): Initialen statt Fehler', (tester) async {
      final env = TestUmgebung(FakeServer());
      await zeige(tester, env, person(avatar: const AvatarDto.vorlage('Z99', 1)));
      expect(find.text('BE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Foto: wird vom Server geladen, zwischengespeichert und danach ohne Verbindung weiter angezeigt', (tester) async {
      late Uint8List png;
      await tester.runAsync(() async => png = await testBild(64, 64));
      final server = FakeServer();
      server.on('GET /members/$fixIdKind/avatar', (_) => http.Response.bytes(png, 200, headers: {'content-type': 'image/png', 'etag': '"a3"'}));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await zeige(tester, env, person(avatar: foto));
      expect(_ohneResize(bildDerAnzeige(tester)), isA<MemoryImage>());
      expect(server.anfragen('GET /members/$fixIdKind/avatar'), hasLength(1));
      // lokal gespeichert (sync_meta): "Version:base64"
      expect((await env.db.metaLesen('avatar:$fixIdKind'))!.startsWith('3:'), isTrue);

      // neue Anzeige ohne Server: das gespeicherte Foto genügt, kein weiterer Abruf
      server.routes.remove('GET /members/$fixIdKind/avatar');
      await tester.pumpWidget(const SizedBox());
      await zeige(tester, env, person(avatar: foto));
      expect(_ohneResize(bildDerAnzeige(tester)), isA<MemoryImage>());
      expect(server.anfragen('GET /members/$fixIdKind/avatar'), hasLength(1));
    });

    testWidgets('neue Version bei nicht erreichbarem Server: das ältere Foto bleibt sichtbar (offline-tauglich)', (tester) async {
      late Uint8List png;
      await tester.runAsync(() async => png = await testBild(32, 32));
      final server = FakeServer();
      server.on('GET /members/$fixIdKind/avatar', (_) => throw http.ClientException('offline'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await env.db.metaSchreiben('avatar:$fixIdKind', '2:${base64Encode(png)}');
      await zeige(tester, env, person(avatar: foto)); // Version 3 gewünscht, 2 lokal
      expect(_ohneResize(bildDerAnzeige(tester)), isA<MemoryImage>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('Foto nicht ladbar (404 oder Offline ohne Zwischenspeicher): Initialen', (tester) async {
      final server = FakeServer();
      server.on('GET /members/$fixIdKind/avatar', (_) => fehler(404, 'not_found'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await zeige(tester, env, person(avatar: foto));
      expect(find.text('BE'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unlesbare Bild-Bytes: Initialen bleiben sichtbar (Fehler-Rückfall des Bildes)', (tester) async {
      final server = FakeServer();
      server.on('GET /members/$fixIdKind/avatar', (_) => http.Response.bytes(Uint8List.fromList([1, 2, 3, 4]), 200, headers: {'content-type': 'image/png'}));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await zeige(tester, env, person(avatar: foto));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await warte(tester);
      expect(find.text('BE'), findsOneWidget);
      tester.takeException(); // der Bild-Ladefehler wird gemeldet, die Oberfläche fängt ihn ab
    });

    testWidgets('Person unbekannt (null): Fragezeichen', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: BenutzerAvatar(user: null))));
      expect(find.text('?'), findsOneWidget);
    });
  });
}

