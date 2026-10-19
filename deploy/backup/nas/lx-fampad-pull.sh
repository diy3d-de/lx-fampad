#!/usr/bin/env bash
# Läuft auf dem NAS (oder einem anderen Rechner, der die Sicherung ABHOLT): holt neue Sicherungen vom Server, prüft sie, rotiert und
# schlägt Alarm (Exit != 0), wenn die letzte Sicherung zu alt ist. Der Server hat keine Zugangsdaten zum NAS (er kennt nur dessen IP
# und öffentlichen SSH-Schlüssel); der NAS-Schlüssel kann dort nur lesen.
# Beschreibung und Einrichtung: docs/BACKUP.md (Abschnitt NAS einrichten).
#
# Aufbewahrung auf dem NAS (ohne rsync --delete; gelöscht wird nur von der Rotation hier):
#   14 tägliche, 8 wöchentliche (ISO-Woche), 12 monatliche Sicherungen; je Zeitraum bleibt die jeweils NEUESTE.
# Schutz vor einem übernommenen Server, der das NAS füllen oder die Rotation austricksen will: nur reguläre Dateien/Ordner (keine Links,
# Geräte, Rechte, Besitzer), Obergrenze je Datei, Ordner mit Datum in der Zukunft = Alarm, Rotation löscht nur, wenn danach genug geprüfte,
# plausibel große Ordner bleiben, Obergrenzen für Anzahl und Gesamtgröße.
#
# Einstellungen per Umgebungsvariable (LXB_…). Aufruf:  bash lx-fampad-pull.sh [--rotate-only] [--dry-run]
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
MAX_FILE_SIZE="${LXB_MAX_FILE_SIZE:-2G}"           # rsync --max-size: größere Dateien werden nicht geholt
MAX_DIRS="${LXB_MAX_DIRS:-120}"                    # mehr Ordner im Archiv = Alarm (Normalwert höchstens ca. 40)
MAX_TOTAL_MB="${LXB_MAX_TOTAL_MB:-20480}"          # mehr Gesamtgröße des Archivs = Alarm
MIN_FREE_MB="${LXB_MIN_FREE_MB:-2048}"             # weniger freier Platz am Ziel = Alarm vor dem Holen
MIN_VALID="${LXB_MIN_VALID:-3}"                    # nach der Rotation müssen mindestens so viele geprüfte Ordner bleiben
MIN_DB_BYTES="${LXB_MIN_DB_BYTES:-2000}"           # kleinere Datenbankdatei gilt als nicht plausibel
RSYNC_TIMEOUT="${LXB_TIMEOUT:-2h}"
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

# Voraussetzung GNU-date: ohne sie würden Alter und Rotation still falsch gerechnet (BusyBox)
[ "$(date -u -d '2026-01-01 -1 day' +%F 2>/dev/null || true)" = "2025-12-31" ] \
  || alarm "date -d funktioniert nicht (kein GNU date, z. B. BusyBox): Alter und Rotation sind nicht berechenbar. GNU coreutils installieren oder das Skript im Container ausführen (docs/BACKUP.md)"
mkdir -p "$ARCHIV"
epoch_von_namen() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s; }
JETZT="$(date -u +%s)"

if [ "$ROTATE_ONLY" = 0 ]; then
  [ -r "$SSH_KEY" ] || alarm "SSH-Schlüssel nicht lesbar: $SSH_KEY"
  [ -s "$KNOWN_HOSTS" ] || alarm "known_hosts-Datei fehlt: $KNOWN_HOSTS (einmalig: ssh-keyscan -p $PORT $SERVER > '$KNOWN_HOSTS', Fingerabdruck vergleichen)"
  RSYNC_VER="$(rsync --version | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p')"   # kein head -1: SIGPIPE zählt unter pipefail als Fehler
  if [ -z "$RSYNC_VER" ] || [ "$(printf '%s\n3.4.0\n' "$RSYNC_VER" | sort -V | head -1)" != "3.4.0" ]; then
    echo "WARNUNG: rsync ${RSYNC_VER:-unbekannt} ist älter als 3.4.0 (bekannte Sicherheitslücken, CVE-2024-12086 u. a.). NAS-Firmware/Paket aktualisieren." >&2
  fi
  FREI="$(df --output=avail -m "$DEST" | tail -1 | tr -d ' ')"
  [ "$FREI" -ge "$MIN_FREE_MB" ] || alarm "zu wenig freier Platz am Ziel: ${FREI} MB (Minimum $MIN_FREE_MB MB)"
  echo "==> Abholen von $SERVER (nur lesend, ohne --delete)"
  SSH_CMD="ssh -p $PORT -i $(printf '%q' "$SSH_KEY") -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(printf '%q' "$KNOWN_HOSTS") -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"
  RSYNC_OPTS=(-rt --no-links --no-perms --no-owner --no-group --no-devices --no-specials --max-size="$MAX_FILE_SIZE" --partial --exclude '.tmp-*' --exclude '.status.*' --exclude '.latest.*')
  if [ "$DRY" = 1 ]; then RSYNC_OPTS+=(--dry-run -v); fi
  timeout "$RSYNC_TIMEOUT" rsync "${RSYNC_OPTS[@]}" -e "$SSH_CMD" "lxbackup@$SERVER:/" "$ARCHIV/" || alarm "rsync vom Server fehlgeschlagen oder Zeitlimit ($RSYNC_TIMEOUT) überschritten"
fi

echo "==> Prüfen"
NEUESTE=""
ANZAHL=0
for d in "$ARCHIV"/[0-9]*-[0-9]*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  [[ "$n" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
  ANZAHL=$((ANZAHL + 1))
  if [ "$(epoch_von_namen "$n")" -gt $((JETZT + 3600)) ]; then
    alarm "Ordner mit Datum in der Zukunft: $n (Manipulation oder falsche Uhr; nichts wird rotiert, Ordner prüfen)"
  fi
  if [ -f "$d/.geprueft" ]; then NEUESTE="$n"; continue; fi
  if [ "$DRY" = 1 ]; then continue; fi
  ( cd "$d" && sha256sum -c --strict --quiet SHA256SUMS ) || alarm "Prüfsummen stimmen nicht: $d (nicht rotieren, Sicherung ansehen)"
  ls "$d"/db-*.dump.age >/dev/null 2>&1 || alarm "keine Datenbanksicherung in $d"
  touch "$d/.geprueft"
  NEUESTE="$n"
  echo "    neu und ok: $n"
done
[ -n "$NEUESTE" ] || { [ "$DRY" = 1 ] && exit 0; alarm "keine Sicherung im Archiv $ARCHIV"; }
[ "$ANZAHL" -le "$MAX_DIRS" ] || alarm "$ANZAHL Ordner im Archiv (Grenze $MAX_DIRS): Flut oder Rotation defekt, nichts wird gelöscht"
GROESSE_MB="$(du -sm "$ARCHIV" | cut -f1)"
[ "$GROESSE_MB" -le "$MAX_TOTAL_MB" ] || alarm "Archiv ist ${GROESSE_MB} MB groß (Grenze ${MAX_TOTAL_MB} MB): nichts wird gelöscht, Ursache klären"

# Alter der neuesten Sicherung (aus dem Ordnernamen, UTC) und der Statusdatei des Servers
ALTER_H=$(( (JETZT - $(epoch_von_namen "$NEUESTE")) / 3600 ))
echo "    neueste Sicherung: $NEUESTE (Alter: ${ALTER_H} h, erlaubt: ${MAX_AGE_HOURS} h)"
[ "$ALTER_H" -le "$MAX_AGE_HOURS" ] || alarm "die neueste Sicherung ist ${ALTER_H} Stunden alt (> ${MAX_AGE_HOURS} h): $NEUESTE"
if [ -f "$ARCHIV/status" ]; then
  RES="$(grep -s '^last_result=' "$ARCHIV/status" | cut -d= -f2-)"
  [ "$RES" = ok ] || alarm "der Server meldet für den letzten Lauf: ${RES:-unbekannt} (journalctl -u lx-fampad-backup auf dem Server)"
fi

echo "==> Rotation ($KEEP_DAILY täglich, $KEEP_WEEKLY wöchentlich, $KEEP_MONTHLY monatlich)"
mapfile -t ALLE < <(for d in "$ARCHIV"/[0-9]*-[0-9]*; do if [ -d "$d" ]; then basename "$d"; fi; done)
mapfile -t LOESCHEN < <(printf '%s\n' "${ALLE[@]}" | zu_loeschen "$(date -u +%Y%m%d)")
# Sicherheitsnetz: nach dem Löschen müssen mindestens MIN_VALID geprüfte, plausibel große Ordner übrig sein
GUT=0
for n in "${ALLE[@]}"; do
  if printf '%s\n' "${LOESCHEN[@]}" | grep -qx "$n"; then continue; fi
  if [ -f "$ARCHIV/$n/.geprueft" ] && [ "$(find "$ARCHIV/$n" -name 'db-*.dump.age' -size +"$((MIN_DB_BYTES - 1))"c | wc -l)" -ge 1 ]; then GUT=$((GUT + 1)); fi
done
if [ "${#LOESCHEN[@]}" -gt 0 ] && [ "$GUT" -lt "$MIN_VALID" ]; then
  alarm "Rotation abgebrochen: nach dem Löschen blieben nur $GUT geprüfte, plausibel große Ordner (Minimum $MIN_VALID). Archiv ansehen"
fi
if [ "${#LOESCHEN[@]}" -eq 0 ]; then echo "    nichts zu löschen."; fi
for n in "${LOESCHEN[@]}"; do
  [[ "$n" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
  if [ "$DRY" = 1 ]; then echo "    [dry-run] würde löschen: $n"; else rm -rf -- "${ARCHIV:?}/$n"; echo "    gelöscht: $n"; fi
done
echo "==> Fertig."
