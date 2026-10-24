import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'constants.dart';
import 'data/api/token_store.dart';
import 'data/auth/auth_state.dart';
import 'data/chat/chat_krypto_state.dart';
import 'data/calendar/zeitzonen.dart';
import 'data/crypto/e2ee_state.dart';
import 'data/crypto/schluessel_speicher.dart';
import 'data/database_provider.dart';
import 'data/push/chat_benachrichtiger_provider.dart';
import 'data/push/push_hintergrund.dart';
import 'data/push/push_wecker.dart';
import 'data/push/push_state.dart';
import 'data/sync_state.dart';
import 'data/teilen/teilen_state.dart';
import 'data/tresor/tresor_sperre.dart';
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
  // ein liegengebliebener Löschauftrag von "Gerät abgeben" (Löschen scheiterte) wird vor allem anderen abgearbeitet
  // (nie still: nur ohne gespeicherte Sitzung dieser Person, nur innerhalb von 24 h; eine erneute Anmeldung verwirft ihn)
  await loeschauftraegeAbarbeiten(
    schluesselSpeicherErzeugen(),
    aktiveUserId: () async => kIsWeb ? null : (await SecureTokenStore().readProfile())?['id'] as String?,
  );
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
        // der geheime E2EE-Personenschlüssel bleibt dabei im Schlüsselspeicher liegen (nur sein Zustand im Arbeitsspeicher wird verworfen); löschen kann ihn nur "Gerät abgeben"
        // unabhängig voneinander: ein Fehler beim Leeren der Datenbank darf das Verwerfen des Schlüssels im Arbeitsspeicher nie verhindern (und umgekehrt)
        localDataWiperProvider.overrideWith((ref) => wiperVerkettet([lokaleDatenWiper(ref), e2eeSitzungWiper(ref), () async => ref.invalidate(chatKryptoProvider), () async => ref.read(teilenProvider.notifier).verwerfen(), () async => ref.invalidate(tresorSperreProvider)])),
        // nach einem Push-Wecker: lokale Benachrichtigung über neue Chat-Nachrichten (ohne Inhalt)
        ereignisBenachrichtigerProvider.overrideWith((ref) => ref.watch(chatBenachrichtigerProvider)),
        // Abmelden meldet auch den Push-Endpunkt ab (Server und ntfy-App)
        pushAbmeldenProvider.overrideWith((ref) => ({required bool serverLoeschen}) => ref.read(pushProvider.notifier).beimAbmelden(serverLoeschen: serverLoeschen)),
        // eine bestätigte Sitzung verwirft einen liegengebliebenen Löschauftrag dieser Person (kein stilles Löschen nach erneuter Anmeldung)
        sitzungBestaetigtProvider.overrideWith((ref) => (userId) => loeschauftragVerwerfen(ref.read(schluesselSpeicherProvider), userId)),
        // merkt den Besitzer der lokalen Daten: nur bei einer ANDEREN Person wird beim Anmelden geleert (nicht nach Sitzungsverlust)
        localDataOwnerProvider.overrideWith((ref) => DatenbankBesitzer(ref.read(appDatabaseProvider))),
      ],
      child: const FampadApp(),
    ),
  );
}
