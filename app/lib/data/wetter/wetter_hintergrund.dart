// Wetterprüfung im Hintergrund-Start nach einem Push-Wecker (Wetter-Hinweise bei geschlossener App). Der Server weckt ein Gerät OHNE Inhalt, wenn die
// Auswertung seines Wetter-Dienstes einen Übergang erkennt (z. B. Frost beginnt) und das Gerät die Art eingeschaltet hat. Das Gerät holt daraufhin selbst
// `GET /weather`, wertet mit derselben lokalen Logik aus wie bei offener App (`aktiveHinweise`) und zeigt die neutrale lokale Benachrichtigung.
//
// Regeln:
//  - Nur mit mindestens einer eingeschalteten Art; sonst gar kein Netzzugriff.
//  - Im Wandtablet-Betrieb keine Benachrichtigung und auch kein Abruf (Bildschirm offen oder "Beim Start automatisch starten" an).
//  - Höchstens ein Abruf je 10 Minuten (der letzte Abruf der App oder dieses Weges steht in `wetter_cache`): Chat-Wecker lösen so keine Wetter-Flut aus.
//  - Das Zugangstoken erneuert der Hintergrund-Client selbst genau einmal je Lauf (`hintergrundErneuern`); scheitert es: Diagnose `sitzung_verloren`.
//  - Entprellung wie bei offener App (je Art höchstens alle 6 Stunden, gemerkt erst nach erfolgreicher Anzeige); ein veralteter Stand warnt nie.
//  - Diagnose (Profil > Benachrichtigungen > Push): Zeit und fester Code, nie Werte (`kDiagWetter`).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../api/models.dart';
import '../app_database.dart';
import '../auth/auth_state.dart' show apiProvider;
import '../database_provider.dart';
import '../push/chat_benachrichtiger.dart' show ChatAnzeigePort;
import '../push/chat_benachrichtiger_provider.dart' show chatAnzeigePortProvider;
import '../standort/standort_hinweis.dart' show kDiagWetter, standortDiagnoseSchreiben;
import '../wandtablet/wandtablet_einstellungen.dart';
import 'wetter_hinweise.dart';
import 'wetter_logik.dart' show aktiveHinweise;
import 'wetter_state.dart' show kWetterCacheSchluessel;

/// Mindestabstand zwischen zwei Abrufen des Wetters (App und Hintergrund zusammen).
const kWetterHintergrundAbstand = Duration(minutes: 10);

/// Obergrenze eines Laufs (Android lässt dem Hintergrund-Start nur wenige Sekunden).
const kWetterHintergrundDauer = Duration(seconds: 20);

class WetterHintergrundPruefer {
  final FampadApi api;
  final AppDatabase db;
  final ChatAnzeigePort anzeige;

  /// Läuft das Gerät im Wandtablet-Betrieb?
  final Future<bool> Function() wandtablet;
  final DateTime Function() jetzt;
  WetterHintergrundPruefer({required this.api, required this.db, required this.anzeige, required this.wandtablet, DateTime Function()? jetzt}) : jetzt = jetzt ?? DateTime.now;

  /// Ein Lauf; schreibt die Diagnose. Wirft nie.
  Future<void> pruefen({Duration mindestAbstand = kWetterHintergrundAbstand, Duration hoechstdauer = kWetterHintergrundDauer}) async {
    var code = 'fehler';
    try {
      code = await _lauf(mindestAbstand).timeout(hoechstdauer, onTimeout: () => 'fehler');
    } on Object {
      code = 'fehler';
    }
    await standortDiagnoseSchreiben(db, kDiagWetter, code, jetzt());
  }

  Future<String> _lauf(Duration mindestAbstand) async {
    final an = await wetterArtenLesen(db);
    if (an.isEmpty) return 'aus';
    if (await wandtablet()) return 'wandtablet';
    final letzter = await _letzterAbruf();
    if (letzter != null && jetzt().difference(letzter).abs() < mindestAbstand) return 'kurz_her';
    final Map<String, dynamic> roh;
    try {
      roh = await api.wetterRoh();
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.nichtAngemeldet) return 'sitzung_verloren';
      return e.istNetzwerk ? 'offline' : 'fehler';
    }
    final nun = jetzt();
    final dto = WetterDto.fromJson(roh);
    try {
      await db.metaSchreiben(kWetterCacheSchluessel, jsonEncode({'abgerufen': nun.toIso8601String(), 'daten': roh}));
    } on Object {
      // nicht speicherbar: der Mindestabstand greift dann nicht, mehr nicht
    }
    if (!dto.verfuegbar) return 'nicht_verfuegbar';
    final ergebnis = await wetterHinweiseZeigen(db: db, anzeige: anzeige, liste: aktiveHinweise(dto, an), nun: nun);
    return switch (ergebnis) {
      WetterZeigen.nichts => 'ok',
      WetterZeigen.schonGemeldet => 'schon_gemeldet',
      WetterZeigen.gezeigt => 'gezeigt',
      WetterZeigen.keineErlaubnis => 'keine_erlaubnis',
    };
  }

  Future<DateTime?> _letzterAbruf() async {
    try {
      final cache = await db.metaLesen(kWetterCacheSchluessel);
      if (cache == null) return null;
      final m = jsonDecode(cache) as Map<String, dynamic>;
      return DateTime.tryParse(m['abgerufen'] as String? ?? '');
    } on Object {
      return null;
    }
  }
}

final wetterHintergrundPrueferProvider = Provider<WetterHintergrundPruefer>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return WetterHintergrundPruefer(
    api: ref.watch(apiProvider),
    db: db,
    anzeige: ref.watch(chatAnzeigePortProvider),
    wandtablet: () async {
      try {
        return ref.read(wandtabletLaeuftProvider) || await db.metaLesen(kWandAutostartSchluessel) == 'ja';
      } on Object {
        return false;
      }
    },
  );
});
