// Oberfläche zu "Verlauf freigeben" (PR 7): die Frage im Chat, wenn eine Person einen neuen Schlüssel hat und ihr älterer Verlauf noch unlesbar ist. Texte duzen, sagen
// nie "E2EE". Logik und Regeln: data/chat/chat_krypto.dart (verlaufAngebote, verlaufFreigeben), Zustand: data/chat/chat_krypto_state.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/chat/chat_krypto.dart';
import '../../data/chat/chat_krypto_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/sicherheitscode.dart';
import '../../ui/widgets.dart';

/// Frage im Chat, wenn eine Person einen neuen Schlüssel hat (Reset, Schlüsselwechsel), den dieses Gerät schon aufgenommen hat, und älterer Verlauf für sie noch
/// unlesbar ist: "Ja, das ist X – Verlauf freigeben". Die Freigabe geschieht nie von selbst: sonst könnte jemand, der ein Konto zurücksetzt und einen eigenen Schlüssel
/// einsetzt, den alten Verlauf mitlesen. Der Tipp zeigt den Sicherheitscode der Person und sagt, wann man ihn nicht tippen soll.
class VerlaufFreigabeHinweis extends ConsumerWidget {
  final String konversationId;
  const VerlaufFreigabeHinweis({super.key, required this.konversationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatKryptoProvider);
    final angebote = [for (final a in ref.read(chatKryptoProvider.notifier).verlaufAngebote) if (a.epochen.containsKey(konversationId)) a];
    if (angebote.isEmpty) return const SizedBox.shrink();
    final e = ref.watch(e2eeProvider);
    String name(String id) => e.mitglieder.where((m) => m.id == id).firstOrNull?.displayName ?? 'Eine Person';
    return Column(
      children: [
        for (final a in angebote)
          Semantics(
            container: true,
            liveRegion: true,
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
              decoration: BoxDecoration(color: kSurface, border: Border.all(color: kWarn.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.history_toggle_off, size: 20, color: kWarn)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${name(a.userId)} hat einen neuen Schlüssel und kann ältere Nachrichten nicht lesen. Du kannst den Verlauf freigeben, wenn du sicher bist, dass das wirklich ${name(a.userId)} ist.',
                          style: const TextStyle(fontSize: 13, height: 1.35, color: kText),
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                          onPressed: () => ref.read(chatKryptoProvider.notifier).verlaufSpaeter(a.userId),
                          child: const Text('Später'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                          onPressed: () => _freigeben(context, ref, a, name(a.userId)),
                          child: const Text('Prüfen und freigeben'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _freigeben(BuildContext context, WidgetRef ref, VerlaufAngebot a, String name) async {
    final e = ref.read(e2eeProvider);
    final schluessel = e.mitglieder.where((m) => m.id == a.userId).firstOrNull?.schluessel;
    final code = schluessel == null ? '–' : personenSicherheitscode(MitgliedSchluessel(a.userId, schluessel));
    final ok = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kSurface,
        scrollable: true,
        title: Text('Verlauf für $name freigeben?'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$name hat einen neuen Schlüssel. Wer den Verlauf bekommt, kann ältere Nachrichten lesen: ${a.anzahl} Schlüssel aus '
              '${a.chats} ${a.chats == 1 ? 'Chat' : 'Chats'}, in denen ihr beide wart.',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 12),
            const MonoLabel('// sicherheitscode'),
            const SizedBox(height: 6),
            Semantics(
              label: 'Sicherheitscode von $name: $code',
              child: SelectableText(code, style: const TextStyle(fontFamily: kFontMono, fontSize: 15, height: 1.5, color: kAccent)),
            ),
            const SizedBox(height: 8),
            Text(
              'Vergleiche den Code mit $name, zum Beispiel am Telefon. Gib den Verlauf nur frei, wenn du sicher bist, dass das wirklich $name ist. Im Zweifel: nicht freigeben und später fragen.',
              style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text('Ja, das ist $name – Verlauf freigeben')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final geklappt = await ref.read(chatKryptoProvider.notifier).verlaufFreigeben(a.userId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(geklappt ? 'Verlauf für $name freigegeben.' : 'Das geht gerade nicht. Versuche es gleich noch einmal.')),
    );
  }
}
