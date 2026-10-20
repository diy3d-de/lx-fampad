# Karte (Spike und Umsetzung)

**Umsetzung (Standort-Seite, Branch `standort-karte`):** Die Spike-Ergebnisse unten gelten weiter. Die Karte ist jetzt in die Standort-Seite eingebaut (`app/lib/features/standort/standort_karte_ansicht.dart`): Stecknadeln mit Profilbild, Genauigkeitskreis, Info beim Tippen, Kamera auf alle eingepasst, „Auf mich zentrieren“, weiche Bewegung. **Ausschnitt: 175 km um Westerburg, maxzoom 14, gemessen 68 938 Kacheln und 1,1 GB** (Build 20261019; ganz Deutschland als Umriss: 206 683 Kacheln, ca. 2,5 GB). Der Bereich steht im Kopf der PMTiles-Datei, die App liest ihn von dort (Rückfall „Karte noch nicht eingerichtet“, solange die Datei fehlt; „außerhalb des Kartenbereichs“ für Teilende außerhalb). Der Karten-Block steht jetzt dauerhaft in `deploy/Caddyfile`. Schritte für den Betreiber: `deploy/README.md`, Abschnitt 11. **Quellen von maplibre_android/maplibre/maplibre_web 0.3.6 auf Netzwerkziele geprüft** (Security-Auflage N5): im Dart-, Kotlin- und Java-Code des Pakets stehen keine Abruf-Adressen außer Doku-Links; die Telemetrie fehlt (kein `telemetry`-Code im Android-SDK 13.5.2). **Aufpassen:** `MapOptions.initStyle` hat als Standard `https://demotiles.maplibre.org/style.json`; die App übergibt immer den eigenen Stil (`karteStyleAusVorlage` lehnt jede Fremd-Adresse ab, Test). Die native Bibliothek `libmaplibre.so` enthält die Zeichenketten `api.maptiler.com`, `api.mapbox.com` und `demotiles.maplibre.org` (Erkennung für API-Schlüssel); sie werden nur angefragt, wenn ein Stil darauf zeigt, was unserer nicht tut. `url_launcher` (transitiv) wird nur von der Attribution des Pakets benutzt, die wir nicht einbinden (eigene Textanzeige ohne Link).

# Karten-Spike (Vorarbeit für „Standort teilen“)

## Release-Build (Ursache der leeren Karte in v0.5.0)

In v0.5.0 (Release-APK) blieb die Karte auf Android leer (graue Fläche, keine Nadeln, die Seite scrollte statt die Karte zu bewegen), im Web und im Debug-Build ging sie. **Ursache:** R8 (Code-Verkleinerung, nur im Release-Build) hat die abstrakten Methoden der Flutter-Schnittstelle `io.flutter.plugin.platform.PlatformView` entfernt (`getView`, `dispose` ...), weil kein Java-Code sie "benutzt". Das maplibre-Paket ruft sie aber über die Dart-JNI-Brücke (`PlatformView.implement` in `jni.g.dart`) auf; ohne die Methoden liefert die Brücke `null`, und `PlatformViewsController.createPlatformView` wirft eine NullPointerException (logcat: `PlatformException(error, null, null, java.lang.NullPointerException`). **Behebung:** Keep-Regeln in `app/android/app/proguard-rules.pro` (`PlatformView`, `PlatformViewFactory`, `ActivityPluginBinding`, `PluginRegistry`, dazu die Klassen des Plugins `com.github.josxha.maplibre.**`, `org.maplibre.**` und `com.github.dart_lang.jni.**`, die das Paket nur zum Teil selbst mitbringt). **Prüfung:** `tools/release-pruefung.sh` (CI-Schritt im Android-Job) baut einen Release-APK mit Wegwerf-Schlüssel und prüft das Manifest (INTERNET, kein ACCESS_BACKGROUND_LOCATION) und R8s `usage.txt` (nichts von `PlatformView`/dem Plugin entfernt). Auf dem Emulator reproduzieren: `app/tool/karte_demo.dart` (nur die Karte mit zwei Beispielpersonen, ohne Anmeldung, gegen den echten Kartenserver): `flutter build apk --release --target-platform android-x64 -t tool/karte_demo.dart` mit dem Wegwerf-Schlüssel aus `tools/release-pruefung.sh` (nie verteilen), `adb logcat`. **Geprüft, dass "Stil geladen" auf beiden Plattformen kommt** (die Nadeln hängen daran): Android-Release im Emulator (Nadeln erscheinen) und Web (Release-Build, Chrome headless gegen einen lokalen Server mit Range-Unterstützung: Konsolen-Log `stilGeladen`, Nadeln erscheinen). Im Web wird nach "geladen" zusätzlich noch einmal eingepasst (beim ersten Einpassen steht die Größe der Karten-Ansicht dort noch nicht fest und die Kamera zoomte zu weit).

**Web: Nadeln als Symbole der Karte (v0.5.2):** Im Web liegt die Karte (WebGL) unter dem Flutter-Zeichenbereich; als `WidgetLayer` hinkten die Nadeln beim Ziehen, Drehen und Zoomen um ein Bild hinterher (die Karte meldet die Bewegung, Flutter projiziert und zeichnet erst danach neu; im Ruhezustand stimmte die Lage exakt). Deshalb zeichnet `standort_pin_bild.dart` die Nadel (wie das Widget, `PinMaler`) als PNG, `addImage` legt es in den Kartenstil und je Person ein `MarkerLayer` setzt es mit Anker unten auf die Position, also im selben Bild wie das Gelände. Tippen: `MapEventClick`, Treffer = Rechteck der Nadel über der Spitze (`pinGetroffen`). Nur Web (`kIsWeb`); Android bleibt bei `WidgetLayer` (dort läuft es einwandfrei). Geprüft mit Chrome headless und Maus-Ziehen (Nadeln wandern mit dem Gelände).

**Fehlersicht:** Meldet MapLibre nicht binnen 10 s "Stil geladen" (Kartenstil oder Kacheln kommen nicht an, Darstellung scheitert), ersetzt eine Meldung "Karte konnte nicht geladen werden" mit "Erneut versuchen" die leere Fläche; Nadeln und Genauigkeitskreise erscheinen erst mit geladener Karte. Gesten: Die Karte bekommt alle Wischgesten (`EagerGestureRecognizer`), die Seite scrollt nicht mehr, solange der Finger auf der Karte liegt. Die Seite bleibt bei 360 px scrollbar: Links und rechts der Karte liegt der Seitenrand von 20 px, darüber und darunter stehen Kopf, Startkarte und die Liste, und dort wischt der Finger die Seite. Ein Vollbild-Knopf oder eine Zwei-Finger-Bedienung ist nicht gebaut (möglicher Folgepunkt, wenn der Rand nicht reicht).


Stand: 19.10.2026, Branch `spike-karte`. Kein Standort-Feature, keine Server- oder Datenbankänderung. Frage: Geht eine Karte komplett ohne Fremd-Einbindung, im Web und auf Android?

**Ergebnis: Ja.** Web (unter der echten CSP, ohne CSP-Änderung) und Android (Emulator, `pmtiles://` über HTTP mit Range) zeigen die Protomaps-Karte vollständig vom eigenen Host. Der Beispielpunkt mit Genauigkeitskreis, Zoom und die ODbL-Attribution funktionieren.

## Bausteine

| Teil | Umsetzung |
| --- | --- |
| Paket | `maplibre` 0.3.6 (BSD-3), exakt gepinnt; Android-SDK 13.5.2, Web gl-js 5.24.0, pmtiles.js 4.5.0 (Einzelheiten und Prüfsummen: `docs/VERSIONEN.md`, Abschnitt Karte) |
| Seite | `app/lib/features/karte/karte_spike_screen.dart`, erreichbar über Profil → Über → „Karte (Test)“, nur für Admins und Debug-Builds, kein Tab. Eigenständiger Einstieg ohne Anmeldung: `app/tool/karte_spike_main.dart` |
| Web-Dateien | `app/web/karte/`: `maplibre-gl-csp.js`, `maplibre-gl-csp-worker.js`, `maplibre-gl.css`, `pmtiles.js`, `karte-init.js` (setzt die Worker-Adresse), Glyphen, Sprites. Einbindung in `index.html`, Prüfsummen in `app/web-assets.sha256` |
| Stil | `app/assets/karte/style.json` (Flutter-Asset), erzeugt von `tools/karte/make-style.mjs` aus `@protomaps/basemaps` 5.7.2; Thema „black“ auf die Design-Tokens umgefärbt, deutsche Namen. Die App ersetzt zur Laufzeit zwei Platzhalter durch absolute Adressen (Android braucht absolute Adressen) und lehnt jede Fremd-Adresse im Stil ab (Test) |
| Kacheln | `tools/karte/extract.sh` (`pmtiles extract`), Datei nicht im Repo |
| Auslieferung | `deploy/einrichtung-karte.sh` (Entwurf, **nicht ausgeführt**) + `deploy/karte/karte-daten.handle` |

## Messwerte

| Messung | Wert |
| --- | --- |
| Extract Westerwald (bbox 6,5/49,6/9,5/51,5, ca. 100 km), Build 20261019 | **z14: 420,6 MB** (25 482 Kacheln, Dauer ca. 20 s); z15 wären 910 MB (100 267 Kacheln); Zoom 15 lohnt nicht, MapLibre überzoomt z14 sauber (Karte lief bis z17) |
| Hochrechnung ganz Deutschland, z14 | grob 3 bis 4 GB (linear nach Fläche; nicht gemessen; `PROJEKTBESCHREIBUNG` nennt 5 bis 10 GB) |
| Glyphen (3 Schriften, Latein) | 0,8 MB auf dem Server, je Start nur ca. 0,23 MB geladen (Bereich 0-255) |
| Sprites (v4 black) | 24 KB |
| Stil | 27 KB (vorher 59 KB, vereinfacht, siehe Befund Android) |
| Web: Karten-Dateien beim ersten Start (JS, CSS, Stil, Glyphen, Sprites; übertragen) | ca. 460 KB; davon JS ca. 300 KB gzip. Das JS lädt bei jedem App-Start (statische Tags); später per Lazy-Load nur beim Öffnen der Karte laden |
| Web: Kachelabruf Startansicht | 8 Range-Anfragen, 98 KB; erste Anfrage 1,6 s nach Seitenaufruf (Flutter-Start), alle fertig nach 0,2 s (lokal, ohne Netzlatenz) |
| Web: JS-Heap | 23 bis 25 MB |
| Android: Zuwachs | `libmaplibre.so` arm64 10,8 MB roh, ca. 3,8 MB gzip; armv7 3,2 MB gzip. Universal-Release-APK also ca. +10 bis 11 MB (nicht gebaut, es fehlt `key.properties`), je-ABI-Split ca. +4 MB. Glyphen/Sprites/JS liegen nicht in der APK (Server) |
| Android: RAM (Debug-Build, Emulator, Karte auf z14) | PSS gesamt 347 MB (App-Gesamtwert inkl. Flutter-Debug), Native Heap 56 MB |

## CSP-Befund (Web)

**Keine CSP-Änderung nötig.** Getestet mit einem eigenen Caddy (v2.11.7) auf der aus `deploy/Caddyfile` übernommenen Site (CSP, COOP/COEP/CORP unverändert), headless Chrome:

- Keine `securitypolicyviolation`-Ereignisse, keine Konsolenfehler (einzige Meldung: Flutter-Debug „Injecting script tag“), `crossOriginIsolated` bleibt `true`, alle Anfragen gehen an denselben Host.
- Gründe: CSP-Build von gl-js mit eigener Worker-Datei (`worker-src 'self'`, kein `blob:` nötig), pmtiles.js nutzt `fetch` mit Range auf die eigene Herkunft (`connect-src 'self'`), Glyphen/Sprites per `fetch`/`img-src 'self'`, Stylesheet `style-src 'self'`; MapLibre setzt Styles per DOM (durch `'unsafe-inline'` ohnehin erlaubt).
- Die Skripte sind eigene Dateien (kein Inline-Skript): deshalb `karte-init.js`.
- Der normale (nicht-CSP-)Build von gl-js würde einen `blob:`-Worker brauchen (`worker-src blob:` steht schon in der CSP); er wird nicht benutzt.

## Auslieferung (Caddy)

- `file_server` beantwortet Range-Anfragen nativ (geprüft: 206, `Content-Range`, ETag). `encode zstd gzip` des Site-Blocks komprimiert die Datei **nicht** (`Accept-Encoding: gzip, br, zstd` ergibt keine `Content-Encoding`); das prüft das Skript nach dem Einrichten ebenfalls.
- Same-Origin: kein CORS, `Cross-Origin-Resource-Policy: same-origin` bleibt.
- Cache: `no-cache` (ETag-Prüfung). Die Datei heißt immer `westerwald.pmtiles` und wird quartalsweise ersetzt, deshalb kein `immutable`. Wer `immutable` will, versioniert den Dateinamen und ändert `kKarteKachelPfad`.
- Ein Site-Block darf nur einmal definiert sein; eine eigene `conf.d`-Datei kann den Pfad deshalb nicht in `familie.lx-labs.dev` einfügen. `deploy/einrichtung-karte.sh` fügt den Block `deploy/karte/karte-daten.handle` (`handle_path /karte-daten/*`, Wurzel `/srv/fampad/karte`) vor dem Fang-Block in `/etc/caddy/conf.d/fampad.caddy` ein: Sicherung, Kandidat validieren, ersetzen, Gesamtkonfiguration validieren, Reload, Prüfung von lx-labs.dev, Familie und Range-Anfrage, bei jedem Fehler Rückfall; Haupt-Caddyfile unangetastet; `--dry-run`. Das Skript prüft zusätzlich, dass die CSP-Zeile unverändert bleibt. Der Entwurf wurde nur lokal geprüft (Bash-Syntax, shellcheck, Einfügen und `caddy validate` gegen `deploy/Caddyfile`), nie auf dem Server.
- **Erledigt:** Der Block (9 Zeilen) steht jetzt dauerhaft in `deploy/Caddyfile`; ein `cp` des Hinweises von `deploy.sh` entfernt ihn nicht mehr.

## Befund Android

- `pmtiles://https://…/westerwald.pmtiles` funktioniert in maplibre-native 13.5.2 zuverlässig mit HTTP-Range (ETag/If-Range, der HTTP-Cache liefert 304). Kein lokaler Tile-Proxy und kein `.mbtiles` nötig. Das Manifest bleibt unverändert (INTERNET vorhanden, `usesCleartextTraffic=false`; für den Emulator-Test mit `http://10.0.2.2` wurde vorübergehend eine Debug-Überlagerung benutzt, nicht eingecheckt; Produktion läuft über HTTPS).
- **Build-Hürde 1:** `maplibre_android` wendet das Gradle-Plugin `org.jlleitschuh.gradle.ktlint` an, bringt es aber nicht mit. Der Build brach ab, bis `app/android/settings.gradle.kts` es (14.2.0, apply false) bereitstellt.
- **Build-Hürde 2:** Das Paket verlangt `android-sdk-opengl:13.5.+` (schwebend). Per `resolutionStrategy.force` auf 13.5.2 festgelegt (13.5.3 war zu jung).
- **Stil-Anpassung:** MapLibre Native wertet manche Protomaps-Ausdrücke nicht aus (Schriftwechsel in `text-font`/`format`, `text-variable-anchor`-Ausdrücke). `make-style.mjs` ersetzt sie durch feste Werte (deutscher Name, `Noto Sans Regular`). Ob das nötig war, ist offen: Die Beschriftung fehlte zunächst, bis klar war, dass der **Emulator mit SwiftShader (Software-GL) keinen Text zeichnet** (selbst ein Test-Symbol nicht). Mit `-gpu host` erscheint alles (Straßen-, Orts-, Gewässernamen, Test-Symbole). Die Stilvereinfachung ist daher vermutlich nicht nötig, aber unschädlich; beim Wechsel auf den Original-Stil auf einem echten Gerät gegenprüfen.
- Marker: Flutter-Widget (`WidgetLayer`) in Personenfarbe; Genauigkeitskreis als Fläche mit echtem Radius in Metern (Ring aus 48 Punkten), wächst beim Zoomen korrekt mit.

## Risiken und offene Punkte

1. **Echtes Gerät fehlt:** Android nur im Emulator (GPU-Modus host) getestet; RAM und Ladezeit auf einem Handy messen.
2. **Pre-1.0-Paket** (maplibre 0.3.x): Updates einzeln prüfen; zwei Build-Eingriffe (ktlint-Plugin, SDK-Pin) bei jedem Paket-Update neu bewerten, sonst entfallen sie vielleicht.
3. **Transitiv neu:** u. a. `url_launcher` (Attribution des Pakets öffnet Links; die Spike-Seite nutzt eine eigene Textanzeige ohne Link) und `html`; `pubspec.lock` änderte außerdem `code_assets`, `native_toolchain_c`, `objective_c` auf ältere Stände (Resolver). Bei Review ansehen.
4. **Sprites** sind aus dem grauen Thema „black“ (nur Pfeil/Stadtpunkte), Beschriftungen von Straßen-Schildern fehlen ggf.; für Standort teilen unwichtig.
5. **Fehlende Glyphenbereiche** (Kyrillisch, Griechisch, Arabisch usw.) ergeben leere Namen, kein Fehler; im Web liefert der Fang-Block (`try_files … /index.html`) dafür `index.html` statt 404, MapLibre verwirft die Antwort.
6. **Datei im Betrieb:** 420 MB auf dem VPS plus Übertragung per scp; Quartals-Update ohne Ausfall (atomares Umbenennen), laufende Sitzungen lesen kurz mit alter Datei weiter bzw. holen sich nach ETag-Wechsel neue Header (bei Fehlern App neu starten).
7. **Lazy-Load** der gl-js-Dateien (jetzt bei jedem Start ca. 300 KB gzip) und Einbindung der Karte erst im Standort-Feature.
8. Das Rechte-/Datenschutz-Modell von „Standort teilen“ ist nicht Teil des Spikes.

## Empfehlung

- **Region/Zoom:** Westerwald-Ausschnitt (ca. 100 km um Westerburg), **maxzoom 14**, rund 420 MB. Wenn die Familie weiter verreist, bbox vergrößern (Faustregel 10 KB/km², ganz Deutschland ca. 3 bis 4 GB) statt Zoom 15.
- **Update:** quartalsweise per `tools/karte/extract.sh` auf dem Entwicklungsrechner, `scp` nach `/srv/fampad/karte/neu.pmtiles`, atomar umbenennen (siehe `tools/karte/README.md`).
- **Einführung:** `deploy/einrichtung-karte.sh --dry-run`, dann ausführen (tmux); danach den Block in `deploy/Caddyfile` übernehmen; vor dem Release `security` über Skript, Dateiauslieferung und die neuen Pakete schauen lassen; gl-js lazy laden.
