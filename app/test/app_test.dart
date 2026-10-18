import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lx_fampad/app.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/features/calendar/calendar_screen.dart';
import 'package:lx_fampad/features/chat/chat_screen.dart';
import 'package:lx_fampad/features/files/files_screen.dart';
import 'package:lx_fampad/features/home/home_screen.dart';
import 'package:lx_fampad/features/lists/lists_screen.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FampadApp()));
    await tester.pump();
  }

  testWidgets('zeigt zuerst die Platzhalter-Anmeldung', (tester) async {
    await start(tester);
    expect(find.text('Mit Passkey anmelden'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('Vorschau öffnet die fünf Tabs und zeigt nach jedem Wechsel genau den gewählten Tab', (tester) async {
    await start(tester);
    await tester.tap(find.text('Vorschau ohne Anmeldung (Phase 0)'));
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    for (final tab in kTabs) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab.label)), findsOneWidget);
    }

    // Die Tabs liegen in einem IndexedStack: alle Seiten sind im Baum, sichtbar (und bedienbar) ist nur die gewählte.
    // Der Titel im Tab-Inhalt (nicht die Beschriftung der NavigationBar) muss zum gewählten Tab passen.
    final seiten = <Type>[HomeScreen, CalendarScreen, ChatScreen, FilesScreen, ListsScreen];
    final titel = ['Hallo', 'Kalender', 'Chat', 'Dateien', 'Listen'];

    for (var tab = 0; tab < kTabs.length; tab++) {
      if (tab > 0) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(kTabs[tab].label)));
        await tester.pump();
      }
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, tab, reason: kTabs[tab].label);
      for (var i = 0; i < seiten.length; i++) {
        final inhalt = find.descendant(of: find.byType(IndexedStack), matching: find.text(titel[i]));
        if (i == tab) {
          expect(inhalt.hitTestable(), findsOneWidget, reason: 'Titel "${titel[i]}" muss bei Tab ${kTabs[tab].label} sichtbar sein');
          expect(find.descendant(of: find.byType(IndexedStack), matching: find.byType(seiten[i])), findsOneWidget);
        } else {
          expect(inhalt.hitTestable(), findsNothing, reason: 'Titel "${titel[i]}" darf bei Tab ${kTabs[tab].label} nicht sichtbar sein');
        }
      }
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
