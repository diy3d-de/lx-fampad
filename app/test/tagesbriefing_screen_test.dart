// Tagesbriefing, Oberfläche: Startseiten-Kachel "Heute im Überblick" (nur mit Schalter und nur mit Inhalt; 360 px, Textskala 1.0/1.5/2.0; Desktop), Schalter und Uhrzeit
// in den Einstellungen (lokal in `sync_meta`).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/startseite/jetzt_wichtig_logik.dart' show kJetztWichtigSchluessel;
import 'package:lx_fampad/data/tagesbriefing/briefing_einstellungen.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/profile/profil_plattform.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tagesbriefing/briefing_karte.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _a1 = 'dddddddd-1111-4111-8111-111111111111';
const _a2 = 'dddddddd-2222-4222-8222-222222222222';
const _t1 = 'eeeeeeee-1111-4111-8111-111111111111';

String _tag(int tage) {
  final h = heuteTag(TestUmgebung.testJetzt);
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  void seed(TestUmgebung e) {
    e.sync.andereAendert('termin', _t1, {'titel': 'Familienfeier', 'ganztaegig': true, 'startDate': _tag(0), 'endDate': _tag(1), 'ownerId': fixIdAdmin, 'audience': 'family'});
    e.sync.andereAendert('aufgabe', _a1, {'titel': 'Müll rausbringen', 'faelligDate': _tag(0), 'assigneeId': fixIdAdmin});
    e.sync.andereAendert('aufgabe', _a2, {'titel': 'Altlast', 'faelligDate': _tag(-3), 'assigneeId': fixIdAdmin});
  }

  Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, {void Function(TestUmgebung env)? vorher, double skala = 1.0, Size groesse = const Size(360, 800), Map<String, String> meta = const {}}) async {
    final env = await angemeldeteUmgebung();
    env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
    env.speicher = MemoryFeiertageSpeicher(null, {kBriefingKachelSchluessel: 'ja', kJetztWichtigSchluessel: 'nein', ...meta}); // der Block "Jetzt wichtig" hat eigene Tests
    vorher?.call(env);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    return (env, c);
  }

  testWidgets('Kachel zeigt Termine und Aufgaben des Tages als ganze Sätze, ohne eigenen Tipp-Knopf', (tester) async {
    await start(tester, vorher: seed);
    expect(find.byType(BriefingStartKarte), findsOneWidget);
    expect(labelFinder('Heute im Überblick'), findsOneWidget);
    Finder inKarte(String t) => find.descendant(of: find.byType(BriefingStartKarte), matching: find.text(t));
    expect(inKarte('Heute steht 1 Termin an: Familienfeier, ganztägig.'), findsOneWidget);
    expect(inKarte('Heute ist 1 Aufgabe fällig.'), findsOneWidget);
    expect(inKarte('1 Aufgabe ist überfällig.'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Heute im Überblick: Heute steht 1 Termin an')), findsOneWidget);
  });

  testWidgets('ohne etwas zu zeigen gibt es die Kachel nicht', (tester) async {
    await start(tester);
    expect(find.byType(BriefingStartKarte), findsNothing); // die Startseite lässt eine leere Kachel weg
    expect(labelFinder('Heute im Überblick'), findsNothing);
  });

  testWidgets('mit ausgeschaltetem Schalter gibt es die Kachel nicht', (tester) async {
    await start(tester, vorher: seed, meta: {kBriefingKachelSchluessel: 'nein'});
    expect(find.byType(BriefingStartKarte), findsNothing);
    expect(labelFinder('Heute im Überblick'), findsNothing);
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Kachel bei 360 px, Textskala $skala: keine Layoutfehler', (tester) async {
      await start(tester, vorher: seed, skala: skala);
      expect(find.byType(BriefingStartKarte), findsOneWidget);
      pruefeLayout(tester, 'Startseite mit Tagesbriefing');
    });
  }

  testWidgets('Desktop: Kachel im Raster', (tester) async {
    final (_, c) = await start(tester, vorher: seed, groesse: const Size(1440, 900));
    c.read(shellTabProvider.notifier).waehlen(0);
    await warte(tester);
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(labelFinder('Heute im Überblick'), findsOneWidget);
  });

  testWidgets('Einstellungen: Standard Kachel an, Benachrichtigung aus, 07:00; Änderungen landen in sync_meta', (tester) async {
    final speicher = MemoryFeiertageSpeicher();
    final env = await angemeldeteUmgebung();
    env.speicher = speicher;
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(briefingEinstellungenProvider.notifier).bereit;
    expect(c.read(briefingEinstellungenProvider), const BriefingEinstellungen());
    expect(c.read(briefingEinstellungenProvider).kachelAn, isTrue);
    expect(c.read(briefingEinstellungenProvider).morgensAn, isFalse);
    expect(briefingUhrzeit(c.read(briefingEinstellungenProvider).minuten), '07:00');
    final n = c.read(briefingEinstellungenProvider.notifier);
    await n.kachelSetzen(false);
    await n.morgensSetzen(true);
    await n.zeitSetzen(6 * 60 + 45);
    await n.zeitSetzen(5000); // ungültig: ignoriert
    expect(speicher.werte[kBriefingKachelSchluessel], 'nein');
    expect(speicher.werte[kBriefingMorgensSchluessel], 'ja');
    expect(speicher.werte[kBriefingZeitSchluessel], '405');
    final c2 = env.container();
    addTearDown(c2.dispose);
    await c2.read(briefingEinstellungenProvider.notifier).bereit;
    expect(c2.read(briefingEinstellungenProvider), const BriefingEinstellungen(kachelAn: false, morgensAn: true, minuten: 405));
  });

  for (final web in [false, true]) {
    testWidgets('Profil: Schalter "Tagesbriefing" in Anzeige; "Morgens benachrichtigen" in Android und Browser (web: $web)', (tester) async {
      final env = await angemeldeteUmgebung();
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));

      env.speicher = MemoryFeiertageSpeicher(null, {kBriefingKachelSchluessel: 'ja'});
      env.extraOverrides.add(profilWebProvider.overrideWithValue(web));
      final c = await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Startseite und Anzeige'));
      expect(find.text('Tagesbriefing'), findsOneWidget);
      await tippe(tester, find.text('Tagesbriefing'));
      expect(c.read(briefingEinstellungenProvider).kachelAn, isFalse);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.text('Benachrichtigungen'));
      expect(find.text('Morgens benachrichtigen'), findsOneWidget);
      expect(find.textContaining('Nur solange die Web-App geöffnet ist'), web ? findsOneWidget : findsNothing);
      await tippe(tester, find.text('Morgens benachrichtigen'));
      expect(c.read(briefingEinstellungenProvider).morgensAn, isTrue);
      pruefeLayout(tester, 'Benachrichtigungen mit Tagesbriefing');
    });
  }
}
