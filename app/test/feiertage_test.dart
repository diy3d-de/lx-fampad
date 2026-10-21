// Feiertage (berechnet) und Schulferien Rheinland-Pfalz (Asset): Ostern, bewegliche Feiertage, Asset-Datei, Agenda-Auswahl,
// Anzeige im Kalender (Monat/Woche) und der lokale Schalter.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/kalender_widgets.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/harness.dart';

DateTime _d(int j, int m, int t) => DateTime.utc(j, m, t);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  test('Ostersonntag: bekannte Daten', () {
    expect(ostersonntag(2026), _d(2026, 4, 5));
    expect(ostersonntag(2027), _d(2027, 3, 28));
    expect(ostersonntag(2028), _d(2028, 4, 16));
    expect(ostersonntag(2024), _d(2024, 3, 31));
    expect(ostersonntag(2025), _d(2025, 4, 20));
    expect(ostersonntag(2038), _d(2038, 4, 25));
  });

  test('Feiertage Rheinland-Pfalz 2026: berechnet, elf Stück, ohne Oster- und Pfingstsonntag', () {
    final f = {for (final h in feiertageRlp(2026)) h.name: h.von};
    expect(f.length, 11);
    expect(f['Neujahr'], _d(2026, 1, 1));
    expect(f['Karfreitag'], _d(2026, 4, 3));
    expect(f['Ostermontag'], _d(2026, 4, 6));
    expect(f['Tag der Arbeit'], _d(2026, 5, 1));
    expect(f['Christi Himmelfahrt'], _d(2026, 5, 14));
    expect(f['Pfingstmontag'], _d(2026, 5, 25));
    expect(f['Fronleichnam'], _d(2026, 6, 4));
    expect(f['Tag der Deutschen Einheit'], _d(2026, 10, 3));
    expect(f['Allerheiligen'], _d(2026, 11, 1));
    expect(f['1. Weihnachtstag'], _d(2026, 12, 25));
    expect(f['2. Weihnachtstag'], _d(2026, 12, 26));
    final g = {for (final h in feiertageRlp(2027)) h.name: h.von};
    expect(g['Christi Himmelfahrt'], _d(2027, 5, 6));
    expect(g['Fronleichnam'], _d(2027, 5, 27));
  });

  test('Asset: Ferien 2026 bis 2028 lesbar, mit Quelle und Stand im Kopf, plausible Bereiche', () {
    final text = File('assets/kalender/schulferien_rlp.json').readAsStringSync();
    expect(text, contains('_quelle'));
    expect(text, contains('_stand'));
    expect(text, contains('Ohne Gewähr'));
    final ferien = ferienAusJson(text);
    expect(ferien.length, 13);
    for (final f in ferien) {
      expect(f.bis.isBefore(f.von), isFalse, reason: f.name);
      expect(f.bis.difference(f.von).inDays, lessThan(45), reason: f.name);
    }
    final sommer2026 = ferien.firstWhere((f) => f.name == 'Sommerferien' && f.von.year == 2026);
    expect(sommer2026.von, _d(2026, 6, 29));
    expect(sommer2026.bis, _d(2026, 8, 7));
    for (final j in [2026, 2027, 2028]) {
      for (final n in ['Osterferien', 'Sommerferien', 'Herbstferien']) {
        expect(ferien.where((f) => f.name == n && f.von.year == j).length, 1, reason: '$n $j');
      }
    }
  });

  test('ferienAusJson: kaputte Einträge und Texte werden übersprungen, nie ein Fehler', () {
    expect(ferienAusJson('kein json'), isEmpty);
    expect(ferienAusJson('{"ferien": 3}'), isEmpty);
    final l = ferienAusJson('{"ferien":[{"name":"A","von":"2026-02-01","bis":"2026-01-01"},{"name":"B","von":"2026-02-01","bis":"2026-02-03"},5,{"von":"x"}]}');
    expect(l.map((e) => e.name), ['B']);
  });

  test('TagesHinweise: fuerTag und Agenda (Ferien nur am ersten sichtbaren Tag, Feiertage an ihrem Tag)', () {
    final ferien = [TagesHinweis(name: 'Sommerferien', art: TagesHinweisArt.ferien, von: _d(2026, 6, 29), bis: _d(2026, 8, 7))];
    final h = TagesHinweise.aus(ferien: ferien, vonJahr: 2026, bisJahr: 2026);
    expect(h.fuerTag(_d(2026, 7, 15)).map((e) => e.name), ['Sommerferien']);
    expect(h.fuerTag(_d(2026, 8, 8)), isEmpty);
    expect(h.fuerTag(_d(2026, 5, 1)).single.name, 'Tag der Arbeit');
    final a = h.fuerAgenda(_d(2026, 7, 15), _d(2026, 9, 15));
    expect(a[_d(2026, 7, 15)]!.single.name, 'Sommerferien');
    expect(a.length, 1, reason: 'in dem Zeitraum liegt kein Feiertag');
    final b = h.fuerAgenda(_d(2026, 6, 1), _d(2026, 7, 31));
    expect(b[_d(2026, 6, 29)]!.single.name, 'Sommerferien');
    expect(b.entries.where((e) => e.value.any((x) => x.art == TagesHinweisArt.ferien)).length, 1);
    expect(TagesHinweise.leer.istLeer, isTrue);
  });

  testWidgets('TagesHinweisZeile: Ferien nennen das Ende, 360 px ohne Überlauf', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TagesHinweisZeile(
            mitEnde: true,
            hinweise: [
              TagesHinweis(name: 'Allerheiligen', art: TagesHinweisArt.feiertag, von: _d(2026, 11, 1), bis: _d(2026, 11, 1)),
              TagesHinweis(name: 'Herbstferien', art: TagesHinweisArt.ferien, von: _d(2026, 10, 5), bis: _d(2026, 10, 16)),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Allerheiligen'), findsOneWidget);
    expect(find.textContaining('Herbstferien · bis'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<ProviderContainer> start(WidgetTester tester, {String feiertage = 'ja'}) async {
    final env = await angemeldeteUmgebung(role: 'admin');
    env.feiertage = feiertage;
    final container = await starteApp(tester, env);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
    await warte(tester);
    return container;
  }

  testWidgets('Kalender Monat: Feiertag in der Tagesliste, Schalter blendet aus und merkt sich die Wahl lokal', (tester) async {
    final container = await start(tester);
    await tippe(tester, find.text('Monat'));
    final jahr = heuteTag().year + 1;
    container.read(kalenderAuswahlProvider.notifier).tag(_d(jahr, 1, 1));
    await warte(tester);
    expect(find.text('Neujahr'), findsOneWidget);
    await tippe(tester, find.text('Feiertage & Ferien'));
    expect(find.text('Neujahr'), findsNothing);
    expect(container.read(feiertageAnzeigenProvider), isFalse);
    expect(await container.read(feiertageSpeicherProvider).lesen(), 'nein');
  });

  testWidgets('Kalender Woche: Feiertage erscheinen am Tag, bei ausgeschaltetem Schalter nicht', (tester) async {
    final container = await start(tester, feiertage: 'nein');
    await tippe(tester, find.text('Woche'));
    final jahr = heuteTag().year + 1;
    container.read(kalenderAuswahlProvider.notifier).tag(_d(jahr, 12, 25));
    await warte(tester);
    expect(find.text('1. Weihnachtstag'), findsNothing);
    await container.read(feiertageAnzeigenProvider.notifier).setzen(true);
    await warte(tester);
    expect(find.text('1. Weihnachtstag'), findsOneWidget);
    expect(find.text('2. Weihnachtstag'), findsOneWidget);
  });
}
