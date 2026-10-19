import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'constants.dart';
import 'data/auth/auth_state.dart';
import 'data/calendar/zeitzonen.dart';
import 'data/database_provider.dart';
import 'data/push/push_hintergrund.dart';
import 'data/push/push_state.dart';
import 'data/sync_state.dart';
import 'features/auth/adresszeile.dart';
import 'features/auth/invite_intake.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hintergrund-Start durch einen Push-Wecker (UnifiedPush-Dienst, App geschlossen): keine Oberfläche, nur abgleichen
  if (args.contains(kPushHintergrundArgument)) {
    await pushHintergrundStarten();
    return;
  }
  pruefeBasisAdressen();
  await initializeDateFormatting('de_DE');
  // Zeitzonen-Daten für Terminserien (Asset der App; schlägt das Laden fehl, rechnet die Anzeige mit UTC statt abzustürzen)
  try {
    await zeitzonenLaden();
  } catch (_) {}
  // Web: Ein Einladungslink (#/einladung/<token>) wird sofort gelesen und aus der Adresszeile entfernt (history.replaceState),
  // noch bevor die Oberfläche startet. Das Token bleibt nur im Arbeitsspeicher.
  final link = einladungAusAdresszeileNehmen();
  runApp(
    ProviderScope(
      overrides: [
        inviteIntakeProvider.overrideWith(() => InviteIntake(vorhanden: link != null, anfang: link?.token)),
        // Abmelden leert die lokale Datenbank (Listen, Ausgang, Sync-Zustand); vorher wird der Sync angehalten, damit eine noch
        // laufende Antwort nicht in die geleerte Datenbank schreibt
        localDataWiperProvider.overrideWith(lokaleDatenWiper),
        // Abmelden meldet auch den Push-Endpunkt ab (Server und ntfy-App)
        pushAbmeldenProvider.overrideWith((ref) => ({required bool serverLoeschen}) => ref.read(pushProvider.notifier).beimAbmelden(serverLoeschen: serverLoeschen)),
        // merkt den Besitzer der lokalen Daten: nur bei einer ANDEREN Person wird beim Anmelden geleert (nicht nach Sitzungsverlust)
        localDataOwnerProvider.overrideWith((ref) => DatenbankBesitzer(ref.read(appDatabaseProvider))),
      ],
      child: const FampadApp(),
    ),
  );
}
