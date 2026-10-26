import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import 'seite_neu_laden.dart';
import 'update_service.dart';

/// Hinweis, wenn nach dem Tippen auf "Installieren" nichts passiert (Android blockiert den Installer bei aktiver automatischer Sperre).
const kInstallierenHinweis = 'Passiert nach dem Tippen auf Installieren nichts, schalte vorübergehend die Automatische Sperre (Android-Einstellungen) aus.';

/// Hinweistext unter dem Installieren-Knopf (Android, solange das Update bereitliegt).
class InstallierenHinweis extends StatelessWidget {
  const InstallierenHinweis({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 8),
    child: Text(kInstallierenHinweis, style: TextStyle(fontSize: 12, height: 1.35, color: kTextMuted)),
  );
}

/// Was die Karte zeigt: Titel, Beschriftung und Aktion des Knopfes (beides null = nur Text).
typedef _Anzeige = (String? titel, String? aktion, VoidCallback? onTap);

_Anzeige _anzeigeFuer(BuildContext context, UpdateState u, UpdateController ctrl) {
  if (u.webNeu) return ('Neue Version verfügbar', 'Neu laden', seiteNeuLaden);
  return switch (u.phase) {
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
}

/// Hinweiskarte "Update verfügbar" auf der Startseite (Statusmodell wie im OTA-Paket) bzw. im Web
/// "Neue Version - neu laden". Sichtbar nur, wenn ein Update bereitliegt, lädt oder fehlgeschlagen ist.
class UpdateAnzeige extends ConsumerWidget {
  const UpdateAnzeige({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updateProvider);
    final (titel, aktion, onTap) = _anzeigeFuer(context, u, ref.read(updateProvider.notifier));
    if (titel == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  u.phase == UpdatePhase.fehler && !u.webNeu ? Icons.error_outline : Icons.system_update,
                  color: u.phase == UpdatePhase.fehler && !u.webNeu ? kDanger : kAccent,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(titel, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12))),
                if (aktion != null) TextButton(onPressed: onTap, child: Text(aktion)),
              ],
            ),
            if (!kIsWeb && !u.webNeu && u.phase == UpdatePhase.bereit) const InstallierenHinweis(),
          ],
        ),
      ),
    );
  }
}

/// Pflicht-Update: ersetzt die App, solange der Server eine neuere Version verlangt. Android bietet
/// Herunterladen/Installieren an, das Web lädt die Seite neu.
class PflichtUpdateSeite extends ConsumerWidget {
  const PflichtUpdateSeite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updateProvider);
    final ctrl = ref.read(updateProvider.notifier);
    final (_, aktion, onTap) = kIsWeb ? ('', 'Neu laden', seiteNeuLaden) : _anzeigeFuer(context, u, ctrl);
    final hinweis = kIsWeb
        ? 'Diese Version der Seite ist veraltet. Bitte neu laden.'
        : u.info == null
            ? 'Diese App-Version wird nicht mehr unterstützt. Ein Update ist gerade nicht abrufbar; bitte später erneut prüfen.'
            : 'Diese App-Version wird nicht mehr unterstützt. Bitte aktualisiere auf Version ${u.info?.version}.';
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const MonoLabel('Update erforderlich', color: kWarn),
                    const SizedBox(height: 4),
                    const Text(
                      'Bitte aktualisieren',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.7, color: kTextStrong),
                    ),
                    const SizedBox(height: 16),
                    Text(hinweis, style: const TextStyle(color: kTextMuted)),
                    const SizedBox(height: 24),
                    if (!kIsWeb && u.phase == UpdatePhase.laedt) Text('Lade Update ${(u.fortschritt * 100).round()} %'),
                    if (aktion != null) FilledButton(onPressed: onTap, child: Text(aktion)),
                    if (!kIsWeb && u.phase == UpdatePhase.bereit) const InstallierenHinweis(),
                    if (!kIsWeb && u.info == null && aktion == null && u.phase != UpdatePhase.pruefe)
                      TextButton(onPressed: ctrl.pruefen, child: const Text('Erneut prüfen')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
