// Standardansicht des Kalenders: Monat; die zuletzt gewählte Ansicht merkt sich das Gerät (lokal in `sync_meta`, nie synchronisiert).
// Unbekannter oder fehlender Wert: Monat. 360 px bei Textskala 1.0 und 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show FeiertageSpeicher, MemoryFeiertageSpeicher, feiertageSpeicherProvider, kFeiertageSchluessel, kKalenderAnsichtSchluessel;
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/kalender_leiste.dart' show AnsichtUmschalter;
import 'package:lx_fampad/features/calendar/kalender_monat.dart' show MonatsRaster;
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  Future<ProviderContainer> start(WidgetTester tester, {String? gemerkt, double skala = 1.0, FeiertageSpeicher? speicher}) async {
    final env = await angemeldeteUmgebung();
    env.kalenderAnsicht = gemerkt;
    env.speicher = speicher;
    final container = await starteApp(tester, env, skala: skala);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
    await warte(tester);
    return container;
  }

  KalenderAnsicht aktuell(ProviderContainer c) => c.read(kalenderAuswahlProvider).ansicht;

  test('ausText: bekannte Werte, sonst Monat', () {
    expect(KalenderAnsicht.ausText('agenda'), KalenderAnsicht.agenda);
    expect(KalenderAnsicht.ausText('monat'), KalenderAnsicht.monat);
    expect(KalenderAnsicht.ausText('woche'), KalenderAnsicht.woche);
    expect(KalenderAnsicht.ausText(null), KalenderAnsicht.monat);
    expect(KalenderAnsicht.ausText(''), KalenderAnsicht.monat);
    expect(KalenderAnsicht.ausText('Woche'), KalenderAnsicht.monat);
    expect(KalenderAnsicht.ausText('quatsch'), KalenderAnsicht.monat);
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Standard ohne gemerkten Wert: Monat (360 px, Textskala $skala)', (tester) async {
      final c = await start(tester, skala: skala);
      expect(aktuell(c), KalenderAnsicht.monat);
      expect(c.read(kalenderAuswahlProvider).geladen, isTrue);
      expect(find.byType(MonatsRaster), findsOneWidget);
      pruefeLayout(tester, 'Kalender Standard Monat');
    });
  }

  testWidgets('ungültiger gemerkter Wert: Monat', (tester) async {
    final c = await start(tester, gemerkt: 'quatsch');
    expect(aktuell(c), KalenderAnsicht.monat);
    expect(find.byType(MonatsRaster), findsOneWidget);
  });

  testWidgets('Lesefehler des Speichers: Monat, Wechsel gilt trotzdem', (tester) async {
    final env = await angemeldeteUmgebung();
    env.speicher = _KaputterSpeicher();
    final c = await starteApp(tester, env);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
    await warte(tester);
    expect(aktuell(c), KalenderAnsicht.monat);
    expect(find.byType(MonatsRaster), findsOneWidget);
    await tippeText(tester, 'Woche');
    expect(aktuell(c), KalenderAnsicht.woche);
  });

  testWidgets('gemerkte Ansicht Woche wird beim Start gezeigt (ohne Zwischenbild in Monat)', (tester) async {
    final c = await start(tester, gemerkt: 'woche');
    expect(aktuell(c), KalenderAnsicht.woche);
    expect(find.byType(MonatsRaster), findsNothing);
  });

  testWidgets('Wechsel auf Woche wird gespeichert und beim Neuaufbau wieder gezeigt; Agenda ebenso', (tester) async {
    final speicher = MemoryFeiertageSpeicher('nein');
    var c = await start(tester, speicher: speicher);
    expect(aktuell(c), KalenderAnsicht.monat);
    await tippeText(tester, 'Woche');
    expect(aktuell(c), KalenderAnsicht.woche);
    expect(speicher.werte[kKalenderAnsichtSchluessel], 'woche');
    // Neuaufbau der App (neuer Container, wie ein neuer Start) mit demselben Speicher
    await tester.pumpWidget(const SizedBox());
    c = await start(tester, speicher: speicher);
    expect(aktuell(c), KalenderAnsicht.woche);
    expect(find.byType(MonatsRaster), findsNothing);
    expect(find.byType(AnsichtUmschalter), findsOneWidget);
    await tippeText(tester, 'Agenda');
    expect(speicher.werte[kKalenderAnsichtSchluessel], 'agenda');
    await tippeText(tester, 'Monat');
    expect(speicher.werte[kKalenderAnsichtSchluessel], 'monat');
  });

  testWidgets('Sprung aus einer Benachrichtigung (ansicht) ändert die gemerkte Ansicht nicht', (tester) async {
    final c = await start(tester, gemerkt: 'woche');
    c.read(kalenderAuswahlProvider.notifier).ansicht(KalenderAnsicht.monat);
    await warte(tester);
    expect(aktuell(c), KalenderAnsicht.monat);
    expect(await c.read(feiertageSpeicherProvider).lesen(schluessel: kKalenderAnsichtSchluessel), 'woche');
  });
}

class _KaputterSpeicher extends MemoryFeiertageSpeicher {
  @override
  Future<String?> lesen({String schluessel = kFeiertageSchluessel}) async => throw StateError('nicht lesbar');

  @override
  Future<void> schreiben(String w, {String schluessel = kFeiertageSchluessel}) async => throw StateError('nicht schreibbar');
}
