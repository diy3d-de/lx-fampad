// Familien-Status, Oberfläche: Kachel auf der Startseite (Stati der Familie mit Ende, abgelaufene nie), Blatt zum Setzen/Ändern/Löschen, Schalter in den Einstellungen
// (aus = nichts davon), 360 px mit Textskala 1.0/1.5/2.0, Desktop-Raster. Die Uhr ist fest (27.10.2026, 15:00 Berlin).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/status/status_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/status/status_karte.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

final _jetzt = DateTime.utc(2026, 10, 27, 14);

/// Die Kachel steht am Ende der Startseite: so weit nach unten wischen, bis sie gebaut ist (Desktop und ausgeschalteter Schalter: nichts zu tun).
Future<void> zurKarte(WidgetTester tester) async {
  for (var i = 0; i < 12 && find.byType(StatusStartKarte).evaluate().isEmpty; i++) {
    final liste = find.byType(Scrollable);
    if (liste.evaluate().isEmpty) return;
    await tester.drag(liste.first, const Offset(0, -300));
    await tester.pump();
  }
  await warte(tester, 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, {void Function(TestUmgebung env)? vorher, double skala = 1.0, Size groesse = const Size(360, 800), Map<String, String> meta = const {}}) async {
    final env = await angemeldeteUmgebung();
    env.speicher = MemoryFeiertageSpeicher(null, meta);
    env.extraOverrides.add(statusJetztProvider.overrideWithValue(() => _jetzt));
    vorher?.call(env);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width < 900 && (meta[kStatusAnzeigenSchluessel] ?? 'ja') != 'nein') await zurKarte(tester);
    return (env, c);
  }

  /// Wartet das Entprellen des Abgleichs ab: danach ist die Änderung beim Fake-Server.
  Future<void> abgleich(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await warte(tester, 10);
  }

  void anderer(TestUmgebung e, {String text = 'Beim Sport', String? bis = '2026-10-27T17:00:00.000Z'}) =>
      e.sync.andereAendert('status', statusId(fixIdKind), {'userId': fixIdKind, 'text': text, 'bis': bis});

  testWidgets('Kachel zeigt den Status einer anderen Person mit Name und Ende', (tester) async {
    await start(tester, vorher: anderer);
    expect(find.byType(StatusStartKarte), findsOneWidget);
    expect(labelFinder('Status'), findsOneWidget);
    Finder inKarte(String t) => find.descendant(of: find.byType(StatusStartKarte), matching: find.text(t));
    expect(inKarte('Ben'), findsOneWidget);
    expect(inKarte('Beim Sport'), findsOneWidget);
    expect(inKarte('bis 18:00'), findsOneWidget);
    expect(inKarte('Mein Status setzen'), findsOneWidget);
    expect(find.bySemanticsLabel('Ben: Beim Sport, bis 18:00'), findsOneWidget);
  });

  testWidgets('abgelaufene Stati werden nirgends gezeigt', (tester) async {
    await start(tester, vorher: (e) => anderer(e, bis: '2026-10-27T13:59:00.000Z'));
    expect(find.text('Beim Sport'), findsNothing);
    expect(find.text('Gerade hat niemand einen Status gesetzt.'), findsOneWidget);
  });

  testWidgets('ohne Ende steht "ohne Ende" da', (tester) async {
    await start(tester, vorher: (e) => anderer(e, text: 'Krank', bis: null));
    expect(find.text('Krank'), findsOneWidget);
    expect(find.text('ohne Ende'), findsOneWidget);
  });

  testWidgets('Schalter aus: keine Kachel, kein Status irgendwo', (tester) async {
    await start(tester, vorher: anderer, meta: {kStatusAnzeigenSchluessel: 'nein'});
    expect(find.byType(StatusStartKarte), findsNothing); // die Kachel steht dann gar nicht in der Liste
    expect(labelFinder('Status'), findsNothing);
    expect(find.text('Beim Sport'), findsNothing);
    expect(find.text('Mein Status setzen'), findsNothing);
  });

  testWidgets('Status setzen: Schnellauswahl, Ende, Speichern; die Kachel zeigt ihn sofort, der Server bekommt die Op', (tester) async {
    final (env, c) = await start(tester);
    await tippe(tester, find.text('Mein Status setzen'));
    expect(find.text('Was machst du gerade?'), findsOneWidget);
    await tippe(tester, find.text('Beim Sport'));
    await tippe(tester, find.text('In 1 Stunde'));
    await tippe(tester, find.text('Status setzen'));
    await warte(tester, 10);
    expect(find.text('Was machst du gerade?'), findsNothing);
    Finder inKarte(String t) => find.descendant(of: find.byType(StatusStartKarte), matching: find.text(t));
    expect(inKarte('Du'), findsOneWidget);
    expect(inKarte('Beim Sport'), findsOneWidget);
    expect(inKarte('bis 16:00'), findsOneWidget);
    expect(inKarte('Meinen Status ändern'), findsOneWidget);
    await abgleich(tester);
    final z = env.sync.zeilen['status/${statusId(fixIdAdmin)}'];
    expect(z, isNotNull);
    expect(z!.fields['text'], 'Beim Sport');
    expect(c.read(eigenerStatusProvider)?.text, 'Beim Sport');
  });

  testWidgets('eigenen Status ändern und löschen', (tester) async {
    final (env, _) = await start(tester, vorher: (e) => e.sync.andereAendert('status', statusId(fixIdAdmin), {'userId': fixIdAdmin, 'text': 'Unterwegs', 'bis': '2026-10-27T17:00:00.000Z'}));
    expect(find.text('Meinen Status ändern'), findsOneWidget);
    await tippe(tester, find.text('Meinen Status ändern'));
    expect(find.text('Wie bisher (bis 18:00)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Dein Status'), 'Lernen');
    await tester.pump();
    await tippe(tester, find.text('Status setzen'));
    await warte(tester, 10);
    expect(find.text('Lernen'), findsOneWidget);
    expect(find.text('Unterwegs'), findsNothing);
    await abgleich(tester);
    expect(env.sync.zeilen['status/${statusId(fixIdAdmin)}']!.fields['text'], 'Lernen');
    await tippe(tester, find.text('Meinen Status ändern'));
    await tippe(tester, find.text('Status löschen'));
    await warte(tester, 10);
    expect(find.text('Lernen'), findsNothing);
    expect(find.text('Mein Status setzen'), findsOneWidget);
    await abgleich(tester);
    expect(env.sync.zeilen['status/${statusId(fixIdAdmin)}']!.geloescht, isTrue);
  });

  testWidgets('ein leerer Status wird abgelehnt, das Blatt bleibt mit einer Meldung offen', (tester) async {
    await start(tester);
    await tippe(tester, find.text('Mein Status setzen'));
    await tippe(tester, find.text('Status setzen'));
    expect(find.textContaining('höchstens 60 Zeichen'), findsOneWidget);
    expect(find.text('Was machst du gerade?'), findsOneWidget);
    pruefeLayout(tester, 'Status-Blatt mit Meldung');
  });

  testWidgets('"Heute Abend" gibt es nach 21 Uhr nicht mehr', (tester) async {
    final env = await angemeldeteUmgebung();
    env.speicher = MemoryFeiertageSpeicher();
    env.extraOverrides.add(statusJetztProvider.overrideWithValue(() => DateTime.utc(2026, 10, 27, 20, 30)));
    await starteApp(tester, env);
    await zurKarte(tester);
    await tippe(tester, find.text('Mein Status setzen'));
    expect(find.text('Morgen früh, 7 Uhr'), findsOneWidget);
    expect(find.text('Heute Abend, 22 Uhr'), findsNothing);
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Kachel und Blatt bei 360 px, Textskala $skala: keine Layoutfehler', (tester) async {
      await start(tester, vorher: (e) => anderer(e, text: 'Bei der Mathe-Nachhilfe bei Frau Müller-Lüdenscheidt in der Stadt'), skala: skala);
      expect(find.byType(StatusStartKarte), findsOneWidget);
      pruefeLayout(tester, 'Startseite mit Status');
      await tippe(tester, find.text('Mein Status setzen'));
      pruefeLayout(tester, 'Status-Blatt');
    });
  }

  testWidgets('Desktop: Kachel im Raster', (tester) async {
    final (_, c) = await start(tester, vorher: anderer, groesse: const Size(1440, 900));
    c.read(shellTabProvider.notifier).waehlen(0);
    await warte(tester);
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(labelFinder('Status'), findsOneWidget);
    expect(find.text('Beim Sport'), findsOneWidget);
  });

  testWidgets('Profil: Schalter "Familien-Status anzeigen" schaltet die Kachel', (tester) async {
    final (_, c) = await start(tester, vorher: anderer);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippe(tester, find.text('Startseite und Anzeige'));
    expect(find.text('Familien-Status anzeigen'), findsOneWidget);
    expect(c.read(statusAnzeigenProvider), isTrue);
    await tippe(tester, find.text('Familien-Status anzeigen'));
    expect(c.read(statusAnzeigenProvider), isFalse);
    expect(c.read(familienStatusProvider), isEmpty);
    pruefeLayout(tester, 'Startseite und Anzeige mit Status-Schalter');
  });

  test('Datenbank: abgelaufene Zeilen bleiben liegen (keine Löschung nötig)', () async {
    final env = await angemeldeteUmgebung();
    await env.db.into(env.db.familienStati).insert(FamilienStatiCompanion.insert(id: 'x', userId: 'u', statusText: 'alt', createdAt: _jetzt));
    expect(await env.db.select(env.db.familienStati).get(), hasLength(1));
  });
}
