# Datensicherung einrichten: Schritt für Schritt

Diese Anleitung führt dich einmal komplett durch (etwa 1 bis 2 Stunden). Hintergründe, Sicherheitsmodell und Grenzen stehen in [`BACKUP.md`](BACKUP.md), der Neuaufbau im Ernstfall in [`WIEDERHERSTELLUNG.md`](WIEDERHERSTELLUNG.md).
Alles auf dem Server führst du selbst mit `sudo` aus; nichts davon macht Claude. Befehle sind zum Kopieren gedacht, `<…>` und Werte in `'…'` ersetzt du durch deine eigenen.

**Reihenfolge ist wichtig:** Schlüssel (1, 2) → **NAS-Snapshots (3) vor dem ersten Lauf** → Server (4 bis 6) → NAS-Abholung (7) → Wiederherstellungstest (8). Ohne Schritt 3 und 8 ist die Sicherung nicht abgenommen.

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

1. Skript auf das NAS bringen (auf deinem PC; `lx-labs` ist dein SSH-Alias des Servers):

```bash
scp lx-labs:lx-fampad/deploy/backup/nas/lx-fampad-pull.sh .
scp lx-fampad-pull.sh <nas-admin-benutzer>@<nas-adresse>:/volume1/backup/lx-fampad-pull.sh
```

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

## Fertig: Checkliste

- [ ] Haupt- und Ersatzschlüssel (privat) im Passwortmanager bzw. ausgedruckt an zwei Orten, **nicht** auf dem Server
- [ ] NAS-Snapshots laufen (14 Tage) oder zweite Kopie per Hyper Backup
- [ ] `systemctl list-timers lx-fampad-backup.timer` zeigt den Timer, `status` meldet `last_result=ok`
- [ ] Der erste Timer-Lauf (am Morgen danach) war erfolgreich: `journalctl -u lx-fampad-backup`
- [ ] NAS-Aufgabe 04:30 läuft, E-Mail bei Fehler ist getestet
- [ ] Wiederherstellungstest (Schritt 8) bestanden und eingetragen
- [ ] Optional: Swap eingerichtet
- [ ] Datenschutz: Die Sicherungen werden erst nach der Aufbewahrungszeit endgültig gelöscht (Server 3 Tage, NAS bis ca. 13 Monate), siehe `DATENSCHUTZ-ENTWURF.md`
