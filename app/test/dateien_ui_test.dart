// Dateiablage, Oberfläche (Paket D4): Sichtbarkeit nach `features.files` (Menüpunkt "Dateien" hinter "Mehr" nach Tresor, Seitenleiste, kein Deep-Link ohne Server-Unterstützung), Übersicht mit Brotkrumen,
// Kontingent, Filtern und Sortierung, Ordner (Anlegen, Umbenennen, Verschieben, Löschen), Freigabe mit der blockierten Änderung, Hochladen mit Vorabprüfung und Übertragungsliste, Datei-Detail mit
// Speichern, Offline-Schalter (nur Android), Fassungen und Löschen; Rollen (Eltern/Admin, Kind) und Layout bei 360 px und Textskala 1.0/1.5/2.0 mit Prüfung der Touch-Ziele. Daten liegen in der
// lokalen Datenbank (schon bestätigt), Uploads und Downloads laufen gegen den Fake-Server der Dateiablage.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';

import 'support/datei_ui_welt.dart';
import 'support/harness.dart';

/// Alles, was die Bedienhilfe zu sehen bekommt (Beschriftung, Wert, Hinweis, Tooltip) als ein Text.
String alleSemantik(WidgetTester tester) {
  final b = StringBuffer();
  void gehe(SemanticsNode n) {
    final d = n.getSemanticsData();
    b..writeln(d.label)..writeln(d.value)..writeln(d.hint)..writeln(d.tooltip);
    n.visitChildren((c) {
      gehe(c);
      return true;
    });
  }

  gehe(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return b.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  /// Startet die App und öffnet "Dateien" (mobil über "Mehr", Desktop über die Seitenleiste).
  Future<(DateiUi, ProviderContainer)> start(
    WidgetTester tester, {
    String rolle = 'admin',
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    bool android = false,
    int belegt = 5368709120,
    int maxDatei = 104857600,
    int kontingent = 10737418240,
    Future<void> Function(DateiUi d)? daten,
    bool oeffnen = true,
  }) async {
    final d = DateiUi.neu(rolle: rolle, android: android, belegt: belegt, maxDatei: maxDatei, kontingent: kontingent);
    final c = await d.start(tester, skala: skala, groesse: groesse);
    if (daten != null) {
      await daten(d);
      await warte(tester);
    }
    if (oeffnen) {
      if (groesse.width >= kDesktopBreakpoint) {
        c.read(shellTabProvider.notifier).waehlen(kDateienTab);
        await warte(tester);
      } else {
        await zumBereich(tester, 'Dateien');
      }
    }
    return (d, c);
  }

  void fuerSkalen(String name, Future<void> Function(WidgetTester tester, double skala) body) {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('$name (Textskala $skala)', (tester) => body(tester, skala));
    }
  }

  Future<void> daten(DateiUi d) async {
    await d.ordner('o-urlaub', 'Urlaub 2026');
    await d.ordner('o-vertraege', 'Verträge und Versicherungen', audience: 'parents');
    await d.ordner('o-italien', 'Italien', parent: 'o-urlaub');
    await d.datei('d-anleitung', 'Anleitung Waschmaschine.pdf', mime: 'application/pdf', groesse: 1500000);
    await d.datei('d-foto', 'Strand.jpg', ordner: 'o-urlaub', mime: 'image/jpeg', groesse: 3400000, besitzer: DateiUi.anderer);
    await d.datei('d-vertrag', 'Mietvertrag.pdf', ordner: 'o-vertraege', audience: 'parents', mime: 'application/pdf', groesse: 900000);
  }

  group('Sichtbarkeit nach features.files', () {
    testWidgets('mit Dateiablage: "Dateien" steht im Blatt "Mehr" in der Gruppe Ablage vor dem Tresor und öffnet den Bereich', (tester) async {
      final (_, _) = await start(tester, oeffnen: false);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      final blatt = find.byType(BottomSheet);
      final tresor = tester.getTopLeft(find.descendant(of: blatt, matching: find.text('Tresor')));
      final dateien = tester.getTopLeft(find.descendant(of: blatt, matching: find.text('Dateien')));
      final muell = find.descendant(of: blatt, matching: find.text('Müll'));
      expect(dateien.dy < tresor.dy || dateien.dx < tresor.dx, isTrue, reason: 'Ablage: Dateien vor Tresor');
      if (muell.evaluate().isNotEmpty) expect(tester.getTopLeft(muell).dy <= dateien.dy, isTrue, reason: 'Zuhause steht vor Ablage');
      await tester.tap(find.descendant(of: blatt, matching: find.text('Dateien')));
      await warte(tester);
      expect(labelFinder('Familie'), findsOneWidget);
      expect(find.text('Noch keine Dateien'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ohne features.files: kein Menüpunkt, kein Tab; ein Deep-Link auf den Bereich landet auf der Startseite', (tester) async {
      final d = DateiUi.neu(dateiablage: false);
      final c = await d.start(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Dateien')), findsNothing);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Tresor')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await warte(tester);
      c.read(shellTabProvider.notifier).waehlen(kDateienTab);
      await warte(tester);
      expect(labelFinder('Familie'), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('Desktop ohne features.files: Seitenleiste ohne "Dateien", der Tab springt zurück zur Startseite', (tester) async {
      final handle = tester.ensureSemantics();
      final d = DateiUi.neu(dateiablage: false);
      final c = await d.start(tester, groesse: const Size(1200, 800));
      expect(find.bySemanticsLabel('Dateien'), findsNothing);
      c.read(shellTabProvider.notifier).waehlen(kDateienTab);
      await warte(tester);
      expect(c.read(shellTabProvider), 0);
      expect(find.text('Noch keine Dateien'), findsNothing);
      handle.dispose();
    });

    testWidgets('Desktop mit Dateiablage: "Dateien" in der Seitenleiste, der Bereich ist Teil der Shell (Seitenleiste bleibt)', (tester) async {
      final handle = tester.ensureSemantics();
      final (_, c) = await start(tester, groesse: const Size(1200, 800), oeffnen: false);
      expect(find.bySemanticsLabel('Dateien'), findsOneWidget);
      await tippe(tester, find.bySemanticsLabel('Dateien'));
      expect(c.read(shellTabProvider), kDateienTab);
      expect(find.text('Noch keine Dateien'), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.byTooltip('Zurück'), findsNothing);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });

  group('Übersicht', () {
    fuerSkalen('Ordner und Dateien der obersten Ebene, Kontingent, Filter; Layout und Touch-Ziele', (tester, skala) async {
      final (_, _) = await start(tester, skala: skala, daten: daten);
      expect(find.text('Urlaub 2026'), findsOneWidget);
      expect(find.text('Verträge und Versicherungen'), findsOneWidget);
      expect(find.text('Anleitung Waschmaschine.pdf'), findsOneWidget);
      // Dateien in Unterordnern stehen nicht oben
      expect(find.text('Strand.jpg'), findsNothing);
      expect(find.text('5 GB von 10 GB belegt'), findsOneWidget);
      for (final f in ['Alle', 'Zuletzt', 'Von mir']) {
        expect(find.text(f), findsOneWidget, reason: f);
      }
      // Offline gibt es nur auf Android
      expect(find.text('Offline'), findsNothing);
      pruefeLayout(tester, 'Übersicht');
    });

    testWidgets('Brotkrumen: in Ordner hinein, über die Brotkrume zurück; die Dateien des Ordners stehen dort', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester, daten: daten);
      await tippe(tester, find.text('Urlaub 2026'));
      expect(find.text('Strand.jpg'), findsOneWidget);
      expect(find.text('Italien'), findsOneWidget);
      expect(find.text('Anleitung Waschmaschine.pdf'), findsNothing);
      await tippe(tester, find.text('Italien'));
      expect(find.text('Dieser Ordner ist leer'), findsOneWidget);
      // Brotkrume: Dateien › Urlaub 2026 › Italien
      expect(find.bySemanticsLabel('Aktueller Ordner: Italien'), findsOneWidget);
      await tippe(tester, find.bySemanticsLabel('Zu Urlaub 2026'));
      expect(find.text('Strand.jpg'), findsOneWidget);
      await tippe(tester, find.bySemanticsLabel('Zu Dateien'));
      expect(find.text('Anleitung Waschmaschine.pdf'), findsOneWidget);
      pruefeLayout(tester, 'Brotkrumen');
      handle.dispose();
    });

    testWidgets('System-Zurück geht erst einen Ordner nach oben und verlässt erst dann den Bereich', (tester) async {
      await start(tester, daten: daten);
      await tippe(tester, find.text('Urlaub 2026'));
      await tippe(tester, find.text('Italien'));
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.text('Strand.jpg'), findsOneWidget, reason: 'Urlaub 2026');
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.text('Anleitung Waschmaschine.pdf'), findsOneWidget, reason: 'oberste Ebene');
      expect(find.byType(NavigationBar), findsNothing);
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('leerer Zustand: ruhig, mit Hinweis "Noch keine Dateien" und Kontingent', (tester) async {
      await start(tester);
      expect(find.text('Noch keine Dateien'), findsOneWidget);
      expect(find.text('Lade etwas hoch oder lege einen Ordner an.'), findsOneWidget);
      expect(find.text('5 GB von 10 GB belegt'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.text('Hochladen'), findsOneWidget);
      pruefeLayout(tester, 'leer');
    });

    testWidgets('Filter "Zuletzt": neueste zuerst, mit Pfad; "Von mir": nur eigene Dateien', (tester) async {
      await start(tester, daten: (d) async {
        await daten(d);
        await d.datei('d-neu', 'Zuletzt.txt', zeit: DateTime.utc(2026, 6, 1, 9, 0), besitzer: DateiUi.ich);
      });
      await tippe(tester, find.text('Zuletzt'));
      final y = {for (final n in ['Zuletzt.txt', 'Anleitung Waschmaschine.pdf']) n: tester.getTopLeft(find.text(n)).dy};
      expect(y['Zuletzt.txt']! < y['Anleitung Waschmaschine.pdf']!, isTrue);
      expect(find.text('Strand.jpg'), findsOneWidget, reason: 'aus Unterordnern');
      expect(find.textContaining('Urlaub 2026'), findsWidgets);
      await tippe(tester, find.text('Von mir'));
      expect(find.text('Strand.jpg'), findsNothing, reason: 'gehört einer anderen Person');
      expect(find.text('Zuletzt.txt'), findsOneWidget);
      await tippe(tester, find.text('Alle'));
      expect(find.text('Urlaub 2026'), findsOneWidget);
    });

    testWidgets('Sortierung: nach Name, Größe und zuletzt geändert', (tester) async {
      await start(tester, daten: (d) async {
        await d.datei('a', 'Alpha.txt', groesse: 100, zeit: DateTime.utc(2026, 1, 1));
        await d.datei('b', 'Beta.txt', groesse: 900, zeit: DateTime.utc(2026, 5, 1));
        await d.datei('c', 'Gamma.txt', groesse: 500, zeit: DateTime.utc(2026, 3, 1));
      });
      double y(String n) => tester.getTopLeft(find.text(n)).dy;
      expect(y('Alpha.txt') < y('Beta.txt') && y('Beta.txt') < y('Gamma.txt'), isTrue);
      Future<void> sortiere(String wie) async {
        await tippe(tester, find.byIcon(Icons.sort));
        await tippe(tester, find.text(wie).last);
      }

      await sortiere('Größe');
      expect(y('Beta.txt') < y('Gamma.txt') && y('Gamma.txt') < y('Alpha.txt'), isTrue, reason: 'größte zuerst');
      await sortiere('Zuletzt geändert');
      expect(y('Beta.txt') < y('Gamma.txt') && y('Gamma.txt') < y('Alpha.txt'), isTrue, reason: 'neueste zuerst');
    });

    testWidgets('Kontingent: ab 90 Prozent knapp, bei 100 Prozent voll (Text, nicht nur Farbe)', (tester) async {
      final (_, _) = await start(tester, belegt: 9663676416); // 9 GB von 10 GB
      expect(find.text('9 GB von 10 GB belegt'), findsOneWidget);
      expect(find.text('Der Speicher wird knapp.'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.color, kWarn);
      expect(bar.value, closeTo(0.9, 0.001));
    });

    testWidgets('Kontingent voll: roter Balken und ein klarer Satz', (tester) async {
      final (_, _) = await start(tester, belegt: 10737418240);
      expect(find.textContaining('Der Speicher ist voll.'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).color, kDanger);
    });

    testWidgets('Kontingent mit den Grenzen des Servers (kleines Kontingent)', (tester) async {
      final (_, _) = await start(tester, kontingent: 2147483648, belegt: 1073741824);
      expect(find.text('1 GB von 2 GB belegt'), findsOneWidget);
    });
  });

  group('Offline-Filter (nur Android)', () {
    testWidgets('Android: Filter "Offline" zeigt Dateien mit Kopie auf diesem Gerät', (tester) async {
      final (d, _) = await start(tester, android: true, daten: (d) async {
        await daten(d);
        await d.datei('d-offline', 'Offline.txt');
        await d.db.into(d.db.dateiCache).insert(DateiCacheCompanion.insert(blobId: 'd-offline-v1', groesse: 2048, name: 'Offline.txt', zuletztGenutzt: DateTime.utc(2026, 3, 3)));
      });
      expect(find.text('Offline'), findsOneWidget);
      await tippe(tester, find.text('Offline'));
      expect(find.text('Offline.txt'), findsOneWidget);
      expect(find.text('Anleitung Waschmaschine.pdf'), findsNothing);
      expect(d.ort, isNotNull);
    });

    testWidgets('Android ohne Offline-Dateien: ruhiger Hinweis', (tester) async {
      await start(tester, android: true, daten: daten);
      await tippe(tester, find.text('Offline'));
      expect(find.text('Keine Offline-Dateien'), findsOneWidget);
    });
  });
}
