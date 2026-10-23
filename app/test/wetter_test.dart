// Wetter: Modell, Hilfen, Kachel auf der Startseite (mobil und Desktop), Detailseite, Offline-Stand, lokaler Schalter, Layout (360 px, Textskala 1.5).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/wetter/wetter_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/wetter/wetter_screen.dart';
import 'package:lx_fampad/widgets/kopfzeile.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Map<String, dynamic> _antwort({
  DateTime? gemessen,
  bool stale = false,
  double temp = 12.54,
  bool verlauf = true,
}) {
  final t = (gemessen ?? DateTime.now().subtract(const Duration(minutes: 5)))
      .toUtc();
  return {
    'available': true,
    'place': 'Westerburg',
    'current': {
      'measuredAt': t.toIso8601String(),
      'stale': stale,
      'temperature': temp,
      'humidity': 71,
      'pressure': 1013.2,
      'rain1h': 0.5,
      'rain24h': 2.1,
      'windKmh': 12,
      'gustKmh': 25,
      'windAngle': 270,
    },
    'min24h': 3.0,
    'max24h': 18.5,
    'series': [
      if (verlauf)
        for (var i = 0; i < 6; i++)
          {
            't': t.subtract(Duration(hours: 5 - i)).toIso8601String(),
            'temperature': 5.0 + i * 2,
          },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(
    WidgetTester tester, {
    Object? Function()? wetter,
    Future<void> Function(TestUmgebung)? vorher,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
  }) async {
    final env = await angemeldeteUmgebung();
    await vorher?.call(env);
    env.server.on('GET /weather', (_) {
      final w = wetter == null ? _antwort() : wetter();
      if (w == null) return fehler(503, 'unavailable');
      return jsonAntwort(w);
    });
    await starteApp(tester, env, skala: skala, groesse: groesse);
    return env;
  }

  group('Modell und Hilfen', () {
    test('WetterDto liest die Antwort des Servers; fehlende Messwerte bleiben null, kaputte Verlaufspunkte fallen weg', () {
      final dto = WetterDto.fromJson({
        ..._antwort(),
        'series': [
          {'t': '2026-10-21T08:00:00Z', 'temperature': 5},
          {'t': 'kaputt', 'temperature': 6},
          {'t': '2026-10-21T09:00:00Z'},
        ],
      });
      expect(dto.verfuegbar, isTrue);
      expect(dto.ort, 'Westerburg');
      expect(dto.aktuell!.temperatur, closeTo(12.54, 0.001));
      expect(dto.aktuell!.windRichtung, 270);
      expect(dto.verlauf, hasLength(1));
      final ohne = WetterDto.fromJson({
        'available': true,
        'place': 'X',
        'current': {'measuredAt': '2026-10-21T08:00:00Z', 'stale': false},
        'series': <Object>[],
      });
      expect(ohne.aktuell!.temperatur, isNull);
      expect(WetterDto.fromJson({'available': false}).verfuegbar, isFalse);
      expect(() => WetterDto.fromJson('kein json'), throwsA(anything));
    });

    test('Texte: Komma, Einheiten, Himmelsrichtung, Stand', () {
      expect(temperaturText(12.54), '12,5 °C');
      expect(temperaturText(null), '–');
      expect(feuchteText(70.6), '71 %');
      expect(druckText(1013.2), '1013 hPa');
      expect(regenText(2.1), '2,1 mm');
      expect(windText(12.4), '12 km/h');
      expect([0.0, 44.0, 90.0, 180.0, 270.0, 359.0].map(windRichtungText), [
        'N',
        'NO',
        'O',
        'S',
        'W',
        'N',
      ]);
      final jetzt = DateTime(2026, 10, 21, 12);
      expect(standText(DateTime(2026, 10, 21, 8, 5), jetzt), '08:05');
      expect(standText(DateTime(2026, 10, 20, 23, 5), jetzt), '20.10. 23:05');
    });
  });

  testWidgets(
    'Startseite: Kachel mit Ort, Temperatur, Stand und Min/Max; Tippen öffnet die Detailseite mit allen Werten',
    (tester) async {
      await start(tester);
      expect(find.text('// WETTER'), findsOneWidget);
      expect(find.text('Westerburg'), findsOneWidget);
      expect(find.text('12,5 °C'), findsOneWidget);
      expect(find.textContaining('Stand '), findsOneWidget);
      expect(find.textContaining('min 3,0 °C · max 18,5 °C'), findsOneWidget);
      // keine Straße, keine Koordinaten, keine Karte
      expect(find.textContaining('straße', findRichText: true), findsNothing);
      await tippe(tester, find.text('Westerburg'));
      expect(find.byType(WetterScreen), findsOneWidget);
      expect(find.text('71 %'), findsOneWidget);
      expect(find.text('1013 hPa'), findsOneWidget);
      expect(find.text('0,5 mm / 2,1 mm'), findsOneWidget);
      expect(find.text('12 km/h aus W'), findsOneWidget);
      expect(find.text('25 km/h'), findsOneWidget);
      expect(find.text('3,0 °C / 18,5 °C'), findsOneWidget);
      expect(find.text('// VERLAUF 24 H'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      pruefeLayout(tester, 'Wetter-Detail');
    },
  );

  testWidgets(
    'Detailseite bei 360 px und Textskala 1.5: nichts läuft über, Touch-Ziele mindestens 44 px',
    (tester) async {
      await start(tester, skala: 1.5);
      pruefeLayout(tester, 'Kachel 1.5');
      await tippe(tester, find.text('Westerburg'));
      expect(find.byType(WetterScreen), findsOneWidget);
      pruefeLayout(tester, 'Detail 1.5');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await warte(tester);
      pruefeLayout(tester, 'Detail 1.5 unten');
    },
  );

  testWidgets(
    'Schalter: ausgeschaltet verschwindet die Kachel, die Wahl bleibt lokal gespeichert (nie auf dem Server)',
    (tester) async {
      final env = await start(tester);
      await tippe(tester, find.text('Westerburg'));
      final schalter = find.byType(Switch);
      expect(tester.widget<Switch>(schalter).value, isTrue);
      await tippe(tester, schalter);
      expect(tester.widget<Switch>(schalter).value, isFalse);
      expect(await env.db.metaLesen(kWetterAnzeigenSchluessel), 'nein');
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
      expect(find.text('// WETTER'), findsNothing);
      expect(
        env.server.log.where(
          (r) => r.method != 'GET' && r.path.contains('weather'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('Server hat Wetter aus: keine Kachel', (tester) async {
    await start(tester, wetter: () => {'available': false});
    expect(find.text('// WETTER'), findsNothing);
  });

  testWidgets(
    'Noch keine Messung: keine Kachel, Detailseite nicht erreichbar',
    (tester) async {
      await start(
        tester,
        wetter: () => {
          'available': true,
          'place': 'Westerburg',
          'current': null,
          'min24h': null,
          'max24h': null,
          'series': <Object>[],
        },
      );
      expect(find.text('// WETTER'), findsNothing);
    },
  );

  testWidgets(
    'Offline-Stand: der Server antwortet nicht, die Kachel zeigt den gespeicherten Stand mit Zeitstempel und "offline"',
    (tester) async {
      final gemessen = DateTime.now().subtract(const Duration(hours: 2));
      await start(
        tester,
        wetter: () => null,
        vorher: (env) async {
          await env.db.metaSchreiben(
            kWetterCacheSchluessel,
            jsonEncode({
              'abgerufen': DateTime.now()
                  .subtract(const Duration(hours: 2))
                  .toIso8601String(),
              'daten': _antwort(gemessen: gemessen, temp: 9.1),
            }),
          );
        },
      );
      expect(find.text('9,1 °C'), findsOneWidget);
      expect(find.textContaining('· offline'), findsOneWidget);
      await tippe(tester, find.text('Westerburg'));
      expect(find.textContaining('zuletzt abgerufen'), findsOneWidget);
      pruefeLayout(tester, 'Offline-Stand');
    },
  );

  testWidgets('Veraltete Messung wird als "veraltet" markiert', (tester) async {
    await start(
      tester,
      wetter: () => _antwort(
        gemessen: DateTime.now().subtract(const Duration(hours: 3)),
        stale: true,
      ),
    );
    expect(find.textContaining('· veraltet'), findsOneWidget);
  });

  testWidgets(
    'Desktop: Karte "Wetter" im Raster, Tippen öffnet die Detailseite',
    (tester) async {
      await start(tester, groesse: const Size(1440, 900));
      expect(find.byType(DesktopHome), findsOneWidget);
      expect(find.text('// WETTER'), findsOneWidget);
      expect(find.text('12,5 °C'), findsOneWidget);
      await tippe(tester, find.text('Westerburg'));
      expect(find.byType(WetterScreen), findsOneWidget);
      // Detailseite als Bereich der Shell: Seitenleiste und Fußzeile bleiben, kein Zurück-Pfeil, Kopfzeile wie bei den anderen Bereichen
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.textContaining('sync: '), findsOneWidget);
      expect(find.byTooltip('Zurück'), findsNothing);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('Wetter'), findsNWidgets(2)); // Seitenleiste + Kopfzeile
      expect(find.byTooltip('Aktualisieren'), findsOneWidget);
      // Kopfzeile sitzt auf Höhe der anderen Bereiche (16 px unter dem Rand)
      expect(tester.getTopLeft(find.byType(TabKopfzeile)).dy, 16);
      // zurück über die Seitenleiste
      await tippe(tester, find.bySemanticsLabel('Start'));
      expect(find.byType(DesktopHome), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Desktop: Seitenleiste zeigt "Wetter" nur bei sichtbarer Kachel', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, groesse: const Size(1440, 900));
    expect(find.bySemanticsLabel('Wetter'), findsOneWidget);
    await tippe(tester, find.bySemanticsLabel('Wetter'));
    expect(find.byType(WetterScreen), findsOneWidget);
    // Schalter aus: der geöffnete Bereich bleibt in der Leiste (verschwindet nicht unter dir), Kachel ist weg
    await tippe(tester, find.byType(Switch));
    expect(find.bySemanticsLabel('Wetter'), findsOneWidget);
    await tippe(tester, find.bySemanticsLabel('Start'));
    expect(find.bySemanticsLabel('Wetter'), findsNothing);
    expect(find.text('// WETTER'), findsNothing);
    handle.dispose();
  });

  for (final groesse in [const Size(360, 800), const Size(1440, 900)]) {
    testWidgets('${groesse.width.toInt()} px: Profil schaltet "Wetter anzeigen" auch bei ausgeschalteter Kachel wieder ein', (tester) async {
      await start(tester, groesse: groesse);
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold, skipOffstage: false).first));
      await c.read(wetterProvider.notifier).anzeigenSetzen(false);
      await warte(tester);
      expect(find.text('// WETTER'), findsNothing);
      if (groesse.width < 900) {
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      } else {
        await tippe(tester, find.byIcon(Icons.settings_outlined));
      }
      await tippeText(tester, 'Startseite und Anzeige');
      expect(find.text('Wetter anzeigen'), findsOneWidget);
      await tippe(tester, find.widgetWithText(SwitchListTile, 'Wetter anzeigen'));
      expect(c.read(wetterProvider).anzeigen, isTrue);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.text('// WETTER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Profil: Server ohne Wetter zeigt nur einen Hinweis statt des Schalters', (tester) async {
    await start(tester, wetter: () => <String, dynamic>{'available': false});
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippeText(tester, 'Startseite und Anzeige');
    expect(find.textContaining('nicht eingerichtet'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Wetter anzeigen'), findsNothing);
  });

  testWidgets('Desktop: ohne Wetter keine Seitenleisten-Zeile', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, groesse: const Size(1440, 900), wetter: () => null);
    expect(find.bySemanticsLabel('Wetter'), findsNothing);
    handle.dispose();
  });

  testWidgets('Desktop, Textskala 1.5: Wetter-Bereich ohne Layoutfehler', (tester) async {
    await start(tester, groesse: const Size(1200, 800), skala: 1.5);
    await tippe(tester, find.text('Westerburg'));
    expect(find.byType(WetterScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
