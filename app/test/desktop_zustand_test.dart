// Desktop-Layout, Teil 2: Grenzen, Rollen, Zustandserhalt beim Wechsel, Semantik und Tastatur, Fußzeile, echte Daten.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/widgets/sync_anzeige.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _l1 = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, Size groesse, {double skala = 1.0, String role = 'admin', FakeServer? server, void Function(TestUmgebung)? vorher}) async {
    final env = await angemeldeteUmgebung(role: role, server: server);
    vorher?.call(env);
    await starteApp(tester, env, groesse: groesse, skala: skala);
    return env;
  }

  void einkauf(TestUmgebung env) {
    env.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
    for (var i = 0; i < 8; i++) {
      env.sync.andereAendert('list_item', '22222222-2222-4222-8222-00000000000$i', {'listId': _l1, 'text': 'Ding $i', 'position': i});
    }
  }

  Future<void> groesseAendern(WidgetTester tester, Size s) async {
    tester.view.physicalSize = s;
    await warte(tester);
  }

  testWidgets('Grenze: 899 px mobil, 900 px Desktop', (tester) async {
    await start(tester, const Size(899, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    await groesseAendern(tester, const Size(900, 800));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('lx-familyhub'), findsOneWidget);
    await groesseAendern(tester, const Size(899, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Admin: Hinweis zum Anlegen sichtbar', (tester) async {
    await start(tester, const Size(1440, 900));
    expect(find.textContaining('klicken zum Anlegen'), findsOneWidget);
  });

  testWidgets('Einkaufskarte zeigt echte Daten, Überstand "+ n weitere"', (tester) async {
    await start(tester, const Size(1440, 900), vorher: einkauf);
    await warte(tester, 10);
    expect(find.text('Ding 0'), findsOneWidget);
    expect(find.text('8 offen'), findsOneWidget);
    expect(find.text('+ 2 weitere'), findsOneWidget);
  });

  testWidgets('Familienkarte: "+ n weitere" bei mehr als 5 Mitgliedern, Skala 1.5 in 2 Spalten ohne Layoutfehler', (tester) async {
    final server = standardServer();
    server.json('GET /members', {
      'members': [
        for (var i = 0; i < 8; i++) userJson(id: '0f0e0d0c-0b0a-4908-8706-05040302010$i', name: 'Person $i', email: 'p$i@beispiel.de', role: i == 0 ? 'admin' : 'child'),
      ],
    });
    await start(tester, const Size(900, 700), skala: 1.5, server: server);
    await warte(tester, 10);
    expect(tester.takeException(), isNull);
    expect(find.text('+ 3 weitere'), findsOneWidget);
    // gleiche Reihe = zwei Spalten
    final a = tester.getTopLeft(find.text('// HEUTE & MORGEN'));
    final b = tester.getTopLeft(find.text('// CHAT · FAMILIE'));
    final c = tester.getTopLeft(find.text('// EINKAUFSLISTE'));
    expect(a.dy, b.dy);
    expect(c.dy, greaterThan(a.dy));
  });

  testWidgets('Zustand bleibt beim Tab-Wechsel und beim Wechsel Desktop <-> Mobil erhalten', (tester) async {
    await start(tester, const Size(1440, 900), vorher: einkauf);
    await tester.tap(find.text('Listen').first);
    await warte(tester);
    final feld = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Was fehlt?');
    expect(feld, findsOneWidget);
    await tester.enterText(feld, 'Entwurf Butter');
    await tester.pump();
    await tester.tap(find.text('Start').first);
    await warte(tester);
    expect(find.text('// EINKAUFSLISTE'), findsOneWidget);
    await tester.tap(find.text('Listen').first);
    await warte(tester);
    expect(find.text('Entwurf Butter'), findsOneWidget, reason: 'Tab-Wechsel');
    // verkleinern: Mobil
    await groesseAendern(tester, const Size(600, 900));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Entwurf Butter'), findsOneWidget, reason: 'Desktop -> Mobil');
    // Rückwechsel
    await groesseAendern(tester, const Size(1440, 900));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Entwurf Butter'), findsOneWidget, reason: 'Mobil -> Desktop');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Geräte werden einmal abgerufen, auch bei Moduswechsel', (tester) async {
    final env = await start(tester, const Size(1440, 900));
    await warte(tester, 10);
    expect(env.server.anfragen('GET /devices'), hasLength(1));
    expect(find.text('geräte: 2'), findsOneWidget);
    await groesseAendern(tester, const Size(600, 900));
    await groesseAendern(tester, const Size(1440, 900));
    expect(env.server.anfragen('GET /devices'), hasLength(1));
  });

  testWidgets('Semantik: Navigation und Karten sind per Tap-Aktion bedienbar', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, const Size(1440, 900));
    tester.semantics.tap(find.semantics.byLabel('Chat'));
    await warte(tester);
    expect(find.text('// HEUTE & MORGEN'), findsNothing);
    tester.semantics.tap(find.semantics.byLabel('Start'));
    await warte(tester);
    expect(find.text('// HEUTE & MORGEN'), findsOneWidget);
    final karte = find.semantics.byLabel(RegExp('^Einkaufsliste'));
    expect(karte, findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Einkaufsliste'))), isSemantics(hasTapAction: true, isFocusable: true, isButton: true));
    tester.semantics.tap(karte);
    await warte(tester);
    expect(find.text('// HEUTE & MORGEN'), findsNothing);
    handle.dispose();
  });

  for (final taste in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('Tastatur: Fokus auf "Chat" und ${taste == LogicalKeyboardKey.space ? 'Leertaste' : 'Enter'} wählt den Bereich', (tester) async {
      await start(tester, const Size(1440, 900));
      bool aufChat() {
        final ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) return false;
        // genau der Eintrag "Chat": das erste Text-Widget unterhalb des fokussierten Elements
        String? erster;
        void suche(Element e) {
          final w = e.widget;
          if (erster == null && w is Text) erster = w.data;
          if (erster == null) e.visitChildren(suche);
        }

        (ctx as Element).visitChildren(suche);
        return erster == 'Chat';
      }

      for (var i = 0; i < 16 && !aufChat(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(aufChat(), isTrue, reason: 'Fokus erreicht den Eintrag "Chat"');
      await tester.sendKeyEvent(taste);
      await warte(tester);
      expect(find.text('// HEUTE & MORGEN'), findsNothing);
    });
  }

  testWidgets('Fußzeile zeigt sync, geräte, verbindung und version', (tester) async {
    await start(tester, const Size(1440, 900));
    await warte(tester, 10);
    expect(find.textContaining('sync: '), findsOneWidget);
    expect(find.textContaining('verbindung: '), findsOneWidget);
    expect(find.text('version: dev'), findsOneWidget, reason: 'ohne WEB_VERSION-define Fallback dev, nie "–"');
  });

  test('syncAnzeige: Text und Farbe je Zustand (eine Quelle für Mobil und Desktop)', () {
    expect(syncAnzeige(const SyncState(status: SyncStatus.synchron)), ('synchron', kTerminal));
    expect(syncAnzeige(const SyncState(status: SyncStatus.synchron, offeneAenderungen: 2)), ('synchron · 2 offen', kTerminal));
    expect(syncAnzeige(const SyncState(status: SyncStatus.offline, offeneAenderungen: 1)), ('offline · 1 offen', kTextMuted));
    expect(syncAnzeige(const SyncState(status: SyncStatus.offline)), ('offline', kTextMuted));
    expect(syncAnzeige(const SyncState(status: SyncStatus.laeuft)), ('gleiche ab …', kTextMuted));
    expect(syncAnzeige(const SyncState(status: SyncStatus.fehler)), ('abgleich fehlgeschlagen', kDanger));
    expect(syncAnzeige(const SyncState(status: SyncStatus.updateNoetig)), ('update nötig', kTextMuted));
    expect(syncAnzeige(const SyncState()), ('nicht verbunden', kTextMuted));
  });
}
