#!/usr/bin/env bash
# Einrichtung Teil 2: Caddy für familyhub.lx-labs.dev (Schritt 6 aus deploy/README.md).
# Schützt lx-labs.dev: erst sichern, dann einbinden, prüfen; bei jedem Fehler wird das Haupt-Caddyfile zurückgesetzt.
# Voraussetzung: DNS-Einträge `familyhub` und `ntfy.familyhub` zeigen auf den Server (nur DNS, graue Wolke).
# ntfy gehört NICHT dazu: Der Site-Block für ntfy.familyhub wird hier vorerst ausgelassen.
#
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-2.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
  echo "Bitte als Benutzer lx starten:  sudo bash $0" >&2
  exit 1
fi
REPO="$(getent passwd "$SUDO_USER" | cut -d: -f6)/lx-fampad"
CADDYFILE=/etc/caddy/Caddyfile
# Jede Ausführung sichert frisch (mit Zeitstempel) und stellt nur DIESE Sicherung wieder her, nie eine ältere
BACKUP="/etc/caddy/Caddyfile.vor-fampad.$(date +%Y%m%d-%H%M%S)"
SITE=/etc/caddy/conf.d/fampad.caddy
IMPORT='import /etc/caddy/conf.d/*.caddy'

echo "==> Voraussetzungen"
curl -fsS http://127.0.0.1:4400/api/v1/health | grep -q '"db":"ok"' || { echo "API läuft nicht (Teil 1 zuerst)" >&2; exit 1; }
curl -fsI --max-time 10 https://lx-labs.dev >/dev/null || { echo "lx-labs.dev antwortet schon vor der Änderung nicht, Abbruch" >&2; exit 1; }
if grep -nE '^[[:space:]]*log[[:space:]{]|^[[:space:]]*log$' "$CADDYFILE" | grep -v '^\s*#' ; then
  echo "    Hinweis: Das Haupt-Caddyfile enthält 'log' (siehe oben). Prüfe, ob es nur im Block von lx-labs.dev steht."
fi

echo "==> Site-Datei ohne ntfy-Block bereitstellen"
mkdir -p /etc/caddy/conf.d
# Alles ab dem ntfy-Block abschneiden (ntfy wird später eingerichtet)
awk '/^ntfy\.familyhub\.lx-labs\.dev/{exit} {print}' "$REPO/deploy/Caddyfile" > "$SITE"
grep -q '^familyhub\.lx-labs\.dev' "$SITE" || { echo "Site-Block familyhub.lx-labs.dev nicht gefunden" >&2; rm -f "$SITE"; exit 1; }

echo "==> Haupt-Caddyfile sichern und Import ergänzen"
cp -p "$CADDYFILE" "$BACKUP"
echo "    Sicherung: $BACKUP"
grep -qsE '^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy' "$CADDYFILE" || printf '\n%s\n' "$IMPORT" >> "$CADDYFILE"

zuruecksetzen() {
  echo "!!  Fehler: Haupt-Caddyfile wird zurückgesetzt." >&2
  cp "$BACKUP" "$CADDYFILE"
  rm -f "$SITE"
  systemctl reload caddy || true
  curl -sI --max-time 10 https://lx-labs.dev | head -1 >&2 || true
  exit 1
}

echo "==> Prüfen"
caddy validate --config "$CADDYFILE" --adapter caddyfile || zuruecksetzen

echo "==> Neu laden"
systemctl reload caddy || zuruecksetzen
sleep 3
curl -fsI --max-time 10 https://lx-labs.dev | head -1 || zuruecksetzen

echo "==> Zertifikat für familyhub.lx-labs.dev abwarten (bis zu 60 s)"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 https://familyhub.lx-labs.dev/api/v1/health 2>/dev/null | grep -q '"db":"ok"'; then
    echo "    familyhub.lx-labs.dev antwortet über HTTPS."
    break
  fi
  sleep 2
done
curl -sI --max-time 10 https://familyhub.lx-labs.dev/api/v1/health | head -1 || true
echo "lx-labs.dev:  $(curl -sI --max-time 10 https://lx-labs.dev | head -1)"
echo
echo "Fertig. Hinweis: Ein späteres lx-labs-Deploy überschreibt /etc/caddy/Caddyfile und entfernt die Import-Zeile (deploy/README.md, Schritt 6)."
