# lx-fampad

Selbst gehostete Familien-Zentrale (Kalender, Chat, Listen, Aufgaben, Dateien, später Fotos, Karte u. a.) für die eigene Familie.
Web und Android aus einer Flutter-Codebasis, Server auf dem netcup-VPS von lx-labs.dev. Domain: **familie.lx-labs.dev**.
Sprache aller Inhalte, UI-Texte und Commit-Nachrichten: **Deutsch**, Ansprache per **du**. Verbindliche Beschreibung: `docs/PROJEKTBESCHREIBUNG.md`, Versionen: `docs/VERSIONEN.md`, Mockups: `docs/mockups/`.

Stand: **Phase 1c-2a** (Server: Konten und Anmeldung seit 1a, Sync-Kern; App: Anmeldung, Einladungen, Konto, Admin seit 1b, Sync und **Listen** in 1c-1, **Kalender-Kern** (Termine, Teilnehmer, Ausnahmen, Serien) in 1c-2a; Chat, Aufgaben, Dateien folgen als eigene Teile auf demselben Kern). Fahrplan in `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 12; Endpunkte in `docs/API.md`.

## Stack

- **Server** (`server/`): Node 24.21.0, TypeScript 6.0.3, Fastify 5.12.5, `@fastify/websocket` 11.3.3, Drizzle ORM 0.45.3 (+ drizzle-kit 0.31.11), PostgreSQL 17, Vitest 5.0.3, ESLint. Anmeldung: `@simplewebauthn/server` 14.0.3 (Passkeys), `argon2` 0.45.1 (Argon2id), `otplib` 13.5.0 (TOTP), `zod` 4.6.5 (Eingabevalidierung). Konfiguration nur über Umgebungsvariablen (`server/.env.example`); ohne `NODE_ENV` gilt `production` (fail-closed), unbekannte Werte brechen den Start ab, lokal `NODE_ENV=development` in `.env`. In `production` ist `AUTH_SECRET_KEY` Pflicht (Hauptschlüssel für TOTP-Verschlüsselung und HMACs, nie in der Datenbank, nie ändern).
- **App** (`app/`): Flutter 3.47.6 / Dart 3.13.5 (Android + Web, kein iOS), Riverpod 3.4.3, drift 2.35.1 (SQLite, im Web WASM/OPFS), `rrule` 0.2.18 + `timezone` 0.11.1 (Terminserien; Zeitzonen-Daten als Asset `assets/tz/latest.tzf`); Anmeldung: `flutter_secure_storage` 11.2.0, `passkeys` 2.23.1 (Web: selbst gehostetes `web/passkeys-bundle.js`), `mobile_scanner` 7.4.2 (QR-Scan, nur Android), `qr_flutter` 4.1.0. Web ohne CDN: `--no-web-resources-cdn`, Schriften gebündelt, `fontFallbackBaseUrl` auf die eigene Domain. `analyzer` (14.4.0) und `sqlite3` (3.7.0, passend zu `web/sqlite3.wasm`) sind bewusst gepinnt; `app/web-assets.sha256` hält die Prüfsummen der Web-Binärdateien (inkl. `passkeys-bundle.js`).
- **Deploy** (`deploy/`): Caddy (Site `familie.lx-labs.dev`, ntfy auf `ntfy.familie.lx-labs.dev`), systemd-Dienst `lx-fampad`, `deploy.sh`, `deploy-web.sh`. Einrichtung: `deploy/README.md`.
- **Versionen sind exakt gepinnt** (kein `^`, kein `~`), Lockfiles (`package-lock.json`, `pubspec.lock`) werden eingecheckt. Neue Pakete nur mit Version, die mindestens 14 Tage alt ist; in `docs/VERSIONEN.md` eintragen.

## Befehle

```bash
# Server (in server/)
npm ci
npm run dev          # tsx watch, liest .env
npm run lint         # ESLint
npm run typecheck    # tsc --noEmit
npm test             # Vitest (Schema-, Anmelde- und Sync-Tests laufen gegen PGlite; mit TEST_DATABASE_URL=postgres://… zusätzlich gegen echtes PostgreSQL 17, dort auch die Parallelitäts-Tests)
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
# Vertragsprüfung gegen den echten Server (nicht Teil von flutter test): app/tool/vertrag_test.dart (Anmeldung und seit 1c der Sync mit zwei Geräten, Konflikten, Rechten, WebSocket, mehrseitigem Snapshot bei purged_rev > 0, Geisterliste), Ablauf im Dateikopf

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
  src/routes/          system.ts (health, version), auth.ts (/api/v1/auth/*), account.ts (/me, /members, /invites, /devices, /ws-ticket), sync.ts (POST /sync), util.ts (Zod-Hilfen, Sitzungsantwort)
  src/ws/              WebSocket /ws (Origin-Prüfung, Ticket-Anmeldung, Anmeldefrist, Server-Ping, Nachrichten-/Verbindungslimits atomar), Hub je Familie
  src/auth/            Anmeldung: invites, register, login, sessions (Cookie, Access-/Refresh-Token mit Rotation und 30-s-Toleranzfenster für verlorene Antworten, Step-up), account (Mitglieder, Geräte, Anmeldedaten, WS-Tickets), lockout, audit, maintenance (Aufräum-Job), bootstrap, crypto/password/totp/webauthn/recovery/challenges, service (Auth)
  src/cli/             bootstrap.ts (Erstinstallation, Notfall-Zurücksetzen)
  src/push/            Push-Wecker (UnifiedPush über eigenes ntfy): endpoint.ts (SSRF-Prüfung der gemeldeten Endpunkte), service.ts (Empfänger, Entprellung, Versand an Loopback-ntfy, Deaktivierung, Empfängerfilter-Hook); routes/push.ts (/me/push)
  src/sync/            Sync-Kern: registry.ts (Entitäten-Register: Felder, Rechte, Beziehungen), permissions.ts (zentrales Rechte-Modell, Rollen mit Sicht für die WebSocket-Hinweise), engine.ts (Ops: Idempotenz, Konflikte pro Feld, Löschen mit Kaskade, Zeitlimits), limits.ts (Token-Buckets je Gerät und Person), pull.ts (Änderungsstrom, mehrseitiger Snapshot mit snapshotRev, Resync, "hidden"), refs.ts (Verweise auf entfernte Mitglieder), maintenance.ts (Tombstones, Protokoll, applied_ops), types.ts (Protokoll), rrule.ts (Prüfung von Wiederholungsregeln), entities/common.ts (gemeinsame Feld-Prüfungen), entities/lists.ts (Listen und Einträge), entities/termine.ts (Termine, Teilnehmer, Ausnahmen), index.ts (Register)
  src/db/              schema.ts (Drizzle), index.ts (Pool), migrate-cli.ts (Migrationsrolle)
  drizzle/             erzeugte SQL-Migrationen (einchecken)
  test/                Vitest: api.test.ts (Routen, Rate-Limit, WebSocket, Konfiguration, Fehlerhandler), migration.test.ts (Schema), auth.test.ts (Bootstrap, Einladungen), auth-login.test.ts (Anmeldearten, Sitzungen, Step-up, Sperren, Familiengrenze, Aufräumen), ws-auth.test.ts (Tickets, Limits), sync.test.ts / sync-rights.test.ts / sync-ops.test.ts / sync-korrektur.test.ts (Sync: Idempotenz, Konflikte, Löschen, Seiten, Parallelität, Validierung; Rechte-Regeltabelle, IDOR, Freigabe; WebSocket, Wartung, Limits; mehrseitiger Snapshot, Geisterlisten, Neusynchronisierung, Token-Buckets, Konfliktwerte, Zeitlimits, WebSocket nur an Rollen mit Sicht; Hilfen in sync-kit.ts), sync-kalender.test.ts (RRULE-Prüfung, Zeitmodell, Rechte-Regeltabelle und Konflikte der Termine, Ausnahmen, Teilnehmer, Kaskade), hardening.test.ts (Log ohne Parameter, ungültige Zeichen, IPv6, Aufräumen, Einladungsrechte, WebSocket-Widerruf), crypto.test.ts (Known-Answer der Schlüsselableitung, IP, Serializer, Zeichen); authenticator.ts (simulierter WebAuthn-Authenticator), helpers.ts (Backends PGlite/PostgreSQL, Welt mit Uhr)
app/
  lib/constants.dart   Design-Tokens, Personenfarben, Tabs, Konstanten
  lib/data/api/        ApiClient (Cookie+CSRF / Bearer+Refresh, Sitzungsgeneration), FampadApi (Endpunkte), Modelle (DTOs, Listen pro Eintrag tolerant), ApiException (deutsche Meldungen, VerbindungsaufbauFehler), Token-Ablage, http_client_io/stub (Android: Verbindungsaufbau getrennt vom Senden)
  lib/data/auth/       auth_state.dart (AuthStatus, AuthController mit Generationszähler, Hooks localDataWiperProvider/localDataOwnerProvider; Daten nur bei ausdrücklichem Abmelden oder anderer Person leeren); lib/data/passkey_service.dart, system_channel.dart (Android-Kanal: Gerätename, FLAG_SECURE, Links)
  lib/ui/              theme.dart (Material 3), widgets.dart (Glow-Hintergrund, Karten, Labels)
  lib/data/calendar/   Kalender-Daten: zeitzonen.dart (Europe/Berlin, Wanduhr <-> Zeitpunkt, Daten laden), expansion.dart (Serien auflösen: rrule + timezone, Ausnahmen, Deckel), wiederholung.dart (Auswahl <-> RRULE), termin_repository.dart (lokal schreiben, Serien ändern, Rechte)
  lib/data/            drift-Datenbank (Version 3: Listen, Einträge, Termine, Teilnehmer, Ausnahmen, Outbox, Sync-Meta), sync_state.dart (Sync-Dienst: Auslöser, Backoff, Zustand für den Indikator), sync/ (sync_store: lokale Änderungen + Antwort übernehmen, sync_engine: ein Abgleichslauf, sync_socket: WebSocket-Client, sync_entities: Entitäten-Register des Clients, sync_models), lists/ (Repository, Rechte der Oberfläche, Mitglieder)
  lib/features/<bereich>/  shell (home_shell: Weiche Mobil/Desktop ab 900 px; desktop_shell: Seitenleiste, Fußzeile, ein IndexedStack mit GlobalKeys), home (home_screen mobil, desktop_home: Karten-Raster der Startseite im Desktop-Layout), calendar (Kalender real seit 1c-2a: Agenda, Monat, Woche, Editor, Detail), chat, files, lists (Listen real seit 1c-1), auth (Login, Einladung, Codes, Warten, Step-up), profile (Profil, Passkeys, Geräte), admin (Mitglieder, Einladungen), update (Manifest-Prüfung Ed25519, Download, Pflicht-Update)
  lib/data/push/       Push (Android, UnifiedPush): push_plattform(+_up/_stub/_fabrik, bedingter Import), push_state (Schalter, Endpunkt, Test), push_wecker (Schnittstelle EreignisBenachrichtiger), push_hintergrund (--unifiedpush-bg); Oberfläche features/profile/push_screen.dart
  lib/widgets/         bereichsübergreifende Widgets: kopfzeile.dart (gemeinsame Kopfzeile aller Tabs: Datum, Titel, Sync-Indikator, Profil-Knopf), sync_indicator.dart, sync_hinweise.dart (Statusleiste und Hinweise des Abgleichs), sync_anzeige (Text und Farbe des Sync-Zustands für Startseite und Desktop-Fußzeile)
  web/                 index.html, flutter_bootstrap.js, sqlite3.wasm, drift_worker.js, Icons
  android/             applicationId dev.lx_labs.fampad, MainActivity + UpdateReceiver (Update per PackageInstaller)
  test/                sync_store_test, sync_engine_test, sync_controller_test, sync_indicator_test, sync_socket_test, sync_auth_test, db_migration_test, lists_screen_test (Sync-Kern gegen Fake-Server/-Socket, Migration, Listen-UI mit Layout 360 px/Textskala 1.5), kalender_expansion_test (Serien, Sommerzeit, Ausnahmen, Deckel, Wiederholung), kalender_repository_test (lokal zuerst, Serien ändern, Rechte, Abgleich mit zwei Geräten), kalender_screen_test (Kopfzeile aller Tabs, Agenda/Monat/Woche, Editor, Serien, Rechte, Update-Hinweis; 360 px/Textskala 1.5), app_test (Tabs), update_test, mobile_layout_test + auth_layout_test (360 px, Textskala 1.5, Touch-Ziele), api_client_test, http_client_test (echte Sockets), auth_state_test, auth_screens_test, auth_flows_test (Einladungslinks, Abmelden, Step-up, Neuladen), models_test, invite_link_test, token_store_passkey_test; support/ (Fake-Server mit MockClient, Beispielantworten)
  tool/                vertrag_test.dart (App-Klassen gegen den echten Server)
deploy/                Caddyfile, lx-fampad.service + lx-fampad-migrate.service, einrichtung-1/2/auth.sh, einrichtung-ntfy.sh + einrichtung-ntfy-up.sh (ntfy, Rechte auf up*), deploy.sh, deploy-web.sh, umbenennung-server.sh (einmalig), ntfy/server.yml, README.md
tools/                 update-manifest.mjs (Ed25519-Signatur des Update-Manifests), README.md
branding/              icon.svg (Master, „lx“ als Pfade), play-store-icon-512.png, make-icons.mjs (Generator)
docs/                  Projektbeschreibung, Versionen, Datenschutz-Entwurf, Mockups
.github/workflows/     ci.yml: Server (Lint, Typen, Tests, Build), App (analyze, test), Android-Debug-Build; release.yml: APK bauen/signieren, Manifest, Release-Entwurf (deploy/README.md, Abschnitt 10)
```

## Icon neu erzeugen

Master: `branding/icon.svg` (120×120, „lx“ aus dem Inter-Variable-Font bei wght 800 als Pfade, vier Personenpunkte im Haus). Alle PNGs entstehen aus `branding/make-icons.mjs`:

```bash
mkdir C:/lxq/icontool && cd C:/lxq/icontool && npm i opentype.js sharp   # Werkzeuge außerhalb des Repos
cd <Repo> && ICON_TOOLS=C:/lxq/icontool node branding/make-icons.mjs
```

Schreibt: `branding/icon.svg`, `branding/play-store-icon-512.png`, `app/web/{favicon.png,icons/*}` (Icon-192/512, Icon-maskable-192/512, apple-touch-icon), Android `mipmap-*/ic_launcher(_round).png` und die Adaptiv-Ebenen `drawable-nodpi/ic_launcher_{background,foreground,monochrome}.png` (`mipmap-anydpi-v26/*.xml` ist von Hand und bleibt). Änderungen am Entwurf nur im Skript machen; danach Vorschau (`ICON_TOOLS/prev`) ansehen, bei 48 und 24 px prüfen. Maskable/adaptiv/Play: Inhalt auf 74 % in der Safe-Zone. `app/web-assets.sha256` ist nicht betroffen (listet keine Icons).

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
- **Kopfzeile aller Tabs identisch:** Jeder Tab beginnt mit `TabKopfzeile(title: …)` (`lib/widgets/kopfzeile.dart`: Datum als `MonoLabel`, Titel, Sync-Indikator, Profil-Knopf; im Desktop-Layout ab `kDesktopBreakpoint` nur Datum und Titel, weil Fußzeile und Seitenleiste Sync und Profil zeigen); nur der Titel ist tab-spezifisch, keine eigenen Aktionen oder Status-Pillen in der Kopfzeile. Der Profil-Knopf zeigt Initialen in der Personenfarbe und nimmt später das Benutzerbild (`bild`) auf.

## Konventionen

- Server: ESM, strikt typisiert, keine Fachlogik in Routen-Dateien, die Fastify-App entsteht in `buildApp()` (testbar mit `app.inject`). Jede fachliche Tabelle hat `family_id`; Sync-Tabellen haben `rev`, `field_revs`, `deleted_at` (Tombstone). Migrationen nur vorwärts und rückwärtskompatibel zur Vorgängerversion der App.
- Fremdschlüssel zwischen familiengebundenen Tabellen sind zusammengesetzt `(family_id, id)`; Ziel-Tabellen brauchen dafür `unique(...)` (kein `uniqueIndex`, drizzle-kit legt Fremdschlüssel vor den Indizes an). Schema-Änderungen: `src/db/schema.ts` ändern, `npm run db:generate`, erzeugte Dateien in `drizzle/` einchecken. Nie eine eingecheckte Migration nachträglich ändern.
- App: ein Bereich = ein Ordner unter `lib/features/`; Zustand mit Riverpod; keine Netzwerk- oder dart:io-Zugriffe in Code, der im Web läuft, ohne bedingten Import (siehe `features/update/apk_downloader*.dart`).
- Anmeldung (Server): Geheimnisse nur gehasht oder verschlüsselt (Tokens/Tickets SHA-256, Passwörter Argon2id, Codes/PINs HMAC, TOTP AES-256-GCM); Einmal-Einlösungen immer atomar (`UPDATE/DELETE … RETURNING`, Zählen vor dem Vergleich); alle Fehlschläge der Anmeldung antworten gleich; jede Route, die Familiendaten liefert, filtert über die Familie der Sitzung (fremde Objekte = 404); neue Prüfungen für sensible Aktionen über `requireStepUp`. Datenbank-Rollen: Laufzeit nur DML (`DATABASE_URL`), Migrationen mit `MIGRATION_DATABASE_URL`.
- Offline-first: UI schreibt in die lokale DB/Outbox und wartet nie auf den Server (Sync-Protokoll: Projektbeschreibung Abschnitt 6 und 6a, `docs/API.md`, Abschnitt „Sync“).
- Kalender: Familienzeitzone fest Europe/Berlin; Zeittermine als UTC + `tzid`, ganztägige als Tage (Ende exklusiv); Serien rechnet nur der Client (`rrule` auf Wanduhrzeit der `tzid` als UTC getarnt, danach `timezone`), der Server prüft nur die Form (`sync/rrule.ts`); Ausnahmen mit fester ID aus Termin und Beginn; nie eine Serie über `any`-Zeiten oder Geräte-Zeitzone rechnen. Serien teilen, kürzen und Ausnahmen vergleichen immer gegen den **ursprünglichen** Beginn (`Vorkommen.original*`), Ausnahmen nie löschen (nur zurücksetzen), `AuswahlKnopf` nie mit `Container(alignment:)` füllen (stapelt sich im `Wrap`).
- Neue Sync-Entität (Aufgaben, Chat, Dateien): Tabelle mit `syncColumns()` und `family_id` (Migration), Eintrag im **Register des Servers** (`server/src/sync/entities/*.ts` + `index.ts`: Felder mit Zod-Prüfung, Rechte-Regel je Rolle, Elternbeziehung, `userRefs`, Obergrenzen, optional `check` für Regeln über mehrere Felder) und im **Register der App** (`app/lib/data/sync/sync_entities.dart` + drift-Tabelle + Repository); Protokoll und Rechte-Modell bleiben unverändert. Rechte nie in Routen oder Engine, nur in der Regeltabelle (`sync/permissions.ts`); nicht lesbare Datensätze ergeben `not_found`. Jede Op wird feldweise geprüft (kein `any`, keine Inhalte im Log); Verweise auf Mitglieder (`ON DELETE SET NULL`) prüft die Engine und bereinigt `sync/refs.ts`.
- Sync (App): lokale Änderungen nur über `SyncStore.aendern/loeschen` (Tabelle + Ausgang in einer Transaktion), Serverantworten nur über `SyncStore.uebernehmen`; ein Abgleich läuft immer nur einzeln (`SyncController`), 401 nie in der Sync-Schleife wiederholen, vor dem Leeren der Datenbank den Sync anhalten (`lokaleDatenWiper`).
- Widget-Tests mit drift: Datenbank mit `DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true)` anlegen (sonst bleiben Timer von drift stehen), Hilfen in `test/support/test_app.dart`.
- App-Anmeldung: Token nie loggen oder in localStorage legen; Refresh nie parallel oder blind wiederholen (Familien-Widerruf); Einladungs-Token nur im Fragment/POST-Body; Screens mit Geheimnissen in `BildschirmSchutz` (FLAG_SECURE); Zwischenablage nur auf Klick; Meldungen nur aus `ApiException`/`PasskeyException` (keine Servertexte).
- Datenschutz: keine Tracker, keine Fremd-Einbindungen (Schriften, Karten, Skripte), Push ohne Inhalte, Standort nur durch die Person selbst. CSP in `deploy/Caddyfile` nicht lockern, ohne Security zu fragen.
- Push: nie Inhalt im Wecker (kein Titel, keine Tags); gemeldete Endpunkte nur über `push/endpoint.ts` annehmen und nie dorthin senden, sondern an `NTFY_URL`; kein eingebetteter FCM-Verteiler (Google). Teilnehmer-Filter (Chat) über `PushService.addRecipientFilter`, lokale Benachrichtigungen über `EreignisBenachrichtiger`.
- `applicationId` (`dev.lx_labs.fampad`) und Android-Signaturschlüssel nie ändern.
- Geheimnisse (`.env`, `key.properties`, Keystores, Signaturschlüssel des Update-Manifests) nie einchecken. `kUpdatePublicKey` ist bis zum ersten Release ein Platzhalter (siehe `tools/README.md`).
- Commit-Nachrichten auf Deutsch, kurz und im Imperativ-/Beschreibungsstil. Kein Push nach `main` ohne ausdrücklichen Auftrag.

## Team

Research, QM/Testing, Coding, Code-Review, Security (Subagenten in `~/.claude/agents/`). Jede Phase durchläuft: Research → Coding → QM/Testing (Sync-Randfälle, Mobilansicht ab 360 px) → Code-Review → Security (vor jedem Deploy, v. a. Auth, Uploads, OTA-Signatur).
