import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/sync_state.dart' show SyncZeiten;
import 'package:lx_fampad/features/calendar/calendar_screen.dart';
import 'package:lx_fampad/features/chat/chat_screen.dart';
import 'package:lx_fampad/features/home/home_screen.dart';
import 'package:lx_fampad/features/lists/lists_screen.dart';
import 'package:lx_fampad/features/tasks/tasks_screen.dart';
import 'package:lx_fampad/features/update/update_banner.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  testWidgets('ohne gespeicherte Anmeldung erscheint die Anmeldung (kein Zugriff auf die Tabs)', (tester) async {
    final env = TestUmgebung(FakeServer());
    await starteApp(tester, env);
    expect(find.text('Mit Passkey anmelden'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(env.server.log.where((r) => r.path == '/me'), isEmpty, reason: 'ohne Token kein Serveraufruf');
  });

  testWidgets('angemeldet: Leiste mit vier Bereichen und Mehr, nach jedem Wechsel zeigt der Stapel genau den gewählten Bereich', (tester) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env);

    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in ['Start', 'Kalender', 'Chat', 'Aufgaben', 'Mehr']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget, reason: label);
    }
    // Listen liegen hinter "Mehr", Dateien sind ausgeblendet
    for (final label in ['Listen', 'Dateien']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsNothing, reason: label);
    }

    // Die Bereiche liegen in einem IndexedStack: alle Seiten sind im Baum, sichtbar (und bedienbar) ist nur der gewählte.
    // Der Titel im Inhalt (nicht die Beschriftung der NavigationBar) muss zum gewählten Bereich passen.
    final seiten = <Type>[HomeScreen, CalendarScreen, ChatScreen, ListsScreen, TasksScreen];
    final titel = ['Hallo, Anna', 'Kalender', 'Chat', 'Listen', 'Aufgaben'];
    final tabs = [0, 1, 2, 4, 5];
    final namen = ['Start', 'Kalender', 'Chat', 'Listen', 'Aufgaben'];

    for (var n = 0; n < tabs.length; n++) {
      if (n > 0) await zumBereich(tester, namen[n]);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, tabs[n], reason: namen[n]);
      for (var i = 0; i < seiten.length; i++) {
        final inhalt = find.descendant(of: find.byType(IndexedStack), matching: find.byWidgetPredicate((w) => w is Text && w.data == titel[i] && w.style?.fontSize == 26));
        if (i == n) {
          expect(inhalt.hitTestable(), findsWidgets, reason: 'Titel "${titel[i]}" muss bei ${namen[n]} sichtbar sein');
          expect(find.descendant(of: find.byType(IndexedStack), matching: find.byType(seiten[i])), findsOneWidget);
        } else {
          expect(inhalt.hitTestable(), findsNothing, reason: 'Titel "${titel[i]}" darf bei ${namen[n]} nicht sichtbar sein');
        }
      }
    }
  });

  testWidgets('Sync-Indikator und Startseite melden "synchron", sobald der Abgleich gelaufen ist', (tester) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env);
    expect(find.byTooltip('Alles aktuell. Tippen zum Übertragen'), findsWidgets);
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Sync: Alles aktuell'), findsOneWidget, reason: 'bei "synchron" nur ein Punkt, kein Text');
    expect(env.sync.anfragen, isNotEmpty, reason: 'beim Start wird sofort abgeglichen');
  });

  testWidgets('ohne Netz zeigt der Sync-Indikator offline, die lokalen Daten bleiben bedienbar', (tester) async {
    final env = await angemeldeteUmgebung();
    env.sync.offline = true;
    await starteApp(tester, env);
    expect(find.byTooltip('Offline'), findsWidgets);
    expect(find.text('Du bist offline. Alles ist auf diesem Gerät gespeichert.'), findsOneWidget, reason: 'der Zustand steht auf der Startseite genau einmal');
    expect(find.byIcon(Icons.cloud_off), findsWidgets, reason: 'Symbol UND Text, nie nur Farbe');
  });

  testWidgets('Serverfehler: Startseite zeigt Symbol, Text und die Handlung "Erneut versuchen" (Touch-Ziel >= 44 px), der Tipp gleicht erneut ab', (tester) async {
    final env = await angemeldeteUmgebung();
    env.zeiten = const SyncZeiten(backoffStart: Duration(minutes: 5));
    env.sync.fehlerQueue.add((500, 'internal_error'));
    await starteApp(tester, env);
    expect(find.text('Übertragen hat nicht geklappt'), findsOneWidget);
    final knopf = find.widgetWithText(TextButton, 'Erneut versuchen');
    expect(knopf, findsOneWidget);
    expect(tester.getSize(knopf).height, greaterThanOrEqualTo(44));
    final n = env.server.anfragen('POST /sync').length;
    await tippe(tester, knopf);
    await warte(tester, 10);
    expect(env.server.anfragen('POST /sync').length, greaterThan(n));
    expect(find.text('Übertragen hat nicht geklappt'), findsNothing);
  });

  testWidgets('Desktop: Fußzeile zeigt beim Fehler Symbol, Text und die Handlung', (tester) async {
    final env = await angemeldeteUmgebung();
    env.zeiten = const SyncZeiten(backoffStart: Duration(minutes: 5));
    env.sync.fehlerQueue.add((500, 'internal_error'));
    await starteApp(tester, env, groesse: const Size(1280, 900));
    expect(find.text('Übertragen hat nicht geklappt'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Erneut versuchen'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsWidgets);
  });

  testWidgets('426 vom Sync (Protokoll zu alt): die Pflicht-Update-Seite ersetzt die App, es folgt kein weiterer Abgleich', (tester) async {
    final env = await angemeldeteUmgebung();
    env.sync.fehlerQueue.add((426, 'update_required'));
    await starteApp(tester, env);
    await warte(tester, 10);
    expect(find.byType(PflichtUpdateSeite), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    final n = env.server.anfragen('POST /sync').length;
    await tester.pump(const Duration(minutes: 10));
    expect(env.server.anfragen('POST /sync').length, n);
  });

  testWidgets('wartendes Konto sieht den Warte-Bildschirm, nicht die App', (tester) async {
    final server = FakeServer()..json('GET /me', meJson(role: 'child', status: 'pending'));
    final env = TestUmgebung(server);
    await env.angemeldet();
    await starteApp(tester, env);
    expect(find.textContaining('Fast geschafft'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('Verbindungsfehler beim Start ohne gespeichertes Profil: Meldung und "Erneut versuchen"', (tester) async {
    final server = FakeServer()..on('GET /me', (_) => fehler(503, 'server_busy', retryAfter: 4));
    final env = TestUmgebung(server);
    await env.angemeldet();
    await starteApp(tester, env);
    expect(find.textContaining('ausgelastet'), findsOneWidget);
    server.json('GET /me', meJson());
    await tippeText(tester, 'Erneut versuchen');
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
