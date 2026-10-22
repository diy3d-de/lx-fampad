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
| `konfiguration` | leer: `/etc/lx-fampad/env` mit Zufallspasswort; Wiederherstellung: `env`, `migrate.env`, ntfy-Token und -Benutzerdatenbank, `assetlinks.json` aus der Sicherung (`AUTH_SECRET_KEY` kommt zurück) |
| `datenbank` | Datenbankrollen (Laufzeit nur lesen/schreiben, Migrationsrolle darf Tabellen ändern), Datenbank, bei Wiederherstellung `pg_restore` als Migrationsrolle über eine Wegwerf-Datenbank, `einrichtung-auth.sh`; danach wird der private Schlüssel aus dem Arbeitsspeicher des Skripts entfernt |
| `anwendung` | (Swap aus `SWAP_MB`, erst jetzt) Server bauen und starten (`deploy.sh`), Migrationen, Wetter-Dienst installieren (gestartet wird er nur auf Wunsch) |
| `ntfy` | ntfy 2.29.0 installieren und härten, Benutzer, Token, Rechte, Eintrag in der `env`; in Wiederholungsläufen startet ntfy nur neu, wenn er nicht läuft oder sich Konfiguration/Härtung geändert haben |
| `caddy` | Caddy 2.11.7 installieren, **nur** Dateien in `/etc/caddy/conf.d/`, `caddy validate` vor jedem Neuladen, Rückfall bei Fehlern; nur wenn DNS stimmt |
| `sicherung` | tägliche verschlüsselte Sicherung des neuen Servers, Abholung durch das NAS (nutzt `einrichtung-backup.sh`) |
| `pruefung` | Abschlussprüfung und die Liste dessen, was du noch tun musst |

**Sicherheitsregeln des Skripts**

- Der **private age-Schlüssel** wird nur von der Eingabe (`--identity-stdin`) oder aus einer von dir genannten **temporären Datei** (`--identity-datei`) gelesen, liegt danach nur im Arbeitsspeicher des Skripts und wird
  nie abgelegt, nie angezeigt und nie als Argument übergeben. Die Sicherung wird nur in Pipes entschlüsselt (`age -d | pg_restore`), nie als Klartextdatei. Mit `--identity-datei-loeschen` wird die Datei sofort nach dem Einlesen überschrieben und gelöscht
  (nur für Dateien unter `/dev/shm` oder `/run`, die root gehören und kein Symlink sind). Eine solche Datei soll **nur bis zum Einlesen** existieren.
  Alle Entschlüsselungen liegen in den Phasen `pakete`, `konfiguration` und `datenbank`; am Ende von `datenbank` verwirft das Skript den Schlüssel (`unset`), **bevor** ein Swap angelegt wird.
- **Swap und Schlüssel:** Swap kann Arbeitsspeicher auf die Platte auslagern, auch den Schlüssel. Ist beim Einlesen schon ein Swap aktiv (`swapon --show`), bricht das Skript ab: erst `swapoff -a` (und den Swap-Bereich danach neu anlegen/überschreiben),
  oder bewusst mit `--swap-ok` fortfahren. Der Swap aus `SWAP_MB` wird erst in der Phase `anwendung` angelegt. Restrisiko: Ein Absturz oder Speicherabzug des Skripts, solange der Schlüssel noch im Speicher ist.
- **Passwörter** (Datenbank, ntfy) entstehen auf dem Server und stehen nur in root-eigenen Dateien (Modus 600), nie in einer Befehlszeile, einem Log oder diesem Repository. Die Parameterdatei enthält nur Öffentliches; Geheimnisse darin lehnt das Skript ab.
- **Caddy / lx-labs.dev:** Das Haupt-Caddyfile (`/etc/caddy/Caddyfile`) wird nie überschrieben. Es wird nur dann neu angelegt (nur die Zeile `import /etc/caddy/conf.d/*.caddy`), wenn es fehlt oder noch das unveränderte Standard-Caddyfile
  des Pakets ist. Auf einem Server mit lx-labs.dev musst du die Importzeile ggf. selbst ergänzen (das Skript sagt dir genau, wie); danach prüft es, ob lx-labs.dev weiter antwortet.
- **Sicherung als Eingabe:** Es wird nur an erlaubten Pfaden entpackt (`/etc/lx-fampad`, `/etc/lx-fampad-backup`, `/srv/fampad/well-known`, `/srv/fampad/releases/android`, `/var/lib/ntfy`, bei vorhandener Dateiablage `/srv/fampad/files`); beide tar-Archive
  (Konfiguration, Dateiablage) werden vorher auf Symlinks, Hardlinks, Geräte, absolute und `..`-Pfade geprüft und mit `--no-same-owner` entpackt. Alle benutzten Archive müssen in `SHA256SUMS` stehen. `pg_restore` läuft **nicht als Superuser**,
  sondern als Migrationsrolle (Eigentümerin der Wegwerf-Datenbank) mit `--no-owner --no-acl`; Besitzer und Rechte setzt danach `einrichtung-auth.sh`.
  **Das ist keine vollständige Echtheitsprüfung:** Ein Datenbank-Dump kann SQL enthalten (Funktionen, Trigger), das Daten verändert, und `SHA256SUMS` schützt nur vor Übertragungsfehlern, nicht vor jemandem, der Archiv *und* Prüfsummen austauscht (wer den öffentlichen age-Schlüssel kennt,
  kann ein gültig verschlüsseltes Archiv erzeugen). Siehe „Offener Punkt: Sicherung signieren“ unten.
- Parameterdatei und Sicherungsordner (mit `SHA256SUMS` und allen Archiven) müssen **root gehören und dürfen für Gruppe und Andere nicht schreibbar sein**, sonst bricht das Skript ab (nach dem Kopieren: `chown -R root:root`, `chmod -R go-w`).
- Alle Quellen sind festgelegt: Node.js und Caddy mit Schlüssel-Fingerabdruck und Version, ntfy wie in `einrichtung-ntfy.sh`, GitHub-Host-Schlüssel mit Fingerabdruck (`docs/VERSIONEN.md`). Führt ein Repository die Version nicht mehr, bricht das Skript ab, nennt die verfügbaren Versionen,
  und du wählst bewusst eine neue (`NODE_PKG_VERSION`, `CADDY_PKG_VERSION` in der Parameterdatei, danach `docs/VERSIONEN.md` nachziehen). Es gibt keinen stillen Ersatz.
- **Symlinks:** In Ordnern, die der Benutzer `lx` beschreiben darf (`~lx/.ssh`, `/srv/fampad/web`, `well-known`, `releases` …), legt root nichts an und ändert nichts über einen Symlink hinweg; vorhandene Symlinks in `well-known` und `releases` werden vor dem Entpacken entfernt, ein Symlink als Wurzel bricht ab.
- **Code-Stand:** Das Skript gibt den verwendeten Commit deutlich aus. `GIT_REF` am besten als **Tag oder Commit-ID**; ein Branch ist beweglich (das Skript warnt).

## 2. Das musst du bereit haben

- [ ] **Privater age-Schlüssel** (Passwortmanager oder Ausdruck): nur bei einer Wiederherstellung nötig. Ohne ihn ist keine Sicherung lesbar. Er kommt **nie** in eine Datei auf dem Server.
- [ ] **Sicherungsordner** (zum Beispiel vom NAS, `…/archiv/20261020-033000/`): darin `db-….dump.age`, `config-….tar.age` und `SHA256SUMS`. Die Dateien sind verschlüsselt; du darfst sie bedenkenlos auf den Server kopieren.
- [ ] **Code-Stand** der Sicherung (Tag, z. B. `v0.6.5`): die Datenbank darf nicht neuer sein als der Code. Trage ihn als `GIT_REF` in die Parameterdatei ein.
- [ ] **Parameterdatei:** Kopie von `deploy/neuinstallation/parameter.beispiel`. Wichtig sind `BACKUP_AGE_RECIPIENTS` (öffentliche age-Schlüssel), `BACKUP_NAS_PUBKEY` und `BACKUP_NAS_IP` (damit der neue Server wieder gesichert wird), bei einer leeren Neuinstallation zusätzlich
  `RELEASE_CERT_SHA256` und ggf. die Wetter-Werte. Ohne diese Datei läuft das Skript auch, aber ohne tägliche Sicherung.
- [ ] Zugang zu **netcup** (neuen Server bestellen), **Cloudflare** (DNS), **GitHub** (Deploy-Key eintragen), dem **NAS**.
- [ ] **Nicht auf dem Server und nicht in der Sicherung** (getrennt aufbewahrt und jetzt griffbereit): privater age-Schlüssel, **Android-Keystore**, **Update-Signaturschlüssel** (`UPDATE_SIGNING_KEY`), Netatmo-Zugangsdaten.
- [ ] Einen Tag vorher (nur beim geplanten Umzug): **TTL** der DNS-Einträge `familie` und `ntfy.familie` auf 300 Sekunden senken.

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
   Läuft auf dem Server schon ein **Swap** (`swapon --show`), zuerst `swapoff -a` (das Skript bricht sonst vor dem Einlesen des Schlüssels ab, siehe Sicherheitsregeln).
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
   die Datei wird sofort nach dem Einlesen überschrieben und gelöscht. Sie darf **nur bis zum Einlesen** existieren (sie liegt auch in `/dev/shm` im Speicher, den ein Swap auslagern könnte; deshalb nur ohne aktiven Swap). Das Löschen akzeptiert das Skript nur für eine Datei unter `/dev/shm` oder `/run`, die root gehört und kein Symlink ist.
6. Das Skript prüft **zuerst**, ob Schlüssel und Sicherung zusammenpassen (Prüfsummen, `age`, pg_dump-Kennung, sicheres Archiv), erst danach verändert es etwas. Bei der Pause (`code`) wie in Abschnitt 4 verfahren; **den Schlüssel musst du beim erneuten Start wieder angeben**.
7. Danach: **DNS umstellen** (Abschnitt 6, Punkt 1) und `bash bootstrap-server.sh --params neuinstallation.params --phase caddy,pruefung`. Erst jetzt holt Caddy die Zertifikate (vorher wären sie fehlgeschlagen und hätten die Let's-Encrypt-Grenzen verbraucht).
8. **Prüfen:** Anmeldung mit Passkey, **TOTP-Anmeldung** (beweist, dass `AUTH_SECRET_KEY` stimmt), Listen und Kalender sichtbar, Push-Test, App-Update-Prüfung. Gelöschte Daten (Löschwünsche nach DSGVO!) sind wieder da und müssen erneut gelöscht werden; mehr dazu in `WIEDERHERSTELLUNG.md`, Abschnitt 3 Schritt 16.
9. **Alten Server** (falls er noch irgendwie läuft) erst abschalten, wenn alles läuft. Danach den **Wetter-Dienst** starten (Netatmo erlaubt nur einen Abrufer gleichzeitig): am einfachsten das Skript mit `--wetter-starten --phase anwendung` (wiederholt auch den Bau; schreibt die `sudo`-Regel für den Wetter-Neustart
   und startet den Dienst) oder von Hand `sudo systemctl enable --now lx-fampad-weather`. Ohne `--wetter-starten` schreibt das Skript die Wetter-Regel **nicht** in die `sudo`-Datei (ein Wiederholungslauf fügt sie nicht hinzu und nimmt eine vorhandene nicht weg), und `deploy.sh` startet einen gestoppten Wetter-Dienst nie
   (er wird nur neu gestartet, wenn er schon läuft). Das gesicherte Zugangs-Token kann veraltet sein: dann
   `sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js`.
10. TTL der DNS-Einträge wieder erhöhen.

**Umzug bei laufendem Altserver:** wie Variante B, aber der alte Server bleibt bis zur DNS-Umschaltung in Betrieb. Reihenfolge: neuen Server bis Schritt 6 fertig machen und lokal prüfen (`curl http://127.0.0.1:4400/api/v1/health`);
auf dem alten `sudo systemctl stop lx-fampad` (Schreibstopp) und `sudo systemctl start lx-fampad-backup.service`; die frische Sicherung holen und auf dem neuen **neu einspielen** (`--datenbank-ersetzen --konfiguration-ersetzen`, siehe unten);
DNS umstellen; Schritt 7. Einzelheiten und Rückfall: `WIEDERHERSTELLUNG.md`, Abschnitt 4.

**Optionen, die absichtlich nichts überschreiben**

- Ist die Datenbank `lx_fampad` schon **nicht leer**, überspringt das Skript die Wiederherstellung (so zerstört ein versehentlicher zweiter Lauf nichts). Ersetzen: `--datenbank-ersetzen`; die alte Datenbank wird nur **umbenannt** (`lx_fampad_vor_<Zeit>`) und muss danach von dir gelöscht werden, weil sie Personendaten enthält.
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
und nimmt den Code-Stand aus einem Tarball der verfolgten Dateien (`git ls-files`), nicht aus einer Kopie des Arbeitsbaums mit `.git`. Das Netz braucht er nur für die Paketquellen. Hinweis: Ein Container zeigt den Swap des Hosts, deshalb gibt der Test `--swap-ok` an.

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
