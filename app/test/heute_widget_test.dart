// Startbildschirm-Widget "Heute" (Android): Zusammenfassung (reine Anzeige, Begrenzung, neutrale Wörter ohne Titel, keine IDs/Chat/Standort),
// Dienst (entprellt, nur Änderungen, löscht beim Abmelden und beim Wipe), Einstellungen und Tipp-Ziele.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/data/heute_widget/heute_widget_dienst.dart';
import 'package:lx_fampad/data/heute_widget/heute_widget_einstellungen.dart';
import 'package:lx_fampad/data/heute_widget/heute_widget_port.dart';
import 'package:lx_fampad/data/heute_widget/heute_zusammenfassung.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/profile/heute_widget_screen.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _t1 = 'aaaaaaaa-1111-4111-8111-111111111111';
const _t2 = 'aaaaaaaa-2222-4222-8222-222222222222';
const _a1 = 'bbbbbbbb-1111-4111-8111-111111111111';
const _a2 = 'bbbbbbbb-2222-4222-8222-222222222222';
const _l1 = 'cccccccc-1111-4111-8111-111111111111';

String _zeit(int tage, int stunde) {
  final heute = heuteTag();
  return instantAusWand(DateTime.utc(heute.year, heute.month, heute.day + tage, stunde), familienOrt).toIso8601String();
}

String _tag(int tage) => tagText(DateTime.utc(heuteTag().year, heuteTag().month, heuteTag().day + tage));

Map<String, dynamic> _termin(String titel, {int tage = 0, int stunde = 10}) => {
  'titel': titel,
  'ort': 'Geheimer Ort',
  'beschreibung': 'Geheime Beschreibung',
  'ganztaegig': false,
  'startUtc': _zeit(tage, stunde),
  'endUtc': _zeit(tage, stunde + 1),
  'tzid': 'Europe/Berlin',
  'ownerId': fixIdAdmin,
  'audience': 'family',
};

Map<String, dynamic> _aufgabe(String titel, int tage) => {'titel': titel, 'faelligDate': _tag(tage), 'prioritaet': 0, 'assigneeId': null, 'erledigtAt': null, 'wiederholung': null};

Termin _t(String id, String titel, {int tage = 0, int stunde = 10, bool ganztaegig = false}) {
  final h = heuteTag();
  return Termin(
    id: id,
    titel: titel,
    ort: 'Geheimer Ort',
    beschreibung: 'Geheime Beschreibung',
    ganztaegig: ganztaegig,
    startUtc: ganztaegig ? null : DateTime.parse(_zeit(tage, stunde)),
    endUtc: ganztaegig ? null : DateTime.parse(_zeit(tage, stunde + 1)),
    tzid: ganztaegig ? null : 'Europe/Berlin',
    startDate: ganztaegig ? _tag(tage) : null,
    endDate: ganztaegig ? tagText(DateTime.utc(h.year, h.month, h.day + tage + 1)) : null,
    rrule: null,
    erinnerungMin: null,
    icalUid: null,
    audience: 'family',
    ownerId: 'user-1',
    createdAt: DateTime.utc(2026, 1, 1),
    rev: 1,
  );
}

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  group('Zusammenfassung', () {
    test('Termine von heute und den zwei Folgetagen, Uhrzeit und Titel; ganztägig ohne Uhrzeit; nur die nötigen Felder', () {
      final daten = KalenderDaten(termine: [_t(_t1, 'Zahnarzt', stunde: 9), _t(_t2, 'Feiertag', ganztaegig: true), _t('t3', 'Morgen', tage: 1), _t('t4', 'Zu weit', tage: 5)]);
      final s = _json(heuteZusammenfassung(kalender: daten, aufgaben: const [], jetzt: DateTime.now(), titelAnzeigen: true));
      expect(s['v'], 1);
      final tage = s['tage'] as List;
      expect(tage.length, 3);
      expect((tage[0]['d'] as String), _tag(0));
      final heute = (tage[0]['t'] as List).cast<Map<String, dynamic>>();
      expect(heute.map((e) => e['x']), ['Feiertag', 'Zahnarzt'], reason: 'ganztägig zuerst');
      expect(heute.firstWhere((e) => e['x'] == 'Zahnarzt')['z'], '09:00');
      expect(heute.firstWhere((e) => e['x'] == 'Feiertag')['z'], '');
      expect((tage[1]['t'] as List).single['x'], 'Morgen');
      final roh = jsonEncode(s);
      expect(roh.contains('Zu weit'), isFalse);
      expect(roh.contains('Geheimer Ort'), isFalse, reason: 'Ort gehört nicht in die Zusammenfassung');
      expect(roh.contains('Geheime Beschreibung'), isFalse);
      expect(roh.contains(_t1), isFalse, reason: 'keine IDs');
    });

    test('Begrenzung: höchstens 8 Termine je Tag, 12 Aufgaben, 8 Listeneinträge', () {
      final daten = KalenderDaten(termine: [for (var i = 0; i < 30; i++) _t('t$i', 'T$i', stunde: 6 + i % 12)]);
      final aufgaben = [
        for (var i = 0; i < 30; i++)
          Aufgabe(
            id: 'a$i',
            frist: false,
            titel: 'A$i',
            beschreibung: '',
            faelligDate: _tag(0),
            faelligUtc: null,
            tzid: null,
            prioritaet: 0,
            assigneeId: null,
            erledigtAt: null,
            erledigtVon: null,
            wiederholung: null,
            erinnerungMin: null,
            audience: 'family',
            ownerId: null,
            createdAt: DateTime.utc(2026, 1, 1),
            rev: 1,
          ),
      ];
      final s = _json(heuteZusammenfassung(kalender: daten, aufgaben: aufgaben, jetzt: DateTime.now(), titelAnzeigen: true));
      expect(((s['tage'] as List)[0]['t'] as List).length, 8);
      expect((s['aufgaben'] as List).length, 12);
      expect(s.containsKey('einkauf'), isFalse, reason: 'ohne gewählte Liste keine Einkaufsdaten');
    });

    test('ohne Titel: neutrale Wörter statt Titel, Zeiten bleiben', () {
      final daten = KalenderDaten(termine: [_t(_t1, 'Therapie bei Dr. X', stunde: 9)]);
      final s = heuteZusammenfassung(kalender: daten, aufgaben: const [], jetzt: DateTime.now(), titelAnzeigen: false, einkaufListe: 'Einkauf');
      expect(s.contains('Therapie'), isFalse);
      expect(s.contains('Dr. X'), isFalse);
      final m = _json(s);
      expect(((m['tage'] as List)[0]['t'] as List).single, {'z': '09:00', 'x': 'Termin'});
      expect(m['einkauf']['n'], 'Einkaufsliste');
    });

    test('ohneStand: nur der Inhalt zählt', () {
      final a = heuteZusammenfassung(kalender: const KalenderDaten(), aufgaben: const [], jetzt: DateTime.now(), titelAnzeigen: true, stand: DateTime.utc(2026, 1, 1));
      final b = heuteZusammenfassung(kalender: const KalenderDaten(), aufgaben: const [], jetzt: DateTime.now(), titelAnzeigen: true, stand: DateTime.utc(2027, 1, 1));
      expect(a == b, isFalse);
      expect(ohneStand(a), ohneStand(b));
    });
  });

  Future<(TestUmgebung, ProviderContainer, FakeHeuteWidgetPort)> start(
    WidgetTester tester, {
    void Function(TestUmgebung)? vorher,
    String tab = 'Start',
    Map<String, String>? speicher,
    bool wiperEcht = false,
  }) async {
    final env = await angemeldeteUmgebung(role: 'admin');
    env.feiertage = 'nein';
    env.wiperEcht = wiperEcht;
    final port = FakeHeuteWidgetPort();
    env.heuteWidgetPort = port;
    env.extraOverrides.add(heuteWidgetSpeicherProvider.overrideWithValue(MemoryHeuteWidgetSpeicher(speicher)));
    vorher?.call(env);
    final c = await starteApp(tester, env);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
    await warte(tester);
    return (env, c, port);
  }

  // mehrere Takte: ein Lesen der Anbieter im Abgleich kann selbst eine Änderung melden und einen weiteren Entprell-Timer starten, bis alles ruht
  Future<void> takt(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 3));
      await warte(tester);
    }
  }

  testWidgets('Dienst: schreibt nach dem Abgleich die Zusammenfassung, nur bei Änderung des Inhalts, entprellt', (tester) async {
    final (env, _, port) = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _termin('Zahnarzt')));
    await takt(tester);
    expect(port.geschrieben, isNotEmpty);
    final erste = port.geschrieben.length;
    final s = _json(port.letzte!);
    expect(((s['tage'] as List)[0]['t'] as List).single['x'], 'Zahnarzt');
    // keine Änderung: nichts Neues schreiben
    await takt(tester);
    expect(port.geschrieben.length, erste);
    // neuer Termin lokal: neu schreiben
    await ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)).read(terminRepositoryProvider).anlegen(
      TerminEingabe(titel: 'Neu', ganztaegig: true, startWand: heuteTag(), endeWand: heuteTag().add(const Duration(days: 1))),
    );
    await takt(tester);
    expect(port.geschrieben.length, greaterThan(erste));
    expect(port.letzte, contains('Neu'));
    expect(env.db, isNotNull);
  });

  testWidgets('Dienst: Aufgaben (fällig bis heute) und gewählte Liste stehen drin, Chat und Standort nie', (tester) async {
    final (_, _, port) = await start(
      tester,
      speicher: {kWidgetListeSchluessel: _l1},
      vorher: (e) {
        e.sync.andereAendert('aufgabe', _a1, _aufgabe('Müll raus', 0));
        e.sync.andereAendert('aufgabe', _a2, _aufgabe('Gestern', -1));
        e.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
        e.sync.andereAendert('list_item', 'dddddddd-1111-4111-8111-111111111111', {'listId': _l1, 'text': 'Milch', 'position': 0});
      },
    );
    await takt(tester);
    final s = _json(port.letzte!);
    expect((s['aufgaben'] as List).map((a) => a['x']), containsAll(['Müll raus', 'Gestern']));
    expect(s['einkauf']['n'], 'Einkauf');
    expect(s['einkauf']['e'], ['Milch']);
    expect(s['einkauf']['a'], 1);
    expect(s.keys.toSet(), {'v', 's', 'tage', 'aufgaben', 'einkauf'}, reason: 'nur diese Bereiche');
  });

  testWidgets('Einstellung "Titel anzeigen" aus: die Zusammenfassung enthält keinen Titel mehr', (tester) async {
    final (_, c, port) = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _termin('Zahnarzt')));
    await takt(tester);
    expect(port.letzte, contains('Zahnarzt'));
    await c.read(heuteWidgetEinstellungenProvider.notifier).titelSetzen(false);
    await takt(tester);
    expect(port.letzte, isNot(contains('Zahnarzt')));
    expect(port.letzte, contains('Termin'));
  });

  testWidgets('Abmelden (lokale Daten leeren) löscht die Zusammenfassung', (tester) async {
    final (env, _, port) = await start(tester, vorher: (e) => e.sync.andereAendert('termin', _t1, _termin('Zahnarzt')));
    await takt(tester);
    expect(port.geschrieben, isNotEmpty);
    expect(port.geloescht, 0);
    // der Wiper der Umgebung (Fake) zählt; der echte Wiper ruft HeuteWidgetDienst.loeschen
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    await container.read(heuteWidgetDienstProvider).loeschen();
    expect(port.geloescht, 1);
    expect(env.geloescht, 0);
  });

  testWidgets('Tipp auf das Widget öffnet den Bereich; unbekannte Ziele werden ignoriert', (tester) async {
    final (_, c, port) = await start(tester);
    port.tippe('aufgaben');
    await warte(tester);
    expect(c.read(shellTabProvider), kAufgabenTab);
    port.tippe('kalender');
    await warte(tester);
    expect(c.read(shellTabProvider), kKalenderTab);
    port.tippe('chat');
    await warte(tester);
    expect(c.read(shellTabProvider), kKalenderTab, reason: 'unbekanntes Ziel ändert nichts');
    port.tippe('../../etc');
    await warte(tester);
    expect(c.read(shellTabProvider), kKalenderTab);
  });

  testWidgets('Start per Tipp auf das Widget: das Ziel wird nach der Anmeldung geöffnet', (tester) async {
    final env = await angemeldeteUmgebung(role: 'admin');
    env.feiertage = 'nein';
    final port = FakeHeuteWidgetPort()..start = 'aufgaben';
    env.heuteWidgetPort = port;
    env.extraOverrides.add(heuteWidgetSpeicherProvider.overrideWithValue(MemoryHeuteWidgetSpeicher()));
    final c = await starteApp(tester, env);
    await warte(tester);
    expect(c.read(shellTabProvider), kAufgabenTab);
    await takt(tester);
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Profil: Widget-Einstellungen (Titel, Liste), 360 px, Textskala $skala', (tester) async {
      final env = await angemeldeteUmgebung(role: 'admin');
      env.feiertage = 'nein';
      env.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
      final port = FakeHeuteWidgetPort();
      env.heuteWidgetPort = port;
      env.extraOverrides.add(heuteWidgetSpeicherProvider.overrideWithValue(MemoryHeuteWidgetSpeicher()));
      final c = await starteApp(tester, env, skala: skala);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Start')));
      await warte(tester);
      Navigator.of(tester.element(find.byType(Scaffold).first)).push<void>(MaterialPageRoute(builder: (_) => const HeuteWidgetScreen()));
      await warte(tester, 12);
      expect(find.text('Titel im Widget zeigen'), findsOneWidget);
      expect(find.text('Einkauf'), findsOneWidget);
      pruefeLayout(tester, 'Widget-Einstellungen $skala');
      await tippe(tester, find.byType(Switch));
      expect(c.read(heuteWidgetEinstellungenProvider).titel, isFalse);
      await tippe(tester, find.text('Einkauf'));
      expect(c.read(heuteWidgetEinstellungenProvider).liste, _l1);
      Navigator.of(tester.element(find.byType(HeuteWidgetScreen))).pop();
      await takt(tester);
    });
  }

  test('Einstellungen: Standard an, keine Liste; gespeicherte Werte werden gelesen', () async {
    final c = ProviderContainer(overrides: [heuteWidgetSpeicherProvider.overrideWithValue(MemoryHeuteWidgetSpeicher({kWidgetTitelSchluessel: 'nein', kWidgetListeSchluessel: 'x'}))]);
    addTearDown(c.dispose);
    expect(c.read(heuteWidgetEinstellungenProvider), const HeuteWidgetEinstellungen());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.read(heuteWidgetEinstellungenProvider), const HeuteWidgetEinstellungen(titel: false, liste: 'x'));
  });
}
