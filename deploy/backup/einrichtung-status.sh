#!/usr/bin/env bash
# Einrichtung der zweiten, lesbaren Statusdatei der Sicherung für die Betreiber-Ansicht "Betrieb" (einmaliger root-Schritt, idempotent).
#   Ordner /var/lib/lx-fampad-status  (root:lx-fampad, 0750: root schreibt, der Dienst lx-fampad liest, sonst niemand)
#   Datei  /var/lib/lx-fampad-status/backup.status   (schreibt lx-fampad-backup nach jedem Lauf; nur last_result, Zeiten und Größen, keine Pfade, keine Geheimnisse)
# Der Dienst bekommt KEIN Leserecht auf /var/backups/lx-fampad (dort liegen die verschlüsselten Sicherungen).
# Gibt es schon eine Statusdatei der Sicherung, wird die zweite sofort daraus gefüllt (sonst erst beim nächsten Lauf um 03:30 Uhr).
# Danach: das aktualisierte Sicherungsskript installieren (sudo bash deploy/backup/einrichtung-backup.sh, ohne Optionen: vorhandene Schlüssel bleiben).
#
# Aufruf auf dem Server:   sudo bash ~/lx-fampad/deploy/backup/einrichtung-status.sh --dry-run    (nur prüfen)
#                          sudo bash ~/lx-fampad/deploy/backup/einrichtung-status.sh
# Fasst weder Caddy noch das Haupt-Caddyfile, PostgreSQL, ntfy oder die Sicherungen an.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

DIR=/var/lib/lx-fampad-status
GROUP=lx-fampad
SRC=/var/backups/lx-fampad/status
DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "Unbekannte Option: $1 (erlaubt: --dry-run)" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten:  sudo bash $0 [--dry-run]" >&2; exit 1; }
getent group "$GROUP" >/dev/null || { echo "FEHLER: Gruppe $GROUP fehlt (der Dienst lx-fampad ist noch nicht eingerichtet)." >&2; exit 1; }
if [ -L "$DIR" ]; then echo "FEHLER: $DIR ist ein Symlink, Abbruch." >&2; exit 1; fi
if [ -e "$DIR" ] && [ ! -d "$DIR" ]; then echo "FEHLER: $DIR ist kein Ordner." >&2; exit 1; fi

echo "==> Statusordner $DIR (root:$GROUP, 0750)$([ "$DRY" = 1 ] && echo ' (Trockenlauf: es wird nichts verändert)')"
if [ "$DRY" = 1 ]; then
  [ -d "$DIR" ] && echo "    vorhanden: $(stat -c '%U:%G %a' "$DIR")" || echo "    würde angelegt"
  [ -f "$SRC" ] && echo "    würde backup.status aus der vorhandenen Statusdatei füllen" || echo "    noch keine Statusdatei der Sicherung: backup.status entsteht beim nächsten Lauf"
  exit 0
fi

install -d -m 0750 -o root -g "$GROUP" "$DIR"
if [ -f "$SRC" ]; then
  TS="$DIR/.backup.status.$$"
  # dieselben Schlüssel wie lx-fampad-backup (write_service_status): nichts anderes, keine Pfade
  if grep -E '^(last_run_utc|last_run_epoch|last_result|last_success_utc|last_success_epoch|db_bytes|config_bytes|total_bytes)=[A-Za-z0-9:_.-]*$' "$SRC" > "$TS"; then
    chgrp "$GROUP" "$TS"; chmod 0640 "$TS"; mv -f "$TS" "$DIR/backup.status"
    echo "    backup.status aus der vorhandenen Statusdatei gefüllt"
  else
    rm -f "$TS"
    echo "    Hinweis: die vorhandene Statusdatei enthält keine bekannten Schlüssel, backup.status entsteht beim nächsten Lauf"
  fi
else
  echo "    noch keine Statusdatei der Sicherung: backup.status entsteht beim nächsten Lauf"
fi
echo "==> Fertig: $(stat -c '%U:%G %a' "$DIR")"
echo "    Weiter: das Sicherungsskript aktualisieren (sudo bash deploy/backup/einrichtung-backup.sh), dann zeigt Betrieb die Sicherung und warnt bei Überalterung."
