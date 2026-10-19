# Datenschutzerklärung – Entwurf (lx-familyhub)

Stand: 18.10.2026 · Status: **Entwurf, keine Rechtsberatung.** Er beschreibt das tatsächliche Verhalten der Software in Phase 0, 1a (Konten und Anmeldung im Server), 1b (App: Anmeldung, Einladungen, Konto) und 1c-1 (Sync-Kern und Listen)
und die in `docs/PROJEKTBESCHREIBUNG.md` festgelegten Phasen 1 bis 3. Vor dem Echtbetrieb mit Dritten (z. B. Großeltern als Familienmitglieder) von einer
fachkundigen Stelle prüfen lassen. Punkte mit **[Prüfen]** sind offen. Spalte „Stand“: **Ist** = heute umgesetzt (Server, Anmelde-Teil der App), **Geplant** = Phase 1 (App, Sync, Fachbereiche) bis 3.

## 1. Verantwortlicher und Geltungsbereich

- Verantwortlich: **[Name, Anschrift, E-Mail des Betreibers]** (Privatperson, betreibt lx-fampad für die eigene Familie).
- Geltungsbereich: Web-App (`familie.lx-labs.dev`), Android-App, Server, Push-Dienst (`ntfy.familie.lx-labs.dev`).
- **[Prüfen]** Haushaltsausnahme (Art. 2 Abs. 2 lit. c DSGVO): Rein familiäre Nutzung fällt eventuell nicht unter die DSGVO. Sobald
  Personen außerhalb des Haushalts teilnehmen (z. B. Großeltern als eingeladene Familienmitglieder) oder der Betreiber die Daten für andere verwaltet, ist vorsorglich so zu
  handeln, als gelte sie. Dieser Entwurf geht vom vorsichtigen Fall aus.

## 2. Überblick: Was lx-fampad nicht tut

Keine Werbung, keine Tracker, keine Statistik-Dienste, keine KI-Auswertung der Familiendaten, keine öffentlichen Profile, keine
eingebetteten Fremdinhalte (Schriften, Karten und Skripte kommen von der eigenen Domain; die Content-Security-Policy in `deploy/Caddyfile`
verbietet Fremdadressen). Es gibt keinen Service Worker und keine Cookies außer dem Anmelde-Cookie (Abschnitt 6).

## 3. Verarbeitete Daten, Zwecke, Rechtsgrundlagen

| Daten | Zweck | Stand | Rechtsgrundlage (Vorschlag) |
| --- | --- | --- | --- |
| Verbindungsdaten: IP-Adresse, Zeitpunkt, aufgerufener Pfad (ohne Query), Statuscode, Antwortzeit in den **Server-Logs** | Betrieb, Fehlersuche, Missbrauchsabwehr | Ist (Details: Abschnitt 4) | Art. 6 Abs. 1 lit. f (berechtigtes Interesse an sicherem Betrieb) |
| Konto: Name, E-Mail, Farbe, Rolle, Familienzugehörigkeit, Status (aktiv / wartet auf Freigabe) | Anmeldung, Zuordnung der Inhalte | Ist (Phase 1a) | Art. 6 Abs. 1 lit. b bzw. lit. f |
| Anmeldedaten: Passkey (Credential-ID, öffentlicher Schlüssel, Zähler), Passwort (Argon2id-Hash), TOTP-Geheimnis (AES-256-GCM-verschlüsselt, Schlüssel außerhalb der Datenbank), Wiederherstellungs-Codes (nur HMAC-Hash, mit Einlöse-Zeitpunkt) | Anmeldung | Ist (Phase 1a) | Art. 6 Abs. 1 lit. b |
| Einladungen: Rolle, Ersteller, Gültigkeit, Token (nur SHA-256-Hash), optionale PIN (nur HMAC-Hash), Zähler der PIN-Fehlversuche, Zeitpunkte (benutzt, widerrufen, gesperrt) | Aufnahme neuer Mitglieder | Ist (Phase 1a) | Art. 6 Abs. 1 lit. b, f |
| Geräte und Sitzungen: Gerätename (bei Browsern grob aus dem User-Agent, z. B. „Chrome auf Windows“), Plattform, App-Version, Zeitpunkte (angelegt, zuletzt aktiv, abgelaufen, widerrufen), Sitzungs-Token (nur Hash), Anmeldeart | Geräteverwaltung, Abmelden einzelner Geräte | Ist (Phase 1a) | Art. 6 Abs. 1 lit. b, f |
| Sicherheitsprotokoll (Audit-Log): Einladung erstellt/benutzt/widerrufen/abgelaufen, PIN-Fehlversuche, Anmeldung (auch fehlgeschlagen), neues Gerät, Rollenänderung, Zurücksetzen, Freigabe/Ablehnung, Wiederherstellungs-Code eingelöst, E2EE-Schlüssel angelegt/gewechselt, Sicherung abgelegt/abgerufen, Geräte-Übertragung eingelöst (nie Schlüsselmaterial), Wiederverwendung eines Refresh-Tokens, fehlgeschlagene WebSocket-Anmeldung, jeweils mit Zeitpunkt, handelnder Person und IP-Adresse | Missbrauchserkennung, Nachvollziehbarkeit | Ist (Phase 1a); nie Passwörter, Tokens, PINs oder Codes | Art. 6 Abs. 1 lit. f |
| Fehlversuchs-Zähler (`login_attempts`): Schlüssel aus einem HMAC der IP (IPv6: des /64-Präfixes), der E-Mail-Adresse bzw. des Paares aus beidem (keine Klartext-Werte), Anzahl, Zeitpunkte, Sperre | Schutz vor Raten von Passwörtern, Codes und PINs | Ist (Phase 1a) | Art. 6 Abs. 1 lit. f |
| Kurzlebige Anmeldezustände: WebAuthn-Challenges, angefangene Registrierungen (Name, E-Mail, Passwort-Hash und verschlüsseltes TOTP-Geheimnis bis zum Abschluss), WebSocket-Tickets (nur Hash) | Ablauf der Anmeldung | Ist (Phase 1a), Löschung nach wenigen Minuten bzw. 30 Sekunden | Art. 6 Abs. 1 lit. b |
| **Benutzerbild** (freiwillig): entweder die Kennung eines mitgelieferten Platzhalters (Zeichnung, kein Personenbezug über die Wahl hinaus) oder ein **hochgeladenes Foto** der Person (personenbezogene Daten, bei Kindern ggf. besonders schutzwürdig), dazu Art und Änderungszähler; das Foto wird in der App auf höchstens 512 x 512 Pixel zugeschnitten und neu kodiert (EXIF/Standort entfällt), die Originaldatei verlässt das Gerät nicht. Das Bild ist **nutzerweit**: gehört eine Person mehreren Familien an, sehen alle dasselbe Foto | Anzeige der Person in Kopfzeile, Listen, Kalender und Mitgliederliste | **Ist (Phase 1c)**; freiwillig, Rechtsgrundlage Art. 6 Abs. 1 lit. a (Einwilligung durch Hochladen; für Kinder entscheiden die Sorgeberechtigten, Abschnitt 7) bzw. lit. b für die Anzeige der Person in der Familie | Art. 6 Abs. 1 lit. a |
| E2EE-Schlüsselverwaltung: **öffentliche Schlüssel** je Person (`person_keys`: X25519 und Ed25519, Schlüsselversion; `person_key_history`: frühere öffentliche Schlüssel, nur anhängend, zum Prüfen alter Signaturen, Löschung mit dem Konto), eine **verschlüsselte Sicherung** des Personenschlüssels (`key_backups`, nur mit dem Wiederherstellungsschlüssel der Person lesbar), eine **kurzlebige verschlüsselte Übertragung** auf ein neues Gerät (`key_transfers`, 2 Minuten, einmal einlösbar; gespeichert wird nur der Hash der Suchkennung). Der Server speichert nie ein Geheimnis im Klartext | Ende-zu-Ende-Verschlüsselung des Chats, Wiederherstellung und Geräte-Wechsel | Ist (E2EE Phase 1); Löschung mit dem Konto, Übertragungen nach Ablauf (Aufräum-Job) | Art. 6 Abs. 1 lit. b, f |
| Inhalte: **Listen und Einträge** (Listenname, Eintragstext, Zuständigkeit, Zeitpunkt „erledigt“, Freigabe-Stufe, wer die Liste angelegt hat) | eigentliche Funktion | **Ist (Phase 1c-1)** | Art. 6 Abs. 1 lit. b |
| Inhalte: **Chat** (Konversationen mit Art, Name und Teilnehmerliste, Nachrichtentext, Autor, Zeitpunkt, Antwort-Verweis, Lesestand je Person und Chat). Direkt- und Gruppenchats sind nur für ihre Teilnehmer sichtbar, **auch Admins und Eltern können sie in der App nicht lesen**; der Nachrichtentext ist für den Server ein undurchsichtiger Text (keine Auswertung, keine Suche, nicht im Log) | eigentliche Funktion | **Ist (Phase 1c-3a)**; nicht Ende-zu-Ende-verschlüsselt: der Betreiber kann den Inhalt technisch lesen (Abschnitt 3, Schluss), die Verschlüsselung ist vorbereitet | Art. 6 Abs. 1 lit. b |
| Inhalte: Termine, Aufgaben, Dateien (Reaktionen im Chat später) | eigentliche Funktion | Geplant (Phase 1), Fotos u. a. Phase 2 | Art. 6 Abs. 1 lit. b |
| Sync-Protokoll: Änderungsprotokoll (`change_log`: Revision, Art und ID des Datensatzes, geänderte Felder mit Inhalt, Autor, Gerät, Zeitpunkt), verarbeitete Ops (`applied_ops`: op_id, Gerät, Ergebnis, Art und ID des Ziel-Datensatzes, bei Konflikten nur die **Namen** der betroffenen Felder, nie ihre Werte), Gerätestand (`devices.last_rev`, `devices.resync_required`) | Abgleich der Geräte, wiederholbares Senden, Echtzeit | Ist (Phase 1c-1); Aufbewahrung Abschnitt 10 | Art. 6 Abs. 1 lit. b, f |
| Standort (Live-Teilen) | Funktion „Standort teilen“ | Geplant (Phase 2) | Art. 6 Abs. 1 lit. a (Einwilligung, Abschnitt 8) |
| Push-Endpunkt je Gerät (UnifiedPush: nur das zufällige Topic `up…` des eigenen ntfy, Tabelle `push_endpoints`, mit Zeitpunkten des letzten Erfolgs/Fehlers und Fehlerzähler); Web Push später | Benachrichtigung „es gibt Neues“ | **Ist (Branch phase-push, Android)**; Web Push geplant | Art. 6 Abs. 1 lit. b, f |

Alle Inhalte liegen in einer PostgreSQL-Datenbank und im Dateisystem des Servers (Dateien später mit AES-256-GCM verschlüsselt).
Die **Chat-Nachrichten** werden ab Phase 2 Ende-zu-Ende verschlüsselt (Schlüssel nur auf den Geräten der Familienmitglieder, Beschreibung in `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 9a); der Betreiber kann sie dann technisch nicht lesen. Das schützt vor einem Datenleck, dem Hoster und gestohlenen Sicherungen. **Nicht** geschützt sind die Metadaten (wer wann in welcher Konversation schreibt) und alle anderen Inhalte (Kalender, Listen, Aufgaben, Dateien): dort kann der Betreiber als Administrator technisch zugreifen. Ein bösartiger Administrator könnte einer Person einen falschen öffentlichen Schlüssel unterschieben, solange niemand den Sicherheitscode vergleicht.

## 4. Server-Logs und IP-Adressen

- **Was geschrieben wird:** Die API (Fastify/Pino) protokolliert je Anfrage Methode, Pfad **ohne Query-Parameter**, Host, Client-IP
  (aus `X-Forwarded-For` von Caddy), Statuscode und Antwortzeit. `Cookie`- und `Authorization`-Header werden geschwärzt und nie geloggt;
  Tickets und Tokens stehen nie in der URL. Caddy schreibt keine eigenen Zugriffslogs (kein `log`-Block im Caddyfile; **[Prüfen]** der Haupt-Caddyfile von lx-labs setzt kein globales `log`). Caddy schreibt aber sein
  Betriebs- und Fehlerlog ins Journal (Einheit `caddy`); darin können bei Fehlern (z. B. fehlgeschlagene TLS-Verbindungen, Proxy-Fehler) Client-IP-Adressen stehen. Der ntfy-Server,
  systemd und weitere Dienste des Servers (z. B. SSH-Anmeldeversuche) erzeugen Meldungen im selben Journal, ebenfalls mit möglichen IP-Adressen.
- **Wohin:** systemd-journald auf dem Server.
- **Wie lange:** höchstens **7 Tage** (`MaxRetentionSec=7day`, Einrichtung in `deploy/README.md`, Abschnitt „Logs und Datenschutz“).
  Das Journal gilt für alle Dienste des Servers, also auch für andere Projekte auf demselben VPS.
- **Im Arbeitsspeicher:** Begrenzungen (Rate-Limit, Verbindungen je IP) halten IP-Adressen nur flüchtig im Speicher des Prozesses; sie werden
  nicht gespeichert und gehen beim Neustart verloren.
- **Datenbank:** `audit_log.ip` wird höchstens 7 Tage aufbewahrt; ein Aufräum-Job (beim Start des Servers und danach **stündlich**) leert die Spalte. Die Fehlversuchs-Zähler enthalten keine Klartext-IP (nur einen HMAC) und werden gelöscht, sobald ihr Zählfenster (15 Minuten) ohne neuen Fehlversuch abgelaufen und keine Sperre mehr aktiv ist, spätestens bei einem der stündlichen Läufe. Offene WebAuthn-Challenges (auch angefangene Registrierungen mit Passwort-Hash und verschlüsseltem TOTP-Geheimnis) und WebSocket-Tickets werden nach Ablauf ebenfalls stündlich gelöscht.
- **[Prüfen]** Der Hoster (netcup) kann auf Netzwerkebene eigene Verbindungsdaten erfassen (Abschnitt 5).

## 5. Empfänger und Auftragsverarbeiter

| Stelle | Rolle | Was dort ankommt |
| --- | --- | --- |
| **netcup GmbH** (Karlsruhe, Deutschland) | Hosting des VPS (Auftragsverarbeiter) | sämtliche Daten liegen auf dem gemieteten Server; **[Prüfen]** Auftragsverarbeitungsvertrag (AVV) mit netcup abgeschlossen |
| **Cloudflare** | nur DNS (Einträge `familie` und `ntfy.familie`, „DNS only“, kein Proxy) | Namensauflösung; kein Datenverkehr der App läuft über Cloudflare. **[Prüfen]** Hinweis in der Erklärung, Drittlandbezug |
| **Let's Encrypt** | Zertifikate für HTTPS (Caddy holt sie automatisch) | die Domainnamen werden in öffentlichen Zertifikatstransparenz-Logs sichtbar; keine Nutzerdaten |
| **Push-Dienst des Browsers** (Google/Mozilla/Apple) | nur bei **Web Push** im Browser | verschlüsselte Mitteilung ohne Inhalt („Neues in der Familie“); der Browser-Anbieter sieht die Push-Adresse und den Zeitpunkt |
| Google Play Services | nur für Passkeys (Credential Manager) auf Android | lokal auf dem Gerät, keine Übermittlung durch die App **[Prüfen]** |

Eigene Dienste statt Fremddienste: Push läuft über einen **eigenen ntfy-Server** (`ntfy.familie.lx-labs.dev`, UnifiedPush) ohne Firebase und ohne
ntfy.sh; Karten (Phase 2) kommen von der eigenen Domain, nicht von Google oder OpenStreetMap-Servern. Eine Weitergabe an sonstige Dritte findet nicht statt.

## 6. Cookies, lokale Speicherung, Aktualisierung

- **Web:** Nach der Anmeldung ein Session-Cookie `__Host-lxsid` (`HttpOnly; Secure; SameSite=Strict`, ohne Domain); technisch notwendig, daher ohne Einwilligungsabfrage
  (§ 25 Abs. 2 Nr. 2 TDDDG). Die Web-App legt zudem eine lokale Datenbank im Browser an (OPFS, Datei `drift_db/lx_fampad/database`; Offline-Betrieb, geteilt von allen Tabs der Seite); sie enthält dieselben Daten wie auf Android (Listen und Einträge, Ausgang, Sync-Zustand) und bleibt auf dem Gerät. Ein WebSocket zum eigenen Server (`wss://familie.lx-labs.dev/ws`) meldet nur „neue Revision N“, ohne Inhalt.
  Kein Service Worker, keine Tracking-Cookies, kein Local-Storage zu Analysezwecken.
- **Android:** Access-/Refresh-Token, Geräte-ID und das zuletzt bekannte **Profil mit Name, E-Mail-Adresse, Rolle und Farbe** (für den Start ohne Netz) im Android-Keystore (`flutter_secure_storage`, Phase 1b), dazu eine lokale SQLite-Datenbank mit der **Kopie der Familiendaten** (seit Phase 1c: Listen und Einträge), dem **Ausgang** (noch nicht bestätigte Änderungen), dem Sync-Zustand und der zuletzt geladenen Mitgliederliste (nur Name, Farbe, Rolle, keine E-Mail-Adressen). Das Profil enthält also personenbezogene Daten (auch die E-Mail-Adresse); der Keystore schützt sie hardwaregestützt und app-gebunden. Die Datensicherung durch Android ist abgeschaltet (`allowBackup=false`, leere Regeln für Cloud-Backup und Geräte-Übertragung: nichts verlässt das Gerät über Android-Backups). Im Web wird nichts in `localStorage` abgelegt (nur die Sitzung im HttpOnly-Cookie). Bildschirmfotos sind auf Seiten mit Geheimnissen (TOTP-Schlüssel, Wiederherstellungscodes, Einladungs-PIN) gesperrt; die Zwischenablage wird nur auf ausdrücklichen Klick befüllt, Android 13+ wird sie dabei als vertraulich markiert (keine Vorschau).
- **Löschverhalten auf dem Gerät (Android und Web):**
  - **Ausdrückliches Abmelden** (Profil, „Überall abmelden“, Gerät in der Geräteliste entfernen): Token, Profil und lokale Datenbank werden gelöscht. Ist der Server dabei nicht erreichbar, wird trotzdem lokal abgemeldet und die Person darauf hingewiesen: Die Sitzung bleibt dann auf dem Server bis zum Ablauf gültig (in der Geräteliste später beendbar). Im Web wird bei einem Serverfehler **nicht** als abgemeldet angezeigt (das Cookie lässt sich nur über den Server löschen); die Person kann es wiederholen oder bewusst nur lokal abmelden.
  - **Sitzungsverlust** (Sitzung abgelaufen, widerrufen, Erneuerung gescheitert): Token und Profil im Keystore werden gelöscht, die **lokale Datenbank bleibt bewusst erhalten**: Sie kann noch nicht gesendete Änderungen enthalten, die nach einer erneuten Anmeldung derselben Person nicht verloren gehen sollen. Die Datenbank merkt sich die Benutzer-ID ihres Besitzers; **meldet sich eine andere Person an, wird sie vor der Anmeldung vollständig geleert.** Wer das Gerät nach einem Sitzungsverlust weitergibt, sollte sich vorher ausdrücklich abmelden bzw. die App-Daten löschen. **[Prüfen]** Ob diese Abwägung (Datenverlust vermeiden gegenüber Daten bleiben bis zur nächsten Anmeldung) für den Echtbetrieb passt; **Neu bewertet in Phase 1c** (jetzt gibt es einen Ausgang): Die Abwägung bleibt, denn ein Löschen bei Sitzungsverlust würde ungesendete Änderungen vernichten; geschützt ist der Fall „andere Person“ (vorher geleert) und das ausdrückliche Abmelden (leert Listen, Ausgang und Sync-Zustand; ein laufender Abgleich wird vorher angehalten und seine späte Antwort verworfen). Die **Gerätekopie ist nicht verschlüsselt** (SQLite/OPFS bzw. App-Speicher; Android-Backup ist aus).
  - Im Browser wird die lokale Datenbank beim Abmelden geleert (alle Zeilen gelöscht). Die Datei im Browser-Speicher (OPFS) wird dabei **nicht** physisch überschrieben oder entfernt; ein vollständiges Entfernen (`secure_delete`) ist für später vorgemerkt. Wer das Gerät nicht allein nutzt, sollte die Websitedaten im Browser löschen.
- **Benutzerbilder (lokaler Zwischenspeicher):** Die App legt die **Fotos aller Familienmitglieder**, die sie angezeigt hat, in der lokalen Datenbank ab (`sync_meta`, Schlüssel `avatar:<Id>`), damit sie offline sichtbar bleiben. Sie verschwinden mit der lokalen Datenbank beim ausdrücklichen Abmelden oder beim Wechsel der Person; bei **Sitzungsverlust** bleiben sie wie die übrige Datenbank bis dahin erhalten. Wird ein Bild entfernt oder ist es auf dem Server nicht mehr vorhanden, wird die lokale Kopie beim nächsten Abruf bzw. Aktualisieren der Mitgliederliste gelöscht; Kopien entfernter Mitglieder ebenso.
- **Kamera (Android):** Nur für das Scannen eines Einladungs-QR-Codes, nur solange der Scan-Bildschirm offen ist; die Erkennung läuft auf dem Gerät, Bilder werden weder gespeichert noch übertragen.
- **Einladungslinks:** Das Token steht im Fragment (`#/…`) und wird nicht an den Server gesendet; die Web-App entfernt es sofort aus der Adresszeile (`history.replaceState`) und sendet es nur im Anfragekörper.
- **App-Update (Android):** Die App ruft `familie.lx-labs.dev/releases/android/latest.json` und die APK von der eigenen Domain ab (die Verbindungsdaten aus Abschnitt 4 fallen an);
  das Manifest ist signiert, Prüfung auf dem Gerät. Zusätzlich liest die App `/api/v1/version`. Es werden keine Gerätekennungen übertragen.

## 7. Kinder und Sorgeberechtigte

- Kinderkonten legen die **Sorgeberechtigten** an (Rolle „Kind“, kein Zugriff auf den Tresor). Die Kinder melden sich mit Passkey auf ihrem eigenen Gerät an.
- **[Prüfen]** Ab welchem Alter eine eigene Einwilligung genügt (Art. 8 DSGVO: Einwilligung bei Diensten der Informationsgesellschaft ab 16 Jahren, darunter Zustimmung der Sorgeberechtigten). Da der Dienst nur Familienmitgliedern offensteht und
  nicht an die Öffentlichkeit gerichtet ist, bleibt zu klären, welche Fassung der Einwilligung gewählt wird. Empfehlung: Die Sorgeberechtigten willigen für Kinder unter 16 Jahren schriftlich ein, auch in die Standortfreigabe.
- Eltern können die Konten ihrer Kinder verwalten und Inhalte einsehen, die in gemeinsamen Bereichen liegen; **Standorte** sehen sie nur, wenn das Kind aktiv teilt (Abschnitt 8). Kinder erfahren, was die Eltern sehen können.
- Es gibt keine Gast-Rolle: Zugriff haben nur eingeladene Familienmitglieder (Admin, Elternteil, Kind). Was nur für Eltern gedacht ist (Freigabe-Stufe „nur Eltern“), sehen Kinder nicht. Beim Wegfall der Gäste (Migration 0005) wurden vorhandene Gast-Konten samt Geräten, Sitzungen und Zuordnungen gelöscht; im Audit-Protokoll bleibt ein Eintrag je entferntem Konto (ohne E-Mail).

## 8. Standort (Phase 2)

- Standort wird **nur von der Person selbst** geteilt; niemand kann ihn einschalten oder anfordern (Eltern können Kindern nur eine Erinnerung schicken).
- Dauer vor dem Start wählbar (15 Minuten, 1 Stunde, 8 Stunden, „bis ich beende“); Beenden jederzeit mit einem Tipp. Solange geteilt wird, zeigt Android eine ständige Benachrichtigung (Vordergrunddienst).
- Beim Beenden löscht der Server die Positionen der Freigabe sofort; laufende Freigaben halten höchstens 2 Stunden Bewegungsspur. Die Ablaufzeit liegt auf dem Server, nicht nur im Gerät.
- Die Freigabe geht an die gesamte Familie oder ausgewählte Mitglieder.
- Das Standortrecht „immer“ unter Android wird nur angefordert, wenn jemand teilt. Rechtsgrundlage: Einwilligung (Art. 6 Abs. 1 lit. a, Widerruf jederzeit durch Beenden).
- Kartenkacheln liefert der eigene Server; weder Google noch OpenStreetMap-Server erfahren den Standort.

## 9. Push-Benachrichtigungen

- Meldungen enthalten **nie Inhalt** („Neue Nachricht in Familie“); Details holt die App nach dem Wecken selbst.
- **Push-Inhalt ist leer:** Der Wecker besteht aus einem festen Wort ohne Text, Titel, Tags oder Namen; weder Inhalt noch Absender noch Anlass sind erkennbar. Der Familien-Server sendet nur an die **eigene** ntfy-Instanz (Loopback); an die vom Gerät gemeldete Adresse sendet er nie. **Kein Google:** Der eingebettete FCM-Verteiler von UnifiedPush ist nicht eingebunden, die App setzt eine selbst installierte ntfy-App als Verteiler voraus. Empfänger sind nur die Geräte der Familie, deren Rolle die Änderung sehen darf; das auslösende Gerät wird nicht geweckt (die anderen Geräte derselben Person schon; sie zeigen eigene Änderungen nicht an). Beim Abmelden, Entfernen des Geräts oder des Mitglieds wird der Endpunkt gelöscht; ein Endpunkt, den ntfy als ungültig meldet, wird deaktiviert.
- Android: UnifiedPush über die ntfy-App als Verteiler und den eigenen ntfy-Server; der Server merkt sich Meldungen höchstens 12 Stunden (`cache-duration`), schreibt nur auf `up*`-Topics und gibt Leserechte nur an ein **gemeinsames Familien-Konto** (`fampad-family`, nur Lesen auf `up*`, ein gemeinsames Passwort für alle ntfy-Apps der Familie, kein Konto je Person). Wer dieses Passwort kennt, kann die (inhaltslosen) Wecker der Topics lesen, deren zufällige Namen er kennt; senden kann er nichts. Das Passwort wird nach jedem Entfernen eines Mitglieds und bei verlorenem Gerät gewechselt (`einrichtung-ntfy-up.sh --rotate`).
- Web: Web Push mit eigenen VAPID-Schlüsseln über den Push-Dienst des Browsers (Abschnitt 5). Das Abonnement ist freiwillig und im Browser widerrufbar.

### 9a. Lokale Terminerinnerungen (Android)

- Erinnerungen an Termine werden **auf dem Gerät** aus den lokal gespeicherten Terminen berechnet und vom Betriebssystem angezeigt. Es gibt dafür keinen Server-Aufruf, keinen Push-Dienst und keine Weitergabe; die Einstellungen (an/aus, Vorlaufzeit, Sperrbildschirm) liegen nur auf dem Gerät.
- Erinnert wird nur an Termine, bei denen die Person Ersteller oder Teilnehmer ist.
- **Sperrbildschirm:** Standardmäßig sind die Benachrichtigungen als privat gekennzeichnet; auf dem gesperrten Gerät steht dann nur ein neutraler Hinweis, Titel und Ort (die Gesundheits-, Schul- oder Arztangaben enthalten können) erscheinen erst nach dem Entsperren. Wer Titel auf dem Sperrbildschirm sehen möchte, schaltet das in Profil, Erinnerungen ein.
- Die geplanten Benachrichtigungen (Titel, Zeit, Ort) speichert das Android-System in der App-internen Ablage des Geräts. Beim Abmelden, beim Wechsel des Kontos und beim Leeren der lokalen Daten werden sie entfernt; bei bloßem Sitzungsverlust bleiben sie zusammen mit den lokalen Daten bestehen.

## 10. Speicherdauer und Löschung

| Daten | Aufbewahrung |
| --- | --- |
| Server-Logs (journald), Client-IP | 7 Tage |
| `audit_log.ip` | 7 Tage, danach geleert (Aufräum-Job) |
| `audit_log`-Einträge | 365 Tage (Voreinstellung `AUDIT_RETENTION_DAYS`) **[Prüfen: Dauer festlegen]**, danach gelöscht |
| Sitzungen und Geräte | Cookie-Sitzung höchstens 30 Tage (7 Tage Leerlauf), App-Sitzung höchstens 90 Tage (30 Tage Leerlauf); abgelaufene Sitzungen löscht der Aufräum-Job einen Tag nach Ablauf, widerrufene nach 30 Tagen, abgemeldete Geräte nach 30 Tagen |
| Einladungen | 24 Stunden Standard, höchstens 7 Tage gültig, einmalig; nie benutzte, abgelaufene Einladungen werden nach 30 Tagen gelöscht, benutzte bleiben als Nachweis (ohne Token) |
| WebAuthn-Challenges, angefangene Registrierungen | 5 Minuten (gelöscht beim nächsten stündlichen Lauf) |
| WebSocket-Tickets | 30 Sekunden (gelöscht beim nächsten stündlichen Lauf) |
| Fehlversuchs-Zähler | 15 Minuten nach dem letzten Fehlversuch (sofern nicht mehr gesperrt), gelöscht beim nächsten stündlichen Lauf |
| Listen und Einträge (Phase 1c-1), Chat (Phase 1c-3a: Konversationen, Nachrichten, Lesestand), später Termine, Aufgaben, Dateien | bis zum Löschen durch die Nutzer. Beim Löschen werden die **Inhalte sofort überschrieben** und alle Inhalte der zugehörigen `change_log`-Einträge geleert; zurück bleibt ein **Tombstone** ohne Inhalt (ID, Revision, Zeitpunkt), bis alle aktiven Geräte der Familie ihn kennen, **spätestens 90 Tage**; dann wird er samt Protokolleintrag gelöscht. Wird ein Mitglied entfernt, werden Verweise auf es (Zuständigkeit, Besitzer, Autor von Chat-Nachrichten) geleert; es wird aus allen Teilnehmerlisten genommen, seine Direktchats (und Gruppen, die dadurch unter zwei Personen fallen) werden gelöscht, sein Lesestand entfällt. Gelöschte Chat-Nachrichten und Chats werden wie alle Inhalte sofort überschrieben; beim **Bearbeiten** einer Nachricht werden ältere Textfassungen auch aus den Protokolleinträgen entfernt. Wer in eine Gruppe aufgenommen wird, sieht den bisherigen Verlauf (die App weist beim Hinzufügen darauf hin); wer entfernt wird, verliert die Gruppe auf seinen Geräten |
| `change_log` (Sync): Einträge, die nicht mehr den aktuellen Stand ihres Datensatzes zeigen | 90 Tage, dann gelöscht (der aktuelle Stand je Datensatz steht ohnehin in der Fachtabelle) |
| `applied_ops` (verarbeitete Client-Operationen: op_id, Gerät, Ergebnis, Ziel, Namen von Konfliktfeldern) | übernommene 90 Tage, **abgelehnte 7 Tage**, dann gelöscht. Konfliktwerte werden nicht gespeichert (sie könnten sonst Inhalte erhalten, die eine Person inzwischen nicht mehr sehen darf; eine Wiederholung liest den aktuellen Stand und prüft die Rechte neu) |
| Gerätestand `devices.last_rev`, `devices.resync_required` | solange das Gerät angemeldet ist; abgemeldete Geräte zählen für die Tombstone-Bereinigung nicht mehr |
| Benutzerfoto (`user_avatars`) | bis die Person es entfernt oder ersetzt (dabei wird die Zeile sofort gelöscht bzw. überschrieben), ein **Admin kann es zurücksetzen** (Audit-Ereignis `avatar_reset`); mit dem Konto fällt es per Kaskade weg. Auf den Geräten verschwindet die Kopie wie in Abschnitt 6 beschrieben; in Backups bis zum Ablauf der letzten Sicherung |
| Standortdaten | nach Ende der Freigabe sofort gelöscht |
| ntfy-Zwischenspeicher | 12 Stunden |
| Backups (restic, verschlüsselt, externes Ziel) | täglich 7, wöchentlich 4, monatlich 6 Stück **[Phase 1]**; gelöschte Daten verschwinden spätestens nach Ablauf der letzten Sicherung |

Löschkonzept (Phase 1 bis 3; für Sync-Daten seit 1c-1 umgesetzt, siehe die Zeilen oben und `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 6a): Konto löschen (entfernt Anmeldedaten, Geräte, Sitzungen, Wiederherstellungs-Codes; Inhalte werden dem Betreiber zugeordnet oder auf Wunsch gelöscht), Familie löschen
(entfernt alle Daten der Familie per Datenbank-Kaskade), Export aller Daten als ZIP (Auskunft/Übertragbarkeit). Umgesetzt in Phase 1a ist das **Entfernen eines Mitglieds** durch einen Admin (löscht die Mitgliedschaft samt Geräten und Sitzungen und, da der Server genau eine Familie bedient, auch das Konto mit Anmeldedaten und Wiederherstellungs-Codes; offene Einladungen der Person werden widerrufen) sowie das **Ablehnen** wartender Mitglieder. **Audit-Einträge bleiben bis zum Ablauf der Aufbewahrungsfrist (365 Tage) bestehen:** Der Verweis auf das Konto (`actor_id`) wird beim Löschen geleert; in den Einzelheiten der Einträge bleibt die frühere interne Benutzer-ID als **Pseudonym** stehen (keine Namen, keine E-Mail-Adressen, nach 7 Tagen auch keine IP). Das ist nicht „anonymisiert“ im strengen Sinn, solange die Zuordnung über andere Quellen (z. B. Sicherungen) möglich wäre.

## 11. Sicherheitsmaßnahmen (Auszug)

TLS für alle Verbindungen (HSTS); Server in Deutschland **[Prüfen: Standort des netcup-Rechenzentrums und Vertragsunterlagen bestätigen]**; PostgreSQL nur lokal erreichbar; eigener Systembenutzer, gehärteter systemd-Dienst mit Speicher- und Prozessgrenzen; Konfiguration und Geheimnisse nur für root lesbar; strenge
Sicherheits-Header und Content-Security-Policy; Rate-Limits für Anmeldung und Schnittstellen; Origin-Prüfung am WebSocket und bei ändernden Anfragen, CSRF-Token; Passkeys und Argon2id; TOTP-Geheimnisse verschlüsselt (AES-256-GCM); Wiederherstellungs-Codes und PINs nur als HMAC; getrennte Datenbank-Rollen (Migration/Betrieb); Sitzungs-Wiederverwendungs-Erkennung; verzögerte Sperre nach Fehlversuchen; Dateien AES-256-GCM
(Phase 1); signierte App-Updates (Ed25519); Backups verschlüsselt.

## 12. Rechte der Betroffenen

Auskunft (Art. 15), Berichtigung (16), Löschung (17), Einschränkung (18), Datenübertragbarkeit (20), Widerspruch (21), Widerruf einer Einwilligung (7 Abs. 3, z. B. Standort beenden) und Beschwerde bei einer Aufsichtsbehörde (Art. 77).
Anfragen an den Verantwortlichen (Abschnitt 1). **[Prüfen]** zuständige Aufsichtsbehörde eintragen.

## 13. Änderungen

Diese Erklärung wird mit jeder Phase angepasst; die jeweils geltende Fassung steht in der App unter „Einstellungen“ **[Phase 1]**. Offene Punkte vor dem Echtbetrieb: Betreiberangaben (Abschnitt 1), AVV mit netcup,
Einwilligungstexte für Kinder und Standort, Aufbewahrungsdauer des Audit-Logs, Aufsichtsbehörde. Hinweis zu Phase 1a: Ein E-Mail-Hinweis bei neuem Gerät ist noch **nicht** umgesetzt (kein Mail-Versand); sobald er kommt, ist der Mail-Dienst in Abschnitt 5 zu ergänzen.
