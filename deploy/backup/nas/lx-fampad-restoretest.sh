#!/usr/bin/env bash
# Automatischer Wiederherstellungstest auf dem NAS (oder einem anderen Rechner mit Docker, der die Sicherungen ABHOLT; nie auf dem Server):
# nimmt die zuletzt vom Pull-Skript geprüfte Sicherung aus dem Archiv, entschlüsselt sie mit dem PRIVATEN age-Schlüssel, spielt die
# Datenbank in eine Wegwerf-PostgreSQL-17 in einem gehärteten Docker-Container ein (ohne Netz, Dateisystem schreibgeschützt, Datenbank nur im
# tmpfs, keine Container-Logs auf der Platte) und schreibt das Ergebnis als kleine Statusdatei $DEST/restoretest-status (nur ok/fehler,
# Zeitpunkt, Größen, Zähler, nie Inhalte). Die eigentliche Prüfung macht wiederherstellung-test.sh (neben diesem Skript oder eine Ebene höher).
# Beschreibung und Einrichtung (Synology, Schritt für Schritt): docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 10; Hintergrund: docs/BACKUP.md.
#
# Der private Schlüssel: nur als Datei mit Rechten 0600/0400 (Besitzer = der ausführende Benutzer), Pfad per --identity oder LXR_KEY, am besten
# mit --keygen direkt auf dem NAS erzeugt (er verlässt das NAS nie). Er liegt NIE im Repository, nie im Archivordner und nie auf dem Server. Wer auf
# dem NAS root ist, kann ihn lesen: er entschlüsselt dann die Sicherungen auf dem NAS. Deshalb einen eigenen Test-Schlüssel verwenden
# (docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 10), nicht den Hauptschlüssel.
#
# Aufruf:  bash lx-fampad-restoretest.sh --identity /abs/pfad/test.key [--ohne-config] [--dry-run] [--rebuild] [--verbose]
#          bash lx-fampad-restoretest.sh --identity /abs/pfad/test.key --keygen     (einmalig: Schlüssel auf dem NAS erzeugen, öffentliche Zeile ausgeben)
#   --keygen    erzeugt den Test-Schlüssel (nur wenn die Datei noch nicht existiert) und gibt NUR den öffentlichen Schlüssel aus
#   --ohne-config  das Konfigurationsarchiv (enthält AUTH_SECRET_KEY) nicht entschlüsseln: für einen Schlüssel, der nur Datenbank (und Dateiablage) lesen darf (LXR_OHNE_CONFIG=1)
#   --dry-run   prüft Voraussetzungen und wählt die Sicherung, startet aber nichts und schreibt keine Statusdatei
#   --rebuild   Docker-Image neu bauen (sonst nur, wenn es fehlt oder älter als LXR_REBUILD_DAYS Tage ist; Internet nötig)
#   --verbose   die komplette Ausgabe des Tests zeigen (kann Fehlertexte von PostgreSQL mit Datenfragmenten enthalten: nur von Hand, nie im Aufgabenplaner)
# Alle Pfade müssen absolut sein. Exit: 0 = ok, 1 = Test fehlgeschlagen (Statusdatei sagt, wo), 2 = Aufruf falsch, 75 = ein anderer Lauf ist aktiv.
# Einstellungen per Umgebungsvariable (LXR_…, Ordner wie beim Pull-Skript LXB_DEST).
set -Eeuo pipefail
umask 077

# Basis-Image fest an einen Digest gebunden (Index-Digest von debian:trixie-20260918-slim, mehr als 14 Tage alt; Aktualisieren: neuen Digest prüfen und hier eintragen)
BASE="debian:trixie-20260918-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a"

DEST="${LXR_DEST:-${LXB_DEST:-/volume1/backup/lx-fampad}}"   # derselbe Zielordner wie beim Pull-Skript
KEY="${LXR_KEY:-}"
TESTSKRIPT="${LXR_TESTSKRIPT:-}"                    # Standard: wiederherstellung-test.sh neben diesem Skript oder eine Ebene höher
IMAGE="${LXR_IMAGE:-lx-fampad-restoretest:pg17}"
REBUILD_DAYS="${LXR_REBUILD_DAYS:-35}"
MAX_AGE_HOURS="${LXR_MAX_AGE_HOURS:-72}"            # ältere neueste Sicherung = Ergebnis fehler (das Pull-Skript alarmiert schon ab 36 h)
TIMEOUT="${LXR_TIMEOUT:-30m}"                       # Zeitlimit für den Container (Zahl + s/m/h/d)
MEMORY="${LXR_MEMORY:-1g}"
TMPFS_SIZE="${LXR_TMPFS_SIZE:-512m}"                # Größe der Wegwerf-Datenbank im Arbeitsspeicher (reicht für eine Familien-Datenbank)
MIN_TABLES="${LXR_MIN_TABLES:-10}"                  # Plausibilität: weniger Tabellen/Migrationen/Zeilen = der Test gilt als fehlgeschlagen (an die eigene Datenbank anpassen)
MIN_MIGRATIONS="${LXR_MIN_MIGRATIONS:-5}"
MIN_ROWS="${LXR_MIN_ROWS:-10}"
NOTIFY_CMD="${LXR_NOTIFY_CMD:-${LXB_NOTIFY_CMD:-}}" # optional: Befehl, der bei Fehlern mit einer Kurzmeldung (ohne Inhalte) aufgerufen wird
NO_CONFIG="${LXR_OHNE_CONFIG:-0}"

DRY=0; REBUILD=0; VERBOSE=0; KEYGEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) [ $# -ge 2 ] || { echo "--identity braucht einen Wert" >&2; exit 2; }; KEY="$2"; shift ;;
    --keygen) KEYGEN=1 ;;
    --ohne-config) NO_CONFIG=1 ;;
    --dry-run) DRY=1 ;;
    --rebuild) REBUILD=1 ;;
    --verbose) VERBOSE=1 ;;
    *) echo "Aufruf: $0 --identity <abs. schlüsseldatei> [--keygen] [--ohne-config] [--dry-run] [--rebuild] [--verbose]" >&2; exit 2 ;;
  esac
  shift
done

STATUS="$DEST/restoretest-status"
ARCHIV="$DEST/archiv"
NAME_RE='^[0-9]{8}-[0-9]{6}$'
START="$(date -u +%s)"
CNAME="lx-fampad-restoretest-$$"

# Ergebnis, das beim Beenden in die Statusdatei geschrieben wird (Standard: fehler, bis alles gelaufen ist)
RESULT=fehler; STEP=vorbereitung; DETAIL=abgebrochen; CONFIG_CHECK=nein
RUN_NAME=""; BACKUP_AGE_H=""; DB_BYTES=""; CFG_BYTES=""; TABLES=""; MIGRATIONS=""; ROWS=""
WRITE_STATUS=0

statuswert() { if [ -f "$STATUS" ] && [ ! -L "$STATUS" ]; then sed -n "s/^$1=\([0-9A-Za-z:._-]*\)\$/\1/p" "$STATUS" | head -1; fi; }
bei_ende() {
  local rc=$?
  trap - EXIT
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  if [ "$WRITE_STATUS" = 1 ]; then
    local jetzt dauer lastok_epoch lastok_utc tmp
    jetzt="$(date -u +%s)"; dauer=$((jetzt - START))
    lastok_epoch="$(statuswert last_success_epoch || true)"; lastok_utc="$(statuswert last_success_utc || true)"
    if [ "$RESULT" = ok ]; then lastok_epoch="$jetzt"; lastok_utc="$(date -u -d "@$jetzt" +%Y-%m-%dT%H:%M:%SZ)"; fi
    if tmp="$(mktemp "$DEST/.restoretest-status.XXXXXX" 2>/dev/null)"; then   # neue Datei (folgt keinem Link), danach atomar umbenennen
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
        [ -z "$ROWS" ] || echo "rows_total=$ROWS"
        echo "duration_s=$dauer"
      } > "$tmp" && mv -f "$tmp" "$STATUS" || { rm -f "$tmp"; echo "WARNUNG: Statusdatei $STATUS konnte nicht geschrieben werden" >&2; }
    else
      echo "WARNUNG: Statusdatei in $DEST konnte nicht angelegt werden" >&2
    fi
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

# Ordner/Datei nur von uns beschreibbar: Besitzer = ausführender Benutzer, kein Gruppen-/Schreibrecht für andere
nur_eigen() {   # $1 = Pfad
  local m; m="$(stat -c %a "$1")"
  [ "$(stat -c %u "$1")" = "$(id -u)" ] && [ $(( 8#$m & 8#022 )) -eq 0 ]
}

# --- Voraussetzungen -------------------------------------------------------------------------------------------------------------
[ "$DRY" = 1 ] || [ "$KEYGEN" = 1 ] || WRITE_STATUS=1
[ "$(date -u -d '2026-01-01 -1 day' +%F 2>/dev/null || true)" = "2025-12-31" ] || fail vorbereitung kein_gnu_date "date -d funktioniert nicht (kein GNU date, BusyBox)"
for p in "$DEST" "$KEY" "$TESTSKRIPT"; do
  [ -z "$p" ] || [[ "$p" = /* ]] || fail vorbereitung pfad_nicht_absolut "Pfade müssen absolut sein (mit / beginnen): $p"
done
case "$DEST$KEY$TESTSKRIPT" in
  *[[:space:]\'\"\\:,]*) fail vorbereitung pfad_ungueltig "Pfade und Schlüsseldatei dürfen keine Leerzeichen, Anführungszeichen, Doppelpunkte, Kommas oder Backslashes enthalten" ;;
esac
[[ "$IMAGE" =~ ^[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] || fail vorbereitung image_ungueltig "LXR_IMAGE ist kein gültiger Image-Name"
[[ "$MEMORY" =~ ^[0-9]+[kmg]?$ ]] && [[ "$TMPFS_SIZE" =~ ^[0-9]+[kmg]?$ ]] || fail vorbereitung wert_ungueltig "LXR_MEMORY und LXR_TMPFS_SIZE müssen eine Zahl mit optionalem k/m/g sein"
[[ "$TIMEOUT" =~ ^[0-9]+[smhd]?$ ]] || fail vorbereitung wert_ungueltig "LXR_TIMEOUT muss eine Zahl mit optionalem s/m/h/d sein"
for v in "$REBUILD_DAYS" "$MAX_AGE_HOURS" "$MIN_TABLES" "$MIN_MIGRATIONS" "$MIN_ROWS"; do
  [[ "$v" =~ ^[0-9]+$ ]] || fail vorbereitung wert_ungueltig "LXR_REBUILD_DAYS, LXR_MAX_AGE_HOURS und LXR_MIN_* müssen Zahlen sein"
done
command -v flock >/dev/null || fail vorbereitung flock_fehlt "flock fehlt (Paket util-linux)"
[ -d "$DEST" ] && [ ! -L "$DEST" ] && [ -w "$DEST" ] || fail vorbereitung ziel_fehlt "Zielordner $DEST existiert nicht, ist ein Link oder nicht beschreibbar"
DEST_REAL="$(readlink -f "$DEST")"
# Sperre auf dem Ordner selbst (keine Sperrdatei: kein Link, dem man folgen könnte)
exec 9< "$DEST" || fail vorbereitung sperre "Zielordner $DEST nicht lesbar"
if ! flock -n 9; then echo "Ein anderer Lauf des Wiederherstellungstests ist aktiv, Abbruch." >&2; WRITE_STATUS=0; exit 75; fi
command -v docker >/dev/null || fail vorbereitung docker_fehlt "docker fehlt (Synology: Container Manager installieren; Aufgabe als root ausführen)"
docker version >/dev/null 2>&1 || fail vorbereitung docker_nicht_erreichbar "docker antwortet nicht (läuft der Container Manager? Aufgabe als root ausführen?)"

# --- Docker-Image (einmalig bauen, danach ohne Netz und ohne Pull benutzen) --------------------------------------------------------
DOCKER_SICHER=(--network none --pull never --log-driver none --read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 512)
bauen() {
  echo "==> Docker-Image $IMAGE wird gebaut (Basis $BASE, PostgreSQL 17, age; Internet nötig)"
  local alt; alt="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  docker pull -q "$BASE" >/dev/null || fail image image_bauen "Basis-Image $BASE konnte nicht geladen werden (Internet?)"
  docker build -q -t "$IMAGE" --build-arg "BASE=$BASE" - >/dev/null 2>&1 <<'DOCKERFILE' || fail image image_bauen "Docker-Image konnte nicht gebaut werden (Internet? Speicherplatz?)"
ARG BASE
FROM ${BASE}
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends postgresql-17 postgresql-client-17 age util-linux ca-certificates >/dev/null \
 && (pg_dropcluster 17 main --stop >/dev/null 2>&1 || true) \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  if [ -n "$alt" ] && [ "$alt" != "$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)" ]; then docker rmi "$alt" >/dev/null 2>&1 || true; fi
}
bild_bereit() {
  if [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then bauen; return; fi
  local created ce
  created="$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null || true)"
  ce="$(date -u -d "$created" +%s 2>/dev/null || echo 0)"
  if [ "$ce" -gt 0 ] && [ "$(( (START - ce) / 86400 ))" -ge "$REBUILD_DAYS" ]; then bauen; fi   # Sicherheitsupdates der Pakete
}

[ -n "$KEY" ] || fail vorbereitung kein_schluessel "kein Schlüssel angegeben (--identity oder LXR_KEY)"
KEYDIR="$(dirname "$KEY")"
[ -d "$KEYDIR" ] && [ ! -L "$KEYDIR" ] && nur_eigen "$KEYDIR" || fail vorbereitung schluessel_ordner "Ordner der Schlüsseldatei fehlt, ist ein Link oder gehört nicht dem ausführenden Benutzer / ist für andere beschreibbar: $KEYDIR"

# --- Schlüssel auf dem NAS erzeugen ------------------------------------------------------------------------------------------------
if [ "$KEYGEN" = 1 ]; then
  [ ! -e "$KEY" ] && [ ! -L "$KEY" ] || fail vorbereitung schluessel_existiert "$KEY existiert schon (nicht überschrieben)"
  bild_bereit
  PUB="$(docker run --rm "${DOCKER_SICHER[@]}" --user "$(id -u):$(id -g)" -v "$KEYDIR:/out" "$IMAGE" \
         sh -c 'umask 077; age-keygen -o "/out/$1" 2>&1 | sed -n "s/^Public key: //p"' sh "$(basename "$KEY")")" || fail vorbereitung keygen "Schlüssel konnte nicht erzeugt werden"
  chmod 600 "$KEY"
  [[ "$PUB" =~ ^age1[0-9a-z]{58}$ ]] || { rm -f "$KEY"; fail vorbereitung keygen "unerwartete Ausgabe von age-keygen (Schlüssel verworfen)"; }
  echo "==> Test-Schlüssel erzeugt: $KEY (Rechte 600; der private Teil verlässt das NAS nie)"
  echo "==> Öffentlicher Schlüssel (auf dem Server als --age-recipient hinzufügen):"
  echo "$PUB"
  exit 0
fi

[ -f "$KEY" ] && [ ! -L "$KEY" ] || fail vorbereitung schluessel_fehlt "Schlüsseldatei fehlt oder ist ein Link: $KEY"
KMODE="$(stat -c %a "$KEY")"; KOWNER="$(stat -c %u "$KEY")"
{ [ "$KMODE" = 600 ] || [ "$KMODE" = 400 ]; } || fail vorbereitung schluessel_rechte "Schlüsseldatei $KEY hat Rechte $KMODE (nötig: chmod 600)"
[ "$KOWNER" = "$(id -u)" ] || fail vorbereitung schluessel_besitzer "Schlüsseldatei $KEY gehört einem anderen Benutzer (nötig: der ausführende Benutzer)"
grep -q '^AGE-SECRET-KEY-' "$KEY" || fail vorbereitung schluessel_inhalt "$KEY enthält keinen privaten age-Schlüssel"
KEY_REAL="$(readlink -f "$KEY")"
case "$KEY_REAL" in "$DEST_REAL"|"$DEST_REAL"/*) fail vorbereitung schluessel_im_archiv "Der Schlüssel darf nicht im Sicherungsordner $DEST liegen" ;; esac

if [ -z "$TESTSKRIPT" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$SELF_DIR/wiederherstellung-test.sh" "$SELF_DIR/../wiederherstellung-test.sh"; do
    if [ -f "$c" ]; then TESTSKRIPT="$(readlink -f "$c")"; break; fi
  done
fi
[ -f "$TESTSKRIPT" ] && [ ! -L "$TESTSKRIPT" ] || fail vorbereitung testskript_fehlt "wiederherstellung-test.sh nicht gefunden oder ein Link (neben dieses Skript legen oder LXR_TESTSKRIPT setzen)"
nur_eigen "$TESTSKRIPT" || fail vorbereitung testskript_rechte "wiederherstellung-test.sh gehört einem anderen Benutzer oder ist für andere beschreibbar (nötig: Besitzer = ausführender Benutzer, chmod 700)"
nur_eigen "$(dirname "$TESTSKRIPT")" || fail vorbereitung testskript_rechte "der Ordner von wiederherstellung-test.sh gehört einem anderen Benutzer oder ist für andere beschreibbar"

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

if [ "$DRY" = 1 ]; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "    Image $IMAGE vorhanden." || echo "    Image $IMAGE fehlt (wird beim echten Lauf gebaut)."
  echo "==> Trockenlauf beendet: Voraussetzungen ok, nichts gestartet, keine Statusdatei geschrieben."
  exit 0
fi
bild_bereit

# --- Test im Container -------------------------------------------------------------------------------------------------------------
STEP=start; DETAIL=docker
# Schreibbar sind nur kleine tmpfs-Flächen (alles im Arbeitsspeicher des Containers, nach dem Lauf weg); die Kapazitäten reichen für Cluster-Anlage und su/runuser
CMD='set -Eeuo pipefail
pg_createcluster 17 main -e UTF8 --locale C.UTF-8 >/dev/null
pg_ctlcluster 17 main start
for i in $(seq 1 30); do pg_isready -q && break; sleep 1; done
pg_isready -q
exec bash /skripte/wiederherstellung-test.sh --identity /schluessel/age.key --run-dir "/backup/$1" --as-postgres "${@:2}"'
EXTRA=(); CONFIG_CHECK=ja
if [ "$NO_CONFIG" = 1 ]; then EXTRA=(--skip-config); CONFIG_CHECK=nein; fi
echo "==> Test läuft (ohne Netz, Datenbank nur im tmpfs des Containers, Dateisystem schreibgeschützt)"
RC=0
OUT="$(timeout "$TIMEOUT" docker run --rm --name "$CNAME" "${DOCKER_SICHER[@]}" \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETUID --cap-add SETGID \
  --memory "$MEMORY" --memory-swap "$MEMORY" \
  --tmpfs "/var/lib/postgresql:rw,mode=0755,size=$TMPFS_SIZE" --tmpfs /etc/postgresql:rw,mode=0755,size=8m \
  --tmpfs /run/postgresql:rw,mode=1777,size=8m --tmpfs /var/log/postgresql:rw,mode=1777,size=64m --tmpfs /tmp:rw,mode=1777,size=64m \
  -v "$RUN_PATH:/backup/$RUN_NAME:ro" -v "$TESTSKRIPT:/skripte/wiederherstellung-test.sh:ro" -v "$KEY:/schluessel/age.key:ro" \
  "$IMAGE" bash -c "$CMD" bash "$RUN_NAME" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1)" || RC=$?
docker rm -f "$CNAME" >/dev/null 2>&1 || true

# Nur Zeilen, die das Prüfskript selbst als Fortschritt oder Kurzergebnis schreibt (keine Fehlertexte von PostgreSQL, die Datenfragmente enthalten könnten)
if [ "$VERBOSE" = 1 ]; then printf '%s\n' "$OUT"; else printf '%s\n' "$OUT" | grep -E '^(==> |    Tabellen im Schema|    angewendete Migrationen|    etc/lx-fampad/env ist|FEHLER: )' || true; fi
LAST="$(printf '%s\n' "$OUT" | sed -n 's|^==> \([1-4]\)/4 .*|\1|p' | tail -1)"
[ -z "$LAST" ] || STEP="schritt$LAST"
TABLES="$(printf '%s\n' "$OUT" | sed -n 's/^    Tabellen im Schema public: \([0-9][0-9]*\)$/\1/p' | tail -1)"
MIGRATIONS="$(printf '%s\n' "$OUT" | sed -n 's/^    angewendete Migrationen (drizzle.__drizzle_migrations): \([0-9][0-9]*\)$/\1/p' | tail -1)"
ROWS="$(printf '%s\n' "$OUT" | sed -n 's/^        public\.[^ ]* | \([0-9][0-9]*\)$/\1/p' | awk '{ s += $1 } END { if (NR > 0) print s }')"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^==> Wiederherstellungstest bestanden'; then
  if [ "${TABLES:-0}" -lt "$MIN_TABLES" ] || [ "${MIGRATIONS:-0}" -lt "$MIN_MIGRATIONS" ] || [ "${ROWS:-0}" -lt "$MIN_ROWS" ]; then
    STEP=plausibilitaet; DETAIL=zu_klein
    echo "FEHLER: die wiederhergestellte Datenbank ist unplausibel klein (Tabellen ${TABLES:-0}/$MIN_TABLES, Migrationen ${MIGRATIONS:-0}/$MIN_MIGRATIONS, Zeilen ${ROWS:-0}/$MIN_ROWS; Grenzen: LXR_MIN_TABLES/LXR_MIN_MIGRATIONS/LXR_MIN_ROWS)" >&2
    exit 1
  fi
  RESULT=ok; STEP=fertig; DETAIL=ok
  echo "==> Wiederherstellungstest bestanden: $RUN_NAME (Tabellen: $TABLES, Migrationen: $MIGRATIONS, Zeilen: $ROWS)"
  exit 0
fi
case "$RC" in
  124) DETAIL=zeitlimit ;;
  125|126|127) DETAIL=docker_start ;;
  *) case "$LAST" in 1) DETAIL=pruefsummen ;; 2) DETAIL=wegwerf_datenbank ;; 3) DETAIL=entschluesseln_einspielen ;; 4) DETAIL=konfigarchiv ;; *) DETAIL=container ;; esac ;;
esac
exit 1
