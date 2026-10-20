// Desktop-Layout (ab kDesktopBreakpoint): Seitenleiste, Karten-Raster der Startseite, Umschalten auf Mobil, Navigation, Textskala 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';

import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, Size groesse, {double skala = 1.0}) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env, groesse: groesse, skala: skala);
    return env;
  }

  Finder navEintrag(String label) => find.bySemanticsLabel(label);

  for (final groesse in [const Size(1440, 900), const Size(900, 700)]) {
    testWidgets('${groesse.width.toInt()} px: Seitenleiste und Startseite', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester, groesse);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.text(kInviteHost), findsOneWidget);
      for (final t in kTabs) {
        expect(navEintrag(t.label), findsOneWidget, reason: t.label);
      }
      expect(find.text('bald'), findsNWidgets(2)); // Fotos, Orte (Aufgaben gibt es seit 1c-4a)
      expect(find.textContaining(RegExp('^Guten (Morgen|Tag|Abend)')), findsOneWidget);
      for (final l in ['// heute & morgen', '// chat · familie', '// einkaufsliste', '// zuletzt geteilt', '// aufgaben', '// familie & orte']) {
        expect(find.text(l.toUpperCase()), findsOneWidget, reason: l);
      }
      expect(find.text('Heute und morgen steht nichts an.'), findsOneWidget); // Termine-Karte ohne Termine
      expect(find.textContaining('sync: '), findsOneWidget);
      expect(find.textContaining('geräte: '), findsOneWidget);
      expect(find.textContaining('verbindung: '), findsOneWidget);
      expect(find.textContaining('version: '), findsOneWidget);
      expect(find.byTooltip('Benachrichtigungen'), findsOneWidget);
      expect(find.text('Neu'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Inhalt der Startseite höchstens kMaxContentWidthDesktop breit
      final w = tester.getSize(find.byType(DesktopHome)).width;
      expect(w, lessThanOrEqualTo(kMaxContentWidthDesktop));
      expect(w, groesse.width - kSidebarWidth);
      handle.dispose();
    });
  }

  testWidgets('3 Spalten bei 1440 px, 2 Spalten bei 900 px', (tester) async {
    await start(tester, const Size(1440, 900));
    final a = tester.getTopLeft(find.text('// HEUTE & MORGEN'));
    final b = tester.getTopLeft(find.text('// CHAT · FAMILIE'));
    final c = tester.getTopLeft(find.text('// EINKAUFSLISTE'));
    expect(a.dy, b.dy);
    expect(b.dy, c.dy);
    final d = tester.getTopLeft(find.text('// ZULETZT GETEILT'));
    expect(d.dy, greaterThan(a.dy));
  });

  testWidgets('600 px: mobil mit NavigationBar, ohne Seitenleiste', (tester) async {
    await start(tester, const Size(600, 900));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('lx-familyhub'), findsNothing);
    expect(find.textContaining('Hallo'), findsWidgets);
  });

  testWidgets('Navigation in der Seitenleiste, "bald"-Einträge sind inaktiv', (tester) async {
    await start(tester, const Size(1440, 900));
    await tester.tap(find.text('Chat').first);
    await warte(tester);
    expect(find.text('// HEUTE & MORGEN'), findsNothing);
    await tester.tap(find.text('Start').first);
    await warte(tester);
    expect(find.text('// HEUTE & MORGEN'), findsOneWidget);
    await tester.tap(find.text('Fotos').first, warnIfMissed: false);
    await warte(tester);
    expect(find.text('// HEUTE & MORGEN'), findsOneWidget);
    // Karte "Zuletzt geteilt" führt in Dateien
    await tester.tap(find.text('Noch keine Dateien'));
    await warte(tester);
    expect(find.text('// ZULETZT GETEILT'), findsNothing);
  });

  testWidgets('"+ Neu" bietet eine neue Liste an', (tester) async {
    await start(tester, const Size(1440, 900));
    await tester.tap(find.text('Neu'));
    await warte(tester);
    expect(find.text('Neue Liste'), findsOneWidget);
  });

  testWidgets('Umschalten Desktop -> Mobil beim Verkleinern', (tester) async {
    await start(tester, const Size(1440, 900));
    expect(find.byType(NavigationBar), findsNothing);
    tester.view.physicalSize = const Size(600, 900);
    await warte(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Textskala 1.5: keine Layoutfehler, Ziele >= 44 px', (tester) async {
    for (final groesse in [const Size(1440, 900), const Size(900, 700)]) {
      await start(tester, groesse, skala: 1.5);
      expect(tester.takeException(), isNull, reason: '${groesse.width}');
      for (final typ in [InkWell, IconButton]) {
        for (final e in find.byType(typ).evaluate()) {
          final w = e.widget;
          if (w is InkWell && w.onTap == null) continue;
          final box = e.renderObject as RenderBox?;
          if (box == null || !box.hasSize) continue;
          var versteckt = false;
          e.visitAncestorElements((a) {
            if (a.widget is Offstage && (a.widget as Offstage).offstage) versteckt = true;
            return !versteckt;
          });
          if (versteckt) continue;
          expect(box.size.height, greaterThanOrEqualTo(43.99), reason: '$typ ${box.size}');
        }
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  test('Tagesgruß nach Tageszeit und Namen', () {
    expect(tagesgruss('Anna Muster', DateTime(2026, 10, 19, 8)), 'Guten Morgen, Anna');
    expect(tagesgruss('Anna', DateTime(2026, 10, 19, 13)), 'Guten Tag, Anna');
    expect(tagesgruss('Anna', DateTime(2026, 10, 19, 20)), 'Guten Abend, Anna');
    expect(tagesgruss('', DateTime(2026, 10, 19, 20)), 'Guten Abend');
    expect(tagesgruss(null, DateTime(2026, 10, 19, 9)), 'Guten Morgen');
  });
}
