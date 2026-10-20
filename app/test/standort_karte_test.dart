// Karte der Teilenden: Stil-Vorlage ohne Fremd-Adressen, Kartenbereich, Stecknadel (Spitze, Profilbild), Karte mit Attrappe statt MapLibre (Nadeln, Info beim
// Tippen, Knöpfe, außerhalb des Kartenbereichs), Rückfall "Karte noch nicht eingerichtet" bei fehlender Datei. 360 px, Textskala 1.5.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
      final s = karteStyleAusVorlage(vorlage, 'https://familie.lx-labs.dev');
      expect(s, contains('pmtiles://https://familie.lx-labs.dev/karte-daten/westerwald.pmtiles'));
      expect(s, contains('https://familie.lx-labs.dev/karte/glyphs/{fontstack}/{range}.pbf'));
      expect(s, isNot(contains('{{')));
      expect(() => karteStyleAusVorlage('{"glyphs":"https://demotiles.maplibre.org/{fontstack}"}', 'https://familie.lx-labs.dev'), throwsStateError);
      expect(() => karteStyleAusVorlage('{"a":"{{UNBEKANNT}}"}', 'https://familie.lx-labs.dev'), throwsStateError);
    });

    test('Basisadresse: Define vor API_BASE vor Herkunft der Seite vor Produktion', () {
      expect(karteOrigin(base: 'http://10.0.2.2:8150/', api: 'https://x', web: false), 'http://10.0.2.2:8150');
      expect(karteOrigin(base: '', api: '', web: true, seite: 'https://familie.lx-labs.dev'), 'https://familie.lx-labs.dev');
      expect(karteOrigin(base: '', api: '', web: false), 'https://familie.lx-labs.dev');
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
      Future<String> Function()? stil,
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
            karteStilProvider.overrideWithValue(stil ?? () async => '{}'),
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
      await zeige(tester, [teilt(_ben)], stil: () async {
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

    testWidgets('Ohne Kartendatei: Layout 360 px, Textskala 1.5 (auch bei geringer Höhe ohne Überlauf)', (tester) async {
      await zeige(tester, [teilt(_ben)], verfuegbar: false, skala: 1.5);
      expect(tester.takeException(), isNull);
      expect(kleineZiele(tester), isEmpty);
    });
  });
}
