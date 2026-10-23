// Profil > Benachrichtigungen: Erinnerungen (alle Plattformen) und Push (nur Android-App; im Web ein Hinweis). Die Seiten dahinter bleiben unverändert.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/push/push_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
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
      label: '// profil',
      titel: 'Benachrichtigungen',
      maxBreite: kMaxContentWidth,
      kinder: [
        const MonoLabel('// auf diesem gerät'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.notifications_none,
          titel: 'Erinnerungen',
          untertitel: 'terminerinnerungen auf diesem gerät',
          onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const ErinnerungenScreen())),
        ),
        if (!web)
          Consumer(
            builder: (context, ref, _) {
              final push = ref.watch(pushProvider);
              return EinstellungsZeile(
                icon: Icons.notifications_outlined,
                titel: 'Push',
                untertitel: push.gewuenscht ? (push.angemeldet ? 'push aktiv' : 'wird eingerichtet') : 'aus',
                status: push.gewuenscht && push.angemeldet ? const RollenPille('an', farbe: kTerminal) : null,
                onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const PushScreen())),
              );
            },
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text('Push gibt es nur in der Android-App.', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          ),
      ],
    );
  }
}
