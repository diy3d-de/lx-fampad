// Lokale Benachrichtigung über neue Chat-Nachrichten nach einem Push-Wecker (Umsetzung von [EreignisBenachrichtiger]). Der Wecker selbst enthält nichts; nach dem
// Abgleich liegen die neuen Nachrichten verschlüsselt in der lokalen Datenbank. Die Benachrichtigung entsteht auf dem Gerät und enthält NIE einen Nachrichteninhalt
// (auch nicht aus alten Klartext-Chats), nur "Neue Nachricht in <Chat>" mit dem Namen des Chats. Auf dem Sperrbildschirm bleibt sie ohne Titel (privat), außer die
// Person schaltet "Titel auf dem Sperrbildschirm zeigen" ein (dieselbe Einstellung wie bei den Terminerinnerungen).
import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../chat/nachrichten_inhalt.dart';
import '../lists/members.dart';
import 'push_wecker.dart';

/// Schnittstelle zum Betriebssystem für Chat-Benachrichtigungen (Android: flutter_local_notifications; Web und Tests: ohne Wirkung bzw. Fake).
abstract class ChatAnzeigePort {
  /// Bereitet Kanal und Plugin vor. false: nicht verfügbar (Web) oder keine Erlaubnis.
  Future<bool> initialisieren();

  /// Zeigt (oder ersetzt) die Benachrichtigung mit der Kennung [id]. [sperrbildschirmTitel]: Titel und Text dürfen auf dem Sperrbildschirm erscheinen.
  /// [anzahl]: Zahl der ungelesenen Nachrichten dieses Chats (Android: `number` der Benachrichtigung, daraus zeigen manche Launcher, z. B. One UI, die Zahl am App-Symbol;
  /// sonst zählt Android die aktiven Benachrichtigungen als Punkt/Zahl).
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl});

  /// Sicherheitshinweis (Passwort-Reset): eigener Kanal "Sicherheit", hohe Wichtigkeit, nie der Chat-Kanal; ein Tipp öffnet Profil › Sicherheit › Sicherheitsereignisse (Nutzlast `sicherheit`).
  /// Nur feste Texte der App, nie Namen oder Einzelheiten. false: nicht angezeigt (keine Erlaubnis, Web), der Aufrufer behält dann seinen Stand.
  /// [nutzlast]: wohin ein Tipp führt (Standard `sicherheit`; der Betreiber-Hinweis nimmt `betrieb`).
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'});

  /// Entfernt die Benachrichtigung mit der Kennung [id] (der Chat wurde gelesen); eine nicht vorhandene ist kein Fehler.
  Future<void> entfernen(int id);
}

class KeineChatAnzeige implements ChatAnzeigePort {
  const KeineChatAnzeige();

  @override
  Future<bool> initialisieren() async => false;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async => false;

  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async => false;

  @override
  Future<void> entfernen(int id) async {}
}

/// Kennung der Benachrichtigung einer Konversation (stabil: eine neue Nachricht im selben Chat ersetzt die bisherige statt zu stapeln).
int chatBenachrichtigungsId(String konversationId) {
  var h = 17;
  for (final c in konversationId.codeUnits) {
    h = (h * 31 + c) & 0x3fffff;
  }
  return 0x100000 + h; // oberhalb der festen Kennungen der Erinnerungen
}

class ChatBenachrichtiger implements EreignisBenachrichtiger {
  final AppDatabase db;
  final ChatAnzeigePort anzeige;
  /// Die angemeldete Person (aus der lokalen Datenbank: auch ohne laufende Oberfläche, im Hintergrund-Start).
  final Future<String?> Function() ich;

  /// Darf der Titel auf dem Sperrbildschirm erscheinen (Einstellung der Erinnerungen)?
  final Future<bool> Function() sperrbildschirmTitel;

  /// Ist die App gerade im Vordergrund? Dann zeigt die Oberfläche selbst, was neu ist.
  final bool Function() istVordergrund;
  static const _namen = KlartextHuelle();

  ChatBenachrichtiger({required this.db, required this.anzeige, required this.ich, required this.sperrbildschirmTitel, required this.istVordergrund});

  @override
  Future<void> neueEreignisse(int rev, {required int vorher}) async {
    if (istVordergrund()) return;
    // vorher <= 0: der erste Abgleich (Neuinstallation, zurückgesetzter Sync-Fortschritt) bringt den ganzen Verlauf: das ist nichts Neues
    if (vorher <= 0) return;
    final me = await ich();
    if (me == null) return;
    // Nachrichten, die mit diesem Abgleich kamen (Revision zwischen vorher und rev), nicht von mir und nicht von einem entfernten Mitglied (ohne Absender)
    final neue =
        await (db.select(db.nachrichten)..where(
              (n) => n.rev.isBiggerThanValue(vorher) & n.rev.isSmallerOrEqualValue(rev) & n.autorId.isNotNull() & n.autorId.equals(me).not() & n.bearbeitetAt.isNull(),
            ))
            .get();
    if (neue.isEmpty) return;
    final nachKonv = <String, int>{};
    for (final n in neue) {
      nachKonv[n.konversationId] = (nachKonv[n.konversationId] ?? 0) + 1;
    }
    final konversationen = {for (final k in await db.select(db.konversationen).get()) k.id: k};
    final mitglieder = Mitglieder(mitgliederAusSpeicher(await db.metaLesen('members')));
    if (!await anzeige.initialisieren()) return;
    final sperre = await sperrbildschirmTitel();
    for (final e in nachKonv.entries) {
      final k = konversationen[e.key];
      if (k == null || k.art == 'meds' || k.art == 'zaehler' || k.art == 'tresor') continue; // die verborgenen Konversationen (Medikamente, Zähler, Tresor) melden nie etwas (sie haben keine Nachrichten)
      // nur, was der eigene Lesestand noch nicht abdeckt (auf einem anderen Gerät schon Gelesenes meldet nichts); Titel und Zahl am Symbol kommen aus derselben Zahl
      final ungelesen = await _ungelesen(e.key, me);
      if (ungelesen <= 0) continue;
      final name = _chatName(k, mitglieder, me);
      await anzeige.zeigen(
        id: chatBenachrichtigungsId(e.key),
        titel: ungelesen == 1 ? 'Neue Nachricht' : '$ungelesen neue Nachrichten',
        text: 'in $name',
        sperrbildschirmTitel: sperre,
        anzahl: ungelesen,
      );
    }
  }

  /// Ungelesene Nachrichten des Chats: fremde Nachrichten, die neuer sind als der eigene Lesestand (wie die Zähler in der App).
  Future<int> _ungelesen(String konversationId, String me) async {
    final z = await db.customSelect(
      'SELECT COUNT(*) AS n FROM nachrichten n WHERE n.konversation_id = ?1 AND (n.autor_id IS NULL OR n.autor_id <> ?2) '
      'AND n.created_at > COALESCE((SELECT l.gelesen_bis FROM lesestand l WHERE l.konversation_id = ?1 AND l.user_id = ?2 LIMIT 1), 0)',
      variables: [Variable.withString(konversationId), Variable.withString(me)],
    ).getSingle();
    return z.read<int>('n');
  }

  /// Name des Chats für die Benachrichtigung: "Familie", die andere Person (Direktchat) oder der Gruppenname (sichtbarer Name, nie ein Nachrichteninhalt).
  String _chatName(Konversation k, Mitglieder mitglieder, String me) {
    switch (k.art) {
      case 'family':
        return 'Familie';
      case 'direct':
        final teilnehmer = _teilnehmer(k);
        final andere = teilnehmer.where((t) => t != me).firstOrNull;
        return mitglieder[andere]?.displayName ?? 'einem Direktchat';
      default:
        final titel = _namen.dekodieren(k.titel);
        if (titel.lesbar && titel.text.trim().isNotEmpty) return titel.text.trim();
        return 'einer Gruppe';
    }
  }

  List<String> _teilnehmer(Konversation k) {
    try {
      final d = jsonDecode(k.teilnehmerJson);
      return d is List ? [for (final x in d) if (x is String) x] : const [];
    } catch (_) {
      return const [];
    }
  }
}
