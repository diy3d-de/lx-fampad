// Schutz vor stillem Verlust ungespeicherter Eingaben in Editoren: nur im Desktop-Layout, wo Seitenleiste, Karten und Benachrichtigungen den
// Bereich wechseln können, während ein Editor offen ist. Mobil bleibt das Verhalten unverändert (Zurück schließt wie bisher).
import 'package:flutter/material.dart';

import '../features/shell/desktop_shell.dart' show DesktopShellMarke;

class UngespeichertSchutz extends StatelessWidget {
  /// Es gibt Eingaben, die noch nicht gespeichert sind (wird bei jeder Meldung von [aenderungen] neu gefragt).
  final bool Function() geaendert;

  /// Meldet Eingaben (z. B. die Textfelder), damit die Sperre ohne Neubau der Seite mitzieht.
  final Listenable aenderungen;
  final Widget child;
  const UngespeichertSchutz({super.key, required this.geaendert, required this.aenderungen, required this.child});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: aenderungen,
    builder: (context, kind) => PopScope(
    canPop: !(geaendert() && DesktopShellMarke.vorhanden(context)),
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final nav = Navigator.of(context);
      final verwerfen = await showDialog<bool>(
        useRootNavigator: false,
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Änderungen verwerfen?'),
          content: const Text('Deine Eingaben sind noch nicht gespeichert.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Weiter bearbeiten')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Verwerfen')),
          ],
        ),
      );
      if (verwerfen == true && context.mounted) nav.pop();
    },
    child: kind!,
    ),
    child: child,
  );
}
