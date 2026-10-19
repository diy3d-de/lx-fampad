# lx-familyhub – Projektbeschreibung

Stand: 19.10.2026 · Status: Konzept, umgesetzt bis Phase 1c-1 (Sync-Kern und Listen) · Mockups: [`docs/mockups/`](mockups/) und Design-Canvas (claude.ai, privat)

## 1. Ziel

Eine Familien-Zentrale nach dem Vorbild von FamilyWall: gemeinsamer Kalender, Chat, Listen, Dateien, Fotos,
Orte und mehr – aber **selbst gehostet** auf dem netcup-VPS von lx-labs.dev. Die Daten der Familie liegen auf
dem eigenen Server in Deutschland und bei keinem Dritten.

- Nutzung im **Browser** und als **Handy-App** (Flutter, zunächst nur Android; iOS ist zurückgestellt, die Flutter-Codebasis hält den Weg offen)
- **Offline-fähig**: die App funktioniert ohne Netz und gleicht sich danach automatisch ab
- **Echtzeit**: Änderungen erscheinen innerhalb von Sekunden auf allen Geräten
- **Anmeldung** mit Benutzerkonto und Passkey oder Passwort mit 2FA
- **Updates over the air** für App und Web, ohne manuelles Neuinstallieren
- Design nach den lx-labs Brand Guidelines (Dark Mode, Cyber Cyan, Inter und JetBrains Mono)

## 2. Rollen

| Rolle | Rechte |
| --- | --- |
| **Admin** (ein Elternteil) | Familie verwalten, Mitglieder einladen und entfernen, Speicher, alle Rechte der Eltern |
| **Elternteil** | Alles lesen und schreiben, Zugriff auf den Tresor, Kind-Einladungen anlegen (Zurücksetzen und Entfernen von Konten vorerst nur Admin, Entscheidung 19.10.2026) |
| **Kind** | Eigene und freigegebene Inhalte; kein Tresor; Ortsfreigabe nur mit Zustimmung der Eltern |

Der Server bedient **genau eine Familie** (die eigene). Es gibt keine Mandanten, kein Kontingent je Familie und
keine offene Registrierung; Zugriff haben ausschließlich eingeladene Familienmitglieder (Admin, Elternteil, Kind). **Gäste gibt es nicht** (Entscheidung 19.10.2026: Rolle, Gast-Einladung und Gast-Freigaben entfallen; Migration 0005 entfernt vorhandene Gast-Konten). Im Datenmodell bleibt
eine `family_id` bewusst erhalten, damit sich später mehrere Familien nachrüsten ließen.

### Design: Vorbild lx-urlaubsplanung

Die Oberfläche folgt **lx-urlaubsplanung** (Web `src/app/globals.css`, Flutter `mobile/lib/main.dart`), das wiederum die
lx-labs-Tokens nutzt. Verbindlich für Web und App:

- **Farben:** `bg #090a0f`, `bg-elevated #0e1017`, `surface #13161f`, `surface-2 #1a1e29`, `surface-hover #212634`,
  `border #242936`, `border-soft #1b1f2b`, `text #e6e8ee`, `text-muted #8b93a7`, `text-faint #5d6578`,
  Akzent `#00f0ff` (weich `rgba(0,240,255,0.12)`, stark `#5cf6ff`), `neural #7c3aed`, `danger #ff5f57`,
  Überschriften `text-strong #ffffff` (`kTextStrong`).
- **Hintergrund:** violett-cyaner Schimmer oben (zwei Radialverläufe, Violett 0.30 links, Cyan 0.09 rechts wie in lx-urlaubsplanung; `kGlowNeuralAlpha`, `kGlowAccentAlpha`) statt
  Punktraster. Dark Mode only; für Drucklisten (Einkauf, Packliste) ein heller Druckstil wie in der Urlaubsplanung.
- **Schrift:** Inter (Text, Überschriften fett mit negativem Letter-Spacing), JetBrains Mono für Kennzahlen,
  Status, Uhrzeiten, Metadaten; selbst gehostet.
- **Personenfarben:** feste Palette `#38bdf8 #34d399 #fbbf24 #fb7185 #a78bfa #f472b6 #a3e635 #fb923c #2dd4bf #818cf8`
  je Familienmitglied (in Kalender, Chat, Karte, Listen einheitlich).
- **Flutter:** Material 3 mit `ColorScheme.fromSeed(kAccent, dark)`, transparenter Scaffold über dem Verlauf,
  `NavigationBar` in `surface` mit Akzent-Indikator und Mono-Beschriftung, `FilledButton` in Cyan, Dialoge und
  Bottom-Sheets in `surface`, Sync-Anzeige und Update-Anzeige (`update_service`, `UpdateAnzeige`) wie dort.
  Konstanten in einer `constants.dart` (kAccent, kBg, kSurface, …), keine Farbwerte in Widgets.
- **Layout:** ab 360 px Breite und bei Textskalierung bis 1.5 ohne Überlauf; Touch-Ziele mindestens 44 px (Knöpfe haben 48 px
  Tipp-Fläche, Kalenderzellen 48 px hoch, Raster mit fester Höhe `mainAxisExtent` statt Seitenverhältnis); der Inhalt wird auf
  Desktop/Tablet auf 720 px Breite begrenzt und zentriert (`kMaxContentWidth`, wie die Anmeldung mit 420 px).
- Code und Muster aus lx-urlaubsplanung (Sync-Indikator, Update-Dialog, Einstellungen) werden übernommen statt neu erfunden.

Die Mockups wurden auf den Hintergrund der Urlaubsplanung umgestellt; Personenfarben und weitere Feinheiten
setzt Coding nach diesem Abschnitt um.

## 3. Funktionsumfang

Die Spalte „Phase“ legt die Reihenfolge fest (siehe Abschnitt 11).

| Bereich | Funktionen | Phase |
| --- | --- | --- |
| **Konten & Familie** | Registrierung per Einladung (Link/QR, optional mit PIN und Freigabe), Profile, Farbe je Mitglied, Rollen | 1 (Server: 1a) |
| **Kalender** | Gemeinsame und persönliche Kalender, Termine mit Teilnehmern, Wiederholungen (RRULE), Erinnerungen, Monat/Woche/Agenda, Filter je Person, Geburtstage | 1 |
| **Chat** | Familien-Chat, Gruppen, Einzelchats, Bilder/Dateien, Lesebestätigung, Reaktionen, Push | 1 |
| **Listen** | Einkaufsliste, Packlisten, beliebige Listen; Abhaken in Echtzeit, Zuständigkeit | 1 |
| **Aufgaben** | Aufgaben mit Fälligkeit, Zuweisung, Wiederholung („jeden Montag Müll“), Erinnerung | 1 |
| **Dateien** | Ordner, Hoch-/Herunterladen (fortsetzbar), Vorschau, Teilen in der Familie, offline verfügbar machen, Speicherkontingent | 1 |
| **Tresor** | Ordner für Ausweise, Verträge, Gesundheit; nur Eltern, erneute Passkey-/2FA-Bestätigung beim Öffnen | 2 |
| **Pinnwand** | Beiträge mit Text/Fotos, Kommentare, Reaktionen – die „Wall“ der Familie | 2 |
| **Fotos & Alben** | Alben, automatische Vorschaubilder, Videos, Freigabe je Album an Eltern oder Familie, GPS-Daten entfernen (optional) | 2 |
| **Essensplan & Rezepte** | Wochenplan, Rezeptsammlung, Zutaten mit einem Klick auf die Einkaufsliste | 2 |
| **Kontakte** | Gemeinsames Adressbuch (Ärzte, Schule, Notfallnummern), Export als vCard | 2 |
| **Standort & Karte** | Live-Standort teilen und Familienmitglieder auf einer Karte verfolgen; Dauer vorab wählbar (15 Min, 1 Std, 8 Std, „bis ich beende“), Teilen jederzeit beenden oder verlängern, Restzeit sichtbar (siehe Abschnitt 3a) | 2 |
| **Orte** | Orte (Zuhause, Schule) mit Ankunfts-/Abfahrts-Hinweis, nur für Mitglieder, die ihren Standort gerade teilen | 3 |
| **Budget** | Ausgaben erfassen, Kategorien, Monatsübersicht, Taschengeld | 3 |
| **Integration** | Kalender-Abo (ICS) lesend nach außen, Import aus Google/Outlook (ICS/CalDAV), Benachrichtigungen per E-Mail | 3 |
| **Startseite** | Heute, nächste Termine, offene Aufgaben, neue Nachrichten, Sync-Status | 1 |
| **Suche** | Über Termine, Nachrichten, Listen, Dateinamen | 2 |

Nicht geplant: Werbung, Tracking, KI-Auswertung der Familiendaten, öffentliche Profile.

### 3a. Standort teilen und verfolgen

Mockup: Screen „App · Standort teilen & Karte“.

- **Freigabe immer durch die Person selbst.** Niemand kann den Standort eines anderen anfordern oder
  einschalten. Eltern können Kindern nur eine Erinnerung schicken („Bitte Standort teilen“).
- **Dauer wählen vor dem Start:** 15 Minuten, 1 Stunde, 8 Stunden oder „bis ich beende“. Danach endet das Teilen
  automatisch, auch wenn die App geschlossen ist (Ablaufzeit liegt auf dem Server, nicht nur im Gerät).
- **Beenden jederzeit:** Knopf „Teilen beenden“ in der App und im Browser; ein Tipp genügt, ohne Rückfrage.
  Beim Beenden löscht der Server die gespeicherten Positionen dieser Freigabe sofort.
- **Verlängern** um jeweils 1 Stunde, solange die Freigabe läuft.
- **Dauerhinweis:** Solange geteilt wird, zeigt die App eine ständige Benachrichtigung (Android:
  Vordergrunddienst) bzw. den System-Hinweis (iOS). Auf der Karte steht bei jedem Mitglied die Restzeit.
- **Karte:** Mitglieder als Marker in ihrer Farbe, Genauigkeitskreis, optionale Bewegungsspur der letzten
  2 Stunden, „zuletzt gesehen vor …“ bei schwachem Signal, Akkustand optional. Wer nicht teilt, erscheint
  ausgegraut ohne Position.
- **Aktualisierung:** Bewegt sich das Gerät, sendet es etwa alle 10 s (Ruhe: alle 60 s) über den bestehenden
  WebSocket bzw. `POST /api/v1/location`; die anderen Geräte erhalten die Position in Echtzeit. Der
  Positionsstrom läuft getrennt vom Sync-Protokoll (kein Eintrag im dauerhaften Änderungsprotokoll).
- **Wer sieht was:** Die Freigabe geht an die ganze Familie oder an ausgewählte Mitglieder (Auswahl vor dem
  Start). Standorte sehen nur die dafür gewählten Familienmitglieder.
- **Kartenkacheln vom eigenen Server:** Karten kommen nicht von Google oder OpenStreetMap-Servern, sonst sähen
  diese, wo die Familie gerade ist. Umsetzung: Vektorkarte für Deutschland als PMTiles-Datei (Protomaps,
  Daten © OpenStreetMap-Mitwirkende, Namensnennung in der App), von Caddy ausgeliefert; Anzeige in Flutter mit
  Paket `maplibre` (0.3.6). Speicherbedarf Deutschland ca. 5 bis 10 GB, vor Start gegen den
  freien VPS-Speicher prüfen (Alternative: nur die Region der Familie als Ausschnitt).

## 4. Plattformen

**Empfehlung: eine Flutter-Codebasis für Android und Web; iOS später.**

- Ein UI-Code, eine Sync-Logik, eine Validierung auf allen Clients – die Lehre aus lx-urlaubsplanung, wo Web
  und App dieselben Regeln doppelt pflegen mussten.
- Trade-off: Flutter Web lädt beim ersten Aufruf mehr (einige MB, danach im Cache) und fühlt sich weniger
  „webbig“ an (Textauswahl, Browser-Suche). Für eine Anwendung hinter einem Login ist das vertretbar; SEO spielt
  keine Rolle.
- Alternative mit mehr Aufwand: Web-Client in SvelteKit/Astro wie bei den anderen lx-Projekten. Nur sinnvoll,
  wenn sich Flutter Web in Phase 1 als zu träge erweist.

Mindestversionen: Android 9 (API 28, nötig für Passkeys über Credential Manager), iOS 16, aktuelle Browser
(Chrome, Edge, Firefox, Safari).

## 5. Architektur

```
                 ┌──────────── netcup VPS (bestehend, auch lx-labs.dev) ─────────────┐
 Browser ──┐     │                                                                    │
           ├─TLS─┼─▶ Caddy :443 ─┬─ lx-labs.dev         ──▶ Node (lx-labs) :4321     │
 App ──────┘     │               └─ familie.lx-labs.dev ─┬─▶ statisch: Flutter-Web    │
   ▲             │                                       ├─▶ API + WebSocket :4400    │
   │             │                                       └─▶ /releases (OTA-Dateien)  │
   │             │   API ──▶ PostgreSQL 17 (nur localhost)                            │
   │             │   API ──▶ Dateiablage /srv/fampad/files (verschlüsselt)           │
   │             │   Backup: restic, verschlüsselt, auf externes Ziel                  │
   │             └────────────────────────────────────────────────────────────────────┘
   └──── Push über eigenen ntfy-Server (UnifiedPush) – nur „es gibt Neues“, kein Inhalt
```

| Schicht | Wahl | Begründung |
| --- | --- | --- |
| Backend | **Node.js 24 + TypeScript + Fastify** | gleiche Laufzeit wie lx-labs, schnell, gute WebSocket- und Schema-Unterstützung |
| Datenbank | **PostgreSQL 17** + Drizzle ORM | Transaktionen für die Sync-Revisionen, JSONB, Volltextsuche |
| Echtzeit | **WebSocket** (`@fastify/websocket`) | Server meldet neue Revision, Client holt die Änderungen |
| Dateien | Dateisystem des VPS, Upload über **tus** (fortsetzbar), AES-256-GCM pro Datei | kein S3 nötig, Abbrüche beim Hochladen am Handy sind normal |
| Vorschaubilder | `sharp` (Bilder), `ffmpeg` (Video-Standbild) | serverseitig, einmalig beim Upload |
| App | **Flutter** (stabile Version, mind. 2 Wochen alt), Riverpod, **drift** (SQLite; im Web WASM/OPFS) | offline-first, gleiche Datenbank-Schicht auf allen Plattformen |
| Sichere Ablage App | `flutter_secure_storage` (Keystore/Keychain) | Tokens nie im Klartext |
| Passkeys | Server `@simplewebauthn/server`, App über Credential Manager (Android) / AuthenticationServices (iOS), Web über WebAuthn | Standard FIDO2 |
| Push | **selbst gehostet:** ntfy auf dem VPS (`ntfy.familie…` oder Pfad hinter Caddy) + **UnifiedPush** in der Flutter-App (Paket `unifiedpush`); Browser: Web Push mit eigenen VAPID-Schlüsseln | kein Google/Apple im Weg. Auf dem Handy läuft die ntfy-App als Verteiler (ein Mal installieren). Inhalt bleibt auf dem Server, die Meldung enthält nur „es gibt Neues“. Einschränkung: Web Push läuft technisch über den Push-Dienst des Browsers (Google/Mozilla), nur verschlüsselt und ohne Inhalt |
| Webserver | **Caddy** (bestehend) | HTTPS automatisch, eine weitere Site im Caddyfile |

Paketversionen werden beim Projektstart von Research geprüft und gepinnt (nur Versionen, die mindestens zwei
Wochen alt sind).

## 6. Synchronisation

Prinzip **offline-first**: Jeder Client hat eine vollständige lokale Kopie der Familiendaten (ohne
Dateiinhalte – die werden bei Bedarf oder „offline verfügbar“ geladen).

1. **Änderungsprotokoll auf dem Server:** Jede Änderung bekommt pro Familie eine fortlaufende Revision
   (`rev`). Gelöschtes bleibt als Grabstein (Tombstone) im Protokoll, bis alle Geräte es kennen.
2. **Ausgang im Client:** Lokale Änderungen landen sofort in der lokalen DB und in einer Outbox
   (`op`, `entity`, `id`, geänderte Felder, `baseRev`). Die Oberfläche wartet nie auf den Server.
3. **Abgleich:** `POST /api/v1/sync { sinceRev, ops[] }` → Server übernimmt die Ops in einer Transaktion und
   antwortet mit Bestätigungen (`acked`: die `op_id`s), Konflikten (`conflicts`: feldweise unterlegene Werte) und allen
   Änderungen seit `sinceRev`. Jede Op trägt eine vom Client vergebene `op_id` (UUID); der Server merkt sie sich
   (`applied_ops`), ein wiederholter Upload (Abbruch nach dem Senden, Zeitüberschreitung) ändert nichts und wird
   erneut bestätigt. `sinceRev` speichert der Server je Gerät (`devices.last_rev`); Tombstones werden erst entfernt,
   wenn alle Geräte sie kennen.
4. **Echtzeit:** Über den WebSocket meldet der Server nur „neue Revision N“; der Client stößt daraufhin den
   Abgleich an. Ohne WebSocket (Hintergrund, schlechtes Netz) Abgleich beim Start, beim Zurückkehren in die
   App, nach Push und alle paar Minuten.
5. **Konflikte:**
   - Felder: „letzte Änderung gewinnt“ **pro Feld** (nicht pro Datensatz) – zwei Personen können denselben
     Termin gleichzeitig an verschiedenen Feldern bearbeiten.
   - Listen-Einträge: jeder Eintrag einzeln, Abhaken gewinnt gegen gleichzeitiges Umbenennen nicht.
   - Chat und Pinnwand: nur Anhängen, keine Konflikte. Reaktionen, Lesebestätigungen und Termin-Teilnehmer sind eigene
     Tabellen mit einer Zeile je Person (und Emoji) und eigenen Sync-Spalten, kein JSON in der Nachricht bzw. im Termin;
     gleichzeitiges Reagieren zweier Personen kollidiert so nie.
   - Ganztägige Termine sind Kalendertage (Datum ohne Uhrzeit und Zeitzone), zeitgebundene Termine Zeitpunkte (UTC).
   - Dateien: unveränderlich, jede neue Fassung ist eine neue Version.
6. **Gleiche Regeln überall:** Der Server prüft jede Op (Rechte, Pflichtfelder). Abgelehnte Ops gehen mit Grund
   an den Client zurück und werden dort sichtbar gemacht, nicht still verworfen.
7. **Protokollversion:** Der Client sendet `protocolVersion`. Ist sie zu alt, antwortet der Server mit
   „Update nötig“ und die App zeigt den Update-Dialog (Abschnitt 8).

### 6a. Umsetzung (Phase 1c-1: Sync-Kern, erster Fachbereich Listen)

Protokoll, Fehlercodes und Felder: [`API.md`](API.md), Abschnitt „Sync“. Hier das tatsächliche Verhalten und die Entscheidungen.

**Server** (`server/src/sync/`, Route `server/src/routes/sync.ts`)

- **Entitäten-Register** (`registry.ts`): Jede synchronisierte Tabelle meldet sich mit Feldern (Prüfung je Feld mit Zod, Zugriff `rw`/`create`/`server`, Pflicht, Standard, Wert im Tombstone), Rechte-Regeln, Elternbeziehung, Verweisen auf Mitglieder und Obergrenzen an. Engine, Änderungsstrom, Löschen mit Kaskade, Aufräumen und das Bereinigen von Mitglieds-Verweisen arbeiten nur über diese Beschreibung. Kalender, Chat, Aufgaben und Dateien tragen sich ohne Umbau am Kern ein (Tabelle mit Sync-Spalten, Eintrag im Register, Rechte-Regel).
- **Rechte-Modell** (`permissions.ts`, für alle Entitäten): Jeder Datensatz liefert Fakten (Freigabe-Stufe `parents`/`family`, Besitzer; die frühere Stufe `all` = auch Gäste entfällt, Eingaben alter Apps mit `all` werden als `family` gespeichert; untergeordnete Datensätze erben sie von der Liste), jede Entität eine Regeltabelle je Rolle (Lesen, Anlegen, Ändern, Löschen mit Geltungsbereich `all`/`shared`/`own`/`none`, erlaubte Felder, erlaubte Werte). Ändern und Löschen setzen Lesen voraus: Was eine Rolle nicht sehen darf, ergibt `not_found` (nie `forbidden`), auch bei IDs einer fremden Familie (alle Abfragen sind an die Familie der Sitzung gebunden). Listen: Admin/Eltern alles; Kind sieht `family`, legt nur Familienlisten an, ändert und löscht nur **eigene** Listen und darf Einträge sichtbarer Listen anlegen, ändern, zuweisen, abhaken, löschen. Tests: `test/sync-rights.test.ts` (Regeltabelle rein und über HTTP).
- **Ops:** `upsert` (nur geänderte Felder, `baseRev`) und `delete` (Tombstone). Höchstens **50** je Anfrage. Idempotenz über `op_id` (`applied_ops`, mit Ergebnis, Ziel und den **Namen** der Konfliktfelder; Werte werden nie gespeichert, eine Wiederholung liest den aktuellen Stand und prüft die Rechte neu); je Op eine Transaktion mit gesperrter Familienzeile (lückenlose Revisionen, Commit-Reihenfolge = Revisionsreihenfolge, auch bei gleichzeitigen Syncs) und Zeitlimits (`lock_timeout` 5 s, `statement_timeout` 10 s; Überschreitung ergibt `503 server_busy` mit `Retry-After`, nichts ist angewendet). `id_taken` gibt es nicht mehr: eine fremde ID ergibt `not_found`.
- **Konflikte (Entscheidung):** Last-write-wins **pro Feld** nach der Reihenfolge des Servers (nie nach der Uhr des Clients). Ein Feld verliert, wenn seine `field_rev` größer als das `baseRev` der Op ist und die Änderung nicht vom selben Gerät stammt; die Antwort nennt den Serverwert. Verschiedene Felder werden zusammengeführt, Listeneinträge sind einzelne Datensätze. **Löschen gewinnt:** ein Update auf einen gelöschten Datensatz wird mit `deleted` abgelehnt (nicht still verworfen: die App zeigt „Eintrag … wurde auf einem anderen Gerät gelöscht“), ein `delete` wirkt immer. Abgelehnte Ops gehen mit Grund an den Client zurück (`rejected[].code`).
- **Sortierung (Entscheidung):** `position` als **Kommazahl** (Mittelwert der Nachbarn) statt Ganzzahl oder Fractional-Index-Text: Verschieben ändert nur ein Feld eines Eintrags, zwei Geräte kollidieren nur, wenn sie genau denselben Eintrag verschieben; kein zusätzliches Paket, einfache Spalte. Gleichstand (gleichzeitiges Einfügen an derselben Stelle) entscheidet die Anlegezeit, dann die ID auf allen Geräten gleich; nach sehr vielen Halbierungen müssten die Positionen einer Liste neu vergeben werden (noch nicht gebaut, Verschieben per Hand kommt später). Neue Einträge stehen oben (kleiner als alle offenen).
- **Änderungsstrom:** zustandsbasiert, stabil nach `rev`, seitenweise (Standard 500). Aus dem `change_log` wird je Datensatz der **aktuelle Stand** geliefert; bei `sinceRev: 0` entsteht so der Snapshot. Rollenabhängig gefiltert; wer die Sicht auf einen Datensatz verliert (Freigabe zurückgenommen), bekommt einen Tombstone mit `hidden` ohne Inhalt, und die Einträge einer Liste werden bei Freigabeänderung neu angestoßen. Ein **gelöschter**, für die Person unsichtbarer Datensatz kommt im Delta ebenfalls als `hidden`-Tombstone (sonst bliebe eine erst entzogene, dann gelöschte Liste als Geist in der App; Preis: die ID eines nie sichtbaren gelöschten Datensatzes wird sichtbar, nie sein Inhalt; **[Prüfen]** später ggf. durch ein „Gelöscht an alle Rollen“-Schema ersetzen). **Mehrseitiger Snapshot:** die erste Seite nennt die Ziel-Revision als `snapshotRev`, die Folgeseiten senden sie mit `sinceRev` als Cursor zurück; sie prüfen nie gegen `purged_rev`, liefern keine Tombstones und schreiben `last_rev` nicht fort; danach folgt ein normaler Lauf ab der Ziel-Revision. `resync_required`, wenn `sinceRev` (ohne Snapshot-Folgeseite) vor `families.purged_rev` liegt, in der Zukunft liegt oder `devices.resync_required` gesetzt ist (Rollenwechsel der Person; Migration 0003).
- **Geräte und Wartung:** `devices.last_rev` ist der zuletzt gesendete `sinceRev` (nicht bei Folgeseiten eines Snapshots). Der stündliche Job löscht Tombstones, die alle aktiven Geräte der Familie kennen oder die älter als 90 Tage sind (mit ihren Protokolleinträgen), entfernt ersetzte Protokolleinträge und verarbeitete Ops nach 90 Tagen (abgelehnte nach 7) und hebt `purged_rev` an. Beim Löschen eines Datensatzes werden seine Inhalte überschrieben und alle Inhalte seiner `change_log`-Einträge geleert (Löschkonzept, `DATENSCHUTZ-ENTWURF.md`, Abschnitt 10).
- **Mitglied entfernen:** Verweise (`assigneeId`, `ownerId`) werden mit Änderungseintrag auf `null` gesetzt (sie prüft der Sync auch beim Setzen: nur aktive Mitglieder der Familie), der Hub meldet die neue Revision. Mitglieder sind keine Sync-Entität.
- **WebSocket:** Nach dem Commit meldet der Hub `{type:"rev", rev}` an die Sockets der Familie, deren Rolle die Änderung (vorher oder nachher) sehen darf (ohne Inhalt; wer einen Datensatz nicht sehen darf, erfährt nicht, dass er sich änderte). Ticket-Anmeldung, Schließen bei Abmelden/Rollenwechsel/Entfernen wie in Abschnitt 7. **Limits:** 50 Ops, 1 MB, 120 Aufrufe/min je IP, zusätzlich Token-Bucket je Gerät und je Person (Anfragen und Ops, 429 mit `Retry-After`, die ganze Anfrage wird abgewiesen) und eine Tagesobergrenze je Gerät (5000 Ops, über `applied_ops`); Einstellungen `SYNC_*` in `server/.env.example`. Inhalte nie im Log.

**App** (`app/lib/data/`, `app/lib/features/lists/`)

- **Lokale Datenbank** (drift, Version 2; Migration von Version 1 behält den Besitzer): Tabellen `lists`, `list_items`, `outbox` (`op_id` UUID, `op`, `entity`, `entity_id`, `fields_json`, `base_rev`, `created_at`, `sent_at`) und `sync_meta` (`sinceRev`, `deviceId`, `ownerUserId`, zwischengespeicherte Mitgliederliste ohne E-Mail). Die Oberfläche liest nur hier und schreibt nur hier; **sie wartet nie auf den Server**.
- **SyncStore:** Eine lokale Änderung landet sofort in der Tabelle und im Ausgang; mehrere Änderungen derselben Zeile vor dem Senden werden zu einer Op verschmolzen (nie mit einer schon gesendeten Op und nur bei gleicher `baseRev`: ist die Zeile inzwischen weitergekommen, wird die neue Änderung eine eigene Op, sonst täuschte sie mit der alten Basis einen Konflikt vor). Löschen entfernt die Zeile samt Einträgen sofort; eine Zeile, deren Anlage **nie gesendet** wurde (Revision 0, keine gesendete Op), verschwindet ohne Op; schon bestätigte Anlagen tragen mindestens Revision 1. Die Antwort wird in **einer Transaktion** übernommen: Bestätigte Ops verlassen den Ausgang, Ablehnungen werden sichtbar (Hinweis; eine abgelehnte neue Zeile verschwindet, bei einer bestehenden wird der Stand neu geladen), Konflikte übernehmen den Serverwert (außer eine spätere lokale Änderung desselben Felds wartet), der Änderungsstrom überschreibt die Zeilen, **darüber liegen die noch offenen lokalen Änderungen**. Wechselt die Geräte-ID (neue Anmeldung), werden die Fachtabellen neu geladen (der Ausgang bleibt; lokal neu angelegte, noch unbestätigte Zeilen werden wiederhergestellt). Der **Snapshot-Cursor** (`snapshotRev` neben `sinceRev` in `sync_meta`) lässt einen unterbrochenen mehrseitigen Snapshot fortsetzen; `resync_required` und Gerätewechsel verwerfen ihn.
- **SyncService** (`sync_state.dart`, `data/sync/`): Auslöser sind Start, Rückkehr in die App, 2 s nach der letzten lokalen Änderung (entprellt), der Hinweis „rev N“ über den WebSocket (nur wenn neuer als bekannt), alle 3 Minuten, Antippen des Indikators und Herunterziehen. Es läuft höchstens ein Abgleich; ein Auslöser währenddessen ergibt genau einen weiteren Lauf (der Hinweis auf die **eigene** Änderung während eines Laufs löst keinen aus; ein Hinweis auf eine Revision, die der Lauf nicht erreicht hat, schon). Beim Wechsel in den Hintergrund wird vorher einmal abgeglichen, wenn Änderungen im Ausgang warten. Fehler (offline, 5xx, 429/503 mit `Retry-After`) lösen einen Backoff mit Zufallsanteil aus (2 s, 4 s ... höchstens 5 min; Auslöser während des Backoffs laufen ins Leere, Antippen geht sofort). **401** stoppt den Dienst ganz (Zeitgeber, Socket, Zustand; der Auth-Zustand führt zur Anmeldung; der Ausgang bleibt, nach erneuter Anmeldung derselben Person startet der Dienst neu und er geht raus). `stoppen()` setzt Zustand und bekannte Revision zurück, **426** zeigt die Pflicht-Update-Seite, `409 device_mismatch` lädt `/me` neu. Abmelden hält den Sync an, bevor die Datenbank geleert wird (eine späte Antwort wird verworfen).
- **WebSocket-Client** (`web_socket_channel` 3.0.3, `sync_socket.dart`): Ticket, Anmeldung als erste Nachricht, Ping/Pong alle 25 s, Neuaufbau mit Backoff und Jitter (1 s bis 60 s), bei Schließcode `4401` sofort ein neues Ticket (ein 401 dort beendet die Sitzung, dann gibt der Socket auf). Nur im Vordergrund, im Web nutzbar (Cookie und Ticket).
- **Oberfläche:** Listen-Tab (Listen anlegen/umbenennen/freigeben/löschen, Einträge anlegen/abhaken/bearbeiten/zuweisen mit Mitgliederfarbe/löschen, Fortschritt, erledigte unten, Pull-to-refresh, Leerzustand, Offline-/Fehlerleiste, Hinweise bei abgelehnten oder überschriebenen Änderungen), Startseite mit der Karte „Einkaufsliste“, Sync-Indikator (synchron, N offen, offline, Fehler, Update nötig). Die Rollen-Rechte der Oberfläche spiegeln den Server (`list_rights.dart`); maßgeblich bleibt der Server.
- **Prüfung im Browser** (headless Chrome, Release-Build hinter Caddy mit COOP/COEP): Die Datenbank wird real geöffnet (OPFS `drift_db/lx_fampad/database`), Listen und Einträge überstehen den Reload (auch bei blockiertem Sync) und werden von zwei Tabs geteilt; offline angelegte Einträge gehen nach dem Wiederherstellen der Verbindung raus. Korrekturrunde: Ein Snapshot über mehrere Seiten (520 Einträge, `purged_rev` über allen Cursorn) lädt vollständig (2 Aufrufe, kein `resync_required`); eine für die Familie freigegebene, dann auf „nur Eltern“ gestellte und gelöschte Liste verschwindet nach dem nächsten Abgleich (`hidden`-Tombstone), obwohl der zweite Browser die Zwischenstände nie sah; im Dialog „Neue Liste“ läuft Tab über Name, Art, Freigabe, Abbrechen, Anlegen und der Fokus steht im Semantikbaum (zuvor übersprang er die Auswahl-Knöpfe für Bedienhilfen).
- **Migration der lokalen Datenbank (Regel):** Jede drift-Migration, die Tabellen für neue Sync-Entitäten anlegt, MUSS `sync_meta.sinceRev` und `snapshotRev` löschen (deviceId, ownerUserId, members und Ausgang bleiben). Eine ältere App überspringt Entitäten ohne Definition, rückt aber ihren Cursor weiter; ohne Reset kämen deren Datensätze nach dem Update nie an. Mit sinceRev 0 holt der nächste Abgleich einen vollständigen (ggf. mehrseitigen) Snapshot und aktualisiert vorhandene Zeilen per Upsert, offene lokale Änderungen und gesendete Ops bleiben erhalten. Der Snapshot enthält keine Tombstones: lokale Zeilen, die der Server schon nicht mehr kennt, blieben sonst stehen (für Listen unkritisch, da die alte App deren Löschungen empfangen hat). Umgesetzt für Schema 1 und 2 -> 3 in `app_database.dart`; Notlösung für bereits aktualisierte Geräte serverseitig: `devices.resync_required = true`.

### 6b. Umsetzung (Phase 1c-2a: Kalender-Kern)

Technische Beschreibung der Felder, Prüfungen und Rechte: `docs/API.md`, Abschnitt „Termine“.

- **Zeitmodell (Entscheidung):** Familienzeitzone fest **Europe/Berlin** für Anzeige und Tagesgrenzen. Zeittermine: Zeitpunkte in UTC (`start_utc`, `end_utc`) plus IANA-Zeitzone (`tzid`), Wiederholungen in der Wanduhrzeit der `tzid` (Sommerzeit-fest); ganztägige Termine: Kalendertage `start_date`/`end_date` (Text `YYYY-MM-DD`, Ende exklusiv wie ICS, keine Zeitzone). `rrule` als Text (UNTIL bei Zeitterminen UTC). Migration 0004 ersetzt die unbenutzten Phase-0-Tabellen `events`/`event_attendees` durch `termine`, `termin_teilnehmer`, `termin_ausnahmen` (je mit `family_id`, Sync-Spalten, zusammengesetzten Fremdschlüsseln).
- **Sync-Entitäten:** `termin` (Titel, Ort, Beschreibung, Zeiten, `rrule`, `erinnerungMin`, `icalUid`, Freigabe, Ersteller), `termin_teilnehmer` (eine Zeile je Person) und `termin_ausnahmen` (eine Zeile je Termin und ursprünglichem Beginn; abgesagt oder mit Überschreibungen). Rechte wie bei Listen über die Regeltabelle (`permissions.ts`): Admin/Eltern alles, Kind sieht `family`, legt Familientermine an und ändert/löscht nur **eigene** (Teilnehmer und Ausnahmen erben Stufe und Besitzer). Der Server prüft die Stimmigkeit der Zeiten (neuer optionaler Schritt `check` im Register, auch nach dem Zusammenführen) und die Wiederholungsregel (Hand-Tokenizer, keine Sekunden-/Minuten-/Stundenserien, `COUNT` höchstens 1000).
- **Wiederholung im Client:** Das Paket `rrule` 0.2.18 kennt keine Zeitzonen: der Beginn wird als Wanduhrzeit der `tzid`, als UTC getarnt, expandiert und danach mit `timezone` 0.11.1 in echte Zeitpunkte umgerechnet (Test über die Zeitumstellung). Deckel: höchstens 1000 Vorkommen je Termin und Abfrage, Horizont 5 Jahre. Die Zeitzonen-Daten (`latest.tzf`, alle Zonen bis 2037) liegen als Asset in der App und kommen von der eigenen Domain (kein CDN); abweichend von der Vorrecherche (Variante „10y“) wird die vollständige Variante gebündelt, weil der Horizont von 5 Jahren über die Spanne der 10y-Daten hinausreicht (+ 188 KB).
- **Korrekturrunde (Review, QM, Security):** Serien teilen, kürzen und vergleichen rechnen mit dem **ursprünglichen** Beginn des Vorkommens (aus dem Schlüssel), nie mit einer verschobenen Anzeige; Ausnahmen werden nie gelöscht, nur zurückgesetzt (feste ID, siehe API.md); ändern sich bei „alle“ Beginn, Art oder Regel, ziehen die Ausnahmen bei reiner Uhrzeitänderung mit, sonst werden sie zurückgesetzt und die Oberfläche weist darauf hin; eine unveränderte Regel wird als gespeicherter Text übernommen (nur eine im Blatt geänderte Wiederholung schreibt sie neu); verschiebt sich der Beginn auf einen anderen Wochentag, wandert der Wochentag der Auswahl mit; fehlen die Zeitzonen-Daten, sind Anlegen und Ändern gesperrt (mit Hinweis und neuem Versuch), Lesen fällt auf UTC zurück. Der Client rechnet Serien mit Zeitbudget (150 ms je Regel und Abfrage), nahe am Fenster (tägliche/wöchentliche Regeln ohne COUNT) und mit Zwischenspeicher. Der neue Teil einer geteilten Serie gehört der Person, die teilt.
- **Serien ändern:** „nur dieses Vorkommen“ = Ausnahme (feste ID aus Termin und Beginn, zwei Geräte schreiben dieselbe Zeile), „alle“ = der Termin selbst, „dieses und alle folgenden“ = die alte Serie endet per `UNTIL` vor dem Vorkommen, ab dort beginnt ein neuer Termin (Teilnehmer und, bei gleicher Regel und Uhrzeit, die Ausnahmen ziehen um; `COUNT` wird anteilig übertragen). Absagen ist eine Ausnahme mit `abgesagt`.
- **Oberfläche** (Eigenbau, keine UI-Pakete): Agenda (Standard, 60 Tage, mehr laden), Monat (48-px-Zellen mit Personenpunkten, Tagesliste), Woche (sieben Tage als Liste, keine Stundenansicht), Filter je Person (Ersteller oder Teilnehmer), Termin-Detail, Editor (ganztägig, Wiederholung, Erinnerung, Teilnehmer, Freigabe), Karte „Als Nächstes“ der Startseite aus echten Terminen. Farbe eines Termins = Personenfarbe des Erstellers. Alles offline-first über `SyncStore.aendern/loeschen`; drift-Schema 3.
- **Kopfzeile:** Alle Tabs teilen eine Kopfzeile (`widgets/kopfzeile.dart`): Datum als Mono-Label, Titel des Tabs, Sync-Indikator und Profil-Knopf (Benutzerbild der Person: Platzhalter-Zeichnung oder Foto, sonst Initialen in der Personenfarbe); nur der Titel ist je Tab verschieden. Im Desktop-Layout (ab 900 px) bleiben Datum und Titel, Sync-Zustand (Fußzeile) und Profil (Seitenleiste) stehen dort schon. Die Desktop-Startkarte „Heute & morgen“ zeigt echte Termine; „Als Nächstes“ (mobil) und diese Karte aktualisieren sich im Minutentakt.
- **Erinnerungen (nur Android, lokal):** Die Benachrichtigung an `erinnerungMin` wird **auf dem Gerät** berechnet und geplant, ohne Server und ohne Push (nichts verlässt das Gerät; Titel, Zeit und Ort stehen nur in der lokalen Benachrichtigung). Pro Gerät, ein Web-Browser zeigt keine Erinnerungen (Hinweis in Profil, Erinnerungen). Technik: `flutter_local_notifications` (`zonedSchedule`) hinter der Schnittstelle `ErinnerungPort` (`app/lib/data/erinnerungen/`), reine Planungslogik in `erinnerung_planung.dart`. **Rollierendes Fenster:** bei App-Start, Rückkehr in die App und jeder Änderung der lokalen Termine (auch durch den Sync) werden die nächsten 300 Erinnerungen berechnet (Horizont 366 Tage) und das Gerät daran angeglichen (nicht mehr gültige Planungen gelöscht, der Rest neu gesetzt; Samsung begrenzt auf rund 500 Alarme, daher Reserve). Gibt es mehr, steht als letzter Platz der Hinweis "Erinnerungen laufen aus – öffne lx-fampad". Der Abgleich ist entprellt (500 ms), ein Fehler des Plugins führt zu einem einmaligen Wiederholversuch, und alles hängt am Wurzel-Widget (nie pausiert), nicht an einer Seite. Nach Neustart und App-Update setzt das Plugin seine Alarme selbst neu (Boot-Receiver); das Fenster wird beim nächsten Start aufgefrischt. **Regeln:** Zeittermine: Beginn minus Vorlaufzeit, ganze Tage in der Wanduhr ("1 Tag vorher" = Vortag zur selben Uhrzeit, auch über die Zeitumstellung), der Rest als absolute Dauer; Serien an jedem Vorkommen, abgesagte nicht, verschobene zur neuen Zeit; **ganztägige Termine: Bezugspunkt 09:00 Uhr Familienzeit am ersten Tag, davon die Vorlaufzeit** ("1 Tag vorher" = 09:00 am Vortag); Vergangenes wird übersprungen; nur Termine, bei denen die Person Ersteller oder Teilnehmer ist (ohne Ersteller nur Teilnehmer). **Sperrbildschirm:** Benachrichtigungen sind standardmäßig privat (nur neutraler Hinweis), Titel/Ort dort nur auf Wunsch. **Konto:** beim Abmelden, Kontowechsel und Leeren der lokalen Daten werden alle Erinnerungen entfernt, bei Sitzungsverlust bleiben sie. Alle Auswahlwerte des Editors (0, 5, 15, 30 Minuten, 1 Stunde, 1 Tag, 1 Woche) werden geplant. Kanal "Terminerinnerungen" (hohe Wichtigkeit); Tippen öffnet den Kalender (Monatsansicht, Tag des Termins). Genaue Alarme über `USE_EXACT_ALARM`, ohne Erlaubnis Rückfall auf ungenaue. `POST_NOTIFICATIONS` wird erst in Profil, Erinnerungen angefragt (nicht beim ersten Start). Einstellungen (nur lokal, im Keystore-gestützten Speicher): an/aus, Titel auf dem Sperrbildschirm, Standard-Vorlaufzeit für neue Termine (Keine, 15 Minuten, 1 Stunde, 1 Tag), Hinweis zum Akkuschutz (Samsung), Testbenachrichtigung in 10 Sekunden.
- **ICS-Import** (Kalender, Knopf „Importieren“): selbstgebauter Parser (`app/lib/data/calendar/ics_parser.dart`, `ics_zonen.dart`), Plan und Schreiben (`ics_import.dart`), Oberfläche `features/calendar/ics_import_screen.dart`. Gelesen werden nur VEVENT (mit relativem VALARM-TRIGGER als Erinnerung) und die Namen aus VTIMEZONE; Teilnehmer, Organisator, Anhänge, URLs und Farben werden ignoriert, nichts wird aus dem Netz geladen. Zeitzonen: IANA, Windows-Namen (eingebettete CLDR-Tabelle), unbekannte und schwebende Zeiten als Europe/Berlin (Hinweis im Bericht); die `tzid` des Termins bleibt erhalten. Wiederholungen nur in der vom Server erlaubten Form (COUNT auf 1000 gekürzt, UNTIL umgerechnet); Stunden-/Minutentakt wird übersprungen, nicht abbildbare Regeln (z. B. BYWEEKNO) werden Einzeltermine; EXDATE und RECURRENCE-ID werden Ausnahmen. Jährliche Serien mit Beginn vor 2000 beginnen im Jahr 2000. Duplikate über `icalUid` (= UID der Datei, bei fehlender oder zu langer UID ein stabiler Hash): erneuter Import legt nichts doppelt an, geänderte Termine werden auf Wunsch aktualisiert. Grenzen: 5 MB, 5000 Termine, Familie 5000 / Kind 500; ein fehlerhafter Termin bricht den Import nicht ab. Lasttest (`app/tool/ics_last_test.dart`, echter Server mit Standard-Limits): 700 Termine (50 Serien, 25 Ausnahmen) stehen nach rund 5 Minuten vollständig auf dem Server, weil der Sync bei 429 genau die Retry-After-Zeit wartet (Limit: 120 Ops je Minute, Burst 100, 5000 je Tag). Offen: Zuordnung der Teilnehmernamen (CN) zu Familienmitgliedern (es gibt nur eine gemeinsame Zuordnung für alle importierten Termine).

### 6c. Umsetzung (Phase 1c-3a: Chat-Kern, E2EE-vorbereitet)

Technische Beschreibung der Felder, Prüfungen und Rechte: `docs/API.md`, Abschnitt „Chat“. Push-Benachrichtigungen (ntfy, ohne Inhalt) folgen als **1c-3b**, Anhänge und Bilder mit den Dateien (**1c-4**); diese Phase kennt nur Text.

- **Arten und Datenmodell (Migration 0007):** `konversationen` (`art`: `family` | `direct` | `group`, `titel`, `teilnehmer`, Ersteller), `nachrichten` (Konversation, Autor, `text`, `antwortAuf`, `bearbeitetAt`, Zeit = `createdAt` vom Server) und `lesestand` (je Person und Konversation `gelesenBis`). Alle mit `family_id`, Sync-Spalten und zusammengesetzten Fremdschlüsseln. **Familienchat:** pro Familie genau einer (eindeutiger Index), ohne Teilnehmerliste, für **alle aktiven Mitglieder** einschließlich später hinzugekommener. Ihn legt die erste App an, in der jemand den Chat-Bereich öffnet und die nach einem Abgleich keinen findet (feste ID aus der Familie, ein zweiter wird vom Server abgelehnt); die anderen Bereiche lösen nichts aus. **Direktchat:** zwei Personen, je Paar genau einer (eindeutiger Index über die sortierte Teilnehmerliste; die App vergibt eine feste ID aus dem Paar, damit zwei Geräte offline denselben Chat anlegen, ohne Nachrichten zu verlieren); unveränderlich, wird nicht gelöscht. **Gruppe:** 2 bis 20 Personen (die UI verlangt beim Anlegen mindestens zwei weitere), Name optional. Die Teilnehmerliste ist eine Spalte (`uuid[]`, sortiert, eindeutig) der Konversation statt einer eigenen Entität: Sichtbarkeit, Rechte und Benachrichtigung ergeben sich damit aus **einer** Zeile, ohne dass Eltern- und Kind-Datensätze gegeneinander konsistent gehalten werden müssen. Der Lesestand hat eine feste ID je Person und Konversation.
- **Sichtbarkeit (Entscheidung, Datenschutz):** Direkt- und Gruppenchats sehen **nur ihre Teilnehmer, auch Admins und Eltern nicht**. Das Rechte-Modell (`sync/permissions.ts`) kennt dafür **Teilnehmer-Fakten** (`Facts.participants`): sie sind eine **harte Grenze vor jeder Rollenregel** (auch vor `all`), es gibt keinen Rollen-Durchgriff. Nachrichten und Lesestände erben die Teilnehmer ihrer Konversation. Nicht sichtbare Datensätze ergeben bei Ändern, Löschen und Anlegen `not_found` (fremde IDs verraten nichts, auch nicht die einer anderen Familie). Der Änderungsstrom liefert Unbeteiligten nie etwas, auch keine `hidden`-Tombstones gelöschter oder umgebauter Privatchats; nur wer durch eine Änderung die Sicht **verliert** (aus der Gruppe entfernt), bekommt den `hidden`-Tombstone (das Protokoll vermerkt im Eintrag, wer die Sicht verlor: `lostSight` im Register). Wird jemand aufgenommen, bekommt er Konversation und Verlauf (die Nachrichten werden neu angestoßen).
- **Rechte:** anlegen darf jede Person (Kinder auch Gruppen; die Teilnehmer müssen aktive Familienmitglieder sein, die anlegende Person muss dabei sein). Nachrichten schreibt jede Person mit Sicht; **bearbeiten und löschen nur der Autor**. **Entscheidung:** Admins dürfen im **Familienchat** fremde Nachrichten löschen (Moderation), **nie in privaten Chats** (die sie nicht sehen); Eltern und Kinder nicht. Gruppen: jeder Teilnehmer darf Namen und Teilnehmer ändern (auch sich selbst entfernen), löschen nur, wer sie angelegt hat. Der Familienchat ist für Clients unveränderlich und nicht löschbar. Lesestand: nur die **eigene** Zeile ist les- und schreibbar (auch Admins sehen die anderer nicht).
- **Obergrenzen:** 500 Konversationen je Familie, 100 je anlegender Person, 20 Teilnehmer je Gruppe, **60 neue Nachrichten je Person und Minute** (`limit_reached`), Text höchstens 16 384 Zeichen auf dem Server (die App begrenzt auf 4000), Gruppenname 512 Zeichen (App: 60).
- **Mitglied entfernen:** die Person wird aus allen Teilnehmerlisten genommen; bleiben weniger als zwei übrig (Direktchat immer), wird die Konversation mit Tombstone gelöscht (die anderen Teilnehmer erfahren es). Nachrichten im Familienchat bleiben, der Autor wird leer („Ehemaliges Mitglied“); ihr Lesestand verschwindet.
- **Echtzeit:** der WebSocket-Hinweis `rev N` geht bei Privatchats **nur an die Teilnehmer** (nach Person, nicht nach Rolle), im Familienchat an alle Rollen mit Sicht: Unbeteiligte erfahren nicht, dass es eine neue Nachricht gibt. Dass die Revision der Familie weiterzählt, ist für sie dennoch sichtbar (Revisionszähler der Antwort); mehr nicht.
- **Inhalt ist für den Server undurchsichtig (E2EE-vorbereitet):** `text` und `titel` sind Zeichenketten, deren Inhalt der Server weder prüft noch auswertet (nur Länge und Zeichensatz; kein Volltext, kein Index, keine Vorschau, kein Suchendpunkt, nie im Log). Die App kapselt sie über die Schnittstelle `NachrichtenInhalt` (kodieren/dekodieren) mit Versionspräfix: heute `p1:` + Klartext, später `e1:` + Base64-Chiffre. Zustände der Anzeige: bereit, „wird entschlüsselt“, „nicht lesbar – warte auf Schlüssel“ (daneben „wird gesendet“ bis der Server bestätigt). Sichtbar für den Server bleiben bewusst nur: Konversation, **Teilnehmerliste** (nötig für Rechte und Push), Autor, Zeit, Größe, Antwort-auf-ID.
- **Datenschutz-Aussage:** Private Chats sind für Admins und Eltern in der App und über die Schnittstelle **nicht lesbar**. Sie sind aber **nicht Ende-zu-Ende-verschlüsselt**: bis zur Einführung der Verschlüsselung ist der Inhalt für den Server-Betreiber (Zugriff auf Server und Datenbank, Sicherungen) lesbar.
- **Oberfläche:** Chat-Tab mit Konversationsliste (Familienchat oben, dann Direktchats, dann Gruppen; letzte Nachricht mit Absender, Zeit in Mono, Ungelesen-Zähler, Personenfarbe/Avatar), „Neuer Chat“ (eine Person = Direktchat, mehrere = Gruppe mit optionalem Namen), Verlauf (Blasen, eigene rechts, Datumstrenner, Antworten, eigene Nachrichten bearbeiten und löschen, Text kopieren; Links werden nicht angeklickt oder vorgeladen, keine Vorschauen), Eingabe mit Senden offline-first (`SyncStore.aendern`), Lesestand beim Öffnen und wenn der Verlauf am Ende steht, Zeichen mit Anzahl am Chat-Tab (Navigationsleiste und Seitenleiste). Ab 900 px (Desktop-Layout) zwei Spalten, Enter sendet. Die Karte „Chat · Familie“ der Desktop-Startseite zeigt die letzten Nachrichten der sichtbaren Chats. drift-Schema 4.
- **Korrekturrunde (Security, Review):**
  - **Feste IDs erzwingt der Server:** Familienchat, Direktchat und Lesestand lassen nur die aus Familie, Paar bzw. Person und Konversation abgeleitete ID zu (SHA-256 mit Präfix `lx-fampad:`, Muster einer UUID Version 5; Known-Answer-Tests auf beiden Seiten), Gruppen eine Zufalls-UUID Version 4. Jede andere ID ist `invalid` (nie ein Hinweis, ob es den Chat schon gibt); niemand kann die ID eines fremden Paares vorab belegen. Wird so ein Datensatz gelöscht (z. B. Direktchat nach Entfernen der Person), belebt ein erneutes Anlegen mit derselben ID ihn wieder (Nachrichten bleiben gelöscht); Gruppen nicht.
  - **Zeit in Millisekunden:** die Chat-Tabellen der App speichern Zeiten als Millisekunden (drift-Schema 5; Listen und Kalender unverändert), sonst würden Reihenfolge und „ungelesen“ innerhalb einer Sekunde falsch. Gleiche Zeit: Zustellreihenfolge des Servers (Revision), eigene noch nicht bestätigte Nachrichten zuletzt. Eine eigene Nachricht trägt bis zur Bestätigung die Uhrzeit dieses Geräts und springt dann an die Serverzeit (bei falsch gehender Uhr ändert sich ihre Stelle im Verlauf einmal).
  - **Verlauf für neu Aufgenommene:** Das Aufnehmen in eine Gruppe schreibt keine Nachricht neu (kein Protokollaufwand); die neue Person bekommt mit ihrem nächsten Abgleich die jüngsten 500 Nachrichten, ein Snapshot (Neuinstallation) später den ganzen Verlauf. Die App warnt vor dem Hinzufügen: „Neue Mitglieder sehen den bisherigen Verlauf der Gruppe.“
  - **Grenzen:** höchstens 20 000 Nachrichten je Konversation, 10 Teilnehmerwechsel und 60 Text-Änderungen je Person und Minute, Text-Kontingent je Person 1 MiB je Stunde und 4 MiB je Tag. Nachrichten, die der Server wegen der Mengenbegrenzung ablehnt, bleiben auf dem Gerät und werden später erneut gesendet. Der Lesestand geht serverseitig nie zurück.
  - **Protokoll:** Beim Bearbeiten werden ältere Fassungen des Textes aus den Protokolleinträgen der Nachricht entfernt; beim Löschen werden die Inhalte geleert, nur der Vermerk, wer die Sicht verloren hat, bleibt (damit auch ein offline gewesenes Gerät die entfernte Gruppe verliert). Nachrichten müssen die Hülle ihrer Konversation tragen (`enc_version` `p1`, unveränderlich; `e1:` ist erst mit der Verschlüsselung gültig), eine Antwort verweist nur auf eine Nachricht derselben Konversation.
  - **Metadaten:** der WebSocket-Hinweis zum Lesestand geht nur an die Person selbst. Die Revisionszahl im Hinweis und in der Antwort zählt für die ganze Familie weiter: Unbeteiligte können daran erkennen, dass es Änderungen gab (nicht wo oder was). Ein späteres Hinweis-Signal ohne Zahl würde das verkleinern.
  - **Bildschirmschutz:** Direkt- und Gruppenchats sind in der Android-App durch `FLAG_SECURE` gegen Bildschirmfotos geschützt (Web und Desktop: ohne Wirkung); der Familienchat nicht.
- **Offen:** Push (1c-3b), Anhänge und Bilder (1c-4), Reaktionen (die Platzhaltertabellen `messages`, `message_reactions`, `message_reads` aus Phase 0 bleiben ungenutzt bis dahin), Ende-zu-Ende-Verschlüsselung (Verfahren in Recherche), Lesebestätigung je Nachricht (jetzt nur Lesestand je Chat), Suche. Bekannte Grenzen: Der Familienchat entsteht erst, wenn jemand den Chat-Bereich öffnet. Zwei Geräte derselben Person, die denselben Lesestand zugleich weiterschreiben, können sich einmal überschreiben (der Server-Stand gewinnt, das nächste Öffnen korrigiert). Beim Aufnehmen in eine Gruppe wird jede Nachricht neu angestoßen (bei sehr langen Verläufen entsprechend viele Protokolleinträge).

## 7. Anmeldung und Konten

Umgesetzt in Phase 1a (Server) und Phase 1b (App: Anmeldung, Einladungen, Konto, Admin; Abschnitt "App-Teil (Phase 1b)" unten). Endpunkte: [`API.md`](API.md). Betrieb (Schlüssel, Datenbank-Rollen, erster Admin): `deploy/README.md`.

### Grundsätze

- **Passkey als Standard.** Jede Person kann einen Passkey einrichten (Handy, Windows Hello, Sicherheitsschlüssel). Server: `@simplewebauthn/server`, nur klassische Algorithmen (ES256, RS256),
  Nutzerprüfung (UV) und auffindbare Passkeys Pflicht, Attestation `none`, Challenge serverseitig gespeichert (5 Minuten, einmal einlösbar), `signCount` wird geprüft (Rückgang = abgelehnt und im Audit-Log).
  RP-ID `familie.lx-labs.dev` (konfigurierbar, `WEBAUTHN_RP_ID`). Für Passkeys in der App braucht `familie.lx-labs.dev` die Dateien `/.well-known/assetlinks.json` (Android) und
  `/.well-known/apple-app-site-association` (iOS); die Android-Origin der App kommt über `WEBAUTHN_ORIGINS`.
- **Passwort nur mit TOTP.** Wer statt Passkey ein Passwort nutzt, richtet bei der Registrierung TOTP ein (die Code-Bestätigung ist Pflicht, sonst entsteht kein Konto). Passwörter mit **Argon2id**
  (32 MiB, 3 Durchgänge; höchstens 2 gleichzeitig, Warteschlange begrenzt, bei Überlast `503`), mindestens 12 Zeichen (einstellbar, nie unter 10). Das TOTP-Geheimnis liegt **AES-256-GCM-verschlüsselt** in der Datenbank (Schlüssel `AUTH_SECRET_KEY` außerhalb der Datenbank, an die Benutzer-ID gebunden).
  Teilschlüssel entstehen per HKDF-SHA256 aus `AUTH_SECRET_KEY` mit dem festen Domänen-Label `lx-fampad/<Zweck>` (`KDF_DOMAIN`, nie ändern; Known-Answer-Test). Replay-Schutz: Der zuletzt akzeptierte Zeitschritt wird atomar fortgeschrieben; derselbe Code gilt nie zweimal. Die Prüfung gegen geleakte Passwörter (k-Anonymität) ist **nicht** umgesetzt (optional, offen).
- **Wiederherstellung:** 10 Einmal-Codes (`XXXX-XXXX-XXXX-XXXX`, rund 78 Bit) beim Einrichten, gespeichert als **HMAC-SHA256 mit dem Server-Schlüssel** (`recovery_codes`, mit Einlöse-Zeitpunkt). Ein Code genügt für die
  Anmeldung (die Sitzung gilt als frisch bestätigt, damit ein neuer Passkey eingerichtet werden kann) oder ersetzt bei Passwort-Konten den TOTP-Code. Admins können ein Mitglied **zurücksetzen** (alle
  Anmeldedaten, Codes und Sitzungen werden widerrufen, eine neue Einladung für dasselbe Konto entsteht); der Betreiber kann das auch per Kommandozeile (`--reset`). Keine Wiederherstellung per SMS.
- **Keine offene Registrierung.** Der Server bedient genau eine Familie.

### Ablauf

1. **Erstinstallation:** Der Betreiber ruft auf dem Server `node dist/cli/bootstrap.js` auf. Das legt die Familie und eine Einladung für den ersten Admin an und gibt den Link aus
   (Einmaltoken, 7 Tage). Läuft die Einladung ab, ersetzt ein erneuter Aufruf sie; nach dem Einlösen ist der Weg gesperrt.
2. **Einladen:** Admins erzeugen Einladungen für jede Rolle (Admin-Einladungen verlangen zusätzlich eine frische Bestätigung); Eltern nur für Kinder (und verwalten nur ihre eigenen Einladungen).
   - **Token:** 256 Bit aus dem CSPRNG, in der Datenbank nur der SHA-256-Hash, einmalig, Rolle fest. Der Link trägt das Token im **URL-Fragment** (`https://familie.lx-labs.dev/#/einladung/<token>`), nie als Pfad oder Query,
     damit es in keinem Server-, Proxy- oder Caddy-Log landet; die App sendet es nur im POST-Body. Der QR-Code kodiert denselben Link (die Grafik erzeugt die App).
   - **Gültigkeit:** Standard 24 Stunden, einstellbar bis 7 Tage; Admins (und Eltern für ihre eigenen Einladungen für Kinder) können widerrufen oder (auch Abgelaufene) verlängern; Verlängern **verkürzt nie**. Wird eine Person herabgestuft oder entfernt, werden ihre offenen Einladungen widerrufen.
   - **PIN (optional):** 6 Ziffern aus dem CSPRNG, nur als HMAC gespeichert, dem Einladenden einmalig bei der Erstellung angezeigt und getrennt weiterzugeben. Jeder Versuch wird **vor** dem Vergleich atomar gezählt;
     nach 5 Fehlversuchen ist die Einladung gesperrt.
   - **Freigabe (optional):** Mit `requireApproval` (Standard: aus) wird das neue Mitglied `pending` und kann sich erst nach Freigabe durch einen Admin anmelden. Früher war sie für Gäste der Standard; seit dem Wegfall der Gäste gibt es sie nur noch auf ausdrücklichen Wunsch.
3. **Annehmen:** Die eingeladene Person prüft die Einladung (`lookup`), wählt Passkey oder Passwort+TOTP, bestätigt den Besitz (Passkey-Antwort bzw. TOTP-Code) und bekommt erst dann das Konto, die
   Wiederherstellungs-Codes und (wenn nicht `pending`) eine Sitzung. Alles geschieht in einer Transaktion; die Einladung wird dabei atomar verbraucht (parallele Einlösungen: genau eine gewinnt).
4. **Anmelden:** Passkey (ohne Kontoangabe), Passwort+TOTP oder Wiederherstellungs-Code. Alle Fehlschläge antworten gleich (`invalid_credentials`); unbekannte Konten rechnen gegen einen Platzhalter-Hash (keine Konto-Enumeration per Antwort oder Zeit).
   **Reihenfolge bei Passwort und Wiederherstellungs-Code:** (1) Passwort bzw. Code prüfen, (2) gesperrte Konten wie ein falsches Passwort behandeln (`invalid_credentials`, nichts verbraucht), (3) den zweiten Faktor nur **prüfen** (TOTP-Zeitschritt bzw. Code unverbraucht), (4) erst jetzt die Statusprüfung: `pending` ergibt `403 account_pending` und verbraucht nichts (die Antwort verrät den Status also nur dem, der Passwort **und** zweiten Faktor kennt), (5) bei aktivem Konto wird der Faktor in **derselben Transaktion** wie die Sitzungserstellung verbraucht; scheitert das (parallel eingelöst), gibt es `invalid_credentials` und keine Sitzung.
5. **Sitzungen:**
   - **Web:** Cookie `__Host-lxsid` (`Secure; HttpOnly; SameSite=Strict`, ohne Domain; Token 256 Bit, in der Datenbank nur der Hash). CSRF-Schutz doppelt: ein fremder `Origin` wird abgelehnt, und jede ändernde Anfrage
     braucht `X-CSRF-Token` (aus der Sitzungs-ID abgeleitet). 30 Tage absolut, 7 Tage Leerlauf.
   - **App:** Access-Token (HMAC-signiert, 15 min, prüft zusätzlich die Sitzung in der Datenbank und wirkt nach einem Widerruf daher sofort nicht mehr) + Refresh-Token mit Rotation. Beim Einlösen setzt der Server `used_at` und
     `rotated_to`; ein erneut vorgelegtes Token widerruft die **ganze `token_family`** und schreibt `session_reuse_detected` ins Audit-Log. Das Refresh-Token ist an die Geräte-ID gebunden; die absolute Dauer (90 Tage) bleibt
     bei der Rotation erhalten, im Leerlauf (30 Tage) läuft es ab. Ablage in `flutter_secure_storage` (App, Phase 1b). **Ausnahme:** kurzes Toleranzfenster für eine verlorene Antwort (nächster Absatz).
   - **Geräteliste** (`GET /devices`), jedes Gerät einzeln abmeldbar, „überall abmelden“. Bei **Rollenwechsel** werden alle Sitzungen der Person widerrufen.
6. **Erneute Bestätigung (Step-up):** wiederverwendbare Prüfung (`requireStepUp`, 5 Minuten) für Tresor, Rollenänderung, Mitglied entfernen/zurücksetzen, Admin-Einladung, neuen Passkey und neue Wiederherstellungs-Codes.
   Bestätigt wird per Passkey, TOTP oder Wiederherstellungs-Code; die Anmeldung selbst zählt als frische Bestätigung.
7. **WebSocket:** `POST /api/v1/ws-ticket` liefert ein Einmal-Ticket (256 Bit, 30 s, nur der Hash gespeichert, atomar einlösbar). Der Socket löst es in der ersten Nachricht ein; Browser mit Cookie sind beim Upgrade angemeldet.
   Fehlgeschlagene Anmeldungen am WebSocket zählen gegen die IP (verzögerte Sperre schon vor dem Upgrade). Nachrichtenlimit je Socket sowie Verbindungslimit je IP (IPv6: je /64) und je Person werden ohne Wettlauf gezählt.
   Der Hub kennt die Verbindungen je Person, Sitzung und Gerät: Abmelden, Gerät entfernen, Rollenwechsel und Entfernen schließen sie sofort (Code `4401`); bei jedem Ping wird die Sitzung erneut geprüft und die Rolle aktualisiert.
8. **Schutz:** Strengere Rate-Limits für Anmelde-, 2FA- und Ticket-Routen; Fehlversuche je IP (IPv6: /64), je Konto und je Paar Konto+IP mit verzögerter Sperre (Paar ab 5, IP ab 20, Konto ab 10 Fehlversuchen 30 s, verdoppelt bis **höchstens 90 s**; Schlüssel nur als HMAC gespeichert; Passkey-Anmeldungen hängen nicht an der Konto-Sperre, Anmeldung und Step-up teilen einen Konto-Schlüssel); Challenge-Erzeugung ohne Anmeldung je IP-Präfix und global begrenzt; Eingaben mit NUL oder einzelnen Surrogaten werden abgelehnt; im Log stehen bei Datenbankfehlern nie SQL-Parameter;
   Audit-Log sicherheitsrelevanter Ereignisse (Anmeldung, neues Gerät, Rollen, Zurücksetzen, Einladungen, Fehlversuche, Wiederverwendung); eigener Fehlerhandler ohne interne Meldungen.
   Die IP im Audit-Log wird nach 7 Tagen entfernt, die Einträge nach 365 Tagen gelöscht (Aufräum-Job beim Start und **stündlich**; er bereinigt auch Sitzungen, Challenges, Tickets und Fehlversuche).
   **Nicht umgesetzt:** Hinweis per Mail bei neuem Gerät (es gibt noch keinen Mail-Versand; das Audit-Log hält `device_added` fest).
9. **Familiengrenze:** Alle Abfragen sind auf die Familie der Sitzung begrenzt; Verweise auf Personen laufen über zusammengesetzte Fremdschlüssel `(family_id, user_id)` auf `memberships`
   (Sitzungen, Geräte, Tickets, Termin-Teilnehmer, Reaktionen, Lesebestätigungen), sodass die Datenbank Verweise über Familiengrenzen verhindert.
- Kinderkonten legen die Eltern per Einladung an; Kinder melden sich mit Passkey auf ihrem eigenen Gerät an.

### Toleranzfenster für ein gerade rotiertes Refresh-Token (Sicherheitsbetrachtung)

**Problem.** Geht die Antwort auf `POST /auth/refresh` verloren (Funkloch nach dem Senden, App wird beendet), hat der Server das Token eingelöst, die App kennt das neue Paar aber nicht. Ohne Fenster wäre jede dieser Wiederholungen eine „Wiederverwendung“ und würde die Token-Familie widerrufen: die Person müsste sich neu anmelden.

**Regel (`refreshSession`, `regrantRefresh` in `server/src/auth/sessions.ts`).** Eine Wiederholung wird bedient, wenn **alle** Bedingungen gelten: höchstens **30 s** seit dem Einlösen (festes Fenster ab `used_at`, `refreshGraceSec`), **dieselbe Geräte-ID** wie beim Einlösen und die **Nachfolgerin ist noch unbenutzt** (nicht eingelöst, nicht widerrufen). Dann wird die erste, nie angekommene Nachfolgerin widerrufen und **genau eine** neue ausgestellt (gleiche Familie, gleiche absolute Ablaufzeit, `rotated_to` zeigt auf die neue); Audit `session_refresh_retry`. Die Zeilen der eingelösten Sitzung und der Nachfolgerin werden mit `FOR UPDATE` gesperrt: gleichzeitige Wiederholungen laufen nacheinander und lassen nie zwei lebende Nachfolger entstehen. Alles andere bleibt Widerruf der ganzen Familie (`session_reuse_detected`): nach 30 s, andere Geräte-ID, benutzte oder widerrufene Nachfolgerin.

**Warum das sicher genug ist (Security-Sicht).**
- Wer ein gestohlenes Refresh-Token nutzen will, braucht **zusätzlich die Geräte-ID** (UUID, liegt nur im Keystore der App und wird nirgends außer im Refresh-Aufruf gesendet). Ein Dieb mit nur dem Token scheitert wie bisher und löst den Widerruf aus.
- Hat ein Dieb Token **und** Geräte-ID (also vollen Zugriff auf den Keystore des Geräts), kann er ohnehin das aktuelle Token selbst einlösen; das Fenster verschafft ihm nichts, was er nicht schon hätte. Er hat höchstens 30 s ab dem letzten Einlösen Zeit, danach (oder sobald die Nachfolgerin benutzt wird) greift die Erkennung wie zuvor.
- Die Nachfolgerin wird beim Wiederholen **widerrufen**: wer das neue Paar schon hat (legitimes Gerät, dessen Antwort doch ankam) verliert es, statt dass zwei Äste der Familie parallel weiterleben. Der legitime Fall ist harmlos (die App legte das Token nur vor, weil sie das neue nie bekam); im Diebstahlsfall wird der Dieb zum alleinigen Besitzer, das legitime Gerät fällt bei seinem nächsten Refresh heraus (`invalid_token`, Anmeldung neu) und der Vorfall bleibt im Audit sichtbar (`session_refresh_retry` ohne passenden Verlust-Hinweis der App). Das Fenster ist bewusst kurz und nicht gleitend.
- Das Fenster ist ein Kompromiss zwischen Verfügbarkeit (keine erzwungene Neuanmeldung nach einem Funkloch) und Erkennung. Abschalten: `refreshGraceSec` auf 0 (Konstante in `server/src/config.ts`).
- Die App ändert ihr Verhalten nicht: sie wiederholt ein Refresh-Token **nicht auf Verdacht**, sondern nur, wenn sicher ist, dass die Anfrage den Server nie erreichte (Fehler beim Verbindungsaufbau); bei unklarem Ausgang (Zeitlimit der Antwort, Abbruch nach dem Senden) meldet sie ab. Eine einmalige Wiederholung im Fenster ließe sich später clientseitig ergänzen (siehe „Später“).

Tests: `server/test/auth-login.test.ts` (Fenster, Rand 30 s, außerhalb, falsche Geräte-ID, Nachfolgerin benutzt, parallele Wiederholungen).

### App-Teil (Phase 1b)

Code: `app/lib/data/api/` (ApiClient, Endpunkte, DTOs, Token-Ablage), `app/lib/data/auth/auth_state.dart` (Riverpod), `app/lib/features/auth|profile|admin/`.

- **API-Client:** `http` gegen `kApiBase`. Web: HttpOnly-Cookie (gleiche Domain), `X-CSRF-Token` (aus der Sitzungsantwort bzw. `GET /me`) an jeder ändernden Anfrage, nichts in `localStorage`. Android: Access-Token als Bearer, Access- und Refresh-Token in `flutter_secure_storage`; Erneuerung kurz vor Ablauf oder nach einem 401 **nur bei den Codes `unauthenticated`/`invalid_token`**; andere 401-Fachcodes (z. B. `step_up_failed`) lösen weder Erneuerung noch einen zweiten Versuch aus (der Versuch zählte sonst doppelt gegen die Sperre). **Refresh wird serialisiert** (ein Future für alle Aufrufer) und bei unklarem Ausgang (Zeitüberschreitung der Antwort, Abbruch nach dem Senden) **nicht wiederholt**: Das Token könnte eingelöst sein, und der Server widerruft bei Wiederverwendung die ganze Familie (Ausnahme: Toleranzfenster, der Client verlässt sich aber nicht darauf). Die lokale Sitzung wird dann verworfen und die Person meldet sich neu an. Nur ein `VerbindungsaufbauFehler` (Verbindung kam nicht zustande: kein Netz, DNS, abgelehnt, TLS, Zeitlimit beim Aufbau von 10 s) lässt die Token unangetastet. Die Einstufung hängt nur vom **Typ** der Ausnahme ab (nie vom Meldungstext): Auf Android öffnet ein eigener Client (`PhasenClient`, `app/lib/data/api/http_client_io.dart`) die Verbindung getrennt vom Senden; die Zeitgrenze für die Antwort (20 s) bleibt davon getrennt. Eine **Sitzungsgeneration** im Client verwirft späte Ergebnisse: eine Erneuerung, die erst nach Abmelden oder Personenwechsel zurückkommt, schreibt keine Token mehr zurück und beendet auch die neue Sitzung nicht. Gerätename, Plattform, Version und die gespeicherte Geräte-ID gehen bei Anmeldung und Registrierung mit.
- **Fehler:** Einheitliche `ApiException` mit fester deutscher Meldung je Fehlercode (nie Servertext oder Systemmeldung). 401 mit `unauthenticated`/`invalid_token` an geschützten Stellen = zurück zur Anmeldung; 429/`too_many_attempts` und 503 `server_busy` zeigen die Wartezeit aus `Retry-After`; `step_up_required` öffnet den Bestätigungsdialog (Passkey, TOTP oder Wiederherstellungscode) und wiederholt die Aktion einmal.
- **Zustand:** `AuthStatus` prüfe / abgemeldet / angemeldet / wartend (Freigabe) / Verbindungsfehler; das Pflicht-Update (`updateProvider`) hat Vorrang. Start: `GET /me`; ohne Netz **oder bei Serverstörung** (503 `server_busy`, 429, 5xx, auch eine HTML-Fehlerseite von Caddy bei 502) startet die Android-App mit dem gespeicherten Profil (Name, E-Mail, Rolle, Farbe im Keystore). Jeder Ausgang von `start()` ist ein Zustand ohne Ladeanzeige (`catch`-Zweig: Fehlerseite mit "Erneut versuchen", nie ein Endlos-Spinner; `SecureTokenStore` fängt beim Lesen alle Ausnahmen ab, löscht den unlesbaren Eintrag und liefert null). Im Web ist ein 401 beim Start der Normalfall (Erstbesuch) und zeigt **keinen** Hinweis "Sitzung abgelaufen" (die Konsole meldet das 401 weiterhin: ein Browser kann ein `HttpOnly`-Cookie nicht vorab prüfen, ein Merker-Flag wäre nicht zuverlässig).
  - **Abmelden** (`AuthController.abmelden`): Android: Serverfehler oder offline werden toleriert, das Token wird lokal gelöscht, die Person erfährt es ("nur auf diesem Gerät abgemeldet; die Sitzung bleibt auf dem Server bis zum Ablauf gültig, beendbar unter Angemeldete Geräte"). Web: bei Serverfehler wird **nicht** als abgemeldet angezeigt (Fehler, "Erneut versuchen", "Trotzdem nur lokal abmelden" mit Warnung, dass die Sitzung auf dem Server gültig bleibt). Ist die Sitzung dort schon beendet (401), gilt es als abgemeldet. Der Zustand geht in jedem Fall, in dem nicht geworfen wird, auf abgemeldet (`try/finally`), auch wenn das Löschen der Daten scheitert (die Person wird informiert).
  - **Lokale Daten:** Ausdrückliches Abmelden (und "Überall abmelden", Gerät in der Liste entfernen) leert die Datenbank über den Hook `localDataWiperProvider` (seit Phase 1c: hält den Sync an und leert Listen, Ausgang und Sync-Zustand, siehe 6a). Ein **Sitzungsverlust** (abgelaufen, widerrufen, Erneuerung gescheitert) löscht Token und Profil, **leert die Datenbank nicht**: Sie kann ungesendete Änderungen (Outbox) enthalten, die nach einer erneuten Anmeldung derselben Person nicht verloren gehen sollen. Die Datenbank merkt sich die Benutzer-ID ihres Besitzers (`sync_meta.ownerUserId`, Hook `localDataOwnerProvider`); meldet sich eine **andere** Person an (Anmeldung, Registrierung, Start mit fremder Sitzung), wird sie vorher geleert; scheitert das, wird die Anmeldung abgebrochen. Dokumentiert in `docs/DATENSCHUTZ-ENTWURF.md`, Abschnitt 6 (das Profil im Keystore enthält auch die E-Mail-Adresse).
  - **Späte Antworten:** Ein Generationszähler im `AuthController` verwirft Antworten von `GET /me`, die erst nach Abmelden oder Personenwechsel eintreffen (Bedingung: weiterhin angemeldet und gleiche `user.id`).
- **Einladung annehmen:** Web: `/#/einladung/<token>` wird in `main()` gelesen und sofort mit `history.replaceState` (unter Mitgabe des vorhandenen `history.state`, damit Flutters Verlaufszähler und die Zurück-Taste heil bleiben) aus der Adresszeile entfernt, auch bei ungültigem Token. Wird ein Link in einen **schon offenen Tab** eingefügt, entsteht ein `popstate` (die Engine springt daraufhin selbst mit `history.go(-1)` zurück, deshalb horcht der Client auf `popstate` **und** `hashchange`: nur im ersten sieht er das Fragment sicher) und der Link wird ebenso sofort entfernt. Flutters Router bekommt das Token **nie**: Die App hat keine benannten Routen (alle Seiten per `Navigator.push` ohne Namen); ein `WidgetsBindingObserver` schluckt alle Pfadmeldungen des Browsers (`didPushRouteInformation`), sodass kein Routenname mit Token in Adresszeile oder Verlauf zurückgeschrieben wird. Der frühere Umweg über eine Route, die sich selbst schließt (`_SofortZurueck`/`maybePop`, mit einem Wettlauf gegen die Einladungsseite), ist entfallen. Doppelte Meldungen desselben Links (Adresszeile und Routenmeldung) fängt der Intake ab. Geprüft im echten Chrome: nach Kaltstart und nach Einfügen in einen offenen Tab stehen weder `location.href` noch der Navigationsverlauf mit Token da; die Zurück-Taste führt zur Anmeldeseite. Android: Link einfügen, QR scannen (`mobile_scanner`, nur Android) oder Intent (`https://familie.lx-labs.dev/` mit Fragment; nur Links mit Fragment `#/einladung` zählen, andere Links der Domain ignoriert die App; ein Link im Status "wartend" öffnet die Einladung). Das Token bleibt im Arbeitsspeicher und geht nur im POST-Body zum Server. Ablauf: prüfen, PIN/Name/E-Mail, Passkey oder Passwort + TOTP (Secret und QR des otpauth-URI), Wiederherstellungscodes (einmalig; ohne Bestätigung "gespeichert" geht es nicht weiter; die Sitzung wird erst danach übernommen), bei `pending` der Warte-Bildschirm.
- **Passkeys:** Paket `passkeys` (Android: Credential Manager, Web: selbst gehostetes `web/passkeys-bundle.js`). Fehler (abgebrochen, kein Support, Google Play-Dienste fehlen, Domain nicht verknüpft) zeigen klare Meldungen mit dem Weg zu Passwort + TOTP. Voraussetzungen auf dem Server: `assetlinks.json` und `WEBAUTHN_ORIGINS` (`deploy/README.md`, Abschnitt 9).
- **Konto und Admin:** Profil/Sicherheit (Passkeys hinzufügen/entfernen, neue Wiederherstellungscodes, Geräteliste mit einzelnem Abmelden), Admin: Mitglieder (Rolle, entfernen, zurücksetzen, freigeben/ablehnen) und Einladungen (erstellen mit Rolle/Gültigkeit/PIN/Freigabe, QR + Link + PIN einmalig, verlängern, widerrufen). Eltern sehen nur die Einladungen für Kinder (Rolle aus `/me`; der Server erzwingt es ohnehin).
- **Datenschutz in der App:** keine Token im Log, `FLAG_SECURE` auf Seiten mit Geheimnissen (Kotlin merkt sich den Wunsch und setzt das Flag in `onCreate`/`onResume` neu), Zwischenablage nur auf Klick und für Geheimnisse (Codes, PIN, TOTP-Schlüssel, Einladungslink) mit `EXTRA_IS_SENSITIVE`, `onNewIntent` ersetzt den Intent. Manifest: `autoVerify="true"` am Einladungs-Filter, Backup komplett aus (`allowBackup=false` plus leere `dataExtractionRules`/`fullBackupContent`), Kamera nicht erforderlich, die privilegierte Berechtigung `CREDENTIAL_MANAGER_SET_ORIGIN` des Passkey-Pakets wird entfernt (`tools:node="remove"`; das Paket setzt keinen Origin, und eine normale App bekäme sie ohnehin nie). Passwortfelder liegen in einer `AutofillGroup` (Web: `<form>`; Passwortmanager erkennen E-Mail und Passwort; die Chrome-Meldung "Password field is not contained in a form" erscheint nur noch bei eingeschalteter Bedienungshilfe, weil Flutter die Eingabe dann außerhalb eines Formulars aufbaut).
- **Bedienung:** Ein abgebrochener Passkey-Dialog ist keine Fehlermeldung (neutraler Hinweis). Nach einer erfolgreichen Aktion (Einladung erstellen, Passkey, Mitglied) ist ein Fehler beim Neuladen der Liste kein Fehler der Aktion (Hinweis "Liste konnte nicht aktualisiert werden", Erfolg bleibt Erfolg). Listen werden pro Eintrag gelesen: ein unbekannter Wert (Rolle, Status einer neueren Server-Version) lässt nur diesen Eintrag weg. Der Step-up-Dialog lässt sich nicht per Tipp daneben und, solange der Passkey-Dialog läuft, nicht per Zurück schließen. Lange Überschriften (z. B. "Wiederherstellungscodes") werden bis auf 18 px verkleinert, statt mitten im Wort umzubrechen. Die Hinweiszeile unter der Anmeldung zeigt den Host aus `API_BASE` bzw. der Seitenadresse; `kInviteHost` kommt aus `--dart-define=INVITE_HOST`.

## 8. Updates (OTA)

| Ziel | Weg |
| --- | --- |
| **Server** | wie lx-labs: `npm run deploy` (bauen, pushen, auf dem VPS aktualisieren). Datenbank-Migrationen nur vorwärts und rückwärtskompatibel zur Vorgängerversion der App. |
| **Web** | Flutter-Web-Build liegt versioniert hinter Caddy. Die Seite fragt `/api/v1/version` ab; bei neuer Version Hinweis „Neue Version – neu laden“: `deploy-web.sh` schreibt die Kennung des Builds nach `version.txt` (der Server meldet sie als `webVersion`) und baut sie mit `--dart-define=WEB_VERSION` in die App ein; weichen beide ab, erscheint der Hinweis. Kein automatisch registrierter Service Worker ohne Zustimmung (wie bei lx-labs, TDDDG). |
| **Android** | **Eigener Update-Kanal auf dem VPS** statt GitHub-Releases: `familie.lx-labs.dev/releases/android/latest.json` mit Version, Mindestversion, SHA-256 und Release-Notes, **signiert mit Ed25519** (privater Schlüssel nur in der CI). Das Manifest ist `{ "payload": "<JSON-Text>", "signature": "<Base64>" }`; signiert wird genau der Text in `payload`. Der Payload enthält `packageName`, `version`, `versionCode`, `minVersion`, `apk`, `sha256`, `size`, `notes`, `issuedAt` und `keyId`. Die App (Paket `cryptography`, öffentlicher Schlüssel als Konstante `kUpdatePublicKey`) prüft: Signatur, `packageName`, `keyId`, `versionCode` (größer als der installierte; ein kleinerer ist ein altes Manifest und wird abgelehnt), `issuedAt` (nicht in der Zukunft, höchstens 365 Tage alt, solange ein Update angeboten wird) und `size` (1 Byte bis 200 MB). Der Download bricht ab, sobald mehr Bytes kommen als `size`; Größe und SHA-256 werden geprüft und unmittelbar vor der Installation erneut berechnet. Installiert wird per `PackageInstaller`-Session nach Klick. Den Schlüssel erzeugt und das Manifest signiert `tools/update-manifest.mjs` (privater Schlüssel nur in der CI, nie im Repo; Ablauf in `tools/README.md`). Vorteil gegenüber dem bestehenden OTA-Paket: kein Lese-Token in der App, nichts Extrahierbares. Signaturschlüssel und `applicationId` nie ändern. |
| **iOS** | *Zurückgestellt.* Apple erlaubt keine eigene Installation von Apps. Weg: **TestFlight / App Store** (Apple Developer Program, 99 $/Jahr; Build auf einem Mac oder per Cloud-CI). Optional später **Shorebird** für Dart-Patches ohne Store-Review – das ist ein externer Dienst und muss vorher von Security/Datenschutz bewertet werden. |
| **Erzwingen** | Die App fragt `/api/v1/version` ab: ist ihre Version kleiner als `minAppVersion` oder ihre Protokollversion kleiner als `minProtocolVersion` (oder das Manifest hat eine höhere `minVersion`), ersetzt eine Pflicht-Update-Seite die App, bis das Update installiert (Web: neu geladen) ist. |

Übernommen aus dem OTA-Paket: Statusmodell (`deaktiviert | pruefe | aktuell | laedt | bereit | fehler`),
Installation nur per Klick, Installationssperre während Upload/Sync, Release-Notes als reiner Text,
verständliche Fehlertexte (offline / Zugang / sonstiges).

## 9. Datenschutz und Sicherheit

- Server in Deutschland (netcup), keine Tracker, keine eingebetteten Fremdinhalte, Schriften selbst gehostet.
- **Verschlüsselung:** TLS 1.3 für alle Verbindungen; Dateien auf dem Server mit AES-256-GCM (Schlüssel pro
  Datei, verpackt mit einem Hauptschlüssel außerhalb des Datenverzeichnisses); Backups mit restic verschlüsselt.
- **Ende-zu-Ende-Verschlüsselung** ist für Phase 1 bewusst **nicht** vorgesehen (für den Chat ist sie geplant; die Schnittstelle dafür ist vorbereitet, Abschnitt 6c; bis dahin ist der Inhalt für den Server-Betreiber lesbar, private Chats sind nur für Admins und Eltern unlesbar): Sie würde Suche,
  Vorschaubilder, Wiederherstellung durch den Admin stark erschweren. Für den Tresor ist sie
  in Phase 3 als Option zu prüfen.
- **Push-Nachrichten** enthalten keinen Inhalt („Neue Nachricht in Familie“), Details holt die App selbst.
- **Standorte:** nur mit ausdrücklicher Zustimmung der Person selbst, mit gewählter Dauer, jederzeit
  beendbar; Positionen werden nach Ende der Freigabe sofort gelöscht, laufende höchstens 2 Stunden als Spur
  gehalten; Standortrecht „immer“ unter Android/iOS wird nur angefordert, wenn jemand teilt. Bei Kindern
  Hinweis in der Datenschutzerklärung zur Einwilligung durch die Sorgeberechtigten.
- **Fotos:** GPS- und andere Metadaten auf Wunsch beim Upload entfernen (Logik aus dem lx-labs-Tool
  „Foto-Metadaten entfernen“).
- **Server-Härtung:** PostgreSQL nur auf localhost, eigener Systembenutzer und systemd-Dienst, Firewall
  unverändert (nur SSH/HTTP/HTTPS), Sicherheits-Header und strenge CSP über Caddy, Upload-Größen und
  Dateitypen begrenzt.
- **Rechtliches:** eigene Datenschutzerklärung für lx-fampad (Kinderdaten, Standort, Web Push über den
  Browser-Dienst), Löschkonzept (Konto löschen, Familie löschen, Export aller Daten als ZIP).

## 10. Betrieb auf dem VPS

- DNS bei Cloudflare: `familie` A-Record auf die Server-IP, **DNS only** (graue Wolke) wie lx-labs.dev.
- Caddy: zusätzlicher Site-Block `familie.lx-labs.dev` (statische Web-App, Reverse Proxy `/api` und `/ws`
  auf `127.0.0.1:4400`, `/releases`, `/.well-known`).
- Dienst `lx-fampad.service` unter eigenem Benutzer, Daten unter `/srv/fampad/`.
- Backups: nächtlich `pg_dump` + Dateien mit restic auf ein externes Ziel, Aufbewahrung 7 Tage / 4 Wochen /
  6 Monate, Wiederherstellung einmal pro Quartal testen.
- Monitoring: `/api/v1/health`, Speicherplatz-Warnung, Log-Rotation; keine IP-Adressen länger als 7 Tage.
- Vor Phase 1 prüfen: RAM, CPU und freier Speicher des VPS reichen für PostgreSQL, Vorschaubilder und das
  Dateivolumen (Fotos/Videos wachsen schnell).

## 11. Projektstruktur (geplant)

```
lx-fampad/
  server/          Node/Fastify-API, Sync, Auth, Dateien, WebSocket, Drizzle-Schema und Migrationen
  app/             Flutter (Android, Web; iOS später): lib/data (drift, sync), lib/features/<bereich>, lib/ui (Tokens)
  deploy/          Caddy-Site, systemd-Dienst, deploy.sh, Backup-Skripte, Anleitung
  docs/            diese Beschreibung, Mockups, Entscheidungen (ADR), Release-Notes-Vorlage
  .github/         CI: Tests, Builds, signiertes Android-Release
```

Design-Tokens aus `lx-labs/src/styles/global.css` werden als `ThemeData`/`ColorScheme` in Flutter
übernommen (keine neuen Farben ohne Token).

## 12. Fahrplan

| Phase | Inhalt | Ergebnis |
| --- | --- | --- |
| **0 – Grundlage** | Versionen recherchieren und pinnen, Repo-Struktur, CI, Server-Grundgerüst, DB-Schema, Caddy-Site, Flutter-Gerüst mit Theme | leere App läuft im Browser und auf Android, Deploy funktioniert |
| **1 – Kern (MVP)** | Konten, Einladungen, Passkey + Passwort/2FA, Sync-Protokoll, Kalender, Chat, Listen, Aufgaben, Dateien, Startseite, Push, Android-OTA | Familie nutzt die App im Alltag |
| **2 – Ausbau** | Tresor, Pinnwand, Fotos & Alben, Essensplan & Rezepte, Kontakte, Suche, Standort & Karte | Funktionsumfang nahe FamilyWall |
| **3 – Extras** | Orte, Budget, ICS/CalDAV-Import, Daten-Export, E2EE-Option für den Tresor | voller Umfang |

Phase 1 läuft in Teilen: **1a** Konten und Anmeldung (Server), **1b** Anmeldung in der App, **1c-1** Sync-Kern und Listen (Server und App, Abschnitt 6a), **1c-2a** Kalender-Kern (Termine, Teilnehmer, Ausnahmen, Wiederholungen, Agenda/Monat/Woche; Abschnitt 6b) auf demselben Kern, **1c-3a** Chat-Kern (Familienchat, Direktchats, Gruppen, Lesestand; Abschnitt 6c), danach Push (1c-3b), Aufgaben, Dateien (Anhänge 1c-4) (Erinnerungen und Geburtstage des Kalenders folgen mit Push bzw. Import).

Jede Phase durchläuft das Team: **Research** (Bibliotheken, Plattformvorgaben) → **Coding** →
**QM/Testing** (Sync-Randfälle: offline, gleichzeitige Änderungen, abgebrochene Uploads; Mobilansicht ab
360 px) → **Code-Review** → **Security** (vor jedem Deploy, insbesondere Auth, Uploads, OTA-Signatur).

### Vor Phase 1 zu erledigen

Ergebnis der Sicherheits-Nachprüfung am Ende von Phase 0; diese Punkte gehören vor Beginn bzw. in den Anfang von Phase 1 (Auth, Sync, Dateien):

- ~~**WebSocket-Fehlversuche zählen:**~~ erledigt in Phase 1a: abgelehnte Tickets/Anmeldungen am WebSocket gegen das Rate-Limit je IP zählen (nicht nur erfolgreiche Verbindungen).
- ~~**Getrennte Datenbank-Rollen:**~~ erledigt in Phase 1a (`lx_fampad_migrate` / `lx_fampad`, `deploy/README.md`): eine Rolle für Migrationen (DDL), eine eingeschränkte für den Betrieb (nur DML); der Dienst läuft mit der Betriebsrolle.
- **GitHub Actions auf Commit-SHA pinnen** und das Signieren des Update-Manifests in einen eigenen Job mit nur dafür freigegebenem Secret (`UPDATE_SIGNING_KEY`) trennen. Dazu in `ci.yml` einen Schritt `npm audit --omit=dev` für den Server aufnehmen (Produktivabhängigkeiten).
- **Später (Befunde aus Phase 1a, bewusst zurückgestellt):**
  - **Audit-Log nur anhängen:** Die Laufzeitrolle darf `audit_log` heute ändern und löschen (der Aufräum-Job braucht das). Besser: Laufzeit nur `INSERT`/`SELECT`, Bereinigung über eine eigene Rolle oder einen Datenbank-Job.
  - **`AUTH_SECRET_KEY`: Key-ID und Rotation:** Gespeicherte HMACs und TOTP-Geheimnisse tragen keine Schlüsselkennung; eine Rotation ist daher nicht möglich. Key-ID im Format (z. B. `v1.<kid>.…`) und Neuverschlüsselung vorsehen.
  - **Bootstrap und Zurücksetzen (`bootstrap.js`) nicht als root aus einem für `lx` schreibbaren Verzeichnis:** Der Aufruf liest Code aus `/srv/fampad/server` (Gruppe `lx-fampad`, `lx` schreibt dort bei jedem Deployment) und läuft mit `sudo`. Stattdessen eine root-eigene, unveränderliche Kopie oder eine eigene Einheit verwenden.
  - **Tresor- und „Familie löschen“-Endpunkte** nur mit Step-up (`requireStepUp`), sobald sie entstehen.
  - **Hinweis per Mail bei neuem Gerät** (setzt Mail-Versand voraus), falls gewünscht.
  - **Prüfung gegen geleakte Passwörter (HIBP, k-Anonymität)** optional.
  - **Fragment-Token im Client (Phase 1b):** Das Einladungs-Token steht im URL-Fragment; der Client liest es und entfernt es sofort mit `history.replaceState` aus der Adresszeile (Verlauf, Screenshots, Referrer); erledigt, auch für Links in einem schon offenen Tab (Abschnitt "App-Teil").
  - **App, später (aus Review und Test von Phase 1b, bewusst zurückgestellt):**
    - **Teilen** von Einladung/PIN über die Android-Freigabe (`share_plus`; heute nur Kopieren auf Klick, vertraulich markiert).
    - **„Gerät vertrauen“** (Anmeldung auf einem vertrauten Gerät dauerhaft ohne zweiten Faktor bzw. längere Step-up-Gültigkeit).
    - **Lokale Browser-Datenbank beim Abmelden vollständig entfernen** (`secure_delete`, OPFS-Datei löschen statt nur Zeilen leeren), siehe `DATENSCHUTZ-ENTWURF.md`, Abschnitt 6.
    - **`FLAG_SECURE` optional global** (Einstellung "Bildschirmfotos sperren" für die ganze App, nicht nur Geheimnis-Seiten).
    - **Wiederherstellungscodes: Hinweis "noch nicht bestätigt"** im Profil, wenn die Person die Codes beim Anlegen nicht als gespeichert bestätigt hat (heute erzwingt der Ablauf die Bestätigung, aber ein Abbruch danach ist nicht sichtbar).
    - **`qr_flutter` 4.1.0 (Wartung):** das Paket wird kaum noch gepflegt; Ersatz oder eigener QR-Painter prüfen.
    - **Refresh-Wiederholung im Toleranzfenster (Client):** bei unklarem Ausgang einmal innerhalb von 25 s mit demselben Token und derselben Geräte-ID wiederholen, statt abzumelden (der Server bedient das seit Phase 1b); bewusst noch nicht gebaut, weil die Abwägung aus dem Abschnitt "Toleranzfenster" erst Erfahrung braucht.
    - **Sitzungsverlust und lokale Daten:** in Phase 1c mit dem Ausgang (Outbox) neu bewertet und **beibehalten**: Ein Sitzungsverlust lässt Daten und Ausgang stehen (sonst gingen ungesendete Änderungen verloren), nach erneuter Anmeldung derselben Person geht der Ausgang raus; eine andere Person bekommt die Daten nie zu sehen (vorher geleert). Offen bleibt die Datenschutz-Abwägung ([Prüfen] in `DATENSCHUTZ-ENTWURF.md`, Abschnitt 6) und das physische Entfernen der Browser-Datei beim Abmelden (siehe oben).
- ~~**Löschkonzept:**~~ erledigt in Phase 1c-1: `audit_log` (IP 7 Tage, Einträge 365 Tage) wird aufgeräumt; beim Löschen eines Sync-Datensatzes werden seine Inhalte und alle Inhalte seiner `change_log`-Einträge sofort geleert, Tombstones verschwinden, sobald alle aktiven Geräte sie kennen, spätestens nach 90 Tagen; ersetzte Protokolleinträge und verarbeitete Ops nach 90 Tagen (Abschnitt 6a, `DATENSCHUTZ-ENTWURF.md`, Abschnitt 10). Offen: Aufbewahrung der aktuellen Inhalte in Datenbank-Sicherungen (restic) und das Löschen eines ganzen Kontos mit seinen Inhalten.
- **Mitgliedschafts-Prüfung bei Schema-Verweisen (für Listen erledigt in Phase 1c-1: der Sync prüft `assigneeId` auf ein aktives Mitglied der Familie und bereinigt Verweise beim Entfernen; die übrigen Entitäten ziehen mit ihren Registereinträgen nach):** Zusammengesetzte Fremdschlüssel `(family_id, user_id)` auf `memberships` gelten für Sitzungen, Geräte, Tickets, Termin-Teilnehmer, Reaktionen und Lesebestätigungen. Für Verweise mit `ON DELETE SET NULL` (`events.owner_id`, `*.assignee_id`, `messages.sender_id`, `files.uploaded_by`, `change_log.author_id`) geht das nicht (die Familien-Spalte würde mit auf NULL gesetzt); sie prüft der Sync serverseitig (Phase 1c). Ursprünglich: wo Zeilen auf andere Datensätze verweisen (Personen, Listen, Dateien), serverseitig prüfen, dass das Ziel zur selben Familie bzw. Mitgliedschaft gehört, nicht nur per Fremdschlüssel.
- ~~**Recovery-Codes:**~~ erledigt in Phase 1a (HMAC-SHA256 mit Server-Schlüssel): nicht mit einem schnellen Hash speichern, sondern mit Argon2 oder als HMAC mit serverseitigem Schlüssel.
- ~~**WebSocket-Limits atomar:**~~ erledigt in Phase 1a: Nachrichtenrate und Verbindungslimit je IP/Benutzer ohne Wettlauf (Prüfen und Zählen in einem Schritt).
- ~~**Eigener Fehlerhandler:**~~ erledigt in Phase 1a: einheitliche Fehlerantworten ohne interne Details (keine Stacktraces oder Meldungen von Bibliotheken), Fehler nur im Log.

## 13. Offene Entscheidungen

Entschieden (18.10.2026): iOS zurückgestellt (nur Android + Web), nur die eigene Familie, Push selbst gehostet
(ntfy/UnifiedPush), Android mit Google Play Services (Passkeys), Karte mit `maplibre`, Debian 13 mit PostgreSQL 17 aus dem Debian-Repo.

Offen:

1. Akku und Zuverlässigkeit von UnifiedPush auf euren Handys früh in Phase 0 testen (Hersteller-Energiesparmodi
   töten Hintergrunddienste); Rückfall: dauerhafte WebSocket-Verbindung per Vordergrunddienst.
2. Speicherkontingent für die Familie und Grenze pro Datei (Videos).
3. Kartenumfang: ganz Deutschland (ca. 5 bis 10 GB) oder nur ein Ausschnitt rund um euren Wohnort.
