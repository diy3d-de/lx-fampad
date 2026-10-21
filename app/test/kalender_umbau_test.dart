// Kalender-Umbau: schlanke Leiste, Filterblatt, Monatsraster mit Balken (mehrtägig über Wochenränder, "+n", heute), Tagesblatt, Tagespanel
// im Desktop-Layout, einklappende Kopfzeile; dazu die reine Belegung der Spuren (monat_layout.dart). 360 px bei Textskala 1.0 und 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/calendar/feiertage.dart' show TagesHinweis, TagesHinweisArt, ferienProvider, geburtstageAnzeigenProvider;
import 'package:lx_fampad/data/calendar/monat_layout.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/ics_import_screen.dart';
import 'package:lx_fampad/features/calendar/kalender_leiste.dart' show KalenderLeiste;
import 'package:lx_fampad/features/calendar/kalender_monat.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';
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

    test('Spuren aus der Zeilenhöhe; Ferien/Feiertage erst ab drei Spuren als Balken', () {
      expect(spurenFuerHoehe(94, 22, 16), 4);
      expect(spurenFuerHoehe(60, 30, 24), 1);
      expect(spurenFuerHoehe(20, 22, 16), lessThan(1));
      expect(hinweiseAlsBalken(2), isFalse);
      expect(hinweiseAlsBalken(3), isTrue);
      expect(hinweiseAlsBalken(0), isFalse);
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
      expect(raster.bottom, inInclusiveRange(nav.top - 90, nav.top - 60), reason: 'füllt den Platz bis auf die Reserve für den runden Knopf');
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

  testWidgets('Kind darf anlegen: runder Knopf und "+ Termin" im Tagesblatt sind da', (tester) async {
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

  Map<String, dynamic> zeitUtc(String titel, String startUtc, String endUtc, {String? rrule}) => {
    'titel': titel,
    'ganztaegig': false,
    'startUtc': startUtc,
    'endUtc': endUtc,
    'tzid': 'Europe/Berlin',
    'rrule': ?rrule,
    'ownerId': fixIdAdmin,
    'audience': 'family',
  };

  /// Beschriftung (Semantics) einer Tageszelle.
  String zellenLabel(WidgetTester tester, DateTime tag) => tester.getSemantics(tagZelle(tag)).label;

  testWidgets('Zeittermin über Mitternacht und Ende genau um 0 Uhr: Tage stimmen', (tester) async {
    final handle = tester.ensureSemantics();
    await start(
      tester,
      monat: _d(2027, 3, 10),
      vorher: (e) {
        e.sync.andereAendert('termin', _id(1), zeitUtc('Nachtwache', '2027-03-10T21:00:00.000Z', '2027-03-11T01:00:00.000Z')); // 22:00 bis 02:00 MEZ
        e.sync.andereAendert('termin', _id(2), zeitUtc('Bis Mitternacht', '2027-03-16T21:00:00.000Z', '2027-03-16T23:00:00.000Z')); // 22:00 bis 24:00 MEZ
      },
    );
    expect(zellenLabel(tester, _d(2027, 3, 10)), contains('Nachtwache'));
    expect(zellenLabel(tester, _d(2027, 3, 11)), contains('Nachtwache'));
    expect(zellenLabel(tester, _d(2027, 3, 12)), contains('keine Termine'));
    expect(zellenLabel(tester, _d(2027, 3, 16)), contains('Bis Mitternacht'));
    expect(zellenLabel(tester, _d(2027, 3, 17)), contains('keine Termine'), reason: 'Ende um 0 Uhr zählt nicht mehr zum Folgetag');
    handle.dispose();
  });

  testWidgets('Sommerzeitwechsel 28.3.2027: Termin über die Umstellung und Termin direkt danach liegen am richtigen Tag', (tester) async {
    final handle = tester.ensureSemantics();
    await start(
      tester,
      monat: _d(2027, 3, 10),
      vorher: (e) {
        e.sync.andereAendert('termin', _id(1), zeitUtc('Umstellung', '2027-03-27T22:30:00.000Z', '2027-03-28T00:30:00.000Z')); // 23:30 MEZ bis 02:30 MESZ
        e.sync.andereAendert('termin', _id(2), zeitUtc('Danach', '2027-03-28T01:30:00.000Z', '2027-03-28T02:30:00.000Z')); // 03:30 bis 04:30 MESZ
      },
    );
    expect(zellenLabel(tester, _d(2027, 3, 26)), contains('keine Termine'));
    expect(zellenLabel(tester, _d(2027, 3, 27)), contains('Umstellung'));
    expect(zellenLabel(tester, _d(2027, 3, 28)), allOf(contains('Umstellung'), contains('Danach'), contains('2 Termine')));
    expect(zellenLabel(tester, _d(2027, 3, 29)), contains('keine Termine'));
    handle.dispose();
  });

  testWidgets('Zeitumstellung 25.10.2026: Termin um 00:30 Sommerzeit gehört zum 25., nicht zum 24.', (tester) async {
    final handle = tester.ensureSemantics();
    await start(
      tester,
      monat: _d(2026, 10, 10),
      vorher: (e) => e.sync.andereAendert('termin', _id(1), zeitUtc('Mitternacht', '2026-10-24T22:30:00.000Z', '2026-10-24T23:30:00.000Z')),
    );
    expect(zellenLabel(tester, _d(2026, 10, 24)), contains('keine Termine'));
    expect(zellenLabel(tester, _d(2026, 10, 25)), contains('Mitternacht'));
    handle.dispose();
  });

  testWidgets('abgesagtes Vorkommen einer Serie fehlt im Raster, die übrigen stehen da', (tester) async {
    await start(
      tester,
      monat: _d(2027, 3, 10),
      vorher: (e) {
        e.sync.andereAendert('termin', _id(1), zeitUtc('Chor', '2027-03-03T17:00:00.000Z', '2027-03-03T18:00:00.000Z', rrule: 'FREQ=WEEKLY'));
        e.sync.andereAendert('termin_ausnahmen', 'cccccccc-1111-4111-8111-111111111111', {'terminId': _id(1), 'originalStart': '2027-03-10T17:00:00Z', 'abgesagt': true});
      },
    );
    expect(find.text('Chor'), findsNWidgets(4), reason: '3., 17., 24. und 31. März; der 10. ist abgesagt');
  });

  testWidgets('Ferien und Feiertage verdrängen auf kleinen Bildschirmen keine Termine: bei wenig Platz nur als Zellenfarbe', (tester) async {
    final handle = tester.ensureSemantics();
    Future<void> lauf(double skala, double hoehe) => start(
      tester,
      skala: skala,
      groesse: Size(360, hoehe),
      monat: _d(2026, 10, 10),
      vorher: (e) {
        e.feiertage = 'ja';
        // feste Ferien statt des Assets (dessen Laden im Test von echtem Datei-Zugriff abhängt)
        e.extraOverrides.add(ferienProvider.overrideWith((ref) async => [TagesHinweis(name: 'Herbstferien', art: TagesHinweisArt.ferien, von: _d(2026, 10, 5), bis: _d(2026, 10, 16))]));
        e.sync.andereAendert('termin', _id(1), zeitUtc('Zahnarzt', '2026-10-07T08:00:00.000Z', '2026-10-07T09:00:00.000Z'));
        e.sync.andereAendert('termin', _id(2), zeitUtc('Schwimmen', '2026-10-07T13:00:00.000Z', '2026-10-07T14:00:00.000Z'));
      },
    );
    await lauf(1.0, 1200); // deutlich genug Platz für drei Spuren
    expect(find.text('Herbstferien'), findsWidgets, reason: 'genug Platz: Balken');
    expect(find.text('Zahnarzt'), findsOneWidget);
    expect(find.text('Schwimmen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await lauf(1.5, 640); // deutlich zu wenig Platz für drei Spuren (die Entscheidung selbst: siehe Test der reinen Funktionen)
    expect(find.text('Herbstferien'), findsNothing, reason: 'wenig Spuren: keine Ferienbalken');
    expect(find.text('Zahnarzt'), findsOneWidget);
    expect(find.text('Schwimmen'), findsOneWidget);
    expect(zellenLabel(tester, _d(2026, 10, 7)), contains('Schulferien Herbstferien'));
    expect(zellenLabel(tester, _d(2026, 10, 3)), contains('Feiertag Tag der Deutschen Einheit'));
    pruefeLayout(tester, 'Ferienwoche');
    handle.dispose();
  });

  testWidgets('Textskala 2.0 bei 360 px: Monat, Filterblatt und Agenda ohne Layoutfehler', (tester) async {
    // Die (nicht für 2.0 ausgelegte, unveränderte) Startseite meldet beim Aufbau einen Überlauf: nur dieser bekannte Fall wird ausgenommen,
    // jeder andere Fehler (auch im Kalender) lässt den Test scheitern.
    final alt = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.toString().contains('RenderFlex overflowed') && d.toString().contains('home_screen.dart')) return;
      alt!(d);
    };
    try {
      await start(tester, skala: 2.0, monat: _d(2027, 3, 10), vorher: (e) => e.sync.andereAendert('termin', _id(1), zeitUtc('Zahnarzt', '2027-03-10T09:00:00.000Z', '2027-03-10T10:00:00.000Z')));
      pruefeLayout(tester, 'Monat 2.0');
      await tippe(tester, filterKnopf);
      pruefeLayout(tester, 'Filterblatt 2.0');
      await tippeText(tester, 'Fertig');
      await tippeText(tester, 'Agenda');
      pruefeLayout(tester, 'Agenda 2.0');
    } finally {
      FlutterError.onError = alt;
    }
  });

  testWidgets('Titel "September 2026" bleibt bei 360 px lesbar (mind. 14 px Schrift), auch eingeklappt; dort liegen Heute und Abgleich im Mehr-Menü', (tester) async {
    final (_, container) = await start(tester, monat: _d(2026, 9, 10));
    for (final eingeklappt in [false, true]) {
      container.read(kalenderKopfEingeklapptProvider.notifier).setzen(eingeklappt);
      await warte(tester);
      final titel = find.text('September 2026');
      expect(titel, findsOneWidget);
      final natuerlich = tester.getSize(titel).width; // Breite bei Schriftgröße 18 vor der Skalierung
      final sichtbar = tester.getBottomRight(titel).dx - tester.getTopLeft(titel).dx;
      expect(sichtbar, greaterThanOrEqualTo(115), reason: 'Titel mindestens ~120 px breit (eingeklappt=$eingeklappt)');
      expect(18 * sichtbar / natuerlich, greaterThanOrEqualTo(14), reason: 'tatsächliche Schriftgröße (eingeklappt=$eingeklappt)');
      expect(tester.getTopLeft(titel).dx, greaterThanOrEqualTo(tester.getBottomRight(find.byTooltip('Vorheriger Monat')).dx - 0.5));
      expect(tester.getBottomRight(titel).dx, lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('Nächster Monat')).dx + 0.5));
      expect(find.byType(ProfilButton), findsOneWidget, reason: 'in der Kopfzeile oder (eingeklappt) in der Leiste');
      expect(find.byTooltip('Heute'), eingeklappt ? findsNothing : findsOneWidget);
      pruefeLayout(tester, 'Leiste eingeklappt=$eingeklappt');
    }
    await tippe(tester, find.byTooltip('Mehr: Importieren, Exportieren'));
    expect(find.text('Heute'), findsOneWidget);
    expect(find.textContaining('Jetzt abgleichen'), findsOneWidget);
    await tippeText(tester, 'Heute');
    expect(container.read(kalenderAuswahlProvider).monat, DateTime.utc(heuteTag().year, heuteTag().month));
  });

  testWidgets('Tipp auf einen Tag des Folgemonats wechselt den Monat nicht; eingeklappt steht der Profil-Knopf in der Leiste', (tester) async {
    final (_, container) = await start(tester, monat: _d(2027, 3, 10));
    await tippe(tester, tagZelle(_d(2027, 4, 1)));
    expect(find.text('Donnerstag, 1. April'), findsOneWidget, reason: 'Tagesblatt für den Tag');
    await tester.tapAt(const Offset(10, 10));
    await warte(tester);
    expect(find.text('März 2027'), findsOneWidget, reason: 'der Monat bleibt');
    expect(container.read(kalenderAuswahlProvider).tag, _d(2027, 4, 1));
    expect(find.byType(TabKopfzeile), findsNothing);
    expect(find.byTooltip('Profil und Sicherheit'), findsOneWidget);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  testWidgets('Der eingeklappte Zustand gilt nur im Kalender-Tab', (tester) async {
    final (_, container) = await start(tester, monat: _d(2027, 3, 10));
    container.read(kalenderKopfEingeklapptProvider.notifier).setzen(true);
    await warte(tester);
    expect(find.byType(TabKopfzeile), findsNothing);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Start')));
    await warte(tester);
    expect(container.read(kalenderKopfEingeklapptProvider), isFalse);
  });

  ScrollPosition agendaPosition(WidgetTester tester) => tester.state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first).position;

  void viele(TestUmgebung e, int n) {
    final heute = heuteTag();
    for (var i = 0; i < n; i++) {
      e.sync.andereAendert('termin', _id(i + 1), _ganztaegig('Tag $i', heute.add(Duration(days: i)), heute.add(Duration(days: i))));
    }
  }

  testWidgets('knapp überlange Agenda (Scrollweite zwischen 80 und 200 px): die Kopfzeile bleibt beim Scrollen stehen', (tester) async {
    await start(tester, monatsansicht: false, groesse: const Size(360, 800), vorher: (e) => viele(e, 12));
    // Fenster so einstellen, dass der Inhalt genau 140 px länger ist als der sichtbare Bereich
    var pos = agendaPosition(tester);
    final inhalt = pos.maxScrollExtent + pos.viewportDimension;
    tester.view.physicalSize = Size(360, 800 + (inhalt - 140) - pos.viewportDimension);
    await warte(tester);
    pos = agendaPosition(tester);
    expect(pos.maxScrollExtent, inInclusiveRange(80, 200), reason: 'Voraussetzung des Tests: knapp überlang');
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await warte(tester);
      expect(find.byType(TabKopfzeile), findsOneWidget, reason: 'kein Einklappen bei knapp überlangem Inhalt');
      await tester.drag(find.byType(ListView), const Offset(0, 120));
      await warte(tester);
      expect(find.byType(TabKopfzeile), findsOneWidget);
    }
  });

  testWidgets('lange Agenda: Scrollen klappt ein, Zurückscrollen klappt aus; kurz nach dem Einklappen gilt die Beruhigung nur für Richtungswechsel', (tester) async {
    final (_, container) = await start(tester, monatsansicht: false, vorher: (e) => viele(e, 40));
    expect(agendaPosition(tester).maxScrollExtent, greaterThan(200));
    final kopf = container.read(kalenderKopfEingeklapptProvider.notifier);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    expect(container.read(kalenderKopfEingeklapptProvider), isTrue, reason: 'Scrollen nach unten klappt ein');
    // sofort zurück: noch in der Beruhigung (Animation), die Kopfzeile bleibt eingeklappt
    expect(kopf.beruhigt, isFalse);
    await tester.drag(find.byType(ListView), const Offset(0, 30));
    expect(container.read(kalenderKopfEingeklapptProvider), isTrue, reason: 'Richtungswechsel innerhalb von 250 ms wird ignoriert');
    await tester.pump(const Duration(milliseconds: 300));
    expect(kopf.beruhigt, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 30));
    await warte(tester);
    expect(container.read(kalenderKopfEingeklapptProvider), isFalse, reason: 'Hochscrollen klappt wieder aus');
    expect(find.byType(TabKopfzeile), findsOneWidget);
  });

  testWidgets('Zurück an den Anfang blendet die Kopfzeile sofort ein, auch innerhalb der Beruhigung', (tester) async {
    final (_, container) = await start(tester, monatsansicht: false, vorher: (e) => viele(e, 40));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(kalenderKopfEingeklapptProvider), isTrue);
    agendaPosition(tester).jumpTo(0);
    await tester.pump();
    expect(container.read(kalenderKopfEingeklapptProvider), isFalse);
  });

  testWidgets('Desktop klappt die Kopfzeile nie ein (Profil und Sync stehen in der Seitenleiste)', (tester) async {
    final (_, container) = await start(tester, groesse: const Size(1440, 900), monat: _d(2027, 3, 10));
    await tippe(tester, tagZelle(_d(2027, 3, 12)));
    expect(container.read(kalenderKopfEingeklapptProvider), isFalse);
    expect(find.text('// ${kopfzeilenDatum()}'.toUpperCase()), findsOneWidget);
  });

  for (final breit in [false, true]) {
    testWidgets('ohne Anlegen-Recht (${breit ? 'Desktop' : 'mobil'}): kein "Importieren", kein "Neuer Termin" in der Leiste', (tester) async {
      final env = await angemeldeteUmgebung();
      tester.view.physicalSize = breit ? const Size(1440, 900) : const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: env.overrides,
          child: MaterialApp(
            theme: ThemeData(fontFamily: kFontSans),
            home: Scaffold(body: KalenderLeiste(breit: breit, personen: const [], darfAnlegen: false, onNeu: () {})),
          ),
        ),
      );
      await warte(tester);
      expect(find.widgetWithText(FilledButton, 'Neuer Termin'), findsNothing);
      await tippe(tester, find.byTooltip(breit ? 'Importieren und Exportieren' : 'Mehr: Importieren, Exportieren'));
      expect(find.text('Importieren'), findsNothing);
      expect(find.text('Kalender exportieren'), findsOneWidget);
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
