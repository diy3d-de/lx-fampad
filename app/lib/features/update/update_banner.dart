import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import 'update_service.dart';

/// Hinweiskarte "Update verfügbar" auf der Startseite (Statusmodell wie im OTA-Paket).
/// Sichtbar nur, wenn ein Update bereitliegt, lädt oder fehlgeschlagen ist.
class UpdateAnzeige extends ConsumerWidget {
  const UpdateAnzeige({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updateProvider);
    final ctrl = ref.read(updateProvider.notifier);
    final (String? titel, String? aktion, VoidCallback? onTap) = switch (u.phase) {
      UpdatePhase.verfuegbar => ('Update ${u.info?.version} verfügbar', 'Herunterladen', ctrl.herunterladen),
      UpdatePhase.laedt => ('Lade Update ${(u.fortschritt * 100).round()} %', null, null),
      UpdatePhase.bereit => ('Update ${u.info?.version} bereit', 'Installieren', () async {
          final messenger = ScaffoldMessenger.of(context);
          final fehler = await ctrl.installieren();
          if (fehler != null) messenger.showSnackBar(SnackBar(content: Text(fehler)));
        }),
      UpdatePhase.fehler => (u.fehler ?? 'Update fehlgeschlagen', 'Erneut prüfen', ctrl.pruefen),
      _ => (null, null, null),
    };
    if (titel == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              u.phase == UpdatePhase.fehler ? Icons.error_outline : Icons.system_update,
              color: u.phase == UpdatePhase.fehler ? kDanger : kAccent,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(titel, style: const TextStyle(fontFamily: kFontMono, fontSize: 12))),
            if (aktion != null) TextButton(onPressed: onTap, child: Text(aktion)),
          ],
        ),
      ),
    );
  }
}
