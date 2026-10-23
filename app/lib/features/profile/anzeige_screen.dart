// Profil > Startseite und Anzeige: Startseite anpassen, Wetter-Schalter (lokal je Gerät) und das Widget "Heute" (nur Android-App).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../home/startseite_anpassen_screen.dart';
import 'heute_widget_screen.dart';
import 'profil_plattform.dart';
import 'profile_screen.dart' show EinstellungsZeile;

class AnzeigeScreen extends ConsumerWidget {
  const AnzeigeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final web = ref.watch(profilWebProvider);
    return AuthSeite(
      label: '// profil',
      titel: 'Startseite und Anzeige',
      maxBreite: kMaxContentWidth,
      kinder: [
        const MonoLabel('// startseite'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.dashboard_customize_outlined,
          titel: 'Startseite anpassen',
          untertitel: 'kacheln verschieben und ausblenden, nur dieses gerät',
          onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const StartseiteAnpassenScreen())),
        ),
        const WetterZeile(),
        if (!web) ...[
          const SizedBox(height: 4),
          const MonoLabel('// android'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.widgets_outlined,
            titel: 'Widget „Heute“',
            untertitel: 'startbildschirm: termine, aufgaben, liste',
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
      return const EinstellungsZeile(icon: Icons.wb_sunny_outlined, titel: 'Wetter anzeigen', untertitel: 'wetter ist auf dem server nicht eingerichtet');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          secondary: const Icon(Icons.wb_sunny_outlined, color: kAccent, size: 22),
          title: const Text('Wetter anzeigen', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('startseite und seitenleiste, nur auf diesem gerät', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          value: st.anzeigen,
          onChanged: (v) => unawaited(ref.read(wetterProvider.notifier).anzeigenSetzen(v)),
        ),
      ),
    );
  }
}
