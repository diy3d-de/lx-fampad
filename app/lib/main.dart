import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'constants.dart';
import 'data/auth/auth_state.dart';
import 'data/database_provider.dart';
import 'features/auth/adresszeile.dart';
import 'features/auth/invite_intake.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pruefeBasisAdressen();
  await initializeDateFormatting('de_DE');
  // Web: Ein Einladungslink (#/einladung/<token>) wird sofort gelesen und aus der Adresszeile entfernt (history.replaceState),
  // noch bevor die Oberfläche startet. Das Token bleibt nur im Arbeitsspeicher.
  final link = einladungAusAdresszeileNehmen();
  runApp(
    ProviderScope(
      overrides: [
        inviteIntakeProvider.overrideWith(() => InviteIntake(vorhanden: link != null, anfang: link?.token)),
        // Abmelden leert die lokale Datenbank (Phase 1c ergänzt die Fachtabellen in AppDatabase.alleDatenLoeschen)
        localDataWiperProvider.overrideWith((ref) => () => ref.read(appDatabaseProvider).alleDatenLoeschen()),
      ],
      child: const FampadApp(),
    ),
  );
}
