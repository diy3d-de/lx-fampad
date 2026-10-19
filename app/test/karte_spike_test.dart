// Karten-Spike: Stil-Vorlage ohne Fremd-Adressen, Platzhalter, Genauigkeitskreis, Seite und Einstieg in Profil > Über.
// Die Karte selbst (MapLibre) ist im Widget-Test nicht lauffähig und wird durch einen Platzhalter ersetzt.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart' show kAppName;
import 'package:lx_fampad/features/karte/karte_config.dart';
import 'package:lx_fampad/features/karte/karte_spike_screen.dart';
import 'package:lx_fampad/features/profile/ueber_screen.dart';
import 'package:lx_fampad/ui/theme.dart';

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  final vorlage = File('assets/karte/style.json').readAsStringSync();

  test('Stil-Vorlage: nur Platzhalter und der OSM-Attributionslink, keine Fremd-Adresse', () {
    final adressen = RegExp(r'https?://[^"\\\s<>]+').allMatches(vorlage).map((m) => m.group(0)!).toSet();
    expect(adressen, {'https://www.openstreetmap.org/copyright'});
    expect(vorlage, contains('{{KARTE_BASE}}'));
    expect(vorlage, contains('pmtiles://{{PMTILES_URL}}'));
    expect(vorlage, contains(kKarteAttribution));
  });

  test('Platzhalter werden durch absolute Adressen der eigenen Domain ersetzt', () {
    final s = karteStyleAusVorlage(vorlage, 'https://familie.lx-labs.dev');
    expect(s, contains('pmtiles://https://familie.lx-labs.dev/karte-daten/westerwald.pmtiles'));
    expect(s, contains('https://familie.lx-labs.dev/karte/glyphs/{fontstack}/{range}.pbf'));
    expect(s, contains('https://familie.lx-labs.dev/karte/sprites/black'));
    expect(s, isNot(contains('{{')));
  });

  test('Fremd-Adresse im Stil wird abgelehnt', () {
    expect(() => karteStyleAusVorlage('{"glyphs":"https://demotiles.maplibre.org/{fontstack}"}', 'https://familie.lx-labs.dev'), throwsStateError);
    expect(() => karteStyleAusVorlage('{"a":"{{UNBEKANNT}}"}', 'https://familie.lx-labs.dev'), throwsStateError);
  });

  test('Basisadresse: Define vor API_BASE vor Herkunft der Seite vor Produktion', () {
    expect(karteOrigin(base: 'http://10.0.2.2:8150/', api: 'https://x', web: false), 'http://10.0.2.2:8150');
    expect(karteOrigin(base: '', api: 'https://api.example', web: false), 'https://api.example');
    expect(karteOrigin(base: '', api: '', web: true, seite: 'https://familie.lx-labs.dev'), 'https://familie.lx-labs.dev');
    expect(karteOrigin(base: '', api: '', web: false), 'https://familie.lx-labs.dev');
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

  testWidgets('Seite zeigt Titel und lädt den Stil (Karte im Test ausgeblendet)', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: KarteSpikeScreen(styleJson: vorlage, ohneKarte: true)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Karte (Test)'), findsOneWidget);
    expect(find.text('Karte (im Test ausgeblendet)'), findsOneWidget);
  });

  testWidgets('Profil > Über zeigt "Karte (Test)" (Debug/Admin), 360 px ohne Überlauf', (tester) async {
    final env = await angemeldeteUmgebung();
    env.extraOverrides.add(ueberInfoProvider.overrideWith((ref) async => const UeberInfo(version: '0.2.0', plattform: 'Web')));
    await starteApp(tester, env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippeText(tester, 'Über $kAppName');
    await warte(tester);
    expect(find.text('Karte (Test)'), findsOneWidget);
    pruefeLayout(tester, 'Über mit Karte (Test)');
  });
}
