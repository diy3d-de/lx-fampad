// Desktop-Layout: Konto und Unterseiten liegen im Inhaltsbereich der Shell (Seitenleiste und Fußzeile bleiben), mobil bleiben es Vollseiten.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/calendar/termin_editor.dart';
import 'package:lx_fampad/features/home/desktop_home.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tasks/aufgabe_editor.dart';
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
    expect(find.text('Version dev'), findsOneWidget);
  }

  for (final groesse in [const Size(1200, 800), const Size(900, 700)]) {
    testWidgets('${groesse.width.toInt()} px: Konto und Unterseite innerhalb der Shell, Zurück funktioniert', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester, groesse);
      await tester.tap(kachel());
      await warte(tester);
      expect(find.text('Profil'), findsOneWidget);
      seitenleisteUndFusszeileDa();
      expect(tester.getTopLeft(find.text('Profil')).dx, greaterThan(248)); // rechts neben der Seitenleiste
      expect(find.byWidgetPredicate((w) => w is LxCard && w.gewaehlt), findsOneWidget); // Konto hervorgehoben

      // Unterseite öffnen: Seitenleiste und Fußzeile bleiben
      await tester.tap(find.text('Sicherheit'));
      await warte(tester);
      await tester.tap(find.text('Anmelden ohne Passwort'));
      await warte(tester);
      expect(find.text('Profil'), findsNothing);
      seitenleisteUndFusszeileDa();
      expect(tester.takeException(), isNull);

      // zurück über die Sammelseite zum Konto, dann zur Startseite
      await tester.tap(find.byTooltip('Zurück'));
      await warte(tester);
      await tester.tap(find.byTooltip('Zurück'));
      await warte(tester);
      expect(find.text('Profil'), findsOneWidget);
      await tester.tap(find.byTooltip('Zurück'));
      await warte(tester);
      expect(find.text('Profil'), findsNothing);
      expect(labelFinder('Heute und morgen'), findsOneWidget);
      seitenleisteUndFusszeileDa();
      handle.dispose();
    });
  }

  testWidgets('Seitenleisten-Eintrag schließt das Konto und wählt den Bereich', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, const Size(1200, 800));
    await tester.tap(kachel());
    await warte(tester);
    expect(find.text('Profil'), findsOneWidget);
    await tester.tap(find.text('Chat').first);
    await warte(tester);
    expect(find.text('Profil'), findsNothing);
    seitenleisteUndFusszeileDa();
    handle.dispose();
  });

  testWidgets('Textskala 1.5, 900 px: Konto in der Shell ohne Layoutfehler', (tester) async {
    await start(tester, const Size(900, 700), skala: 1.5);
    await tester.tap(kachel());
    await warte(tester);
    expect(find.text('Profil'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobil (600 px): Profil-Knopf öffnet eine Vollseite ohne Seitenleiste', (tester) async {
    await start(tester, const Size(600, 900));
    await tester.tap(find.byType(ProfilButton).first);
    await warte(tester);
    expect(find.text('Profil'), findsOneWidget);
    expect(find.text('lx-familyhub'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  Future<void> oeffnen(WidgetTester tester, Widget seite) async {
    final nav = Navigator.of(tester.element(find.byType(DesktopHome, skipOffstage: false)));
    nav.push<void>(MaterialPageRoute(builder: (_) => seite));
    await warte(tester);
  }

  int tab(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(DesktopHome, skipOffstage: false))).read(shellTabProvider);

  testWidgets('Seite mit PopScope(canPop: false) bleibt beim Bereichswechsel offen, der Bereich bleibt unverändert', (tester) async {
    await start(tester, const Size(1200, 800));
    await oeffnen(tester, const PopScope(canPop: false, child: Scaffold(body: Text('gesperrte Seite'))));
    await tester.tap(find.text('Chat').first);
    await warte(tester);
    expect(find.text('gesperrte Seite'), findsOneWidget);
    expect(tab(tester), 0);
    seitenleisteUndFusszeileDa();
  });

  testWidgets('Klick auf den schon gewählten Bereich schließt die Unterseite', (tester) async {
    await start(tester, const Size(1200, 800));
    await tester.tap(kachel());
    await warte(tester);
    expect(find.text('Profil'), findsOneWidget);
    await tester.tap(find.text('Start').first);
    await warte(tester);
    expect(find.text('Profil'), findsNothing);
    expect(labelFinder('Heute und morgen'), findsOneWidget);
  });

  testWidgets('Editor mit Eingaben: Bereichswechsel fragt nach; weiter bearbeiten bleibt, verwerfen schließt (Dialog im Shell-Navigator)', (tester) async {
    await start(tester, const Size(1200, 800));
    await oeffnen(tester, const AufgabeEditor());
    expect(find.text('Neue Aufgabe'), findsOneWidget);
    // ohne Eingaben: kein Dialog, Bereichswechsel schließt den Editor
    await tester.tap(find.text('Chat').first);
    await warte(tester);
    expect(find.text('Neue Aufgabe'), findsNothing);
    expect(tab(tester), kChatTab);
    await tester.tap(find.text('Start').first);
    await warte(tester);
    await oeffnen(tester, const AufgabeEditor());
    await tester.enterText(find.descendant(of: find.byType(AufgabeEditor), matching: find.byType(TextField)).first, 'Müll rausbringen');
    await tester.pump();
    await tester.tap(find.text('Chat').first);
    await warte(tester);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    expect(tab(tester), 0);
    seitenleisteUndFusszeileDa();
    await tester.tap(find.text('Weiter bearbeiten'));
    await warte(tester);
    expect(find.text('Neue Aufgabe'), findsOneWidget);
    expect(find.text('Änderungen verwerfen?'), findsNothing);
    await tester.tap(find.byTooltip('Zurück'));
    await warte(tester);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Verwerfen'));
    await warte(tester);
    expect(find.text('Neue Aufgabe'), findsNothing);
    expect(find.text('Änderungen verwerfen?'), findsNothing);
    expect(labelFinder('Heute und morgen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (name, editor, titel) in [('Aufgaben-Editor', const AufgabeEditor(), 'Neue Aufgabe'), ('Termin-Editor', const TerminEditor(), 'Neuer Termin')]) {
    testWidgets('$name: "Verwerfen" nach einem Bereichswechsel schließt die Seite und wählt den Bereich; "Weiter bearbeiten" nicht', (tester) async {
      await start(tester, const Size(1200, 800));
      await oeffnen(tester, editor);
      await tester.enterText(find.descendant(of: find.byType(editor.runtimeType), matching: find.byType(TextField)).first, 'Etwas');
      await tester.pump();
      await tester.tap(find.text('Chat').first);
      await warte(tester);
      expect(find.text('Änderungen verwerfen?'), findsOneWidget);
      await tester.tap(find.text('Weiter bearbeiten'));
      await warte(tester);
      expect(find.text(titel), findsOneWidget);
      expect(tab(tester), 0);
      // später ein Zurück ohne Rückfrage-Bezug zum alten Ziel: Verwerfen über den Pfeil wählt keinen Bereich
      await tester.tap(find.byTooltip('Zurück'));
      await warte(tester);
      await tester.tap(find.text('Verwerfen'));
      await warte(tester);
      expect(find.text(titel), findsNothing);
      expect(tab(tester), 0);
      // erneut öffnen: Wechsel, Verwerfen -> Chat ist gewählt
      await oeffnen(tester, editor);
      await tester.enterText(find.descendant(of: find.byType(editor.runtimeType), matching: find.byType(TextField)).first, 'Etwas');
      await tester.pump();
      await tester.tap(find.text('Chat').first);
      await warte(tester);
      await tester.tap(find.text('Verwerfen'));
      await warte(tester);
      expect(find.text(titel), findsNothing);
      expect(tab(tester), kChatTab);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mobil: Editor ohne Rückfrage beim Zurück', (tester) async {
    await start(tester, const Size(600, 900));
    final nav = Navigator.of(tester.element(find.byType(Scaffold).first));
    nav.push<void>(MaterialPageRoute(builder: (_) => const AufgabeEditor()));
    await warte(tester);
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.tap(find.byTooltip('Zurück'));
    await warte(tester);
    expect(find.text('Änderungen verwerfen?'), findsNothing);
    expect(find.text('Neue Aufgabe'), findsNothing);
  });
}
