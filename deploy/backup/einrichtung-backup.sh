#!/usr/bin/env bash
# Einrichtung der automatischen Sicherung (docs/BACKUP.md, deploy/README.md Abschnitt "Backups"). Idempotent.
#   1. Vorabprüfungen (nichts wird verändert, wenn eine fehlschlägt)
#   2. Pakete age, rsync, sqlite3 installieren (nur wenn fehlend)
#   3. Benutzer lxbackup (ohne Passwort, Shell /bin/sh nur für den erzwungenen Befehl), /var/backups/lx-fampad (root:lxbackup, 0750)
#   4. Skript nach /usr/local/sbin/lx-fampad-backup, Empfängerdatei /etc/lx-fampad-backup/recipients.txt (nur ÖFFENTLICHE age-Schlüssel),
#      systemd-Dienst und -Timer (täglich ca. 03:30 Uhr)
#   5. ~lxbackup/.ssh/authorized_keys (root-eigen, vom Benutzer nicht änderbar):
#        restrict,from="<NAS-IP>",command="/usr/bin/rrsync -ro /var/backups/lx-fampad" <Schlüssel des NAS>
#      -> nur lesen, nur dieses Verzeichnis, keine Shell, kein PTY, keine Weiterleitung
#   6. Selbsttest: ein Probelauf der Sicherung, Rechteprüfung (lxbackup kann nur lesen), Abholung über rrsync, Auflistung
# Es werden KEINE privaten Schlüssel erzeugt oder abgelegt. Caddy und das Haupt-Caddyfile (lx-labs.dev) werden NICHT angefasst,
# ebenso wenig sshd_config, lx-fampad, PostgreSQL-Rollen und ntfy.
# Rückfall bei Fehler: in diesem Lauf neu angelegte Dateien/Units/Benutzer werden entfernt, ersetzte Dateien zurückgespielt.
#
# Aufruf auf dem Server als Benutzer lx:
#   sudo bash ~/lx-fampad/deploy/backup/einrichtung-backup.sh --dry-run --age-recipient 'age1…' --nas-pubkey 'ssh-ed25519 AAAA…' --nas-ip 203.0.113.7
#   (Trockenlauf nur prüfen; ohne --dry-run einrichten.)
# Optionen:
#   --age-recipient 'age1…'      öffentlicher age-Schlüssel (mehrfach erlaubt, empfohlen: Hauptschlüssel + Ersatzschlüssel)
#   --age-recipient-file DATEI   Datei mit age1…-Zeilen
#   --age-recipient-config 'age1…'  optional, mehrfach: eigene Empfänger NUR für config-*.tar.age (enthält AUTH_SECRET_KEY); der Dump bleibt für
#                                die --age-recipient-Schlüssel, so trennt der Schlüssel die Daten vom Hauptschlüssel (| --age-recipient-config-file DATEI)
#   --nas-pubkey 'ssh-ed25519 …' öffentlicher SSH-Schlüssel des NAS (eine Zeile)   | --nas-pubkey-file DATEI
#   --nas-ip IP[,IP…]            Adresse(n) des NAS ("from=" im authorized_keys): gültige IPv4/IPv6-Adresse oder CIDR (mindestens /16 bzw. /48)
#   --dry-run                    nur Prüfungen
#   --ohne-systemd               nur für Tests/Container: keine systemctl-Aufrufe, Selbsttest ruft das Skript direkt auf
# Beim ersten Lauf sind age-Empfänger, NAS-Schlüssel und NAS-IP Pflicht; bei Wiederholung dürfen sie fehlen (vorhandene bleiben).
# WICHTIG: In tmux/screen starten. ACHTUNG: Das Skript läuft als root und kopiert Dateien aus dem (für lx schreibbaren) Checkout nach
# /usr/local/sbin und /etc: vorher `git -C ~/lx-fampad log -3 --stat` und `git -C ~/lx-fampad status --short deploy` ansehen.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

BACKUP_USER=lxbackup
OUT_DIR=/var/backups/lx-fampad
CONF_DIR=/etc/lx-fampad-backup
RECIPIENTS="$CONF_DIR/recipients.txt"
RECIPIENTS_CONFIG="$CONF_DIR/recipients-config.txt"
CONF="$CONF_DIR/backup.conf"
BIN=/usr/local/sbin/lx-fampad-backup
UNIT_DIR=/etc/systemd/system
HOME_DIR=/var/lib/lxbackup
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
DB_NAME=lx_fampad
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY=0
NO_SYSTEMD=0
RECIP_ARGS=()
RECIP_CFG_ARGS=()
NAS_KEY_ARG=""
NAS_IP=""

usage() { sed -n '2,/^set -E/{/^set -E/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --ohne-systemd) NO_SYSTEMD=1 ;;
    --age-recipient) [ $# -ge 2 ] || { echo "--age-recipient braucht einen Wert" >&2; exit 2; }; RECIP_ARGS+=("$2"); shift ;;
    --age-recipient-file) [ $# -ge 2 ] || { echo "--age-recipient-file braucht einen Wert" >&2; exit 2; }
      [ -r "$2" ] || { echo "Datei nicht lesbar: $2" >&2; exit 2; }
      while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; case "$l" in ''|'#'*) ;; *) RECIP_ARGS+=("$l") ;; esac; done < "$2"; shift ;;
    --age-recipient-config) [ $# -ge 2 ] || { echo "--age-recipient-config braucht einen Wert" >&2; exit 2; }; RECIP_CFG_ARGS+=("$2"); shift ;;
    --age-recipient-config-file) [ $# -ge 2 ] || { echo "--age-recipient-config-file braucht einen Wert" >&2; exit 2; }
      [ -r "$2" ] || { echo "Datei nicht lesbar: $2" >&2; exit 2; }
      while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; case "$l" in ''|'#'*) ;; *) RECIP_CFG_ARGS+=("$l") ;; esac; done < "$2"; shift ;;
    --nas-pubkey) [ $# -ge 2 ] || { echo "--nas-pubkey braucht einen Wert" >&2; exit 2; }; NAS_KEY_ARG="$2"; shift ;;
    --nas-pubkey-file) [ $# -ge 2 ] || { echo "--nas-pubkey-file braucht einen Wert" >&2; exit 2; }
      [ -r "$2" ] || { echo "Datei nicht lesbar: $2" >&2; exit 2; }
      NAS_KEY_ARG="$(grep -v '^[[:space:]]*#' "$2" | grep -v '^[[:space:]]*$' | head -1 || true)"; shift ;;
    --nas-ip) [ $# -ge 2 ] || { echo "--nas-ip braucht einen Wert" >&2; exit 2; }; NAS_IP="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte mit sudo starten:  sudo bash $0 [Optionen]" >&2
  exit 1
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd /
SRC_SCRIPT="$SELF_DIR/lx-fampad-backup.sh"
SRC_SERVICE="$SELF_DIR/lx-fampad-backup.service"
SRC_TIMER="$SELF_DIR/lx-fampad-backup.timer"

# --- Rückfall-Verwaltung ------------------------------------------------------------------------------------------------------
WORK=""
UNDO=()              # Einträge "restore|<Ziel>|<Sicherung>" oder "remove|<Ziel>"
USER_CREATED=0
DIR_CREATED=""       # Verzeichnisse, die dieser Lauf neu angelegt hat (nur wenn leer wieder entfernt)
TIMER_ENABLED_NOW=0
TIMER_WAR_ENABLED=0  # Zustand des Timers VOR diesem Lauf (der Rückfall setzt nur zurück, was dieser Lauf geändert hat)
TIMER_WAR_AKTIV=0
ARMED=0

aufraeumen() { if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi; return 0; }
zuruecksetzen() {
  trap - ERR INT TERM HUP
  set +e
  ARMED=0
  echo "!!  Fehler: Änderungen dieses Laufs werden zurückgenommen." >&2
  if [ "$TIMER_ENABLED_NOW" = 1 ] && [ "$NO_SYSTEMD" = 0 ]; then
    if [ "$TIMER_WAR_AKTIV" = 0 ]; then systemctl stop lx-fampad-backup.timer >/dev/null 2>&1; fi
    if [ "$TIMER_WAR_ENABLED" = 0 ]; then systemctl disable lx-fampad-backup.timer >/dev/null 2>&1; fi
  fi
  local i e
  for ((i=${#UNDO[@]}-1; i>=0; i--)); do
    e="${UNDO[$i]}"
    case "$e" in
      restore\|*) IFS='|' read -r _ dst bak <<<"$e"; cp -p "$bak" "$dst" ;;
      remove\|*)  IFS='|' read -r _ dst <<<"$e"; rm -f "$dst" ;;
    esac
  done
  if [ "$USER_CREATED" = 1 ]; then
    userdel "$BACKUP_USER" 2>/dev/null; rm -rf "$HOME_DIR"
    # Ablage nicht mit einer verwaisten Gruppen-ID zurücklassen
    if [ -d "$OUT_DIR" ]; then chown -R root:root "$OUT_DIR"; chmod 0700 "$OUT_DIR"; fi
  fi
  for d in $DIR_CREATED; do rmdir "$d" 2>/dev/null; done
  if [ "$NO_SYSTEMD" = 0 ]; then systemctl daemon-reload; fi
  echo "    Zurückgesetzt. Bereits erzeugte Sicherungen unter $OUT_DIR bleiben erhalten. Ursache beheben und das Skript erneut ausführen." >&2
  aufraeumen
  exit 1
}
bei_fehler() {
  local code=$? zeile=${1:-?}
  trap - ERR
  echo "!!  Fehler in Zeile $zeile (Code $code)." >&2
  if [ "$ARMED" = 1 ]; then zuruecksetzen; fi
  aufraeumen
  exit "$code"
}
bei_abbruch() { trap - ERR INT TERM HUP; echo "!!  Abbruch." >&2; if [ "$ARMED" = 1 ]; then zuruecksetzen; fi; aufraeumen; exit 130; }
trap 'bei_fehler $LINENO' ERR
trap bei_abbruch INT TERM HUP
bei_exit() { local rc=$?; trap - EXIT; if [ "$rc" -ne 0 ] && [ "$ARMED" = 1 ]; then zuruecksetzen; fi; aufraeumen; exit "$rc"; }
trap bei_exit EXIT

fehler() { echo "FEHLER: $*" >&2; exit 1; }
info() { echo "    $*"; }

# Datei installieren: put <Quelle> <Ziel> <Modus> <Eigentümer:Gruppe>; sichert eine vorhandene abweichende Datei für den Rückfall
put() {
  local src="$1" dst="$2" mode="$3" own="$4" bak
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then chmod "$mode" "$dst"; chown "$own" "$dst"; return 0; fi
    bak="$WORK/undo-$(printf '%s' "$dst" | sha256sum | cut -c1-16)"
    cp -p "$dst" "$bak"
    cp -p "$dst" "$dst.vor-backup.$STAMP"
    # nur die 3 neuesten Altkopien behalten
    find "$(dirname "$dst")" -maxdepth 1 -name "$(basename "$dst").vor-backup.*" -printf '%f\n' | sort -r | tail -n +4 \
      | while IFS= read -r old; do rm -f -- "$(dirname "$dst")/$old"; done
    UNDO+=("restore|$dst|$bak")
  else
    UNDO+=("remove|$dst")
  fi
  install -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$src" "$dst"
}
mkd() {   # mkd <Pfad> <Modus> <Eigentümer:Gruppe>; merkt sich neu angelegte Verzeichnisse
  if [ ! -d "$1" ]; then DIR_CREATED="$1 $DIR_CREATED"; fi
  install -d -m "$2" -o "${3%%:*}" -g "${3##*:}" "$1"
}

# --- 1. Vorabprüfungen -------------------------------------------------------------------------------------------------------------
echo "==> 1/6 Prüfungen$([ "$DRY" = 1 ] && echo ' (Trockenlauf: es wird nichts verändert)')"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = debian ] || echo "    Hinweis: Debian erwartet, gefunden: ${ID:-unbekannt}"
for b in install sha256sum cmp awk getent useradd usermod runuser ssh-keygen mktemp df; do command -v "$b" >/dev/null || fehler "$b fehlt"; done
if [ "$NO_SYSTEMD" = 0 ]; then
  command -v systemctl >/dev/null && [ -d /run/systemd/system ] || fehler "systemd läuft nicht (in Containern: --ohne-systemd)"
fi
[ -f "$SRC_SCRIPT" ] && [ -f "$SRC_SERVICE" ] && [ -f "$SRC_TIMER" ] || fehler "Dateien in $SELF_DIR fehlen (Repository aktuell? git pull)"
bash -n "$SRC_SCRIPT" || fehler "Syntaxfehler in $SRC_SCRIPT"
info "Skript lx-fampad-backup.sh: sha256 $(sha256sum "$SRC_SCRIPT" | cut -c1-16)…"

# Empfänger: age1… (X25519) – einen privaten Schlüssel nie annehmen
RECIP_RE='^age1[02-9ac-hj-np-z]{58}$'
for r in "${RECIP_ARGS[@]+"${RECIP_ARGS[@]}"}" "${RECIP_CFG_ARGS[@]+"${RECIP_CFG_ARGS[@]}"}"; do
  # die Meldungen geben den übergebenen Wert nie vollständig aus (könnte ein Geheimnis sein)
  if [[ "${r^^}" == *AGE-SECRET-KEY* ]]; then fehler "Das ist ein PRIVATER age-Schlüssel. Der gehört nie auf den Server. Nur den öffentlichen (age1…) übergeben."; fi
  [[ "$r" =~ $RECIP_RE ]] || fehler "Ungültiger age-Empfänger: '${r:0:8}…' (erwartet age1… mit 62 Zeichen, von age-keygen oder 'age-keygen -y')"
done
if [ "${#RECIP_ARGS[@]}" -eq 0 ] && [ ! -s "$RECIPIENTS" ]; then
  fehler "Kein age-Empfänger: --age-recipient 'age1…' angeben (Schlüssel auf dem NAS/PC erzeugen: age-keygen, siehe docs/BACKUP.md)"
fi

# NAS-Schlüssel: genau eine Zeile "<Typ> <Base64> [Kommentar]", ohne Optionen davor; wird neu zusammengesetzt (Kommentar verworfen)
NAS_LINE_KEY=""
if [ -n "$NAS_KEY_ARG" ]; then
  [[ "$NAS_KEY_ARG" != *$'\n'* ]] || fehler "--nas-pubkey muss eine einzelne Zeile sein"
  if [[ "$NAS_KEY_ARG" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\ ([A-Za-z0-9+/]+=*)(\ .*)?$ ]]; then
    NAS_LINE_KEY="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    fehler "Ungültiger SSH-Schlüssel (erwartet 'ssh-ed25519 AAAA… Kommentar', ohne vorangestellte Optionen)"
  fi
  printf '%s\n' "$NAS_LINE_KEY" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1 || fehler "ssh-keygen erkennt den Schlüssel nicht"
  case "$NAS_LINE_KEY" in ssh-rsa*) info "Hinweis: RSA-Schlüssel; ed25519 wäre besser (ssh-keygen -t ed25519).";; esac
fi
# NAS-Adresse: per Parser (nicht per Sperrliste). Ergebnis ist die kanonische Schreibweise; so landet nur Geprüftes im authorized_keys.
# Zulässig: einzelne IPv4/IPv6-Adresse oder Netz (CIDR, keine gesetzten Hostbits) mit Präfix mindestens /16 (IPv4) bzw. /48 (IPv6).
# Abgelehnt: unspezifizierte/Multicast-/IPv4-mapped-Adressen, führende Nullen, Leerzeichen, Anführungszeichen, alles andere.
ip_pruefen() {
  python3 -I -c '
import ipaddress, sys
s = sys.argv[1]
if s != s.strip() or not s or any(c in s for c in " \t\"\x27\\,*?!#") :
    sys.exit("Zeichen nicht erlaubt")
try:
    n = ipaddress.ip_network(s, strict=True)
except ValueError as e:
    sys.exit("keine gültige Adresse/CIDR: %s" % e)
if n.network_address.is_unspecified or n.network_address.is_multicast or n.network_address.is_reserved:
    sys.exit("unspezifizierte/Multicast-/reservierte Adresse")
if n.version == 6 and (n.network_address.ipv4_mapped is not None or n.network_address.sixtofour is not None or n.network_address.teredo is not None):
    sys.exit("IPv4-mapped/6to4/Teredo nicht erlaubt")
mn = 16 if n.version == 4 else 48
if n.prefixlen < mn:
    sys.exit("Netz zu groß (Präfix /%d, erlaubt ab /%d)" % (n.prefixlen, mn))
print(str(n.network_address) if n.num_addresses == 1 else str(n))
' "$1"
}
NAS_FROM=""
if [ -n "$NAS_IP" ]; then
  command -v python3 >/dev/null || fehler "python3 fehlt (wird für die Adressprüfung und von rrsync gebraucht)"
  IFS=',' read -ra IPS <<<"$NAS_IP"
  [ "${#IPS[@]}" -le 4 ] || fehler "höchstens 4 NAS-Adressen"
  for ip in "${IPS[@]}"; do
    CANON="$(ip_pruefen "$ip" 2>&1)" || fehler "Ungültige NAS-Adresse '${ip:0:45}': $CANON"
    NAS_FROM="${NAS_FROM:+$NAS_FROM,}$CANON"
    case "$CANON" in
      127.*|::1) info "Hinweis: $CANON ist eine Loopback-Adresse (nur für Tests sinnvoll)." ;;
      10.*|192.168.*|172.1[6-9].*|172.2?.*|172.3[01].*|fc*|fd*) info "WARNUNG: $CANON ist eine private Adresse: der Server sieht das NAS mit der öffentlichen Adresse des Anschlusses (sofern kein VPN). Passt die Adresse?" ;;
    esac
    if ! ip route get "${CANON%%/*}" >/dev/null 2>&1; then info "WARNUNG: für $CANON gibt es keine Route auf diesem Server (ip route get)."; fi
    if grep -qw "${CANON%%/*}" <<<"$(ip -o addr show)"; then info "WARNUNG: $CANON ist eine Adresse dieses Servers."; fi
  done
  NAS_IP="$NAS_FROM"
fi
if [ ! -s "$AUTH_KEYS" ] || ! grep -q rrsync "$AUTH_KEYS" 2>/dev/null; then
  { [ -n "$NAS_LINE_KEY" ] && [ -n "$NAS_IP" ]; } || fehler "Erster Lauf: --nas-pubkey und --nas-ip sind Pflicht (öffentlicher SSH-Schlüssel und Adresse des NAS)"
fi
if { [ -n "$NAS_LINE_KEY" ] && [ -z "$NAS_IP" ]; } || { [ -z "$NAS_LINE_KEY" ] && [ -n "$NAS_IP" ]; }; then
  fehler "--nas-pubkey und --nas-ip nur zusammen angeben"
fi

RRSYNC="$(command -v rrsync || true)"
[ -n "$RRSYNC" ] || RRSYNC=/usr/bin/rrsync
if [ ! -x "$RRSYNC" ] && [ -x /usr/share/doc/rsync/scripts/rrsync ]; then RRSYNC=/usr/share/doc/rsync/scripts/rrsync; fi
NEED_PKG=()
for p in age rsync sqlite3; do dpkg -s "$p" >/dev/null 2>&1 || NEED_PKG+=("$p"); done
if [ "${#NEED_PKG[@]}" -gt 0 ]; then
  info "Pakete fehlen: ${NEED_PKG[*]} (werden installiert; Candidate: $(for p in "${NEED_PKG[@]}"; do printf '%s=%s ' "$p" "$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"; done))"
  for p in "${NEED_PKG[@]}"; do
    POL="$(apt-cache policy "$p" 2>/dev/null || true)"   # nicht per Pipe an grep -q (SIGPIPE würde unter pipefail als Fehler zählen)
    grep -q 'Candidate: [^(]' <<<"$POL" || fehler "Paket $p ist in den apt-Quellen nicht verfügbar (apt-get update?)"
  done
else
  info "age, rsync, sqlite3 vorhanden."
fi
# rrsync ist ein Python-Skript: ohne python3 läuft der erzwungene Befehl nicht
command -v python3 >/dev/null || fehler "python3 fehlt (rrsync und die Adressprüfung brauchen es): apt install python3-minimal"
if [ "${#NEED_PKG[@]}" -gt 0 ]; then
  # Simulation: zeigt, was apt wirklich installieren würde (auch bei --dry-run, ohne etwas zu ändern)
  SIM="$(apt-get -s install --no-install-recommends "${NEED_PKG[@]}" 2>&1)" || { echo "$SIM" >&2; fehler "apt-get -s install schlägt fehl (apt-Quellen/Sperre?)"; }
  info "apt-Simulation:"; { grep -E '^Inst ' <<<"$SIM" || true; } | sed 's/^/        /'
  if grep -q '^Remv ' <<<"$SIM"; then fehler "apt würde Pakete entfernen, Abbruch: $(grep '^Remv ' <<<"$SIM" | tr '\n' ' ')"; fi
elif [ ! -x "$RRSYNC" ]; then
  fehler "rrsync nicht gefunden (Paket rsync: $(dpkg -s rsync 2>/dev/null | awk '/^Version:/{print $2}'))"
fi
if dpkg -s needrestart >/dev/null 2>&1; then info "needrestart ist installiert: apt läuft mit NEEDRESTART_MODE=l (nur auflisten, keine Dienste neu starten)."; fi
if command -v sshd >/dev/null; then
  SSHD_T="$(sshd -T 2>/dev/null || true)"
  if [ -n "$SSHD_T" ]; then
    grep -qi '^pubkeyauthentication yes' <<<"$SSHD_T" || fehler "sshd: PubkeyAuthentication ist aus"
    AU="$(grep -iE '^(allowusers|allowgroups) ' <<<"$SSHD_T" || true)"
    if [ -n "$AU" ]; then
      if ! grep -qiE "^allowusers .*\\b${BACKUP_USER}\\b" <<<"$AU" && ! grep -qi '^allowgroups' <<<"$AU"; then
        fehler "sshd: AllowUsers erlaubt $BACKUP_USER nicht. sshd_config wird hier nie geändert: $BACKUP_USER dort von Hand ergänzen (z. B. 'AllowUsers lx $BACKUP_USER'), sshd -t, reload, dann neu starten."
      fi
      info "Hinweis: sshd hat AllowUsers/AllowGroups gesetzt – prüfen, dass $BACKUP_USER erlaubt ist: $AU"
    fi
    grep -iE '^authorizedkeysfile ' <<<"$SSHD_T" | grep -q '\.ssh/authorized_keys' || fehler "sshd: AuthorizedKeysFile weicht ab: $(grep -i '^authorizedkeysfile' <<<"$SSHD_T")"
  fi
else
  info "Hinweis: sshd nicht gefunden (Prüfung übersprungen)."
fi
runuser -u postgres -- psql -X -tAq -d "$DB_NAME" -c 'select 1' >/dev/null 2>&1 || fehler "Datenbank $DB_NAME nicht erreichbar (PostgreSQL läuft? als postgres lesbar?)"
info "Datenbank $DB_NAME erreichbar."
[ -f /etc/lx-fampad/env ] || fehler "/etc/lx-fampad/env fehlt (Installation vollständig?)"
grep -q '^AUTH_SECRET_KEY=.\+' /etc/lx-fampad/env || info "WARNUNG: AUTH_SECRET_KEY fehlt in /etc/lx-fampad/env (einrichtung-auth.sh)."
FREE_MB="$(df --output=avail -m "$(dirname "$OUT_DIR")" | tail -1 | tr -d ' ')"
[ "$FREE_MB" -ge 2048 ] || fehler "zu wenig freier Platz in /var/backups: ${FREE_MB} MB (mindestens 2048 MB)"
info "Platz in /var/backups: ${FREE_MB} MB."
if id "$BACKUP_USER" >/dev/null 2>&1; then
  uid="$(id -u "$BACKUP_USER")"
  [ "$uid" -lt 1000 ] || fehler "Benutzer $BACKUP_USER existiert mit UID $uid (kein Systembenutzer); bitte klären"
  info "Benutzer $BACKUP_USER vorhanden (UID $uid)."
else
  info "Benutzer $BACKUP_USER wird angelegt."
fi
info "Caddy, Haupt-Caddyfile und sshd_config bleiben unberührt."

if [ "$DRY" = 1 ]; then
  echo "==> Trockenlauf beendet: alle Prüfungen bestanden. Geplant wäre:"
  echo "    - Pakete: ${NEED_PKG[*]:-keine}"
  echo "    - Benutzer $BACKUP_USER, $OUT_DIR (root:$BACKUP_USER 0750), $CONF_DIR"
  echo "    - $BIN, ${UNIT_DIR}/lx-fampad-backup.{service,timer} (täglich ca. 03:30 Uhr)"
  [ "${#RECIP_ARGS[@]}" -eq 0 ] || echo "    - ${#RECIP_ARGS[@]} age-Empfänger nach $RECIPIENTS"
  [ "${#RECIP_CFG_ARGS[@]}" -eq 0 ] || echo "    - ${#RECIP_CFG_ARGS[@]} eigene Empfänger für die Konfiguration nach $RECIPIENTS_CONFIG"
  [ -z "$NAS_LINE_KEY" ] || echo "    - $AUTH_KEYS: restrict,from=\"$NAS_IP\",command=\"$RRSYNC -ro $OUT_DIR\" $NAS_LINE_KEY"
  echo "    - Selbsttest mit Probelauf"
  exit 0
fi

WORK="$(mktemp -d)"
chmod 0755 "$WORK"
ARMED=1

# --- 2. Pakete ---------------------------------------------------------------------------------------------------------------------------
echo "==> 2/6 Pakete"
if [ "${#NEED_PKG[@]}" -gt 0 ]; then
  # needrestart (falls vorhanden) soll nur auflisten, nie Dienste (sshd, postgresql, lx-labs) neu starten
  env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 apt-get install -y --no-install-recommends "${NEED_PKG[@]}"
else
  info "nichts zu installieren."
fi
{ command -v age >/dev/null && command -v sqlite3 >/dev/null; } || fehler "age/sqlite3 nach der Installation nicht verfügbar"
RRSYNC="$(command -v rrsync || echo /usr/bin/rrsync)"
[ -x "$RRSYNC" ] || fehler "rrsync nicht gefunden"

# --- 3. Benutzer und Verzeichnisse -----------------------------------------------------------------------------------------------------
echo "==> 3/6 Benutzer $BACKUP_USER und Verzeichnisse"
if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$HOME_DIR" --no-create-home --shell /bin/sh --comment "lx-fampad Sicherung abholen" "$BACKUP_USER"
  USER_CREATED=1
fi
# Kein Passwort-Login ('*' statt '!' – ein gesperrtes Konto lehnt sshd je nach PAM-Einstellung auch für Schlüssel ab)
usermod -p '*' -s /bin/sh -d "$HOME_DIR" "$BACKUP_USER"
mkd "$HOME_DIR" 0755 root:root                  # root-eigen: lxbackup kann seinen authorized_keys-Eintrag nicht ändern
mkd "$HOME_DIR/.ssh" 0755 root:root
mkd "$OUT_DIR" 0750 root:"$BACKUP_USER"        # lxbackup: nur lesen/durchsuchen
chown root:"$BACKUP_USER" "$OUT_DIR"; chmod 0750 "$OUT_DIR"
mkd "$CONF_DIR" 0755 root:root
info "$OUT_DIR: $(stat -c '%U:%G %a' "$OUT_DIR")"

# --- 4. Skript, Konfiguration, systemd ----------------------------------------------------------------------------------------------
echo "==> 4/6 Skript, Empfänger, Dienst und Timer"
put "$SRC_SCRIPT" "$BIN" 0755 root:root
if [ "${#RECIP_ARGS[@]}" -gt 0 ]; then
  { echo "# Öffentliche age-Schlüssel (nur Empfänger; privater Schlüssel liegt NIE auf dem Server). Von einrichtung-backup.sh geschrieben."
    printf '%s\n' "${RECIP_ARGS[@]}" | awk '!s[$0]++'; } > "$WORK/recipients.txt"
  put "$WORK/recipients.txt" "$RECIPIENTS" 0644 root:root
fi
grep -qE '^age1[02-9ac-hj-np-z]{58}$' "$RECIPIENTS" || fehler "$RECIPIENTS enthält keinen gültigen Empfänger"
if [ "${#RECIP_CFG_ARGS[@]}" -gt 0 ]; then
  { echo "# Öffentliche age-Schlüssel NUR für config-*.tar.age (enthält AUTH_SECRET_KEY). Zum Aufheben dieser Trennung die Datei löschen."
    printf '%s\n' "${RECIP_CFG_ARGS[@]}" | awk '!s[$0]++'; } > "$WORK/recipients-config.txt"
  put "$WORK/recipients-config.txt" "$RECIPIENTS_CONFIG" 0644 root:root
fi
if [ ! -e "$CONF" ]; then
  cat > "$WORK/backup.conf" <<'EOF'
# Einstellungen für /usr/local/sbin/lx-fampad-backup (Shell-Syntax, nur root darf schreiben). Standardwerte stehen im Skript.
#KEEP=3              # Ordner, die auf dem Server bleiben
#INCLUDE_APK=1       # neueste APK mitsichern (0 = nur latest.json)
#INCLUDE_FILES=0     # /srv/fampad/files als eigenes Archiv mitsichern (kann groß werden)
#MIN_FREE_MB=1024
EOF
  put "$WORK/backup.conf" "$CONF" 0644 root:root
fi
put "$SRC_SERVICE" "$UNIT_DIR/lx-fampad-backup.service" 0644 root:root
put "$SRC_TIMER" "$UNIT_DIR/lx-fampad-backup.timer" 0644 root:root
if [ "$NO_SYSTEMD" = 0 ]; then
  systemctl daemon-reload
  if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify "$UNIT_DIR/lx-fampad-backup.service" "$UNIT_DIR/lx-fampad-backup.timer" || fehler "systemd-analyze verify meldet Fehler"
  fi
  # Zustand merken: der Rückfall nimmt nur zurück, was dieser Lauf geändert hat
  if systemctl is-enabled --quiet lx-fampad-backup.timer 2>/dev/null; then TIMER_WAR_ENABLED=1; fi
  if systemctl is-active --quiet lx-fampad-backup.timer 2>/dev/null; then TIMER_WAR_AKTIV=1; fi
  systemctl enable --now lx-fampad-backup.timer
  TIMER_ENABLED_NOW=1
  info "Timer: $(systemctl list-timers lx-fampad-backup.timer --no-legend 2>/dev/null | head -1)"
else
  info "[ohne systemd] Dienst/Timer nur als Dateien installiert."
fi

# --- 5. SSH-Zugang für das NAS ---------------------------------------------------------------------------------------------------------
echo "==> 5/6 SSH-Zugang für das NAS (nur lesen über rrsync)"
if [ -n "$NAS_LINE_KEY" ]; then
  printf '%s\n' "# lx-fampad Sicherung abholen (von einrichtung-backup.sh geschrieben; nur lesen, nur $OUT_DIR)" \
    "restrict,from=\"$NAS_IP\",command=\"$RRSYNC -ro $OUT_DIR\" $NAS_LINE_KEY lx-fampad-backup-nas" > "$WORK/authorized_keys"
  put "$WORK/authorized_keys" "$AUTH_KEYS" 0644 root:root
  ssh-keygen -l -f "$AUTH_KEYS" >/dev/null 2>&1 || fehler "authorized_keys wird von ssh-keygen nicht gelesen"
  info "authorized_keys geschrieben: $(tail -1 "$AUTH_KEYS" | cut -c1-110)…"
else
  info "unverändert (kein neuer NAS-Schlüssel angegeben)."
fi
[ "$(stat -c '%U %a' "$AUTH_KEYS")" = "root 644" ] || fehler "authorized_keys: Besitzer/Rechte falsch"

# --- 6. Selbsttest ---------------------------------------------------------------------------------------------------------------------------
echo "==> 6/6 Selbsttest: Probelauf der Sicherung"
if [ "$NO_SYSTEMD" = 0 ]; then
  systemctl start lx-fampad-backup.service || { journalctl -u lx-fampad-backup -n 30 --no-pager >&2; fehler "Probelauf fehlgeschlagen (Meldungen oben; journalctl -u lx-fampad-backup)"; }
else
  "$BIN" || fehler "Probelauf fehlgeschlagen"
fi
LATEST="$(cat "$OUT_DIR/LATEST")"
[[ "$LATEST" =~ ^[0-9]{8}-[0-9]{6}$ ]] || fehler "LATEST ungültig"
info "Ergebnis in $OUT_DIR/$LATEST:"
find "$OUT_DIR/$LATEST" -type f -printf "%M %u:%g %s %f\n" | sed 's/^/        /'
sed 's/^/        /' "$OUT_DIR/status"
( cd "$OUT_DIR/$LATEST" && sha256sum -c --strict --quiet SHA256SUMS ) || fehler "Prüfsummen stimmen nicht"
info "Prüfsummen ok."

info "Rechteprüfung als $BACKUP_USER:"
as_bu() { runuser -u "$BACKUP_USER" -- "$@"; }
as_bu cat "$OUT_DIR/$LATEST/SHA256SUMS" >/dev/null || fehler "$BACKUP_USER kann die Sicherung nicht lesen"
if as_bu sh -c "( touch '$OUT_DIR/probe' ) 2>/dev/null"; then rm -f "$OUT_DIR/probe"; fehler "$BACKUP_USER darf in $OUT_DIR schreiben"; fi
if as_bu sh -c "touch '$OUT_DIR/$LATEST/probe' 2>/dev/null"; then rm -f "$OUT_DIR/$LATEST/probe"; fehler "$BACKUP_USER darf im Sicherungsordner schreiben"; fi
# Löschversuch an einer Probe-Datei (nie an einer echten Sicherungsdatei)
PROBE="$OUT_DIR/$LATEST/.rechteprobe"
install -m 0640 -o root -g "$BACKUP_USER" /dev/null "$PROBE"
as_bu sh -c "rm -f '$PROBE' 2>/dev/null; chmod 0777 '$PROBE' 2>/dev/null; true"
if [ ! -e "$PROBE" ] || [ "$(stat -c %a "$PROBE")" != 640 ]; then rm -f "$PROBE"; fehler "$BACKUP_USER konnte eine Datei löschen oder ändern"; fi
rm -f "$PROBE"
if as_bu cat /etc/lx-fampad/env >/dev/null 2>&1; then fehler "$BACKUP_USER kann /etc/lx-fampad/env lesen"; fi
if as_bu cat /etc/shadow >/dev/null 2>&1; then fehler "$BACKUP_USER kann /etc/shadow lesen"; fi
if as_bu sh -c "( echo x >> '$AUTH_KEYS' ) 2>/dev/null"; then fehler "$BACKUP_USER darf seinen authorized_keys ändern"; fi
info "ok: lesen nur in $OUT_DIR; kein Schreiben, kein Zugriff auf Geheimnisse."

info "Abholung über rrsync (ohne SSH, nur die erzwungene Richtlinie):"
cat > "$WORK/fakessh" <<EOF
#!/bin/sh
# ersetzt ssh: ruft den erzwungenen Befehl so auf, wie sshd es täte
shift
SSH_ORIGINAL_COMMAND="\$*"
export SSH_ORIGINAL_COMMAND
exec $RRSYNC -ro $OUT_DIR
EOF
chmod 0755 "$WORK/fakessh"
PULL="$WORK/pull"; mkdir -m 0700 "$PULL"; chown "$BACKUP_USER" "$PULL"
# Dieselben Optionen wie nas/lx-fampad-pull.sh (synchron halten): der Selbsttest soll zeigen, dass rrsync sie wirklich akzeptiert
PULL_OPTS=(-rt --no-links --no-perms --no-owner --no-group --no-devices --no-specials --max-size=2G
  --exclude='.geprueft' --exclude='.partial' --exclude='.tmp-*'
  --include='/[0-9]*-[0-9]*/' --include='/[0-9]*-[0-9]*/db-*.dump.age' --include='/[0-9]*-[0-9]*/config-*.tar.age'
  --include='/[0-9]*-[0-9]*/files-*.tar.age' --include='/[0-9]*-[0-9]*/SHA256SUMS' --include='/status' --include='/LATEST' --exclude='*')
as_bu rsync "${PULL_OPTS[@]}" --stats -e "$WORK/fakessh" "x:/" "$PULL/" >"$WORK/pull.out" 2>&1 || { cat "$WORK/pull.out" >&2; fehler "Abholung über rrsync mit den Pull-Optionen fehlgeschlagen"; }
[ -f "$PULL/$LATEST/SHA256SUMS" ] || fehler "Abholung lieferte den Sicherungsordner nicht"
( cd "$PULL/$LATEST" && as_bu sha256sum -c --strict --quiet SHA256SUMS ) || fehler "abgeholte Dateien weichen ab"
if as_bu rsync "${PULL_OPTS[@]}" -e "$WORK/fakessh" "x:/../../etc/passwd" "$PULL/" >/dev/null 2>&1; then fehler "rrsync lässt Pfade außerhalb des Verzeichnisses zu"; fi
echo probe > "$PULL/probe-upload"
if as_bu rsync -rt -e "$WORK/fakessh" "$PULL/probe-upload" "x:/probe-upload" >/dev/null 2>&1; then fehler "rrsync erlaubt Hochladen (nicht read-only)"; fi
[ ! -e "$OUT_DIR/probe-upload" ] || fehler "Upload ist angekommen"
info "ok: Abholung funktioniert, Pfade außerhalb und Hochladen werden abgelehnt."

ARMED=0
echo
echo "Fertig. Nächste Schritte:"
echo "  - Vom NAS testen:  rsync -a -e 'ssh -i <Schlüssel>' $BACKUP_USER@<Server>:/ <Zielordner>/   (docs/BACKUP.md, Abschnitt NAS einrichten)"
echo
echo "!!  WICHTIG: Der Server kann die Sicherung NICHT entschlüsseln und prüft nicht, ob der private Schlüssel zum Empfänger passt."
echo "!!  Teste noch HEUTE mit dem privaten age-Schlüssel (am besten auf deinem PC mit einer vom NAS geholten Sicherung):"
echo "!!    deploy/backup/wiederherstellung-test.sh --identity <schlüssel> --run-dir <ordner>   (docs/WIEDERHERSTELLUNG.md)"
echo "!!  Ohne bestandenen Test ist die Sicherung ungeprüft; ein Tippfehler im Schlüssel macht alles unlesbar."
echo
echo "  - Status: sudo cat $OUT_DIR/status;  Timer: systemctl list-timers lx-fampad-backup.timer;  Log: journalctl -u lx-fampad-backup"
echo "  - Rückbau: docs/BACKUP.md, Abschnitt Rückbau"
