// Dateiablage, Oberfläche (Paket D4), Teil 3: Datei-Detail (Angaben, Öffnen von Bildern, Speichern auf Android über den Systemdialog, Offline-Schalter nur Android mit belegter Größe, Fassungen, neue Fassung,
// Umbenennen, Verschieben, Freigabe, endgültiges Löschen, Datenschutz-Hinweis), Rollen (Elternteil/Admin, Kind: nur Familie, ändert nur Eigenes), Desktop im Inhalts-Navigator, Startseite (Kachel "Zuletzt
// geteilt", Schnellaktionen) und der Durchgang für die Bedienhilfe. Layout bei 360 px und Textskala 1.0/1.5/2.0 mit Prüfung der Touch-Ziele.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/dateien/datei_waehler.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';

import 'support/datei_ui_welt.dart';
import 'support/harness.dart';

const _hoch = Size(360, 2600);

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

  Future<(DateiUi, ProviderContainer)> start(
    WidgetTester tester, {
    String rolle = 'admin',
    double skala = 1.0,
    Size groesse = _hoch,
    bool android = false,
    Future<void> Function(DateiUi d)? daten,
    bool oeffnen = true,
  }) async {
    final d = DateiUi.neu(rolle: rolle, android: android);
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

  Future<void> eingabe(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
  }

  Future<DateiZeile?> dateiZeile(DateiUi d, String id) => (d.db.select(d.db.dateien)..where((x) => x.id.equals(id))).getSingleOrNull();

  Future<void> anleitung(DateiUi d) async {
    await d.ordner('o-schule', 'Schule');
    await d.ordner('o-eltern', 'Verträge', audience: 'parents');
    await d.datei('d1', 'Anleitung.pdf', mime: 'application/pdf', groesse: 5000);
  }

  Future<void> dateiOeffnen(WidgetTester tester, String name) => tippe(tester, find.text(name));

  /// Lässt die Uhr des Tests in kleinen Schritten laufen, bis [fertig] gilt (höchstens [max] Schritte): Hinweise verschwinden nach einigen Sekunden, darum nicht länger warten als nötig.
  Future<void> bis(WidgetTester tester, bool Function() fertig, {int max = 120}) async {
    for (var i = 0; i < max && !fertig(); i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('Datei-Detail', () {
    fuerSkalen('Angaben, Aktionen, Datenschutz-Hinweis; Layout und Touch-Ziele', (tester, skala) async {
      await start(tester, skala: skala, daten: anleitung);
      await dateiOeffnen(tester, 'Anleitung.pdf');
      expect(find.text('Anleitung.pdf'), findsWidgets);
      expect(find.text('// DATEI'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);
      expect(find.text('4,9 KB'), findsOneWidget);
      expect(find.text('Oberste Ebene'), findsOneWidget);
      expect(find.text('Speichern'), findsOneWidget);
      expect(find.text('Öffnen'), findsNothing, reason: 'Öffnen in der App gibt es nur für Bilder');
      for (final t in ['Umbenennen', 'Verschieben', 'Neue Fassung hochladen', 'Datei endgültig löschen']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('// FREIGABE'), findsOneWidget);
      expect(find.textContaining('Fassung 1 · aktuell'), findsOneWidget);
      expect(find.textContaining('Vorschaubilder enthalten keinen Standort'), findsOneWidget);
      expect(find.textContaining('nie per Link nach außen'), findsOneWidget);
      // ohne Android kein Offline-Schalter
      expect(find.text('Offline verfügbar'), findsNothing);
      pruefeLayout(tester, 'Datei');
    });

    testWidgets('Umbenennen und Verschieben schreiben lokal; ein ungültiger Name wird erklärt', (tester) async {
      final (d, _) = await start(tester, daten: anleitung);
      await dateiOeffnen(tester, 'Anleitung.pdf');
      await tippe(tester, find.text('Umbenennen'));
      await eingabe(tester, 'x/y');
      await tippe(tester, find.text('Umbenennen').last);
      expect(find.textContaining('Dieser Name ist nicht möglich'), findsOneWidget);
      await eingabe(tester, 'Handbuch.pdf');
      await tippe(tester, find.text('Umbenennen').last);
      expect((await dateiZeile(d, 'd1'))!.name, 'Handbuch.pdf');
      expect(find.text('Handbuch.pdf'), findsWidgets);
      await tippe(tester, find.text('Verschieben'));
      await tippe(tester, find.text('Schule'));
      expect((await dateiZeile(d, 'd1'))!.ordnerId, 'o-schule');
      expect(find.text('Schule'), findsOneWidget, reason: 'neuer Ordnerpfad in den Angaben');
    });

    testWidgets('Freigabe ändern (Eltern): "Nur Eltern" gilt sofort; zurück auf "Familie" geht, solange der Ordner offen ist', (tester) async {
      final (d, _) = await start(tester, daten: anleitung);
      await dateiOeffnen(tester, 'Anleitung.pdf');
      await tippe(tester, find.widgetWithText(InkWell, 'Nur Eltern'));
      expect((await dateiZeile(d, 'd1'))!.audience, 'parents');
      await tippe(tester, find.widgetWithText(InkWell, 'Familie'));
      expect((await dateiZeile(d, 'd1'))!.audience, 'family');
    });

    testWidgets('Löschen: Bestätigung sagt ehrlich "endgültig" und "keinen Papierkorb"; Abbrechen löscht nichts, Bestätigen schließt die Seite', (tester) async {
      final (d, _) = await start(tester, daten: (d) async {
        await anleitung(d);
        await d.datei('d2', 'Mehrere Fassungen.txt', fassungen: 3);
      });
      await dateiOeffnen(tester, 'Mehrere Fassungen.txt');
      await tippe(tester, find.text('Datei endgültig löschen'));
      expect(find.text('Datei endgültig löschen?'), findsOneWidget);
      expect(find.textContaining('allen 3 Fassungen'), findsOneWidget);
      expect(find.textContaining('Das lässt sich nicht rückgängig machen'), findsOneWidget);
      expect(find.textContaining('keinen Papierkorb'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(await dateiZeile(d, 'd2'), isNotNull);
      await tippe(tester, find.text('Datei endgültig löschen'));
      await tippe(tester, find.text('Endgültig löschen'));
      expect(await dateiZeile(d, 'd2'), isNull);
      expect(find.text('Mehrere Fassungen.txt'), findsNothing);
      expect(find.text('Anleitung.pdf'), findsOneWidget, reason: 'zurück in der Übersicht');
    });

    testWidgets('Fassungen: Liste mit aktueller Fassung; eine neue Fassung wird eingereiht (Art "fassung")', (tester) async {
      final (d, _) = await start(tester, daten: (d) async => d.datei('d3', 'Plan.txt', fassungen: 3, groesse: 1000));
      await dateiOeffnen(tester, 'Plan.txt');
      expect(find.text('Fassung 3 · aktuell'), findsOneWidget);
      expect(find.text('Fassung 2'), findsOneWidget);
      expect(find.text('Fassung 1'), findsOneWidget);
      expect(find.byTooltip('Fassung 2 speichern'), findsOneWidget);
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Plan.txt', 400)]);
      await tippe(tester, find.text('Neue Fassung hochladen'));
      expect(find.text('Die neue Fassung wird hochgeladen.'), findsOneWidget);
      final z = (await d.db.select(d.db.transfers).get()).single;
      expect(z.art, 'fassung');
      expect(z.dateiId, 'd3');
      // abgebrochene Auswahl: nichts passiert
      await tippe(tester, find.text('Neue Fassung hochladen'));
      expect(await d.db.select(d.db.transfers).get(), hasLength(1));
    });

    testWidgets('Bild: "Öffnen" zeigt die Bildansicht und lädt das Bild mit der Anmeldung; zu große Bilder bleiben beim Speichern', (tester) async {
      final (d, _) = await start(tester, daten: (d) async {
        await d.datei('b1', 'Strand.jpg', mime: 'image/jpeg', groesse: 2048);
        await d.datei('b2', 'Riesig.jpg', mime: 'image/jpeg', groesse: 30 * 1024 * 1024);
      });
      d.blob('b1-v1', Uint8List(2048), mime: 'image/jpeg');
      await dateiOeffnen(tester, 'Strand.jpg');
      expect(find.text('Öffnen'), findsOneWidget);
      await tippe(tester, find.text('Öffnen'));
      await warte(tester, 10);
      expect(d.env.server.anfragen('GET /files/blobs/b1-v1'), isNotEmpty);
      expect(find.byTooltip('Zurück'), findsOneWidget);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Zurück'));
      await dateiOeffnen(tester, 'Riesig.jpg');
      await tippe(tester, find.text('Öffnen'));
      expect(find.textContaining('zu groß für die Ansicht'), findsOneWidget);
      expect(d.env.server.anfragen('GET /files/blobs/b2-v1'), isEmpty);
    });
  });

  group('Android: Speichern und Offline', () {
    testWidgets('Speichern lädt in den Cache und übergibt die Bytes dem Systemdialog', (tester) async {
      final (d, _) = await start(tester, android: true, daten: anleitung);
      d.blob('d1-v1', Uint8List.fromList(List.filled(5000, 7)));
      await dateiOeffnen(tester, 'Anleitung.pdf');
      await tippe(tester, find.text('Speichern'));
      await bis(tester, () => d.gespeichert.isNotEmpty);
      expect(d.gespeichert, hasLength(1));
      expect(d.gespeichert.single.name, 'Anleitung.pdf');
      expect(d.gespeichert.single.laenge, 5000);
      expect(find.text('Gespeichert.'), findsOneWidget);
      expect(d.ort!.dateien.keys, contains('/cache/d1-v1'));
      // ein zweites Speichern kommt aus dem Cache, ohne neuen Abruf
      final abrufe = d.env.server.anfragen('GET /files/blobs/d1-v1').length;
      await tippe(tester, find.text('Speichern'));
      await warte(tester, 10);
      expect(d.gespeichert, hasLength(2));
      expect(d.env.server.anfragen('GET /files/blobs/d1-v1').length, abrufe);
    });

    testWidgets('Fehler beim Laden (Datei beim Server weg): feste Meldung, nichts gespeichert', (tester) async {
      final (d, _) = await start(tester, android: true, daten: anleitung);
      await dateiOeffnen(tester, 'Anleitung.pdf');
      await tippe(tester, find.text('Speichern'));
      await bis(tester, () => find.text('Die Datei gibt es nicht mehr.').evaluate().isNotEmpty);
      expect(d.gespeichert, isEmpty);
      expect(find.text('Die Datei gibt es nicht mehr.'), findsOneWidget);
    });

    testWidgets('Offline verfügbar: einschalten lädt und heftet an (mit belegter Größe), ausschalten entfernt die Kopie', (tester) async {
      final (d, _) = await start(tester, android: true, daten: anleitung);
      d.blob('d1-v1', Uint8List.fromList(List.filled(5000, 3)));
      await dateiOeffnen(tester, 'Anleitung.pdf');
      expect(find.text('Offline verfügbar'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tippe(tester, find.byType(Switch));
      await warte(tester, 40);
      final z = await d.db.select(d.db.dateiCache).getSingle();
      expect(z.blobId, 'd1-v1');
      expect(z.angeheftet, isTrue);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('Auf diesem Gerät: 4,9 KB'), findsOneWidget);
      await tippe(tester, find.byType(Switch));
      await warte(tester, 10);
      expect(await d.db.select(d.db.dateiCache).get(), isEmpty);
      expect(d.ort!.dateien.containsKey('/cache/d1-v1'), isFalse);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    fuerSkalen('Offline-Zeile: Layout und Touch-Ziele (Android)', (tester, skala) async {
      await start(tester, skala: skala, android: true, daten: anleitung);
      await dateiOeffnen(tester, 'Anleitung.pdf');
      expect(find.text('Offline verfügbar'), findsOneWidget);
      pruefeLayout(tester, 'Offline');
    });
  });

  group('Rollen', () {
    Future<void> gemischt(DateiUi d) async {
      await d.ordner('o-alle', 'Für alle', besitzer: DateiUi.anderer);
      await d.ordner('o-eltern', 'Nur für Eltern', audience: 'parents');
      await d.datei('d-fremd', 'Fremd.txt', besitzer: DateiUi.anderer);
      await d.datei('d-eigen', 'Eigen.txt', besitzer: DateiUi.ich);
      await d.datei('d-geheim', 'Geheim.pdf', audience: 'parents', mime: 'application/pdf');
    }

    testWidgets('Kind: sieht nur Einträge für die Familie, keine Stufen-Pillen, keine Eltern-Ordner und keine Eltern-Dateien', (tester) async {
      final (_, _) = await start(tester, rolle: 'child', daten: gemischt);
      expect(find.text('Für alle'), findsOneWidget);
      expect(find.text('Fremd.txt'), findsOneWidget);
      expect(find.text('Eigen.txt'), findsOneWidget);
      expect(find.text('Nur für Eltern'), findsNothing);
      expect(find.text('Geheim.pdf'), findsNothing);
      expect(find.text('Nur Eltern'), findsNothing);
      await tippe(tester, find.text('Zuletzt'));
      expect(find.text('Geheim.pdf'), findsNothing, reason: 'auch nicht in Filtern');
    });

    testWidgets('Kind: fremde Datei nur ansehen und speichern, eigene Datei ändern, aber nie die Freigabe', (tester) async {
      final (_, _) = await start(tester, rolle: 'child', daten: gemischt);
      await dateiOeffnen(tester, 'Fremd.txt');
      expect(find.text('Speichern'), findsOneWidget);
      for (final t in ['Umbenennen', 'Verschieben', 'Neue Fassung hochladen', 'Datei endgültig löschen']) {
        expect(find.text(t), findsNothing, reason: 'fremd: $t');
      }
      expect(find.text('// FREIGABE'), findsNothing);
      await tippe(tester, find.byTooltip('Zurück'));
      await dateiOeffnen(tester, 'Eigen.txt');
      for (final t in ['Umbenennen', 'Verschieben', 'Neue Fassung hochladen', 'Datei endgültig löschen']) {
        expect(find.text(t), findsOneWidget, reason: 'eigen: $t');
      }
      expect(find.text('// FREIGABE'), findsNothing, reason: 'die Stufe ändern nur Eltern');
    });

    testWidgets('Kind: Ordner eines anderen nur ansehen; eigene Ordner anlegen geht (immer für die Familie); Ordner mit Inhalt löschen nur Eltern', (tester) async {
      final (d, _) = await start(tester, rolle: 'child', daten: (d) async {
        await gemischt(d);
        await d.ordner('o-mein', 'Mein Ordner', besitzer: DateiUi.ich);
        await d.datei('d-im-ordner', 'Drin.txt', ordner: 'o-mein', besitzer: DateiUi.ich);
      });
      await tippe(tester, find.byTooltip('Ordner Für alle verwalten'));
      expect(find.text('Ordner umbenennen'), findsNothing);
      expect(find.text('Ordner löschen'), findsNothing);
      expect(find.text('Nur Eltern'), findsNothing, reason: 'keine Wahl der Freigabe');
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Ordner Mein Ordner verwalten'));
      expect(find.text('Ordner umbenennen'), findsOneWidget);
      await tippe(tester, find.text('Ordner löschen'));
      expect(find.textContaining('Einen Ordner mit Inhalt löschen nur Eltern'), findsOneWidget);
      expect((await d.db.select(d.db.ordner).get()).any((o) => o.id == 'o-mein'), isTrue);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Neuer Ordner'));
      await eingabe(tester, 'Kinderzimmer');
      await tippe(tester, find.text('Anlegen'));
      final neu = (await d.db.select(d.db.ordner).get()).firstWhere((o) => o.name == 'Kinderzimmer');
      expect(neu.audience, 'family');
    });

    testWidgets('Kind: Upload landet immer bei "Familie"', (tester) async {
      final (d, _) = await start(tester, rolle: 'child');
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Bild.png', 100)]);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      expect((await d.db.select(d.db.transfers).get()).single.audience, 'family');
    });

    testWidgets('Elternteil: sieht alles mit Stufen-Pillen und ändert alles; Admin ebenso', (tester) async {
      for (final rolle in ['parent', 'admin']) {
        final (_, _) = await start(tester, rolle: rolle, daten: gemischt);
        expect(find.text('Nur für Eltern'), findsOneWidget, reason: rolle);
        expect(find.text('Geheim.pdf'), findsOneWidget, reason: rolle);
        expect(find.text('Nur Eltern'), findsWidgets, reason: 'Pillen: $rolle');
        await dateiOeffnen(tester, 'Fremd.txt');
        for (final t in ['Umbenennen', 'Verschieben', 'Neue Fassung hochladen', 'Datei endgültig löschen']) {
          expect(find.text(t), findsOneWidget, reason: '$rolle: $t');
        }
        expect(find.text('// FREIGABE'), findsOneWidget);
        // für die nächste Rolle sauber neu starten
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('Desktop (Inhalts-Navigator)', () {
    for (final groesse in [const Size(1200, 800), const Size(900, 700)]) {
      testWidgets('${groesse.width.toInt()} px: Unterseiten laufen im Inhaltsbereich, Seitenleiste bleibt; "Hochladen" als Knopf statt FAB', (tester) async {
        final (d, _) = await start(tester, groesse: groesse, daten: (d) async {
          await anleitung(d);
          await d.datei('d9', 'Zeugnis.pdf', ordner: 'o-schule', mime: 'application/pdf');
        });
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Hochladen'), findsOneWidget);
        expect(find.text('lx-familyhub'), findsOneWidget);
        await tippe(tester, find.text('Schule'));
        expect(find.text('Zeugnis.pdf'), findsOneWidget);
        await tippe(tester, find.text('Zeugnis.pdf'));
        expect(find.text('// DATEI'), findsOneWidget);
        expect(find.text('lx-familyhub'), findsOneWidget, reason: 'die Seitenleiste bleibt');
        await tippe(tester, find.byTooltip('Zurück'));
        expect(find.text('Zeugnis.pdf'), findsOneWidget, reason: 'zurück im Ordner');
        d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Neu.txt', 10)]);
        await tippe(tester, find.widgetWithText(FilledButton, 'Hochladen'));
        await tippe(tester, find.text('Dateien wählen'));
        expect((await d.db.select(d.db.transfers).get()).single.ordnerId, 'o-schule');
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Startseite', () {
    testWidgets('Desktop-Kachel "Zuletzt geteilt": die letzten Dateien, Tippen öffnet den Bereich', (tester) async {
      final (_, c) = await start(tester, groesse: const Size(1440, 900), oeffnen: false, daten: (d) async {
        await d.datei('a', 'Alt.txt', zeit: DateTime.utc(2026, 1, 1));
        await d.datei('b', 'Neu.txt', zeit: DateTime.utc(2026, 5, 1));
      });
      expect(find.text('// ZULETZT GETEILT'), findsOneWidget);
      expect(find.text('Neu.txt'), findsOneWidget);
      expect(find.text('Alt.txt'), findsOneWidget);
      await tippe(tester, find.text('// ZULETZT GETEILT'));
      expect(c.read(shellTabProvider), kDateienTab);
    });

    testWidgets('Desktop-Kachel ohne Dateien: ruhiger Leerzustand', (tester) async {
      final (_, _) = await start(tester, groesse: const Size(1440, 900), oeffnen: false);
      expect(find.text('// ZULETZT GETEILT'), findsOneWidget);
      expect(find.text('Noch keine Dateien'), findsOneWidget);
    });

    testWidgets('mobile Schnellaktionen "Datei" und "Foto" öffnen die Dateiauswahl (mit Dateiablage)', (tester) async {
      final (d, _) = await start(tester, groesse: const Size(360, 900), oeffnen: false);
      await tippe(tester, find.text('Datei'));
      await tippe(tester, find.text('Foto'));
      expect(d.auswahlAnfragen, [false, true]);
    });

    testWidgets('ohne Dateiablage bleibt es beim bisherigen Hinweis, keine Auswahl', (tester) async {
      final d = DateiUi.neu(dateiablage: false);
      await d.start(tester, groesse: const Size(360, 900));
      await tippe(tester, find.text('Datei'));
      expect(find.text('Kommt in Phase 1'), findsOneWidget);
      expect(d.auswahlAnfragen, isEmpty);
    });
  });

  group('Bedienhilfe', () {
    testWidgets('Übersicht: Zeilen, Knöpfe und Kontingent haben sprechende Beschriftungen und Tooltips', (tester) async {
      final handle = tester.ensureSemantics();
      final (_, _) = await start(tester, groesse: const Size(360, 900), daten: (d) async {
        await d.ordner('o1', 'Urlaub 2026');
        await d.datei('d1', 'Anleitung.pdf', mime: 'application/pdf', groesse: 1500000);
      });
      final s = alleSemantik(tester);
      for (final erwartet in [
        'Speicher der Familie: 5 GB von 10 GB belegt',
        'Ordner Urlaub 2026, Familie. Öffnen',
        'Anleitung.pdf, 1,4 MB',
        'Ordner Urlaub 2026 verwalten',
        'Übertragungen',
        'Hochladen',
        'Sortieren, jetzt: Name',
        'Aktueller Ordner: Dateien',
      ]) {
        expect(s, contains(erwartet), reason: erwartet);
      }
      handle.dispose();
    });

    testWidgets('Datei-Detail und Ordnerseite: Chips, Fassungen und Hinweise sind benannt', (tester) async {
      final handle = tester.ensureSemantics();
      final (_, _) = await start(tester, daten: (d) async {
        await d.ordner('o1', 'Urlaub 2026');
        await d.datei('d1', 'Plan.txt', fassungen: 2);
      });
      await tippe(tester, find.text('Plan.txt'));
      final s = alleSemantik(tester);
      for (final erwartet in ['Fassung 2, aktuell', 'Fassung 1', 'Fassung 1 speichern', 'Datenschutz', 'Typ: Text', 'Größe: ', 'Familie', 'Nur Eltern']) {
        expect(s, contains(erwartet), reason: erwartet);
      }
      handle.dispose();
    });
  });
}
