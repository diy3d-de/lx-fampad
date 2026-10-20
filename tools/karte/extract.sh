#!/usr/bin/env bash
# Erzeugt den Kartenausschnitt (PMTiles, Protomaps-Basemap) für lx-fampad. Läuft auf dem Entwicklungsrechner, NICHT auf dem Server.
# Die Datei gehört nicht ins Repository (hunderte MB bis einige GB), siehe tools/karte/README.md.
#
#   PMTILES=<Pfad zur pmtiles-CLI> tools/karte/extract.sh [Build-Datum JJJJMMTT] [Ausgabedatei]
#
# Region und Zoom sind Parameter (Umgebungsvariablen), damit ein späterer Wechsel (z. B. auf ganz Deutschland) nur ein neuer Aufruf ist:
#   BBOX="min_lon,min_lat,max_lon,max_lat"   Rechteck (Standard: 175 km um Westerburg, ca. 1,1 GB)
#   REGION=tools/karte/deutschland.geojson   Umriss als GeoJSON (Polygon/MultiPolygon); hat Vorrang vor BBOX (ganz Deutschland, ca. 2,5 GB)
#   MAXZOOM=14                               höchste Zoomstufe (ab 14 überzoomt MapLibre; 15 würde die Datei mehr als verdoppeln)
#   DRY_RUN=1                                nur Kachelzahl und Größe schätzen, nichts schreiben
# Die App und die Server-Skripte ändern sich dabei nicht: die App liest den Kartenbereich aus dem Kopf der Datei.
# Standard: neuester Build, Ausgabe ./neu.pmtiles
set -Eeuo pipefail

PMTILES="${PMTILES:-pmtiles}"
# Westerburg (50,56 N / 7,97 E) +/- 175 km: lat +/- 1,575 Grad, lon +/- 1,575 / cos(50,56 Grad) = +/- 2,48 Grad
BBOX="${BBOX:-5.49,48.99,10.45,52.14}"
REGION="${REGION:-}"
MAXZOOM="${MAXZOOM:-14}"
CLI_VERSION_ERWARTET="1.31.2"

command -v "$PMTILES" >/dev/null || { echo "pmtiles-CLI fehlt (PMTILES=<Pfad>); Release-Binary von github.com/protomaps/go-pmtiles ${CLI_VERSION_ERWARTET}, Prüfsumme in tools/karte/README.md" >&2; exit 1; }
"$PMTILES" version | grep -q "pmtiles ${CLI_VERSION_ERWARTET}" || echo "Hinweis: erwartet pmtiles ${CLI_VERSION_ERWARTET}, gefunden: $("$PMTILES" version | head -1)" >&2

BUILD="${1:-}"
OUT="${2:-neu.pmtiles}"
if [ -z "$BUILD" ]; then
  BUILD="$(curl -fsS https://build-metadata.protomaps.dev/builds.json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);console.log(j[j.length-1].key.replace('.pmtiles',''))})")"
fi
case "$BUILD" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "Build-Datum erwartet JJJJMMTT, bekommen: $BUILD" >&2; exit 2 ;; esac

if [ -n "$REGION" ]; then
  [ -f "$REGION" ] || { echo "REGION=$REGION nicht gefunden" >&2; exit 2; }
  AUSWAHL=(--region="$REGION"); BESCHREIBUNG="Umriss $REGION"
else
  AUSWAHL=(--bbox="$BBOX"); BESCHREIBUNG="bbox $BBOX"
fi

echo "Build $BUILD, $BESCHREIBUNG, maxzoom $MAXZOOM -> $OUT"
if [ "${DRY_RUN:-0}" = 1 ]; then
  "$PMTILES" extract "https://build.protomaps.com/${BUILD}.pmtiles" "$OUT.tmp" "${AUSWAHL[@]}" --maxzoom="$MAXZOOM" --dry-run
  exit 0
fi
"$PMTILES" extract "https://build.protomaps.com/${BUILD}.pmtiles" "$OUT.tmp" "${AUSWAHL[@]}" --maxzoom="$MAXZOOM"
"$PMTILES" verify "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
