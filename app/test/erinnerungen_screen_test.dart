// Profil > Erinnerungen: Schalter, Berechtigung, Standard-Vorlaufzeit, Samsung-Hinweis, Testbenachrichtigung; Web nur mit Hinweis.
// Layout bei 360 px Breite, Textskala 1.0 und 1.5, Touch-Ziele mindestens 44 px.
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/features/lists/list_dialogs.dart' show AuswahlKnopf;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart' show fixIdAdmin;
import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(testVorbereiten);

  late FakeErinnerungPort port;
  late MemoryErinnerungSpeicher speicher;

  Future<void> oeffnen(WidgetTester tester, {double skala = 1.0, bool verfuegbar = true, bool erlaubt = true, bool exakt = true, bool mitTermin = false}) async {
    port = FakeErinnerungPort()
      ..verfuegbar = verfuegbar
      ..erlaubt = erlaubt
      ..exakt = exakt;
    speicher = MemoryErinnerungSpeicher();
    final env = await angemeldeteUmgebung();
    env.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(port), erinnerungSpeicherProvider.overrideWithValue(speicher)]);
    if (mitTermin) {
      final start = DateTime.now().toUtc().add(const Duration(days: 3));
      await env.db
          .into(env.db.termine)
          .insert(
            TermineCompanion.insert(
              id: 't1',
              titel: 'Zahnarzt',
              startUtc: Value(start),
              endUtc: Value(start.add(const Duration(hours: 1))),
              tzid: const Value('Europe/Berlin'),
              erinnerungMin: const Value(15),
              ownerId: const Value(fixIdAdmin),
              createdAt: DateTime.utc(2026, 10, 1),
            ),
          );
    }
    await starteApp(tester, env, skala: skala);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippeText(tester, 'Erinnerungen');
    await warte(tester);
  }

  for (final skala in [1.0, 1.5]) {
    testWidgets('Textskala $skala: alle Bedienelemente sichtbar, kein Überlauf, Touch-Ziele mindestens 44 px', (tester) async {
      await oeffnen(tester, skala: skala, erlaubt: false);
      expect(find.text('Erinnerungen auf diesem Gerät'), findsOneWidget);
      expect(find.text('Benachrichtigungen erlauben'), findsOneWidget);
      expect(find.textContaining('Hintergrundnutzungsgrenzen'), findsOneWidget);
      expect(find.text('Testbenachrichtigung in 10 Sekunden'), findsOneWidget);
      for (final f in [find.byType(AuswahlKnopf), find.byType(SwitchListTile), find.byType(FilledButton), find.byType(OutlinedButton)]) {
        for (final e in f.evaluate()) {
          final box = e.renderObject! as RenderBox;
          expect(box.size.height, greaterThanOrEqualTo(44), reason: '${e.widget.runtimeType}');
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Schalter aus: lokal gespeichert, alle geplanten Erinnerungen gelöscht', (tester) async {
    await oeffnen(tester, mitTermin: true);
    expect(port.letzte, hasLength(1));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    final geloescht = port.geloescht;
    await tippe(tester, find.byType(Switch));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(speicher.daten['erinnerung_an'], 'nein');
    expect(port.geloescht, greaterThan(geloescht));
  });

  testWidgets('Berechtigung fehlt: Knopf fragt an, danach verschwindet der Hinweis', (tester) async {
    await oeffnen(tester, erlaubt: false);
    expect(find.textContaining('noch nicht erlaubt'), findsOneWidget);
    await tippeText(tester, 'Benachrichtigungen erlauben');
    expect(port.anfragen, 1);
    expect(find.textContaining('noch nicht erlaubt'), findsNothing);
  });

  testWidgets('Berechtigung abgelehnt: Hinweis bleibt, Systemeinstellungen lassen sich öffnen', (tester) async {
    await oeffnen(tester, erlaubt: false);
    port.anfrageErteilt = false;
    await tippeText(tester, 'Benachrichtigungen erlauben');
    expect(find.textContaining('noch nicht erlaubt'), findsOneWidget);
    await tippeText(tester, 'Systemeinstellungen öffnen');
    expect(port.systemEinstellungen, 1);
  });

  testWidgets('keine genauen Alarme: Hinweis auf mögliche Verspätung', (tester) async {
    await oeffnen(tester, exakt: false);
    expect(find.textContaining('Genaue Alarme sind auf diesem Gerät nicht erlaubt'), findsOneWidget);
  });

  testWidgets('Standard-Vorlaufzeit wählen: wird lokal gespeichert', (tester) async {
    await oeffnen(tester);
    await tippeText(tester, '1 Stunde');
    expect(speicher.daten['erinnerung_vorlauf'], '60');
    await tippeText(tester, 'Keine');
    expect(speicher.daten['erinnerung_vorlauf'], '');
  });

  testWidgets('Testbenachrichtigung: in 10 Sekunden geplant, bei fehlender Berechtigung wird erst gefragt', (tester) async {
    await oeffnen(tester);
    await tippeText(tester, 'Testbenachrichtigung in 10 Sekunden');
    expect(port.tests, [const Duration(seconds: 10)]);
    expect(find.textContaining('in 10 Sekunden'), findsWidgets);
  });

  testWidgets('Testbenachrichtigung ohne Berechtigung und ohne Zustimmung: nichts geplant', (tester) async {
    await oeffnen(tester, erlaubt: false);
    port.anfrageErteilt = false;
    await tippeText(tester, 'Testbenachrichtigung in 10 Sekunden');
    expect(port.anfragen, greaterThan(0));
    expect(port.tests, isEmpty);
  });

  testWidgets('Web: nur Hinweis, keine Bedienelemente', (tester) async {
    await oeffnen(tester, verfuegbar: false);
    expect(find.textContaining('nur in der Android-App'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Testbenachrichtigung in 10 Sekunden'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
