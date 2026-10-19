#!/usr/bin/env bash
# Wiederherstellungstest (docs/WIEDERHERSTELLUNG.md): entschlüsselt eine Sicherung mit dem PRIVATEN age-Schlüssel, spielt die Datenbank
# in eine WEGWERF-Datenbank lx_fampad_restoretest ein, zählt Tabellen und Zeilen, prüft das Konfigurationsarchiv (nur Dateiliste) und
# löscht die Wegwerf-Datenbank wieder. Die Produktivdatenbank (lx_fampad) und alle Dateien des Dienstes werden nie angefasst.
#
# Läuft auf dem Entwicklungsrechner (PostgreSQL 17 mit Superuser-Zugang über die üblichen libpq-Variablen PGHOST/PGUSER/PGPASSWORD)
# oder auf dem Server (--as-postgres: Aufrufe als Benutzer postgres über die Unix-Socket; dann als root/sudo starten).
# Der Klartext der Datenbank läuft nur durch eine Pipe (age -d | pg_restore) und landet nie als Datei auf der Platte.
# Der private Schlüssel gehört NICHT auf den Server: den Test dort nur mit einer vorübergehend übertragenen Schlüsseldatei
# (danach sicher löschen) ausführen, besser auf dem eigenen Rechner mit einer vom NAS geholten Sicherung.
#
# Aufruf:
#   deploy/backup/wiederherstellung-test.sh --identity ~/lx-fampad-age.key --run-dir /pfad/zu/20261020-013000 [--as-postgres] [--keep]
#     --identity DATEI   privater age-Schlüssel (AGE-SECRET-KEY-…)
#     --run-dir ORDNER   ein Sicherungsordner (mit db-*.dump.age, config-*.tar.age, SHA256SUMS)
#     --as-postgres      psql/pg_restore als Benutzer postgres ausführen (nur Server)
#     --keep             Wegwerf-Datenbank am Ende NICHT löschen (zum Nachsehen; danach von Hand: dropdb lx_fampad_restoretest)
set -Eeuo pipefail

SCRATCH_DB=lx_fampad_restoretest      # fest; nie ein anderer Name
IDENTITY=""
RUN_DIR=""
AS_PG=0
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) [ $# -ge 2 ] || { echo "--identity braucht einen Wert" >&2; exit 2; }; IDENTITY="$2"; shift ;;
    --run-dir) [ $# -ge 2 ] || { echo "--run-dir braucht einen Wert" >&2; exit 2; }; RUN_DIR="$2"; shift ;;
    --as-postgres) AS_PG=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,/^set -E/{/^set -E/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done

fehler() { echo "FEHLER: $*" >&2; exit 1; }
[ -n "$IDENTITY" ] && [ -n "$RUN_DIR" ] || fehler "--identity und --run-dir sind Pflicht (--help)"
[ -r "$IDENTITY" ] || fehler "Schlüsseldatei nicht lesbar: $IDENTITY"
grep -q '^AGE-SECRET-KEY-' "$IDENTITY" || fehler "$IDENTITY enthält keinen privaten age-Schlüssel"
[ -d "$RUN_DIR" ] || fehler "Ordner fehlt: $RUN_DIR"
for b in age pg_restore psql tar sha256sum; do command -v "$b" >/dev/null || fehler "$b fehlt"; done

shopt -s nullglob
DBS=("$RUN_DIR"/db-*.dump.age)
CFGS=("$RUN_DIR"/config-*.tar.age)
[ "${#DBS[@]}" -eq 1 ] || fehler "genau eine db-*.dump.age in $RUN_DIR erwartet (gefunden: ${#DBS[@]})"
DB_FILE="${DBS[0]}"

if [ "$AS_PG" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || fehler "--as-postgres nur als root/sudo"
  pg() { (cd / && runuser -u postgres -- "$@"); }
else
  pg() { "$@"; }
fi
PSQL() { pg psql -X -v ON_ERROR_STOP=1 -q -d postgres "$@"; }

DROP_ON_EXIT=0
aufraeumen() {
  local rc=$?
  trap - EXIT
  if [ "$DROP_ON_EXIT" = 1 ] && [ "$KEEP" = 0 ]; then
    PSQL -c "DROP DATABASE IF EXISTS $SCRATCH_DB WITH (FORCE)" >/dev/null 2>&1 && echo "==> Wegwerf-Datenbank $SCRATCH_DB gelöscht." || echo "WARNUNG: $SCRATCH_DB konnte nicht gelöscht werden (von Hand: dropdb $SCRATCH_DB)" >&2
  elif [ "$DROP_ON_EXIT" = 1 ]; then
    echo "==> --keep: $SCRATCH_DB bleibt bestehen. Löschen: dropdb $SCRATCH_DB"
  fi
  exit "$rc"
}
trap aufraeumen EXIT

echo "==> 1/4 Prüfsummen"
if [ -f "$RUN_DIR/SHA256SUMS" ]; then
  ( cd "$RUN_DIR" && sha256sum -c --strict SHA256SUMS ) || fehler "Prüfsummen stimmen nicht: die Sicherung ist beschädigt"
else
  echo "    Hinweis: keine SHA256SUMS im Ordner."
fi

echo "==> 2/4 Wegwerf-Datenbank $SCRATCH_DB anlegen"
PSQL -tAc "select 1" >/dev/null || fehler "keine Verbindung zu PostgreSQL (PGHOST/PGUSER/PGPASSWORD oder --as-postgres)"
if [ "$(PSQL -tAc "select count(*) from pg_database where datname='$SCRATCH_DB'")" != 0 ]; then
  echo "    $SCRATCH_DB existiert (Rest eines früheren Tests) und wird ersetzt."
  PSQL -c "DROP DATABASE $SCRATCH_DB WITH (FORCE)"
fi
PSQL -c "CREATE DATABASE $SCRATCH_DB"
DROP_ON_EXIT=1

echo "==> 3/4 Entschlüsseln und einspielen (age -d | pg_restore, ohne Besitzer/Rechte)"
age -d -i "$IDENTITY" "$DB_FILE" | pg pg_restore --no-owner --no-privileges --exit-on-error -d "$SCRATCH_DB" \
  || fehler "Entschlüsseln oder pg_restore fehlgeschlagen (falscher Schlüssel? beschädigt? PostgreSQL-Version älter als die der Sicherung?)"
TABLES="$(pg psql -X -tAq -d "$SCRATCH_DB" -c "select count(*) from pg_tables where schemaname='public'")"
[ "$TABLES" -gt 0 ] || fehler "wiederhergestellte Datenbank enthält keine Tabellen"
echo "    Tabellen im Schema public: $TABLES"
echo "    Zeilen je Tabelle (exakt gezählt):"
pg psql -X -tAq -d "$SCRATCH_DB" -F ' | ' <<'SQL' | sed 's/^/        /'
select format('select %L as tabelle, count(*) as zeilen from %I.%I', schemaname||'.'||tablename, schemaname, tablename)
from pg_tables where schemaname in ('public','drizzle') order by 1
\gexec
SQL
MIG="$(pg psql -X -tAq -d "$SCRATCH_DB" -c "select count(*) from drizzle.__drizzle_migrations" 2>/dev/null || echo "?")"
echo "    angewendete Migrationen (drizzle.__drizzle_migrations): $MIG"

echo "==> 4/4 Konfigurationsarchiv (nur Dateiliste, nichts wird entpackt)"
if [ "${#CFGS[@]}" -eq 1 ]; then
  LIST="$(age -d -i "$IDENTITY" "${CFGS[0]}" | tar -tzf -)" || fehler "Konfigurationsarchiv nicht lesbar"
  # shellcheck disable=SC2001
  sed "s/^/        /" <<<"$LIST"
  grep -qx 'etc/lx-fampad/env' <<<"$LIST" || fehler "etc/lx-fampad/env fehlt im Archiv (AUTH_SECRET_KEY!)"
  echo "    etc/lx-fampad/env ist enthalten."
else
  echo "    Hinweis: kein (oder mehr als ein) config-*.tar.age im Ordner, übersprungen."
fi
echo "==> Wiederherstellungstest bestanden: $RUN_DIR"
