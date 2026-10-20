// Lokale Benachrichtigung über neue Chat-Nachrichten nach einem Push-Wecker: nie ein Inhalt (auch nicht bei altem Klartext), nur "Neue Nachricht in <Chat>";
// eigene, bearbeitete und alte Nachrichten lösen nichts aus; im Vordergrund zeigt die Oberfläche selbst; der Titel erscheint nur auf Wunsch auf dem Sperrbildschirm.
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';

const _ich = 'aaaaaaaa-0000-4000-8000-000000000001';
const _ben = 'bbbbbbbb-0000-4000-8000-000000000002';
const _cora = 'cccccccc-0000-4000-8000-000000000003';

class _Anzeige implements ChatAnzeigePort {
  bool erlaubt = true;
  int initialisiert = 0;
  final List<({int id, String titel, String text, bool sperre, int? anzahl})> gezeigt = [];
  final List<int> entfernt = [];

  @override
  Future<bool> initialisieren() async {
    initialisiert++;
    return erlaubt;
  }

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async {
    gezeigt.add((id: id, titel: titel, text: text, sperre: sperrbildschirmTitel, anzahl: anzahl));
    return true;
  }

  @override
  Future<void> entfernen(int id) async => entfernt.add(id);
}

void main() {
  late AppDatabase db;
  late _Anzeige anzeige;
  var vordergrund = false;
  var sperre = false;
  String? ich = _ich;

  ChatBenachrichtiger benachrichtiger() => ChatBenachrichtiger(
    db: db,
    anzeige: anzeige,
    ich: () async => ich,
    sperrbildschirmTitel: () async => sperre,
    istVordergrund: () => vordergrund,
  );

  Future<void> konv(String id, String art, {List<String> teilnehmer = const [], String titel = ''}) => db
      .into(db.konversationen)
      .insert(KonversationenCompanion.insert(id: id, art: art, createdAt: DateTime.utc(2026, 10, 19), teilnehmerJson: Value(jsonEncode(teilnehmer)), titel: Value(titel), rev: const Value(1)));

  Future<void> nachricht(String id, String konv, String autor, int rev, {String text = 'e1:AAAA', DateTime? bearbeitet}) => db.into(db.nachrichten).insert(
    NachrichtenCompanion.insert(id: id, konversationId: konv, inhalt: text, createdAt: DateTime.utc(2026, 10, 19, 9), autorId: Value(autor), bearbeitetAt: Value(bearbeitet), rev: Value(rev)),
  );

  setUp(() async {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    anzeige = _Anzeige();
    vordergrund = false;
    sperre = false;
    ich = _ich;
    await db.metaSchreiben(
      'members',
      jsonEncode([
        {'id': _ich, 'displayName': 'Anna', 'colorIndex': 0, 'role': 'admin', 'status': 'active'},
        {'id': _ben, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'},
        {'id': _cora, 'displayName': 'Cora', 'colorIndex': 2, 'role': 'parent', 'status': 'active'},
      ]),
    );
  });
  tearDown(() => db.close());

  test('neue Nachricht im Familienchat: "Neue Nachricht" in Familie, ohne Inhalt', () async {
    await konv('fam', 'family');
    await nachricht('n1', 'fam', _ben, 5, text: 'p1:GEHEIMER KLARTEXT');
    await benachrichtiger().neueEreignisse(5, vorher: 4);
    expect(anzeige.gezeigt, hasLength(1));
    final z = anzeige.gezeigt.single;
    expect([z.titel, z.text], ['Neue Nachricht', 'in Familie']);
    expect('${z.titel} ${z.text}', isNot(contains('GEHEIM')));
    expect(z.sperre, isFalse, reason: 'Standard: privat auf dem Sperrbildschirm');
  });

  test('mehrere Nachrichten im selben Chat ergeben eine Benachrichtigung ("3 neue Nachrichten"), je Chat eine eigene Kennung', () async {
    await konv('dm', 'direct', teilnehmer: [_ich, _ben]);
    await konv('g', 'group', teilnehmer: [_ich, _ben, _cora], titel: 'p1:Wochenende');
    for (var i = 0; i < 3; i++) {
      await nachricht('n$i', 'dm', _ben, 10 + i);
    }
    await nachricht('g1', 'g', _cora, 20);
    await benachrichtiger().neueEreignisse(20, vorher: 5);
    final nach = {for (final z in anzeige.gezeigt) z.text: z};
    expect(nach['in Ben']!.titel, '3 neue Nachrichten');
    expect(nach['in Wochenende']!.titel, 'Neue Nachricht');
    expect(nach['in Ben']!.id, isNot(nach['in Wochenende']!.id));
    expect(chatBenachrichtigungsId('dm'), chatBenachrichtigungsId('dm'));
    expect(chatBenachrichtigungsId('dm'), greaterThan(0x100000));
  });

  test('Zahl am App-Symbol: die Benachrichtigung trägt ALLE ungelesenen Nachrichten des Chats (auch ältere), der eigene Lesestand zieht ab', () async {
    await konv('dm', 'direct', teilnehmer: [_ich, _ben]);
    // zwei ältere ungelesene (aus früheren Abgleichen), eine neue; eine eigene zählt nie
    await nachricht('alt1', 'dm', _ben, 1);
    await nachricht('alt2', 'dm', _ben, 2);
    await nachricht('eigen', 'dm', _ich, 3);
    await nachricht('neu', 'dm', _ben, 9);
    await benachrichtiger().neueEreignisse(9, vorher: 8);
    expect(anzeige.gezeigt.single.titel, 'Neue Nachricht', reason: 'Titel zählt nur, was mit diesem Abgleich kam');
    expect(anzeige.gezeigt.single.anzahl, 3);
    // eigener Lesestand bis nach den älteren Nachrichten (alle um 09:00): nur noch die später entstandene zählt
    anzeige.gezeigt.clear();
    await db.into(db.lesestaende).insert(LesestaendeCompanion.insert(id: 'ls', konversationId: 'dm', userId: _ich, gelesenBis: DateTime.utc(2026, 10, 19, 9)));
    await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: 'spaeter', konversationId: 'dm', inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19, 10), autorId: const Value(_ben), rev: const Value(10)));
    await benachrichtiger().neueEreignisse(10, vorher: 9);
    expect(anzeige.gezeigt.single.anzahl, 1);
  });

  test('Gruppe ohne Namen und unbekannte Person: neutrale Bezeichnung statt Inhalt', () async {
    await konv('g', 'group', teilnehmer: [_ich, _ben, _cora]);
    await konv('dm2', 'direct', teilnehmer: [_ich, 'unbekannt-0000']);
    await nachricht('a', 'g', _ben, 5);
    await nachricht('b', 'dm2', 'unbekannt-0000', 6);
    await benachrichtiger().neueEreignisse(6, vorher: 0);
    expect(anzeige.gezeigt.map((z) => z.text).toSet(), {'in einer Gruppe', 'in einem Direktchat'});
  });

  test('eigene, bearbeitete, alte und neuere Nachrichten sowie Nachrichten ohne Absender lösen nichts aus', () async {
    await konv('fam', 'family');
    await nachricht('eigen', 'fam', _ich, 5);
    await nachricht('bearbeitet', 'fam', _ben, 6, bearbeitet: DateTime.utc(2026, 10, 19, 9, 5));
    await nachricht('alt', 'fam', _ben, 3);
    await nachricht('neuer', 'fam', _ben, 9);
    await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: 'ohne', konversationId: 'fam', inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19, 9), rev: const Value(7)));
    await benachrichtiger().neueEreignisse(8, vorher: 4);
    expect(anzeige.gezeigt, isEmpty);
  });

  test('im Vordergrund und ohne angemeldete Person gibt es nichts; ohne Erlaubnis ebenso', () async {
    await konv('fam', 'family');
    await nachricht('n1', 'fam', _ben, 5);
    vordergrund = true;
    await benachrichtiger().neueEreignisse(5, vorher: 4);
    expect(anzeige.initialisiert, 0);
    vordergrund = false;
    ich = null;
    await benachrichtiger().neueEreignisse(5, vorher: 4);
    ich = _ich;
    anzeige.erlaubt = false;
    await benachrichtiger().neueEreignisse(5, vorher: 4);
    expect(anzeige.gezeigt, isEmpty);
  });

  test('Titel auf dem Sperrbildschirm nur auf Wunsch (Einstellung der Erinnerungen)', () async {
    await konv('fam', 'family');
    await nachricht('n1', 'fam', _ben, 5);
    sperre = true;
    await benachrichtiger().neueEreignisse(5, vorher: 4);
    expect(anzeige.gezeigt.single.sperre, isTrue);
  });
}
