#!/usr/bin/env bash
# Läuft auf dem NAS (oder einem anderen Rechner, der die Sicherung ABHOLT): holt neue Sicherungen vom Server, prüft sie, rotiert und
# schlägt Alarm (Exit != 0), wenn die letzte Sicherung zu alt ist. Der Server hat keinerlei Zugangsdaten zum NAS.
# Beschreibung und Einrichtung: docs/BACKUP.md (Abschnitt NAS einrichten).
#
# Aufbewahrung auf dem NAS (ohne rsync --delete; gelöscht wird nur von der Rotation hier):
#   14 tägliche, 8 wöchentliche (ISO-Woche), 12 monatliche Sicherungen; je Zeitraum bleibt die jeweils NEUESTE.
#
# Einstellungen oben anpassen oder per Umgebungsvariable setzen. Aufruf:  bash lx-fampad-pull.sh [--rotate-only] [--dry-run]
set -Eeuo pipefail

SERVER="${LXB_SERVER:-familie.lx-labs.dev}"        # Host des VPS (SSH-Port: LXB_PORT)
PORT="${LXB_PORT:-22}"
SSH_KEY="${LXB_KEY:-$HOME/.ssh/lx-fampad-backup}"  # privater SSH-Schlüssel NUR für diese Aufgabe
KNOWN_HOSTS="${LXB_KNOWN_HOSTS:-$HOME/.ssh/lx-fampad-backup.known_hosts}"   # einmalig befüllen (docs/BACKUP.md), danach strikt geprüft
DEST="${LXB_DEST:-/volume1/backup/lx-fampad}"      # Zielordner auf dem NAS
MAX_AGE_HOURS="${LXB_MAX_AGE_HOURS:-36}"           # älter = Alarm
KEEP_DAILY="${LXB_KEEP_DAILY:-14}"
KEEP_WEEKLY="${LXB_KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${LXB_KEEP_MONTHLY:-12}"
NOTIFY_CMD="${LXB_NOTIFY_CMD:-}"                   # optional: Befehl, der bei Fehlern mit der Meldung als Argument aufgerufen wird

ROTATE_ONLY=0
DRY=0
for a in "$@"; do
  case "$a" in
    --rotate-only) ROTATE_ONLY=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "Aufruf: $0 [--rotate-only] [--dry-run]" >&2; exit 2 ;;
  esac
done

alarm() {
  echo "ALARM: $*" >&2
  if [ -n "$NOTIFY_CMD" ]; then $NOTIFY_CMD "lx-fampad Sicherung: $*" || true; fi
  exit 1
}
trap 'alarm "Skript abgebrochen (Zeile $LINENO)"' ERR

ARCHIV="$DEST/archiv"

# Rotation: gibt die Namen der zu LÖSCHENDEN Ordner aus (Namen YYYYMMDD-HHMMSS, UTC). Reine Funktion, testbar.
# Eingabe: Ordnernamen (eine je Zeile); Argument: Stichtag YYYYMMDD
zu_loeschen() {
  local today="$1" names n day week month
  mapfile -t names < <(grep -E '^[0-9]{8}-[0-9]{6}$' | sort)
  [ "${#names[@]}" -gt 0 ] || return 0
  declare -A keep=() lastday=() lastweek=() lastmonth=() okday=() okweek=() okmonth=()
  local i
  for ((i=0; i<KEEP_DAILY; i++)); do okday[$(date -u -d "${today:0:4}-${today:4:2}-${today:6:2} -$i day" +%Y%m%d)]=1; done
  for ((i=0; i<KEEP_WEEKLY; i++)); do okweek[$(date -u -d "${today:0:4}-${today:4:2}-${today:6:2} -$((i*7)) day" +%G-%V)]=1; done
  for ((i=0; i<KEEP_MONTHLY; i++)); do okmonth[$(date -u -d "${today:0:4}-${today:4:2}-01 -$i month" +%Y%m)]=1; done
  for n in "${names[@]}"; do   # aufsteigend: später überschreibt früher = neuester je Zeitraum
    day="${n:0:8}"; week="$(date -u -d "${day:0:4}-${day:4:2}-${day:6:2}" +%G-%V)"; month="${day:0:6}"
    lastday[$day]="$n"; lastweek[$week]="$n"; lastmonth[$month]="$n"
  done
  for day in "${!lastday[@]}"; do [ -n "${okday[$day]:-}" ] && keep[${lastday[$day]}]=1; done
  for week in "${!lastweek[@]}"; do [ -n "${okweek[$week]:-}" ] && keep[${lastweek[$week]}]=1; done
  for month in "${!lastmonth[@]}"; do [ -n "${okmonth[$month]:-}" ] && keep[${lastmonth[$month]}]=1; done
  # Sicherheitsnetz: die 3 neuesten bleiben immer
  for ((i=${#names[@]}-1; i>=0 && i>=${#names[@]}-3; i--)); do keep[${names[$i]}]=1; done
  for n in "${names[@]}"; do [ -n "${keep[$n]:-}" ] || echo "$n"; done
}

# shellcheck disable=SC2317
if [ "${LXB_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi   # nur für Tests: Funktionen laden
mkdir -p "$ARCHIV"

if [ "$ROTATE_ONLY" = 0 ]; then
  [ -r "$SSH_KEY" ] || alarm "SSH-Schlüssel nicht lesbar: $SSH_KEY"
  [ -s "$KNOWN_HOSTS" ] || alarm "known_hosts-Datei fehlt: $KNOWN_HOSTS (einmalig: ssh-keyscan -p $PORT $SERVER > $KNOWN_HOSTS, Fingerabdruck vergleichen)"
  echo "==> Abholen von $SERVER (nur lesend, ohne --delete)"
  RSYNC_OPTS=(-a --partial --exclude '.tmp-*' --exclude '.status.*' --exclude '.latest.*')
  [ "$DRY" = 0 ] || RSYNC_OPTS+=(--dry-run -v)
  rsync "${RSYNC_OPTS[@]}" -e "ssh -p $PORT -i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS" \
    "lxbackup@$SERVER:/" "$ARCHIV/" || alarm "rsync vom Server fehlgeschlagen"
fi

echo "==> Prüfen"
NEUESTE=""
for d in "$ARCHIV"/[0-9]*-[0-9]*; do
  [ -d "$d" ] || continue
  [[ "$(basename "$d")" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
  [ -f "$d/.geprueft" ] && { NEUESTE="$(basename "$d")"; continue; }
  if [ "$DRY" = 1 ]; then continue; fi
  ( cd "$d" && sha256sum -c --strict --quiet SHA256SUMS ) || alarm "Prüfsummen stimmen nicht: $d (nicht rotieren, Sicherung ansehen)"
  ls "$d"/db-*.dump.age >/dev/null 2>&1 || alarm "keine Datenbanksicherung in $d"
  touch "$d/.geprueft"
  NEUESTE="$(basename "$d")"
  echo "    neu und ok: $NEUESTE"
done
[ -n "$NEUESTE" ] || { [ "$DRY" = 1 ] && exit 0; alarm "keine Sicherung im Archiv $ARCHIV"; }

# Alter der neuesten Sicherung (aus dem Ordnernamen, UTC) und der Statusdatei des Servers
epoch_von_namen() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s; }
JETZT="$(date -u +%s)"
ALTER_H=$(( (JETZT - $(epoch_von_namen "$NEUESTE")) / 3600 ))
echo "    neueste Sicherung: $NEUESTE (Alter: ${ALTER_H} h, erlaubt: ${MAX_AGE_HOURS} h)"
[ "$ALTER_H" -le "$MAX_AGE_HOURS" ] || alarm "die neueste Sicherung ist ${ALTER_H} Stunden alt (> ${MAX_AGE_HOURS} h): $NEUESTE"
if [ -f "$ARCHIV/status" ]; then
  RES="$(grep -s '^last_result=' "$ARCHIV/status" | cut -d= -f2-)"
  [ "$RES" = ok ] || alarm "der Server meldet für den letzten Lauf: ${RES:-unbekannt} (journalctl -u lx-fampad-backup auf dem Server)"
fi

echo "==> Rotation ($KEEP_DAILY täglich, $KEEP_WEEKLY wöchentlich, $KEEP_MONTHLY monatlich)"
mapfile -t LOESCHEN < <(for d in "$ARCHIV"/[0-9]*-[0-9]*; do [ -d "$d" ] && basename "$d"; done | zu_loeschen "$(date -u +%Y%m%d)")
if [ "${#LOESCHEN[@]}" -eq 0 ]; then echo "    nichts zu löschen."; fi
for n in "${LOESCHEN[@]}"; do
  [[ "$n" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
  if [ "$DRY" = 1 ]; then echo "    [dry-run] würde löschen: $n"; else rm -rf -- "${ARCHIV:?}/$n"; echo "    gelöscht: $n"; fi
done
echo "==> Fertig."
