// Welche Kacheln der Startseite es gerade gibt (je Layout): Müll nur mit Abfuhrterminen, Wetter nur mit Daten und eingeschaltetem Schalter,
// Geburtstage nur, wenn einer ansteht (dann bleibt die Kachel leer und wird nicht gezeichnet, steht aber auf der Anpassen-Seite).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/muell/muell_state.dart';
import '../../data/startseite/startseite_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../calendar/geburtstage_karte.dart' show geburtstageVorhandenProvider;

KachelVerfuegbarkeit _verfuegbar(StartLayout l, {required bool muell, required bool wetter, bool geburtstage = true}) => KachelVerfuegbarkeit(
  angeboten: {
    for (final id in l.standard)
      if (!(id == 'muell' && !muell) && !(id == 'wetter' && !wetter)) id,
  },
  leer: {if (l == StartLayout.mobil && !geburtstage) 'geburtstage'},
);

final mobilVerfuegbarProvider = Provider.autoDispose<KachelVerfuegbarkeit>(
  (ref) => _verfuegbar(
    StartLayout.mobil,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine)),
    wetter: ref.watch(wetterProvider.select((w) => w.kachelSichtbar)),
    geburtstage: ref.watch(geburtstageVorhandenProvider),
  ),
);

final desktopVerfuegbarProvider = Provider.autoDispose<KachelVerfuegbarkeit>(
  (ref) => _verfuegbar(
    StartLayout.desktop,
    muell: ref.watch(muellProvider.select((m) => m.hatTermine)),
    wetter: ref.watch(wetterProvider.select((w) => w.kachelSichtbar)),
  ),
);

Provider<KachelVerfuegbarkeit> verfuegbarProvider(StartLayout l) => l == StartLayout.mobil ? mobilVerfuegbarProvider : desktopVerfuegbarProvider;
