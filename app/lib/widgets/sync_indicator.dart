import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../data/sync_state.dart';

/// Wolken-Symbol in der Kopfzeile: Abgleichstatus, Tippen gleicht sofort ab.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    if (sync.status == SyncStatus.laeuft) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final fehler = sync.status == SyncStatus.fehler;
    final getrennt = sync.status == SyncStatus.getrennt;
    final offen = sync.offeneAenderungen > 0;
    return IconButton(
      tooltip: fehler
          ? 'Abgleich fehlgeschlagen: ${sync.meldung ?? ''}'
          : getrennt
              ? 'Nicht verbunden'
              : 'Jetzt abgleichen',
      icon: Icon(
        fehler || getrennt ? Icons.cloud_off : (offen ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined),
        // wie der "online"-Punkt auf lx-labs.dev: Terminal-Grün, wenn alles abgeglichen ist
        color: fehler ? kDanger : (getrennt || offen ? kTextMuted : kTerminal),
      ),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        await ref.read(syncProvider.notifier).synchronisieren();
        messenger.showSnackBar(SnackBar(content: Text(ref.read(syncProvider).meldung ?? 'Abgeglichen')));
      },
    );
  }
}
