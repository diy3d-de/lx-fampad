// Meldungen des Abgleichs über dem Inhalt eines Bereichs: Statusleiste (offline, Fehler, Update nötig) und Hinweise zu abgelehnten
// oder überholten Änderungen ("... wurde auf einem anderen Gerät gelöscht"). Gemeinsam für Listen und Kalender.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../data/sync_state.dart';

/// Statusleiste und Hinweise des Abgleichs (leer, solange alles in Ordnung ist).
class SyncHinweise extends ConsumerWidget {
  const SyncHinweise({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SyncStatusLeiste(sync),
        for (final h in sync.hinweise) SyncHinweisBox(h, onClose: () => ref.read(syncProvider.notifier).hinweisSchliessen(h.id)),
      ],
    );
  }
}

class SyncStatusLeiste extends StatelessWidget {
  final SyncState sync;
  const SyncStatusLeiste(this.sync, {super.key});

  @override
  Widget build(BuildContext context) {
    final offen = sync.offeneAenderungen;
    final String? text = switch (sync.status) {
      SyncStatus.offline => offen > 0 ? 'Offline – $offen ${offen == 1 ? 'Änderung wird' : 'Änderungen werden'} später übertragen.' : 'Offline – Änderungen werden später übertragen.',
      SyncStatus.fehler => 'Der Übertragen hat nicht geklappt. Deine Änderungen bleiben gespeichert und werden erneut gesendet.',
      SyncStatus.updateNoetig => 'Bitte aktualisiere die App, damit wieder alles übertragen wird.',
      SyncStatus.wartung => offen > 0 ? 'Wartung – $offen ${offen == 1 ? 'Änderung wird' : 'Änderungen werden'} danach übertragen.' : 'Wartung – danach geht es weiter.',
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    final farbe = sync.status == SyncStatus.offline ? kTextMuted : (sync.status == SyncStatus.fehler ? kDanger : kWarn);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        liveRegion: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: farbe.withValues(alpha: 0.08),
            border: Border.all(color: farbe.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(sync.status == SyncStatus.offline ? Icons.cloud_off : (sync.status == SyncStatus.wartung ? Icons.build_outlined : Icons.error_outline), size: 16, color: farbe),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: farbe))),
            ],
          ),
        ),
      ),
    );
  }
}

class SyncHinweisBox extends StatelessWidget {
  final SyncMeldung hinweis;
  final VoidCallback onClose;
  const SyncHinweisBox(this.hinweis, {super.key, required this.onClose});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(
          color: kWarn.withValues(alpha: 0.08),
          border: Border.all(color: kWarn.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: kWarn),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(hinweis.text, style: const TextStyle(fontSize: 13))),
            ),
            IconButton(tooltip: 'Hinweis schließen', icon: const Icon(Icons.close, size: 18), onPressed: onClose),
          ],
        ),
      ),
    ),
  );
}
