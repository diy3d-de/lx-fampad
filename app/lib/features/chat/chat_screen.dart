// Chat: Konversationsliste (Familienchat oben, Direktchats, Gruppen) und Nachrichtenansicht. Schmal: Liste, Tippen öffnet den Verlauf als eigene
// Seite. Breit (Desktop-Layout): zwei Spalten, Liste links, Verlauf rechts. Alles liest und schreibt die lokale Datenbank (offline-first).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../shell/shell_tab.dart';
import 'chat_anzeige.dart';
import 'chat_verlauf.dart';
import 'personen_wahl.dart';

/// Ab dieser Breite des Bereichs stehen Liste und Verlauf nebeneinander.
const kChatZweiSpaltenBreite = 640.0;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  bool _familienchatGeprueft = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _familienchatPruefen() : null);
  }

  /// Den Familienchat legt die erste App an, in der jemand den Chat-Bereich öffnet und die nach einem erfolgreichen Abgleich keinen findet
  /// (feste ID, der Server lässt nur einen zu). Vorher passiert nichts: die anderen Bereiche lösen keine Änderungen aus.
  void _familienchatPruefen() {
    if (_familienchatGeprueft || ref.read(syncProvider).letzterAbgleich == null || ref.read(shellTabProvider) != kChatTab) return;
    final liste = ref.read(chatUebersichtProvider).value;
    if (liste == null) return;
    _familienchatGeprueft = true;
    if (liste.any((e) => e.art == ChatArt.family)) return;
    unawaited(ref.read(chatRepositoryProvider).familienchatSicherstellen());
  }

  Future<void> _neuerChat(bool zweiSpalten) async {
    final repo = ref.read(chatRepositoryProvider);
    final gewaehlt = ref.read(gewaehlterChatProvider.notifier);
    final navigator = Navigator.of(context);
    final wahl = await navigator.push<PersonenAuswahl>(MaterialPageRoute(builder: (_) => const PersonenWahlSeite(modus: PersonenWahlModus.neuerChat)));
    if (wahl == null || !mounted) return;
    final id = wahl.personen.length == 1 ? await repo.direktChat(wahl.personen.first) : await repo.gruppeAnlegen(wahl.personen.toList(), name: wahl.name);
    if (!mounted) return;
    if (zweiSpalten) {
      gewaehlt.waehlen(id);
    } else {
      _oeffnen(id);
    }
  }

  void _oeffnen(String id) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (c) => Scaffold(
          backgroundColor: kBg,
          body: LxBackground(
            child: SafeArea(child: LxContentWidth(child: ChatVerlauf(konversationId: id, beiSchliessen: () => Navigator.of(c).pop()))),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatUebersichtProvider, (_, _) => _familienchatPruefen());
    ref.listen(syncProvider.select((s) => s.letzterAbgleich), (_, _) => _familienchatPruefen());
    ref.listen(shellTabProvider, (_, _) => _familienchatPruefen());
    return LayoutBuilder(
      builder: (context, c) {
        final zweiSpalten = c.maxWidth >= kChatZweiSpaltenBreite;
        final liste = _Liste(
          zweiSpalten: zweiSpalten,
          onNeu: () => _neuerChat(zweiSpalten),
          onOeffnen: (id) {
            if (zweiSpalten) {
              ref.read(gewaehlterChatProvider.notifier).waehlen(id);
            } else {
              _oeffnen(id);
            }
          },
        );
        if (!zweiSpalten) return liste;
        final gewaehlt = ref.watch(gewaehlterChatProvider);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: c.maxWidth >= 900 ? 340 : 280, child: liste),
            const VerticalDivider(width: 1, color: kBorderSoft),
            Expanded(
              child: gewaehlt == null
                  ? const EmptyState(icon: Icons.forum_outlined, title: 'Wähle einen Chat', hint: 'Oder starte links einen neuen Chat.')
                  : ChatVerlauf(key: ValueKey(gewaehlt), konversationId: gewaehlt, zurueckPfeil: false, beiSchliessen: () => ref.read(gewaehlterChatProvider.notifier).waehlen(null)),
            ),
          ],
        );
      },
    );
  }
}

class _Liste extends ConsumerWidget {
  final bool zweiSpalten;
  final VoidCallback onNeu;
  final void Function(String id) onOeffnen;
  const _Liste({required this.zweiSpalten, required this.onNeu, required this.onOeffnen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(chatUebersichtProvider);
    final eintraege = async.value ?? const <ChatEintrag>[];
    final mitglieder = chatMitglieder(ref, eintraege);
    final ich = ref.watch(authProvider.select((s) => s.user?.id));
    final inhalt = ref.watch(nachrichtenInhaltProvider);
    final gewaehlt = zweiSpalten ? ref.watch(gewaehlterChatProvider) : null;
    final direkt = [for (final e in eintraege) if (e.art == ChatArt.direct) e];
    final gruppen = [for (final e in eintraege) if (e.art == ChatArt.group) e];
    final familie = [for (final e in eintraege) if (e.art == ChatArt.family) e];

    Widget kachel(ChatEintrag e) {
      final name = chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt);
      final anderer = e.art == ChatArt.direct ? mitglieder[e.teilnehmer.where((t) => t != ich).firstOrNull] : null;
      return _Kachel(
        eintrag: e,
        name: name,
        vorschau: chatVorschau(e, mitglieder, ich, inhalt),
        person: anderer,
        gewaehlt: e.id == gewaehlt,
        onTap: () => onOeffnen(e.id),
      );
    }

    Widget abschnitt(String titel, List<ChatEintrag> l) => l.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 4), child: Semantics(header: true, child: MonoLabel(titel))),
              for (final e in l) kachel(e),
            ],
          );

    final Widget inhaltsbereich = async.hasError
        ? const EmptyState(icon: Icons.error_outline, title: 'Chats nicht geladen', hint: 'Die lokalen Daten konnten nicht gelesen werden.')
        : !async.hasValue
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : eintraege.isEmpty
        ? const EmptyState(icon: Icons.chat_bubble_outline, title: 'Noch keine Chats', hint: 'Der Familienchat erscheint nach dem ersten Abgleich. Starte unten einen neuen Chat.')
        : ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [abschnitt('familie', familie), abschnitt('direkt', direkt), abschnitt('gruppen', gruppen)],
          );

    return Stack(
      children: [
        Column(
          children: [
            const Padding(padding: EdgeInsets.fromLTRB(20, 16, 20, 4), child: TabKopfzeile(title: 'Chat')),
            Expanded(child: inhaltsbereich),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onNeu,
            icon: const Icon(Icons.edit_outlined, size: 20),
            label: const Text('Neuer Chat'),
          ),
        ),
      ],
    );
  }
}

class _Kachel extends StatelessWidget {
  final ChatEintrag eintrag;
  final String name;
  final String vorschau;
  final UserDto? person;
  final bool gewaehlt;
  final VoidCallback onTap;
  const _Kachel({required this.eintrag, required this.name, required this.vorschau, required this.person, required this.gewaehlt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ungelesen = eintrag.ungelesen;
    final zeit = eintrag.letzte == null ? '' : zeitKurz(eintrag.letzte!.createdAt);
    return Semantics(
      button: true,
      selected: gewaehlt,
      label: 'Chat mit $name${ungelesen > 0 ? ', $ungelesen ungelesen' : ''}${zeit.isEmpty ? '' : ', $zeit'}. $vorschau',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: gewaehlt ? kAccentSoft : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  ChatAvatar(art: eintrag.art, person: person, name: name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: ungelesen > 0 ? FontWeight.w800 : FontWeight.w600, color: kTextStrong)),
                        const SizedBox(height: 2),
                        Text(vorschau, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: ungelesen > 0 ? kText : kTextMuted, fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (zeit.isNotEmpty) Text(zeit, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                      if (ungelesen > 0) ...[const SizedBox(height: 4), UngelesenZeichen(ungelesen)],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
