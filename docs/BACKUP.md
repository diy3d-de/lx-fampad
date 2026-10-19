# Datensicherung von lx-fampad

Der Server sichert sich täglich selbst, verschlüsselt, und **das NAS holt die Sicherung ab** (Pull). Der Server hält **keine Zugangsdaten zum NAS** (er kennt nur dessen IP und den öffentlichen SSH-Schlüssel); der NAS-Schlüssel kann dort nur lesen. Ein übernommener Server kann Sicherungen auf dem NAS deshalb **nicht löschen**; Rotation und Speicherplatz des NAS sind aber nur durch die Gegenmaßnahmen im Pull-Skript geschützt (nur reguläre Dateien, Größen- und Mengengrenzen, Zukunftsdaten = Alarm, Rotation löscht nur bei genug geprüften Ordnern).
Wiederherstellung: [`WIEDERHERSTELLUNG.md`](WIEDERHERSTELLUNG.md). Datenschutz: `DATENSCHUTZ-ENTWURF.md`, Abschnitt 10.

```
VPS 03:30  lx-fampad-backup.timer ─▶ pg_dump | age ─▶ /var/backups/lx-fampad/<UTC-Zeit>/{db,config}-….age  (3 Tage)
NAS 04:30  rsync über SSH (Benutzer lxbackup, nur lesen) ─▶ NAS-Archiv ─▶ Rotation 14 täglich + 8 wöchentlich + 12 monatlich
```

## Was gesichert wird

| Inhalt | Archiv | Hinweis |
| --- | --- | --- |
| Datenbank `lx_fampad` (alles: Konten, Anmeldedaten, Listen, Kalender, Audit-Log) | `db-<Zeit>.dump.age` | `pg_dump -Fc` als `postgres`, ein konsistenter Schnappschuss, Klartext nur in einer Pipe (nie auf Platte) |
| `/etc/lx-fampad/*` (**`AUTH_SECRET_KEY`**, `migrate.env`, ntfy-Token, ntfy-Familienpasswort) | `config-<Zeit>.tar.age` | ohne `AUTH_SECRET_KEY` sind TOTP-Geheimnisse und HMACs der Datenbank unbrauchbar |
| `/etc/caddy/conf.d/*.caddy` | dito | **nicht** das Haupt-Caddyfile `/etc/caddy/Caddyfile`: es gehört lx-labs.dev und kann deren Geheimnisse enthalten; die Familien-Site entsteht aus dem Repository neu |
| Rollen und Passwort-Hashes (`pg_dumpall --globals-only`, keine Daten) | `globals.sql` im Konfigurationsarchiv | erleichtert den Neuaufbau der Datenbank-Rollen |
| `/etc/ntfy/server.yml`, `/var/lib/ntfy/*.db` (Benutzer/Tokens) | dito | SQLite online per `sqlite3 .backup` (konsistent, ohne den Dienst zu stoppen; Zwischenkopie nur im RAM) |
| systemd-Units `lx-fampad*`, Drop-ins von ntfy, sudoers, journald-Begrenzung | dito | |
| `/srv/fampad/well-known`, `releases/android/latest.json` + neueste APK | dito | APK ist aus GitHub Releases neu erzeugbar; abschaltbar mit `INCLUDE_APK=0` (spart ca. 90 MB je Tag und Kopie) |
| `/srv/fampad/files` (Dateiablage) | `files-<Zeit>.tar.age` | **aus**, bis die Ablage genutzt wird (`INCLUDE_FILES=1` in `/etc/lx-fampad-backup/backup.conf`). Bei großen Datenmengen später inkrementell (restic/borg) lösen |
| **nicht gesichert** | | Web-Build, `server/` (kommen aus `deploy.sh`), Schriften; lx-labs.dev (eigenes Projekt); **Standortdaten nie** (der Server speichert sie nicht, ein Pfad dafür ist nicht vorgesehen) |

Alles ist mit **age** verschlüsselt (X25519, ChaCha20-Poly1305), nur mit öffentlichen Schlüsseln. Die Sicherung enthält persönliche Daten und
`AUTH_SECRET_KEY`; deshalb liegt nie eine unverschlüsselte *Datei* auf Platte, NAS oder Übertragungsweg: der Dump läuft durch eine Pipe, die ntfy-Zwischenkopie und `globals.sql` nur im RAM (`/dev/shm`, 0700). Grenze: Pipe-Puffer und RAM-Dateien können bei Speichermangel in den **Swap** geraten (`einrichtung-swap.sh` legt eine Swapdatei an); wer das ausschließen will, verschlüsselt den Swap (dm-crypt mit Zufallsschlüssel, `crypttab`) oder lässt `vm.swappiness=10` und genug RAM frei. Optional trennst du die Schlüssel: `--age-recipient-config` gibt nur `config-*.tar.age` (mit `AUTH_SECRET_KEY`) an einen **eigenen** Schlüssel; wer den Dump-Schlüssel hat, kann dann nicht die Anmeldegeheimnisse entschlüsseln (und umgekehrt); für eine Wiederherstellung brauchst du beide. Der **private** Schlüssel liegt nie auf dem Server.
Dateien je Sicherung: `db-…`, `config-…`, ggf. `files-…`, `SHA256SUMS`; daneben `status` (letzter Erfolg, Größen) und `LATEST`.

## 1. Schlüssel erzeugen (auf deinem PC oder dem NAS, nie auf dem Server)

```bash
age-keygen -o lx-fampad-age.key
# Ausgabe:  Public key: age1…   <- das ist der öffentliche Schlüssel (darf auf den Server)
age-keygen -y lx-fampad-age.key    # gibt den öffentlichen Schlüssel erneut aus
```

`age-keygen` gibt es für Windows/Linux/macOS (<https://github.com/FiloSottile/age/releases>, Debian: `apt install age`). Die Datei `lx-fampad-age.key`
enthält den **privaten** Schlüssel (`AGE-SECRET-KEY-…`):

- in den **Passwortmanager** (als Anhang oder Text) **und** ausgedruckt/zweiter Ort (Safe, Familie): ohne ihn sind alle Sicherungen wertlos,
- **nie** auf den Server, nie in Git, nie ins NAS-Archiv neben die Sicherungen,
- Empfehlung: einen **zweiten** Schlüssel erzeugen und beide Empfänger angeben (`--age-recipient` zweimal); Verlust eines Schlüssels ist dann nicht fatal.
- Zusätzlich `AUTH_SECRET_KEY` einmal im Passwortmanager ablegen (steht auch verschlüsselt in jeder Sicherung, aber ein zweiter Weg schadet nicht).

Schlüsselwechsel: neuen Empfänger mit `einrichtung-backup.sh --age-recipient …` setzen (ersetzt die Empfängerliste); ältere Sicherungen
bleiben nur mit dem alten privaten Schlüssel lesbar, also alte Schlüssel aufheben, solange alte Sicherungen existieren.

## 2. SSH-Schlüssel für das NAS (nur für diese Aufgabe)

Auf dem NAS (oder dem Rechner, der abholt), als der Benutzer, der den Abholjob ausführt:

```bash
ssh-keygen -t ed25519 -N '' -C 'lx-fampad-backup' -f ~/.ssh/lx-fampad-backup     # ohne Passphrase, weil der Job unbeaufsichtigt läuft
cat ~/.ssh/lx-fampad-backup.pub     # <- öffentlicher Teil für den Server
```

Der Schlüssel öffnet auf dem Server **nur** `rrsync -ro /var/backups/lx-fampad` (nur lesen, nur dieses Verzeichnis, keine Shell, kein PTY, keine
Weiterleitung) und nur von der NAS-Adresse. Er gehört in keinen anderen Zweck. Die feste, **öffentliche IP-Adresse des NAS bzw. des Anschlusses**
brauchst du für `--nas-ip` (ändert sie sich oft, bei DynDNS-Anschlüssen besser das NAS-Netz über ein eigenes Gateway mit fester Adresse
ansprechen; das Skript verlangt eine Adresse: eine gültige IPv4/IPv6-Adresse oder ein Netz (CIDR) mit mindestens /16 bzw. /48, mehrere mit Komma; alles andere, auch `0.0.0.0/0` und `::/0`, lehnt der Parser ab).

## 3. Server einrichten (3 Befehle, du führst sie selbst aus)

Auf dem Server als Benutzer `lx`, in tmux/screen. Vorher den Stand ansehen (das Skript läuft als root, der Checkout gehört dir):

```bash
git -C ~/lx-fampad pull --ff-only && git -C ~/lx-fampad log -3 --stat && git -C ~/lx-fampad status --short deploy
# 1. Trockenlauf (prüft alles, ändert nichts)
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh --dry-run \
  --age-recipient 'age1…' --nas-pubkey 'ssh-ed25519 AAAA… lx-fampad-backup' --nas-ip 203.0.113.7
# 2. Einrichten (derselbe Aufruf ohne --dry-run; legt Benutzer, Verzeichnisse, Dienst und Timer an und macht einen Probelauf)
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh \
  --age-recipient 'age1…' --nas-pubkey 'ssh-ed25519 AAAA… lx-fampad-backup' --nas-ip 203.0.113.7
# 3. Probe: Zeitplan und Status
systemctl list-timers lx-fampad-backup.timer && sudo cat /var/backups/lx-fampad/status
```

Das Skript installiert bei Bedarf `age`, `rsync` (liefert `rrsync`) und `sqlite3` aus Debian, ändert **nicht** Caddy, das Haupt-Caddyfile,
`sshd_config`, PostgreSQL-Rollen oder lx-fampad, fragt nichts interaktiv und nimmt bei einem Fehler die in diesem Lauf angelegten oder geänderten Dateien, Units, den Benutzer und den Timer-Zustand zurück (installierte Pakete und bereits erzeugte Sicherungen bleiben). Es prüft
auch, dass sshd den Benutzer `lxbackup` zulässt (bei `AllowUsers` in der `sshd_config` bricht es ab und sagt, was zu ergänzen ist).
Mehrfaches Ausführen ist gefahrlos; ohne Optionen bleiben vorhandene Schlüssel und Adresse unverändert.

Die systemd-Einheit ist gehärtet (`ProtectSystem=strict`, `ProtectProc=invisible`, `UMask=0077`, `RestrictAddressFamilies`, `MemoryMax`); `PrivateNetwork=true` ist bewusst nicht gesetzt (Zugriff auf PostgreSQL per Unix-Socket ließ sich ohne systemd im Test nicht absichern). Vorab prüft das Skript den Platz (Reserve + 2× Datenbankgröße, bei `INCLUDE_FILES=1` plus Dateiablage) und räumt Reste abgebrochener Läufe (`.tmp-*`, `/dev/shm`) zuerst weg. Die ntfy-Datenbanken werden mit `sqlite3 .backup` (10 s Wartezeit bei Sperren) gesichert; legt das Lesen als root `-wal`/`-shm` an, gleicht das Skript deren Besitzer an `user.db` an.

Einstellungen (optional) in `/etc/lx-fampad-backup/backup.conf`: `KEEP` (Ordner auf dem Server, Standard 3), `INCLUDE_APK`, `INCLUDE_FILES`, `MIN_FREE_MB`.
Manuell sichern: `sudo systemctl start lx-fampad-backup.service`; Log: `journalctl -u lx-fampad-backup`.
Ein Fehler beendet den Dienst mit Exit ≠ 0 (im `systemctl --failed` sichtbar) und schreibt `last_result=fehler` in die Statusdatei; vorhandene Sicherungen
bleiben unverändert, nichts Halbfertiges wird veröffentlicht.

## 4. NAS einrichten (Abholen)

Das NAS-Modell ist offen, deshalb generisch. Voraussetzungen auf dem NAS: `bash` (4.x), `rsync`, `ssh`, GNU-`date` (Test: `date -u -d '2026-01-01 -1 day' +%F`
muss `2025-12-31` ausgeben), `sha256sum`. Das Skript [`deploy/backup/nas/lx-fampad-pull.sh`](../deploy/backup/nas/lx-fampad-pull.sh) macht alles:

1. holt neue Ordner mit `rsync -a --partial` (**ohne `--delete`**: das NAS behält, was einmal da war; gelöscht wird nur durch die Rotation) nach `<Ziel>/archiv/`,
2. prüft jeden neuen Ordner mit `sha256sum -c SHA256SUMS`,
3. schlägt Alarm (Exit ≠ 0, Meldung), wenn die neueste Sicherung älter als 36 Stunden ist, eine Prüfsumme nicht stimmt oder der Server `last_result=fehler` meldet,
4. rotiert: **14 tägliche, 8 wöchentliche (ISO-Woche), 12 monatliche**; je Zeitraum bleibt die neueste, die 3 neuesten immer.

Zusätzlich: Ausführungszeitlimit 2 h (`timeout`), SSH mit `ConnectTimeout=30` und `ServerAlive*` (hängende Verbindungen enden), rsync nur mit `-rt --no-links --no-perms --no-owner --no-group --no-devices --no-specials --max-size`, Warnung bei rsync < 3.4.0 (CVE-2024-12086), Alarm bei freiem Platz < 2 GB am Ziel. Fehlt GNU-`date -d` (BusyBox), bricht das Skript mit Alarm ab, statt still falsch zu rechnen.

Einmalig vorbereiten (als der Benutzer, der den Job ausführt):

```bash
mkdir -p ~/lx-fampad-backup && cp lx-fampad-pull.sh ~/lx-fampad-backup/
# Host-Schlüssel des Servers festhalten und den Fingerabdruck mit dem Server vergleichen (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub dort):
ssh-keyscan -p <SSH-Port> -t ed25519 familie.lx-labs.dev > ~/.ssh/lx-fampad-backup.known_hosts && ssh-keygen -lf ~/.ssh/lx-fampad-backup.known_hosts
# Probe, ohne etwas zu schreiben
LXB_DEST=/volume1/backup/lx-fampad bash ~/lx-fampad-backup/lx-fampad-pull.sh --dry-run
```

Einstellungen per Umgebungsvariable (Standardwerte im Skript): `LXB_SERVER` (Standard `familie.lx-labs.dev`), `LXB_PORT`, `LXB_KEY`, `LXB_KNOWN_HOSTS`,
`LXB_DEST`, `LXB_MAX_AGE_HOURS` (36), `LXB_KEEP_DAILY/WEEKLY/MONTHLY`, `LXB_NOTIFY_CMD` (Befehl, der bei Alarm mit der Meldung aufgerufen wird).
Die Namen der Ordner sind UTC-Zeitstempel; die Rotation rechnet ebenfalls in UTC.

### Synology (DSM 7): Aufgabenplaner

1. SSH-Schlüssel auf dem NAS erzeugen (Abschnitt 2, per SSH-Sitzung als Admin-Benutzer; DSM: Systemsteuerung, Terminal & SNMP, SSH aktivieren, danach ruhig wieder abschalten) oder auf dem PC erzeugen und `~/.ssh/lx-fampad-backup` auf das NAS kopieren (`chmod 600`).
2. Skript nach `/volume1/backup/lx-fampad-pull.sh` kopieren, Zielordner anlegen (Freigabe nur für Admins, nicht für Familienmitglieder: auch verschlüsselt gehören die Daten nicht in eine offene Freigabe).
3. Systemsteuerung, **Aufgabenplaner**, Erstellen, Geplante Aufgabe, **Benutzerdefiniertes Skript**: Benutzer: der, dem `~/.ssh` gehört (nicht root nötig); Zeitplan **täglich 04:30**; Aufgabeneinstellungen:
   ```bash
   LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-pull.sh
   ```
   Haken bei **Ausführungsdetails per E-Mail senden**, Haken bei **nur bei abnormaler Beendigung**: bei Alarm (Exit ≠ 0) bekommst du die Mail mit der Meldung. (E-Mail-Versand in DSM unter Benachrichtigung einrichten.)
4. Falls `date -d` fehlt (ältere/eingeschränkte Busybox-Umgebung): GNU coreutils nachinstallieren (Entware `opkg install coreutils-date`) oder das Skript in einem Docker-Container (Image `debian:trixie-slim` mit `rsync openssh-client`) ausführen.
5. **Hyper Backup** kann zusätzlich das fertige Archiv `<Ziel>/archiv/` auf ein zweites Ziel (USB, Cloud) sichern; die Daten sind bereits age-verschlüsselt. Eine Rotation durch Hyper Backup allein ersetzt das Skript nicht (es holt nicht vom Server).

### QNAP

Gleiches Skript; Ausführung per `crontab` im QTS (Eintrag nach `/etc/config/crontab` und `crontab /etc/config/crontab && /etc/init.d/crond.sh restart`, überlebt Neustarts nur über `autorun.sh`) oder als Container (Container Station). `rsync` und `ssh` sind vorhanden, GNU-`date` wie oben prüfen. Für das Mail bei Alarm `LXB_NOTIFY_CMD` auf ein Mailprogramm des NAS setzen.

### Generisches Linux (cron oder systemd-Timer)

```bash
# cron (crontab -e) – 04:30; MAILTO bekommt die Ausgabe bei jeder Meldung, deshalb nur Fehler ausgeben:
MAILTO=du@example.org
30 4 * * *  LXB_DEST=/srv/backup/lx-fampad /home/backup/lx-fampad-backup/lx-fampad-pull.sh >/dev/null
```

(`>/dev/null` verwirft die Fortschrittsmeldungen; Alarme gehen auf stderr und lösen die Mail aus.) Alternative systemd-Timer:

```ini
# ~/.config/systemd/user/lx-fampad-pull.service
[Service]
Type=oneshot
Environment=LXB_DEST=/srv/backup/lx-fampad
ExecStart=/home/backup/lx-fampad-backup/lx-fampad-pull.sh
# ~/.config/systemd/user/lx-fampad-pull.timer
[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
[Install]
WantedBy=timers.target
```
`systemctl --user enable --now lx-fampad-pull.timer`; `loginctl enable-linger <benutzer>`; Fehlschlag sichtbar mit `systemctl --user --failed` (mit `OnFailure=` eine Mail auslösen).

### Zeitplan

Server **03:30** (plus bis zu 5 Minuten Zufallsverzögerung, die Sicherung dauert derzeit Sekunden), NAS **04:30**. Das NAS sollte nie vor 04:00 holen. Verpasst der Server den Lauf (aus), holt `Persistent=true` ihn beim Start nach.

### Überwachung

- Das Pull-Skript prüft das **Alter** der neuesten Sicherung (aus dem Ordnernamen) und die **Statusdatei** des Servers; älter als 36 h oder `last_result=fehler` ist ein Alarm (Exit ≠ 0).
- Läuft das NAS-Skript selbst nicht mehr (NAS aus, Aufgabe deaktiviert), meldet sich nichts: einmal im Monat im NAS-Archiv nachsehen, ob der neueste Ordner von gestern ist. Idee für später: ein ntfy-Wecker, der die Statusdatei liest und den Admin erinnert (nicht umgesetzt).
- Auf dem Server: `sudo cat /var/backups/lx-fampad/status` (`last_success_utc`, `last_result`), `systemctl status lx-fampad-backup.service`.

### Ohne Skript (nur zum Verständnis)

```bash
rsync -a --partial --exclude '.tmp-*' -e 'ssh -i ~/.ssh/lx-fampad-backup' lxbackup@familie.lx-labs.dev:/ /ziel/archiv/
```

## 5. Aufbewahrung und Löschen (Datenschutz)

| Ort | Dauer |
| --- | --- |
| Server `/var/backups/lx-fampad` | die letzten 3 Läufe (ca. 3 Tage) |
| NAS | 14 tägliche, 8 wöchentliche, 12 monatliche (ältester Stand ca. 12 Monate) |

Daten, die in der App oder durch Entfernen eines Mitglieds gelöscht werden, verschwinden aus der Live-Datenbank sofort, **aus den Sicherungen erst nach Ablauf
der Aufbewahrung** (spätestens ca. 13 Monate). Wird eine Wiederherstellung eingespielt, sind gelöschte Konten und Inhalte danach wieder da und
müssen erneut gelöscht werden (Wiederherstellungs-Handbuch, Schritt „Nacharbeiten“). Standortdaten gibt es in Sicherungen nicht.

## 6. Rückbau

```bash
sudo systemctl disable --now lx-fampad-backup.timer
sudo rm /etc/systemd/system/lx-fampad-backup.{service,timer} /usr/local/sbin/lx-fampad-backup && sudo systemctl daemon-reload
sudo userdel lxbackup && sudo rm -rf /var/lib/lxbackup          # entfernt auch den SSH-Zugang des NAS
sudo rm -rf /etc/lx-fampad-backup /var/backups/lx-fampad        # löscht die Sicherungen auf dem Server (das NAS-Archiv bleibt)
```

## Sicherheitsmodell in Kürze

- Wer den Server übernimmt, kann Sicherungen lesen (verschlüsselt, ohne privaten Schlüssel nutzlos) und die der letzten 3 Tage löschen, **nicht** die auf dem NAS.
- Wer das NAS übernimmt, hat nur verschlüsselte Dateien; der Server hält keine Zugangsdaten zum NAS (nur dessen IP und öffentlichen Schlüssel).
- Ein übernommener Server kann dem Pull-Skript Müll anbieten (riesige oder viele Dateien, gefälschte Zeitstempel). Das Skript holt nur reguläre Dateien bis `LXB_MAX_FILE_SIZE` (2 GB), prüft Prüfsummen, lehnt Ordner mit Datum in der Zukunft ab (Alarm), bricht bei zu vielen Ordnern/zu großem Archiv ab und rotiert nur, wenn danach mindestens 3 geprüfte, plausibel große Ordner bleiben.
- Zeitzonen: der Timer läuft nach der Systemzeit des Servers (`timedatectl`), die Ordnernamen und die Rotation rechnen in **UTC**; bei Sommerzeit verschiebt sich 03:30 Ortszeit entsprechend gegenüber den Namen.
- Der NAS-Schlüssel kann auf dem Server nur lesen (`rrsync -ro`, `restrict`, `from=`); `~lxbackup` und `authorized_keys` gehören root, der Benutzer kann sie nicht ändern.
- Ein Server-Fehler (Datenbank leer, Platte voll, age kaputt) bricht ab, statt eine leere/halbe Sicherung zu veröffentlichen; ein stiller Ausfall fällt über das Alter auf dem NAS auf.
- Grenzen: Die Verschlüsselung schützt nicht vor dem Verlust des privaten Schlüssels (dann ist alles weg); ein Wiederherstellungstest (halbjährlich) prüft Schlüssel und Inhalt.
