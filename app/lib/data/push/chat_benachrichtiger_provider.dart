// Verdrahtung des Chat-Benachrichtigers: Datenbank, Anzeige (Android: Plugin), Einstellung "Titel auf dem Sperrbildschirm" der Erinnerungen. Wird als
// [ereignisBenachrichtigerProvider] eingesetzt (main.dart und der Hintergrund-Start, push_hintergrund.dart).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database_provider.dart';
import '../erinnerungen/erinnerung_einstellungen.dart';
import 'chat_anzeige_port_stub.dart' if (dart.library.io) 'chat_anzeige_port_io.dart';
import 'chat_benachrichtiger.dart';
import 'push_wecker.dart';

final chatAnzeigePortProvider = Provider<ChatAnzeigePort>((ref) => chatAnzeigePortErzeugen());

final chatBenachrichtigerProvider = Provider<EreignisBenachrichtiger>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return ChatBenachrichtiger(
    db: db,
    anzeige: ref.watch(chatAnzeigePortProvider),
    ich: () async {
      try {
        return await db.besitzerLesen();
      } catch (_) {
        return null;
      }
    },
    sperrbildschirmTitel: () async {
      try {
        return (await ref.read(erinnerungSpeicherProvider).lesen())[kSperrbildschirmSchluessel] == 'ja';
      } catch (_) {
        return false;
      }
    },
    istVordergrund: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );
});
