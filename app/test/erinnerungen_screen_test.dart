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
import 'support/test_app.dart' show TestUmgebung;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(testVorbereiten);

  late FakeErinnerungPort port;
  late MemoryErinnerungSpeicher speicher;
  late TestUmgebung env;

  Future<void> oeffnen(WidgetTester tester, {double skala = 1.0, bool verfuegbar = true, bool erlaubt = true, bool exakt = true, bool mitTermin = false, bool dauerhaft = false}) async {
    port = FakeErinnerungPort()
      ..verfuegbar = verfuegbar
      ..erlaubt = erlaubt
      ..exakt = exakt
      ..dauerhaft = dauerhaft;
    speicher = MemoryErinnerungSpeicher();
    env = await angemeldeteUmgebung();
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
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    final geloescht = port.geloescht;
    await tippe(tester, find.byType(Switch).first);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    expect(speicher.daten['erinnerung_an'], 'nein');
    expect(port.geloescht, greaterThan(geloescht));
  });

  testWidgets('Sperrbildschirm: Standard aus, Schalter wird lokal gespeichert', (tester) async {
    await oeffnen(tester);
    expect(find.text('Titel auf Sperrbildschirm zeigen'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).last).value, isFalse);
    await tippe(tester, find.byType(Switch).last);
    expect(tester.widget<Switch>(find.byType(Switch).last).value, isTrue);
    expect(speicher.daten['erinnerung_sperrbildschirm'], 'ja');
  });

  testWidgets('Gepushte Route: Änderungen der Termine hinter den offenen Einstellungen führen trotzdem zur Neuplanung', (tester) async {
    await oeffnen(tester);
    expect(find.text('Erinnerungen auf diesem Gerät'), findsOneWidget, reason: 'die Einstellungen sind oben, Profil und Start liegen verdeckt darunter');
    final start = DateTime.now().toUtc().add(const Duration(days: 3));
    await tester.runAsync(() => env.db.into(env.db.termine).insert(
      TermineCompanion.insert(
        id: 't9',
        titel: 'Arzt',
        startUtc: Value(start),
        endUtc: Value(start.add(const Duration(hours: 1))),
        tzid: const Value('Europe/Berlin'),
        erinnerungMin: const Value(15),
        ownerId: const Value(fixIdAdmin),
        createdAt: DateTime.utc(2026, 10, 1),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 700)); // Entprellzeit
    await warte(tester, 10);
    expect(port.letzte, hasLength(1));
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
    expect(find.textContaining('Genaue Alarme ("Alarme & Erinnerungen") sind auf diesem Gerät nicht erlaubt'), findsOneWidget);
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


  for (final skala in [1.0, 1.5]) {
    testWidgets('Termin-Editor Textskala $skala: ohne Berechtigung steht ein Hinweis mit Link, mit Berechtigung nicht', (tester) async {
      for (final erlaubt in [false, true]) {
        port = FakeErinnerungPort()..erlaubt = erlaubt;
        speicher = MemoryErinnerungSpeicher();
        env = await angemeldeteUmgebung();
        env.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(port), erinnerungSpeicherProvider.overrideWithValue(speicher)]);
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
        await tippeText(tester, 'Neuer Termin');
        await tippeText(tester, '15 Minuten');
        await warte(tester);
        expect(find.textContaining('Benachrichtigungen für lx-familyhub nicht erlaubt'), erlaubt ? findsNothing : findsOneWidget);
        if (!erlaubt) {
          await tippeText(tester, 'Benachrichtigungen erlauben');
          expect(find.text('Titel auf Sperrbildschirm zeigen'), findsOneWidget, reason: 'Link öffnet die Einstellungen');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  testWidgets('Testbenachrichtigung ohne Berechtigung: Knopf gesperrt, keine versteckte Anfrage', (tester) async {
    await oeffnen(tester, erlaubt: false);
    final knopf = find.ancestor(of: find.text('Testbenachrichtigung in 10 Sekunden'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(knopf).onPressed, isNull);
    expect(port.anfragen, 0);
    expect(port.tests, isEmpty);
  });

  testWidgets('Testbenachrichtigung mit Berechtigung wird geplant', (tester) async {
    await oeffnen(tester);
    await tippeText(tester, 'Testbenachrichtigung in 10 Sekunden');
    expect(port.tests, hasLength(1));
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Dauerhaft verweigert (Textskala $skala): Weg führt in die Einstellungen, kein Dialog-Knopf', (tester) async {
      await oeffnen(tester, skala: skala, erlaubt: false, dauerhaft: true);
      expect(find.textContaining('fragt nicht mehr danach'), findsOneWidget);
      expect(find.text('In den Einstellungen erlauben'), findsOneWidget);
      final e = find.ancestor(of: find.text('In den Einstellungen erlauben'), matching: find.byType(FilledButton)).evaluate().first;
      expect((e.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(44));
      await tippeText(tester, 'In den Einstellungen erlauben');
      expect(port.systemEinstellungen, 1);
      expect(port.anfragen, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Systemeinstellungen nicht zu öffnen: verständlicher Hinweis mit dem Weg', (tester) async {
    await oeffnen(tester, erlaubt: false);
    port.systemOk = false;
    await tippeText(tester, 'Systemeinstellungen öffnen');
    expect(find.textContaining('Apps, lx-familyhub, Benachrichtigungen'), findsOneWidget);
  });

  testWidgets('Rückkehr in den Vordergrund: nachträglich erlaubt wird erkannt und nachgeplant, ohne Neustart', (tester) async {
    await oeffnen(tester, erlaubt: false, mitTermin: true);
    expect(find.textContaining('noch nicht erlaubt'), findsOneWidget);
    expect(find.textContaining('erlaubt ja'), findsNothing);
    final geplant = port.planungen.length;
    port.erlaubt = true; // Person erlaubt es in den Android-Einstellungen
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await warte(tester, 10);
    expect(find.textContaining('noch nicht erlaubt'), findsNothing);
    expect(find.text('Benachrichtigungen sind erlaubt.'), findsOneWidget);
    expect(port.planungen.length, greaterThan(geplant), reason: 'Planung wird nach dem Erlauben neu gesetzt');
    final knopf = find.ancestor(of: find.text('Testbenachrichtigung in 10 Sekunden'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(knopf).onPressed, isNotNull);
  });

  testWidgets('Diagnose-Zeile zeigt nur Zustände', (tester) async {
    await oeffnen(tester, mitTermin: true);
    final text = tester.widget<Text>(find.byKey(const Key('erinnerung-diagnose'))).data!;
    expect(text, contains('erlaubt ja'));
    expect(text, contains('plugin ja'));
    expect(text, isNot(contains('Zahnarzt')));
  });

  testWidgets('Status unbekannt: eigener Hinweis, Test-Knopf bleibt, "Erneut prüfen" liest neu', (tester) async {
    await oeffnen(tester, erlaubt: false);
    port.statusUnbekannt = true;
    await tester.pumpWidget(const SizedBox());
    await oeffnen(tester, erlaubt: false);
    port.statusUnbekannt = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await warte(tester, 10);
    expect(find.textContaining('ließ sich nicht prüfen'), findsOneWidget);
    final knopf = find.ancestor(of: find.text('Testbenachrichtigung in 10 Sekunden'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(knopf).onPressed, isNotNull);
    port.statusUnbekannt = false;
    port.erlaubt = true;
    await tippeText(tester, 'Erneut prüfen');
    expect(find.text('Benachrichtigungen sind erlaubt.'), findsOneWidget);
  });

  testWidgets('Knopf "erlauben" ohne Dialog (dauerhaft verweigert, Status erst danach bekannt): führt direkt in die Einstellungen', (tester) async {
    await oeffnen(tester, erlaubt: false);
    port.dauerhaft = true; // Android zeigt keinen Dialog; erst nach dem Versuch ist das erkennbar
    await tippeText(tester, 'Benachrichtigungen erlauben');
    expect(port.systemEinstellungen, 1);
    expect(find.text('In den Einstellungen erlauben'), findsOneWidget);
  });

  testWidgets('Mehrfaches schnelles Zurückkehren: kein Fehler, Status stimmt danach', (tester) async {
    await oeffnen(tester, erlaubt: false, mitTermin: true);
    port.erlaubt = true;
    for (var i = 0; i < 3; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    await warte(tester, 12);
    expect(find.text('Benachrichtigungen sind erlaubt.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Web: nur Hinweis, keine Bedienelemente', (tester) async {
    await oeffnen(tester, verfuegbar: false);
    expect(find.textContaining('nur in der Android-App'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Testbenachrichtigung in 10 Sekunden'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
