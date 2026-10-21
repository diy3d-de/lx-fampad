#!/usr/bin/env bash
# Einrichtung 0.6.0 auf dem Server (als root): Sicherung der Datenbank und Wetter-Einstellungen,
# danach (nach deploy.sh) die Netatmo-Zugangsdaten. Keine Geheimnisse in dieser Datei.
#
#   sudo bash einrichtung-wetter.sh vorher  [--dry-run]   # VOR deploy.sh: DB-Sicherung + Einträge in /etc/lx-fampad/env
#   sudo bash einrichtung-wetter.sh nachher [--dry-run]   # NACH deploy.sh: Zugangsdaten eingeben (ohne Echo), Neustart, Log
#
# Idempotent: vorhandene Einträge mit gleichem Wert bleiben, ein abweichender Wert bricht ab (nichts wird überschrieben).
# Die Sicherung liegt nur für root lesbar unter /var/backups; nach ein bis zwei Wochen löschen.
set -euo pipefail

ENV_DATEI="${ENV_DATEI:-/etc/lx-fampad/env}"
DB_NAME="${DB_NAME:-lx_fampad}"
SICHERUNG="${SICHERUNG:-/var/backups/lx-fampad-vor-0.6.0.sql.gz}"
WEATHER_CLI="${WEATHER_CLI:-/srv/fampad/server/dist/cli/weather-setup.js}"

# Einstellungen ohne Geheimnisse (Ort Salz, Station des Nutzers, Suchrechteck um Salz)
EINTRAEGE=(
  "WEATHER_ENABLED=true"
  "WEATHER_PLACE=Salz"
  "WEATHER_STATION_MAC=70:ee:50:01:79:f2"
  "WEATHER_BBOX=50.49,7.94,50.53,7.99"
)

modus="${1:-}"
trocken=0
[ "${2:-}" = "--dry-run" ] && trocken=1

if [ "$modus" != "vorher" ] && [ "$modus" != "nachher" ]; then
  echo "Aufruf: sudo bash $0 vorher|nachher [--dry-run]" >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte mit sudo ausführen." >&2
  exit 1
fi

tu() { # Befehl ausführen oder im Trockenlauf nur anzeigen
  if [ "$trocken" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

vorher() {
  echo "==> 1/2 Datenbank sichern ($SICHERUNG)"
  if [ -e "$SICHERUNG" ]; then
    echo "    Datei existiert schon, wird nicht überschrieben: $SICHERUNG" >&2
    exit 1
  fi
  if [ "$trocken" -eq 1 ]; then
    echo "[dry-run] pg_dump $DB_NAME | gzip > $SICHERUNG (umask 077)"
  else
    (
      umask 077
      cd /tmp
      runuser -u postgres -- pg_dump "$DB_NAME" | gzip > "$SICHERUNG"
    )
    gzip -t "$SICHERUNG"
    groesse=$(stat -c %s "$SICHERUNG")
    if [ "$groesse" -lt 1024 ]; then
      echo "    Sicherung auffällig klein ($groesse Byte), bitte prüfen." >&2
      exit 1
    fi
    echo "    ok: $(ls -lh "$SICHERUNG" | awk '{print $5, $9}')"
  fi

  echo "==> 2/2 Wetter-Einstellungen in $ENV_DATEI"
  if [ ! -f "$ENV_DATEI" ]; then
    echo "    $ENV_DATEI fehlt." >&2
    exit 1
  fi
  neu=()
  for zeile in "${EINTRAEGE[@]}"; do
    schluessel="${zeile%%=*}"
    vorhanden=$(grep -E "^${schluessel}=" "$ENV_DATEI" || true)
    if [ -z "$vorhanden" ]; then
      neu+=("$zeile")
    elif [ "$vorhanden" != "$zeile" ]; then
      echo "    Abbruch: $schluessel steht schon anders in $ENV_DATEI ($vorhanden); bitte von Hand prüfen." >&2
      exit 1
    fi
  done
  if [ "${#neu[@]}" -eq 0 ]; then
    echo "    schon vollständig, nichts zu tun."
  else
    tu cp -p "$ENV_DATEI" "$ENV_DATEI.bak-$(date +%Y%m%d%H%M%S)"
    if [ "$trocken" -eq 1 ]; then
      printf '[dry-run] anhängen: %s\n' "${neu[@]}"
    else
      printf '%s\n' "${neu[@]}" >> "$ENV_DATEI"
      echo "    angehängt: ${#neu[@]} Zeile(n)"
    fi
  fi
  echo "Fertig. Jetzt: ssh lx-labs bash lx-fampad/deploy/deploy.sh (macht Claude), danach: sudo bash $0 nachher"
}

nachher() {
  if [ ! -f "$WEATHER_CLI" ]; then
    echo "$WEATHER_CLI fehlt: erst deploy.sh ausführen." >&2
    exit 1
  fi
  echo "==> Netatmo-Zugangsdaten eingeben (Eingabe unsichtbar; client_id, client_secret, refresh_token)"
  if [ "$trocken" -eq 1 ]; then
    echo "[dry-run] node --env-file=$ENV_DATEI $WEATHER_CLI"
    echo "[dry-run] systemctl restart lx-fampad"
    return
  fi
  node --env-file="$ENV_DATEI" "$WEATHER_CLI"
  echo "==> Dienst neu starten"
  systemctl restart lx-fampad
  sleep 3
  systemctl is-active lx-fampad
  journalctl -u lx-fampad -n 30 --no-pager
  echo "Die Wetter-Kachel erscheint in der App nach spätestens 10 Minuten."
  echo "Zustand prüfen: sudo node --env-file=$ENV_DATEI $WEATHER_CLI --status"
}

"$modus"
