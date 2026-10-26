// Startseiten-Kachel "Heute im Überblick" (Tagesbriefing): Termine, Aufgaben, Fristen, Abfuhrtermine und Wetter des Tages als kurze, ganze Sätze. Nur lokal berechnet
// (data/tagesbriefing/briefing_logik.dart), kein Server. Die Kachel gibt es nur mit eingeschaltetem Schalter und nur, wenn es etwas zu zeigen gibt.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart' show kalenderDatenProvider;
import '../../data/muell/muell_state.dart' show muellProvider;
import '../../data/tagesbriefing/briefing_einstellungen.dart';
import '../../data/tagesbriefing/briefing_logik.dart';
import '../../data/tasks/aufgabe_logik.dart' show tagVon;
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../../data/wetter/vorhersage_logik.dart' show vorhersageVeraltet;
import '../../data/wetter/vorhersage_modelle.dart' show VorhersageTag;
import '../../data/wetter/vorhersage_state.dart' show vorhersageProvider;
import '../../data/wetter/wetter_state.dart' show wetterProvider;
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;

/// Das Briefing des heutigen Tages (leer, solange die Person nicht angemeldet ist). Das Wetter fließt nur ein, wenn die Wetter-Kachel an ist und die Vorhersage frisch ist.
final tagesbriefingProvider = Provider.autoDispose<Tagesbriefing>((ref) {
  final ich = ref.watch(authProvider.select((a) => a.user?.id));
  final rolle = ref.watch(authProvider.select((a) => a.user?.role));
  if (ich == null) return const Tagesbriefing();
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  final muell = ref.watch(muellProvider.select((m) => m.hatTermine ? m.tage : null));
  VorhersageTag? wetter;
  // die Vorhersage wird nur beobachtet (und damit geholt), wenn die Wetter-Kachel überhaupt an ist
  if (ref.watch(wetterProvider.select((w) => w.kachelSichtbar))) {
    final teil = ref.watch(vorhersageProvider.select((v) => v.dto?.vorhersage));
    if (teil != null && !vorhersageVeraltet(teil, jetzt)) {
      final heute = tagVon(jetzt);
      wetter = teil.tage.where((t) => t.datum.year == heute.year && t.datum.month == heute.month && t.datum.day == heute.day).firstOrNull;
    }
  }
  return baueTagesbriefing(
    kalender: ref.watch(kalenderDatenProvider),
    aufgaben: ref.watch(aufgabenProvider).value ?? const [],
    ich: ich,
    elternRolle: rolle == Role.admin || rolle == Role.parent,
    jetzt: jetzt,
    muell: muell,
    wetter: wetter,
  );
});

/// Zustand der Kachel für die Verfügbarkeit (startseite_verfuegbar.dart): [angeboten] = Schalter an, [leer] = gerade nichts zu zeigen.
final briefingKachelProvider = Provider.autoDispose<({bool angeboten, bool leer})>((ref) {
  final an = ref.watch(briefingEinstellungenProvider.select((e) => e.kachelAn));
  if (!an) return (angeboten: false, leer: true);
  return (angeboten: true, leer: !ref.watch(tagesbriefingProvider.select((b) => b.hatInhalt)));
});

IconData _symbol(BriefingArt a) => switch (a) {
  BriefingArt.termine => Icons.event_outlined,
  BriefingArt.aufgaben => Icons.task_alt_outlined,
  BriefingArt.fristen => Icons.flag_outlined,
  BriefingArt.muell => Icons.delete_outline,
  BriefingArt.wetter => Icons.wb_sunny_outlined,
};

/// Die Kachel (mobile und Desktop-Startseite). Ohne Inhalt oder bei ausgeschaltetem Schalter wird nichts gezeichnet.
class BriefingStartKarte extends ConsumerWidget {
  const BriefingStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(briefingKachelProvider);
    final b = ref.watch(tagesbriefingProvider);
    if (!k.angeboten || !b.hatInhalt) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: 'Heute im Überblick: ${b.zeilen.map((z) => z.text).join(' ')}',
      excludeSemantics: true,
      child: LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('Heute im Überblick'),
            const SizedBox(height: 12),
            for (final (i, z) in b.zeilen.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 1), child: Icon(_symbol(z.art), size: 18, color: kAccent)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(z.text, style: const TextStyle(fontSize: 14, height: 1.35, color: kText))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
