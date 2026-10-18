# Gepinnte Versionen (Phase 0)

Stichtag 18.10.2026, nur Versionen mit mindestens 14 Tagen Alter. Lockfiles (`package-lock.json`, `pubspec.lock`) werden eingecheckt. Quelle: Research-Teammate.

## Server

| Paket | Version | Hinweis |
| --- | --- | --- |
| Node.js | 24.21.0 | wie lx-labs; Node 26 erst nach Phase 1 prüfen |
| TypeScript | 6.0.3 | TS 7 hat noch keine API, nur optional als Typcheck |
| Fastify | 5.12.5 | auf Node 24 im Test prüfen |
| @fastify/websocket | 11.3.3 | Auth über Session-Cookie beim Upgrade oder Einmal-Ticket |
| drizzle-orm / drizzle-kit | 0.45.3 / 0.31.11 | 1.0 noch RC; kein `db.query` (Relational v1) |
| PostgreSQL | 17 (Debian 13) oder 18.6 (PGDG) | Entscheidung offen |
| @simplewebauthn/server | 14.0.3 | Registrierung: `supportedAlgorithmIDs` auf klassische Algorithmen setzen |
| otplib | 13.5.0 | API ≠ v12; Replay-Schutz über `afterTimeStep` |
| argon2 | 0.45.1 | Argon2id, Prebuilds |
| @tus/server / @tus/file-store | 2.4.5 / 2.1.1 | Teil-Uploads liegen unverschlüsselt: nach `onUploadFinish` verschlüsselt ablegen |
| sharp | 0.35.5 | |
| Vitest | 5.0.3 | |
| ntfy | 2.28.0 (2.31.1 ab 31.10.) | eigene Subdomain, `deny-all`, UnifiedPush-Topics `up*` |

## App

| Paket | Version | Hinweis |
| --- | --- | --- |
| Flutter / Dart | 3.47.6 / 3.13.5 | wie lx-urlaubsplanung |
| flutter_riverpod | 3.4.3 | |
| drift / drift_dev | 2.35.1 | Web: COOP/COEP-Header für OPFS, sonst IndexedDB-Fallback |
| drift_flutter / sqlite3 | 0.3.1 / 3.7.0 | `sqlite3.wasm` zur Version passend |
| flutter_secure_storage | 11.2.0 | im Web nicht für Tokens nutzen (nur HttpOnly-Cookie) |
| passkeys | 2.23.1 | `assetlinks.json` mit allen Signatur-Fingerprints, `bundle.js` selbst hosten |
| unifiedpush / unifiedpush_android | 6.2.0 / 3.5.0 | nur Android |
| maplibre | 0.3.6 | Ersatz für flutter_map + PMTiles-Vektor (veraltet); pre-1.0 |
| geolocator | 14.1.1 | Vordergrunddienst eingebaut |
| web_socket_channel | 3.0.3 | Reconnect selbst bauen |

## Auflagen aus der Recherche

- Flutter Web: `--no-web-resources-cdn`, Schriften (Inter, JetBrains Mono) bündeln, `fontFallbackBaseUrl` auf eigene Domain, CSP mit `'wasm-unsafe-eval'`. Im Network-Tab prüfen, dass nichts von Google lädt.
- Karte: Glyphen und Sprites selbst hosten, PMTiles per `pmtiles extract` aus Protomaps erzeugen, Größe vorab messen.
- Phase-0-Spikes: Passkey mit signierter Sideload-APK (ggf. ohne Play Services), drift im Web (Reload, zwei Tabs), UnifiedPush mit ntfy auf den echten Handys.
