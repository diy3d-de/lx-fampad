# Deployment von lx-fampad (Debian 13, netcup-VPS)

lx-fampad läuft auf demselben VPS wie lx-labs.dev: eigener Caddy-Block, eigener Systembenutzer, eigener Dienst.
Grundeinrichtung des Servers (Benutzer `lx`, SSH-Schlüssel, ufw, Caddy, Node.js) steht in `lx-labs/deploy/README.md` und wird hier vorausgesetzt.

```
Browser/App ──HTTPS──▶ Caddy :443 ─┬─ familie.lx-labs.dev
                                   │    /api/*, /ws        ──▶ Node (lx-fampad) 127.0.0.1:4400 ──▶ PostgreSQL 17 (localhost)
                                   │    /releases/*        ──▶ /srv/fampad/releases   (Android-OTA: latest.json + APK)
                                   │    /.well-known/*     ──▶ /srv/fampad/well-known (assetlinks.json)
                                   │    /font-fallback/*   ──▶ /srv/fampad/font-fallback
                                   │    alles andere       ──▶ /srv/fampad/web/current (Flutter-Web-Build)
                                   └─ ntfy.familie.lx-labs.dev ──▶ ntfy 127.0.0.1:2586 (UnifiedPush)
```

Dateien in diesem Ordner:

- `Caddyfile` – Site-Block `familie.lx-labs.dev` mit strengen Sicherheits-Headern (ntfy liegt eigenständig in `ntfy/ntfy.caddy`)
- `lx-fampad.service` – systemd-Dienst der API (eigener Benutzer, gehärtet, Speicher-/Prozessgrenzen); `lx-fampad-migrate.service` führt vor jedem Start die Migrationen mit der Migrationsrolle aus; `einrichtung-auth.sh` richtet Schlüssel und Datenbank-Rollen ein
- `deploy.sh` – läuft auf dem Server: Code holen, Server bauen (`npm ci --ignore-scripts`), nur Produktivpakete übertragen, Dienst neu starten, Health-Check mit `"db":"ok"`
- `deploy-web.sh` – läuft auf dem PC: Prüfsummen prüfen, Flutter-Web bauen, `version.txt` (= `webVersion`) schreiben und versioniert hochladen
- `einrichtung-ntfy.sh` – richtet ntfy ein (Installation, Härtung, Token, `ntfy.caddy`; Abschnitt 7); `ntfy/server.yml` (deny-all), `ntfy/ntfy.caddy` (eigene Caddy-Datei)
- `backup/` – tägliche verschlüsselte Sicherung (age) und Einrichtung, Wiederherstellungstest, Pull-Skript für das NAS (Abschnitt "Backups"); `einrichtung-swap.sh` – Swapdatei

Verzeichnisse auf dem Server:

| Pfad | Inhalt | Besitzer |
| --- | --- | --- |
| `~/lx-fampad` | Git-Checkout (nur lesend per Deploy-Key) | `lx` |
| `/srv/fampad/server` | gebauter Server (`dist`, `drizzle`, `node_modules`) | `lx`, Gruppe `lx-fampad` |
| `/srv/fampad/server.prev` | Vorversion für den automatischen Rückfall von `deploy.sh` | `lx`, Gruppe `lx-fampad` |
| `/etc/caddy/conf.d/fampad.caddy` | Caddy-Konfiguration dieses Projekts (eingebunden, siehe Schritt 6) | `root` |
| `/srv/fampad/web/<version>` + `current` | Flutter-Web-Builds, `current` ist ein Symlink | `lx` |
| `/srv/fampad/releases/android` | `latest.json` und APK des Update-Kanals | `lx` |
| `/srv/fampad/well-known` | `assetlinks.json` (später `apple-app-site-association`) | `lx` |
| `/srv/fampad/font-fallback` | Fallback-Schriften für Flutter Web | `lx` |
| `/srv/fampad/files` | Dateiablage (später verschlüsselt) | `lx-fampad`, 0700 |
| `/etc/lx-fampad/env` | Konfiguration und Geheimnisse (Datenbank-Passwort) | `root:root`, 0600 |

---

## Einmalige Einrichtung

### 0. DNS (Cloudflare)

Zwei A-Einträge auf die Server-IP, beide **DNS only** (graue Wolke), wie bei lx-labs.dev:

| Name | Typ | Inhalt | Proxy-Status |
| --- | --- | --- | --- |
| `familie` | A | `<SERVER-IP>` | DNS only |
| `ntfy.familie` | A | `<SERVER-IP>` | DNS only |

### 1. PostgreSQL 17 (Debian-Repository) und Datenbank

Debian 13 liefert PostgreSQL 17. Der Server lauscht standardmäßig nur auf localhost; das so lassen (`listen_addresses` nicht ändern).

```bash
sudo apt install -y postgresql postgresql-client rsync
sudo -u postgres psql -c "select version();"        # muss PostgreSQL 17.x melden

# Passwort erzeugen und anzeigen (zum Einfügen in die nächsten Schritte; nicht in Befehlszeilen schreiben)
openssl rand -base64 24 | tr -d '/+='

# Rolle und Datenbank in einer psql-Sitzung. Das Passwort NICHT per psql -c / echo setzen: Befehlszeilen stehen in
# der Prozessliste, im Shell-Verlauf und (je nach log_statement) im PostgreSQL-Log. \password fragt ohne Anzeige ab.
sudo -u postgres psql
postgres=# CREATE ROLE lx_fampad LOGIN;           -- Laufzeitrolle; die Migrationsrolle lx_fampad_migrate legt einrichtung-auth.sh an (Schritt 5)
postgres=# \password lx_fampad
postgres=# CREATE DATABASE lx_fampad OWNER lx_fampad ENCODING 'UTF8';
postgres=# \q
```

### 2. Systembenutzer, Verzeichnisse, Konfiguration

```bash
sudo adduser --system --group --no-create-home --shell /usr/sbin/nologin lx-fampad
sudo usermod -aG lx-fampad lx                       # lx darf den Code in /srv/fampad/server ablegen

sudo mkdir -p /srv/fampad/{server,server.prev,web,releases/android,well-known,font-fallback,files} /etc/lx-fampad
sudo chown lx:lx-fampad /srv/fampad/server /srv/fampad/server.prev && sudo chmod 750 /srv/fampad/server /srv/fampad/server.prev
sudo chown -R lx:lx /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback
sudo chmod -R 755 /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback
sudo chown lx-fampad:lx-fampad /srv/fampad/files && sudo chmod 700 /srv/fampad/files
sudo chmod 755 /srv/fampad                           # Caddy muss web/releases lesen können

```

Nach `usermod` einmal ab- und wieder anmelden, damit die Gruppe gilt. Die Konfigurationsdatei folgt in Schritt 5 (sie braucht den Git-Checkout aus Schritt 4).

### 3. Node.js 24

Wie bei lx-labs (NodeSource 24). Gepinnt ist 24.21.0 (`server/.nvmrc`); `node --version` prüfen.

### 4. Code holen

Gleicher Weg wie bei lx-labs: eigener Deploy-Key (nur lesen) für das Repository `lx-fampad`.

```bash
ssh-keygen -t ed25519 -C "lx-fampad-server" -N "" -f ~/.ssh/id_ed25519_fampad
cat ~/.ssh/id_ed25519_fampad.pub     # auf GitHub als Deploy key eintragen (ohne Schreibrecht)
git clone git@github.com:<dein-github-name>/lx-fampad.git ~/lx-fampad
```

(Bei zwei Repositories auf einem Server die Schlüssel per `~/.ssh/config` mit je einem `Host`-Alias trennen.)

### 5. Konfiguration und Dienst einrichten

**Zuerst die Log-Aufbewahrung begrenzen** (ab dem ersten Start landen Client-IP-Adressen im Journal; Hintergrund: Abschnitt "Logs und Datenschutz" unten). Das gilt für alle Dienste des Servers, auch lx-labs:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nMaxRetentionSec=7day\n' | sudo tee /etc/systemd/journald.conf.d/lx-retention.conf
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

```bash
# Konfiguration: Vorlage ist server/.env.example. Die Datei enthält das Datenbank-Passwort: root:root, 0600.
# systemd liest sie als root (EnvironmentFile), der Dienst selbst und auch der Benutzer lx können sie nicht lesen.
sudo install -o root -g root -m 600 ~/lx-fampad/server/.env.example /etc/lx-fampad/env
sudoedit /etc/lx-fampad/env      # DATABASE_URL mit dem Passwort aus Schritt 1, FILES_DIR=/srv/fampad/files
sudo ls -l /etc/lx-fampad/env    # -rw------- root root

# Anmeldung (Phase 1a): erzeugt AUTH_SECRET_KEY, trennt die Datenbank-Rollen (Migration/Betrieb) und installiert BEIDE
# Einheiten (lx-fampad.service + lx-fampad-migrate.service). IMMER VOR dem ersten deploy.sh mit Phase-1-Code ausführen
# (sonst startet der Dienst ohne AUTH_SECRET_KEY nicht), Details: Abschnitt "Anmeldung und Datenbank-Rollen".
sudo bash ~/lx-fampad/deploy/einrichtung-auth.sh

# deploy.sh darf den Dienst ohne Passwort neu starten (nur genau diesen Befehl)
echo 'lx ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-fampad' | sudo tee /etc/sudoers.d/lx-fampad
sudo chmod 440 /etc/sudoers.d/lx-fampad
# nur wenn der Wetter-Dienst eingerichtet ist (Abschnitt 12): zusätzlich dessen Neustart erlauben
#   echo 'lx ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-fampad, /usr/bin/systemctl restart lx-fampad-weather' | sudo tee /etc/sudoers.d/lx-fampad
sudo visudo -cf /etc/sudoers.d/lx-fampad     # muss "parsed OK" melden; sonst Datei sofort löschen (ein Fehler kann sudo sperren)

# erstes Deployment: baut den Server, überträgt ihn und startet den Dienst (Migrationen laufen dabei)
bash ~/lx-fampad/deploy/deploy.sh
sudo systemctl enable lx-fampad
curl http://127.0.0.1:4400/api/v1/health      # → {"status":"ok","db":"ok"}
```

Der Dienst darf nur lokal sprechen (`IPAddressDeny=any`, `IPAddressAllow=localhost`: PostgreSQL und Caddy laufen auf demselben Server) und höchstens 1,5 Kerne nutzen (`CPUQuota=150%`). **Ausnahme später:** Web-Push (Phase 5) braucht ausgehende HTTPS-Verbindungen zu den Push-Diensten; dann die IP-Sperre in `lx-fampad.service` gezielt öffnen und hier vermerken. Startet der Dienst nach einer Änderung an diesen Zeilen nicht, zeigt `systemd-analyze security lx-fampad` und `journalctl -u lx-fampad` den Grund.

Der Port 4400, `HOST=127.0.0.1` und `NODE_ENV=production` stehen fest in `lx-fampad.service` (nicht in der env-Datei: `EnvironmentFile` überschreibt `Environment=`, deshalb fehlen sie in `server/.env.example`); dadurch kann `deploy.sh` den Health-Check ausführen, ohne die env-Datei zu lesen. Wer den Port ändert, muss `lx-fampad.service`, `deploy.sh` und `Caddyfile` gemeinsam anpassen. `deploy.sh` meldet erst "online", wenn der Health-Check `"db":"ok"` liefert (nicht nur "ok" ohne Datenbank).

`deploy.sh` sichert vor jedem Deployment die laufende Version in `/srv/fampad/server.prev`. Besteht der Health-Check nach dem Neustart nicht, spielt das Skript die Vorversion automatisch zurück und endet mit Fehler (Migrationen werden nicht zurückgedreht; sie sind nur vorwärts und rückwärtskompatibel).

Vor dem Start wendet `lx-fampad-migrate.service` die Migrationen an (mit der Migrationsrolle). Fehler stehen in `sudo journalctl -u lx-fampad -n 50`.

### Anmeldung und Datenbank-Rollen (Phase 1a)

Ab Phase 1a gibt es Konten. Dafür braucht der Server (alles erledigt `deploy/einrichtung-auth.sh`, idempotent, auch für eine **bestehende Installation**):

- **`AUTH_SECRET_KEY`** in `/etc/lx-fampad/env` (256 Bit, Base64): Hauptschlüssel für die TOTP-Verschlüsselung (AES-256-GCM) und die HMACs von Wiederherstellungs-Codes und Einladungs-PINs. Ohne ihn startet der Dienst in `production` nicht (fail-closed; `deploy.sh` spielt dann die Vorversion zurück). Er liegt **außerhalb der Datenbank**, darf nie geändert oder verloren gehen (sonst sind alle TOTP-Geheimnisse und Codes unbrauchbar) und gehört in die Datensicherung, getrennt vom Datenbank-Dump. Alternativ `AUTH_SECRET_KEY_FILE`.
- **Zwei Datenbank-Rollen:** `lx_fampad_migrate` (Eigentümer von Datenbank und Tabellen, darf DDL, nur für Migrationen) und `lx_fampad` (Laufzeit, nur SELECT/INSERT/UPDATE/DELETE; `ALTER DEFAULT PRIVILEGES` gibt Tabellen künftiger Migrationen automatisch dieselben Rechte). `DATABASE_URL` in `/etc/lx-fampad/env` bleibt die Laufzeitrolle; die Zugangsdaten der Migrationsrolle stehen als `MIGRATION_DATABASE_URL` nur in `/etc/lx-fampad/migrate.env` (`root:root`, 0600), die ausschließlich `lx-fampad-migrate.service` lädt. Der Dienst selbst kennt sie nicht.
- **`lx-fampad-migrate.service`** (oneshot, `Requires=` von `lx-fampad.service`) ersetzt das frühere `ExecStartPre`: Vor jedem Start laufen die Migrationen mit der Migrationsrolle. Die Einheit lädt **nur** `migrate.env` (nicht die env-Datei mit `AUTH_SECRET_KEY`); fehlt die Datei, scheitert sie mit klarer Meldung und damit auch der Start des Dienstes. `einrichtung-auth.sh` legt sie an und erzwingt bei jedem Lauf Besitzer und Rechte (`root:root`, 0600) beider Dateien.
- Passkeys: `WEBAUTHN_RP_ID` (Standard: Hostname von `PUBLIC_URL`, also `familie.lx-labs.dev`). Ein späterer Wechsel der RP-ID macht alle Passkeys unbrauchbar.

**Umstellung einer laufenden Installation:** `git pull`, dann direkt nacheinander

```bash
sudo bash ~/lx-fampad/deploy/einrichtung-auth.sh     # Schlüssel, Rollen, Einheiten (ändert den laufenden Dienst nicht)
bash ~/lx-fampad/deploy/deploy.sh                    # baut, migriert (Migration 0001) und startet neu
```

**Reihenfolge ist zwingend:** `einrichtung-auth.sh` VOR dem ersten `deploy.sh` mit Phase-1-Code. Ohne `AUTH_SECRET_KEY` startet der Dienst in `production` nicht, ohne `migrate.env` scheitert die Migrations-Einheit; `deploy.sh` spielt dann zwar die Vorversion zurück, die Migration 0001 hätte aber trotzdem schon die Tabellen verändert, falls sie vorher lief.

**Vorprüfung für Altdaten (Migration 0001):** Die Migration ergänzt zusammengesetzte Fremdschlüssel `(family_id, user_id)` -> `memberships` für `devices`, `sessions`, `ws_tickets`, `event_attendees`, `message_reactions` und `message_reads`. Zeilen ohne passende Mitgliedschaft lassen die Migration scheitern (sie läuft in einer Transaktion und wird dann vollständig zurückgerollt; der Dienst startet nicht, `deploy.sh` spielt die Vorversion zurück). In Phase 0 waren diese Tabellen leer, bei einer Installation mit Testdaten vorher prüfen (muss in jeder Zeile 0 ergeben):

```bash
sudo -u postgres psql lx_fampad -c "
select 'devices' t, count(*) from devices x left join memberships m on m.family_id = x.family_id and m.user_id = x.user_id where m.id is null
union all select 'sessions', count(*) from sessions x left join memberships m on m.family_id = x.family_id and m.user_id = x.user_id where m.id is null
union all select 'event_attendees', count(*) from event_attendees x left join memberships m on m.family_id = x.family_id and m.user_id = x.user_id where m.id is null
union all select 'message_reactions', count(*) from message_reactions x left join memberships m on m.family_id = x.family_id and m.user_id = x.user_id where m.id is null
union all select 'message_reads', count(*) from message_reads x left join memberships m on m.family_id = x.family_id and m.user_id = x.user_id where m.id is null;"
```

Verwaiste Testzeilen vorher löschen (`delete from sessions x where not exists (select 1 from memberships m where m.family_id = x.family_id and m.user_id = x.user_id);`, entsprechend für die übrigen Tabellen); `ws_tickets` gibt es vor der Migration nicht.

Zwischen beiden Schritten sollte der Server nicht neu starten: die alte Programmversion kennt die getrennten Rollen nicht (sie würde beim Start die Migrationen mit der Laufzeitrolle versuchen und scheitern). Die laufende Version arbeitet mit der Laufzeitrolle weiter, weil sie nur DML braucht.

#### Erster Admin (Bootstrap)

Es gibt genau eine Familie und keine offene Registrierung. Den ersten Admin legt der Betreiber auf dem Server an (nach dem Deployment):

```bash
sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --family "Familie Beispiel" [--pin]
```

Das Skript legt Familie und eine Einladung für den ersten Admin an und gibt den Link `https://familie.lx-labs.dev/#/einladung/<Token>` aus (Einmaltoken, 7 Tage gültig; in der Datenbank steht nur der SHA-256-Hash; das Token steht im URL-Fragment und taucht in keinem Log auf). `--pin` verlangt zusätzlich eine 6-stellige PIN, die getrennt weitergegeben wird. Ein erneuter Aufruf vor dem Einlösen ersetzt die Einladung; nach dem Einlösen bricht er ab (`already_bootstrapped`).

**Notfall** (der einzige Admin hat Passkey/Passwort und alle Wiederherstellungs-Codes verloren):

```bash
sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --reset admin@example.org
```

widerruft alle Anmeldedaten, Sitzungen und Codes dieses Mitglieds und gibt einen neuen Einladungslink für dasselbe Konto aus.

**Aufräumen:** Beim Start und danach stündlich leert der Dienst die IP-Spalte im Audit-Log (älter als 7 Tage), löscht Audit-Einträge nach `AUDIT_RETENTION_DAYS` (Standard 365) sowie abgelaufene Sitzungen, Challenges, Tickets und Fehlversuche und protokolliert abgelaufene Einladungen.

### 6. Caddy

Festgelegter Pfad: die Konfiguration liegt in **`/etc/caddy/conf.d/fampad.caddy`**; das Haupt-Caddyfile (`/etc/caddy/Caddyfile`, gehört dem lx-labs-Deploy) bindet sie mit der Zeile `import /etc/caddy/conf.d/*.caddy` ein. Reihenfolge zum Schutz von lx-labs.dev: erst sichern, dann Zeile anfügen, prüfen, bei Fehler sofort zurückkopieren, erst danach neu laden.

**Vorab prüfen:** Das Haupt-Caddyfile von lx-labs darf kein globales `log` setzen (kein `log` im Optionsblock `{ … }` ganz oben und keines außerhalb eines Site-Blocks). Sonst entstünden auch für lx-fampad Zugriffslogs mit IP-Adressen, die der Datenschutz-Entwurf ausschließt. Prüfen: `grep -n '^[[:space:]]*log' /etc/caddy/Caddyfile`; ein `log` nur im Site-Block von lx-labs.dev betrifft die Familie nicht.

```bash
sudo mkdir -p /etc/caddy/conf.d
sudo cp ~/lx-fampad/deploy/Caddyfile /etc/caddy/conf.d/fampad.caddy

# 1. Sicherung des Haupt-Caddyfiles (jedes Mal frisch, mit Zeitstempel; zurückgespielt wird nur diese)
BAK="/etc/caddy/Caddyfile.vor-fampad.$(date +%Y%m%d-%H%M%S)"
sudo cp -p /etc/caddy/Caddyfile "$BAK"
# 2. Zeile anfügen (nur, wenn sie noch fehlt)
grep -qsE '^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy' /etc/caddy/Caddyfile \
  || echo 'import /etc/caddy/conf.d/*.caddy' | sudo tee -a /etc/caddy/Caddyfile
# 3. Prüfen; bei Fehler sofort zurückkopieren (und nichts neu laden)
if caddy validate --config /etc/caddy/Caddyfile; then
  sudo systemctl reload caddy
else
  sudo cp -p "$BAK" /etc/caddy/Caddyfile
  echo "Caddy-Prüfung fehlgeschlagen, Haupt-Caddyfile zurückgesetzt"
fi
```

Danach lx-labs.dev prüfen (`curl -sI https://lx-labs.dev | head -1`).

**Achtung: Ein Deploy von lx-labs entfernt die Import-Zeile.** Der lx-labs-Deploy überschreibt `/etc/caddy/Caddyfile` aus `lx-labs/deploy/Caddyfile`. Dauerhaft lösen lässt sich das nur dort. **Vorschlag für `lx-labs/deploy/Caddyfile`** (dieses Repository ändert das lx-labs-Repository nicht; der Eintrag ist dort von Hand vorzunehmen), am Ende der Datei:

```caddy
# lx-fampad (Repository lx-fampad, Datei wird von dessen deploy/ gepflegt)
import /etc/caddy/conf.d/*.caddy
```

Ein Glob-Import ohne Treffer ist für Caddy kein Fehler. Bis der Vorschlag umgesetzt ist: nach jedem lx-labs-Deploy `deploy.sh` (oder `grep conf.d /etc/caddy/Caddyfile`) ausführen. `deploy.sh` warnt, wenn die Zeile fehlt; dann Schritt 1 bis 3 oben wiederholen.

Caddy holt danach die Zertifikate für beide Domains. Bis die Web-App hochgeladen ist (Schritt 8), antwortet `familie.lx-labs.dev` unter `/` mit 404; `/api/v1/health` geht sofort.

### 7. ntfy (UnifiedPush)

Ein Skript richtet alles ein, idempotent, mit demselben Schutz für lx-labs.dev wie Schritt 6. **In tmux oder screen starten** (oder mit `sudo systemd-run --scope bash …`), damit ein SSH-Abbruch den Lauf nicht mitten in der Caddy-Änderung beendet; fängt das Skript ein HUP/INT/TERM, läuft der Rückfall trotzdem.

```bash
sudo bash ~/lx-fampad/deploy/einrichtung-ntfy.sh --dry-run   # nur prüfen, verändert nichts
sudo bash ~/lx-fampad/deploy/einrichtung-ntfy.sh
```

**Voraussetzungen:** Schritt 6 ist erledigt (Importzeile `import /etc/caddy/conf.d/*.caddy` im Haupt-Caddyfile; fehlt sie, bricht das Skript ab und ergänzt sie **nicht** selbst, dann zuerst `einrichtung-2.sh`), `lx-labs.dev` antwortet, und der DNS-Eintrag `ntfy.familie` (A, ggf. AAAA; DNS only) zeigt auf eine globale Adresse dieses Servers. Das Skript prüft das vor jeder Änderung und bricht sonst mit klarer Meldung ab.

**Reihenfolge im Skript:**

1. Prüfungen (Importzeile, `lx-labs.dev`, DNS-Adressen gegen die lokalen globalen Adressen, Port 2586 frei, `ntfy.familie.lx-labs.dev` ist in keiner anderen Caddy-Datei schon definiert). Bei einem Fehler wird nichts verändert.
2. Installation von ntfy **2.28.0** (exakt gepinnt, Release vom 27.08.2026) aus dem offiziellen apt-Repository `archive.ntfy.sh`. Gewählt gegenüber dem GitHub-.deb, weil das Repository signiert ist: Das Skript vergleicht den Schlüssel-Fingerabdruck `55BA 774A 6F5E E674 31E4 B6B7 CFDB 962D 4F1E C4AF` (vorher auf <https://docs.ntfy.sh/install/> gegenlesen) und bricht bei Abweichung ab; die GitHub-Releases haben keine Signatur. `/etc/apt/preferences.d/ntfy` sorgt dafür, dass aus diesem Repository nur das Paket `ntfy` kommt (Pin-Priority 1 für alles andere). Führt das Repository die Version nicht mehr, fällt das Skript auf das Release-.deb mit gepinnter SHA-256 zurück. Danach `apt-mark hold ntfy`.
3. Systembenutzer `ntfy`, `/var/lib/ntfy` (Benutzerdatenbank), `/var/cache/ntfy` (Nachrichten-Cache 12 h, **Anhänge aus**), `/etc/ntfy/server.yml` aus `deploy/ntfy/server.yml` (deny-all, nur `127.0.0.1:2586`, `behind-proxy`, Rate-Limits; eine abweichende bisherige Datei wird mit Zeitstempel gesichert), systemd-Härtung als Drop-in `/etc/systemd/system/ntfy.service.d/haertung.conf`, Dienst starten und lokal prüfen.
4. ntfy-Benutzer `fampad-server` (Rolle `user`, kein Admin, Passwort wird nicht gespeichert) mit **Token**, das nur auf `fampad-*` schreiben darf (zum Publizieren). Das Token liegt in `/etc/lx-fampad/ntfy-token` (root, 0600) und erscheint weder im Log noch in der Prozessliste. Lokale Rechteprobe: anonym 401/403, `fampad-*` 200, anderes Topic 401/403.
5. Caddy: nur `/etc/caddy/conf.d/ntfy.caddy` aus `deploy/ntfy/ntfy.caddy` (eigenständige Datei, nicht `fampad.caddy`; `deploy.sh` und `einrichtung-2.sh` fassen sie nie an). Das Haupt-Caddyfile wird **nie geschrieben**, nur zum Nachlesen gesichert (`/etc/caddy/Caddyfile.vor-ntfy.<Zeitstempel>`). Ablauf: die Kandidat-Datei zuerst allein mit `caddy validate` prüfen, dann atomar installieren (erst `ntfy.caddy.neu`, dann umbenennen), danach Vollvalidierung mit allem Importierten, erst dann `reload`, danach `https://lx-labs.dev`, `https://familie.lx-labs.dev/api/v1/health` und `https://ntfy.familie.lx-labs.dev` (inkl. Rechteprobe) prüfen.

**Bei Fehlern ab Schritt 5** (Validierung, Reload, eine der Prüfungen, Strg+C, SSH-Abbruch): automatischer Rückfall. Die vorherige `ntfy.caddy` kommt zurück, gab es keine, wird sie entfernt; dann `reload` und Prüfung von `lx-labs.dev`. Fehler in Schritt 1 bis 4 lassen Caddy unberührt (ntfy selbst bleibt dann installiert; das Skript lässt sich gefahrlos wiederholen). Danach Ursache klären (`journalctl -u caddy -n 50`, `journalctl -u ntfy -n 50`) und erneut starten. **Nach einem Zertifikatsfehler mindestens 1 Stunde warten** (Let's-Encrypt-Limit für Fehlversuche), vorher DNS prüfen.

**In `/etc/lx-fampad/env` eintragen** (das Skript ändert die Datei nicht und gibt das Token nicht aus). Der Dienst `lx-fampad` läuft mit `IPAddressDeny=any` und darf nur nach localhost, deshalb ist `NTFY_URL` die Loopback-Adresse, nicht die öffentliche URL. systemd liest die env-Datei als root; `/etc/lx-fampad/ntfy-token` muss für den Dienst-Benutzer `lx-fampad` nicht lesbar sein. Das Skript nennt am Ende diesen Befehl (hängt nur an, wenn `NTFY_*` fehlt, und ergänzt vorher einen fehlenden Zeilenumbruch am Dateiende, damit `AUTH_SECRET_KEY` nie verfälscht wird):

```bash
sudo sh -c 'f=/etc/lx-fampad/env; if grep -qE "^NTFY_(URL|TOKEN)=" "$f"; then echo "NTFY_* schon vorhanden, nichts geändert"; else [ -z "$(tail -c1 "$f")" ] || echo >> "$f"; printf "NTFY_URL=http://127.0.0.1:2586\nNTFY_TOKEN=%s\n" "$(cat /etc/lx-fampad/ntfy-token)" >> "$f"; fi'
sudo systemctl restart lx-fampad
```

Der Server liest die Werte seit dem Push-Versand (Branch phase-push): ohne beide Werte ist Push still aus (ein Hinweis im Log). Mit beiden Werten und dem Skript aus „Push für die Handys“ unten ist Push an.

**Prüfen:**

```bash
sudo systemctl status ntfy
curl -fsS https://ntfy.familie.lx-labs.dev/v1/health                                          # {"healthy":true}
curl -s -o /dev/null -w '%{http_code}\n' -d x https://ntfy.familie.lx-labs.dev/fampad-test    # 401 oder 403 (anonym verboten)
sudo -u ntfy ntfy access --config /etc/ntfy/server.yml                                        # Rechteübersicht
sudo ls -l /etc/lx-fampad/ntfy-token                                                          # -rw------- root root
curl -sI https://lx-labs.dev | head -1
```

**Token rotieren:** Das Token läuft nicht ab. Neues Token: `sudo -u ntfy ntfy token --config /etc/ntfy/server.yml list` (altes ansehen), `sudo rm /etc/lx-fampad/ntfy-token`, Skript erneut starten (legt ein neues an), danach das alte widerrufen (`sudo -u ntfy ntfy token --config /etc/ntfy/server.yml remove fampad-server <altes-tk_…>`), `NTFY_TOKEN` in der env-Datei ersetzen und `lx-fampad` neu starten.

**Version aktualisieren:** Aktuell ist **2.28.0** gepinnt; **2.29.0** darf frühestens ab 21.10. (14 Tage nach Veröffentlichung) übernommen werden. Sicher aktualisieren: Release-Datum prüfen, neuen Fingerabdruck und Version auf docs.ntfy.sh gegenlesen, dann `NTFY_VERSION` (und `NTFY_DEB_SHA256` für den Fallback) im Skript anheben, per PR mergen; auf dem Server `sudo apt-mark unhold ntfy && sudo apt-get update && sudo apt-get install ntfy=<neu> && sudo apt-mark hold ntfy && sudo systemctl restart ntfy`, anschließend `curl https://ntfy.familie.lx-labs.dev/v1/health`. Das Skript lässt eine andere installierte Version unangetastet.

**Rückbau:** `sudo rm /etc/caddy/conf.d/ntfy.caddy && sudo systemctl reload caddy` (lx-labs.dev und familie bleiben unberührt), `sudo systemctl disable --now ntfy`. Daten liegen unter `/var/lib/ntfy`.

**Push für die Handys (UnifiedPush):** Standard von ntfy ist **deny-all**, auch anonym. Das Skript `einrichtung-ntfy-up.sh` (nur ntfy-CLI, **kein** Caddy, `/etc/lx-fampad/env` bleibt unberührt, idempotent, `--dry-run`) setzt die Rechte für die `up*`-Topics der Handys:

```bash
sudo bash ~/lx-fampad/deploy/einrichtung-ntfy-up.sh --dry-run   # nur prüfen
sudo bash ~/lx-fampad/deploy/einrichtung-ntfy-up.sh
```

- `fampad-server` (Token des Familien-Servers) bekommt **write-only** auf `up*` (zusätzlich zu `fampad-*`): Der Server sendet die Wecker mit Token, **nie anonym**.
- Neuer Benutzer `fampad-family` bekommt **read-only** auf `up*` mit einem **gemeinsamen, zufällig erzeugten Passwort** (liegt root-only in `/etc/lx-fampad/ntfy-family-password`, wird nie angezeigt). Die ntfy-App der Handys ist nur Empfänger (Verteiler) und abonniert ihr `up<Zufall>`-Topic; sie braucht deshalb Leserecht, aber kein Schreibrecht.
- **Begründung der Entscheidung:** Anonymes Lesen oder Schreiben auf `up*` ist unnötig offen. Die Topic-Namen (`up` + 12 Zufallszeichen) sind zwar nicht erratbar, sollen aber nicht die einzige Hürde sein. Ein gemeinsamer Lese-Benutzer für die Familie genügt, weil er nichts senden kann und die Wecker keinen Inhalt tragen; je Handy ein Benutzer wäre mehr Pflegeaufwand ohne Gewinn. **Passwort wechseln mit `--rotate` nach jedem Entfernen eines Mitglieds und wenn ein Handy verloren geht**, danach in allen ntfy-Apps der Familie neu eintragen (das Passwort ist ein gemeinsames Familien-Konto: Wer es kennt, kann die inhaltslosen Wecker der `up*`-Topics lesen, deren Namen er kennt).
- Das Skript prüft zum Schluss lokal und über HTTPS: anonym 401/403 (Lesen und Schreiben), Server schreibt 200, `fampad-family` liest 200 und schreibt 401/403 sowie liest `fampad-*` nicht.
- Syntax gegen `binwiederhier/ntfy:v2.28.0` im Docker-Container geprüft (`ntfy access --config CFG USER TOPIC PERM`, Flags vor dem Unterbefehl; `ntfy user change-pass` liest `NTFY_PASSWORD`).

**Was jede Person in der ntfy-App eintragen muss** (die App auf dem Handy; das Passwort gibt der Betreiber persönlich weiter, es steht per `sudo cat /etc/lx-fampad/ntfy-family-password` bereit):

1. ntfy-App installieren, **bevorzugt aus F-Droid** (oder GitHub-Release): Diese Fassung hat keine Firebase-Bestandteile. Die Fassung aus Google Play bringt Google-Dienste (Firebase) mit; sie funktioniert, passt aber nicht zum Ziel „kein Google“. Keinen eingebetteten FCM-Verteiler benutzen.
2. In der ntfy-App: Einstellungen, **Standardserver** auf `https://ntfy.familie.lx-labs.dev` stellen, **bevor** in lx-fampad Push eingeschaltet wird. Sonst liegt der UnifiedPush-Endpunkt auf ntfy.sh, und der Familien-Server lehnt ihn ab (`invalid_endpoint`).
3. In der ntfy-App Benutzer `fampad-family` und das Passwort eintragen (Einstellungen, Benutzer verwalten).
4. In lx-fampad: Profil, **Benachrichtigungen**, einschalten, dann **Test-Wecker senden**.
5. Akku: ntfy und lx-fampad **unbegrenzt/ohne Einschränkung** laufen lassen. Samsung: Einstellungen, Akku, Hintergrundnutzungsbegrenzungen, „Nie schlafende Apps“ (beide Apps eintragen) und „Automatische Sperre“ für diese Apps abschalten.

**Hinweis zu Fremd-Weckern:** Das Plugin hängt eine exportierte Empfänger-Komponente in das Manifest (Verteiler sind fremde Apps). Sie verwirft jede Nachricht ohne gültiges Registrierungs-Token (zufällig je Registrierung, nur dem Verteiler bekannt; Quelltext `MessagingReceiver.onReceive` der Connector-Bibliothek geprüft). Zusätzlich drosselt die App Hintergrund-Abgleiche auf einen je 10 s und `MainActivity` übernimmt keine Start-Argumente aus Intents.

**Server-Betrieb Push:** `NTFY_URL`, `NTFY_TOKEN` (siehe oben) und optional `NTFY_PUBLIC_HOST` (Standard `ntfy.familie.lx-labs.dev`: Host, den gemeldete Endpunkte haben müssen). Der Wecker geht per Loopback an `NTFY_URL` (der Dienst hat `IPAddressDeny=any` mit `IPAddressAllow=localhost`). Migration `0009_push` kommt mit dem normalen `deploy.sh`. Prüfen: `journalctl -u lx-fampad | grep -i push` (kein „Push ist aus“); in der App Profil, Benachrichtigungen, Test-Wecker.

### 8. Web-App hochladen

Auf dem PC (Flutter 3.47.6 installiert, Git Bash/WSL, SSH-Alias `lx-labs`):

```bash
deploy/deploy-web.sh
```

Das Skript baut mit `--no-web-resources-cdn`, lädt nach `/srv/fampad/web/<version>` und schaltet `current` um. Zurückrollen: auf dem Server `cd /srv/fampad/web && ln -sfn <alte-version> current`.

**Prüfen (Pflicht vor dem ersten Echtbetrieb):** Seite in Chrome öffnen, Entwicklerwerkzeuge → Netzwerk: Es darf **nichts** von `fonts.gstatic.com`, `gstatic.com` oder anderen Fremddomains geladen werden. In der Konsole: `crossOriginIsolated` muss `true` sein (sonst fehlt COOP/COEP, drift fällt auf IndexedDB zurück).

**Fallback-Schriften:** `web/flutter_bootstrap.js` verweist `fontFallbackBaseUrl` auf `https://familie.lx-labs.dev/font-fallback/`. Dort müssen die Noto-Schriften liegen, die Flutter bei fehlenden Zeichen (z. B. Emoji) nachlädt. Welche Dateien nötig sind, zeigt der Netzwerk-Tab, wenn ein Emoji in der App erscheint (404-Anfragen an `/font-fallback/...`); die Dateien aus dem gleichnamigen Pfad von `fonts.gstatic.com/s/` einmalig herunterladen und mit gleicher Pfadstruktur ablegen. Ohne diese Dateien werden solche Zeichen nur als Kästchen dargestellt, es gibt aber keinen Fremdabruf.

### 9. Passkey- und Update-Dateien (ab Phase 1)

- `/srv/fampad/well-known/assetlinks.json` mit dem SHA-256-Fingerprint des **Release-Signaturschlüssels** der Android-App (`dev.lx_labs.fampad`). Vorlage: `deploy/assetlinks.json.template` (Platzhalter ersetzen). Ablauf **Android-Zuordnung (Passkeys und App-Links)**:
  1. Fingerprint des Release-Schlüssels ermitteln: aus dem Release-Workflow (Schritt "Signatur prüfen, Prüfsumme berechnen", Zeile `SHA-256` des Zertifikats) oder `keytool -list -v -keystore <keystore> -alias <alias>` (Zeile `SHA256:`).
     **In der Produktion steht NUR der Release-Fingerprint** in `assetlinks.json` und in `WEBAUTHN_ORIGINS`. Der Debug-Schlüssel (`~/.android/debug.keystore`, Passwort `android`) ist öffentlich bekannt: Jeder kann damit eine App mit demselben Paketnamen bauen und signieren. Stünde er in der Produktion, könnte so eine fremde App Passkeys der Domain nutzen und Einladungs-Links übernehmen. Debug-Builds testet man gegen eine **getrennte Testinstanz** (eigene Domain/Subdomain, eigene `assetlinks.json` und `WEBAUTHN_ORIGINS` mit dem Debug-Fingerprint, nie dieselbe Datenbank).
  2. Datei als `/srv/fampad/well-known/assetlinks.json` ablegen und prüfen: `curl -s https://familie.lx-labs.dev/.well-known/assetlinks.json` (Content-Type JSON, kein Redirect). Sie muss beide Beziehungen enthalten (die Vorlage tut das): `delegate_permission/common.get_login_creds` (Passkeys) und `delegate_permission/common.handle_all_urls` (App-Links, Schritt 5). Google prüft die Datei beim ersten Passkey-Aufruf; ein Zwischenspeicher kann Änderungen verzögern.
  3. **Server:** Die Android-App hat eine eigene WebAuthn-Origin `android:apk-key-hash:<Hash>`. Sie muss in `WEBAUTHN_ORIGINS` stehen (`/etc/lx-fampad/env`, kommagetrennt; **ohne sie lehnt der Server jeden Passkey der App ab**). `<Hash>` = SHA-256-Fingerprint des **Release**-Schlüssels als Base64url ohne Auffüllung, z. B. `echo AABBCC…(Hex ohne Doppelpunkte) | xxd -r -p | basenc --base64url | tr -d =`. Danach `sudo systemctl restart lx-fampad`. Nur ein Eintrag (Release); Debug-Origins nur auf der Testinstanz.
  4. Die App-RP-ID ist `familie.lx-labs.dev` (`WEBAUTHN_RP_ID`); der Browser nutzt `https://familie.lx-labs.dev` (`PUBLIC_URL`). Erst nach 2. und 3. funktionieren Passkeys in der App; bis dahin Passwort + TOTP. Passkeys brauchen Google Play-Dienste und ein eingerichtetes Google-Konto/Passwortmanager.
  5. **Verifizierte App-Links (`autoVerify`):** Der Einladungs-Intent-Filter in `app/android/app/src/main/AndroidManifest.xml` trägt `android:autoVerify="true"` für `https://familie.lx-labs.dev/`. Android prüft beim Installieren (und später gelegentlich), ob `/.well-known/assetlinks.json` die `handle_all_urls`-Beziehung mit dem Fingerprint der installierten App enthält, und öffnet Einladungslinks dann direkt in der App, ohne Auswahldialog. **Reihenfolge:** zuerst `assetlinks.json` ausliefern und mit `curl` prüfen (Schritt 2), **danach** die App mit `autoVerify` installieren bzw. aktualisieren; sonst schlägt die Prüfung beim Installieren still fehl (der Link öffnet dann weiter im Browser bzw. mit Nachfrage). Prüfen auf einem Gerät mit `adb`: `adb shell pm get-app-links dev.lx_labs.fampad` (Status `verified` für `familie.lx-labs.dev`); neu anstoßen: `adb shell pm verify-app-links --re-verify dev.lx_labs.fampad`. Auch verifizierte Links verlassen sich nicht auf das Fragment: Android reicht es an die App durch, die es liest (`MainActivity.linkAus`). Host und Pfad stehen in `AndroidManifest.xml`, `MainActivity.kt` und (als `INVITE_HOST`) in `lib/constants.dart`; bei einem Domainwechsel alle drei ändern.
  6. **Berechtigungen des Passkey-Pakets:** `passkeys_android` bringt `CREDENTIAL_MANAGER_SET_ORIGIN` mit. Das ist eine privilegierte Berechtigung für Browser und System-Apps, die den Origin einer fremden Seite setzen; eine normale App bekommt sie nie, und das Paket setzt keinen Origin (geprüft im Quelltext). Sie ist deshalb im Manifest mit `tools:node="remove"` entfernt. Passkeys der App laufen über die App-Origin `android:apk-key-hash:…` (Schritt 3) und sind davon nicht betroffen. Nach einem Update des Pakets `passkeys` kurz prüfen, ob es neue Berechtigungen anfordert (`aapt dump permissions` auf der APK). **Ungeprüft auf einem Gerät** (kein Android-Build in dieser Umgebung): Nach dem ersten Release-Build Passkey anlegen und anmelden testen.
  7. **Datensicherung:** `allowBackup="false"` plus leere Regeln (`res/xml/data_extraction_rules.xml`, `res/xml/backup_rules.xml`) schließen Cloud-Backup und Geräte-Übertragung vollständig aus. Anmeldedaten liegen im Android Keystore und würden nach einer Wiederherstellung ohnehin unlesbar sein.
- `/srv/fampad/releases/android/latest.json` und `dev-lx_labs-fampad-<version>.apk` (erzeugt vom Release-Workflow, Abschnitt 10). **Erst hochladen, wenn der echte Update-Schlüssel eingebaut ist:** In `app/lib/constants.dart` steht ein Platzhalter-Schlüssel (`kUpdatePublicKey`), zu dem es keinen privaten Schlüssel gibt; die App lehnt dann jedes Manifest ab. Ablauf:
  1. Schlüssel erzeugen (außerhalb des Repositories): `node tools/update-manifest.mjs keygen ~/lx-update-key.pem`; öffentlichen Schlüssel in `kUpdatePublicKey` und eine neue `kUpdateKeyId` eintragen, den privaten als CI-Secret `UPDATE_SIGNING_KEY` hinterlegen.
  2. App mit dem neuen Schlüssel bauen, signieren: `node tools/update-manifest.mjs sign --apk … --version … --version-code … --key-id … --out latest.json` (Näheres: `tools/README.md`; normalerweise erledigt das der Release-Workflow, Abschnitt 10).
  3. APK und `latest.json` nach `/srv/fampad/releases/android/` legen, **APK zuerst**, dann `latest.json`.
  4. **Stabiler Download-Link:** Die APK zusätzlich als `lx-familyhub-latest.apk` im selben Ordner ablegen (Kopie, kein Symlink; z. B. `cp dev-lx_labs-fampad-<version>.apk lx-familyhub-latest.apk` auf dem Server, oder die Datei beim Upload unter diesem Namen hochladen, ebenfalls vor `latest.json`). Die App nennt diesen Link in der Einladung, im Willkommenshinweis und unter Profil > Über (`kApkDownloadUrl` in `constants.dart`); er enthält nie ein Token. Bei jedem Release neu überschreiben, sonst verteilt der Link eine alte Version. Prüfen: `curl -sI https://familie.lx-labs.dev/releases/android/lx-familyhub-latest.apk` (200, `Content-Type: application/vnd.android.package-archive`, `Content-Length` wie die Versions-APK). Caddy (`/releases/*`) liefert die Datei bereits aus und setzt den APK-Content-Type; ein `Content-Disposition` gibt es nicht, Android-Browser laden die APK trotzdem herunter (optional `header @apk Content-Disposition "attachment"`, nur nach Rückfrage und über die validierenden Skripte).
  Der private Schlüssel gehört nie in das Repository und nie auf den Server.

---

### 10. Android-Release per GitHub Actions (APK bauen, signieren, ausliefern)

Der Workflow `.github/workflows/release.yml` läuft bei einem Tag `v*` (z. B. `v0.2.0`) oder manuell (Actions > "Release (Android)" > Run workflow, Version ohne `v`). Ablauf:

**Vor dem Tag die Version setzen:** `version:` in `app/pubspec.yaml` (z. B. `0.4.0+4000`; Build-Nummer = versionCode = major*1000000 + minor*1000 + patch) und `version` in `server/package.json` und `server/package-lock.json` (beide Stellen oben) auf die Release-Version bringen und committen. Der Job **build** bricht ab, wenn pubspec.yaml oder package.json nicht zur Release-Version (Tag bzw. Eingabe) passen; ebenso `deploy/deploy-web.sh <version>` (oder `RELEASE_VERSION=<version>`; ohne Angabe gilt ein Git-Tag auf HEAD, gibt es keinen, nur eine Warnung). Die Web-App zeigt dann `<version>` und die Build-Kennung (`<version>-<Datum+Uhrzeit>`), unter Profil > Über getrennt.

1. **build**: Version prüfen, Lockfile erzwingen, build_runner, analyze, test, dann `flutter build apk --release` mit dem Android-Schlüssel aus den Secrets (`key.properties` entsteht erst im Job und wird danach gelöscht) und `--dart-define` für `API_BASE`, `INVITE_HOST` und `RELEASES_BASE` (`https://familie.lx-labs.dev`). `versionName` = Tag, `versionCode` = `major*1000000 + minor*1000 + patch` (0.2.0 gibt 2000); der Wert aus `pubspec.yaml` wird dabei überschrieben. Danach `apksigner verify` und SHA-256. Dateiname: `dev-lx_labs-fampad-<version>.apk` (passt zur Namensprüfung der App).
2. **sign** (Environment `release`, manuelle Freigabe): prüft, dass `kUpdateKeyId`/`kUpdatePublicKey` in `constants.dart` echt sind und zum Secret `UPDATE_SIGNING_KEY` passen, erzeugt und signiert `latest.json`. Nur dieser Job sieht den Update-Schlüssel.
3. **draft**: legt einen **Release-Entwurf** mit APK, `.sha256` und `latest.json` an (nichts wird veröffentlicht).
4. **deploy** (optional, nur manuell mit Häkchen "deploy_vps", Environment `vps-deploy` mit Freigabe): lädt auf den VPS hoch. Der stabile Download-Link `lx-familyhub-latest.apk` (Abschnitt 9, Schritt 4) wird dabei **nicht** automatisch angelegt (rrsync erlaubt nur Schreiben); nach jedem Release von Hand als Kopie der neuen APK ablegen.

**Entscheidung zur Auslieferung:** Der Upload ist als Option eingebaut, standardmäßig aus. Begründung: Der Schlüssel liegt als GitHub-Secret außerhalb des Servers und ist auf dem Server per `authorized_keys` auf `rrsync -wo /srv/fampad/releases/android` beschränkt (nur Schreiben in genau diesen Ordner, keine Shell, kein Lesen, kein Löschen). Ein gestohlener Schlüssel kann daher keinen Code ausführen und keine gültig signierte Aktualisierung erzeugen (dazu fehlt `UPDATE_SIGNING_KEY`); das Restrisiko ist, dass jemand `latest.json` mit Unsinn überschreibt (die App lehnt es ab, Updates fallen aus). Wer das nicht will, lässt die Option aus und lädt den Entwurf von Hand hoch (APK zuerst, `sha256sum -c`, dann `latest.json`; `scp` nach `/srv/fampad/releases/android/`). Der Upload prüft vorher SHA-256 (Datei gegen Manifest), schreibt die APK zuerst und `latest.json` zuletzt; rsync legt jede Datei über eine Temp-Datei an und benennt sie um, daher erscheint sie vollständig oder gar nicht.

**Wichtig:** `applicationId` (`dev.lx_labs.fampad`) und der Android-Keystore dürfen **nie** geändert werden. Mit einem anderen Schlüssel lässt sich die App nicht mehr über die installierte Version aktualisieren; geht der Keystore verloren, hilft nur Deinstallieren und Neuinstallieren (lokale Daten weg). Keystore und Passwörter zusätzlich offline sichern.

**Einmalig vorbereiten (Reihenfolge des ersten Releases):**

1. Android-Keystore erzeugen (außerhalb des Repositories):
   ```bash
   keytool -genkeypair -v -keystore ~/lx-fampad-release.jks -alias lxfampad -keyalg RSA -keysize 4096 -validity 10000
   base64 -w0 ~/lx-fampad-release.jks      # Ausgabe = Secret ANDROID_KEYSTORE_BASE64
   ```
2. Update-Schlüssel erzeugen: `node tools/update-manifest.mjs keygen ~/lx-update-key.pem` (siehe `tools/README.md`). Den öffentlichen Schlüssel in `kUpdatePublicKey` und eine echte `kUpdateKeyId` (Textwert, z. B. `'fampad-2026-1'`) in `app/lib/constants.dart` eintragen, committen. **Erst damit nimmt die App Manifeste an.**
3. Secrets anlegen (Repository > Settings > Secrets and variables > Actions):

   | Secret | Inhalt | Gilt für |
   | --- | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | Keystore, Base64 (Schritt 1) | Repository-Secret (Job build) |
   | `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Angaben aus `keytool` | Repository-Secret (Job build) |
   | `UPDATE_SIGNING_KEY` | Inhalt von `~/lx-update-key.pem` | **nur** in der Environment `release` |
   | `VPS_SSH_KEY`, `VPS_KNOWN_HOSTS`, `VPS_HOST`, `VPS_USER` | nur für den optionalen Upload (s. u.) | **nur** in der Environment `vps-deploy` |

   Environments (Settings > Environments): `release` und (falls Upload gewollt) `vps-deploy` mit "Required reviewers" = du selbst. Optional die Variable `UPDATE_MIN_VERSION` (Mindestversion, ab der ein Update Pflicht ist; Standard 0.1.0).
4. Optional SSH-Zugang für den Upload: Schlüssel auf dem PC erzeugen (`ssh-keygen -t ed25519 -N "" -C lx-fampad-release -f ~/lx-release-deploy`), die öffentliche Zeile auf dem Server in `~lx/.ssh/authorized_keys` mit Beschränkung eintragen:
   ```
   restrict,command="/usr/bin/rrsync -wo /srv/fampad/releases/android" ssh-ed25519 AAAA… lx-fampad-release
   ```
   (Pfad von rrsync mit `command -v rrsync` prüfen; Paket `rsync`.) Den privaten Schlüssel als `VPS_SSH_KEY` hinterlegen, den Host-Schlüssel als `VPS_KNOWN_HOSTS` (`ssh-keyscan -t ed25519 <host>`, Fingerabdruck mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` auf dem Server vergleichen), dazu `VPS_HOST` und `VPS_USER` (`lx`). Danach die lokale Schlüsseldatei löschen.
5. Erstes Release: `git tag v0.1.0 && git push origin v0.1.0`, Freigabe der Environment `release` erteilen, Entwurf unter "Releases" prüfen. Die erste APK wird **von Hand** auf die Handys installiert (aus dem Entwurf). Das Zertifikat-SHA-256 aus dem Schritt "Signatur prüfen, Prüfsumme berechnen" im Log gehört in `/srv/fampad/well-known/assetlinks.json` (Passkeys, Abschnitt 9).
6. **`latest.json` erst hochladen, wenn der echte öffentliche Schlüssel in `constants.dart` steht und die dazu gebaute App installiert ist** (der Workflow verweigert das Signieren sonst). Danach den Entwurf veröffentlichen und APK + `latest.json` auf den Server legen (Upload-Job oder von Hand, APK zuerst).

**APK-Größe und Architektur (ab 0.5.2):** Die Release-APK enthält nur **arm64-v8a** (`--target-platform android-arm64` im Workflow, `abiFilters` in `app/android/app/build.gradle.kts`) und komprimierte Bibliotheken (`useLegacyPackaging`): etwa 24 MB statt 127 MB (0.5.1: Universal-APK mit armeabi-v7a, arm64-v8a und x86_64). Dateiname, Manifest (`latest.json`, `size` ist die echte Größe), stabiler Link `lx-familyhub-latest.apk`, applicationId, Signatur und `versionCode` bleiben unverändert; bestehende Installationen aktualisieren sich wie gewohnt (Grenze der App: `kMaxApkBytes`). Der Schritt "Signatur prüfen, Prüfsumme berechnen" bricht ab, wenn die APK andere ABIs enthält oder 40 MB überschreitet; `tools/release-pruefung.sh` (CI, Job `android-debug`) prüft dasselbe. **Risiko 32-Bit:** Ein Gerät mit reinem 32-Bit-Userspace (armeabi-v7a, z. B. manche ältere Einsteiger-Geräte mit Android 9/10) kann die APK nicht installieren (`INSTALL_FAILED_NO_MATCHING_ABIS`), ein Update schlägt dort still fehl und die installierte Version bleibt bestehen. Vor dem Release auf jedem Familiengerät prüfen: `adb shell getprop ro.product.cpu.abilist` muss `arm64-v8a` enthalten (Einstellungen > Über das Telefon zeigt es bei modernen Samsung-Geräten als 64-Bit). Notfalls Universal-APK von Hand bauen: `flutter build apk --release` (ohne `--target-platform`, dann sind alle ABIs enthalten und die APK entsprechend größer).

Der Android-Build wird außerdem bei jedem Push und Pull Request als Debug-APK geprüft (`.github/workflows/ci.yml`, Job `android-debug`).

### 11. Karte (Kartenkacheln)

Die Standort-Seite zeigt die Karte nur, wenn die Kartendatei auf dem Server liegt. **Bis dahin** steht dort „Karte noch nicht eingerichtet“, die Liste funktioniert; ein Deploy vor diesen Schritten schadet also nichts. Die Datei (`westerwald.pmtiles`, bei 175 km Umkreis um Westerburg ca. 1,1 GB) gehört nicht ins Repository und nicht in die Datensicherung (sie ist jederzeit neu erzeugbar, bewusst ausgenommen: `docs/BACKUP.md`).

1. **Datei erzeugen** (Entwicklungsrechner, siehe `tools/karte/README.md`): `PMTILES=… tools/karte/extract.sh 20261019 westerwald.pmtiles` (ca. 1,1 GB, etwa eine halbe Minute; schätzen ohne Schreiben: `DRY_RUN=1`).
2. **Server vorbereiten** (als `lx` auf dem Server, in tmux; **Haupt-Caddyfile wird nie geändert**, nur `conf.d/fampad.caddy`, mit Rückfall und Prüfung von lx-labs.dev):
   ```bash
   cd ~/lx-fampad && git pull
   sudo bash deploy/einrichtung-karte.sh --dry-run     # zeigt Prüfungen und die geplante Änderung, schreibt nichts
   sudo bash deploy/einrichtung-karte.sh               # legt /srv/fampad/karte an, fügt den Block ein, validiert, lädt Caddy neu
   ```
   Das Skript verlangt 20 GB freien Platz auf `/srv`. Der Karten-Block steht seit dieser Version auch in `deploy/Caddyfile`: ein späteres `deploy.sh`-Hinweis-`cp` entfernt ihn nicht mehr.
3. **Hochladen** (Entwicklungsrechner; `rsync` setzt nach einem Abbruch fort, `scp` beginnt von vorn):
   ```bash
   rsync -avP --partial --inplace westerwald.pmtiles lx-labs:/srv/fampad/karte/neu.pmtiles
   # ohne rsync: scp westerwald.pmtiles lx-labs:/srv/fampad/karte/neu.pmtiles
   ssh lx-labs 'chmod 644 /srv/fampad/karte/neu.pmtiles && mv -f /srv/fampad/karte/neu.pmtiles /srv/fampad/karte/westerwald.pmtiles'
   ```
   **`chmod 644` ist nötig** (die Datei gehört `lx`, Caddy läuft als anderer Benutzer); das Umbenennen auf demselben Dateisystem ist atomar (laufende Karten lesen kurz mit der alten Datei weiter, nach dem ETag-Wechsel mit der neuen).
4. **Prüfen:** `sudo bash deploy/einrichtung-karte.sh` (idempotent, ändert nichts mehr, macht den Range-Test: 206, PMTiles-Kennung, kein `Content-Encoding`, ETag) oder von Hand: `curl -s -o /dev/null -w '%{http_code}\n' -r 0-15 https://familie.lx-labs.dev/karte-daten/westerwald.pmtiles` muss `206` liefern. In der App (neu laden) zeigt die Standort-Seite danach die Karte, sobald jemand teilt.
5. **Rückbau:** Block `handle_path /karte-daten/*` aus `/etc/caddy/conf.d/fampad.caddy` entfernen (das Skript nennt die Sicherungsdatei), `caddy validate`, `sudo systemctl reload caddy`; Datei löschen.

Zugriffslogs: Caddy schreibt für diese Site **keine Zugriffslogs** (kein `log`-Block in `deploy/Caddyfile`; **vor dem Deploy auf dem Server bestätigen**, dass auch Haupt-Caddyfile und `conf.d/` keinen für familie.lx-labs.dev setzen: `sudo grep -rn "log" /etc/caddy/Caddyfile /etc/caddy/conf.d/`), Kachel-Anfragen werden also nicht mitgeschrieben; `journalctl` hält Caddy-Fehlermeldungen höchstens 7 Tage (Abschnitt „Logs und Datenschutz“).

### 12. Wetter (Netatmo, optional)

Der Server holt die Werte einer öffentlichen Netatmo-Station (nur der Server, nie die App). Ohne diese Schritte ist das Wetter aus (Standard) und nichts passiert.

**Der Abruf läuft in einem eigenen Dienst `lx-fampad-weather.service`, nicht in der API.** `lx-fampad.service` sperrt jedes Netz außer Loopback (`IPAddressDeny=any`); `api.netatmo.com` liegt hinter Azure Front Door mit wechselnden IPs, und `IPAddressAllow=` kennt keine Hostnamen. Statt die Sperre der API zu lockern, läuft nur der Abruf-Takt (`dist/cli/weather-poller.js`, kein HTTP-Port) in einem zweiten Prozess (gleicher Benutzer, gleiche Härtung, aber `IPAddressAllow=any`); `GET /weather` liest nur aus der Datenbank. **Trade-off:** Dieser eine Prozess darf ins ganze Internet verbinden (Ziel nicht filterbar); ausgeglichen durch `SocketBindDeny=any` (kein Listening), kein Schreibzugriff aufs Dateisystem, keine Capabilities und minimalen Code. Es gibt genau einen Abruf-Takt: die API startet keinen.

1. **Developer-App** (einmalig, im Browser, mit deinem Netatmo-Konto): `https://dev.netatmo.com` anmelden, „My apps“, „Create“; Name und Beschreibung frei, **Scope `read_station`**. Auf der Seite der App stehen **Client ID** und **Client Secret**; der „Token generator“ (Scope `read_station` anhaken) erzeugt ein **Refresh-Token**. Diese drei Werte **nie** in Chat, Repository, Shell-Verlauf oder Dateien kopieren, sondern nur im nächsten Schritt eintippen oder einfügen. Die Nutzungsbedingungen von Netatmo (Developer Terms) vorher lesen.
2. **Einstellungen** in `/etc/lx-fampad/env` (keine Geheimnisse; MAC und Rechteck der Station, das Rechteck klein halten, höchstens 0,5 Grad je Richtung):
   ```
   WEATHER_ENABLED=true
   WEATHER_PLACE=Salz
   WEATHER_STATION_MAC=aa:bb:cc:dd:ee:ff
   WEATHER_BBOX=<lat_sw>,<lon_sw>,<lat_ne>,<lon_ne>
   ```
   Das Rechteck muss die Station einschließen (Südwest-Ecke, Nordost-Ecke, Dezimalgrad). Ungültige Werte brechen den Start ab (fail-closed).
3. **Zugangsdaten eintragen** (nach `deploy.sh`, auf dem Server; die Eingabe wird nicht angezeigt, die Werte stehen danach nur verschlüsselt in der Datenbank):
   ```bash
   sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js
   ```
   Das Skript fragt `client_id`, `client_secret` und `refresh_token` ab und macht einen Probeabruf (`ok` oder der Grund). `--status` zeigt den Zustand, `--remove` löscht die Zugangsdaten. Danach den Wetter-Dienst einrichten (Schritt 3a) bzw. neu starten: `sudo systemctl restart lx-fampad-weather`.
3a. **Wetter-Dienst einrichten** (einmalig, nach `deploy.sh` mit diesem Stand und nach dem ersten Start der API, damit die Migration die Tabellen angelegt hat). Als Benutzer `lx`, zuerst trocken:
   ```bash
   sudo bash ~/lx-fampad/deploy/einrichtung-wetter.sh dienst --dry-run
   sudo bash ~/lx-fampad/deploy/einrichtung-wetter.sh dienst
   ```
   Das Skript prüft die Unit mit `systemd-analyze verify`, kopiert sie nach `/etc/systemd/system/`, macht `daemon-reload` und `enable --now` und zeigt den Status. Von Hand: `sudo cp ~/lx-fampad/deploy/lx-fampad-weather.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now lx-fampad-weather`. `deploy.sh` startet den Dienst danach bei jedem Update neu (falls vorhanden) und weist auf eine geänderte Unit hin. Ohne `WEATHER_ENABLED=true` beendet sich der Prozess sofort und bleibt gestoppt; ohne Zugangsdaten läuft er und prüft alle 10 Minuten erneut.
4. **Prüfen:** `journalctl -u lx-fampad-weather -n 50` zeigt höchstens Codes wie `station_not_found` (MAC oder Rechteck stimmen nicht, oder die Station ist nicht öffentlich) oder `invalid_grant` (Token ungültig: Schritt 3 mit einem neuen Refresh-Token wiederholen; der Abruf ist bis dahin abgeschaltet). In der App erscheint die Kachel nach dem ersten erfolgreichen Abruf (spätestens nach 10 Minuten).
5. **Ausschalten:** `WEATHER_ENABLED` entfernen und `sudo systemctl restart lx-fampad lx-fampad-weather` (der Wetter-Dienst bleibt danach gestoppt; ganz entfernen: `sudo systemctl disable --now lx-fampad-weather`); die Messwerte der letzten 7 Tage bleiben in der Tabelle `weather_samples`, die Zugangsdaten löschen mit `weather-setup.js --remove`.

**Netatmo rotiert das Refresh-Token bei jeder Erneuerung.** Scheitert das Speichern des neuen Tokens in der Transaktion, schreibt der Dienst es ersatzweise außerhalb davon (Fehlercode `rotate_persist` in `weather-setup --status`). Steht im Log „ging verloren, weather-setup erneut ausführen“, ist das Token weg: Schritt 3 mit einem neuen Refresh-Token wiederholen. Ist der Abruf abgeschaltet (`invalid_grant`), prüft der Dienst alle 10 Minuten, ob neue Zugangsdaten da sind. Deshalb gibt es genau einen Abruf-Takt (ein Dienstprozess); nie dieselben Zugangsdaten auf einem zweiten System (z. B. einer Test-Instanz) gleichzeitig verwenden, sonst macht ein System das Token des anderen ungültig. Der Probeabruf von `weather-setup` läuft nur, wenn `WEATHER_ENABLED=true` in der Umgebung des Befehls steht (über `--env-file`).

## Updates veröffentlichen

**VOR dem Deploy von Migration 0005 (Gäste entfallen):** Sicherung ziehen und prüfen, ob Gäste existieren. Die Migration löscht Gast-Konten und ist nicht umkehrbar. **Dieser Deploy wird bei Fehler nicht automatisch zurückgerollt:** der Rückfall von `deploy.sh` spielt nur den Code zurück, nicht die Datenbank (ein alter Server würde zudem `audience 'all'` in die neue Enum-Spalte schreiben und mit 500 antworten). Wiederherstellung per Dump.

```bash
sudo -u postgres pg_dump lx_fampad > ~/lx_fampad-vor-0005.sql
sudo -u postgres psql lx_fampad -c "select count(*) from memberships where role='guest';"
```

```bash
git push                                                       # PC
ssh lx-labs bash lx-fampad/deploy/deploy.sh          # Server: pull, bauen, neu starten, Health-Check
deploy/deploy-web.sh                                           # Web-App (nur bei Änderungen in app/)
```

Die Caddy-Konfiguration wird nicht automatisch übernommen (sudo mit Passwort); weicht `deploy/Caddyfile` von `/etc/caddy/conf.d/fampad.caddy` ab, meldet `deploy.sh` den Befehl dazu (mit `caddy validate` vor dem Neuladen). Datenbank-Migrationen laufen nur vorwärts und müssen zur Vorgängerversion der App passen (Rollback der Server-Version ohne Datenbank-Rollback).

## Logs und Datenschutz (journald)

Die API-Logs enthalten Client-IP-Adressen (hinter Caddy aus `X-Forwarded-For`). Aufbewahrung höchstens **7 Tage**, ältere Einträge löscht journald selbst.

Die Begrenzung wird in Schritt 5 eingerichtet (vor dem ersten Start des Dienstes). Prüfen: `cat /etc/systemd/journald.conf.d/lx-retention.conf` und `journalctl --disk-usage`.

Das gilt für alle Dienste auf dem Server (journald hat eine gemeinsame Aufbewahrung), also auch für lx-labs und Caddy. Der Caddyfile schreibt keine Zugriffslogs (kein `log`-Block); wer sie einschaltet, muss Rotation und Aufbewahrung ebenfalls auf 7 Tage begrenzen. Was lx-fampad sonst speichert, steht in `docs/DATENSCHUTZ-ENTWURF.md`.

## Backups

Täglich 03:30 (UTC-Zeitstempel in den Namen) sichert `lx-fampad-backup.timer` die Datenbank (`pg_dump -Fc`) und die Konfiguration (`/etc/lx-fampad` mit `AUTH_SECRET_KEY`, Caddy-Dateien des Projekts, ntfy, Units) **verschlüsselt mit age** nach `/var/backups/lx-fampad/` (die letzten 3 Läufe). Das **NAS holt ab** (rsync über SSH, Benutzer `lxbackup`, erzwungenes `rrsync -ro`, nur lesen); der Server hält keine Zugangsdaten zum NAS (nur dessen IP und öffentlichen Schlüssel). Den privaten age-Schlüssel gibt es nur beim Betreiber (Passwortmanager/Ausdruck), nie auf dem Server. Einrichtung, NAS-Seite (Synology, QNAP, Linux), Überwachung und Rückbau: [`docs/BACKUP.md`](../docs/BACKUP.md); Neuaufbau, Umzug, Wiederherstellungstest: [`docs/WIEDERHERSTELLUNG.md`](../docs/WIEDERHERSTELLUNG.md).

```bash
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh --dry-run --age-recipient 'age1…' --nas-pubkey 'ssh-ed25519 AAAA…' --nas-ip <NAS-IP>   # prüfen
sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh            --age-recipient 'age1…' --nas-pubkey 'ssh-ed25519 AAAA…' --nas-ip <NAS-IP>   # einrichten + Probelauf
systemctl list-timers lx-fampad-backup.timer && sudo cat /var/backups/lx-fampad/status
```

**Schritt-für-Schritt-Anleitung zum Einrichten:** [`docs/BACKUP-EINRICHTUNG-SCHRITTE.md`](../docs/BACKUP-EINRICHTUNG-SCHRITTE.md). Nicht gesichert wird u. a. `/srv/fampad/karte` (Kartendatei, neu erzeugbar).

Das Skript ändert weder Caddy noch das Haupt-Caddyfile (lx-labs.dev) noch `sshd_config`; es nimmt bei Fehlern die in diesem Lauf angelegten oder geänderten Dateien, Units, den Benutzer und den Timer-Zustand zurück. Dateien: `deploy/backup/{lx-fampad-backup.sh, lx-fampad-backup.service, lx-fampad-backup.timer, einrichtung-backup.sh, wiederherstellung-test.sh, nas/lx-fampad-pull.sh}`.

### Swap

Der Server hat 2 GB RAM und keinen Swap. `sudo bash ~/lx-fampad/deploy/einrichtung-swap.sh --dry-run`, dann ohne `--dry-run`: legt `/swapfile` (1 GB, 0600) an, trägt sie in `/etc/fstab` ein (nur wenn es fehlt; baut eine Kopie mit Zeilenumbruch-Prüfung, prüft sie mit `findmnt --verify`, ersetzt erst dann, testet mit `swapon -a`, stellt bei Fehler die Sicherung `/etc/fstab.vor-swap` zurück) und setzt `vm.swappiness=10` (`/etc/sysctl.d/99-lx-fampad-swap.conf`). Idempotent, prüft den freien Platz (1 GB + 4 GB Reserve), nimmt eine halb angelegte Datei bei Fehlern zurück. Prüfen: `swapon --show`, `free -m`. Rückbau steht im Kopf des Skripts.

## Passwort-Anmeldung mit authKey (Rollout und Stichtag)

Voraussetzung: `E2EE_PW_BACKUP=true` in `/etc/lx-fampad/env` (siehe `server/.env.example`). `AUTH_LEGACY_PASSWORD_LOGIN` bleibt zuerst ungesetzt (= an).

1. Server aktualisieren (Migration 0017), Test zu zweit; `GET /api/v1/version` zeigt `features.authKey: true`.
2. **Erst auf allen Geräten der Familie die neue App installieren und einmal anmelden** (das stellt das Konto automatisch um). **Erst danach** Passwörter ändern: Ein Passwortwechsel oder eine Reset-Einladung mit der neuen App macht die alte Klartext-Anmeldung dieses Mitglieds unbrauchbar, noch nicht aktualisierte Geräte (0.5.x/0.6.0) kommen dann nicht mehr mit Passwort hinein.
3. In der App unter Profil > Mitglieder und Einladungen (Admin) prüfen: Bei keinem Mitglied steht „altes passwort-verfahren“ (die Markierung für das alte Passwort-Verfahren; oder `GET /api/v1/members/password-modes` zeigt keinen `legacy`-Eintrag).
4. Erst dann Stichtag: `AUTH_LEGACY_PASSWORD_LOGIN=false` setzen und den Dienst neu starten. Alte Apps bekommen `403 legacy_login_disabled` („Bitte aktualisiere die App“). Der Passwort-Reset durch Admins (PR 4b) ist der Rückweg für Ausgesperrte; bis dahin hilft nur die Anmeldung per Passkey oder Wiederherstellungscode.

**Warnung Rückschalten:** Wird `E2EE_PW_BACKUP` ausgeschaltet, `AUTH_LEGACY_PASSWORD_LOGIN` auf `false` gesetzt oder der Server auf einen Stand vor PR 4 zurückgestellt, können sich Konten mit authKey-Passwort (Platzhalter im Klartext-Hash) nicht mehr per Passwort anmelden, nur noch per Passkey oder Wiederherstellungscode; PR 4b (Admin-Passwort-Reset) ist der Rückweg. Die App sendet für solche Konten nie Klartext. Reihenfolge beim Ausrollen: **erst den Server, dann die Web-App und die APK**.

## Nützliche Befehle auf dem Server

| Befehl | Zweck |
| --- | --- |
| `sudo systemctl status lx-fampad` | Dienststatus |
| `sudo journalctl -u lx-fampad -f` | Logs live |
| `sudo journalctl -u caddy -n 50` | Caddy-Logs (Zertifikate, Fehler) |
| `curl https://familie.lx-labs.dev/api/v1/version` | Server-, Protokoll- und Mindestversion |
| `sudo systemctl status ntfy` | ntfy-Status |

## Noch offen (spätere Phasen)

- Backups der Dateiablage (`/srv/fampad/files`): erst wenn sie genutzt wird (`INCLUDE_FILES=1`, später inkrementell); Datenbank und Konfiguration sind erledigt, siehe Abschnitt "Backups"
- Speicherplatz-Warnung; Aufbewahrung von IP-Adressen in der Datenbank (`audit_log.ip`) höchstens 7 Tage (Aufräum-Job in Phase 1)
- Hauptschlüssel für die Dateiverschlüsselung außerhalb von `/srv/fampad/files` ablegen (Phase 1)

## Umbenennung von lx-familienzentrale

Das Projekt hieß früher `lx-familienzentrale` (Dienst/Benutzer/Verzeichnisse `lx-familie`, `/srv/familie`, Datenbank `lx_familie`). Die Domain `familie.lx-labs.dev` und die WebAuthn-RP-ID bleiben. Eine bestehende Installation wird einmalig mit `umbenennung-server.sh` umgestellt (idempotent, bricht bei jedem Fehler mit Meldung ab; `lx-labs` und dessen Caddy-Site werden nicht angefasst).

**Vorher prüfen, was im Checkout liegt:** Das Skript läuft als root, der Checkout `~/lx-familienzentrale` gehört aber `lx` (schreibbar), und das Skript installiert Dateien daraus nach `/etc` (Units, Caddy). Es zeigt den letzten Commit an und bricht bei uncommitteten Änderungen in `deploy/` ab; trotzdem vorher selbst ansehen:

```bash
cd ~/lx-familienzentrale && git pull --ff-only           # neuen Stand holen (enthält das Skript)
git log -3 --stat                                         # stammen die Commits von dir?
git status --short deploy                                 # muss leer sein
git diff origin/<Branch> -- deploy                        # sollte leer sein
sudo bash ~/lx-familienzentrale/deploy/umbenennung-server.sh
cd ~ && newgrp lx-fampad                                  # oder neu anmelden (umbenannte Gruppe)
cd ~/lx-fampad && bash deploy/deploy.sh                   # neuen Code ausrollen
```

Schritt 0 prüft **alle** Voraussetzungen (Befehle, `/srv/familie/{server,files}`, `server.prev` wird bei Bedarf angelegt, `env`, Caddy-Import und -Konfiguration, freier Platz) und legt Fehlendes an, bevor irgendein Dienst gestoppt wird. Danach sichert es **getrennt**: nach `/var/backups/lx-fampad-umbenennung-<Zeit>/` pg_dump, Caddyfile, Site-Datei, Units und sudoers, und nach `/root/lx-fampad-umbenennung-<Zeit>-schluessel/` (nur root, 0700/0600) `/etc/lx-familie` mit den env-Dateien und `AUTH_SECRET_KEY`. Der Dump enthält Klarnamen und Anmeldedaten, der Schlüssel entschlüsselt die TOTP-Geheimnisse darin; beides gehört nicht zusammen in einen Ordner (Backup-Werkzeuge, Weitergabe). **Beide Sicherungen nach wenigen Tagen ohne Auffälligkeiten löschen, spätestens nach 14 Tagen** (`sudo rm -rf /var/backups/lx-fampad-umbenennung-* /root/lx-fampad-umbenennung-*-schluessel`). Das Skript stoppt dann den Dienst, benennt Benutzer und Gruppe getrennt und wiederholbar um (`usermod -l`, `groupmod -n`; die Mitgliedschaft von `lx` bleibt), `/srv/familie` -> `/srv/fampad`, `/etc/lx-familie` -> `/etc/lx-fampad`, Datenbank und Rollen (`lx_fampad`, `lx_fampad_migrate`) um, passt die env-Dateien an (0600 root:root; Passwörter werden geprüft und bei Bedarf neu gesetzt), tauscht Units und sudoers aus, ersetzt `conf.d/familie.caddy` durch `fampad.caddy` (mit `caddy validate` vor dem Reload, bei Fehler Rückfall und Prüfung von lx-labs.dev), benennt `~/lx-familienzentrale` -> `~/lx-fampad` und `~/familie.git` -> `~/fampad.git` um (git-Remote wird mitgezogen) und prüft zuletzt `https://familie.lx-labs.dev/api/v1/health` (`"db":"ok"`) und `https://lx-labs.dev` (200).

Danach anpassen: PC-Aufrufe (`ssh lx-labs bash lx-fampad/deploy/deploy.sh`), GitHub-Repository auf `diy3d-de/lx-fampad` umbenennen und den Remote setzen. Der SSH-Deploy-Key `~/.ssh/id_ed25519_familie` darf seinen Namen behalten.

Wird das Skript nach einem Abbruch wiederholt, folgt die Caddy-Site dem Vorhandenen: Ein `ntfy`-Block kommt nur in die neue Site-Datei, wenn er in der bisherigen Datei stand. Hat ein Abbruch die Datenbank für Verbindungen gesperrt (`ALLOW_CONNECTIONS false` während des Umbenennens), öffnet sie das Skript beim Beenden und bei jedem Start wieder.

**Rückbau** (als root, `B=/var/backups/lx-fampad-umbenennung-<Zeit>`, `K=/root/lx-fampad-umbenennung-<Zeit>-schluessel`):

1. `systemctl disable --now lx-fampad; rm /etc/systemd/system/lx-fampad*.service /etc/sudoers.d/lx-fampad`
2. Caddy: `rm /etc/caddy/conf.d/fampad.caddy; cp $B/familie.caddy /etc/caddy/conf.d/ ; cp $B/Caddyfile /etc/caddy/Caddyfile; caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`; danach `curl -sI https://lx-labs.dev | head -1`
3. Datenbank/Rollen zurück: `sudo -u postgres psql -c "ALTER DATABASE lx_fampad RENAME TO lx_familie" -c "ALTER ROLE lx_fampad RENAME TO lx_familie" -c "ALTER ROLE lx_fampad_migrate RENAME TO lx_familie_migrate"` (vorher Verbindungen trennen; Passwörter ggf. neu setzen). Notfalls aus `$B/lx_familie.dump` wiederherstellen (`pg_restore -C -d postgres`).
4. Benutzer/Gruppe: `groupmod -n lx-familie lx-fampad; usermod -l lx-familie -d /home/lx-familie lx-fampad`
5. Verzeichnisse: `mv /srv/fampad /srv/familie; mv /etc/lx-fampad /etc/lx-familie`; env-Dateien aus `$K/etc-lx-familie/` zurückkopieren
6. Units aus `$B/lx-familie*.service` nach `/etc/systemd/system/`, `$B/sudoers-lx-familie` nach `/etc/sudoers.d/lx-familie` (0440, `visudo -cf`), `systemctl daemon-reload; systemctl enable --now lx-familie`
7. `mv ~/lx-fampad ~/lx-familienzentrale; mv ~/fampad.git ~/familie.git` und Remote zurücksetzen
