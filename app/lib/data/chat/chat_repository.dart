// Chat für die Oberfläche: liest aus der lokalen Datenbank (Streams) und schreibt Änderungen sofort lokal (Tabelle und Ausgang, über
// SyncStore). Nichts wartet auf das Netz; der Abgleich läuft im Hintergrund (data/sync/). Inhalte laufen über NachrichtenInhalt.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'chat_ids.dart';
import 'nachrichten_inhalt.dart';

/// Art einer Konversation.
enum ChatArt {
  family('family'),
  direct('direct'),
  group('group');

  final String wire;
  const ChatArt(this.wire);

  static ChatArt von(String wire) => values.firstWhere((a) => a.wire == wire, orElse: () => ChatArt.group);
}

/// Teilnehmer-IDs einer Konversation (beim Familienchat leer: alle Mitglieder).
List<String> teilnehmerIds(Konversation k) {
  try {
    final d = jsonDecode(k.teilnehmerJson);
    return d is List ? [for (final x in d) if (x is String) x] : const [];
  } catch (_) {
    return const [];
  }
}

extension KonversationArt on Konversation {
  ChatArt get chatArt => ChatArt.von(art);
}

/// Zeile der Konversationsliste: Konversation, letzte Nachricht und Anzahl ungelesener.
class ChatEintrag {
  final Konversation konversation;
  final List<String> teilnehmer;
  final Nachricht? letzte;
  final int ungelesen;
  const ChatEintrag({required this.konversation, required this.teilnehmer, required this.letzte, required this.ungelesen});

  String get id => konversation.id;
  ChatArt get art => konversation.chatArt;

  /// Zeitpunkt der letzten Aktivität (letzte Nachricht, sonst Anlegen).
  DateTime get aktivitaet => letzte?.createdAt ?? konversation.createdAt;
}

/// Reihenfolge der Liste: Familienchat oben, dann Direktchats, dann Gruppen, jeweils die jüngste Aktivität zuerst.
List<ChatEintrag> sortiereChats(Iterable<ChatEintrag> alle) {
  int rang(ChatEintrag e) => switch (e.art) {
    ChatArt.family => 0,
    ChatArt.direct => 1,
    ChatArt.group => 2,
  };
  final liste = alle.toList()
    ..sort((a, b) {
      final r = rang(a).compareTo(rang(b));
      if (r != 0) return r;
      final t = b.aktivitaet.compareTo(a.aktivitaet);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  return liste;
}

class ChatRepository {
  final AppDatabase db;
  final SyncStore store;
  final NachrichtenInhalt inhalt;

  /// Angemeldete Person und ihre Familie (Besitzer neuer Nachrichten, solange der Server es noch nicht bestätigt hat).
  final String? Function() ich;
  final String? Function() familie;

  /// Wird nach jeder lokalen Änderung aufgerufen (stößt den entprellten Abgleich an).
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  ChatRepository({
    required this.db,
    required this.store,
    required this.inhalt,
    required this.ich,
    required this.familie,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  // ------------------------------------------------------------------ Lesen

  /// Konversationsliste mit letzter Nachricht und Ungelesen-Zähler (sortiert, siehe [sortiereChats]).
  Stream<List<ChatEintrag>> uebersicht(String me) {
    const sql = '''
SELECT k.id AS kid,
  (SELECT n.id FROM nachrichten n WHERE n.konversation_id = k.id ORDER BY n.created_at DESC, n.id DESC LIMIT 1) AS letzte_id,
  (SELECT COUNT(*) FROM nachrichten n WHERE n.konversation_id = k.id AND (n.autor_id IS NULL OR n.autor_id <> ?1)
     AND n.created_at > COALESCE((SELECT l.gelesen_bis FROM lesestand l WHERE l.konversation_id = k.id AND l.user_id = ?1 LIMIT 1), 0)) AS ungelesen
FROM konversationen k''';
    return db
        .customSelect(sql, variables: [Variable.withString(me)], readsFrom: {db.konversationen, db.nachrichten, db.lesestaende})
        .watch()
        .asyncMap((zeilen) async {
          final konv = {for (final k in await db.select(db.konversationen).get()) k.id: k};
          final letzteIds = [for (final z in zeilen) if (z.read<String?>('letzte_id') != null) z.read<String>('letzte_id')];
          final letzte = letzteIds.isEmpty
              ? <String, Nachricht>{}
              : {for (final n in await (db.select(db.nachrichten)..where((t) => t.id.isIn(letzteIds))).get()) n.id: n};
          return sortiereChats([
            for (final z in zeilen)
              if (konv[z.read<String>('kid')] case final k?)
                ChatEintrag(
                  konversation: k,
                  teilnehmer: teilnehmerIds(k),
                  letzte: letzte[z.read<String?>('letzte_id')],
                  ungelesen: z.read<int>('ungelesen'),
                ),
          ]);
        });
  }

  /// Alle ungelesenen Nachrichten (für das Zeichen am Chat-Tab).
  Stream<int> ungelesenGesamt(String me) {
    const sql = '''
SELECT COUNT(*) AS n FROM nachrichten n
WHERE (n.autor_id IS NULL OR n.autor_id <> ?1)
  AND n.created_at > COALESCE((SELECT l.gelesen_bis FROM lesestand l WHERE l.konversation_id = n.konversation_id AND l.user_id = ?1 LIMIT 1), 0)''';
    return db
        .customSelect(sql, variables: [Variable.withString(me)], readsFrom: {db.nachrichten, db.lesestaende})
        .watchSingle()
        .map((z) => z.read<int>('n'));
  }

  Stream<Konversation?> konversation(String id) => (db.select(db.konversationen)..where((k) => k.id.equals(id))).watchSingleOrNull();

  /// Nachrichten einer Konversation, älteste zuerst.
  Stream<List<Nachricht>> nachrichten(String konversationId) =>
      (db.select(db.nachrichten)
            ..where((n) => n.konversationId.equals(konversationId))
            ..orderBy([(n) => OrderingTerm.asc(n.createdAt), (n) => OrderingTerm.asc(n.id)]))
          .watch();

  /// Die jüngsten Nachrichten über alle sichtbaren Konversationen (Startseite).
  Stream<List<Nachricht>> juengste(int anzahl) =>
      (db.select(db.nachrichten)
            ..orderBy([(n) => OrderingTerm.desc(n.createdAt), (n) => OrderingTerm.desc(n.id)])
            ..limit(anzahl))
          .watch();

  // ------------------------------------------------------------------ Senden, Bearbeiten, Löschen

  /// Neue Nachricht: sofort lokal, "wird gesendet" bis der Server sie bestätigt. Leere Nachrichten werden nicht gesendet (Rückgabe null).
  Future<String?> senden(String konversationId, String text, {String? antwortAuf}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    final id = _neueId();
    await store.aendern(
      'nachricht',
      id,
      {'konversationId': konversationId, 'text': inhalt.kodieren(t), 'antwortAuf': ?antwortAuf},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'autorId': ich()},
    );
    beiAenderung();
    return id;
  }

  Future<void> bearbeiten(String nachrichtId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await store.aendern('nachricht', nachrichtId, {'text': inhalt.kodieren(t)}, nurLokal: {'bearbeitetAt': zeitFuerServer(_jetzt())});
    beiAenderung();
  }

  Future<void> loeschen(String nachrichtId) async {
    await store.loeschen('nachricht', nachrichtId);
    beiAenderung();
  }

  // ------------------------------------------------------------------ Konversationen

  /// Legt den Familienchat an, falls es lokal keinen gibt (die erste App, die ihn nicht findet; feste ID, daher auch bei gleichzeitigem Anlegen
  /// auf mehreren Geräten nur einer). Erst nach einem erfolgreichen Abgleich aufrufen.
  Future<void> familienchatSicherstellen() async {
    final fam = familie();
    if (fam == null) return;
    final da = await (db.select(db.konversationen)..where((k) => k.art.equals(ChatArt.family.wire))).get();
    if (da.isNotEmpty) return;
    await store.aendern('konversation', familienchatId(fam), {'art': ChatArt.family.wire}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()});
    beiAenderung();
  }

  /// Direktchat mit einer Person: den vorhandenen öffnen oder (mit fester ID je Paar) anlegen. Liefert die ID.
  Future<String> direktChat(String andere) async {
    final me = ich();
    if (me == null) throw StateError('Nicht angemeldet');
    final id = direktChatId(me, andere);
    if (await (db.select(db.konversationen)..where((k) => k.id.equals(id))).getSingleOrNull() != null) return id;
    await store.aendern(
      'konversation',
      id,
      {'art': ChatArt.direct.wire, 'teilnehmer': ([me, andere]..sort())},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
    );
    beiAenderung();
    return id;
  }

  /// Neue Gruppe aus mehreren Personen (die eigene kommt dazu); der Name ist optional.
  Future<String> gruppeAnlegen(List<String> andere, {String name = ''}) async {
    final me = ich();
    if (me == null) throw StateError('Nicht angemeldet');
    final id = _neueId();
    final teilnehmer = {me, ...andere}.toList()..sort();
    await store.aendern(
      'konversation',
      id,
      {'art': ChatArt.group.wire, 'titel': inhalt.kodieren(name.trim()), 'teilnehmer': teilnehmer},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
    );
    beiAenderung();
    return id;
  }

  Future<void> gruppeUmbenennen(String id, String name) async {
    await store.aendern('konversation', id, {'titel': inhalt.kodieren(name.trim())});
    beiAenderung();
  }

  Future<void> teilnehmerSetzen(String id, List<String> teilnehmer) async {
    await store.aendern('konversation', id, {'teilnehmer': ({...teilnehmer}.toList()..sort())});
    beiAenderung();
  }

  Future<void> gruppeLoeschen(String id) async {
    await store.loeschen('konversation', id);
    beiAenderung();
  }

  // ------------------------------------------------------------------ Lesestand

  /// Setzt den Lesestand auf die neueste fremde Nachricht der Konversation (nur vorwärts, nur wenn es etwas Neues gibt).
  Future<void> gelesenSetzen(String konversationId) async {
    final me = ich();
    if (me == null) return;
    final neueste = db.nachrichten.createdAt.max();
    final z =
        await (db.selectOnly(db.nachrichten)
              ..addColumns([neueste])
              ..where(db.nachrichten.konversationId.equals(konversationId) & (db.nachrichten.autorId.isNull() | db.nachrichten.autorId.equals(me).not())))
            .getSingle();
    final bis = z.read(neueste);
    if (bis == null) return;
    final id = lesestandId(konversationId, me);
    final aktuell = await (db.select(db.lesestaende)..where((l) => l.id.equals(id))).getSingleOrNull();
    if (aktuell != null && !bis.isAfter(aktuell.gelesenBis)) return;
    await store.aendern('lesestand', id, {'konversationId': konversationId, 'userId': me, 'gelesenBis': zeitFuerServer(bis)});
    beiAenderung();
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    inhalt: ref.watch(nachrichtenInhaltProvider),
    ich: () => ref.read(authProvider).user?.id,
    familie: () => ref.read(authProvider).me?.familyId,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});

/// Konversationsliste der angemeldeten Person (leer ohne Anmeldung).
final chatUebersichtProvider = StreamProvider<List<ChatEintrag>>((ref) {
  final me = ref.watch(authProvider.select((s) => s.user?.id));
  if (me == null) return Stream.value(const []);
  return ref.watch(chatRepositoryProvider).uebersicht(me);
});

/// Anzahl ungelesener Nachrichten insgesamt (Zeichen am Chat-Tab).
final chatUngelesenProvider = StreamProvider<int>((ref) {
  final me = ref.watch(authProvider.select((s) => s.user?.id));
  if (me == null) return Stream.value(0);
  return ref.watch(chatRepositoryProvider).ungelesenGesamt(me);
});

final konversationProvider = StreamProvider.autoDispose.family<Konversation?, String>((ref, id) => ref.watch(chatRepositoryProvider).konversation(id));

final nachrichtenProvider = StreamProvider.autoDispose.family<List<Nachricht>, String>((ref, id) => ref.watch(chatRepositoryProvider).nachrichten(id));

final juengsteNachrichtenProvider = StreamProvider.autoDispose<List<Nachricht>>((ref) => ref.watch(chatRepositoryProvider).juengste(40));

/// Die im Desktop-Layout (Zwei-Spalten) gewählte Konversation.
class GewaehlterChat extends Notifier<String?> {
  @override
  String? build() => null;

  void waehlen(String? id) => state = id;
}

final gewaehlterChatProvider = NotifierProvider<GewaehlterChat, String?>(GewaehlterChat.new);
