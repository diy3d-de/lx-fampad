// Startseiten-Kachel "Countdown": je gewähltem Termin "Titel - in N Tagen" (höchstens 3, nächster zuerst), aus der lokalen Datenbank.
// Die Auswahl liegt lokal je Gerät (Schalter im Termin-Detail). Ohne Countdown auf einen künftigen Termin gibt es die Kachel nicht.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/countdown/countdown_logik.dart';
import '../../data/countdown/countdown_state.dart';
import '../../ui/widgets.dart';
import '../shell/shell_tab.dart';
import 'calendar_anzeige.dart';
import 'calendar_state.dart';

/// Die Countdowns (Startseite: Kachel und Verfügbarkeit; ohne Treffer gibt es die Kachel nicht).
final countdownEintraegeProvider = Provider.autoDispose<List<CountdownEintrag>>((ref) {
  final ids = ref.watch(countdownTermineProvider);
  if (ids.isEmpty) return const [];
  final daten = ref.watch(kalenderDatenProvider);
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  // nur die gewählten Termine auflösen (Serien: nächstes Vorkommen binnen eines Jahres)
  final gewaehlt = KalenderDaten(termine: [for (final t in daten.termine) if (ids.contains(t.id)) t], ausnahmen: daten.ausnahmen);
  return countdownEintraege(vorkommen: anstehende(gewaehlt, jetzt, tage: 366), ids: ids, heute: heuteTag(jetzt));
});

class CountdownKarte extends ConsumerWidget {
  const CountdownKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liste = ref.watch(countdownEintraegeProvider);
    if (liste.isEmpty) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Countdown: ${liste.map((e) => '${e.titel} – ${e.text}').join(', ')}. Kalender öffnen',
      excludeSemantics: true,
      child: LxCard(
        onTap: () => ref.read(shellTabProvider.notifier).waehlen(kKalenderTab),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('// countdown'),
            const SizedBox(height: 12),
            for (final e in liste)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.hourglass_bottom, size: 18, color: kAccent),
                    const SizedBox(width: 10),
                    Expanded(child: Text(e.titel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                    const SizedBox(width: 8),
                    Text(e.text, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Schalter "Countdown auf der Startseite" im Termin-Detail (lokal je Gerät).
class CountdownSchalter extends ConsumerWidget {
  final String terminId;
  const CountdownSchalter({super.key, required this.terminId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final an = ref.watch(countdownTermineProvider.select((s) => s.contains(terminId)));
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(Icons.hourglass_bottom, size: 18, color: kTextMuted),
      title: const Text('Countdown auf der Startseite'),
      value: an,
      onChanged: (w) => ref.read(countdownTermineProvider.notifier).schalten(terminId, w),
    );
  }
}
