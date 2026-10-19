#!/usr/bin/env bash
# Tägliche Sicherung von lx-fampad (läuft als root über lx-fampad-backup.timer; installiert von einrichtung-backup.sh nach
# /usr/local/sbin/lx-fampad-backup, NICHT aus dem Git-Checkout starten).
#
# Ergebnis: /var/backups/lx-fampad/<UTC-Zeitstempel>/
#     db-<Zeit>.dump.age       pg_dump -Fc der Datenbank, direkt durch age verschlüsselt (Klartext nie als Datei: Pipe; Pipe-Puffer und /dev/shm können bei Speichermangel in den Swap geraten, siehe docs/BACKUP.md)
#     config-<Zeit>.tar.age    Konfiguration, Geheimnisse (AUTH_SECRET_KEY!), Caddy-Dateien des Projekts, ntfy, systemd-Units, ...
#     files-<Zeit>.tar.age     nur wenn INCLUDE_FILES=1 (Dateiablage)
#     SHA256SUMS               Prüfsummen der .age-Dateien
#   status                     Schlüssel=Wert-Datei (letzter Erfolg, Größen) für die Überwachung auf dem NAS
#   LATEST                     Name des neuesten Ordners
# Alles wird in .tmp-<Zeit>/ aufgebaut und erst am Ende per rename veröffentlicht (atomar). Aufbewahrung hier: die letzten KEEP Ordner
# (Standard 3); der Rest liegt auf dem NAS (docs/BACKUP.md).
#
# Verschlüsselung: age, nur mit ÖFFENTLICHEN Schlüsseln aus /etc/lx-fampad-backup/recipients.txt. Der private Schlüssel liegt nie auf
# dem Server. Die Sicherung enthält persönliche Daten und AUTH_SECRET_KEY, deshalb nie unverschlüsselt ablegen.
# Entscheidung ntfy: die SQLite-Dateien werden online mit "sqlite3 .backup" gesichert (konsistent, kein Dienststopp, keine Unterbrechung der
# Push-Verbindungen); die Zwischenkopie liegt nur im RAM (/dev/shm, 0700) und wird sofort gelöscht (Swap: siehe oben). Auch ein pg_dumpall --globals-only (Rollen, keine Daten) kommt so ins Konfigurationsarchiv.
# Standortdaten kommen nie in eine Sicherung (der Server speichert keine; hier ist auch kein Pfad dafür vorgesehen).
#
# Aufruf (root):  /usr/local/sbin/lx-fampad-backup        Exit 0 = Erfolg, sonst Fehler (Meldung auf stderr -> journalctl -u lx-fampad-backup)
set -Eeuo pipefail
umask 077
cd /
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

OUT_DIR=/var/backups/lx-fampad
RECIPIENTS=/etc/lx-fampad-backup/recipients.txt
RECIPIENTS_CONFIG=/etc/lx-fampad-backup/recipients-config.txt   # optional: eigene Empfänger NUR für config-*.tar.age (AUTH_SECRET_KEY), getrennt vom Dump
CONF=/etc/lx-fampad-backup/backup.conf
DB_NAME=lx_fampad
KEEP=3                       # Ordner, die auf dem Server bleiben
INCLUDE_APK=1                # neueste APK + latest.json (1) oder nur latest.json (0)
INCLUDE_FILES=0              # /srv/fampad/files als eigenes Archiv (Dateiablage, erst später sinnvoll; kann groß werden)
BACKUP_GROUP=lxbackup        # Lesegruppe für die Abholung
MIN_FREE_MB=1024
LOCK_FILE=/run/lock/lx-fampad-backup.lock   # nicht im RuntimeDirectory: systemd löscht es nach dem Lauf, ein paralleler manueller Lauf hätte dann eine andere Sperre

if [ -f "$CONF" ]; then
  if [ "$(stat -c '%u' "$CONF")" != 0 ] || [ $(( 8#$(stat -c '%a' "$CONF") & 8#022 )) -ne 0 ]; then
    echo "FEHLER: $CONF muss root gehören und darf für Gruppe/Andere nicht schreibbar sein." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$CONF"
fi

fail() { echo "FEHLER: $*" >&2; exit 1; }
log() { echo "    $*"; }

[ "$(id -u)" -eq 0 ] || fail "nur als root"
[[ "$DB_NAME" =~ ^[a-z0-9_]+$ ]] || fail "DB_NAME ungültig"
{ [[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ]; } || fail "KEEP muss eine Zahl >= 1 sein"
{ [[ "$INCLUDE_APK" =~ ^[01]$ ]] && [[ "$INCLUDE_FILES" =~ ^[01]$ ]]; } || fail "INCLUDE_APK/INCLUDE_FILES müssen 0 oder 1 sein"
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || fail "MIN_FREE_MB ungültig"

# Sperre gegen Doppellauf
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Eine andere Sicherung läuft noch (Sperre $LOCK_FILE), Abbruch." >&2; exit 75; }

STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP=""
SHM=""
ARMED=0

# --- Status-Datei (atomar; bei Fehlern bleibt der letzte Erfolg erhalten) ---------------------------------------------------
old_val() { grep -s "^$1=" "$OUT_DIR/status" | head -1 | cut -d= -f2- || true; }
write_status() {   # $1 = ok|fehler, danach Schlüssel=Wert für den Erfolgsfall
  local result="$1"; shift
  local ts="$OUT_DIR/.status.$$"
  {
    echo "last_run_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "last_run_epoch=$(date +%s)"
    echo "last_result=$result"
    if [ "$result" = ok ]; then
      echo "last_success_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "last_success_epoch=$(date +%s)"
      printf '%s\n' "$@"
    else
      echo "last_success_utc=$(old_val last_success_utc)"
      echo "last_success_epoch=$(old_val last_success_epoch)"
      echo "last_dir=$(old_val last_dir)"
      echo "total_bytes=$(old_val total_bytes)"
    fi
  } > "$ts"
  if getent group "$BACKUP_GROUP" >/dev/null; then chgrp "$BACKUP_GROUP" "$ts"; chmod 0640 "$ts"; else chmod 0600 "$ts"; fi
  mv -f "$ts" "$OUT_DIR/status"
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$ARMED" = 1 ]; then
    echo "FEHLER: Sicherung fehlgeschlagen (Code $rc). Es wurde nichts veröffentlicht; die vorhandenen Sicherungen bleiben unverändert." >&2
    write_status fehler || true
  fi
  if [ -n "$SHM" ]; then rm -rf -- "$SHM"; fi
  if [ -n "$TMP" ]; then rm -rf -- "$TMP"; fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT HUP

# --- Vorabprüfungen ------------------------------------------------------------------------------------------------------------
echo "==> Prüfungen ($STAMP UTC)"
[ -d "$OUT_DIR" ] || fail "$OUT_DIR fehlt (einrichtung-backup.sh legt es an)"
# Ab hier gilt jeder Fehler als fehlgeschlagene Sicherung (Status "fehler" wird geschrieben, damit das NAS es sofort sieht)
ARMED=1
# Reste abgebrochener Läufe ZUERST entfernen (die Sperre garantiert: kein anderer Lauf aktiv), sonst blockieren sie die Platzprüfung
find "$OUT_DIR" -maxdepth 1 -name '.tmp-*' -exec rm -rf -- {} + 2>/dev/null || true
find /dev/shm -maxdepth 1 -name 'lx-fampad-backup.*' -exec rm -rf -- {} + 2>/dev/null || true
for b in age tar gzip sha256sum flock runuser sqlite3 df sync du; do command -v "$b" >/dev/null || fail "$b fehlt (einrichtung-backup.sh installiert age und sqlite3)"; done
check_recipients() {   # $1 = Datei
  [ -s "$1" ] || fail "$1 fehlt oder ist leer (öffentlicher age-Schlüssel, siehe docs/BACKUP.md)"
  if grep -qi 'AGE-SECRET-KEY' "$1"; then fail "$1 enthält einen PRIVATEN Schlüssel. Sofort entfernen: der private Schlüssel gehört nie auf den Server."; fi
  grep -qE '^age1[02-9ac-hj-np-z]{58}$' "$1" || fail "$1 enthält keinen gültigen Empfänger (age1…)"
}
check_recipients "$RECIPIENTS"
CONFIG_RECIPIENTS="$RECIPIENTS"
if [ -e "$RECIPIENTS_CONFIG" ]; then check_recipients "$RECIPIENTS_CONFIG"; CONFIG_RECIPIENTS="$RECIPIENTS_CONFIG"; fi
PGDUMP="$(find /usr/lib/postgresql -maxdepth 3 -name pg_dump -path '*/bin/*' 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$PGDUMP" ] || [ ! -x "$PGDUMP" ]; then PGDUMP="$(command -v pg_dump || true)"; fi
[ -n "$PGDUMP" ] || fail "pg_dump fehlt"
PGDUMPALL="$(dirname "$PGDUMP")/pg_dumpall"
[ -x "$PGDUMPALL" ] || PGDUMPALL="$(command -v pg_dumpall || true)"
[ -n "$PGDUMPALL" ] || fail "pg_dumpall fehlt"
TABLES="$(runuser -u postgres -- psql -X -tAq -d "$DB_NAME" -c "select count(*) from pg_tables where schemaname='public'")" \
  || fail "Datenbank $DB_NAME nicht lesbar"
[ "${TABLES:-0}" -gt 0 ] || fail "Datenbank $DB_NAME enthält keine Tabellen (leer?), Abbruch statt leerer Sicherung"
# Platz: Reserve + 2x Datenbankgröße (Dump ist meist kleiner; Puffer) + bei INCLUDE_FILES die Dateiablage
DB_MB="$(runuser -u postgres -- psql -X -tAq -d "$DB_NAME" -c "select (pg_database_size(current_database())/1048576)::bigint")" || DB_MB=0
NEED=$((MIN_FREE_MB + 2 * DB_MB))
if [ "$INCLUDE_FILES" = 1 ] && [ -d /srv/fampad/files ]; then NEED=$((NEED + $(du -sm /srv/fampad/files | cut -f1))); fi
FREE="$(df --output=avail -m "$OUT_DIR" | tail -1 | tr -d ' ')"
[ "$FREE" -ge "$NEED" ] || fail "zu wenig freier Platz in $OUT_DIR: ${FREE} MB (benötigt ${NEED} MB: Reserve ${MIN_FREE_MB} + 2x Datenbank ${DB_MB} + ggf. Dateiablage)"
log "pg_dump: $PGDUMP; Datenbank $DB_NAME: $TABLES Tabellen, ${DB_MB} MB; frei: ${FREE} MB (benötigt ${NEED} MB)"

# Zeitstempel mit Sekundenauflösung: nach einem Lauf in derselben Sekunde kurz warten statt scheitern
for _ in 1 2 3 4 5; do
  [ ! -e "$OUT_DIR/$STAMP" ] && break
  sleep 1; STAMP="$(date -u +%Y%m%d-%H%M%S)"
done
[ ! -e "$OUT_DIR/$STAMP" ] || fail "$OUT_DIR/$STAMP existiert schon"
TMP="$OUT_DIR/.tmp-$STAMP"
mkdir -m 0700 "$TMP"

encrypt() { age -R "$RECIPIENTS" -o "$1"; }   # liest stdin, schreibt die verschlüsselte Datei (Datenbank, Dateiablage)
encrypt_config() { age -R "$CONFIG_RECIPIENTS" -o "$1"; }   # Konfiguration (mit AUTH_SECRET_KEY), ggf. andere Empfänger
check_age() { { [ -s "$1" ] && [ "$(head -c 21 "$1")" = "age-encryption.org/v1" ]; } || fail "$1 ist leer oder keine age-Datei"; }

# --- 1. Datenbank ----------------------------------------------------------------------------------------------------------------
echo "==> 1/3 Datenbank $DB_NAME (pg_dump -Fc | age)"
# Als postgres über die Unix-Socket (peer); ein Snapshot, konsistent. Rollen/Rechte werden nicht verändert.
runuser -u postgres -- "$PGDUMP" -Fc -d "$DB_NAME" | encrypt "$TMP/db-$STAMP.dump.age"
check_age "$TMP/db-$STAMP.dump.age"
log "db-$STAMP.dump.age: $(stat -c %s "$TMP/db-$STAMP.dump.age") Bytes"

# --- 2. Konfiguration --------------------------------------------------------------------------------------------------------------
echo "==> 2/3 Konfiguration und Geheimnisse (tar | age)"
SHM="$(mktemp -d -p /dev/shm lx-fampad-backup.XXXXXXXX)"
chmod 0700 "$SHM"
shopt -s nullglob
PATHS=()
MISSING=()
add() { local p; for p in "$@"; do if [ -e "$p" ]; then PATHS+=("${p#/}"); else MISSING+=("$p"); fi; done; }
add /etc/lx-fampad                                   # env, migrate.env (AUTH_SECRET_KEY!), ntfy-token, ntfy-family-password
# Das Haupt-Caddyfile (/etc/caddy/Caddyfile) gehört lx-labs.dev und kann deren Geheimnisse enthalten: bewusst NICHT in dieser Sicherung
add /etc/caddy/conf.d/*.caddy                        # fampad.caddy, ntfy.caddy
add /etc/ntfy/server.yml
add /etc/systemd/system/lx-fampad*                   # Units und Drop-ins (auch die der Sicherung)
add /etc/systemd/system/ntfy.service.d
add /etc/sudoers.d/lx-fampad
add /etc/systemd/journald.conf.d/lx-retention.conf
add /etc/lx-fampad-backup                            # nur öffentliche Schlüssel und backup.conf
add /srv/fampad/well-known
add /srv/fampad/releases/android/latest.json
if [ "$INCLUDE_APK" = 1 ]; then
  APK="$(printf '%s\n' /srv/fampad/releases/android/*.apk | grep -v 'latest' | sort -V | tail -1 || true)"
  if [ -n "$APK" ]; then add "$APK" "$APK.sha256"; fi
fi
# ntfy-Datenbanken: konsistente Kopie per SQLite-Backup-API in den RAM-Ordner, im Archiv unter var/lib/ntfy/
NTFY_N=0
if [ -d /var/lib/ntfy ]; then
  mkdir -p "$SHM/var/lib/ntfy"
  for db in /var/lib/ntfy/*.db; do
    sqlite3 -cmd '.timeout 10000' "$db" ".backup '$SHM/var/lib/ntfy/$(basename "$db")'" || fail "sqlite3 .backup für $db fehlgeschlagen"
    NTFY_N=$((NTFY_N + 1))
    # Das Lesen als root kann -wal/-shm anlegen: dem ntfy-Benutzer wieder zuordnen (sonst kann ntfy sie nicht mehr öffnen)
    for side in "$db-wal" "$db-shm"; do
      if [ -e "$side" ] && [ "$(stat -c %u "$side")" != "$(stat -c %u "$db")" ]; then
        chown --reference="$db" "$side"; chmod --reference="$db" "$side"
        log "Besitzer von $side an $db angeglichen"
      fi
    done
  done
fi
# Rollen und Passwort-Hashes (nur Rollen/Tablespaces, keine Daten) für den Neuaufbau; nur im verschlüsselten Archiv
runuser -u postgres -- "$PGDUMPALL" --globals-only > "$SHM/globals.sql" || fail "pg_dumpall --globals-only fehlgeschlagen"
[ -s "$SHM/globals.sql" ] || fail "globals.sql ist leer"
[ -e /etc/lx-fampad/env ] || fail "/etc/lx-fampad/env fehlt (AUTH_SECRET_KEY!), Abbruch"
{
  echo "lx-fampad Sicherung $STAMP (UTC)"
  echo "Rechner: $(hostname)"
  echo "Datenbank: $DB_NAME ($TABLES Tabellen), $("$PGDUMP" --version)"
  echo "Enthaltene Pfade (relativ zu /):"; printf '  %s\n' "${PATHS[@]}"
  echo "ntfy-Datenbanken (sqlite3 .backup): $NTFY_N"
  if [ "${#MISSING[@]}" -gt 0 ]; then echo "Nicht vorhanden (übersprungen):"; printf '  %s\n' "${MISSING[@]}"; fi
} > "$SHM/BACKUP-INFO.txt"
TAR_ARGS=(--numeric-owner --warning=no-file-changed -czf - -C / "${PATHS[@]}" -C "$SHM" BACKUP-INFO.txt globals.sql)
if [ "$NTFY_N" -gt 0 ]; then TAR_ARGS+=(var/lib/ntfy); fi
tar "${TAR_ARGS[@]}" | encrypt_config "$TMP/config-$STAMP.tar.age"
check_age "$TMP/config-$STAMP.tar.age"
rm -rf -- "$SHM"; SHM=""
log "config-$STAMP.tar.age: $(stat -c %s "$TMP/config-$STAMP.tar.age") Bytes, ${#PATHS[@]} Pfade, ntfy-DBs: $NTFY_N"
if [ "${#MISSING[@]}" -gt 0 ]; then log "nicht vorhanden (übersprungen): ${MISSING[*]}"; fi

# --- 3. Dateiablage (optional) ---------------------------------------------------------------------------------------------------
echo "==> 3/3 Dateiablage"
if [ "$INCLUDE_FILES" = 1 ] && [ -d /srv/fampad/files ]; then
  tar --numeric-owner --warning=no-file-changed -cf - -C / srv/fampad/files | encrypt "$TMP/files-$STAMP.tar.age"
  check_age "$TMP/files-$STAMP.tar.age"
  log "files-$STAMP.tar.age: $(stat -c %s "$TMP/files-$STAMP.tar.age") Bytes"
else
  log "übersprungen (INCLUDE_FILES=$INCLUDE_FILES)"
fi

# --- Prüfsummen, Rechte, Veröffentlichen ---------------------------------------------------------------------------------------
( cd "$TMP" && sha256sum -- *.age > SHA256SUMS && sha256sum -c --strict --quiet SHA256SUMS )
if getent group "$BACKUP_GROUP" >/dev/null; then
  chgrp -R "$BACKUP_GROUP" "$TMP"; chmod 0750 "$TMP"; chmod 0640 "$TMP"/*
else
  echo "    Hinweis: Gruppe $BACKUP_GROUP fehlt, Dateien bleiben nur für root lesbar." >&2
fi
TOTAL="$(du -sb "$TMP" | cut -f1)"
DB_BYTES="$(stat -c %s "$TMP/db-$STAMP.dump.age")"
CFG_BYTES="$(stat -c %s "$TMP/config-$STAMP.tar.age")"
sync -f "$TMP" 2>/dev/null || sync
mv -T "$TMP" "$OUT_DIR/$STAMP"
TMP=""
sync -f "$OUT_DIR" 2>/dev/null || sync

# LATEST und status erst nach dem rename
LT="$OUT_DIR/.latest.$$"
echo "$STAMP" > "$LT"
if getent group "$BACKUP_GROUP" >/dev/null; then chgrp "$BACKUP_GROUP" "$LT"; chmod 0640 "$LT"; fi
mv -f "$LT" "$OUT_DIR/LATEST"
write_status ok "last_dir=$STAMP" "db_bytes=$DB_BYTES" "config_bytes=$CFG_BYTES" "total_bytes=$TOTAL"

# --- Aufbewahrung (nur nach Erfolg): die neuesten KEEP Ordner bleiben ---------------------------------------------------
echo "==> Aufbewahrung: die letzten $KEEP Sicherungen bleiben"
mapfile -t ALL < <(find "$OUT_DIR" -maxdepth 1 -mindepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' -printf '%f\n' | sort)
if [ "${#ALL[@]}" -gt "$KEEP" ]; then
  for d in "${ALL[@]:0:${#ALL[@]}-KEEP}"; do
    [[ "$d" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    rm -rf -- "${OUT_DIR:?}/$d"
    log "gelöscht: $d"
  done
fi
echo "==> Fertig: $OUT_DIR/$STAMP ($TOTAL Bytes). Vorhanden: $(find "$OUT_DIR" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*' | wc -l) Sicherung(en)."
