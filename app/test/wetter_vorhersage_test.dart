// Wetter-Vorhersage und amtliche DWD-Warnungen: tolerantes Modell, reine Logik (Veraltung, Auswahl, Texte), Startseiten-Warnkarte, Wetter-Seite
// (Tagesliste, Stundenband, Regenwahrscheinlichkeit, Warnkarten), Rückfall ohne Vorhersage (älterer Server), Layout 360 px bei Textskala 1.5/2.0.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/wetter/vorhersage_logik.dart';
import 'package:lx_fampad/data/wetter/vorhersage_modelle.dart';
import 'package:lx_fampad/data/wetter/vorhersage_state.dart';
import 'package:lx_fampad/features/wetter/wetter_screen.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

String _tag(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _wetter() => {
  'available': true,
  'place': 'Westerburg',
  'current': {'measuredAt': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String(), 'stale': false, 'temperature': 12.5, 'humidity': 71, 'pressure': 1013.2, 'windKmh': 12},
  'min24h': 3.0,
  'max24h': 18.5,
  'series': <Object>[],
};

Map<String, dynamic> _warnung({int level = 3, String kind = 'wind', String title = 'Sturmböen', String text = 'Es treten Sturmböen um 70 km/h auf.', Duration von = const Duration(hours: -1), Duration bis = const Duration(hours: 8)}) => {
  'level': level,
  'kind': kind,
  'title': title,
  'text': text,
  'from': DateTime.now().add(von).toUtc().toIso8601String(),
  'until': DateTime.now().add(bis).toUtc().toIso8601String(),
};

Map<String, dynamic> _antwort({List<Map<String, dynamic>>? warnungen, bool stale = false, Duration alter = const Duration(minutes: 3), bool ohneVorhersage = false, Duration warnAlter = const Duration(minutes: 3)}) {
  final jetzt = DateTime.now();
  final heute = DateTime(jetzt.year, jetzt.month, jetzt.day);
  return {
    'available': true,
    'source': 'Deutscher Wetterdienst',
    'forecast': ohneVorhersage
        ? null
        : {
            'updatedAt': jetzt.subtract(alter).toUtc().toIso8601String(),
            'stale': stale,
            'days': [
              for (var i = 0; i < 7; i++)
                {'date': _tag(heute.add(Duration(days: i, hours: 12))), 'min': 4.0 + i, 'max': 11.0 + i * 1.5, 'rain': i == 1 ? 6.4 : 0.0, 'pop': i == 1 ? 80 : 10, 'windKmh': 20 + i, 'gustKmh': 55, 'symbol': i == 1 ? 'regen' : (i == 2 ? 'sonne' : 'wolken')},
            ],
            'hours': [
              for (var i = 0; i < 30; i++)
                {'t': DateTime(jetzt.year, jetzt.month, jetzt.day, jetzt.hour).add(Duration(hours: i)).toUtc().toIso8601String(), 'temp': 8.0 + (i % 6), 'rain': i % 5 == 0 ? 0.4 : 0.0, 'pop': 20, 'windKmh': 15, 'gustKmh': 30, 'symbol': i % 7 == 0 ? 'regen' : 'teils'},
            ],
          },
    'warnings': {'updatedAt': jetzt.subtract(warnAlter).toUtc().toIso8601String(), 'stale': false, 'items': warnungen ?? [_warnung()]},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modell', () {
    test('liest Tage, Stunden und Warnungen; kaputte Einträge fallen einzeln weg, unbekannte Symbole werden "unbekannt"', () {
      final dto = VorhersageDto.fromJson({
        ..._antwort(),
        'forecast': {
          'updatedAt': '2026-10-24T10:00:00Z',
          'stale': false,
          'days': [
            {'date': '2026-10-24', 'min': 3, 'max': 9, 'symbol': 'ufo'},
            {'date': 'gestern', 'min': 1, 'max': 2},
            {'date': '2026-10-25', 'min': 'x', 'max': 2},
            'Text',
            {'date': '2026-10-26', 'min': 5, 'max': 2, 'symbol': 'regen'},
          ],
          'hours': [
            {'t': '2026-10-24T10:00:00Z', 'temp': 7.5, 'symbol': 'nebel'},
            {'t': 'kaputt', 'temp': 1},
            {'t': '2026-10-24T11:00:00Z'},
          ],
        },
        'warnings': {
          'updatedAt': '2026-10-24T10:00:00Z',
          'items': [
            {'level': 2, 'kind': 'neu', 'title': 'Dauerregen', 'text': 'Text', 'from': '2026-10-24T11:00:00Z', 'until': null},
            {'level': 9, 'title': 'x', 'from': '2026-10-24T11:00:00Z'},
            {'level': 2, 'title': 'ohne Beginn'},
          ],
        },
      });
      expect(dto.verfuegbar, isTrue);
      expect(dto.vorhersage!.tage, hasLength(2));
      expect(dto.vorhersage!.tage.first.symbol, WetterSymbol.unbekannt);
      expect(dto.vorhersage!.tage.last.max, 5); // max nie unter min
      expect(dto.vorhersage!.stunden, hasLength(1));
      expect(dto.warnungen!.items, hasLength(1));
      expect(dto.warnungen!.items.single.art, WarnArt.sonst);
      expect(dto.warnungen!.items.single.bis, isNull);
    });

    test('nie ein Fehler: ältere Server, kaputte Antworten und "nicht verfügbar"', () {
      for (final x in [null, 'text', 5, <Object>[], {'available': false}, {}]) {
        expect(VorhersageDto.fromJson(x).verfuegbar, isFalse);
      }
      final ohne = VorhersageDto.fromJson({'available': true});
      expect(ohne.verfuegbar, isTrue);
      expect(ohne.vorhersage, isNull);
      expect(ohne.warnungen, isNull);
      expect(VorhersageDto.fromJson({'available': true, 'source': '<b>x</b>'}).quelle, 'Deutscher Wetterdienst');
    });
  });

  group('Logik', () {
    final jetzt = DateTime(2026, 10, 24, 12, 30);
    WarnungenTeil teil(List<WetterWarnung> l, {Duration alter = const Duration(minutes: 5), bool veraltet = false}) => WarnungenTeil(aktualisiert: jetzt.subtract(alter), veraltet: veraltet, items: l);
    WetterWarnung w(int stufe, {Duration? bis = const Duration(hours: 5), Duration von = const Duration(hours: -1), String titel = 'T'}) =>
        WetterWarnung(stufe: stufe, art: WarnArt.wind, titel: titel, text: '', von: jetzt.add(von), bis: bis == null ? null : jetzt.add(bis));

    test('Startseite: nur Stufe 2 bis 4, nur frisch, nur geltende; höchste Stufe zuerst', () {
      final dto = VorhersageDto(verfuegbar: true, warnungen: teil([w(1), w(2, titel: 'a'), w(4, titel: 'c'), w(3, bis: const Duration(minutes: -1)), w(3, titel: 'b')]));
      final l = startseitenWarnungen(dto, jetzt);
      expect(l.map((x) => x.titel), ['c', 'b', 'a']);
      expect(startseitenWarnungen(VorhersageDto(verfuegbar: true, warnungen: teil([w(3)], alter: const Duration(minutes: 61))), jetzt), isEmpty);
      expect(startseitenWarnungen(VorhersageDto(verfuegbar: true, warnungen: teil([w(3)], veraltet: true)), jetzt), isEmpty);
      expect(startseitenWarnungen(null, jetzt), isEmpty);
      expect(startseitenWarnungen(VorhersageDto.nichtVerfuegbar, jetzt), isEmpty);
      // Ende offen (null) gilt weiter
      expect(startseitenWarnungen(VorhersageDto(verfuegbar: true, warnungen: teil([w(2, bis: null)])), jetzt), hasLength(1));
    });

    test('Veraltung: Vorhersage nach 12 Stunden, Warnungen nach einer Stunde', () {
      VorhersageTeil v(Duration alter, {bool stale = false}) => VorhersageTeil(aktualisiert: jetzt.subtract(alter), veraltet: stale, tage: const [], stunden: const []);
      expect(vorhersageVeraltet(v(const Duration(hours: 11)), jetzt), isFalse);
      expect(vorhersageVeraltet(v(const Duration(hours: 13)), jetzt), isTrue);
      expect(vorhersageVeraltet(v(const Duration(minutes: 5), stale: true), jetzt), isTrue);
      expect(warnungenVeraltet(teil([], alter: const Duration(minutes: 59)), jetzt), isFalse);
      expect(warnungenVeraltet(teil([], alter: const Duration(minutes: 61)), jetzt), isTrue);
    });

    test('Namen, Zeiträume, Stufen, Spannbalken, Stunden', () {
      expect(tagName(DateTime(2026, 10, 24), jetzt), 'Heute');
      expect(tagName(DateTime(2026, 10, 25), jetzt), 'Morgen');
      expect(tagName(DateTime(2026, 10, 26), jetzt), 'Mo');
      expect(stufeName(2), 'Markante Wetterwarnung');
      expect(stufeName(4), 'Extreme Unwetterwarnung');
      expect(warnZeitraum(w(2, von: const Duration(hours: 1), bis: const Duration(hours: 4)), jetzt), 'heute 13:30 bis 16:30 Uhr');
      expect(warnZeitraum(w(2, von: const Duration(hours: -1), bis: const Duration(hours: 4)), jetzt), 'bis heute 16:30 Uhr');
      expect(warnZeitraum(WetterWarnung(stufe: 2, art: WarnArt.wind, titel: 'T', text: '', von: DateTime(2026, 10, 24, 22, 30), bis: DateTime(2026, 10, 25, 10, 30)), jetzt), 'heute 22:30 bis morgen 10:30 Uhr');
      expect(warnZeitraum(w(2, von: const Duration(hours: 1), bis: null), jetzt), 'heute ab 13:30 Uhr');
      final tag = VorhersageTag(datum: DateTime(2026), min: 5, max: 10, regenMm: 0, symbol: WetterSymbol.sonne);
      final b = spannBalken(tag, 0, 20);
      expect(b.links, closeTo(0.25, 0.001));
      expect(b.breite, closeTo(0.25, 0.001));
      final punkt = spannBalken(VorhersageTag(datum: DateTime(2026), min: 20, max: 20, regenMm: 0, symbol: WetterSymbol.sonne), 0, 20);
      expect(punkt.links + punkt.breite, lessThanOrEqualTo(1.0 + 1e-9));
      expect(punkt.breite, greaterThan(0));
      final st = [for (var i = -3; i < 40; i++) VorhersageStunde(zeit: DateTime(2026, 10, 24, 12).add(Duration(hours: i)), temperatur: 1, regenMm: 0, symbol: WetterSymbol.sonne)];
      final n = naechsteStunden(st, jetzt);
      expect(n, hasLength(24));
      expect(n.first.zeit, DateTime(2026, 10, 24, 12));
    });
  });

  Future<TestUmgebung> start(
    WidgetTester tester, {
    Object? Function()? forecast,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
  }) async {
    final env = await angemeldeteUmgebung();
    env.server.on('GET /weather', (_) => jsonAntwort(_wetter()));
    env.server.on('GET /weather/forecast', (_) {
      final f = forecast == null ? _antwort() : forecast();
      if (f == null) return fehler(404, 'not_found');
      return jsonAntwort(f);
    });
    await starteApp(tester, env, skala: skala, groesse: groesse);
    await warte(tester, 12);
    return env;
  }

  testWidgets('Startseite: Warnkarte mit Stufe als Text; Tipp öffnet die Wetter-Seite mit Warnung, Tagesliste, Stundenband und Quelle', (tester) async {
    await start(tester);
    expect(labelFinder('Amtliche Warnung · Stufe 3'), findsOneWidget);
    expect(find.textContaining('Sturmböen (Stufe 3)'), findsOneWidget);
    pruefeLayout(tester, 'DWD-Warnkarte');
    await tippe(tester, labelFinder('Amtliche Warnung · Stufe 3'));
    expect(find.byType(WetterScreen), findsOneWidget);
    expect(labelFinder('DWD-Warnung · Stufe 3'), findsOneWidget);
    expect(labelFinder('Nächste Tage'), findsOneWidget);
    expect(find.text('Heute'), findsWidgets);
    expect(find.text('Morgen'), findsOneWidget);
    expect(labelFinder('Nächste 24 Stunden'), findsOneWidget);
    expect(labelFinder('Regenwahrscheinlichkeit'), findsOneWidget);
    expect(find.text('Quelle: Deutscher Wetterdienst'), findsOneWidget);
    expect(find.textContaining('Regen 80 %'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Stufe 3 von 4')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stufe 1 erscheint nur auf der Wetter-Seite, nie als Startseiten-Karte', (tester) async {
    await start(tester, forecast: () => _antwort(warnungen: [_warnung(level: 1, title: 'Windböen')]));
    expect(find.textContaining('AMTLICHE WARNUNG'), findsNothing);
    await tippe(tester, find.text('Westerburg'));
    expect(labelFinder('DWD-Warnung · Stufe 1'), findsOneWidget);
  });

  testWidgets('Warnungen und Vorhersage werden nicht als aktuell gezeigt, wenn der Stand alt ist', (tester) async {
    await start(tester, forecast: () => _antwort(warnAlter: const Duration(hours: 2), alter: const Duration(hours: 14)));
    expect(find.textContaining('AMTLICHE WARNUNG'), findsNothing);
    await tippe(tester, find.text('Westerburg'));
    expect(find.textContaining('Amtliche Warnungen sind gerade nicht aktuell'), findsOneWidget);
    expect(find.textContaining('Die Vorhersage ist veraltet'), findsOneWidget);
    expect(labelFinder('Nächste 24 Stunden'), findsNothing);
    expect(labelFinder('Nächste Tage'), findsOneWidget);
  });

  testWidgets('Älterer Server ohne die Route: ruhiger Hinweis statt Fehlerfläche, nie ein Absturz', (tester) async {
    await start(tester, forecast: () => null);
    expect(find.textContaining('AMTLICHE WARNUNG'), findsNothing);
    await tippe(tester, find.text('Westerburg'));
    expect(find.text('Die Vorhersage ist gerade nicht verfügbar.'), findsOneWidget);
    expect(labelFinder('Nächste Tage'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Server ohne Vorhersage (available false): kein Abschnitt, keine Karte', (tester) async {
    await start(tester, forecast: () => {'available': false});
    await tippe(tester, find.text('Westerburg'));
    expect(labelFinder('Nächste Tage'), findsNothing);
    expect(find.text('Die Vorhersage ist gerade nicht verfügbar.'), findsNothing);
    expect(find.textContaining('AMTLICHE WARNUNG'), findsNothing);
  });

  testWidgets('Offline-Stand: der letzte Stand liegt in sync_meta', (tester) async {
    final env = await start(tester);
    expect(await env.db.metaLesen(kVorhersageCacheSchluessel), isNotNull);
    final m = jsonDecode((await env.db.metaLesen(kVorhersageCacheSchluessel))!) as Map<String, dynamic>;
    expect(VorhersageDto.fromJson(m['daten']).vorhersage!.tage, hasLength(7));
  });

  for (final skala in [1.5, 2.0]) {
    testWidgets('Wetter-Seite bei Textskala $skala auf 360 px: kein Überlauf, Touch-Ziele', (tester) async {
      await start(tester, skala: skala, forecast: () => _antwort(warnungen: [_warnung(), _warnung(level: 2, title: 'Dauerregen', kind: 'regen'), _warnung(level: 4, title: 'Hitze', kind: 'hitze')]));
      pruefeLayout(tester, 'Startseite mit Warnkarte $skala');
      await tippe(tester, labelFinder('Amtliche Warnung · Stufe 4'));
      pruefeLayout(tester, 'Wetter-Seite $skala');
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await warte(tester);
        pruefeLayout(tester, 'Wetter-Seite $skala unten $i');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Desktop-Startseite zeigt die Warnkarte', (tester) async {
    await start(tester, groesse: const Size(1440, 900));
    expect(labelFinder('Amtliche Warnung · Stufe 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
