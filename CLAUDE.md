# lx-fampad

Selbst gehostete Familien-Zentrale (Kalender, Chat, Listen, Aufgaben, Dateien, später Fotos, Karte u. a.) für die eigene Familie.
Web und Android aus einer Flutter-Codebasis, Server auf dem netcup-VPS von lx-labs.dev. Domain: **familie.lx-labs.dev**.
Sprache aller Inhalte, UI-Texte und Commit-Nachrichten: **Deutsch**, Ansprache per **du**. Verbindliche Beschreibung: `docs/PROJEKTBESCHREIBUNG.md`, Versionen: `docs/VERSIONEN.md`, Mockups: `docs/mockups/`.

Stand: **Phase 1a** (Server: Konten und Anmeldung; die App folgt in 1b, Sync in 1c). Fahrplan in `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 12; Endpunkte in `docs/API.md`.

## Stack

- **Server** (`server/`): Node 24.21.0, TypeScript 6.0.3, Fastify 5.12.5, `@fastify/websocket` 11.3.3, Drizzle ORM 0.45.3 (+ drizzle-kit 0.31.11), PostgreSQL 17, Vitest 5.0.3, ESLint. Anmeldung: `@simplewebauthn/server` 14.0.3 (Passkeys), `argon2` 0.45.1 (Argon2id), `otplib` 13.5.0 (TOTP), `zod` 4.6.5 (Eingabevalidierung). Konfiguration nur über Umgebungsvariablen (`server/.env.example`); ohne `NODE_ENV` gilt `production` (fail-closed), unbekannte Werte brechen den Start ab, lokal `NODE_ENV=development` in `.env`. In `production` ist `AUTH_SECRET_KEY` Pflicht (Hauptschlüssel für TOTP-Verschlüsselung und HMACs, nie in der Datenbank, nie ändern).
- **App** (`app/`): Flutter 3.47.6 / Dart 3.13.5 (Android + Web, kein iOS), Riverpod 3.4.3, drift 2.35.1 (SQLite, im Web WASM/OPFS). Web ohne CDN: `--no-web-resources-cdn`, Schriften gebündelt, `fontFallbackBaseUrl` auf die eigene Domain. `analyzer` (14.4.0) und `sqlite3` (3.7.0, passend zu `web/sqlite3.wasm`) sind bewusst gepinnt; `app/web-assets.sha256` hält die Prüfsummen der Web-Binärdateien.
- **Deploy** (`deploy/`): Caddy (Site `familie.lx-labs.dev`, ntfy auf `ntfy.familie.lx-labs.dev`), systemd-Dienst `lx-fampad`, `deploy.sh`, `deploy-web.sh`. Einrichtung: `deploy/README.md`.
- **Versionen sind exakt gepinnt** (kein `^`, kein `~`), Lockfiles (`package-lock.json`, `pubspec.lock`) werden eingecheckt. Neue Pakete nur mit Version, die mindestens 14 Tage alt ist; in `docs/VERSIONEN.md` eintragen.

## Befehle

```bash
# Server (in server/)
npm ci
npm run dev          # tsx watch, liest .env
npm run lint         # ESLint
npm run typecheck    # tsc --noEmit
npm test             # Vitest (Schema- und Anmelde-Tests laufen gegen PGlite; mit TEST_DATABASE_URL=postgres://… zusätzlich gegen echtes PostgreSQL)
npm run build        # nach dist/
npm run db:generate  # neue Migration aus src/db/schema.ts erzeugen (drizzle/)
npm run migrate      # Migrationen anwenden (MIGRATION_DATABASE_URL, sonst DATABASE_URL; nach build)
npm run bootstrap    # Erstinstallation: Familie + Einladungslink für den ersten Admin (nach build); --reset <E-Mail> für den Notfall; auf dem Server: sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js

# App (in app/)
flutter pub get --enforce-lockfile   # pubspec.lock ist eingecheckt; neu auflösen nur bewusst mit "flutter pub get"
dart run build_runner build --delete-conflicting-outputs   # drift: erzeugt lib/data/app_database.g.dart (nicht eingecheckt); in der CI ohne die Option
flutter analyze
flutter test
flutter run -d chrome
flutter build web --release --no-web-resources-cdn

# Werkzeuge (Repo-Wurzel)
node --test "tools/*.test.mjs"                                      # Test der Manifest-Signatur
node tools/update-manifest.mjs keygen|sign …            # Update-Schlüssel, Manifest signieren (tools/README.md)

# Deploy
ssh lx-labs bash lx-fampad/deploy/deploy.sh   # Server
deploy/deploy-web.sh                                    # Web-App
```

## Struktur

```
server/
  src/config.ts        Umgebungsvariablen -> Config
  src/log.ts, net.ts   Fehler-Serializer fürs Log (nie SQL-Parameter), IP-Normalisierung (IPv6 /64)
  src/app.ts           Fastify-App (buildApp, ohne Port; für Tests)
  src/server.ts        Start, Datenbank, Shutdown
  src/errors.ts        AppError + eigener Fehlerhandler (nie interne Meldungen)
  src/routes/          system.ts (health, version), auth.ts (/api/v1/auth/*), account.ts (/me, /members, /invites, /devices, /ws-ticket), util.ts (Zod-Hilfen, Sitzungsantwort), placeholders.ts (/sync: 501 bis Phase 1c)
  src/ws/              WebSocket /ws (Origin-Prüfung, Ticket-Anmeldung, Anmeldefrist, Server-Ping, Nachrichten-/Verbindungslimits atomar), Hub je Familie
  src/auth/            Anmeldung: invites, register, login, sessions (Cookie, Access-/Refresh-Token, Step-up), account (Mitglieder, Geräte, Anmeldedaten, WS-Tickets), lockout, audit, maintenance (Aufräum-Job), bootstrap, crypto/password/totp/webauthn/recovery/challenges, service (Auth)
  src/cli/             bootstrap.ts (Erstinstallation, Notfall-Zurücksetzen)
  src/sync/            nur Typen (Phase 1c)
  src/db/              schema.ts (Drizzle), index.ts (Pool), migrate-cli.ts (Migrationsrolle)
  drizzle/             erzeugte SQL-Migrationen (einchecken)
  test/                Vitest: api.test.ts (Routen, Rate-Limit, WebSocket, Konfiguration, Fehlerhandler), migration.test.ts (Schema), auth.test.ts (Bootstrap, Einladungen), auth-login.test.ts (Anmeldearten, Sitzungen, Step-up, Sperren, Familiengrenze, Aufräumen), ws-auth.test.ts (Tickets, Limits), hardening.test.ts (Log ohne Parameter, ungültige Zeichen, IPv6, Aufräumen, Einladungsrechte, WebSocket-Widerruf), crypto.test.ts (Known-Answer der Schlüsselableitung, IP, Serializer, Zeichen); authenticator.ts (simulierter WebAuthn-Authenticator), helpers.ts (Backends PGlite/PostgreSQL, Welt mit Uhr)
app/
  lib/constants.dart   Design-Tokens, Personenfarben, Tabs, Konstanten
  lib/ui/              theme.dart (Material 3), widgets.dart (Glow-Hintergrund, Karten, Labels)
  lib/data/            drift-Datenbank, Provider, Sync-Zustand
  lib/features/<bereich>/  shell, home, calendar, chat, files, lists, login, update (Manifest-Prüfung Ed25519, Download, Pflicht-Update)
  lib/widgets/         bereichsübergreifende Widgets (Sync-Indikator)
  web/                 index.html, flutter_bootstrap.js, sqlite3.wasm, drift_worker.js, Icons
  android/             applicationId dev.lx_labs.fampad, MainActivity + UpdateReceiver (Update per PackageInstaller)
  test/                app_test (Tabs), update_test (Ed25519, Manifest), mobile_layout_test (360 px, Textskala 1.5, Touch-Ziele)
deploy/                Caddyfile, lx-fampad.service + lx-fampad-migrate.service, einrichtung-1/2/auth.sh, deploy.sh, deploy-web.sh, umbenennung-server.sh (einmalig), ntfy/server.yml, README.md
tools/                 update-manifest.mjs (Ed25519-Signatur des Update-Manifests), README.md
docs/                  Projektbeschreibung, Versionen, Datenschutz-Entwurf, Mockups
.github/workflows/     ci.yml: Server (Lint, Typen, Tests, Build), App (analyze, test), Android-Debug-Build; release.yml: APK bauen/signieren, Manifest, Release-Entwurf (deploy/README.md, Abschnitt 10)
```

## Design-Regeln (verbindlich)

Vorbild ist **lx-urlaubsplanung** (`src/app/globals.css`, `mobile/lib/main.dart`); Tokens stehen in `docs/PROJEKTBESCHREIBUNG.md` (Abschnitt Design) und in `app/lib/constants.dart`.

- **Nur Dark Mode.** Hintergrund `#090A0F` mit violett-cyanem Schimmer oben (`LxBackground`), kein Punktraster. Für Drucklisten später heller Druckstil.
- **Farben nur über Konstanten** (auch Weiß: `kTextStrong`, kein `Colors.white`) (`kBg`, `kSurface`, `kAccent`, …) in `constants.dart`; keine Hex-Werte in Widgets. Neue Farben dort anlegen und in der Projektbeschreibung ergänzen.
- **Akzent** Cyber Cyan `#00F0FF` (Buttons, Auswahl), `neural` `#7C3AED` für Glow/Sonderfälle, `terminal` `#10B981` für „online/synchron“, `danger` `#FF5F57`.
- **Personenfarben:** feste Palette von 10 Farben (`personPalette`), je Familienmitglied einheitlich in Kalender, Chat, Karte, Listen.
- **Schrift:** Inter (Überschriften fett `w800`, Letter-Spacing negativ), JetBrains Mono für Kennzahlen, Status, Uhrzeiten, Metadaten und Abschnitts-Labels (`// zuletzt`, `MonoLabel`). Selbst gehostet, nie Google-Fonts-Abruf.
- **Material 3:** transparenter Scaffold über dem Verlauf, `NavigationBar` in `surface` mit Akzent-Indikator und Mono-Beschriftung, `FilledButton` in Cyan, Dialoge/Bottom-Sheets in `surface`, Karten mit 1-px-Rand `border` (`LxCard`). Keine weichen Drop-Shadows.
- Touch-Ziele mindestens 44 px (feste Höhen per `mainAxisExtent`, nie `childAspectRatio`), Inhalt auf `kMaxContentWidth` (720 px) begrenzt, Layout ab 360 px Breite auch bei Textskalierung 1.5, Beschriftungen für Screenreader (`Semantics`/`tooltip`).
- Muster aus lx-urlaubsplanung (Sync-Indikator, Update-Dialog, Einstellungen) übernehmen statt neu erfinden.

## Konventionen

- Server: ESM, strikt typisiert, keine Fachlogik in Routen-Dateien, die Fastify-App entsteht in `buildApp()` (testbar mit `app.inject`). Jede fachliche Tabelle hat `family_id`; Sync-Tabellen haben `rev`, `field_revs`, `deleted_at` (Tombstone). Migrationen nur vorwärts und rückwärtskompatibel zur Vorgängerversion der App.
- Fremdschlüssel zwischen familiengebundenen Tabellen sind zusammengesetzt `(family_id, id)`; Ziel-Tabellen brauchen dafür `unique(...)` (kein `uniqueIndex`, drizzle-kit legt Fremdschlüssel vor den Indizes an). Schema-Änderungen: `src/db/schema.ts` ändern, `npm run db:generate`, erzeugte Dateien in `drizzle/` einchecken. Nie eine eingecheckte Migration nachträglich ändern.
- App: ein Bereich = ein Ordner unter `lib/features/`; Zustand mit Riverpod; keine Netzwerk- oder dart:io-Zugriffe in Code, der im Web läuft, ohne bedingten Import (siehe `features/update/apk_downloader*.dart`).
- Anmeldung (Server): Geheimnisse nur gehasht oder verschlüsselt (Tokens/Tickets SHA-256, Passwörter Argon2id, Codes/PINs HMAC, TOTP AES-256-GCM); Einmal-Einlösungen immer atomar (`UPDATE/DELETE … RETURNING`, Zählen vor dem Vergleich); alle Fehlschläge der Anmeldung antworten gleich; jede Route, die Familiendaten liefert, filtert über die Familie der Sitzung (fremde Objekte = 404); neue Prüfungen für sensible Aktionen über `requireStepUp`. Datenbank-Rollen: Laufzeit nur DML (`DATABASE_URL`), Migrationen mit `MIGRATION_DATABASE_URL`.
- Offline-first: UI schreibt in die lokale DB/Outbox und wartet nie auf den Server (Sync-Protokoll: Projektbeschreibung Abschnitt 6).
- Datenschutz: keine Tracker, keine Fremd-Einbindungen (Schriften, Karten, Skripte), Push ohne Inhalte, Standort nur durch die Person selbst. CSP in `deploy/Caddyfile` nicht lockern, ohne Security zu fragen.
- `applicationId` (`dev.lx_labs.fampad`) und Android-Signaturschlüssel nie ändern.
- Geheimnisse (`.env`, `key.properties`, Keystores, Signaturschlüssel des Update-Manifests) nie einchecken. `kUpdatePublicKey` ist bis zum ersten Release ein Platzhalter (siehe `tools/README.md`).
- Commit-Nachrichten auf Deutsch, kurz und im Imperativ-/Beschreibungsstil. Kein Push nach `main` ohne ausdrücklichen Auftrag.

## Team

Research, QM/Testing, Coding, Code-Review, Security (Subagenten in `~/.claude/agents/`). Jede Phase durchläuft: Research → Coding → QM/Testing (Sync-Randfälle, Mobilansicht ab 360 px) → Code-Review → Security (vor jedem Deploy, v. a. Auth, Uploads, OTA-Signatur).
