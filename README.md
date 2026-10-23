# lx-familyhub

Selbst gehostete Familien-Zentrale nach dem Vorbild von FamilyWall: gemeinsamer Kalender, Chat, Listen, Aufgaben und Dateien
(später Fotos, Karte, Tresor u. a.). Läuft im Browser und als Android-App, offline-fähig, mit Echtzeit-Abgleich.
Die Daten bleiben auf dem eigenen Server in Deutschland (`familie.lx-labs.dev`).

**Status: Phase 1c-1.** Server, Datenbankschema, Konten und Anmeldung (Passkey, Passwort + 2FA, Einladungen), Flutter-App mit Anmeldung, Sync-Kern
(offline-first, Konflikte pro Feld, WebSocket-Hinweis) und den **Listen** als erstem Fachbereich stehen; Kalender, Chat, Aufgaben und Dateien folgen auf demselben Kern.

| Ordner | Inhalt |
| --- | --- |
| `server/` | Node 24 + TypeScript + Fastify + Drizzle (PostgreSQL 17), REST `/api/v1`, WebSocket `/ws` |
| `app/` | Flutter 3.47.7 (Android + Web), Riverpod, drift |
| `deploy/` | Caddy, systemd, Deploy-Skripte, ntfy, Anleitung für Debian 13 |
| `docs/` | [Projektbeschreibung](docs/PROJEKTBESCHREIBUNG.md), [gepinnte Versionen](docs/VERSIONEN.md), Mockups |

## Schnellstart

```bash
# Server (Node 24, siehe server/.nvmrc)
cd server && npm ci
npm test && npm run lint
cp .env.example .env        # DATABASE_URL anpassen, dann: npm run build && npm run migrate && npm start
curl http://127.0.0.1:4400/api/v1/health

# App (Flutter 3.47.7)
cd app && flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
flutter analyze && flutter test
flutter run -d chrome
```

Ohne `DATABASE_URL` startet der Server trotzdem (Health meldet `db: skipped`); die Schema-Tests laufen gegen PGlite und brauchen keine Datenbank.

## Weiterlesen

- Stack, Befehle, Struktur, Design- und Code-Konventionen: [CLAUDE.md](CLAUDE.md)
- Einrichtung und Updates auf dem VPS: [deploy/README.md](deploy/README.md)
- Architektur, Sync, Anmeldung, Fahrplan: [docs/PROJEKTBESCHREIBUNG.md](docs/PROJEKTBESCHREIBUNG.md)
- App-Details (Builds, Web-Dateien): [app/README.md](app/README.md)
