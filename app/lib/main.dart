import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'constants.dart';
import 'data/auth/auth_state.dart';
import 'data/calendar/zeitzonen.dart';
import 'data/crypto/e2ee_state.dart';
import 'data/database_provider.dart';
import 'data/sync_state.dart';
import 'features/auth/adresszeile.dart';
import 'features/auth/invite_intake.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        // zusätzlich verschwindet der geheime E2EE-Personenschlüssel vom Gerät (Wiederverbinden per QR oder Wiederherstellungsschlüssel)
        localDataWiperProvider.overrideWith((ref) {
          final daten = lokaleDatenWiper(ref);
          final schluessel = e2eeDatenWiper(ref);
          return () async {
            await daten();
            await schluessel();
          };
        }),
        // merkt den Besitzer der lokalen Daten: nur bei einer ANDEREN Person wird beim Anmelden geleert (nicht nach Sitzungsverlust)
        localDataOwnerProvider.overrideWith((ref) => DatenbankBesitzer(ref.read(appDatabaseProvider))),
      ],
      child: const FampadApp(),
    ),
  );
}
