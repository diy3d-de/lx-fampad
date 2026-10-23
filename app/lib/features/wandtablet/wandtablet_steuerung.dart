// Start des Wandtablet-Modus: Einstieg (nur über Profil > Startseite und Anzeige und die Zeile auf der Desktop-Startseite) und Autostart nach der Anmeldung.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/wandtablet/wandtablet_einstellungen.dart';
import 'wandtablet_screen.dart';

/// Öffnet den Modus über allem (Wurzel-Navigator, auch aus der Desktop-Shell heraus). Gibt zurück, wenn er beendet ist.
Future<void> wandtabletStarten(BuildContext context) => Navigator.of(context, rootNavigator: true).push<void>(WandtabletScreen.route());

/// true, sobald die Person angemeldet ist und die Einstellungen gelesen sind. Das Wurzel-Widget (app.dart) hört darauf und prüft dann EINMAL je
/// Anmeldung, ob "Beim Start automatisch starten" an ist (ein späteres Umschalten startet den Modus nie von selbst).
final wandtabletBereitProvider = Provider<bool>((ref) {
  final angemeldet = ref.watch(authProvider.select((a) => a.status == AuthStatus.angemeldet && a.user != null));
  return angemeldet && ref.watch(wandtabletEinstellungenProvider.select((e) => e.geladen));
});

/// Zeile am Ende der Desktop-/Tablet-Startseite: startet den Modus. Keine Kopfzeilen-Aktion (die Kopfzeile bleibt bei allen Tabs gleich).
class WandtabletStartZeile extends StatelessWidget {
  const WandtabletStartZeile({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: kTextMuted, tapTargetSize: MaterialTapTargetSize.padded),
      onPressed: () => unawaited(wandtabletStarten(context)),
      icon: const Icon(Icons.tv_outlined, size: 18),
      label: const Text('Wandtablet-Modus', style: TextStyle(fontFamily: kFontMono, fontSize: 12)),
    ),
  );
}
