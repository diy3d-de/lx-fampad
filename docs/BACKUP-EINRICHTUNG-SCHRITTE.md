# Datensicherung einrichten: Schritt für Schritt

Diese Anleitung führt dich einmal komplett durch (etwa 1 bis 2 Stunden). Hintergründe, Sicherheitsmodell und Grenzen stehen in [`BACKUP.md`](BACKUP.md), der Neuaufbau im Ernstfall in [`WIEDERHERSTELLUNG.md`](WIEDERHERSTELLUNG.md).
Alles auf dem Server führst du selbst mit `sudo` aus; nichts davon macht Claude. Befehle sind zum Kopieren gedacht, `<…>` und Werte in `'…'` ersetzt du durch deine eigenen.

**Reihenfolge ist wichtig:** Schlüssel (1, 2) → **NAS-Snapshots (3) vor dem ersten Lauf** → Server (4 bis 6) → NAS-Abholung (7) → Wiederherstellungstest (8), optional automatischer Wochentest auf dem NAS (10), optional Rückmeldung des NAS an die Betreiber-Ansicht (11). Ohne Schritt 3 und 8 ist die Sicherung nicht abgenommen.

Was nicht gesichert wird (bewusst): Web-App und Server-Code (kommen aus `deploy.sh`), die kommende Kartendatei `/srv/fampad/karte` (1 bis 5 GB, neu erzeugbar), lx-labs.dev, Standortdaten (gibt es nicht auf der Platte).

---

## 1. age-Schlüssel erzeugen (auf deinem PC, nie auf dem Server)

`age` verschlüsselt die Sicherung. Du brauchst zwei Schlüsselpaare: einen **Hauptschlüssel** und einen **Ersatzschlüssel** (Verlust eines Schlüssels ist dann nicht fatal).

1. `age` herunterladen: <https://github.com/FiloSottile/age/releases> (Windows: `age-v…-windows-amd64.zip`, entpacken, `age.exe` und `age-keygen.exe` in einen Ordner, z. B. `C:\age`). Linux/macOS: `apt install age` bzw. `brew install age`.
2. PowerShell öffnen und im Ordner mit `age-keygen.exe` die Schlüssel erzeugen:

```powershell
cd C:\age
.\age-keygen.exe -o lx-fampad-age-haupt.key
.\age-keygen.exe -o lx-fampad-age-ersatz.key
```

**Erwartung:** je eine Zeile `Public key: age1…` (62 Zeichen, beginnt mit `age1`). Das ist der **öffentliche** Schlüssel. Notiere beide.
Den öffentlichen Schlüssel jederzeit erneut anzeigen:

```powershell
.\age-keygen.exe -y lx-fampad-age-haupt.key
.\age-keygen.exe -y lx-fampad-age-ersatz.key
```

3. **Wo der private Schlüssel liegt** (die Dateien `*.key` enthalten `AGE-SECRET-KEY-…`):
   - **Hauptschlüssel:** Inhalt der Datei in den Passwortmanager (als sicheres Textfeld oder Dateianhang) **und** einmal ausdrucken und in den Safe/zu den Familienunterlagen legen.
   - **Ersatzschlüssel:** an einem anderen Ort als den Hauptschlüssel: z. B. USB-Stick im Safe bei Verwandten oder zweiter Passwortmanager-Eintrag.
   - **Nie** auf den Server, nie in Git, nie auf die NAS-Freigabe neben die Sicherungen, nie per Mail.
   - Danach die Dateien vom PC löschen, wenn sie sicher abgelegt sind (oder verschlüsselter Datenträger).
4. Zusätzlich `AUTH_SECRET_KEY` einmal im Passwortmanager ablegen (auf dem Server: `sudo grep '^AUTH_SECRET_KEY=' /etc/lx-fampad/env`). Er steckt zwar verschlüsselt in jeder Sicherung, ein zweiter Weg schadet nicht.

---

## 2. SSH-Schlüssel für das NAS und die NAS-Adresse

Der Server kennt später nur den **öffentlichen** Schlüssel und die Adresse deines NAS-Anschlusses; er hat keine Zugangsdaten zum NAS.

1. **Synology:** Systemsteuerung → Terminal & SNMP → *SSH-Dienst aktivieren* (nach der Einrichtung wieder ausschalten). Benutzer-Home-Verzeichnisse müssen an sein (Systemsteuerung → Benutzer und Gruppe → Erweitert → *Benutzerhomedienst aktivieren*). Dann per SSH anmelden und den Schlüssel **nur für diese Aufgabe** erzeugen:

```bash
ssh <nas-admin-benutzer>@<nas-adresse>
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -N '' -C 'lx-fampad-backup' -f ~/.ssh/lx-fampad-backup
cat ~/.ssh/lx-fampad-backup.pub
```

**Erwartung:** eine Zeile `ssh-ed25519 AAAA… lx-fampad-backup`. Das ist der **öffentliche** Schlüssel (`NAS_PUB`). Die Datei ohne `.pub` ist der private Schlüssel und bleibt auf dem NAS.

2. **Öffentliche Adresse deines Anschlusses** (so sieht der Server das NAS), im Heimnetz abfragen:

```bash
curl -4 -s https://ifconfig.me ; echo
curl -6 -s --max-time 5 https://ifconfig.me ; echo
```

**Erwartung:** eine IPv4-Adresse (z. B. `203.0.113.7`), und eventuell eine IPv6-Adresse (oder nichts, wenn du kein IPv6 hast). Welche der NAS tatsächlich benutzt, entscheidet sein Weg zum Server: nimm beide, getrennt durch Komma (`NAS_IP='203.0.113.7,2001:db8:1234::/48'`, ein IPv6-Präfix nur als `/48` oder kleiner angeben, nie einzelne wechselnde Adressen raten). **Wichtig:** Ändert sich deine öffentliche IPv4 (Router-Neuverbindung), schlägt die Abholung fehl; dann Schritt 4 mit der neuen Adresse wiederholen (das Skript ist wiederholbar). Eine feste Adresse ist deshalb besser.

---

## 3. NAS-Snapshots einrichten (Pflicht, bevor der erste Lauf passiert)

Die Snapshots sind die Rückfallebene, falls ein manipulierter Server oder ein Skriptfehler etwas Falsches ins Archiv bringt. Voraussetzung: Volume mit **Btrfs**.

1. Freigegebenen Ordner für die Sicherungen anlegen (Systemsteuerung → Freigegebener Ordner → Erstellen), Name z. B. `backup`. Zugriff nur für dich (Admin), **nicht** für Familienmitglieder. Prüfen: Das Volume ist Btrfs (Speicher-Manager → Volume → Dateisystem).
2. Paketzentrale → **Snapshot Replication** installieren.
3. Snapshot Replication → *Snapshots* → Ordner `backup` wählen → *Einstellungen* → Reiter *Zeitplan*:
   - *Snapshot-Zeitplan aktivieren*: täglich, **05:30 Uhr** (nach dem Abholen um 04:30).
   - Reiter *Aufbewahrung*: *Neueste Snapshots behalten*: **14**.
   - Wenn angeboten (DSM 7.2): *Unveränderliche Snapshots* für 14 Tage aktivieren.
4. Einmal von Hand testen: *Snapshot* → *Erstellen*, danach muss in der Liste ein Eintrag mit Datum stehen.

**Erwartung:** Unter *Snapshots* erscheint täglich ein neuer Eintrag, ältere als 14 Tage verschwinden. Kein Btrfs? Dann stattdessen Hyper Backup des Ordners auf eine USB-Platte oder in die Cloud (Ziel: zweite, unabhängige Kopie). Ohne eine dieser beiden Absicherungen die Schritte 4 bis 6 noch nicht ausführen.

---

## 4. Server: Skripte prüfen und Trockenlauf

Per SSH auf den Server, in `tmux` (bricht dann nicht mit der Verbindung ab):

```bash
ssh lx-labs
tmux new -s backup
```

1. Stand der Skripte holen und **ansehen** (das Skript läuft als root und kopiert aus deinem Checkout nach `/usr/local/sbin` und `/etc`):

```bash
git -C ~/lx-fampad pull --ff-only
git -C ~/lx-fampad log -3 --stat
git -C ~/lx-fampad status --short deploy
```

**Erwartung:** die letzten Commits (Backup-Dateien in `deploy/backup/`), und `status` ohne Ausgabe (keine lokalen Änderungen).

2. Deine Werte als Variablen setzen (ersetzen!):

```bash
AGE_PUB='age1…haupt…'
AGE_PUB2='age1…ersatz…'
NAS_PUB='ssh-ed25519 AAAA… lx-fampad-backup'
NAS_IP='203.0.113.7'
```

3. **Trockenlauf** (prüft nur, ändert nichts):

```bash
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh --dry-run \
  --age-recipient "$AGE_PUB" --age-recipient "$AGE_PUB2" \
  --nas-pubkey "$NAS_PUB" --nas-ip "$NAS_IP"
```

**Erwartung (Auszug):**

```
==> 1/6 Prüfungen (Trockenlauf: es wird nichts verändert)
    Skript lx-fampad-backup.sh: sha256 ……………
    Pakete fehlen: age sqlite3 (werden installiert; Candidate: …)        # oder: age, rsync, sqlite3 vorhanden.
    apt-Simulation:
        Inst age (…)
    Datenbank lx_fampad erreichbar.
    Platz in /var/backups: … MB.
    Benutzer lxbackup wird angelegt.
    Caddy, Haupt-Caddyfile und sshd_config bleiben unberührt.
==> Trockenlauf beendet: alle Prüfungen bestanden. Geplant wäre:
    - Pakete: age sqlite3
    - Benutzer lxbackup, /var/backups/lx-fampad (root:lxbackup 0750), /etc/lx-fampad-backup
    …
```

Bei `FEHLER: …` nichts weiter tun, sondern die Meldung lesen: typische Ursachen sind ein `AllowUsers` in der `sshd_config` (das Skript sagt, was zu ergänzen ist), eine ungültige `NAS_IP` oder ein Tippfehler im age-Schlüssel (`age1…` mit genau 62 Zeichen).

---

## 5. Server: Einrichten und erster Lauf

Derselbe Aufruf **ohne** `--dry-run`:

```bash
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh \
  --age-recipient "$AGE_PUB" --age-recipient "$AGE_PUB2" \
  --nas-pubkey "$NAS_PUB" --nas-ip "$NAS_IP"
```

**Erwartung:** die Abschnitte `==> 2/6 Pakete` bis `==> 6/6 Selbsttest: Probelauf der Sicherung`, darin Zeilen wie

```
    db-<Zeit>.dump.age: … Bytes
    config-<Zeit>.tar.age: … Bytes, … Pfade, ntfy-DBs: 2
    Prüfsummen ok.
    ok: lesen nur in /var/backups/lx-fampad; kein Schreiben, kein Zugriff auf Geheimnisse.
    ok: Abholung funktioniert, Pfade außerhalb und Hochladen werden abgelehnt.
```

und am Ende eine **WICHTIG-Mahnung** zum Wiederherstellungstest (Schritt 8) sowie `Fertig. Nächste Schritte:`. Bei einem Fehler nimmt das Skript alles Neue selbst zurück (Meldung `Zurückgesetzt`); dann Ursache beheben und denselben Befehl wiederholen.

---

## 6. Server: Ergebnis prüfen

```bash
systemctl list-timers lx-fampad-backup.timer
sudo cat /var/backups/lx-fampad/status
sudo ls -l /var/backups/lx-fampad /var/backups/lx-fampad/$(sudo cat /var/backups/lx-fampad/LATEST)
journalctl -u lx-fampad-backup -n 30 --no-pager
```

**Erwartung:**
- `list-timers`: `lx-fampad-backup.timer` mit `NEXT` heute oder morgen gegen 03:30 (Systemzeit, bis zu 5 Minuten Verzögerung).
- `status`: `last_result=ok`, `last_success_utc=<jetzt>`, `db_bytes`, `config_bytes`.
- Ordner `<YYYYMMDD-HHMMSS>` (UTC) mit `db-….dump.age`, `config-….tar.age`, `SHA256SUMS`, Rechte `-rw-r----- root lxbackup`.
- `journalctl`: nach dem Probelauf kann es leer sein (der Selbsttest lief außerhalb des Dienstes) oder die Läufe zeigen `==> Fertig: …`. Der **erste echte Timer-Lauf** am nächsten Morgen: `journalctl -u lx-fampad-backup -n 30 --no-pager` muss `==> Fertig` enthalten und `systemctl status lx-fampad-backup.service` darf nicht `failed` melden. Falls der Dienst-Lauf scheitert (z. B. wegen der systemd-Härtung), steht der Grund dort: bitte melden, bevor du weitermachst.

Einen Dienst-Lauf sofort anstoßen (statt bis morgen zu warten):

```bash
sudo systemctl start lx-fampad-backup.service && sudo journalctl -u lx-fampad-backup -n 20 --no-pager
```

**Erwartung:** keine Fehlermeldung, zuletzt `==> Fertig: /var/backups/lx-fampad/… `.

---

## 7. NAS: Abholung einrichten (Synology DSM, Aufgabenplaner)

1. Skript auf das NAS bringen: **aus deinem eigenen Git-Checkout auf dem PC, nicht vom Server** (ein übernommener Server könnte dir sonst ein manipuliertes Skript unterschieben), am besten von einem Tag, den du geprüft hast. Auf dem PC (PowerShell):

```powershell
cd C:\Projekte\lx-familienzentrale
git fetch --tags
git checkout <geprüfter-Tag>
Get-FileHash -Algorithm SHA256 deploy\backup\nas\lx-fampad-pull.sh
scp deploy\backup\nas\lx-fampad-pull.sh <nas-admin-benutzer>@<nas-adresse>:/volume1/backup/lx-fampad-pull.sh
```

   Danach auf dem NAS `sha256sum /volume1/backup/lx-fampad-pull.sh` ausführen: die Prüfsumme muss mit der vom PC übereinstimmen (Groß-/Kleinschreibung egal), sonst nicht benutzen.

2. Auf dem NAS (SSH-Sitzung): Voraussetzungen und Host-Schlüssel des Servers festhalten.

```bash
date -u -d '2026-01-01 -1 day' +%F
bash --version | head -1
rsync --version | head -1
```

**Erwartung:** `2025-12-31` (GNU-date), bash ≥ 4, rsync ≥ 3.4.0 (älter: Warnung, Paket/DSM aktualisieren). Kommt bei `date` ein Fehler, ist es BusyBox: Skript im Container ausführen oder GNU coreutils installieren (siehe `BACKUP.md`).

```bash
ssh-keyscan -t ed25519 familie.lx-labs.dev > ~/.ssh/lx-fampad-backup.known_hosts
ssh-keygen -lf ~/.ssh/lx-fampad-backup.known_hosts
```

**Erwartung:** `256 SHA256:… familie.lx-labs.dev (ED25519)`. **Vergleiche den Fingerabdruck** mit dem auf dem Server (`ssh lx-labs ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`): er muss gleich sein.

3. Zugang testen (der erzwungene Befehl lässt nur lesen zu, eine Meldung von `rrsync` ist die richtige Antwort):

```bash
ssh -i ~/.ssh/lx-fampad-backup -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOME/.ssh/lx-fampad-backup.known_hosts lxbackup@familie.lx-labs.dev
```

**Erwartung:** eine Meldung wie `rrsync error: SSH_ORIGINAL_COMMAND does not run rsync` oder sofortiges Ende ohne Shell, **kein** Eingabeprompt. `Permission denied (publickey)` bedeutet: falscher Schlüssel, falsche `NAS_IP` (Schritt 2: Absenderadresse prüfen) oder `lxbackup` nicht in `AllowUsers`.

4. Probelauf ohne Schreiben, dann der erste echte Lauf:

```bash
LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-pull.sh --dry-run
LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-pull.sh
```

**Erwartung (echter Lauf):**

```
==> Abholen von familie.lx-labs.dev (nur lesend, ohne --delete, zuerst in /volume1/backup/lx-fampad/.staging)
    zu holen: … MB
    neu und ok: <YYYYMMDD-HHMMSS>
==> Prüfen
    neueste Sicherung: <…> (Alter: 0 h, erlaubt: 36 h)
==> Rotation (14 täglich, 8 wöchentlich, 12 monatlich)
    nichts zu löschen.
==> Fertig.
```

und unter `/volume1/backup/lx-fampad/archiv/` liegt der Ordner mit `.geprueft`. Bei `ALARM: …` die Meldung lesen, die Fälle stehen in `BACKUP.md`, Abschnitt „Bei Alarm“.

5. **Aufgabenplaner** (DSM): Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe → *Benutzerdefiniertes Skript*:
   - *Allgemein*: Name `lx-fampad Sicherung abholen`, Benutzer: derselbe Benutzer, dem `~/.ssh/lx-fampad-backup` gehört (nicht root).
   - *Zeitplan*: täglich, **04:30**.
   - *Aufgabeneinstellungen*: Haken bei *Ausführungsdetails per E-Mail senden* und *Nur bei abnormaler Beendigung*; im Feld *Benutzerdefiniertes Skript*:

```bash
LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-pull.sh
```

   - Benachrichtigung per E-Mail zuvor einrichten (Systemsteuerung → Benachrichtigung). Exit-Code 75 (anderer Lauf aktiv) kann im Aufgabenplaner als „abnormal“ gemeldet werden, das ist selten und harmlos.
   - Aufgabe markieren → *Ausführen* und das Ergebnis ansehen (*Aktion* → *Ausgabeergebnis anzeigen*): muss dem echten Lauf aus Schritt 4 entsprechen.

Einmal im Monat im NAS-Archiv nachsehen, dass der neueste Ordner von gestern ist (läuft die Aufgabe selbst nicht mehr, meldet sich nichts).

---

## 8. Erster Wiederherstellungstest (heute, nicht später)

Prüft, dass dein privater Schlüssel wirklich zu den Sicherungen passt und die Datenbank sich einspielen lässt. Fasst den Server nie an. Auf deinem **PC**, mit einer Sicherung **vom NAS** (nicht vom Server).

1. Einen Sicherungsordner vom NAS auf den PC holen:

```powershell
mkdir C:\lx-backup
scp -r <nas-admin-benutzer>@<nas-adresse>:/volume1/backup/lx-fampad/archiv/<YYYYMMDD-HHMMSS> C:\lx-backup\
```

2. Test mit Docker (Docker Desktop läuft; keine lokale PostgreSQL-Installation nötig). Der Container installiert PostgreSQL 17 und `age`, startet eine **Wegwerf**-Datenbank und führt das Skript aus; alles verschwindet danach. Pfade anpassen:

```powershell
docker run --rm `
  -v "C:\lx-backup:/backup:ro" `
  -v "C:\Projekte\lx-familienzentrale\deploy\backup:/skripte:ro" `
  -v "C:\age\lx-fampad-age-haupt.key:/schluessel/age.key:ro" `
  debian:trixie bash -c "apt-get update -qq && apt-get install -y -qq postgresql-17 age util-linux >/dev/null 2>&1 && pg_ctlcluster 17 main start && sleep 3 && bash /skripte/wiederherstellung-test.sh --identity /schluessel/age.key --run-dir /backup/<YYYYMMDD-HHMMSS> --as-postgres"
```

(Der Schlüssel liegt dafür kurz auf dem PC; danach wieder sicher verwahren.)

**Erwartung:**

```
==> 1/4 Prüfsummen
db-….dump.age: OK
config-….tar.age: OK
==> 2/4 Wegwerf-Datenbank lx_fampad_restoretest anlegen
==> 3/4 Entschlüsseln und einspielen (age -d | pg_restore, ohne Besitzer/Rechte)
    Tabellen im Schema public: <N>
    Zeilen je Tabelle (exakt gezählt):
        public.users | <Anzahl> …
    angewendete Migrationen (drizzle.__drizzle_migrations): <Zahl, aktuell 13>
==> 4/4 Konfigurationsarchiv (nur Dateiliste, nichts wird entpackt)
    etc/lx-fampad/env ist enthalten.
==> Wiederherstellungstest bestanden: …
```

Prüfe: die Tabellen- und Zeilenzahlen passen zur Größenordnung deiner Familie (Mitglieder, Listen, Termine, Aufgaben, Chat-Nachrichten, `person_key_history`), die Migrationszahl entspricht dem Stand des Servers. Bei `no identity matched`: falscher privater Schlüssel (Haupt-/Ersatzschlüssel mit dem anderen Schlüssel versuchen). Trage Datum und Ergebnis in dein Betriebsbuch ein; wiederhole den Test alle 6 Monate.

---

## 9. Optional: Swap auf dem Server (2 GB RAM, kein Swap)

Auf dem Server (tmux):

```bash
sudo bash ~/lx-fampad/deploy/einrichtung-swap.sh --dry-run
```

**Erwartung:** `==> Prüfungen (Trockenlauf)`, freier Platz ausreichend (1 GB + 4 GB Reserve), `fstab-Eintrag: fehlt`, am Ende `==> Trockenlauf beendet, nichts verändert.`

```bash
sudo bash ~/lx-fampad/deploy/einrichtung-swap.sh
swapon --show
free -m
```

**Erwartung:** `swapon --show` listet `/swapfile` (1024M, `file`), `free -m` zeigt `Swap: 1023`. Das Skript hat `/etc/fstab` per Kopie geprüft (Sicherung `/etc/fstab.vor-swap`) und `vm.swappiness=10` gesetzt. Nach dem nächsten Neustart steht die Swapdatei wieder in `swapon --show`.

---

## 10. Optional, empfohlen: Wiederherstellungstest jede Woche automatisch (auf dem NAS)

Der manuelle Test aus Schritt 8 prüft einmal. Eine Sicherung, die niemand zurückspielt, kann trotzdem kaputt sein (falscher Schlüssel, beschädigte Datei, neue Datenbank-Version). Deshalb spielt das NAS **jeden Sonntag** die zuletzt abgeholte Sicherung in eine **Wegwerf-Datenbank** ein (Docker-Container, ohne Netz, schreibgeschütztes Dateisystem, Datenbank nur im tmpfs des Containers, danach weg) und schreibt das Ergebnis in eine kleine Statusdatei (`ok` oder `fehler`, Zeitpunkt, Größen, Zähler, **nie Inhalte oder Geheimnisse**). Bei einem Fehler schlägt der Aufgabenplaner an und schickt dir die E-Mail aus Schritt 7. Der Server und die Produktivdatenbank werden nie angefasst.

**Sicherheitsabwägung (bitte lesen):**
- Für den Test muss ein **privater** Schlüssel auf dem NAS liegen. Wer auf dem NAS Administrator ist, kann damit **alles entschlüsseln, was dieser Schlüssel lesen darf**: die Datenbank-Sicherungen und, falls eingeschaltet (`INCLUDE_FILES=1`), die Dateiablage (`files-*.tar.age`). Das sind alle personenbezogenen Daten der Familie im Klartext (die Chats sind zusätzlich Ende-zu-Ende verschlüsselt und bleiben auch dann unlesbar).
- Das **Konfigurationsarchiv mit `AUTH_SECRET_KEY`** liest dieser Schlüssel **nicht** (Schritt 10.4: eigene Empfänger nur für die Konfiguration). Der Test prüft deshalb nur Datenbank und Prüfsummen; das Konfigurationsarchiv prüfst du weiter von Hand (Schritt 8, halbjährlich).
- Du erzeugst dafür einen **eigenen Test-Schlüssel** (nicht den Hauptschlüssel, nicht den Ersatzschlüssel), und zwar **direkt auf dem NAS**: der private Teil verlässt das NAS nie, nur die öffentliche Zeile geht zum Server. Er liegt im Home-Verzeichnis von `root` (nicht in einer Freigabe, damit ihn weder Snapshots noch Hyper Backup mitnehmen), Rechte `600`.
- Der Container ist gehärtet (keine Netzverbindung, keine Linux-Rechte außer den fünf für PostgreSQL nötigen, `no-new-privileges`, Dateisystem schreibgeschützt, kein Container-Log auf der Platte, `--memory-swap` gleich Arbeitsspeicher). Die Datenbank liegt nur im tmpfs (Arbeitsspeicher) des Containers. Ehrliche Grenze: Der Klartext liegt im Arbeitsspeicher des NAS (der Container schreibt nichts auf die Platte, `--memory-swap` verhindert seine Auslagerung); wer auf dem NAS root ist, kann ihn dort während des Laufs trotzdem mitlesen.
- Bist du mit der Abwägung nicht einverstanden: nicht einrichten und Schritt 8 weiter halbjährlich von Hand machen.

**Voraussetzungen:** ein Synology mit Docker-Unterstützung (Paket *Container Manager*, bei DSM 7.0/7.1 *Docker*; nicht jedes Modell kann es: Paketzentrale ansehen), etwa 1 GB freier Arbeitsspeicher, Internet beim Bauen des Images (einmalig und danach alle 35 Tage automatisch). Die Aufgabe läuft als `root` (Docker verlangt das bei Synology).

### 10.1 Container Manager installieren

Paketzentrale → *Container Manager* suchen → Installieren. Fertig (nichts weiter einstellen).

### 10.2 Skripte auf das NAS bringen (aus deinem eigenen Git-Checkout, nicht vom Server)

Die Skripte laufen auf dem NAS als `root` und fassen den privaten Schlüssel an. Hole sie deshalb **nicht** vom Server (ein übernommener Server könnte dir manipulierte Skripte unterschieben), sondern aus deinem eigenen Git-Checkout auf dem PC, am besten von einem **Tag, den du geprüft hast**. Auf dem PC (PowerShell):

```powershell
cd C:\Projekte\lx-familienzentrale
git fetch --tags
git checkout <geprüfter-Tag>
Get-FileHash -Algorithm SHA256 deploy\backup\wiederherstellung-test.sh, deploy\backup\nas\lx-fampad-restoretest.sh
scp deploy\backup\wiederherstellung-test.sh deploy\backup\nas\lx-fampad-restoretest.sh <nas-admin-benutzer>@<nas-adresse>:/volume1/homes/<nas-admin-benutzer>/
```

Dann auf dem NAS (SSH als Admin, danach `sudo -i`, Passwort eingeben) die Prüfsummen **vergleichen** (müssen Zeichen für Zeichen mit denen vom PC übereinstimmen; Groß-/Kleinschreibung egal), erst dann installieren:

```bash
sudo -i
cd /volume1/homes/<nas-admin-benutzer>
sha256sum wiederherstellung-test.sh lx-fampad-restoretest.sh
mkdir -p /root/lx-fampad-restoretest && chmod 700 /root/lx-fampad-restoretest
mv wiederherstellung-test.sh lx-fampad-restoretest.sh /root/lx-fampad-restoretest/
chown root:root /root/lx-fampad-restoretest/*.sh && chmod 700 /root/lx-fampad-restoretest/*.sh
ls -l /root/lx-fampad-restoretest
```

**Erwartung:** zwei Dateien `-rwx------ root root`; die zwei Prüfsummen stimmen mit dem PC überein. Weichen sie ab: nichts installieren, Dateien auf dem PC prüfen (`git status`, richtiger Tag?) und neu kopieren.

### 10.3 Test-Schlüssel direkt auf dem NAS erzeugen

Auf dem NAS (weiter als `root`). Das erzeugt zuerst das Docker-Image (einmalig, einige Minuten, Internet nötig; die Basis ist auf einen festen Digest gebunden) und dann den Schlüssel:

```bash
bash /root/lx-fampad-restoretest/lx-fampad-restoretest.sh --identity /root/lx-fampad-restoretest/lx-fampad-age-test.key --keygen
ls -l /root/lx-fampad-restoretest
```

**Erwartung:** `==> Test-Schlüssel erzeugt: …`, danach **eine Zeile `age1…`** (der öffentliche Schlüssel, `AGE_PUB_TEST`: die kannst du kopieren) und die Datei `lx-fampad-age-test.key` mit `-rw-------`. Der private Teil verlässt das NAS nie; das Skript überschreibt nie eine vorhandene Schlüsseldatei. Geht der Schlüssel verloren, erzeugst du auf dieselbe Weise einen neuen (alten Schlüssel vorher löschen) und wiederholst 10.4.

### 10.4 Dem Server den öffentlichen Schlüssel nur für die Datenbank geben

Auf dem Server den Einrichtungsaufruf aus Schritt 5 **wiederholen** (er ist wiederholbar und **ersetzt** die Empfängerlisten, deshalb alle Schlüssel angeben): Haupt-, Ersatz- **und** Test-Schlüssel für Datenbank (und Dateiablage), nur Haupt- und Ersatzschlüssel für die Konfiguration:

```bash
AGE_PUB_TEST='age1…test…'
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh --dry-run \
  --age-recipient "$AGE_PUB" --age-recipient "$AGE_PUB2" --age-recipient "$AGE_PUB_TEST" \
  --age-recipient-config "$AGE_PUB" --age-recipient-config "$AGE_PUB2" \
  --nas-pubkey "$NAS_PUB" --nas-ip "$NAS_IP"
```

**Erwartung:** in der Übersicht `3 age-Empfänger` und `2 eigene Empfänger für die Konfiguration`. Dann derselbe Aufruf **ohne** `--dry-run`, danach `sudo systemctl start lx-fampad-backup.service`. **Wichtig:** Nur Sicherungen, die **nach** dieser Umstellung entstehen, kann der Test-Schlüssel lesen; der Test beginnt also mit dem nächsten Pull (Schritt 10.5). Haupt- und Ersatzschlüssel lesen weiterhin alles.

### 10.5 Einmal von Hand testen

Zuerst muss das NAS eine Sicherung haben, die der Test-Schlüssel lesen kann (aus der Zeit nach 10.4): den Pull aus Schritt 7 einmal von Hand ausführen (`LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-pull.sh`) und prüfen, dass `neu und ok: <Datum>` erscheint. Dann (als `root`):

```bash
cd /root/lx-fampad-restoretest
LXB_DEST=/volume1/backup/lx-fampad bash lx-fampad-restoretest.sh --identity /root/lx-fampad-restoretest/lx-fampad-age-test.key --ohne-config --dry-run
```

**Erwartung:** `==> Sicherung: <Datum> (Alter … h …)`, `Image … vorhanden.`, `==> Trockenlauf beendet`. Eine Zeile `FEHLER: …` sagt, was fehlt (z. B. Schlüsselrechte, Docker nicht gefunden). Dann der echte Lauf:

```bash
LXB_DEST=/volume1/backup/lx-fampad bash lx-fampad-restoretest.sh --identity /root/lx-fampad-restoretest/lx-fampad-age-test.key --ohne-config
cat /volume1/backup/lx-fampad/restoretest-status
```

**Erwartung:**

```
==> 1/4 Prüfsummen
==> 2/4 Wegwerf-Datenbank lx_fampad_restoretest anlegen
==> 3/4 Entschlüsseln und einspielen (age -d | pg_restore, ohne Besitzer/Rechte)
    Tabellen im Schema public: <N>
    angewendete Migrationen (drizzle.__drizzle_migrations): <Zahl>
==> 4/4 Konfigurationsarchiv …   (übersprungen, weil --ohne-config)
==> Wiederherstellungstest bestanden: <Datum> (Tabellen: <N>, Migrationen: <Zahl>, Zeilen: <Summe>)
```

und in der Statusdatei `last_result=ok`, `last_success_utc=<jetzt>`, `db_bytes=…`, `tables=…`, `rows_total=…`, `config_check=nein`.

**Mindestwerte:** Der Test gilt auch dann als fehlgeschlagen (`detail=zu_klein`), wenn die wiederhergestellte Datenbank zu klein ist, also eine leere oder fast leere Sicherung. Die Standardgrenzen sind bewusst niedrig (mindestens 10 Tabellen, 5 Migrationen, 10 Zeilen). Setze sie **auf etwa die Hälfte der Werte aus deinem ersten Lauf** (`tables`, `migrations`, `rows_total`), damit auch eine halb leere Sicherung auffällt: in der Aufgabe (10.6) vor das Skript `LXR_MIN_TABLES=… LXR_MIN_MIGRATIONS=… LXR_MIN_ROWS=…` schreiben.

### 10.6 Aufgabenplaner: jeden Sonntag

Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe → *Benutzerdefiniertes Skript*:
- *Allgemein*: Name `lx-fampad Wiederherstellungstest`, Benutzer **root**.
- *Zeitplan*: **wöchentlich, Sonntag, 06:00** (nach dem Abholen um 04:30 und den Snapshots um 05:30).
- *Aufgabeneinstellungen*: Haken bei *Ausführungsdetails per E-Mail senden* und *Nur bei abnormaler Beendigung*; im Feld *Benutzerdefiniertes Skript*:

```bash
LXB_DEST=/volume1/backup/lx-fampad LXR_MIN_TABLES=10 LXR_MIN_MIGRATIONS=5 LXR_MIN_ROWS=10 bash /root/lx-fampad-restoretest/lx-fampad-restoretest.sh --identity /root/lx-fampad-restoretest/lx-fampad-age-test.key --ohne-config
```

(die drei Zahlen durch deine Werte aus 10.5 ersetzen)
- Aufgabe markieren → *Ausführen* → *Aktion* → *Ausgabeergebnis anzeigen*: muss `Wiederherstellungstest bestanden` enthalten. Die Ausgabe enthält nur Fortschrittszeilen und Zähler, keine Daten.
- Beendet sich der Test mit einem Fehler (Exit 1), kommt die E-Mail, und `restoretest-status` meldet `last_result=fehler` mit `step` und `detail`. Ein anderer laufender Test (Exit 75) ist harmlos.

### 10.7 Ergebnis lesen und was Fehler bedeuten

```bash
cat /volume1/backup/lx-fampad/restoretest-status
```

| Wert | Bedeutung |
| --- | --- |
| `last_result` | `ok` oder `fehler` |
| `last_run_utc`, `last_success_utc` | letzter Lauf, letzter erfolgreicher Lauf (UTC) |
| `run_dir`, `backup_age_h` | welche Sicherung getestet wurde und wie alt sie war |
| `db_bytes`, `config_bytes` | Größe der verschlüsselten Dateien |
| `tables`, `migrations`, `rows_total` | Zähler der wiederhergestellten Datenbank (Größenordnung vergleichen) |
| `config_check` | `ja` = Konfigurationsarchiv geprüft, `nein` = bewusst übersprungen (`--ohne-config`) |
| `step`, `detail` | bei `fehler`: wo und warum (Tabelle unten) |

| `detail` | Ursache und was zu tun ist |
| --- | --- |
| `pruefsummen` | Datei beschädigt oder verändert: Archiv und Snapshots ansehen (BACKUP.md, „Bei Alarm“) |
| `entschluesseln_einspielen` | Test-Schlüssel passt nicht zu dieser Sicherung (nach 10.4 neu erzeugt? Sicherung aus der Zeit davor?), Datei beschädigt oder PostgreSQL im Image älter als 17 |
| `konfigarchiv` | nur ohne `--ohne-config`: Schlüssel kann das Konfigurationsarchiv nicht lesen oder `etc/lx-fampad/env` fehlt darin |
| `zu_klein` | Datenbank wiederhergestellt, aber unter den Mindestwerten (10.5): leere/zu kleine Sicherung oder Grenzen zu hoch |
| `sicherung_zu_alt` | neueste geprüfte Sicherung älter als 72 h: holt der Pull (Schritt 7) noch ab? |
| `keine_sicherung`, `kein_archiv`, `marke_stimmt_nicht` | Pull noch nie gelaufen bzw. Archiv verändert (BACKUP.md, „Bei Alarm“) |
| `schluessel_rechte`, `schluessel_besitzer`, `schluessel_fehlt`, `schluessel_inhalt`, `schluessel_im_archiv`, `schluessel_ordner`, `testskript_rechte` | Schlüsseldatei und Skripte prüfen: `chmod 600` bzw. `700`, Besitzer root, richtiger absoluter Pfad, kein Link, nicht im Sicherungsordner, Ordner nur für root beschreibbar |
| `pfad_nicht_absolut`, `pfad_ungueltig`, `wert_ungueltig` | Aufruf: Pfade absolut ohne Leerzeichen, `LXR_…`-Werte als Zahl (mit k/m/g bzw. s/m/h/d) |
| `docker_fehlt`, `docker_nicht_erreichbar`, `docker_start`, `image_bauen` | Container Manager installiert und gestartet? Aufgabe als root? Beim Bauen Internet und Speicherplatz |
| `zeitlimit` | der Test hat 30 Minuten überschritten (`LXR_TIMEOUT`), NAS ausgelastet oder Datenbank sehr groß (`LXR_TMPFS_SIZE`/`LXR_MEMORY` erhöhen) |

Das Image wird alle 35 Tage automatisch neu gebaut (Sicherheitsupdates der Pakete), von Hand mit `--rebuild`. Das Basis-Image ist im Skript an einen festen Digest (`BASE=…`) gebunden und wird nie ohne Absicht neu geladen (`--pull never`); die Pakete darin kommen beim Bauen aus dem Debian-Archiv. Den Digest erneuerst du bei Gelegenheit mit einer neuen Skriptfassung. Einmal im Monat in der Statusdatei nachsehen, dass `last_run_utc` höchstens 8 Tage alt ist (läuft die Aufgabe selbst nicht mehr, meldet sich nichts, wie beim Pull).

### 10.8 Meldung an den Server

Das Ergebnis geht an den Server, sobald du Abschnitt 11 eingerichtet hast (eigener, eingeschränkter Schlüssel des NAS; der Server hält weiter keine Zugangsdaten zum NAS). Ohne Abschnitt 11 bleibt die E-Mail des Aufgabenplaners das Warnsignal.

---

## 11. Optional, empfohlen: Rückmeldung des NAS an die Betreiber-Ansicht (Betrieb Paket 3)

Mit diesem Schritt zeigt „Betrieb“ > **Backups** die letzte Abholung und den letzten Wiederherstellungstest, und der Server warnt dich per Push (ohne Inhalt), wenn die Abholung älter als 36 Stunden ist oder der Test älter als 10 Tage bzw. fehlgeschlagen ist. Der Server bekommt **keine** Zugangsdaten zum NAS: das NAS schickt nur eine kleine, geprüfte Statusdatei über einen **zweiten, eigenen** SSH-Schlüssel, der auf dem Server genau einen Befehl ausführen darf (Hintergrund und Grenzen: [`BACKUP.md`](BACKUP.md), Abschnitt „Rückmeldung an den Server“). Bis du das einrichtest, steht in der App „noch keine Rückmeldung“, und es gibt keine Warnung dazu.

### 11.1 Zweiten SSH-Schlüssel auf dem NAS erzeugen

Als der Benutzer, der die Aufgaben ausführt (Synology: `root`), **nicht** den Schlüssel der Abholung wiederverwenden:

```bash
ssh-keygen -t ed25519 -N '' -C 'lx-fampad-status' -f ~/.ssh/lx-fampad-status
cat ~/.ssh/lx-fampad-status.pub
```

Die Zeile `ssh-ed25519 AAAA… lx-fampad-status` ist der **öffentliche** Schlüssel (der private bleibt auf dem NAS). Er wird dem Server nur für den einen Befehl gegeben.

### 11.2 Server: Trockenlauf und Einrichten

Per SSH auf den Server (in `tmux`). Wie bei Schritt 4: erst den Stand ansehen, denn das Skript läuft als root und kopiert aus deinem Checkout nach `/usr/local/sbin`:

```bash
git -C ~/lx-fampad pull --ff-only
git -C ~/lx-fampad log -3 --stat
git -C ~/lx-fampad status --short deploy
NAS_PUB2='ssh-ed25519 AAAA… lx-fampad-status'
NAS_IP='203.0.113.7'      # dieselbe Adresse wie in Schritt 5
sudo bash ~/lx-fampad/deploy/backup/einrichtung-nasstatus.sh --dry-run --nas-pubkey "$NAS_PUB2" --nas-ip "$NAS_IP"
```

**Erwartung:** Prüfungen ohne `FEHLER`, am Ende `Trockenlauf beendet: alle Prüfungen bestanden` mit der Liste dessen, was angelegt würde (Benutzer `lxnasstatus`, Ordner `/var/lib/lx-fampad-nasstatus`, Befehl, `authorized_keys`). Meldet es, dass der Schlüssel der Abholung doppelt verwendet wird: einen neuen erzeugen (11.1). Erlaubt dein `sshd` nur bestimmte Benutzer (`AllowUsers`), nennt das Skript es: dann `lxnasstatus` von Hand in `sshd_config` ergänzen (`sshd -t`, dann neu laden). Das Skript ändert `sshd_config`, Caddy und das Haupt-Caddyfile nie. Dann derselbe Aufruf ohne `--dry-run`:

```bash
sudo bash ~/lx-fampad/deploy/backup/einrichtung-nasstatus.sh --nas-pubkey "$NAS_PUB2" --nas-ip "$NAS_IP"
```

**Erwartung:** `4/4 Selbsttest` endet mit zwei Zeilen `ok: …` und `Fertig.`. Den Rückbau siehe [`BACKUP.md`](BACKUP.md), Abschnitt „Rückbau“ (zusätzlich: `sudo userdel lxnasstatus`, `/var/lib/lxnasstatus`, `/var/lib/lx-fampad-nasstatus` und `/usr/local/sbin/lx-fampad-nasstatus-empfang` löschen).

### 11.3 NAS: Skripte aus dem eigenen Git-Checkout

Wie in 10.2: nicht vom Server holen, sondern vom PC (geprüfter Tag), Prüfsummen vergleichen. Neu sind `lx-fampad-nasstatus.sh`; **`lx-fampad-pull.sh` und `lx-fampad-restoretest.sh` ersetzt du durch die neuen Fassungen** (sie schreiben `pull-status` bzw. rufen die Meldung auf). Alle drei liegen im selben Ordner auf dem NAS (das Pull- und das Restoretest-Skript suchen das Meldeskript neben sich):

```powershell
cd C:\Projekte\lx-familienzentrale
Get-FileHash -Algorithm SHA256 deploy\backup\nas\lx-fampad-nasstatus.sh, deploy\backup\nas\lx-fampad-pull.sh, deploy\backup\nas\lx-fampad-restoretest.sh
scp deploy\backup\nas\lx-fampad-nasstatus.sh deploy\backup\nas\lx-fampad-pull.sh deploy\backup\nas\lx-fampad-restoretest.sh <nas-admin-benutzer>@<nas-adresse>:/volume1/homes/<nas-admin-benutzer>/
```

Auf dem NAS (`sudo -i`): Prüfsummen mit `sha256sum` vergleichen und die Dateien dorthin legen, wo die Aufgaben sie schon aufrufen (`lx-fampad-pull.sh` z. B. `/volume1/backup/`, `lx-fampad-restoretest.sh` in `/root/lx-fampad-restoretest/`); das Meldeskript neben **jedes** der beiden (oder `LXB_STATUS_MELDER=/pfad/lx-fampad-nasstatus.sh` in der Aufgabe setzen). Rechte `700`, Besitzer `root`. Der Melder nutzt dieselbe `known_hosts`-Datei wie der Pull (`~/.ssh/lx-fampad-backup.known_hosts`, Schritt 7) und den neuen Schlüssel `~/.ssh/lx-fampad-status`.

### 11.4 Einmal von Hand testen

```bash
# was würde gesendet? (nichts wird gesendet)
LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-nasstatus.sh --print
# senden
LXB_DEST=/volume1/backup/lx-fampad bash /volume1/backup/lx-fampad-nasstatus.sh
```

**Erwartung:** `--print` zeigt nur Zeilen mit festen Schlüsseln (`pull_result=ok`, `pull_success_epoch=…`, …), `Status an den Server gemeldet.`. Auf dem Server: `sudo cat /var/lib/lx-fampad-nasstatus/nas.status` zeigt dieselben Zeilen plus `received_epoch=…`. Wenn es noch keine `pull-status` gibt (der Pull lief noch nicht in der neuen Fassung), zuerst den Pull von Hand starten (Schritt 7). In der App: **Betrieb > Backups** (Prüfung neu starten). Ab jetzt melden das Pull-Skript (04:30) und der Wiederherstellungstest (sonntags) nach jedem Lauf von selbst; ein Fehler beim Melden ändert nie das Ergebnis der Sicherung.

### 11.5 Fehlerbilder

| Meldung / Anzeige | Ursache |
| --- | --- |
| `Statusmeldung an den Server fehlgeschlagen` | Schlüssel, Adresse (`--nas-ip` muss die öffentliche Adresse des NAS sein), `known_hosts` oder die Einrichtung auf dem Server prüfen; `ssh -i ~/.ssh/lx-fampad-status -v lxnasstatus@<server>` von Hand ansehen |
| `abgelehnt: …` auf dem Server (der Befehl nimmt die Datei nicht an) | die Datei hat ein unerwartetes Format: eine selbst geänderte Skriptfassung? Auf dem NAS von Hand `bash lx-fampad-nasstatus.sh` ausführen (zeigt die Meldung) und `--print` ansehen |
| App: „Noch keine Rückmeldung vom NAS“ | es wurde noch nichts gemeldet, oder der Dienst darf `/var/lib/lx-fampad-nasstatus` nicht lesen (Gruppe `lx-fampad`, `2750`) |
| App: „nicht lesbar (ungültiges Format)“ | die Datei auf dem Server ist größer als 4 KB oder hat ein ungültiges Format: neu senden; sie wird bei jedem Lauf ersetzt |
| Warnung „Abholung durch das NAS“ | die letzte erfolgreiche Abholung ist älter als 36 Stunden oder das Pull-Skript meldete `fehler`: Aufgabenplaner und `pull-status` prüfen |
| Warnung „Wiederherstellungstest“ | der letzte erfolgreiche Test ist älter als 10 Tage oder fehlgeschlagen: `restoretest-status` (10.7) |

---

## Fertig: Checkliste

- [ ] Haupt- und Ersatzschlüssel (privat) im Passwortmanager bzw. ausgedruckt an zwei Orten, **nicht** auf dem Server
- [ ] NAS-Snapshots laufen (14 Tage) oder zweite Kopie per Hyper Backup
- [ ] `systemctl list-timers lx-fampad-backup.timer` zeigt den Timer, `status` meldet `last_result=ok`
- [ ] Der erste Timer-Lauf (am Morgen danach) war erfolgreich: `journalctl -u lx-fampad-backup`
- [ ] NAS-Aufgabe 04:30 läuft, E-Mail bei Fehler ist getestet
- [ ] Wiederherstellungstest (Schritt 8) bestanden und eingetragen
- [ ] Optional: Swap eingerichtet
- [ ] Optional: automatischer Wochentest auf dem NAS (Schritt 10): `restoretest-status` zeigt `last_result=ok`, E-Mail bei Fehler ist getestet
- [ ] Optional: Rückmeldung des NAS (Schritt 11): „Betrieb > Backups“ zeigt Abholung und Test mit Alter
- [ ] Datenschutz: Die Sicherungen werden erst nach der Aufbewahrungszeit endgültig gelöscht (Server 3 Tage, NAS bis ca. 13 Monate), siehe `DATENSCHUTZ-ENTWURF.md`
