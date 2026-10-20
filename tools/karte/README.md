# Kartendaten (Protomaps, PMTiles)

Werkzeuge für die Karte (Spike, Ergebnis in `docs/KARTE-SPIKE.md`). Nichts davon läuft auf dem Server oder in der App; die große Datei gehört **nicht** ins Repository.

## Werkzeuge (außerhalb des Repos, z. B. `C:\lxq\pmtools`)

| Werkzeug | Version | Herkunft / Prüfsumme |
| --- | --- | --- |
| `pmtiles`-CLI (go-pmtiles) | 1.31.2 (22.07.2026) | Release-Binary `go-pmtiles_1.31.2_Windows_x86_64.zip` von github.com/protomaps/go-pmtiles, SHA-256 `a658baa4d7e55020aef6ca17bd9ff9faa1582671266b36f58c52db0ac8e785a1` (Linux x86_64: `3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f`) |
| `@protomaps/basemaps` | 5.7.2 (Stil-Generator) | `npm i --save-exact @protomaps/basemaps@5.7.2` in einem Werkzeugordner |
| `basemaps-assets` | Commit `028c18f` (31.10.2025) | `git clone https://github.com/protomaps/basemaps-assets` (Schriften Noto Sans, OFL; Sprites) |

## Kacheln erzeugen (Quartals-Update)

Standard: **175 km Umkreis um Westerburg** (50,56 N / 7,97 E), Zoom bis 14, Quelle: aktuelle Protomaps-Basemap (Build-Liste: https://build-metadata.protomaps.dev/builds.json, Doku https://docs.protomaps.com/basemaps/downloads):

```bash
PMTILES=/pfad/zu/pmtiles tools/karte/extract.sh [JJJJMMTT] neu.pmtiles
# Standard: bbox 5.49,48.99,10.45,52.14 (min_lon,min_lat,max_lon,max_lat = lat +/- 1,575 Grad, lon +/- 1,575/cos(50,56 Grad) = +/- 2,48 Grad), maxzoom 14
# gemessen (Build 20261019): 68 938 Kacheln, **1,1 GB** (1 104 045 147 Byte), Dauer etwa 30 s
DRY_RUN=1 PMTILES=… tools/karte/extract.sh      # nur schätzen (Kachelzahl, Größe), nichts schreiben

# ganz Deutschland als Umriss statt Rechteck (gemessen: 206 683 Kacheln, ca. 2,5 GB, etwa 1 Minute):
REGION=tools/karte/deutschland.geojson PMTILES=… tools/karte/extract.sh 20261019 deutschland.pmtiles
# beliebiges anderes Rechteck: BBOX="min_lon,min_lat,max_lon,max_lat"; höchste Zoomstufe: MAXZOOM=14
```

**Der Kartenbereich steht im Kopf der Datei** (min/max Länge und Breite); die App liest ihn von dort. Ein späterer Wechsel auf einen größeren Ausschnitt (z. B. ganz Deutschland) ist deshalb nur ein neuer Aufruf von `extract.sh` und ein neuer Upload: weder App noch Server-Skripte ändern sich (das Skript prüft nur 1 MB bis 8 GB und 20 GB freien Platz).

`deutschland.geojson`: Umriss der Bundesrepublik, abgeleitet aus **Natural Earth 1:10m Admin 0 Countries** (Public Domain, naturalearthdata.com; Eintrag ADM0_A3 = DEU), Koordinaten auf vier Nachkommastellen (ca. 10 m) gerundet, 3027 Punkte, 52 KB. Die Datei wird nur beim Erzeugen gebraucht, nicht von der App.

Einspielen auf dem Server (Ordner und Caddy-Block einmalig durch `deploy/einrichtung-karte.sh`, Schritt für Schritt: `deploy/README.md`, Abschnitt 11):

```bash
rsync -avP --partial --inplace neu.pmtiles lx-labs:/srv/fampad/karte/neu.pmtiles   # bei Abbruch wiederholen: setzt fort (scp: von vorn)
ssh lx-labs 'chmod 644 /srv/fampad/karte/neu.pmtiles && mv -f /srv/fampad/karte/neu.pmtiles /srv/fampad/karte/westerwald.pmtiles'   # atomar (gleiches Dateisystem)
```

`chmod 644` ist nötig: sonst kann Caddy die Datei nicht lesen (404/403, in der App steht "Karte noch nicht eingerichtet"). Die Datei gehört nicht ins Backup (neu erzeugbar, bewusst ausgenommen: `docs/BACKUP.md`).

Der ETag ändert sich mit der Datei; laufende Karten laden beim nächsten Start neu. Quartalsweise wiederholen (Protomaps baut täglich; OSM-Daten ändern sich laufend, für Standort teilen genügt alle 3 Monate).

## Stil, Schriften, Sprites

```bash
KARTE_TOOLS=<Ordner mit node_modules/@protomaps/basemaps> ASSETS=<basemaps-assets> node tools/karte/make-style.mjs
```

Erzeugt `app/assets/karte/style.json` (Flutter-Asset, dunkel nach den Design-Tokens, deutsche Namen), `app/web/karte/glyphs/` (Noto Sans Regular/Medium/Italic, nur Bereiche 0-255, 256-511, 8192-8447, ca. 0,8 MB) und `app/web/karte/sprites/` (Version 4, Thema black). Die Farben stehen nur im Skript und im erzeugten Stil. Die Platzhalter `{{KARTE_BASE}}` und `{{PMTILES_URL}}` ersetzt die App zur Laufzeit (`features/karte/karte_config.dart`).

Lizenzen: Daten © OpenStreetMap-Mitwirkende (ODbL, Attribution steht in der Karte), Protomaps-Basemap/-Stil BSD-3, Schriften Noto Sans (OFL 1.1, Text in `app/web/karte/glyphs/OFL.txt`), MapLibre BSD-3 (`app/web/karte/LICENSE-maplibre-gl.txt`). Sprites (`app/web/karte/sprites/`, Themen `black` für den dunklen und `light` für den hellen Stil): unveränderte Kopien aus `protomaps/basemaps-assets` (`sprites/v4`), dort laut README abgeleitet aus den MIT-lizenzierten tangrams/icons (https://github.com/tangrams/icons); für beide Themen gilt dieselbe Lizenz. Das Theme `light` stammt aus `@protomaps/basemaps` (BSD-3, wie `black`; nur das Werkzeug läuft, in die App gelangt der erzeugte Stil). `web-assets.sha256` führt Sprites und Glyphen bewusst nicht auf: es sind reine Daten (PNG/JSON/PBF), kein ausführbarer Code, der unterschoben werden könnte.
