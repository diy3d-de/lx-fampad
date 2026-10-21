#!/usr/bin/env bash
# Einrichtung des Wetter-Abruf-Dienstes (lx-fampad-weather.service, deploy/README.md, Abschnitt 12). Idempotent.
#   dienst   installiert die Unit nach /etc/systemd/system (nur wenn sie sich unterscheidet), prüft sie mit systemd-analyze,
#            daemon-reload, enable --now und zeigt den Status. Caddy, Haupt-Caddyfile und /etc/lx-fampad/env bleiben unberührt.
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-wetter.sh dienst [--dry-run]
#   --dry-run  prüft nur (Voraussetzungen, systemd-analyze auf einer Kopie) und zeigt, was geschehen würde.
# Voraussetzungen: deploy.sh ist gelaufen (dist/cli/weather-poller.js liegt in /srv/fampad/server), die API lief mindestens einmal
# (Migration 0015 hat die Wetter-Tabellen angelegt).
set -Eeuo pipefail

UNIT=lx-fampad-weather.service
ZIEL="/etc/systemd/system/$UNIT"
POLLER=/srv/fampad/server/dist/cli/weather-poller.js

DRY=0
MODUS="${1:-}"
case "${2:-}" in "") ;; --dry-run) DRY=1 ;; *) MODUS="" ;; esac
if [ "$MODUS" != "dienst" ]; then
  echo "Aufruf: sudo bash $0 dienst [--dry-run]" >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte mit sudo starten:  sudo bash $0 dienst [--dry-run]" >&2
  exit 1
fi
QUELLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$UNIT"
[ -f "$QUELLE" ] || { echo "FEHLER: $QUELLE fehlt." >&2; exit 1; }
[ -f "$POLLER" ] || { echo "FEHLER: $POLLER fehlt. Erst deploy.sh ausführen (Stand mit dem Wetter-Dienst)." >&2; exit 1; }
[ -f /etc/lx-fampad/env ] || { echo "FEHLER: /etc/lx-fampad/env fehlt (README, Schritt 5)." >&2; exit 1; }
if ! grep -qE '^WEATHER_ENABLED=(true|1)[[:space:]]*$' /etc/lx-fampad/env; then
  echo "Hinweis: WEATHER_ENABLED=true steht nicht in /etc/lx-fampad/env. Der Dienst beendet sich dann sofort (Exit 0) und bleibt gestoppt." >&2
fi

# Prüfung auf einer Kopie, bevor etwas installiert wird (systemd-analyze verify liest die Datei und ihre Abhängigkeiten)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$QUELLE" "$TMP/$UNIT"
echo "==> systemd-analyze verify"
systemd-analyze verify "$TMP/$UNIT"

if [ -f "$ZIEL" ] && cmp -s "$QUELLE" "$ZIEL"; then
  echo "==> Unit ist bereits aktuell: $ZIEL"
  GEAENDERT=0
else
  echo "==> Unit wird installiert: $ZIEL"
  [ -f "$ZIEL" ] && diff -u "$ZIEL" "$QUELLE" || true
  GEAENDERT=1
fi
if [ "$DRY" -eq 1 ]; then
  echo "==> --dry-run: nichts installiert, nichts gestartet. Danach: sudo bash $0 dienst"
  exit 0
fi

if [ "$GEAENDERT" -eq 1 ]; then
  install -m 0644 -o root -g root "$QUELLE" "$ZIEL"
  systemctl daemon-reload
fi
systemctl enable --now "$UNIT"
# eine geänderte Unit wirkt erst nach einem Neustart
[ "$GEAENDERT" -eq 1 ] && systemctl restart "$UNIT"
sleep 2
systemctl --no-pager --full status "$UNIT" || true
echo "==> Log: journalctl -u lx-fampad-weather -n 30   |   Zustand: sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js --status"
