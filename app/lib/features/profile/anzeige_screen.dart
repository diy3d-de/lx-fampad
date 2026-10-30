// Profil > Startseite und Anzeige: Startseite anpassen, Wetter-Schalter (lokal je Gerät) und das Widget "Heute" (nur Android-App).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../status/status_einstellungen_ui.dart' show StatusSchalterZeile;
import '../home/jetzt_wichtig_block.dart' show JetztWichtigSchalterZeile;
import '../tagesbriefing/briefing_einstellungen_ui.dart' show BriefingKachelZeile;
import '../home/startseite_anpassen_screen.dart';
import 'leiste_anpassen_screen.dart';
import '../wandtablet/wandtablet_einstellungen_screen.dart';
import 'heute_widget_screen.dart';
import 'profil_plattform.dart';
import 'profile_screen.dart' show EinstellungsZeile;

class AnzeigeScreen extends ConsumerWidget {
  const AnzeigeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final web = ref.watch(profilWebProvider);
    return AuthSeite(
      label: 'Profil',
      titel: 'Startseite und Anzeige',
      maxBreite: kMaxContentWidth,
      kinder: [
        const MonoLabel('Startseite'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.dashboard_customize_outlined,
          titel: 'Startseite anpassen',
          untertitel: 'Kacheln verschieben und ausblenden, nur auf diesem Gerät',
          onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const StartseiteAnpassenScreen())),
        ),
        if (MediaQuery.sizeOf(context).width < kDesktopBreakpoint)
          EinstellungsZeile(
            icon: Icons.view_agenda_outlined,
            titel: 'Untere Leiste',
            untertitel: 'Vier Bereiche und „Mehr“, nur auf diesem Gerät',
            onTap: () => Navigator.of(context).push<void>(LeisteAnpassenScreen.route()),
          ),
        const WetterZeile(),
        const JetztWichtigSchalterZeile(),
        const BriefingKachelZeile(),
        const StatusSchalterZeile(),
        EinstellungsZeile(
          icon: Icons.tv_outlined,
          titel: 'Wandtablet-Modus',
          untertitel: 'Vollbild für ein Tablet an der Wand, nur auf diesem Gerät',
          onTap: () => Navigator.of(context).push<void>(WandtabletEinstellungenScreen.route()),
        ),
        if (!web) ...[
          const SizedBox(height: 4),
          const MonoLabel('Android'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.widgets_outlined,
            titel: 'Widget „Heute“',
            untertitel: 'Auf dem Startbildschirm: Termine, Aufgaben und eine Liste',
            onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const HeuteWidgetScreen())),
          ),
        ],
      ],
    );
  }
}

/// Schalter "Wetter anzeigen" (lokal je Gerät): auch bei ausgeschaltetem Wetter erreichbar, denn dann gibt es weder Kachel noch Seitenleisten-Eintrag.
/// Meldet der Server das Wetter als nicht eingerichtet, steht nur ein Hinweis da.
class WetterZeile extends ConsumerWidget {
  const WetterZeile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(wetterProvider);
    if (st.dto != null && !st.dto!.verfuegbar) {
      return const EinstellungsZeile(icon: Icons.wb_sunny_outlined, titel: 'Wetter anzeigen', untertitel: 'Das Wetter ist auf dem Server nicht eingerichtet.');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          secondary: const Icon(Icons.wb_sunny_outlined, color: kAccent, size: 22),
          title: const Text('Wetter anzeigen', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Auf Startseite und Seitenleiste, nur auf diesem Gerät', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          value: st.anzeigen,
          onChanged: (v) => unawaited(ref.read(wetterProvider.notifier).anzeigenSetzen(v)),
        ),
      ),
    );
  }
}
