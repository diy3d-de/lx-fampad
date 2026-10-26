// Startseiten-Kachel "Ablesen fällig" (mobil und Desktop) und Einstieg in den Bereich. Die Kachel erscheint NUR für Eltern und Admins und nur, wenn mindestens ein Zähler abgelesen
// werden soll. Sie zeigt nur die Zahl und seit wann (nie Art, Name oder Stand). Das Wandtablet zeigt keine Zähler.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'zaehler_screen.dart';

/// Öffnet den Bereich: im Desktop-Layout als Bereich der Shell, sonst als eigene Seite. Für alle außer Eltern und Admins passiert nichts (auch nicht über Erinnerung oder Kachel).
void zaehlerOeffnen(BuildContext context) {
  final c = ProviderScope.containerOf(context);
  if (!c.read(zaehlerDarfProvider)) return;
  if (DesktopShellMarke.vorhanden(context)) {
    c.read(shellTabProvider.notifier).waehlen(kZaehlerTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(zaehlerRoute()));
}

/// Was die Kachel zeigt: wie viele Zähler abgelesen werden sollen und seit wann der älteste Solltermin offen ist.
class ZaehlerKachelDaten {
  final int faellig;
  final DateTime? seit;
  const ZaehlerKachelDaten({this.faellig = 0, this.seit});
  bool get sichtbar => faellig > 0;
}

final zaehlerKachelProvider = Provider.autoDispose<ZaehlerKachelDaten>((ref) {
  if (!ref.watch(zaehlerDarfProvider)) return const ZaehlerKachelDaten();
  final d = ref.watch(zaehlerDatenProvider);
  if (d.reihen.isEmpty) return const ZaehlerKachelDaten();
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  final heute = zaehlerHeute(jetzt);
  DateTime? seit;
  var n = 0;
  for (final r in faelligeReihen(d.reihen, heute)) {
    n++;
    final t = reiheFaelligkeit(r, heute).letzterTermin;
    if (t != null && (seit == null || t.isBefore(seit))) seit = t;
  }
  return ZaehlerKachelDaten(faellig: n, seit: seit);
});

String zaehlerKachelSemantik(ZaehlerKachelDaten d) => 'Ablesen fällig: ${d.faellig} ${d.faellig == 1 ? 'Zähler wartet' : 'Zähler warten'} auf eine Ablesung${d.seit == null ? '' : ', seit ${tagDeutsch(d.seit!)}'}. Öffnen';

/// Inhalt der Kachel (ohne Rahmen und Label), von der mobilen und der Desktop-Startseite verwendet.
class ZaehlerKachelInhalt extends StatelessWidget {
  final ZaehlerKachelDaten daten;
  const ZaehlerKachelInhalt({super.key, required this.daten});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.speed_outlined, size: 20, color: kWarn),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          '${daten.faellig} ${daten.faellig == 1 ? 'Zähler wartet' : 'Zähler warten'} auf eine Ablesung${daten.seit == null ? '' : ' · seit ${tagKurz(daten.seit!)}'}',
          style: const TextStyle(height: 1.3),
        ),
      ),
    ],
  );
}

/// Kachel der Handy-Startseite.
class ZaehlerStartKarte extends ConsumerWidget {
  const ZaehlerStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(zaehlerKachelProvider);
    if (!d.sichtbar) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: zaehlerKachelSemantik(d),
      excludeSemantics: true,
      child: LxCard(
        onTap: () => zaehlerOeffnen(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [const Expanded(child: MonoLabel('Ablesen fällig')), Text('${d.faellig}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kWarn))]),
            const SizedBox(height: 10),
            ZaehlerKachelInhalt(daten: d),
          ],
        ),
      ),
    );
  }
}
