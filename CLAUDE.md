# lx-familienzentrale

Selbst gehostete Familien-Zentrale (Kalender, Chat, Listen, Aufgaben, Dateien, später Fotos, Karte u. a.) für die eigene Familie.
Web und Android aus einer Flutter-Codebasis, Server auf dem netcup-VPS von lx-labs.dev. Domain: **familie.lx-labs.dev**.
Sprache aller Inhalte, UI-Texte und Commit-Nachrichten: **Deutsch**, Ansprache per **du**. Verbindliche Beschreibung: `docs/PROJEKTBESCHREIBUNG.md`, Versionen: `docs/VERSIONEN.md`, Mockups: `docs/mockups/`.

Stand: **Phase 0** (Gerüst, keine Fachfeatures). Fahrplan in `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 12.

## Stack

- **Server** (`server/`): Node 24.21.0, TypeScript 6.0.3, Fastify 5.12.5, `@fastify/websocket` 11.3.3, Drizzle ORM 0.45.3 (+ drizzle-kit 0.31.11), PostgreSQL 17, Vitest 5.0.3, ESLint. Konfiguration nur über Umgebungsvariablen (`server/.env.example`).
- **App** (`app/`): Flutter 3.47.6 / Dart 3.13.5 (Android + Web, kein iOS), Riverpod 3.4.3, drift 2.35.1 (SQLite, im Web WASM/OPFS). Web ohne CDN: `--no-web-resources-cdn`, Schriften gebündelt, `fontFallbackBaseUrl` auf die eigene Domain.
- **Deploy** (`deploy/`): Caddy (Site `familie.lx-labs.dev`, ntfy auf `ntfy.familie.lx-labs.dev`), systemd-Dienst `lx-familie`, `deploy.sh`, `deploy-web.sh`. Einrichtung: `deploy/README.md`.
- **Versionen sind exakt gepinnt** (kein `^`, kein `~`), Lockfiles (`package-lock.json`, `pubspec.lock`) werden eingecheckt. Neue Pakete nur mit Version, die mindestens 14 Tage alt ist; in `docs/VERSIONEN.md` eintragen.

## Befehle

```bash
# Server (in server/)
npm ci
npm run dev          # tsx watch, liest .env
npm run lint         # ESLint
npm run typecheck    # tsc --noEmit
npm test             # Vitest (Schema-Test läuft gegen PGlite, keine lokale Datenbank nötig)
npm run build        # nach dist/
npm run db:generate  # neue Migration aus src/db/schema.ts erzeugen (drizzle/)
npm run migrate      # Migrationen anwenden (DATABASE_URL, nach build)

# App (in app/)
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift: erzeugt lib/data/app_database.g.dart (nicht eingecheckt)
flutter analyze
flutter test
flutter run -d chrome
flutter build web --release --no-web-resources-cdn

# Deploy
ssh lx-labs bash lx-familienzentrale/deploy/deploy.sh   # Server
deploy/deploy-web.sh                                    # Web-App
```

## Struktur

```
server/
  src/config.ts        Umgebungsvariablen -> Config
  src/app.ts           Fastify-App (buildApp, ohne Port; für Tests)
  src/server.ts        Start, Datenbank, Shutdown
  src/routes/          system.ts (/api/v1/health, /api/v1/version), placeholders.ts (501 bis Phase 1)
  src/ws/              WebSocket /ws (hello, ping/pong), Hub je Familie
  src/auth/, sync/     nur Typen/Platzhalter-Schnittstellen (Phase 1)
  src/db/              schema.ts (Drizzle), index.ts (Pool), migrate-cli.ts
  drizzle/             erzeugte SQL-Migrationen (einchecken)
  test/                Vitest: api.test.ts, migration.test.ts
app/
  lib/constants.dart   Design-Tokens, Personenfarben, Tabs, Konstanten
  lib/ui/              theme.dart (Material 3), widgets.dart (Glow-Hintergrund, Karten, Labels)
  lib/data/            drift-Datenbank, Provider, Sync-Zustand
  lib/features/<bereich>/  shell, home, calendar, chat, files, lists, login, update
  lib/widgets/         bereichsübergreifende Widgets (Sync-Indikator)
  web/                 index.html, flutter_bootstrap.js, sqlite3.wasm, drift_worker.js, Icons
  android/             applicationId dev.lx_labs.familienzentrale, MainActivity (Update-Kanal)
deploy/                Caddyfile, lx-familie.service, deploy.sh, deploy-web.sh, ntfy/server.yml, README.md
docs/                  Projektbeschreibung, Versionen, Mockups
.github/workflows/     CI: Server (Lint, Typen, Tests, Build), App (analyze, test)
```

## Design-Regeln (verbindlich)

Vorbild ist **lx-urlaubsplanung** (`src/app/globals.css`, `mobile/lib/main.dart`); Tokens stehen in `docs/PROJEKTBESCHREIBUNG.md` (Abschnitt Design) und in `app/lib/constants.dart`.

- **Nur Dark Mode.** Hintergrund `#090A0F` mit violett-cyanem Schimmer oben (`LxBackground`), kein Punktraster. Für Drucklisten später heller Druckstil.
- **Farben nur über Konstanten** (`kBg`, `kSurface`, `kAccent`, …) in `constants.dart`; keine Hex-Werte in Widgets. Neue Farben dort anlegen und in der Projektbeschreibung ergänzen.
- **Akzent** Cyber Cyan `#00F0FF` (Buttons, Auswahl), `neural` `#7C3AED` für Glow/Sonderfälle, `terminal` `#10B981` für „online/synchron“, `danger` `#FF5F57`.
- **Personenfarben:** feste Palette von 10 Farben (`personPalette`), je Familienmitglied einheitlich in Kalender, Chat, Karte, Listen.
- **Schrift:** Inter (Überschriften fett `w800`, Letter-Spacing negativ), JetBrains Mono für Kennzahlen, Status, Uhrzeiten, Metadaten und Abschnitts-Labels (`// zuletzt`, `MonoLabel`). Selbst gehostet, nie Google-Fonts-Abruf.
- **Material 3:** transparenter Scaffold über dem Verlauf, `NavigationBar` in `surface` mit Akzent-Indikator und Mono-Beschriftung, `FilledButton` in Cyan, Dialoge/Bottom-Sheets in `surface`, Karten mit 1-px-Rand `border` (`LxCard`). Keine weichen Drop-Shadows.
- Touch-Ziele mindestens 44 px, Layout ab 360 px Breite, Beschriftungen für Screenreader (`Semantics`/`tooltip`).
- Muster aus lx-urlaubsplanung (Sync-Indikator, Update-Dialog, Einstellungen) übernehmen statt neu erfinden.

## Konventionen

- Server: ESM, strikt typisiert, keine Fachlogik in Routen-Dateien, die Fastify-App entsteht in `buildApp()` (testbar mit `app.inject`). Jede fachliche Tabelle hat `family_id`; Sync-Tabellen haben `rev`, `field_revs`, `deleted_at` (Tombstone). Migrationen nur vorwärts und rückwärtskompatibel zur Vorgängerversion der App.
- Schema-Änderungen: `src/db/schema.ts` ändern, `npm run db:generate`, erzeugte Dateien in `drizzle/` einchecken. Nie eine eingecheckte Migration nachträglich ändern.
- App: ein Bereich = ein Ordner unter `lib/features/`; Zustand mit Riverpod; keine Netzwerk- oder dart:io-Zugriffe in Code, der im Web läuft, ohne bedingten Import (siehe `features/update/apk_downloader*.dart`).
- Offline-first: UI schreibt in die lokale DB/Outbox und wartet nie auf den Server (Sync-Protokoll: Projektbeschreibung Abschnitt 6).
- Datenschutz: keine Tracker, keine Fremd-Einbindungen (Schriften, Karten, Skripte), Push ohne Inhalte, Standort nur durch die Person selbst. CSP in `deploy/Caddyfile` nicht lockern, ohne Security zu fragen.
- `applicationId` (`dev.lx_labs.familienzentrale`) und Android-Signaturschlüssel nie ändern.
- Geheimnisse (`.env`, `key.properties`, Keystores, Signaturschlüssel des Update-Manifests) nie einchecken.
- Commit-Nachrichten auf Deutsch, kurz und im Imperativ-/Beschreibungsstil. Kein Push nach `main` ohne ausdrücklichen Auftrag.

## Team

Research, QM/Testing, Coding, Code-Review, Security (Subagenten in `~/.claude/agents/`). Jede Phase durchläuft: Research → Coding → QM/Testing (Sync-Randfälle, Mobilansicht ab 360 px) → Code-Review → Security (vor jedem Deploy, v. a. Auth, Uploads, OTA-Signatur).
