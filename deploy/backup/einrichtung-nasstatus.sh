#!/usr/bin/env bash
# Einrichtung des Rückkanals "Status vom NAS" für die Betreiber-Ansicht (Betrieb Paket 3; einmaliger root-Schritt, idempotent):
# das NAS meldet nach jeder Abholung und jedem Wiederherstellungstest eine kleine, validierte Statusdatei. Der Server hält dafür KEINE Zugangsdaten zum NAS.
#   1. Benutzer lxnasstatus (ohne Passwort, Shell /bin/sh nur für den erzwungenen Befehl; kein Zugriff auf Sicherungen, Konfiguration oder die Statusdatei der Sicherung)
#   2. Ordner /var/lib/lx-fampad-nasstatus (lxnasstatus:lx-fampad, 2750): nur lxnasstatus schreibt, der Dienst lx-fampad liest (Datei nas.status, 0640)
#   3. Befehl /usr/local/sbin/lx-fampad-nasstatus-empfang (root:root 0755): liest von stdin höchstens 4 KB, prüft jede Zeile (Whitelist der Schlüssel, Zahlen/Zeiten/ok-Codes) und
#      schreibt atomar nas.status; alles andere wird abgelehnt
#   4. ~lxnasstatus/.ssh/authorized_keys (root-eigen, vom Benutzer nicht änderbar):
#        restrict,from="<NAS-IP>",command="/usr/local/sbin/lx-fampad-nasstatus-empfang" <ZWEITER Schlüssel des NAS>
#      -> nur dieser Befehl, keine Shell, kein PTY, keine Weiterleitung, nur von der NAS-Adresse
#   5. Selbsttest in einem Wegwerf-Ordner (gültige und ungültige Eingaben, Rechte); die echte Datei nas.status wird dabei nie angelegt oder verändert
# Es werden KEINE privaten Schlüssel erzeugt oder abgelegt. Caddy und das Haupt-Caddyfile (lx-labs.dev), sshd_config, lx-fampad, PostgreSQL, ntfy und die Sicherungen
# werden NICHT angefasst. Der Rückfall bei einem Fehler nimmt nur zurück, was dieser Lauf neu angelegt oder ersetzt hat.
#
# Aufruf auf dem Server als Benutzer lx (Anleitung: docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 11):
#   sudo bash ~/lx-fampad/deploy/backup/einrichtung-nasstatus.sh --dry-run --nas-pubkey 'ssh-ed25519 AAAA…' --nas-ip 203.0.113.7
#   (Trockenlauf nur prüfen; ohne --dry-run einrichten.)
# Optionen:
#   --nas-pubkey 'ssh-ed25519 …'   öffentlicher Schlüssel des NAS für die Statusmeldung (eine Zeile) | --nas-pubkey-file DATEI. NICHT derselbe wie für die Abholung.
#   --nas-ip IP[,IP…]              Adresse(n) des NAS ("from=" im authorized_keys): gültige IPv4/IPv6-Adresse oder CIDR (mindestens /16 bzw. /48)
#   --dry-run                      nur Prüfungen
# Beim ersten Lauf sind NAS-Schlüssel und NAS-IP Pflicht; bei Wiederholung dürfen sie fehlen (der vorhandene Eintrag bleibt).
# ACHTUNG: Das Skript läuft als root und kopiert eine Datei aus dem (für lx schreibbaren) Checkout nach /usr/local/sbin: vorher
# `git -C ~/lx-fampad log -3 --stat` und `git -C ~/lx-fampad status --short deploy` ansehen.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

STATUS_USER=lxnasstatus
SERVICE_GROUP=lx-fampad
SERVICE_USER=lx-fampad
STATUS_DIR=/var/lib/lx-fampad-nasstatus
HOME_DIR=/var/lib/lxnasstatus
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
BIN=/usr/local/sbin/lx-fampad-nasstatus-empfang
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY=0
NAS_KEY_ARG=""
NAS_IP=""

usage() { sed -n '2,/^set -E/{/^set -E/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
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
SRC_BIN="$SELF_DIR/lx-fampad-nasstatus-empfang.sh"

# --- Rückfall-Verwaltung ------------------------------------------------------------------------------------------------------
WORK=""
UNDO=()              # Einträge "restore|<Ziel>|<Sicherung>" oder "remove|<Ziel>"
USER_CREATED=0
DIR_CREATED=""
ARMED=0

aufraeumen() { if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi; return 0; }
zuruecksetzen() {
  trap - ERR INT TERM HUP
  set +e
  ARMED=0
  echo "!!  Fehler: Änderungen dieses Laufs werden zurückgenommen." >&2
  local i e
  for ((i=${#UNDO[@]}-1; i>=0; i--)); do
    e="${UNDO[$i]}"
    case "$e" in
      restore\|*) IFS='|' read -r _ dst bak <<<"$e"; cp -p "$bak" "$dst" ;;
      remove\|*)  IFS='|' read -r _ dst <<<"$e"; rm -f "$dst" ;;
    esac
  done
  if [ "$USER_CREATED" = 1 ]; then userdel "$STATUS_USER" 2>/dev/null; rm -rf "$HOME_DIR"; fi
  for d in $DIR_CREATED; do rmdir "$d" 2>/dev/null; done
  echo "    Zurückgesetzt. Ursache beheben und das Skript erneut ausführen." >&2
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
    cp -p "$dst" "$dst.vor-nasstatus.$STAMP"
    find "$(dirname "$dst")" -maxdepth 1 -name "$(basename "$dst").vor-nasstatus.*" -printf '%f\n' | sort -r | tail -n +4 \
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
echo "==> 1/4 Prüfungen$([ "$DRY" = 1 ] && echo ' (Trockenlauf: es wird nichts verändert)')"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = debian ] || echo "    Hinweis: Debian erwartet, gefunden: ${ID:-unbekannt}"
for b in install sha256sum cmp getent useradd usermod runuser ssh-keygen mktemp stat head tr date python3; do command -v "$b" >/dev/null || fehler "$b fehlt"; done
[ -f "$SRC_BIN" ] || fehler "Datei $SRC_BIN fehlt (Repository aktuell? git pull)"
bash -n "$SRC_BIN" || fehler "Syntaxfehler in $SRC_BIN"
info "Befehl lx-fampad-nasstatus-empfang.sh: sha256 $(sha256sum "$SRC_BIN" | cut -c1-16)…"
getent group "$SERVICE_GROUP" >/dev/null || fehler "Gruppe $SERVICE_GROUP fehlt (der Dienst lx-fampad ist noch nicht eingerichtet)"
for p in "$STATUS_DIR" "$HOME_DIR"; do
  if [ -L "$p" ]; then fehler "$p ist ein Symlink, Abbruch."; fi
  if [ -e "$p" ] && [ ! -d "$p" ]; then fehler "$p ist kein Ordner."; fi
done

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
  # Der Statuskanal braucht einen EIGENEN Schlüssel: der der Abholung darf nicht doppelt verwendet werden
  if [ -r /var/lib/lxbackup/.ssh/authorized_keys ] && grep -qF "${NAS_LINE_KEY#* }" /var/lib/lxbackup/.ssh/authorized_keys; then
    fehler "Das ist der Schlüssel der Abholung (lxbackup). Für die Statusmeldung einen eigenen, zweiten Schlüssel erzeugen (ssh-keygen -t ed25519 -f ~/.ssh/lx-fampad-status)."
  fi
fi
# NAS-Adresse: per Parser (nicht per Sperrliste); Ergebnis ist die kanonische Schreibweise, so landet nur Geprüftes im authorized_keys.
# Zulässig: einzelne IPv4/IPv6-Adresse oder Netz (CIDR, keine gesetzten Hostbits) mit Präfix mindestens /16 (IPv4) bzw. /48 (IPv6).
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
  IFS=',' read -ra IPS <<<"$NAS_IP"
  [ "${#IPS[@]}" -le 4 ] || fehler "höchstens 4 NAS-Adressen"
  for ip in "${IPS[@]}"; do
    CANON="$(ip_pruefen "$ip" 2>&1)" || fehler "Ungültige NAS-Adresse '${ip:0:45}': $CANON"
    NAS_FROM="${NAS_FROM:+$NAS_FROM,}$CANON"
    case "$CANON" in
      127.*|::1) info "Hinweis: $CANON ist eine Loopback-Adresse (nur für Tests sinnvoll)." ;;
      10.*|192.168.*|172.1[6-9].*|172.2?.*|172.3[01].*|fc*|fd*) info "WARNUNG: $CANON ist eine private Adresse: der Server sieht das NAS mit der öffentlichen Adresse des Anschlusses (sofern kein VPN). Passt die Adresse?" ;;
    esac
  done
  NAS_IP="$NAS_FROM"
fi
if [ ! -s "$AUTH_KEYS" ] || ! grep -q "$BIN" "$AUTH_KEYS" 2>/dev/null; then
  { [ -n "$NAS_LINE_KEY" ] && [ -n "$NAS_IP" ]; } || fehler "Erster Lauf: --nas-pubkey und --nas-ip sind Pflicht (öffentlicher SSH-Schlüssel und Adresse des NAS)"
fi
if { [ -n "$NAS_LINE_KEY" ] && [ -z "$NAS_IP" ]; } || { [ -z "$NAS_LINE_KEY" ] && [ -n "$NAS_IP" ]; }; then
  fehler "--nas-pubkey und --nas-ip nur zusammen angeben"
fi
if command -v sshd >/dev/null; then
  SSHD_T="$(sshd -T 2>/dev/null || true)"
  if [ -n "$SSHD_T" ]; then
    grep -qi '^pubkeyauthentication yes' <<<"$SSHD_T" || fehler "sshd: PubkeyAuthentication ist aus"
    AU="$(grep -iE '^(allowusers|allowgroups) ' <<<"$SSHD_T" || true)"
    if [ -n "$AU" ]; then
      if ! grep -qiE "^allowusers .*\\b${STATUS_USER}\\b" <<<"$AU" && ! grep -qi '^allowgroups' <<<"$AU"; then
        fehler "sshd: AllowUsers erlaubt $STATUS_USER nicht. sshd_config wird hier nie geändert: $STATUS_USER dort von Hand ergänzen (z. B. 'AllowUsers lx lxbackup $STATUS_USER'), sshd -t, reload, dann neu starten."
      fi
      info "Hinweis: sshd hat AllowUsers/AllowGroups gesetzt – prüfen, dass $STATUS_USER erlaubt ist: $AU"
    fi
    grep -iE '^authorizedkeysfile ' <<<"$SSHD_T" | grep -q '\.ssh/authorized_keys' || fehler "sshd: AuthorizedKeysFile weicht ab: $(grep -i '^authorizedkeysfile' <<<"$SSHD_T")"
  fi
else
  info "Hinweis: sshd nicht gefunden (Prüfung übersprungen)."
fi
if id "$STATUS_USER" >/dev/null 2>&1; then
  uid="$(id -u "$STATUS_USER")"
  [ "$uid" -lt 1000 ] || fehler "Benutzer $STATUS_USER existiert mit UID $uid (kein Systembenutzer); bitte klären"
  info "Benutzer $STATUS_USER vorhanden (UID $uid)."
else
  info "Benutzer $STATUS_USER wird angelegt."
fi
info "Caddy, Haupt-Caddyfile, sshd_config, die Sicherungen und die Statusdatei der Sicherung bleiben unberührt."

if [ "$DRY" = 1 ]; then
  echo "==> Trockenlauf beendet: alle Prüfungen bestanden. Geplant wäre:"
  echo "    - Benutzer $STATUS_USER, Ordner $STATUS_DIR ($STATUS_USER:$SERVICE_GROUP 2750), $HOME_DIR (root-eigen)"
  echo "    - $BIN (root:root 0755)"
  [ -z "$NAS_LINE_KEY" ] || echo "    - $AUTH_KEYS: restrict,from=\"$NAS_IP\",command=\"$BIN\" $NAS_LINE_KEY"
  echo "    - Selbsttest in einem Wegwerf-Ordner"
  exit 0
fi

WORK="$(mktemp -d)"
chmod 0755 "$WORK"
ARMED=1

# --- 2. Benutzer und Ordner ---------------------------------------------------------------------------------------------------------
echo "==> 2/4 Benutzer $STATUS_USER und Ordner"
if ! id "$STATUS_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$HOME_DIR" --no-create-home --shell /bin/sh --comment "lx-fampad Status vom NAS" "$STATUS_USER"
  USER_CREATED=1
fi
# Kein Passwort-Login ('*' statt '!': ein gesperrtes Konto lehnt sshd je nach PAM-Einstellung auch für Schlüssel ab)
usermod -p '*' -s /bin/sh -d "$HOME_DIR" "$STATUS_USER"
mkd "$HOME_DIR" 0755 root:root                  # root-eigen: der Benutzer kann seinen authorized_keys-Eintrag nicht ändern
mkd "$HOME_DIR/.ssh" 0755 root:root
# setgid: neue Dateien gehören der Gruppe lx-fampad (der Dienst liest), nur $STATUS_USER schreibt
mkd "$STATUS_DIR" 2750 "$STATUS_USER:$SERVICE_GROUP"
chown "$STATUS_USER:$SERVICE_GROUP" "$STATUS_DIR"; chmod 2750 "$STATUS_DIR"
info "$STATUS_DIR: $(stat -c '%U:%G %a' "$STATUS_DIR")"

# --- 3. Befehl und SSH-Zugang -------------------------------------------------------------------------------------------------------
echo "==> 3/4 Befehl und SSH-Zugang für das NAS (nur dieser eine Befehl)"
put "$SRC_BIN" "$BIN" 0755 root:root
if [ -n "$NAS_LINE_KEY" ]; then
  printf '%s\n' "# lx-fampad Status vom NAS (von einrichtung-nasstatus.sh geschrieben; nur der Befehl unten, nur von der NAS-Adresse)" \
    "restrict,from=\"$NAS_IP\",command=\"$BIN\" $NAS_LINE_KEY lx-fampad-nasstatus-nas" > "$WORK/authorized_keys"
  put "$WORK/authorized_keys" "$AUTH_KEYS" 0644 root:root
  ssh-keygen -l -f "$AUTH_KEYS" >/dev/null 2>&1 || fehler "authorized_keys wird von ssh-keygen nicht gelesen"
  info "authorized_keys geschrieben: $(tail -1 "$AUTH_KEYS" | cut -c1-110)…"
else
  info "unverändert (kein neuer NAS-Schlüssel angegeben)."
fi
[ "$(stat -c '%U %a' "$AUTH_KEYS")" = "root 644" ] || fehler "authorized_keys: Besitzer/Rechte falsch"

# --- 4. Selbsttest ---------------------------------------------------------------------------------------------------------------------------
echo "==> 4/4 Selbsttest (Wegwerf-Ordner, die echte Statusdatei bleibt unberührt)"
as_su() { runuser -u "$STATUS_USER" -- "$@"; }
T="$WORK/test"
mkdir -m 2750 "$T"; chown "$STATUS_USER:$SERVICE_GROUP" "$T"; chmod 2750 "$T"
NOW="$(date -u +%s)"
GUT="nas_format=1
pull_result=ok
pull_run_epoch=$NOW
pull_success_epoch=$NOW
pull_count=14
restore_result=ok
restore_run_epoch=$NOW
restore_success_epoch=$NOW
restore_config_check=nein"
empfang() { printf '%s\n' "$1" | as_su env LX_NASSTATUS_DIR="$T" SSH_ORIGINAL_COMMAND='cat /etc/shadow' "$BIN"; }
empfang "$GUT" >/dev/null || fehler "gültige Beispieldatei wurde abgelehnt"
[ "$(stat -c '%U:%G %a' "$T/nas.status")" = "$STATUS_USER:$SERVICE_GROUP 640" ] || fehler "Rechte der Beispieldatei falsch: $(stat -c '%U:%G %a' "$T/nas.status")"
grep -q '^received_epoch=' "$T/nas.status" || fehler "received_epoch fehlt"
cp "$T/nas.status" "$WORK/vorher"
ablehnen() {   # $1 = Beschreibung, $2 = Eingabe
  if empfang "$2" >/dev/null 2>&1; then fehler "Selbsttest: '$1' wurde angenommen"; fi
  cmp -s "$T/nas.status" "$WORK/vorher" || fehler "Selbsttest: '$1' hat die Datei verändert"
}
ablehnen "unbekannter Schlüssel" "$GUT
evil=1"
ablehnen "doppelter Schlüssel" "$GUT
pull_count=3"
ablehnen "Befehlszeichen im Wert" "pull_result=ok
restore_config_check=ja;id"
ablehnen "Zeit in der Zukunft" "pull_result=ok
pull_success_epoch=$((NOW + 100000))"
ablehnen "ohne Ergebnis" "pull_count=3"
if as_su sh -c "head -c 5000 /dev/zero | tr '\\0' a | env LX_NASSTATUS_DIR='$T' '$BIN'" >/dev/null 2>&1; then fehler "Selbsttest: mehr als 4 KB wurden angenommen"; fi
cmp -s "$T/nas.status" "$WORK/vorher" || fehler "Selbsttest: zu große Eingabe hat die Datei verändert"
info "ok: gültige Dateien angenommen, ungültige abgelehnt (Datei blieb jeweils unverändert)."
info "Rechteprüfung als $STATUS_USER:"
as_su sh -c "touch '$STATUS_DIR/.rechteprobe' && rm -f '$STATUS_DIR/.rechteprobe'" || fehler "$STATUS_USER kann in $STATUS_DIR nicht schreiben"
for verboten in /var/lib/lx-fampad-status /var/backups/lx-fampad /etc/lx-fampad /srv/fampad; do
  if [ -d "$verboten" ] && as_su sh -c "touch '$verboten/.rechteprobe' 2>/dev/null"; then rm -f "$verboten/.rechteprobe"; fehler "$STATUS_USER darf in $verboten schreiben"; fi
done
if as_su cat /etc/lx-fampad/env >/dev/null 2>&1; then fehler "$STATUS_USER kann /etc/lx-fampad/env lesen"; fi
if as_su cat /etc/shadow >/dev/null 2>&1; then fehler "$STATUS_USER kann /etc/shadow lesen"; fi
if as_su sh -c "( echo x >> '$AUTH_KEYS' ) 2>/dev/null"; then fehler "$STATUS_USER darf seinen authorized_keys ändern"; fi
if as_su sh -c "( echo x >> '$BIN' ) 2>/dev/null"; then fehler "$STATUS_USER darf den Befehl ändern"; fi
if runuser -u "$SERVICE_USER" -- sh -c "touch '$STATUS_DIR/.rechteprobe' 2>/dev/null" 2>/dev/null; then rm -f "$STATUS_DIR/.rechteprobe"; fehler "der Dienst $SERVICE_USER darf in $STATUS_DIR schreiben (soll nur lesen)"; fi
info "ok: $STATUS_USER schreibt nur in $STATUS_DIR, keine Geheimnisse lesbar, Befehl und Schlüsseleintrag unveränderlich; der Dienst liest nur."

ARMED=0
echo
echo "Fertig. Nächste Schritte (auf dem NAS, docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 11):"
echo "  - die Skripte lx-fampad-nasstatus.sh, lx-fampad-pull.sh und lx-fampad-restoretest.sh aus deinem Git-Checkout auf das NAS bringen"
echo "  - bash lx-fampad-nasstatus.sh --print   (Vorschau), danach bash lx-fampad-nasstatus.sh   (sendet)"
echo "  - Server: sudo cat $STATUS_DIR/nas.status    (erst nach der ersten Meldung vorhanden)"
echo "  - Rückbau: docs/BACKUP.md, Abschnitt Rückbau"
