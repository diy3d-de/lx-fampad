// Wetter, Station-Paket: interaktiver Verlauf (Berühren, Maus, Pfeiltasten, Chips, Zeitraum, Screenreader), erweiterte Seite, Hinweise (Schalter, Warnkarte,
// lokale Benachrichtigung mit Entprellung), alles bei 360 px und Textskala 1.5/2.0. Ältere Server (nur Temperatur) bleiben bedienbar.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart' show ChatAnzeigePort;
import 'package:lx_fampad/data/push/chat_benachrichtiger_provider.dart' show chatAnzeigePortProvider;
import 'package:lx_fampad/data/wetter/wetter_hinweise.dart';
import 'package:lx_fampad/data/wetter/wetter_logik.dart' show WetterHinweisArt;
import 'package:lx_fampad/data/wetter/wetter_state.dart';
import 'package:lx_fampad/features/wetter/wetter_hinweis_karte.dart';
import 'package:lx_fampad/features/wetter/wetter_screen.dart';
import 'package:lx_fampad/features/wetter/wetter_verlauf_karte.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

class _Anzeige implements ChatAnzeigePort {
  final gezeigt = <({int id, String text, String nutzlast})>[];
  @override
  Future<bool> initialisieren() async => true;
  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async => true;
  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async {
    gezeigt.add((id: id, text: text, nutzlast: nutzlast));
    return true;
  }

  @override
  Future<void> entfernen(int id) async {}
}

/// Antwort mit Stundenreihen (168 Stunden bis zur laufenden Stunde), Tagen und Sonne.
Map<String, dynamic> _antwort({
  double temp = 12.5,
  double boeen = 25,
  bool regen = true,
  bool wind = true,
  bool druck = true,
  bool hourly = true,
  double druckJetzt = 1013.2,
  double druckAbfall = 2,
  double? regenDavor = 0,
  double regenJetzt = 0.5,
}) {
  final jetzt = DateTime.now().toUtc();
  final letzte = DateTime.utc(jetzt.year, jetzt.month, jetzt.day, jetzt.hour);
  final von = letzte.subtract(const Duration(hours: 167));
  List<double?> reihe(double? Function(int i) f) => [for (var i = 0; i < 168; i++) f(i)];
  final t0 = jetzt.subtract(const Duration(minutes: 5));
  String tag(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final heute = tag(DateTime.now());
  final gestern = tag(DateTime.now().subtract(const Duration(days: 1)));
  final morgen = tag(DateTime.now().add(const Duration(days: 1)));
  return {
    'available': true,
    'place': 'Westerburg',
    'current': {
      'measuredAt': t0.toIso8601String(),
      'stale': false,
      'temperature': temp,
      'humidity': 71,
      'pressure': druck ? druckJetzt : null,
      'rain1h': regen ? regenJetzt : null,
      'rain24h': regen ? 2.1 : null,
      'windKmh': wind ? 12 : null,
      'gustKmh': wind ? boeen : null,
      'windAngle': wind ? 235 : null,
    },
    'min24h': 3.0,
    'max24h': 18.5,
    'series': [
      for (var i = 0; i < 6; i++) {'t': t0.subtract(Duration(hours: 5 - i)).toIso8601String(), 'temperature': 5.0 + i * 2},
    ],
    if (hourly) ...{
      'hourly': {
        'from': von.toIso8601String(),
        'stepSec': 3600,
        'temperature': reihe((i) => i == 167 ? temp : 8 + 4 * math.sin(i / 9)),
        'humidity': reihe((i) => 70 + (i % 5).toDouble()),
        'pressure': reihe((i) => !druck ? null : (i == 167 ? druckJetzt : (i == 164 ? druckJetzt + druckAbfall : 1010 + (i % 3).toDouble()))),
        'rain': reihe((i) => !regen ? null : (i == 167 ? regenJetzt : (i == 166 ? regenDavor : (i % 11 == 0 ? 0.8 : 0.0)))),
        'windKmh': reihe((i) => !wind ? null : 10 + (i % 7).toDouble()),
        'gustKmh': reihe((i) => !wind ? null : 20 + (i % 9).toDouble()),
        'windAngle': reihe((i) => !wind ? null : 200 + (i % 40).toDouble()),
      },
      'days': [
        {'date': gestern, 'min': 4.8, 'max': 13.5},
        {'date': heute, 'min': 6.2, 'max': 12.1},
      ],
      'sun': [
        {'date': heute, 'sunrise': '${heute}T07:21:00+02:00', 'sunset': '${heute}T17:57:00+02:00'},
        {'date': morgen, 'sunrise': '${morgen}T07:23:00+02:00', 'sunset': '${morgen}T17:55:00+02:00'},
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(
    WidgetTester tester, {
    Map<String, dynamic> Function()? wetter,
    Future<void> Function(TestUmgebung)? vorher,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    bool detail = false,
  }) async {
    final env = await angemeldeteUmgebung();
    await vorher?.call(env);
    env.server.on('GET /weather', (_) => jsonAntwort(wetter == null ? _antwort() : wetter()));
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (detail) {
      if (find.text('Westerburg').evaluate().isEmpty) await tester.scrollUntilVisible(find.text('Westerburg'), 300, scrollable: find.byType(Scrollable).first);
      await tippe(tester, find.text('Westerburg'));
    }
    return env;
  }

  Finder inVerlauf(Finder f) => find.descendant(of: find.byType(WetterVerlaufKarte), matching: f);
  Finder diagramm() => find.byKey(const ValueKey('wetter-diagramm'));
  Finder kopfZeit() => inVerlauf(find.textContaining(RegExp(r'^// ')));

  group('Interaktiver Verlauf', () {
    testWidgets('Chips nur für Größen mit Daten, Zeiträume umschaltbar, Berühren zeigt Zeit und Wert, zweites Tippen auf dieselbe Stelle löscht', (tester) async {
      await start(tester, detail: true);
      for (final c in ['Temperatur', 'Feuchte', 'Druck', 'Regen', 'Wind']) {
        expect(inVerlauf(find.text(c)), findsOneWidget, reason: c);
      }
      for (final c in ['24 Stunden', '3 Tage', '7 Tage']) {
        expect(inVerlauf(find.text(c)), findsOneWidget, reason: c);
      }
      expect(inVerlauf(find.text('// JETZT')), findsOneWidget);
      final r = tester.getRect(diagramm());
      await tester.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
      await warte(tester);
      expect(inVerlauf(find.text('// JETZT')), findsNothing);
      expect(kopfZeit(), findsOneWidget);
      expect(inVerlauf(find.textContaining('zum Schnitt')), findsOneWidget);
      // Ziehen verschiebt das Fadenkreuz
      final vorher = (tester.widget<Text>(kopfZeit())).data;
      await tester.dragFrom(Offset(r.left + r.width * 0.5, r.center.dy), Offset(-r.width * 0.3, 0));
      await warte(tester);
      expect((tester.widget<Text>(kopfZeit())).data, isNot(vorher));
      // 7 Tage: Zeit mit Wochentag
      await tippe(tester, inVerlauf(find.text('7 Tage')));
      expect(inVerlauf(find.text('// JETZT')), findsOneWidget);
      await tester.ensureVisible(diagramm());
      await tester.pump();
      final r2 = tester.getRect(diagramm());
      await tester.tapAt(Offset(r2.left + r2.width * 0.2, r2.center.dy));
      await warte(tester);
      expect((tester.widget<Text>(kopfZeit())).data, matches(RegExp(r'^// (MO|DI|MI|DO|FR|SA|SO) \d\d:\d\d$')));
      // Größe wechselt, Fadenkreuz weg
      await tippe(tester, inVerlauf(find.text('Regen')));
      expect(inVerlauf(find.text('// JETZT')), findsOneWidget);
      expect(inVerlauf(find.textContaining('Summe')), findsOneWidget);
      pruefeLayout(tester, 'Verlauf Regen');
    });

    testWidgets('Maus: Darüberfahren zeigt den Wert, Verlassen löscht; Pfeiltasten und Escape', (tester) async {
      await start(tester, detail: true);
      final r = tester.getRect(diagramm());
      final maus = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await maus.addPointer(location: Offset(r.left + 10, r.top - 50));
      await maus.moveTo(Offset(r.left + r.width * 0.7, r.center.dy));
      await warte(tester);
      expect(inVerlauf(find.text('// JETZT')), findsNothing);
      await maus.moveTo(Offset(r.left + r.width * 0.7, r.top - 80));
      await warte(tester);
      expect(inVerlauf(find.text('// JETZT')), findsOneWidget);
      await maus.removePointer();
      // Fokus per Klick, dann Tasten
      await tester.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
      await warte(tester);
      final a = (tester.widget<Text>(kopfZeit())).data;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await warte(tester);
      final b = (tester.widget<Text>(kopfZeit())).data;
      expect(b, isNot(a));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await warte(tester);
      expect((tester.widget<Text>(kopfZeit())).data, isNot(b));
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await warte(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // am Ende bleibt es am Ende
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await warte(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await warte(tester);
      expect(inVerlauf(find.text('// JETZT')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Screenreader: Textzusammenfassung mit Tiefst- und Höchstwert, Fadenkreuz per Erhöhen/Verringern', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester, detail: true);
      final knoten = find.semantics.byLabel(RegExp(r'Temperatur der letzten 24 Stunden\. Tiefstwert .* Grad um \d\d:\d\d Uhr\. Höchstwert .* Grad um \d\d:\d\d Uhr\. Zuletzt'));
      expect(knoten, findsOneWidget);
      tester.semantics.increase(knoten);
      await warte(tester);
      expect(inVerlauf(find.text('// JETZT')), findsNothing);
      handle.dispose();
    });

    testWidgets('Fehlt eine Reihe (kein Regenmesser, kein Windmesser), erscheint ihr Chip nicht', (tester) async {
      await start(tester, wetter: () => _antwort(regen: false, wind: false, druck: false), detail: true);
      expect(inVerlauf(find.text('Temperatur')), findsOneWidget);
      expect(inVerlauf(find.text('Feuchte')), findsOneWidget);
      expect(inVerlauf(find.text('Regen')), findsNothing);
      expect(inVerlauf(find.text('Wind')), findsNothing);
      expect(inVerlauf(find.text('Druck')), findsNothing);
      // auch die Karten dazu fehlen
      expect(find.text('// REGEN'), findsNothing);
      expect(find.text('// WIND'), findsNothing);
      expect(find.text('LUFTDRUCK'), findsNothing);
      pruefeLayout(tester, 'ohne Regen und Wind');
    });

    testWidgets('Älterer Server ohne neue Felder: Verlauf nur Temperatur, 24 Stunden, keine Zeitraum-Chips, Seite funktioniert', (tester) async {
      await start(tester, wetter: () => _antwort(hourly: false), detail: true);
      expect(inVerlauf(find.text('Temperatur')), findsOneWidget);
      expect(inVerlauf(find.text('Regen')), findsNothing);
      expect(inVerlauf(find.text('24 Stunden')), findsNothing);
      expect(diagramm(), findsOneWidget);
      expect(find.textContaining('Taupunkt'), findsOneWidget);
      expect(find.text('Gestern'), findsNothing);
      expect(find.text('3,0 °C / 18,5 °C'), findsOneWidget);
      pruefeLayout(tester, 'älterer Server');
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: Detailseite ohne Überlauf, Touch-Ziele mindestens 44 px, Fadenkreuz bedienbar', (tester) async {
        await start(tester, skala: skala, detail: true);
        pruefeLayout(tester, 'Detail $skala');
        final r = tester.getRect(diagramm());
        await tester.tapAt(Offset(r.left + r.width * 0.6, r.center.dy));
        await warte(tester);
        pruefeLayout(tester, 'Fadenkreuz $skala');
        for (final g in ['Druck', 'Regen', 'Wind', 'Feuchte']) {
          await tippe(tester, inVerlauf(find.text(g)));
          pruefeLayout(tester, '$g $skala');
        }
        await tippe(tester, inVerlauf(find.text('7 Tage')));
        for (var i = 0; i < 4; i++) {
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
          await warte(tester);
          pruefeLayout(tester, 'Detail unten $skala/$i');
        }
      });
    }
  });

  group('Erweiterte Seite', () {
    testWidgets('Kacheln mit Trend, gefühlt, Taupunkt; Regenbalken, Wind-Kompass mit Böen, Vergleich und Sonne', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester, detail: true);
      expect(find.text('TEMPERATUR'), findsOneWidget);
      expect(find.text('GEFÜHLT'), findsOneWidget);
      expect(find.text('LUFTFEUCHTE'), findsOneWidget);
      expect(find.text('LUFTDRUCK'), findsOneWidget);
      expect(find.textContaining('Taupunkt'), findsOneWidget);
      expect(find.textContaining('in 3 h'), findsWidgets);
      expect(find.textContaining('Druck'), findsWidgets);
      expect(find.text('1 h: 0,5 · 24 h: 2,1 mm'), findsOneWidget);
      expect(find.text('aus SW · Böen bis 25 km/h'), findsOneWidget);
      expect(find.text('Heute'), findsOneWidget);
      expect(find.text('Gestern'), findsOneWidget);
      expect(find.text('Diese Woche'), findsOneWidget);
      expect(find.text('6,2 °C bis 12,1 °C'), findsOneWidget);
      expect(find.textContaining('4,8 °C bis 13,5 °C'), findsOneWidget);
      expect(find.text('07:21 bis 17:57 Uhr'), findsOneWidget);
      expect(find.text('07:23 bis 17:55 Uhr'), findsOneWidget);
      // Semantics der Bausteine
      expect(find.semantics.byLabel(RegExp('^Luftdruck 1013 hPa, (fällt|steigt) um')), findsOneWidget);
      expect(find.semantics.byLabel(RegExp('^Wind 12 km/h aus Südwesten, Böen bis 25 km/h')), findsOneWidget);
      expect(find.semantics.byLabel(RegExp('^Regen je Stunde, letzte 24 Stunden')), findsOneWidget);
      expect(find.semantics.byLabel(RegExp('^Heute: ')), findsOneWidget);
      // nie Koordinaten oder Stationsangaben
      expect(find.textContaining(RegExp(r'\b50\.\d|\b7\.9|Straße|MAC'), findRichText: true), findsNothing);
      handle.dispose();
    });

    testWidgets('Desktop: Wetter-Bereich zeigt alles ohne Layoutfehler', (tester) async {
      await start(tester, groesse: const Size(1440, 900), detail: true);
      expect(find.byType(WetterVerlaufKarte), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Hinweise', () {
    testWidgets('Standard: nur Frost an; Warnkarte oben bei Frost, nicht bei milder Temperatur', (tester) async {
      final anzeige = _Anzeige();
      await start(tester, wetter: () => _antwort(temp: 1.4), vorher: (e) async => e.extraOverrides.add(chatAnzeigePortProvider.overrideWithValue(anzeige)));
      await warte(tester, 12);
      expect(find.byType(WetterHinweisKarte), findsOneWidget);
      expect(find.text('// WETTER-HINWEIS'), findsOneWidget);
      expect(find.text('Frostwarnung: 1,4 °C'), findsOneWidget);
      pruefeLayout(tester, 'Warnkarte');
      // lokale Benachrichtigung: genau einmal, neutral, mit Ziel Wetter
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.text, 'Frostwarnung: 1,4 °C');
      expect(anzeige.gezeigt.single.nutzlast, 'wetter');
      expect(anzeige.gezeigt.single.text, isNot(contains('Westerburg')));
      // noch ein Abruf: entprellt (6 Stunden)
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold, skipOffstage: false).first));
      await c.read(wetterProvider.notifier).aktualisieren();
      await warte(tester, 12);
      expect(anzeige.gezeigt, hasLength(1));
      // Tipp auf die Karte öffnet die Wetter-Seite
      await tippe(tester, find.text('Frostwarnung: 1,4 °C'));
      expect(find.byType(WetterScreen), findsOneWidget);
    });

    testWidgets('Milde Temperatur: keine Karte, keine Benachrichtigung; Regen, Wind, Hitze, Druck sind standardmäßig aus', (tester) async {
      final anzeige = _Anzeige();
      await start(
        tester,
        wetter: () => _antwort(temp: 33, boeen: 80, druckJetzt: 1000, druckAbfall: 6, regenDavor: 0),
        vorher: (e) async => e.extraOverrides.add(chatAnzeigePortProvider.overrideWithValue(anzeige)),
      );
      await warte(tester, 12);
      expect(find.byType(WetterHinweisKarte), findsOneWidget); // Widget ist da, zeigt aber nichts
      expect(find.text('// WETTER-HINWEIS'), findsNothing);
      expect(anzeige.gezeigt, isEmpty);
    });

    testWidgets('Eingeschaltete Arten melden sich: Hitze, Wind, Druckabfall und Regen; je Art eine Benachrichtigung', (tester) async {
      final anzeige = _Anzeige();
      await start(
        tester,
        wetter: () => _antwort(temp: 33, boeen: 80, druckJetzt: 1000, druckAbfall: 6, regenDavor: 0),
        vorher: (e) async {
          e.extraOverrides.add(chatAnzeigePortProvider.overrideWithValue(anzeige));
          for (final a in WetterHinweisArt.values) {
            await e.db.metaSchreiben(a.schluessel, 'ja');
          }
        },
      );
      await warte(tester, 12);
      expect(find.text('Hitze: 33,0 °C'), findsOneWidget);
      expect(find.text('Starker Wind: Böen bis 80 km/h'), findsOneWidget);
      expect(find.text('Regen beginnt'), findsOneWidget);
      expect(find.textContaining('Luftdruck fällt schnell'), findsOneWidget);
      expect(anzeige.gezeigt.map((g) => g.id).toSet(), hasLength(4));
      expect(anzeige.gezeigt.map((g) => g.nutzlast).toSet(), {'wetter'});
    });

    testWidgets('Ausgeschaltet (alle Arten aus): keine Karte und keine Benachrichtigung trotz Frost', (tester) async {
      final anzeige = _Anzeige();
      await start(
        tester,
        wetter: () => _antwort(temp: -4),
        vorher: (e) async {
          e.extraOverrides.add(chatAnzeigePortProvider.overrideWithValue(anzeige));
          await e.db.metaSchreiben(WetterHinweisArt.frost.schluessel, 'nein');
        },
      );
      await warte(tester, 12);
      expect(find.text('// WETTER-HINWEIS'), findsNothing);
      expect(anzeige.gezeigt, isEmpty);
    });

    testWidgets('Offline-Stand und veraltete Messung lösen nie einen Hinweis aus', (tester) async {
      final anzeige = _Anzeige();
      final env = await angemeldeteUmgebung();
      env.extraOverrides.add(chatAnzeigePortProvider.overrideWithValue(anzeige));
      // gespeicherter Stand mit Frost, der Server antwortet nicht
      await env.db.metaSchreiben(
        kWetterCacheSchluessel,
        jsonEncode({'abgerufen': DateTime.now().subtract(const Duration(hours: 5)).toIso8601String(), 'daten': _antwort(temp: -4)}),
      );
      env.server.on('GET /weather', (_) => fehler(503, 'unavailable'));
      await starteApp(tester, env);
      await warte(tester, 12);
      expect(find.text('// WETTER-HINWEIS'), findsNothing);
      expect(anzeige.gezeigt, isEmpty);
    });

    testWidgets('Schalter-Seite (Profil › Benachrichtigungen › Wetter-Hinweise): fünf Schalter, lokal gespeichert, ehrlicher Hinweis, 360 px / Textskala 2.0', (tester) async {
      final env = await start(tester, skala: 2.0);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Benachrichtigungen');
      expect(find.text('Wetter-Hinweise'), findsOneWidget);
      await tippe(tester, find.text('Wetter-Hinweise'));
      expect(find.textContaining('Ohne geöffnete App kommt kein Hinweis'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNWidgets(5));
      final schalter = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).map((s) => s.value).toList();
      expect(schalter, [true, false, false, false, false]); // Standard: nur Frost
      pruefeLayout(tester, 'Hinweise-Seite');
      await tippe(tester, find.widgetWithText(SwitchListTile, 'Starker Wind'));
      expect(await env.db.metaLesen(WetterHinweisArt.wind.schluessel), 'ja');
      await tippe(tester, find.widgetWithText(SwitchListTile, 'Frostwarnung'));
      expect(await env.db.metaLesen(WetterHinweisArt.frost.schluessel), 'nein');
      // nie auf dem Server
      expect(env.server.log.where((r) => r.method != 'GET' && r.path.contains('weather')), isEmpty);
      for (var i = 0; i < 2; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await warte(tester);
        pruefeLayout(tester, 'Hinweise-Seite unten');
      }
    });

    testWidgets('Benachrichtigungen: ohne Wetter auf dem Server keine Zeile "Wetter-Hinweise"', (tester) async {
      await start(tester, wetter: () => {'available': false});
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Benachrichtigungen');
      expect(find.text('Wetter-Hinweise'), findsNothing);
    });

    testWidgets('Warnkarte bei Textskala 2.0 auf 360 px ohne Überlauf, Desktop: Karte oben im Raster', (tester) async {
      await start(tester, wetter: () => _antwort(temp: -4, boeen: 80), skala: 2.0, vorher: (e) async => e.db.metaSchreiben(WetterHinweisArt.wind.schluessel, 'ja'));
      await warte(tester, 12);
      expect(find.text('// WETTER-HINWEIS'), findsOneWidget);
      pruefeLayout(tester, 'Warnkarte 2.0');
    });

    testWidgets('Desktop-Startseite zeigt die Warnkarte', (tester) async {
      await start(tester, wetter: () => _antwort(temp: -4), groesse: const Size(1440, 900));
      await warte(tester, 12);
      expect(find.text('// WETTER-HINWEIS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
