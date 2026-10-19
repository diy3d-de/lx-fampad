import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../ui/widgets.dart';
import 'auth_widgets.dart';

/// Konto ist angelegt, wartet aber auf die Freigabe durch einen Admin (Gast-Einladungen, "Freigabe erforderlich").
class PendingScreen extends ConsumerWidget {
  const PendingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(authProvider.select((s) => s.user?.displayName));
    return AuthSeite(
      zurueck: false,
      maxBreite: 420,
      kinder: [
        const SizedBox(height: 24),
        const MarkenKopf(),
        const SizedBox(height: 28),
        const Align(alignment: Alignment.centerLeft, child: RollenPille('wartet auf freigabe', farbe: kWarn)),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            name == null ? 'Fast geschafft' : 'Fast geschafft, $name',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Dein Konto ist angelegt. Ein Admin der Familie muss es noch freigeben. Danach kannst du dich anmelden. '
          'Du musst hier nichts weiter tun.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 20),
        const LxCard(
          child: Row(
            children: [
              Icon(Icons.hourglass_top, color: kWarn),
              SizedBox(width: 12),
              Expanded(child: Text('Sag dem Admin kurz Bescheid, dann geht es schneller.')),
            ],
          ),
        ),
        const SizedBox(height: 20),
        HauptKnopf(text: 'Zur Anmeldung', icon: Icons.login, onPressed: ref.read(authProvider.notifier).zurAnmeldung),
      ],
    );
  }
}
