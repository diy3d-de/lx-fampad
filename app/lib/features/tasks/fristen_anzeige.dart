// Gemeinsame Anzeige-Bausteine der Fristen: Ampelfarbe, Text "läuft in 12 Tagen ab", Startseiten-Karte "Fristen".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../data/tasks/fristen_logik.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../shell/shell_tab.dart';
import 'tasks_state.dart';

/// Farbe der Ampel: überfällig rot, innerhalb der Vorwarnzeit gelb, sonst ruhig (gedämpft), erledigt gedämpft.
Color fristFarbe(FristAmpel a) => switch (a) {
  FristAmpel.ueberfaellig => kDanger,
  FristAmpel.bald => kWarn,
  FristAmpel.ruhig || FristAmpel.erledigt => kTextMuted,
};

/// Wort zur Ampel für Screenreader (die Farbe allein sagt nichts).
String fristAmpelWort(FristAmpel a) => switch (a) {
  FristAmpel.ueberfaellig => 'überfällig',
  FristAmpel.bald => 'bald fällig',
  FristAmpel.ruhig => 'in Ruhe',
  FristAmpel.erledigt => 'erledigt',
};

/// "Mi, 21. Okt 2027" für einen Tag.
String fristDatumTextFuer(DateTime tag) => DateFormat('E, d. MMM y', 'de_DE').format(tag);

/// Ablaufdatum einer Frist als Text.
String fristDatumText(Aufgabe a) {
  final t = fristTag(a);
  return t == null ? 'ohne Datum' : fristDatumTextFuer(t);
}

/// Kurztext einer Frist: "in 12 Tagen · Mi, 21. Okt 2026".
String fristKurzText(Aufgabe a, DateTime jetzt) {
  final rest = fristRestTage(a, jetzt);
  return rest == null ? 'ohne Datum' : '${fristRestText(rest)} · ${fristDatumText(a)}';
}

/// Fristen, die jetzt überfällig oder in ihrer Vorwarnzeit sind (Startseite: Karte und Verfügbarkeit der Kachel; ohne Treffer gibt es die Kachel nicht).
final dringendeFristenProvider = Provider.autoDispose<List<Aufgabe>>((ref) {
  final alle = ref.watch(aufgabenProvider).value ?? const <Aufgabe>[];
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  return dringendeFristen(alle, jetzt);
});

/// Startseiten-Karte "Fristen": überfällige und bald ablaufende Fristen. Tippen öffnet die Aufgaben in der Ansicht "Fristen".
class FristenStartKarte extends ConsumerWidget {
  const FristenStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liste = ref.watch(dringendeFristenProvider);
    if (liste.isEmpty) return const SizedBox.shrink();
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final zeigen = liste.take(4).toList();
    final ueberfaellig = liste.where((a) => fristAmpel(a, jetzt) == FristAmpel.ueberfaellig).length;
    return Semantics(
      button: true,
      label: 'Fristen: ${liste.length} ${liste.length == 1 ? 'Frist braucht' : 'Fristen brauchen'} Aufmerksamkeit${ueberfaellig > 0 ? ', davon $ueberfaellig überfällig' : ''}. Fristen öffnen',
      excludeSemantics: true,
      child: LxCard(
        onTap: () {
          ref.read(aufgabenAnsichtProvider.notifier).filter(AufgabeFilter.fristen);
          ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('Fristen'),
            const SizedBox(height: 12),
            for (final a in zeigen)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 4, height: 34, margin: const EdgeInsets.only(right: 10), decoration: BoxDecoration(color: fristFarbe(fristAmpel(a, jetzt)), borderRadius: BorderRadius.circular(2))),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.titel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            fristKurzText(a, jetzt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: fristFarbe(fristAmpel(a, jetzt))),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (liste.length > zeigen.length) Text('+ ${liste.length - zeigen.length} weitere', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          ],
        ),
      ),
    );
  }
}
