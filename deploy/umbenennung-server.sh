#!/usr/bin/env bash
# Einmalige Umbenennung der BESTEHENDEN Installation auf dem VPS: lx-familienzentrale -> lx-fampad.
# Betrifft nur dieses Projekt. Der Dienst lx-labs und die Caddy-Site lx-labs.dev werden NICHT angefasst
# (nur Caddy wird neu geladen; schlägt das fehl, wird die alte Konfiguration zurückgespielt).
#
# Vorher im Checkout den neuen Stand holen (er enthält dieses Skript und die neuen Einheiten):
#   cd ~/lx-familienzentrale && git pull --ff-only
# ACHTUNG: Das Skript läuft als root, der Checkout gehört aber dem Benutzer lx (schreibbar). Es installiert Dateien aus dem
# Checkout nach /etc (systemd-Einheiten, Caddy). Vor dem Start also prüfen, WAS dort liegt:
#   git -C ~/lx-familienzentrale log -3 --stat
#   git -C ~/lx-familienzentrale status --short deploy     # muss leer sein (das Skript bricht sonst ab)
#   git -C ~/lx-familienzentrale diff origin/<Branch> -- deploy   # falls vom Remote abweichend
# Aufruf auf dem Server als Benutzer lx (aus dem alten Pfad):
#   sudo bash ~/lx-familienzentrale/deploy/umbenennung-server.sh
# Das Skript benennt am Ende auch den Checkout ~/lx-familienzentrale in ~/lx-fampad um (es kopiert alles, was es
# aus dem Checkout braucht, vorher in ein Zwischenverzeichnis). Danach: cd ~/lx-fampad && bash deploy/deploy.sh
#
# Was umbenannt wird (alt -> neu):
#   Dienste        lx-familie.service, lx-familie-migrate.service  -> lx-fampad.service, lx-fampad-migrate.service
#   Benutzer/Grp.  lx-familie                                       -> lx-fampad (Mitgliedschaft von lx bleibt, sie hängt an der GID)
#   Verzeichnisse  /srv/familie, /etc/lx-familie                    -> /srv/fampad, /etc/lx-fampad
#   Datenbank      lx_familie, Rollen lx_familie, lx_familie_migrate -> lx_fampad, lx_fampad, lx_fampad_migrate
#   sudoers        /etc/sudoers.d/lx-familie                        -> /etc/sudoers.d/lx-fampad
#   Caddy          /etc/caddy/conf.d/familie.caddy                  -> /etc/caddy/conf.d/fampad.caddy (Snippet fampad_sicherheit)
#   Checkout       ~/lx-familienzentrale, bare ~/familie.git        -> ~/lx-fampad, ~/fampad.git
# Unverändert: Domain familie.lx-labs.dev, ntfy.familie.lx-labs.dev, WebAuthn-RP-ID, Umgebungsvariablen-Namen, AUTH_SECRET_KEY.
#
# Das Skript ist idempotent: Jeder Schritt prüft den Ist-Zustand und überspringt Erledigtes (auch Benutzer und Gruppe einzeln,
# die Caddy-Site folgt dem Zustand der vorhandenen Site-Datei: ntfy-Block nur, wenn er vorher da war). Bei jedem Fehler bricht es
# mit Meldung ab; der Rückbau steht in deploy/README.md (Abschnitt "Umbenennung von lx-familienzentrale").
# Schritt 0 prüft ALLE Voraussetzungen (Befehle, Verzeichnisse, Dateien, Caddy-Import, Platz) und legt Fehlendes an, BEVOR
# irgendein Dienst gestoppt wird. Wird die Datenbank beim Umbenennen gesperrt (ALLOW_CONNECTIONS false), öffnet sie das Skript
# bei Fehler und bei jedem Neustart wieder.
# Sicherung vor der ersten Änderung, bewusst GETRENNT:
#   /var/backups/lx-fampad-umbenennung-<Zeit>/           pg_dump, Caddy, Units, sudoers (ohne Schlüssel)
#   /root/lx-fampad-umbenennung-<Zeit>-schluessel/       /etc/lx-familie mit env-Dateien und AUTH_SECRET_KEY (nur root, 0700/0600)
# Beides nach wenigen Tagen ohne Auffälligkeiten löschen (spätestens nach 14 Tagen, siehe deploy/README.md): ein Dump enthält
# Anmeldedaten und Klarnamen, der Schlüssel entschlüsselt die TOTP-Geheimnisse im Dump.

set -Eeuo pipefail

ALT_NAME=lx-familie
ALT_DB=lx_familie
ALT_DB_MIGRATE=lx_familie_migrate
NEU_NAME=lx-fampad
NEU_DB=lx_fampad
NEU_DB_MIGRATE=lx_fampad_migrate

SCHRITT="Start"
BACKUP_DIR=""
KEY_DIR=""
STAGE=""
PSQL=()
# shellcheck disable=SC2329  # wird über trap ERR aufgerufen
fehler() {
  echo >&2
  echo "!!  FEHLER im Schritt: $SCHRITT (Zeile $1)." >&2
  if [ -n "$BACKUP_DIR" ]; then echo "    Sicherung: $BACKUP_DIR (Schlüssel getrennt: $KEY_DIR)" >&2; fi
  echo "    Das Skript ist wiederholbar (nach Behebung der Ursache erneut starten)." >&2
  echo "    Rückbau und Hinweise: deploy/README.md, Abschnitt \"Umbenennung von lx-familienzentrale\"." >&2
  echo "    Hinweis: Wurden die Dienste schon gestoppt, laufen sie bis zur Behebung nicht." >&2
  exit 1
}
trap 'fehler $LINENO' ERR

abbruch() { echo "!!  $*" >&2; trap - ERR; exit 1; }
schritt() { SCHRITT="$1"; echo "==> $1"; }

db_da()    { "${PSQL[@]}" -c "select 1 from pg_database where datname='$1'" | grep -q 1; }
rolle_da() { "${PSQL[@]}" -c "select 1 from pg_roles where rolname='$1'" | grep -q 1; }

# Datenbanken, die ein früherer (abgebrochener) Lauf für Verbindungen gesperrt hat, wieder öffnen
db_oeffnen() {
  [ "${#PSQL[@]}" -gt 0 ] || return 0
  local d
  for d in "$ALT_DB" "$NEU_DB"; do
    if db_da "$d" && [ "$("${PSQL[@]}" -c "select datallowconn from pg_database where datname='$d'")" = "f" ]; then
      "${PSQL[@]}" -c "ALTER DATABASE $d ALLOW_CONNECTIONS true" && echo "    Datenbank $d wieder für Verbindungen geöffnet."
    fi
  done
}

# shellcheck disable=SC2329  # wird über trap EXIT aufgerufen
aufraeumen() {
  local rc=$?
  trap - ERR
  db_oeffnen || true
  if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
  return "$rc"
}
trap aufraeumen EXIT

main() {
  cd /

  # ---------------------------------------------------------------- 0. Prüfungen
  schritt "0/12 Prüfungen"
  [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] || abbruch "Bitte als Benutzer lx starten:  sudo bash $0"
  LX="$SUDO_USER"
  LX_HOME="$(getent passwd "$LX" | cut -d: -f6)"
  ALT_REPO="$LX_HOME/lx-familienzentrale"
  NEU_REPO="$LX_HOME/lx-fampad"
  ALT_BARE="$LX_HOME/familie.git"
  NEU_BARE="$LX_HOME/fampad.git"
  for c in systemctl pg_dump pg_restore psql visudo caddy curl usermod groupmod sed awk git openssl pgrep mktemp install journalctl seq df; do
    command -v "$c" >/dev/null || abbruch "Befehl fehlt: $c"
  done
  PSQL=(sudo -u postgres psql -v ON_ERROR_STOP=1 -q -X -tA)
  "${PSQL[@]}" -c 'select 1' >/dev/null || abbruch "Zugriff auf PostgreSQL als postgres funktioniert nicht."
  db_oeffnen
  systemctl is-active --quiet postgresql || abbruch "PostgreSQL läuft nicht."
  systemctl is-active --quiet caddy || abbruch "Caddy läuft nicht."
  systemctl is-active --quiet lx-labs || abbruch "lx-labs läuft nicht (Ausgangszustand muss sauber sein)."
  lxlabs_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://lx-labs.dev || true)
  [ "$lxlabs_code" = "200" ] || abbruch "https://lx-labs.dev liefert schon vor der Umbenennung $lxlabs_code statt 200."

  # Dateien des neuen Stands: aus dem Checkout (alt oder, falls schon umbenannt, neu)
  REPO_AKTUELL="$ALT_REPO"
  [ -d "$ALT_REPO" ] || REPO_AKTUELL="$NEU_REPO"
  for f in lx-fampad.service lx-fampad-migrate.service Caddyfile; do
    [ -f "$REPO_AKTUELL/deploy/$f" ] || abbruch "$REPO_AKTUELL/deploy/$f fehlt. Zuerst im Checkout 'git pull --ff-only' (Branch mit der Umbenennung)."
  done
  # Der Checkout gehört lx, das Skript läuft als root und installiert daraus nach /etc: Stand anzeigen, Abweichungen verbieten
  if [ -d "$REPO_AKTUELL/.git" ]; then
    echo "    Stand des Checkouts (wird als root nach /etc installiert):"
    sudo -u "$LX" git -C "$REPO_AKTUELL" log -1 --format='      %h %an %ad  %s' --date=short || echo "      (kein Commit lesbar)"
    aenderungen="$(sudo -u "$LX" git -C "$REPO_AKTUELL" status --porcelain -- deploy)"
    [ -z "$aenderungen" ] || abbruch "Der Checkout hat uncommittete Änderungen in deploy/ (git status --short deploy). Prüfen und zurücksetzen oder einchecken, dann erneut starten:
$aenderungen"
  fi
  # Eingebettete Dateien sicherstellen, bevor irgendetwas verschoben wird
  STAGE="$(mktemp -d /root/umbenennung-stage.XXXXXX)"
  cp "$REPO_AKTUELL/deploy/lx-fampad.service" "$REPO_AKTUELL/deploy/lx-fampad-migrate.service" "$REPO_AKTUELL/deploy/Caddyfile" "$STAGE/"
  grep -q '^familie\.lx-labs\.dev' "$STAGE/Caddyfile" || abbruch "Site-Block familie.lx-labs.dev fehlt im neuen Caddyfile."

  # Voraussetzungen des Servers, alle VOR dem ersten Stoppen/Verschieben
  CADDYFILE=/etc/caddy/Caddyfile
  [ -f "$CADDYFILE" ] || abbruch "$CADDYFILE fehlt."
  grep -qsE '^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy' "$CADDYFILE" \
    || abbruch "$CADDYFILE enthält die Zeile 'import /etc/caddy/conf.d/*.caddy' nicht (deploy/README.md, Schritt 6). Nichts geändert."
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || abbruch "Die Caddy-Konfiguration ist schon vor der Umbenennung ungültig (caddy validate)."
  if [ -d /srv/familie ]; then SRV=/srv/familie; elif [ -d /srv/fampad ]; then SRV=/srv/fampad; else abbruch "Weder /srv/familie noch /srv/fampad vorhanden."; fi
  for d in server files; do
    [ -d "$SRV/$d" ] || abbruch "$SRV/$d fehlt (einrichtung-1.sh nicht gelaufen?)."
  done
  # server.prev (Vorversion für den Rückfall von deploy.sh) fehlt auf frischen Installationen: jetzt anlegen, nicht erst mitten drin
  if [ ! -d "$SRV/server.prev" ]; then
    install -d -m 750 -o "$LX" -g root "$SRV/server.prev"
    echo "    $SRV/server.prev angelegt (Besitzer $LX; Gruppe wird in Schritt 4 gesetzt)."
  fi
  ENV_DIR=/etc/$ALT_NAME
  [ -d "$ENV_DIR" ] || ENV_DIR=/etc/$NEU_NAME
  [ -f "$ENV_DIR/env" ] || abbruch "$ENV_DIR/env fehlt."
  grep -q '^DATABASE_URL=' "$ENV_DIR/env" || abbruch "DATABASE_URL fehlt in $ENV_DIR/env."
  frei_mb=$(df -Pm /var/backups | awk 'NR==2{print $4}')
  [ "${frei_mb:-0}" -ge 200 ] || abbruch "Unter /var/backups sind nur ${frei_mb:-0} MB frei (mindestens 200 MB für die Sicherung)."

  # Kollisionen: alter und neuer Name gleichzeitig vorhanden = unklarer Zustand
  if id "$ALT_NAME" >/dev/null 2>&1 && id "$NEU_NAME" >/dev/null 2>&1; then abbruch "Benutzer $ALT_NAME und $NEU_NAME existieren beide."; fi
  if getent group "$ALT_NAME" >/dev/null && getent group "$NEU_NAME" >/dev/null; then abbruch "Gruppen $ALT_NAME und $NEU_NAME existieren beide."; fi
  if [ -d /srv/familie ] && [ -d /srv/fampad ]; then abbruch "/srv/familie und /srv/fampad existieren beide."; fi
  if [ -d "/etc/$ALT_NAME" ] && [ -d "/etc/$NEU_NAME" ]; then abbruch "/etc/$ALT_NAME und /etc/$NEU_NAME existieren beide."; fi
  if db_da "$ALT_DB" && db_da "$NEU_DB"; then abbruch "Datenbanken $ALT_DB und $NEU_DB existieren beide."; fi
  if { rolle_da "$ALT_DB" && rolle_da "$NEU_DB"; } || { rolle_da "$ALT_DB_MIGRATE" && rolle_da "$NEU_DB_MIGRATE"; }; then
    abbruch "Alte und neue Datenbank-Rollen existieren gleichzeitig."
  fi
  noch_alt=0
  if id "$ALT_NAME" >/dev/null 2>&1 || getent group "$ALT_NAME" >/dev/null || [ -d /srv/familie ] || [ -d "/etc/$ALT_NAME" ] || db_da "$ALT_DB" \
     || [ -f "/etc/systemd/system/$ALT_NAME.service" ] || [ -f /etc/caddy/conf.d/familie.caddy ] \
     || [ -f "/etc/sudoers.d/$ALT_NAME" ] || [ -d "$ALT_REPO" ] || [ -d "$ALT_BARE" ]; then noch_alt=1; fi
  if [ "$noch_alt" -eq 0 ]; then
    echo "    Es ist nichts Altes mehr vorhanden: die Umbenennung ist bereits erfolgt. Es folgen nur die Abschlussprüfungen."
  fi
  echo "    Voraussetzungen erfüllt (lx-labs.dev: 200)."

  if [ "$noch_alt" -eq 1 ]; then
    # -------------------------------------------------------------- 1. Sicherung
    schritt "1/12 Sicherung nach /var/backups"
    ZEIT="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/var/backups/lx-fampad-umbenennung-$ZEIT"
    KEY_DIR="/root/lx-fampad-umbenennung-$ZEIT-schluessel"
    install -d -m 700 -o root -g root "$BACKUP_DIR" "$KEY_DIR"
    if db_da "$ALT_DB"; then
      # Ausgabe schreibt root (Umleitung), pg_dump läuft als postgres; Format "custom" (pg_restore)
      # shellcheck disable=SC2024  # die Umleitung soll als root schreiben
      sudo -u postgres pg_dump -Fc "$ALT_DB" > "$BACKUP_DIR/$ALT_DB.dump"
      [ -s "$BACKUP_DIR/$ALT_DB.dump" ] || abbruch "pg_dump hat eine leere Datei erzeugt."
      pg_restore -l "$BACKUP_DIR/$ALT_DB.dump" >/dev/null || abbruch "Die Sicherung ist nicht lesbar."
      chmod 600 "$BACKUP_DIR/$ALT_DB.dump"
    elif db_da "$NEU_DB"; then
      # shellcheck disable=SC2024  # die Umleitung soll als root schreiben
      sudo -u postgres pg_dump -Fc "$NEU_DB" > "$BACKUP_DIR/$NEU_DB.dump"
      chmod 600 "$BACKUP_DIR/$NEU_DB.dump"
    fi
    # env-Dateien (AUTH_SECRET_KEY, Datenbank-Passwörter) getrennt vom Dump, nur für root
    [ -d "/etc/$ALT_NAME" ] && cp -a "/etc/$ALT_NAME" "$KEY_DIR/etc-$ALT_NAME"
    [ -d "/etc/$NEU_NAME" ] && cp -a "/etc/$NEU_NAME" "$KEY_DIR/etc-$NEU_NAME"
    find "$KEY_DIR" -type f -exec chmod 600 {} +
    find "$KEY_DIR" -type d -exec chmod 700 {} +
    cp -a /etc/caddy/Caddyfile "$BACKUP_DIR/Caddyfile"
    [ -f /etc/caddy/conf.d/familie.caddy ] && cp -a /etc/caddy/conf.d/familie.caddy "$BACKUP_DIR/familie.caddy"
    [ -f /etc/caddy/Caddyfile.vor-familie ] && cp -a /etc/caddy/Caddyfile.vor-familie "$BACKUP_DIR/Caddyfile.vor-familie"
    for u in "$ALT_NAME.service" "$ALT_NAME-migrate.service"; do
      [ -f "/etc/systemd/system/$u" ] && cp -a "/etc/systemd/system/$u" "$BACKUP_DIR/$u"
    done
    [ -f "/etc/sudoers.d/$ALT_NAME" ] && cp -a "/etc/sudoers.d/$ALT_NAME" "$BACKUP_DIR/sudoers-$ALT_NAME"
    { id "$ALT_NAME" 2>&1 || true; id "$LX"; ls -ld /srv/familie /srv/familie/* 2>&1 || true; } > "$BACKUP_DIR/zustand.txt"
    echo "    $BACKUP_DIR"
    echo "    $KEY_DIR (Schlüssel/env, getrennt)"

    # -------------------------------------------------------------- 2. Dienste stoppen
    schritt "2/12 Dienste stoppen und alte Einheiten abschalten"
    for u in "$ALT_NAME.service" "$ALT_NAME-migrate.service" "$NEU_NAME.service" "$NEU_NAME-migrate.service"; do
      systemctl stop "$u" 2>/dev/null || true
    done
    systemctl disable "$ALT_NAME.service" 2>/dev/null || true
    # Es darf kein Prozess des Dienstbenutzers mehr laufen (sonst scheitert usermod)
    for u in "$ALT_NAME" "$NEU_NAME"; do
      if id "$u" >/dev/null 2>&1 && pgrep -u "$u" >/dev/null 2>&1; then abbruch "Es laufen noch Prozesse von $u."; fi
    done

    # -------------------------------------------------------------- 3. Benutzer und Gruppe
    schritt "3/12 Systembenutzer und -gruppe umbenennen"
    # Benutzer und Gruppe getrennt prüfen: bricht usermod ODER groupmod ab, holt ein erneuter Lauf genau das Fehlende nach
    if id "$ALT_NAME" >/dev/null 2>&1; then
      usermod -l "$NEU_NAME" -d "/home/$NEU_NAME" "$ALT_NAME"
    else
      echo "    Benutzer: schon erledigt."
    fi
    if getent group "$ALT_NAME" >/dev/null; then
      groupmod -n "$NEU_NAME" "$ALT_NAME"
    else
      echo "    Gruppe: schon erledigt."
    fi
    id "$NEU_NAME" >/dev/null 2>&1 || abbruch "Benutzer $NEU_NAME fehlt nach der Umbenennung."
    getent group "$NEU_NAME" >/dev/null || abbruch "Gruppe $NEU_NAME fehlt nach der Umbenennung."
    # Gruppenmitgliedschaft von lx: hängt an der GID, bleibt erhalten; zur Sicherheit prüfen und ggf. nachziehen
    id -nG "$LX" | tr ' ' '\n' | grep -qx "$NEU_NAME" || usermod -aG "$NEU_NAME" "$LX"
    echo "    $LX ist Mitglied von: $(id -nG "$LX")"

    # -------------------------------------------------------------- 4. Verzeichnisse
    schritt "4/12 Verzeichnisse verschieben"
    if [ -d /srv/familie ]; then mv /srv/familie /srv/fampad; fi
    if [ -d "/etc/$ALT_NAME" ]; then mv "/etc/$ALT_NAME" "/etc/$NEU_NAME"; fi
    # Rechte wie in einrichtung-1.sh (Besitzer folgen den umbenannten IDs, das hier ist nur die Absicherung)
    chown root:root "/etc/$NEU_NAME"; chmod 755 "/etc/$NEU_NAME"
    chmod 755 /srv/fampad
    chown "$LX":"$NEU_NAME" /srv/fampad/server /srv/fampad/server.prev
    chmod 750 /srv/fampad/server /srv/fampad/server.prev
    chown "$NEU_NAME":"$NEU_NAME" /srv/fampad/files
    chmod 700 /srv/fampad/files
    ls -ld /srv/fampad /srv/fampad/server /srv/fampad/files

    # -------------------------------------------------------------- 5. Datenbank und Rollen
    schritt "5/12 Datenbank und Rollen umbenennen"
    db_oeffnen   # Rest eines früheren Abbruchs
    if db_da "$ALT_DB"; then
      # gesperrt wird nur kurz; bei Fehler öffnet der EXIT-Handler (aufraeumen) die Datenbank wieder
      "${PSQL[@]}" -c "ALTER DATABASE $ALT_DB ALLOW_CONNECTIONS false"
      "${PSQL[@]}" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ALT_DB' AND pid <> pg_backend_pid()" >/dev/null
      "${PSQL[@]}" -c "ALTER DATABASE $ALT_DB RENAME TO $NEU_DB"
      "${PSQL[@]}" -c "ALTER DATABASE $NEU_DB ALLOW_CONNECTIONS true"
    fi
    for paar in "$ALT_DB:$NEU_DB" "$ALT_DB_MIGRATE:$NEU_DB_MIGRATE"; do
      alt="${paar%%:*}"; neu="${paar##*:}"
      if rolle_da "$alt"; then
        "${PSQL[@]}" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='$alt' AND pid <> pg_backend_pid()" >/dev/null
        "${PSQL[@]}" -c "ALTER ROLE $alt RENAME TO $neu"
      fi
    done
    { db_da "$NEU_DB" && rolle_da "$NEU_DB"; } || abbruch "Datenbank/Rolle $NEU_DB fehlt nach der Umbenennung."

    # -------------------------------------------------------------- 6. env-Dateien
    schritt "6/12 env-Dateien anpassen"
    for f in "/etc/$NEU_NAME/env" "/etc/$NEU_NAME/migrate.env"; do
      [ -f "$f" ] || continue
      sed -i -e 's#/srv/familie#/srv/fampad#g' \
             -e "s#/etc/$ALT_NAME#/etc/$NEU_NAME#g" \
             -e "s#$ALT_DB_MIGRATE#$NEU_DB_MIGRATE#g" \
             -e "s#$ALT_DB#$NEU_DB#g" "$f"
      chown root:root "$f"; chmod 600 "$f"
    done
    grep -q '^DATABASE_URL=' "/etc/$NEU_NAME/env" || abbruch "DATABASE_URL fehlt in /etc/$NEU_NAME/env."
    echo "    angepasst (root:root, 0600). Inhalt wird nicht angezeigt (enthält Passwörter)."

    # Anmeldung der umbenannten Rollen prüfen. Bei SCRAM-Passwörtern bleibt das Passwort beim Umbenennen erhalten
    # (nur MD5-Passwörter werden von PostgreSQL gelöscht); schlägt die Anmeldung fehl, wird ein neues Passwort gesetzt.
    url_passwort() { sed -n "s#^$2=postgres\(ql\)\{0,1\}://[^:]*:\([^@]*\)@.*#\2#p" "$1" | head -1; }
    login_ok() { PGPASSWORD="$3" PGCONNECT_TIMEOUT=5 psql -X -tA -h 127.0.0.1 -U "$1" -d "$NEU_DB" -c 'select 1' >/dev/null 2>&1; }
    passwort_neu_setzen() { # Rolle, Datei, Variable
      local pw; pw="$(openssl rand -base64 24 | tr -d '/+=')"
      printf "ALTER ROLE %s LOGIN PASSWORD '%s';\n" "$1" "$pw" | "${PSQL[@]}"
      sed -i "s#^\($3=postgres\(ql\)\{0,1\}://[^:]*:\)[^@]*@#\1$pw@#" "$2"
      echo "    Passwort der Rolle $1 neu gesetzt (steht nur in $2)."
    }
    pw="$(url_passwort "/etc/$NEU_NAME/env" DATABASE_URL)"
    login_ok "$NEU_DB" "$NEU_DB" "$pw" || passwort_neu_setzen "$NEU_DB" "/etc/$NEU_NAME/env" DATABASE_URL
    pw="$(url_passwort "/etc/$NEU_NAME/env" DATABASE_URL)"
    login_ok "$NEU_DB" "$NEU_DB" "$pw" || abbruch "Anmeldung als $NEU_DB schlägt trotz neuem Passwort fehl (pg_hba.conf?)."
    if [ -f "/etc/$NEU_NAME/migrate.env" ] && rolle_da "$NEU_DB_MIGRATE"; then
      pw="$(url_passwort "/etc/$NEU_NAME/migrate.env" MIGRATION_DATABASE_URL)"
      login_ok "$NEU_DB_MIGRATE" "$NEU_DB" "$pw" || passwort_neu_setzen "$NEU_DB_MIGRATE" "/etc/$NEU_NAME/migrate.env" MIGRATION_DATABASE_URL
      pw="$(url_passwort "/etc/$NEU_NAME/migrate.env" MIGRATION_DATABASE_URL)"
      login_ok "$NEU_DB_MIGRATE" "$NEU_DB" "$pw" || abbruch "Anmeldung als $NEU_DB_MIGRATE schlägt fehl."
    fi
    unset pw
    echo "    Anmeldung beider Rollen funktioniert."

    # -------------------------------------------------------------- 7. systemd
    schritt "7/12 systemd-Einheiten austauschen"
    cp "$STAGE/lx-fampad.service" "$STAGE/lx-fampad-migrate.service" /etc/systemd/system/
    chmod 644 /etc/systemd/system/lx-fampad.service /etc/systemd/system/lx-fampad-migrate.service
    rm -f "/etc/systemd/system/$ALT_NAME.service" "/etc/systemd/system/$ALT_NAME-migrate.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/$ALT_NAME.service"
    systemctl daemon-reload
    systemctl reset-failed "$ALT_NAME.service" "$ALT_NAME-migrate.service" 2>/dev/null || true

    # -------------------------------------------------------------- 8. sudoers
    schritt "8/12 sudoers"
    tmp_sudo="$(mktemp /etc/sudoers.d/.lx-fampad.XXXXXX)"
    echo "$LX ALL=(root) NOPASSWD: /usr/bin/systemctl restart $NEU_NAME" > "$tmp_sudo"
    chmod 440 "$tmp_sudo"
    if ! visudo -cf "$tmp_sudo" >/dev/null; then rm -f "$tmp_sudo"; abbruch "sudoers-Prüfung fehlgeschlagen, nichts geändert."; fi
    mv "$tmp_sudo" "/etc/sudoers.d/$NEU_NAME"
    rm -f "/etc/sudoers.d/$ALT_NAME"
    visudo -c >/dev/null || abbruch "sudoers insgesamt fehlerhaft (Sicherung: $BACKUP_DIR)."

    # -------------------------------------------------------------- 9. Dienst starten
    schritt "9/12 Dienst lx-fampad starten (Migrationen laufen davor)"
    systemctl enable "$NEU_NAME.service"
    if [ ! -f "/etc/$NEU_NAME/migrate.env" ]; then
      # Phase-0-Bestand: Die neuen Einheiten verlangen migrate.env und AUTH_SECRET_KEY (legt einrichtung-auth.sh an),
      # und der installierte Code kennt die Anmeldung noch nicht. Starten wäre sinnlos; erst einrichtung-auth.sh + deploy.sh.
      PHASE0_BESTAND=1
      echo "    Phase-0-Bestand (keine migrate.env): der Dienst wird hier NICHT gestartet."
      echo "    Er startet nach 'einrichtung-auth.sh' und 'deploy.sh' (Hinweise am Ende)."
    else
      systemctl start "$NEU_NAME.service"
      ok=0
      for i in $(seq 1 30); do
        if curl -fsS --max-time 3 http://127.0.0.1:4400/api/v1/health 2>/dev/null | grep -q '"db":"ok"'; then ok=1; echo "    lokal online mit Datenbank nach ${i}s"; break; fi
        sleep 1
      done
      [ "$ok" -eq 1 ] || { journalctl -u "$NEU_NAME" -n 30 --no-pager >&2 || true; abbruch "Dienst antwortet nicht mit \"db\":\"ok\"."; }
    fi

    # -------------------------------------------------------------- 10. Caddy
    schritt "10/12 Caddy: familie.caddy -> fampad.caddy"
    ALT_SITE=/etc/caddy/conf.d/familie.caddy
    NEU_SITE=/etc/caddy/conf.d/fampad.caddy
    cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile.vor-validate"
    caddy_zurueck() {
      echo "!!  Caddy-Konfiguration wird auf den Stand vor der Umbenennung zurückgesetzt." >&2
      cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"
      rm -f "$NEU_SITE"
      [ -f "$BACKUP_DIR/familie.caddy" ] && cp -a "$BACKUP_DIR/familie.caddy" "$ALT_SITE"
      systemctl reload caddy || true
      echo "    lx-labs.dev: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://lx-labs.dev || echo kein-Ergebnis)" >&2
      abbruch "Caddy-Schritt fehlgeschlagen; alte Konfiguration zurückgespielt. Der Dienst lx-fampad läuft weiter lokal."
    }
    mkdir -p /etc/caddy/conf.d
    # Der ntfy-Block kommt nur dazu, wenn er vorher da war (einrichtung-2.sh lässt ihn weg). Maßgeblich ist die vorhandene
    # Site-Datei: die alte, bei einer Wiederholung die schon geschriebene neue. Ohne jede Datei bleibt er weg (nachrüsten ist
    # einfacher als eine Zertifikatsanforderung für eine Domain ohne DNS-Eintrag).
    VORLAGE=""
    for f in "$ALT_SITE" "$NEU_SITE"; do
      if [ -f "$f" ]; then VORLAGE="$f"; break; fi
    done
    if [ -n "$VORLAGE" ] && grep -q '^ntfy\.familie\.lx-labs\.dev' "$VORLAGE"; then
      cp "$STAGE/Caddyfile" "$STAGE/fampad.caddy"
    else
      awk '/^ntfy\.familie\.lx-labs\.dev/{exit} {print}' "$STAGE/Caddyfile" > "$STAGE/fampad.caddy"
    fi
    grep -q '^familie\.lx-labs\.dev' "$STAGE/fampad.caddy" || abbruch "Site-Block familie.lx-labs.dev fehlt in der neuen Site-Datei."
    if [ -f "$ALT_SITE" ]; then
      # Die alte Datei muss vor dem Prüfen weg (gleicher Site-Block würde doppelt definiert)
      mv "$ALT_SITE" "$BACKUP_DIR/familie.caddy.entfernt"
    fi
    install -m 644 -o root -g root "$STAGE/fampad.caddy" "$NEU_SITE"
    [ -f /etc/caddy/Caddyfile.vor-familie ] && mv /etc/caddy/Caddyfile.vor-familie /etc/caddy/Caddyfile.vor-fampad.aus-familie
    caddy validate --config "$CADDYFILE" --adapter caddyfile || caddy_zurueck
    systemctl reload caddy || caddy_zurueck
    sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://lx-labs.dev || true)
    [ "$code" = "200" ] || caddy_zurueck
    echo "    Caddy neu geladen, lx-labs.dev: $code"

    # -------------------------------------------------------------- 11. Checkout und bare Repository
    schritt "11/12 Checkout und bare Repository umbenennen"
    als_lx() { sudo -u "$LX" -H "$@"; }
    if [ -d "$ALT_BARE" ]; then
      [ -e "$NEU_BARE" ] && abbruch "$NEU_BARE existiert schon."
      mv "$ALT_BARE" "$NEU_BARE"
      # Hooks im bare Repository können alte Pfade enthalten
      if [ -d "$NEU_BARE/hooks" ]; then
        # Variable statt Pipe: ohne Treffer liefert grep 1, das würde unter pipefail/set -e den Lauf abbrechen
        hooks="$(grep -rlI -E 'familie\.git|lx-familienzentrale|/srv/familie|lx-familie' "$NEU_BARE/hooks" 2>/dev/null || true)"
        while IFS= read -r h; do
          [ -n "$h" ] || continue
          sed -i -e 's#familie\.git#fampad.git#g' -e 's#lx-familienzentrale#lx-fampad#g' -e 's#/srv/familie#/srv/fampad#g' -e 's#lx-familie#lx-fampad#g' "$h"
          echo "    Hook angepasst: $h"
        done <<< "$hooks"
      fi
      echo "    $ALT_BARE -> $NEU_BARE"
    fi
    if [ -d "$ALT_REPO" ]; then
      [ -e "$NEU_REPO" ] && abbruch "$NEU_REPO existiert schon."
      mv "$ALT_REPO" "$NEU_REPO"
      echo "    $ALT_REPO -> $NEU_REPO"
    fi
    if [ -d "$NEU_REPO/.git" ]; then
      url="$(als_lx git -C "$NEU_REPO" remote get-url origin 2>/dev/null || true)"
      case "$url" in
        */familie.git|*"$ALT_BARE")
          als_lx git -C "$NEU_REPO" remote set-url origin "$NEU_BARE"
          echo "    git-Remote origin: $NEU_BARE" ;;
        *lx-familienzentrale*)
          echo "    Hinweis: git-Remote origin zeigt auf GitHub ($url). Nach der Umbenennung des Repositorys (diy3d-de/lx-fampad)"
          echo "    leitet GitHub um; sauber umstellen mit: git -C $NEU_REPO remote set-url origin git@github.com:diy3d-de/lx-fampad.git" ;;
        *) echo "    git-Remote origin unverändert: ${url:-<keiner>}" ;;
      esac
    fi
  fi

  # ---------------------------------------------------------------- 12. Abschlussprüfung
  schritt "12/12 Abschlussprüfung"
  if [ ! -f "/etc/$NEU_NAME/migrate.env" ]; then PHASE0_BESTAND=1; fi
  if [ "${PHASE0_BESTAND:-0}" -ne 1 ]; then
    systemctl is-active --quiet "$NEU_NAME" || abbruch "lx-fampad.service ist nicht aktiv."
  fi
  systemctl is-active --quiet lx-labs || abbruch "lx-labs ist nicht aktiv."
  systemctl is-active --quiet caddy || abbruch "caddy ist nicht aktiv."
  for u in "$ALT_NAME" "$ALT_NAME-migrate"; do
    [ ! -e "/etc/systemd/system/$u.service" ] || abbruch "Alte Einheit $u.service ist noch installiert."
  done
  if [ "${PHASE0_BESTAND:-0}" -ne 1 ]; then
    ok=0
    for i in $(seq 1 30); do
      if curl -fsS --max-time 5 https://familie.lx-labs.dev/api/v1/health 2>/dev/null | grep -q '"db":"ok"'; then ok=1; break; fi
      sleep 2
    done
    [ "$ok" -eq 1 ] || abbruch "https://familie.lx-labs.dev/api/v1/health liefert nicht \"db\":\"ok\" (Rückbau: deploy/README.md)."
    echo "    https://familie.lx-labs.dev/api/v1/health: \"db\":\"ok\""
  else
    echo "    familie.lx-labs.dev bleibt bis zum Start des Dienstes ohne Antwort der API (Phase-0-Bestand, siehe unten)."
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://lx-labs.dev || true)
  [ "$code" = "200" ] || abbruch "https://lx-labs.dev liefert $code statt 200."
  echo "    https://lx-labs.dev: $code"
  echo
  echo "Fertig. Nächste Schritte als Benutzer lx:"
  echo "  1. Neu anmelden (oder 'newgrp $NEU_NAME'), damit die umbenannte Gruppe in der Sitzung gilt."
  if [ "${PHASE0_BESTAND:-0}" -eq 1 ]; then
    echo "  2a. sudo bash ~/lx-fampad/deploy/einrichtung-auth.sh   # Schlüssel, getrennte Datenbankrollen, migrate.env (VOR deploy.sh)"
    echo "  2b. cd ~/lx-fampad && bash deploy/deploy.sh            # neuen Code bauen, ausrollen und den Dienst starten"
  else
    echo "  2. cd ~/lx-fampad && bash deploy/deploy.sh      # neuen Code bauen und ausrollen"
  fi
  echo "  3. Auf dem PC die ssh-Aufrufe anpassen (ssh lx-labs bash lx-fampad/deploy/deploy.sh)."
  if [ -n "$BACKUP_DIR" ]; then
    echo "Sicherung (nach einigen Tagen ohne Auffälligkeiten löschen, spätestens nach 14 Tagen; sie enthält Anmeldedaten):"
    echo "  $BACKUP_DIR"
    echo "  $KEY_DIR   (AUTH_SECRET_KEY und env-Dateien, getrennt)"
  fi
}

# Erst nach dem vollständigen Einlesen ausführen: das Skript liegt im Checkout, der am Ende verschoben wird.
main "$@"
exit 0
