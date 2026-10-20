# Kartendaten (Protomaps, PMTiles)

Werkzeuge für die Karte (Spike, Ergebnis in `docs/KARTE-SPIKE.md`). Nichts davon läuft auf dem Server oder in der App; die große Datei gehört **nicht** ins Repository.

## Werkzeuge (außerhalb des Repos, z. B. `C:\lxq\pmtools`)

| Werkzeug | Version | Herkunft / Prüfsumme |
| --- | --- | --- |
| `pmtiles`-CLI (go-pmtiles) | 1.31.2 (22.07.2026) | Release-Binary `go-pmtiles_1.31.2_Windows_x86_64.zip` von github.com/protomaps/go-pmtiles, SHA-256 `a658baa4d7e55020aef6ca17bd9ff9faa1582671266b36f58c52db0ac8e785a1` (Linux x86_64: `3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f`) |
| `@protomaps/basemaps` | 5.7.2 (Stil-Generator) | `npm i --save-exact @protomaps/basemaps@5.7.2` in einem Werkzeugordner |
| `basemaps-assets` | Commit `028c18f` (31.10.2025) | `git clone https://github.com/protomaps/basemaps-assets` (Schriften Noto Sans, OFL; Sprites) |

## Kacheln erzeugen (Quartals-Update)

Ausschnitt um Westerburg (50,56 N / 7,97 E, etwa 100 km Umkreis), Zoom bis 14, Quelle: aktuelle Protomaps-Basemap (Build-Liste: https://build-metadata.protomaps.dev/builds.json, Doku https://docs.protomaps.com/basemaps/downloads):

```bash
PMTILES=/pfad/zu/pmtiles tools/karte/extract.sh [JJJJMMTT] neu.pmtiles
# bbox 6.5,49.6,9.5,51.5 (min_lon,min_lat,max_lon,max_lat), maxzoom 14; Ergebnis ca. 420 MB, Dauer etwa 20 s
```

Einspielen auf dem Server (Ordner und Caddy-Block einmalig durch `deploy/einrichtung-karte.sh`):

```bash
scp neu.pmtiles lx-labs:/srv/fampad/karte/neu.pmtiles
ssh lx-labs 'mv -f /srv/fampad/karte/neu.pmtiles /srv/fampad/karte/westerwald.pmtiles'   # atomar (gleiches Dateisystem)
```

Der ETag ändert sich mit der Datei; laufende Karten laden beim nächsten Start neu. Quartalsweise wiederholen (Protomaps baut täglich; OSM-Daten ändern sich laufend, für Standort teilen genügt alle 3 Monate).

## Stil, Schriften, Sprites

```bash
KARTE_TOOLS=<Ordner mit node_modules/@protomaps/basemaps> ASSETS=<basemaps-assets> node tools/karte/make-style.mjs
```

Erzeugt `app/assets/karte/style.json` (Flutter-Asset, dunkel nach den Design-Tokens, deutsche Namen), `app/web/karte/glyphs/` (Noto Sans Regular/Medium/Italic, nur Bereiche 0-255, 256-511, 8192-8447, ca. 0,8 MB) und `app/web/karte/sprites/` (Version 4, Thema black). Die Farben stehen nur im Skript und im erzeugten Stil. Die Platzhalter `{{KARTE_BASE}}` und `{{PMTILES_URL}}` ersetzt die App zur Laufzeit (`features/karte/karte_config.dart`).

Lizenzen: Daten © OpenStreetMap-Mitwirkende (ODbL, Attribution steht in der Karte), Protomaps-Basemap/-Stil BSD-3, Schriften Noto Sans (OFL 1.1, Text in `app/web/karte/glyphs/OFL.txt`), MapLibre BSD-3 (`app/web/karte/LICENSE-maplibre-gl.txt`).
