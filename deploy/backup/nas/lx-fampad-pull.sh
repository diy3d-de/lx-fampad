#!/usr/bin/env bash
# Läuft auf dem NAS (oder einem anderen Rechner, der die Sicherung ABHOLT): holt neue Sicherungen vom Server, prüft sie, rotiert und
# schlägt Alarm (Exit != 0), wenn die letzte Sicherung zu alt ist. Der Server hat keine Zugangsdaten zum NAS (er kennt nur dessen IP
# und öffentlichen SSH-Schlüssel); der NAS-Schlüssel kann dort nur lesen.
# Beschreibung und Einrichtung: docs/BACKUP.md (Abschnitt NAS einrichten).
#
# Aufbewahrung auf dem NAS (ohne rsync --delete; gelöscht wird nur von der Rotation hier):
#   14 tägliche, 8 wöchentliche (ISO-Woche), 12 monatliche Sicherungen; je Zeitraum bleibt die jeweils NEUESTE.
# Es wird zuerst in ein Staging-Verzeichnis geholt (nur Ordnernamen YYYYMMDD-HHMMSS mit db-/config-/files-*.age und SHA256SUMS, nie bereits
# bekannte Ordner), geprüft und erst dann ins Archiv verschoben: der Server kann Archivordner weder überschreiben noch die lokale Prüfmarke
# (.geprueft = Hash der SHA256SUMS) setzen. Neue Ordner müssen NEUER sein als alles, was lokal je gesehen wurde (gesehen.txt), sonst Alarm.
# Schutz vor einem übernommenen Server, der das NAS füllen oder die Rotation austricksen will: nur reguläre Dateien/Ordner (keine Links,
# Geräte, Rechte, Besitzer), Obergrenze je Datei, Ordner mit Datum in der Zukunft = Alarm, Rotation löscht nur, wenn danach genug geprüfte,
# plausibel große Ordner bleiben, Obergrenzen für Anzahl und Gesamtgröße.
#
# Einstellungen per Umgebungsvariable (LXB_…). Aufruf:  bash lx-fampad-pull.sh [--rotate-only] [--dry-run]
set -Eeuo pipefail
umask 077

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
MAX_PULL_MB="${LXB_MAX_PULL_MB:-1024}"           # mehr zu holende Daten je Lauf (vorab per rsync --dry-run --stats ermittelt) = Alarm
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
# Pfade/Host landen in der ssh-Befehlszeile für rsync -e (Leerzeichen und Anführungszeichen würden dort falsch zerlegt): ablehnen
case "$SERVER$SSH_KEY$KNOWN_HOSTS" in
  *[[:space:]\'\"\\]*) alarm "Host, SSH-Schlüssel- und known_hosts-Pfad dürfen keine Leerzeichen, Anführungszeichen oder Backslashes enthalten" ;;
esac
[[ "$PORT" =~ ^[0-9]+$ ]] || alarm "LXB_PORT muss eine Zahl sein"
mkdir -p "$ARCHIV"
GESEHEN="$DEST/gesehen.txt"     # alle je angenommenen Ordnernamen (auch die durch die Rotation gelöschten)
touch "$GESEHEN"
epoch_von_namen() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s; }
hash_von() { sha256sum "$1/SHA256SUMS" | cut -d' ' -f1; }
JETZT="$(date -u +%s)"
NAME_RE='^[0-9]{8}-[0-9]{6}$'

# Übernimmt einen geholten Ordner nur, wenn er vollständig geprüft ist
pruefen_ordner() {   # $1 = Pfad; Meldungen über alarm()
  local d="$1"
  [ -z "$(find "$d" ! -type f ! -type d -print -quit)" ] || alarm "$d enthält Links oder Sonderdateien (nicht übernommen)"
  [ -f "$d/SHA256SUMS" ] || alarm "$d: SHA256SUMS fehlt (nicht übernommen)"
  ( cd "$d" && sha256sum -c --strict --quiet SHA256SUMS ) || alarm "Prüfsummen stimmen nicht: $d (nicht übernommen, nicht rotieren, Sicherung ansehen)"
  ls "$d"/db-*.dump.age >/dev/null 2>&1 || alarm "keine Datenbanksicherung in $d (nicht übernommen)"
  [ "$(find "$d" -name 'db-*.dump.age' -size +"$((MIN_DB_BYTES - 1))"c | wc -l)" -ge 1 ] || alarm "Datenbanksicherung in $d ist unplausibel klein (nicht übernommen)"
}

if [ "$ROTATE_ONLY" = 0 ]; then
  [ -r "$SSH_KEY" ] || alarm "SSH-Schlüssel nicht lesbar: $SSH_KEY"
  [ -s "$KNOWN_HOSTS" ] || alarm "known_hosts-Datei fehlt: $KNOWN_HOSTS (einmalig: ssh-keyscan -p $PORT $SERVER > '$KNOWN_HOSTS', Fingerabdruck vergleichen)"
  RSYNC_VER="$(rsync --version | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p')"   # kein head -1: SIGPIPE zählt unter pipefail als Fehler
  if [ -z "$RSYNC_VER" ] || [ "$(printf '%s\n3.4.0\n' "$RSYNC_VER" | sort -V | head -1)" != "3.4.0" ]; then
    echo "WARNUNG: rsync ${RSYNC_VER:-unbekannt} ist älter als 3.4.0 (bekannte Sicherheitslücken, CVE-2024-12086 u. a.). NAS-Firmware/Paket aktualisieren." >&2
  fi
  FREI="$(df --output=avail -m "$DEST" | tail -1 | tr -d ' ')"
  [ "$FREI" -ge "$MIN_FREE_MB" ] || alarm "zu wenig freier Platz am Ziel: ${FREI} MB (Minimum $MIN_FREE_MB MB)"

  # Bereits bekannte Ordner (Archiv + gesehen.txt) holt rsync gar nicht erst: der Server kann sie nicht überschreiben
  STAGING="$DEST/.staging"
  rm -rf "$STAGING"; mkdir -m 0700 "$STAGING"
  EXCL="$DEST/.exclude"
  { for d in "$ARCHIV"/[0-9]*-[0-9]*; do if [ -d "$d" ]; then basename "$d"; fi; done; cat "$GESEHEN"; } | { grep -E "$NAME_RE" || true; } | sort -u | sed 's#^#/#; s#$#/#' > "$EXCL"
  # Dieselbe Liste an Optionen nutzt der Selbsttest in einrichtung-backup.sh (synchron halten)
  SSH_CMD="ssh -p $PORT -i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"
  RSYNC_OPTS=(-rt --no-links --no-perms --no-owner --no-group --no-devices --no-specials --max-size="$MAX_FILE_SIZE"
    --exclude-from="$EXCL" --exclude='.geprueft' --exclude='.partial' --exclude='.tmp-*'
    --include='/[0-9]*-[0-9]*/' --include='/[0-9]*-[0-9]*/db-*.dump.age' --include='/[0-9]*-[0-9]*/config-*.tar.age'
    --include='/[0-9]*-[0-9]*/files-*.tar.age' --include='/[0-9]*-[0-9]*/SHA256SUMS' --include='/status' --include='/LATEST' --exclude='*')
  echo "==> Abholen von $SERVER (nur lesend, ohne --delete, zuerst in $STAGING)"
  # Größenprüfung vorab: wie viel würde übertragen?
  STATS="$(timeout "$RSYNC_TIMEOUT" rsync "${RSYNC_OPTS[@]}" --dry-run --stats -e "$SSH_CMD" "lxbackup@$SERVER:/" "$STAGING/" 2>&1)" || { echo "$STATS" >&2; alarm "rsync (Vorabprüfung) fehlgeschlagen oder Zeitlimit ($RSYNC_TIMEOUT) überschritten"; }
  BYTES="$(sed -n 's/^Total transferred file size: \([0-9,.]*\) bytes.*/\1/p' <<<"$STATS" | tr -d ',.')"
  [[ "$BYTES" =~ ^[0-9]+$ ]] || alarm "Größe der Übertragung nicht ermittelbar (rsync --stats)"
  echo "    zu holen: $((BYTES / 1048576)) MB"
  [ "$BYTES" -le "$((MAX_PULL_MB * 1048576))" ] || alarm "der Server bietet $((BYTES / 1048576)) MB an (Grenze $MAX_PULL_MB MB): nichts geholt, Ursache klären"
  if [ "$DRY" = 1 ]; then
    timeout "$RSYNC_TIMEOUT" rsync "${RSYNC_OPTS[@]}" --dry-run -v -e "$SSH_CMD" "lxbackup@$SERVER:/" "$STAGING/" || alarm "rsync fehlgeschlagen"
    rm -rf "$STAGING" "$EXCL"
  else
    timeout "$RSYNC_TIMEOUT" rsync "${RSYNC_OPTS[@]}" -e "$SSH_CMD" "lxbackup@$SERVER:/" "$STAGING/" || alarm "rsync vom Server fehlgeschlagen oder Zeitlimit ($RSYNC_TIMEOUT) überschritten"
    # Neueste lokal je gesehene Ordner: neue müssen strikt neuer sein (sonst Fälschung/Rotation-Vergiftung)
    NEUESTE_BEKANNT="$( { for d in "$ARCHIV"/[0-9]*-[0-9]*; do if [ -d "$d" ]; then basename "$d"; fi; done; cat "$GESEHEN"; } | { grep -E "$NAME_RE" || true; } | sort | tail -1)"
    for d in "$STAGING"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"; n="$(basename "$d")"
      [[ "$n" =~ $NAME_RE ]] || alarm "unzulässiger Ordnername im Staging: $n"
      if [ "$(epoch_von_namen "$n")" -gt $((JETZT + 3600)) ]; then
        alarm "Ordner mit Datum in der Zukunft: $n (Manipulation oder falsche Uhr; nichts übernommen, nichts rotiert, Ordner prüfen)"
      fi
      if [ -e "$ARCHIV/$n" ] || grep -qx "$n" "$GESEHEN"; then alarm "bereits bekannter Ordner im Staging: $n (nicht übernommen)"; fi
      if [ -n "$NEUESTE_BEKANNT" ] && ! [[ "$n" > "$NEUESTE_BEKANNT" ]]; then
        alarm "Ordner $n ist nicht neuer als der neueste bekannte ($NEUESTE_BEKANNT): Fälschung oder Zeitfehler am Server (nicht übernommen)"
      fi
    done
    for d in "$STAGING"/*/; do   # aufsteigend nach Namen
      [ -d "$d" ] || continue
      d="${d%/}"; n="$(basename "$d")"
      pruefen_ordner "$d"
      hash_von "$d" > "$d/.geprueft"
      [ ! -e "$ARCHIV/$n" ] || alarm "$ARCHIV/$n existiert schon"
      mv -T "$d" "$ARCHIV/$n"
      echo "$n" >> "$GESEHEN"
      echo "    neu und ok: $n"
    done
    if [ -f "$STAGING/status" ]; then mv -f "$STAGING/status" "$ARCHIV/status"; fi
    if [ -f "$STAGING/LATEST" ]; then mv -f "$STAGING/LATEST" "$ARCHIV/LATEST"; fi
    rm -rf "$STAGING" "$EXCL"
  fi
fi

echo "==> Prüfen"
NEUESTE=""
ANZAHL=0
for d in "$ARCHIV"/[0-9]*-[0-9]*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  [[ "$n" =~ $NAME_RE ]] || continue
  ANZAHL=$((ANZAHL + 1))
  if [ "$(epoch_von_namen "$n")" -gt $((JETZT + 3600)) ]; then
    alarm "Ordner mit Datum in der Zukunft: $n (Manipulation oder falsche Uhr; nichts wird rotiert, Ordner prüfen)"
  fi
  if [ -s "$d/.geprueft" ]; then
    # die Marke enthält den Hash der SHA256SUMS zum Zeitpunkt der Prüfung
    [ "$(cat "$d/.geprueft")" = "$(hash_von "$d")" ] || alarm "$n: SHA256SUMS hat sich seit der Prüfung geändert (Manipulation?)"
    NEUESTE="$n"; continue
  fi
  if [ "$DRY" = 1 ]; then continue; fi
  # ältere Ordner ohne Marke (frühere Skriptfassung) einmal prüfen und markieren
  pruefen_ordner "$d"
  hash_von "$d" > "$d/.geprueft"
  grep -qx "$n" "$GESEHEN" || echo "$n" >> "$GESEHEN"
  NEUESTE="$n"
  echo "    nachgeprüft und ok: $n"
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
# leere Felder: ${A[@]+"${A[@]}"} hält auch bash < 4.4 unter set -u ruhig
mapfile -t LOESCHEN < <(printf '%s\n' ${ALLE[@]+"${ALLE[@]}"} | zu_loeschen "$(date -u +%Y%m%d)")
# Sicherheitsnetz: nach dem Löschen müssen mindestens MIN_VALID geprüfte, plausibel große Ordner übrig sein
GUT=0
for n in ${ALLE[@]+"${ALLE[@]}"}; do
  if printf '%s\n' ${LOESCHEN[@]+"${LOESCHEN[@]}"} | grep -qx "$n"; then continue; fi
  if [ -f "$ARCHIV/$n/.geprueft" ] && [ "$(find "$ARCHIV/$n" -name 'db-*.dump.age' -size +"$((MIN_DB_BYTES - 1))"c | wc -l)" -ge 1 ]; then GUT=$((GUT + 1)); fi
done
if [ "${#LOESCHEN[@]}" -gt 0 ] && [ "$GUT" -lt "$MIN_VALID" ]; then
  alarm "Rotation abgebrochen: nach dem Löschen blieben nur $GUT geprüfte, plausibel große Ordner (Minimum $MIN_VALID). Archiv ansehen"
fi
if [ "${#LOESCHEN[@]}" -eq 0 ]; then echo "    nichts zu löschen."; fi
for n in ${LOESCHEN[@]+"${LOESCHEN[@]}"}; do
  [[ "$n" =~ $NAME_RE ]] || continue
  if [ "$DRY" = 1 ]; then echo "    [dry-run] würde löschen: $n"; else rm -rf -- "${ARCHIV:?}/$n"; echo "    gelöscht: $n"; fi
done
echo "==> Fertig."
