// Karte (Test): Spike für "Standort teilen" (docs/KARTE-SPIKE.md). Nur für Administratoren und Debug-Builds sichtbar (Profil > Über).
// Zeigt die Protomaps-Karte vom eigenen Server (PMTiles), einen Beispielpunkt mit Genauigkeitskreis und die ODbL-Attribution.
// Kein Standort-Feature: Der Punkt ist fest (Westerburg), nichts wird gelesen, gesendet oder gespeichert.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre/maplibre.dart';

import '../../constants.dart';
import 'karte_config.dart';

/// Beispielpunkt (Westerburg) und Genauigkeit in Metern.
const kKarteBeispielPunkt = (lat: 50.5612, lng: 7.9741);
const kKarteBeispielGenauigkeit = 120.0;

/// Kreis um [lat]/[lng] mit [radiusMeter] als geschlossener Ring für eine Fläche; Näherung für kleine Radien.
List<Geographic> kreisRing(double lat, double lng, double radiusMeter, {int punkte = 48}) {
  final dLat = radiusMeter / 111320.0;
  final dLng = radiusMeter / (111320.0 * math.cos(lat * math.pi / 180));
  final ring = <Geographic>[
    for (var i = 0; i < punkte; i++)
      Geographic(lon: lng + dLng * math.cos(2 * math.pi * i / punkte), lat: lat + dLat * math.sin(2 * math.pi * i / punkte)),
  ];
  return [...ring, ring.first];
}

class KarteSpikeScreen extends StatefulWidget {
  /// Zum Testen: Stil direkt übergeben statt aus dem Asset zu laden, und die Karte durch einen Platzhalter ersetzen.
  final String? styleJson;
  final bool ohneKarte;
  const KarteSpikeScreen({super.key, this.styleJson, this.ohneKarte = false});

  @override
  State<KarteSpikeScreen> createState() => _KarteSpikeScreenState();
}

class _KarteSpikeScreenState extends State<KarteSpikeScreen> {
  late final Future<String> _style = _ladeStil();

  Future<String> _ladeStil() async {
    final vorlage = widget.styleJson ?? await rootBundle.loadString('assets/karte/style.json');
    return karteStyleAusVorlage(vorlage, karteOrigin());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(backgroundColor: kBg, title: const Text('Karte (Test)')),
    body: FutureBuilder<String>(
      future: _style,
      builder: (context, snap) {
        if (snap.hasError) return const _Hinweis('Kartenstil konnte nicht geladen werden.');
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        if (widget.ohneKarte) return const _Hinweis('Karte (im Test ausgeblendet)');
        return Stack(
          children: [
            Positioned.fill(
              child: MapLibreMap(
                options: MapOptions(
                  initStyle: snap.data!,
                  initCenter: Geographic(lon: kKarteBeispielPunkt.lng, lat: kKarteBeispielPunkt.lat),
                  initZoom: 14,
                  minZoom: 5,
                  maxZoom: 17,
                  // Die PMTiles-Datei deckt nur den Westerwald ab (ca. 100 km um Westerburg): außerhalb gibt es keine Kacheln
                  maxBounds: LngLatBounds(longitudeWest: 6.5, longitudeEast: 9.5, latitudeSouth: 49.6, latitudeNorth: 51.5),
                ),
                layers: [
                  PolygonLayer(
                    polygons: [
                      Feature(geometry: Polygon.from([kreisRing(kKarteBeispielPunkt.lat, kKarteBeispielPunkt.lng, kKarteBeispielGenauigkeit)])),
                    ],
                    color: kAccent.withValues(alpha: 0.18),
                    outlineColor: kAccent,
                  ),
                ],
                children: [
                  WidgetLayer(
                    markers: [
                      Marker(
                        point: Geographic(lon: kKarteBeispielPunkt.lng, lat: kKarteBeispielPunkt.lat),
                        size: const Size(22, 22),
                        child: Semantics(
                          label: 'Beispielpunkt mit Genauigkeitskreis',
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: personColor(0),
                              border: Border.all(color: kTextStrong, width: 3),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const MapControlButtons(),
                ],
              ),
            ),
            const Positioned(right: 8, bottom: 8, child: _Attribution()),
          ],
        );
      },
    ),
  );
}

class _Hinweis extends StatelessWidget {
  final String text;
  const _Hinweis(this.text);
  @override
  Widget build(BuildContext context) =>
      Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text, style: const TextStyle(color: kTextMuted))));
}

/// ODbL: Hinweis auf die Datenquelle, immer sichtbar (nicht nur beim Antippen).
class _Attribution extends StatelessWidget {
  const _Attribution();
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Kartendaten $kKarteAttribution',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(color: kBg.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(6)),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(kKarteAttribution, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
      ),
    ),
  );
}
