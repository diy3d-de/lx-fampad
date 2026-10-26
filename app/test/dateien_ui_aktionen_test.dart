// Dateiablage, Oberfläche (Paket D4), Teil 2: Ordner (Anlegen, Umbenennen, Verschieben mit Zyklus-/Tiefenprüfung, Löschen leer und mit Inhalt), Freigabe mit der blockierten Änderung, Hochladen
// (Vorabprüfung, Fotos, Namensgleichheit, Abbruch), Liste der Übertragungen, Datei-Detail (Speichern, Offline nur Android, Fassungen, Umbenennen, Verschieben, Freigabe, Löschen), Rollen (Eltern/Admin, Kind),
// Desktop (Inhalts-Navigator) und die Startseite. Layout bei 360 px und Textskala 1.0/1.5/2.0 mit Prüfung der Touch-Ziele.
import 'package:drift/drift.dart' show Value;
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

const _hoch = Size(360, 2400); // hoch genug, dass die ganze Seite gebaut ist (ListView baut nur Sichtbares)

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

  Future<void> standard(DateiUi d) async {
    await d.ordner('o-urlaub', 'Urlaub 2026');
    await d.ordner('o-italien', 'Italien', parent: 'o-urlaub');
    await d.ordner('o-vertraege', 'Verträge', audience: 'parents');
    await d.ordner('o-miete', 'Miete', parent: 'o-vertraege', audience: 'parents');
    await d.datei('d-foto', 'Strand.jpg', ordner: 'o-urlaub', mime: 'image/jpeg', groesse: 3400000);
    await d.datei('d-anleitung', 'Anleitung.pdf', mime: 'application/pdf', groesse: 1500000);
    await d.datei('d-vertrag', 'Mietvertrag.pdf', ordner: 'o-miete', audience: 'parents', mime: 'application/pdf', groesse: 900000);
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

  Future<OrdnerZeile?> ordnerZeile(DateiUi d, String id) => (d.db.select(d.db.ordner)..where((o) => o.id.equals(id))).getSingleOrNull();
  Future<DateiZeile?> dateiZeile(DateiUi d, String id) => (d.db.select(d.db.dateien)..where((x) => x.id.equals(id))).getSingleOrNull();

  Future<void> inOrdner(WidgetTester tester, String name) async {
    await tippe(tester, find.text(name));
  }

  Future<void> ordnerVerwalten(WidgetTester tester, String name) async {
    await tippe(tester, find.byTooltip('Ordner $name verwalten'));
  }

  group('Ordner', () {
    testWidgets('Neuer Ordner über "Hochladen": Name eingeben, anlegen; die Familie ist die Stufe', (tester) async {
      final (d, _) = await start(tester);
      await tippe(tester, find.text('Hochladen'));
      expect(find.text('Dateien wählen'), findsOneWidget);
      expect(find.text('Fotos wählen'), findsOneWidget);
      await tippe(tester, find.text('Neuer Ordner'));
      await eingabe(tester, 'Schule');
      await tippe(tester, find.text('Anlegen'));
      expect(find.text('Schule'), findsOneWidget);
      final o = (await d.db.select(d.db.ordner).get()).single;
      expect(o.name, 'Schule');
      expect(o.audience, 'family');
      expect(o.parentId, isNull);
      expect(o.ownerId, DateiUi.ich);
    });

    testWidgets('ein ungültiger Name wird im Dialog erklärt und nie geschrieben', (tester) async {
      final (d, _) = await start(tester);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Neuer Ordner'));
      await eingabe(tester, 'a/b');
      await tippe(tester, find.text('Anlegen'));
      expect(find.textContaining('Dieser Name ist nicht möglich'), findsOneWidget);
      expect(await d.db.select(d.db.ordner).get(), isEmpty);
      await tippe(tester, find.text('Abbrechen'));
      expect(find.textContaining('Dieser Name ist nicht möglich'), findsNothing);
    });

    testWidgets('Neuer Ordner in einem Ordner nur für Eltern erbt die Stufe', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await inOrdner(tester, 'Verträge');
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Neuer Ordner'));
      await eingabe(tester, 'Versicherung');
      await tippe(tester, find.text('Anlegen'));
      final o = (await d.db.select(d.db.ordner).get()).firstWhere((x) => x.name == 'Versicherung');
      expect(o.audience, 'parents');
      expect(o.parentId, 'o-vertraege');
    });

    fuerSkalen('Ordnerseite: Freigabe, Größe, Unterordner, Aktionen; Layout und Touch-Ziele', (tester, skala) async {
      await start(tester, skala: skala, daten: standard);
      await ordnerVerwalten(tester, 'Urlaub 2026');
      expect(find.text('Urlaub 2026'), findsWidgets);
      expect(labelFinder('Freigabe'), findsOneWidget);
      expect(find.text('Familie'), findsWidgets);
      expect(find.text('Nur Eltern'), findsOneWidget);
      expect(find.textContaining('3,2 MB'), findsOneWidget, reason: 'Größe der Dateien im Ordner');
      expect(find.text('Italien'), findsOneWidget);
      expect(find.textContaining('nicht offener sein als der Ordner'), findsOneWidget);
      for (final t in ['Ordner umbenennen', 'Ordner verschieben', 'Ordner löschen']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      pruefeLayout(tester, 'Ordnerseite');
    });

    testWidgets('Umbenennen: der neue Name steht überall, ein ungültiger wird abgelehnt', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await ordnerVerwalten(tester, 'Urlaub 2026');
      await tippe(tester, find.text('Ordner umbenennen'));
      expect(find.widgetWithText(TextField, 'Urlaub 2026'), findsOneWidget);
      await eingabe(tester, 'Sommer');
      await tippe(tester, find.text('Umbenennen'));
      expect(find.text('Sommer'), findsWidgets);
      expect((await ordnerZeile(d, 'o-urlaub'))!.name, 'Sommer');
      await tippe(tester, find.text('Ordner umbenennen'));
      await eingabe(tester, '..');
      await tippe(tester, find.text('Umbenennen'));
      expect(find.textContaining('Dieser Name ist nicht möglich'), findsOneWidget);
      expect((await ordnerZeile(d, 'o-urlaub'))!.name, 'Sommer');
    });

    testWidgets('Verschieben: die Ordnerwahl sperrt Unterordner (Zyklus) und Ordner nur für Eltern mit Grund', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await ordnerVerwalten(tester, 'Urlaub 2026');
      await tippe(tester, find.text('Ordner verschieben'));
      expect(find.text('Oberste Ebene'), findsOneWidget);
      expect(find.text('Urlaub 2026'), findsWidgets);
      expect(find.text('Nicht in sich selbst oder einen Unterordner.'), findsOneWidget, reason: 'Italien liegt darunter');
      expect(find.textContaining('Dieser Ordner ist nur für Eltern'), findsWidgets, reason: 'Verträge und Miete');
      // ein gesperrter Eintrag lässt sich nicht antippen
      await tester.tap(find.text('Verträge').last, warnIfMissed: false);
      await warte(tester);
      expect((await ordnerZeile(d, 'o-urlaub'))!.parentId, isNull);
      // ein erlaubtes Ziel: nach Italien geht nicht (Zyklus), "Oberste Ebene" ist gleich dem jetzigen Ort: nichts ändert sich
      await tippe(tester, find.text('Oberste Ebene'));
      expect((await ordnerZeile(d, 'o-urlaub'))!.parentId, isNull);
    });

    testWidgets('Verschieben in einen anderen Ordner schreibt den neuen Elternordner', (tester) async {
      final (d, _) = await start(tester, daten: (d) async {
        await standard(d);
        await d.ordner('o-schule', 'Schule');
      });
      await inOrdner(tester, 'Urlaub 2026');
      await ordnerVerwalten(tester, 'Italien');
      await tippe(tester, find.text('Ordner verschieben'));
      await tippe(tester, find.text('Schule'));
      expect((await ordnerZeile(d, 'o-italien'))!.parentId, 'o-schule');
    });

    testWidgets('Verschieben: zu tiefe Ziele sind gesperrt (höchstens 6 Ebenen)', (tester) async {
      final (_, _) = await start(tester, daten: (d) async {
        String? p;
        for (var i = 1; i <= 5; i++) {
          await d.ordner('e$i', 'Ebene $i', parent: p);
          p = 'e$i';
        }
        await d.ordner('x', 'Mit Kind');
        await d.ordner('y', 'Kind', parent: 'x');
      });
      await ordnerVerwalten(tester, 'Mit Kind');
      await tippe(tester, find.text('Ordner verschieben'));
      expect(find.text('So tief lassen sich Ordner nicht schachteln.'), findsWidgets);
    });

    testWidgets('Leeren Ordner löschen: Bestätigung, danach ist er weg und die Seite schließt', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await inOrdner(tester, 'Urlaub 2026');
      await ordnerVerwalten(tester, 'Italien');
      await tippe(tester, find.text('Ordner löschen'));
      expect(find.text('Ordner löschen?'), findsOneWidget);
      expect(find.textContaining('leere Ordner'), findsOneWidget);
      await tippe(tester, find.text('Löschen'));
      expect(await ordnerZeile(d, 'o-italien'), isNull);
    });

    testWidgets('Ordner mit Inhalt löschen: Anzahl in der Bestätigung, alles darunter geht von unten nach oben', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await ordnerVerwalten(tester, 'Urlaub 2026');
      await tippe(tester, find.text('Ordner löschen'));
      expect(find.text('Ordner mit Inhalt löschen?'), findsOneWidget);
      expect(find.textContaining('1 Datei und 1 Unterordner'), findsOneWidget);
      expect(find.textContaining('keinen Papierkorb'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(await ordnerZeile(d, 'o-urlaub'), isNotNull, reason: 'abgebrochen');
      await tippe(tester, find.text('Ordner löschen'));
      await tippe(tester, find.text('Mit Inhalt löschen'));
      expect(await ordnerZeile(d, 'o-urlaub'), isNull);
      expect(await ordnerZeile(d, 'o-italien'), isNull);
      expect(await dateiZeile(d, 'd-foto'), isNull);
      expect(await dateiZeile(d, 'd-anleitung'), isNotNull, reason: 'andere Dateien bleiben');
    });
  });

  group('Freigabe', () {
    testWidgets('"Nur Eltern": Bestätigung nennt die Zahl, danach gilt es für alles darunter (Dateien und Unterordner)', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await ordnerVerwalten(tester, 'Urlaub 2026');
      await tippe(tester, find.text('Nur Eltern'));
      expect(find.text('Nur für Eltern?'), findsOneWidget);
      expect(find.textContaining('2 Einträge darunter'), findsOneWidget);
      expect(find.textContaining('Kinder sehen sie nicht mehr'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect((await ordnerZeile(d, 'o-urlaub'))!.audience, 'family');
      await tippe(tester, find.text('Nur Eltern'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Nur Eltern')));
      expect((await ordnerZeile(d, 'o-urlaub'))!.audience, 'parents');
      expect((await ordnerZeile(d, 'o-italien'))!.audience, 'parents');
      expect((await dateiZeile(d, 'd-foto'))!.audience, 'parents');
      expect((await dateiZeile(d, 'd-anleitung'))!.audience, 'family', reason: 'liegt woanders');
      expect(labelFinder('Ordner · nur Eltern'), findsOneWidget);
    });

    testWidgets('blockierte Änderung: ein Unterordner kann nicht offener sein als sein Ordner; die Meldung erklärt es und bietet an, die übergeordneten Ordner mitzuändern', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await inOrdner(tester, 'Verträge');
      await ordnerVerwalten(tester, 'Miete');
      await tippe(tester, find.text('Familie').last);
      expect(find.text('Erst die übergeordneten Ordner freigeben?'), findsOneWidget);
      expect(find.textContaining('Für alle sichtbare Einträge liegen nur in Ordnern'), findsOneWidget);
      expect(find.textContaining('„Verträge“'), findsOneWidget);
      // Abbrechen ändert nichts
      await tippe(tester, find.text('Abbrechen'));
      expect((await ordnerZeile(d, 'o-miete'))!.audience, 'parents');
      expect((await ordnerZeile(d, 'o-vertraege'))!.audience, 'parents');
      await tippe(tester, find.text('Familie').last);
      await tippe(tester, find.text('Auch freigeben'));
      expect((await ordnerZeile(d, 'o-vertraege'))!.audience, 'family');
      expect((await ordnerZeile(d, 'o-miete'))!.audience, 'family');
      expect((await dateiZeile(d, 'd-vertrag'))!.audience, 'parents', reason: 'die Datei behält ihre Freigabe');
    });

    testWidgets('Datei nur für Eltern in einem Ordner nur für Eltern: "Familie" wird erklärt, nichts ändert sich', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await inOrdner(tester, 'Verträge');
      await inOrdner(tester, 'Miete');
      await inOrdner(tester, 'Mietvertrag.pdf');
      await tippe(tester, find.text('Familie').last);
      expect(find.textContaining('Verschiebe die Datei zuerst in einen Ordner für alle'), findsOneWidget);
      expect((await dateiZeile(d, 'd-vertrag'))!.audience, 'parents');
    });
  });

  group('Hochladen', () {
    testWidgets('Dateien wählen: wird eingereiht, Hinweis mit Weg zur Liste, Datei erscheint nach dem Upload', (tester) async {
      final (d, _) = await start(tester);
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Zeugnis.pdf', 1200)]);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      expect(d.auswahlAnfragen, [false]);
      expect(find.text('Eine Datei wird hochgeladen.'), findsOneWidget);
      expect(find.text('Anzeigen'), findsOneWidget);
      final z = await d.db.select(d.db.transfers).get();
      expect(z, hasLength(1));
      expect(z.single.name, 'Zeugnis.pdf');
      expect(z.single.art, 'datei');
      expect(z.single.audience, 'family');
      await warte(tester, 30);
      expect(find.text('Zeugnis.pdf'), findsOneWidget, reason: 'nach dem Upload liegt die Datei im Ordner');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Fotos wählen fragt den Picker nur nach Bildern', (tester) async {
      final (d, _) = await start(tester);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Fotos wählen'));
      expect(d.auswahlAnfragen, [true]);
      expect(await d.db.select(d.db.transfers).get(), isEmpty, reason: 'abgebrochen');
      expect(find.textContaining('hochgeladen'), findsNothing);
    });

    testWidgets('mehrere Dateien: gleiche Namen im Ordner bekommen eine Nummer', (tester) async {
      final (d, _) = await start(tester, daten: (d) async => d.datei('d1', 'Foto.jpg', mime: 'image/jpeg'));
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Foto.jpg', 100), d.gewaehlt('Foto.jpg', 200), d.gewaehlt('Neu.txt', 300)]);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      expect(find.text('3 Dateien werden hochgeladen.'), findsOneWidget);
      final namen = [for (final z in await d.db.select(d.db.transfers).get()) z.name]..sort();
      expect(namen, ['Foto (2).jpg', 'Foto (3).jpg', 'Neu.txt']);
    });

    testWidgets('im Ordner hochladen: Ziel und Stufe kommen vom Ordner (Eltern-Ordner = Nur Eltern)', (tester) async {
      final (d, _) = await start(tester, daten: standard);
      await inOrdner(tester, 'Verträge');
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Police.pdf', 500)]);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      final z = (await d.db.select(d.db.transfers).get()).single;
      expect(z.ordnerId, 'o-vertraege');
      expect(z.audience, 'parents');
    });

    testWidgets('zu groß: klare Meldung vorab, kein Upload', (tester) async {
      final (d, _) = await start(tester, maxDatei: 1000);
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Riesig.bin', 2000)]);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      expect(find.text('Die Datei ist größer als erlaubt.'), findsOneWidget);
      expect(await d.db.select(d.db.transfers).get(), isEmpty);
    });

    testWidgets('Kontingent reicht nicht: "Der Speicher der Familie ist voll."', (tester) async {
      final (d, _) = await start(tester, kontingent: 10000, belegt: 9500);
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Gross.bin', 1000)]);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      expect(find.text('Der Speicher der Familie ist voll.'), findsOneWidget);
      expect(await d.db.select(d.db.transfers).get(), isEmpty);
    });

    testWidgets('leere Datei und nicht lesbare Datei werden erklärt; die gültigen gehen trotzdem', (tester) async {
      final (d, _) = await start(tester);
      d.naechsteAuswahl = DateiAuswahl([d.gewaehlt('Leer.txt', 0), d.gewaehlt('Gut.txt', 50)], 2);
      await tippe(tester, find.text('Hochladen'));
      await tippe(tester, find.text('Dateien wählen'));
      expect(find.textContaining('Eine Datei wird hochgeladen.'), findsOneWidget);
      expect(find.textContaining('Die Datei ist leer.'), findsOneWidget);
      expect(find.textContaining('2 Dateien ließen sich nicht öffnen.'), findsOneWidget);
      expect((await d.db.select(d.db.transfers).get()).map((z) => z.name), ['Gut.txt']);
    });
  });

  group('Übertragungen', () {
    Future<void> zeilen(DateiUi d) async {
      final jetzt = DateTime.utc(2026, 3, 5, 12);
      Future<void> z(String id, String zustand, String name, {String art = 'datei', int groesse = 1000, int uebertragen = 0, String? fehler}) => d.db.into(d.db.transfers).insert(
        TransfersCompanion.insert(
          id: id,
          richtung: art == 'runter' ? 'runter' : 'Hoch',
          art: art,
          zustand: zustand,
          name: name,
          groesse: Value(groesse),
          uebertragen: Value(uebertragen),
          fehlerCode: Value(fehler),
          createdAt: jetzt.add(Duration(minutes: id.length)),
          aktualisiertAt: jetzt,
        ),
      );
      await z('l', 'laeuft', 'Urlaub.mp4', groesse: 2000, uebertragen: 900);
      await z('ff', 'fehler', 'Voll.zip', fehler: 'quota_exceeded');
      await z('fff', 'fertig', 'Fertig.pdf');
      await z('ffff', 'datei_noetig', 'Neu waehlen.jpg');
      await z('fffff', 'abgebrochen', 'Weg.txt');
      await z('x', 'laeuft', 'Geheimer Anhang.pdf', art: 'anhang');
    }

    fuerSkalen('Liste: Fortschritt, Fehler mit festem Text, Aktionen; Tresor-Anhänge fehlen; Layout und Touch-Ziele', (tester, skala) async {
      final (_, _) = await start(tester, skala: skala, daten: zeilen);
      await tippe(tester, find.byTooltip('Übertragungen'));
      expect(labelFinder('Dateien'), findsOneWidget);
      expect(find.text('Urlaub.mp4'), findsOneWidget);
      expect(find.text('Lädt hoch · 45 %'), findsOneWidget);
      expect(find.text('Der Speicher der Familie ist voll.'), findsOneWidget);
      expect(find.text('Bitte wähle die Datei noch einmal.'), findsOneWidget);
      expect(find.text('Abgebrochen'), findsOneWidget);
      expect(find.text('Fertig'), findsOneWidget);
      expect(find.text('Geheimer Anhang.pdf'), findsNothing, reason: 'Tresor-Anhänge stehen nur im Tresor');
      expect(find.textContaining('Setzt sich fort'), findsOneWidget);
      pruefeLayout(tester, 'Übertragungen');
    });

    testWidgets('Abbrechen, Wiederholen, Entfernen und "Erledigte entfernen" wirken auf die Zeilen', (tester) async {
      final (d, _) = await start(tester, daten: zeilen);
      await tippe(tester, find.byTooltip('Übertragungen'));
      expect(find.text('Abbrechen'), findsOneWidget);
      expect(find.text('Wiederholen'), findsWidgets);
      expect(find.text('Datei wählen'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      final laeuft = await (d.db.select(d.db.transfers)..where((t) => t.id.equals('l'))).getSingle();
      expect(laeuft.zustand, 'abgebrochen');
      await tippe(tester, find.text('Erledigte entfernen'));
      final rest = [for (final t in await d.db.select(d.db.transfers).get()) t.id]..sort();
      expect(rest, ['ff', 'ffff', 'x'], reason: 'fertige und abgebrochene sind weg, Fehler und Anhang bleiben');
      expect(find.text('Fertig'), findsNothing);
      // Entfernen einer Fehlerzeile
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen').first);
      expect((await d.db.select(d.db.transfers).get()).length, lessThan(3));
    });

    testWidgets('Fortschritt steht NUR in der Liste: auf der Übersicht nur ein Hinweis mit Zahl, die Kopfzeile bleibt unverändert', (tester) async {
      final (_, _) = await start(tester, daten: zeilen);
      expect(find.textContaining('Übertragung läuft'), findsOneWidget);
      expect(find.textContaining('brauchen dich'), findsOneWidget);
      // der einzige Balken der Übersicht ist das Kontingent
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('45 %'), findsNothing);
      await tippe(tester, find.textContaining('Übertragung läuft'));
      expect(find.text('Lädt hoch · 45 %'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
    });

    testWidgets('ohne Übertragungen: ruhiger Hinweis', (tester) async {
      final (_, _) = await start(tester);
      await tippe(tester, find.byTooltip('Übertragungen'));
      expect(find.textContaining('Keine Übertragungen'), findsOneWidget);
      expect(find.text('Erledigte entfernen'), findsNothing);
    });
  });
}

