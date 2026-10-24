// Warnkarte "Amtliche Warnung" oben auf der Startseite (mobil und Desktop), im Muster der Wetter-Hinweis-Karte: nur sichtbar, solange der Deutsche Wetterdienst für
// den Ort eine Warnung ab Stufe 2 ("markant") meldet und der Stand frisch ist (ein veralteter Stand zeigt nie eine Karte). Farbe nach DWD-Stufe, die Stufe
// steht immer auch als Text. Fest oben, nicht verschiebbar; ein Tipp öffnet die Wetter-Seite. Nur Anzeige, kein Push.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/vorhersage_logik.dart';
import '../../data/wetter/vorhersage_state.dart';
import '../../ui/widgets.dart';
import 'vorhersage_teile.dart' show warnArtIcon;
import 'wetter_karte.dart' show wetterOeffnen;

class WetterDwdWarnKarte extends ConsumerWidget {
  const WetterDwdWarnKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dto = ref.watch(vorhersageProvider.select((s) => s.dto));
    final jetzt = DateTime.now();
    final liste = startseitenWarnungen(dto, jetzt);
    if (liste.isEmpty) return const SizedBox.shrink();
    final farbe = warnFarbe(liste.first.stufe);
    final gezeigt = liste.take(2).toList();
    final rest = liste.length - gezeigt.length;
    final label = 'Amtliche Warnung des Deutschen Wetterdienstes: ${[for (final w in liste) '${stufeName(w.stufe)} ${w.titel}, ${warnZeitraum(w, jetzt)}'].join('. ')}. Wetter öffnen';
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        container: true,
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: () => wetterOeffnen(context),
        child: Material(
          color: farbe.withValues(alpha: 0.10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: farbe.withValues(alpha: 0.6))),
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
                    MonoLabel('// amtliche warnung · stufe ${liste.first.stufe}', color: farbe),
                    const SizedBox(height: 6),
                    for (final w in gezeigt)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(warnArtIcon(w.art), size: 18, color: warnFarbe(w.stufe)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${w.titel} (Stufe ${w.stufe}), ${warnZeitraum(w, jetzt)}',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kText),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (rest > 0) Text('+ $rest weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
                    const Text('Quelle: Deutscher Wetterdienst', style: TextStyle(fontSize: 11, color: kTextMuted)),
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
