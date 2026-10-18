import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lx_familienzentrale/app.dart';
import 'package:lx_familienzentrale/constants.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FamilienzentraleApp()));
    await tester.pump();
  }

  testWidgets('zeigt zuerst die Platzhalter-Anmeldung', (tester) async {
    await start(tester);
    expect(find.text('Mit Passkey anmelden'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('Vorschau öffnet die fünf Tabs und wechselt zwischen ihnen', (tester) async {
    await start(tester);
    await tester.tap(find.text('Vorschau ohne Anmeldung (Phase 0)'));
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    for (final tab in kTabs) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab.label)), findsOneWidget);
    }

    for (final (tab, titel) in [(1, 'Kalender'), (2, 'Chat'), (3, 'Dateien'), (4, 'Listen')]) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(kTabs[tab].label)));
      await tester.pump();
      expect(find.text(titel).hitTestable(), findsWidgets, reason: titel);
    }
  });

  testWidgets('Sync-Indikator meldet den Zustand ohne Server', (tester) async {
    await start(tester);
    await tester.tap(find.text('Vorschau ohne Anmeldung (Phase 0)'));
    await tester.pump();
    expect(find.byTooltip('Nicht verbunden'), findsWidgets);
    expect(find.text('nicht verbunden'), findsOneWidget);
  });
}
