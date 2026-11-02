// Schalter "Neue und geänderte Termine melden" (Profil > Benachrichtigungen): nur lokal auf diesem Gerät, Standard an. Gemeldet werden Termine anderer
// Personen, nie Geburtstage; der Text ist neutral (der Titel nur mit "Titel auf Sperrbildschirm zeigen" in den Erinnerungen, im Browser nie).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/calendar/termin_hinweis_dienst.dart';
import '../../ui/widgets.dart';

class TerminHinweiseSchalterZeile extends ConsumerWidget {
  const TerminHinweiseSchalterZeile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final an = ref.watch(terminHinweiseAnProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          secondary: const Icon(Icons.event_available_outlined, color: kAccent, size: 22),
          title: const Text('Neue und geänderte Termine melden', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text(
            'Wenn jemand anderes einen Termin anlegt oder ändert, nur auf diesem Gerät. Der Titel steht nur da, wenn du in den Erinnerungen „Titel auf Sperrbildschirm zeigen“ eingeschaltet hast; dann sehen ihn auch Smartwatches und Apps, die Benachrichtigungen mitlesen.',
            style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, color: kTextMuted),
          ),
          value: an,
          onChanged: (v) => unawaited(ref.read(terminHinweiseAnProvider.notifier).setzen(v)),
        ),
      ),
    );
  }
}
