// Geburtstage als Termin-Art (ohne Schemaänderung): Marke in der UID, Alter, Anzeigetitel, Erkennung importierter Geburtstage, Editor,
// Anzeige im Kalender und Startseiten-Karte.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/geburtstag.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart' show planeErinnerungen;
import 'package:lx_fampad/features/calendar/calendar_anzeige.dart' show anstehende;
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _uuid = '0b0c0d0e-1111-4111-8111-111111111111';

Termin _termin({String titel = 'Max', String? uid, bool ganztaegig = true, String start = '2026-02-23', String end = '2026-02-24', String? rrule = 'FREQ=YEARLY', int? erinnerungMin, String? ownerId}) => Termin(
  id: 't1',
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: ganztaegig,
  startUtc: null,
  endUtc: null,
  tzid: null,
  startDate: start,
  endDate: end,
  rrule: rrule,
  erinnerungMin: erinnerungMin,
  icalUid: uid,
  audience: 'family',
  ownerId: ownerId,
  createdAt: DateTime.utc(2026, 1, 1),
  rev: 1,
);

Vorkommen _vorkommen(Termin t, DateTime tag) => Vorkommen(
  termin: t,
  schluessel: tagText(tag),
  ganztaegig: true,
  startWand: tag,
  endeWand: tag.add(const Duration(days: 1)),
  startUtc: tag,
  titel: t.titel,
  ort: '',
  geaendert: false,
  serie: true,
  originalStartWand: tag,
  originalEndeWand: tag.add(const Duration(days: 1)),
  originalStartUtc: tag,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  test('Marke: Geburtsjahr steckt in der UID, 0000 = unbekannt, fremde UIDs sind keine Marke', () {
    expect(geburtstagUid(2018, _uuid), 'lxfampad-geb-2018-$_uuid');
    expect(geburtstagUid(null, _uuid), 'lxfampad-geb-0000-$_uuid');
    final t = _termin(uid: geburtstagUid(1984, _uuid));
    expect(hatGeburtstagsMarke(t), isTrue);
    expect(geburtsjahr(t), 1984);
    expect(geburtstagUidSuffix(t.icalUid), _uuid);
    expect(geburtsjahr(_termin(uid: geburtstagUid(null, _uuid))), isNull);
    expect(hatGeburtstagsMarke(_termin(uid: 'event/1004')), isFalse);
    expect(hatGeburtstagsMarke(_termin(uid: 'lxfampad-geb-20x8-$_uuid')), isFalse);
    expect(geburtstagUidSuffix('event/1'), isNull);
  });

  test('Anzeigetitel und Alter', () {
    final t = _termin(uid: geburtstagUid(2018, _uuid));
    expect(vorkommenTitel(_vorkommen(t, DateTime.utc(2027, 2, 23))), 'Max wird 9');
    expect(alterBeiVorkommen(_vorkommen(t, DateTime.utc(2026, 2, 23))), 8);
    // Geburtsjahr unbekannt
    final u = _termin(uid: geburtstagUid(null, _uuid));
    expect(vorkommenTitel(_vorkommen(u, DateTime.utc(2027, 2, 23))), 'Max hat Geburtstag');
    // Jahr vor 2000 (Serie beginnt 2000): Alter trotzdem richtig
    final alt = _termin(uid: geburtstagUid(1984, _uuid), start: '2000-02-23', end: '2000-02-24');
    expect(alterBeiVorkommen(_vorkommen(alt, DateTime.utc(2026, 2, 23))), 42);
    // Geburtsjahr = Jahr des Vorkommens: kein Alter 0
    expect(alterBeiVorkommen(_vorkommen(t, DateTime.utc(2018, 2, 23))), isNull);
    // Import ohne Marke: Titel unverändert, kein Alter
    final imp = _termin(titel: 'Geburtstag Max', rrule: 'FREQ=YEARLY;INTERVAL=1;BYMONTH=2;BYMONTHDAY=23');
    expect(vorkommenTitel(_vorkommen(imp, DateTime.utc(2027, 2, 23))), 'Geburtstag Max');
  });

  test('Erkennung: Marke oder (ganztägig, eintägig, jährlich, Titel mit Geburtstag/Birthday)', () {
    expect(istGeburtstag(_termin(uid: geburtstagUid(2018, _uuid))), isTrue);
    expect(istGeburtstag(_termin(titel: 'Geburtstag Eva')), isTrue);
    expect(istGeburtstag(_termin(titel: "Eva's Birthday")), isTrue);
    expect(istGeburtstag(_termin(titel: 'Geburtstag Eva', rrule: 'FREQ=WEEKLY')), isFalse, reason: 'nicht jährlich');
    expect(istGeburtstag(_termin(titel: 'Geburtstag Eva', rrule: null)), isFalse, reason: 'einmalig');
    expect(istGeburtstag(_termin(titel: 'Geburtstagsfeier', end: '2026-02-26')), isFalse, reason: 'mehrtägig');
    expect(istGeburtstag(_termin(titel: 'Zahnarzt')), isFalse);
    expect(istGeburtstag(_termin(titel: 'Geburtstag Eva', ganztaegig: false)), isFalse);
  });

  test('Schalttag: Geburtstag am 29.2. erscheint auch in normalen Jahren am letzten Februartag (28.2.), in Schaltjahren am 29.2.', () {
    expect(geburtstagRegel(2, 29), 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1');
    expect(geburtstagRegel(2, 28), 'FREQ=YEARLY');
    final t = _termin(titel: 'Leo', uid: geburtstagUid(2016, _uuid), start: '2016-02-29', end: '2016-03-01', rrule: geburtstagRegel(2, 29));
    final v = vorkommenImFenster(termine: [t], ausnahmen: const {}, vonWand: DateTime.utc(2026, 1, 1), bisWand: DateTime.utc(2029, 1, 1), jetzt: DateTime.utc(2026, 1, 1));
    expect([for (final x in v) tagText(x.ersterTag)], ['2026-02-28', '2027-02-28', '2028-02-29']);
    expect([for (final x in v) vorkommenTitel(x)], ['Leo wird 10', 'Leo wird 11', 'Leo wird 12']);
    // Startseiten-Karte (anstehende) und Erinnerung nutzen dieselben Vorkommen
    final daten = KalenderDaten(termine: [_termin(titel: 'Leo', uid: geburtstagUid(2016, _uuid), start: '2016-02-29', end: '2016-03-01', rrule: geburtstagRegel(2, 29), erinnerungMin: 1440, ownerId: 'me')]);
    expect([for (final x in anstehende(daten, DateTime.utc(2027, 2, 1, 12), tage: 60)) tagText(x.ersterTag)], ['2027-02-28']);
    final e = planeErinnerungen(daten: daten, ich: 'me', jetzt: DateTime.utc(2027, 2, 1, 12));
    expect(e.first.titel, 'Leo wird 11');
    expect(e.first.zeit, instantAusWand(DateTime.utc(2027, 2, 27, 9), familienOrt), reason: '1 Tag vorher, 09:00');
    // ohne die Schalttag-Regel gäbe es 2026 und 2027 keinen Eintrag
    final naiv = _termin(uid: geburtstagUid(2016, _uuid), start: '2016-02-29', end: '2016-03-01');
    expect(vorkommenImFenster(termine: [naiv], ausnahmen: const {}, vonWand: DateTime.utc(2026, 1, 1), bisWand: DateTime.utc(2028, 1, 1), jetzt: DateTime.utc(2026, 1, 1)), isEmpty);
  });

  Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, {String tab = 'Kalender', void Function(TestUmgebung)? vorher, Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung(role: 'admin');
    vorher?.call(env);
    final c = await starteApp(tester, env, groesse: groesse);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
    await warte(tester);
    return (env, c);
  }

  testWidgets('Editor: Geburtstag anlegen (ganztägig, jährlich, Marke mit Geburtsjahr), erscheint mit Alter in der Agenda', (tester) async {
    final (env, _) = await start(tester, groesse: const Size(360, 2400)); // hoch genug, dass der Editor nicht scrollen muss
    await tippe(tester, find.byTooltip('Neuer Termin'));
    await tester.enterText(find.byType(TextField).first, 'Lena');
    await tippe(tester, find.text('Geburtstag'));
    expect(find.text('Geburtsdatum'), findsWidgets);
    expect(labelFinder('Letzter Tag'), findsNothing, reason: 'Zeitfelder entfallen beim Geburtstag');
    expect(labelFinder('Wie oft?'), findsNothing);
    await tippe(tester, find.text('Geburtstag anlegen'));
    await warte(tester, 10);
    final zeilen = await env.db.select(env.db.termine).get();
    expect(zeilen, hasLength(1));
    final t = zeilen.single;
    expect(t.titel, 'Lena');
    expect(t.ganztaegig, isTrue);
    expect(t.rrule, 'FREQ=YEARLY');
    expect(hatGeburtstagsMarke(t), isTrue);
    expect(geburtsjahr(t), heuteTag().year - 10);
    final s = tagAusText(t.startDate)!;
    expect(s.year, heuteTag().year - 10 >= 2000 ? heuteTag().year - 10 : 2000);
    expect(tagAusText(t.endDate)!.difference(s).inDays, 1);
    // Agenda: heute ist ihr Geburtstag (Datum = heute vor 10 Jahren): "Lena wird 10", mit Torten-Symbol
    expect(find.text('Lena wird 10'), findsOneWidget);
    expect(find.byIcon(Icons.cake_outlined), findsWidgets);
  });

  testWidgets('Startseite: Karte "Nächste Geburtstage" nur mit Geburtstagen, Tippen öffnet den Kalender', (tester) async {
    final (_, _) = await start(tester, tab: 'Start');
    expect(labelFinder('Geburtstage'), findsNothing);
  });

  testWidgets('Startseite mit Geburtstag in 3 Tagen: Karte zeigt Name, Alter und Tag', (tester) async {
    final heute = heuteTag();
    final tag = DateTime.utc(heute.year, heute.month, heute.day + 3);
    final geboren = tag.year - 8;
    await start(tester, tab: 'Start', vorher: (e) {
      e.sync.andereAendert('termin', 'aaaaaaaa-1111-4111-8111-111111111111', {
        'titel': 'Mia',
        'ganztaegig': true,
        'startDate': tagText(DateTime.utc(geboren >= 2000 ? geboren : 2000, tag.month, tag.day)),
        'endDate': tagText(DateTime.utc(geboren >= 2000 ? geboren : 2000, tag.month, tag.day + 1)),
        'rrule': 'FREQ=YEARLY',
        'icalUid': geburtstagUid(geboren, _uuid),
        'ownerId': fixIdAdmin,
        'audience': 'family',
      });
    });
    expect(labelFinder('Geburtstage'), findsOneWidget);
    expect(find.text('Mia wird 8'), findsWidgets);
    pruefeLayout(tester, 'Startseite Geburtstage');
  });
}
