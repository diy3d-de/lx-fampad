// Wetter-Hinweise (Frost, Regen, Wind, Hitze, Druckabfall): rein lokal auf dem Gerät, nichts geht an den Server. Je Art abschaltbar (`sync_meta`,
// Standard: nur Frost an). Eine gelbe Karte auf der Startseite gilt, solange der Wert auffällig ist; zusätzlich eine lokale Benachrichtigung beim Abruf,
// SOLANGE DIE APP LÄUFT (kein Hintergrunddienst, kein Push: ohne geöffnete App kommt kein Hinweis). Je Art höchstens eine Benachrichtigung in 6 Stunden.
// Texte sind neutral und kurz, nie mit Ort oder Koordinaten.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../push/chat_benachrichtiger_provider.dart' show chatAnzeigePortProvider;
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
      final db = ref.read(appDatabaseProvider);
      final an = <WetterHinweisArt>{};
      for (final a in WetterHinweisArt.values) {
        final v = await db.metaLesen(a.schluessel);
        if (v == null ? a.standardAn : v == 'ja') an.add(a);
      }
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

/// Ein Durchgang: für jeden geltenden Hinweis zeigen, wenn die Art nicht in den letzten 6 Stunden gemeldet wurde. Gemerkt wird erst nach erfolgreicher
/// Anzeige (ohne Erlaubnis oder bei einem Fehler kommt der Hinweis beim nächsten Abruf noch einmal). Nie ein Fehler nach außen.
Future<void> wetterHinweiseBenachrichtigen(Ref ref, {DateTime? jetzt}) async {
  try {
    final liste = ref.read(aktiveWetterHinweiseProvider);
    if (liste.isEmpty) return;
    final db = ref.read(appDatabaseProvider);
    final nun = jetzt ?? DateTime.now();
    final anzeige = ref.read(chatAnzeigePortProvider);
    var bereit = false;
    for (final h in liste) {
      final zuletzt = int.tryParse(await db.metaLesen(h.art.zuletztSchluessel) ?? '');
      if (zuletzt != null && nun.difference(DateTime.fromMillisecondsSinceEpoch(zuletzt)).abs() < kWetterHinweisAbstand) continue;
      if (!bereit) {
        if (!await anzeige.initialisieren()) return;
        bereit = true;
      }
      final ok = await anzeige.zeigenSicherheit(id: kWetterBenachrichtigungsId + h.art.index, titel: 'Wetter', text: h.text, nutzlast: kWetterPayload);
      if (ok) await db.metaSchreiben(h.art.zuletztSchluessel, nun.millisecondsSinceEpoch.toString());
    }
  } on Object {
    // ein Zusatz: nie den Abruf stören
  }
}
