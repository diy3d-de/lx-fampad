# VPS-Checkliste: lx-fampad neben lx-labs.dev

Ziel: `familyhub.lx-labs.dev` auf den bestehenden netcup-VPS bringen, ohne dass `lx-labs.dev` ausfällt.
Die Befehle stehen in [`deploy/README.md`](../deploy/README.md) (Nummern in Klammern). Dieser Plan legt Reihenfolge,
Prüfungen und Rückbau fest. Auf dem Server wird erst nach ausdrücklicher Freigabe gearbeitet.

## A. Vorher prüfen (nur lesen)

- [ ] **Snapshot/Backup** im netcup SCP anlegen; Datum notieren.
- [ ] Debian-Version: `cat /etc/os-release` (erwartet 13).
- [ ] RAM und Platz: `free -h`, `df -h /srv /var` — Richtwert: mind. 1 GB RAM frei, mind. 20 GB Platz für Dateien
      (Karte später zusätzlich 5–10 GB).
- [ ] Belegte Ports: `ss -tlnp` — frei sein müssen `127.0.0.1:4400` (API), `127.0.0.1:2586` (ntfy), `127.0.0.1:5432` (PostgreSQL).
- [ ] lx-labs läuft: `systemctl status lx-labs`, `curl -sI https://lx-labs.dev | head -3` — Ausgangszustand merken.
- [ ] Sicherung der Caddy-Konfiguration: `sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.vor-fampad` (README 6 legt sie ebenfalls an).
- [ ] Haupt-Caddyfile von lx-labs setzt **kein globales `log`** (`grep -n '^[[:space:]]*log' /etc/caddy/Caddyfile`, Treffer einzeln ansehen); sonst gäbe es Zugriffslogs mit IPs auch für die Familie.
- [ ] Firewall-Ausgangszustand: `sudo ufw status verbose` (aktiv; nur 22, 80, 443 offen) notieren.
- [ ] Vorschlag für `lx-labs/deploy/Caddyfile` vorbereiten: `import /etc/caddy/conf.d/*.caddy` (siehe README 6), damit ein
      lx-labs-Deploy die Familien-Site nicht mehr entfernt.

## B. Reihenfolge der Einrichtung (jeweils danach lx-labs.dev prüfen, siehe E.)

1. **DNS** bei Cloudflare: `familyhub` und `ntfy.familyhub` als A-Record, *DNS only* (README 0). Betrifft nur die neuen Namen.
2. **PostgreSQL 17** installieren, Rolle und Datenbank `lx_fampad` anlegen, Passwort per `\password` (README 1).
3. **Systembenutzer, Verzeichnisse** (`/srv/fampad`, auch `server.prev`), `/etc/lx-fampad/env` als `root:root 0600` (README 2).
4. **Node 24**: nur nutzen, falls lx-labs dieselbe Hauptversion hat; sonst nicht systemweit ändern (README 3).
5. **journald auf 7 Tage begrenzen** (`MaxRetentionSec=7day`, README 5, erster Block) — **vor** dem ersten Start des Dienstes, weil ab dann IP-Adressen im Journal stehen. Prüfen: `journalctl --disk-usage`.
6. **Code holen, Dienst einrichten** (README 4–5): `lx-fampad.service` startet auf `127.0.0.1:4400`; sudoers-Datei mit `sudo visudo -cf /etc/sudoers.d/lx-fampad` prüfen. Prüfen: `curl http://127.0.0.1:4400/api/v1/health` liefert `"db":"ok"`.
7. **Caddy**: `fampad.caddy` nach `/etc/caddy/conf.d/`, Haupt-Caddyfile sichern (`Caddyfile.vor-fampad`), Import-Zeile anfügen, **erst** `caddy validate --config /etc/caddy/Caddyfile`, bei Fehler sofort zurückkopieren, **dann** `systemctl reload caddy` (README 6). Bei Fehler: Rückbau C.
8. **ntfy** auf eigener Subdomain: Paketquelle erst nach Fingerabdruck-Vergleich mit docs.ntfy.sh, `deny-all`, danach Benutzer pro Handy (README 7).
9. **Web-App hochladen** mit `deploy-web.sh` (README 8).
10. **Erst später:** `assetlinks.json`, `latest.json` und APK **nicht** hochladen, bis der echte Update-Schlüssel erzeugt und in der App eingebaut ist (README 9). Die Ed25519-Prüfung in der App ist fertig; bis dahin steht ein Platzhalter-Schlüssel (`kUpdateKeyId == 'platzhalter'`) in der App und sie lehnt jedes Manifest ab.

## C. Rückbau (jeweils unabhängig von lx-labs)

| Stufe | Befehle (als root) |
| --- | --- |
| Nur Caddy | `rm /etc/caddy/conf.d/fampad.caddy`, Import-Zeile `import /etc/caddy/conf.d/*.caddy` aus `/etc/caddy/Caddyfile` entfernen (oder `Caddyfile.vor-fampad` zurückkopieren) → `caddy validate --config /etc/caddy/Caddyfile` → `systemctl reload caddy` |
| Dienst | `systemctl disable --now lx-fampad ntfy` |
| Alles | zusätzlich: `rm /etc/systemd/system/lx-fampad.service` (+ `systemctl daemon-reload`), `rm /etc/sudoers.d/lx-fampad`, `gpasswd -d lx lx-fampad` (macht `usermod -aG lx-fampad lx` rückgängig), `userdel lx-fampad`, `dropdb lx_fampad`, `dropuser lx_fampad`, `rm -r /srv/fampad /etc/lx-fampad`, DNS-Einträge löschen |
| ntfy-Quelle | `apt-mark unhold ntfy && apt purge ntfy`, `rm /etc/apt/sources.list.d/ntfy.list /etc/apt/keyrings/ntfy.gpg`, `apt update` |
| journald | `rm /etc/systemd/journald.conf.d/lx-retention.conf` → `systemctl restart systemd-journald` (Achtung: gilt für alle Dienste; Löschen ist nur sinnvoll, wenn die 7-Tage-Grenze auch für lx-labs nicht mehr gewollt ist) |
| Notfall | Snapshot aus A. zurückspielen |

`Caddyfile.vor-fampad` zurückkopieren und `systemctl reload caddy`, falls das Haupt-Caddyfile selbst verändert wurde.

## D. Verhalten bei lx-labs-Updates

- Der lx-labs-Deploy (`npm run deploy`) kopiert sein Caddyfile über `/etc/caddy/Caddyfile`. Mit dem `import`-Block darin bleibt die Familien-Site
  erhalten. Ohne ihn fallen `familyhub.lx-labs.dev` und `ntfy.familyhub.lx-labs.dev` aus; lx-labs.dev selbst bleibt erreichbar.
- Nach dem ersten lx-labs-Deploy danach einmal prüfen: `curl -sI https://familyhub.lx-labs.dev/api/v1/health`.

## E. Prüfungen nach jedem Schritt

- [ ] `curl -sI https://lx-labs.dev | head -1` → `HTTP/2 200`
- [ ] `systemctl is-active lx-labs caddy` → beide `active`
- [ ] `journalctl -u caddy -n 20 --no-pager` ohne Fehler
- [ ] `free -h` und `uptime`: Last/RAM im Rahmen (bei mehr als ca. 80 % RAM: Limits der Units senken oder Server vergrößern)
- [ ] Firewall: `sudo ufw status verbose` unverändert gegenüber A. (nur 22, 80, 443)
- [ ] **von außen** (anderer Rechner/Handy-Netz, nicht vom Server): `nc -zv -w 3 <SERVER-IP> 4400`, `2586`, `5432` müssen alle fehlschlagen (Zeitüberschreitung/refused); nur 80/443 antworten
- [ ] nach Schritt 7/9: `https://familyhub.lx-labs.dev` lädt, Netzwerk-Tab ohne Fremdabrufe, `crossOriginIsolated === true`
- [ ] Sicherheit: `curl -sI https://familyhub.lx-labs.dev` zeigt HSTS, CSP, COOP/COEP; `https://ntfy.familyhub.lx-labs.dev` verlangt Anmeldung

## F. Danach (Betrieb)

- [ ] Backup einrichten (`deploy/backup/einrichtung-backup.sh`, `docs/BACKUP.md`: age-Schlüssel, NAS-Schlüssel, 3 Befehle) und eine Wiederherstellung testen (`docs/WIEDERHERSTELLUNG.md`, `deploy/backup/wiederherstellung-test.sh`).
- [ ] Swapdatei einrichten (`sudo bash deploy/einrichtung-swap.sh --dry-run`, dann ohne Option): 2 GB RAM, derzeit kein Swap.
- [ ] journald-Begrenzung (7 Tage) ist bereits aus Schritt 5 aktiv: `journalctl --disk-usage` und `cat /etc/systemd/journald.conf.d/lx-retention.conf` kontrollieren.
- [ ] Datenschutzerklärung veröffentlichen, bevor andere Personen das System nutzen.
