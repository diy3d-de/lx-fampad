// Marke "dieses Gerät ruft gerade selbst die Passwort-Sicherung ab" (automatisches Verbinden nach der Anmeldung, Verbinden mit Passwort, Passwortwechsel,
// Erneuern nach einem Reset). Der Server schreibt dabei ein Sicherheitsereignis `key_backup_pw_read`, weckt das auslösende Gerät aber nicht; liest dieses Gerät
// seine Ereignisse später selbst (App-Start), erkennt der [SicherheitsPruefer] sein eigenes Ereignis an dieser Marke und zeigt es nicht als Warnung.
// Nur ein Ereignis nahe an der Marke ([kEigenerAbrufFenster]) gilt als eigen; Abrufe anderer Geräte werden wie jedes Sicherheitsereignis gemeldet.
// Die Marke steht in `sync_meta` (Zeitpunkt, kein Inhalt) und verschwindet mit der lokalen Datenbank.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database_provider.dart';

const kEigenerPwAbrufSchluessel = 'sicherheitEigenerPwAbruf';

/// Ein Abruf der Passwort-Sicherung gilt als eigen, wenn sein Zeitpunkt höchstens so weit von der Marke entfernt liegt (Uhrabweichung eingerechnet).
const kEigenerAbrufFenster = Duration(minutes: 2);

/// Setzt die Marke (VOR dem Abruf). Wirft nie: die Marke ist ein Zusatz und darf den Ablauf nie verhindern.
final eigenerPwAbrufMarkeProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(kEigenerPwAbrufSchluessel, DateTime.now().toUtc().toIso8601String());
    } on Object {
      // ohne Marke wird ein eigener Abruf eben als Hinweis angezeigt
    }
  };
});
