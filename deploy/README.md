# Deployment der Familienzentrale (Debian 13, netcup-VPS)

Die Familienzentrale läuft auf demselben VPS wie lx-labs.dev: eigener Caddy-Block, eigener Systembenutzer, eigener Dienst.
Grundeinrichtung des Servers (Benutzer `lx`, SSH-Schlüssel, ufw, Caddy, Node.js) steht in `lx-labs/deploy/README.md` und wird hier vorausgesetzt.

```
Browser/App ──HTTPS──▶ Caddy :443 ─┬─ familie.lx-labs.dev
                                   │    /api/*, /ws        ──▶ Node (lx-familie) 127.0.0.1:4400 ──▶ PostgreSQL 17 (localhost)
                                   │    /releases/*        ──▶ /srv/familie/releases   (Android-OTA: latest.json + APK)
                                   │    /.well-known/*     ──▶ /srv/familie/well-known (assetlinks.json)
                                   │    /font-fallback/*   ──▶ /srv/familie/font-fallback
                                   │    alles andere       ──▶ /srv/familie/web/current (Flutter-Web-Build)
                                   └─ ntfy.familie.lx-labs.dev ──▶ ntfy 127.0.0.1:2586 (UnifiedPush)
```

Dateien in diesem Ordner:

- `Caddyfile` – Site-Blöcke `familie.lx-labs.dev` und `ntfy.familie.lx-labs.dev` mit strengen Sicherheits-Headern
- `lx-familie.service` – systemd-Dienst der API (eigener Benutzer, gehärtet, Speicher-/Prozessgrenzen, Migrationen vor dem Start)
- `deploy.sh` – läuft auf dem Server: Code holen, Server bauen (`npm ci --ignore-scripts`), nur Produktivpakete übertragen, Dienst neu starten, Health-Check mit `"db":"ok"`
- `deploy-web.sh` – läuft auf dem PC: Prüfsummen prüfen, Flutter-Web bauen, `version.txt` (= `webVersion`) schreiben und versioniert hochladen
- `ntfy/server.yml` – ntfy-Konfiguration (deny-all, nur `up*`-Topics beschreibbar)

Verzeichnisse auf dem Server:

| Pfad | Inhalt | Besitzer |
| --- | --- | --- |
| `~/lx-familienzentrale` | Git-Checkout (nur lesend per Deploy-Key) | `lx` |
| `/srv/familie/server` | gebauter Server (`dist`, `drizzle`, `node_modules`) | `lx`, Gruppe `lx-familie` |
| `/srv/familie/web/<version>` + `current` | Flutter-Web-Builds, `current` ist ein Symlink | `lx` |
| `/srv/familie/releases/android` | `latest.json` und APK des Update-Kanals | `lx` |
| `/srv/familie/well-known` | `assetlinks.json` (später `apple-app-site-association`) | `lx` |
| `/srv/familie/font-fallback` | Fallback-Schriften für Flutter Web | `lx` |
| `/srv/familie/files` | Dateiablage (später verschlüsselt) | `lx-familie`, 0700 |
| `/etc/lx-familie/env` | Konfiguration und Geheimnisse (Datenbank-Passwort) | `root:root`, 0600 |

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
postgres=# CREATE ROLE lx_familie LOGIN;
postgres=# \password lx_familie
postgres=# CREATE DATABASE lx_familie OWNER lx_familie ENCODING 'UTF8';
postgres=# \q
```

### 2. Systembenutzer, Verzeichnisse, Konfiguration

```bash
sudo adduser --system --group --no-create-home --shell /usr/sbin/nologin lx-familie
sudo usermod -aG lx-familie lx                       # lx darf den Code in /srv/familie/server ablegen

sudo mkdir -p /srv/familie/{server,web,releases/android,well-known,font-fallback,files} /etc/lx-familie
sudo chown lx:lx-familie /srv/familie/server && sudo chmod 750 /srv/familie/server
sudo chown -R lx:lx /srv/familie/web /srv/familie/releases /srv/familie/well-known /srv/familie/font-fallback
sudo chmod -R 755 /srv/familie/web /srv/familie/releases /srv/familie/well-known /srv/familie/font-fallback
sudo chown lx-familie:lx-familie /srv/familie/files && sudo chmod 700 /srv/familie/files
sudo chmod 755 /srv/familie                           # Caddy muss web/releases lesen können

```

Nach `usermod` einmal ab- und wieder anmelden, damit die Gruppe gilt. Die Konfigurationsdatei folgt in Schritt 5 (sie braucht den Git-Checkout aus Schritt 4).

### 3. Node.js 24

Wie bei lx-labs (NodeSource 24). Gepinnt ist 24.21.0 (`server/.nvmrc`); `node --version` prüfen.

### 4. Code holen

Gleicher Weg wie bei lx-labs: eigener Deploy-Key (nur lesen) für das Repository `lx-familienzentrale`.

```bash
ssh-keygen -t ed25519 -C "lx-familienzentrale-server" -N "" -f ~/.ssh/id_ed25519_familie
cat ~/.ssh/id_ed25519_familie.pub     # auf GitHub als Deploy key eintragen (ohne Schreibrecht)
git clone git@github.com:<dein-github-name>/lx-familienzentrale.git ~/lx-familienzentrale
```

(Bei zwei Repositories auf einem Server die Schlüssel per `~/.ssh/config` mit je einem `Host`-Alias trennen.)

### 5. Konfiguration und Dienst einrichten

```bash
# Konfiguration: Vorlage ist server/.env.example. Die Datei enthält das Datenbank-Passwort: root:root, 0600.
# systemd liest sie als root (EnvironmentFile), der Dienst selbst und auch der Benutzer lx können sie nicht lesen.
sudo install -o root -g root -m 600 ~/lx-familienzentrale/server/.env.example /etc/lx-familie/env
sudoedit /etc/lx-familie/env      # DATABASE_URL mit dem Passwort aus Schritt 1, FILES_DIR=/srv/familie/files
sudo ls -l /etc/lx-familie/env    # -rw------- root root

sudo cp ~/lx-familienzentrale/deploy/lx-familie.service /etc/systemd/system/
sudo systemctl daemon-reload

# deploy.sh darf den Dienst ohne Passwort neu starten (nur genau diesen Befehl)
echo 'lx ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-familie' | sudo tee /etc/sudoers.d/lx-familie
sudo chmod 440 /etc/sudoers.d/lx-familie

# erstes Deployment: baut den Server, überträgt ihn und startet den Dienst (Migrationen laufen dabei)
bash ~/lx-familienzentrale/deploy/deploy.sh
sudo systemctl enable lx-familie
curl http://127.0.0.1:4400/api/v1/health      # → {"status":"ok","db":"ok"}
```

Der Port 4400 und `HOST=127.0.0.1` stehen fest in `lx-familie.service` (nicht in der env-Datei); dadurch kann `deploy.sh` den Health-Check ausführen, ohne die env-Datei zu lesen. Wer den Port ändert, muss `lx-familie.service`, `deploy.sh` und `Caddyfile` gemeinsam anpassen. `deploy.sh` meldet erst "online", wenn der Health-Check `"db":"ok"` liefert (nicht nur "ok" ohne Datenbank).

Beim Start wendet `ExecStartPre` die Migrationen an. Fehler stehen in `sudo journalctl -u lx-familie -n 50`.

### 6. Caddy

```bash
sudo cp ~/lx-familienzentrale/deploy/Caddyfile /etc/caddy/familie.caddy
echo 'import /etc/caddy/familie.caddy' | sudo tee -a /etc/caddy/Caddyfile    # vorläufig, siehe unten
caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

**Achtung: Ein Deploy von lx-labs entfernt die Import-Zeile.** `/etc/caddy/Caddyfile` gehört dem lx-labs-Deploy, der die Datei aus `lx-labs/deploy/Caddyfile` überschreibt. Dauerhaft lösen lässt sich das nur dort. **Vorschlag für `lx-labs/deploy/Caddyfile`** (dieses Repository ändert das lx-labs-Repository nicht; der Eintrag ist dort von Hand vorzunehmen), am Ende der Datei:

```caddy
# Familienzentrale (Repository lx-familienzentrale, Datei wird von dessen deploy/ gepflegt)
import /etc/caddy/familie.caddy
```

Caddy bricht beim `reload` mit einem Fehler ab, wenn `/etc/caddy/familie.caddy` fehlt; deshalb zuerst Schritt 6 ausführen, dann den lx-labs-Deploy. Bis der Vorschlag umgesetzt ist: nach jedem lx-labs-Deploy `deploy.sh` (oder `grep familie.caddy /etc/caddy/Caddyfile`) ausführen. `deploy.sh` warnt, wenn die Zeile in `/etc/caddy/Caddyfile` fehlt; dann die Zeile mit dem Befehl oben wieder anfügen und Caddy neu laden.

Caddy holt danach die Zertifikate für beide Domains. Bis die Web-App hochgeladen ist (Schritt 8), antwortet `familie.lx-labs.dev` unter `/` mit 404; `/api/v1/health` geht sofort.

### 7. ntfy (UnifiedPush)

ntfy ist **2.28.0** gepinnt (2.31.1 ab 31.10.). Installation aus dem offiziellen Debian-Repository von ntfy, Version festhalten:

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://archive.heckel.io/apt/pubkey.txt | sudo gpg --dearmor -o /etc/apt/keyrings/archive.heckel.io.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/archive.heckel.io.gpg] https://archive.heckel.io/apt debian main" | sudo tee /etc/apt/sources.list.d/archive.heckel.io.list
sudo apt update && apt-cache policy ntfy          # 2.28.0 muss in der Liste stehen
sudo apt install -y ntfy=2.28.0 && sudo apt-mark hold ntfy

sudo cp ~/lx-familienzentrale/deploy/ntfy/server.yml /etc/ntfy/server.yml
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

Das Skript baut mit `--no-web-resources-cdn`, lädt nach `/srv/familie/web/<version>` und schaltet `current` um. Zurückrollen: auf dem Server `cd /srv/familie/web && ln -sfn <alte-version> current`.

**Prüfen (Pflicht vor dem ersten Echtbetrieb):** Seite in Chrome öffnen, Entwicklerwerkzeuge → Netzwerk: Es darf **nichts** von `fonts.gstatic.com`, `gstatic.com` oder anderen Fremddomains geladen werden. In der Konsole: `crossOriginIsolated` muss `true` sein (sonst fehlt COOP/COEP, drift fällt auf IndexedDB zurück).

**Fallback-Schriften:** `web/flutter_bootstrap.js` verweist `fontFallbackBaseUrl` auf `https://familie.lx-labs.dev/font-fallback/`. Dort müssen die Noto-Schriften liegen, die Flutter bei fehlenden Zeichen (z. B. Emoji) nachlädt. Welche Dateien nötig sind, zeigt der Netzwerk-Tab, wenn ein Emoji in der App erscheint (404-Anfragen an `/font-fallback/...`); die Dateien aus dem gleichnamigen Pfad von `fonts.gstatic.com/s/` einmalig herunterladen und mit gleicher Pfadstruktur ablegen. Ohne diese Dateien werden solche Zeichen nur als Kästchen dargestellt, es gibt aber keinen Fremdabruf.

### 9. Passkey- und Update-Dateien (ab Phase 1)

- `/srv/familie/well-known/assetlinks.json` mit den SHA-256-Fingerprints aller Signaturschlüssel der Android-App (`dev.lx_labs.familienzentrale`)
- `/srv/familie/releases/android/latest.json` und `lx-familienzentrale-<version>.apk`. **Erst hochladen, wenn der echte Update-Schlüssel eingebaut ist:** In `app/lib/constants.dart` steht ein Platzhalter-Schlüssel (`kUpdatePublicKey`), zu dem es keinen privaten Schlüssel gibt; die App lehnt dann jedes Manifest ab. Ablauf:
  1. Schlüssel erzeugen (außerhalb des Repositories): `node tools/update-manifest.mjs keygen ~/lx-update-key.pem`; öffentlichen Schlüssel in `kUpdatePublicKey` und eine neue `kUpdateKeyId` eintragen, den privaten als CI-Secret `UPDATE_SIGNING_KEY` hinterlegen.
  2. App mit dem neuen Schlüssel bauen, signieren: `node tools/update-manifest.mjs sign --apk … --version … --version-code … --key-id … --out latest.json` (Näheres: `tools/README.md`).
  3. APK und `latest.json` nach `/srv/familie/releases/android/` legen, **APK zuerst**, dann `latest.json`.
  Der private Schlüssel gehört nie in das Repository und nie auf den Server.

---

## Updates veröffentlichen

```bash
git push                                                       # PC
ssh lx-labs bash lx-familienzentrale/deploy/deploy.sh          # Server: pull, bauen, neu starten, Health-Check
deploy/deploy-web.sh                                           # Web-App (nur bei Änderungen in app/)
```

Die Caddy-Konfiguration wird nicht automatisch übernommen (sudo mit Passwort); weicht `deploy/Caddyfile` ab, meldet `deploy.sh` den Befehl dazu. Datenbank-Migrationen laufen nur vorwärts und müssen zur Vorgängerversion der App passen (Rollback der Server-Version ohne Datenbank-Rollback).

## Logs und Datenschutz (journald)

Die API-Logs enthalten Client-IP-Adressen (hinter Caddy aus `X-Forwarded-For`). Aufbewahrung höchstens **7 Tage**, ältere Einträge löscht journald selbst:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nMaxRetentionSec=7day\n' | sudo tee /etc/systemd/journald.conf.d/lx-retention.conf
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

Das gilt für alle Dienste auf dem Server (journald hat eine gemeinsame Aufbewahrung), also auch für lx-labs und Caddy. Der Caddyfile schreibt keine Zugriffslogs (kein `log`-Block); wer sie einschaltet, muss Rotation und Aufbewahrung ebenfalls auf 7 Tage begrenzen. Was die Familienzentrale sonst speichert, steht in `docs/DATENSCHUTZ-ENTWURF.md`.

## Nützliche Befehle auf dem Server

| Befehl | Zweck |
| --- | --- |
| `sudo systemctl status lx-familie` | Dienststatus |
| `sudo journalctl -u lx-familie -f` | Logs live |
| `sudo journalctl -u caddy -n 50` | Caddy-Logs (Zertifikate, Fehler) |
| `curl https://familie.lx-labs.dev/api/v1/version` | Server-, Protokoll- und Mindestversion |
| `sudo systemctl status ntfy` | ntfy-Status |

## Noch offen (spätere Phasen)

- Backups: nächtlich `pg_dump` + `/srv/familie/files` mit restic auf ein externes Ziel; Wiederherstellung quartalsweise testen
- Speicherplatz-Warnung; Aufbewahrung von IP-Adressen in der Datenbank (`audit_log.ip`) höchstens 7 Tage (Aufräum-Job in Phase 1)
- Hauptschlüssel für die Dateiverschlüsselung außerhalb von `/srv/familie/files` ablegen (Phase 1)
