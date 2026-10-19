// Kalender-Oberfläche und gemeinsame Kopfzeile: Agenda, Monat, Woche, Filter je Person, Termin anlegen/ändern/löschen (auch Serien),
// Rechte, Startseite "Als Nächstes", Update-Hinweis; alles bei 360 px Breite und Textskala 1.0 und 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';
import 'package:lx_fampad/features/update/update_banner.dart';
import 'package:lx_fampad/features/update/update_service.dart';
import 'package:lx_fampad/ui/widgets.dart';
import 'package:lx_fampad/widgets/kopfzeile.dart';
import 'package:lx_fampad/widgets/sync_indicator.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _t1 = 'aaaaaaaa-1111-4111-8111-111111111111';
const _t2 = 'aaaaaaaa-2222-4222-8222-222222222222';
const _t3 = 'aaaaaaaa-3333-4333-8333-333333333333';

/// Beginn eines Termins [tage] Tage nach heute um [stunde] Uhr (Familienzone) als UTC-Text.
String _zeit(int tage, int stunde, [int minute = 0]) {
  final heute = heuteTag();
  final w = DateTime.utc(heute.year, heute.month, heute.day + tage, stunde, minute);
  return instantAusWand(w, familienOrt).toIso8601String();
}

String _tag(int tage) => tagText(DateTime.utc(heuteTag().year, heuteTag().month, heuteTag().day + tage));

Map<String, dynamic> _zeittermin(String titel, {int tage = 1, int stunde = 10, String? owner, String? rrule, String ort = '', String audience = 'family'}) => {
  'titel': titel,
  'ort': ort,
  'ganztaegig': false,
  'startUtc': _zeit(tage, stunde),
  'endUtc': _zeit(tage, stunde + 1),
  'tzid': 'Europe/Berlin',
  'rrule': ?rrule,
  'ownerId': owner ?? fixIdAdmin,
  'audience': audience,
};

Future<void> zumTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  await warte(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', void Function(TestUmgebung env)? vorher, double skala = 1.0, String tab = 'Kalender'}) async {
    final env = await angemeldeteUmgebung(role: role);
    vorher?.call(env);
    await starteApp(tester, env, skala: skala);
    await zumTab(tester, tab);
    return env;
  }

  for (final skala in [1.0, 1.5]) {
    testWidgets('Kopfzeile Textskala $skala: alle Tabs zeigen Datum, Sync-Symbol und Profil-Knopf gleich angeordnet', (tester) async {
      await start(tester, skala: skala, tab: 'Start');
      final datum = '// ${kopfzeilenDatum()}'.toUpperCase();
      Rect? profil;
      Rect? sync;
      Rect? label;
      for (final tab in kTabs) {
        await zumTab(tester, tab.label);
        expect(find.text(datum), findsOneWidget, reason: 'Datum im Tab ${tab.label}');
        expect(find.byType(SyncIndicator), findsOneWidget, reason: 'Sync-Symbol im Tab ${tab.label}');
        expect(find.byTooltip('Profil und Sicherheit'), findsOneWidget, reason: 'Profil-Knopf im Tab ${tab.label}');
        final p = tester.getRect(find.byType(ProfilButton));
        final s = tester.getRect(find.byType(SyncIndicator));
        final l = tester.getRect(find.text(datum));
        profil ??= p;
        sync ??= s;
        label ??= l;
        expect(p, profil, reason: 'Profil-Knopf wandert in ${tab.label}');
        expect(s.right, sync.right, reason: 'Sync-Symbol wandert in ${tab.label}');
        expect(l.topLeft, label.topLeft, reason: 'Datum wandert in ${tab.label}');
        pruefeLayout(tester, 'Tab ${tab.label}');
      }
    });
  }

  testWidgets('Profil-Knopf: Initialen in der Personenfarbe (Platzhalter für das Benutzerbild), öffnet das Profil', (tester) async {
    await start(tester, tab: 'Start');
    final avatar = tester.widget<PersonAvatar>(find.descendant(of: find.byType(ProfilButton), matching: find.byType(PersonAvatar)));
    expect(avatar.name, 'Anna');
    expect(avatar.colorIndex, 3);
    expect(avatar.bild, isNull);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  testWidgets('Agenda: Termine nach Tagen, Zeit, Ort, Serien-Symbol; leere Agenda', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('termin', _t1, _zeittermin('Zahnarzt', ort: 'Praxis Dr. Meier'));
      e.sync.andereAendert('termin', _t2, {
        'titel': 'Ferien',
        'ganztaegig': true,
        'startDate': _tag(3),
        'endDate': _tag(6),
        'ownerId': fixIdKind,
      });
      e.sync.andereAendert('termin', _t3, _zeittermin('Training', tage: 0, stunde: 22, rrule: 'FREQ=WEEKLY'));
    });
    expect(find.text('Zahnarzt'), findsOneWidget);
    expect(find.text('10:00–11:00'), findsWidgets);
    expect(find.text('Praxis Dr. Meier'), findsOneWidget);
    expect(find.text('Ferien'), findsNWidgets(3), reason: 'mehrtägig: an jedem Tag');
    expect(find.text('ganztägig'), findsWidgets);
    expect(find.byIcon(Icons.repeat), findsWidgets);
    expect(find.textContaining('· HEUTE'), findsOneWidget, reason: 'der heutige Tag ist markiert');
    pruefeLayout(tester, 'Agenda');
  });

  testWidgets('Agenda ohne Termine: Hinweis', (tester) async {
    await start(tester);
    expect(find.text('Keine Termine'), findsOneWidget);
  });

  testWidgets('Filter je Person: nur Termine von Ben (Ersteller oder Teilnehmer)', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('termin', _t1, _zeittermin('Annas Termin'));
      e.sync.andereAendert('termin', _t2, _zeittermin('Bens Termin', owner: fixIdKind));
      e.sync.andereAendert('termin', _t3, _zeittermin('Gemeinsam', stunde: 14));
      e.sync.andereAendert('termin_teilnehmer', 'bbbbbbbb-1111-4111-8111-111111111111', {'terminId': _t3, 'userId': fixIdKind});
    });
    expect(find.text('Annas Termin'), findsOneWidget);
    await tippe(tester, find.bySemanticsLabel('Termine von Ben'));
    expect(find.text('Annas Termin'), findsNothing);
    expect(find.text('Bens Termin'), findsOneWidget);
    expect(find.text('Gemeinsam'), findsOneWidget);
    await tippeText(tester, 'Alle');
    expect(find.text('Annas Termin'), findsOneWidget);
  });

  testWidgets('Detail, Bearbeiten (alle) und Löschen eines einzelnen Termins', (tester) async {
    final env = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _zeittermin('Zahnarzt')));
    await tippeText(tester, 'Zahnarzt');
    expect(find.text('Bearbeiten'), findsOneWidget);
    await tippeText(tester, 'Bearbeiten');
    expect(find.text('Termin bearbeiten'), findsOneWidget);
    await eingeben(tester, 'Titel', 'Zahnarzt Kontrolle');
    await tippeText(tester, 'Speichern');
    await warte(tester, 8);
    expect((await env.db.select(env.db.termine).get()).single.titel, 'Zahnarzt Kontrolle');
    expect(find.text('Zahnarzt Kontrolle'), findsOneWidget);

    await tippeText(tester, 'Zahnarzt Kontrolle');
    await tippeText(tester, 'Löschen');
    expect(find.text('Termin „Zahnarzt Kontrolle“ löschen?'), findsOneWidget);
    await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
    await warte(tester, 8);
    expect(await env.db.select(env.db.termine).get(), isEmpty);
    pruefeLayout(tester, 'nach dem Löschen');
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Termin anlegen (Textskala $skala): Editor, Wiederholung, Teilnehmer; erscheint in der Agenda; Layout', (tester) async {
      final env = await start(tester, skala: skala);
      await tippeText(tester, 'Neuer Termin');
      expect(find.text('Neuer Termin'), findsWidgets);
      pruefeLayout(tester, 'Editor');
      await eingeben(tester, 'Titel', 'Elternabend mit einem ziemlich langen Titel, der umbrechen muss');
      await eingeben(tester, 'Ort', 'Schule');
      // Wiederholung: wöchentlich
      await tippeText(tester, 'Einmalig');
      pruefeLayout(tester, 'Wiederholung');
      await tippeText(tester, 'Wöchentlich');
      await tippeText(tester, 'Nach Anzahl');
      await tippeText(tester, 'Fertig');
      // Teilnehmer
      await tippe(tester, find.bySemanticsLabel('Teilnehmer Ben'));
      await tippeText(tester, 'Termin anlegen');
      await warte(tester, 10);
      final t = (await env.db.select(env.db.termine).get()).single;
      expect(t.titel, startsWith('Elternabend'));
      expect(t.ort, 'Schule');
      expect(t.rrule, startsWith('FREQ=WEEKLY;BYDAY='));
      expect(t.rrule, endsWith('COUNT=10'));
      expect(t.tzid, 'Europe/Berlin');
      expect(t.ownerId, fixIdAdmin);
      expect((await env.db.select(env.db.terminTeilnehmer).get()).single.userId, fixIdKind);
      expect(find.textContaining('Elternabend'), findsWidgets);
      // zum Server gelangt (Abgleich nach der Änderung)
      await warte(tester, 30);
      expect(env.sync.zeilen.values.where((z) => z.entity == 'termin'), hasLength(1));
      pruefeLayout(tester, 'Agenda nach dem Anlegen');
    });
  }

  testWidgets('Editor: ohne Titel wird nicht gespeichert, mit Titel schon', (tester) async {
    final env = await start(tester);
    await tippeText(tester, 'Neuer Termin');
    await tippeText(tester, 'Termin anlegen');
    expect(find.text('Gib dem Termin einen Titel.'), findsOneWidget);
    expect(await env.db.select(env.db.termine).get(), isEmpty);
    await eingeben(tester, 'Titel', 'x');
    await tippeText(tester, 'Termin anlegen');
    await warte(tester, 8);
    expect(await env.db.select(env.db.termine).get(), hasLength(1));
  });

  testWidgets('Serie: nur dieses Vorkommen löschen = Ausnahme "abgesagt"; die Serie bleibt', (tester) async {
    final env = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _zeittermin('Chor', rrule: 'FREQ=WEEKLY')));
    final vorher = find.text('Chor').evaluate().length;
    expect(vorher, greaterThan(3));
    await tippe(tester, find.text('Chor').first);
    await tippeText(tester, 'Löschen');
    expect(find.text('Nur dieses Vorkommen'), findsOneWidget);
    expect(find.text('Dieses und alle folgenden'), findsNothing, reason: 'das erste Vorkommen hat kein "folgende"');
    await tippeText(tester, 'Nur dieses Vorkommen');
    await warte(tester, 8);
    final a = await env.db.select(env.db.terminAusnahmen).get();
    expect(a.single.abgesagt, isTrue);
    expect(a.single.terminId, _t1);
    expect(find.text('Chor').evaluate().length, vorher - 1);
    expect(await env.db.select(env.db.termine).get(), hasLength(1));
  });

  testWidgets('Serie: dieses und folgende löschen kürzt die Serie (UNTIL)', (tester) async {
    final env = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _zeittermin('Chor', rrule: 'FREQ=WEEKLY')));
    await tippe(tester, find.text('Chor').at(2));
    await tippeText(tester, 'Löschen');
    await tippeText(tester, 'Dieses und alle folgenden');
    await warte(tester, 8);
    final t = (await env.db.select(env.db.termine).get()).single;
    expect(t.rrule, contains('UNTIL='));
    expect(find.text('Chor').evaluate().length, 2);
  });

  testWidgets('Serie: nur dieses Vorkommen ändern (Titel) erzeugt eine Ausnahme mit Überschreibung', (tester) async {
    final env = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _zeittermin('Chor', rrule: 'FREQ=WEEKLY')));
    await tippe(tester, find.text('Chor').at(1));
    await tippeText(tester, 'Bearbeiten');
    await tippeText(tester, 'Nur dieses Vorkommen');
    expect(find.text('Dieses Vorkommen'), findsOneWidget);
    expect(find.text('Wiederholung'), findsNothing, reason: 'eine Ausnahme hat keine eigene Wiederholung');
    await eingeben(tester, 'Titel', 'Chor Sonderprobe');
    await tippeText(tester, 'Speichern');
    await warte(tester, 8);
    final a = (await env.db.select(env.db.terminAusnahmen).get()).single;
    expect(a.titel, 'Chor Sonderprobe');
    expect(a.abgesagt, isFalse);
    expect((await env.db.select(env.db.termine).get()).single.titel, 'Chor');
    expect(find.text('Chor Sonderprobe'), findsOneWidget);
  });

  testWidgets('Monat: 48-px-Zellen, Punkte in Personenfarben, Tag wählen zeigt dessen Termine; Layout', (tester) async {
    await start(tester, vorher: (e) {
      e.sync.andereAendert('termin', _t1, _zeittermin('Heute-Termin', tage: 0, stunde: 22));
    });
    await tippeText(tester, 'Monat');
    final heute = heuteTag();
    final zelle = find.widgetWithText(InkWell, '${heute.day}').first;
    expect(tester.getSize(zelle).height, 48);
    expect(tester.getSize(zelle).width, greaterThanOrEqualTo(44));
    await tippe(tester, zelle);
    expect(find.text('Heute-Termin'), findsOneWidget);
    await tippe(tester, find.byTooltip('Nächster Monat'));
    expect(find.text('Heute-Termin'), findsNothing);
    pruefeLayout(tester, 'Monat');
  });

  testWidgets('Woche: sieben Tage, blättern, "frei" bei leeren Tagen', (tester) async {
    await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _zeittermin('Wochentermin', tage: 0, stunde: 22)));
    await tippeText(tester, 'Woche');
    expect(find.text('Wochentermin'), findsOneWidget);
    expect(find.text('frei'), findsWidgets);
    await tippe(tester, find.byTooltip('Nächste Woche'));
    expect(find.text('Wochentermin'), findsNothing);
    await tippeText(tester, 'Heute');
    expect(find.text('Wochentermin'), findsOneWidget);
    pruefeLayout(tester, 'Woche');
  });

  testWidgets('Rechte: Gäste legen nichts an; Kinder ändern keine fremden Termine', (tester) async {
    await start(tester, role: 'guest', vorher: (e) => e.sync.andereAendert('termin', _t1, _zeittermin('Zahnarzt', audience: 'all')));
    expect(find.text('Neuer Termin'), findsNothing);
    await tippeText(tester, 'Zahnarzt');
    expect(find.text('Bearbeiten'), findsNothing);
    expect(find.text('Du darfst diesen Termin nicht ändern.'), findsOneWidget);
  });

  testWidgets('Kind: eigener Termin änderbar, fremder nicht', (tester) async {
    await start(tester, role: 'child', vorher: (e) {
      e.sync.andereAendert('termin', _t1, _zeittermin('Fremd'));
      e.sync.andereAendert('termin', _t2, _zeittermin('Eigen', owner: fixIdAdmin, stunde: 15));
    });
    // in meJson ist der Nutzer immer "Anna" (fixIdAdmin) mit der Rolle: Ersteller fixIdAdmin = eigener Termin
    await tippeText(tester, 'Eigen');
    expect(find.text('Bearbeiten'), findsOneWidget);
  });

  testWidgets('Startseite: "Als Nächstes" zeigt echte Termine, Tippen öffnet den Kalender; Schnellzugriff "Termin" öffnet den Editor', (tester) async {
    await start(tester, tab: 'Start', vorher: (e) {
      e.sync.andereAendert('termin', _t1, _zeittermin('Zahnarzt', tage: 1));
      e.sync.andereAendert('termin', _t2, _zeittermin('Elternabend', tage: 2, stunde: 19));
    });
    expect(find.text('Zahnarzt'), findsOneWidget);
    expect(find.text('Elternabend'), findsOneWidget);
    expect(find.text('Keine anstehenden Termine'), findsNothing);
    pruefeLayout(tester, 'Start mit Terminen');
    await tippeText(tester, 'Zahnarzt');
    expect(find.text('Kalender'), findsWidgets);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
    await zumTab(tester, 'Start');
    await tippeText(tester, 'Termin');
    expect(find.text('Neuer Termin'), findsWidgets);
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('Startseite ohne Termine: Hinweis', (tester) async {
    await start(tester, tab: 'Start');
    expect(find.text('Keine anstehenden Termine'), findsOneWidget);
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Update-Hinweis Textskala $skala: Installieren-Karte nennt die automatische Sperre', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = skala;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final info = UpdateInfo(
        version: '0.2.0',
        versionCode: 2,
        minVersion: '0.1.0',
        notes: '',
        apkUrl: Uri.parse('https://familie.test/a.apk'),
        sha256: 'a' * 64,
        size: 1,
        issuedAt: DateTime.utc(2026, 10, 19),
      );
      final container = ProviderContainer(overrides: [updateProvider.overrideWith(() => _FesterUpdate(UpdateState(phase: UpdatePhase.bereit, info: info)))]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(fontFamily: kFontSans),
            home: const Scaffold(body: SingleChildScrollView(child: Padding(padding: EdgeInsets.all(20), child: UpdateAnzeige()))),
          ),
        ),
      );
      expect(find.text('Installieren'), findsOneWidget);
      expect(find.textContaining('schalte vorübergehend die Automatische Sperre (Android-Einstellungen) aus'), findsOneWidget);
      expect(find.text(kInstallierenHinweis), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Pflicht-Seite zeigt ihn ebenfalls
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: MaterialApp(theme: ThemeData(fontFamily: kFontSans), home: const PflichtUpdateSeite())),
      );
      expect(find.text(kInstallierenHinweis), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _FesterUpdate extends UpdateController {
  final UpdateState fest;
  _FesterUpdate(this.fest);

  @override
  UpdateState build() => fest;
}
