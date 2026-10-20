#!/usr/bin/env bash
# Erzeugt den Kartenausschnitt (PMTiles, Protomaps-Basemap) für lx-fampad. Läuft auf dem Entwicklungsrechner, NICHT auf dem Server.
# Die Datei gehört nicht ins Repository (hunderte MB), siehe tools/karte/README.md.
#   PMTILES=<Pfad zur pmtiles-CLI> tools/karte/extract.sh [Build-Datum JJJJMMTT] [Ausgabedatei]
# Standard: neuester Build, Ausgabe ./neu.pmtiles
set -Eeuo pipefail

PMTILES="${PMTILES:-pmtiles}"
BBOX="6.5,49.6,9.5,51.5"      # min_lon,min_lat,max_lon,max_lat: Westerburg (50.56 N, 7.97 E) +/- ca. 100 km
MAXZOOM=14                    # Protomaps liefert bis z15; ab z14 überzoomt MapLibre (z15 würde die Datei mehr als verdoppeln)
CLI_VERSION_ERWARTET="1.31.2"

command -v "$PMTILES" >/dev/null || { echo "pmtiles-CLI fehlt (PMTILES=<Pfad>); Release-Binary von github.com/protomaps/go-pmtiles ${CLI_VERSION_ERWARTET}, Prüfsumme in tools/karte/README.md" >&2; exit 1; }
"$PMTILES" version | grep -q "pmtiles ${CLI_VERSION_ERWARTET}" || echo "Hinweis: erwartet pmtiles ${CLI_VERSION_ERWARTET}, gefunden: $("$PMTILES" version | head -1)" >&2

BUILD="${1:-}"
OUT="${2:-neu.pmtiles}"
if [ -z "$BUILD" ]; then
  BUILD="$(curl -fsS https://build-metadata.protomaps.dev/builds.json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);console.log(j[j.length-1].key.replace('.pmtiles',''))})")"
fi
case "$BUILD" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "Build-Datum erwartet JJJJMMTT, bekommen: $BUILD" >&2; exit 2 ;; esac

echo "Build $BUILD, bbox $BBOX, maxzoom $MAXZOOM -> $OUT"
"$PMTILES" extract "https://build.protomaps.com/${BUILD}.pmtiles" "$OUT.tmp" --bbox="$BBOX" --maxzoom="$MAXZOOM"
"$PMTILES" verify "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
