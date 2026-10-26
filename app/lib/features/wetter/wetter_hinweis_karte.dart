// Gelbe Warnkarte "Wetter-Hinweis" oben auf der Startseite (mobil und Desktop), wie die Absicherungs-Karte: nur sichtbar, solange ein eingeschalteter Wert auffällt.
// Fest oben, nicht verschiebbar; ein Tipp öffnet die Wetter-Seite.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/wetter_hinweise.dart';
import '../../ui/widgets.dart';
import 'wetter_karte.dart' show wetterOeffnen;

class WetterHinweisKarte extends ConsumerWidget {
  const WetterHinweisKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liste = ref.watch(aktiveWetterHinweiseProvider);
    if (liste.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        container: true,
        button: true,
        label: 'Wetter-Hinweis: ${liste.map((h) => h.text).join('. ')}. Wetter öffnen',
        excludeSemantics: true,
        onTap: () => wetterOeffnen(context),
        child: Material(
          color: kWarn.withValues(alpha: 0.10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: kWarn.withValues(alpha: 0.5))),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => wetterOeffnen(context),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MonoLabel('Wetter-hinweis', color: kWarn),
                    const SizedBox(height: 6),
                    for (final h in liste) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(h.text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kText))),
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
