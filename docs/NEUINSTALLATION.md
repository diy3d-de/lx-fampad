# Server-Neuinstallation und Wiederherstellung (Schritt für Schritt)

Dieses Handbuch brauchst du, wenn der Server ausgefallen ist, die Platte kaputt ist oder du auf einen anderen Server umziehst. Ein Skript baut den Server auf einem
frischen Debian 13 neu auf: **leer** oder **aus der verschlüsselten Sicherung** (Datenbank und Konfiguration). Das Skript ersetzt keine Entscheidungen und
keine Schritte, die nur du tun kannst (DNS, Firewall, Schlüssel): Sie stehen in Abschnitt 6.

Wer das Skript nur lesen will: `deploy/neuinstallation/bootstrap-server.sh` (Kopf = Bedienungsanleitung, `--hilfe`). Hintergrund und die Handarbeit statt Skript:
[`WIEDERHERSTELLUNG.md`](WIEDERHERSTELLUNG.md). Die Sicherung selbst: [`BACKUP.md`](BACKUP.md).

## 1. Was das Skript macht (und was nicht)

Es arbeitet in **Phasen**, jede endet mit **Prüfpunkten**; bei einem Fehler hält es an und sagt, wo. Es ist **idempotent**: Du kannst es nach einem Abbruch mit demselben Befehl
noch einmal starten, bereits Erledigtes wird erkannt und übersprungen. Vorhandene Konfiguration, Schlüssel und Datenbanken überschreibt es nie ohne ausdrückliche Option.

| Phase | Was passiert |
| --- | --- |
| `pruefen` | nur lesen: Debian 13, Platz, Netz, DNS, Parameter, Sicherung (Prüfsummen), vorhandener Zustand |
| `pakete` | Debian-Pakete (PostgreSQL 17, age, rsync, sqlite3, git …), Node.js 24.21.0 aus NodeSource (Schlüssel-Fingerabdruck und Version fest eingebaut, kein `curl \| bash`); bei einer Wiederherstellung wird hier zuerst geprüft, ob dein Schlüssel zur Sicherung passt |
| `system` | Benutzer `lx` (optional) und `lx-fampad`, Ordner unter `/srv/fampad`, Log-Aufbewahrung 7 Tage, `sudo`-Regel (nur: Dienst neu starten), optional Schlüssel für den GitHub-Release-Upload |
| `code` | Git-Checkout nach `~lx/lx-fampad` mit eigenem Deploy-Key (GitHub-Host-Schlüssel fest eingebaut); **pausiert**, bis du den Deploy-Key bei GitHub eingetragen hast |
| `konfiguration` | leer: `/etc/lx-fampad/env` mit Zufallspasswort; Wiederherstellung (über ein Staging im Arbeitsspeicher, gezielt kopiert): `env`, `migrate.env`, ntfy-Token und -Benutzerdatenbank, `assetlinks.json`, Update-Kanal, Empfänger der Sicherung (`AUTH_SECRET_KEY` kommt zurück; `backup.conf` nicht) |
| `datenbank` | Datenbankrollen (Laufzeit nur lesen/schreiben, Migrationsrolle darf Tabellen ändern), Datenbank, bei Wiederherstellung `pg_restore` als Migrationsrolle über eine Wegwerf-Datenbank, `einrichtung-auth.sh`; danach wird der private Schlüssel aus dem Arbeitsspeicher des Skripts entfernt |
| `anwendung` | (Swap aus `SWAP_MB`, erst jetzt) Server bauen und starten (`deploy.sh`), Migrationen, Wetter-Dienst installieren (gestartet wird er nur auf Wunsch) |
| `ntfy` | ntfy 2.29.0 installieren und härten, Benutzer, Token, Rechte, Eintrag in der `env`; in Wiederholungsläufen startet ntfy nur neu, wenn er nicht läuft oder sich Konfiguration/Härtung geändert haben |
| `caddy` | Caddy 2.11.7 installieren, **nur** Dateien in `/etc/caddy/conf.d/`, `caddy validate` vor jedem Neuladen, Rückfall bei Fehlern; nur wenn DNS stimmt |
| `sicherung` | tägliche verschlüsselte Sicherung des neuen Servers, Abholung durch das NAS (nutzt `einrichtung-backup.sh`) |
| `pruefung` | Abschlussprüfung und die Liste dessen, was du noch tun musst |

**Sicherheitsregeln des Skripts**

- Der **private age-Schlüssel** wird nur von der Eingabe (`--identity-stdin`) oder aus einer von dir genannten **temporären Datei** (`--identity-datei`) gelesen, liegt danach nur im Arbeitsspeicher des Skripts und wird
  nie abgelegt, nie angezeigt und nie als Argument übergeben. Die Sicherung wird nur in Pipes entschlüsselt (`age -d | pg_restore`), nie als Klartextdatei. Mit `--identity-datei-loeschen` wird die Datei sofort nach dem Einlesen überschrieben und gelöscht
  (nur für Dateien unter `/dev/shm`, `/run/lxfampad` oder `/run/user`, ohne `..` und auch nach `realpath` dort, die root gehören und kein Symlink sind). Eine solche Datei soll **nur bis zum Einlesen** existieren.
  Alle Entschlüsselungen liegen in den Phasen `pakete`, `konfiguration` und `datenbank`; am Ende von `datenbank` verwirft das Skript den Schlüssel (`unset`), **bevor** ein Swap angelegt wird.
- **Swap und Schlüssel:** Swap kann Arbeitsspeicher auf die Platte auslagern, auch den Schlüssel. Ist beim Einlesen schon ein Swap aktiv (gelesen wird `/proc/swaps`; ist sie nicht lesbar, gilt Swap als aktiv), bricht das Skript ab: erst `swapoff -a` (und den Swap-Bereich danach neu anlegen/überschreiben),
  oder bewusst mit `--swap-ok` fortfahren. Der Swap aus `SWAP_MB` wird erst in der Phase `anwendung` angelegt. Restrisiko: Ein Absturz oder Speicherabzug des Skripts, solange der Schlüssel noch im Speicher ist.
- **Passwörter** (Datenbank, ntfy) entstehen auf dem Server und stehen nur in root-eigenen Dateien (Modus 600), nie in einer Befehlszeile, einem Log oder diesem Repository. Die Parameterdatei enthält nur Öffentliches; Geheimnisse darin lehnt das Skript ab.
- **Caddy / lx-labs.dev:** Das Haupt-Caddyfile (`/etc/caddy/Caddyfile`) wird nie überschrieben. Es wird nur dann neu angelegt (nur die Zeile `import /etc/caddy/conf.d/*.caddy`), wenn es fehlt oder noch das unveränderte Standard-Caddyfile
  des Pakets ist. Auf einem Server mit lx-labs.dev musst du die Importzeile ggf. selbst ergänzen (das Skript sagt dir genau, wie); danach prüft es, ob lx-labs.dev weiter antwortet.
- **Sicherung als Eingabe: dem Inhalt wird nicht blind vertraut.** Archive und `SHA256SUMS` werden beim ersten Zugriff **einmal** in ein root-eigenes Arbeitsverzeichnis kopiert und nur dort geprüft und benutzt (kein Austausch nach der Prüfung). Entpackt wird nie direkt nach `/`, sondern zuerst in ein **Staging im Arbeitsspeicher**
  (`--no-same-owner --no-same-permissions`); danach kopiert das Skript gezielt (nur reguläre Dateien, feste Modi und Eigentümer): `/etc/lx-fampad` (nur Dateien der obersten Ebene, 600 root), `/srv/fampad/well-known` und `releases/android`, `/var/lib/ntfy` und bei vorhandener Dateiablage `/srv/fampad/files` (jeweils nur wenn sie fehlen).
  Die beiden tar-Archive (Konfiguration, Dateiablage) werden vorher auf Symlinks, Hardlinks, Geräte, absolute und `..`-Pfade geprüft. Alle benutzten Archive müssen in `SHA256SUMS` stehen. **Nicht** aus der Sicherung übernommen werden Caddy-Dateien, ntfy-Konfiguration, Units, sudoers und vor allem **`backup.conf`**
  (root lädt sie später per `source`: sie entsteht nur aus den Parametern `BACKUP_KEEP`, `BACKUP_INCLUDE_APK`, `BACKUP_INCLUDE_FILES`); von `/etc/lx-fampad-backup` kommen nur `recipients.txt` und `recipients-config.txt`, und nur wenn sie fehlen und jede Zeile ein öffentlicher age-Schlüssel (`age1…`) ist.
  `pg_restore` läuft **nicht als Superuser**, sondern als Migrationsrolle (Eigentümerin der Wegwerf-Datenbank) mit `--no-owner --no-acl`; Besitzer und Rechte setzt danach `einrichtung-auth.sh`.
  **Das ist keine vollständige Echtheitsprüfung:** Ein Datenbank-Dump kann SQL enthalten (Funktionen, Trigger), das Daten verändert, und `SHA256SUMS` schützt nur vor Übertragungsfehlern, nicht vor jemandem, der Archiv *und* Prüfsummen austauscht (wer den öffentlichen age-Schlüssel kennt,
  kann ein gültig verschlüsseltes Archiv erzeugen). Siehe „Offener Punkt: Sicherung signieren“ unten.
- Parameterdatei und Sicherungsordner (mit `SHA256SUMS` und allen Archiven) müssen **root gehören und dürfen für Gruppe und Andere nicht schreibbar sein**, sonst bricht das Skript ab (nach dem Kopieren: `chown -R root:root`, `chmod -R go-w`). Die Parameterdatei wird einmal geöffnet und genau diese geöffnete Datei geprüft und gelesen.
- Alle Quellen sind festgelegt: Node.js und Caddy mit Schlüssel-Fingerabdruck und Version, ntfy wie in `einrichtung-ntfy.sh`, GitHub-Host-Schlüssel mit Fingerabdruck (`docs/VERSIONEN.md`). Führt ein Repository die Version nicht mehr, bricht das Skript ab, nennt die verfügbaren Versionen,
  und du wählst bewusst eine neue (`NODE_PKG_VERSION`, `CADDY_PKG_VERSION` in der Parameterdatei, danach `docs/VERSIONEN.md` nachziehen). Es gibt keinen stillen Ersatz.
- **Symlinks:** In Ordnern, die der Benutzer `lx` beschreiben darf (`~lx/.ssh`, `/srv/fampad/web`, `well-known`, `releases` …), legt root nichts an und ändert nichts über einen Symlink hinweg; vorhandene Symlinks in `well-known` und `releases` werden vor dem Entpacken entfernt, ein Symlink als Wurzel bricht ab.
- **Code-Stand:** Das Skript gibt den verwendeten Commit deutlich aus. `GIT_REF` am besten als **Tag oder Commit-ID**; ein Branch ist beweglich (das Skript warnt).

## 2. Das musst du bereit haben

- [ ] **Privater age-Schlüssel** (Passwortmanager oder Ausdruck): nur bei einer Wiederherstellung nötig. Ohne ihn ist keine Sicherung lesbar. Er kommt **nie** in eine Datei auf dem Server.
- [ ] **Sicherungsordner** (zum Beispiel vom NAS, `…/archiv/20261020-033000/`): darin `db-….dump.age`, `config-….tar.age` und `SHA256SUMS`. Die Dateien sind verschlüsselt; du darfst sie bedenkenlos auf den Server kopieren.
- [ ] **Code-Stand** der Sicherung (Tag, z. B. `v0.6.5`): die Datenbank darf nicht neuer sein als der Code. Trage ihn als `GIT_REF` in die Parameterdatei ein.
- [ ] **Parameterdatei:** Kopie von `deploy/neuinstallation/parameter.beispiel`. Wichtig sind `BACKUP_AGE_RECIPIENTS` (öffentliche age-Schlüssel), `BACKUP_NAS_PUBKEY` und `BACKUP_NAS_IP` (damit der neue Server wieder gesichert wird; zusätzlich `BACKUP_KEEP`, `BACKUP_INCLUDE_APK`, `BACKUP_INCLUDE_FILES`, falls dein altes `backup.conf` vom Standard abwich: es wird **nicht** aus der Sicherung übernommen), bei einer leeren Neuinstallation zusätzlich
  `RELEASE_CERT_SHA256` und ggf. die Wetter-Werte. Ohne diese Datei läuft das Skript auch, aber ohne tägliche Sicherung.
- [ ] Zugang zu **netcup** (neuen Server bestellen), **Cloudflare** (DNS), **GitHub** (Deploy-Key eintragen), dem **NAS**.
- [ ] **Nicht auf dem Server und nicht in der Sicherung** (getrennt aufbewahrt und jetzt griffbereit): privater age-Schlüssel, **Android-Keystore**, **Update-Signaturschlüssel** (`UPDATE_SIGNING_KEY`), Netatmo-Zugangsdaten.
- [ ] Einen Tag vorher (nur beim geplanten Umzug): **TTL** der DNS-Einträge `familie` und `ntfy.familie` auf 300 Sekunden senken.

Welche Schlüssel und Geheimnisse es überhaupt gibt, wo sie entstehen, wo sie hingehören und was ohne sie passiert, steht in Abschnitt 2a (Schlüssel-Landkarte).

## 2a. Schlüssel-Landkarte (komplette Neuinstallation ohne Wiederherstellung)

Dieser Abschnitt beantwortet für eine **leere Neuinstallation** (Variante A): Welche Schlüssel und Geheimnisse gibt es, wo entstehen sie, wo gehören sie hin, was passiert ohne sie und in welcher Reihenfolge erzeugst du sie.
Alle Beispielwerte sind Platzhalter (`age1…`, `AA:BB:…`, `tk_…`); echte Werte stehen nie in dieser Datei, nie in der Parameterdatei (sie nimmt nur Öffentliches an) und nie im Chat.

**Drei Grundregeln**

1. **Privat bleibt privat:** Private Schlüssel (age, NAS-SSH, Keystore, Update-Signatur, CI-Upload-SSH) liegen **nie auf dem Server und nie im Repository**. Auf den Server gehen nur die öffentlichen Gegenstücke.
2. **Was das Skript erzeugt, steht nur auf dem Server** (`/etc/lx-fampad/…`, root, Modus 600). Es steckt in der Konfigurationssicherung (`config-*.tar.age`), ist aber nicht an anderer Stelle hinterlegt, bis du es selbst ablegst (Ausnahme `AUTH_SECRET_KEY`: zusätzlich in den Passwortmanager, B3).
3. **Bei einer leeren Neuinstallation ist `AUTH_SECRET_KEY` neu.** Das ist harmlos, solange noch niemand ein Konto hat. Danach ändert er sich nie wieder (B3).

### Tabelle 1: Was du selbst erzeugst (auf PC, NAS oder im Browser)

| Nr | Name | Art | Erzeugt wo und womit | Eingetragen / abgelegt | Folge bei Verlust oder Fehlen | Aufbewahrung |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | **age-Hauptschlüssel** (Sicherung) | privat + öffentlich (`age1…`) | PC: `age-keygen -o lx-fampad-age-haupt.key` (`age-keygen -y <Datei>` zeigt den öffentlichen Teil) | **öffentlich** in der Parameterdatei `BACKUP_AGE_RECIPIENTS` (mehrere mit Komma), daraus `/etc/lx-fampad-backup/recipients.txt`; **privat nirgends hinterlegt** (nur beim Wiederherstellen per `--identity-stdin`) | Ohne **alle** privaten age-Schlüssel ist keine Sicherung lesbar (nicht ersetzbar). Fehlt `BACKUP_AGE_RECIPIENTS` beim Lauf, richtet das Skript die tägliche Sicherung **nicht** ein (Hinweis „OFFEN“) | Passwortmanager **und** Ausdruck im Safe; nie auf Server, in Git, auf die NAS-Freigabe neben die Sicherungen oder per Mail |
| A2 | **age-Ersatzschlüssel** | wie A1 | PC: `age-keygen -o lx-fampad-age-ersatz.key` | öffentlicher Teil als zweiter Eintrag in `BACKUP_AGE_RECIPIENTS` | Verlust eines der beiden Schlüssel ist nicht fatal, solange der andere da ist; **alte Sicherungen bleiben nur mit dem Schlüssel lesbar, mit dem sie verschlüsselt wurden** | an einem **anderen Ort** als A1 (z. B. USB-Stick im Safe bei Verwandten, zweiter Passwortmanager) |
| A3 | **age-Test-Schlüssel** (optional, nur für den Wochentest auf dem NAS) | wie A1 | direkt auf dem NAS: `bash lx-fampad-restoretest.sh --identity <Datei> --keygen` (Datei `0600` unter `/root` des NAS) | öffentlicher Teil als weiterer Eintrag in `BACKUP_AGE_RECIPIENTS`; dann **zusätzlich** `BACKUP_AGE_RECIPIENTS_CONFIG` = nur Haupt- und Ersatzschlüssel, damit der Test-Schlüssel `AUTH_SECRET_KEY` nie lesen kann | nur der automatische Test fällt aus; neu erzeugen und die Empfängerliste neu setzen (Parameterdatei anpassen, `--phase sicherung`) | bleibt auf dem NAS und verlässt es nie |
| A4 | **NAS-SSH-Schlüssel** (Abholen der Sicherung) und **öffentliche IP des NAS** | privat + öffentlich; IP öffentlich | auf dem NAS: `ssh-keygen -t ed25519 -N '' -C 'lx-fampad-backup' -f ~/.ssh/lx-fampad-backup`; IP z. B. `curl -4 -s https://ifconfig.me` im Heimnetz | öffentlicher Teil `BACKUP_NAS_PUBKEY` **und** IP `BACKUP_NAS_IP` (beide nur zusammen) in der Parameterdatei; daraus `~lxbackup/.ssh/authorized_keys` mit `restrict,from="<IP>",command="rrsync -ro /var/backups/lx-fampad"`; der private Teil bleibt auf dem NAS | Ohne beides richtet das Skript die Abholung nicht ein („OFFEN“): der Server hält dann nur seine 3 lokalen Sicherungen. Ändert sich die IP des Anschlusses, schlägt die Abholung fehl: Parameter ändern, `--phase sicherung` wiederholen | privat nur auf dem NAS (Datei ohne `.pub`) |
| A5 | **PC-SSH-Schlüssel** (dein Zugang als Benutzer `lx`) | privat + öffentlich | PC: `ssh-keygen -t ed25519` (Standardbefehl; im Repository nicht beschrieben) | öffentliche Zeile in `LX_SSH_PUBKEY` (wirkt nur mit `--lx-anlegen`), landet in `~lx/.ssh/authorized_keys`; auf dem PC SSH-Alias `lx-labs` für `deploy-web.sh` | Ohne ihn hat ein neu angelegter Benutzer `lx` keinen Schlüssel; du kommst dann nur über den root-Zugang des Anbieters auf den Server. Neuen Schlüssel eintragen | privat nur auf dem PC (Passphrase empfohlen) |
| A6 | **Android-Release-Keystore** mit Alias und Passwörtern | privat (Geheimnis) | PC: `keytool -genkeypair -v -keystore ~/lx-fampad-release.jks -alias lxfampad -keyalg RSA -keysize 4096 -validity 10000`; `base64 -w0 ~/lx-fampad-release.jks` | GitHub-Repository-Secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (nur Job `build`; daraus entsteht erst im Job `app/android/key.properties`, danach gelöscht); lokal nur für Release-Builds `app/android/key.properties` (nicht eingecheckt, der Build bricht ohne sie ab) | **Nicht ersetzbar:** mit einem anderen Schlüssel lässt sich die installierte App nicht mehr aktualisieren (nur Deinstallieren/Neuinstallieren, lokale Daten weg); der Fingerabdruck ändert sich (A7), Passkeys der App und App-Links brauchen dann neue `assetlinks.json` und `WEBAUTHN_ORIGINS` | Datei **und** Passwörter offline sichern (Passwortmanager + Kopie); **bei einer Server-Neuinstallation den vorhandenen Keystore weiterverwenden, nie neu erzeugen** |
| A7 | **Fingerabdruck des Release-Zertifikats** (SHA-256) | öffentlich | `keytool -list -v -keystore ~/lx-fampad-release.jks -alias lxfampad` (Zeile `SHA256:`) oder aus dem Release-Lauf (Schritt „Signatur prüfen, Prüfsumme berechnen“, `apksigner verify --print-certs`) | Parameter `RELEASE_CERT_SHA256` (32 Bytes `AA:BB:…`): das Skript macht daraus `/srv/fampad/well-known/assetlinks.json` und `WEBAUTHN_ORIGINS=android:apk-key-hash:<Base64url>` in der `env` | Fehlt er, meldet das Skript „OFFEN“: Passkeys der Android-App und verifizierte App-Links gehen erst nach Nachtrag (`deploy/README.md`, Abschnitt 9). Ein falscher Wert (z. B. der öffentlich bekannte Debug-Schlüssel) öffnet Passkeys der Domain für fremde Apps: **nur den Release-Fingerabdruck** | kein Geheimnis; in die Betriebsunterlagen |
| A8 | **Update-Signaturschlüssel** (Ed25519, signiert `latest.json`) | privat (PEM) + öffentlich (Base64) | PC, außerhalb des Repositories: `node tools/update-manifest.mjs keygen ~/lx-update-key.pem` (gibt den öffentlichen Schlüssel aus) | **öffentlich** als `kUpdatePublicKey` und `kUpdateKeyId` in `app/lib/constants.dart` (Teil der App; im Repository steht heute ein echter Wert, `kUpdateKeyId = 'fampad-1'`); **privat** als Secret `UPDATE_SIGNING_KEY` **nur in der GitHub-Environment `release`** (manuelle Freigabe) | Server-Neuinstallation: **nicht betroffen**, der Schlüssel gehört zur App und zur CI. Geht der private Schlüssel verloren, kann die App keine Updates mehr annehmen: neuen erzeugen, `constants.dart` ändern, App neu bauen und **von Hand neu installieren** | Passwortmanager/Offline-Kopie; Datei nach dem Hinterlegen vom PC löschen; nie ins Repository (`*.pem` steht in `.gitignore`) |
| A9 | **CI-Upload-SSH-Schlüssel** (optional; Release automatisch auf den Server laden) | privat + öffentlich | PC: `ssh-keygen -t ed25519 -N "" -C lx-fampad-release -f ~/lx-release-deploy` | **öffentlich** `CI_DEPLOY_PUBKEY` (Parameterdatei, wird `authorized_keys` von `lx` mit `restrict,command="rrsync -wo /srv/fampad/releases/android"`); **privat** als Secret `VPS_SSH_KEY` in der Environment `vps-deploy` | Ohne ihn lädst du APK und `latest.json` von Hand hoch (`deploy/README.md`, Abschnitt 10); kein Einfluss auf den Betrieb | privater Teil nur als Secret; lokale Datei nach dem Hinterlegen löschen |
| A10 | **Netatmo-Zugangsdaten** (optional, nur Wetter): `client_id`, `client_secret`, `refresh_token` | Geheimnisse | Browser: `https://dev.netatmo.com` > My apps > Create (Scope `read_station`), „Token generator“ | **nicht** in Datei oder Parameter: nach dem Lauf auf dem Server eintippen (C6). Die öffentlichen Wetter-Werte (`WEATHER_PLACE`, `WEATHER_STATION_MAC`, `WEATHER_BBOX`) stehen in der Parameterdatei | Ohne sie bleibt das Wetter aus oder abgeschaltet (`invalid_grant`): Refresh-Token neu erzeugen, `weather-setup.js` wiederholen | Passwortmanager; nie in Chat, Repository oder Shell-Verlauf; nie auf zwei Systemen gleichzeitig benutzen (Netatmo rotiert das Token) |

### Tabelle 2: Was das Skript auf dem Server selbst erzeugt

| Nr | Name | Art | Erzeugt wo und womit | Eingetragen / abgelegt | Folge bei Verlust oder Fehlen | Aufbewahrung |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | **Datenbank-Passwort der Laufzeitrolle** `lx_fampad` | Geheimnis | Phase `konfiguration`: `openssl rand -base64 24` (Sonderzeichen entfernt), eingesetzt in der Vorlage `server/.env.example` an der Stelle `CHANGE_ME` | `DATABASE_URL` in `/etc/lx-fampad/env` (root:root, 600); Phase `datenbank` setzt es als Rollenpasswort (über stdin) | Gibt es die `env`, bleibt es bestehen. Ohne `env` Passwort der Rolle neu setzen; wirkt nur lokal (127.0.0.1) | nur auf dem Server (Konfigurationssicherung), nie ausgeben |
| B2 | **Deploy-Key des Servers** (nur Lesezugriff auf das GitHub-Repository) | privat + öffentlich | Phase `code`: `ssh-keygen -t ed25519 -N "" -C "lx-fampad-server"` als Benutzer `lx`, Datei `~lx/.ssh/id_ed25519_fampad` | öffentlicher Teil wird bei der **Pause (Exit 10)** angezeigt: bei GitHub unter Settings > Deploy keys **ohne Schreibrecht** eintragen, dann denselben Befehl wiederholen. Der GitHub-Host-Schlüssel ist im Skript per Fingerabdruck fest eingebaut | Ohne Eintrag bleibt das Skript in `code` stehen. Geht er später verloren, scheitert nur der Abruf des Codes: neuen Schlüssel erzeugen, bei GitHub eintragen; den des alten Servers dort entfernen | privat nur auf dem Server |
| B3 | **`AUTH_SECRET_KEY`** (Hauptschlüssel der Anmeldung, 256 Bit) | Geheimnis | Phase `datenbank` über `deploy/einrichtung-auth.sh`: `openssl rand -base64 32`, **nur wenn er fehlt** | `AUTH_SECRET_KEY=` in `/etc/lx-fampad/env`; der Server startet in `production` ohne ihn nicht (mindestens 32 Byte, Platzhalter werden abgelehnt) | **Nie ändern oder verlieren.** Er verschlüsselt die TOTP-Geheimnisse und die Netatmo-Zugangsdaten (über abgeleitete Schlüssel) und sichert per HMAC Einladungs-PINs, Wiederherstellungscodes und die Prüfwerte der Passwort-Anmeldung mit `authKey`. Fehlt er später: TOTP, Codes, PINs, Netatmo-Daten und die `authKey`-Passwort-Anmeldung sind unbrauchbar; Passkeys bleiben nutzbar. Er schützt **nicht** die Chat-Inhalte (Abschnitt „Abgrenzung“) | steckt verschlüsselt in jeder Konfigurationssicherung; zusätzlich **einmal in den Passwortmanager** (`sudo grep '^AUTH_SECRET_KEY=' /etc/lx-fampad/env`), nie im Chat oder Repository |
| B4 | **Passwort der Migrationsrolle** `lx_fampad_migrate` | Geheimnis | Phase `datenbank` über `einrichtung-auth.sh`: `openssl rand -base64 24`, nur wenn die Datei fehlt | `MIGRATION_DATABASE_URL` in `/etc/lx-fampad/migrate.env` (root:root, 600; nur die Migrations-Einheit lädt sie) | Existiert die Rolle, aber die Datei fehlt, bricht `einrichtung-auth.sh` mit Hinweis ab: Passwort der Rolle neu setzen und Datei von Hand anlegen. Der laufende Betrieb braucht sie nur für Migrationen | nur auf dem Server |
| B5 | **ntfy-Benutzer `fampad-server`** und sein **Token** `tk_…` (der Server weckt die Handys) | Geheimnis | Phase `ntfy`: ntfy-CLI (`ntfy user add`, `ntfy token add --label=lx-fampad fampad-server`); das Passwort des Benutzers ist zufällig und wird **nicht gespeichert** (Zugriff nur per Token) | Token in `/etc/lx-fampad/ntfy-token` (root, 600) und als `NTFY_TOKEN` (mit `NTFY_URL=http://127.0.0.1:2586`) in `/etc/lx-fampad/env`; `lx-fampad` wird neu gestartet | Fehlt Token oder `NTFY_URL`, ist **Push still aus**, der Rest läuft. Rotieren: `deploy/README.md`, Abschnitt 7 | nur auf dem Server |
| B6 | **ntfy-Benutzer `fampad-family`** und sein **Passwort** (gemeinsamer Lese-Zugang der Handys auf `up*`) | Geheimnis | Phase `ntfy`: Zufallswert (`head -c 24 /dev/urandom`, Base64) | `/etc/lx-fampad/ntfy-family-password` (root, 600); ansehen mit `sudo less …` (nicht `cat`) | Fehlt die Datei, setzt das Skript ein **neues** Passwort und meldet „OFFEN“: in **allen** ntfy-Apps der Familie neu eintragen | nur auf dem Server; Weitergabe persönlich (nie per Chat) |
| B7 | **`WEBAUTHN_ORIGINS`** und **`assetlinks.json`** | öffentlich (abgeleitet aus A7) | Fingerabdruck wird zu Base64url bzw. in die Vorlage `deploy/assetlinks.json.template` eingesetzt | `/etc/lx-fampad/env` und `/srv/fampad/well-known/assetlinks.json` | siehe A7 | in der Sicherung |
| B8 | **SSH-Host-Schlüssel des Servers** und **TLS-Zertifikate** | Host-Schlüssel privat (Server); Zertifikate automatisch | Host-Schlüssel entstehen bei der Installation des Servers (Debian/Anbieter), nicht durch das Skript. TLS: Caddy holt sie von Let's Encrypt, **erst wenn DNS stimmt** (Phase `caddy`) | Host-Schlüssel: `known_hosts` auf PC und NAS (C3) und Secret `VPS_KNOWN_HOSTS` (C1); Zertifikate verwaltet Caddy | Neuer Server = neuer Host-Schlüssel: PC, NAS und GitHub-Secret müssen ihn neu lernen, sonst schlagen Verbindung, Abholung und Upload fehl (sie prüfen strikt). Zertifikate: Grenzen von Let's Encrypt beachten (Abschnitt 7) | nichts aufzubewahren; beim Eintragen den Fingerabdruck vergleichen |

### Tabelle 3: Was du nach dem Lauf einträgst oder auslöst

| Nr | Was | Wo | Folge bei Fehlen |
| --- | --- | --- | --- |
| C1 | **GitHub-Secrets für den Release-Upload:** `VPS_KNOWN_HOSTS` (Ausgabe von `ssh-keyscan -t ed25519 <IP>`; Fingerabdruck mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` auf dem Server vergleichen), `VPS_HOST`, `VPS_USER` (`lx`), `VPS_SSH_KEY` (privater Teil von A9). Diese vier **nur** in der Environment `vps-deploy`; `ANDROID_*` im Repository, `UPDATE_SIGNING_KEY` nur in `release`. Optional die Variable `UPDATE_MIN_VERSION` (kein Geheimnis) | GitHub > Settings > Secrets and variables > Actions bzw. Environments | Nur der optionale Upload schlägt fehl; Bau und Signatur laufen weiter, hochladen dann von Hand |
| C2 | **Deploy-Key bei GitHub eintragen** (B2) | bei der Pause der Phase `code` | Skript hält an |
| C3 | **NAS lernt den neuen Host-Schlüssel:** `ssh-keygen -R familie.lx-labs.dev -f ~/.ssh/lx-fampad-backup.known_hosts`, dann `ssh-keyscan -t ed25519 familie.lx-labs.dev >> …`, Fingerabdruck vergleichen; Probe: `lx-fampad-pull.sh --dry-run`. Der NAS-Schlüssel (A4) bleibt gültig | auf dem NAS | Abholung bricht mit Alarm ab (strikte Host-Prüfung); der Server hat dann nur seine 3 lokalen Sicherungen |
| C4 | **Ersten Admin anlegen:** `sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --family "<Familienname>" [--pin]`. Ausgabe: **Einladungslink** (Einmaltoken, 7 Tage gültig, in der Datenbank nur als Hash); `--pin` verlangt zusätzlich eine 6-stellige PIN, getrennt weitergeben. Danach Passkey oder Passwort + TOTP einrichten und die Wiederherstellungscodes notieren | Server; Link im Browser | ohne ihn kein Konto. Link abgelaufen: Befehl wiederholen (ersetzt die Einladung); Admin ausgesperrt: `--reset <E-Mail>` |
| C5 | **Betreiber setzen:** `sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/operator.js grant <E-Mail>` | Server | nur die Ansicht „Betrieb“ fehlt |
| C6 | **Netatmo eintragen** (A10): `sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js` (Eingabe unsichtbar, Werte danach nur verschlüsselt in der Datenbank), dann den Wetter-Dienst starten (`--wetter-starten --phase anwendung` oder `sudo systemctl enable --now lx-fampad-weather`) | Server | kein Wetter |
| C7 | **ntfy-Passwort von `fampad-family`** (B6) in die ntfy-App jedes Handys eintragen (UnifiedPush) | Handys | kein Push (Chat-Hinweise); der Abgleich beim Öffnen der App funktioniert weiter |
| C8 | **Sicherung abnehmen:** Wiederherstellungstest mit dem **privaten** age-Schlüssel (A1) auf deinem PC (`deploy/backup/wiederherstellung-test.sh`) mit einer vom NAS geholten Sicherung des neuen Servers | PC | die Sicherung gilt als ungeprüft |

DNS (Cloudflare, `familie` und `ntfy.familie`, DNS only) ist kein Schlüssel, gehört aber vor die Phase `caddy` (Abschnitt 6, Punkt 1).

### Reihenfolge

**Was du VOR dem ersten Lauf erzeugst (PC, NAS, Browser)**

1. **age-Schlüssel** (A1, A2): zwei Paare erzeugen, den privaten Teil in Passwortmanager und Ausdruck legen, die beiden öffentlichen `age1…` notieren.
2. **NAS-SSH-Schlüssel** (A4) auf dem NAS erzeugen; öffentliche Zeile und öffentliche IP des NAS notieren. Optional jetzt oder später der **Test-Schlüssel** (A3).
3. **PC-SSH-Schlüssel** (A5), falls der Benutzer `lx` neu angelegt wird; SSH-Alias `lx-labs` auf die neue IP.
4. **Android-Keystore** (A6): nur beim allerersten Mal erzeugen, sonst den vorhandenen verwenden; daraus den **Fingerabdruck** (A7) lesen.
5. **Update-Signaturschlüssel** (A8): nur beim allerersten Mal bzw. wenn verloren; öffentlicher Teil nach `app/lib/constants.dart`, privater Teil als Secret in `release`.
6. Optional **CI-Upload-Schlüssel** (A9) und **Netatmo-Werte** (A10, nur bereithalten).
7. **Parameterdatei** aus `parameter.beispiel` ausfüllen, nur Öffentliches: `BACKUP_AGE_RECIPIENTS` (A1, A2, ggf. A3), `BACKUP_AGE_RECIPIENTS_CONFIG` (nur A1, A2, falls A3 benutzt wird), `BACKUP_NAS_PUBKEY` + `BACKUP_NAS_IP` (A4), `LX_SSH_PUBKEY` (A5), `RELEASE_CERT_SHA256` (A7), `CI_DEPLOY_PUBKEY` (A9), Wetter-Orts-Werte.
8. **DNS** setzen (Abschnitt 6, Punkt 1) und den Server vorbereiten (Abschnitt 3).

**Was das Skript auf dem Server selbst erzeugt** (in der Reihenfolge der Phasen)

1. `code`: Deploy-Key (B2); **Pause**, bis er bei GitHub eingetragen ist (C2).
2. `konfiguration`: `env` mit Datenbank-Passwort (B1), `WEBAUTHN_ORIGINS` und `assetlinks.json` (B7).
3. `datenbank`: Datenbankrollen, `AUTH_SECRET_KEY` (B3), Passwort der Migrationsrolle (B4).
4. `ntfy`: Token (B5), Familienpasswort (B6), Eintrag in die `env`.
5. `caddy`: TLS-Zertifikate (B8), nur wenn DNS stimmt.
6. `sicherung`: Empfängerlisten (A1 bis A3, nur öffentlich) und NAS-Zugang (A4) einrichten.

**Was du nach dem Lauf einträgst:** C1 bis C8 aus Tabelle 3. Zuerst C3 und C8, damit die Sicherung läuft und geprüft ist; danach C4, damit die Familie Konten bekommt.

### Abgrenzung: Schlüssel der Personen sind keine Serverschlüssel

Der **Personenschlüssel** für die Ende-zu-Ende-Verschlüsselung der Chats entsteht auf dem **Gerät** der Person und liegt nur im Schlüsselspeicher des Geräts (Android Keystore bzw. Browser). Der **Wiederherstellungsschlüssel** (14 Vierergruppen) und, falls `E2EE_PW_BACKUP=true`, die **Passwort-Sicherung** gehören der Person und verschlüsseln nur eine Sicherung ihres Personenschlüssels. Der Server speichert davon nur öffentliche Schlüssel und undurchsichtige Blöcke und kann keinen Schlüssel für jemanden ersetzen; es gibt keinen Nachschlüssel für Admins. Für die Neuinstallation heißt das:

- Du erzeugst und hinterlegst **nichts davon** für die Personen. Jede Person richtet ihren Schlüssel nach der Anmeldung selbst ein und sichert ihn (Profil > Verschlüsselung).
- Bei einer **leeren** Neuinstallation gibt es keine alten Chats, also auch nichts zu entschlüsseln. Bei einer **Wiederherstellung** ändert sich an den Personenschlüsseln nichts (Abschnitt 7).
- `AUTH_SECRET_KEY` (B3) und die age-Schlüssel (A1 bis A3) schützen den **Server und die Sicherung**, nicht die Chat-Inhalte.

### Passkey-Domain (WebAuthn) und Android-App-Links

- **Domain/RP-ID:** `PUBLIC_URL=https://familie.lx-labs.dev` in der `env` (aus `server/.env.example`); die RP-ID ist standardmäßig der Hostname daraus (`WEBAUTHN_RP_ID` ist in der Vorlage auskommentiert). Das ist **kein Schlüssel, aber an die Passkeys gebunden**: Ein Wechsel macht alle Passkeys unbrauchbar. Das Skript prüft `PUBLIC_URL` auf diese Domain.
- **Android:** Passkeys der App brauchen zwei Dinge, beide aus A7: `assetlinks.json` (Beziehungen `get_login_creds` und `handle_all_urls`, Paket `dev.lx_labs.fampad`) und `WEBAUTHN_ORIGINS=android:apk-key-hash:…` in der `env`. Beides trägt das Skript aus `RELEASE_CERT_SHA256` ein; in der Produktion nur der Release-Fingerabdruck.
- Ändert sich der Keystore (A6), ändert sich der Fingerabdruck: `assetlinks.json` und `WEBAUTHN_ORIGINS` müssen nachgezogen werden (`deploy/README.md`, Abschnitt 9).

### Was im Repository nicht oder nur teilweise beschrieben ist

- Erzeugung des **PC-SSH-Schlüssels** (A5) und die SSH-Konfiguration (Alias `lx-labs`): verwiesen wird nur auf das Repository lx-labs; hier fehlt eine eigene Anleitung.
- **Zugänge zu netcup und Cloudflare** und deren Absicherung: keine Anleitung im Repository.
- **Rückmeldung des NAS-Wochentests an den Server** (eigener „Status-Schlüssel“ des NAS): nicht gebaut, nur als offener Punkt „Betrieb Paket 3“ beschrieben (`BACKUP.md`, Abschnitt „Automatischer Wiederherstellungstest“); es gibt dafür noch keinen Schlüssel.
- **Signatur der Sicherung** (eigener Signaturschlüssel, weder auf Server noch NAS): geplant, nicht umgesetzt (Abschnitt 10); diesen Schlüssel gibt es heute nicht.
- **GitHub-Secrets sind nach dem Setzen nicht mehr lesbar:** Das Repository beschreibt keine Ablage der Originale; leg sie selbst im Passwortmanager ab (A6, A8, A9).
- Ob das **ACME-Konto von Caddy** und die Zertifikate gesichert werden, ist nicht beschrieben; sie entstehen bei Bedarf neu (Grenzen von Let's Encrypt beachten).
- Ob zu `kUpdatePublicKey` in `constants.dart` der **private Schlüssel** noch in `UPDATE_SIGNING_KEY` liegt, lässt sich aus dem Repository nicht prüfen; der Release-Lauf prüft es vor dem Signieren (`tools/verify-update-key.mjs`).

## 3. Neuen Server vorbereiten (du)

1. **Server bestellen** (netcup): Debian 13 (trixie), 64 Bit, mindestens 2 GB RAM und 25 GB Platz (mit Karte). Du bekommst eine IP-Adresse und Root-Zugang per SSH.
2. **Firewall** einstellen (netcup-Firewall oder `ufw`): nur die Ports **22, 80 und 443** von außen. Das Skript richtet keine Firewall ein, prüft aber am Ende, dass 4400, 2586 und 5432 nur lokal lauschen.
3. **Skript und Parameterdatei hochladen** (auf deinem PC im Repository):

   ```bash
   scp deploy/neuinstallation/bootstrap-server.sh deploy/neuinstallation/parameter.beispiel root@<NEUE-IP>:/root/
   ```

   Es genügt diese eine Datei; den Rest des Repositories holt das Skript in der Phase `code` selbst. Auf dem Server gehören Skript **und** Parameterdatei root und dürfen nur root schreiben: `chown root:root bootstrap-server.sh neuinstallation.params && chmod 600 neuinstallation.params`.
4. **Auf dem Server** (per `ssh root@<NEUE-IP>`): `apt-get update && apt-get install -y tmux curl ca-certificates iproute2`, dann in `tmux` arbeiten (`tmux new -s neu`; nach einem Verbindungsabbruch mit `tmux attach -t neu` zurück).
5. Parameterdatei ausfüllen: `cp parameter.beispiel neuinstallation.params && nano neuinstallation.params` (nur Zeilen ohne `#` am Anfang zählen).

## 4. Variante A: leere Neuinstallation (neuer Familienserver ohne alte Daten)

```bash
bash bootstrap-server.sh --dry-run --params neuinstallation.params --lx-anlegen     # 1. Trockenlauf: verändert nichts, zeigt PROBLEM-Zeilen
bash bootstrap-server.sh --params neuinstallation.params --lx-anlegen               # 2. echter Lauf
```

- `--lx-anlegen` legt den Benutzer `lx` an, falls es ihn noch nicht gibt (mit `LX_SSH_PUBKEY` aus der Parameterdatei als SSH-Schlüssel). Hast du `lx` schon, lass die Option weg.
- **Pause bei `code`:** Das Skript zeigt einen öffentlichen Schlüssel und endet mit „PAUSE“ (Exit-Code 10). Trage ihn bei GitHub ein (Repository, Settings, Deploy keys, Add deploy key, **ohne** Schreibrecht), und starte **denselben Befehl noch einmal**.
- Am Ende steht, was das Skript als **OFFEN** erkannt hat (zum Beispiel DNS), und die Liste „Das musst du noch selbst tun“ (Abschnitt 6).
- Danach auf dem Server den **ersten Admin** anlegen und den Link einlösen (Passkey/TOTP): `sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --family "<Familienname>"`; Betreiber setzen: `deploy/README.md` Abschnitt 5.

## 5. Variante B: Wiederherstellung nach einem Ausfall

Ziel: derselbe Stand wie zur letzten Sicherung (höchstens ca. 24 Stunden Verlust), mit denselben Konten, Anmeldedaten und Schlüsseln.

1. Abschnitt 3 erledigen. Die **Domain bleibt `familie.lx-labs.dev`**: Das ist die Passkey-Domain (RP-ID); sie darf sich nie ändern. Das Skript lehnt eine Sicherung mit anderer Domain ab.
2. **Sicherung auf den Server kopieren** (vom PC aus; die Dateien sind verschlüsselt): `scp -r /pfad/archiv/20261020-033000 root@<NEUE-IP>:/root/sicherung/`. Danach auf dem Server: `chown -R root:root /root/sicherung && chmod -R go-w /root/sicherung` (das Skript verlangt root-Eigentum und keine Gruppen-/Welt-Schreibrechte; fehlt ein Archiv in `SHA256SUMS`, bricht es ab).
   Läuft auf dem Server schon ein **Swap** (`cat /proc/swaps`), zuerst `swapoff -a` (das Skript bricht sonst vor dem Einlesen des Schlüssels ab, siehe Sicherheitsregeln).
3. In die Parameterdatei den **Code-Stand** eintragen (`GIT_REF=v0.6.5` o. ä.) und die `BACKUP_*`-Werte, damit der neue Server wieder gesichert wird.
4. **Trockenlauf** (der Schlüssel wird dabei nicht gelesen):

   ```bash
   bash bootstrap-server.sh --dry-run --params neuinstallation.params --lx-anlegen \
     --sicherung /root/sicherung/20261020-033000 --identity-stdin
   ```

5. **Echter Lauf.** Der private age-Schlüssel wird beim Start abgefragt: einfügen (die Eingabe bleibt unsichtbar), `Enter`, dann `Strg+D`. Er landet nur im Arbeitsspeicher.

   ```bash
   bash bootstrap-server.sh --params neuinstallation.params --lx-anlegen \
     --sicherung /root/sicherung/20261020-033000 --identity-stdin
   ```

   Alternative (wenn das Einfügen nicht geht): Schlüsseldatei vorübergehend **in den Arbeitsspeicher** legen, `scp ~/lx-fampad-age.key root@<NEUE-IP>:/dev/shm/age.key`, und `--identity-datei /dev/shm/age.key --identity-datei-loeschen` angeben:
   die Datei wird sofort nach dem Einlesen überschrieben und gelöscht. Sie darf **nur bis zum Einlesen** existieren (sie liegt auch in `/dev/shm` im Speicher, den ein Swap auslagern könnte; deshalb nur ohne aktiven Swap). Das Löschen akzeptiert das Skript nur für eine Datei unter `/dev/shm`, `/run/lxfampad` oder `/run/user`, die root gehört und kein Symlink ist.
6. Das Skript prüft **zuerst**, ob Schlüssel und Sicherung zusammenpassen (Prüfsummen, `age`, pg_dump-Kennung, sicheres Archiv), erst danach verändert es etwas. Bei der Pause (`code`) wie in Abschnitt 4 verfahren; **den Schlüssel musst du beim erneuten Start wieder angeben**.
7. Danach: **DNS umstellen** (Abschnitt 6, Punkt 1) und `bash bootstrap-server.sh --params neuinstallation.params --phase caddy,pruefung`. Erst jetzt holt Caddy die Zertifikate (vorher wären sie fehlgeschlagen und hätten die Let's-Encrypt-Grenzen verbraucht).
8. **Prüfen:** Anmeldung mit Passkey, **TOTP-Anmeldung** (beweist, dass `AUTH_SECRET_KEY` stimmt), Listen und Kalender sichtbar, Push-Test, App-Update-Prüfung. Gelöschte Daten (Löschwünsche nach DSGVO!) sind wieder da und müssen erneut gelöscht werden; mehr dazu in `WIEDERHERSTELLUNG.md`, Abschnitt 3 Schritt 16.
9. **Alten Server** (falls er noch irgendwie läuft) erst abschalten, wenn alles läuft. Danach den **Wetter-Dienst** starten (Netatmo erlaubt nur einen Abrufer gleichzeitig): am einfachsten das Skript mit `--wetter-starten --phase anwendung` (wiederholt auch den Bau; schreibt die `sudo`-Regel für den Wetter-Neustart,
   schaltet den Dienst ein und startet ihn neu) oder von Hand `sudo systemctl enable --now lx-fampad-weather`. Ohne `--wetter-starten` schreibt das Skript die Wetter-Regel **nicht** in die `sudo`-Datei (ein Wiederholungslauf fügt sie nicht hinzu und nimmt eine vorhandene nicht weg), und `deploy.sh` startet einen ausgeschalteten,
   gestoppten Wetter-Dienst nie (er wird nur neu gestartet, wenn er läuft oder eingeschaltet ist, wie bisher). Das gesicherte Zugangs-Token kann veraltet sein: dann
   `sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js`.
10. TTL der DNS-Einträge wieder erhöhen.

**Umzug bei laufendem Altserver:** wie Variante B, aber der alte Server bleibt bis zur DNS-Umschaltung in Betrieb. Reihenfolge: neuen Server bis Schritt 6 fertig machen und lokal prüfen (`curl http://127.0.0.1:4400/api/v1/health`);
auf dem alten `sudo systemctl stop lx-fampad` (Schreibstopp) und `sudo systemctl start lx-fampad-backup.service`; die frische Sicherung holen und auf dem neuen **neu einspielen** (`--datenbank-ersetzen --konfiguration-ersetzen`, siehe unten);
DNS umstellen; Schritt 7. Einzelheiten und Rückfall: `WIEDERHERSTELLUNG.md`, Abschnitt 4.

**Optionen, die absichtlich nichts überschreiben**

- Ist die Datenbank `lx_fampad` schon **nicht leer**, überspringt das Skript die Wiederherstellung (so zerstört ein versehentlicher zweiter Lauf nichts). Ersetzen: `--datenbank-ersetzen`; die alte Datenbank wird nur **umbenannt** (`lx_fampad_vor_<Zeit>`) und muss danach von dir gelöscht werden, weil sie Personendaten enthält (`sudo -u postgres psql -c "DROP DATABASE lx_fampad_vor_<Zeit>"`: das Verbot neuer Verbindungen, `ALLOW_CONNECTIONS false`, steht dort absichtlich und hindert das Löschen nicht).
  Die Dienste werden erst gestoppt, wenn die neue Datenbank fertig eingespielt ist; schlägt der Tausch fehl, geht der Name zurück, die Verbindungen werden wieder erlaubt und die Dienste starten wieder (Fehler dabei meldet das Skript als WARNUNG).
- Jeder Teil einer Wiederherstellung gilt für sich und wird **nur ergänzt, wenn er fehlt**: auch bei gleichem `AUTH_SECRET_KEY` (die env bleibt dann) werden fehlende Dateien in `/etc/lx-fampad`, `well-known`, `releases/android`, die ntfy-Benutzerdatenbank und die Dateiablage nachgeholt. Fehlte der ntfy-Benutzer `fampad-family`, obwohl eine Passwortdatei da war, setzt das Skript ein neues Passwort und meldet das als OFFEN (alle Handys neu eintragen).
- Weicht eine vorhandene `/etc/lx-fampad/env` von der Sicherung ab (anderer `AUTH_SECRET_KEY`), bricht das Skript ab. Ersetzen: `--konfiguration-ersetzen` (eine Kopie bleibt als `env.vor-wiederherstellung.<Zeit>`).
- Beide Optionen fragen nach (`ja` eintippen); mit `--yes` ohne Rückfrage.

## 6. Was nur du tun kannst

| # | Schritt | Wann | Wie |
| --- | --- | --- | --- |
| 1 | **DNS** (Cloudflare): A-Einträge `familie` und `ntfy.familie` auf die IP des neuen Servers, **DNS only** (graue Wolke), AAAA nur, wenn der Server IPv6 hat | nach dem Skriptlauf (Wiederherstellung/Umzug) bzw. vorher (leere Neuinstallation) | danach `bash bootstrap-server.sh --params … --phase caddy,pruefung`; `dig +short familie.lx-labs.dev` zeigt zuerst die neue IP |
| 2 | **Firewall:** nur 22, 80, 443; SSH nur mit Schlüssel (Passwort-Login aus) | vor dem ersten Lauf | netcup-Firewall oder `ufw`; Skript prüft und warnt nur |
| 3 | **Deploy-Key bei GitHub** eintragen | bei der Pause in der Phase `code` | öffentlichen Schlüssel aus der Ausgabe kopieren, Deploy key ohne Schreibrecht |
| 4 | **GitHub-Secrets** für den Release-Upload aktualisieren | wenn du den Upload per Actions nutzt | `VPS_KNOWN_HOSTS` = neuer SSH-Host-Schlüssel (`ssh-keyscan -t ed25519 <IP>`, Fingerabdruck mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` auf dem Server vergleichen), ggf. `VPS_HOST`; der Schlüssel aus `CI_DEPLOY_PUBKEY` muss zum Secret `VPS_SSH_KEY` passen |
| 5 | **NAS neu verbinden** | nach dem Lauf | auf dem NAS den neuen Host-Schlüssel eintragen: `ssh-keygen -R familie.lx-labs.dev -f ~/.ssh/lx-fampad-backup.known_hosts`, `ssh-keyscan -t ed25519 familie.lx-labs.dev >> …`, Fingerabdruck vergleichen; der NAS-Schlüssel selbst bleibt gültig, den Zugang auf dem Server hat das Skript aus `BACKUP_NAS_*` wieder angelegt; Probe: `lx-fampad-pull.sh --dry-run` (`BACKUP.md`, Abschnitt 4) |
| 6 | **Web-App hochladen** | nach DNS und Caddy | vom PC `deploy/deploy-web.sh` (SSH-Alias auf den neuen Server) |
| 7 | **APK-Link** `lx-familyhub-latest.apk` neu kopieren (Kopie der neuesten APK im Ordner `/srv/fampad/releases/android`) und `latest.json` prüfen | nach der Wiederherstellung | `deploy/README.md` Abschnitt 9; `latest.json` und die neueste APK kommen aus der Sicherung (wenn `INCLUDE_APK=1`), sonst aus den GitHub-Releases |
| 8 | **Kartendatei** (1,1 GB) neu erzeugen und hochladen | nach der Wiederherstellung | `deploy/README.md` Abschnitt 11 (steht nicht in der Sicherung); bis dahin zeigt die Standort-Seite die Liste |
| 9 | **Fallback-Schriften** nach `/srv/fampad/font-fallback` | nach der Wiederherstellung | `deploy/README.md` Abschnitt 8 (nicht in der Sicherung); ohne sie erscheinen Emoji als Kästchen |
| 10 | **Wetter-Dienst starten**, wenn der alte Server aus ist | Wiederherstellung | `sudo systemctl enable --now lx-fampad-weather`; Netatmo-Token ggf. neu (`weather-setup.js`) |
| 11 | **Neue Sicherung prüfen** (Wiederherstellungstest mit dem privaten Schlüssel auf deinem PC) | am selben Tag | `deploy/backup/wiederherstellung-test.sh --identity … --run-dir …` mit einer **vom NAS geholten** Sicherung des neuen Servers |
| 12 | Leere Neuinstallation: **ersten Admin** anlegen, **Betreiber** setzen, ntfy-App der Familie einrichten | nach dem Skriptlauf | `deploy/README.md` Abschnitte 5 und 7; Passwort von `fampad-family` ansehen mit `sudo less /etc/lx-fampad/ntfy-family-password` (nicht `cat`: das Passwort bliebe im Terminal-Verlauf; nach dem Ansehen `q` und `clear`, bei tmux zusätzlich `tmux clear-history`) |
| 13 | **Alten Server** abschalten/löschen lassen | erst nach mindestens einer Woche stabilem Betrieb | er enthält Konfiguration und Datenbank: vor der Rückgabe Datenträger bereinigen lassen |

## 7. Checkliste: Was geht verloren, was nicht?

| Was | Nach der Wiederherstellung | Hinweis |
| --- | --- | --- |
| Konten, Listen, Kalender, Aufgaben, Chats (verschlüsselt), Reaktionen, Pins, Einstellungen | **bleibt** bis zur letzten Sicherung | Änderungen der letzten bis zu ~24 Stunden fehlen; Geräte mit neuerem Stand holen alles neu (ihr Ausgang bleibt erhalten) |
| Gelöschtes seit der Sicherung | **kommt zurück** | Löschwünsche nach DSGVO erneut ausführen |
| `AUTH_SECRET_KEY` (TOTP-Geheimnisse, Wiederherstellungscodes, Einladungs-PINs) | **bleibt** (steht in der Konfigurationssicherung) | ohne ihn wären TOTP und alle Codes unbrauchbar; nie neu erzeugen, um „es zum Laufen zu bringen“ |
| Passkeys und Passwörter | **bleiben** | die Passkey-Domain `familie.lx-labs.dev` ändert sich nicht |
| Anmelde-Sitzungen der Geräte | **bleiben** gültig | zwischenzeitlich widerrufene Sitzungen sind wieder gültig: bei Verdacht „überall abmelden“ |
| **Chat-Schlüssel (Epochenschlüssel)** | **nicht auf dem Server, nie in der Sicherung** | liegen nur im Arbeitsspeicher der Geräte; der Server hat nur Chiffretext und für jedes Gerät verpackte Schlüssel. Die Geräte lesen weiter wie bisher. Hat jemand **kein** Gerät mehr und keinen Wiederherstellungsschlüssel, sind seine Chats unlesbar: das ist unabhängig von der Serverwiederherstellung |
| **Standort teilen** | **geht verloren** (bewusst) | wird nur im Arbeitsspeicher des Servers gehalten und nie gesichert; nach einem Neustart/Neuaufbau starten alle das Teilen neu |
| ntfy: Benutzer, Rechte, Token, Push-Registrierungen der Geräte | **bleiben** (Benutzerdatenbank + Datenbank) | fehlt die Sicherung der ntfy-Datenbank, legt das Skript neu an: dann in allen ntfy-Apps das Passwort von `fampad-family` neu eintragen |
| **ntfy-Nachrichten-Cache** (12 Stunden) | **geht verloren** | unkritisch: Wecker enthalten nie Inhalt; verpasste Wecker holt die App beim Öffnen per Abgleich nach |
| Wetter-Zugangsdaten (Netatmo) | **bleiben** (verschlüsselt in der Datenbank) | das Refresh-Token kann veraltet sein: dann `weather-setup.js` erneut |
| Web-App-Build, Server-Code | **kommt neu** | `deploy-web.sh` / Skript (`GIT_REF`) |
| APK im Update-Kanal, `latest.json`, `assetlinks.json` | **bleiben** (neueste APK nur bei `INCLUDE_APK=1`) | der stabile Link `lx-familyhub-latest.apk` ist eine Kopie und kommt nicht mit |
| Kartendatei, Fallback-Schriften | **geht verloren** | neu erzeugen/herunterladen (Tabelle in Abschnitt 6) |
| Dateiablage | nur bei `INCLUDE_FILES=1` | wird erst relevant, wenn die Dateiablage genutzt wird |
| Sicherungen auf dem Server (3 Tage) | **gehen verloren** | die Kopien auf dem NAS (14 täglich, 8 wöchentlich, 12 monatlich) bleiben |
| SSH-Host-Schlüssel des Servers | **neu** | PC, NAS und das GitHub-Secret `VPS_KNOWN_HOSTS` müssen den neuen kennen |
| TLS-Zertifikate | **neu** von Let's Encrypt | Grenzen: höchstens 5 Fehlversuche je Stunde und Name, 5 neue Zertifikate je Woche für denselben Namen; bei Fehlern mindestens 1 Stunde warten |
| Haupt-Caddyfile, lx-labs.dev | **nicht Teil dieser Sicherung** | gehört dem Projekt lx-labs |
| Privater age-Schlüssel, Android-Keystore, `UPDATE_SIGNING_KEY` | **nie auf dem Server** | getrennt aufbewahren; ohne den Keystore lässt sich die App nicht mehr aktualisieren |

## 8. Typische Probleme

| Meldung / Problem | Ursache und Maßnahme |
| --- | --- |
| `PROBLEM: …` im Trockenlauf | im echten Lauf wäre das ein Abbruch; beheben (z. B. `--lx-anlegen`, Platz, Netz), Trockenlauf wiederholen |
| `PAUSE: GitHub lässt diesen Server noch nicht lesen` | Deploy-Key bei GitHub eintragen, Befehl wiederholen (Exit-Code 10 ist keine Störung) |
| `Datenbank-Archiv lässt sich mit diesem Schlüssel nicht lesen` | falscher privater Schlüssel (andere Sicherung?) oder beschädigte Datei; nächstältere Sicherung vom NAS nehmen |
| `Prüfsummen stimmen nicht` | Sicherung beschädigt (Übertragung?), erneut kopieren oder ältere nehmen |
| `PUBLIC_URL der Sicherung ist …` | falsche Domain: der Server darf nur `familie.lx-labs.dev` sein (Passkeys) |
| `…existiert und weicht von der Sicherung ab` | auf dem Server liegt schon eine andere Konfiguration; prüfen, dann `--konfiguration-ersetzen` |
| Datenbank „nicht leer, Wiederherstellung übersprungen“ | gewollt (Schutz); zum Ersetzen `--datenbank-ersetzen` |
| `deploy.sh fehlgeschlagen` (Migration) | Code-Stand passt nicht zur Datenbank: `GIT_REF` auf den Stand der Sicherung (oder neuer) setzen; Meldungen: `journalctl -u lx-fampad-migrate -u lx-fampad -n 50` |
| `Haupt-Caddyfile … ist nicht das Standard-Caddyfile` (OFFEN) | auf diesem Server läuft schon Caddy (lx-labs.dev): die eine Zeile `import /etc/caddy/conf.d/*.caddy` selbst am Ende des Haupt-Caddyfiles ergänzen, `caddy validate --config /etc/caddy/Caddyfile`, `systemctl reload caddy`, dann `--phase caddy` |
| `DNS zeigt noch nicht auf diesen Server` (OFFEN) | DNS umstellen, warten, bis `dig +short familie.lx-labs.dev` die neue IP zeigt; dann `--phase caddy,pruefung` |
| Zertifikat fehlt / `antwortet nicht` nach `caddy` | Skript hat zurückgerollt; DNS prüfen, **mindestens 1 Stunde warten**, `journalctl -u caddy -n 50`, wiederholen |
| `Swap ist aktiv … Schlüssel könnte … ausgelagert werden` | `swapoff -a` und neu starten, oder bewusst `--swap-ok`; den Swap legt das Skript erst nach dem Verwerfen des Schlüssels an (`SWAP_MB`) |
| `… muss root gehören …` / `… nicht in SHA256SUMS` | Parameterdatei bzw. Sicherungsordner: `chown -R root:root`, `chmod -R go-w`; fehlt ein Archiv in `SHA256SUMS`, ist die Sicherung unvollständig oder verändert: andere Sicherung nehmen |
| `pg_restore fehlgeschlagen` | läuft als Migrationsrolle ohne Superuser-Rechte (`--no-owner --no-acl`); die Wegwerf-Datenbank wurde gelöscht, `lx_fampad` und alle Dienste sind unverändert. Meldung des Dumps ansehen (z. B. eine Erweiterung, die Superuser-Rechte braucht: dann ist der Dump nicht mit dieser Version vereinbar, bitte melden); in der Wiederholung wird neu eingespielt |
| `SSH erlaubt die Anmeldung mit Passwort` (OFFEN) | in `/etc/ssh/sshd_config` `PasswordAuthentication no` (nur wenn dein Schlüssel-Login funktioniert), `sshd -t`, `systemctl reload ssh`; optional `fail2ban` |
| ntfy wird beim zweiten Lauf nicht neu gestartet | gewollt: ein Wiederholungslauf startet ntfy nur neu, wenn er nicht läuft oder sich Konfiguration/Härtung geändert haben (die Wecker bleiben ungestört) |
| Abbruch irgendwo | Ursache beheben und **denselben Befehl** noch einmal starten (oder `--ab <Phase>`); nichts muss zurückgebaut werden |

## 9. Was getestet ist und was nicht

Getestet (im Debian-13-Container, ohne systemd): `shellcheck` und `bash -n`; die Hilfsfunktionen (Parameterdatei und Rechteprüfung, Caddy-Hauptdatei-Erkennung, DNS-Vergleich, Schlüsselumrechnung, `env`-Bearbeitung, Prüfung und Entschlüsselung von Sicherungsarchiven
einschließlich Symlink-, Hardlink-, `..`-, Falschschlüssel- und SHA256SUMS-Fällen); der Trockenlauf auf einem leeren Server; ein kompletter Lauf **leer** (Pakete, PostgreSQL 17, Node, Datenbankrollen, Bau, Migrationen, ntfy mit Token/Rechten, Sicherung mit Abholpfad) und danach eine **Wiederherstellung**
in einem zweiten frischen Container (Schlüssel über stdin, `pg_restore` als Migrationsrolle, `AUTH_SECRET_KEY` und Datenbank gleich, ntfy-Token gültig, kein Schlüssel auf der Platte, zweiter Lauf ändert nichts und startet ntfy nicht neu, keine Wetter-Regel in `sudo`).
Aufruf: `deploy/neuinstallation/test-docker.sh` (läuft mit `--network none`) und `deploy/neuinstallation/test-integration/test-integration.sh`.
**Isolation der Tests:** Der Integrationstest läuft nur in Docker (Container-Lauf und `systemctl`-Attrappe brechen ohne `/.dockerenv` ab), ruft das Skript immer mit `--ohne-systemd` auf (spricht nie `familie.lx-labs.dev` oder `lx-labs.dev` an; `--dns-pruefung-ueberspringen` gibt es nur zusammen damit)
und nimmt den Code-Stand aus einem Tarball der verfolgten Dateien (`git ls-files`), nicht aus einer Kopie des Arbeitsbaums mit `.git`. Das Netz braucht er nur für die Paketquellen. Hinweis: Ein Container zeigt den Swap des Hosts, deshalb gibt der Test `--swap-ok` an. `--ohne-systemd` bricht mit Exit 2 ab, wenn `/run/systemd/system` existiert (also auf einem echten Server), und `test-bootstrap.sh` bricht ab, wenn `/srv/fampad/server` existiert.

**Nicht getestet** (nur auf einem echten Server prüfbar): echtes systemd (Unit-Härtung, `systemd-analyze verify`, Neustart nach Reboot), Caddy-Reload mit Zertifikaten und Let's Encrypt, DNS-Umschaltung, die Pause beim GitHub-Deploy-Key, die Koexistenz mit lx-labs.dev
(Haupt-Caddyfile `fremd` mit Importzeile), `ufw`, `--wetter-starten`, ein Datenbankdump mit echten Daten und Datenmengen, netcup-spezifisches (Cloud-Init, Snapshots). Vor dem ersten echten Einsatz einmal als Übung mit `--dry-run` auf einem Wegwerf-Server (Abschnitt 3) durchspielen und
das Ergebnis in dein Betriebsbuch eintragen; `WIEDERHERSTELLUNG.md` empfiehlt das ohnehin einmal im Jahr.

## 10. Offener Punkt: Sicherung signieren (nicht gebaut)

Die Echtheit einer Sicherung ist heute nur teilweise gesichert: `age` verschlüsselt mit dem **öffentlichen** Schlüssel, den jeder kennt, der Zugriff auf den Server oder die Konfiguration hat; ein gültig verschlüsseltes Archiv kann deshalb jeder erzeugen, der den öffentlichen Schlüssel besitzt.
`SHA256SUMS` liegt neben den Archiven und schützt nur vor Übertragungsfehlern. Das Skript begrenzt den Schaden (nur erlaubte Pfade, keine Links, `pg_restore` ohne Superuser-Rechte, alle Archive müssen in `SHA256SUMS` stehen), kann aber nicht beweisen, dass der Inhalt echt ist.
**Geplant, aber nicht umgesetzt:** `SHA256SUMS` mit einem **Signaturschlüssel signieren, der nicht auf dem Server und nicht auf dem NAS liegt** (z. B. mit `minisign` oder `ssh-keygen -Y sign`, geprüft mit einem im Skript fest eingebauten öffentlichen Schlüssel). Dann könnte weder ein übernommener Server noch ein übernommenes NAS
eine unterschobene Sicherung als echt ausgeben; die Signatur müsste aber von einer Stelle kommen, die den Server nicht kennt (PC des Betreibers nach dem Abholen), und die Wiederherstellung würde sie vor dem Entpacken prüfen. Bis dahin: Sicherungen aus dem NAS-Archiv nehmen (mit Snapshots, `BACKUP.md`) und den
Wiederherstellungstest regelmäßig mit einer NAS-Sicherung machen.

## 11. Dateien

- `deploy/neuinstallation/bootstrap-server.sh` – das Skript (Kopf: Bedienungsanleitung)
- `deploy/neuinstallation/parameter.beispiel` – Vorlage der Parameterdatei (nur Öffentliches)
- `deploy/neuinstallation/test-bootstrap.sh`, `test-docker.sh`, `test-integration/` – Tests (Docker nötig; verändern nichts am eigenen Rechner)
- Gebrauchte Bausteine (unverändert): `deploy/einrichtung-auth.sh`, `einrichtung-swap.sh`, `backup/einrichtung-status.sh`, `backup/einrichtung-backup.sh`, `deploy.sh` (neu: `DEPLOY_OHNE_PULL=1` lässt den festgelegten Code-Stand stehen), `Caddyfile`, `ntfy/`, `lx-fampad*.service`
