// Chat-Benachrichtigungen werden geräumt, sobald der Chat gelesen ist (Punkt/Zahl am App-Symbol verschwinden); beim ersten Stand der Liste werden gelesene Chats geräumt.
import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/push/chat_benachrichtigung_raeumen.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger_provider.dart';

class _Anzeige implements ChatAnzeigePort {
  final List<int> entfernt = [];
  @override
  Future<bool> initialisieren() async => true;
  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async => true;
  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async => false;
  @override
  Future<void> entfernen(int id) async => entfernt.add(id);
}

void main() {
  late AppDatabase db;
  late Konversation k1;
  late Konversation k2;

  setUp(() async {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    for (final id in ['k1', 'k2']) {
      await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: id, art: 'group', createdAt: DateTime.utc(2026, 10, 19)));
    }
    k1 = await (db.select(db.konversationen)..where((k) => k.id.equals('k1'))).getSingle();
    k2 = await (db.select(db.konversationen)..where((k) => k.id.equals('k2'))).getSingle();
  });
  tearDown(() => db.close());

  ChatEintrag e(Konversation k, int ungelesen) => ChatEintrag(konversation: k, teilnehmer: const [], letzte: null, ungelesen: ungelesen);

  test('erster Stand: gelesene Chats werden geräumt, ungelesene nicht; später nur beim Übergang auf 0', () async {
    final anzeige = _Anzeige();
    final quelle = StreamController<List<ChatEintrag>>();
    addTearDown(quelle.close);
    final c = ProviderContainer(overrides: [chatAnzeigePortProvider.overrideWithValue(anzeige), chatUebersichtProvider.overrideWith((ref) => quelle.stream)]);
    addTearDown(c.dispose);
    c.listen(chatBenachrichtigungenRaeumenProvider, (_, _) {});
    c.listen(chatUebersichtProvider, (_, _) {});
    quelle.add([e(k1, 0), e(k2, 3)]);
    await Future<void>.delayed(Duration.zero);
    expect(anzeige.entfernt, [chatBenachrichtigungsId('k1')]);
    // k2 wird gelesen: geräumt; k1 bleibt bei 0: nicht noch einmal
    quelle.add([e(k1, 0), e(k2, 0)]);
    await Future<void>.delayed(Duration.zero);
    expect(anzeige.entfernt, [chatBenachrichtigungsId('k1'), chatBenachrichtigungsId('k2')]);
    // neue Nachricht, wieder gelesen: erneut geräumt
    quelle.add([e(k1, 2), e(k2, 0)]);
    await Future<void>.delayed(Duration.zero);
    quelle.add([e(k1, 0), e(k2, 0)]);
    await Future<void>.delayed(Duration.zero);
    expect(anzeige.entfernt.where((i) => i == chatBenachrichtigungsId('k1')), hasLength(2));
  });
}
