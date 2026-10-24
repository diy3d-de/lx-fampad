// Wetter-Hinweise (Frost, Regen, Wind, Hitze, Druckabfall): Die Auswertung geschieht immer lokal auf dem Gerät (aus der Antwort von GET /weather). Je Art
// abschaltbar (`sync_meta`, Standard: nur Frost an). Eine gelbe Karte auf der Startseite gilt, solange der Wert auffällig ist; zusätzlich eine lokale
// Benachrichtigung nach einem frischen Abruf. Bei geschlossener App weckt der Server das Gerät (Push-Wecker ohne Inhalt, `wetter_hintergrund.dart`), wenn er
// einen Übergang erkennt; der Server erfährt dafür nur, WELCHE Arten das Gerät will (`wetter_meldung.dart`), nie Inhalte oder Standort. Ohne eingerichtetes
// Push gilt weiter nur die offene App. Je Art höchstens eine Benachrichtigung in 6 Stunden (auch auf dem Gerät). Texte sind neutral und kurz, nie mit Ort
// oder Koordinaten. Im Wandtablet-Betrieb gibt es keine Benachrichtigung.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../app_database.dart';
import '../database_provider.dart';
import '../push/chat_benachrichtiger.dart' show ChatAnzeigePort;
import '../push/chat_benachrichtiger_provider.dart' show chatAnzeigePortProvider;
import '../wandtablet/wandtablet_einstellungen.dart';
import 'wetter_logik.dart';
import 'wetter_state.dart';

const int kWetterBenachrichtigungsId = 0x700010; // + Index der Art (0x700010 bis 0x700014)
const kWetterPayload = 'wetter';
bool istWetterPayload(String? payload) => payload == kWetterPayload;

/// Mindestabstand zwischen zwei Benachrichtigungen derselben Art.
const kWetterHinweisAbstand = Duration(hours: 6);

/// Älter als dies ist der Abruf zu alt, um darauf zu warnen (Offline-Stand, lange pausierte App).
const kWetterHinweisMaxAlter = Duration(minutes: 40);

extension WetterHinweisArtText on WetterHinweisArt {
  String get titel => switch (this) {
    WetterHinweisArt.frost => 'Frostwarnung',
    WetterHinweisArt.regen => 'Regen beginnt',
    WetterHinweisArt.wind => 'Starker Wind',
    WetterHinweisArt.hitze => 'Hitze',
    WetterHinweisArt.druck => 'Luftdruck fällt schnell',
  };
  String get erklaerung => switch (this) {
    WetterHinweisArt.frost => 'wenn die Temperatur unter 2 °C fällt',
    WetterHinweisArt.regen => 'wenn die Station Regen misst, nachdem es trocken war',
    WetterHinweisArt.wind => 'Böen über 50 km/h',
    WetterHinweisArt.hitze => 'über 30 °C',
    WetterHinweisArt.druck => 'mehr als 4 hPa in 3 Stunden',
  };
  bool get standardAn => this == WetterHinweisArt.frost;
  String get schluessel => 'wetter_hinweis_$name';
  String get zuletztSchluessel => 'wetter_hinweis_zuletzt_$name';
}

/// Die eingeschalteten Arten aus `sync_meta` (fehlt der Wert: Standard der Art). Auch die Hintergrund-Engine liest so.
Future<Set<WetterHinweisArt>> wetterArtenLesen(AppDatabase db) async {
  final an = <WetterHinweisArt>{};
  for (final a in WetterHinweisArt.values) {
    final v = await db.metaLesen(a.schluessel);
    if (v == null ? a.standardAn : v == 'ja') an.add(a);
  }
  return an;
}

class WetterHinweisEinstellungen {
  final Set<WetterHinweisArt> an;
  final bool geladen;
  const WetterHinweisEinstellungen({required this.an, required this.geladen});
}

class WetterHinweisEinstellungenNotifier extends Notifier<WetterHinweisEinstellungen> {
  @override
  WetterHinweisEinstellungen build() {
    ref.watch(authProvider.select((s) => s.user?.id));
    unawaited(_lesen());
    return WetterHinweisEinstellungen(an: {for (final a in WetterHinweisArt.values) if (a.standardAn) a}, geladen: false);
  }

  Future<void> _lesen() async {
    try {
      final an = await wetterArtenLesen(ref.read(appDatabaseProvider));
      if (!ref.mounted) return;
      state = WetterHinweisEinstellungen(an: an, geladen: true);
    } on Object {
      if (ref.mounted) state = WetterHinweisEinstellungen(an: state.an, geladen: true);
    }
  }

  Future<void> setzen(WetterHinweisArt art, bool an) async {
    state = WetterHinweisEinstellungen(an: {...state.an.where((a) => a != art), if (an) art}, geladen: true);
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(art.schluessel, an ? 'ja' : 'nein');
    } on Object {
      // nicht speicherbar: gilt bis zum Schließen
    }
  }
}

final wetterHinweisEinstellungenProvider = NotifierProvider<WetterHinweisEinstellungenNotifier, WetterHinweisEinstellungen>(WetterHinweisEinstellungenNotifier.new);

/// Die gerade geltenden Hinweise (leer bei Offline-Stand, altem Abruf, ausgeschaltetem Wetter oder wenn nichts auffällt).
final aktiveWetterHinweiseProvider = Provider<List<WetterHinweis>>((ref) {
  final einst = ref.watch(wetterHinweisEinstellungenProvider);
  if (!einst.geladen || einst.an.isEmpty) return const [];
  final st = ref.watch(wetterProvider);
  final abgerufen = st.abgerufen;
  if (st.fehler || abgerufen == null || DateTime.now().difference(abgerufen) > kWetterHinweisMaxAlter) return const [];
  return aktiveHinweise(st.dto, einst.an);
});

/// Tipp auf eine Wetter-Benachrichtigung: die Shell öffnet die Wetter-Seite.
class WetterOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final wetterOeffnenProvider = NotifierProvider<WetterOeffnenAnforderung, int>(WetterOeffnenAnforderung.new);

/// Zeigt nach jedem frischen Abruf die Benachrichtigungen für neu auffällige Werte (höchstens einmal je Art in 6 Stunden). Läuft nur mit mindestens
/// einer eingeschalteten Art (sonst fragt die App im Hintergrund gar nicht nach dem Wetter) und nur, solange die App läuft. Am Wurzel-Widget gelesen.
final wetterHinweisSteuerungProvider = Provider<void>((ref) {
  if (kIsWeb) return; // im Browser gibt es keine lokalen Benachrichtigungen
  if (ref.watch(authProvider.select((s) => s.user?.id)) == null) return;
  final einst = ref.watch(wetterHinweisEinstellungenProvider);
  if (!einst.geladen || einst.an.isEmpty) return;
  ref.listen(wetterProvider, (alt, neu) {
    if (neu.fehler || neu.abgerufen == null || neu.abgerufen == alt?.abgerufen) return;
    unawaited(wetterHinweiseBenachrichtigen(ref));
  });
});

/// Ergebnis von [wetterHinweiseZeigen].
enum WetterZeigen { nichts, schonGemeldet, gezeigt, keineErlaubnis }

/// Zeigt für jeden Hinweis der Liste die Benachrichtigung, wenn die Art nicht in den letzten 6 Stunden gemeldet wurde. Gemerkt wird erst nach erfolgreicher
/// Anzeige (ohne Erlaubnis oder bei einem Fehler kommt der Hinweis beim nächsten Abruf noch einmal). Gemeinsam für die laufende App und den Hintergrund-Start.
Future<WetterZeigen> wetterHinweiseZeigen({required AppDatabase db, required ChatAnzeigePort anzeige, required List<WetterHinweis> liste, required DateTime nun}) async {
  if (liste.isEmpty) return WetterZeigen.nichts;
  var bereit = false;
  var gezeigt = false;
  var unterdrueckt = false;
  var verweigert = false;
  for (final h in liste) {
    final zuletzt = int.tryParse(await db.metaLesen(h.art.zuletztSchluessel) ?? '');
    if (zuletzt != null && nun.difference(DateTime.fromMillisecondsSinceEpoch(zuletzt)).abs() < kWetterHinweisAbstand) {
      unterdrueckt = true;
      continue;
    }
    if (!bereit) {
      if (!await anzeige.initialisieren()) return WetterZeigen.keineErlaubnis;
      bereit = true;
    }
    final ok = await anzeige.zeigenSicherheit(id: kWetterBenachrichtigungsId + h.art.index, titel: 'Wetter', text: h.text, nutzlast: kWetterPayload);
    if (ok) {
      await db.metaSchreiben(h.art.zuletztSchluessel, nun.millisecondsSinceEpoch.toString());
      gezeigt = true;
    } else {
      verweigert = true;
    }
  }
  if (gezeigt) return WetterZeigen.gezeigt;
  if (verweigert) return WetterZeigen.keineErlaubnis;
  return unterdrueckt ? WetterZeigen.schonGemeldet : WetterZeigen.nichts;
}

/// Ein Durchgang in der laufenden App (nach einem frischen Abruf). Nie ein Fehler nach außen. Im Wandtablet-Betrieb kommt nichts.
Future<void> wetterHinweiseBenachrichtigen(Ref ref, {DateTime? jetzt}) async {
  try {
    if (ref.read(wandtabletLaeuftProvider)) return;
    final liste = ref.read(aktiveWetterHinweiseProvider);
    if (liste.isEmpty) return;
    await wetterHinweiseZeigen(db: ref.read(appDatabaseProvider), anzeige: ref.read(chatAnzeigePortProvider), liste: liste, nun: jetzt ?? DateTime.now());
  } on Object {
    // ein Zusatz: nie den Abruf stören
  }
}
