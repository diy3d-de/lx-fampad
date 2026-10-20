// Karte (docs/KARTE-SPIKE.md): Adressen, Kartenbereich und Stil-Vorlage. Alles kommt vom eigenen Server (kein Fremd-Anbieter, keine Tracker).
// Style (assets/karte/style.json) und Glyphen/Sprites sind statisch; nur die absoluten Adressen setzt die App zur Laufzeit ein,
// weil MapLibre Native (Android) keine relativen Adressen auflöst. Die PMTiles-Datei liegt unter /karte-daten/ (deploy/einrichtung-karte.sh).
import 'package:flutter/foundation.dart';

import '../../constants.dart';

/// Basisadresse für die Karte. Reihenfolge: --dart-define=KARTE_BASE, API_BASE, im Web die eigene Herkunft, sonst die Produktion.
const kKarteBase = String.fromEnvironment('KARTE_BASE', defaultValue: '');

/// Glyphen und Sprites (Teil des Web-Builds, `app/web/karte/`).
const kKarteStatischPfad = '/karte';

/// Kacheln: eine PMTiles-Datei, vom Caddy mit Range-Anfragen ausgeliefert.
const kKarteKachelPfad = '/karte-daten/westerwald.pmtiles';

/// Umschließendes Rechteck der Kartendatei (steht im Kopf der PMTiles-Datei, siehe karte_verfuegbar.dart). Außerhalb gibt es keine Kacheln.
/// Die App kennt keinen festen Bereich: ein späterer Wechsel auf eine größere Datei (z. B. ganz Deutschland) braucht keine neue App.
class KartenBereich {
  final double west;
  final double ost;
  final double sued;
  final double nord;
  const KartenBereich({required this.west, required this.ost, required this.sued, required this.nord});

  /// Westerburg (50,56 N / 7,97 E) +/- 175 km: der Bereich der ersten Datei (Vorgabe für Tests und als Rückfall).
  static const westerburg175 = KartenBereich(west: 5.49, ost: 10.45, sued: 48.99, nord: 52.14);

  /// Liegt der Punkt im Bereich der Kartendatei?
  bool enthaelt(double lat, double lng) => lat >= sued && lat <= nord && lng >= west && lng <= ost;
}

/// Quelle für die Attribution (ODbL). Steht zusätzlich im Style (sources.protomaps.attribution).
const kKarteAttribution = '© OpenStreetMap-Mitwirkende';

String karteOrigin({String base = kKarteBase, String api = kApiBase, bool? web, String? seite}) {
  if (base.isNotEmpty) return _ohneSchraegstrich(base);
  if (api.isNotEmpty) return _ohneSchraegstrich(api);
  if (web ?? kIsWeb) return seite ?? Uri.base.origin;
  return 'https://familie.lx-labs.dev';
}

String _ohneSchraegstrich(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

/// Setzt die Adressen in die Style-Vorlage ein. Wirft, wenn Platzhalter übrig bleiben oder eine Fremd-Adresse im Style steht.
String karteStyleAusVorlage(String vorlage, String origin) {
  final s = vorlage
      .replaceAll('{{KARTE_BASE}}', '$origin$kKarteStatischPfad')
      .replaceAll('{{PMTILES_URL}}', '$origin$kKarteKachelPfad');
  if (s.contains('{{')) throw StateError('Platzhalter im Kartenstil nicht ersetzt');
  // Nur eigene Adressen (und der Link der Attribution): jede andere http(s)-Adresse wäre eine Fremd-Einbindung.
  final fremd = RegExp(r'https?://[^"\s<>]+')
      .allMatches(s)
      .map((m) => m.group(0)!)
      .where((u) => !u.startsWith(origin) && !u.startsWith('https://www.openstreetmap.org/copyright'));
  if (fremd.isNotEmpty) throw StateError('Fremd-Adresse im Kartenstil: ${fremd.first}');
  return s;
}
