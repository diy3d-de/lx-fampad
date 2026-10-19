// Mobilansicht: 360 px Breite (kleinstes unterstütztes Handy) bei Textskalierung 1.0 und 1.5 über Anmeldung und
// alle fünf Tabs (angemeldet über den Fake-Server; Anmeldung und Konto-Screens: auth_layout_test.dart). Geprüft werden: keine Layoutfehler (Overflow u. ä.) und Touch-Ziele von mindestens 44 px.
// Die echten Schriften werden geladen, weil die Standardschrift der Tests (Ahem) andere Breiten hat.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lx_fampad/app.dart';
import 'package:lx_fampad/constants.dart';

import 'support/fake_server.dart';
import 'support/test_app.dart';

const _breite = 360.0;
const _minZiel = 44.0;

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de_DE');
    for (final (familie, datei) in [('Inter', 'assets/fonts/Inter.ttf'), ('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf')]) {
      final lader = FontLoader(familie)..addFont(Future.value(ByteData.sublistView(File(datei).readAsBytesSync())));
      await lader.load();
    }
  });

  /// Größen aller antippbaren Elemente, die kleiner als 44 px sind (Tipp-Fläche, nicht nur sichtbare Form).
  List<String> kleineZiele(WidgetTester tester) {
    final zu = <String>[];
    void pruefe(Element element, String name) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached || !_sichtbar(element)) return;
      final s = box.size;
      if (s.height < _minZiel - 0.01 || s.width < _minZiel - 0.01) {
        zu.add('$name ${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)}');
      }
    }

    // Material-Knöpfe vergrößern ihre Tipp-Fläche auf 48 px (MaterialTapTargetSize.padded, im Theme gesetzt):
    // gemessen wird die Größe des Knopf-Widgets selbst.
    for (final typ in <Type>[IconButton, TextButton, FilledButton, OutlinedButton, FloatingActionButton]) {
      for (final element in find.byType(typ).evaluate()) {
        pruefe(element, typ.toString());
      }
    }
    // Eigene Tippflächen (InkWell/InkResponse, z. B. Karten, Kalenderzellen, Reiter): nur solche mit Aktion und
    // ohne Knopf oder Navigationsleiste darüber (deren Größe ist oben bzw. durch NavigationBar gesichert).
    for (final typ in <Type>[InkWell, InkResponse]) {
      for (final element in find.byType(typ).evaluate()) {
        final w = element.widget;
        final onTap = w is InkWell ? w.onTap : (w as InkResponse).onTap;
        if (onTap == null || _hatVorfahr(element, (a) => a is ButtonStyleButton || a is IconButton || a is NavigationBar)) continue;
        pruefe(element, typ.toString());
      }
    }
    return zu;
  }

  for (final skala in [1.0, 1.5]) {
    testWidgets('360 px Breite, Textskalierung $skala: alle Tabs ohne Layoutfehler, Ziele >= 44 px', (tester) async {
      tester.view.physicalSize = const Size(_breite, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = skala;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await _angemeldetStarten(tester);
      expect(tester.takeException(), isNull, reason: 'Start');

      for (var i = 0; i < kTabs.length; i++) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(kTabs[i].label)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'Tab ${kTabs[i].label}');
        expect(kleineZiele(tester), isEmpty, reason: 'Tab ${kTabs[i].label}: Touch-Ziele unter $_minZiel px');
      }

      // Kalender: Monat wechseln und Tag antippen darf nichts brechen
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
      await tester.pump();
      await tester.tap(find.byTooltip('Nächster Monat'));
      await tester.pump();
      await tester.tap(find.text('15').hitTestable());
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'Kalender bedienen');
      expect(kleineZiele(tester), isEmpty, reason: 'Kalender nach Bedienung');

      // Listen: leerer Zustand, Liste anlegen, Eintrag hinzufügen (Layout und Ziele)
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Listen')));
      await tester.pump();
      expect(find.text('Noch keine Liste'), findsOneWidget);
      expect(kleineZiele(tester), isEmpty, reason: 'Listen leer');
      await tester.tap(find.text('Liste anlegen'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.widgetWithText(TextField, 'Name der Liste'), 'Wocheneinkauf mit einem ziemlich langen Namen');
      await tester.tap(find.text('Anlegen'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'Milch und etwas, das mit einem sehr langen Text in mehrere Zeilen umbricht');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Milch und etwas'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'Listen bedienen');
      expect(kleineZiele(tester), isEmpty, reason: 'Listen mit Eintrag');
    });
  }

  testWidgets('Breites Tablet (unter dem Desktop-Umbruch): Inhalt bleibt auf kMaxContentWidth begrenzt und zentriert', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _angemeldetStarten(tester);
    expect(tester.takeException(), isNull);

    final stack = tester.getRect(find.byType(IndexedStack));
    expect(stack.width, kMaxContentWidth);
    expect(stack.center.dx, closeTo(400, 0.5));
  });
}

Future<void> _angemeldetStarten(WidgetTester tester) async {
  final env = TestUmgebung(standardServer());
  await env.angemeldet();
  final container = env.container();
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const FampadApp()));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _hatVorfahr(Element element, bool Function(Widget) test) {
  var gefunden = false;
  element.visitAncestorElements((a) {
    if (test(a.widget)) {
      gefunden = true;
      return false;
    }
    return true;
  });
  return gefunden;
}

/// Ob das Element sichtbar ist: nicht unter einem Offstage (z. B. die nicht gewählten Seiten des IndexedStack).
bool _sichtbar(Element element) => !_hatVorfahr(element, (w) => w is Offstage && w.offstage);
