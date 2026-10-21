// Desktop-Layout: Konto und Unterseiten liegen im Inhaltsbereich der Shell (Seitenleiste und Fußzeile bleiben), mobil bleiben es Vollseiten.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/ui/widgets.dart';
import 'package:lx_fampad/widgets/kopfzeile.dart';

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<void> start(WidgetTester tester, Size groesse, {double skala = 1.0}) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env, groesse: groesse, skala: skala);
  }

  Finder kachel() => find.byIcon(Icons.settings_outlined);

  void seitenleisteUndFusszeileDa() {
    expect(find.text('lx-familyhub'), findsOneWidget);
    expect(find.textContaining('sync: '), findsOneWidget);
    expect(find.textContaining('version: '), findsOneWidget);
  }

  for (final groesse in [const Size(1200, 800), const Size(900, 700)]) {
    testWidgets('${groesse.width.toInt()} px: Konto und Unterseite innerhalb der Shell, Zurück funktioniert', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester, groesse);
      await tester.tap(kachel());
      await warte(tester);
      expect(find.text('Profil & Sicherheit'), findsOneWidget);
      seitenleisteUndFusszeileDa();
      expect(tester.getTopLeft(find.text('Profil & Sicherheit')).dx, greaterThan(248)); // rechts neben der Seitenleiste
      expect(find.byWidgetPredicate((w) => w is LxCard && w.gewaehlt), findsOneWidget); // Konto hervorgehoben

      // Unterseite öffnen: Seitenleiste und Fußzeile bleiben
      await tester.tap(find.text('Passkeys'));
      await warte(tester);
      expect(find.text('Profil & Sicherheit'), findsNothing);
      seitenleisteUndFusszeileDa();
      expect(tester.takeException(), isNull);

      // zurück zum Konto, dann zur Startseite
      await tester.tap(find.byTooltip('Zurück'));
      await warte(tester);
      expect(find.text('Profil & Sicherheit'), findsOneWidget);
      await tester.tap(find.byTooltip('Zurück'));
      await warte(tester);
      expect(find.text('Profil & Sicherheit'), findsNothing);
      expect(find.text('// HEUTE & MORGEN'), findsOneWidget);
      seitenleisteUndFusszeileDa();
      handle.dispose();
    });
  }

  testWidgets('Seitenleisten-Eintrag schließt das Konto und wählt den Bereich', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, const Size(1200, 800));
    await tester.tap(kachel());
    await warte(tester);
    expect(find.text('Profil & Sicherheit'), findsOneWidget);
    await tester.tap(find.text('Chat').first);
    await warte(tester);
    expect(find.text('Profil & Sicherheit'), findsNothing);
    seitenleisteUndFusszeileDa();
    handle.dispose();
  });

  testWidgets('Textskala 1.5, 900 px: Konto in der Shell ohne Layoutfehler', (tester) async {
    await start(tester, const Size(900, 700), skala: 1.5);
    await tester.tap(kachel());
    await warte(tester);
    expect(find.text('Profil & Sicherheit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobil (600 px): Profil-Knopf öffnet eine Vollseite ohne Seitenleiste', (tester) async {
    await start(tester, const Size(600, 900));
    await tester.tap(find.byType(ProfilButton).first);
    await warte(tester);
    expect(find.text('Profil & Sicherheit'), findsOneWidget);
    expect(find.text('lx-familyhub'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
