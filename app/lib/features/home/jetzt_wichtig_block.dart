// Block "Jetzt wichtig" oben auf der Startseite (mobil und Desktop), direkt unter den festen Warnkarten: Überfälliges, heute noch Anstehendes und der Müll
// heute/morgen in höchstens fünf Zeilen. Nur lokal berechnet (data/startseite/jetzt_wichtig_logik.dart), kein Server. Der Block erscheint nur, wenn es
// etwas zu zeigen gibt und der Schalter (Profil > Startseite und Anzeige, Standard an) an ist. Jede Zeile hat Symbol UND Text, nie nur Farbe.
// Gesundheit, Zähler, Tresor, Chat und Standort tauchen hier nie auf.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart' show kalenderDatenProvider;
import '../../data/muell/muell_state.dart' show muellProvider;
import '../../data/startseite/jetzt_wichtig_logik.dart';
import '../../data/startseite/jetzt_wichtig_state.dart';
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../muell/muell_karte.dart' show muellOeffnen;
import '../shell/shell_tab.dart';

/// Der Block für jetzt (leer, solange die Person nicht angemeldet ist oder der Schalter aus ist).
final jetztWichtigProvider = Provider.autoDispose<JetztWichtig>((ref) {
  if (!ref.watch(jetztWichtigAnProvider)) return const JetztWichtig();
  final ich = ref.watch(authProvider.select((a) => a.user?.id));
  final rolle = ref.watch(authProvider.select((a) => a.user?.role));
  if (ich == null) return const JetztWichtig();
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  return baueJetztWichtig(
    kalender: ref.watch(kalenderDatenProvider),
    aufgaben: ref.watch(aufgabenProvider).value ?? const [],
    ich: ich,
    elternRolle: rolle == Role.admin || rolle == Role.parent,
    jetzt: jetzt,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine ? m.tage : null)),
  );
});

IconData _symbol(JetztArt a) => switch (a) {
  JetztArt.ueberfaellig => Icons.error_outline,
  JetztArt.termin => Icons.event_outlined,
  JetztArt.aufgabe => Icons.task_alt_outlined,
  JetztArt.muell => Icons.delete_outline,
};

String _lesetext(JetztZeile z) => switch (z.art) {
  JetztArt.ueberfaellig => 'Überfällig: ${z.text}, ${z.zusatz}',
  JetztArt.termin => 'Termin: ${z.text}, ${z.zusatz}',
  JetztArt.aufgabe => 'Aufgabe: ${z.text}, ${z.zusatz}',
  JetztArt.muell => 'Müll: ${z.text}',
};

/// Der Block; ohne Inhalt oder bei ausgeschaltetem Schalter wird nichts gezeichnet.
class JetztWichtigBlock extends ConsumerWidget {
  const JetztWichtigBlock({super.key});

  void _oeffnen(BuildContext context, WidgetRef ref, JetztZeile z) {
    switch (z.art) {
      case JetztArt.ueberfaellig || JetztArt.aufgabe:
        ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      case JetztArt.termin:
        ref.read(shellTabProvider.notifier).waehlen(kKalenderTab);
      case JetztArt.muell:
        muellOeffnen(context);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(jetztWichtigProvider);
    if (!b.hatInhalt) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        container: true,
        label: 'Jetzt wichtig, ${b.gesamt} ${b.gesamt == 1 ? 'Eintrag' : 'Einträge'}',
        child: LxCard(
          gewaehlt: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: MonoLabel('Jetzt wichtig')),
                  Text('${b.gesamt}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, color: kTextMuted)),
                ],
              ),
              const SizedBox(height: 4),
              for (final z in b.zeilen)
                Semantics(
                  button: true,
                  label: _lesetext(z),
                  excludeSemantics: true,
                  child: InkWell(
                    key: ValueKey('jetzt:${z.art.name}:${z.text}'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _oeffnen(context, ref, z),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Row(
                        children: [
                          Icon(_symbol(z.art), size: 18, color: z.dringend ? kDanger : kAccent),
                          const SizedBox(width: 10),
                          Expanded(child: Text(z.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: kText))),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              z.zusatz,
                              textAlign: TextAlign.end,
                              style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, fontWeight: z.dringend ? FontWeight.w700 : FontWeight.w400, color: z.dringend ? kDanger : kTextMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (b.weitere > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Text('+ ${b.weitere} weitere', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Schalter "Jetzt wichtig" (Profil > Startseite und Anzeige), nur auf diesem Gerät.
class JetztWichtigSchalterZeile extends ConsumerWidget {
  const JetztWichtigSchalterZeile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final an = ref.watch(jetztWichtigAnProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          secondary: const Icon(Icons.priority_high, color: kAccent, size: 22),
          title: const Text('Jetzt wichtig', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Überfälliges, Heutiges und der Müll ganz oben auf der Startseite, nur auf diesem Gerät', style: TextStyle(fontFamily: kFontSans, fontSize: 11, color: kTextMuted)),
          value: an,
          onChanged: (v) => unawaited(ref.read(jetztWichtigAnProvider.notifier).setzen(v)),
        ),
      ),
    );
  }
}
