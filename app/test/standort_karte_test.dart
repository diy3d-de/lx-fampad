// Karte der Teilenden: Stil-Vorlage ohne Fremd-Adressen, Kartenbereich, Stecknadel (Spitze, Profilbild), Karte mit Attrappe statt MapLibre (Nadeln, Info beim
// Tippen, Knöpfe, außerhalb des Kartenbereichs), Rückfall "Karte noch nicht eingerichtet" bei fehlender Datei. 360 px, Textskala 1.5.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lx_fampad/constants.dart' show kSurface;
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/avatar/avatar_foto.dart';
import 'package:lx_fampad/data/providers.dart';
import 'package:lx_fampad/data/standort/standort_dienst.dart';
import 'package:lx_fampad/data/standort/standort_modelle.dart';
import 'package:lx_fampad/data/standort/standort_port.dart';
import 'package:lx_fampad/features/karte/karte_config.dart';
import 'package:lx_fampad/features/karte/karte_stil.dart';
import 'package:lx_fampad/features/karte/karte_verfuegbar.dart';
import 'package:lx_fampad/features/standort/standort_karte_ansicht.dart';
import 'package:lx_fampad/features/standort/standort_pin.dart';
import 'package:lx_fampad/ui/theme.dart';

import 'support/harness.dart';

const _ich = 'a0000000-0000-4000-8000-00000000000a';
const _ben = 'b0000000-0000-4000-8000-00000000000b';
const _cora = 'c0000000-0000-4000-8000-00000000000c';

class _FakeAuth extends AuthController {
  final UserDto user;
  _FakeAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user);
}

class _Steuerung extends StandortController {
  final StandortState anfang;
  _Steuerung(this.anfang);
  @override
  StandortState build() => anfang;
}

UserDto _user(String id, String name, int farbe, {AvatarDto? avatar}) => UserDto(id: id, email: null, displayName: name, colorIndex: farbe, role: Role.parent, status: MemberStatus.active, avatar: avatar);

/// Ein gültiges 1x1-PNG (für das Foto im Kopf der Nadel).
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, 0x00, 0x05, 0xFE, 0x02, 0xFE, 0xA7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Kopf einer PMTiles-Datei (127 Byte, Version 3) mit dem Bereich west/süd/ost/nord in Grad.
Uint8List _kopfBytes(double west, double sued, double ost, double nord) {
  final b = Uint8List(127);
  b.setRange(0, 7, 'PMTiles'.codeUnits);
  b[7] = 3;
  final d = ByteData.sublistView(b);
  d.setInt32(102, (west * 1e7).round(), Endian.little);
  d.setInt32(106, (sued * 1e7).round(), Endian.little);
  d.setInt32(110, (ost * 1e7).round(), Endian.little);
  d.setInt32(114, (nord * 1e7).round(), Endian.little);
  return b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  final vorlage = File('assets/karte/style.json').readAsStringSync();
  final jetzt = DateTime(2026, 10, 20, 12);

  group('Konfiguration', () {
    test('Stil-Vorlage: nur Platzhalter und der OSM-Attributionslink, keine Fremd-Adresse', () {
      final adressen = RegExp(r'https?://[^"\\\s<>]+').allMatches(vorlage).map((m) => m.group(0)!).toSet();
      expect(adressen, {'https://www.openstreetmap.org/copyright'});
      expect(vorlage, contains('{{KARTE_BASE}}'));
      expect(vorlage, contains('pmtiles://{{PMTILES_URL}}'));
      expect(vorlage, contains(kKarteAttribution));
    });

    test('Platzhalter werden durch absolute Adressen der eigenen Domain ersetzt; Fremd-Adressen werden abgelehnt', () {
      final s = karteStyleAusVorlage(vorlage, 'https://familyhub.lx-labs.dev');
      expect(s, contains('pmtiles://https://familyhub.lx-labs.dev/karte-daten/westerwald.pmtiles'));
      expect(s, contains('https://familyhub.lx-labs.dev/karte/glyphs/{fontstack}/{range}.pbf'));
      expect(s, isNot(contains('{{')));
      expect(() => karteStyleAusVorlage('{"glyphs":"https://demotiles.maplibre.org/{fontstack}"}', 'https://familyhub.lx-labs.dev'), throwsStateError);
      expect(() => karteStyleAusVorlage('{"a":"{{UNBEKANNT}}"}', 'https://familyhub.lx-labs.dev'), throwsStateError);
    });

    test('Basisadresse: Define vor API_BASE vor Herkunft der Seite vor Produktion', () {
      expect(karteOrigin(base: 'http://10.0.2.2:8150/', api: 'https://x', web: false), 'http://10.0.2.2:8150');
      expect(karteOrigin(base: '', api: '', web: true, seite: 'https://familyhub.lx-labs.dev'), 'https://familyhub.lx-labs.dev');
      expect(karteOrigin(base: '', api: '', web: false), 'https://familyhub.lx-labs.dev');
    });

    test('Kartenbereich (Vorgabe 175 km um Westerburg): Mitte drin, Paris, Nordsee und Alpen draußen', () {
      const b = KartenBereich.westerburg175;
      expect(b.enthaelt(50.5612, 7.9741), isTrue);
      expect(b.enthaelt(50.1109, 8.6821), isTrue); // Frankfurt
      expect(b.enthaelt(48.8566, 2.3522), isFalse); // Paris
      expect(b.enthaelt(53.5, 8.0), isFalse); // Nordsee
      expect(b.enthaelt(47.5, 8.0), isFalse); // Alpenrand
    });

    test('Genauigkeitskreis: geschlossener Ring mit dem gewünschten Radius in Metern', () {
      const lat = 50.5612, lng = 7.9741;
      final ring = kreisRing(lat, lng, 120);
      expect(ring.first.lat, ring.last.lat);
      expect(ring.first.lon, ring.last.lon);
      for (final p in ring) {
        final dy = (p.lat - lat) * 111320.0;
        final dx = (p.lon - lng) * 111320.0 * math.cos(lat * math.pi / 180);
        expect(math.sqrt(dx * dx + dy * dy), closeTo(120, 0.5));
      }
    });
  });

  group('Verfügbarkeit der Kartendatei', () {
    Future<KartenBereich?> bereichPruefen(http.Response Function(http.Request) antwort) async {
      final c = ProviderContainer(overrides: [httpClientProvider.overrideWithValue(MockClient((r) async => antwort(r)))]);
      addTearDown(c.dispose);
      return c.read(karteDateiProvider.future);
    }

    Future<bool> pruefen(http.Response Function(http.Request) antwort) async => (await bereichPruefen(antwort)) != null;

    /// Kopf einer PMTiles-Datei (127 Byte) mit dem Bereich west/süd/ost/nord (Grad).
    Uint8List kopf(double west, double sued, double ost, double nord, {int version = 3}) {
      final b = Uint8List(127);
      b.setRange(0, 7, 'PMTiles'.codeUnits);
      b[7] = version;
      final d = ByteData.sublistView(b);
      d.setInt32(102, (west * 1e7).round(), Endian.little);
      d.setInt32(106, (sued * 1e7).round(), Endian.little);
      d.setInt32(110, (ost * 1e7).round(), Endian.little);
      d.setInt32(114, (nord * 1e7).round(), Endian.little);
      return b;
    }

    final pmtiles = kopf(5.49, 48.99, 10.45, 52.14);

    test('206 mit PMTiles-Kennung: vorhanden; die Anfrage ist eine Range-Anfrage auf die Datei', () async {
      http.Request? gesehen;
      expect(
        await pruefen((r) {
          gesehen = r;
          return http.Response.bytes(pmtiles, 206);
        }),
        isTrue,
      );
      expect(gesehen!.url.path, '/karte-daten/westerwald.pmtiles');
      expect(gesehen!.headers['Range'], 'bytes=0-126');
    });

    test('Der Bereich kommt aus dem Kopf der Datei (175 km, später ganz Deutschland ohne neue App); Unsinn ist ungültig', () async {
      final b = await bereichPruefen((r) => http.Response.bytes(pmtiles, 206));
      expect(b!.west, closeTo(5.49, 1e-6));
      expect(b.nord, closeTo(52.14, 1e-6));
      final de = await bereichPruefen((r) => http.Response.bytes(kopf(5.85, 47.27, 15.03, 55.07), 206));
      expect(de!.enthaelt(52.5, 13.4), isTrue); // Berlin
      expect(de.enthaelt(48.14, 11.58), isTrue); // München
      // unsinnige Bereiche (alles 0, Ost vor West, außerhalb der Erde) gelten als keine brauchbare Datei
      expect(await bereichPruefen((r) => http.Response.bytes(kopf(0, 0, 0, 0), 206)), isNull);
      expect(await bereichPruefen((r) => http.Response.bytes(kopf(10, 48, 5, 52), 206)), isNull);
      expect(await bereichPruefen((r) => http.Response.bytes(kopf(-200, 48, 5, 52), 206)), isNull);
      expect(await bereichPruefen((r) => http.Response.bytes(kopf(5, 48, 10, 52, version: 2), 206)), isNull);
    });

    test('Ein Server, der trotz Range-Anfrage 200 mit der ganzen Datei liefert, wird nach dem Status verworfen: der Körper wird nicht gelesen', () async {
      var gezogen = 0;
      var abgebrochen = false;
      Stream<List<int>> riesig() async* {
        try {
          while (true) {
            gezogen += 1 << 20;
            yield Uint8List(1 << 20);
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          abgebrochen = true;
        }
      }

      final c = ProviderContainer(overrides: [httpClientProvider.overrideWithValue(MockClient.streaming((r, _) async => http.StreamedResponse(riesig(), 200)))]);
      addTearDown(c.dispose);
      expect(await c.read(karteDateiProvider.future), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gezogen, lessThan(8 << 20), reason: 'höchstens ein paar Stücke, nie die ganze Datei');
      expect(abgebrochen, isTrue);
    });

    test('Ein 206 mit endlosem Körper (Kopf stimmt): nach 127 Byte ist Schluss, der Rest wird nicht gelesen', () async {
      var gezogen = 0;
      Stream<List<int>> endlos() async* {
        yield pmtiles;
        while (true) {
          gezogen += 1 << 20;
          yield Uint8List(1 << 20);
          await Future<void>.delayed(Duration.zero);
        }
      }

      final c = ProviderContainer(overrides: [httpClientProvider.overrideWithValue(MockClient.streaming((r, _) async => http.StreamedResponse(endlos(), 206)))]);
      addTearDown(c.dispose);
      expect((await c.read(karteDateiProvider.future))!.west, closeTo(5.49, 1e-6));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gezogen, 0);
    });

    test('404, index.html mit 200 (Fang-Block der Web-App), 200 ohne Range, Fehler: nicht vorhanden', () async {
      expect(await pruefen((r) => http.Response('nicht da', 404)), isFalse);
      expect(await pruefen((r) => http.Response('<!doctype html><html>', 200)), isFalse);
      expect(await pruefen((r) => http.Response.bytes(pmtiles, 200)), isFalse);
      expect(await pruefen((r) => http.Response.bytes(Uint8List.fromList(List.filled(16, 1)), 206)), isFalse);
      final c = ProviderContainer(overrides: [httpClientProvider.overrideWithValue(MockClient((r) async => throw http.ClientException('offline')))]);
      addTearDown(c.dispose);
      // ein Netzfehler ist kein "nicht vorhanden": Fehlerzustand, damit die Seite es von selbst wieder versucht
      await expectLater(c.read(karteDateiProvider.future), throwsA(isA<http.ClientException>()));
    });

    test('Serverfehler (5xx) ist ein Fehlerzustand, 404 und 403 sind "nicht vorhanden"', () async {
      Future<KartenBereich?> mit(int status) {
        final c = ProviderContainer(overrides: [httpClientProvider.overrideWithValue(MockClient((r) async => http.Response('x', status)))]);
        addTearDown(c.dispose);
        return c.read(karteDateiProvider.future);
      }

      expect(await mit(404), isNull);
      expect(await mit(403), isNull);
      await expectLater(mit(502), throwsA(isA<http.ClientException>()));
    });
  });

  group('Kartenstil dunkel/hell', () {
    final hellVorlage = File('assets/karte/style-hell.json').readAsStringSync();

    test('Auswahl: Standard dunkel, Umschalten, unbekannte Werte ergeben null', () {
      expect(kKartenStilStandard, KartenStil.dunkel);
      expect(KartenStil.dunkel.anderer, KartenStil.hell);
      expect(KartenStil.hell.anderer, KartenStil.dunkel);
      expect(KartenStil.aus('hell'), KartenStil.hell);
      expect(KartenStil.aus('dunkel'), KartenStil.dunkel);
      expect(KartenStil.aus('system'), isNull);
      expect(KartenStil.aus(null), isNull);
      // der Knopf nennt, was er bewirkt
      expect(KartenStil.dunkel.umschaltText, 'Helle Karte');
      expect(KartenStil.hell.umschaltText, 'Dunkle Karte');
    });

    test('Beide Stile: nur eigene Adressen, gleiche Quelle und Schriften, eigene Sprites; der helle ist wirklich hell', () {
      for (final stil in KartenStil.values) {
        final vorlage = File(stil.asset).readAsStringSync();
        final adressen = RegExp(r'https?://[^"\\\s<>]+').allMatches(vorlage).map((m) => m.group(0)!).toSet();
        expect(adressen, {'https://www.openstreetmap.org/copyright'}, reason: stil.wert);
        expect(vorlage, contains(kKarteAttribution), reason: stil.wert);
        // streng wie bisher: Platzhalter werden ersetzt, jede Fremd-Adresse wird abgelehnt
        final fertig = karteStyleAusVorlage(vorlage, 'https://familyhub.lx-labs.dev');
        expect(fertig, isNot(contains('{{')));
        expect(() => karteStyleAusVorlage(vorlage.replaceFirst('{{KARTE_BASE}}/glyphs', 'https://fremd.example/glyphs'), 'https://familyhub.lx-labs.dev'), throwsStateError);
      }
      Map<String, dynamic> lies(String t) => jsonDecode(t) as Map<String, dynamic>;
      final dunkel = lies(vorlage), hell = lies(hellVorlage);
      expect(dunkel['sprite'], '{{KARTE_BASE}}/sprites/black');
      expect(hell['sprite'], '{{KARTE_BASE}}/sprites/light');
      expect(hell['glyphs'], dunkel['glyphs']);
      expect(hell['sources'], dunkel['sources']);
      for (final n in ['light.json', 'light.png', 'light@2x.json', 'light@2x.png', 'black.json', 'black.png']) {
        expect(File('web/karte/sprites/$n').existsSync(), isTrue, reason: n);
      }
      // Hintergrundfarbe: hell deutlich heller als dunkel
      double helligkeit(Map<String, dynamic> st) {
        final bg = (st['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['type'] == 'background')['paint']['background-color'] as String;
        return Color(int.parse('FF${bg.substring(1)}', radix: 16)).computeLuminance();
      }
      expect(helligkeit(hell), greaterThan(0.6));
      expect(helligkeit(dunkel), lessThan(0.05));
    });

    test('Speicher: Standard, gespeicherter Wert, Wahl wird abgelegt, kaputter oder werfender Speicher stört nicht', () async {
      Future<(ProviderContainer, KartenStilNotifier)> start(MemoryKartenStilSpeicher sp) async {
        final c = ProviderContainer(overrides: [kartenStilSpeicherProvider.overrideWithValue(sp)]);
        addTearDown(c.dispose);
        final n = c.read(kartenStilProvider.notifier);
        await n.bereit;
        return (c, n);
      }

      var (c, n) = await start(MemoryKartenStilSpeicher());
      expect(c.read(kartenStilProvider), KartenStil.dunkel);
      var sp = MemoryKartenStilSpeicher('hell');
      (c, n) = await start(sp);
      expect(c.read(kartenStilProvider), KartenStil.hell);
      await n.umschalten();
      expect(c.read(kartenStilProvider), KartenStil.dunkel);
      expect(sp.wert, 'dunkel');
      (c, n) = await start(MemoryKartenStilSpeicher('quatsch'));
      expect(c.read(kartenStilProvider), KartenStil.dunkel);
      sp = MemoryKartenStilSpeicher()..wirft = true;
      (c, n) = await start(sp);
      expect(c.read(kartenStilProvider), KartenStil.dunkel);
      await n.setzen(KartenStil.hell); // Speichern scheitert still, die Wahl gilt
      expect(c.read(kartenStilProvider), KartenStil.hell);
    });

    test('Wahl vor dem Ende des Lesens wird nicht vom gespeicherten Wert überschrieben', () async {
      final sp = MemoryKartenStilSpeicher('hell');
      final c = ProviderContainer(overrides: [kartenStilSpeicherProvider.overrideWithValue(sp)]);
      addTearDown(c.dispose);
      final n = c.read(kartenStilProvider.notifier);
      final fertig = n.setzen(KartenStil.dunkel);
      await n.bereit;
      await fertig;
      expect(c.read(kartenStilProvider), KartenStil.dunkel);
    });
  });

  group('Stecknadel', () {
    test('Umriss: Spitze liegt auf der Mitte der Unterkante, Kopf ist gefüllt, Ecken sind leer', () {
      final pfad = PinMaler.umriss(kPinGroesse);
      expect(pfad.contains(Offset(kPinGroesse.width / 2, kPinGroesse.height - 2)), isTrue);
      expect(pfad.contains(Offset(kPinGroesse.width / 2, PinMaler.kopfMitteY)), isTrue);
      expect(pfad.contains(const Offset(2, 2)), isFalse);
      expect(pfad.contains(Offset(kPinGroesse.width - 2, kPinGroesse.height - 2)), isFalse);
      expect(pfad.contains(Offset(2, kPinGroesse.height - 2)), isFalse);
      expect(kPinGroesse.width, greaterThanOrEqualTo(44));
    });

    testWidgets('Kopf zeigt Initialen, Platzhalter-Zeichnung oder Foto der Person; die Größe bleibt gleich', (tester) async {
      Future<void> zeige(UserDto u, {List<Override> ueber = const []}) async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: ueber,
            child: MaterialApp(
              theme: buildTheme(),
              home: Scaffold(body: Center(child: StandortPin(user: u, name: u.displayName, farbIndex: u.colorIndex))),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      await zeige(_user(_ben, 'Ben Beispiel', 2));
      expect(find.text('BB'), findsOneWidget);
      // die Initialen sitzen auf einer dunklen Scheibe: sonst wären sie in der Farbe der Nadel unsichtbar
      expect(find.descendant(of: find.byType(StandortPin), matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == kSurface)), findsOneWidget);
      expect(tester.getSize(find.byType(StandortPin)), kPinGroesse);
      await zeige(_user(_ben, 'Ben', 2, avatar: const AvatarDto.vorlage('V01', 1)));
      expect(find.byType(Image), findsOneWidget);
      await zeige(
        _user(_ben, 'Ben', 2, avatar: const AvatarDto.foto(3)),
        ueber: [avatarFotoProvider.overrideWith((ref, k) async => _png)],
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.getSize(find.byType(StandortPin)), kPinGroesse);
    });
  });

  group('Karte (Attrappe statt MapLibre)', () {
    GeteiltePosition teilt(String id, {double lat = 50.56, double lng = 7.97, Duration alter = const Duration(minutes: 2), double? g = 12}) =>
        GeteiltePosition(userId: id, shareId: 's$id', endetAt: jetzt.add(const Duration(hours: 1)), breite: lat, laenge: lng, genauigkeit: g, messzeit: jetzt.subtract(alter));

    Future<void> zeige(
      WidgetTester tester,
      List<GeteiltePosition> liste, {
      bool verfuegbar = true,
      StandortState? zustand,
      double skala = 1.0,
      Future<String> Function(KartenStil)? stil,
      MemoryKartenStilSpeicher? stilSpeicher,
      bool laedtNie = false,
      http.Client? httpClient,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = skala;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final namen = {_ben: _user(_ben, 'Ben', 2), _cora: _user(_cora, 'Cora Berger', 4, avatar: const AvatarDto.vorlage('V01', 1))};
      await tester.pumpWidget(
        ProviderScope(
            key: UniqueKey(),
          overrides: [
            authProvider.overrideWith(() => _FakeAuth(_user(_ich, 'Anna', 0))),
            standortProvider.overrideWith(() => _Steuerung(zustand ?? const StandortState())),
            standortUhrProvider.overrideWith((ref) => () => jetzt),
            karteAttrappeProvider.overrideWithValue(true),
            karteStilProvider.overrideWithValue(stil ?? (_) async => '{}'),
            kartenStilSpeicherProvider.overrideWithValue(stilSpeicher ?? MemoryKartenStilSpeicher()),
            karteAttrappeLaedtNieProvider.overrideWithValue(laedtNie),
            karteLadeFristProvider.overrideWithValue(const Duration(seconds: 10)),
            if (httpClient == null) karteDateiProvider.overrideWith((ref) async => verfuegbar ? KartenBereich.westerburg175 : null) else httpClientProvider.overrideWithValue(httpClient),
          ],
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(body: ListView(padding: const EdgeInsets.all(20), children: [StandortKarte(positionen: liste, mitglieder: namen)])),
          ),
        ),
      );
      await warte(tester);
    }

    testWidgets('Nadeln für alle mit Position (ohne Position und ungeprüfte nicht), Info beim Tippen: Name, "vor X", Genauigkeit', (tester) async {
      await zeige(tester, [
        teilt(_ben),
        teilt(_cora, alter: const Duration(minutes: 9), g: 1400),
        GeteiltePosition(userId: 'x', shareId: 'sx', endetAt: jetzt.add(const Duration(hours: 1))),
      ]);
      expect(find.byType(StandortPin), findsNWidgets(2));
      expect(find.text('Karte noch nicht eingerichtet'), findsNothing);
      expect(find.text(kKarteAttribution), findsOneWidget);
      final sem = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Standort von Ben'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Standort von Cora Berger, nicht mehr aktuell')), findsOneWidget);
      sem.dispose();
      await tippe(tester, find.byType(StandortPin).first);
      expect(find.text('vor 2 Min · ± 12 m'), findsOneWidget);
      await tippe(tester, find.byType(StandortPin).at(1));
      expect(find.text('vor 9 Min · ± 1,4 km'), findsOneWidget);
      await tippe(tester, find.byTooltip('Schließen'));
      expect(find.text('vor 9 Min · ± 1,4 km'), findsNothing);
    });

    testWidgets('Knöpfe: "Alle zeigen" immer, "Auf mich zentrieren" nur mit eigener Position; eigene Nadel heißt "Du"', (tester) async {
      await zeige(tester, [teilt(_ben)]);
      expect(find.byTooltip('Alle zeigen'), findsOneWidget);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.my_location)).onPressed, isNull);
      await zeige(
        tester,
        [teilt(_ben)],
        zustand: StandortState(phase: StandortPhase.teilt, endetAt: jetzt.add(const Duration(hours: 1)), eigene: GeraetePosition(breite: 50.5, laenge: 7.9, genauigkeit: 8, zeit: jetzt)),
      );
      expect(find.byType(StandortPin), findsNWidgets(2));
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.my_location)).onPressed, isNotNull);
      await tippe(tester, find.byType(StandortPin).last);
      expect(find.text('Du'), findsOneWidget);
    });

    testWidgets('Folgen: mit einer einzigen Person an (Knopf aktiv, Tooltip "Folgen beenden"), Tippen schaltet aus und wieder an; 44 px Touch-Ziel', (tester) async {
      await zeige(tester, [teilt(_ben)]);
      expect(find.byTooltip('Folgen beenden'), findsOneWidget);
      expect(find.byIcon(Icons.gps_fixed), findsOneWidget);
      final groesse = tester.getSize(find.widgetWithIcon(IconButton, Icons.gps_fixed));
      expect(groesse.width, greaterThanOrEqualTo(44));
      expect(groesse.height, greaterThanOrEqualTo(44));
      await tippe(tester, find.byTooltip('Folgen beenden'));
      expect(find.byTooltip('Folgen'), findsOneWidget);
      expect(find.byIcon(Icons.gps_not_fixed), findsOneWidget);
      await tippe(tester, find.byTooltip('Folgen'));
      expect(find.byTooltip('Folgen beenden'), findsOneWidget);
    });

    testWidgets('Folgen: bei mehreren Personen ohne Auswahl gesperrt; Tipp auf eine Nadel wählt sie und schaltet Folgen an; "Alle zeigen" schaltet aus', (tester) async {
      await zeige(tester, [teilt(_ben), teilt(_cora)]);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.gps_not_fixed)).onPressed, isNull);
      await tippe(tester, find.byType(StandortPin).first);
      expect(find.byTooltip('Folgen beenden'), findsOneWidget);
      await tippe(tester, find.byTooltip('Alle zeigen'));
      expect(find.byTooltip('Folgen'), findsOneWidget);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.gps_not_fixed)).onPressed, isNotNull); // eine Person ist noch gewählt
    });

    testWidgets('Außerhalb des Kartenbereichs: Hinweis, keine Nadel; die Person bleibt in der Liste (hier: nicht Teil der Karte)', (tester) async {
      await zeige(tester, [teilt(_ben), teilt(_cora, lat: 48.8566, lng: 2.3522)]);
      expect(find.byType(StandortPin), findsOneWidget);
      expect(find.textContaining('Cora Berger: außerhalb des Kartenbereichs'), findsOneWidget);
    });

    testWidgets('Ohne Kartendatei: "Karte noch nicht eingerichtet", Hinweis auf die Liste, "Erneut prüfen"; keine Nadeln', (tester) async {
      await zeige(tester, [teilt(_ben)], verfuegbar: false);
      expect(find.text('Karte noch nicht eingerichtet'), findsOneWidget);
      expect(find.textContaining('Die Liste unten zeigt weiterhin alle Positionen'), findsOneWidget);
      expect(find.text('Erneut prüfen'), findsOneWidget);
      expect(find.byType(StandortPin), findsNothing);
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('Layout bei 360 px, Textskala $skala: kein Überlauf, Touch-Ziele mindestens 44 px', (tester) async {
        await zeige(
          tester,
          [teilt(_ben), teilt(_cora, lat: 48.8566, lng: 2.3522)],
          skala: skala,
          zustand: StandortState(phase: StandortPhase.teilt, endetAt: jetzt.add(const Duration(hours: 1)), eigene: GeraetePosition(breite: 50.5, laenge: 7.9, genauigkeit: 8, zeit: jetzt)),
        );
        await tippe(tester, find.byType(StandortPin).first);
        expect(tester.takeException(), isNull);
        expect(kleineZiele(tester), isEmpty);
        for (final pin in tester.widgetList<StandortPin>(find.byType(StandortPin))) {
          expect(pin, isNotNull);
        }
        expect(tester.getSize(find.byType(StandortPin).first).width, greaterThanOrEqualTo(44));
      });
    }

    testWidgets('Netzfehler ist "Karte nicht erreichbar" (nicht "nicht eingerichtet"); "Erneut prüfen" und die Rückkehr in die App versuchen es wieder', (tester) async {
      var online = false;
      // MockClient liefert über echte Ereignisschleifen: im Widget-Test mit kurzer echter Wartezeit abwarten
      Future<void> netz(WidgetTester t) async {
        await warte(t);
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await warte(t);
      }

      final client = MockClient((r) async {
        if (!online) throw http.ClientException('offline');
        return http.Response.bytes(_kopfBytes(5.49, 48.99, 10.45, 52.14), 206);
      });
      await zeige(tester, [teilt(_ben)], httpClient: client);
      await netz(tester);
      expect(find.text('Karte nicht erreichbar'), findsOneWidget);
      expect(find.text('Karte noch nicht eingerichtet'), findsNothing);
      online = true;
      await tippe(tester, find.text('Erneut prüfen'));
      await netz(tester);
      expect(find.byType(StandortPin), findsOneWidget);
      // und wieder weg, dann Rückkehr in die App
      online = false;
      await zeige(tester, [teilt(_ben)], httpClient: client);
      await netz(tester);
      expect(find.text('Karte nicht erreichbar'), findsOneWidget);
      online = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await netz(tester);
      expect(find.byType(StandortPin), findsOneWidget);
    });

    testWidgets('Karte bleibt leer (kein "Stil geladen"): keine Nadeln, nach 10 s Meldung statt leerer Fläche, "Erneut versuchen" startet neu', (tester) async {
      await zeige(tester, [teilt(_ben)], laedtNie: true);
      expect(find.byType(StandortPin), findsNothing, reason: 'ohne geladene Karte keine Nadeln');
      expect(find.text('Karte konnte nicht geladen werden'), findsNothing);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Karte konnte nicht geladen werden'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Karte konnte nicht geladen werden'), findsOneWidget);
      expect(find.text('Erneut versuchen'), findsOneWidget);
      // neuer Versuch: Meldung weg, nach der Frist wieder da (die Attrappe lädt hier nie)
      await tester.tap(find.text('Erneut versuchen'));
      await tester.pump();
      expect(find.text('Karte konnte nicht geladen werden'), findsNothing);
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('Karte konnte nicht geladen werden'), findsOneWidget);
    });

    testWidgets('Geladene Karte: keine Zeitüberschreitung, Nadeln da', (tester) async {
      await zeige(tester, [teilt(_ben)]);
      await tester.pump(const Duration(seconds: 15));
      expect(find.text('Karte konnte nicht geladen werden'), findsNothing);
      expect(find.byType(StandortPin), findsOneWidget);
    });

    testWidgets('Fehler beim Laden des Stils: "Erneut prüfen" lädt ihn neu (der Fehler bleibt nicht gemerkt)', (tester) async {
      var versuche = 0;
      await zeige(tester, [teilt(_ben)], stil: (_) async {
        if (++versuche == 1) throw StateError('kaputt');
        return '{}';
      });
      expect(find.textContaining('Der Kartenstil konnte nicht geladen werden'), findsOneWidget);
      await tippe(tester, find.text('Erneut prüfen'));
      expect(versuche, 2);
      expect(find.byType(StandortPin), findsOneWidget);
    });

    testWidgets('Eigene Position außerhalb des Kartenbereichs: Hinweis "Du", "Auf mich zentrieren" gesperrt', (tester) async {
      await zeige(
        tester,
        [teilt(_ben)],
        zustand: StandortState(phase: StandortPhase.teilt, endetAt: jetzt.add(const Duration(hours: 1)), eigene: GeraetePosition(breite: 40.0, laenge: 3.0, zeit: jetzt)),
      );
      expect(find.textContaining('Du: außerhalb des Kartenbereichs'), findsOneWidget);
      expect(find.byType(StandortPin), findsOneWidget);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.my_location)).onPressed, isNull);
    });

    testWidgets('Stil umschalten: Knopf nennt die Wirkung, der neue Stil wird geladen, die Wahl liegt im Speicher, die Nadeln bleiben', (tester) async {
      final geladen = <KartenStil>[];
      final sp = MemoryKartenStilSpeicher();
      await zeige(tester, [teilt(_ben)], stilSpeicher: sp, stil: (st) async {
        geladen.add(st);
        return '{}';
      });
      expect(geladen, [KartenStil.dunkel]);
      expect(find.byTooltip('Helle Karte'), findsOneWidget);
      expect(find.byTooltip('Dunkle Karte'), findsNothing);
      expect(find.byIcon(Icons.light_mode), findsOneWidget);
      await tippe(tester, find.byTooltip('Helle Karte'));
      expect(geladen, [KartenStil.dunkel, KartenStil.hell]);
      expect(sp.wert, 'hell');
      expect(find.byTooltip('Dunkle Karte'), findsOneWidget);
      expect(find.byIcon(Icons.dark_mode), findsOneWidget);
      expect(find.byType(StandortPin), findsOneWidget);
      await tippe(tester, find.byTooltip('Dunkle Karte'));
      expect(geladen.last, KartenStil.dunkel);
      expect(sp.wert, 'dunkel');
    });

    testWidgets('Stilwechsel scheitert: die Karte bleibt im gezeigten Stil, Knopf und Nadeln bleiben, ein späterer Wechsel klappt', (tester) async {
      var hellFehler = true;
      await zeige(tester, [teilt(_ben)], stil: (st) async {
        if (st == KartenStil.hell && hellFehler) throw StateError('kaputt');
        return '{}';
      });
      await tippe(tester, find.byTooltip('Helle Karte'));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Helle Karte'), findsOneWidget, reason: 'die Karte zeigt weiter dunkel');
      expect(find.byType(StandortPin), findsOneWidget);
      hellFehler = false;
      // Wahl steht (Gerätewahl) auf hell, die Karte zeigt dunkel: erst zurück auf dunkel, dann wieder hell
      await tippe(tester, find.byTooltip('Helle Karte'));
      await tippe(tester, find.byTooltip('Helle Karte'));
      expect(find.byTooltip('Dunkle Karte'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(StandortPin), findsOneWidget);
    });

    testWidgets('Schnelles Hin und Zurück (dunkel, hell, dunkel) vor dem Ende des Ladens: kein Stilwechsel, nichts Halbes', (tester) async {
      final hell = Completer<String>();
      final geladen = <KartenStil>[];
      await zeige(tester, [teilt(_ben)], stil: (st) {
        geladen.add(st);
        return st == KartenStil.hell ? hell.future : Future.value('{}');
      });
      await tippe(tester, find.byTooltip('Helle Karte')); // Wahl hell, Laden läuft
      final c = ProviderScope.containerOf(tester.element(find.byType(StandortKarte)));
      await c.read(kartenStilProvider.notifier).setzen(KartenStil.dunkel); // wieder dunkel
      hell.complete('{}');
      await warte(tester);
      expect(geladen, [KartenStil.dunkel, KartenStil.hell]);
      expect(find.byTooltip('Helle Karte'), findsOneWidget, reason: 'die Karte blieb dunkel');
      expect(find.byType(StandortPin), findsOneWidget);
    });

    testWidgets('Wahl während des ersten Ladens wird danach angewendet', (tester) async {
      final erst = Completer<String>();
      final geladen = <KartenStil>[];
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(() => _FakeAuth(_user(_ich, 'Anna', 0))),
            standortProvider.overrideWith(() => _Steuerung(const StandortState())),
            standortUhrProvider.overrideWith((ref) => () => jetzt),
            karteAttrappeProvider.overrideWithValue(true),
            karteStilProvider.overrideWithValue((st) {
              geladen.add(st);
              return geladen.length == 1 ? erst.future : Future.value('{}');
            }),
            kartenStilSpeicherProvider.overrideWithValue(MemoryKartenStilSpeicher()),
            karteDateiProvider.overrideWith((ref) async => KartenBereich.westerburg175),
          ],
          child: MaterialApp(theme: buildTheme(), home: Scaffold(body: ListView(children: [StandortKarte(positionen: [teilt(_ben)], mitglieder: {_ben: _user(_ben, 'Ben', 2)})]))),
        ),
      );
      await warte(tester);
      final c = ProviderScope.containerOf(tester.element(find.byType(StandortKarte)));
      await c.read(kartenStilProvider.notifier).setzen(KartenStil.hell);
      erst.complete('{}');
      await warte(tester);
      expect(geladen, [KartenStil.dunkel, KartenStil.hell]);
      expect(find.byTooltip('Dunkle Karte'), findsOneWidget);
    });

    testWidgets('Vollbild zehnmal öffnen und schließen: immer genau eine Kartenfläche', (tester) async {
      await zeige(tester, [teilt(_ben)]);
      for (var i = 0; i < 10; i++) {
        await tippe(tester, find.byTooltip('Vollbild'));
        expect(find.byTooltip('Vollbild beenden'), findsOneWidget);
        expect(find.byType(StandortPin), findsOneWidget);
        await tippe(tester, find.byTooltip('Vollbild beenden'));
        expect(find.byTooltip('Vollbild'), findsOneWidget);
        expect(find.byType(StandortPin), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Vollbild mit Hinweiszettel (außerhalb des Bereichs): Textskala 1.5, kein Überlauf', (tester) async {
      await zeige(
        tester,
        [teilt(_ben)],
        skala: 1.5,
        zustand: StandortState(phase: StandortPhase.teilt, endetAt: jetzt.add(const Duration(hours: 1)), eigene: GeraetePosition(breite: 40.0, laenge: 3.0, zeit: jetzt)),
      );
      await tippe(tester, find.byTooltip('Vollbild'));
      expect(find.textContaining('außerhalb des Kartenbereichs'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(kleineZiele(tester), isEmpty);
    });

    testWidgets('Gespeicherte Wahl hell: die Karte startet gleich mit dem hellen Stil (kein Aufblitzen des dunklen)', (tester) async {
      final geladen = <KartenStil>[];
      await zeige(tester, [teilt(_ben)], stilSpeicher: MemoryKartenStilSpeicher('hell'), stil: (st) async {
        geladen.add(st);
        return '{}';
      });
      expect(geladen, [KartenStil.hell]);
      expect(find.byTooltip('Dunkle Karte'), findsOneWidget);
    });

    testWidgets('Vollbild: eine einzige Kartenfläche, Knöpfe und Nadeln bleiben, Auswahl bleibt beim Schließen, Schließen/Esc/Systemzurück beenden nur das Vollbild', (tester) async {
      await zeige(tester, [teilt(_ben), teilt(_cora, lat: 50.6)]);
      expect(find.byTooltip('Vollbild'), findsOneWidget);
      await tippe(tester, find.byType(StandortPin).first);
      expect(find.text('vor 2 Min · ± 12 m'), findsOneWidget);

      await tippe(tester, find.byTooltip('Vollbild'));
      expect(find.byTooltip('Vollbild beenden'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(find.text('Karte im Vollbild', skipOffstage: false), findsOneWidget, reason: 'die Karte in der Seite ist abgebaut');
      // genau zwei Nadeln: die der Vollbild-Karte (nie zusätzlich die der Seite)
      expect(find.byType(StandortPin), findsNWidgets(2));
      for (final t in ['Alle zeigen', 'Helle Karte']) {
        expect(find.byTooltip(t), findsOneWidget, reason: t);
      }
      expect(find.text(kKarteAttribution), findsOneWidget);
      expect(find.text('vor 2 Min · ± 12 m'), findsOneWidget, reason: 'die Auswahl ist mitgekommen');
      // Stil im Vollbild umschalten, dann zurück: die Wahl gilt auch in der Seite
      await tippe(tester, find.byTooltip('Helle Karte'));
      await tippe(tester, find.byTooltip('Vollbild beenden'));
      expect(find.byTooltip('Vollbild beenden'), findsNothing);
      expect(find.text('Karte im Vollbild'), findsNothing);
      expect(find.byTooltip('Vollbild'), findsOneWidget);
      expect(find.byTooltip('Dunkle Karte'), findsOneWidget);
      expect(find.byType(StandortPin), findsNWidgets(2));
      expect(find.text('vor 2 Min · ± 12 m'), findsOneWidget, reason: 'die Auswahl blieb');

      // Esc
      await tippe(tester, find.byTooltip('Vollbild'));
      expect(find.byTooltip('Vollbild beenden'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await warte(tester);
      expect(find.byTooltip('Vollbild beenden'), findsNothing);
      expect(find.byTooltip('Vollbild'), findsOneWidget);

      // Systemzurück: schließt nur das Vollbild, die Seite darunter bleibt
      await tippe(tester, find.byTooltip('Vollbild'));
      await tester.binding.handlePopRoute();
      await warte(tester);
      expect(find.byTooltip('Vollbild beenden'), findsNothing);
      expect(find.byType(StandortKarte), findsOneWidget);
      expect(find.byTooltip('Vollbild'), findsOneWidget);
    });

    testWidgets('Vollbild: "Auf mich zentrieren" nur mit eigener Position; Nadel antippen zeigt die Info', (tester) async {
      await zeige(
        tester,
        [teilt(_ben)],
        zustand: StandortState(phase: StandortPhase.teilt, endetAt: jetzt.add(const Duration(hours: 1)), eigene: GeraetePosition(breite: 50.55, laenge: 7.96, zeit: jetzt)),
      );
      await tippe(tester, find.byTooltip('Vollbild'));
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.my_location)).onPressed, isNotNull);
      await tippe(tester, find.byType(StandortPin).first);
      expect(find.byTooltip('Schließen'), findsOneWidget);
      await tippe(tester, find.byTooltip('Schließen'));
      expect(find.byTooltip('Schließen'), findsNothing);
    });

    testWidgets('Vollbild: Layout 360 px, Textskala 1.5, Touch-Ziele mindestens 44 px', (tester) async {
      await zeige(tester, [teilt(_ben), teilt(_cora, lat: 50.6)], skala: 1.5);
      expect(kleineZiele(tester), isEmpty, reason: 'in der Seite');
      await tippe(tester, find.byTooltip('Vollbild'));
      expect(tester.takeException(), isNull);
      expect(kleineZiele(tester), isEmpty, reason: 'im Vollbild');
      await tippe(tester, find.byType(StandortPin).first);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ohne Kartendatei: Layout 360 px, Textskala 1.5 (auch bei geringer Höhe ohne Überlauf)', (tester) async {
      await zeige(tester, [teilt(_ben)], verfuegbar: false, skala: 1.5);
      expect(tester.takeException(), isNull);
      expect(kleineZiele(tester), isEmpty);
    });
  });
}
