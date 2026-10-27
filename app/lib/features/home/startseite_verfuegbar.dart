// Welche Kacheln der Startseite es gerade gibt (je Layout): Müll nur mit Abfuhrterminen, Wetter nur mit Daten und eingeschaltetem Schalter, Countdown nur mit einem Countdown auf einen künftigen Termin,
// Geburtstage nur, wenn einer ansteht (dann bleibt die Kachel leer und wird nicht gezeichnet, steht aber auf der Anpassen-Seite).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dateien/datei_state.dart' show dateienVerfuegbarProvider;
import '../../data/muell/muell_state.dart';
import '../../data/startseite/startseite_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../calendar/countdown_karte.dart' show countdownEintraegeProvider;
import '../calendar/geburtstage_karte.dart' show geburtstageAnstehendProvider;
import '../tasks/fristen_anzeige.dart' show dringendeFristenProvider;
import '../medikamente/medikament_anzeige.dart' show medikamenteVorhandenProvider;
import '../medikamente/medikamente_karte.dart' show medKachelProvider;
import '../zaehler/zaehler_anzeige.dart' show zaehlerVorhandenProvider;
import '../zaehler/zaehler_karte.dart' show zaehlerKachelProvider;
import '../../data/status/status_state.dart' show statusAnzeigenProvider;
import '../tagesbriefing/briefing_karte.dart' show briefingKachelProvider;

KachelVerfuegbarkeit _verfuegbar(StartLayout l, {required bool muell, required bool wetter, bool geburtstage = true, bool countdown = true, bool fristen = true, bool medikamente = false, bool medikamenteOffen = false, bool zaehler = false, bool zaehlerOffen = false, bool dateien = false, bool briefing = true, bool briefingLeer = false, bool status = true}) => KachelVerfuegbarkeit(
  angeboten: {
    for (final id in l.standard)
      if (!(id == 'muell' && !muell) && !(id == 'wetter' && !wetter) && !(id == 'countdown' && !countdown) && !(id == 'medikamente' && !medikamente) && !(id == 'zaehler' && !zaehler) && !(id == 'dateien' && !dateien) && !(id == 'tagesbriefing' && !briefing) && !(id == 'status' && !status)) id,
  },
  leer: {if (l == StartLayout.mobil && !geburtstage) 'geburtstage', if (!fristen) 'fristen', if (!medikamenteOffen) 'medikamente', if (!zaehlerOffen) 'zaehler', if (briefingLeer) 'tagesbriefing'},
);

final mobilVerfuegbarProvider = Provider.autoDispose<KachelVerfuegbarkeit>(
  (ref) => _verfuegbar(
    StartLayout.mobil,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine)),
    wetter: ref.watch(wetterProvider.select((w) => w.kachelSichtbar)),
    geburtstage: ref.watch(geburtstageAnstehendProvider.select((l) => l.isNotEmpty)),
    countdown: ref.watch(countdownEintraegeProvider.select((l) => l.isNotEmpty)),
    fristen: ref.watch(dringendeFristenProvider.select((l) => l.isNotEmpty)),
    medikamente: ref.watch(medikamenteVorhandenProvider),
    medikamenteOffen: ref.watch(medKachelProvider.select((k) => k.sichtbar)),
    zaehler: ref.watch(zaehlerVorhandenProvider),
    zaehlerOffen: ref.watch(zaehlerKachelProvider.select((k) => k.sichtbar)),
    briefing: ref.watch(briefingKachelProvider.select((k) => k.angeboten)),
    briefingLeer: ref.watch(briefingKachelProvider.select((k) => k.leer)),
    status: ref.watch(statusAnzeigenProvider),
  ),
);

final desktopVerfuegbarProvider = Provider.autoDispose<KachelVerfuegbarkeit>(
  (ref) => _verfuegbar(
    StartLayout.desktop,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine)),
    wetter: ref.watch(wetterProvider.select((w) => w.kachelSichtbar)),
    countdown: ref.watch(countdownEintraegeProvider.select((l) => l.isNotEmpty)),
    fristen: ref.watch(dringendeFristenProvider.select((l) => l.isNotEmpty)),
    medikamente: ref.watch(medikamenteVorhandenProvider),
    medikamenteOffen: ref.watch(medKachelProvider.select((k) => k.sichtbar)),
    zaehler: ref.watch(zaehlerVorhandenProvider),
    zaehlerOffen: ref.watch(zaehlerKachelProvider.select((k) => k.sichtbar)),
    briefing: ref.watch(briefingKachelProvider.select((k) => k.angeboten)),
    briefingLeer: ref.watch(briefingKachelProvider.select((k) => k.leer)),
    dateien: ref.watch(dateienVerfuegbarProvider).value ?? false,
    status: ref.watch(statusAnzeigenProvider),
  ),
);

Provider<KachelVerfuegbarkeit> verfuegbarProvider(StartLayout l) => l == StartLayout.mobil ? mobilVerfuegbarProvider : desktopVerfuegbarProvider;
