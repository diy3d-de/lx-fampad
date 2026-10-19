// ICS-Import: Plan (neu / vorhanden / geändert / übersprungen, Limits, Rechte), Schreiben über den SyncStore (Ausgang), erneuter Import ohne
// Duplikate, Aktualisieren, und der Ablauf in der Oberfläche (Vorschau, Import, Bericht) bei 360 px und Textskala 1.0 und 1.5.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/ics_datei.dart';
import 'package:lx_fampad/data/calendar/ics_import.dart';
import 'package:lx_fampad/data/calendar/ics_parser.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/harness.dart';

final _admin = TerminRechte(Role.admin, 'user-1');
Uint8List _fixture(String n) => File('test/fixtures/ics/$n').readAsBytesSync();

class _Geraet {
  final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  late final SyncStore store = SyncStore(db);
  late final IcsImporter importer;
  var geaendert = 0;
  var _n = 0;
  _Geraet() {
    importer = IcsImporter(
      db: db,
      store: store,
      ich: () => 'user-1',
      beiAenderung: () => geaendert++,
      jetzt: () => DateTime.utc(2026, 10, 19, 8),
      neueId: () => '00000000-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}',
    );
  }

  Future<IcsPlan> plan(IcsErgebnis e, {Role rolle = Role.admin}) async {
    final termine = await db.select(db.termine).get();
    final ausn = <String, List<TerminAusnahme>>{};
    for (final a in await db.select(db.terminAusnahmen).get()) {
      ausn.putIfAbsent(a.terminId, () => []).add(a);
    }
    return icsPlanen(e, bestehende: termine, ausnahmen: ausn, rechte: TerminRechte(rolle, 'user-1'));
  }

  Future<List<Termin>> termine() => db.select(db.termine).get();
  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  group('Plan und Import', () {
    test('Import legt Termine mit UID, Zeitzone, Freigabe und Ausnahmen an und stößt den Sync an', () async {
      final g = _Geraet();
      final e = icsLesen(_fixture('familywall.ics'));
      final plan = await g.plan(e);
      expect(plan.neu, e.termine.length);
      final b = await g.importer.importieren(plan, sicht: TerminSicht.all, rechte: _admin, teilnehmer: {'user-2'});
      expect(b.neu, e.termine.length);
      expect(g.geaendert, 1);
      final alle = await g.termine();
      expect(alle, hasLength(e.termine.length));
      final madrid = alle.firstWhere((t) => t.icalUid == 'event/1011');
      expect(madrid.tzid, 'Europe/Madrid');
      expect(madrid.audience, 'all');
      expect(madrid.ownerId, 'user-1');
      final serie = alle.firstWhere((t) => t.icalUid == 'event/1007');
      expect((await g.db.select(g.db.terminAusnahmen).get()).where((a) => a.terminId == serie.id), hasLength(4));
      expect((await g.db.select(g.db.terminTeilnehmer).get()), hasLength(e.termine.length));
      final ops = await g.ausgang();
      expect(ops.where((o) => o.entity == 'termin'), hasLength(e.termine.length));
    });

    test('erneuter Import legt keine Duplikate an', () async {
      final g = _Geraet();
      final e = icsLesen(_fixture('familywall.ics'));
      await g.importer.importieren(await g.plan(e), sicht: TerminSicht.family, rechte: _admin);
      final davor = (await g.termine()).length;
      final plan2 = await g.plan(e);
      expect(plan2.neu, 0);
      expect(plan2.vorhanden, e.termine.length);
      final b = await g.importer.importieren(plan2, sicht: TerminSicht.family, rechte: _admin);
      expect(b.neu, 0);
      expect(b.vorhanden, e.termine.length);
      expect((await g.termine()).length, davor);
      expect(g.geaendert, 1); // der zweite Lauf hat nichts geschrieben
    });

    test('geänderte Termine werden nur auf Wunsch aktualisiert', () async {
      final g = _Geraet();
      final e1 = _ics('A', 'Alt');
      await g.importer.importieren(await g.plan(e1), sicht: TerminSicht.family, rechte: _admin);
      final e2 = _ics('A', 'Neu');
      final plan = await g.plan(e2);
      expect(plan.geaendert, 1);
      var b = await g.importer.importieren(plan, sicht: TerminSicht.family, rechte: _admin);
      expect(b.aktualisiert, 0);
      expect((await g.termine()).single.titel, 'Alt');
      b = await g.importer.importieren(plan, sicht: TerminSicht.family, rechte: _admin, aktualisieren: true);
      expect(b.aktualisiert, 1);
      expect((await g.termine()).single.titel, 'Neu');
    });

    test('Grenzen: Familie 5000, Kind 500 eigene; Kind darf fremde Termine nicht aktualisieren', () async {
      final g = _Geraet();
      final viele = IcsErgebnis(
        termine: [for (var i = 0; i < 520; i++) IcsTermin(uid: 'u$i', titel: 'T$i', ganztaegig: true, startDate: '2026-12-01', endDate: '2026-12-02')],
        hinweise: const [],
        gelesen: 520,
        abgeschnitten: false,
      );
      final kind = await g.plan(viele, rolle: Role.child);
      expect(kind.neu, kMaxTermineKind);
      expect(kind.eintraege.where((x) => x.status == IcsStatus.uebersprungen), hasLength(20));
      final admin = await g.plan(viele);
      expect(admin.neu, 520);
      // vorhandener Termin eines anderen, Kind darf ihn nicht ändern
      await g.importer.importieren(await g.plan(_ics('F', 'Alt')), sicht: TerminSicht.family, rechte: _admin);
      final fremd = (await g.termine()).single;
      await (g.db.update(g.db.termine)..where((t) => t.id.equals(fremd.id))).write(const TermineCompanion(ownerId: Value('anderer')));
      final p = await g.plan(_ics('F', 'Neu'), rolle: Role.child);
      expect(p.eintraege.single.status, IcsStatus.vorhanden);
      expect(p.eintraege.single.grund, isNotNull);
    });

    test('Fehler bei einem Termin lässt die anderen durch, Abbruch stoppt', () async {
      final g = _Geraet();
      final e = IcsErgebnis(
        termine: [
          const IcsTermin(uid: 'ok1', titel: 'ok', ganztaegig: true, startDate: '2026-12-01', endDate: '2026-12-02'),
          IcsTermin(uid: 'kaputt', titel: 'kaputt', ganztaegig: false, startUtc: null, endUtc: null, tzid: 'Europe/Berlin'), // startUtc fehlt -> Fehler
          const IcsTermin(uid: 'ok2', titel: 'ok2', ganztaegig: true, startDate: '2026-12-01', endDate: '2026-12-02'),
        ],
        hinweise: const [],
        gelesen: 3,
        abgeschnitten: false,
      );
      final b = await g.importer.importieren(await g.plan(e), sicht: TerminSicht.family, rechte: _admin);
      expect(b.neu, 2);
      expect(b.uebersprungen.single.titel, 'kaputt');
      final abbruch = IcsAbbruch()..angefordert = true;
      final b2 = await _Geraet().importer.importieren(await g.plan(e), sicht: TerminSicht.family, rechte: _admin, abbruch: abbruch);
      expect(b2.abgebrochen, isTrue);
      expect(b2.neu, 0);
    });
  });

  group('Aktualisieren und Ablehnungen', () {
    test('Aktualisieren prüft die Rechte beim Schreiben noch einmal; Plan nennt den vorhandenen Termin', () async {
      final g = _Geraet();
      await g.importer.importieren(await g.plan(_ics('A', 'Alt')), sicht: TerminSicht.family, rechte: _admin);
      final plan = await g.plan(_ics('A', 'Neu'));
      expect(plan.eintraege.single.status, IcsStatus.geaendert);
      expect(plan.eintraege.single.vorhanden?.titel, 'Alt');
      await (g.db.update(g.db.termine)).write(const TermineCompanion(ownerId: Value('anderer')));
      final b = await g.importer.importieren(plan, sicht: TerminSicht.family, rechte: TerminRechte(Role.child, 'user-1'), aktualisieren: true);
      expect(b.aktualisiert, 0);
      expect(b.uebersprungen.single.text, contains('keine Berechtigung'));
      expect((await g.termine()).single.titel, 'Alt');
    });

    test('Aktualisieren setzt Ausnahmen zurück, die es in der Datei nicht mehr gibt; vorher zeigt der Plan eine Änderung', () async {
      String serie(String exdate) =>
          'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:s\r\nDTSTART:20261201T100000Z\r\nDTEND:20261201T110000Z\r\nRRULE:FREQ=WEEKLY\r\n$exdate\r\nSUMMARY:Serie\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      IcsErgebnis lies(String t) => icsLesen(Uint8List.fromList(utf8.encode(t)));
      final g = _Geraet();
      await g.importer.importieren(await g.plan(lies(serie('EXDATE:20261208T100000Z'))), sicht: TerminSicht.family, rechte: _admin);
      expect((await g.db.select(g.db.terminAusnahmen).get()).single.abgesagt, isTrue);
      final plan = await g.plan(lies(serie('')));
      expect(plan.geaendert, 1);
      await g.importer.importieren(plan, sicht: TerminSicht.family, rechte: _admin, aktualisieren: true);
      expect((await g.db.select(g.db.terminAusnahmen).get()).single.abgesagt, isFalse);
    });

    test('mehrere vorhandene Termine mit derselben UID: Hinweis im Plan', () async {
      final g = _Geraet();
      await g.importer.importieren(await g.plan(_ics('D', 'Eins')), sicht: TerminSicht.family, rechte: _admin);
      final alt = (await g.termine()).single;
      await g.db.into(g.db.termine).insert(alt.copyWith(id: 'zweiter', rev: 1).toCompanion(false));
      final plan = await g.plan(_ics('D', 'Eins'));
      expect(plan.hinweise.any((h) => h.text.contains('mehrfach')), isTrue);
    });

    test('abgelehnte Op (invalid) blockiert den Ausgang nicht: sie wird verworfen und der Termin weicht', () async {
      final g = _Geraet();
      await g.importer.importieren(await g.plan(_ics('R', 'Zu viel')), sicht: TerminSicht.family, rechte: _admin);
      final ops = await g.db.select(g.db.outbox).get();
      final termin = ops.firstWhere((o) => o.entity == 'termin');
      final antwort = SyncResult(
        resyncNoetig: false,
        rev: 1,
        acked: const [],
        rejected: [SyncRejected(termin.opId, 'invalid')],
        conflicts: const [],
        changes: const [],
        hasMore: false,
        next: 0,
        snapshotRev: null,
        serverTime: null,
      );
      await g.store.uebernehmen(antwort, ops);
      expect(await g.store.offeneAnzahl(), 0);
    });
  });

  group('Oberfläche', () {
    for (final skala in [1.0, 1.5]) {
      testWidgets('Import-Ablauf mit FamilyWall-Auszug, 360 px, Textskala $skala', (tester) async {
        final env = await angemeldeteUmgebung();
        env.extraOverrides.addAll([icsLeserProvider.overrideWithValue((b, f) async => icsLesen(b)),
          icsDateiWaehlerProvider.overrideWithValue(() async => IcsDatei(name: 'familywall.ics', bytes: Stream.value(_fixture('familywall.ics'))))]);
        await starteApp(tester, env, skala: skala);
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
        await warte(tester);
        await tester.tap(find.text('Importieren'));
        await warte(tester);
        expect(find.text('ICS-Datei auswählen'), findsOneWidget);
        pruefeLayout(tester, 'Start');
        await tester.tap(find.text('ICS-Datei auswählen'));
        await warte(tester, 12);
        expect(find.text('Windparkfest'), findsOneWidget);
        expect(find.textContaining('Termine importieren'), findsOneWidget);
        pruefeLayout(tester, 'Vorschau');
        await tester.tap(find.textContaining('Termine importieren'));
        await warte(tester, 20);
        expect(find.text('Der Import ist fertig. Die Termine werden im Hintergrund mit dem Server abgeglichen.'), findsOneWidget);
        pruefeLayout(tester, 'Bericht');
        expect((await env.db.select(env.db.termine).get()), isNotEmpty);
        await tester.tap(find.text('Fertig'));
        await warte(tester);
        expect(find.text('Importieren'), findsOneWidget);
      });
    }

    testWidgets('keine ICS-Datei: verständliche Meldung statt Absturz', (tester) async {
      final env = await angemeldeteUmgebung();
      env.extraOverrides.addAll([icsLeserProvider.overrideWithValue((b, f) async => icsLesen(b)),
          icsDateiWaehlerProvider.overrideWithValue(() async => IcsDatei(name: 'x.ics', bytes: Stream.value(Uint8List.fromList([1, 2, 3]))))]);
      await starteApp(tester, env);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
      await warte(tester);
      await tester.tap(find.text('Importieren'));
      await warte(tester);
      await tester.tap(find.text('ICS-Datei auswählen'));
      await warte(tester, 12);
      expect(find.textContaining('keine ICS-Kalenderdatei'), findsOneWidget);
    });

  });
}

IcsErgebnis _ics(String uid, String titel) => icsLesen(Uint8List.fromList(utf8.encode('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:$uid\r\nDTSTART:20261201T100000Z\r\nDTEND:20261201T110000Z\r\nSUMMARY:$titel\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n')));
