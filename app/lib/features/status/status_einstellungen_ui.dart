// Schalter "Familien-Status anzeigen" (Profil > Startseite und Anzeige): nur lokal auf diesem Gerät. Aus: die Kachel "Status" und alle Status-Zeilen verschwinden, der Status
// anderer wird nirgends gezeigt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/status/status_state.dart';
import '../../ui/widgets.dart';

class StatusSchalterZeile extends ConsumerWidget {
  const StatusSchalterZeile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final an = ref.watch(statusAnzeigenProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          secondary: const Icon(Icons.mood_outlined, color: kAccent, size: 22),
          title: const Text('Familien-Status anzeigen', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Die Kachel „Status“ auf der Startseite, nur auf diesem Gerät', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          value: an,
          onChanged: (v) => unawaited(ref.read(statusAnzeigenProvider.notifier).setzen(v)),
        ),
      ),
    );
  }
}
