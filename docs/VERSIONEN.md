# Gepinnte Versionen (Phase 0 bis 1c)

Stichtag 18.10.2026, nur Versionen mit mindestens 14 Tagen Alter (Veröffentlichungsdatum in der Spalte „Hinweis“ bei den Paketen von Phase 1a, geprüft mit `npm view <Paket> time`). Alle Versionen sind exakt gepinnt (kein `^`, kein `~`); Lockfiles (`package-lock.json`, `pubspec.lock`) werden eingecheckt. Quelle: Research-Teammate.

## Server

| Paket | Version | Hinweis |
| --- | --- | --- |
| Node.js | 24.21.0 | wie lx-labs; Node 26 erst nach Phase 1 prüfen |
| TypeScript | 6.0.3 | TS 7 hat noch keine API, nur optional als Typcheck |
| Fastify | 5.12.5 | auf Node 24 im Test prüfen |
| @fastify/websocket | 11.3.3 | Auth über Session-Cookie beim Upgrade oder Einmal-Ticket |
| drizzle-orm / drizzle-kit | 0.45.3 / 0.31.11 | 1.0 noch RC; kein `db.query` (Relational v1) |
| PostgreSQL | 17 (Debian 13, Debian-Repo) | entschieden 18.10.2026 |
| @simplewebauthn/server | 14.0.3 | Phase 1a im Einsatz (veröffentlicht 25.09.2026). `supportedAlgorithmIDs` = ES256/RS256, UV Pflicht, Attestation `none`; Antworten werden im Test mit einem eigenen Test-Authenticator erzeugt |
| otplib | 13.5.0 | Phase 1a im Einsatz (21.08.2026). API ≠ v12 (funktionale `verify`/`generate`, `epochTolerance`); Replay-Schutz über `afterTimeStep` und atomares Fortschreiben von `credentials.last_time_step` |
| argon2 | 0.45.1 | Phase 1a im Einsatz (21.07.2026). Argon2id (32 MiB, t=3, p=1). Native Prebuilds liegen im Paket: läuft auch mit `npm ci --ignore-scripts` (deploy.sh), auf Debian 13/glibc x64 noch nicht auf dem echten Server geprüft |
| zod | 4.6.5 | Phase 1a: Eingabevalidierung der Routen (13.09.2026). 4.6.6 (11.10.) und 4.6.7 (12.10.) waren zum Stichtag jünger als 14 Tage |
| @tus/server / @tus/file-store | 2.4.5 / 2.1.1 | Teil-Uploads liegen unverschlüsselt: nach `onUploadFinish` verschlüsselt ablegen |
| sharp | 0.35.5 | |
| pg / @types/pg | 8.23.1 / 8.23.1 | node-postgres; Pool mit Fehler-Handler und Verbindungs-Timeout |
| @fastify/rate-limit | 11.2.0 | 11.2.1 (08.10.2026) war zum Stichtag jünger als 14 Tage |
| @types/ws | 8.18.2 | Typen für den WebSocket (ws kommt über @fastify/websocket) |
| @types/node | 24.19.1 | passend zu Node 24 |
| @electric-sql/pglite (pglite) | 0.5.8 | nur Tests: PostgreSQL als WASM für den Schema-Test; zusätzlich läuft derselbe Test gegen echtes PostgreSQL 17 (`TEST_DATABASE_URL`) |
| tsx | 4.23.15 | nur Entwicklung (`npm run dev`) |
| eslint / @eslint/js / typescript-eslint | 10.12.0 / 10.0.1 / 8.71.0 | |
| Vitest | 5.0.3 | |
| ntfy | 2.28.0 (2.31.1 ab 31.10.) | eigene Subdomain, `deny-all`, UnifiedPush-Topics `up*` |

## App

| Paket | Version | Hinweis |
| --- | --- | --- |
| Flutter / Dart | 3.47.6 / 3.13.5 | wie lx-urlaubsplanung |
| flutter_riverpod | 3.4.3 | |
| drift / drift_dev | 2.35.1 | Web: COOP/COEP-Header für OPFS, sonst IndexedDB-Fallback |
| drift_flutter / sqlite3 | 0.3.1 / 3.7.0 | `sqlite3.wasm` zur Version passend |
| flutter_secure_storage | 11.2.0 | Phase 1b im Einsatz (16.09.2026): Access-/Refresh-Token und Geräte-ID der Android-App im Keystore; im Web nicht genutzt (nur HttpOnly-Cookie, `MemoryTokenStore`) |
| mobile_scanner | 7.4.2 | Phase 1b: QR-Scan für Einladungen, **nur Android** (14.09.2026). Auf dem Web-Pfad nie aufgerufen (der Web-Scanner lädt Skripte von einem CDN, das die CSP verbietet); ML Kit arbeitet auf dem Gerät, das Bild verlässt es nicht. Manifest-Berechtigung CAMERA kommt aus dem Paket |
| qr_flutter | 4.1.0 | Phase 1b: QR-Codes für Einladungen und TOTP-Einrichtung, erzeugt in der App (letzte Version, 14.05.2023) |
| web | 1.1.1 | Phase 1b: `history.replaceState` und `hashchange` für den Einladungslink (bisher nur transitiv) |
| passkeys | 2.23.1 | Phase 1b im Einsatz (14.09.2026). Android per Credential Manager, Web per JS-Bündel (siehe unten, selbst gehostet). `assetlinks.json` mit allen Signatur-Fingerprints: `deploy/assetlinks.json.template`, Anleitung `deploy/README.md` Abschnitt 9. Transitiv: passkeys_android 2.14.1, passkeys_web 2.10.1, passkeys_platform_interface 2.10.0 (alle 14.09.2026), passkeys_darwin/windows/doctor, package_info_plus 10.2.2 (01.10.2026), win32 6.4.0 |
| unifiedpush / unifiedpush_android | 6.2.0 / 3.4.1 | Push-Zweig im Einsatz (nur Android; veröffentlicht 13.10.2025 / 16.11.2025, beide ≥ 14 Tage). **unifiedpush_android bewusst 3.4.1 statt 3.5.0:** 3.5.0 (25.08.2026) baut mit dem neuen Android-Gradle-Plugin ohne `kotlin-android` (AGP 9 „built-in Kotlin“), das Projekt hat das laut Flutter-Vorlage abgeschaltet (`android.builtInKotlin=false`, `android.newDsl=false` in `app/android/gradle.properties`); 3.4.1 nutzt das klassische `kotlin-android`-Plugin und passt dazu (unifiedpush 6.2.0 verlangt `^3.4.0`). Wiedervorlage: bei Umstellung auf AGP-9-Kotlin 3.5.0 prüfen. Der Dart-Code wird über bedingten Import (`app/lib/data/push/push_plattform_fabrik.dart`) nur mit `dart:io` geladen, nie im Web-Build. Ohne eingebetteten FCM-Verteiler (kein Google). Android bringt die Bibliothek `org.unifiedpush.android:connector:3.1.2` als Gradle-Abhängigkeit mit (Maven Central; die Fassungen 3.3.5/3.5.0 des Plugins nutzen 3.3.5; Quelltext der Empfänger-Prüfung gelesen: Nachrichten ohne bekanntes Registrierungs-Token werden verworfen): Manifest-Beitrag = Berechtigung WAKE_LOCK, `<queries>` für Verteiler, ein exportierter Empfänger `MessagingReceiverImpl` (Verteiler -> App) und ein exportierter `RaiseToForegroundService`; nach dem ersten Debug-Build den gemergten Manifest prüfen. Transitiv: unifiedpush_platform_interface 4.0.0, unifiedpush_storage_interface 1.0.0, unifiedpush_linux 1.0.0 (alle 13.10.2025), webpush_encryption 1.0.1 (07.12.2025), webcrypto 0.6.0 (17.11.2025; native BoringSSL im Android-Build per CMake aus dem mitgelieferten Quelltext `third_party/boringssl`, 14 MB im Paket: CMake lädt **nichts** aus dem Netz nach, FetchContent/ExternalProject/Download kommen in den CMake-Dateien nicht vor; der Build braucht NDK und CMake der CI; das Plugin nutzt das klassische `kotlin-android`-Plugin und passt zu den Projekt-Flags. Es läuft im Web-Build mit der Browser-Kryptografie), window_manager 0.5.2 und screen_retriever(_linux/_macos/_platform_interface/_windows) 0.2.2 (04.07.2026). `dependency_overrides`: `dbus: 0.8.0` (unifiedpush_linux will ^0.7.11, file_picker_linux 2.0.1 ^0.8.0; Linux wird nie gebaut, nur der Versionskonflikt wird gelöst) |
| maplibre | 0.3.6 | Ersatz für flutter_map + PMTiles-Vektor (veraltet); pre-1.0 |
| geolocator | 14.1.1 | Vordergrunddienst eingebaut |
| web_socket_channel | 3.0.3 | Phase 1c im Einsatz (direkte Abhängigkeit seit 1c; stand schon vorher als transitive Abhängigkeit im Lockfile): WebSocket-Client des Sync (`app/lib/data/sync/sync_socket.dart`), Reconnect mit Backoff und Jitter selbst gebaut; läuft auf Android und im Web |
| rrule | 0.2.18 | Phase 1c-2a im Einsatz (06.01.2026, Apache-2.0): Terminserien expandieren (`app/lib/data/calendar/expansion.dart`). Kennt **keine Zeitzonen** (rechnet mit `DateTime.utc`): die Wanduhrzeit der Termin-Zeitzone wird als UTC getarnt expandiert und danach mit timezone umgerechnet. Transitiv: time 2.1.6 (07.12.2025) |
| timezone | 0.11.1 | Phase 1c-2a im Einsatz (29.06.2026; 0.11.2 vom 12.10.2026 war zum Stichtag jünger als 14 Tage): Zeitzonen-Daten für Sommerzeit. Gebündelt wird `latest.tzf` (alle Zonen bis 2037, 253760 Byte) als Asset `app/assets/tz/latest.tzf` (kein CDN, kein Abruf von Dritten); abweichend von der Vorrecherche nicht die Variante `10y` (nur rund 2020 bis 2030), weil der Horizont der Serien 5 Jahre beträgt. Prüfsumme siehe unten; die Dateien `lib/data/*.dart` des Pakets (Daten als Dart-Code) werden nicht eingebunden |
| file_picker | 13.1.0 | ICS-Import (veröffentlicht 15.09.2026, MIT): System-Dateiauswahl, gelesen über `readAsByteStream` (kein dart:io, läuft im Web); Android ohne Speicherberechtigung (das Plugin trägt nur eine `<queries>`-Angabe ein, nach dem ersten Debug-Build den gemergten Manifest prüfen: keine neuen Berechtigungen), Web im Browser-Dialog. Transitive Pakete stehen in der Tabelle darunter |
| flutter_local_notifications | 22.3.1 | Terminerinnerungen, nur Android (veröffentlicht 13.09.2026, BSD-3): `zonedSchedule` mit rollierendem Fenster (`app/lib/data/erinnerungen/`); 22.3.2 (12.10.2026) und 23.0.0-dev.x waren zum Stichtag zu jung oder Vorabversion. Braucht Core-Library-Desugaring (`desugar_jdk_libs` 2.1.4 in `android/app/build.gradle.kts`). Im Web wird das Plugin nicht aufgerufen (bedingter Import). Transitiv: flutter_local_notifications_platform_interface 12.2.0 (08.08.2026), _web 1.0.0 (07.06.2026), _windows 3.1.1 (14.06.2026), _linux **8.0.2 (12.10.2026, 7 Tage alt)**: einzige Ausnahme von der 14-Tage-Regel, weil 8.0.1 `dbus ^0.7` verlangt und file_picker_linux 2.0.1 `dbus ^0.8`; die Linux-/Windows-Teile sind nicht Teil der Android- und Web-Builds. **Wiedervorlage 26.10.2026:** Ausnahme entfällt (dann 14 Tage alt). Manifest: `RECEIVE_BOOT_COMPLETED`, `USE_EXACT_ALARM`, `POST_NOTIFICATIONS` und die beiden Receiver (nur intern); nach dem ersten CI-Build den gemergten Manifest prüfen |
| desugar_jdk_libs | 2.1.4 | Core-Library-Desugaring für `flutter_local_notifications` (`coreLibraryDesugaring` in `app/android/app/build.gradle.kts`, von Google, Version aus der README des Plugins; lange vor dem Stichtag veröffentlicht). Release-Build: `app/android/app/proguard-rules.pro` (Plugin und Gson/TypeToken) |
| (transitiv zu file_picker) | android_file_picker 2.0.0 (14.09.2026), file_picker_darwin 2.1.2 (22.09.2026), file_picker_linux 2.0.1 (22.09.2026), file_picker_platform_interface 4.0.0 (14.09.2026), file_picker_web 4.0.0 (14.09.2026), windows_file_picker 2.0.0 (14.09.2026), cross_file 0.3.5+5 (25.08.2026), dbus 0.8.0 (16.09.2026), petitparser 7.0.2 (14.02.2026), xml 7.0.1 (25.04.2026) | Alle mindestens 14 Tage alt (Stand 19.10.2026). Die ersten sechs und petitparser/xml sind in `app/pubspec.yaml` unter `dependency_overrides` festgehalten, weil bei der Auflösung sonst Oktober-Stände (android_file_picker 2.1.1, file_picker_platform_interface 4.2.0, file_picker_web 4.2.0 ..., jünger als 14 Tage) gewählt würden. **Wiedervorlage 19.11.2026:** prüfen, ob die neuen Stände dann 14 Tage alt sind, und die Overrides entfernen |
| http | 1.6.0 | Update-Prüfung und APK-Download |
| crypto | 3.0.7 | SHA-256 der APK |
| cryptography | 2.9.0 | Ed25519-Prüfung des Update-Manifests (reines Dart, auch im Web); 21.11.2025 |
| path_provider | 2.1.6 | Cache-Ordner für die heruntergeladene APK |
| intl | 0.20.3 | Datumsformate (de_DE) |
| flutter_lints | 6.0.0 | nur Entwicklung |
| build_runner | 2.16.1 | nur Entwicklung (drift-Code); `--delete-conflicting-outputs` nur lokal, nicht in der CI |
| analyzer | 14.4.0 | nur Entwicklung, **fest gepinnt**: 14.5.0 ist zu jung und bricht build_runner 2.16.1 |

## Android-Build

| Baustein | Version | Hinweis |
| --- | --- | --- |
| Android Gradle Plugin | 9.1.0 | `android/settings.gradle.kts`; mit `android.builtInKotlin=false` und `android.newDsl=false` (Flutter-Vorlage) |
| Kotlin-Plugin | 2.4.0 | `org.jetbrains.kotlin.android`, in `app/android/app/build.gradle.kts` angewendet |
| Gradle | 9.3.1 | Wrapper |
| androidx.core | 1.16.0 | `implementation` in `app/android/app/build.gradle.kts` (Update-Installation nutzt `PackageInstaller` ohne FileProvider) |

## Prüfsummen eingecheckter Binärdateien (Web)

`app/web/sqlite3.wasm` gehört zu sqlite3 **3.7.0** (in `app/pubspec.yaml` fest gepinnt, `pubspec.lock` eingecheckt); `app/web/drift_worker.js` zu drift 2.35.1. `app/web/passkeys-bundle.js` gehört zu passkeys_web 2.10.1 (siehe oben). Beim Aktualisieren von sqlite3 oder drift beide Dateien und diese Prüfsummen gemeinsam ändern. Die CI und `deploy/deploy-web.sh` prüfen sie mit `sha256sum -c app/web-assets.sha256`.

| Datei | SHA-256 |
| --- | --- |
| `sqlite3.wasm` | `fbcd2e8214f9231ea961e1b7706a22dd1194cfbfe6f26f13841b5aa7a0be1a1f` |
| `drift_worker.js` | `fe5f13be0526f78293796aefb9a29d3823a2dbdbf1bccd3f0faeb90eaaafd72a` |
| `passkeys-bundle.js` | `4ae8f64edcf3c6f31c28edadcbe77cc40bfabdfae74c1f683cd9c0f525a8b47e` |

Zeitzonen-Daten: `app/assets/tz/latest.tzf` ist die unveränderte Datei `lib/data/latest.tzf` aus timezone **0.11.1** (liegt im Flutter-Asset-Bündel, nicht unter `web/`; daher nicht in `web-assets.sha256`). Beim Aktualisieren von timezone die Datei aus dem Paket neu kopieren und diese Prüfsumme ändern: `e67e57be5d320b54e96381b59fdc2e7b0ec803b7e1be98621e445312cf5f295e` (SHA-256).

### Passkey-JS-Bündel (Web)

`app/web/passkeys-bundle.js` (16486 Byte) stammt aus dem Paket **passkeys_web 2.10.1**: Für diese Version gibt es kein veröffentlichtes `bundle.js` (die GitHub-Releases enthalten keine Dateien; die Anleitung des Pakets verweist auf ein altes von 2.4.0), daher wird es aus dem mitgelieferten Quelltext gebaut: Ordner `javascript/` des Pakets (im Pub-Cache) kopieren, `npm ci --ignore-scripts`, `npx rollup -c` (Ausgabe `dist/bundle.js`, `@github/webauthn-json` 2.1.1 aus dem mitgelieferten Lockfile). Es enthält keine Fremd-Adressen (nur einen W3C-Verweis im Kommentar). `web/index.html` bindet es per `<script src="passkeys-bundle.js">` ein (CSP `script-src 'self'`). `.gitattributes` führt es als binär, damit die Prüfsumme nicht durch Zeilenenden-Umwandlung bricht. Bei einem Update von passkeys/passkeys_web neu bauen und die Prüfsumme unten ändern.

## Platzhalter-Benutzerbilder

Die zehn Zeichnungen in `app/assets/avatare/` (V01, V08, V12, M01, M08, M13, K07, K08, K12, K13) stammen aus dem eigenen Mockup `docs/mockups/avatare.html` (eigene Zeichnungen des Projekts, keine Fremdquelle) und stehen unter der Lizenz des Projekts. Quellen (SVG) und Render-Skript: `app/tool/avatare/`.

## Auflagen aus der Recherche

- Flutter Web: `--no-web-resources-cdn`, Schriften (Inter, JetBrains Mono) bündeln, `fontFallbackBaseUrl` auf eigene Domain, CSP mit `'wasm-unsafe-eval'`. Im Network-Tab prüfen, dass nichts von Google lädt.
- Karte: Glyphen und Sprites selbst hosten, PMTiles per `pmtiles extract` aus Protomaps erzeugen, Größe vorab messen.
- Phase-0-Spikes: Passkey mit signierter Sideload-APK (ggf. ohne Play Services), drift im Web (Reload, zwei Tabs), UnifiedPush mit ntfy auf den echten Handys.
