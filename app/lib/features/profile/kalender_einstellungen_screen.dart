// Profil > Kalender: Einstellungen des Kalenders. Heute nur der Abschnitt "Import und Export" (ICS), die Abläufe sind die vorhandenen
// Seiten (ics_import_screen, ics_export_screen); aus dem Menü "Mehr" der Kalenderansicht ist sie über "Kalender-Einstellungen …" erreichbar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../calendar/ics_export_screen.dart';
import '../calendar/ics_import_screen.dart';
import 'profile_screen.dart' show EinstellungsZeile;

/// Öffnet die Seite "Kalender" (Unterseite wie die übrigen Profilseiten; in der Desktop-Shell im Inhalts-Navigator).
Future<void> kalenderEinstellungenOeffnen(BuildContext context) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const KalenderEinstellungenScreen()));

class KalenderEinstellungenScreen extends ConsumerWidget {
  const KalenderEinstellungenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider.select((a) => a.user));
    final darfAnlegen = TerminRechte(user?.role ?? Role.child, user?.id).darfAnlegen;
    return AuthSeite(
      label: '// kalender',
      titel: 'Kalender',
      maxBreite: kMaxContentWidth,
      kinder: [
        const MonoLabel('Import und Export'),
        const SizedBox(height: 8),
        if (darfAnlegen)
          EinstellungsZeile(
            icon: Icons.file_download_outlined,
            titel: 'Datei importieren (.ics)',
            untertitel: 'termine aus einer ics-datei übernehmen',
            onTap: () => icsImportOeffnen(context),
          ),
        EinstellungsZeile(
          icon: Icons.file_upload_outlined,
          titel: 'Kalender exportieren',
          untertitel: 'termine als ics-datei speichern',
          onTap: () => icsExportOeffnen(context),
        ),
      ],
    );
  }
}
