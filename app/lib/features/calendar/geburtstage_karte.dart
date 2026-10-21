// Startseiten-Karte "Nächste Geburtstage": die nächsten Geburtstage der kommenden 60 Tage aus der lokalen Datenbank (auch offline).
// Ohne Geburtstage erscheint die Karte gar nicht. Tippen öffnet den Kalender.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/termin_repository.dart';
import '../../ui/widgets.dart';
import '../shell/shell_tab.dart';
import 'calendar_anzeige.dart';
import 'calendar_state.dart';

class GeburtstageKarte extends ConsumerWidget {
  const GeburtstageKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(kalenderDatenProvider);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final heute = heuteTag(jetzt);
    final liste = nurGeburtstage(anstehende(daten, jetzt)).take(3).toList();
    if (liste.isEmpty) return const SizedBox.shrink();
    String tagText(Vorkommen v) {
      final tag = v.ersterTag;
      if (tag == heute) return 'heute';
      if (tag == heute.add(const Duration(days: 1))) return 'morgen';
      return DateFormat('E, d. MMM', 'de_DE').format(tag).toLowerCase();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Semantics(
        button: true,
        label: 'Nächste Geburtstage: ${liste.map((v) => '${vorkommenTitel(v)} ${tagText(v)}').join(', ')}. Kalender öffnen',
        excludeSemantics: true,
        child: LxCard(
          onTap: () => ref.read(shellTabProvider.notifier).waehlen(kKalenderTab),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MonoLabel('// geburtstage'),
              const SizedBox(height: 12),
              for (final v in liste)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.cake_outlined, size: 18, color: kGeburtstag),
                      const SizedBox(width: 10),
                      Expanded(child: Text(vorkommenTitel(v), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                      const SizedBox(width: 8),
                      Text(tagText(v), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
