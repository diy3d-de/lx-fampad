// Barrierefreiheit: Durchgang über die wichtigsten Oberflächen bei 360 px und Textskala 2.0 (kein Überlauf, Touch-Ziele mindestens 44 px) und eine Prüfung des Semantics-Baums:
// jedes antippbare Element und jedes Textfeld hat eine Beschriftung (Label, Hinweis, Wert oder Tooltip), damit ein Screenreader nie "Schaltfläche" ohne Namen vorliest.
// Die Kontraste der Token prüft kontrast_test.dart, die Suche, das Teilen und die Chat-Suche haben ihre Layout-Tests mit Textskala 2.0 selbst.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/features/neuigkeiten/neuigkeiten_dialog.dart';
import 'package:lx_fampad/data/neuigkeiten/neuigkeiten.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart' show EinstellungsZeile;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/suche/such_einstieg.dart' show SuchKnopf;

import 'support/chat_ui_aufbau.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

/// Alle sichtbaren, antippbaren Knoten und Textfelder des Semantics-Baums ohne Beschriftung (Pfad zur Fehlersuche).
List<String> unbeschriftet(WidgetTester tester) {
  final wurzel = tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  final fehler = <String>[];
  if (wurzel == null) return ['kein Semantics-Baum (ensureSemantics fehlt)'];
  void besuche(SemanticsNode n, String pfad) {
    final d = n.getSemanticsData();
    // in den Elternknoten eingemischte Knoten (z. B. der Schalter in einer SwitchListTile) zählen mit diesem
    final versteckt = d.flagsCollection.isHidden || n.isMergedIntoParent;
    if (!versteckt) {
      final bedienbar = d.hasAction(SemanticsAction.tap) || d.flagsCollection.isTextField;
      final name = d.label.trim().isNotEmpty || d.value.trim().isNotEmpty || d.hint.trim().isNotEmpty || d.tooltip.trim().isNotEmpty;
      // ein innerer Knoten gleicher Größe unter einem benannten Knoten gehört zum selben Bedienelement (z. B. der Knopf unter dem Tooltip des Schwebeknopfs)
      final elter = n.parent?.getSemanticsData();
      final vomElterBenannt = elter != null && n.parent!.rect.size == n.rect.size && (elter.label.trim().isNotEmpty || elter.tooltip.trim().isNotEmpty);
      if (bedienbar && !name && !vomElterBenannt) fehler.add('$pfad/${n.id} ${n.rect.size.width.round()}x${n.rect.size.height.round()}');
    }
    n.visitChildren((c) {
      besuche(c, '$pfad/${n.id}');
      return true;
    });
  }

  besuche(wurzel, '');
  return fehler;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  const l1 = '11111111-1111-4111-8111-111111111111';

  Future<TestUmgebung> start(WidgetTester tester, {double skala = 2.0, Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung();
    env.sync.andereAendert('list', l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
    for (final (i, e) in [('Milch', 'Kühlregal'), ('Vollkornbrot mit Sonnenblumenkernen und Leinsamen', 'Backwaren'), ('Äpfel', 'Obst und Gemüse')].indexed) {
      env.sync.andereAendert('list_item', '33333333-3333-4333-8333-00000000000$i', {'listId': l1, 'text': e.$1, 'position': i, 'category': null});
    }
    env.sync.andereAendert('aufgabe', 'bbbbbbbb-1111-4111-8111-111111111111', {'titel': 'Eine Aufgabe mit einem langen Titel, der umbrechen muss', 'beschreibung': '', 'prioritaet': 3});
    env.sync.andereAendert('termin', 'aaaaaaaa-1111-4111-8111-111111111111', {
      'titel': 'Zahnarzt',
      'ganztaegig': true,
      'startDate': '2026-11-14',
      'endDate': '2026-11-15',
      'ownerId': fixIdAdmin,
      'audience': 'family',
    });
    await starteApp(tester, env, skala: skala, groesse: groesse);
    return env;
  }

  Future<void> zumTab(WidgetTester tester, String label) async {
    await zumBereich(tester, label);
  }

  void pruefe(WidgetTester tester, String wo) {
    pruefeLayout(tester, wo);
    final ohne = unbeschriftet(tester);
    expect(ohne, isEmpty, reason: '$wo: Elemente ohne Beschriftung im Semantics-Baum');
  }

  for (final skala in [1.0, 2.0]) {
    group('Textskala $skala', () {
      testWidgets('Startseite', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        pruefe(tester, 'Startseite $skala');
        h.dispose();
      });

      testWidgets('Listen (Einkaufsliste mit Einträgen)', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await zumTab(tester, 'Listen');
        pruefe(tester, 'Listen $skala');
        h.dispose();
      });

      testWidgets('Chat-Liste', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await zumTab(tester, 'Chat');
        pruefe(tester, 'Chat-Liste $skala');
        h.dispose();
      });

      testWidgets('Aufgaben und Kalender', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await zumTab(tester, 'Aufgaben');
        pruefe(tester, 'Aufgaben $skala');
        await zumTab(tester, 'Kalender');
        pruefe(tester, 'Kalender $skala');
        h.dispose();
      });

      testWidgets('Profil: Hauptseite und Sammelseiten', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        pruefe(tester, 'Profil-Hauptseite $skala');
        for (final seite in ['Sicherheit', 'Benachrichtigungen', 'Startseite und Anzeige']) {
          await tippe(tester, find.text(seite));
          pruefe(tester, 'Profil > $seite $skala');
          await tippe(tester, find.byTooltip('Zurück'));
        }
        h.dispose();
      });
    });
  }

  for (final skala in [1.0, 2.0]) {
    group('Weitere Seiten, Textskala $skala', () {
      testWidgets('Kalender-Einstellungen, Startseite anpassen', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippe(tester, find.widgetWithText(EinstellungsZeile, 'Kalender'));
        pruefe(tester, 'Kalender-Einstellungen $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippe(tester, find.text('Startseite und Anzeige'));
        await tippe(tester, find.text('Startseite anpassen'));
        pruefe(tester, 'Startseite anpassen $skala');
        h.dispose();
      });

      testWidgets('Suche und Teilen-Auswahl', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await tippe(tester, find.byType(SuchKnopf));
        pruefe(tester, 'Suche leer $skala');
        await tester.enterText(find.byType(TextField), 'zahn');
        await tester.pump(const Duration(milliseconds: 300));
        await warte(tester);
        pruefe(tester, 'Suche mit Treffern $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        const codec = StandardMethodCodec();
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(kSystemChannel, codec.encodeMethodCall(const MethodCall('share', 'Ein geteilter Text')), (_) {});
        await warte(tester);
        pruefe(tester, 'Teilen-Auswahl $skala');
        h.dispose();
      });

      testWidgets('Chat-Verlauf mit Suchleiste', (tester) async {
        final h = tester.ensureSemantics();
        final env = await angemeldeteUmgebung();
        final a = ChatUiAufbau(env);
        env.extraOverrides.addAll(a.overrides);
        env.server.json('GET /members', {
          'members': [userJson(), userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'), userJson(id: coraId, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de')],
        });
        const fam = '44444444-4444-4444-8444-444444444444';
        env.sync.andereAendert('konversation', fam, {'art': 'family', 'encVersion': 'e1', 'titel': '', 'teilnehmer': <String>[], 'ownerId': null, 'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String()});
        await a.epoche(fam, [a.anna, a.ben, a.cora], art: 'family');
        await a.nachricht(fam, 'a0000000-0000-4000-8000-000000000001', a.ben, 'Wer holt heute die Kinder ab? Das ist eine längere Nachricht, die umbrechen muss.', DateTime.now().toUtc().subtract(const Duration(minutes: 30)).toIso8601String());
        await starteApp(tester, env, skala: skala);
        await zumTab(tester, 'Chat');
        await tippe(tester, find.textContaining('Wer holt heute'));
        pruefe(tester, 'Chat-Verlauf $skala');
        await tippe(tester, find.byTooltip('Im Chat suchen'));
        await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'In diesem Chat suchen …'), 'kinder');
        await tester.pump(const Duration(milliseconds: 400));
        await warte(tester, 10);
        pruefe(tester, 'Chat-Suchleiste $skala');
        h.dispose();
      });

      testWidgets('Neuigkeiten-Dialog und Countdown-Kachel', (tester) async {
        final h = tester.ensureSemantics();
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () => neuigkeitenDialogZeigen(ctx, Neuigkeit('0.9.2', [for (var i = 0; i < 4; i++) 'Ein längerer Stichpunkt Nummer $i, der in der schmalen Breite umbrechen muss']), onGesehen: () {}),
                  child: const Text('auf'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('auf'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(unbeschriftet(tester), isEmpty, reason: 'Neuigkeiten-Dialog');
        expect(tester.getSize(find.byType(TextButton).last).height, greaterThanOrEqualTo(44));
        h.dispose();
      });
    });
  }

  testWidgets('Prüfer erkennt einen Icon-Knopf ohne Beschriftung und akzeptiert einen mit Tooltip', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Row(children: [IconButton(icon: const Icon(Icons.add), onPressed: () {})]))));
    expect(unbeschriftet(tester), isNotEmpty);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Row(children: [IconButton(tooltip: 'Hinzufügen', icon: const Icon(Icons.add), onPressed: () {})]))));
    expect(unbeschriftet(tester), isEmpty);
    h.dispose();
  });

  testWidgets('Desktop-Layout: Seitenleiste und Startseite haben beschriftete Bedienelemente', (tester) async {
    final h = tester.ensureSemantics();
    final env = await start(tester, skala: 1.0, groesse: const Size(1200, 800));
    expect(env, isNotNull);
    pruefe(tester, 'Desktop-Startseite');
    h.dispose();
  });

  test('Konstante: Touch-Ziel-Mindestmaß', () => expect(minZiel, 44.0));
  test('Konstante: Desktop-Grenze', () => expect(kDesktopBreakpoint, 900.0));
  test('Konstante: Listen-Tab', () => expect(kTabs[kListenTab].label, 'Listen'));
}
