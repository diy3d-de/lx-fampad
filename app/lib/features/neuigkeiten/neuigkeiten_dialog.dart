import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/neuigkeiten/neuigkeiten.dart';
import '../../ui/widgets.dart';

/// Dialog "Neu in x.y.z"; [onGesehen] läuft beim Schließen (merkt die Version).
Future<void> neuigkeitenDialogZeigen(BuildContext context, Neuigkeit n, {required void Function() onGesehen}) async {
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: kSurface,
      title: Text('Neu in ${n.version}', style: const TextStyle(fontWeight: FontWeight.w800, color: kTextStrong)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MonoLabel('// neuigkeiten'),
              const SizedBox(height: 10),
              for (final p in n.punkte)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ', style: TextStyle(color: kAccent)),
                      Expanded(child: Text(p, style: const TextStyle(color: kTextStrong))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Verstanden'))],
    ),
  );
  onGesehen();
}
