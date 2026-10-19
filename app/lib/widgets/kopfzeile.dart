// Gemeinsame Kopfzeile aller Tabs: Datum als Mono-Label ("// do, 22. okt"), Titel des Tabs, Sync-Indikator und Profil-Knopf. Nur der Titel
// ist je Tab verschieden; Datum, Indikator und Profil-Menü stehen überall gleich und gleich angeordnet (Start, Kalender, Chat, Dateien, Listen).
// Im Desktop-Layout (ab kDesktopBreakpoint) zeigen Seitenleiste (Profil) und Fußzeile (Sync) beides schon: dort bleiben Datum und Titel.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../data/auth/auth_state.dart';
import '../features/profile/profile_screen.dart';
import '../ui/widgets.dart';
import 'sync_indicator.dart';

/// Datum der Kopfzeile in Kleinschreibung ("do, 22. okt").
String kopfzeilenDatum([DateTime? jetzt]) => DateFormat('E, d. MMM', 'de_DE').format(jetzt ?? DateTime.now()).toLowerCase();

class TabKopfzeile extends StatelessWidget {
  final String title;
  const TabKopfzeile({super.key, required this.title});

  @override
  Widget build(BuildContext context) => ScreenHeader(
    label: '// ${kopfzeilenDatum()}',
    title: title,
    // Desktop-Layout: Sync-Zustand steht in der Fußzeile, das Profil unten in der Seitenleiste (nicht doppelt)
    actions: MediaQuery.sizeOf(context).width >= kDesktopBreakpoint ? const [] : const [SyncIndicator(), ProfilButton()],
  );
}

/// Profil-Knopf der Kopfzeile: zeigt das Benutzerbild der Person. Solange es keines gibt (Platzhalter), stehen die Initialen in der
/// Personenfarbe im Kreis; ohne angemeldete Person ein Symbol. [bild] ist für das spätere Benutzerbild (Avatar) vorgesehen.
class ProfilButton extends ConsumerWidget {
  final ImageProvider<Object>? bild;
  const ProfilButton({super.key, this.bild});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider.select((s) => s.user));
    return Semantics(
      button: true,
      label: 'Profil und Sicherheit',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Profil und Sicherheit',
        child: InkResponse(
          radius: 24,
          onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: user == null
                  ? const Icon(Icons.account_circle_outlined)
                  : PersonAvatar(name: user.displayName, colorIndex: user.colorIndex, size: 34, bild: bild),
            ),
          ),
        ),
      ),
    );
  }
}
