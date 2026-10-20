// Einstieg in "Standort teilen" auf der Startseite (mobil und Desktop): zeigt in einem Satz, ob du teilst oder jemand mit dir teilt, und öffnet die Seite.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/standort/standort_dienst.dart';
import '../../ui/widgets.dart';
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'standort_screen.dart';

/// Öffnet die Standort-Seite: im Desktop-Layout als Bereich der Shell (Seitenleiste und Fußzeile bleiben, erkannt an der Shell über dem Aufrufer), sonst als eigene Seite.
void standortOeffnen(BuildContext context) {
  if (DesktopShellMarke.vorhanden(context)) {
    ProviderScope.containerOf(context).read(shellTabProvider.notifier).waehlen(kStandortTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const StandortScreen())));
}

/// Ein Satz zum Stand: "Du teilst deinen Standort", "Anna teilt ihren Standort", "Niemand teilt gerade".
String standortKurzstatus(StandortState st, Map<String, UserDto> namen) {
  if (st.teilt) return st.phase == StandortPhase.startet ? 'Teilen wird gestartet …' : 'Du teilst deinen Standort';
  final wer = [for (final p in st.geteilt.values) namen[p.userId]?.displayName ?? 'Jemand']..sort();
  if (wer.isEmpty) return 'Niemand teilt gerade';
  if (wer.length == 1) return '${wer.first} teilt den Standort';
  return '${wer.length} teilen ihren Standort: ${wer.take(2).join(', ')}${wer.length > 2 ? ' u. a.' : ''}';
}

/// Karte der mobilen Startseite.
class StandortStartKarte extends ConsumerWidget {
  const StandortStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(standortProvider);
    // Namen nur, wenn jemand teilt (sonst keine Abfrage der Mitglieder nur für diesen Satz)
    final namen = st.geteilt.isEmpty ? const <String, UserDto>{} : ref.watch(standortMitgliederProvider);
    final text = standortKurzstatus(st, namen);
    return Semantics(
      container: true,
      button: true,
      label: 'Standort. $text',
      excludeSemantics: true,
      onTap: () => standortOeffnen(context),
      child: LxCard(
        onTap: () => standortOeffnen(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MonoLabel('// standort'),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(st.teilt ? Icons.my_location : Icons.location_on_outlined, size: 20, color: st.teilt ? kTerminal : kAccent),
                  const SizedBox(width: 12),
                  Expanded(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis)),
                  const Icon(Icons.chevron_right, color: kTextMuted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
