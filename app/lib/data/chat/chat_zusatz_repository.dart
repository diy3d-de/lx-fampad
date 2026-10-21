// Reaktionen, Stimmen (Umfragen) und Pins für die Oberfläche: liest aus der lokalen Datenbank (Streams) und schreibt sofort lokal (Tabelle und Ausgang, über SyncStore).
// Reaktion und Stimme liegen im Ausgang als lokaler Klartext (`l1:` + `r1:`/`s1:`); der Abgleich verschlüsselt sie erst beim Senden (ChatOpVorbereiter) in die Hülle `e1:`.
// Der Server weiß nur, DASS eine Person auf eine Nachricht reagiert oder abgestimmt hat, nie womit. Rechte: siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6c.
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'chat_ids.dart';
import 'chat_krypto.dart';
import 'chat_repository.dart';
import 'chat_zusatz_inhalt.dart';

/// Höchstens so viele Nachrichten sind je Chat angeheftet (wie auf dem Server).
const kMaxPins = 5;

/// Es sind schon [kMaxPins] Nachrichten angeheftet.
class PinGrenze implements Exception {
  const PinGrenze();
}

class ChatZusatzRepository {
  final AppDatabase db;
  final SyncStore store;

  /// Angemeldete Person.
  final String? Function() ich;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;

  ChatZusatzRepository({required this.db, required this.store, required this.ich, required this.beiAenderung, DateTime Function()? jetzt}) : _jetzt = jetzt ?? DateTime.now;

  // ------------------------------------------------------------------ Lesen

  Stream<List<Reaktion>> reaktionen(String konversationId) => (db.select(db.reaktionen)..where((r) => r.konversationId.equals(konversationId))).watch();

  Stream<List<Stimme>> stimmen(String konversationId) => (db.select(db.stimmen)..where((r) => r.konversationId.equals(konversationId))).watch();

  /// Angeheftete Nachrichten, die zuletzt angehefteten zuerst.
  Stream<List<ChatPin>> pins(String konversationId) =>
      (db.select(db.pins)
            ..where((p) => p.konversationId.equals(konversationId))
            ..orderBy([(p) => OrderingTerm.desc(p.createdAt), (p) => OrderingTerm.desc(p.id)]))
          .watch();

  // ------------------------------------------------------------------ Schreiben

  /// Reaktionen, Stimmen und Pins gibt es nur in verschlüsselten Chats; eine unbekannte oder nicht verschlüsselte Konversation ergibt [ChatNichtVerschluesselt].
  Future<void> _verschluesselterChat(String konversationId) async {
    final k = await (db.select(db.konversationen)..where((t) => t.id.equals(konversationId))).getSingleOrNull();
    if (k == null || k.encVersion != 'e1') throw const ChatNichtVerschluesselt();
  }

  /// Setzt die eigene Reaktion auf die Nachricht (ersetzt eine frühere: je Person eine). Nur auf gesendete Nachrichten (der Server kennt die Nachricht sonst nicht).
  Future<void> reagieren(String konversationId, String nachrichtId, String emoji) async {
    final me = ich();
    if (me == null || reaktionLesen(reaktionKodieren(emoji)) == null) return;
    await _verschluesselterChat(konversationId);
    final id = reaktionId(nachrichtId, me);
    final inhalt = '$kPraefixLokal${reaktionKodieren(emoji)}';
    final da = await (db.select(db.reaktionen)..where((r) => r.id.equals(id))).getSingleOrNull();
    await store.aendern(
      'reaktion',
      id,
      da == null ? {'konversationId': konversationId, 'nachrichtId': nachrichtId, 'userId': me, 'inhalt': inhalt} : {'inhalt': inhalt},
      nurLokal: da == null ? {'createdAt': zeitFuerServer(_jetzt())} : const {},
    );
    beiAenderung();
  }

  /// Nimmt die eigene Reaktion zurück.
  Future<void> reaktionEntfernen(String nachrichtId) async {
    final me = ich();
    if (me == null) return;
    await store.loeschen('reaktion', reaktionId(nachrichtId, me));
    beiAenderung();
  }

  /// Gibt die eigene Stimme ab oder ändert sie; eine leere Auswahl nimmt sie zurück. Ob die Umfrage noch läuft, prüft die Oberfläche (der Server kennt das Ende nicht;
  /// Stimmen nach dem Ende zählt jede App nicht mit).
  Future<void> abstimmen(String konversationId, String nachrichtId, Set<int> auswahl) async {
    final me = ich();
    if (me == null) return;
    final id = stimmeId(nachrichtId, me);
    if (auswahl.isEmpty) {
      await store.loeschen('stimme', id);
      beiAenderung();
      return;
    }
    await _verschluesselterChat(konversationId);
    final inhalt = '$kPraefixLokal${stimmeKodieren(auswahl)}';
    final da = await (db.select(db.stimmen)..where((r) => r.id.equals(id))).getSingleOrNull();
    final jetzt = zeitFuerServer(_jetzt());
    await store.aendern(
      'stimme',
      id,
      da == null ? {'konversationId': konversationId, 'nachrichtId': nachrichtId, 'userId': me, 'inhalt': inhalt} : {'inhalt': inhalt},
      nurLokal: da == null ? {'createdAt': jetzt} : {'geaendertAt': jetzt},
    );
    beiAenderung();
  }

  /// Heftet die Nachricht an (oben im Chat). Mehr als [kMaxPins] gehen nicht ([PinGrenze]).
  Future<void> pinnen(String konversationId, String nachrichtId) async {
    final me = ich();
    if (me == null) return;
    await _verschluesselterChat(konversationId);
    final id = pinId(nachrichtId);
    if (await (db.select(db.pins)..where((p) => p.id.equals(id))).getSingleOrNull() != null) return;
    final anzahl = await (db.select(db.pins)..where((p) => p.konversationId.equals(konversationId))).get();
    if (anzahl.length >= kMaxPins) throw const PinGrenze();
    await store.aendern('pin', id, {'konversationId': konversationId, 'nachrichtId': nachrichtId}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'gepinntVon': me});
    beiAenderung();
  }

  Future<void> pinLoesen(String nachrichtId) async {
    await store.loeschen('pin', pinId(nachrichtId));
    beiAenderung();
  }
}

final chatZusatzRepositoryProvider = Provider<ChatZusatzRepository>((ref) {
  return ChatZusatzRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});

final reaktionenProvider = StreamProvider.autoDispose.family<List<Reaktion>, String>((ref, id) => ref.watch(chatZusatzRepositoryProvider).reaktionen(id));

final stimmenProvider = StreamProvider.autoDispose.family<List<Stimme>, String>((ref, id) => ref.watch(chatZusatzRepositoryProvider).stimmen(id));

final pinsProvider = StreamProvider.autoDispose.family<List<ChatPin>, String>((ref, id) => ref.watch(chatZusatzRepositoryProvider).pins(id));
