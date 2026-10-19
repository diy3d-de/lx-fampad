import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../data/sync_state.dart';

/// Wolken-Symbol in der Kopfzeile: Zustand des Abgleichs. Grün und fertig = synchron; Pfeil nach oben mit Zahl = N Änderungen
/// noch nicht beim Server; durchgestrichen = offline; rot = Fehler. Tippen gleicht sofort ab.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    if (sync.status == SyncStatus.laeuft) {
      return Semantics(
        label: 'Abgleich läuft',
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    final n = sync.offeneAenderungen;
    final offen = n > 0 ? (n == 1 ? '1 Änderung offen' : '$n Änderungen offen') : null;
    final (IconData icon, Color farbe, String text) = switch (sync.status) {
      SyncStatus.fehler => (Icons.cloud_off, kDanger, 'Abgleich fehlgeschlagen. ${sync.meldung ?? ''}'.trim()),
      SyncStatus.updateNoetig => (Icons.system_update_alt, kWarn, 'Bitte aktualisiere die App'),
      SyncStatus.offline => (Icons.cloud_off, kTextMuted, offen == null ? 'Offline' : 'Offline, $offen'),
      SyncStatus.getrennt => (Icons.cloud_off, kTextMuted, 'Nicht verbunden'),
      SyncStatus.synchron || SyncStatus.laeuft => n > 0
          ? (Icons.cloud_upload_outlined, kTextMuted, offen!)
          : (Icons.cloud_done_outlined, kTerminal, 'Synchron'),
    };
    return IconButton(
      tooltip: sync.status == SyncStatus.synchron && n == 0 ? 'Synchron. Tippen zum Abgleichen' : text,
      icon: Badge(
        isLabelVisible: n > 0,
        label: Text('$n', style: const TextStyle(fontFamily: kFontMono, fontSize: 10)),
        backgroundColor: kAccent,
        textColor: kOnAccent,
        child: Icon(icon, color: farbe),
      ),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        await ref.read(syncProvider.notifier).synchronisieren(manuell: true);
        // der Abgleich kann länger dauern: inzwischen weg (Seitenwechsel, Abmelden), dann weder ref noch messenger anfassen
        if (!context.mounted) return;
        final s = ref.read(syncProvider);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              switch (s.status) {
                SyncStatus.synchron => 'Abgeglichen',
                SyncStatus.offline => 'Offline – Änderungen werden später abgeglichen.',
                SyncStatus.getrennt => 'Nicht verbunden',
                _ => s.meldung ?? 'Der Abgleich ist fehlgeschlagen.',
              },
            ),
          ),
        );
      },
    );
  }
}
