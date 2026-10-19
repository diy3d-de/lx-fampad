// Chat-Repository: Senden/Bearbeiten/Löschen offline-first, feste IDs, Direkt- und Gruppenchats, Lesestand, Ungelesen-Zähler, Reihenfolge der
// Liste, Kaskade beim Verschwinden einer Konversation und die Inhaltshülle. Reine Datenbank-Tests, kein Netz.
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/chat/nachrichten_inhalt.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

const _ich = 'aaaaaaaa-0000-4000-8000-000000000001';
const _ben = 'bbbbbbbb-0000-4000-8000-000000000002';
const _cora = 'cccccccc-0000-4000-8000-000000000003';
const _fam = 'ffffffff-0000-4000-8000-00000000000f';

SyncResult antwort({int rev = 1, List<String> acked = const [], List<SyncChange> changes = const []}) => SyncResult(
  resyncNoetig: false,
  rev: rev,
  acked: acked,
  rejected: const [],
  conflicts: const [],
  changes: changes,
  hasMore: false,
  next: 0,
  snapshotRev: null,
  serverTime: null,
);

SyncChange aenderung(String entity, String id, Map<String, dynamic> fields, int rev) =>
    SyncChange(rev: rev, entity: entity, id: id, tombstone: false, hidden: false, fields: fields);

String zeit(int sekunden) => DateTime.utc(2026, 10, 19, 8, 0, sekunden).toIso8601String();

void main() {
  late AppDatabase db;
  late SyncStore store;
  late ChatRepository repo;
  var ops = 0;
  var ids = 0;
  var geaendert = 0;
  var jetzt = DateTime.utc(2026, 10, 19, 9);

  setUp(() {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    ops = 0;
    ids = 0;
    geaendert = 0;
    jetzt = DateTime.utc(2026, 10, 19, 9);
    store = SyncStore(db, opId: () => 'op-${++ops}');
    repo = ChatRepository(
      db: db,
      store: store,
      inhalt: const KlartextHuelle(),
      ich: () => _ich,
      familie: () => _fam,
      beiAenderung: () => geaendert++,
      jetzt: () => jetzt,
      neueId: () => '00000000-0000-4000-8000-${(++ids).toString().padLeft(12, '0')}',
    );
  });
  tearDown(() => db.close());

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<List<Nachricht>> nachrichten() => db.select(db.nachrichten).get();

  Future<void> vomServer(List<SyncChange> changes) => store.uebernehmen(antwort(changes: changes), const []);

  Map<String, dynamic> konvJson(String art, {List<String> teilnehmer = const [], String titel = ''}) => {
    'art': art,
    'titel': titel,
    'teilnehmer': teilnehmer,
    'ownerId': _ich,
    'createdAt': zeit(0),
  };

  Map<String, dynamic> nachrichtJson(String konv, String text, {String? autor, int sek = 10, String? antwort}) => {
    'konversationId': konv,
    'text': 'p1:$text',
    'antwortAuf': antwort,
    'autorId': autor ?? _ben,
    'bearbeitetAt': null,
    'createdAt': zeit(sek),
  };

  group('Inhaltshülle', () {
    const huelle = KlartextHuelle();

    test('Klartext bekommt das Präfix p1: und kommt unverändert zurück (auch Emoji, Zeilenumbrüche, Links)', () {
      const text = 'Hallo 👋\nhttps://example.org <b>x</b>';
      expect(huelle.kodieren(text), 'p1:$text');
      final d = huelle.dekodieren(huelle.kodieren(text));
      expect(d.text, text);
      expect(d.status, InhaltStatus.bereit);
      expect(huelle.kodieren(''), '');
      expect(huelle.dekodieren('').status, InhaltStatus.bereit);
    });

    test('verschlüsselte oder unbekannte Hüllen sind "nicht entschlüsselbar", nie als Text sichtbar', () {
      for (final wire in ['e1:QUJD', 'x9:foo', 'ohne Präfix']) {
        final d = huelle.dekodieren(wire);
        expect(d.status, InhaltStatus.nichtEntschluesselbar, reason: wire);
        expect(d.text, '');
        expect(d.lesbar, isFalse);
      }
    });
  });

  group('feste IDs', () {
    test('Direktchat-ID hängt nicht von der Reihenfolge ab, andere Paare ergeben andere IDs', () {
      expect(direktChatId(_ich, _ben), direktChatId(_ben, _ich));
      expect(direktChatId(_ich, _ben), isNot(direktChatId(_ich, _cora)));
      expect(direktChatId(_ich, _ben), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('Familienchat- und Lesestand-ID sind stabil und verschieden', () {
      expect(familienchatId(_fam), familienchatId(_fam));
      expect(lesestandId('k1', _ich), lesestandId('K1', _ich.toUpperCase()));
      expect(lesestandId('k1', _ich), isNot(lesestandId('k1', _ben)));
      expect(lesestandId('k1', _ich), isNot(lesestandId('k2', _ich)));
    });
  });

  group('Senden, Bearbeiten, Löschen', () {
    test('senden schreibt sofort lokal ("wird gesendet" = rev 0) und stellt die Op mit der Hülle in den Ausgang', () async {
      await vomServer([aenderung('konversation', 'k1', konvJson('family'), 1)]);
      final id = await repo.senden('k1', '  Hallo Welt  ', antwortAuf: 'q1');
      expect(id, isNotNull);
      final n = (await nachrichten()).single;
      expect(n.rev, 0);
      expect(n.autorId, _ich);
      expect(n.inhalt, 'p1:Hallo Welt');
      expect(n.createdAt.toUtc(), DateTime.utc(2026, 10, 19, 9));
      final op = (await ausgang()).single;
      expect(op.entity, 'nachricht');
      expect(op.baseRev, 0);
      expect(jsonDecode(op.fieldsJson), {'konversationId': 'k1', 'text': 'p1:Hallo Welt', 'antwortAuf': 'q1'});
      expect(geaendert, 1);
    });

    test('leere Nachrichten werden nicht gesendet', () async {
      expect(await repo.senden('k1', '   \n '), isNull);
      expect(await nachrichten(), isEmpty);
      expect(await ausgang(), isEmpty);
    });

    test('Bestätigung des Servers: die Nachricht bekommt Revision und Serverzeit, der Ausgang ist leer', () async {
      await vomServer([aenderung('konversation', 'k1', konvJson('family'), 1)]);
      final id = (await repo.senden('k1', 'Hi'))!;
      await store.uebernehmen(
        antwort(rev: 2, acked: ['op-1'], changes: [aenderung('nachricht', id, nachrichtJson('k1', 'Hi', autor: _ich, sek: 20), 2)]),
        await ausgang(),
      );
      final n = (await nachrichten()).single;
      expect(n.rev, 2);
      expect(n.createdAt.toUtc(), DateTime.utc(2026, 10, 19, 8, 0, 20));
      expect(await ausgang(), isEmpty);
    });

    test('bearbeiten ändert nur den Text (Hülle) und setzt lokal die Zeit; löschen entfernt lokal und merkt die Löschung vor', () async {
      await vomServer([aenderung('konversation', 'k1', konvJson('family'), 1), aenderung('nachricht', 'n1', nachrichtJson('k1', 'alt', autor: _ich), 2)]);
      await repo.bearbeiten('n1', ' neu ');
      var n = (await nachrichten()).single;
      expect(n.inhalt, 'p1:neu');
      expect(n.bearbeitetAt, isNotNull);
      final op = (await ausgang()).single;
      expect(op.baseRev, 2);
      expect(jsonDecode(op.fieldsJson), {'text': 'p1:neu'});
      await repo.loeschen('n1');
      expect(await nachrichten(), isEmpty);
      expect((await ausgang()).last.op, 'delete');
    });

    test('eine Nachricht, die der Server nie sah, verschwindet beim Löschen spurlos', () async {
      await vomServer([aenderung('konversation', 'k1', konvJson('family'), 1)]);
      final id = (await repo.senden('k1', 'Oops'))!;
      await repo.loeschen(id);
      expect(await nachrichten(), isEmpty);
      expect(await ausgang(), isEmpty);
    });
  });

  group('Konversationen', () {
    test('Familienchat wird nur einmal angelegt (feste ID) und nur ohne vorhandenen', () async {
      await repo.familienchatSicherstellen();
      await repo.familienchatSicherstellen();
      final k = (await db.select(db.konversationen).get()).single;
      expect(k.id, familienchatId(_fam));
      expect(k.art, 'family');
      expect((await ausgang()), hasLength(1));
      expect(jsonDecode((await ausgang()).single.fieldsJson), {'art': 'family'});
    });

    test('Familienchat vom Server verhindert das Anlegen', () async {
      await vomServer([aenderung('konversation', 'irgendeine', konvJson('family'), 1)]);
      await repo.familienchatSicherstellen();
      expect(await ausgang(), isEmpty);
    });

    test('Direktchat: feste ID je Paar, Teilnehmer sortiert, zweiter Aufruf legt nichts neu an', () async {
      final id = await repo.direktChat(_ben);
      expect(id, direktChatId(_ich, _ben));
      expect(await repo.direktChat(_ben), id);
      final k = (await db.select(db.konversationen).get()).single;
      expect(teilnehmerIds(k), [_ich, _ben]..sort());
      expect(await ausgang(), hasLength(1));
      expect(jsonDecode((await ausgang()).single.fieldsJson), {'art': 'direct', 'teilnehmer': [_ich, _ben]..sort()});
    });

    test('Gruppe: die eigene Person kommt dazu, Name als Hülle, Teilnehmer sortiert und ohne Doppelte', () async {
      final id = await repo.gruppeAnlegen([_cora, _ben, _ben], name: ' Oma-Geburtstag ');
      final k = (await db.select(db.konversationen).get()).single;
      expect(k.id, id);
      expect(k.titel, 'p1:Oma-Geburtstag');
      expect(teilnehmerIds(k), [_ich, _ben, _cora]..sort());
      final ohneName = await repo.gruppeAnlegen([_ben, _cora]);
      expect((await (db.select(db.konversationen)..where((t) => t.id.equals(ohneName))).getSingle()).titel, '');
      await repo.gruppeUmbenennen(id, 'Neu');
      await repo.teilnehmerSetzen(id, [_ich, _cora]);
      final g = await (db.select(db.konversationen)..where((t) => t.id.equals(id))).getSingle();
      expect(g.titel, 'p1:Neu');
      expect(teilnehmerIds(g), [_ich, _cora]..sort());
    });

    test('Verliert die Person die Sicht (hidden-Tombstone), verschwinden Konversation, Nachrichten und Lesestand samt offenen Ops', () async {
      await vomServer([
        aenderung('konversation', 'g1', konvJson('group', teilnehmer: [_ich, _ben, _cora]), 1),
        aenderung('nachricht', 'n1', nachrichtJson('g1', 'Hi'), 2),
        aenderung('lesestand', 'l1', {'konversationId': 'g1', 'userId': _ich, 'gelesenBis': zeit(10), 'createdAt': zeit(10)}, 3),
      ]);
      await repo.senden('g1', 'unterwegs');
      expect(await ausgang(), isNotEmpty);
      await store.uebernehmen(
        antwort(rev: 4, changes: const [SyncChange(rev: 4, entity: 'konversation', id: 'g1', tombstone: true, hidden: true, fields: {})]),
        const [],
      );
      expect(await db.select(db.konversationen).get(), isEmpty);
      expect(await nachrichten(), isEmpty);
      expect(await db.select(db.lesestaende).get(), isEmpty);
      expect(await ausgang(), isEmpty);
    });
  });

  group('Lesestand und Ungelesen', () {
    Future<void> grundstand() => vomServer([
      aenderung('konversation', 'fam', konvJson('family'), 1),
      aenderung('konversation', 'dm', konvJson('direct', teilnehmer: [_ich, _ben]..sort()), 2),
      aenderung('konversation', 'g1', konvJson('group', teilnehmer: [_ich, _ben, _cora]..sort(), titel: 'p1:Ausflug'), 3),
      aenderung('nachricht', 'n1', nachrichtJson('fam', 'Moin', sek: 10), 4),
      aenderung('nachricht', 'n2', nachrichtJson('fam', 'Eigene', autor: _ich, sek: 11), 5),
      aenderung('nachricht', 'n3', nachrichtJson('dm', 'Hast du Zeit?', sek: 12), 6),
      aenderung('nachricht', 'n4', nachrichtJson('dm', 'Noch da?', sek: 13), 7),
    ]);

    test('Ungelesen zählt fremde Nachrichten nach dem Lesestand, eigene nie; Liste: Familie, Direkt, Gruppen', () async {
      await grundstand();
      final liste = await repo.uebersicht(_ich).first;
      expect([for (final e in liste) e.id], ['fam', 'dm', 'g1']);
      expect({for (final e in liste) e.id: e.ungelesen}, {'fam': 1, 'dm': 2, 'g1': 0});
      expect(liste[1].letzte?.id, 'n4');
      expect(liste[2].letzte, isNull);
      expect(await repo.ungelesenGesamt(_ich).first, 3);
      // eine andere Person sieht ihre eigene Zählung (hier: alles von _ich fremd)
      expect(await repo.ungelesenGesamt(_ben).first, 1);
    });

    test('gelesenSetzen: Lesestand auf die neueste fremde Nachricht, nur vorwärts, nichts bei Unverändertem', () async {
      await grundstand();
      await repo.gelesenSetzen('dm');
      var op = (await ausgang()).single;
      expect(op.entity, 'lesestand');
      final felder = jsonDecode(op.fieldsJson) as Map<String, dynamic>;
      expect(felder['konversationId'], 'dm');
      expect(felder['userId'], _ich);
      expect(DateTime.parse(felder['gelesenBis'] as String), DateTime.utc(2026, 10, 19, 8, 0, 13));
      final zeile = (await db.select(db.lesestaende).get()).single;
      expect(zeile.id, lesestandId('dm', _ich));
      expect((await repo.uebersicht(_ich).first).firstWhere((e) => e.id == 'dm').ungelesen, 0);
      expect(await repo.ungelesenGesamt(_ich).first, 1);

      // zweiter Aufruf ohne neue Nachricht: keine neue Op
      await repo.gelesenSetzen('dm');
      expect(await ausgang(), hasLength(1));
      // nur eigene Nachrichten in der Familie: der Lesestand folgt der fremden (Moin), nicht der eigenen
      await repo.gelesenSetzen('fam');
      final fam = (await db.select(db.lesestaende).get()).firstWhere((l) => l.konversationId == 'fam');
      expect(fam.gelesenBis.toUtc(), DateTime.utc(2026, 10, 19, 8, 0, 10));
      // neue fremde Nachricht -> wieder ungelesen, erneutes Setzen ändert die vorhandene Zeile (Update statt zweiter Anlage)
      await vomServer([aenderung('nachricht', 'n5', nachrichtJson('dm', 'Hallo?', sek: 30), 8)]);
      expect(await repo.ungelesenGesamt(_ich).first, 1);
      await repo.gelesenSetzen('dm');
      expect(await db.select(db.lesestaende).get(), hasLength(2));
      expect(await repo.ungelesenGesamt(_ich).first, 0);
    });

    test('ohne fremde Nachrichten gibt es keinen Lesestand', () async {
      await vomServer([aenderung('konversation', 'fam', konvJson('family'), 1), aenderung('nachricht', 'n2', nachrichtJson('fam', 'Eigene', autor: _ich), 2)]);
      await repo.gelesenSetzen('fam');
      expect(await ausgang(), isEmpty);
    });
  });

  group('Anzeige-Zustände', () {
    test('nachrichten-Strom ist nach Zeit sortiert, juengste liefert die neuesten zuerst', () async {
      await vomServer([
        aenderung('konversation', 'fam', konvJson('family'), 1),
        aenderung('nachricht', 'n2', nachrichtJson('fam', 'zweite', sek: 20), 3),
        aenderung('nachricht', 'n1', nachrichtJson('fam', 'erste', sek: 10), 2),
      ]);
      expect([for (final n in await repo.nachrichten('fam').first) n.id], ['n1', 'n2']);
      expect([for (final n in await repo.juengste(5).first) n.id], ['n2', 'n1']);
    });
  });
}
