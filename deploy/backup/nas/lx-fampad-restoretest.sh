#!/usr/bin/env bash
# Automatischer Wiederherstellungstest auf dem NAS (oder einem anderen Rechner mit Docker, der die Sicherungen ABHOLT; nie auf dem Server):
# nimmt die zuletzt vom Pull-Skript geprüfte Sicherung aus dem Archiv, entschlüsselt sie mit dem PRIVATEN age-Schlüssel, spielt die
# Datenbank in eine Wegwerf-PostgreSQL-17 in einem Docker-Container ein (ohne Netz, Daten nur im Arbeitsspeicher des Containers) und
# schreibt das Ergebnis als kleine Statusdatei $DEST/restoretest-status (nur ok/fehler, Zeitpunkt, Größen, Zähler, nie Inhalte).
# Die eigentliche Prüfung macht wiederherstellung-test.sh (liegt im selben Ordner oder eine Ebene höher); sie läuft im Container.
# Beschreibung und Einrichtung (Synology, Schritt für Schritt): docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 10; Hintergrund: docs/BACKUP.md.
#
# Der private Schlüssel: nur als Datei mit Rechten 0600/0400 (Besitzer = der ausführende Benutzer), Pfad per --identity oder LXR_KEY. Er liegt NIE im
# Repository, nie neben den Sicherungen im Archiv und nie auf dem Server. Wer auf dem NAS root ist, kann ihn lesen: er entschlüsselt dann alle
# Sicherungen auf dem NAS. Deshalb einen eigenen Test-Schlüssel verwenden (docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 10), nicht den Hauptschlüssel.
#
# Aufruf:  bash lx-fampad-restoretest.sh --identity /pfad/test.key [--dry-run] [--rebuild] [--verbose]
#   --ohne-config  das Konfigurationsarchiv (enthält AUTH_SECRET_KEY) nicht entschlüsseln: für einen Schlüssel, der nur die Datenbank lesen darf (LXR_OHNE_CONFIG=1)
#   --dry-run   prüft Voraussetzungen und wählt die Sicherung, startet aber nichts und schreibt keine Statusdatei
#   --rebuild   Docker-Image neu bauen (sonst nur, wenn es fehlt oder älter als LXR_REBUILD_DAYS Tage ist; einmalig Internet nötig)
#   --verbose   die komplette Ausgabe des Tests zeigen (kann Fehlertexte von PostgreSQL mit Datenfragmenten enthalten: nur von Hand, nie im Aufgabenplaner)
# Exit: 0 = ok, 1 = Test fehlgeschlagen (Statusdatei sagt, wo), 2 = Aufruf falsch, 75 = ein anderer Lauf ist aktiv.
# Einstellungen per Umgebungsvariable (LXR_…, Ordner wie beim Pull-Skript LXB_DEST).
set -Eeuo pipefail
umask 077

DEST="${LXR_DEST:-${LXB_DEST:-/volume1/backup/lx-fampad}}"   # derselbe Zielordner wie beim Pull-Skript
KEY="${LXR_KEY:-}"
TESTSKRIPT="${LXR_TESTSKRIPT:-}"                    # Standard: wiederherstellung-test.sh neben diesem Skript oder eine Ebene höher
IMAGE="${LXR_IMAGE:-lx-fampad-restoretest:pg17}"
REBUILD_DAYS="${LXR_REBUILD_DAYS:-35}"
MAX_AGE_HOURS="${LXR_MAX_AGE_HOURS:-72}"            # ältere neueste Sicherung = Ergebnis fehler (das Pull-Skript alarmiert schon ab 36 h)
TIMEOUT="${LXR_TIMEOUT:-30m}"                       # Zeitlimit für den Container
MEMORY="${LXR_MEMORY:-1g}"
TMPFS_SIZE="${LXR_TMPFS_SIZE:-512m}"                # Größe der Wegwerf-Datenbank im Arbeitsspeicher (reicht für eine Familien-Datenbank)
NOTIFY_CMD="${LXR_NOTIFY_CMD:-${LXB_NOTIFY_CMD:-}}" # optional: Befehl, der bei Fehlern mit einer Kurzmeldung (ohne Inhalte) aufgerufen wird

NO_CONFIG="${LXR_OHNE_CONFIG:-0}"
DRY=0; REBUILD=0; VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) [ $# -ge 2 ] || { echo "--identity braucht einen Wert" >&2; exit 2; }; KEY="$2"; shift ;;
    --ohne-config) NO_CONFIG=1 ;;
    --dry-run) DRY=1 ;;
    --rebuild) REBUILD=1 ;;
    --verbose) VERBOSE=1 ;;
    *) echo "Aufruf: $0 --identity <schlüsseldatei> [--ohne-config] [--dry-run] [--rebuild] [--verbose]" >&2; exit 2 ;;
  esac
  shift
done

STATUS="$DEST/restoretest-status"
ARCHIV="$DEST/archiv"
NAME_RE='^[0-9]{8}-[0-9]{6}$'
START="$(date -u +%s)"
CNAME="lx-fampad-restoretest-$$"

# Ergebnis, das beim Beenden in die Statusdatei geschrieben wird (Standard: fehler, bis alles gelaufen ist)
RESULT=fehler; STEP=vorbereitung; DETAIL=abgebrochen
CONFIG_CHECK=nein
RUN_NAME=""; BACKUP_AGE_H=""; DB_BYTES=""; CFG_BYTES=""; TABLES=""; MIGRATIONS=""
WRITE_STATUS=0

statuswert() { [ -f "$STATUS" ] && sed -n "s/^$1=\([0-9A-Za-z:._-]*\)\$/\1/p" "$STATUS" | head -1 || true; }
bei_ende() {
  local rc=$?
  trap - EXIT
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  if [ "$WRITE_STATUS" = 1 ]; then
    local jetzt dauer lastok_epoch lastok_utc tmp
    jetzt="$(date -u +%s)"; dauer=$((jetzt - START))
    lastok_epoch="$(statuswert last_success_epoch)"; lastok_utc="$(statuswert last_success_utc)"
    if [ "$RESULT" = ok ]; then lastok_epoch="$jetzt"; lastok_utc="$(date -u -d "@$jetzt" +%Y-%m-%dT%H:%M:%SZ)"; fi
    tmp="$STATUS.tmp.$$"
    {
      echo "last_result=$RESULT"
      echo "last_run_epoch=$jetzt"
      echo "last_run_utc=$(date -u -d "@$jetzt" +%Y-%m-%dT%H:%M:%SZ)"
      [ -z "$lastok_epoch" ] || echo "last_success_epoch=$lastok_epoch"
      [ -z "$lastok_utc" ] || echo "last_success_utc=$lastok_utc"
      echo "step=$STEP"
      echo "detail=$DETAIL"
      echo "run_dir=${RUN_NAME:-keine}"
      [ -z "$BACKUP_AGE_H" ] || echo "backup_age_h=$BACKUP_AGE_H"
      [ -z "$DB_BYTES" ] || echo "db_bytes=$DB_BYTES"
      [ -z "$CFG_BYTES" ] || echo "config_bytes=$CFG_BYTES"
      echo "config_check=$CONFIG_CHECK"
      [ -z "$TABLES" ] || echo "tables=$TABLES"
      [ -z "$MIGRATIONS" ] || echo "migrations=$MIGRATIONS"
      echo "duration_s=$dauer"
    } > "$tmp" && mv -f "$tmp" "$STATUS" || echo "WARNUNG: Statusdatei $STATUS konnte nicht geschrieben werden" >&2
    if [ "$RESULT" != ok ]; then
      echo "ALARM: Wiederherstellungstest fehlgeschlagen (Schritt: $STEP, Grund: $DETAIL)" >&2
      if [ -n "$NOTIFY_CMD" ]; then $NOTIFY_CMD "lx-fampad Wiederherstellungstest: fehlgeschlagen (Schritt $STEP, $DETAIL)" || true; fi
      [ "$rc" -ne 0 ] || rc=1
    fi
  fi
  exit "$rc"
}
trap bei_ende EXIT
fail() { STEP="$1"; DETAIL="$2"; echo "FEHLER: $3" >&2; exit 1; }   # Schritt, Kurzcode (nur [a-z0-9_]), Meldung

# --- Voraussetzungen -------------------------------------------------------------------------------------------------------------
[ "$DRY" = 1 ] || WRITE_STATUS=1
[ "$(date -u -d '2026-01-01 -1 day' +%F 2>/dev/null || true)" = "2025-12-31" ] || fail vorbereitung kein_gnu_date "date -d funktioniert nicht (kein GNU date, BusyBox)"
case "$DEST$KEY$TESTSKRIPT" in
  *[[:space:]\'\"\\:,]*) fail vorbereitung pfad_ungueltig "Pfade und Schlüsseldatei dürfen keine Leerzeichen, Anführungszeichen, Doppelpunkte, Kommas oder Backslashes enthalten" ;;
esac
[[ "$IMAGE" =~ ^[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] || fail vorbereitung image_ungueltig "LXR_IMAGE ist kein gültiger Image-Name"
command -v flock >/dev/null || fail vorbereitung flock_fehlt "flock fehlt (Paket util-linux)"
[ -d "$DEST" ] && [ -w "$DEST" ] || fail vorbereitung ziel_fehlt "Zielordner $DEST existiert nicht oder ist nicht beschreibbar"
exec 9>>"$DEST/.restoretest.lock" || fail vorbereitung sperre "Sperrdatei $DEST/.restoretest.lock nicht beschreibbar"
if ! flock -n 9; then echo "Ein anderer Lauf des Wiederherstellungstests ist aktiv, Abbruch." >&2; WRITE_STATUS=0; exit 75; fi
command -v docker >/dev/null || fail vorbereitung docker_fehlt "docker fehlt (Synology: Container Manager installieren; Aufgabe als root ausführen)"
docker version >/dev/null 2>&1 || fail vorbereitung docker_nicht_erreichbar "docker antwortet nicht (läuft der Container Manager? Aufgabe als root ausführen?)"

[ -n "$KEY" ] || fail vorbereitung kein_schluessel "kein Schlüssel angegeben (--identity oder LXR_KEY)"
[ -f "$KEY" ] && [ ! -L "$KEY" ] || fail vorbereitung schluessel_fehlt "Schlüsseldatei fehlt oder ist ein Link: $KEY"
KMODE="$(stat -c %a "$KEY")"; KOWNER="$(stat -c %u "$KEY")"
{ [ "$KMODE" = 600 ] || [ "$KMODE" = 400 ]; } || fail vorbereitung schluessel_rechte "Schlüsseldatei $KEY hat Rechte $KMODE (nötig: chmod 600)"
[ "$KOWNER" = "$(id -u)" ] || fail vorbereitung schluessel_besitzer "Schlüsseldatei $KEY gehört einem anderen Benutzer (nötig: der ausführende Benutzer)"
grep -q '^AGE-SECRET-KEY-' "$KEY" || fail vorbereitung schluessel_inhalt "$KEY enthält keinen privaten age-Schlüssel"
case "$KEY" in "$DEST"/*) fail vorbereitung schluessel_im_archiv "Der Schlüssel darf nicht im Sicherungsordner $DEST liegen" ;; esac

if [ -z "$TESTSKRIPT" ]; then
  for c in "$(dirname "${BASH_SOURCE[0]}")/wiederherstellung-test.sh" "$(dirname "${BASH_SOURCE[0]}")/../wiederherstellung-test.sh"; do
    if [ -f "$c" ]; then TESTSKRIPT="$(cd "$(dirname "$c")" && pwd)/wiederherstellung-test.sh"; break; fi
  done
fi
[ -f "$TESTSKRIPT" ] || fail vorbereitung testskript_fehlt "wiederherstellung-test.sh nicht gefunden (neben dieses Skript legen oder LXR_TESTSKRIPT setzen)"

# --- Sicherung wählen: die neueste, die das Pull-Skript geprüft und markiert hat -------------------------------------------------
name_ok() { [[ "$1" =~ $NAME_RE ]] && date -u -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s >/dev/null 2>&1; }
epoch_von_namen() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s; }
[ -d "$ARCHIV" ] || fail auswahl kein_archiv "Archiv $ARCHIV fehlt (Pull-Skript noch nie gelaufen?)"
for d in "$ARCHIV"/[0-9]*-[0-9]*; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  n="$(basename "$d")"; name_ok "$n" || continue
  [ -s "$d/.geprueft" ] || continue
  [ "$(cat "$d/.geprueft")" = "$(sha256sum "$d/SHA256SUMS" | cut -d' ' -f1)" ] || fail auswahl marke_stimmt_nicht "$n: SHA256SUMS hat sich seit der Prüfung durch das Pull-Skript geändert"
  RUN_NAME="$n"          # aufsteigend: der letzte ist der neueste
done
[ -n "$RUN_NAME" ] || fail auswahl keine_sicherung "keine geprüfte Sicherung im Archiv $ARCHIV"
RUN_PATH="$ARCHIV/$RUN_NAME"
BACKUP_AGE_H=$(( (START - $(epoch_von_namen "$RUN_NAME")) / 3600 ))
shopt -s nullglob
DBF=("$RUN_PATH"/db-*.dump.age); CFG=("$RUN_PATH"/config-*.tar.age)
[ "${#DBF[@]}" -eq 1 ] || fail auswahl db_datei "in $RUN_NAME wird genau eine db-*.dump.age erwartet"
DB_BYTES="$(stat -c %s "${DBF[0]}")"
if [ "${#CFG[@]}" -eq 1 ]; then CFG_BYTES="$(stat -c %s "${CFG[0]}")"; fi
echo "==> Sicherung: $RUN_NAME (Alter ${BACKUP_AGE_H} h, Datenbank ${DB_BYTES} Bytes)"
[ "$BACKUP_AGE_H" -le "$MAX_AGE_HOURS" ] || fail auswahl sicherung_zu_alt "die neueste geprüfte Sicherung ist ${BACKUP_AGE_H} Stunden alt (erlaubt ${MAX_AGE_HOURS} h): holt das Pull-Skript noch ab?"

# --- Docker-Image (einmalig bauen, danach ohne Netz benutzen) ----------------------------------------------------------------------
bauen() {
  echo "==> Docker-Image $IMAGE wird gebaut (PostgreSQL 17, age; einmalig, Internet nötig)"
  local alt; alt="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE' || fail image image_bauen "Docker-Image konnte nicht gebaut werden (Internet? Speicherplatz?)"
FROM debian:trixie-slim
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends postgresql-17 postgresql-client-17 age util-linux ca-certificates >/dev/null \
 && (pg_dropcluster 17 main --stop >/dev/null 2>&1 || true) \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  if [ -n "$alt" ] && [ "$alt" != "$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)" ]; then docker rmi "$alt" >/dev/null 2>&1 || true; fi
}
if [ "$DRY" = 1 ]; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "    Image $IMAGE vorhanden." || echo "    Image $IMAGE fehlt (wird beim echten Lauf gebaut)."
  echo "==> Trockenlauf beendet: Voraussetzungen ok, nichts gestartet, keine Statusdatei geschrieben."
  exit 0
fi
if [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  bauen
else
  CREATED="$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null || true)"
  CE="$(date -u -d "$CREATED" +%s 2>/dev/null || echo 0)"
  if [ "$CE" -gt 0 ] && [ "$(( (START - CE) / 86400 ))" -ge "$REBUILD_DAYS" ]; then bauen; fi   # Sicherheitsupdates des Basis-Images
fi

# --- Test im Container -------------------------------------------------------------------------------------------------------------
STEP=start; DETAIL=docker
CMD='set -Eeuo pipefail
pg_createcluster 17 main -e UTF8 --locale C.UTF-8 >/dev/null
pg_ctlcluster 17 main start
for i in $(seq 1 30); do pg_isready -q && break; sleep 1; done
pg_isready -q
exec bash /skripte/wiederherstellung-test.sh --identity /schluessel/age.key --run-dir "/backup/$1" --as-postgres "${@:2}"'
EXTRA=(); CONFIG_CHECK=ja
if [ "$NO_CONFIG" = 1 ]; then EXTRA=(--skip-config); CONFIG_CHECK=nein; fi
echo "==> Test läuft (ohne Netz, Datenbank nur im Arbeitsspeicher des Containers)"
RC=0
OUT="$(timeout "$TIMEOUT" docker run --rm --name "$CNAME" --network none --memory "$MEMORY" --pids-limit 512 \
  --tmpfs "/var/lib/postgresql:rw,mode=0755,size=$TMPFS_SIZE" \
  -v "$RUN_PATH:/backup/$RUN_NAME:ro" -v "$TESTSKRIPT:/skripte/wiederherstellung-test.sh:ro" -v "$KEY:/schluessel/age.key:ro" \
  "$IMAGE" bash -c "$CMD" bash "$RUN_NAME" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1)" || RC=$?
docker rm -f "$CNAME" >/dev/null 2>&1 || true

# Nur Zeilen, die das Prüfskript selbst als Fortschritt oder Kurzergebnis schreibt (keine Fehlertexte von PostgreSQL, die Datenfragmente enthalten könnten)
if [ "$VERBOSE" = 1 ]; then printf '%s\n' "$OUT"; else printf '%s\n' "$OUT" | grep -E '^(==> |    Tabellen im Schema|    angewendete Migrationen|    etc/lx-fampad/env ist|FEHLER: )' || true; fi
LAST="$(printf '%s\n' "$OUT" | sed -n 's|^==> \([1-4]\)/4 .*|\1|p' | tail -1)"
[ -z "$LAST" ] || STEP="schritt$LAST"
TABLES="$(printf '%s\n' "$OUT" | sed -n 's/^    Tabellen im Schema public: \([0-9][0-9]*\)$/\1/p' | tail -1)"
MIGRATIONS="$(printf '%s\n' "$OUT" | sed -n 's/^    angewendete Migrationen (drizzle.__drizzle_migrations): \([0-9][0-9]*\)$/\1/p' | tail -1)"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^==> Wiederherstellungstest bestanden'; then
  RESULT=ok; STEP=fertig; DETAIL=ok
  echo "==> Wiederherstellungstest bestanden: $RUN_NAME (Tabellen: ${TABLES:-?}, Migrationen: ${MIGRATIONS:-?})"
  exit 0
fi
case "$RC" in
  124) DETAIL=zeitlimit ;;
  125|126|127) DETAIL=docker_start ;;
  *) case "$LAST" in 1) DETAIL=pruefsummen ;; 2) DETAIL=wegwerf_datenbank ;; 3) DETAIL=entschluesseln_einspielen ;; 4) DETAIL=konfigarchiv ;; *) DETAIL=container ;; esac ;;
esac
exit 1
