// Startseiten-Kachel "Müll" (mobil und Desktop): Datum der nächsten Abholung und die Symbole der Abfallarten dieses Tages; am Tag vor der
// Abholung ("morgen", und am Tag selbst) ist sie hervorgehoben. Tippen öffnet die Seite. Alle Familienmitglieder (auch Kinder) sehen sie.
// Sichtbar nur, wenn der Server die Abfuhrtermine eingeschaltet hat und es Termine gibt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_modelle.dart';
import '../../data/muell/muell_state.dart';
import '../../ui/widgets.dart';
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'muell_screen.dart';
import 'muell_widgets.dart';

/// Öffnet die Müll-Seite: im Desktop-Layout als Bereich der Shell (Seitenleiste und Fußzeile bleiben), sonst als eigene Seite.
void muellOeffnen(BuildContext context) {
  if (DesktopShellMarke.vorhanden(context)) {
    ProviderScope.containerOf(context).read(shellTabProvider.notifier).waehlen(kMuellTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MuellScreen())));
}

/// Der Zustand der Kachel: nächste Abholung, Abstand in Tagen und ob sie hervorgehoben wird (heute oder morgen).
class MuellKachelDaten {
  final MuellTag? abholung;
  final int tage;
  const MuellKachelDaten(this.abholung, this.tage);

  bool get hervorgehoben => abholung != null && tage >= 0 && tage <= 1;

  static MuellKachelDaten aus(MuellZustand z, DateTime jetzt) {
    final heute = muellHeute(jetzt);
    final t = naechsteAbholung(z.tage, heute);
    return MuellKachelDaten(t, t == null ? 0 : tageBis(t.tag, heute));
  }
}

String muellKachelSemantik(MuellKachelDaten d) {
  final t = d.abholung;
  if (t == null) return 'Müll: keine weitere Abholung bekannt. Öffnen';
  return 'Müll: nächste Abholung ${muellLangDatum(t.tag)}, ${artenText(t.arten)}, ${tageBisText(d.tage)}. Öffnen';
}

/// Inhalt der Kachel (ohne Rahmen und Label), von der mobilen und der Desktop-Startseite verwendet.
class MuellKachelInhalt extends StatelessWidget {
  final MuellKachelDaten daten;
  const MuellKachelInhalt({super.key, required this.daten});

  @override
  Widget build(BuildContext context) {
    final t = daten.abholung;
    if (t == null) return const Text('Keine weitere Abholung bekannt', style: TextStyle(color: kTextMuted));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(muellKurzDatum(t.tag), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: kTextStrong, letterSpacing: -0.2)),
        const SizedBox(height: 8),
        MuellSymbolReihe(t.arten),
        const SizedBox(height: 8),
        if (daten.hervorgehoben)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(999)),
              child: Text(daten.tage == 0 ? 'heute' : 'morgen', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, fontWeight: FontWeight.w500, color: kOnAccent)),
            ),
          )
        else
          Text('${tageBisText(daten.tage)} · ${artenText(t.arten)}', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: kTextMuted)),
      ],
    );
  }
}

/// Karte der mobilen Startseite; ohne Daten oder bei ausgeschaltetem Server nimmt sie keinen Platz ein.
class MuellStartKarte extends ConsumerWidget {
  const MuellStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(muellProvider);
    if (!z.hatTermine) return const SizedBox.shrink();
    final jetzt = muellJetzt(ref);
    final d = MuellKachelDaten.aus(z, jetzt);
    return Semantics(
      container: true,
      button: true,
      label: muellKachelSemantik(d),
      excludeSemantics: true,
      onTap: () => muellOeffnen(context),
      child: LxCard(
        gewaehlt: d.hervorgehoben,
        onTap: () => muellOeffnen(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoLabel(d.hervorgehoben ? 'Müll · ${d.tage == 0 ? 'heute' : 'morgen'}' : 'Müll'),
              const SizedBox(height: 10),
              MuellKachelInhalt(daten: d),
            ],
          ),
        ),
      ),
    );
  }
}
