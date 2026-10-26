// Startseiten-Kachel "Medikamente" (mobil und Desktop) und Einstieg in den Bereich. Die Kachel erscheint nur, wenn für diese Person (oder ihre Kinder) heute noch Einnahmen offen sind oder
// der Vorrat/das Rezept knapp ist. Sie zeigt nur die Uhrzeit der nächsten Einnahme und "Ich" bzw. den Vornamen, NIE Medikamentenname oder Dosis (die stehen erst nach dem Tippen in der
// Ansicht). Das Wandtablet zeigt keine Medikamente.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/medikamente/medikament_heute.dart';
import '../../data/medikamente/medikament_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'medikamente_screen.dart';

/// Öffnet den Bereich: im Desktop-Layout als Bereich der Shell (Seitenleiste und Fußzeile bleiben), sonst als eigene Seite.
void medikamenteOeffnen(BuildContext context) {
  if (DesktopShellMarke.vorhanden(context)) {
    ProviderScope.containerOf(context).read(shellTabProvider.notifier).waehlen(kMedikamenteTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(medikamenteRoute()));
}

/// Was die Kachel zeigt: nächster offener Slot (nur Zeit und Person), Zahl der offenen Einnahmen und ob Vorrat/Rezept knapp sind.
class MedKachelDaten {
  final int offen;
  final String? zeit;
  final String? person;
  final bool warnung;
  const MedKachelDaten({this.offen = 0, this.zeit, this.person, this.warnung = false});

  bool get sichtbar => offen > 0 || warnung;
}

final medKachelProvider = Provider.autoDispose<MedKachelDaten>((ref) {
  final d = ref.watch(medDatenProvider);
  if (d.eintraege.isEmpty) return const MedKachelDaten();
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  final slots = heuteSlots(d.eintraege, jetzt).where((s) => !s.erledigt).toList();
  final naechster = slots.isEmpty ? null : slots.first;
  String? person;
  if (naechster != null) {
    person = naechster.subjektId.toLowerCase() == d.ich?.toLowerCase() ? 'Ich' : (d.person(naechster.subjektId)?.displayName.split(RegExp(r'\s+')).first ?? 'Kind');
  }
  return MedKachelDaten(offen: slots.length, zeit: naechster?.zeit, person: person, warnung: warnungen(d.eintraege, jetzt).isNotEmpty);
});

String medKachelSemantik(MedKachelDaten d) => d.offen > 0
    ? 'Medikamente: ${d.offen} ${d.offen == 1 ? 'Einnahme' : 'Einnahmen'} offen${d.zeit == null ? '' : ', nächste um ${d.zeit} Uhr, ${d.person}'}${d.warnung ? ', Vorrat oder Rezept beachten' : ''}. Öffnen'
    : 'Medikamente: Vorrat oder Rezept beachten. Öffnen';

/// Inhalt der Kachel (ohne Rahmen und Label), von der mobilen und der Desktop-Startseite verwendet.
class MedKachelInhalt extends StatelessWidget {
  final MedKachelDaten daten;
  const MedKachelInhalt({super.key, required this.daten});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (daten.zeit != null)
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(daten.zeit!, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(child: Text('${daten.person} · nächste Einnahme', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextMuted))),
          ],
        ),
      if (daten.warnung) ...[
        if (daten.zeit != null) const SizedBox(height: 6),
        const Row(children: [Icon(Icons.warning_amber_rounded, size: 16, color: kWarn), SizedBox(width: 6), Expanded(child: Text('Vorrat oder Rezept beachten', style: TextStyle(fontSize: 13, color: kWarn)))]),
      ],
    ],
  );
}

/// Kachel der Handy-Startseite.
class MedikamenteStartKarte extends ConsumerWidget {
  const MedikamenteStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(medKachelProvider);
    if (!d.sichtbar) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: medKachelSemantik(d),
      excludeSemantics: true,
      child: LxCard(
        onTap: () => medikamenteOeffnen(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [const Expanded(child: MonoLabel('Medikamente')), if (d.offen > 0) Text('${d.offen} offen', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kWarn))]),
            const SizedBox(height: 10),
            MedKachelInhalt(daten: d),
          ],
        ),
      ),
    );
  }
}
