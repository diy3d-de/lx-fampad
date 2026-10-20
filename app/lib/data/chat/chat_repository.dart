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
import 'chat_krypto.dart';
import 'chat_krypto_state.dart';
import 'nachrichten_inhalt.dart';

/// Größte Nachricht in der Schnittstelle (UTF-16-Einheiten, wie auf dem Server).
const kMaxNachrichtWire = 16384;

/// Die Nachricht ist zu lang für den Server (die Oberfläche zeigt einen Hinweis).
class NachrichtZuLang implements Exception {
  const NachrichtZuLang();
}

/// In diesem Chat darf nicht geschrieben werden, weil er nicht Ende-zu-Ende verschlüsselt ist (Altbestand): die App sendet nie Klartext.
class ChatNichtVerschluesselt implements Exception {
  const ChatNichtVerschluesselt();
}

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

  /// Die Verschlüsselung dieser Person (null, solange kein Schlüssel bereit ist). Nötig, um Chats anzulegen und Mitglieder zu wechseln.
  final Future<ChatKrypto?> Function() krypto;

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
    required this.krypto,
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
  (SELECT n.id FROM nachrichten n WHERE n.konversation_id = k.id ORDER BY n.created_at DESC, CASE WHEN n.rev = 0 THEN 1 ELSE 0 END DESC, n.rev DESC, n.id DESC LIMIT 1) AS letzte_id,
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
            ..orderBy(_reihenfolge(aufsteigend: true)))
          .watch();

  /// Lesestände der Konversation (alle Teilnehmer; der Server liefert sie den Teilnehmern): Grundlage der Lesebestätigung an eigenen Nachrichten.
  Stream<List<Lesestand>> lesestaende(String konversationId) => (db.select(db.lesestaende)..where((l) => l.konversationId.equals(konversationId))).watch();

  /// Epochen der Konversation (nur die signierten Mitgliederlisten zählen: Empfänger der Nachrichten zum Sendezeitpunkt, Lesebestätigung).
  Stream<List<Epoche>> epochenListen(String konversationId) => (db.select(db.konversationEpochen)..where((e) => e.konversationId.equals(konversationId))).watch();

  /// Reihenfolge der Nachrichten: Zeit (Millisekunden), bei gleicher Zeit die Zustellreihenfolge des Servers (Revision; noch nicht bestätigte zuletzt), dann die ID.
  /// Eine eigene, noch nicht bestätigte Nachricht trägt die Zeit dieses Geräts und springt mit der Bestätigung an die Serverzeit.
  static List<OrderingTerm Function($NachrichtenTable)> _reihenfolge({required bool aufsteigend}) {
    final modus = aufsteigend ? OrderingMode.asc : OrderingMode.desc;
    return [
      (n) => OrderingTerm(expression: n.createdAt, mode: modus),
      (n) => OrderingTerm(expression: CustomExpression<int>('CASE WHEN rev = 0 THEN 1 ELSE 0 END'), mode: modus),
      (n) => OrderingTerm(expression: n.rev, mode: modus),
      (n) => OrderingTerm(expression: n.id, mode: modus),
    ];
  }

  /// Die jüngsten Nachrichten über alle sichtbaren Konversationen (Startseite).
  Stream<List<Nachricht>> juengste(int anzahl) =>
      (db.select(db.nachrichten)
            ..orderBy(_reihenfolge(aufsteigend: false))
            ..limit(anzahl))
          .watch();

  // ------------------------------------------------------------------ Senden, Bearbeiten, Löschen

  /// Neue Nachricht: sofort lokal, "wird gesendet" bis der Server sie bestätigt. Leere Nachrichten werden nicht gesendet (Rückgabe null). Im Ausgang liegt der
  /// Klartext (`l1:`); der Abgleich verschlüsselt ihn erst beim Senden mit der dann aktuellen Epoche (Ende-zu-Ende) und hält die Nachricht zurück, bis das geht.
  Future<String?> senden(String konversationId, String text, {String? antwortAuf}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    _laengePruefen(t);
    await _verschluesselterChat(konversationId);
    final id = _neueId();
    await store.aendern(
      'nachricht',
      id,
      {'konversationId': konversationId, 'text': '$kPraefixLokal$t', 'antwortAuf': ?antwortAuf},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'autorId': ich()},
    );
    beiAenderung();
    return id;
  }

  /// Geschrieben wird nur in verschlüsselten Chats (e1); ein Altbestand ohne Verschlüsselung bleibt lesbar, bekommt aber nichts Neues.
  Future<void> _verschluesselterChat(String konversationId) async {
    final k = await (db.select(db.konversationen)..where((t) => t.id.equals(konversationId))).getSingleOrNull();
    if (k == null || k.encVersion != 'e1') throw const ChatNichtVerschluesselt();
  }

  /// Länge wie auf dem Server und in der Hülle: höchstens ein paar tausend Zeichen UND [kMaxNachrichtBytes] Bytes (Emoji und Schrift mit mehr Bytes pro Zeichen
  /// würden die verschlüsselte Hülle sonst über die Obergrenze des Servers heben). Zu lang wird nie gesendet.
  static void _laengePruefen(String klartext) {
    if (klartext.length > kMaxNachrichtenZeichen * 2 || utf8.encode(klartext).length > kMaxNachrichtBytes) throw const NachrichtZuLang();
  }

  Future<void> bearbeiten(String nachrichtId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    _laengePruefen(t);
    final n = await (db.select(db.nachrichten)..where((x) => x.id.equals(nachrichtId))).getSingleOrNull();
    if (n == null) return;
    await _verschluesselterChat(n.konversationId);
    await store.aendern('nachricht', nachrichtId, {'text': '$kPraefixLokal$t'}, nurLokal: {'bearbeitetAt': zeitFuerServer(_jetzt())});
    beiAenderung();
  }

  Future<void> loeschen(String nachrichtId) async {
    await store.loeschen('nachricht', nachrichtId);
    beiAenderung();
  }

  // ------------------------------------------------------------------ Konversationen

  /// Der Chat braucht Verschlüsselung: ohne eingerichtete Schlüssel dieser Person geht nichts.
  Future<ChatKrypto> _kryptoPflicht() async {
    final k = await krypto();
    if (k == null) throw const VerschluesselungNichtBereit('Richte zuerst die Verschlüsselung ein (Profil, Verschlüsselung).');
    return k;
  }

  /// Legt den Familienchat an, falls es lokal keinen gibt (die erste App, die ihn nicht findet; feste ID, daher auch bei gleichzeitigem Anlegen
  /// auf mehreren Geräten nur einer). Erst nach einem erfolgreichen Abgleich aufrufen. Verschlüsselt (e1): die erste Epoche geht an alle aktiven Mitglieder, die ihre
  /// Verschlüsselung eingerichtet haben (die übrigen kommen mit einer neuen Epoche dazu, sobald sie so weit sind). Ohne eigenen Schlüssel passiert nichts.
  /// Liefert true, wenn es den Familienchat lokal gibt (schon vorher oder jetzt angelegt); false, wenn es noch nicht ging (kein Schlüssel bereit).
  Future<bool> familienchatSicherstellen() async {
    final fam = familie();
    if (fam == null) return false;
    final da = await (db.select(db.konversationen)..where((k) => k.art.equals(ChatArt.family.wire))).get();
    if (da.isNotEmpty) return true;
    final k = await krypto();
    if (k == null) return false;
    final id = familienchatId(fam);
    final alle = k.aktiveMitglieder();
    final epoche = await k.epocheErstellen(konversationId: id, mitglieder: alle, unvertrauteAuslassen: true);
    await store.aendernMehrere([
      SyncAenderung('konversation', id, {'art': ChatArt.family.wire, 'encVersion': 'e1'}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()}),
      ...epoche,
    ]);
    beiAenderung();
    return true;
  }

  /// Gibt es den Direktchat mit dieser Person schon (lokal)?
  Future<bool> direktChatVorhanden(String andere) async {
    final me = ich();
    if (me == null) return false;
    return await (db.select(db.konversationen)..where((k) => k.id.equals(direktChatId(me, andere)))).getSingleOrNull() != null;
  }

  /// Direktchat mit einer Person: den vorhandenen öffnen oder (mit fester ID je Paar) anlegen. Liefert die ID. Die andere Person braucht eine eingerichtete
  /// Verschlüsselung ([SchluesselFehlt] sonst).
  Future<String> direktChat(String andere) async {
    final me = ich();
    if (me == null) throw StateError('Nicht angemeldet');
    final id = direktChatId(me, andere);
    if (await (db.select(db.konversationen)..where((k) => k.id.equals(id))).getSingleOrNull() != null) return id;
    final k = await _kryptoPflicht();
    final epoche = await k.epocheErstellen(konversationId: id, mitglieder: {me, andere});
    await store.aendernMehrere([
      SyncAenderung(
        'konversation',
        id,
        {'art': ChatArt.direct.wire, 'encVersion': 'e1', 'teilnehmer': ([me, andere]..sort())},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
      ),
      ...epoche,
    ]);
    beiAenderung();
    return id;
  }

  /// Neue Gruppe aus mehreren Personen (die eigene kommt dazu); der Name ist optional (sichtbar für den Server, nur der Inhalt der Nachrichten ist verschlüsselt).
  /// Alle Teilnehmer brauchen eine eingerichtete Verschlüsselung ([SchluesselFehlt] sonst).
  Future<String> gruppeAnlegen(List<String> andere, {String name = ''}) async {
    final me = ich();
    if (me == null) throw StateError('Nicht angemeldet');
    final id = _neueId();
    final teilnehmer = {me, ...andere}.toList()..sort();
    final k = await _kryptoPflicht();
    final epoche = await k.epocheErstellen(konversationId: id, mitglieder: teilnehmer.toSet());
    await store.aendernMehrere([
      SyncAenderung(
        'konversation',
        id,
        {'art': ChatArt.group.wire, 'encVersion': 'e1', 'titel': inhalt.kodieren(name.trim()), 'teilnehmer': teilnehmer},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
      ),
      ...epoche,
    ]);
    beiAenderung();
    return id;
  }

  Future<void> gruppeUmbenennen(String id, String name) async {
    await store.aendern('konversation', id, {'titel': inhalt.kodieren(name.trim())});
    beiAenderung();
  }

  /// Teilnehmer ändern: ausgehend vom aktuellen Stand der Konversation (nicht von der Mitgliederliste) werden nur die genannten Personen hinzugefügt oder entfernt.
  /// Jeder Wechsel legt eine NEUE Epoche an (neuer Schlüssel nur für die Verbleibenden und Neuen: entfernte Personen lesen Neues nicht mehr). Mit [verlaufTeilen]
  /// bekommen die Neuen zusätzlich die Schlüssel der älteren Epochen (sonst sehen sie den bisherigen Verlauf nicht lesbar). Neue Personen brauchen eine eingerichtete
  /// Verschlüsselung ([SchluesselFehlt] sonst). Wer sich selbst entfernt, legt keine Epoche an (das tun die Verbleibenden).
  Future<void> teilnehmerAendern(String id, {Set<String> hinzu = const {}, Set<String> weg = const {}, bool verlaufTeilen = false}) async {
    final k = await (db.select(db.konversationen)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (k == null) return;
    final neu = {...teilnehmerIds(k), ...hinzu}..removeAll(weg);
    final sortiert = {...neu}.toList()..sort();
    final aenderungen = <SyncAenderung>[SyncAenderung('konversation', id, {'teilnehmer': sortiert})];
    final me = ich();
    if (k.encVersion == 'e1' && (me == null || neu.contains(me))) {
      final kr = await _kryptoPflicht();
      aenderungen.addAll(await kr.epocheErstellen(konversationId: id, mitglieder: neu, historieFuer: verlaufTeilen ? hinzu : const {}, unvertrauteAuslassen: weg.isNotEmpty && hinzu.isEmpty));
    }
    await store.aendernMehrere(aenderungen);
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
    final ms = z.read(neueste);
    if (ms == null) return;
    final bis = DateTime.fromMillisecondsSinceEpoch(ms);
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
    // nur für Gruppennamen (p1): das Repository darf sich nicht mit jeder entschlüsselten Nachricht neu aufbauen (sonst starten alle Datenbank-Streams neu)
    inhalt: const KlartextHuelle(),
    krypto: () => ref.read(chatKryptoProvider.notifier).krypto(),
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

final epochenListenProvider = StreamProvider.autoDispose.family<List<Epoche>, String>((ref, id) => ref.watch(chatRepositoryProvider).epochenListen(id));

/// Lesestände aller Teilnehmer einer Konversation (Lesebestätigung, siehe lese_status.dart).
final lesestaendeProvider = StreamProvider.autoDispose.family<List<Lesestand>, String>((ref, id) => ref.watch(chatRepositoryProvider).lesestaende(id));

final juengsteNachrichtenProvider = StreamProvider.autoDispose<List<Nachricht>>((ref) => ref.watch(chatRepositoryProvider).juengste(40));

/// Die im Desktop-Layout (Zwei-Spalten) gewählte Konversation.
class GewaehlterChat extends Notifier<String?> {
  @override
  String? build() => null;

  void waehlen(String? id) => state = id;
}

final gewaehlterChatProvider = NotifierProvider<GewaehlterChat, String?>(GewaehlterChat.new);
