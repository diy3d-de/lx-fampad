// Anzeige-Hilfen des Chats: Namen, Vorschau, Zeitangaben, Avatare, Ungelesen-Zeichen, Rechte der Oberfläche.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/lese_status.dart';
import '../../data/chat/chat_zusatz_inhalt.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/lists/members.dart';
import '../../widgets/benutzer_avatar.dart';

/// Name der Konversation: "Familie", die andere Person (Direktchat) oder der Gruppenname, sonst die Namen der Mitglieder ("Anna, Ben +2").
String chatName(Konversation k, List<String> teilnehmer, Mitglieder mitglieder, String? ich, NachrichtenInhalt inhalt) {
  switch (k.chatArt) {
    case ChatArt.family:
      return 'Familie';
    case ChatArt.direct:
      final andere = teilnehmer.where((t) => t != ich);
      return mitglieder[andere.firstOrNull]?.displayName ?? 'Unbekannt';
    case ChatArt.group:
      final titel = inhalt.dekodieren(k.titel);
      if (titel.lesbar && titel.text.trim().isNotEmpty) return titel.text;
      final namen = [for (final t in teilnehmer.where((t) => t != ich)) mitglieder[t]?.displayName.split(RegExp(r'\s+')).first ?? 'Unbekannt'];
      if (namen.isEmpty) return 'Gruppe';
      return namen.length <= 3 ? namen.join(', ') : '${namen.take(2).join(', ')} +${namen.length - 2}';
    case ChatArt.meds:
      return 'Medikamente'; // nie in der Chatliste, nur als Rückfall
    case ChatArt.zaehler:
      return 'Zähler'; // nie in der Chatliste, nur als Rückfall
    case ChatArt.tresor:
      return 'Tresor'; // nie in der Chatliste, nur als Rückfall
  }
}

/// Kurzer Text einer Nachricht für Listen und Zitate (eine Zeile, ohne Inhalt bei nicht lesbaren Nachrichten).
String nachrichtKurztext(Nachricht n, NachrichtenInhalt inhalt) {
  final d = inhalt.nachricht(n);
  return switch (d.status) {
    InhaltStatus.bereit => switch (umfrageLesen(d.text)) {
      final u? => umfrageKurztext(u),
      null => d.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
    },
    InhaltStatus.wirdEntschluesselt => 'wird entschlüsselt …',
    InhaltStatus.nichtEntschluesselbar => 'Nachricht nicht lesbar',
  };
}

/// Vorschau in der Konversationsliste, bei Gruppen und im Familienchat mit dem Namen des Absenders.
String chatVorschau(ChatEintrag e, Mitglieder mitglieder, String? ich, NachrichtenInhalt inhalt) {
  final n = e.letzte;
  if (n == null) return 'Noch keine Nachrichten';
  final text = nachrichtKurztext(n, inhalt);
  if (n.autorId != null && n.autorId == ich) return 'Du: $text';
  if (e.art == ChatArt.direct) return text;
  final autor = mitglieder[n.autorId]?.displayName.split(RegExp(r'\s+')).first;
  return autor == null ? text : '$autor: $text';
}

DateTime _tag(DateTime t) => DateTime(t.year, t.month, t.day);

/// Zeitangabe der Liste: heute die Uhrzeit, gestern "gestern", diese Woche der Wochentag, sonst das Datum.
String zeitKurz(DateTime t, [DateTime? jetzt]) {
  final j = jetzt ?? DateTime.now();
  final tage = _tag(j).difference(_tag(t)).inDays;
  if (tage <= 0) return DateFormat('HH:mm', 'de_DE').format(t);
  if (tage == 1) return 'gestern';
  if (tage < 7) return DateFormat('E', 'de_DE').format(t);
  return DateFormat('dd.MM.yy', 'de_DE').format(t);
}

/// Datumstrenner im Verlauf ("Heute", "Gestern", "Mo., 19. Oktober").
String datumTrenner(DateTime t, [DateTime? jetzt]) {
  final j = jetzt ?? DateTime.now();
  final tage = _tag(j).difference(_tag(t)).inDays;
  if (tage == 0) return 'Heute';
  if (tage == 1) return 'Gestern';
  return DateFormat(t.year == j.year ? 'E, d. MMMM' : 'd. MMMM y', 'de_DE').format(t);
}

bool gleicherTag(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Uhrzeit einer Nachricht.
String uhrzeit(DateTime t) => DateFormat('HH:mm', 'de_DE').format(t);

/// Text der Lesebestätigung (Tooltip und Screenreader): "wird gesendet", "gesendet", "gelesen" bzw. in Gruppen, wer gelesen hat.
String leseBeschreibung(LeseInfo i, String Function(String id) name) {
  final basis = _leseBasis(i, name);
  return i.geschaetzt && !i.ungesendet ? '$basis (Empfänger nur geschätzt)' : basis;
}

String _leseBasis(LeseInfo i, String Function(String id) name) {
  switch (i.zustand) {
    case LeseZustand.wartet:
      return 'wartet auf das Senden';
    case LeseZustand.wirdGesendet:
      return 'wird gesendet';
    case LeseZustand.haengt:
      return 'wartet auf Verbindung oder Schlüssel';
    case LeseZustand.abgelehnt:
      return 'Senden fehlgeschlagen: ${ablehnungsGrund(i.fehlerCode)}';
    case LeseZustand.gelesen:
      return i.empfaenger.length <= 1 ? 'gelesen' : 'gelesen von allen: ${(i.gelesenVon.toList()..sort()).map(name).join(', ')}';
    case LeseZustand.gesendet:
      if (i.gelesenVon.isEmpty) return 'gesendet';
      return 'gesendet, gelesen von ${i.gelesenVon.map(name).join(', ')} (${i.gelesenVon.length} von ${i.empfaenger.length})';
  }
}

/// Haken an einer eigenen Nachricht: Uhr (wird gesendet), ein Haken (beim Server angekommen), zwei Haken in der Akzentfarbe (alle haben gelesen).
class LeseHaken extends StatelessWidget {
  final LeseInfo info;
  final String text;
  const LeseHaken({super.key, required this.info, required this.text});

  @override
  Widget build(BuildContext context) {
    final (icon, farbe) = switch (info.zustand) {
      LeseZustand.wartet || LeseZustand.wirdGesendet => (Icons.schedule, kTextFaint),
      LeseZustand.haengt => (Icons.schedule, kWarn),
      LeseZustand.abgelehnt => (Icons.error_outline, kDanger),
      LeseZustand.gesendet => (Icons.check, kTextFaint),
      LeseZustand.gelesen => (Icons.done_all, kAccent),
    };
    return Tooltip(message: text, child: Icon(icon, size: 15, color: farbe, semanticLabel: text));
  }
}

/// Avatar einer Konversation: Person (Direktchat) in der Personenfarbe, Gruppe und Familie als Symbol.
class ChatAvatar extends StatelessWidget {
  final ChatArt art;
  final UserDto? person;
  final String name;
  final double size;
  const ChatAvatar({super.key, required this.art, required this.person, required this.name, this.size = 44});

  @override
  Widget build(BuildContext context) {
    if (art == ChatArt.direct) return BenutzerAvatar(user: person, ersatzName: name, size: size);
    final farbe = art == ChatArt.family ? kAccent : kNeural;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: farbe.withValues(alpha: 0.16), border: Border.all(color: farbe.withValues(alpha: 0.55))),
        child: Icon(art == ChatArt.family ? Icons.home_outlined : Icons.groups_outlined, size: size * 0.5, color: farbe),
      ),
    );
  }
}

/// Zähler ungelesener Nachrichten (Kapsel in Akzentfarbe); bei 0 nichts.
class UngelesenZeichen extends StatelessWidget {
  final int anzahl;
  const UngelesenZeichen(this.anzahl, {super.key});

  @override
  Widget build(BuildContext context) {
    if (anzahl <= 0) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: Container(
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(999)),
        child: Text(anzahl > 99 ? '99+' : '$anzahl', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, fontWeight: FontWeight.w700, color: kOnAccent)),
      ),
    );
  }
}

/// Was die Oberfläche der angemeldeten Person im Chat anbietet. Spiegelt sync/entities/chat.ts; maßgeblich ist immer der Server.
class ChatRechte {
  final Role rolle;
  final String? userId;
  const ChatRechte(this.rolle, this.userId);

  bool eigene(Nachricht n) => userId != null && n.autorId == userId;

  /// Bearbeiten nur eigene Nachrichten.
  bool darfBearbeiten(Nachricht n) => eigene(n);

  /// Löschen: eigene Nachrichten; Admins zusätzlich fremde im Familienchat (nie in privaten Chats).
  bool darfLoeschen(Nachricht n, ChatArt art) => eigene(n) || (rolle == Role.admin && art == ChatArt.family);

  /// Anheften: in privaten Chats jede Person, im Familienchat nur Eltern und Admins (Kinder sehen die Anheftungen).
  bool darfPinnen(ChatArt art) => art != ChatArt.family || rolle != Role.child;

  /// Lösen: Eltern und Admins jede Anheftung, Kinder nur ihre eigene.
  bool darfPinLoesen(ChatPin p) => rolle != Role.child || (userId != null && p.gepinntVon == userId);

  /// Gruppe löschen darf, wer sie angelegt hat; Name und Teilnehmer ändern alle Teilnehmer.
  bool darfGruppeLoeschen(Konversation k) => k.chatArt == ChatArt.group && userId != null && k.ownerId == userId;
}

/// Mitglieder für Namen in der Liste. Solange es nichts anzuzeigen gibt (kein Chat außer einem leeren Familienchat), wird die Liste nicht geladen:
/// die Anmeldung der Startseite löst so keine zusätzliche Abfrage der Mitglieder aus.
Mitglieder chatMitglieder(WidgetRef ref, List<ChatEintrag> eintraege) =>
    Mitglieder(eintraege.any((e) => e.letzte != null || e.art != ChatArt.family) ? (ref.watch(mitgliederProvider).value ?? const []) : const []);
