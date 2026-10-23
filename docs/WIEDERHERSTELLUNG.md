# Wiederherstellung und Umzug von lx-fampad

Handbuch für den Ernstfall (Server verloren, Platte defekt, Umzug auf einen größeren Tarif oder anderen Server) und für den regelmäßigen Test.
Die Sicherung beschreibt [`BACKUP.md`](BACKUP.md). Auf dem Server wird erst gearbeitet, wenn du es ausdrücklich willst; die Befehle führst du selbst aus.

**Du brauchst:** den privaten age-Schlüssel (Passwortmanager/Ausdruck), eine Sicherung (vom NAS oder `/var/backups/lx-fampad` des Servers), Zugang zu
DNS (Cloudflare) und zum Server-Anbieter (netcup). Ohne den privaten age-Schlüssel ist keine Sicherung lesbar.

## 1. Was liegt wo, was muss gesichert sein

| Was | Wo (Server) | Gesichert? | Ersatz, wenn verloren |
| --- | --- | --- | --- |
| Datenbank `lx_fampad` | PostgreSQL 17 | ja, `db-*.dump.age` | nicht ersetzbar |
| **`AUTH_SECRET_KEY`** und übrige Konfiguration | `/etc/lx-fampad/env` | ja, `config-*.tar.age` (+ Passwortmanager) | nicht ersetzbar: ohne ihn sind TOTP-Geheimnisse (AES-GCM) und alle HMACs (Einladungs-PINs, Wiederherstellungs-Codes) unbrauchbar; Passkeys und Passwörter bleiben nutzbar |
| `migrate.env`, `ntfy-token`, `ntfy-family-password` | `/etc/lx-fampad/` | ja | Passwörter/Token neu erzeugbar (siehe unten) |
| Caddy-Dateien des Projekts | `/etc/caddy/conf.d/{fampad,ntfy}.caddy` | ja | aus `deploy/` des Repositories neu erzeugbar (`einrichtung-2.sh`, `einrichtung-ntfy.sh`) |
| Haupt-Caddyfile | `/etc/caddy/Caddyfile` | **nein** (kann Geheimnisse von lx-labs enthalten) | **gehört lx-labs.dev**: aus dem lx-labs-Repository, nie aus dieser Sicherung zurückspielen |
| ntfy: Benutzer, Zugriffsrechte, Token | `/var/lib/ntfy/user.db`, `/etc/ntfy/server.yml` | ja | neu anlegbar, aber alle Handys müssten ihre ntfy-Anmeldung neu einrichten |
| systemd-Units, sudoers, journald-Begrenzung | `/etc/systemd/system/lx-fampad*`, `/etc/sudoers.d/lx-fampad` | ja | aus `deploy/` neu erzeugbar |
| Android-Update-Kanal | `/srv/fampad/releases/android` | `latest.json` + neueste APK | aus GitHub Releases neu erzeugbar |
| `assetlinks.json` | `/srv/fampad/well-known` | ja | aus `deploy/assetlinks.json.template` |
| Web-App, Server-Code, Schriften | `/srv/fampad/{web,server,font-fallback}` | nein | `deploy-web.sh` bzw. `deploy.sh` |
| Dateiablage | `/srv/fampad/files` | nur mit `INCLUDE_FILES=1` | nicht ersetzbar, sobald genutzt |
| NAS-Rückkanal („Status vom NAS“): Benutzer `lxnasstatus`, Befehl `/usr/local/sbin/lx-fampad-nasstatus-empfang`, Ordner `/var/lib/lx-fampad-nasstatus` | `/var/lib/lxnasstatus`, `/usr/local/sbin`, `/var/lib/lx-fampad-nasstatus` | **nein** | `deploy/backup/einrichtung-nasstatus.sh` (mit dem **zweiten** öffentlichen SSH-Schlüssel des NAS, `~/.ssh/lx-fampad-status.pub`, und der NAS-IP); ohne ihn fehlen nur die Anzeige und die Warnungen „NAS“ in „Betrieb“ |
| Update-Signaturschlüssel (Ed25519), Android-Keystore | beim Entwickler / GitHub Secrets | **nicht Teil dieser Sicherung** | getrennt sichern (`tools/README.md`, `deploy/README.md` Abschnitt 10): geht der Keystore verloren, lässt sich die App nicht mehr aktualisieren |
| lx-labs.dev | eigenes Projekt | nein | eigenes Deploy/Backup von lx-labs |

## 2. Wiederherstellungstest (halbjährlich, ohne Risiko)

Bevorzugt **auf deinem eigenen Rechner mit einem eigenen, lokalen PostgreSQL** (nicht im Produktivcluster, nicht in einem geteilten Cluster): die Wegwerf-Datenbank enthält alle personenbezogenen Daten im Klartext, ebenso eine mit `--keep` stehen gelassene. Das Rollen-Skript `globals.sql` im Konfigurationsarchiv gehört nicht in den Test.

Prüft: Schlüssel passt, Sicherung ist unbeschädigt, Datenbank lässt sich einspielen, `AUTH_SECRET_KEY` ist enthalten. Fasst Produktivdaten nie an.

```bash
# Auf dem eigenen Rechner (PostgreSQL 17-Client und -Server lokal, age installiert), Sicherung vom NAS:
deploy/backup/wiederherstellung-test.sh --identity ~/lx-fampad-age.key --run-dir /pfad/archiv/20261020-013000
# Variante auf dem Server (nur wenn kein lokales PostgreSQL da ist; Schlüssel nur vorübergehend übertragen und danach löschen):
sudo bash deploy/backup/wiederherstellung-test.sh --identity /dev/shm/age.key --run-dir /var/backups/lx-fampad/<Zeit> --as-postgres
```

Das Skript prüft die Prüfsummen, legt die **Wegwerf-Datenbank `lx_fampad_restoretest`** an, spielt `age -d | pg_restore` ein (Klartext nur in der Pipe),
zählt Tabellen und Zeilen je Tabelle, listet das Konfigurationsarchiv (ohne zu entpacken; bricht ab, wenn `etc/lx-fampad/env` fehlt) und löscht die
Wegwerf-Datenbank wieder (`--keep` lässt sie zum Nachsehen stehen). Vergleiche die Zeilenzahlen mit der laufenden Datenbank (Größenordnung: Mitglieder,
Listen, Termine); Termin im Kalender: Datum der Sicherung notieren. Trage Datum und Ergebnis in dein Betriebsbuch ein.

Mit `--skip-config` überspringt das Skript Schritt 4 (Konfigurationsarchiv), für einen Schlüssel, der nur Datenbank (und Dateiablage) lesen darf. Das nutzt der **automatische Wochentest auf dem NAS** (`deploy/backup/nas/lx-fampad-restoretest.sh`, Docker-Wegwerf-Datenbank, Statusdatei `restoretest-status`; Einrichtung: `BACKUP-EINRICHTUNG-SCHRITTE.md`, Abschnitt 10, Hintergrund `BACKUP.md`). Er ersetzt den halbjährlichen Test von Hand nicht ganz: das Konfigurationsarchiv (`AUTH_SECRET_KEY`) prüfst du weiter selbst.

Zusätzlich einmal im Jahr: einen **kompletten Neuaufbau** auf einem Wegwerf-Server oder einer VM nach Abschnitt 3 durchspielen (ohne DNS-Umschaltung).

Zur Einordnung: Dieser Test betrifft den **Server**. Ob sich der **Schlüssel der Chats** (Sicherung mit Wiederherstellungsschlüssel, Passwort oder Passkey) wirklich wieder öffnen lässt, prüft jede Person selbst in der App (Profil > Verschlüsselung > „Wiederherstellung testen“, Erinnerung alle 90 Tage, rein lokal; Abschnitt 9a der Projektbeschreibung). Bei einem Neuaufbau aus der Datenbanksicherung bleiben diese Sicherungen erhalten (sie liegen als undurchsichtige Blobs in der Datenbank).

## 3. Neuaufbau auf einem frischen Debian-13-VPS

**Der übliche Weg ist das Skript `deploy/neuinstallation/bootstrap-server.sh`** (Schritt für Schritt für Laien: [`NEUINSTALLATION.md`](NEUINSTALLATION.md), mit Liste dessen, was verloren geht und was du selbst tun musst). Es macht die folgenden Schritte 4 bis 14 in einem Lauf (Pakete, Benutzer, Konfiguration und Datenbank aus der Sicherung, Dienste, ntfy, Caddy nur als `conf.d`-Dateien, Sicherung). Die Handarbeit unten bleibt als Rückfallebene und zum Nachvollziehen.

Gilt für Totalverlust und für den Umzug (Variante B in Abschnitt 4). Grundlage ist eine bestehende Einrichtung nach `deploy/README.md`; die Skripte sind
idempotent und bleiben in dieser Reihenfolge. Nummern in Klammern verweisen auf die Abschnitte der `deploy/README.md`.

**Vorbereitung auf dem PC**

1. **TTL** der DNS-Einträge `familie` und `ntfy.familie` auf 300 s senken (beim Umzug: einen Tag vorher). Einträge noch **nicht** ändern.
2. Sicherung holen und entschlüsseln-testen (Abschnitt 2). Den **Stand des Codes** festlegen, der zur Sicherung passt (Git-Tag/Commit der laufenden Version; die
   Datenbank darf nicht neuer sein als der Code, ältere Datenbanken migriert der Server beim Start).
3. Entschlüsselte Daten **nur im RAM des Servers** ablegen (`/dev/shm`, tmpfs): Schlüssel bleibt auf dem PC, Klartext nur durch den SSH-Tunnel:

```bash
RUN=/pfad/archiv/<Zeit>      # Ordner der Sicherung auf dem PC
age -d -i ~/lx-fampad-age.key "$RUN"/db-*.dump.age     | ssh lx-labs 'umask 077; cat > /dev/shm/db.dump'
age -d -i ~/lx-fampad-age.key "$RUN"/config-*.tar.age  | ssh lx-labs 'umask 077; cat > /dev/shm/config.tar.gz'
```

**Auf dem neuen Server (als `lx`, in tmux)**

4. **Grundeinrichtung** des Servers (Benutzer `lx`, SSH, ufw, Caddy, `lx-labs`) wie in `lx-labs/deploy/README.md`: das ist ein anderes Projekt und liegt nicht in dieser
   Sicherung. Ist lx-labs.dev auf dem neuen Server noch nicht eingerichtet, zuerst das erledigen.
5. **PostgreSQL 17, Node 24, Code holen** (1, 3, 4 der README: `apt install postgresql postgresql-client rsync`, Node, `git clone` nach `~/lx-fampad`, dann den Stand aus Schritt 2 auschecken).
6. **Frische Installation als Gerüst:** `sudo bash ~/lx-fampad/deploy/einrichtung-1.sh` (README 2 bis 5: Benutzer, Verzeichnisse, Rolle, **neue** Schlüssel und Passwörter, Migrationsrolle, Units, erstes Deployment).
   Anschließend `sudo systemctl stop lx-fampad`.
7. **Konfiguration aus der Sicherung zurückspielen** (überschreibt die neuen Schlüssel, vor allem `AUTH_SECRET_KEY`). Nur diese Pfade, **nie** `etc/caddy/Caddyfile`:

```bash
sudo tar -tzf /dev/shm/config.tar.gz | head -50            # ansehen
sudo tar -xzf /dev/shm/config.tar.gz -C / \
  etc/lx-fampad srv/fampad/well-known srv/fampad/releases/android
sudo chown -R lx:lx /srv/fampad/well-known /srv/fampad/releases
sudo chown root:root /etc/lx-fampad/* && sudo chmod 600 /etc/lx-fampad/*
sudo grep -c '^AUTH_SECRET_KEY=.' /etc/lx-fampad/env        # muss 1 sein
```

   (`etc/caddy/conf.d/*.caddy`, `etc/ntfy/server.yml` und die Units werden in den Schritten 11 und 12 aus dem Repository neu erzeugt; die archivierten Fassungen dienen zum Vergleich:
   `tar -xzf … -C /tmp/alt etc/caddy etc/ntfy etc/systemd`.)
8. **Datenbank-Passwörter angleichen:** Die neuen Rollen haben neue Passwörter, die zurückgespielten Dateien die alten. Die Rollen bekommen die Passwörter aus den Dateien (nichts steht in einer Befehlszeile):

```bash
sudo bash <<'EOS'
set -euo pipefail
pw() { sed -n "s|^$1=postgres://[^:]*:\([^@]*\)@.*|\1|p" "$2" | head -1; }
RT="$(pw DATABASE_URL /etc/lx-fampad/env)"; MG="$(pw MIGRATION_DATABASE_URL /etc/lx-fampad/migrate.env)"
[ -n "$RT" ] && [ -n "$MG" ] || { echo "Passwörter nicht gefunden" >&2; exit 1; }
printf "ALTER ROLE lx_fampad PASSWORD '%s';\nALTER ROLE lx_fampad_migrate PASSWORD '%s';\n" "$RT" "$MG" | sudo -u postgres psql -v ON_ERROR_STOP=1 -q
EOS
```

9. **Datenbank ersetzen** (die frische, leere wird verworfen; die Rollen bleiben):

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<'SQL'
DROP DATABASE lx_fampad WITH (FORCE);
CREATE DATABASE lx_fampad OWNER lx_fampad_migrate ENCODING 'UTF8';
SQL
sudo -u postgres pg_restore --exit-on-error -d lx_fampad < /dev/shm/db.dump      # Besitzer und Rechte stammen aus der Sicherung
sudo bash ~/lx-fampad/deploy/einrichtung-auth.sh                                   # setzt Besitzer/Rechte erneut (idempotent), Units
sudo -u postgres psql -d lx_fampad -c '\dt' | head                                 # Tabellen da?
sudo shred -u /dev/shm/db.dump /dev/shm/config.tar.gz || sudo rm -f /dev/shm/db.dump /dev/shm/config.tar.gz
```

   Hinweis: `pg_restore` ohne `--no-owner` setzt voraus, dass `lx_fampad_migrate` und `lx_fampad` existieren (tun sie nach Schritt 6). Mit `--no-owner --no-privileges` würde `einrichtung-auth.sh` Besitzer und Rechte allein setzen: ebenfalls zulässig.
10. **Dienst starten und prüfen:** `sudo systemctl start lx-fampad`, `curl -s http://127.0.0.1:4400/api/v1/health` muss `"db":"ok"` liefern; `journalctl -u lx-fampad -n 30`. Bei „Migration fehlgeschlagen“: Code-Stand passt nicht zur Datenbank (Schritt 2).
11. **DNS umschalten, dann Caddy:** Erst jetzt die A-Einträge `familie` und `ntfy.familie` (DNS only) auf die neue IP setzen, **warten, bis** `dig +short familie.lx-labs.dev` die neue IP zeigt, dann
    `sudo bash ~/lx-fampad/deploy/einrichtung-2.sh` (README 6: Sicherung/Validierung/Rückfall; ändert das Haupt-Caddyfile nur um die Importzeile und lässt lx-labs.dev unberührt). Caddy holt die
    Zertifikate neu (Let's-Encrypt-Limits: höchstens 5 Fehlversuche je Stunde und Name, 5 neue Zertifikate je Woche für denselben Namensatz; bei Fehlern **nicht** wiederholt neu laden, sondern
    `journalctl -u caddy`, DNS prüfen, eine Stunde warten).
12. **ntfy:** `sudo bash ~/lx-fampad/deploy/einrichtung-ntfy.sh` (README 7), danach die gesicherten Zugangsdaten wieder einsetzen. Der Dienst darf dafür kurz stehen:

```bash
age -d -i ~/lx-fampad-age.key "$RUN"/config-*.tar.age | ssh lx-labs 'umask 077; cat > /dev/shm/config.tar.gz'     # auf dem PC, falls Schritt 3 schon aufgeräumt
sudo systemctl stop ntfy
sudo tar -xzf /dev/shm/config.tar.gz -C / var/lib/ntfy etc/lx-fampad/ntfy-token etc/lx-fampad/ntfy-family-password
sudo chown -R ntfy:ntfy /var/lib/ntfy && sudo chmod 600 /etc/lx-fampad/ntfy-token
sudo systemctl start ntfy && sudo shred -u /dev/shm/config.tar.gz
```

    (`etc/lx-fampad/ntfy-family-password` nur, wenn die Datei im Archiv ist.) Passen `NTFY_TOKEN` in `/etc/lx-fampad/env` und die wiederhergestellte `user.db` nicht zusammen, in `env` das
    Token aus `ntfy-token` eintragen (README 7). Dienst `lx-fampad` neu starten.
13. **Web-App und App-Dateien:** vom PC `deploy/deploy-web.sh` (README 8). `assetlinks.json` und `latest.json` kamen mit Schritt 7 zurück (README 9).
14. **Sicherung wieder einrichten:** Abschnitt 3 der `BACKUP.md` (`einrichtung-backup.sh` mit denselben Schlüsseln; der NAS-Schlüssel bleibt gültig, nur das `known_hosts` auf dem NAS muss den neuen Host-Schlüssel kennen: `ssh-keygen -R familie.lx-labs.dev`, `ssh-keyscan` neu). **Danach den Rückkanal „Status vom NAS“ neu einrichten** (er steht in keiner Sicherung und fehlt auf dem neuen Server still): `sudo bash ~/lx-fampad/deploy/backup/einrichtung-nasstatus.sh --dry-run --nas-pubkey '<~/.ssh/lx-fampad-status.pub vom NAS>' --nas-ip '<NAS-IP>'`, dann ohne `--dry-run`; Anleitung: `BACKUP-EINRICHTUNG-SCHRITTE.md`, Abschnitt 11. Der Umzugs-Assistent (`umzug.sh`) hat dafür `--weiter nasstatus`.
15. **Test:** `https://familie.lx-labs.dev` laden, Anmeldung mit Passkey/Passwort, **TOTP-Anmeldung** (beweist `AUTH_SECRET_KEY`), Listen und Kalender sichtbar, Push-Test, App-Update-Prüfung,
    `curl -sI https://lx-labs.dev` unverändert 200. Von außen: `nc -zv -w 3 <IP> 4400 2586 5432` müssen scheitern.
16. **Nacharbeiten:** (a) **Datenverlust-Fenster:** Änderungen seit der Sicherung (bis zu ca. 24 h) fehlen; Geräte, deren Stand neuer ist als der des Servers, melden `resync_required` und laden alles neu
    (der lokale Ausgang mit noch nicht gesendeten Änderungen bleibt erhalten und wird danach gesendet). (b) **Gelöschte Daten kommen zurück:** Konten oder Inhalte, die zwischen Sicherung und Ausfall
    gelöscht wurden (Löschwunsch nach DSGVO!), sind wieder da: Liste der seither erfüllten Löschwünsche führen und sie erneut löschen. (c) Sitzungen und Geräte aus der Sicherung gelten weiter; wurden zwischenzeitlich
    Sitzungen widerrufen, sind sie wieder gültig: bei Verdacht auf Kompromittierung über die Admin-Oberfläche „überall abmelden“. (d) TTL der DNS-Einträge wieder erhöhen. (e) Alte Server-Instanz abschalten/löschen.

**Rückfall des Neuaufbaus:** Solange der alte Server steht, bleibt er Rückfallebene: DNS zurückstellen (TTL 300 s). Auf dem neuen Server lässt sich jede Stufe wiederholen: `einrichtung-*.sh` sind idempotent;
die Datenbank kann (Schritt 9) erneut ersetzt werden.

## 4. Umzug auf einen größeren Tarif oder anderen Server

**Variante A: Tarifwechsel beim Hoster ohne Neuaufbau.** Bei netcup lässt sich der Tarif im Kundenportal (SCP) möglicherweise upgraden, ohne dass der Server neu aufgesetzt wird (Daten bleiben, ggf. kurzer Neustart und neue Plattengröße). **Nicht verifiziert:** vorher im Kundenportal und in den Vertragsbedingungen prüfen, ob ein Wechsel ohne Neuaufbau
und ohne IP-Änderung möglich ist, ob die Platte mitwächst (dann `growpart`/`resize2fs`) und welche Ausfallzeit angekündigt ist. Vorher: Snapshot im SCP, frische Sicherung (`sudo systemctl start lx-fampad-backup.service`) und eine Kopie auf dem NAS. Nachher: `free -h`,
`df -h`, `systemctl is-active lx-fampad caddy ntfy postgresql lx-labs`, Health-Check, `swapon --show` (Swapdatei aus `deploy/einrichtung-swap.sh` bleibt bestehen), Zeitplan `systemctl list-timers`.

**Variante B: Neuaufbau, Wiederherstellung, DNS-Umschaltung (empfohlen bei Anbieter-/Systemwechsel).**

1. Tag vorher: TTL der Einträge `familie` und `ntfy.familie` auf 300 s.
2. Neuen Server aufsetzen (Abschnitt 3, Schritte 4 bis 10) mit einer **frischen** Sicherung; die App ändert sich nicht (Domain bleibt).
3. Auf dem neuen Server gründlich testen, **ohne** DNS: `curl --resolve familie.lx-labs.dev:443:<neue-IP> https://familie.lx-labs.dev/api/v1/health` geht erst nach dem Zertifikat; vorher lokal
   `http://127.0.0.1:4400/api/v1/health`. Anmeldung erst nach der Umschaltung sinnvoll.
4. **Schreibstopp am alten Server:** `sudo systemctl stop lx-fampad` (Nutzer arbeiten offline weiter, die Apps halten ihren Ausgang und senden nach der Umschaltung). Letzte Sicherung ziehen (`systemctl start lx-fampad-backup.service`), auf dem neuen Server einspielen (Schritte 7 bis 10).
5. DNS umstellen (Schritt 11), Caddy-Zertifikate abwarten, testen (Schritt 15). Alter Server bleibt eine Woche im Stand-by (ohne laufenden `lx-fampad`).
6. Danach TTL erhöhen, alten Server kündigen/löschen (vorher Datenträger bereinigen lassen; er enthält die Konfiguration und die Datenbank).

Die WebAuthn-RP-ID (`familie.lx-labs.dev`) bleibt gleich, deshalb funktionieren Passkeys nach dem Umzug weiter.

## 5. Rollback und typische Fehler

| Problem | Maßnahme |
| --- | --- |
| `pg_restore`: „role … does not exist“ | Rollen fehlen (Schritt 6 nicht gelaufen); mit `--no-owner --no-privileges` einspielen und `einrichtung-auth.sh` ausführen |
| Dienst startet nicht („AUTH_SECRET_KEY“) | `env` aus Schritt 7 nicht übernommen oder leere Zeile; `grep AUTH_SECRET_KEY /etc/lx-fampad/env` |
| TOTP-Anmeldung schlägt für alle fehl | falscher `AUTH_SECRET_KEY`: der Schlüssel aus dem Passwortmanager/älteren Sicherungen muss zum Datenbankstand passen; **nie** einen neuen setzen, um „es zum Laufen zu bringen“ |
| Zertifikat fehlt | DNS prüfen (`dig`), Caddy-Log; bei Fehlversuchen mindestens 1 Stunde warten (Limit) |
| Falsche Datenbank eingespielt | Schritt 9 wiederholen (verwirft die Datenbank erneut); die Sicherungen auf dem NAS bleiben unverändert |
| `age: no identity matched` | falscher privater Schlüssel (andere Sicherung/anderer Empfänger): zweiten Schlüssel versuchen |
| Sicherung beschädigt (Prüfsumme) | nächstältere Sicherung vom NAS nehmen (14 tägliche, 8 wöchentliche, 12 monatliche) |
| Haupt-Caddyfile überschrieben | nur aus dem lx-labs-Repository herstellen; diese Sicherung enthält es nicht |
