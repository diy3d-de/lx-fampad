# Datenschutzerklärung – Entwurf (lx-fampad)

Stand: 18.10.2026 · Status: **Entwurf, keine Rechtsberatung.** Er beschreibt das tatsächliche Verhalten der Software in Phase 0 und 1a (Konten und Anmeldung im Server)
und die in `docs/PROJEKTBESCHREIBUNG.md` festgelegten Phasen 1 bis 3. Vor dem Echtbetrieb mit Dritten (Großeltern, Gäste) von einer
fachkundigen Stelle prüfen lassen. Punkte mit **[Prüfen]** sind offen. Spalte „Stand“: **Ist** = heute umgesetzt (Server), **Geplant** = Phase 1 (App, Sync, Fachbereiche) bis 3.

## 1. Verantwortlicher und Geltungsbereich

- Verantwortlich: **[Name, Anschrift, E-Mail des Betreibers]** (Privatperson, betreibt lx-fampad für die eigene Familie).
- Geltungsbereich: Web-App (`familie.lx-labs.dev`), Android-App, Server, Push-Dienst (`ntfy.familie.lx-labs.dev`).
- **[Prüfen]** Haushaltsausnahme (Art. 2 Abs. 2 lit. c DSGVO): Rein familiäre Nutzung fällt eventuell nicht unter die DSGVO. Sobald
  Personen außerhalb des Haushalts teilnehmen (Großeltern als Gäste) oder der Betreiber die Daten für andere verwaltet, ist vorsorglich so zu
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
| Sicherheitsprotokoll (Audit-Log): Einladung erstellt/benutzt/widerrufen/abgelaufen, PIN-Fehlversuche, Anmeldung (auch fehlgeschlagen), neues Gerät, Rollenänderung, Zurücksetzen, Freigabe/Ablehnung, Wiederherstellungs-Code eingelöst, Wiederverwendung eines Refresh-Tokens, fehlgeschlagene WebSocket-Anmeldung, jeweils mit Zeitpunkt, handelnder Person und IP-Adresse | Missbrauchserkennung, Nachvollziehbarkeit | Ist (Phase 1a); nie Passwörter, Tokens, PINs oder Codes | Art. 6 Abs. 1 lit. f |
| Fehlversuchs-Zähler (`login_attempts`): Schlüssel aus einem HMAC der IP (IPv6: des /64-Präfixes), der E-Mail-Adresse bzw. des Paares aus beidem (keine Klartext-Werte), Anzahl, Zeitpunkte, Sperre | Schutz vor Raten von Passwörtern, Codes und PINs | Ist (Phase 1a) | Art. 6 Abs. 1 lit. f |
| Kurzlebige Anmeldezustände: WebAuthn-Challenges, angefangene Registrierungen (Name, E-Mail, Passwort-Hash und verschlüsseltes TOTP-Geheimnis bis zum Abschluss), WebSocket-Tickets (nur Hash) | Ablauf der Anmeldung | Ist (Phase 1a), Löschung nach wenigen Minuten bzw. 30 Sekunden | Art. 6 Abs. 1 lit. b |
| Inhalte: Termine, Chat-Nachrichten (inkl. Lesebestätigungen, Reaktionen), Listen, Aufgaben, Dateien | eigentliche Funktion | Geplant (Phase 1), Fotos u. a. Phase 2 | Art. 6 Abs. 1 lit. b |
| Standort (Live-Teilen) | Funktion „Standort teilen“ | Geplant (Phase 2) | Art. 6 Abs. 1 lit. a (Einwilligung, Abschnitt 8) |
| Push-Endpunkt je Gerät (UnifiedPush/Web Push), enthält nie Inhalte | Benachrichtigung „es gibt Neues“ | Geplant (Phase 1) | Art. 6 Abs. 1 lit. b, f |

Alle Inhalte liegen in einer PostgreSQL-Datenbank und im Dateisystem des Servers (Dateien später mit AES-256-GCM verschlüsselt).
Eine Ende-zu-Ende-Verschlüsselung gibt es in Phase 1 bewusst nicht; der Betreiber kann als Administrator technisch auf Inhalte zugreifen.

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
  (§ 25 Abs. 2 Nr. 2 TDDDG). Die Web-App legt zudem eine lokale Datenbank im Browser an (OPFS/IndexedDB, Offline-Betrieb); sie bleibt auf dem Gerät und wird mit dem Server abgeglichen.
  Kein Service Worker, keine Tracking-Cookies, kein Local-Storage zu Analysezwecken.
- **Android:** Access-/Refresh-Token, Geräte-ID und das zuletzt bekannte Profil (Name, Rolle, Farbe; für den Start ohne Netz) im Android-Keystore (`flutter_secure_storage`, Phase 1b), lokale SQLite-Datenbank; Datensicherung durch Android ist abgeschaltet (`allowBackup=false`). Beim Abmelden werden Token und lokale Datenbank gelöscht. Im Web wird nichts in `localStorage` abgelegt (nur die Sitzung im HttpOnly-Cookie). Bildschirmfotos sind auf Seiten mit Geheimnissen (TOTP-Schlüssel, Wiederherstellungscodes, Einladungs-PIN) gesperrt; die Zwischenablage wird nur auf ausdrücklichen Klick befüllt.
- **Kamera (Android):** Nur für das Scannen eines Einladungs-QR-Codes, nur solange der Scan-Bildschirm offen ist; die Erkennung läuft auf dem Gerät, Bilder werden weder gespeichert noch übertragen.
- **Einladungslinks:** Das Token steht im Fragment (`#/…`) und wird nicht an den Server gesendet; die Web-App entfernt es sofort aus der Adresszeile (`history.replaceState`) und sendet es nur im Anfragekörper.
- **App-Update (Android):** Die App ruft `familie.lx-labs.dev/releases/android/latest.json` und die APK von der eigenen Domain ab (die Verbindungsdaten aus Abschnitt 4 fallen an);
  das Manifest ist signiert, Prüfung auf dem Gerät. Zusätzlich liest die App `/api/v1/version`. Es werden keine Gerätekennungen übertragen.

## 7. Kinder und Sorgeberechtigte

- Kinderkonten legen die **Sorgeberechtigten** an (Rolle „Kind“, kein Zugriff auf den Tresor). Die Kinder melden sich mit Passkey auf ihrem eigenen Gerät an.
- **[Prüfen]** Ab welchem Alter eine eigene Einwilligung genügt (Art. 8 DSGVO: Einwilligung bei Diensten der Informationsgesellschaft ab 16 Jahren, darunter Zustimmung der Sorgeberechtigten). Da der Dienst nur Familienmitgliedern offensteht und
  nicht an die Öffentlichkeit gerichtet ist, bleibt zu klären, welche Fassung der Einwilligung gewählt wird. Empfehlung: Die Sorgeberechtigten willigen für Kinder unter 16 Jahren schriftlich ein, auch in die Standortfreigabe.
- Eltern können die Konten ihrer Kinder verwalten und Inhalte einsehen, die in gemeinsamen Bereichen liegen; **Standorte** sehen sie nur, wenn das Kind aktiv teilt (Abschnitt 8). Kinder erfahren, was die Eltern sehen können.
- Gäste (z. B. Großeltern) sehen ausschließlich ausdrücklich freigegebene Bereiche und nie Standorte.

## 8. Standort (Phase 2)

- Standort wird **nur von der Person selbst** geteilt; niemand kann ihn einschalten oder anfordern (Eltern können Kindern nur eine Erinnerung schicken).
- Dauer vor dem Start wählbar (15 Minuten, 1 Stunde, 8 Stunden, „bis ich beende“); Beenden jederzeit mit einem Tipp. Solange geteilt wird, zeigt Android eine ständige Benachrichtigung (Vordergrunddienst).
- Beim Beenden löscht der Server die Positionen der Freigabe sofort; laufende Freigaben halten höchstens 2 Stunden Bewegungsspur. Die Ablaufzeit liegt auf dem Server, nicht nur im Gerät.
- Die Freigabe geht an die gesamte Familie oder ausgewählte Mitglieder; Gäste sehen nie Standorte.
- Das Standortrecht „immer“ unter Android wird nur angefordert, wenn jemand teilt. Rechtsgrundlage: Einwilligung (Art. 6 Abs. 1 lit. a, Widerruf jederzeit durch Beenden).
- Kartenkacheln liefert der eigene Server; weder Google noch OpenStreetMap-Server erfahren den Standort.

## 9. Push-Benachrichtigungen

- Meldungen enthalten **nie Inhalt** („Neue Nachricht in Familie“); Details holt die App nach dem Wecken selbst.
- Android: UnifiedPush über die ntfy-App als Verteiler und den eigenen ntfy-Server; der Server merkt sich Meldungen höchstens 12 Stunden (`cache-duration`), schreibt nur auf `up*`-Topics und gibt Leserechte nur an angemeldete Geräte.
- Web: Web Push mit eigenen VAPID-Schlüsseln über den Push-Dienst des Browsers (Abschnitt 5). Das Abonnement ist freiwillig und im Browser widerrufbar.

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
| Chat, Termine, Listen, Dateien | bis zum Löschen durch die Nutzer; gelöschte Einträge bleiben als **Tombstone** (ohne Inhalt) im Änderungsprotokoll, bis alle Geräte sie kennen |
| Standortdaten | nach Ende der Freigabe sofort gelöscht |
| ntfy-Zwischenspeicher | 12 Stunden |
| Backups (restic, verschlüsselt, externes Ziel) | täglich 7, wöchentlich 4, monatlich 6 Stück **[Phase 1]**; gelöschte Daten verschwinden spätestens nach Ablauf der letzten Sicherung |

Löschkonzept (Phase 1 bis 3): Konto löschen (entfernt Anmeldedaten, Geräte, Sitzungen, Wiederherstellungs-Codes; Inhalte werden dem Betreiber zugeordnet oder auf Wunsch gelöscht), Familie löschen
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
