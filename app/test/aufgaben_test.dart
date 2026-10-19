// Aufgaben: reine Logik (Fälligkeit, Überfälligkeit, einfache Wiederholung, Filter, Sortierung), AufgabeRepository (lokal sofort + Ausgang,
// Folgeaufgabe mit fester ID, Unteraufgaben), Rechte der Oberfläche und der Abgleich über den Sync-Kern (zwei Geräte gegen den Fake-Server).
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_entities.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/tasks/aufgabe_logik.dart';
import 'package:lx_fampad/data/tasks/aufgabe_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

DateTime tag(int y, int m, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, m, d, h, mi);

Aufgabe aufgabe({
  String id = 'a1',
  String titel = 'Müll',
  String? faelligDate,
  DateTime? faelligUtc,
  String? tzid,
  int prioritaet = 0,
  String? assigneeId,
  DateTime? erledigtAt,
  String? wiederholung,
  String audience = 'family',
  String? ownerId,
  DateTime? createdAt,
}) => Aufgabe(
  id: id,
  titel: titel,
  beschreibung: '',
  faelligDate: faelligDate,
  faelligUtc: faelligUtc,
  tzid: tzid,
  prioritaet: prioritaet,
  assigneeId: assigneeId,
  erledigtAt: erledigtAt,
  erledigtVon: null,
  wiederholung: wiederholung,
  erinnerungMin: null,
  audience: audience,
  ownerId: ownerId,
  createdAt: createdAt ?? DateTime.utc(2026, 10, 1),
  rev: 1,
);

class Geraet {
  final AppDatabase db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  late final SyncStore store;
  late final AufgabeRepository repo;
  var geaendert = 0;
  var _n = 0;
  DateTime jetzt;

  Geraet(String ich, {String praefix = '00000000-0000-4000-8000-', DateTime? jetzt}) : jetzt = jetzt ?? DateTime.utc(2026, 10, 19, 8) {
    store = SyncStore(db);
    repo = AufgabeRepository(
      db: db,
      store: store,
      ich: () => ich,
      beiAenderung: () => geaendert++,
      jetzt: () => this.jetzt,
      neueId: () => '$praefix${(++_n).toString().padLeft(12, '0')}',
    );
  }

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<Aufgabe?> a(String id) => (db.select(db.aufgaben)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<List<Aufgabe>> alle() => db.select(db.aufgaben).get();
  Future<List<AufgabePunkt>> punkte() => db.select(db.aufgabePunkte).get();
}

SyncResult antwort({int rev = 1, List<String> acked = const [], List<SyncRejected> rejected = const [], List<SyncChange> changes = const []}) =>
    SyncResult(resyncNoetig: false, rev: rev, acked: acked, rejected: rejected, conflicts: const [], changes: changes, hasMore: false, next: 0, snapshotRev: null, serverTime: null);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  group('Fälligkeit und Überfälligkeit', () {
    final jetzt = DateTime.utc(2026, 10, 19, 8, 30); // 10:30 Uhr Berlin

    test('Tag: überfällig erst ab dem Folgetag, heute fällig bis Mitternacht', () {
      expect(istUeberfaellig(aufgabe(faelligDate: '2026-10-18'), jetzt), isTrue);
      expect(istUeberfaellig(aufgabe(faelligDate: '2026-10-19'), jetzt), isFalse);
      expect(istHeuteFaellig(aufgabe(faelligDate: '2026-10-19'), jetzt), isTrue);
      expect(istUeberfaellig(aufgabe(faelligDate: '2026-10-20'), jetzt), isFalse);
      expect(istUeberfaellig(aufgabe(), jetzt), isFalse);
    });

    test('Zeitpunkt: überfällig, sobald er vorbei ist; Wanduhr in der Zeitzone der Aufgabe', () {
      final a = aufgabe(faelligUtc: DateTime.utc(2026, 10, 19, 8), tzid: 'Europe/Berlin'); // 10:00 Berlin, vor 30 Minuten
      expect(istUeberfaellig(a, jetzt), isTrue);
      expect(faelligWand(a), tag(2026, 10, 19, 10));
      final spaeter = aufgabe(faelligUtc: DateTime.utc(2026, 10, 19, 12), tzid: 'Europe/Berlin');
      expect(istUeberfaellig(spaeter, jetzt), isFalse);
      expect(istHeuteFaellig(spaeter, jetzt), isTrue);
    });

    test('Erledigte Aufgaben sind nie überfällig', () {
      expect(istUeberfaellig(aufgabe(faelligDate: '2026-10-01', erledigtAt: jetzt), jetzt), isFalse);
    });

    test('Um Mitternacht Berlin wechselt "heute" (nicht um Mitternacht UTC)', () {
      final spaetAbends = DateTime.utc(2026, 10, 19, 22, 30); // 00:30 am 20.10. in Berlin
      expect(tagVon(spaetAbends), tag(2026, 10, 20));
      expect(istUeberfaellig(aufgabe(faelligDate: '2026-10-19'), spaetAbends), isTrue);
    });
  });

  group('Einfache Wiederholung', () {
    final jetzt = DateTime.utc(2026, 10, 19, 8);

    test('täglich, wöchentlich, monatlich ab dem Fälligkeitstag', () {
      expect(naechsteFaelligkeit(basisWand: tag(2026, 10, 19), wdh: AufgabeWdh.taeglich, mitUhrzeit: false, jetzt: jetzt), tag(2026, 10, 20));
      expect(naechsteFaelligkeit(basisWand: tag(2026, 10, 19), wdh: AufgabeWdh.woechentlich, mitUhrzeit: false, jetzt: jetzt), tag(2026, 10, 26));
      expect(naechsteFaelligkeit(basisWand: tag(2026, 10, 19), wdh: AufgabeWdh.monatlich, mitUhrzeit: false, jetzt: jetzt), tag(2026, 11, 19));
    });

    test('lange überfällig: die nächste Fälligkeit liegt nach heute, nicht mitten in der Vergangenheit', () {
      expect(naechsteFaelligkeit(basisWand: tag(2026, 10, 14), wdh: AufgabeWdh.taeglich, mitUhrzeit: false, jetzt: jetzt), tag(2026, 10, 20));
      expect(naechsteFaelligkeit(basisWand: tag(2026, 9, 28), wdh: AufgabeWdh.woechentlich, mitUhrzeit: false, jetzt: jetzt), tag(2026, 10, 26));
    });

    test('Monatsende: der 31. wird im kürzeren Monat der letzte Tag, Jahreswechsel stimmt', () {
      expect(naechsteFaelligkeit(basisWand: tag(2026, 1, 31), wdh: AufgabeWdh.monatlich, mitUhrzeit: false, jetzt: tag(2026, 1, 31, 8)), tag(2026, 2, 28));
      expect(naechsteFaelligkeit(basisWand: tag(2028, 1, 31), wdh: AufgabeWdh.monatlich, mitUhrzeit: false, jetzt: tag(2028, 1, 31, 8)), tag(2028, 2, 29));
      expect(naechsteFaelligkeit(basisWand: tag(2026, 12, 15), wdh: AufgabeWdh.monatlich, mitUhrzeit: false, jetzt: tag(2026, 12, 15, 8)), tag(2027, 1, 15));
    });

    test('mit Uhrzeit: derselbe Wandzeit-Schritt, heute noch Ausstehendes zählt nicht als erledigt-Vorlauf', () {
      expect(naechsteFaelligkeit(basisWand: tag(2026, 10, 19, 9, 30), wdh: AufgabeWdh.taeglich, mitUhrzeit: true, jetzt: jetzt), tag(2026, 10, 20, 9, 30));
    });

    test('einmalig und Deckel: keine Folgeaufgabe', () {
      expect(naechsteFaelligkeit(basisWand: tag(2026, 10, 19), wdh: AufgabeWdh.keine, mitUhrzeit: false, jetzt: jetzt), isNull);
      // sechs Jahre in der Vergangenheit, täglich: mehr als kMaxWiederholSchritte Schritte bis heute
      expect(naechsteFaelligkeit(basisWand: tag(2020, 1, 1), wdh: AufgabeWdh.taeglich, mitUhrzeit: false, jetzt: jetzt), isNull);
      expect(kMaxWiederholSchritte, 1000);
    });

    test('unbekannte Wiederholung gilt als einmalig, unbekannte Priorität als keine', () {
      expect(AufgabeWdh.von('yearly'), AufgabeWdh.keine);
      expect(AufgabeWdh.von(null), AufgabeWdh.keine);
      expect(AufgabePrio.von(9), AufgabePrio.keine);
      expect(AufgabePrio.von(3), AufgabePrio.hoch);
    });
  });

  group('Filter und Sortierung', () {
    final a1 = aufgabe(id: 'a1', titel: 'Ohne Datum', createdAt: DateTime.utc(2026, 10, 1));
    final a2 = aufgabe(id: 'a2', titel: 'Morgen hoch', faelligDate: '2026-10-20', prioritaet: 3, assigneeId: 'u-ich', createdAt: DateTime.utc(2026, 10, 2));
    final a3 = aufgabe(id: 'a3', titel: 'Gestern niedrig', faelligDate: '2026-10-18', prioritaet: 1, assigneeId: 'u-ben', createdAt: DateTime.utc(2026, 10, 3));
    final a4 = aufgabe(id: 'a4', titel: 'Fertig', faelligDate: '2026-10-10', erledigtAt: DateTime.utc(2026, 10, 12), assigneeId: 'u-ich', createdAt: DateTime.utc(2026, 10, 4));
    final a5 = aufgabe(id: 'a5', titel: 'Später fertig', erledigtAt: DateTime.utc(2026, 10, 15), createdAt: DateTime.utc(2026, 10, 5));
    final alle = [a1, a2, a3, a4, a5];

    test('Filter: offen, alle, meine (nur offene), erledigt, dazu Person', () {
      List<String> ids(List<Aufgabe> l) => [for (final a in l) a.id];
      expect(ids(filtereAufgaben(alle, filter: AufgabeFilter.offen)), ['a1', 'a2', 'a3']);
      expect(ids(filtereAufgaben(alle, filter: AufgabeFilter.alle)), ['a1', 'a2', 'a3', 'a4', 'a5']);
      expect(ids(filtereAufgaben(alle, filter: AufgabeFilter.meine, ich: 'u-ich')), ['a2']);
      expect(ids(filtereAufgaben(alle, filter: AufgabeFilter.erledigt)), ['a4', 'a5']);
      expect(ids(filtereAufgaben(alle, filter: AufgabeFilter.alle, person: 'u-ben')), ['a3']);
      expect(ids(filtereAufgaben(alle, filter: AufgabeFilter.meine)), isEmpty);
    });

    test('Sortierung nach Fälligkeit: Fällige zuerst, ohne Datum danach, Erledigte unten (neueste zuerst)', () {
      expect([for (final a in sortiereAufgaben(alle, AufgabeSortierung.faelligkeit)) a.id], ['a3', 'a2', 'a1', 'a5', 'a4']);
    });

    test('Sortierung nach Priorität: hoch zuerst, bei gleicher Priorität nach Fälligkeit', () {
      expect([for (final a in sortiereAufgaben(alle, AufgabeSortierung.prioritaet)) a.id], ['a2', 'a3', 'a1', 'a5', 'a4']);
    });
  });

  group('AufgabeRepository (lokal zuerst)', () {
    late Geraet g;
    setUp(() => g = Geraet('u-ich'));
    tearDown(() => g.db.close());

    AufgabeEingabe eingabe({String titel = 'Müll rausbringen', DateTime? faellig, bool mitUhrzeit = false, AufgabeWdh wdh = AufgabeWdh.keine, List<PunktEingabe> punkte = const [], String? zu, AufgabePrio prio = AufgabePrio.keine}) =>
        AufgabeEingabe(titel: titel, faellig: faellig, mitUhrzeit: mitUhrzeit, wiederholung: wdh, punkte: punkte, zustaendig: zu, prioritaet: prio);

    test('Schnell anlegen: lokal sofort da, Ausgang trägt nur den Inhalt, Ersteller und Zeit nur lokal', () async {
      final id = await g.repo.schnellAnlegen('  Milch holen ', zustaendig: 'u-kind');
      final a = (await g.a(id))!;
      expect([a.titel, a.ownerId, a.assigneeId, a.rev, a.erledigtAt], ['Milch holen', 'u-ich', 'u-kind', 0, null]);
      final ops = await g.ausgang();
      expect(ops.map((o) => o.entity), ['aufgabe']);
      final f = jsonDecode(ops.single.fieldsJson) as Map<String, dynamic>;
      expect(f['titel'], 'Milch holen');
      expect(f['faelligDate'], isNull);
      expect(f['wiederholung'], isNull);
      expect(f.containsKey('ownerId'), isFalse);
      expect(f.containsKey('createdAt'), isFalse);
      expect(g.geaendert, 1);
    });

    test('Fälligkeit: Tag als Text, mit Uhrzeit UTC + Zeitzone (Sommerzeit), nie beides; Wiederholung ohne Fälligkeit entfällt', () async {
      final tagId = await g.repo.anlegen(eingabe(faellig: tag(2026, 10, 25), wdh: AufgabeWdh.woechentlich));
      final zeitId = await g.repo.anlegen(eingabe(faellig: tag(2026, 10, 20, 10), mitUhrzeit: true));
      final ohneId = await g.repo.anlegen(eingabe(wdh: AufgabeWdh.taeglich));
      final t = (await g.a(tagId))!;
      expect([t.faelligDate, t.faelligUtc, t.tzid, t.wiederholung], ['2026-10-25', null, null, 'weekly']);
      final z = (await g.a(zeitId))!;
      expect([z.faelligDate, z.faelligUtc!.toUtc(), z.tzid], [null, DateTime.utc(2026, 10, 20, 8), 'Europe/Berlin']);
      expect((await g.a(ohneId))!.wiederholung, isNull);
    });

    test('Unteraufgaben werden mit angelegt (Position nach Reihenfolge, erledigte mit Zeit)', () async {
      final id = await g.repo.anlegen(eingabe(punkte: [
        const PunktEingabe(id: 'p-1', text: 'Tonne raus'),
        const PunktEingabe(id: 'p-2', text: 'Sack holen', erledigt: true),
      ]));
      final p = await g.punkte();
      expect(p.map((x) => (x.id, x.aufgabeId, x.inhalt, x.position, x.doneAt != null)), [('p-1', id, 'Tonne raus', 0.0, false), ('p-2', id, 'Sack holen', 1.0, true)]);
      expect((await g.ausgang()).map((o) => o.entity), ['aufgabe', 'aufgabe_punkt', 'aufgabe_punkt']);
    });

    test('Speichern sendet nur geänderte Felder; Unteraufgaben: neu, geändert, entfernt', () async {
      final id = await g.repo.anlegen(eingabe(punkte: [const PunktEingabe(id: 'p-1', text: 'a'), const PunktEingabe(id: 'p-2', text: 'b')]));
      // der Server hat alles bestätigt
      await g.db.delete(g.db.outbox).go();
      await g.db.customStatement('UPDATE aufgaben SET rev = 3');
      await g.db.customStatement('UPDATE aufgabe_punkte SET rev = 3');
      final alt = (await g.a(id))!;
      await g.repo.speichern(
        alt,
        eingabe(prio: AufgabePrio.hoch, punkte: [const PunktEingabe(id: 'p-2', text: 'b geändert'), const PunktEingabe(id: 'p-3', text: 'neu')]),
        bisherigePunkte: await g.punkte(),
      );
      final ops = await g.ausgang();
      expect([for (final o in ops) '${o.op}:${o.entity}'], ['upsert:aufgabe', 'upsert:aufgabe_punkt', 'upsert:aufgabe_punkt', 'delete:aufgabe_punkt']);
      expect(jsonDecode(ops[0].fieldsJson), {'prioritaet': 3});
      expect(jsonDecode(ops[1].fieldsJson), {'text': 'b geändert', 'position': 0.0});
      expect(jsonDecode(ops[2].fieldsJson)['text'], 'neu');
      expect(ops[3].entityId, 'p-1');
      expect((await g.punkte()).map((p) => p.id).toSet(), {'p-2', 'p-3'});
      // unverändert speichern: nichts im Ausgang
      await g.db.delete(g.db.outbox).go();
      final jetzt = (await g.a(id))!;
      await g.repo.speichern(jetzt, eingabe(prio: AufgabePrio.hoch, punkte: [const PunktEingabe(id: 'p-2', text: 'b geändert'), const PunktEingabe(id: 'p-3', text: 'neu')]), bisherigePunkte: await g.punkte());
      expect(await g.ausgang(), isEmpty);
    });

    test('Abhaken setzt Zeit und Person, Zurücksetzen löscht beides; ohne Wiederholung keine Folgeaufgabe', () async {
      final id = await g.repo.schnellAnlegen('x');
      await g.db.delete(g.db.outbox).go();
      await g.repo.erledigt((await g.a(id))!, true);
      var a = (await g.a(id))!;
      expect([a.erledigtAt!.toUtc(), a.erledigtVon], [DateTime.utc(2026, 10, 19, 8), 'u-ich']);
      expect(await g.alle(), hasLength(1));
      await g.repo.erledigt(a, false);
      a = (await g.a(id))!;
      expect([a.erledigtAt, a.erledigtVon], [null, null]);
    });

    test('Wiederkehrende Aufgabe: Erledigen legt die nächste an (feste ID, gleiche Daten, Unteraufgaben ohne Haken), nur einmal', () async {
      final id = await g.repo.anlegen(eingabe(
        titel: 'Tonne',
        faellig: tag(2026, 10, 19),
        wdh: AufgabeWdh.woechentlich,
        zu: 'u-kind',
        prio: AufgabePrio.mittel,
        punkte: [const PunktEingabe(id: 'p-1', text: 'Gelb'), const PunktEingabe(id: 'p-2', text: 'Blau', erledigt: true)],
      ));
      await g.repo.erledigt((await g.a(id))!, true);
      final folge = (await g.a(folgeAufgabeId(id)))!;
      expect([folge.titel, folge.faelligDate, folge.wiederholung, folge.assigneeId, folge.prioritaet, folge.erledigtAt, folge.ownerId], ['Tonne', '2026-10-26', 'weekly', 'u-kind', 2, null, 'u-ich']);
      final punkte = (await g.punkte()).where((p) => p.aufgabeId == folge.id).toList()..sort((a, b) => a.position.compareTo(b.position));
      expect(punkte.map((p) => (p.inhalt, p.doneAt, p.id)), [('Gelb', null, folgePunktId(folge.id, 'p-1')), ('Blau', null, folgePunktId(folge.id, 'p-2'))]);
      // Haken weg und wieder dran: keine zweite Folgeaufgabe
      await g.repo.erledigt((await g.a(id))!, false);
      await g.repo.erledigt((await g.a(id))!, true);
      expect(await g.alle(), hasLength(2));
    });

    test('Wiederkehrend mit Uhrzeit: die Wandzeit bleibt über die Zeitumstellung (10:00 Berlin = 08:00 UTC im Sommer, 09:00 UTC im Winter)', () async {
      final id = await g.repo.anlegen(eingabe(faellig: tag(2026, 10, 24, 10), mitUhrzeit: true, wdh: AufgabeWdh.taeglich));
      g.jetzt = DateTime.utc(2026, 10, 24, 9);
      await g.repo.erledigt((await g.a(id))!, true);
      final folge = (await g.a(folgeAufgabeId(id)))!;
      expect(folge.faelligUtc!.toUtc(), DateTime.utc(2026, 10, 25, 9)); // 25.10.: Sommerzeit endet, 10:00 Berlin = 09:00 UTC
      expect(folge.tzid, 'Europe/Berlin');
      expect(folge.faelligDate, isNull);
    });

    test('Folgeaufgabe: gleiche ID auf jedem Gerät (zwei Geräte erledigen dieselbe Aufgabe: eine Zeile)', () {
      expect(folgeAufgabeId('a1'), folgeAufgabeId('a1'));
      expect(folgeAufgabeId('a1'), isNot(folgeAufgabeId('a2')));
      expect(folgeAufgabeId('a1'), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('Löschen entfernt Aufgabe und Unteraufgaben lokal; der Server erfährt es über eine Op (nur wenn bestätigt)', () async {
      final id = await g.repo.anlegen(eingabe(punkte: [const PunktEingabe(id: 'p-1', text: 'a')]));
      await g.repo.loeschen(id); // nie beim Server gewesen: spurlos
      expect(await g.alle(), isEmpty);
      expect(await g.punkte(), isEmpty);
      expect(await g.ausgang(), isEmpty);
      final id2 = await g.repo.anlegen(eingabe(punkte: [const PunktEingabe(id: 'p-9', text: 'a')]));
      await g.db.delete(g.db.outbox).go();
      await g.db.customStatement('UPDATE aufgaben SET rev = 2');
      await g.db.customStatement('UPDATE aufgabe_punkte SET rev = 2');
      await g.repo.loeschen(id2);
      expect(await g.alle(), isEmpty);
      expect(await g.punkte(), isEmpty);
      expect([for (final o in await g.ausgang()) '${o.op}:${o.entity}'], ['delete:aufgabe']);
    });
  });

  group('Rechte der Oberfläche', () {
    test('Eltern alles, Kinder nur eigene und nur Familie', () {
      for (final r in [Role.admin, Role.parent]) {
        final rechte = AufgabeRechte(r, 'u1');
        expect(rechte.darfAnlegen && rechte.darfAendern(aufgabe(ownerId: 'u2')) && rechte.darfFreigabeAendern, isTrue);
        expect(rechte.freigaben, AufgabeSicht.values);
      }
      const kind = AufgabeRechte(Role.child, 'u1');
      expect(kind.darfAnlegen, isTrue);
      expect(kind.darfAendern(aufgabe(ownerId: 'u1')), isTrue);
      expect(kind.darfAendern(aufgabe(ownerId: 'u2')), isFalse);
      expect(kind.darfAendern(aufgabe()), isFalse);
      expect(kind.darfFreigabeAendern, isFalse);
      expect(kind.freigaben, [AufgabeSicht.family]);
    });
  });

  group('Abgleich (SyncStore)', () {
    late Geraet g;
    setUp(() => g = Geraet('u-ich'));
    tearDown(() => g.db.close());

    const aufgabeFelder = {
      'titel': 'Müll',
      'beschreibung': 'Gelbe Tonne',
      'faelligDate': '2026-10-25',
      'faelligUtc': null,
      'tzid': null,
      'prioritaet': 2,
      'assigneeId': 'u-kind',
      'erledigtAt': null,
      'erledigtVon': null,
      'wiederholung': 'weekly',
      'erinnerungMin': null,
      'audience': 'family',
      'ownerId': 'u-mama',
      'createdAt': '2026-10-19T08:00:00.000Z',
    };

    test('Änderungsstrom legt Aufgabe und Unteraufgabe an; hidden/Tombstone der Aufgabe entfernt die Unteraufgaben mit', () async {
      await g.store.uebernehmen(
        antwort(rev: 2, changes: [
          const SyncChange(rev: 1, entity: 'aufgabe', id: 'a-1', tombstone: false, hidden: false, fields: aufgabeFelder),
          const SyncChange(rev: 2, entity: 'aufgabe_punkt', id: 'p-1', tombstone: false, hidden: false, fields: {'aufgabeId': 'a-1', 'text': 'Tonne', 'doneAt': null, 'position': 1.5, 'createdAt': '2026-10-19T08:00:00.000Z'}),
        ]),
        const [],
      );
      final a = (await g.a('a-1'))!;
      expect([a.titel, a.prioritaet, a.assigneeId, a.wiederholung, a.faelligDate, a.ownerId, a.rev], ['Müll', 2, 'u-kind', 'weekly', '2026-10-25', 'u-mama', 1]);
      expect((await g.punkte()).single.position, 1.5);
      await g.store.uebernehmen(antwort(rev: 3, changes: const [SyncChange(rev: 3, entity: 'aufgabe', id: 'a-1', tombstone: true, hidden: true, fields: {})]), const []);
      expect(await g.alle(), isEmpty);
      expect(await g.punkte(), isEmpty);
    });

    test('Zuständige Person entfernt (assigneeId null im Strom): Anzeige ohne Person', () async {
      await g.store.uebernehmen(antwort(rev: 1, changes: const [SyncChange(rev: 1, entity: 'aufgabe', id: 'a-1', tombstone: false, hidden: false, fields: aufgabeFelder)]), const []);
      await g.store.uebernehmen(antwort(rev: 2, changes: const [SyncChange(rev: 2, entity: 'aufgabe', id: 'a-1', tombstone: false, hidden: false, fields: {'assigneeId': null, 'ownerId': null})]), const []);
      final a = (await g.a('a-1'))!;
      expect([a.assigneeId, a.ownerId, a.titel], [null, null, 'Müll']);
    });

    test('abgelehnte Änderung an gelöschter Aufgabe: Hinweis; zu viele Unteraufgaben: Hinweis', () async {
      await g.store.uebernehmen(antwort(rev: 1, changes: const [SyncChange(rev: 1, entity: 'aufgabe', id: 'a-1', tombstone: false, hidden: false, fields: aufgabeFelder)]), const []);
      await g.repo.erledigt((await g.a('a-1'))!, true);
      final gesendet = await g.store.naechsteOps(50);
      final b = await g.store.uebernehmen(antwort(rev: 2, rejected: [SyncRejected(gesendet.first.opId, 'limit_reached')]), gesendet);
      expect(b.hinweise.single.text, contains('zu viele Aufgaben'));
    });
  });

  group('Zwei Geräte gegen den Fake-Server', () {
    late FakeServer server;
    late FakeSyncServer fake;

    Future<(Geraet, SyncEngine)> geraet(String ich, String geraetId, String praefix) async {
      final d = Geraet(ich, praefix: praefix);
      final tokens = MemoryTokenStore();
      await tokens.writeTokens(
        StoredTokens(accessToken: 'access-1', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'refresh-1', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: geraetId),
      );
      final client = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test');
      final engine = SyncEngine(store: d.store, api: FampadApi(client, geraet: () async => null), geraeteId: () async => geraetId, seite: 500, maxOps: 50);
      return (d, engine);
    }

    setUp(() {
      server = FakeServer();
      fake = FakeSyncServer();
      fake.registrieren(server);
    });

    test('Aufgabe mit Unteraufgaben kommt auf dem zweiten Gerät an; Haken und Löschen auch', () async {
      final (a, ea) = await geraet('u-a', fixDevice, '00000000-0000-4000-8000-');
      final (b, eb) = await geraet('u-b', 'geraet-b', '11111111-0000-4000-8000-');
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      final id = await a.repo.anlegen(const AufgabeEingabe(titel: 'Putzen', prioritaet: AufgabePrio.hoch, punkte: [PunktEingabe(id: '00000000-0000-4000-8000-0000000000aa', text: 'Bad')]));
      expect((await ea.abgleichen()).ok, isTrue);
      expect((await eb.abgleichen()).ok, isTrue);
      expect((await b.a(id))?.prioritaet, 3);
      expect((await b.punkte()).single.inhalt, 'Bad');
      await b.repo.erledigt((await b.a(id))!, true);
      await eb.abgleichen();
      await ea.abgleichen();
      expect((await a.a(id))!.erledigtAt, isNotNull);
      await a.repo.loeschen(id);
      await ea.abgleichen();
      await eb.abgleichen();
      expect(await b.alle(), isEmpty);
      expect(await b.punkte(), isEmpty);
    });

    test('zwei Geräte erledigen dieselbe wiederkehrende Aufgabe: genau eine Folgeaufgabe', () async {
      final (a, ea) = await geraet('u-a', fixDevice, '00000000-0000-4000-8000-');
      final (b, eb) = await geraet('u-b', 'geraet-b', '11111111-0000-4000-8000-');
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      final id = await a.repo.anlegen(AufgabeEingabe(titel: 'Tonne', faellig: tag(2026, 10, 19), wiederholung: AufgabeWdh.taeglich));
      await ea.abgleichen();
      await eb.abgleichen();
      await a.repo.erledigt((await a.a(id))!, true);
      await b.repo.erledigt((await b.a(id))!, true);
      await ea.abgleichen();
      expect((await eb.abgleichen()).ok, isTrue);
      await ea.abgleichen();
      expect(fake.zeilen.values.where((z) => z.entity == 'aufgabe'), hasLength(2));
      expect(await a.alle(), hasLength(2));
      expect(await b.alle(), hasLength(2));
      expect((await a.a(folgeAufgabeId(id)))!.faelligDate, '2026-10-20');
    });
  });

  test('Entitäten im Register des Clients', () {
    expect(syncEntities.keys, containsAll(['aufgabe', 'aufgabe_punkt']));
    expect(syncEntities['aufgabe']!.kinder.single.entity, 'aufgabe_punkt');
    expect(kFamilienZone, 'Europe/Berlin');
  });
}
