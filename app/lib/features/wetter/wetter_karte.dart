// Startseiten-Kachel "Wetter" (mobil und Desktop): Ortsname, Temperatur, Stand der Messung; Tippen öffnet die Detailseite.
// Sichtbar nur, wenn der Server das Wetter eingeschaltet hat, eine Messung vorliegt und der Schalter an ist.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import 'wetter_screen.dart';

void wetterOeffnen(BuildContext context) {
  unawaited(
    Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const WetterScreen())),
  );
}

/// Inhalt der Kachel (ohne Rahmen), von der mobilen und der Desktop-Startseite verwendet.
class WetterInhalt extends StatelessWidget {
  final WetterZustand zustand;
  const WetterInhalt({super.key, required this.zustand});

  @override
  Widget build(BuildContext context) {
    final dto = zustand.dto!;
    final a = dto.aktuell!;
    final stand = wetterStand(zustand, DateTime.now());
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dto.ort,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: kTextStrong,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                stand.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 11,
                  color: stand.warnung ? kWarn : kTextMuted,
                ),
              ),
              if (dto.min24h != null && dto.max24h != null) ...[
                const SizedBox(height: 4),
                Text(
                  'min ${temperaturText(dto.min24h)} · max ${temperaturText(dto.max24h)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 11,
                    color: kTextMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          temperaturText(a.temperatur),
          style: const TextStyle(
            fontFamily: kFontMono,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: kAccent,
          ),
        ),
        const Icon(Icons.chevron_right, color: kTextMuted),
      ],
    );
  }
}

String wetterSemantik(WetterZustand st) {
  final dto = st.dto!;
  final stand = wetterStand(st, DateTime.now());
  return 'Wetter in ${dto.ort}: ${temperaturText(dto.aktuell!.temperatur)}. ${stand.text}. Details öffnen';
}

/// Karte der mobilen Startseite; ohne Daten oder bei ausgeschaltetem Schalter nimmt sie keinen Platz ein.
class WetterStartKarte extends ConsumerWidget {
  const WetterStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(wetterProvider);
    if (!st.kachelSichtbar) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        container: true,
        button: true,
        label: wetterSemantik(st),
        excludeSemantics: true,
        onTap: () => wetterOeffnen(context),
        child: LxCard(
          onTap: () => wetterOeffnen(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MonoLabel('// wetter'),
                const SizedBox(height: 10),
                WetterInhalt(zustand: st),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
