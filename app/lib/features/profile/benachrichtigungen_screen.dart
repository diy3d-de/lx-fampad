// Profil > Benachrichtigungen: Erinnerungen (alle Plattformen) und Push (nur Android-App; im Web ein Hinweis). Die Seiten dahinter bleiben unverändert.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/erinnerungen/web_erinnerung_state.dart' show webErinnerungAnProvider;
import '../../data/push/push_state.dart';
import '../../data/wetter/wetter_hinweise.dart';
import '../../data/wetter/wetter_logik.dart' show WetterHinweisArt;
import '../../data/wetter/wetter_state.dart';
import '../wetter/wetter_hinweise_screen.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../tagesbriefing/briefing_einstellungen_ui.dart' show BriefingMorgensZeile;
import 'erinnerungen_screen.dart';
import 'profil_plattform.dart';
import 'profile_screen.dart' show EinstellungsZeile;
import 'push_screen.dart';

class BenachrichtigungenScreen extends ConsumerWidget {
  const BenachrichtigungenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final web = ref.watch(profilWebProvider);
    return AuthSeite(
      label: 'Profil',
      titel: 'Benachrichtigungen',
      maxBreite: kMaxContentWidth,
      kinder: [
        const MonoLabel('Auf diesem Gerät'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.notifications_none,
          titel: web ? 'Erinnerungen im Browser' : 'Erinnerungen',
          untertitel: web ? (ref.watch(webErinnerungAnProvider) ? 'An, nur solange die Web-App geöffnet ist' : 'Aus') : 'Terminerinnerungen auf diesem Gerät',
          onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const ErinnerungenScreen())),
        ),
        // Wetter-Hinweise: nur wenn der Server das Wetter anbietet
        Consumer(
          builder: (context, ref, _) {
            if (!ref.watch(wetterProvider.select((s) => s.dto?.verfuegbar ?? false))) return const SizedBox.shrink();
            final an = ref.watch(wetterHinweisEinstellungenProvider.select((e) => e.an.length));
            return EinstellungsZeile(
              icon: Icons.thermostat,
              titel: 'Wetter-Hinweise',
              untertitel: an == 0 ? 'Alle aus' : '$an von ${WetterHinweisArt.values.length} an',
              onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const WetterHinweiseScreen())),
            );
          },
        ),
        if (!web) const BriefingMorgensZeile(),
        if (!web)
          Consumer(
            builder: (context, ref, _) {
              final push = ref.watch(pushProvider);
              return EinstellungsZeile(
                icon: Icons.notifications_outlined,
                titel: 'Push',
                untertitel: push.gewuenscht ? (push.angemeldet ? 'Hinweise aktiv' : 'Wird eingerichtet …') : 'Aus',
                status: push.gewuenscht && push.angemeldet ? const RollenPille('an', farbe: kTerminal) : null,
                onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const PushScreen())),
              );
            },
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text('Push gibt es nur in der Android-App.', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          ),
      ],
    );
  }
}
