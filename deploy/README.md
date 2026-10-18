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

- `Caddyfile` – Site-Blöcke `familie.lx-labs.dev` und `ntfy.familie.lx-labs.dev` mit strengen Sicherheits-Headern
- `lx-fampad.service` – systemd-Dienst der API (eigener Benutzer, gehärtet, Speicher-/Prozessgrenzen); `lx-fampad-migrate.service` führt vor jedem Start die Migrationen mit der Migrationsrolle aus; `einrichtung-auth.sh` richtet Schlüssel und Datenbank-Rollen ein
- `deploy.sh` – läuft auf dem Server: Code holen, Server bauen (`npm ci --ignore-scripts`), nur Produktivpakete übertragen, Dienst neu starten, Health-Check mit `"db":"ok"`
- `deploy-web.sh` – läuft auf dem PC: Prüfsummen prüfen, Flutter-Web bauen, `version.txt` (= `webVersion`) schreiben und versioniert hochladen
- `ntfy/server.yml` – ntfy-Konfiguration (deny-all, nur `up*`-Topics beschreibbar)

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

ntfy ist **2.28.0** gepinnt (2.31.1 ab 31.10.). Installation aus dem offiziellen Debian-Repository von ntfy, Version festhalten.

Paketquelle einrichten und **vor dem Installieren den Schlüssel prüfen**. Die Anleitung steht in der offiziellen Dokumentation (<https://docs.ntfy.sh/install/>, Abschnitt Debian/Ubuntu-Repository), dort auch der Fingerabdruck. Beim Erstellen dieser Anleitung nannte die Seite die Quelle `https://archive.ntfy.sh/apt` (der ältere Name `archive.heckel.io` ist abgelöst) und den Fingerabdruck `55BA 774A 6F5E E674 31E4 B6B7 CFDB 962D 4F1E C4AF`. **Den aktuellen Wert selbst auf docs.ntfy.sh nachlesen und vergleichen**; bei Abweichung abbrechen.

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/ntfy.gpg https://archive.ntfy.sh/apt/keyring.gpg
gpg --show-keys --with-fingerprint /etc/apt/keyrings/ntfy.gpg      # Fingerabdruck mit der Dokumentation vergleichen
# erst wenn er übereinstimmt:
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main" | sudo tee /etc/apt/sources.list.d/ntfy.list
sudo apt update && apt-cache policy ntfy          # 2.28.0 muss in der Liste stehen
sudo apt install -y ntfy=2.28.0 && sudo apt-mark hold ntfy

sudo cp ~/lx-fampad/deploy/ntfy/server.yml /etc/ntfy/server.yml
sudo mkdir -p /var/lib/ntfy /var/cache/ntfy && sudo chown ntfy:ntfy /var/lib/ntfy /var/cache/ntfy
sudo systemctl enable --now ntfy
```

Zugriff: Standard ist **deny-all**. Nur `up*`-Topics (UnifiedPush) dürfen anonym beschrieben werden; gelesen wird mit einem Benutzer je Handy:

```bash
sudo ntfy access '*' 'up*' write-only                 # der Familien-Server und Apps dürfen Weckrufe senden
sudo ntfy user add handy-anna                         # fragt ein Passwort ab; je Handy ein Benutzer
sudo ntfy access handy-anna 'up*' read-only
sudo ntfy access                                      # Übersicht prüfen
```

Auf dem Handy: ntfy-App als UnifiedPush-Verteiler installieren, Server `https://ntfy.familie.lx-labs.dev` und den Benutzer eintragen. Die Meldungen enthalten nie Inhalte („es gibt Neues“).

### 8. Web-App hochladen

Auf dem PC (Flutter 3.47.6 installiert, Git Bash/WSL, SSH-Alias `lx-labs`):

```bash
deploy/deploy-web.sh
```

Das Skript baut mit `--no-web-resources-cdn`, lädt nach `/srv/fampad/web/<version>` und schaltet `current` um. Zurückrollen: auf dem Server `cd /srv/fampad/web && ln -sfn <alte-version> current`.

**Prüfen (Pflicht vor dem ersten Echtbetrieb):** Seite in Chrome öffnen, Entwicklerwerkzeuge → Netzwerk: Es darf **nichts** von `fonts.gstatic.com`, `gstatic.com` oder anderen Fremddomains geladen werden. In der Konsole: `crossOriginIsolated` muss `true` sein (sonst fehlt COOP/COEP, drift fällt auf IndexedDB zurück).

**Fallback-Schriften:** `web/flutter_bootstrap.js` verweist `fontFallbackBaseUrl` auf `https://familie.lx-labs.dev/font-fallback/`. Dort müssen die Noto-Schriften liegen, die Flutter bei fehlenden Zeichen (z. B. Emoji) nachlädt. Welche Dateien nötig sind, zeigt der Netzwerk-Tab, wenn ein Emoji in der App erscheint (404-Anfragen an `/font-fallback/...`); die Dateien aus dem gleichnamigen Pfad von `fonts.gstatic.com/s/` einmalig herunterladen und mit gleicher Pfadstruktur ablegen. Ohne diese Dateien werden solche Zeichen nur als Kästchen dargestellt, es gibt aber keinen Fremdabruf.

### 9. Passkey- und Update-Dateien (ab Phase 1)

- `/srv/fampad/well-known/assetlinks.json` mit den SHA-256-Fingerprints aller Signaturschlüssel der Android-App (`dev.lx_labs.fampad`)
- `/srv/fampad/releases/android/latest.json` und `dev-lx_labs-fampad-<version>.apk` (erzeugt vom Release-Workflow, Abschnitt 10). **Erst hochladen, wenn der echte Update-Schlüssel eingebaut ist:** In `app/lib/constants.dart` steht ein Platzhalter-Schlüssel (`kUpdatePublicKey`), zu dem es keinen privaten Schlüssel gibt; die App lehnt dann jedes Manifest ab. Ablauf:
  1. Schlüssel erzeugen (außerhalb des Repositories): `node tools/update-manifest.mjs keygen ~/lx-update-key.pem`; öffentlichen Schlüssel in `kUpdatePublicKey` und eine neue `kUpdateKeyId` eintragen, den privaten als CI-Secret `UPDATE_SIGNING_KEY` hinterlegen.
  2. App mit dem neuen Schlüssel bauen, signieren: `node tools/update-manifest.mjs sign --apk … --version … --version-code … --key-id … --out latest.json` (Näheres: `tools/README.md`; normalerweise erledigt das der Release-Workflow, Abschnitt 10).
  3. APK und `latest.json` nach `/srv/fampad/releases/android/` legen, **APK zuerst**, dann `latest.json`.
  Der private Schlüssel gehört nie in das Repository und nie auf den Server.

---

### 10. Android-Release per GitHub Actions (APK bauen, signieren, ausliefern)

Der Workflow `.github/workflows/release.yml` läuft bei einem Tag `v*` (z. B. `v0.2.0`) oder manuell (Actions > "Release (Android)" > Run workflow, Version ohne `v`). Ablauf:

1. **build**: Lockfile erzwingen, build_runner, analyze, test, dann `flutter build apk --release` mit dem Android-Schlüssel aus den Secrets (`key.properties` entsteht erst im Job und wird danach gelöscht) und `--dart-define` für `API_BASE` und `RELEASES_BASE` (`https://familie.lx-labs.dev`). `versionName` = Tag, `versionCode` = `major*1000000 + minor*1000 + patch` (0.2.0 gibt 2000); der Wert aus `pubspec.yaml` wird dabei überschrieben. Danach `apksigner verify` und SHA-256. Dateiname: `dev-lx_labs-fampad-<version>.apk` (passt zur Namensprüfung der App).
2. **sign** (Environment `release`, manuelle Freigabe): prüft, dass `kUpdateKeyId`/`kUpdatePublicKey` in `constants.dart` echt sind und zum Secret `UPDATE_SIGNING_KEY` passen, erzeugt und signiert `latest.json`. Nur dieser Job sieht den Update-Schlüssel.
3. **draft**: legt einen **Release-Entwurf** mit APK, `.sha256` und `latest.json` an (nichts wird veröffentlicht).
4. **deploy** (optional, nur manuell mit Häkchen "deploy_vps", Environment `vps-deploy` mit Freigabe): lädt auf den VPS hoch.

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

Der Android-Build wird außerdem bei jedem Push und Pull Request als Debug-APK geprüft (`.github/workflows/ci.yml`, Job `android-debug`).

## Updates veröffentlichen

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

## Nützliche Befehle auf dem Server

| Befehl | Zweck |
| --- | --- |
| `sudo systemctl status lx-fampad` | Dienststatus |
| `sudo journalctl -u lx-fampad -f` | Logs live |
| `sudo journalctl -u caddy -n 50` | Caddy-Logs (Zertifikate, Fehler) |
| `curl https://familie.lx-labs.dev/api/v1/version` | Server-, Protokoll- und Mindestversion |
| `sudo systemctl status ntfy` | ntfy-Status |

## Noch offen (spätere Phasen)

- Backups: nächtlich `pg_dump` + `/srv/fampad/files` mit restic auf ein externes Ziel; Wiederherstellung quartalsweise testen
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
