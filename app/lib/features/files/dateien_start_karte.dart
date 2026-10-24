// Startseite und Dateiablage (Abschnitt 6n): die Kachel "Zuletzt geteilt" im Desktop-Raster (die letzten Dateien, Tippen öffnet den Bereich) und die Schnellaktionen "Datei" und "Foto" der mobilen
// Startseite (öffnen den Weg zum Hochladen in die oberste Ebene). Beides gibt es nur, wenn der Server die Dateiablage meldet; sonst bleibt es ausgeblendet bzw. beim bisherigen Hinweis. Die Kachel
// zeigt Dateinamen nur auf dem eigenen Bildschirm, nie in einer Benachrichtigung (Dateien lösen nie Push, Erinnerungen oder Hinweise aus).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/dateien/datei_alle.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_repository.dart';
import '../../data/dateien/datei_state.dart';
import '../../ui/widgets.dart';
import 'dateien_aktionen.dart';
import 'dateien_bausteine.dart';

/// Die letzten (höchstens drei) Dateien, neueste zuerst, für die Kachel.
final letzteDateienProvider = Provider<List<DateiEintrag>>((ref) {
  final l = [for (final d in ref.watch(alleDateienProvider).value ?? const <DateiEintrag>[]) if (!d.ohneFassung) d];
  return dateienSortiert<DateiEintrag>(l, DateiSortierung.geaendert, name: (d) => d.name, geaendert: (d) => d.geaendert, groesse: (d) => d.groesse).take(3).toList();
});

/// Text für die Bedienhilfe der Kachel.
String dateienKachelSemantik(List<DateiEintrag> l) => l.isEmpty ? 'Zuletzt geteilt. Noch keine Dateien. Öffnen' : 'Zuletzt geteilt. ${[for (final d in l) d.name].join(', ')}. Öffnen';

class DateienKachelInhalt extends ConsumerWidget {
  const DateienKachelInhalt({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(letzteDateienProvider);
    if (l.isEmpty) return const EmptyState(icon: Icons.folder_outlined, title: 'Noch keine Dateien', hint: 'Lade etwas hoch, dann siehst du es hier.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final d in l)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                ExcludeSemantics(child: Icon(dateiIcon(vorschauArt(d.mime, d.name)), size: 18, color: kAccent)),
                const SizedBox(width: 10),
                Expanded(child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(groesseText(d.groesse), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Schnellaktion der mobilen Startseite: mit Dateiablage Dateien (oder Fotos) wählen und in die oberste Ebene hochladen, sonst der bisherige Hinweis.
void dateiSchnellHochladen(BuildContext context, WidgetRef ref, {required bool nurBilder}) {
  if (ref.read(dateienVerfuegbarProvider).value ?? false) {
    unawaited(dateienHochladen(context, ref, nurBilder: nurBilder));
  } else {
    zeigePhase1Hinweis(context);
  }
}
