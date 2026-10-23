// Einstellungen "Benachrichtigungen" (nur Android): Schalter, Status, Test-Wecker, Verteiler-Auswahl, Anleitung; Layout ab 360 px bei Textskala 1.5.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/push/push_state.dart';
import 'package:lx_fampad/data/standort/standort_hinweis.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';
import 'package:lx_fampad/features/profile/push_screen.dart';
import 'package:lx_fampad/ui/theme.dart';

import 'support/fake_push.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  late TestUmgebung env;
  late FakePush fake;
  var registriert = false;
  late MemoryErinnerungSpeicher speicher;

  Future<ProviderContainer> zeige(WidgetTester tester, Widget seite, {double skala = 1.0, bool unterstuetzt = true, Duration wartezeit = const Duration(milliseconds: 200)}) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = skala;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    kanalMocken();
    env = await angemeldeteUmgebung();
    registriert = false;
    env.server.on('GET /me/push', (_) => jsonAntwort({'available': true, 'server': 'x', 'registered': registriert, 'active': registriert, 'lastOkAt': null, 'lastErrorAt': null}));
    env.server.on('PUT /me/push', (_) {
      registriert = true;
      return jsonAntwort({'ok': true});
    });
    env.server.on('DELETE /me/push', (_) {
      registriert = false;
      return jsonAntwort({'ok': true});
    });
    env.server.on('POST /me/push/test', (_) => jsonAntwort({'result': 'sent'}));
    fake = FakePush()..unterstuetzt = unterstuetzt;
    speicher = MemoryErinnerungSpeicher();
    final c = ProviderContainer(
      overrides: [
        ...env.overrides,
        pushPlattformProvider.overrideWithValue(fake),
        erinnerungSpeicherProvider.overrideWithValue(speicher),
        pushTestWartezeitProvider.overrideWithValue(wartezeit),
      ],
    );
    addTearDown(c.dispose);
    await c.read(pushProvider.notifier).starten();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(theme: buildTheme(), home: seite)));
    await warte(tester);
    return c;
  }

  testWidgets('aus: Schalter, Status "aus", Anleitung mit Server-Adresse und Akku-Hinweis; Test-Knopf gesperrt', (tester) async {
    await zeige(tester, const PushScreen());
    expect(find.text('Benachrichtigungen'), findsOneWidget);
    expect(find.text('Auf diesem Gerät benachrichtigen'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    expect(find.textContaining(kNtfyServerUrl), findsOneWidget);
    expect(find.textContaining('Nie schlafende Apps'), findsOneWidget);
    expect(find.textContaining('Automatische Sperre'), findsOneWidget);
    expect(find.textContaining('keinen Text'), findsOneWidget); // Datenschutz: Wecker ohne Inhalt
    final test = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Test-Wecker senden'));
    expect(test.onPressed, isNull);
    pruefeLayout(tester, 'Push aus');
  });

  testWidgets('Standortfreigaben melden: Standard an, Schalter wird lokal gespeichert (nie auf dem Server), Text nennt den Datenschutz', (tester) async {
    final c = await zeige(tester, const PushScreen());
    expect(find.text('Standortfreigaben melden'), findsOneWidget);
    expect(find.textContaining('nie den Standort'), findsOneWidget);
    final schalter = find.byType(Switch).last;
    expect(tester.widget<Switch>(schalter).value, isTrue);
    await tippe(tester, schalter);
    await warte(tester);
    expect(tester.widget<Switch>(schalter).value, isFalse);
    expect(speicher.daten[kStandortHinweisSchluessel], 'aus');
    expect(c.read(standortHinweisAnProvider).value, isFalse);
    await tippe(tester, schalter);
    await warte(tester);
    expect(speicher.daten[kStandortHinweisSchluessel], 'an');
    pruefeLayout(tester, 'Standortfreigaben melden');
  });

  testWidgets('einschalten: registriert, Status "angemeldet", danach Test-Wecker mit Ergebnis "angekommen"', (tester) async {
    final c = await zeige(tester, const PushScreen(), wartezeit: const Duration(seconds: 30));
    await tippe(tester, find.byType(Switch).first);
    await warte(tester);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    expect(fake.registriert, 1);
    expect(find.text('ntfy'), findsOneWidget); // Verteiler im Status
    expect(c.read(pushProvider).angemeldet, isTrue);
    final test = find.widgetWithText(OutlinedButton, 'Test-Wecker senden');
    await tippe(tester, test);
    expect(find.textContaining('Der Server sendet den Wecker'), findsOneWidget);
    fake.wecker();
    await warte(tester);
    expect(find.textContaining('Test-Wecker ist angekommen'), findsOneWidget);
    expect(find.text('noch keiner'), findsNothing);
    pruefeLayout(tester, 'Push an');
    // dem Test-Wecker folgt ein Abgleich-Versuch ohne angemeldeten Sync-Dienst: keine Ausnahme
    expect(tester.takeException(), isNull);
    // ausschalten
    await tippe(tester, find.byType(Switch).first);
    await warte(tester);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    expect(registriert, isFalse);
  });

  testWidgets('ohne ntfy-App: Hinweis statt Fehler-Absturz', (tester) async {
    await zeige(tester, const PushScreen());
    fake.installiert = [];
    await tippe(tester, find.byType(Switch).first);
    expect(find.textContaining('keine ntfy-App installiert'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
  });

  testWidgets('mehrere Verteiler: Auswahldialog, nach der Wahl wird registriert', (tester) async {
    await zeige(tester, const PushScreen());
    fake.installiert = ['io.heckel.ntfy', 'org.andere.verteiler'];
    await tippe(tester, find.byType(Switch).first);
    expect(find.text('Verteiler wählen'), findsOneWidget);
    await tippe(tester, find.text('org.andere.verteiler'));
    await warte(tester);
    expect(fake.gespeichert, 'org.andere.verteiler');
    expect(fake.registriert, 1);
    expect(find.text('Verteiler wählen'), findsNothing);
  });

  testWidgets('Web/ohne Push-Plattform: nur der Hinweis, kein Schalter', (tester) async {
    await zeige(tester, const PushScreen(), unterstuetzt: false);
    expect(find.textContaining('nur in der Android-App'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('Layout 360 px bei Textskala 1.5: Schalter an, Fehler, Test-Ergebnis', (tester) async {
    await zeige(tester, const PushScreen(), skala: 1.5);
    await tippe(tester, find.byType(Switch).first);
    await warte(tester);
    await tippe(tester, find.widgetWithText(OutlinedButton, 'Test-Wecker senden'));
    await tester.pump(const Duration(milliseconds: 400));
    await warte(tester);
    expect(find.textContaining('nichts angekommen'), findsOneWidget);
    pruefeLayout(tester, 'Push Textskala 1.5');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await warte(tester);
    pruefeLayout(tester, 'Push Anleitung Textskala 1.5');
  });

  testWidgets('Profil: Zeile "Benachrichtigungen" führt über die Sammelseite zu Push (Android), Status "aus"', (tester) async {
    await zeige(tester, const ProfileScreen());
    final zeile = find.text('Benachrichtigungen');
    expect(zeile, findsOneWidget);
    await tippe(tester, zeile);
    expect(find.text('aus'), findsOneWidget);
    await tippe(tester, find.text('Push'));
    expect(find.text('Auf diesem Gerät benachrichtigen'), findsOneWidget);
  });
}
