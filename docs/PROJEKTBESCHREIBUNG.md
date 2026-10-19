# lx-fampad – Projektbeschreibung

Stand: 18.10.2026 · Status: Konzept · Mockups: [`docs/mockups/`](mockups/) und Design-Canvas (claude.ai, privat)

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
| **Gast** (z. B. Großeltern) | Nur freigegebene Bereiche (z. B. ein Album, ein Kalender, ein Chat) |

Der Server bedient **genau eine Familie** (die eigene). Es gibt keine Mandanten, kein Kontingent je Familie und
keine offene Registrierung; Großeltern u. a. kommen als Gäste per Einladung dazu. Im Datenmodell bleibt
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
| **Fotos & Alben** | Alben, automatische Vorschaubilder, Videos, Freigabe an Gäste, GPS-Daten entfernen (optional) | 2 |
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
  Start). Gäste sehen nie Standorte.
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
2. **Einladen:** Admins erzeugen Einladungen für jede Rolle (Admin-Einladungen verlangen zusätzlich eine frische Bestätigung); Eltern nur für Kinder und Gäste (und verwalten nur ihre eigenen Einladungen).
   - **Token:** 256 Bit aus dem CSPRNG, in der Datenbank nur der SHA-256-Hash, einmalig, Rolle fest. Der Link trägt das Token im **URL-Fragment** (`https://familie.lx-labs.dev/#/einladung/<token>`), nie als Pfad oder Query,
     damit es in keinem Server-, Proxy- oder Caddy-Log landet; die App sendet es nur im POST-Body. Der QR-Code kodiert denselben Link (die Grafik erzeugt die App).
   - **Gültigkeit:** Standard 24 Stunden, einstellbar bis 7 Tage; Admins (und Eltern für ihre eigenen Einladungen für Kinder/Gäste) können widerrufen oder (auch Abgelaufene) verlängern; Verlängern **verkürzt nie**. Wird eine Person herabgestuft oder entfernt, werden ihre offenen Einladungen widerrufen.
   - **PIN (optional):** 6 Ziffern aus dem CSPRNG, nur als HMAC gespeichert, dem Einladenden einmalig bei der Erstellung angezeigt und getrennt weiterzugeben. Jeder Versuch wird **vor** dem Vergleich atomar gezählt;
     nach 5 Fehlversuchen ist die Einladung gesperrt.
   - **Freigabe (optional):** Mit `requireApproval` (Standard für Gäste) wird das neue Mitglied `pending` und kann sich erst nach Freigabe durch einen Admin anmelden. Die Freigabe bei Gästen abzuschalten darf nur ein Admin; für Eltern erzwingt der Server sie.
3. **Annehmen:** Die eingeladene Person prüft die Einladung (`lookup`), wählt Passkey oder Passwort+TOTP, bestätigt den Besitz (Passkey-Antwort bzw. TOTP-Code) und bekommt erst dann das Konto, die
   Wiederherstellungs-Codes und (wenn nicht `pending`) eine Sitzung. Alles geschieht in einer Transaktion; die Einladung wird dabei atomar verbraucht (parallele Einlösungen: genau eine gewinnt).
4. **Anmelden:** Passkey (ohne Kontoangabe), Passwort+TOTP oder Wiederherstellungs-Code. Alle Fehlschläge antworten gleich (`invalid_credentials`); unbekannte Konten rechnen gegen einen Platzhalter-Hash (keine Konto-Enumeration per Antwort oder Zeit).
5. **Sitzungen:**
   - **Web:** Cookie `__Host-lxsid` (`Secure; HttpOnly; SameSite=Strict`, ohne Domain; Token 256 Bit, in der Datenbank nur der Hash). CSRF-Schutz doppelt: ein fremder `Origin` wird abgelehnt, und jede ändernde Anfrage
     braucht `X-CSRF-Token` (aus der Sitzungs-ID abgeleitet). 30 Tage absolut, 7 Tage Leerlauf.
   - **App:** Access-Token (HMAC-signiert, 15 min, prüft zusätzlich die Sitzung in der Datenbank und wirkt nach einem Widerruf daher sofort nicht mehr) + Refresh-Token mit Rotation. Beim Einlösen setzt der Server `used_at` und
     `rotated_to`; ein erneut vorgelegtes Token widerruft die **ganze `token_family`** und schreibt `session_reuse_detected` ins Audit-Log. Das Refresh-Token ist an die Geräte-ID gebunden; die absolute Dauer (90 Tage) bleibt
     bei der Rotation erhalten, im Leerlauf (30 Tage) läuft es ab. Ablage in `flutter_secure_storage` (App, Phase 1b).
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

### App-Teil (Phase 1b)

Code: `app/lib/data/api/` (ApiClient, Endpunkte, DTOs, Token-Ablage), `app/lib/data/auth/auth_state.dart` (Riverpod), `app/lib/features/auth|profile|admin/`.

- **API-Client:** `http` gegen `kApiBase`. Web: HttpOnly-Cookie (gleiche Domain), `X-CSRF-Token` (aus der Sitzungsantwort bzw. `GET /me`) an jeder ändernden Anfrage, nichts in `localStorage`. Android: Access-Token als Bearer, Access- und Refresh-Token in `flutter_secure_storage`; Erneuerung kurz vor Ablauf oder nach einem 401. **Refresh wird serialisiert** (ein Future für alle Aufrufer) und bei unklarem Ausgang (Zeitüberschreitung, Abbruch nach dem Senden) **nicht wiederholt**: Das Token könnte eingelöst sein, und der Server widerruft bei Wiederverwendung die ganze Familie. Die lokale Sitzung wird dann verworfen und die Person meldet sich neu an; nur Fehler vor dem Senden (kein Netz, DNS, Verbindung abgelehnt, TLS) lassen die Token unangetastet. Gerätename, Plattform, Version und die gespeicherte Geräte-ID gehen bei Anmeldung und Registrierung mit.
- **Fehler:** Einheitliche `ApiException` mit fester deutscher Meldung je Fehlercode (nie Servertext oder Systemmeldung). 401 an geschützten Stellen = zurück zur Anmeldung; 429/`too_many_attempts` und 503 `server_busy` zeigen die Wartezeit aus `Retry-After`; `step_up_required` öffnet den Bestätigungsdialog (Passkey, TOTP oder Wiederherstellungscode) und wiederholt die Aktion einmal.
- **Zustand:** `AuthStatus` prüfe / abgemeldet / angemeldet / wartend (Freigabe) / Verbindungsfehler; das Pflicht-Update (`updateProvider`) hat Vorrang. Start: `GET /me`; ohne Netz startet die Android-App mit dem gespeicherten Profil. Abmelden und "Überall abmelden" löschen die Token und rufen den Hook `localDataWiperProvider` (leert die drift-Datenbank, Phase 1c ergänzt die Fachtabellen). Ein Sitzungsverlust von außen (Widerruf) leert die lokalen Daten **nicht** (ungesendete Änderungen); meldet sich danach eine andere Person an, muss Phase 1c bereinigen.
- **Einladung annehmen:** Web: `/#/einladung/<token>` wird in `main()` gelesen und sofort mit `history.replaceState` entfernt (auch bei ungültigem Token und bei späterem `hashchange`). Android: Link einfügen, QR scannen (`mobile_scanner`, nur Android) oder Intent (`https://familie.lx-labs.dev/` mit Fragment). Das Token bleibt im Arbeitsspeicher und geht nur im POST-Body zum Server. Ablauf: prüfen, PIN/Name/E-Mail, Passkey oder Passwort + TOTP (Secret und QR des otpauth-URI), Wiederherstellungscodes (einmalig; ohne Bestätigung "gespeichert" geht es nicht weiter; die Sitzung wird erst danach übernommen), bei `pending` der Warte-Bildschirm.
- **Passkeys:** Paket `passkeys` (Android: Credential Manager, Web: selbst gehostetes `web/passkeys-bundle.js`). Fehler (abgebrochen, kein Support, Google Play-Dienste fehlen, Domain nicht verknüpft) zeigen klare Meldungen mit dem Weg zu Passwort + TOTP. Voraussetzungen auf dem Server: `assetlinks.json` und `WEBAUTHN_ORIGINS` (`deploy/README.md`, Abschnitt 9).
- **Konto und Admin:** Profil/Sicherheit (Passkeys hinzufügen/entfernen, neue Wiederherstellungscodes, Geräteliste mit einzelnem Abmelden), Admin: Mitglieder (Rolle, entfernen, zurücksetzen, freigeben/ablehnen) und Einladungen (erstellen mit Rolle/Gültigkeit/PIN/Freigabe, QR + Link + PIN einmalig, verlängern, widerrufen). Eltern sehen nur die Einladungen für Kinder und Gäste (Rolle aus `/me`; der Server erzwingt es ohnehin).
- **Datenschutz in der App:** keine Token im Log, `FLAG_SECURE` auf Seiten mit Geheimnissen, Zwischenablage nur auf Klick.

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
- **Ende-zu-Ende-Verschlüsselung** ist für Phase 1 bewusst **nicht** vorgesehen: Sie würde Suche,
  Vorschaubilder, Wiederherstellung durch den Admin und Gast-Freigaben stark erschweren. Für den Tresor ist sie
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
  - **Fragment-Token im Client (Phase 1b):** Das Einladungs-Token steht im URL-Fragment; der Client liest es und entfernt es sofort mit `history.replaceState` aus der Adresszeile (Verlauf, Screenshots, Referrer).
- **Löschkonzept (teilweise erledigt):** `audit_log` (IP 7 Tage, Einträge 365 Tage) ist geregelt und wird aufgeräumt; offen bleibt `change_log.changes` (Sync, Phase 1c). Aufbewahrung und Löschung von `audit_log` und `change_log.changes` festlegen (personenbezogene Inhalte in Änderungsprotokollen, IP-Spalte höchstens 7 Tage).
- **Mitgliedschafts-Prüfung bei Schema-Verweisen (teilweise erledigt):** Zusammengesetzte Fremdschlüssel `(family_id, user_id)` auf `memberships` gelten für Sitzungen, Geräte, Tickets, Termin-Teilnehmer, Reaktionen und Lesebestätigungen. Für Verweise mit `ON DELETE SET NULL` (`events.owner_id`, `*.assignee_id`, `messages.sender_id`, `files.uploaded_by`, `change_log.author_id`) geht das nicht (die Familien-Spalte würde mit auf NULL gesetzt); sie prüft der Sync serverseitig (Phase 1c). Ursprünglich: wo Zeilen auf andere Datensätze verweisen (Personen, Listen, Dateien), serverseitig prüfen, dass das Ziel zur selben Familie bzw. Mitgliedschaft gehört, nicht nur per Fremdschlüssel.
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
