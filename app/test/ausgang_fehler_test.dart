// Ausgang mit Fehlerzustand: eine vom Server endgültig abgelehnte neue Chat-Nachricht bleibt lokal und im Ausgang (mit Grund-Code, nie mit Inhalt),
// sendet nichts mehr, zählt nicht als "offen" und lässt sich erneut senden (feste ID, neue op_id, kein Duplikat) oder verwerfen. Dazu die Ableitung
// des Zustands (wartet, wird gesendet, hängt, abgelehnt).
import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/lese_status.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

const _k = '55555555-5555-4555-8555-555555555555';
const _n = '66666666-6666-4666-8666-666666666666';
const _l1 = '11111111-1111-4111-8111-111111111111';
const _i1 = '22222222-2222-4222-8222-222222222222';

SyncResult _antwort({List<String> acked = const [], List<SyncRejected> rejected = const [], int rev = 1, List<SyncChange> changes = const []}) => SyncResult(
  resyncNoetig: false,
  rev: rev,
  acked: acked,
  rejected: rejected,
  conflicts: const [],
  changes: changes,
  hasMore: false,
  next: 0,
  snapshotRev: null,
  serverTime: null,
);

void main() {
  late AppDatabase db;
  late SyncStore store;
  var zaehler = 0;
  var jetzt = DateTime.utc(2026, 10, 20, 10);

  setUp(() {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    zaehler = 0;
    jetzt = DateTime.utc(2026, 10, 20, 10);
    store = SyncStore(db, opId: () => 'op-${++zaehler}', jetzt: () => jetzt);
  });
  tearDown(() => db.close());

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<List<Nachricht>> nachrichten() => db.select(db.nachrichten).get();

  Future<OutboxData> senden() async {
    await store.aendern('nachricht', _n, {'konversationId': _k, 'text': 'e1:geheim', 'autorId': 'u1'}, nurLokal: {'createdAt': '2026-10-20T10:00:00.000Z'});
    final ops = await store.naechsteOps(50);
    expect(ops, hasLength(1));
    return ops.single;
  }

  group('Ablehnung einer neuen Nachricht', () {
    test('bleibt lokal und im Ausgang, markiert mit dem Code; ohne Hinweis und ohne Neuladen', () async {
      final op = await senden();
      final bericht = await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'forbidden')]), [op]);
      expect(bericht.hinweise, isEmpty);
      expect(bericht.neuLaden, isFalse);
      final z = (await ausgang()).single;
      expect(z.opId, op.opId);
      expect(z.fehlerCode, 'forbidden');
      expect(z.sentAt, isNull);
      expect(await nachrichten(), hasLength(1));
      expect((await nachrichten()).single.rev, 0);
    });

    test('wird nicht mehr gesendet, zählt nicht als offene Änderung und blockiert weitere Nachrichten nicht', () async {
      final op = await senden();
      await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'invalid')]), [op]);
      expect(await store.naechsteOps(50), isEmpty);
      expect(await store.offeneAnzahl(), 0);
      expect(await store.offeneAenderungen().first, 0);
      expect(await store.hatAltenKlartext(Duration.zero), isFalse);
      // eine andere Nachricht geht weiter
      await store.aendern('nachricht', '77777777-7777-4777-8777-777777777777', {'konversationId': _k, 'text': 'e1:zwei'});
      expect(await store.naechsteOps(50), hasLength(1));
      expect(await store.offeneAnzahl(), 1);
    });

    test('der Code wird nur als kurzer Kleinbuchstaben-Code gespeichert (nie ein Text des Servers)', () async {
      final op = await senden();
      await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'Geheimer Text vom Server, der nicht in die Datenbank gehört')]), [op]);
      expect((await ausgang()).single.fehlerCode, 'unbekannt');
    });

    test('gelöschter Chat und Mengenbegrenzung gehen den üblichen Weg (kein Fehlerzustand)', () async {
      var op = await senden();
      await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'parent_deleted')]), [op]);
      expect(await nachrichten(), isEmpty);
      expect(await ausgang(), isEmpty);
      op = await senden();
      await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'limit_reached')]), [op]);
      final neu = (await ausgang()).single;
      expect(neu.fehlerCode, isNull);
      expect(neu.opId, isNot(op.opId)); // später erneut, mit neuer op_id
      expect(await nachrichten(), hasLength(1));
    });

    test('andere Entitäten bleiben beim bisherigen Verhalten (abgelehnter Listeneintrag verschwindet mit Hinweis)', () async {
      await store.uebernehmen(
        _antwort(
          changes: [
            SyncChange(rev: 1, entity: 'list', id: _l1, tombstone: false, hidden: false, fields: {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family', 'ownerId': null, 'createdAt': '2026-10-19T08:00:00.000Z'}),
          ],
        ),
        const [],
      );
      await store.aendern('list_item', _i1, {'listId': _l1, 'text': 'Milch', 'position': 0});
      final op = (await store.naechsteOps(50)).single;
      final bericht = await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'forbidden')]), [op]);
      expect(bericht.hinweise, isNotEmpty);
      expect(await ausgang(), isEmpty);
    });
  });

  group('Erneut senden und Verwerfen', () {
    test('Erneut senden: dieselbe Nachricht (feste ID), neue op_id, wieder im Versand; nach der Bestätigung genau eine Nachricht', () async {
      final op = await senden();
      await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'forbidden')]), [op]);
      jetzt = jetzt.add(const Duration(minutes: 5));
      expect(await store.erneutSenden('nachricht', _n), isTrue);
      final z = (await ausgang()).single;
      expect(z.fehlerCode, isNull);
      expect(z.opId, isNot(op.opId));
      expect(z.createdAt.toUtc(), jetzt, reason: 'die Zeit für "hängt" beginnt neu');
      final erneut = (await store.naechsteOps(50)).single;
      expect(erneut.entityId, _n);
      await store.uebernehmen(
        _antwort(
          acked: [erneut.opId],
          rev: 2,
          changes: [
            SyncChange(rev: 2, entity: 'nachricht', id: _n, tombstone: false, hidden: false, fields: {'konversationId': _k, 'text': 'e1:geheim', 'autorId': 'u1', 'createdAt': '2026-10-20T10:00:00.000Z'}),
          ],
        ),
        [erneut],
      );
      expect(await ausgang(), isEmpty);
      final liste = await nachrichten();
      expect(liste, hasLength(1));
      expect(liste.single.rev, 2);
    });

    test('Erneut senden ohne abgelehnte Op tut nichts', () async {
      await senden();
      expect(await store.erneutSenden('nachricht', _n), isFalse);
    });

    test('Verwerfen löscht die lokale Nachricht und die Op; es geht nichts zum Server', () async {
      final op = await senden();
      await store.uebernehmen(_antwort(rejected: [SyncRejected(op.opId, 'forbidden')]), [op]);
      await store.loeschen('nachricht', _n);
      expect(await nachrichten(), isEmpty);
      expect(await ausgang(), isEmpty);
    });
  });

  group('Zustand', () {
    OutboxData op({DateTime? sentAt, String? fehler, Duration alt = Duration.zero}) =>
        OutboxData(id: 1, opId: 'o', op: 'upsert', entity: 'nachricht', entityId: _n, fieldsJson: '{}', baseRev: 0, createdAt: jetzt.subtract(alt), sentAt: sentAt, fehlerCode: fehler);

    test('keine Op: wird gesendet; nie gesendet: wartet; Versuch läuft: wird gesendet', () {
      expect(ausgangZustand(null, jetzt: jetzt), LeseZustand.wirdGesendet);
      expect(ausgangZustand(op(), jetzt: jetzt), LeseZustand.wartet);
      expect(ausgangZustand(op(sentAt: jetzt), jetzt: jetzt), LeseZustand.wirdGesendet);
    });

    test('nach mehr als zwei Minuten ohne Fortschritt: hängt (gesendet oder nicht)', () {
      expect(ausgangZustand(op(alt: const Duration(minutes: 2)), jetzt: jetzt), LeseZustand.wartet);
      expect(ausgangZustand(op(alt: const Duration(minutes: 2, seconds: 1)), jetzt: jetzt), LeseZustand.haengt);
      expect(ausgangZustand(op(alt: const Duration(minutes: 5), sentAt: jetzt.subtract(const Duration(minutes: 1))), jetzt: jetzt), LeseZustand.haengt);
    });

    test('gerade unterwegs (Sendeversuch vor wenigen Sekunden): nie hängt, auch bei alter Op', () {
      expect(ausgangZustand(op(alt: const Duration(minutes: 9), sentAt: jetzt.subtract(const Duration(seconds: 5))), jetzt: jetzt), LeseZustand.wirdGesendet);
      expect(ausgangZustand(op(alt: const Duration(minutes: 9), sentAt: jetzt.subtract(const Duration(seconds: 30))), jetzt: jetzt), LeseZustand.haengt);
      expect(haengtAb(op(alt: const Duration(minutes: 9), sentAt: jetzt.subtract(const Duration(seconds: 5))), jetzt), jetzt.add(const Duration(seconds: 10)));
    });

    test('mehrere Ops je Nachricht: abgelehnt hat Vorrang, sonst gilt die Anlage (älteste)', () {
      OutboxData o(int id, {String? fehler}) => OutboxData(id: id, opId: 'o$id', op: 'upsert', entity: 'nachricht', entityId: _n, fieldsJson: '{}', baseRev: 0, createdAt: jetzt, sentAt: null, fehlerCode: fehler);
      expect(ausgangJeNachricht([o(1, fehler: 'forbidden'), o(2)])[_n]!.opId, 'o1');
      expect(ausgangJeNachricht([o(1), o(2, fehler: 'invalid')])[_n]!.opId, 'o2');
      expect(ausgangJeNachricht([o(1), o(2)])[_n]!.opId, 'o1');
    });

    test('Fehler-Code gewinnt gegen jedes Alter: abgelehnt', () {
      expect(ausgangZustand(op(fehler: 'forbidden', alt: const Duration(hours: 1)), jetzt: jetzt), LeseZustand.abgelehnt);
    });

    test('haengtAb: Zeitpunkt für das Neuzeichnen, bei Fehler oder ohne Op null', () {
      expect(haengtAb(op(), jetzt), jetzt.add(kHaengtNach));
      expect(haengtAb(op(alt: const Duration(minutes: 3)), jetzt), isNull);
      expect(haengtAb(op(fehler: 'forbidden'), jetzt), isNull);
      expect(haengtAb(null, jetzt), isNull);
    });

    test('leseInfo: bestätigte Nachricht ignoriert den Ausgang, unbestätigte folgt ihm', () {
      final n = Nachricht(id: _n, konversationId: _k, autorId: 'u1', inhalt: 'e1:x', antwortAuf: null, bearbeitetAt: null, createdAt: jetzt, rev: 0);
      final i = leseInfo(nachricht: n, empfaenger: {'b'}, gelesenBis: const {}, ausgang: op(fehler: 'forbidden'), jetzt: jetzt);
      expect(i.zustand, LeseZustand.abgelehnt);
      expect(i.fehlerCode, 'forbidden');
      expect(i.ungesendet, isTrue);
      expect(leseInfo(nachricht: n, empfaenger: {'b'}, gelesenBis: const {}, ausgang: op(alt: const Duration(minutes: 9)), jetzt: jetzt).zustand, LeseZustand.haengt);
      final bestaetigt = n.copyWith(rev: 4);
      final b = leseInfo(nachricht: bestaetigt, empfaenger: {'b'}, gelesenBis: const {}, ausgang: op(fehler: 'forbidden'), jetzt: jetzt);
      expect(b.zustand, LeseZustand.gesendet);
      expect(b.ungesendet, isFalse);
      expect(b.fehlerCode, isNull);
    });
  });
}
