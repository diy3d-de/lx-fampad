// Kalender-Umbau: schlanke Leiste, Filterblatt, Monatsraster mit Balken (mehrtägig über Wochenränder, "+n", heute), Tagesblatt, Tagespanel
// im Desktop-Layout, einklappende Kopfzeile; dazu die reine Belegung der Spuren (monat_layout.dart). 360 px bei Textskala 1.0 und 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/calendar/feiertage.dart' show geburtstageAnzeigenProvider;
import 'package:lx_fampad/data/calendar/monat_layout.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/ics_import_screen.dart';
import 'package:lx_fampad/features/calendar/kalender_monat.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/widgets/kopfzeile.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

String _id(int n) => 'aaaaaaaa-0000-4000-8000-${n.toString().padLeft(12, '0')}';

DateTime _d(int j, int m, int t) => DateTime.utc(j, m, t);

Map<String, dynamic> _ganztaegig(String titel, DateTime von, DateTime bisInklusive, {String owner = fixIdAdmin, String? rrule}) => {
  'titel': titel,
  'ganztaegig': true,
  'startDate': tagText(von),
  'endDate': tagText(bisInklusive.add(const Duration(days: 1))),
  'rrule': ?rrule,
  'ownerId': owner,
  'audience': 'family',
};

Map<String, dynamic> _zeit(String titel, DateTime tag, int stunde) => {
  'titel': titel,
  'ganztaegig': false,
  'startUtc': DateTime.utc(tag.year, tag.month, tag.day, stunde - 1).toIso8601String(), // Winterzeit (MEZ): UTC + 1
  'endUtc': DateTime.utc(tag.year, tag.month, tag.day, stunde).toIso8601String(),
  'tzid': 'Europe/Berlin',
  'ownerId': fixIdAdmin,
  'audience': 'family',
};

BalkenQuelle _q(String id, DateTime von, DateTime bis, {BalkenArt art = BalkenArt.termin, String sortierung = ''}) =>
    BalkenQuelle(id: id, text: id, farbe: kAccent, art: art, von: von, bis: bis, sortierung: sortierung);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  // ---------------------------------------------------------------------------------------------- Belegung der Spuren (reine Logik)

  group('wochenLayout', () {
    final montag = _d(2027, 3, 1); // Montag

    test('mehrtägiger Eintrag über den Wochenrand: in jeder Woche abgeschnitten, Rand "offen"', () {
      final q = _q('Ski', _d(2027, 3, 4), _d(2027, 3, 8)); // Do bis Mo
      final w1 = wochenLayout(montag: montag, quellen: [q], maxSpuren: 4);
      expect(w1.balken.single.start, 3);
      expect(w1.balken.single.ende, 6);
      expect(w1.balken.single.vorneOffen, isFalse);
      expect(w1.balken.single.hintenOffen, isTrue);
      final w2 = wochenLayout(montag: _d(2027, 3, 8), quellen: [q], maxSpuren: 4);
      expect(w2.balken.single.start, 0);
      expect(w2.balken.single.ende, 0);
      expect(w2.balken.single.vorneOffen, isTrue);
      expect(w2.balken.single.hintenOffen, isFalse);
      expect(wochenLayout(montag: _d(2027, 3, 15), quellen: [q], maxSpuren: 4).balken, isEmpty);
    });

    test('Längere zuerst (oben), Ferien vor Feiertagen vor Terminen bei gleicher Länge; gleiche Spur nur bei freien Spalten', () {
      final ferien = _q('Ferien', _d(2027, 3, 1), _d(2027, 3, 7), art: BalkenArt.ferien);
      final urlaub = _q('Urlaub', _d(2027, 3, 1), _d(2027, 3, 3));
      final a = _q('A', _d(2027, 3, 1), _d(2027, 3, 1));
      final b = _q('B', _d(2027, 3, 5), _d(2027, 3, 5));
      final feier = _q('Feier', _d(2027, 3, 1), _d(2027, 3, 1), art: BalkenArt.feiertag);
      final l = wochenLayout(montag: montag, quellen: [a, b, feier, urlaub, ferien], maxSpuren: 6);
      int spur(String id) => l.balken.firstWhere((x) => x.quelle.id == id).spur;
      expect(spur('Ferien'), 0);
      expect(spur('Urlaub'), 1);
      expect(spur('Feier'), 2, reason: 'Feiertag vor dem Termin am selben Tag');
      expect(spur('A'), 3);
      expect(spur('B'), 1, reason: 'Freitag ist in Spur 1 frei (Urlaub endet am Mittwoch)');
      expect(l.hatMehr, isFalse);
    });

    test('Überlauf: die letzte Spur zeigt "+n" je Tag, verdeckte Einträge werden gezählt', () {
      final tag = _d(2027, 3, 3);
      final qs = [for (var i = 1; i <= 6; i++) _q('E$i', tag, tag, sortierung: '$i')];
      final l = wochenLayout(montag: montag, quellen: qs, maxSpuren: 4);
      expect(l.spuren, 3, reason: 'drei Spuren Balken, die vierte gehört dem "+n"');
      expect(l.balken.map((b) => b.quelle.id), ['E1', 'E2', 'E3']);
      expect(l.mehr[2], 3);
      expect(l.mehr.where((n) => n > 0), hasLength(1));
      // passt alles genau in die Spuren: kein "+n"
      expect(wochenLayout(montag: montag, quellen: qs, maxSpuren: 6).hatMehr, isFalse);
      // nur eine Spur: gar kein Balken, alles als "+n"
      final eins = wochenLayout(montag: montag, quellen: qs, maxSpuren: 1);
      expect(eins.balken, isEmpty);
      expect(eins.mehr[2], 6);
    });

    test('Kalenderwoche (ISO) und Wochen des Monats', () {
      expect(kalenderwoche(_d(2026, 10, 21)), 43);
      expect(kalenderwoche(_d(2027, 1, 1)), 53, reason: '1.1.2027 gehört zur KW 53 von 2026');
      expect(kalenderwoche(_d(2026, 12, 31)), 53);
      expect(kalenderwoche(_d(2025, 12, 29)), 1);
      expect(wochenDesMonats(_d(2027, 3, 1)).length, 5);
      expect(wochenDesMonats(_d(2027, 3, 1)).first, _d(2027, 3, 1));
      expect(wochenDesMonats(_d(2026, 10, 1)).length, 5);
      expect(wochenDesMonats(_d(2026, 8, 1)).length, 6, reason: 'August 2026: Samstag bis Montag');
      expect(wochenDesMonats(_d(2027, 2, 1)).length, 4, reason: 'Februar 2027 beginnt am Montag und hat 28 Tage');
    });
  });

  // ---------------------------------------------------------------------------------------------- Oberfläche

  Future<(TestUmgebung, ProviderContainer)> start(
    WidgetTester tester, {
    String role = 'admin',
    void Function(TestUmgebung env)? vorher,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    DateTime? monat,
    bool monatsansicht = true,
  }) async {
    final env = await angemeldeteUmgebung(role: role);
    vorher?.call(env);
    final container = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width >= kDesktopBreakpoint) {
      container.read(shellTabProvider.notifier).waehlen(kTabs.indexWhere((t) => t.label == 'Kalender'));
    } else {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
    }
    await warte(tester);
    if (monatsansicht) container.read(kalenderAuswahlProvider.notifier).ansicht(KalenderAnsicht.monat);
    if (monat != null) container.read(kalenderAuswahlProvider.notifier).tag(monat);
    await warte(tester);
    return (env, container);
  }

  Finder tagZelle(DateTime tag) => find.byKey(ValueKey('kalender-tag-${tagText(tag)}'));

  for (final skala in [1.0, 1.5]) {
    testWidgets('Leiste (360 px, Textskala $skala): Monat, Pfeile, Heute, Filter, Mehr; Umschalter; Raster füllt den Platz ohne Scrollen der Seite', (tester) async {
      final (_, container) = await start(tester, skala: skala, monat: _d(2027, 3, 10));
      expect(find.text('März 2027'), findsOneWidget);
      expect(find.text('${heuteTag().day}'), findsWidgets, reason: 'Heute-Knopf zeigt den Tag');
      expect(find.byTooltip('Vorheriger Monat'), findsOneWidget);
      expect(find.byTooltip('Mehr: Importieren, Exportieren'), findsOneWidget);
      await tippe(tester, find.byTooltip('Nächster Monat'));
      expect(find.text('April 2027'), findsOneWidget);
      await tippe(tester, find.byTooltip('Heute'));
      expect(container.read(kalenderAuswahlProvider).tag, heuteTag());
      // das Raster beginnt direkt unter Leiste und Umschalter und reicht bis zur Navigation (kein Scrollen der Seite, kein Überlauf)
      final raster = tester.getRect(find.byType(MonatsRaster));
      final nav = tester.getRect(find.byType(NavigationBar));
      expect(raster.bottom, lessThanOrEqualTo(nav.top + 0.5));
      expect(raster.bottom, greaterThan(nav.top - 20), reason: 'füllt den verbleibenden Platz');
      expect(raster.top, lessThan(skala == 1.0 ? 260 : 340), reason: 'beginnt weit oben');
      pruefeLayout(tester, 'Leiste');
    });
  }

  testWidgets('Monat wählen: Tipp auf den Titel öffnet die Datumswahl, die Wahl springt in den Monat', (tester) async {
    await start(tester, monat: _d(2027, 3, 10));
    await tippe(tester, find.bySemanticsLabel(RegExp('^Monat wählen')));
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tippe(tester, find.descendant(of: find.byType(DatePickerDialog), matching: find.text('20')));
    await tippeText(tester, 'OK');
    expect(find.text('März 2027'), findsOneWidget);
  });

  testWidgets('Mehr-Menü: Importieren (nur wer anlegen darf) und Exportieren', (tester) async {
    await start(tester);
    await tippe(tester, find.byTooltip('Mehr: Importieren, Exportieren'));
    expect(find.text('Importieren'), findsOneWidget);
    expect(find.text('Kalender exportieren'), findsOneWidget);
    await tippeText(tester, 'Importieren');
    expect(find.byType(IcsImportScreen), findsOneWidget);
  });

  testWidgets('Filterblatt: Schalter Geburtstage blendet Geburtstage in der Agenda aus, Zähler zählt aktive Filter, "Zurücksetzen"', (tester) async {
    final heute = heuteTag();
    await start(
      tester,
      monatsansicht: false,
      vorher: (e) => e.sync.andereAendert('termin', _id(1), _ganztaegig('Geburtstag Opa', DateTime.utc(2000, heute.month, heute.day), DateTime.utc(2000, heute.month, heute.day), rrule: 'FREQ=YEARLY')),
    );
    expect(find.text('Geburtstag Opa'), findsOneWidget);
    await tippe(tester, filterKnopf);
    expect(find.text('Filter und Anzeige'), findsOneWidget);
    expect(find.text('Feiertage'), findsOneWidget);
    expect(find.text('Schulferien'), findsOneWidget);
    await tippe(tester, find.text('Geburtstage'));
    await tippeText(tester, 'Fertig');
    expect(find.text('Geburtstag Opa'), findsNothing);
    expect(find.byTooltip('Filter und Anzeige, 3 aktiv'), findsOneWidget, reason: 'Geburtstage, Feiertage (im Test aus) und Ferien (im Test aus)');
    await tippe(tester, filterKnopf);
    await tippeText(tester, 'Zurücksetzen');
    await tippeText(tester, 'Fertig');
    expect(find.text('Geburtstag Opa'), findsOneWidget);
    expect(find.byTooltip('Filter und Anzeige'), findsOneWidget);
    pruefeLayout(tester, 'Filterblatt');
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Raster (360 px, Textskala $skala): mehrtägiger Balken läuft über den Wochenrand, heute ist markiert, Wochenenden abgesetzt, KW links', (tester) async {
      await start(
        tester,
        skala: skala,
        monat: _d(2027, 3, 10),
        vorher: (e) {
          e.sync.andereAendert('termin', _id(1), _ganztaegig('Skiurlaub', _d(2027, 3, 4), _d(2027, 3, 8))); // Do bis Mo, über den Wochenrand
          e.sync.andereAendert('termin', _id(2), _zeit('Zahnarzt', _d(2027, 3, 16), 10));
        },
      );
      final ski = find.text('Skiurlaub');
      expect(ski, findsNWidgets(2), reason: 'ein Balken je Woche');
      final r1 = tester.getRect(ski.first);
      final r2 = tester.getRect(ski.last);
      expect(r1.top, lessThan(r2.top), reason: 'erste Woche oben');
      expect(r2.left, lessThan(r1.left), reason: 'in der zweiten Woche am Wochenanfang, in der ersten am Donnerstag');
      expect(find.text('Zahnarzt'), findsOneWidget);
      // Kalenderwochen links (KW 9 bis 13 im März 2027)
      for (final kw in ['9', '10', '11', '12', '13']) {
        expect(find.text(kw), findsWidgets);
      }
      pruefeLayout(tester, 'Raster');
    });
  }

  testWidgets('heute: die Zelle ist als "heute" beschriftet (Semantics je Tag mit Terminen)', (tester) async {
    final heute = heuteTag();
    final handle = tester.ensureSemantics();
    await start(tester, vorher: (e) => e.sync.andereAendert('termin', _id(1), _ganztaegig('Heute frei', heute, heute)));
    final label = tester.getSemantics(tagZelle(heute)).label;
    expect(label, contains('heute'));
    expect(label, contains('1 Termin: Heute frei'));
    final anderer = heute.day == 15 ? 16 : 15;
    expect(tester.getSemantics(tagZelle(_d(heute.year, heute.month, anderer))).label, isNot(contains('heute')));
    handle.dispose();
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Überlauf (360 px, Textskala $skala): Balken nach Höhe, der Rest als "+n"; nie ein Überlauf-Fehler', (tester) async {
      await start(
        tester,
        skala: skala,
        monat: _d(2027, 3, 10),
        vorher: (e) {
          for (var i = 1; i <= 8; i++) {
            e.sync.andereAendert('termin', _id(i), _zeit('Ev$i', _d(2027, 3, 10), 8 + i));
          }
        },
      );
      final sichtbar = [for (var i = 1; i <= 8; i++) if (find.text('Ev$i').evaluate().isNotEmpty) i];
      expect(sichtbar.length, inInclusiveRange(1, 5), reason: 'nicht alle 8 passen in eine Zeile');
      expect(sichtbar, [for (var i = 1; i <= sichtbar.length; i++) i], reason: 'die frühesten zuerst');
      expect(find.text('+${8 - sichtbar.length}'), findsOneWidget);
      if (skala > 1.0) {
        // größere Schrift: weniger Balken je Zeile
        expect(sichtbar.length, lessThanOrEqualTo(3));
      }
      pruefeLayout(tester, 'Überlauf');
    });
  }

  testWidgets('Tagesblatt: Tipp auf den Tag, Termine mit Zeit und Farbe, "+ Termin" legt für den Tag an, Tipp auf Termin = Detailblatt', (tester) async {
    await start(
      tester,
      monat: _d(2027, 3, 10),
      vorher: (e) {
        e.sync.andereAendert('termin', _id(1), _ganztaegig('Kita-Fest', _d(2027, 3, 10), _d(2027, 3, 10)));
        e.sync.andereAendert('termin', _id(2), _zeit('Schwimmen', _d(2027, 3, 10), 16));
      },
    );
    await tippe(tester, tagZelle(_d(2027, 3, 10)));
    expect(find.text('Mittwoch, 10. März'), findsOneWidget);
    expect(find.text('ganztägig'), findsOneWidget);
    expect(find.text('16:00'), findsOneWidget);
    expect(find.text('Termin'), findsOneWidget);
    pruefeLayout(tester, 'Tagesblatt');
    await tippe(tester, find.text('Schwimmen').last);
    expect(find.text('Bearbeiten'), findsOneWidget, reason: 'vorhandenes Detailblatt');
    await tester.tapAt(const Offset(10, 10));
    await warte(tester);
    await tippe(tester, tagZelle(_d(2027, 3, 12)));
    expect(find.text('Keine Termine – frei!'), findsOneWidget);
    await tippeText(tester, 'Termin');
    expect(find.text('Neuer Termin'), findsWidgets, reason: 'Editor');
  });

  testWidgets('Kopfzeile klappt im Raster ein (Tipp auf einen Tag) und kommt beim Herunterziehen wieder', (tester) async {
    final (_, container) = await start(tester, monat: _d(2027, 3, 10));
    expect(find.byType(TabKopfzeile), findsOneWidget);
    final oben = tester.getRect(find.byType(MonatsRaster)).top;
    await tippe(tester, tagZelle(_d(2027, 3, 10)));
    await tester.tapAt(const Offset(10, 10)); // Tagesblatt schließen
    await warte(tester);
    expect(container.read(kalenderKopfEingeklapptProvider), isTrue);
    expect(find.byType(TabKopfzeile), findsNothing);
    expect(tester.getRect(find.byType(MonatsRaster)).top, lessThan(oben), reason: 'das Raster rückt nach oben');
    pruefeLayout(tester, 'eingeklappt');
    await tester.drag(find.byType(MonatsRaster), const Offset(0, 300));
    await warte(tester);
    expect(find.byType(TabKopfzeile), findsOneWidget);
  });

  testWidgets('Kopfzeile in der Agenda: beim Scrollen nach unten eingeklappt, beim Zurückscrollen wieder da; Umschalten blendet sie ein', (tester) async {
    final (_, container) = await start(
      tester,
      monatsansicht: false,
      vorher: (e) {
        final heute = heuteTag();
        for (var i = 0; i < 30; i++) {
          e.sync.andereAendert('termin', _id(i + 1), _ganztaegig('Tag $i', heute.add(Duration(days: i)), heute.add(Duration(days: i))));
        }
      },
    );
    expect(find.byType(TabKopfzeile), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await warte(tester);
    expect(find.byType(TabKopfzeile), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await warte(tester);
    expect(find.byType(TabKopfzeile), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await warte(tester);
    expect(find.byType(TabKopfzeile), findsNothing);
    container.read(kalenderKopfEingeklapptProvider.notifier).setzen(false);
    await tippeText(tester, 'Woche');
    expect(find.byType(TabKopfzeile), findsOneWidget);
  });

  testWidgets('Rechte: Kinder sehen den runden Knopf und "Importieren" nicht anders als zuvor (anlegen erlaubt), "+ Termin" im Blatt vorhanden', (tester) async {
    await start(tester, role: 'child', monat: _d(2027, 3, 10));
    expect(find.byTooltip('Neuer Termin'), findsOneWidget);
    await tippe(tester, tagZelle(_d(2027, 3, 10)));
    expect(find.text('Termin'), findsOneWidget);
  });

  for (final breite in [1440.0, 1000.0]) {
    testWidgets('Desktop ($breite px): Leiste in einer Zeile mit Personenchips, Anzeige-Menü, Import/Export und "Neuer Termin"; ${breite >= 1440 ? 'Tagespanel statt Sheet' : 'schmal: Tagesblatt'}', (tester) async {
      await start(
        tester,
        groesse: Size(breite, 900),
        monat: _d(2027, 3, 10),
        vorher: (e) {
          e.sync.andereAendert('termin', _id(1), _zeit('Schwimmen', _d(2027, 3, 10), 16));
          e.sync.andereAendert('termin', _id(2), _zeit('Elternabend', _d(2027, 3, 12), 19));
        },
      );
      expect(find.text('März 2027'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Neuer Termin'), findsOneWidget);
      expect(find.text('Anzeige'), findsOneWidget);
      expect(find.text('Importieren / Exportieren'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Schwimmen 16:00'), findsOneWidget, reason: 'Desktop: Zeit im Balken');
      if (breite >= 1440) {
        // Panel zeigt den gewählten Tag (heute bzw. der per Provider gewählte 10.3.), ein Tipp auf einen anderen Tag wechselt ohne Sheet
        expect(find.text('Mittwoch, 10. März'), findsOneWidget);
        expect(find.text('Termin an diesem Tag'), findsOneWidget);
        await tippe(tester, tagZelle(_d(2027, 3, 12)));
        expect(find.text('Freitag, 12. März'), findsOneWidget);
        expect(find.text('Mittwoch, 10. März'), findsNothing);
        expect(find.text('19:00'), findsOneWidget, reason: 'Termin des Tages im Panel');
        await tippe(tester, find.text('Elternabend').last);
        expect(find.text('Bearbeiten'), findsOneWidget);
      } else {
        expect(find.text('Termin an diesem Tag'), findsNothing);
        await tippe(tester, tagZelle(_d(2027, 3, 12)));
        expect(find.text('Freitag, 12. März'), findsOneWidget, reason: 'Tagesblatt');
      }
      pruefeLayout(tester, 'Desktop');
    });
  }

  testWidgets('Desktop: Anzeige-Menü schaltet Geburtstage um', (tester) async {
    final (_, container) = await start(tester, groesse: const Size(1440, 900));
    expect(container.read(geburtstageAnzeigenProvider), isTrue);
    await tippeText(tester, 'Anzeige');
    await tippeText(tester, 'Geburtstage');
    expect(container.read(geburtstageAnzeigenProvider), isFalse);
  });
}

/// Knopf "Filter und Anzeige" der Leiste (die Beschriftung nennt die Zahl aktiver Filter).
final filterKnopf = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Filter und Anzeige'));
