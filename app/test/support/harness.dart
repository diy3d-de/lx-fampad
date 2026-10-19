// Widget-Test-Hilfen: Schriften laden, App mit Fake-Server starten, tippen/warten, Layoutprüfung (360 px, Textskala, Touch-Ziele).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lx_fampad/app.dart';
import 'package:lx_fampad/constants.dart';

import 'fake_server.dart';
import 'test_app.dart';

const minZiel = 44.0;

/// Aufrufe des System-Kanals (Gerätename, Bildschirmschutz ...) seit dem Start der App im Test.
final kanalAufrufe = <MethodCall>[];

/// Antwortet die Android-Seite auf "copySensitive" mit Erfolg (sonst fällt die App auf die normale Zwischenablage zurück)?
bool kanalGeheimOk = false;

/// Ersetzt die Android-Seite des System-Kanals (ohne Mock bliebe ein Kanalaufruf im Test hängen).
void kanalMocken() {
  kanalAufrufe.clear();
  kanalGeheimOk = false;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel(kSystemChannel), (call) async {
    kanalAufrufe.add(call);
    if (call.method == 'copySensitive') return kanalGeheimOk;
    return call.method == 'deviceName' ? 'Pixel 9' : null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel(kSystemChannel), null));
}

/// Lädt die echten Schriften (die Test-Standardschrift Ahem hat andere Breiten) und die deutschen Datumsformate.
Future<void> testVorbereiten() async {
  await initializeDateFormatting('de_DE');
  for (final (familie, datei) in [('Inter', 'assets/fonts/Inter.ttf'), ('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf')]) {
    final lader = FontLoader(familie)..addFont(Future.value(ByteData.sublistView(File(datei).readAsBytesSync())));
    await lader.load();
  }
}

/// Startet die ganze App (FampadApp) mit dem Fake-Server auf einem 360-px-Handy.
Future<ProviderContainer> starteApp(
  WidgetTester tester,
  TestUmgebung env, {
  double skala = 1.0,
  Size groesse = const Size(360, 800),
}) async {
  tester.view.physicalSize = groesse;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = skala;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  kanalMocken();
  final container = env.container();
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const FampadApp()));
  await warte(tester);
  return container;
}

/// Lässt anstehende Futures (Fake-Server antwortet sofort) und Übergänge ablaufen, ohne auf Dauer-Animationen zu warten.
Future<void> warte(WidgetTester tester, [int runden = 6]) async {
  for (var i = 0; i < runden; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> tippe(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first);
  await warte(tester);
}

Future<void> tippeText(WidgetTester tester, String text) => tippe(tester, find.text(text));

Future<void> eingeben(WidgetTester tester, String label, String wert) async {
  final f = find.widgetWithText(TextField, label);
  expect(f, findsOneWidget, reason: 'Feld "$label"');
  await tester.ensureVisible(f);
  await tester.enterText(f, wert);
  await tester.pump();
}

/// Alle antippbaren Elemente unter 44 px (sichtbare Tipp-Fläche).
List<String> kleineZiele(WidgetTester tester) {
  final zu = <String>[];
  void pruefe(Element element, String name) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    var sichtbar = true;
    element.visitAncestorElements((a) {
      if (a.widget is Offstage && (a.widget as Offstage).offstage) sichtbar = false;
      if (a.widget is Visibility && !(a.widget as Visibility).visible) sichtbar = false;
      return sichtbar;
    });
    if (!sichtbar) return;
    final s = box.size;
    if (s.height < minZiel - 0.01 || s.width < minZiel - 0.01) zu.add('$name ${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)}');
  }

  bool hatVorfahr(Element e, bool Function(Widget) test) {
    var gefunden = false;
    e.visitAncestorElements((a) {
      if (test(a.widget)) gefunden = true;
      return !gefunden;
    });
    return gefunden;
  }

  for (final typ in <Type>[IconButton, TextButton, FilledButton, OutlinedButton, FloatingActionButton, ChoiceChip, Checkbox, Switch]) {
    for (final element in find.byType(typ).evaluate()) {
      // Checkbox/Switch stecken in ListTiles mit ≥ 48 px; ihre Tipp-Fläche ist die ganze Zeile
      if ((typ == Checkbox || typ == Switch) && hatVorfahr(element, (w) => w is ListTile || w is SwitchListTile || w is CheckboxListTile)) continue;
      pruefe(element, typ.toString());
    }
  }
  for (final typ in <Type>[InkWell, InkResponse]) {
    for (final element in find.byType(typ).evaluate()) {
      final w = element.widget;
      final onTap = w is InkWell ? w.onTap : (w as InkResponse).onTap;
      if (onTap == null ||
          hatVorfahr(
            element,
            (a) => a is ButtonStyleButton || a is IconButton || a is NavigationBar || a is RawChip || a is Chip || a is PopupMenuButton || a is ListTile || a is PopupMenuItem,
          )) {
        continue;
      }
      pruefe(element, typ.toString());
    }
  }
  return zu;
}

/// Prüft den aktuellen Bildschirm: keine Layout-Ausnahmen und keine zu kleinen Ziele.
void pruefeLayout(WidgetTester tester, String wo) {
  expect(tester.takeException(), isNull, reason: wo);
  expect(kleineZiele(tester), isEmpty, reason: '$wo: Touch-Ziele unter $minZiel px');
}

/// Server und Umgebung eines angemeldeten Nutzers (App-Modus).
Future<TestUmgebung> angemeldeteUmgebung({String role = 'admin', FakeServer? server}) async {
  final env = TestUmgebung(server ?? standardServer(role: role));
  await env.angemeldet();
  return env;
}
