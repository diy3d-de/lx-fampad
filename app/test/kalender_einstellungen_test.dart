// Profil > Kalender: Abschnitt "Import und Export" mit den beiden Einträgen, die die vorhandenen Abläufe öffnen; Zeile in der Profilliste.
// Layout bei 360 px (Textskala 1.0 und 1.5), Touch-Ziele mindestens 44 px, Desktop-Shell (Seitenleiste bleibt).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/calendar/ics_export_screen.dart';
import 'package:lx_fampad/features/calendar/ics_import_screen.dart';
import 'package:lx_fampad/features/profile/kalender_einstellungen_screen.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart' show EinstellungsZeile;

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<void> oeffneMobil(WidgetTester tester, {double skala = 1.0}) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env, skala: skala);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippe(tester, find.widgetWithText(EinstellungsZeile, 'Kalender'));
  }

  for (final skala in [1.0, 1.5]) {
    testWidgets('Textskala $skala (360 px): Abschnitt und beide Einträge sichtbar, kein Überlauf, Touch-Ziele mindestens 44 px', (tester) async {
      await oeffneMobil(tester, skala: skala);
      expect(find.byType(KalenderEinstellungenScreen), findsOneWidget);
      expect(find.text('IMPORT UND EXPORT'), findsOneWidget);
      expect(find.text('Datei importieren (.ics)'), findsOneWidget);
      expect(find.text('Kalender exportieren'), findsOneWidget);
      for (final e in find.byType(EinstellungsZeile).evaluate()) {
        expect((e.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(44));
      }
      pruefeLayout(tester, 'Kalender-Einstellungen');
    });
  }

  testWidgets('Einträge öffnen Import und Export, zurück landet auf der Seite Kalender', (tester) async {
    await oeffneMobil(tester);
    await tippe(tester, find.text('Datei importieren (.ics)'));
    expect(find.byType(IcsImportScreen), findsOneWidget);
    await tippe(tester, find.byTooltip('Zurück'));
    expect(find.byType(KalenderEinstellungenScreen), findsOneWidget);
    await tippe(tester, find.text('Kalender exportieren'));
    expect(find.byType(IcsExportScreen), findsOneWidget);
    await tippe(tester, find.byTooltip('Zurück'));
    expect(find.byType(KalenderEinstellungenScreen), findsOneWidget);
  });

  testWidgets('Semantics: Einträge sind als Schaltflächen mit Titel erreichbar', (tester) async {
    final handle = tester.ensureSemantics();
    await oeffneMobil(tester);
    expect(find.bySemanticsLabel(RegExp('Datei importieren')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Kalender exportieren')), findsWidgets);
    handle.dispose();
  });

  testWidgets('Desktop (1200 px): Seite liegt im Inhaltsbereich, Seitenleiste und Fußzeile bleiben, Import öffnet ebenfalls dort', (tester) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env, groesse: const Size(1200, 800));
    await tippe(tester, find.byIcon(Icons.settings_outlined));
    await tippe(tester, find.widgetWithText(EinstellungsZeile, 'Kalender'));
    expect(find.byType(KalenderEinstellungenScreen), findsOneWidget);
    expect(find.text('lx-familyhub'), findsOneWidget);
    expect(find.textContaining('sync: '), findsOneWidget);
    expect(tester.getTopLeft(find.text('IMPORT UND EXPORT')).dx, greaterThan(248), reason: 'rechts neben der Seitenleiste');
    await tippe(tester, find.text('Datei importieren (.ics)'));
    expect(find.byType(IcsImportScreen), findsOneWidget);
    expect(find.text('lx-familyhub'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
