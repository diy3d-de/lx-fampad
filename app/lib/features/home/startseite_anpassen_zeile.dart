// Zeile am Ende der Startseite (mobil und Desktop): öffnet "Startseite anpassen".
import 'package:flutter/material.dart';

import '../../constants.dart';
import 'startseite_anpassen_screen.dart';

/// Zeile am Ende der Startseite: öffnet "Startseite anpassen" (Kopfzeile bleibt bei allen Tabs gleich, daher kein Knopf dort).
class StartseiteAnpassenZeile extends StatelessWidget {
  const StartseiteAnpassenZeile({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: kTextMuted, tapTargetSize: MaterialTapTargetSize.padded),
      onPressed: () => Navigator.of(context).push<void>(StartseiteAnpassenScreen.route()),
      icon: const Icon(Icons.tune, size: 18),
      label: const Text('Startseite anpassen', style: TextStyle(fontFamily: kFontMono, fontSize: 12)),
    ),
  );
}
