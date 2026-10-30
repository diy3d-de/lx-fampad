# lx-familyhub

Selbst gehostete Familien-Zentrale nach dem Vorbild von FamilyWall für die eigene Familie. Läuft im Browser und als Android-App
aus einer Flutter-Codebasis, offline-fähig, mit Echtzeit-Abgleich. Die Daten bleiben auf dem eigenen Server in Deutschland
(`familyhub.lx-labs.dev`), ohne Tracker und ohne Fremddienste für Nutzerdaten.

**Stand: Version 0.27** (aktuelle Version: siehe [Releases](../../releases)). Enthalten sind:

- **Familie:** Kalender (Serien, Farben, Feiertage und Ferien, Geburtstage, ICS), Aufgaben und Fristen, Listen mit Einkaufsliste,
  Familien-Status, Standort teilen mit Karte (flüchtig, Ende-zu-Ende verschlüsselt), Suche
- **Chat:** Familienchat, Direktchats und Gruppen, Ende-zu-Ende verschlüsselt (Reaktionen, Umfragen, Pins), Push ohne Inhalt
  über eigenes ntfy
- **Zuhause:** Wetter (Netatmo-Station, DWD-Warnungen), Müll-Abfuhrtermine, Zähler mit Home-Assistant-Anbindung,
  Tagesbriefing, Wandtablet-Modus, Widget „Heute“
- **Vertraulich:** Tresor, Medikamenten-Plan, Vorsorge und Impfungen (alle Ende-zu-Ende verschlüsselt, nur für berechtigte Rollen)
- **Dateien:** Dateiablage mit Freigaben, Fassungen und Offline-Kopien
- **Betrieb:** Betreiber-Ansicht (nur lesend), verschlüsselte Backups, signierte App-Updates

Fahrplan und Ideen: [docs/PROJEKTBESCHREIBUNG.md](docs/PROJEKTBESCHREIBUNG.md), Abschnitt 12.

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
