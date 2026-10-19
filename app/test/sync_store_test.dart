// SyncStore: lokale Änderungen (Tabelle + Ausgang), Verschmelzen ungesendeter Ops, Löschen mit Kaskade und die Übernahme von
// Antworten des Servers (Bestätigung, Ablehnung, Konflikt, Änderungsstrom, Resync). Reine Datenbank-Tests, kein Netz.
import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

const _l1 = '11111111-1111-4111-8111-111111111111';
const _i1 = '22222222-2222-4222-8222-222222222222';
const _i2 = '33333333-3333-4333-8333-333333333333';

SyncResult antwort({
  int rev = 1,
  List<String> acked = const [],
  List<SyncRejected> rejected = const [],
  List<SyncConflict> conflicts = const [],
  List<SyncChange> changes = const [],
  bool hasMore = false,
  int next = 0,
  bool resync = false,
}) => SyncResult(
  resyncNoetig: resync,
  rev: rev,
  acked: acked,
  rejected: rejected,
  conflicts: conflicts,
  changes: changes,
  hasMore: hasMore,
  next: next,
  serverTime: null,
);

SyncChange aenderung(String entity, String id, Map<String, dynamic> fields, int rev) =>
    SyncChange(rev: rev, entity: entity, id: id, tombstone: false, hidden: false, fields: fields);

SyncChange grab(String entity, String id, int rev, {bool hidden = false}) =>
    SyncChange(rev: rev, entity: entity, id: id, tombstone: true, hidden: hidden, fields: const {});

Map<String, dynamic> listeVomServer({String name = 'Einkauf'}) => {
  'name': name,
  'kind': 'shopping',
  'audience': 'family',
  'ownerId': null,
  'createdAt': '2026-10-19T08:00:00.000Z',
};

Map<String, dynamic> eintragVomServer({String text = 'Milch', String list = _l1}) => {
  'listId': list,
  'text': text,
  'assigneeId': null,
  'doneAt': null,
  'position': 0,
  'createdAt': '2026-10-19T08:00:00.000Z',
};

void main() {
  late AppDatabase db;
  late SyncStore store;
  var zaehler = 0;

  setUp(() {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    zaehler = 0;
    store = SyncStore(db, opId: () => 'op-${++zaehler}');
  });
  tearDown(() => db.close());

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<Liste?> liste(String id) => (db.select(db.listen)..where((l) => l.id.equals(id))).getSingleOrNull();
  Future<Listeneintrag?> eintrag(String id) => (db.select(db.listenEintraege)..where((l) => l.id.equals(id))).getSingleOrNull();

  /// Zeile ist beim Server bekannt (Revision gesetzt, nichts im Ausgang).
  Future<void> synchronisiert() async {
    final r = antwort(rev: 3, changes: [aenderung('list', _l1, listeVomServer(), 1), aenderung('list_item', _i1, eintragVomServer(), 2), aenderung('list_item', _i2, eintragVomServer(text: 'Brot'), 3)]);
    await store.uebernehmen(r, const []);
  }

  group('UUID', () {
    test('neueUuid ist eine gültige Version-4-UUID und nie doppelt', () {
      final muster = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      final ids = {for (var i = 0; i < 500; i++) neueUuid()};
      expect(ids, hasLength(500));
      for (final id in ids) {
        expect(id, matches(muster));
      }
    });
  });

  group('lokale Änderungen', () {
    test('Anlegen schreibt sofort in die Tabelle und stellt eine Op in den Ausgang (baseRev 0)', () async {
      await store.aendern('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z', 'ownerId': 'ich'});
      final l = await liste(_l1);
      expect(l?.name, 'Einkauf');
      expect(l?.ownerId, 'ich');
      expect(l?.rev, 0);
      final op = (await ausgang()).single;
      expect(op.op, 'upsert');
      expect(op.baseRev, 0);
      expect(op.opId, 'op-1');
      expect(op.fieldsJson, isNot(contains('ownerId')), reason: 'Server-Felder gehen nie zum Server');
      expect(op.fieldsJson, isNot(contains('createdAt')));
      expect(op.sentAt, isNull);
    });

    test('mehrere Änderungen vor dem Senden werden zu einer Op verschmolzen (später gewinnt je Feld), baseRev bleibt', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'Hafermilch'});
      await store.aendern('list_item', _i1, {'doneAt': '2026-10-19T09:00:00.000Z'});
      await store.aendern('list_item', _i1, {'text': 'Hafermilch (2x)'});
      final ops = await ausgang();
      expect(ops, hasLength(1));
      expect(ops.single.baseRev, 2, reason: 'Revision, auf der die Zeile beim Server steht');
      expect(ops.single.fieldsJson, contains('Hafermilch (2x)'));
      expect(ops.single.fieldsJson, contains('doneAt'));
      expect((await eintrag(_i1))?.inhalt, 'Hafermilch (2x)');
    });

    test('eine schon gesendete Op wird nicht mehr verschmolzen (sonst ginge die spätere Änderung verloren)', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'A'});
      await store.naechsteOps(10);
      await store.aendern('list_item', _i1, {'text': 'B'});
      final ops = await ausgang();
      expect(ops, hasLength(2));
      expect(ops.first.sentAt, isNotNull);
      expect(ops.last.sentAt, isNull);
      expect(ops.first.opId, isNot(ops.last.opId));
    });

    test('Änderung an einer Zeile, die es lokal nicht (mehr) gibt, legt keine Teilzeile und keine Op an', () async {
      await store.aendern('list_item', _i1, {'text': 'Hafermilch'});
      await store.aendern('list_item', _i1, {'doneAt': '2026-10-19T09:00:00.000Z'});
      expect(await eintrag(_i1), isNull);
      expect(await ausgang(), isEmpty);
    });

    test('Löschen einer nie gesendeten Zeile verschwindet spurlos (auch die Ops der Einträge)', () async {
      await store.aendern('list', _l1, {'name': 'Einkauf'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z'});
      await store.aendern('list_item', _i1, {'listId': _l1, 'text': 'Milch'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z'});
      await store.loeschen('list', _l1);
      expect(await liste(_l1), isNull);
      expect(await eintrag(_i1), isNull);
      expect(await ausgang(), isEmpty);
    });

    test('Löschen einer synchronisierten Liste: lokal sofort weg samt Einträgen, eine delete-Op, ungesendete Ops entfallen', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'Hafermilch'});
      await store.loeschen('list', _l1);
      expect(await liste(_l1), isNull);
      expect(await eintrag(_i1), isNull);
      expect(await eintrag(_i2), isNull);
      final ops = await ausgang();
      expect(ops, hasLength(1));
      expect(ops.single.op, 'delete');
      expect(ops.single.entity, 'list');
      expect(ops.single.baseRev, 1);
    });

    test('Löschen eines Eintrags, dessen Änderung schon gesendet wurde: gesendete Op bleibt, delete folgt', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'A'});
      await store.naechsteOps(10);
      await store.loeschen('list_item', _i1);
      final ops = await ausgang();
      expect([for (final o in ops) o.op], ['upsert', 'delete']);
    });
  });

  group('Senden', () {
    test('naechsteOps liefert die ältesten zuerst, markiert sie als gesendet und liefert sie beim nächsten Mal erneut', () async {
      await store.aendern('list', _l1, {'name': 'A'});
      await store.aendern('list', 'zweite', {'name': 'B'});
      final erste = await store.naechsteOps(1);
      expect(erste.single.opId, 'op-1');
      final alle = await store.naechsteOps(10);
      expect([for (final o in alle) o.opId], ['op-1', 'op-2']);
    });

    test('offeneAenderungen zählt live mit', () async {
      final werte = <int>[];
      final sub = store.offeneAenderungen().listen(werte.add);
      await Future<void>.delayed(Duration.zero);
      await store.aendern('list', _l1, {'name': 'A'});
      await Future<void>.delayed(Duration.zero);
      await (db.delete(db.outbox)).go();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(werte, [0, 1, 0]);
    });
  });

  group('Antwort übernehmen', () {
    test('Bestätigte Ops verlassen den Ausgang; der Änderungsstrom setzt die Revision der Zeile und sinceRev', () async {
      await store.aendern('list', _l1, {'name': 'Einkauf'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z'});
      final gesendet = await store.naechsteOps(10);
      final b = await store.uebernehmen(antwort(rev: 5, acked: ['op-1'], changes: [aenderung('list', _l1, listeVomServer(), 5)]), gesendet);
      expect(b.hinweise, isEmpty);
      expect(await ausgang(), isEmpty);
      expect((await liste(_l1))?.rev, 5);
      expect(await store.sinceRev(), 5);
    });

    test('mit weiteren Seiten gilt das Seitenende (next), sonst der Stand der Familie', () async {
      await store.uebernehmen(antwort(rev: 99, hasMore: true, next: 40, changes: [aenderung('list', _l1, listeVomServer(), 40)]), const []);
      expect(await store.sinceRev(), 40);
      await store.uebernehmen(antwort(rev: 99), const []);
      expect(await store.sinceRev(), 99);
    });

    test('der Stand des Servers überschreibt nur Felder ohne offene lokale Änderung', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'lokal geändert'});
      await store.uebernehmen(
        antwort(rev: 6, changes: [aenderung('list_item', _i1, {...eintragVomServer(text: 'vom Server'), 'doneAt': '2026-10-19T10:00:00.000Z', 'position': 7}, 6)]),
        const [],
      );
      final e = await eintrag(_i1);
      expect(e?.inhalt, 'lokal geändert', reason: 'ungesendete Änderung bleibt sichtbar');
      expect(e?.doneAt, isNotNull, reason: 'andere Felder kommen vom Server');
      expect(e?.position, 7);
      expect(e?.rev, 6);
    });

    test('Konflikt: der Wert des Servers gilt, ein Hinweis nennt den Namen', () async {
      await synchronisiert();
      await store.aendern('list', _l1, {'name': 'Meine Liste'});
      final gesendet = await store.naechsteOps(10);
      final b = await store.uebernehmen(
        antwort(rev: 4, acked: ['op-1'], conflicts: [const SyncConflict(opId: 'op-1', entity: 'list', id: _l1, fields: {'name': 'Wocheneinkauf'}, serverRev: 4)]),
        gesendet,
      );
      expect((await liste(_l1))?.name, 'Wocheneinkauf');
      expect(b.hinweise.single.text, contains('gleichzeitig'));
      expect(b.hinweise.single.text, contains('Wocheneinkauf'));
    });

    test('Konflikt: eine spätere, noch ungesendete Änderung desselben Felds bleibt stehen', () async {
      await synchronisiert();
      await store.aendern('list', _l1, {'name': 'Erste'});
      final gesendet = await store.naechsteOps(10);
      await store.aendern('list', _l1, {'name': 'Zweite'});
      await store.uebernehmen(
        antwort(rev: 4, acked: ['op-1'], conflicts: [const SyncConflict(opId: 'op-1', entity: 'list', id: _l1, fields: {'name': 'Fremd'}, serverRev: 4)]),
        gesendet,
      );
      expect((await liste(_l1))?.name, 'Zweite');
    });

    test('abgelehnt mit deleted: Zeile verschwindet, Hinweis nennt den Eintrag, Folge-Ops entfallen', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'Hafermilch'});
      final gesendet = await store.naechsteOps(10);
      await store.aendern('list_item', _i1, {'doneAt': '2026-10-19T10:00:00.000Z'});
      final b = await store.uebernehmen(antwort(rev: 6, rejected: [const SyncRejected('op-1', 'deleted')]), gesendet);
      expect(await eintrag(_i1), isNull);
      expect(await ausgang(), isEmpty, reason: 'auch die Folge-Op für die gelöschte Zeile entfällt');
      expect(b.hinweise.single.text, contains('Hafermilch'));
      expect(b.hinweise.single.text, contains('gelöscht'));
    });

    test('abgelehnt mit forbidden bei einer neuen Zeile: sie verschwindet wieder; bei einer bestehenden wird neu geladen', () async {
      await store.aendern('list', _l1, {'name': 'Neu'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z'});
      var gesendet = await store.naechsteOps(10);
      var b = await store.uebernehmen(antwort(rejected: [const SyncRejected('op-1', 'forbidden')]), gesendet);
      expect(await liste(_l1), isNull);
      expect(b.hinweise.single.text, contains('darfst'));
      expect(b.neuLaden, isFalse);

      await synchronisiert();
      await store.aendern('list', _l1, {'name': 'Fremde Änderung'});
      gesendet = await store.naechsteOps(10);
      b = await store.uebernehmen(antwort(rev: 3, rejected: [SyncRejected(gesendet.single.opId, 'forbidden')]), gesendet);
      expect(b.neuLaden, isTrue);
    });

    test('abgelehnte delete-Op einer schon gelöschten Zeile ist kein Fehler', () async {
      await synchronisiert();
      await store.loeschen('list_item', _i1);
      final gesendet = await store.naechsteOps(10);
      final b = await store.uebernehmen(antwort(rev: 4, rejected: [const SyncRejected('op-1', 'not_found')]), gesendet);
      expect(b.hinweise, isEmpty);
      expect(await ausgang(), isEmpty);
    });

    test('Tombstone: Zeile und untergeordnete verschwinden; ohne offene Änderung kein Hinweis, mit offener Änderung ein Hinweis', () async {
      await synchronisiert();
      var b = await store.uebernehmen(antwort(rev: 5, changes: [grab('list_item', _i2, 4)]), const []);
      expect(await eintrag(_i2), isNull);
      expect(b.hinweise, isEmpty);

      await store.aendern('list_item', _i1, {'text': 'Hafermilch'});
      b = await store.uebernehmen(antwort(rev: 6, changes: [grab('list', _l1, 6)]), const []);
      expect(await liste(_l1), isNull);
      expect(await eintrag(_i1), isNull, reason: 'Einträge einer gelöschten Liste verschwinden mit');
      expect(await ausgang(), isEmpty);
      expect(b.hinweise.single.text, contains('Hafermilch'));
    });

    test('"hidden": die Zeile verschwindet ohne Hinweis (Freigabe zurückgenommen)', () async {
      await synchronisiert();
      final b = await store.uebernehmen(antwort(rev: 5, changes: [grab('list', _l1, 5, hidden: true)]), const []);
      expect(await liste(_l1), isNull);
      expect(await eintrag(_i1), isNull);
      expect(b.hinweise, isEmpty);
    });

    test('lokal gelöscht, aber der Server liefert noch den alten Stand: die Zeile kommt nicht zurück', () async {
      await synchronisiert();
      await store.loeschen('list_item', _i1);
      await store.uebernehmen(antwort(rev: 7, changes: [aenderung('list_item', _i1, eintragVomServer(), 7)]), const []);
      expect(await eintrag(_i1), isNull);
    });

    test('Änderungen für unbekannte Entitäten (neuere App-Version) werden übersprungen', () async {
      await store.uebernehmen(antwort(rev: 2, changes: [aenderung('kalender', 'x', {'a': 1}, 2), aenderung('list', _l1, listeVomServer(), 2)]), const []);
      expect(await liste(_l1), isNotNull);
      expect(await store.sinceRev(), 2);
    });

    test('Resync: Fachtabellen werden geleert, sinceRev ist 0, der Ausgang bleibt, neu angelegte lokale Zeilen bleiben sichtbar', () async {
      await synchronisiert();
      await store.aendern('list', 'neu-1', {'name': 'Nur lokal'}, nurLokal: {'createdAt': '2026-10-19T08:00:00.000Z'});
      await store.aendern('list_item', _i1, {'text': 'geändert'});
      final b = await store.uebernehmen(antwort(rev: 3, resync: true), const []);
      expect(b.resync, isTrue);
      expect(await store.sinceRev(), 0);
      expect(await eintrag(_i2), isNull);
      expect((await liste('neu-1'))?.name, 'Nur lokal');
      expect(await ausgang(), hasLength(2));
      // der Snapshot bringt die Zeile zurück, die offene Änderung liegt darüber
      await store.uebernehmen(antwort(rev: 3, changes: [aenderung('list', _l1, listeVomServer(), 1), aenderung('list_item', _i1, eintragVomServer(), 2)]), const []);
      expect((await eintrag(_i1))?.inhalt, 'geändert');
    });
  });

  group('Gerät', () {
    test('beim ersten Mal wird die Geräte-ID nur gemerkt; wechselt sie, werden Fachtabellen geleert und sinceRev zurückgesetzt (Ausgang bleibt)', () async {
      expect(await store.geraetZuordnen('geraet-a'), isFalse);
      await synchronisiert();
      await store.sinceRevSetzen(3);
      await store.aendern('list_item', _i1, {'text': 'offen'});
      expect(await store.geraetZuordnen('geraet-a'), isFalse);
      expect(await liste(_l1), isNotNull);
      expect(await store.geraetZuordnen('geraet-b'), isTrue);
      expect(await liste(_l1), isNull);
      expect(await store.sinceRev(), 0);
      expect(await ausgang(), hasLength(1));
    });
  });

  group('Löschen aller Daten (Abmelden / Personenwechsel)', () {
    test('alleDatenLoeschen leert Fachtabellen, Ausgang und Sync-Zustand', () async {
      await synchronisiert();
      await store.aendern('list_item', _i1, {'text': 'offen'});
      await db.besitzerSetzen('u1');
      await store.geraetZuordnen('geraet-a');
      await db.alleDatenLoeschen();
      expect(await liste(_l1), isNull);
      expect(await eintrag(_i1), isNull);
      expect(await ausgang(), isEmpty);
      expect(await db.besitzerLesen(), isNull);
      expect(await store.sinceRev(), 0);
      expect(await db.metaLesen(SyncStore.kDeviceId), isNull);
    });
  });
}
