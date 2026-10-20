// Der Hintergrund-Abgleich eines Push-Weckers (headless) baut keine Chat-Verschlüsselung auf: kein ChatKryptoController, kein Schlüsselbund. Klartext im Ausgang
// bleibt dort liegen (der Store sendet `l1:` nie) und geht erst beim nächsten Start der App hinaus.
import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_krypto_state.dart';
import 'package:lx_fampad/data/database_provider.dart';
import 'package:lx_fampad/data/push/push_hintergrund.dart';
import 'package:lx_fampad/data/sync_state.dart';

void main() {
  test('Hintergrund-Container: kein Vorbereiter, keine Chat-Krypto-Initialisierung', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    final c = hintergrundContainer(zusaetzlich: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(c.dispose);
    expect(c.read(opVorbereiterProvider), isNull);
    c.read(syncEngineProvider);
    final store = c.read(syncStoreProvider);
    await store.aendern('nachricht', 'n-1', {'konversationId': 'k', 'text': 'l1:geheim'}, nurLokal: {'createdAt': DateTime.utc(2026, 10, 19).toIso8601String()});
    expect(await store.naechsteOps(10), isEmpty, reason: 'Klartext geht nie hinaus');
    expect(c.exists(chatKryptoProvider), isFalse, reason: 'der Wecker baut keinen ChatKryptoController');
  });
}
