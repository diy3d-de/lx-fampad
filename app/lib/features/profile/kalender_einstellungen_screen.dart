// Profil > Kalender: Einstellungen des Kalenders. Abschnitt "Erinnerung" (Standard-Erinnerung für neue Termine, lokal je Gerät) und
// Abschnitt "Import und Export" (ICS), die Abläufe sind die vorhandenen Seiten (ics_import_screen, ics_export_screen); aus dem Menü "Mehr"
// der Kalenderansicht ist sie über "Kalender-Einstellungen …" erreichbar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/erinnerungen/erinnerung_einstellungen.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_state.dart' show erinnerungText;
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import '../calendar/ics_export_screen.dart';
import '../calendar/ics_import_screen.dart';
import 'profile_screen.dart' show EinstellungsZeile;

/// Öffnet die Seite "Kalender" (Unterseite wie die übrigen Profilseiten; in der Desktop-Shell im Inhalts-Navigator).
Future<void> kalenderEinstellungenOeffnen(BuildContext context) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const KalenderEinstellungenScreen()));

/// Kurztext der Standard-Erinnerung für die Zeile ("1 Stunde vorher", "Keine").
String standardErinnerungKurz(int? min) => min == null ? 'Keine' : erinnerungText(min);

class KalenderEinstellungenScreen extends ConsumerWidget {
  const KalenderEinstellungenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider.select((a) => a.user));
    final darfAnlegen = TerminRechte(user?.role ?? Role.child, user?.id).darfAnlegen;
    final standard = ref.watch(erinnerungEinstellungenProvider.select((e) => e.standardVorlauf));
    return AuthSeite(
      label: 'Kalender',
      titel: 'Kalender',
      maxBreite: kMaxContentWidth,
      kinder: [
        const MonoLabel('Erinnerung'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.notifications_none,
          titel: 'Standard-Erinnerung',
          untertitel: 'Gilt für neue Termine: ${standardErinnerungKurz(standard)}. Beim Anlegen kannst du sie ändern.',
          onTap: () => unawaited(standardErinnerungWaehlen(context)),
        ),
        const SizedBox(height: 12),
        const MonoLabel('Import und Export'),
        const SizedBox(height: 8),
        if (darfAnlegen)
          EinstellungsZeile(
            icon: Icons.file_download_outlined,
            titel: 'Datei importieren (.ics)',
            untertitel: 'Termine aus einer ICS-Datei übernehmen',
            onTap: () => icsImportOeffnen(context),
          ),
        EinstellungsZeile(
          icon: Icons.file_upload_outlined,
          titel: 'Kalender exportieren',
          untertitel: 'Termine als ICS-Datei speichern',
          onTap: () => icsExportOeffnen(context),
        ),
      ],
    );
  }
}

/// Auswahl-Blatt der Standard-Erinnerung (dieselben Werte wie im Termin-Editor, plus "Keine" als eigener Wert).
Future<void> standardErinnerungWaehlen(BuildContext context) => showModalBottomSheet<void>(
  useRootNavigator: false,
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (_) => const _StandardErinnerungBlatt(),
);

class _StandardErinnerungBlatt extends ConsumerWidget {
  const _StandardErinnerungBlatt();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gewaehlt = ref.watch(erinnerungEinstellungenProvider.select((e) => e.standardVorlauf));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Standard-Erinnerung', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'Gilt für neue Termine auf diesem Gerät. Ganztägige Termine erinnern ab 09:00 Uhr. Ändern kannst du sie bei jedem Termin.',
              style: TextStyle(fontSize: 13, color: kTextMuted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in kStandardVorlaeufe)
                  AuswahlKnopf(
                    text: m == null ? 'Keine' : erinnerungText(m).replaceAll(' vorher', ''),
                    gewaehlt: gewaehlt == m,
                    onTap: () {
                      unawaited(ref.read(erinnerungEinstellungenProvider.notifier).vorlaufSetzen(m));
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
