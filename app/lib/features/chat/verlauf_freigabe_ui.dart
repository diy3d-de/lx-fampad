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

/// "28.10.2026, 14:05" (lokale Zeit).
String freigabeZeit(DateTime t) {
  final l = t.toLocal();
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(l.day)}.${z(l.month)}.${l.year}, ${z(l.hour)}:${z(l.minute)}';
}

/// Frage im Chat, wenn eine Person einen neuen Schlüssel hat (Reset, Schlüsselwechsel), den dieses Gerät schon aufgenommen hat, und älterer Verlauf für sie noch
/// unlesbar ist: "Ja, das ist X – Verlauf freigeben". Die Freigabe geschieht nie von selbst: sonst könnte jemand, der ein Konto zurücksetzt und einen eigenen Schlüssel
/// einsetzt, den alten Verlauf mitlesen. Der Tipp zeigt den Sicherheitscode der Person und sagt, wann man ihn nicht tippen soll. Wurde der Zugang der Person vor kurzem
/// zurückgesetzt (Hinweis an die Familie), gilt eine Wartefrist von 24 Stunden ab dem Hinweis; danach geht es nur mit Sicherheitscode-Vergleich und getipptem Namen.
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
    final jetzt = DateTime.now();
    return Column(
      children: [
        for (final a in angebote)
          Builder(
            builder: (context) {
              final frist = a.fruehestens;
              final gesperrt = frist != null && jetzt.isBefore(frist);
              final streng = a.zuruecksetzung != null;
              final wer = name(a.userId);
              return Semantics(
                container: true,
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
                  decoration: BoxDecoration(color: kSurface, border: Border.all(color: (streng ? kDanger : kWarn).withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(streng ? Icons.warning_amber_rounded : Icons.history_toggle_off, size: 20, color: streng ? kDanger : kWarn)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              gesperrt
                                  ? 'Der Zugang von $wer wurde vor kurzem zurückgesetzt. Sprich mit $wer, bevor du etwas freigibst. Der alte Verlauf lässt sich frühestens ab ${freigabeZeit(frist)} freigeben.'
                                  : streng
                                  ? '$wer hat einen neuen Schlüssel, und der Zugang wurde zurückgesetzt. Gib den Verlauf nur frei, wenn du sicher bist, dass das wirklich $wer ist.'
                                  : '$wer hat einen neuen Schlüssel und kann ältere Nachrichten nicht lesen. Du kannst den Verlauf freigeben, wenn du sicher bist, dass das wirklich $wer ist.',
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
                              onPressed: gesperrt ? null : () => _freigeben(context, ref, a, wer),
                              child: Text(gesperrt ? 'Noch gesperrt' : 'Prüfen und freigeben'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Future<void> _freigeben(BuildContext context, WidgetRef ref, VerlaufAngebot a, String name) async {
    // der Code stammt aus genau dem Schlüssel, für den die Wraps entstehen
    final code = personenSicherheitscode(MitgliedSchluessel(a.userId, a.schluessel));
    final ok = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (_) => _FreigabeDialog(name: name, code: code, anzahl: a.anzahl, chats: a.chats, namenTippen: a.zuruecksetzung != null),
    );
    if (ok != true || !context.mounted) return;
    final r = await ref.read(chatKryptoProvider.notifier).verlaufFreigeben(a.userId);
    if (!context.mounted) return;
    final text = r == null
        ? 'Das geht gerade nicht. Versuche es gleich noch einmal.'
        : r.rest > 0
        ? '${r.gesendet} Schlüssel werden gesendet, ${r.rest} folgen. Tippe in einer Minute noch einmal auf „Prüfen und freigeben“.'
        : 'Der Verlauf für $name wird gesendet.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _FreigabeDialog extends StatefulWidget {
  final String name;
  final String code;
  final int anzahl;
  final int chats;
  final bool namenTippen;
  const _FreigabeDialog({required this.name, required this.code, required this.anzahl, required this.chats, required this.namenTippen});

  @override
  State<_FreigabeDialog> createState() => _FreigabeDialogState();
}

class _FreigabeDialogState extends State<_FreigabeDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _bereit => !widget.namenTippen || _name.text.trim().toLowerCase() == widget.name.trim().toLowerCase();

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    return AlertDialog(
      backgroundColor: kSurface,
      scrollable: true,
      title: Text('Verlauf für $name freigeben?'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$name hat einen neuen Schlüssel. Wer den Verlauf bekommt, kann ältere Nachrichten lesen: ${widget.anzahl} Schlüssel aus '
            '${widget.chats} ${widget.chats == 1 ? 'Chat' : 'Chats'}, in denen ihr beide wart. Pro Tipp werden höchstens $kMaxFreigabeWraps Schlüssel gesendet; bei mehr tippst du später noch einmal.',
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 12),
          const MonoLabel('// sicherheitscode'),
          const SizedBox(height: 6),
          Semantics(
            label: 'Sicherheitscode von $name: ${widget.code}',
            child: SelectableText(widget.code, style: const TextStyle(fontFamily: kFontMono, fontSize: 15, height: 1.5, color: kAccent)),
          ),
          const SizedBox(height: 8),
          Text(
            'Vergleiche den Code mit $name, zum Beispiel am Telefon. Gib den Verlauf nur frei, wenn du sicher bist, dass das wirklich $name ist. Im Zweifel: nicht freigeben und später fragen.',
            style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
          ),
          if (widget.namenTippen) ...[
            const SizedBox(height: 12),
            Text(
              'Der Zugang von $name wurde zurückgesetzt. Tippe zur Bestätigung den Namen „$name“ ein, nachdem ihr den Code verglichen habt.',
              style: const TextStyle(fontSize: 13, height: 1.4, color: kText),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'Name', hintText: name),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
        FilledButton(onPressed: _bereit ? () => Navigator.of(context).pop(true) : null, child: Text('Ja, das ist $name – Verlauf freigeben')),
      ],
    );
  }
}
