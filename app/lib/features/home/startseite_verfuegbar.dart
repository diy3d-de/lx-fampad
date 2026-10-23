// Welche Kacheln der Startseite es gerade gibt (je Layout): Müll nur mit Abfuhrterminen, Wetter nur mit Daten und eingeschaltetem Schalter, Countdown nur mit einem Countdown auf einen künftigen Termin,
// Geburtstage nur, wenn einer ansteht (dann bleibt die Kachel leer und wird nicht gezeichnet, steht aber auf der Anpassen-Seite).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/muell/muell_state.dart';
import '../../data/startseite/startseite_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../calendar/countdown_karte.dart' show countdownEintraegeProvider;
import '../calendar/geburtstage_karte.dart' show geburtstageAnstehendProvider;
import '../tasks/fristen_anzeige.dart' show dringendeFristenProvider;

KachelVerfuegbarkeit _verfuegbar(StartLayout l, {required bool muell, required bool wetter, bool geburtstage = true, bool countdown = true, bool fristen = true}) => KachelVerfuegbarkeit(
  angeboten: {
    for (final id in l.standard)
      if (!(id == 'muell' && !muell) && !(id == 'wetter' && !wetter) && !(id == 'countdown' && !countdown)) id,
  },
  leer: {if (l == StartLayout.mobil && !geburtstage) 'geburtstage', if (!fristen) 'fristen'},
);

final mobilVerfuegbarProvider = Provider.autoDispose<KachelVerfuegbarkeit>(
  (ref) => _verfuegbar(
    StartLayout.mobil,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine)),
    wetter: ref.watch(wetterProvider.select((w) => w.kachelSichtbar)),
    geburtstage: ref.watch(geburtstageAnstehendProvider.select((l) => l.isNotEmpty)),
    countdown: ref.watch(countdownEintraegeProvider.select((l) => l.isNotEmpty)),
    fristen: ref.watch(dringendeFristenProvider.select((l) => l.isNotEmpty)),
  ),
);

final desktopVerfuegbarProvider = Provider.autoDispose<KachelVerfuegbarkeit>(
  (ref) => _verfuegbar(
    StartLayout.desktop,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine)),
    wetter: ref.watch(wetterProvider.select((w) => w.kachelSichtbar)),
    countdown: ref.watch(countdownEintraegeProvider.select((l) => l.isNotEmpty)),
    fristen: ref.watch(dringendeFristenProvider.select((l) => l.isNotEmpty)),
  ),
);

Provider<KachelVerfuegbarkeit> verfuegbarProvider(StartLayout l) => l == StartLayout.mobil ? mobilVerfuegbarProvider : desktopVerfuegbarProvider;
