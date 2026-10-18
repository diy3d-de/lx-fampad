# VPS-Checkliste: Familienzentrale neben lx-labs.dev

Ziel: `familie.lx-labs.dev` auf den bestehenden netcup-VPS bringen, ohne dass `lx-labs.dev` ausfällt.
Die Befehle stehen in [`deploy/README.md`](../deploy/README.md) (Nummern in Klammern). Dieser Plan legt Reihenfolge,
Prüfungen und Rückbau fest. Auf dem Server wird erst nach ausdrücklicher Freigabe gearbeitet.

## A. Vorher prüfen (nur lesen)

- [ ] **Snapshot/Backup** im netcup SCP anlegen; Datum notieren.
- [ ] Debian-Version: `cat /etc/os-release` (erwartet 13).
- [ ] RAM und Platz: `free -h`, `df -h /srv /var` — Richtwert: mind. 1 GB RAM frei, mind. 20 GB Platz für Dateien
      (Karte später zusätzlich 5–10 GB).
- [ ] Belegte Ports: `ss -tlnp` — frei sein müssen `127.0.0.1:4400` (API), `127.0.0.1:2586` (ntfy), `127.0.0.1:5432` (PostgreSQL).
- [ ] lx-labs läuft: `systemctl status lx-labs`, `curl -sI https://lx-labs.dev | head -3` — Ausgangszustand merken.
- [ ] Sicherung der Caddy-Konfiguration: `cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.vor-familie`.
- [ ] Vorschlag für `lx-labs/deploy/Caddyfile` vorbereiten: `import /etc/caddy/conf.d/*.caddy` (siehe C. und deploy/README), damit ein
      lx-labs-Deploy die Familien-Site nicht mehr entfernt.

## B. Reihenfolge der Einrichtung (jeweils danach lx-labs.dev prüfen, siehe E.)

1. **DNS** bei Cloudflare: `familie` und `ntfy.familie` als A-Record, *DNS only* (README 0). Betrifft nur die neuen Namen.
2. **PostgreSQL 17** installieren, Rolle und Datenbank `lx_familie` anlegen, Passwort per `\password` (README 1).
3. **Systembenutzer, Verzeichnisse** (`/srv/familie`), `/etc/lx-familie/env` als `root:root 0600` (README 2).
4. **Node 24**: nur nutzen, falls lx-labs dieselbe Hauptversion hat; sonst nicht systemweit ändern (README 3).
5. **Code holen, Dienst einrichten** (README 4–5): `lx-familie.service` startet auf `127.0.0.1:4400`. Prüfen: `curl http://127.0.0.1:4400/api/v1/health` liefert `"db":"ok"`.
6. **Caddy**: `familie.caddy` nach `/etc/caddy/conf.d/`, **erst** `caddy validate --config /etc/caddy/Caddyfile`, dann `systemctl reload caddy` (README 6). Bei Fehler: Rückbau C.
7. **ntfy** auf eigener Subdomain, `deny-all`, danach Benutzer pro Handy (README 7).
8. **Web-App hochladen** mit `deploy-web.sh` (README 8).
9. **Erst später:** `assetlinks.json`, `latest.json` und APK **nicht** hochladen, bis der Ed25519-Verifier und die Signatur fertig sind (README 9).

## C. Rückbau (jeweils unabhängig von lx-labs)

| Stufe | Befehle (als root) |
| --- | --- |
| Nur Caddy | `rm /etc/caddy/conf.d/familie.caddy` (bzw. Import-Zeile entfernen) → `caddy validate` → `systemctl reload caddy` |
| Dienst | `systemctl disable --now lx-familie ntfy` |
| Alles | zusätzlich: `rm /etc/systemd/system/lx-familie.service`, `userdel` des Systembenutzers, `dropdb lx_familie`, `dropuser lx_familie`, `rm -r /srv/familie /etc/lx-familie`, DNS-Einträge löschen |
| Notfall | Snapshot aus A. zurückspielen |

`Caddyfile.vor-familie` zurückkopieren und `systemctl reload caddy`, falls das Haupt-Caddyfile selbst verändert wurde.

## D. Verhalten bei lx-labs-Updates

- Der lx-labs-Deploy (`npm run deploy`) kopiert sein Caddyfile über `/etc/caddy/Caddyfile`. Mit dem `import`-Block darin bleibt die Familien-Site
  erhalten. Ohne ihn fallen `familie.lx-labs.dev` und `ntfy.familie.lx-labs.dev` aus; lx-labs.dev selbst bleibt erreichbar.
- Nach dem ersten lx-labs-Deploy danach einmal prüfen: `curl -sI https://familie.lx-labs.dev/api/v1/health`.

## E. Prüfungen nach jedem Schritt

- [ ] `curl -sI https://lx-labs.dev | head -1` → `HTTP/2 200`
- [ ] `systemctl is-active lx-labs caddy` → beide `active`
- [ ] `journalctl -u caddy -n 20 --no-pager` ohne Fehler
- [ ] `free -h` und `uptime`: Last/RAM im Rahmen (bei mehr als ca. 80 % RAM: Limits der Units senken oder Server vergrößern)
- [ ] nach Schritt 6/8: `https://familie.lx-labs.dev` lädt, Netzwerk-Tab ohne Fremdabrufe, `crossOriginIsolated === true`
- [ ] Sicherheit: `curl -sI https://familie.lx-labs.dev` zeigt HSTS, CSP, COOP/COEP; `https://ntfy.familie.lx-labs.dev` verlangt Anmeldung

## F. Danach (Betrieb)

- [ ] Backup-Job (`pg_dump` + Dateien, restic) einrichten und eine Wiederherstellung testen.
- [ ] journald auf 7 Tage begrenzen (`MaxRetentionSec=7day`).
- [ ] Datenschutzerklärung veröffentlichen, bevor andere Personen das System nutzen.
