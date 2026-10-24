#!/usr/bin/env bash
# Server-Neuinstallation von lx-fampad auf einem frischen Debian-13-VPS (docs/NEUINSTALLATION.md).
# Wiederholbar und idempotent: jede Phase prüft, was schon da ist, und ändert nur Fehlendes. Ohne --sicherung entsteht eine
# leere Installation, mit --sicherung wird Datenbank und Konfiguration aus einer age-verschlüsselten Sicherung zurückgespielt.
#
# IMMER zuerst mit --dry-run:  sudo bash bootstrap-server.sh --dry-run [Optionen]   (liest nur, ändert nichts, Klartext der Sicherung wird nie angefasst)
#
# Aufruf (root, am besten in tmux):
#   sudo bash bootstrap-server.sh [--dry-run] [--params DATEI] [--phase a,b | --ab PHASE]
#        [--sicherung ORDNER (--identity-stdin | --identity-datei DATEI [--identity-datei-loeschen])] [Weitere Optionen]
#
# Phasen (in dieser Reihenfolge; jede endet mit Prüfpunkten):
#   pruefen         nur lesen: Debian 13, Platz, Netz, Parameter, Sicherung, DNS, vorhandener Zustand
#   pakete          apt-Pakete, PostgreSQL 17, Node.js (NodeSource, Version und Schlüssel gepinnt), Prüfung der Sicherung mit dem Schlüssel
#   system          Benutzer (lx, lx-fampad), Verzeichnisse, journald (7 Tage), sudo-Regel, optional CI-Schlüssel und Swap
#   code            Git-Checkout (Deploy-Key, GitHub-Host-Schlüssel gepinnt; pausiert, bis der Deploy-Key eingetragen ist)
#   konfiguration   /etc/lx-fampad/env (neu: Zufallspasswort; Sicherung: aus dem Archiv über ein Staging im Arbeitsspeicher, gezielt kopiert), assetlinks.json
#   datenbank       Rollen (Laufzeit nur DML, Migrationsrolle), Datenbank, ggf. pg_restore, einrichtung-auth.sh (AUTH_SECRET_KEY, Einheiten)
#   anwendung       Server bauen und starten (deploy.sh), Migrationen, Wetter-Einheit (wird nur auf Wunsch gestartet)
#   ntfy            ntfy installieren und härten, Benutzer/Token/Rechte (oder aus der Sicherung), env-Einträge
#   caddy           Caddy (offizielles Repository, Version und Schlüssel gepinnt) und NUR /etc/caddy/conf.d/*.caddy; nur wenn DNS stimmt
#   sicherung       tägliche Sicherung und Statusdatei (einrichtung-backup.sh / einrichtung-status.sh)
#   pruefung        Abschlussprüfung und Liste dessen, was du noch selbst tun musst
#
# Optionen:
#   --dry-run                  nur prüfen und anzeigen
#   --params DATEI             Parameterdatei (SCHLÜSSEL=Wert, nur Öffentliches; Vorlage: parameter.beispiel). Nie Geheimnisse hineinschreiben.
#   --phase a,b                nur diese Phasen   |   --ab PHASE   ab dieser Phase bis zum Ende
#   --sicherung ORDNER         Sicherungsordner (db-*.dump.age, config-*.tar.age, SHA256SUMS), z. B. vom NAS
#   --identity-stdin           privaten age-Schlüssel von stdin lesen (Einfügen, dann Strg+D; Eingabe unsichtbar)
#   --identity-datei DATEI     privaten age-Schlüssel aus dieser (temporären) Datei lesen; wird nie kopiert
#   --identity-datei-loeschen  die Schlüsseldatei nach dem Einlesen sofort überschreiben und löschen (nur Dateien unter /dev/shm, /run/lxfampad oder /run/user, ohne .., root-eigen, kein Symlink)
#   --swap-ok                  trotz aktivem Swap fortfahren (sonst Abbruch vor dem Einlesen des Schlüssels: Swap könnte ihn auf die Platte auslagern)
#   --konfiguration-ersetzen   eine vorhandene, abweichende /etc/lx-fampad/env durch die der Sicherung ersetzen (Kopie bleibt)
#   --datenbank-ersetzen       eine vorhandene, NICHT leere Datenbank lx_fampad durch die Sicherung ersetzen (die alte wird umbenannt, nicht gelöscht)
#   --wetter-starten           den Wetter-Dienst einschalten (nur, wenn der alte Server aus ist: Netatmo-Token!)
#   --dns-pruefung-ueberspringen  Caddy ohne DNS-Prüfung behandeln (nur Container-Tests, nur zusammen mit --ohne-systemd, sonst Exit 2)
#   --lx-anlegen               den Benutzer lx anlegen, falls er fehlt (ohne Passwort; Schlüssel aus LX_SSH_PUBKEY)
#   --yes                      Rückfragen mit "ja" beantworten (nur zusammen mit den ausdrücklichen --...-ersetzen-Optionen sinnvoll)
#   --ohne-systemd             NUR für Container-Tests (test-integration/): kein systemd-Zwang, kein systemd-analyze, Caddy-Site-Dateien werden nur geprüft,
#                              nie gegen die echten Internet-Adressen betrieben; systemctl wird trotzdem aufgerufen (im Test eine Attrappe)
# Exit-Codes: 0 fertig (ggf. mit Hinweisen "OFFEN"), 1 Fehler, 2 falscher Aufruf, 10 Pause (ein Schritt von dir ist nötig, danach denselben Befehl wiederholen).
#
# Sicherheitsregeln dieses Skripts: kein Geheimnis in Argumenten, Log oder Repository (Passwörter entstehen auf dem Server, der private
# age-Schlüssel liegt nur im Arbeitsspeicher und wird nie abgelegt); das Haupt-Caddyfile von lx-labs.dev wird nie überschrieben (nur
# /etc/caddy/conf.d/*.caddy; die Importzeile nur in einem unveränderten Standard-Caddyfile); kein curl|bash, alle Quellen mit Schlüssel- oder
# Prüfsummen-Pin. EHRLICH: Dem Inhalt einer Sicherung darf nicht blind vertraut werden (jeder, der den öffentlichen age-Schlüssel kennt, kann ein
# gültiges Archiv erzeugen; SHA256SUMS schützt nur vor Übertragungsfehlern). Deshalb: Archive und SHA256SUMS werden einmal in ein root-eigenes
# Arbeitsverzeichnis kopiert und nur dort geprüft/benutzt; entpackt wird zuerst in ein Staging (--no-same-owner --no-same-permissions) und dann gezielt
# kopiert (nur reguläre Dateien, feste Modi); nichts aus der Sicherung wird als root geladen oder ausgeführt (backup.conf kommt aus den Parametern,
# von den Backup-Einstellungen wird nur recipients*.txt nach Formatprüfung übernommen); der Dump läuft als Migrationsrolle, nie als Superuser, kann
# aber SQL enthalten. Echte Echtheit beweist erst eine Signatur von SHA256SUMS (offener Punkt, docs/NEUINSTALLATION.md).
# Der private Schlüssel wird nach der letzten Entschlüsselung verworfen (vor einem Swap); ein vorhandener Swap bricht vor dem Einlesen ab (--swap-ok).
#
# Das gesamte Skript steht in Funktionen: bash liest es vollständig, bevor es etwas ausführt (der Git-Checkout darf es während des Laufs ersetzen).
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
umask 022

# --- Festwerte und Pins ---------------------------------------------------------------------------------------------------------
# Die Versionen entsprechen docs/VERSIONEN.md; ntfy wird aus deploy/einrichtung-ntfy.sh gelesen (eine einzige Quelle für diese Pins).
readonly DOMAIN="familyhub.lx-labs.dev"                 # fest: Passkeys (RP-ID) und App-Links hängen daran, nie ändern
readonly NTFY_DOMAIN="ntfy.familyhub.lx-labs.dev"
readonly LX_USER="lx"
readonly SVC_USER="lx-fampad"
readonly ETC_DIR="/etc/lx-fampad"
readonly ENV_FILE="/etc/lx-fampad/env"
readonly MIGRATE_ENV="/etc/lx-fampad/migrate.env"
readonly DB_NAME="lx_fampad"
readonly RT_ROLE="lx_fampad"
readonly MG_ROLE="lx_fampad_migrate"
readonly PG_MAJOR="17"
# Pins: Standardwerte; mit NODE_PKG_VERSION / CADDY_PKG_VERSION in der Parameterdatei bewusst übersteuerbar (wenn das Repository die Version nicht mehr führt)
NODE_PKG_VERSION="24.21.0-1nodesource1"               # = server/.nvmrc 24.21.0
readonly NODESOURCE_FPR="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
readonly NODESOURCE_KEY_URL="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
CADDY_PKG_VERSION="2.11.7"
readonly CADDY_FPR="65760C51EDEA2017CEA2CA15155B6D79CA56EA34"
readonly CADDY_KEY_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly GITHUB_ED25519_FPR="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"   # https://api.github.com/meta (ssh_key_fingerprints)
readonly RRSYNC_RELEASES="/srv/fampad/releases/android"
readonly PHASEN=(pruefen pakete system code konfiguration datenbank anwendung ntfy caddy sicherung pruefung)

# --- Zustand des Laufs ------------------------------------------------------------------------------------------------------------
DRY=0; JA=0; OHNE_SYSTEMD=0; LX_ANLEGEN=0
PARAMS_DATEI=""; NUR_PHASEN=""; AB_PHASE=""
SICHERUNG_DIR=""; ID_STDIN=0; ID_DATEI=""; ID_LOESCHEN=0
KONFIG_ERSETZEN=0; DB_ERSETZEN=0; WETTER_STARTEN=0; DNS_UEBERSPRINGEN=0; SWAP_OK=0
RESTORE=0
AGE_ID=""                  # privater Schlüssel, nur hier im Arbeitsspeicher
SCHLUESSEL_VERWORFEN=0     # 1 nach der letzten Entschlüsselung (Ende der Phase datenbank), bevor ein Swap aktiviert wird
DB_ARCHIV=""; CFG_ARCHIV=""; FILES_ARCHIV=""
REPO=""; LX_HOME=""
AKTUELLE_PHASE="-"
TMP_ARBEIT=""; POLICY_RC_ANGELEGT=0
OFFEN=()
# Parameter (Standardwerte; werden aus der Parameterdatei überschrieben)
P_GIT_REPO_URL="git@github.com:diy3d-de/lx-fampad.git"
P_GIT_REF=""
P_LX_SSH_PUBKEY=""; P_CI_DEPLOY_PUBKEY=""
P_WEATHER_ENABLED=""; P_WEATHER_PLACE=""; P_WEATHER_STATION_MAC=""; P_WEATHER_BBOX=""
P_RELEASE_CERT_SHA256=""; P_E2EE_PW_BACKUP=""; P_AUTH_LEGACY_PASSWORD_LOGIN=""
P_BACKUP_AGE_RECIPIENTS=""; P_BACKUP_AGE_RECIPIENTS_CONFIG=""; P_BACKUP_NAS_PUBKEY=""; P_BACKUP_NAS_IP=""
P_SWAP_MB="0"
P_NODE_PKG_VERSION=""; P_CADDY_PKG_VERSION=""
P_BACKUP_KEEP=""; P_BACKUP_INCLUDE_APK=""; P_BACKUP_INCLUDE_FILES=""

# --- Ausgabe ---------------------------------------------------------------------------------------------------------------------------
info() { echo "    $*"; }
warn() { echo "    WARNUNG: $*" >&2; }
fehler() { echo "FEHLER: $*" >&2; exit 1; }
schritt() { echo; echo "==> $*"; }
offen() { OFFEN+=("$*"); echo "    OFFEN: $*"; }
trocken() { [ "$DRY" = 1 ]; }
# Aktion ausführen oder (Trockenlauf) nur anzeigen. Nur für einfache Befehle; zusammengesetzte Schritte prüfen $DRY selbst.
aktion() { # $1 Beschreibung, Rest: Befehl
  local text="$1"; shift
  if trocken; then echo "    [dry-run] $text"; return 0; fi
  info "$text"
  "$@"
}
pruefpunkt() { # $1 Text, Rest: Befehl (ohne Ausgabe); im Trockenlauf nur genannt
  local text="$1"; shift
  if trocken; then echo "    [dry-run] Prüfpunkt: $text"; return 0; fi
  if "$@" >/dev/null 2>&1; then echo "    Prüfpunkt ok: $text"; else fehler "Prüfpunkt fehlgeschlagen in Phase $AKTUELLE_PHASE: $text"; fi
}
sysd() { systemctl "$@"; }   # im Test (--ohne-systemd) steht hier eine Attrappe (test-integration/fake-systemctl.sh)
frage_ja() { # $1 Frage; Rückfragen nur mit --yes oder am Terminal
  [ "$JA" = 1 ] && return 0
  [ -r /dev/tty ] || fehler "Rückfrage nötig, aber kein Terminal vorhanden: --yes angeben oder in einem Terminal starten"
  local antwort
  read -r -p "$1 [ja/N] " antwort </dev/tty
  [ "$antwort" = ja ]
}

# --- Aufräumen und Fehlerbehandlung ------------------------------------------------------------------------------------------------
# Sperre gegen zwei gleichzeitige Läufe: PID-Datei (kein flock: von diesem Lauf gestartete Hintergrunddienste würden den Dateideskriptor erben)
SPERRDATEI=/run/lock/lx-fampad-neuinstallation.pid
SPERRE_GESETZT=0
sperren() {
  local alt
  if ( set -C; echo "$$" > "$SPERRDATEI" ) 2>/dev/null; then SPERRE_GESETZT=1; return 0; fi
  alt="$(cat "$SPERRDATEI" 2>/dev/null || true)"
  if [[ "$alt" =~ ^[0-9]+$ ]] && kill -0 "$alt" 2>/dev/null && tr '\0' ' ' < "/proc/$alt/cmdline" 2>/dev/null | grep -q 'bootstrap-server'; then
    fehler "Ein anderer Lauf von bootstrap-server.sh ist aktiv (PID $alt)"
  fi
  echo "$$" > "$SPERRDATEI"; SPERRE_GESETZT=1   # veraltete Sperre eines abgebrochenen Laufs
}
aufraeumen() {
  local rc=$?
  trap - EXIT
  AGE_ID=""
  if [ "$SPERRE_GESETZT" = 1 ] && [ "$(cat "$SPERRDATEI" 2>/dev/null)" = "$$" ]; then rm -f "$SPERRDATEI"; fi
  if [ "$POLICY_RC_ANGELEGT" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi
  if [ -n "$TMP_ARBEIT" ]; then rm -rf -- "$TMP_ARBEIT"; fi
  if [ -n "$STAGE_SHM" ]; then rm -rf -- "$STAGE_SHM"; fi
  if [ -n "$STAGE_FILES" ]; then rm -rf -- "$STAGE_FILES"; fi
  if [ -n "$ARCH_ARBEIT" ]; then rm -rf -- "$ARCH_ARBEIT"; fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 10 ]; then
    echo "!!  Abbruch in Phase '$AKTUELLE_PHASE' (Code $rc). Ursache beheben und denselben Befehl wiederholen (idempotent) oder mit --ab $AKTUELLE_PHASE neu starten." >&2
  fi
  exit "$rc"
}
bei_fehler() {
  local code=$? zeile=${1:-?}
  trap - ERR
  echo "!!  Fehler in Zeile $zeile (Code $code), Phase '$AKTUELLE_PHASE'." >&2
  CADDY_ROLLBACK_AKTIV=${CADDY_ROLLBACK_AKTIV:-0}
  if [ "$CADDY_ROLLBACK_AKTIV" = 1 ]; then caddy_zuruecksetzen; fi
  exit "$code"
}
CADDY_ROLLBACK_AKTIV=0

# --- Parameterdatei --------------------------------------------------------------------------------------------------------------------
# Wird NIE als Shell ausgeführt (kein source): nur Zeilen SCHLÜSSEL=Wert aus einer festen Liste; alles andere bricht ab.
# Datei oder Ordner gehört root und ist für Gruppe/Andere nicht schreibbar (sonst könnte ein anderer Benutzer sie zwischen Prüfung und Benutzung austauschen)
nur_root_schreibbar() { # $1 Pfad
  [ -e "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ] && [ $(( 8#$(stat -c %a "$1") & 8#022 )) -eq 0 ]
}
# Dasselbe an einem bereits geöffneten Dateideskriptor: geprüft wird genau die Datei, die danach gelesen wird (kein Austausch dazwischen)
fd_root_schreibbar() { # $1 Deskriptor-Nummer
  [ -f "/proc/self/fd/$1" ] && [ "$(stat -L -c %u "/proc/self/fd/$1")" = 0 ] && [ $(( 8#$(stat -L -c %a "/proc/self/fd/$1") & 8#022 )) -eq 0 ]
}
parameter_lesen() { # $1 Datei
  local datei="$1" zeile key val n=0 pfd
  local re_dq='^"(.*)"$' re_sq="^'(.*)'\$"
  [ -r "$datei" ] && [ ! -L "$datei" ] || fehler "Parameterdatei nicht lesbar oder ein Symlink: $datei"
  exec {pfd}< "$datei"   # einmal öffnen: Eigentümer, Rechte und Inhalt stammen aus derselben Datei
  fd_root_schreibbar "$pfd" || fehler "Parameterdatei $datei muss root gehören und darf für Gruppe/Andere nicht schreibbar sein (chown root:root, chmod 600)"
  while IFS= read -r zeile <&"$pfd" || [ -n "$zeile" ]; do
    n=$((n + 1)); zeile="${zeile%$'\r'}"
    case "$zeile" in ''|'#'*) continue ;; esac
    [[ "$zeile" =~ ^[[:space:]]*# ]] && continue
    [[ "$zeile" =~ ^([A-Z0-9_]+)=(.*)$ ]] || fehler "Parameterdatei Zeile $n: erwartet SCHLÜSSEL=Wert"
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ $re_dq ]]; then val="${BASH_REMATCH[1]}"; elif [[ "$val" =~ $re_sq ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ "${val^^}" == *"AGE-SECRET-KEY"* || "${val^^}" == *"PRIVATE KEY"* ]]; then
      fehler "Parameterdatei Zeile $n: enthält einen privaten Schlüssel. Der gehört nie in eine Datei auf dem Server."
    fi
    case "$key" in
      GIT_REPO_URL|GIT_REF|LX_SSH_PUBKEY|CI_DEPLOY_PUBKEY|WEATHER_ENABLED|WEATHER_PLACE|WEATHER_STATION_MAC|WEATHER_BBOX|RELEASE_CERT_SHA256|E2EE_PW_BACKUP|AUTH_LEGACY_PASSWORD_LOGIN|BACKUP_AGE_RECIPIENTS|BACKUP_AGE_RECIPIENTS_CONFIG|BACKUP_NAS_PUBKEY|BACKUP_NAS_IP|BACKUP_KEEP|BACKUP_INCLUDE_APK|BACKUP_INCLUDE_FILES|SWAP_MB|NODE_PKG_VERSION|CADDY_PKG_VERSION)
        printf -v "P_$key" '%s' "$val" ;;
      *) fehler "Parameterdatei Zeile $n: unbekannter Schlüssel '$key' (erlaubt sind nur die Schlüssel aus parameter.beispiel; Geheimnisse gehören nicht hierher)" ;;
    esac
  done
  exec {pfd}<&-
}
SSH_KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/]+=*( [^[:cntrl:]]*)?$'
AGE_RECIP_RE='^age1[02-9ac-hj-np-z]{58}$'
parameter_pruefen() {
  local r
  [[ "$P_GIT_REPO_URL" =~ ^(git@github\.com:|https://github\.com/)[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fehler "GIT_REPO_URL ungültig (nur GitHub: git@github.com:NAME/REPO.git oder https://github.com/NAME/REPO.git)"
  if [ -n "$P_GIT_REF" ]; then
    [[ "$P_GIT_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || fehler "GIT_REF ungültig (Tag, Branch oder Commit)"
  fi
  [ -z "$P_LX_SSH_PUBKEY" ] || [[ "$P_LX_SSH_PUBKEY" =~ $SSH_KEY_RE ]] || fehler "LX_SSH_PUBKEY ist kein öffentlicher SSH-Schlüssel"
  [ -z "$P_CI_DEPLOY_PUBKEY" ] || [[ "$P_CI_DEPLOY_PUBKEY" =~ $SSH_KEY_RE ]] || fehler "CI_DEPLOY_PUBKEY ist kein öffentlicher SSH-Schlüssel"
  [ -z "$P_BACKUP_NAS_PUBKEY" ] || [[ "$P_BACKUP_NAS_PUBKEY" =~ $SSH_KEY_RE ]] || fehler "BACKUP_NAS_PUBKEY ist kein öffentlicher SSH-Schlüssel"
  case "$P_WEATHER_ENABLED" in ''|true|false) ;; *) fehler "WEATHER_ENABLED muss true oder false sein" ;; esac
  [ -z "$P_WEATHER_PLACE" ] || [[ "$P_WEATHER_PLACE" =~ ^[^[:cntrl:]\\\"\'\$\`=]{1,60}$ ]] || fehler "WEATHER_PLACE enthält unzulässige Zeichen"
  [ -z "$P_WEATHER_STATION_MAC" ] || [[ "$P_WEATHER_STATION_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || fehler "WEATHER_STATION_MAC ungültig (aa:bb:cc:dd:ee:ff)"
  [ -z "$P_WEATHER_BBOX" ] || [[ "$P_WEATHER_BBOX" =~ ^-?[0-9]{1,3}(\.[0-9]+)?(,-?[0-9]{1,3}(\.[0-9]+)?){3}$ ]] || fehler "WEATHER_BBOX ungültig (lat_sw,lon_sw,lat_ne,lon_ne)"
  [ -z "$P_RELEASE_CERT_SHA256" ] || [[ "$P_RELEASE_CERT_SHA256" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || fehler "RELEASE_CERT_SHA256 ungültig (32 Hex-Bytes mit Doppelpunkten)"
  case "$P_E2EE_PW_BACKUP" in ''|true|false) ;; *) fehler "E2EE_PW_BACKUP muss true oder false sein" ;; esac
  case "$P_AUTH_LEGACY_PASSWORD_LOGIN" in ''|true|false) ;; *) fehler "AUTH_LEGACY_PASSWORD_LOGIN muss true oder false sein" ;; esac
  if [ "$P_AUTH_LEGACY_PASSWORD_LOGIN" = false ] && [ "$P_E2EE_PW_BACKUP" != true ]; then
    fehler "AUTH_LEGACY_PASSWORD_LOGIN=false braucht E2EE_PW_BACKUP=true (sonst bricht der Server den Start ab)"
  fi
  local liste
  for liste in "$P_BACKUP_AGE_RECIPIENTS" "$P_BACKUP_AGE_RECIPIENTS_CONFIG"; do
    [ -z "$liste" ] && continue
    IFS=',' read -ra teile <<<"$liste"
    for r in "${teile[@]}"; do [[ "$r" =~ $AGE_RECIP_RE ]] || fehler "BACKUP_AGE_RECIPIENTS: ungültiger öffentlicher age-Schlüssel '${r:0:8}…'"; done
  done
  [ -z "$P_BACKUP_NAS_IP" ] || [[ "$P_BACKUP_NAS_IP" =~ ^[0-9a-fA-F:./,]+$ ]] || fehler "BACKUP_NAS_IP enthält unzulässige Zeichen (IP oder CIDR, mehrere mit Komma)"
  if { [ -n "$P_BACKUP_NAS_PUBKEY" ] && [ -z "$P_BACKUP_NAS_IP" ]; } || { [ -z "$P_BACKUP_NAS_PUBKEY" ] && [ -n "$P_BACKUP_NAS_IP" ]; }; then
    fehler "BACKUP_NAS_PUBKEY und BACKUP_NAS_IP gehören zusammen"
  fi
  [ -z "$P_NODE_PKG_VERSION" ] || [[ "$P_NODE_PKG_VERSION" =~ ^24\.[0-9]+\.[0-9]+-1nodesource1$ ]] || fehler "NODE_PKG_VERSION ungültig (24.x.y-1nodesource1)"
  [ -z "$P_CADDY_PKG_VERSION" ] || [[ "$P_CADDY_PKG_VERSION" =~ ^2\.[0-9]+\.[0-9]+$ ]] || fehler "CADDY_PKG_VERSION ungültig (2.x.y)"
  [ -z "$P_BACKUP_KEEP" ] || { [[ "$P_BACKUP_KEEP" =~ ^[0-9]{1,2}$ ]] && [ "$P_BACKUP_KEEP" -ge 1 ]; } || fehler "BACKUP_KEEP muss eine Zahl von 1 bis 99 sein"
  [ -z "$P_BACKUP_INCLUDE_APK" ] || [[ "$P_BACKUP_INCLUDE_APK" =~ ^[01]$ ]] || fehler "BACKUP_INCLUDE_APK muss 0 oder 1 sein"
  [ -z "$P_BACKUP_INCLUDE_FILES" ] || [[ "$P_BACKUP_INCLUDE_FILES" =~ ^[01]$ ]] || fehler "BACKUP_INCLUDE_FILES muss 0 oder 1 sein"
  [[ "$P_SWAP_MB" =~ ^[0-9]+$ ]] || fehler "SWAP_MB muss eine Zahl sein"
  if [ "$P_SWAP_MB" -ne 0 ] && { [ "$P_SWAP_MB" -lt 256 ] || [ "$P_SWAP_MB" -gt 8192 ]; }; then fehler "SWAP_MB: 0 oder 256 bis 8192"; fi
  return 0
}

# --- Kleine, einzeln testbare Hilfen -----------------------------------------------------------------------------------------------
# Wert einer Zeile SCHLÜSSEL=Wert (letzte gewinnt, wie bei systemd)
env_wert() { # $1 Datei, $2 Schlüssel
  { grep -E "^$2=" "$1" 2>/dev/null || true; } | tail -n 1 | cut -d= -f2-
}
# Zeile SCHLÜSSEL=Wert setzen oder anhängen, Wert aus ENV_WERT (nie in der Prozessliste); Datei bleibt root:root 0600
env_setzen() { # $1 Datei, $2 Schlüssel; ENV_WERT=...
  local datei="$1" key="$2" tmp
  tmp="$(mktemp "$datei.XXXXXX")"
  K="$key" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["ENV_WERT"]; fertig = 0 }
    index($0, k "=") == 1 { if (!fertig) { print k "=" v; fertig = 1 } ; next }
    { print }
    END { if (!fertig) print k "=" v }' "$datei" > "$tmp"
  chown root:root "$tmp"; chmod 600 "$tmp"
  mv -f "$tmp" "$datei"
}
# Fingerabdruck (AA:BB:...) -> Base64url ohne Auffüllung (WEBAUTHN_ORIGINS der Android-App)
fingerabdruck_base64url() {
  python3 -c 'import base64,sys; h=sys.argv[1].replace(":",""); print(base64.urlsafe_b64encode(bytes.fromhex(h)).decode().rstrip("="))' "$1"
}
# Zustand des Haupt-Caddyfiles: fehlt | import | standard | fremd
caddy_haupt_zustand() { # $1 Pfad
  local f="$1" norm
  [ -e "$f" ] || { echo fehlt; return 0; }
  if grep -qE '^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy' "$f"; then echo import; return 0; fi
  norm="$({ grep -vE '^[[:space:]]*(#|$)' "$f" || true; } | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -s ' ' | tr '\n' '|')"
  case "$norm" in
    ''|':80 {|root * /usr/share/caddy|file_server|}|') echo standard ;;
    *) echo fremd ;;
  esac
}
# DNS-Vergleich: alle Adressen (A und AAAA) müssen globale Adressen dieses Servers sein
dns_vergleichen() { # $1 lokale Adressen, $2 A-Adressen, $3 AAAA-Adressen ; Meldung in DNS_GRUND
  local lokal="$1" a4="$2" a6="$3" a
  DNS_GRUND=""
  [ -n "$a4" ] || { DNS_GRUND="kein A-Eintrag"; return 1; }
  for a in $a4 $a6; do
    grep -qxiF "$a" <<<"$lokal" || { DNS_GRUND="zeigt auf $a (keine globale Adresse dieses Servers)"; return 1; }
  done
  return 0
}
dns_pruefen() { # $1 Host
  local lokal a4 a6
  lokal="$(ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')"
  a4="$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  a6="$(getent ahostsv6 "$1" 2>/dev/null | awk '{print $1}' | { grep -vi '^::ffff:' || true; } | sort -u || true)"
  dns_vergleichen "$lokal" "$a4" "$a6"
}
# ntfy-Pins aus deploy/einrichtung-ntfy.sh (einzige Quelle)
ntfy_pins_lesen() {
  local f="$REPO/deploy/einrichtung-ntfy.sh"
  if [ ! -r "$f" ]; then
    trocken && return 1   # Trockenlauf mit einem einzelnen Skript ohne Checkout: die Pins stehen erst nach dem Klonen zur Verfügung
    fehler "$f fehlt"
  fi
  NTFY_VERSION="$(sed -nE 's/^NTFY_VERSION="([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$f" | head -n 1)"
  NTFY_FPR="$(sed -nE 's/^NTFY_FPR="([0-9A-F]{40})".*/\1/p' "$f" | head -n 1)"
  NTFY_APT_URL="$(sed -nE 's/^NTFY_APT_URL="(https:\/\/[A-Za-z0-9.\/-]+)".*/\1/p' "$f" | head -n 1)"
  NTFY_DEB_SHA256="$(sed -nE 's/^NTFY_DEB_SHA256="([0-9a-f]{64})".*/\1/p' "$f" | head -n 1)"
  [ -n "$NTFY_VERSION" ] && [ -n "$NTFY_FPR" ] && [ -n "$NTFY_APT_URL" ] && [ -n "$NTFY_DEB_SHA256" ] || fehler "ntfy-Pins in $f nicht lesbar (Format geändert?)"
  NTFY_DEB_URL="https://github.com/binwiederhier/ntfy/releases/download/v${NTFY_VERSION}/ntfy_${NTFY_VERSION}_linux_amd64.deb"
}
# Ausgabe erst in eine Variable, dann prüfen: "cmd | grep -q" würde unter pipefail abbrechen, sobald grep früh schließt
apt_version_da() { # $1 Paket, $2 Version
  local liste
  liste="$(apt-cache madison "$1" | awk '{print $3}')"
  grep -Fxq "$2" <<<"$liste"
}
http_enthaelt() { # $1 URL, $2 Muster (fester Text)
  local body
  body="$(curl -fsS --max-time 5 "$1" 2>/dev/null || true)"
  grep -qF -- "$2" <<<"$body"
}
fehlende_pakete() { local p; for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done; }
apt_installieren() { # Pakete (mit oder ohne =Version)
  env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 apt-get install -y --no-install-recommends "$@"
}
psql_pg() { (cd / && runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -q "$@"); }
db_vorhanden() { [ "$(psql_pg -d postgres -tAc "select count(*) from pg_database where datname='$1'")" = 1 ]; }
db_tabellen() { psql_pg -d "$1" -tAc "select count(*) from pg_tables where schemaname='public'"; }
rolle_vorhanden() { [ "$(psql_pg -d postgres -tAc "select count(*) from pg_roles where rolname='$1'")" = 1 ]; }
# Passwort aus postgres://user:pw@host/db einer env-Datei; nur unkritische Zeichen (kein SQL-Quoting-Risiko)
db_passwort_lesen() { # $1 Datei, $2 Schlüssel
  local url pw
  url="$(env_wert "$1" "$2")"
  pw="$(sed -nE 's|^postgres(ql)?://[^:@/]+:([^@/]*)@.*|\2|p' <<<"$url")"
  [[ "$pw" =~ ^[A-Za-z0-9._~-]{8,}$ ]] || return 1
  printf '%s' "$pw"
}

# --- age und Sicherungsarchive (Klartext nur in Pipes, Schlüssel nur im Arbeitsspeicher) ------------------------------------------
age_entschluesseln() { # $1 Datei -> Klartext auf stdout; der Schlüssel läuft über eine Pipe (kein Datei, keine Prozessliste)
  age -d -i <(printf '%s\n' "$AGE_ID") -- "$1"
}
# Schlüsseldatei darf nur gelöscht werden, wenn sie im Arbeitsspeicher liegt (/dev/shm, /run/lxfampad, /run/user), ohne ..-Teile, auch aufgelöst
# (realpath) dort bleibt, kein Symlink ist und root gehört
identitaet_pfad_erlaubt() { # $1 Pfad (nur die Schreibweise)
  case "$1" in *..*) return 1 ;; esac
  case "$1" in /dev/shm/*|/run/lxfampad/*|/run/user/*) return 0 ;; *) return 1 ;; esac
}
identitaet_datei_loeschbar() { # $1 Pfad
  local rp
  identitaet_pfad_erlaubt "$1" || return 1
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 1
  rp="$(realpath -e -- "$1")" || return 1
  identitaet_pfad_erlaubt "$rp"
}
# Swap kann Arbeitsspeicher (und damit den Schlüssel) auf die Platte auslagern. Gelesen wird /proc/swaps (kein Programm, das fehlen kann);
# ist die Datei nicht lesbar, gilt Swap als aktiv (fail-closed).
SWAPS_DATEI=/proc/swaps
swap_aktiv() {
  [ -r "$SWAPS_DATEI" ] || return 0
  [ -n "$(awk 'NR > 1' "$SWAPS_DATEI")" ]
}
identitaet_laden() {
  local roh="" zeile
  if swap_aktiv; then
    [ "$SWAP_OK" = 1 ] || fehler "Auf diesem Server ist Swap aktiv (/proc/swaps) oder nicht prüfbar: der private Schlüssel könnte aus dem Arbeitsspeicher auf die Platte ausgelagert werden. Erst 'swapoff -a', oder bewusst mit --swap-ok fortfahren (danach den Swap-Bereich überschreiben/neu anlegen)."
    warn "Swap ist aktiv, --swap-ok angegeben: der Schlüssel kann im Swap landen."
  fi
  if [ "$ID_LOESCHEN" = 1 ]; then
    identitaet_datei_loeschbar "$ID_DATEI" || fehler "--identity-datei-loeschen: nur für eine reguläre Datei unter /dev/shm, /run/lxfampad oder /run/user (ohne ..), die root gehört und kein Symlink ist"
  fi
  if [ "$ID_STDIN" = 1 ]; then
    if [ -t 0 ]; then
      echo "    Privaten age-Schlüssel einfügen (Eingabe unsichtbar), danach Enter und Strg+D:" >&2
      while IFS= read -rs zeile; do roh+="$zeile"$'\n'; done
      echo >&2
    else
      roh="$(cat)"
    fi
  else
    [ -r "$ID_DATEI" ] || fehler "Schlüsseldatei nicht lesbar: $ID_DATEI"
    if [ -n "$(find "$ID_DATEI" -maxdepth 0 -perm /077 2>/dev/null)" ]; then warn "$ID_DATEI ist für andere lesbar; besser chmod 600 (und nur in /dev/shm ablegen)"; fi
    roh="$(cat "$ID_DATEI")"
    if [ "$ID_LOESCHEN" = 1 ]; then
      shred -u "$ID_DATEI" 2>/dev/null || rm -f "$ID_DATEI"
      info "Schlüsseldatei überschrieben und gelöscht (der Schlüssel liegt nur noch im Arbeitsspeicher dieses Laufs)."
    fi
  fi
  AGE_ID="$({ grep -E '^AGE-SECRET-KEY-1[0-9A-Z]+$' <<<"$roh" || true; })"
  roh=""
  [ -n "$AGE_ID" ] || fehler "Kein privater age-Schlüssel (AGE-SECRET-KEY-1…) gefunden"
  info "age-Schlüssel eingelesen (nur im Arbeitsspeicher)."
}
# Ordnerprüfung (nur lesen, auch im Trockenlauf): Dateinamen, Prüfsummen, Alter
sicherung_ordner_pruefen() {
  local d="$SICHERUNG_DIR" n
  [ -d "$d" ] || fehler "Sicherungsordner fehlt: $d"
  d="$(cd "$d" && pwd)"; SICHERUNG_DIR="$d"
  nur_root_schreibbar "$d" || fehler "Sicherungsordner $d muss root gehören und darf für Gruppe/Andere nicht schreibbar sein (chown -R root:root, chmod -R go-w)"
  DB_ARCHIV=""; CFG_ARCHIV=""; FILES_ARCHIV=""
  shopt -s nullglob
  local dbs=("$d"/db-*.dump.age) cfgs=("$d"/config-*.tar.age) fls=("$d"/files-*.tar.age)
  shopt -u nullglob
  [ "${#dbs[@]}" -eq 1 ] || fehler "genau eine db-*.dump.age in $d erwartet (gefunden: ${#dbs[@]})"
  [ "${#cfgs[@]}" -eq 1 ] || fehler "genau eine config-*.tar.age in $d erwartet (gefunden: ${#cfgs[@]})"
  [[ "$(basename "${dbs[0]}")" =~ ^db-[0-9]{8}-[0-9]{6}\.dump\.age$ ]] || fehler "unerwarteter Dateiname: $(basename "${dbs[0]}")"
  [[ "$(basename "${cfgs[0]}")" =~ ^config-[0-9]{8}-[0-9]{6}\.tar\.age$ ]] || fehler "unerwarteter Dateiname: $(basename "${cfgs[0]}")"
  DB_ARCHIV="${dbs[0]}"; CFG_ARCHIV="${cfgs[0]}"
  if [ "${#fls[@]}" -eq 1 ]; then FILES_ARCHIV="${fls[0]}"; fi
  [ -f "$d/SHA256SUMS" ] || fehler "SHA256SUMS fehlt in $d"
  local f
  for f in "$d/SHA256SUMS" "$DB_ARCHIV" "$CFG_ARCHIV" ${FILES_ARCHIV:+"$FILES_ARCHIV"}; do
    nur_root_schreibbar "$f" || fehler "$f muss root gehören, kein Symlink sein und darf für Gruppe/Andere nicht schreibbar sein"
  done
  # Im echten Lauf werden die Dateien EINMAL in ein root-eigenes Arbeitsverzeichnis kopiert (Platte, nicht RAM: die Dateiablage kann groß sein; nur
  # verschlüsselte Daten). Geprüft und benutzt werden nur diese Kopien: Ein Austausch im Quellordner nach der Prüfung greift nicht mehr.
  local pd="$d"
  if ! trocken; then
    ARCH_ARBEIT="$(mktemp -d -p /var/tmp lx-fampad-bootstrap-sicherung.XXXXXX)"
    chmod 700 "$ARCH_ARBEIT"
    cp -- "$d/SHA256SUMS" "$DB_ARCHIV" "$CFG_ARCHIV" ${FILES_ARCHIV:+"$FILES_ARCHIV"} "$ARCH_ARBEIT/" || fehler "Kopieren der Sicherung nach $ARCH_ARBEIT fehlgeschlagen (Platz?)"
    DB_ARCHIV="$ARCH_ARBEIT/$(basename "$DB_ARCHIV")"; CFG_ARCHIV="$ARCH_ARBEIT/$(basename "$CFG_ARCHIV")"
    if [ -n "$FILES_ARCHIV" ]; then FILES_ARCHIV="$ARCH_ARBEIT/$(basename "$FILES_ARCHIV")"; fi
    pd="$ARCH_ARBEIT"
  fi
  # alle benutzten Archive müssen in SHA256SUMS stehen (sha256sum -c prüft sonst nur, was dort eingetragen ist)
  for f in "$DB_ARCHIV" "$CFG_ARCHIV" ${FILES_ARCHIV:+"$FILES_ARCHIV"}; do
    awk -v n="$(basename "$f")" '$2 == n || $2 == "*" n { g = 1 } END { exit !g }' "$pd/SHA256SUMS" || fehler "$(basename "$f") steht nicht in SHA256SUMS: die Sicherung ist unvollständig oder verändert"
  done
  ( cd "$pd" && sha256sum -c --strict --quiet SHA256SUMS ) || fehler "Prüfsummen stimmen nicht: die Sicherung ist beschädigt (eine ältere vom NAS nehmen)"
  n="$(basename "$d")"
  info "Sicherung: $d (Prüfsummen ok$([[ "$n" =~ ^[0-9]{8}-[0-9]{6}$ ]] && echo ", Zeitstempel $n UTC"))"
}
# Schlüsselprüfung (nur im echten Lauf): passt der Schlüssel, ist der Dump ein pg_dump, sind alle Einträge des Archivs sicher
sicherung_inhalt_pruefen() {
  local magic namen
  magic="$(age_entschluesseln "$DB_ARCHIV" 2>/dev/null | head -c 5 || true)"
  [ "$magic" = "PGDMP" ] || fehler "Datenbank-Archiv lässt sich mit diesem Schlüssel nicht lesen oder ist kein pg_dump (falscher Schlüssel? 'no identity matched')"
  namen="$(tar_archiv_pruefen "$CFG_ARCHIV" z "Konfigurationsarchiv")" || exit 1
  grep -qx 'etc/lx-fampad/env' <<<"$namen" || fehler "etc/lx-fampad/env fehlt im Konfigurationsarchiv (AUTH_SECRET_KEY!)"
  CFG_NAMEN="$namen"
  info "Schlüssel passt; Datenbank-Archiv ist ein pg_dump; Konfigurationsarchiv enthält nur Dateien und Ordner."
  if [ -n "$FILES_ARCHIV" ]; then
    namen="$(tar_archiv_pruefen "$FILES_ARCHIV" "" "Dateiablage-Archiv")" || exit 1
    if grep -qvE '^srv/fampad/files(/|$)' <<<"$namen"; then fehler "Dateiablage-Archiv enthält Pfade außerhalb von srv/fampad/files: wird nicht entpackt"; fi
    info "Dateiablage-Archiv enthält nur Dateien und Ordner unter srv/fampad/files."
  fi
}
# Ein (verschlüsseltes) tar-Archiv ansehen, ohne etwas zu entpacken: nur reguläre Dateien und Ordner (keine Symlinks, Hardlinks, Geräte),
# keine absoluten oder ..-Pfade. Gibt die Namen aus; bei Fehlern eine Meldung auf stderr und Rückgabe 1.
tar_archiv_pruefen() { # $1 Datei, $2 "z" (gzip) oder "", $3 Bezeichnung
  local typen namen
  typen="$(age_entschluesseln "$1" | tar "-tv$2f" - | cut -c1)" || { echo "FEHLER: $3 nicht lesbar" >&2; return 1; }
  if grep -qv '^[-d]$' <<<"$typen"; then echo "FEHLER: $3 enthält Links oder Gerätedateien: wird nicht entpackt" >&2; return 1; fi
  namen="$(age_entschluesseln "$1" | tar "-t$2f" -)" || { echo "FEHLER: $3 nicht lesbar" >&2; return 1; }
  if grep -qE '(^|/)\.\.(/|$)|^/' <<<"$namen"; then echo "FEHLER: $3 enthält unsichere Pfade: wird nicht entpackt" >&2; return 1; fi
  printf '%s\n' "$namen"
}
CFG_NAMEN=""
# Nur ausdrücklich genannte Pfade entpacken (wer immer das Archiv erzeugt hat: nichts Unbekanntes landet auf der Platte)
ARCH_ARBEIT=""; STAGE_SHM=""; STAGE_FILES=""
# Entpackt wird NIE direkt nach /: erst in ein root-eigenes Staging (Arbeitsspeicher /dev/shm, 700), mit --no-same-owner und
# --no-same-permissions (Modi/Eigentümer aus dem Archiv zählen nicht). Danach kopiert das Skript gezielt und setzt Modi und Eigentümer selbst.
config_in_staging() { # Präfixe (relativ zu /), nur vorhandene werden entpackt
  local p gefunden=()
  for p in "$@"; do
    if awk -v p="$p" 'index($0, p "/") == 1 || $0 == p { f = 1 } END { exit !f }' <<<"$CFG_NAMEN"; then gefunden+=("$p"); fi
  done
  [ "${#gefunden[@]}" -gt 0 ] || return 0
  if [ -z "$STAGE_SHM" ]; then
    [ -d /dev/shm ] || fehler "/dev/shm fehlt (Staging im Arbeitsspeicher)"
    STAGE_SHM="$(mktemp -d -p /dev/shm lx-fampad-bootstrap.XXXXXX)"; chmod 700 "$STAGE_SHM"
  fi
  ( umask 077; age_entschluesseln "$CFG_ARCHIV" | tar -xzf - -C "$STAGE_SHM" --no-same-owner --no-same-permissions -- "${gefunden[@]}" )
  info "entpackt (Staging): ${gefunden[*]}"
}
# Gibt nur Namen zurück, die als einfache Dateinamen taugen (keine Pfadteile)
einfacher_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }
# Kopiert die regulären Dateien der obersten Ebene (keine Symlinks, keine Unterordner) mit festem Modus und Eigentümer root
staging_dateien_kopieren() { # $1 Quellordner im Staging, $2 Zielordner, $3 Modus, $4 "nur-fehlende" oder "alle"
  local f n
  [ -d "$1" ] || return 0
  for f in "$1"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    n="$(basename "$f")"
    einfacher_name "$n" || { warn "Datei mit ungewöhnlichem Namen übersprungen: $n"; continue; }
    if [ "$4" = nur-fehlende ] && [ -e "$2/$n" ]; then continue; fi
    install -m "$3" -o root -g root "$f" "$2/$n"
  done
}
# Symlinks in den für lx beschreibbaren Bäumen entfernen, bevor root dort etwas entpackt oder anlegt (lx könnte sie vorbereitet haben)
lx_baeume_bereinigen() {
  local d
  for d in "$@"; do
    [ ! -L "$d" ] || fehler "$d ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
    [ ! -d "$d" ] || find "$d" -type l -delete
  done
}
config_hat() { awk -v p="$1" 'index($0, p "/") == 1 || $0 == p { f = 1 } END { exit !f }' <<<"$CFG_NAMEN"; }

# --- Wiederherstellungs-Vorbereitung (einmal je Lauf, wenn --sicherung gesetzt ist) -----------------------------------------------
restore_bereit() {
  [ "$RESTORE" = 1 ] || return 0
  trocken && return 0
  [ "$SCHLUESSEL_VERWORFEN" = 0 ] || return 0
  [ -z "$AGE_ID" ] || return 0
  command -v age >/dev/null || fehler "age fehlt (Phase pakete installiert es)"
  [ -n "$DB_ARCHIV" ] || sicherung_ordner_pruefen   # nötig, wenn die Phase pruefen nicht mitläuft (--ab, --phase)
  identitaet_laden
  sicherung_inhalt_pruefen
}

# Nach der letzten Entschlüsselung: den Schlüssel aus dem Arbeitsspeicher des Skripts entfernen (vor Swap, Bau und allem Weiteren)
schluessel_verwerfen() {
  [ "$RESTORE" = 1 ] || return 0
  trocken && return 0
  [ "$SCHLUESSEL_VERWORFEN" = 0 ] || return 0
  AGE_ID=""; unset AGE_ID; AGE_ID=""
  SCHLUESSEL_VERWORFEN=1
  info "age-Schlüssel aus dem Arbeitsspeicher des Skripts entfernt (alle Entschlüsselungen sind erledigt)."
}

# Probleme, die im Trockenlauf nur gemeldet werden, im echten Lauf aber abbrechen
PROBLEME=0
blockiert() {
  if trocken; then echo "    PROBLEM: $*" >&2; PROBLEME=$((PROBLEME + 1)); else fehler "$*"; fi
}

node_ok() { command -v node >/dev/null && [[ "$(node --version 2>/dev/null)" =~ ^v24\.([0-9]+)\. ]] && [ "${BASH_REMATCH[1]}" -ge 21 ]; }
postgres_bereit() {
  if ! pg_lsclusters -h 2>/dev/null | awk '{print $4}' | grep -qx online; then pg_ctlcluster "$PG_MAJOR" main start; fi
  for _ in $(seq 1 30); do
    if (cd / && runuser -u postgres -- pg_isready -q); then return 0; fi
    sleep 1
  done
  return 1
}
# PostgreSQL darf nur auf localhost lauschen (Debian-Standard; wird nie geändert, nur geprüft)
postgres_nur_lokal() {
  local adr
  adr="$(ss -ltnH 'sport = :5432' 2>/dev/null | awk '{print $4}' | { grep -vE '^(127\.0\.0\.1|\[::1\]):5432$' || true; })"
  [ -z "$adr" ]
}
authorized_keys_ergaenzen() { # $1 Benutzer, $2 vollständige Zeile
  local u="$1" zeile="$2" home dir f grp
  home="$(getent passwd "$u" | cut -d: -f6)"; grp="$(id -gn "$u")"
  dir="$home/.ssh"; f="$dir/authorized_keys"
  # lx darf in seinem Home Symlinks anlegen: root folgt ihnen nie
  [ ! -L "$home" ] && [ ! -L "$dir" ] && [ ! -L "$f" ] || fehler "$dir oder $f ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
  install -d -m 700 -o "$u" -g "$grp" "$dir"
  local tmp="$TMP_ARBEIT/authorized_keys.$u"
  : > "$tmp"
  if [ -f "$f" ]; then cat -- "$f" > "$tmp"; fi
  grep -qxF -- "$zeile" "$tmp" || printf '%s\n' "$zeile" >> "$tmp"
  schreibe_neu "$tmp" "$f" 600 "$u:$grp"
}
# Datei im Verzeichnis eines anderen Benutzers (lx) neu anlegen: Symlink ablehnen, alte Datei entfernen, mit noclobber (O_EXCL) schreiben,
# dann Eigentümer/Modus setzen. Restrisiko: ein Austausch zwischen den Schritten durch lx selbst (kein Vorschlaghammer: das Verzeichnis gehört ihm).
schreibe_neu() { # $1 Quelldatei, $2 Ziel, $3 Modus, $4 Eigentümer:Gruppe
  [ ! -L "$2" ] || fehler "$2 ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
  rm -f -- "$2"
  ( set -C; cat -- "$1" > "$2" ) || fehler "$2 ließ sich nicht neu anlegen (existiert schon?)"
  chown -h "$4" "$2"; chmod "$3" "$2"
}
# Regel für den Neustart per deploy.sh. Die Wetter-Regel gibt es nur, wenn der Wetter-Dienst gewollt ist (--wetter-starten) oder die Regel schon
# da war: ein Wiederholungslauf ohne die Option fügt sie nicht hinzu und nimmt sie nicht weg.
sudoers_schreiben() { # $1 mit Wetter-Neustart (1/0)
  local regel="$LX_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-fampad" tmp="$TMP_ARBEIT/sudoers-lx-fampad" mit="$1"
  if [ -f /etc/sudoers.d/lx-fampad ] && grep -q 'restart lx-fampad-weather' /etc/sudoers.d/lx-fampad; then mit=1; fi
  [ "$mit" = 1 ] && regel="$regel, /usr/bin/systemctl restart lx-fampad-weather"
  printf '%s\n' "$regel" > "$tmp"
  visudo -cf "$tmp" >/dev/null || fehler "sudoers-Prüfung fehlgeschlagen (Regel: $regel)"
  install -m 440 -o root -g root "$tmp" /etc/sudoers.d/lx-fampad
}
REPO_ZIEL=""
repo_bestimmen() {
  local selbst
  LX_HOME="$(getent passwd "$LX_USER" | cut -d: -f6 || true)"
  [ -n "$LX_HOME" ] || LX_HOME="/home/$LX_USER"
  REPO_ZIEL="$LX_HOME/lx-fampad"
  REPO="$REPO_ZIEL"
  # Trockenlauf auf einem Server ohne Checkout: die Dateien dort lesen, wo dieses Skript liegt (nur lesend)
  if trocken && [ ! -f "$REPO/deploy/lx-fampad.service" ]; then
    selbst="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || true)"
    if [ -n "$selbst" ] && [ -f "$selbst/deploy/lx-fampad.service" ]; then REPO="$selbst"; fi
  fi
}
git_lx() {
  runuser -u "$LX_USER" -- env HOME="$LX_HOME" GIT_SSH_COMMAND="$GIT_SSH" GIT_TERMINAL_PROMPT=0 git -C "$REPO" "$@"
}
GIT_SSH=""
github_hostkey_sichern() {
  local kf="$LX_HOME/.ssh/known_hosts_fampad" keys fpr
  if [ -s "$kf" ] && ssh-keygen -lf "$kf" 2>/dev/null | grep -qF "$GITHUB_ED25519_FPR"; then return 0; fi
  keys="$(ssh-keyscan -T 10 -t ed25519 github.com 2>/dev/null)"
  fpr="$(ssh-keygen -lf /dev/stdin <<<"$keys" 2>/dev/null | awk '{print $2}')"
  [ "$fpr" = "$GITHUB_ED25519_FPR" ] || fehler "SSH-Host-Schlüssel von github.com stimmt nicht mit dem gepinnten überein (gefunden: ${fpr:-keiner}; erwartet: $GITHUB_ED25519_FPR). Nichts wurde eingetragen."
  [ ! -L "$kf" ] && [ ! -L "$LX_HOME/.ssh" ] || fehler "$kf oder $LX_HOME/.ssh ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
  printf '%s\n' "$keys" > "$TMP_ARBEIT/known_hosts_fampad"
  schreibe_neu "$TMP_ARBEIT/known_hosts_fampad" "$kf" 644 "$LX_USER:$(id -gn "$LX_USER")"
}
CADDY_ARBEITSLISTE=()

# =================================================================================================================================
# Phasen
# =================================================================================================================================
netz_pruefen() { # $1 URL
  if curl -fsSI --max-time 10 "$1" >/dev/null 2>&1; then info "erreichbar: $1"; else blockiert "nicht erreichbar: $1"; fi
}
phase_pruefen() {
  [ "$(id -u)" -eq 0 ] || fehler "Bitte als root starten:  sudo bash $0 ..."
  local os_id os_ver mem_mb frei_gb h b
  for b in curl ip awk sed tar sha256sum getent runuser flock dpkg; do
    command -v "$b" >/dev/null || blockiert "Werkzeug '$b' fehlt (apt install curl ca-certificates iproute2)"
  done
  os_id="$(sed -nE 's/^ID=//p' /etc/os-release | tr -d '"')"; os_ver="$(sed -nE 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
  [ "$os_id" = debian ] && [ "$os_ver" = 13 ] || fehler "Vorgesehen ist nur Debian 13 (trixie); gefunden: ${os_id:-?} ${os_ver:-?}"
  [ "$(dpkg --print-architecture)" = amd64 ] || fehler "Nur amd64 vorgesehen"
  if [ "$OHNE_SYSTEMD" = 0 ]; then [ -d /run/systemd/system ] || fehler "systemd läuft nicht (in Containern: --ohne-systemd, nur für Tests)"; fi
  info "System: Debian $os_ver, $(uname -m)"
  mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  [ "$mem_mb" -ge 1500 ] || blockiert "zu wenig Arbeitsspeicher: ${mem_mb} MB (mindestens 1,5 GB; Bau des Servers braucht ihn)"
  frei_gb="$(df --output=avail -BG /srv 2>/dev/null | tail -n 1 | tr -dc '0-9')"
  [ "${frei_gb:-0}" -ge 5 ] || blockiert "zu wenig freier Platz auf /srv: ${frei_gb:-?} GB (mindestens 5 GB; mit Kartendatei 25 GB)"
  [ "${frei_gb:-0}" -ge 25 ] || info "Platz auf /srv: ${frei_gb} GB (für die Kartendatei später 20 GB frei halten)"
  info "Arbeitsspeicher ${mem_mb} MB, freier Platz ${frei_gb} GB"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then info "Firewall: ufw ist aktiv."
  else info "Firewall: kein aktives ufw gefunden. Das Skript richtet keine Firewall ein: Anbieter-Firewall oder ufw (nur 22, 80, 443) stellst du selbst ein (docs/NEUINSTALLATION.md)."; fi

  schritt "Vorhandener Zustand (nur lesen)"
  if node_ok; then info "Node.js: $(node --version) (passt, bleibt)"; elif command -v node >/dev/null; then blockiert "Node.js $(node --version) ist installiert, passt aber nicht (24.x ab 24.21 nötig); das Skript ersetzt keine fremde Installation"; else info "Node.js: fehlt (wird installiert: $NODE_PKG_VERSION)"; fi
  if command -v caddy >/dev/null; then info "Caddy: $(caddy version 2>/dev/null | awk '{print $1}') vorhanden"; else info "Caddy: fehlt (wird installiert: $CADDY_PKG_VERSION)"; fi
  info "Haupt-Caddyfile: $(caddy_haupt_zustand /etc/caddy/Caddyfile)  (import = fertig, standard/fehlt = wird angelegt, fremd = du musst eine Zeile ergänzen)"
  if [ -f /etc/caddy/Caddyfile ] && grep -qE '^[[:space:]]*(www\.)?lx-labs\.dev' /etc/caddy/Caddyfile; then info "lx-labs.dev ist in diesem Caddyfile eingerichtet: Koexistenz, das Haupt-Caddyfile bleibt unberührt."; fi
  if command -v psql >/dev/null && (cd / && runuser -u postgres -- pg_isready -q) 2>/dev/null; then
    if db_vorhanden "$DB_NAME" 2>/dev/null; then info "Datenbank $DB_NAME: vorhanden, $(db_tabellen "$DB_NAME") Tabellen"; else info "Datenbank $DB_NAME: fehlt"; fi
  else info "PostgreSQL: nicht installiert oder nicht gestartet"; fi
  if [ -e "$ENV_FILE" ]; then info "$ENV_FILE: vorhanden (wird nicht überschrieben)"; else info "$ENV_FILE: fehlt"; fi
  if id "$LX_USER" >/dev/null 2>&1; then info "Benutzer $LX_USER: vorhanden"; elif [ "$LX_ANLEGEN" = 1 ]; then info "Benutzer $LX_USER: fehlt, wird angelegt (--lx-anlegen)"; else blockiert "Benutzer $LX_USER fehlt (wie bei lx-labs einrichten oder --lx-anlegen)"; fi

  schritt "Netz (nur lesen)"
  netz_pruefen https://deb.debian.org
  netz_pruefen https://github.com
  node_ok || netz_pruefen https://deb.nodesource.com
  command -v caddy >/dev/null || netz_pruefen https://dl.cloudsmith.io
  command -v ntfy >/dev/null || netz_pruefen https://archive.ntfy.sh/apt/keyring.gpg

  schritt "DNS (nur lesen)"
  for h in "$DOMAIN" "$NTFY_DOMAIN"; do
    if dns_pruefen "$h"; then info "$h zeigt auf diesen Server"; else info "$h: $DNS_GRUND"; fi
  done
  info "Stimmt DNS noch nicht (z. B. beim Umzug), richtet die Phase caddy nichts ein; sie lässt sich nach dem Umschalten allein wiederholen."

  if [ "$RESTORE" = 1 ]; then
    schritt "Sicherung (nur lesen)"
    sicherung_ordner_pruefen
    if trocken; then info "Der private Schlüssel wird im Trockenlauf nicht gelesen; Inhalt und Schlüssel prüft der echte Lauf in der Phase pakete, bevor etwas verändert wird."; fi
    if [ -n "$ID_DATEI" ] && [ ! -r "$ID_DATEI" ]; then blockiert "Schlüsseldatei nicht lesbar: $ID_DATEI"; fi
    if [ "$ID_LOESCHEN" = 1 ] && ! identitaet_datei_loeschbar "$ID_DATEI"; then blockiert "--identity-datei-loeschen: nur für eine reguläre Datei unter /dev/shm oder /run, die root gehört (kein Symlink)"; fi
    if swap_aktiv; then
      if [ "$SWAP_OK" = 1 ]; then info "Swap ist aktiv; --swap-ok ist angegeben."; else blockiert "Swap ist aktiv (swapon --show): der Schlüssel könnte auf die Platte ausgelagert werden. Erst swapoff -a oder bewusst --swap-ok"; fi
    else info "Swap: nicht aktiv (gut: der Schlüssel bleibt im Arbeitsspeicher). Ein Swap aus SWAP_MB wird erst angelegt, wenn alle Entschlüsselungen fertig sind."; fi
  fi
  if [ -n "$P_GIT_REF" ]; then info "Code-Stand (GIT_REF): $P_GIT_REF"; else info "Code-Stand: wie im Checkout $REPO (kein GIT_REF gesetzt; für eine Wiederherstellung den Stand der Sicherung festlegen!)"; fi
  [ -z "$P_BACKUP_AGE_RECIPIENTS" ] && info "Sicherung des neuen Servers: BACKUP_* nicht gesetzt (die Phase sicherung wird übersprungen oder nutzt vorhandene Empfänger)"
  return 0
}

phase_pakete() {
  local fehlend=()
  if [ "$RESTORE" = 1 ]; then
    # age zuerst, damit Schlüssel und Sicherung geprüft sind, bevor irgendetwas verändert wird
    mapfile -t fehlend < <(fehlende_pakete age ca-certificates tar gzip)
    if [ "${#fehlend[@]}" -gt 0 ]; then
      if trocken; then info "[dry-run] apt-get install ${fehlend[*]} (vor der Schlüsselprüfung)"; else aktion "apt-get update" apt-get update -qq; apt_installieren "${fehlend[@]}"; fi
    fi
    restore_bereit
  fi
  mapfile -t fehlend < <(fehlende_pakete adduser ca-certificates curl gnupg git openssh-client rsync age sqlite3 xz-utils openssl python3 sudo postgresql postgresql-client iproute2 tmux)
  if [ "${#fehlend[@]}" -gt 0 ]; then
    if trocken; then info "[dry-run] apt-get install ${fehlend[*]}"; else aktion "apt-get update" apt-get update -qq; apt_installieren "${fehlend[@]}"; fi
  else info "alle Debian-Pakete vorhanden."; fi

  # PostgreSQL 17: nur lokal, nie verändert
  if trocken; then
    info "[dry-run] PostgreSQL ${PG_MAJOR}: Cluster prüfen/starten, nur localhost"
  else
    command -v pg_lsclusters >/dev/null || fehler "PostgreSQL nicht installiert"
    pg_lsclusters -h | awk '{print $1}' | grep -qx "$PG_MAJOR" || fehler "Kein PostgreSQL-$PG_MAJOR-Cluster (Debian 13 liefert $PG_MAJOR; pg_lsclusters prüfen)"
    postgres_bereit || fehler "PostgreSQL startet nicht (journalctl -u postgresql)"
  fi
  pruefpunkt "PostgreSQL $PG_MAJOR läuft und lauscht nur auf localhost" bash -c "psql --version | grep -q ' $PG_MAJOR\\.' && ! ss -ltnH 'sport = :5432' | awk '{print \$4}' | grep -vqE '^(127\\.0\\.0\\.1|\\[::1\\]):5432\$'"

  # Node.js (NodeSource, Schlüssel-Fingerabdruck und Version gepinnt; wie lx-labs, aber ohne "curl | bash")
  if node_ok; then
    info "Node.js $(node --version) ist vorhanden."
  elif command -v node >/dev/null; then
    blockiert "Node.js $(node --version) passt nicht und wird nicht ersetzt"
  elif trocken; then
    info "[dry-run] Node.js $NODE_PKG_VERSION aus deb.nodesource.com (Schlüssel $NODESOURCE_FPR prüfen, installieren, apt-mark hold)"
  else
    node_installieren
  fi
  # shellcheck disable=SC2016
  pruefpunkt "Node.js 24.x (ab 24.21) unter /usr/bin/node" bash -c '[ "$(command -v node)" = /usr/bin/node ] && node --version | grep -qE "^v24\.(2[1-9]|[3-9][0-9])\."'
}
node_installieren() {
  local key="$TMP_ARBEIT/nodesource.key" got
  curl -fsSL --max-time 60 -o "$key" "$NODESOURCE_KEY_URL"
  got="$(gpg --batch --show-keys --with-colons "$key" | awk -F: '$1=="pub"{p=1} $1=="fpr"&&p{print $10; p=0}')"
  [ "$got" = "$NODESOURCE_FPR" ] || fehler "Fingerabdruck des NodeSource-Schlüssels stimmt nicht (erwartet $NODESOURCE_FPR, gefunden: ${got:-keiner}). Nichts installiert."
  gpg --batch --dearmor < "$key" > /usr/share/keyrings/nodesource.gpg
  chmod 644 /usr/share/keyrings/nodesource.gpg
  cat > /etc/apt/sources.list.d/nodesource.sources <<'EOF'
Types: deb
URIs: https://deb.nodesource.com/node_24.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
  printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/nodejs
  apt-get update -qq
  apt_version_da nodejs "$NODE_PKG_VERSION" || fehler "nodejs=$NODE_PKG_VERSION steht nicht (mehr) im NodeSource-Repository. Verfügbar (neueste zuerst): $(apt-cache madison nodejs | awk '{print $3}' | head -n 5 | tr '\n' ' '). Eine bewusst gewählte 24.x-Version trägst du als NODE_PKG_VERSION in die Parameterdatei ein (und in docs/VERSIONEN.md), nichts wurde installiert."
  apt_installieren "nodejs=$NODE_PKG_VERSION"
  apt-mark hold nodejs >/dev/null
  info "Node.js $(node --version) installiert (Schlüssel-Fingerabdruck geprüft, per apt-mark hold festgehalten)."
}

phase_system() {
  if id "$LX_USER" >/dev/null 2>&1; then info "Benutzer $LX_USER vorhanden."
  elif [ "$LX_ANLEGEN" = 1 ]; then
    aktion "Benutzer $LX_USER anlegen (ohne Passwort)" adduser --disabled-password --gecos "" "$LX_USER"
    if [ -n "$P_LX_SSH_PUBKEY" ]; then
      if trocken; then info "[dry-run] SSH-Schlüssel aus LX_SSH_PUBKEY für $LX_USER eintragen"; else authorized_keys_ergaenzen "$LX_USER" "$P_LX_SSH_PUBKEY"; fi
    else
      info "Hinweis: kein LX_SSH_PUBKEY: der Benutzer $LX_USER hat keinen SSH-Zugang, bis du einen Schlüssel einträgst."
    fi
  else
    blockiert "Benutzer $LX_USER fehlt (--lx-anlegen oder wie bei lx-labs einrichten)"
  fi
  repo_bestimmen
  if trocken; then
    info "[dry-run] Systembenutzer $SVC_USER, Gruppe, $LX_USER in Gruppe $SVC_USER"
    info "[dry-run] Verzeichnisse /srv/fampad/{server,server.prev,web,releases/android,well-known,font-fallback,karte,files}, $ETC_DIR"
    info "[dry-run] journald: MaxRetentionSec=7day; sudo-Regel für $LX_USER (nur: systemctl restart lx-fampad)"
    [ -z "$P_CI_DEPLOY_PUBKEY" ] || info "[dry-run] CI-Schlüssel (rrsync -wo $RRSYNC_RELEASES) in ~$LX_USER/.ssh/authorized_keys"
  else
    id "$SVC_USER" >/dev/null 2>&1 || adduser --system --group --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
    usermod -aG "$SVC_USER" "$LX_USER"
    mkdir -p /srv/fampad/{server,server.prev,web,releases/android,well-known,font-fallback,karte,files} "$ETC_DIR"
    # Ordner, die lx beschreiben darf: nie einem Symlink folgen (chown -h, keine Symlinks als Wurzel)
    local d
    for d in /srv/fampad /srv/fampad/server /srv/fampad/server.prev /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback /srv/fampad/karte /srv/fampad/files; do
      [ ! -L "$d" ] || fehler "$d ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
    done
    chown -h "$LX_USER:$SVC_USER" /srv/fampad/server /srv/fampad/server.prev
    chmod 750 /srv/fampad/server /srv/fampad/server.prev
    chown -hR "$LX_USER:$LX_USER" /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback /srv/fampad/karte
    # Modi nur an echten Ordnern und Dateien setzen (find folgt keinen Symlinks; chmod -R könnte einem von lx angelegten Link folgen)
    find /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback /srv/fampad/karte -type d -exec chmod 755 {} +
    find /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback /srv/fampad/karte -type f -exec chmod u=rw,go=r {} +
    chown -h "$SVC_USER:$SVC_USER" /srv/fampad/files
    chmod 700 /srv/fampad/files
    chmod 755 /srv/fampad
    chown root:root "$ETC_DIR"; chmod 755 "$ETC_DIR"
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nMaxRetentionSec=7day\n' > /etc/systemd/journald.conf.d/lx-retention.conf
    sysd restart systemd-journald
    sudoers_schreiben 0
    if [ -n "$P_CI_DEPLOY_PUBKEY" ]; then
      local rr
      rr="$(command -v rrsync || echo /usr/bin/rrsync)"
      authorized_keys_ergaenzen "$LX_USER" "restrict,command=\"$rr -wo $RRSYNC_RELEASES\" $P_CI_DEPLOY_PUBKEY"
      info "CI-Schlüssel eingetragen: nur Schreiben nach $RRSYNC_RELEASES (rrsync -wo)."
    fi
  fi
  # shellcheck disable=SC2016
  pruefpunkt "Verzeichnisse und Rechte (/srv/fampad/files 700, server 750)" bash -c '[ "$(stat -c %a /srv/fampad/files)" = 700 ] && [ "$(stat -c %a /srv/fampad/server)" = 750 ] && [ "$(stat -c %U:%G /srv/fampad/files)" = lx-fampad:lx-fampad ]'
  pruefpunkt "sudo-Regel gültig" visudo -cf /etc/sudoers.d/lx-fampad
  pruefpunkt "journald auf 7 Tage begrenzt" grep -q '^MaxRetentionSec=7day' /etc/systemd/journald.conf.d/lx-retention.conf
}

phase_code() {
  local url="$P_GIT_REPO_URL" key="$LX_HOME/.ssh/id_ed25519_fampad" vorhanden=0 netz=0 sha
  GIT_SSH="ssh -i $key -o IdentitiesOnly=yes -o UserKnownHostsFile=$LX_HOME/.ssh/known_hosts_fampad -o StrictHostKeyChecking=yes -o BatchMode=yes"
  [ -d "$REPO_ZIEL/.git" ] && vorhanden=1
  if [ "$vorhanden" = 1 ]; then
    REPO="$REPO_ZIEL"
    info "Checkout vorhanden: $REPO_ZIEL"
    url="$(git_lx remote get-url origin 2>/dev/null || echo "$P_GIT_REPO_URL")"
  fi
  if [ "$vorhanden" = 0 ] || [ -n "$P_GIT_REF" ]; then netz=1; fi
  if trocken; then
    if [ "$netz" = 1 ] && [[ "$url" == git@* ]]; then
      info "[dry-run] Deploy-Key $key (ed25519, ohne Passphrase) anlegen, falls er fehlt; SSH-Host-Schlüssel von github.com gegen den gepinnten Fingerabdruck prüfen; ohne Zugriff pausiert das Skript (Exit 10)"
    fi
    if [ "$vorhanden" = 0 ]; then info "[dry-run] git clone $url nach $REPO_ZIEL"; else info "[dry-run] kein neuer Abruf nötig: der vorhandene Checkout bleibt${P_GIT_REF:+, danach git checkout $P_GIT_REF}"; fi
    return 0
  fi
  if [ "$netz" = 1 ] && [[ "$url" == git@* ]]; then
    [ ! -L "$LX_HOME/.ssh" ] && [ ! -L "$key" ] && [ ! -L "$key.pub" ] || fehler "$LX_HOME/.ssh oder der Deploy-Key ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
    install -d -m 700 -o "$LX_USER" -g "$(id -gn "$LX_USER")" "$LX_HOME/.ssh"
    github_hostkey_sichern
    if [ ! -s "$key" ]; then
      runuser -u "$LX_USER" -- ssh-keygen -q -t ed25519 -N "" -C "lx-fampad-server" -f "$key"
      info "Deploy-Key erzeugt: $key"
    fi
    if ! runuser -u "$LX_USER" -- env HOME="$LX_HOME" GIT_SSH_COMMAND="$GIT_SSH" GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; then
      echo
      echo "PAUSE: GitHub lässt diesen Server noch nicht lesen. Trage diesen ÖFFENTLICHEN Schlüssel bei GitHub als Deploy key ein"
      echo "       (Repository, Settings, Deploy keys, Add deploy key, OHNE Schreibrecht):"
      echo
      cat "$key.pub"
      echo
      echo "       Danach denselben Befehl noch einmal starten (bereits Erledigtes wird übersprungen)."
      exit 10
    fi
    info "GitHub-Zugriff mit dem Deploy-Key funktioniert."
  fi
  if [ "$vorhanden" = 0 ]; then
    runuser -u "$LX_USER" -- env HOME="$LX_HOME" GIT_SSH_COMMAND="$GIT_SSH" GIT_TERMINAL_PROMPT=0 git clone "$url" "$REPO_ZIEL"
    REPO="$REPO_ZIEL"
  fi
  if [[ "$url" == git@* ]]; then git_lx config core.sshCommand "$GIT_SSH"; fi
  if [ -n "$P_GIT_REF" ]; then
    git_lx fetch --tags --prune origin
    sha="$(git_lx rev-parse --verify --quiet "origin/$P_GIT_REF^{commit}" || git_lx rev-parse --verify --quiet "$P_GIT_REF^{commit}" || true)"
    [ -n "$sha" ] || fehler "GIT_REF '$P_GIT_REF' nicht gefunden (Tag, Branch oder Commit?)"
    if git_lx rev-parse --verify --quiet "refs/remotes/origin/$P_GIT_REF" >/dev/null; then
      warn "GIT_REF '$P_GIT_REF' ist ein BRANCH und damit beweglich: heute und beim nächsten Mal kann das ein anderer Stand sein. Für eine Wiederherstellung einen Tag oder eine Commit-ID nehmen."
    fi
    git_lx checkout --quiet --detach "$sha"
    info "Code-Stand: $P_GIT_REF = $sha"
  fi
  echo "    ==> CODE-STAND DIESES LAUFS: $(git_lx rev-parse HEAD) ($(git_lx describe --tags --always 2>/dev/null || echo ohne-Tag))"
  info "Code-Stand jetzt: $(git_lx log -1 --format='%h %s (%ci)')"
  info "Letzte Commits (bitte kurz ansehen: das Skript führt als root Dateien aus diesem Checkout aus):"
  git_lx log -3 --format='        %h %an: %s' | cat
  pruefpunkt "Checkout enthält deploy/lx-fampad.service und server/package.json" bash -c "[ -f '$REPO/deploy/lx-fampad.service' ] && [ -f '$REPO/server/package.json' ]"
  pruefpunkt "Checkout hat keine lokalen Änderungen in deploy/" bash -c "[ -z \"\$(runuser -u $LX_USER -- git -C '$REPO' status --short -- deploy)\" ]"
}

phase_konfiguration() {
  restore_bereit
  if [ "$RESTORE" = 1 ]; then konfiguration_aus_sicherung; else konfiguration_neu; fi
  well_known_pruefen
  pruefpunkt "$ENV_FILE gehört root:root, Modus 600" bash -c "[ \"\$(stat -c %U:%G:%a '$ENV_FILE')\" = root:root:600 ]"
  pruefpunkt "PUBLIC_URL zeigt auf https://$DOMAIN (Passkey-RP-ID bleibt)" bash -c "grep -qE '^PUBLIC_URL=https://$DOMAIN/?\$' '$ENV_FILE'"
}
konfiguration_neu() {
  if [ -e "$ENV_FILE" ]; then
    info "$ENV_FILE existiert schon und bleibt unverändert (Parameter WEATHER_*/E2EE_*/RELEASE_CERT_* werden dann nicht eingetragen)."
    return 0
  fi
  if trocken; then
    info "[dry-run] $ENV_FILE aus server/.env.example mit zufälligem Datenbank-Passwort (root:root, 0600) anlegen"
    return 0
  fi
  local pw
  pw="$(openssl rand -base64 24 | tr -d '/+=')"
  ( umask 077; PW="$pw" awk '{ gsub("CHANGE_ME", ENVIRON["PW"]); print }' "$REPO/server/.env.example" > "$ENV_FILE" )
  chown root:root "$ENV_FILE"; chmod 600 "$ENV_FILE"
  pw=""
  {
    echo ""
    echo "# --- von deploy/neuinstallation/bootstrap-server.sh ergänzt (öffentliche Einstellungen aus der Parameterdatei) ---"
    if [ "$P_WEATHER_ENABLED" = true ] && [ -n "$P_WEATHER_PLACE" ] && [ -n "$P_WEATHER_STATION_MAC" ] && [ -n "$P_WEATHER_BBOX" ]; then
      echo "WEATHER_ENABLED=true"; echo "WEATHER_PLACE=$P_WEATHER_PLACE"; echo "WEATHER_STATION_MAC=$P_WEATHER_STATION_MAC"; echo "WEATHER_BBOX=$P_WEATHER_BBOX"
    fi
    if [ -n "$P_RELEASE_CERT_SHA256" ]; then echo "WEBAUTHN_ORIGINS=android:apk-key-hash:$(fingerabdruck_base64url "$P_RELEASE_CERT_SHA256")"; fi
    [ -z "$P_E2EE_PW_BACKUP" ] || echo "E2EE_PW_BACKUP=$P_E2EE_PW_BACKUP"
    [ -z "$P_AUTH_LEGACY_PASSWORD_LOGIN" ] || echo "AUTH_LEGACY_PASSWORD_LOGIN=$P_AUTH_LEGACY_PASSWORD_LOGIN"
  } >> "$ENV_FILE"
  info "$ENV_FILE angelegt (Datenbank-Passwort steht nur dort; AUTH_SECRET_KEY erzeugt einrichtung-auth.sh in der Phase datenbank)."
  [ -n "$P_RELEASE_CERT_SHA256" ] || offen "WEBAUTHN_ORIGINS fehlt (RELEASE_CERT_SHA256 nicht gesetzt): Passkeys der Android-App gehen erst, wenn du ihn nach deploy/README.md Abschnitt 9 einträgst"
}
# Alles aus der Sicherung wird erst in ein Staging im Arbeitsspeicher entpackt, dort geprüft und dann gezielt kopiert.
# Jeder Schritt gilt für sich: der Abgleich über AUTH_SECRET_KEY betrifft nur die env-Dateien; die übrigen Teile (Update-Kanal, well-known,
# ntfy-Benutzerdatenbank, Dateiablage, Empfänger der Sicherung) werden immer "nur wenn sie fehlen" wiederhergestellt.
# NICHT aus der Sicherung übernommen: backup.conf (root lädt sie per source), Caddy-Dateien, ntfy-Konfiguration, Units, sudoers.
konfiguration_aus_sicherung() {
  local alt neu env_ersetzen=0 env_vorhanden=0 url rp f
  [ ! -e "$ENV_FILE" ] || env_vorhanden=1
  if trocken; then
    info "[dry-run] aus config-*.tar.age ins Staging (Arbeitsspeicher, --no-same-permissions): etc/lx-fampad, etc/lx-fampad-backup (nur recipients*.txt nach Formatprüfung), srv/fampad/well-known, srv/fampad/releases/android, var/lib/ntfy"
    if [ "$env_vorhanden" = 1 ]; then info "[dry-run] $ENV_FILE existiert: AUTH_SECRET_KEY würde mit dem der Sicherung verglichen; die übrigen Teile werden trotzdem 'nur wenn sie fehlen' wiederhergestellt"; fi
    info "[dry-run] Caddy-Dateien, ntfy-Konfiguration, Units, sudoers und backup.conf der Sicherung werden NICHT übernommen (kommen frisch aus dem Repository bzw. den Parametern)"
    return 0
  fi
  config_in_staging etc/lx-fampad etc/lx-fampad-backup srv/fampad/well-known srv/fampad/releases/android var/lib/ntfy
  config_hat etc/lx-fampad || fehler "etc/lx-fampad nicht im Archiv"
  local senv="$STAGE_SHM/etc/lx-fampad/env"
  [ -f "$senv" ] && [ ! -L "$senv" ] || fehler "etc/lx-fampad/env fehlt im Archiv oder ist kein reguläre Datei"
  # Prüfen, BEVOR irgendetwas verändert wird
  [ -n "$(env_wert "$senv" AUTH_SECRET_KEY)" ] || fehler "AUTH_SECRET_KEY fehlt in der env der Sicherung"
  url="$(env_wert "$senv" PUBLIC_URL)"; rp="$(env_wert "$senv" WEBAUTHN_RP_ID)"
  [[ "${url%/}" == "https://$DOMAIN" ]] || fehler "PUBLIC_URL der Sicherung ist '$url', erwartet https://$DOMAIN. Die Domain (Passkey-RP-ID) darf sich nicht ändern; nichts wurde verändert."
  [ -z "$rp" ] || [ "$rp" = "$DOMAIN" ] || fehler "WEBAUTHN_RP_ID der Sicherung ist '$rp', erwartet $DOMAIN"
  db_passwort_lesen "$senv" DATABASE_URL >/dev/null || fehler "DATABASE_URL der Sicherung nicht lesbar (Passwort mit unerwarteten Zeichen?)"
  # 1. env-Dateien (nur hier entscheidet der Abgleich)
  if [ "$env_vorhanden" = 1 ]; then
    alt="$(env_wert "$ENV_FILE" AUTH_SECRET_KEY)"; neu="$(env_wert "$senv" AUTH_SECRET_KEY)"
    if [ "$alt" = "$neu" ]; then
      info "$ENV_FILE stammt schon aus dieser Sicherung (AUTH_SECRET_KEY gleich): env bleibt, fehlende Dateien in $ETC_DIR werden ergänzt."
    else
      alt=""; neu=""
      [ "$KONFIG_ERSETZEN" = 1 ] || fehler "$ENV_FILE existiert und weicht von der Sicherung ab. Ein falscher AUTH_SECRET_KEY macht TOTP-Geheimnisse und Codes unbrauchbar. Prüfe, warum die Datei da ist; zum bewussten Ersetzen --konfiguration-ersetzen angeben (eine Kopie bleibt)."
      frage_ja "Vorhandene Konfiguration durch die der Sicherung ersetzen?" || fehler "abgebrochen"
      cp -p "$ENV_FILE" "$ENV_FILE.vor-wiederherstellung.$(date +%Y%m%d-%H%M%S)"
      info "Kopie der bisherigen env angelegt (root, 0600)."
      env_ersetzen=1
    fi
    alt=""; neu=""
  else
    env_ersetzen=1
  fi
  if [ "$env_ersetzen" = 1 ]; then
    staging_dateien_kopieren "$STAGE_SHM/etc/lx-fampad" "$ETC_DIR" 600 alle
    info "Konfiguration aus der Sicherung wiederhergestellt (AUTH_SECRET_KEY und Datenbank-Zugangsdaten stammen aus der Sicherung)."
  else
    staging_dateien_kopieren "$STAGE_SHM/etc/lx-fampad" "$ETC_DIR" 600 nur-fehlende
  fi
  # 2. Empfänger der Sicherung (nur recipients*.txt, nur wenn sie fehlen und das Format stimmt; backup.conf kommt aus den Parametern)
  mkdir -p /etc/lx-fampad-backup; chown root:root /etc/lx-fampad-backup; chmod 755 /etc/lx-fampad-backup
  for f in recipients.txt recipients-config.txt; do
    [ -f "$STAGE_SHM/etc/lx-fampad-backup/$f" ] && [ ! -L "$STAGE_SHM/etc/lx-fampad-backup/$f" ] || continue
    [ ! -e "/etc/lx-fampad-backup/$f" ] || continue
    if empfaenger_datei_ok "$STAGE_SHM/etc/lx-fampad-backup/$f"; then
      install -m 644 -o root -g root "$STAGE_SHM/etc/lx-fampad-backup/$f" "/etc/lx-fampad-backup/$f"
      info "Empfängerdatei $f aus der Sicherung übernommen (Format geprüft)."
    else
      warn "$f aus der Sicherung hat nicht das Format 'age1…' (eine Zeile je öffentlichem Schlüssel) und wird NICHT übernommen: BACKUP_AGE_RECIPIENTS in der Parameterdatei setzen."
    fi
  done
  # 3. Update-Kanal und assetlinks (nur wenn fehlend; vorher Symlinks in diesen lx-Bäumen entfernen)
  lx_baeume_bereinigen /srv/fampad/well-known /srv/fampad/releases
  rsync_stage "$STAGE_SHM/srv/fampad/well-known/" /srv/fampad/well-known/ "$LX_USER:$LX_USER" D755,F644
  rsync_stage "$STAGE_SHM/srv/fampad/releases/android/" /srv/fampad/releases/android/ "$LX_USER:$LX_USER" D755,F644
  # 4. ntfy-Benutzerdatenbank (nur wenn noch keine da ist; die Phase ntfy übergibt sie dem Benutzer ntfy)
  if [ -s /var/lib/ntfy/user.db ]; then info "ntfy-Benutzerdatenbank vorhanden, wird nicht überschrieben."
  elif [ -d "$STAGE_SHM/var/lib/ntfy" ]; then
    mkdir -p /var/lib/ntfy
    rsync_stage "$STAGE_SHM/var/lib/ntfy/" /var/lib/ntfy/ root:root D750,F600
  fi
  # 5. Dateiablage (nur wenn /srv/fampad/files leer ist)
  if [ -n "$FILES_ARCHIV" ]; then
    [ ! -L /srv/fampad/files ] || fehler "/srv/fampad/files ist ein Symlink: Abbruch"
    if [ -n "$(find /srv/fampad/files -mindepth 1 -print -quit 2>/dev/null)" ]; then
      info "Dateiablage ist nicht leer: nicht überschrieben."
    else
      STAGE_FILES="$(mktemp -d -p /srv/fampad .staging-files.XXXXXX)"; chmod 700 "$STAGE_FILES"
      ( umask 077; age_entschluesseln "$FILES_ARCHIV" | tar -xf - -C "$STAGE_FILES" --no-same-owner --no-same-permissions -- srv/fampad/files )
      rsync_stage "$STAGE_FILES/srv/fampad/files/" /srv/fampad/files/ "$SVC_USER:$SVC_USER" D700,F600
      info "Dateiablage aus files-*.tar.age wiederhergestellt."
    fi
  fi
}
# Kopiert ein Staging-Verzeichnis nach Ziel: nur "nur wenn fehlend" (--ignore-existing), keine Symlinks/Geräte, feste Modi und Eigentümer
rsync_stage() { # $1 Quelle/ (mit Slash), $2 Ziel/, $3 Eigentümer:Gruppe, $4 --chmod-Angabe
  [ -d "$1" ] || return 0
  rsync -rt --no-links --no-devices --no-specials --ignore-existing --chown="$3" --chmod="$4" -- "$1" "$2"
}
# Empfängerdatei: nur Kommentare, Leerzeilen und öffentliche age-Schlüssel (nie ein privater), mindestens ein Schlüssel
empfaenger_datei_ok() { # $1 Datei
  local z n=0
  while IFS= read -r z || [ -n "$z" ]; do
    z="${z%$'\r'}"
    case "$z" in ''|'#'*) continue ;; esac
    [[ "$z" =~ $AGE_RECIP_RE ]] || return 1
    n=$((n + 1))
  done < "$1"
  [ "$n" -gt 0 ]
}
well_known_pruefen() {
  local f=/srv/fampad/well-known/assetlinks.json tpl="$REPO/deploy/assetlinks.json.template"
  if [ -s "$f" ] && ! grep -q 'RELEASE-SHA256-FINGERPRINT-EINTRAGEN' "$f"; then info "assetlinks.json vorhanden."; return 0; fi
  if [ -z "$P_RELEASE_CERT_SHA256" ]; then offen "assetlinks.json fehlt (RELEASE_CERT_SHA256 nicht gesetzt): ohne sie gibt es weder Passkeys in der App noch verifizierte App-Links (deploy/README.md Abschnitt 9)"; return 0; fi
  if trocken; then info "[dry-run] assetlinks.json aus der Vorlage mit RELEASE_CERT_SHA256 erzeugen"; return 0; fi
  [ ! -L /srv/fampad/well-known ] || fehler "/srv/fampad/well-known ist ein Symlink: Abbruch (Verdacht auf Manipulation)"
  FP="$P_RELEASE_CERT_SHA256" awk '/RELEASE-SHA256-FINGERPRINT-EINTRAGEN/ { print "        \"" toupper(ENVIRON["FP"]) "\""; next } { print }' "$tpl" > "$TMP_ARBEIT/assetlinks.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP_ARBEIT/assetlinks.json" || fehler "erzeugte assetlinks.json ist kein gültiges JSON"
  schreibe_neu "$TMP_ARBEIT/assetlinks.json" "$f" 644 "$LX_USER:$LX_USER"   # Symlink ablehnen, entfernen, mit noclobber (O_EXCL) schreiben
  info "assetlinks.json aus der Vorlage erzeugt."
}

phase_datenbank() {
  restore_bereit
  local rt_pw mg_pw tabellen
  if trocken; then
    info "[dry-run] Rolle $RT_ROLE (Passwort aus $ENV_FILE) anlegen bzw. angleichen, nur DML nach einrichtung-auth.sh"
    if [ "$RESTORE" = 1 ]; then
      info "[dry-run] Rolle $MG_ROLE (Passwort aus $MIGRATE_ENV der Sicherung), leere Datenbank $DB_NAME aufbauen: Wegwerf-DB, age -d | pg_restore, dann Umbenennen"
      info "[dry-run] eine vorhandene, nicht leere Datenbank wird NICHT angefasst (nur mit --datenbank-ersetzen, die alte wird dann umbenannt)"
    else
      info "[dry-run] leere Datenbank $DB_NAME (UTF8), Migrationsrolle und AUTH_SECRET_KEY über einrichtung-auth.sh"
    fi
    info "[dry-run] bash $REPO/deploy/einrichtung-auth.sh (AUTH_SECRET_KEY, Rollentrennung, Einheiten lx-fampad.service und lx-fampad-migrate.service)"
    pruefpunkt "Rollen, Eigentümer und Rechte (Laufzeitrolle: kein DDL)" true
    return 0
  fi
  [ -f "$ENV_FILE" ] || fehler "$ENV_FILE fehlt (Phase konfiguration)"
  postgres_bereit || fehler "PostgreSQL läuft nicht"
  rt_pw="$(db_passwort_lesen "$ENV_FILE" DATABASE_URL)" || fehler "Datenbank-Passwort in $ENV_FILE nicht lesbar"
  rolle_setzen "$RT_ROLE" "$rt_pw"
  info "Rolle $RT_ROLE: Passwort aus $ENV_FILE gesetzt."
  tabellen=0
  db_vorhanden "$DB_NAME" && tabellen="$(db_tabellen "$DB_NAME")"
  if [ "$RESTORE" = 1 ]; then
    [ -f "$MIGRATE_ENV" ] || fehler "$MIGRATE_ENV fehlt (steckt in der Sicherung unter etc/lx-fampad)"
    mg_pw="$(db_passwort_lesen "$MIGRATE_ENV" MIGRATION_DATABASE_URL)" || fehler "Passwort in $MIGRATE_ENV nicht lesbar"
    rolle_setzen "$MG_ROLE" "$mg_pw"
    mg_pw=""
    info "Rolle $MG_ROLE: Passwort aus $MIGRATE_ENV gesetzt."
    if [ "$tabellen" -gt 0 ] && [ "$DB_ERSETZEN" = 0 ]; then
      info "Datenbank $DB_NAME ist nicht leer ($tabellen Tabellen): die Wiederherstellung wird übersprungen (idempotent). Ersetzen nur mit --datenbank-ersetzen."
    else
      if [ "$tabellen" -gt 0 ]; then
        frage_ja "Die vorhandene Datenbank $DB_NAME mit $tabellen Tabellen wird umbenannt und durch die Sicherung ersetzt (die Dienste werden erst nach dem erfolgreichen Einspielen kurz gestoppt). Fortfahren?" || fehler "abgebrochen"
      fi
      datenbank_wiederherstellen "$tabellen"
    fi
  else
    if db_vorhanden "$DB_NAME"; then info "Datenbank $DB_NAME vorhanden ($tabellen Tabellen)."
    else
      psql_pg -d postgres -c "CREATE DATABASE $DB_NAME OWNER $RT_ROLE TEMPLATE template0 ENCODING 'UTF8'"
      info "Datenbank $DB_NAME angelegt."
    fi
  fi
  rt_pw=""
  schluessel_verwerfen   # letzte Entschlüsselung erledigt: der Schlüssel verschwindet, bevor Swap, Bau und Dienste kommen
  info "einrichtung-auth.sh: AUTH_SECRET_KEY, Rollentrennung, Einheiten"
  bash "$REPO/deploy/einrichtung-auth.sh"
  pruefpunkt "Datenbank $DB_NAME gehört $MG_ROLE" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -X -tAc \"select pg_get_userbyid(datdba) from pg_database where datname='$DB_NAME'\")\" = $MG_ROLE ]"
  pruefpunkt "Laufzeitrolle $RT_ROLE ist weder Superuser noch darf sie anlegen" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -X -tAc \"select rolsuper or rolcreatedb or rolcreaterole from pg_roles where rolname='$RT_ROLE'\")\" = f ]"
  pruefpunkt "Laufzeitrolle darf in public nichts anlegen (nur DML)" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -X -d $DB_NAME -tAc \"select has_schema_privilege('$RT_ROLE','public','CREATE')\")\" = f ]"
  if [ "$RESTORE" = 1 ]; then
    pruefpunkt "wiederhergestellte Datenbank enthält Tabellen" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -X -d $DB_NAME -tAc \"select count(*) from pg_tables where schemaname='public'\")\" -gt 0 ]"
  fi
  pruefpunkt "systemd-Einheiten lx-fampad und lx-fampad-migrate installiert" bash -c '[ -f /etc/systemd/system/lx-fampad.service ] && [ -f /etc/systemd/system/lx-fampad-migrate.service ]'
  pruefpunkt "AUTH_SECRET_KEY gesetzt" grep -q '^AUTH_SECRET_KEY=.\{32,\}' "$ENV_FILE"
}
rolle_setzen() { # $1 Rolle, $2 Passwort (nur Zeichen A-Za-z0-9._~-); Passwort läuft über stdin, nie über eine Befehlszeile
  local verb=CREATE
  rolle_vorhanden "$1" && verb=ALTER
  printf "%s ROLE %s LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;\n" "$verb" "$1" "$2" | psql_pg -d postgres
}
# Sicherung in eine Wegwerf-Datenbank einspielen und erst bei Erfolg an den Platz von lx_fampad setzen (kein halbfertiger Zustand)
#
# pg_restore läuft NICHT als Superuser: als Migrationsrolle (Eigentümerin der Wegwerf-Datenbank), mit --no-owner --no-acl. Alles, was der
# Dump enthält, wird so mit den Rechten dieser Rolle ausgeführt (kein Superuser-Zugriff durch eine manipulierte Sicherung); Besitzer und
# Rechte setzt danach einrichtung-auth.sh. Grenze: Ein Dump kann auch dann SQL enthalten, das die Daten verändert; echte Echtheit würde nur
# eine Signatur der Sicherung liefern (offener Punkt, docs/NEUINSTALLATION.md).
datenbank_wiederherstellen() { # $1 Tabellenzahl der vorhandenen Datenbank
  local tmpdb="${DB_NAME}_wiederherstellung" alt="" mg_pw fampad_aktiv=0 wetter_aktiv=0
  mg_pw="$(db_passwort_lesen "$MIGRATE_ENV" MIGRATION_DATABASE_URL)" || fehler "Passwort in $MIGRATE_ENV nicht lesbar"
  psql_pg -d postgres -c "DROP DATABASE IF EXISTS $tmpdb WITH (FORCE)"
  psql_pg -d postgres -c "CREATE DATABASE $tmpdb OWNER $MG_ROLE TEMPLATE template0 ENCODING 'UTF8'"
  info "pg_restore als $MG_ROLE (age -d | pg_restore --no-owner --no-acl, Klartext nur in der Pipe) ..."
  if ! age_entschluesseln "$DB_ARCHIV" | PGPASSWORD="$mg_pw" pg_restore -h 127.0.0.1 -U "$MG_ROLE" --no-owner --no-acl --exit-on-error -d "$tmpdb"; then
    mg_pw=""
    psql_pg -d postgres -c "DROP DATABASE IF EXISTS $tmpdb WITH (FORCE)" || true
    fehler "pg_restore fehlgeschlagen (die halbfertige Wegwerf-Datenbank wurde gelöscht; $DB_NAME und alle Dienste sind unverändert)"
  fi
  mg_pw=""
  # erst jetzt (die Wegwerf-Datenbank ist fertig) werden Dienste gestoppt und die Namen getauscht; bei jedem Fehler geht alles zurück
  if db_vorhanden "$DB_NAME" && [ "$1" -gt 0 ]; then
    systemctl is-active --quiet lx-fampad && fampad_aktiv=1
    systemctl is-active --quiet lx-fampad-weather && wetter_aktiv=1
    sysd stop lx-fampad || true
    sysd stop lx-fampad-weather || true
    alt="${DB_NAME}_vor_$(date +%Y%m%d_%H%M%S)"
  fi
  if ! datenbank_tauschen "$tmpdb" "$alt"; then
    # Rückfall in dieser Reihenfolge: ERST den Namen zurück (die alte Datenbank trägt das Verbot neuer Verbindungen mit sich),
    # DANN Verbindungen wieder erlauben (auf dem endgültigen Namen); Fehler werden gemeldet, nicht verschluckt
    local rueckfall_ok=1
    if [ -n "$alt" ] && ! db_vorhanden "$DB_NAME" && db_vorhanden "$alt"; then
      psql_pg -d postgres -c "ALTER DATABASE $alt RENAME TO $DB_NAME" || { warn "Rückbenennung $alt -> $DB_NAME FEHLGESCHLAGEN: von Hand: ALTER DATABASE $alt RENAME TO $DB_NAME"; rueckfall_ok=0; }
    fi
    if db_vorhanden "$DB_NAME"; then
      psql_pg -d postgres -c "ALTER DATABASE $DB_NAME WITH ALLOW_CONNECTIONS true" || { warn "ALLOW_CONNECTIONS auf $DB_NAME konnte nicht gesetzt werden: von Hand: ALTER DATABASE $DB_NAME WITH ALLOW_CONNECTIONS true"; rueckfall_ok=0; }
    fi
    if [ "$fampad_aktiv" = 1 ]; then sysd start lx-fampad || { warn "lx-fampad ließ sich nicht wieder starten"; rueckfall_ok=0; }; fi
    if [ "$wetter_aktiv" = 1 ]; then sysd start lx-fampad-weather || { warn "lx-fampad-weather ließ sich nicht wieder starten"; rueckfall_ok=0; }; fi
    psql_pg -d postgres -c "DROP DATABASE IF EXISTS $tmpdb WITH (FORCE)" || warn "Wegwerf-Datenbank $tmpdb blieb stehen (von Hand: DROP DATABASE $tmpdb)"
    if [ "$rueckfall_ok" = 1 ]; then fehler "Datenbank konnte nicht ausgetauscht werden: der alte Zustand ist wiederhergestellt, Dienste laufen wie vorher"; fi
    fehler "Datenbank konnte nicht ausgetauscht werden UND der Rückfall ist unvollständig (Meldungen WARNUNG oben): bitte von Hand prüfen (psql -l, systemctl status lx-fampad)"
  fi
  [ -z "$alt" ] || info "Bisherige Datenbank umbenannt in $alt (enthält Personendaten; ALLOW_CONNECTIONS ist dort aus, DROP DATABASE $alt geht trotzdem: nach der Prüfung löschen)."
  info "Datenbank $DB_NAME aus der Sicherung wiederhergestellt: $(db_tabellen "$DB_NAME") Tabellen."
}
datenbank_tauschen() { # $1 fertige Wegwerf-Datenbank, $2 neuer Name der alten (leer = alte Datenbank ist leer oder fehlt: wird gelöscht)
  if db_vorhanden "$DB_NAME"; then
    if [ -n "$2" ]; then
      psql_pg -d postgres -c "ALTER DATABASE $DB_NAME WITH ALLOW_CONNECTIONS false" || return 1
      psql_pg -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME'" >/dev/null || return 1
      psql_pg -d postgres -c "ALTER DATABASE $DB_NAME RENAME TO $2" || return 1
    else
      psql_pg -d postgres -c "DROP DATABASE $DB_NAME WITH (FORCE)" || return 1
    fi
  fi
  psql_pg -d postgres -c "ALTER DATABASE $1 RENAME TO $DB_NAME" || return 1
}

phase_anwendung() {
  schluessel_verwerfen   # Sicherheitsnetz: ein Swap darf nie aktiviert werden, solange der Schlüssel im Arbeitsspeicher ist
  if [ "$P_SWAP_MB" -gt 0 ]; then
    if trocken; then info "[dry-run] Swap ${P_SWAP_MB} MB über einrichtung-swap.sh"; else bash "$REPO/deploy/einrichtung-swap.sh" --size-mb "$P_SWAP_MB"; fi
  else
    info "Swap: nicht angefordert (SWAP_MB=0). Der Server hat meist 2 GB RAM; SWAP_MB=1024 wird empfohlen (Bau und Sicherung)."
  fi
  if trocken; then
    info "[dry-run] deploy.sh als $LX_USER (ohne git pull, damit ein festgelegter Code-Stand bleibt): npm ci, Bau, Start, Migrationen (lx-fampad-migrate.service), Health-Check"
    info "[dry-run] systemctl enable lx-fampad; einrichtung-auth.sh erneut (Leserecht auf drizzle.__drizzle_migrations)"
    info "[dry-run] lx-fampad-weather.service installieren (gestartet wird sie nur mit --wetter-starten)"
    pruefpunkt "API antwortet mit db ok, alle Migrationen angewendet" true
    return 0
  fi
  [ -f "$ENV_FILE" ] && [ -f "$MIGRATE_ENV" ] || fehler "env/migrate.env fehlen (Phasen konfiguration und datenbank zuerst)"
  info "deploy.sh (Bau und Start; dauert einige Minuten)"
  sudo -u "$LX_USER" -H env DEPLOY_OHNE_PULL=1 sg "$SVC_USER" -c "bash '$REPO/deploy/deploy.sh'" || {
    journalctl -u lx-fampad-migrate -u lx-fampad -n 40 --no-pager >&2 || true
    fehler "deploy.sh fehlgeschlagen (Meldungen oben; häufig: Migration passt nicht zum Code-Stand, GIT_REF prüfen)"
  }
  sysd enable lx-fampad
  bash "$REPO/deploy/einrichtung-auth.sh" >/dev/null
  wetter_einheit
  pruefpunkt "API antwortet mit db ok" http_enthaelt http://127.0.0.1:4400/api/v1/health '"db":"ok"'
  pruefpunkt "alle Migrationen angewendet" migrationen_ok
}
migrationen_ok() {
  local erwartet gelaufen
  erwartet="$(grep -c '"tag"' "$REPO/server/drizzle/meta/_journal.json")"
  gelaufen="$(psql_pg -d "$DB_NAME" -tAc 'select count(*) from drizzle.__drizzle_migrations')"
  [ "$erwartet" -gt 0 ] && [ "$gelaufen" -ge "$erwartet" ]
}
wetter_einheit() {
  local unit=lx-fampad-weather.service src="$REPO/deploy/lx-fampad-weather.service" ziel=/etc/systemd/system/lx-fampad-weather.service
  [ -f "$src" ] || { info "Wetter-Einheit nicht im Checkout (älterer Code-Stand): übersprungen."; return 0; }
  cp "$src" "$TMP_ARBEIT/$unit"
  if [ "$OHNE_SYSTEMD" = 0 ]; then systemd-analyze verify "$TMP_ARBEIT/$unit" || fehler "systemd-analyze verify meldet Fehler in $unit"; fi
  if ! cmp -s "$TMP_ARBEIT/$unit" "$ziel"; then install -m 644 -o root -g root "$TMP_ARBEIT/$unit" "$ziel"; sysd daemon-reload; fi
  # sudo-Regel für den Wetter-Neustart nur mit --wetter-starten (oder wenn sie schon da war); sonst kann deploy.sh den Wetter-Dienst nie versehentlich starten
  sudoers_schreiben "$WETTER_STARTEN"
  if grep -qE '^WEATHER_ENABLED=(true|1)[[:space:]]*$' "$ENV_FILE"; then
    if [ "$WETTER_STARTEN" = 1 ]; then
      sysd enable "$unit"
      sysd restart "$unit"   # auch im Wiederholungslauf: neue Einheit/neuer Code wird wirksam (enable --now würde einen laufenden Dienst nicht neu starten)
      info "Wetter-Dienst gestartet (neu gestartet)."
    else
      offen "Wetter-Dienst ist installiert, aber NICHT gestartet: Netatmo rotiert das Refresh-Token, zwei Server dürfen es nicht gleichzeitig abrufen. Erst wenn der alte Server aus ist: sudo systemctl enable --now lx-fampad-weather (oder dieses Skript mit --wetter-starten). Das gesicherte Token ist evtl. veraltet: dann sudo node --env-file=$ENV_FILE /srv/fampad/server/dist/cli/weather-setup.js"
    fi
  else
    info "Wetter: WEATHER_ENABLED nicht gesetzt, Dienst nur installiert (aus)."
  fi
}

phase_ntfy() {
  ntfy_pins_lesen || { NTFY_VERSION="(wird nach dem Klonen aus deploy/einrichtung-ntfy.sh gelesen)"; NTFY_FPR="(dito)"; }
  local cfg=/etc/ntfy/server.yml port=2586 token_file="$ETC_DIR/ntfy-token" pw_file="$ETC_DIR/ntfy-family-password" local_url=http://127.0.0.1:2586
  if trocken; then
    info "[dry-run] ntfy $NTFY_VERSION aus archive.ntfy.sh (Schlüssel $NTFY_FPR prüfen, Fallback: .deb mit SHA-256), apt-mark hold, Dienst startet nie vor der Konfiguration"
    info "[dry-run] /etc/ntfy/server.yml aus dem Repository (nur 127.0.0.1:$port, deny-all), Härtung als Drop-in"
    if [ "$RESTORE" = 1 ]; then info "[dry-run] ntfy-Datenbank (Benutzer, Token): kommt schon aus der Phase konfiguration (nur solange /var/lib/ntfy/user.db fehlt)"; fi
    info "[dry-run] ntfy wird nur neu gestartet, wenn er nicht läuft oder sich Konfiguration/Härtung ändern"
    info "[dry-run] Benutzer fampad-server (nur Schreiben auf fampad-* und up*, Token), fampad-family (nur Lesen auf up*); NTFY_URL/NTFY_TOKEN in der env"
    pruefpunkt "ntfy: anonym 401/403, Token darf auf fampad-* schreiben, nicht auf fremde Themen" true
    return 0
  fi
  [ -f "$ENV_FILE" ] || fehler "$ENV_FILE fehlt"
  # Installation
  local installiert
  installiert="$(dpkg-query -W -f='${Version}' ntfy 2>/dev/null || true)"
  if [ "$installiert" = "$NTFY_VERSION" ]; then info "ntfy $NTFY_VERSION ist installiert."
  elif [ -n "$installiert" ]; then info "ntfy $installiert ist installiert (Ziel $NTFY_VERSION); das Skript ändert die Version nie (Aktualisierung: deploy/README.md Abschnitt 7)."
  else ntfy_installieren; fi
  # Konfiguration, Verzeichnisse, Härtung
  id ntfy >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/ntfy --shell /usr/sbin/nologin ntfy
  install -d -m 750 -o ntfy -g ntfy /var/lib/ntfy /var/cache/ntfy
  install -d -m 755 -o root -g root /etc/ntfy
  local neustart=0
  systemctl is-active --quiet ntfy || neustart=1
  if [ ! -f "$cfg" ] || ! cmp -s "$REPO/deploy/ntfy/server.yml" "$cfg"; then neustart=1; fi
  if [ -f "$cfg" ] && ! cmp -s "$REPO/deploy/ntfy/server.yml" "$cfg"; then cp -p "$cfg" "$cfg.vor-neuinstallation.$(date +%Y%m%d-%H%M%S).bak"; fi
  install -m 640 -o root -g ntfy "$REPO/deploy/ntfy/server.yml" "$cfg"
  install -d -m 755 /etc/systemd/system/ntfy.service.d
  cat > "$TMP_ARBEIT/haertung.conf" <<'EOF'
[Service]
User=ntfy
Group=ntfy
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=/var/lib/ntfy /var/cache/ntfy
UMask=0077
EOF
  if ! cmp -s "$TMP_ARBEIT/haertung.conf" /etc/systemd/system/ntfy.service.d/haertung.conf; then
    install -m 644 -o root -g root "$TMP_ARBEIT/haertung.conf" /etc/systemd/system/ntfy.service.d/haertung.conf
    neustart=1
  fi
  sysd daemon-reload
  # Die gesicherte ntfy-Benutzerdatenbank (Benutzer, Rechte, Token) hat die Phase konfiguration schon entpackt (dort ist der Schlüssel noch da); hier gehört sie nur noch dem Benutzer ntfy
  chown -hR ntfy:ntfy /var/lib/ntfy; chmod 750 /var/lib/ntfy
  sysd enable ntfy
  # ntfy wird nur neu gestartet, wenn er nicht lief oder sich Konfiguration/Härtung geändert haben (ein Wiederholungslauf unterbricht die Wecker nicht)
  if [ "$neustart" = 1 ]; then sysd restart ntfy; else info "ntfy läuft mit unveränderter Konfiguration: kein Neustart."; fi
  local ok=0
  for _ in $(seq 1 20); do
    if http_enthaelt "$local_url/v1/health" '"healthy":true'; then ok=1; break; fi
    sleep 1
  done
  [ "$ok" = 1 ] || { journalctl -u ntfy -n 30 --no-pager >&2 || true; fehler "ntfy startet nicht (Log oben)"; }
  info "ntfy läuft auf 127.0.0.1:$port."
  ntfy_benutzer_einrichten "$cfg" "$token_file" "$pw_file"
  ntfy_env_eintragen "$token_file"
  ntfy_lokale_probe "$token_file" "$pw_file" "$local_url"
}
ntfy_als_ntfy() { runuser -u ntfy -- ntfy "$@"; }
ntfy_installieren() {
  local fpr_ok
  # während der Installation darf der Dienst nicht mit der Standardkonfiguration starten (Standard: Port 80)
  if [ ! -e /usr/sbin/policy-rc.d ]; then
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n[ "$1" = ntfy ] && exit 101\nexit 0\n' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    POLICY_RC_ANGELEGT=1
  fi
  mkdir -p /etc/apt/keyrings
  curl -fsSL --max-time 60 -o "$TMP_ARBEIT/ntfy.gpg" "$NTFY_APT_URL/keyring.gpg"
  fpr_ok="$(gpg --batch --show-keys --with-colons "$TMP_ARBEIT/ntfy.gpg" | awk -F: '$1=="pub"{p=1} $1=="fpr"&&p{print $10; p=0}')"
  [ "$fpr_ok" = "$NTFY_FPR" ] || fehler "Fingerabdruck des ntfy-Schlüssels stimmt nicht (erwartet $NTFY_FPR, gefunden: ${fpr_ok:-keiner}). Nichts installiert."
  install -m 644 -o root -g root "$TMP_ARBEIT/ntfy.gpg" /etc/apt/keyrings/ntfy.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/ntfy.gpg] $NTFY_APT_URL stable main" > /etc/apt/sources.list.d/ntfy.list
  cat > /etc/apt/preferences.d/ntfy <<'EOF'
Package: *
Pin: origin archive.ntfy.sh
Pin-Priority: 1

Package: ntfy
Pin: origin archive.ntfy.sh
Pin-Priority: 500
EOF
  apt-get update -qq
  if apt_version_da ntfy "$NTFY_VERSION"; then
    apt_installieren -o Dpkg::Options::=--force-confold "ntfy=$NTFY_VERSION"
  else
    info "$NTFY_VERSION steht nicht (mehr) im Repository; Fallback: Release-.deb mit gepinnter SHA-256."
    curl -fsSL --max-time 300 -o "$TMP_ARBEIT/ntfy.deb" "$NTFY_DEB_URL"
    echo "$NTFY_DEB_SHA256  $TMP_ARBEIT/ntfy.deb" | sha256sum -c - >/dev/null || fehler "Prüfsumme des .deb stimmt nicht, nichts installiert"
    apt_installieren -o Dpkg::Options::=--force-confold "$TMP_ARBEIT/ntfy.deb"
  fi
  apt-mark hold ntfy >/dev/null
  if [ "$POLICY_RC_ANGELEGT" = 1 ]; then rm -f /usr/sbin/policy-rc.d; POLICY_RC_ANGELEGT=0; fi
  info "ntfy $NTFY_VERSION installiert und per apt-mark hold festgehalten."
}
ntfy_benutzer_einrichten() { # $1 cfg, $2 Token-Datei, $3 Passwort-Datei
  local cfg="$1" token_file="$2" pw_file="$3" ulist pw tlist out token=""
  ulist="$(ntfy_als_ntfy user --config "$cfg" list)"
  if ! grep -q '^user fampad-server ' <<<"$ulist"; then
    pw="$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n')"
    NTFY_PASSWORD="$pw" ntfy_als_ntfy user --config "$cfg" add --role=user fampad-server >/dev/null
    pw=""
    info "ntfy-Benutzer fampad-server angelegt (Zugriff nur per Token)."
  fi
  ntfy_als_ntfy access --config "$cfg" fampad-server 'fampad-*' write-only >/dev/null
  ntfy_als_ntfy access --config "$cfg" fampad-server 'up*' write-only >/dev/null
  if [ -s "$token_file" ]; then
    token="$(head -n 1 "$token_file" | tr -d '[:space:]')"
    tlist="$(ntfy_als_ntfy token --config "$cfg" list)"
    if [[ "$token" =~ ^tk_[A-Za-z0-9]+$ ]] && grep -Fq -- "- $token " <<<"$tlist"; then info "Token in $token_file ist gültig."
    else info "Token in $token_file ist dem Server unbekannt, wird ersetzt."; token=""; fi
  fi
  if [ -z "$token" ]; then
    out="$(ntfy_als_ntfy token --config "$cfg" add --label=lx-fampad fampad-server)"
    token="$(grep -o 'tk_[A-Za-z0-9]\+' <<<"$out" | head -n 1)"
    [ -n "$token" ] || fehler "Token konnte nicht angelegt werden"
    ( umask 077; printf '%s\n' "$token" > "$token_file" )
    out=""
    info "neues Token angelegt."
  fi
  token=""
  chown root:root "$token_file"; chmod 600 "$token_file"
  # fampad-family: gemeinsamer Lese-Benutzer der Handys (nur up*, nur lesen); Passwort bleibt auf dem Server
  if ! grep -q '^user fampad-family ' <<<"$ulist"; then
    if [ -s "$pw_file" ]; then
      offen "ntfy-Benutzer fampad-family war in der ntfy-Datenbank nicht vorhanden, aber $pw_file existierte (aus der Sicherung?): das Passwort wird NEU gesetzt und die Datei ersetzt. In allen ntfy-Apps der Familie das neue Passwort eintragen (sudo less $pw_file, nicht cat)"
    fi
    pw="$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')"
    NTFY_PASSWORD="$pw" ntfy_als_ntfy user --config "$cfg" add --role=user fampad-family >/dev/null
    ( umask 077; printf '%s\n' "$pw" > "$pw_file" )
    pw=""
    info "ntfy-Benutzer fampad-family angelegt, Passwort in $pw_file (root, nicht angezeigt)."
  elif [ ! -s "$pw_file" ]; then
    pw="$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')"
    NTFY_PASSWORD="$pw" ntfy_als_ntfy user --config "$cfg" change-pass fampad-family >/dev/null
    ( umask 077; printf '%s\n' "$pw" > "$pw_file" )
    pw=""
    offen "ntfy-Passwort von fampad-family wurde neu gesetzt (Datei fehlte): in allen ntfy-Apps der Familie neu eintragen (sudo cat $pw_file, persönlich weitergeben)"
  fi
  chown root:root "$pw_file"; chmod 600 "$pw_file"
  ntfy_als_ntfy access --config "$cfg" fampad-family 'up*' read-only >/dev/null
}
ntfy_env_eintragen() { # $1 Token-Datei
  local token neu_url=http://127.0.0.1:2586 geaendert=0
  token="$(head -n 1 "$1" | tr -d '[:space:]')"
  if [ "$(env_wert "$ENV_FILE" NTFY_URL)" != "$neu_url" ]; then ENV_WERT="$neu_url" env_setzen "$ENV_FILE" NTFY_URL; geaendert=1; fi
  if [ "$(env_wert "$ENV_FILE" NTFY_TOKEN)" != "$token" ]; then ENV_WERT="$token" env_setzen "$ENV_FILE" NTFY_TOKEN; geaendert=1; fi
  token=""
  if [ "$geaendert" = 1 ]; then
    info "NTFY_URL/NTFY_TOKEN in $ENV_FILE eingetragen; lx-fampad wird neu gestartet."
    sysd restart lx-fampad
  else
    info "NTFY_URL/NTFY_TOKEN in $ENV_FILE sind aktuell."
  fi
}
ntfy_lokale_probe() { # $1 Token-Datei, $2 Passwort-Datei, $3 lokale URL
  local token pw code
  token="$(head -n 1 "$1" | tr -d '[:space:]')"; pw="$(head -n 1 "$2" | tr -d '[:space:]')"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -d x "$3/fampad-pruefung" || true)"
  [ "$code" = 401 ] || [ "$code" = 403 ] || fehler "ntfy: anonymes Schreiben ist nicht verboten (HTTP $code)"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - -d 'Prüfung' "$3/fampad-pruefung" || true)"
  [ "$code" = 200 ] || fehler "ntfy: Token darf nicht auf fampad-* schreiben (HTTP $code)"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - -d 'Prüfung' "$3/fremdes-thema" || true)"
  [ "$code" = 401 ] || [ "$code" = 403 ] || fehler "ntfy: Token darf auf fremde Themen schreiben (HTTP $code)"
  code="$(printf 'user = "fampad-family:%s"\n' "$pw" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$3/upPruefung0000/json?poll=1" || true)"
  [ "$code" = 200 ] || fehler "ntfy: fampad-family darf up* nicht lesen (HTTP $code)"
  code="$(printf 'user = "fampad-family:%s"\n' "$pw" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - -d x "$3/upPruefung0000" || true)"
  [ "$code" = 401 ] || [ "$code" = 403 ] || fehler "ntfy: fampad-family darf auf up* schreiben (HTTP $code)"
  token=""; pw=""
  info "Prüfpunkt ok: ntfy-Rechte (anonym 401/403, Server-Token schreibt, fremdes Thema verboten, fampad-family nur lesen auf up*)."
}

# --- Caddy -------------------------------------------------------------------------------------------------------------------------
phase_caddy() {
  local zustand dns_ok=1 h hauptdatei=/etc/caddy/Caddyfile
  zustand="$(caddy_haupt_zustand "$hauptdatei")"
  if ! command -v caddy >/dev/null; then
    if trocken; then info "[dry-run] Caddy $CADDY_PKG_VERSION aus dl.cloudsmith.io (Schlüssel $CADDY_FPR prüfen, installieren, apt-mark hold)"; zustand="standard"
    else caddy_installieren; zustand="$(caddy_haupt_zustand "$hauptdatei")"; fi
  else info "Caddy vorhanden: $(caddy version 2>/dev/null | awk '{print $1}')"; fi
  for h in "$DOMAIN" "$NTFY_DOMAIN"; do
    if [ "$DNS_UEBERSPRINGEN" = 1 ]; then info "DNS-Prüfung übersprungen (--dns-pruefung-ueberspringen)"; continue; fi
    if dns_pruefen "$h"; then info "DNS ok: $h"; else dns_ok=0; info "DNS: $h $DNS_GRUND"; fi
  done
  case "$zustand" in
    import) info "Haupt-Caddyfile bindet conf.d bereits ein (unverändert)." ;;
    fehlt|standard)
      if trocken; then info "[dry-run] Haupt-Caddyfile ($zustand) durch eine Datei ersetzen, die nur 'import /etc/caddy/conf.d/*.caddy' enthält (Kopie des alten bleibt)"
      else caddy_hauptdatei_schreiben "$hauptdatei"; fi ;;
    fremd)
      offen "Haupt-Caddyfile ($hauptdatei) ist nicht das Standard-Caddyfile und enthält die Zeile 'import /etc/caddy/conf.d/*.caddy' nicht (lx-labs.dev?). Das Skript ändert es nie. Füge die Zeile von Hand am Ende ein, prüfe mit 'caddy validate --config $hauptdatei', lade mit 'systemctl reload caddy' und wiederhole dann: bootstrap-server.sh --phase caddy"
      return 0 ;;
  esac
  if [ "$dns_ok" = 0 ]; then
    offen "DNS zeigt noch nicht auf diesen Server: Caddy bekommt noch keine Site-Dateien (sonst scheitert die Zertifikatsausstellung und zählt gegen die Let's-Encrypt-Grenzen). Nach dem Umschalten: bootstrap-server.sh --phase caddy,pruefung"
    return 0
  fi
  caddy_sites_installieren "$hauptdatei"
}
caddy_installieren() {
  local key="$TMP_ARBEIT/caddy.key" got
  curl -fsSL --max-time 60 -o "$key" "$CADDY_KEY_URL"
  got="$(gpg --batch --show-keys --with-colons "$key" | awk -F: '$1=="pub"{p=1} $1=="fpr"&&p{print $10; p=0}')"
  [ "$got" = "$CADDY_FPR" ] || fehler "Fingerabdruck des Caddy-Schlüssels stimmt nicht (erwartet $CADDY_FPR, gefunden: ${got:-keiner}). Nichts installiert."
  gpg --batch --dearmor < "$key" > /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt_version_da caddy "$CADDY_PKG_VERSION" || fehler "caddy=$CADDY_PKG_VERSION steht nicht (mehr) im Caddy-Repository. Verfügbar (neueste zuerst): $(apt-cache madison caddy | awk '{print $3}' | head -n 5 | tr '\n' ' '). Eine bewusst gewählte 2.x-Version trägst du als CADDY_PKG_VERSION in die Parameterdatei ein (und in docs/VERSIONEN.md); nichts wurde installiert."
  apt_installieren "caddy=$CADDY_PKG_VERSION"
  apt-mark hold caddy >/dev/null
  info "Caddy $CADDY_PKG_VERSION installiert (Schlüssel-Fingerabdruck geprüft, per apt-mark hold festgehalten)."
}
caddy_hauptdatei_schreiben() { # $1 Pfad; nur für fehlendes oder unverändertes Standard-Caddyfile
  local f="$1" bak=""
  if [ -e "$f" ]; then bak="$f.vor-neuinstallation.$(date +%Y%m%d-%H%M%S)"; cp -p "$f" "$bak"; fi
  printf '%s\n' "# Angelegt von lx-fampad/deploy/neuinstallation/bootstrap-server.sh auf einem frischen Server." \
    "# Die Sites liegen in conf.d (fampad.caddy, ntfy.caddy). Diese Zeile darf ein anderes Deploy nicht entfernen (deploy/README.md, Schritt 6)." \
    "import /etc/caddy/conf.d/*.caddy" > "$TMP_ARBEIT/Caddyfile.neu"
  mkdir -p /etc/caddy/conf.d
  caddy validate --config "$TMP_ARBEIT/Caddyfile.neu" --adapter caddyfile >/dev/null 2>&1 || fehler "caddy validate meldet Fehler im neuen Haupt-Caddyfile"
  install -m 644 -o root -g root "$TMP_ARBEIT/Caddyfile.neu" "$f"
  sysd reload caddy || { [ -z "$bak" ] || cp -p "$bak" "$f"; fehler "Caddy lässt sich nicht neu laden; altes Haupt-Caddyfile zurückgespielt"; }
  info "Haupt-Caddyfile angelegt (nur die Importzeile)${bak:+; Kopie des bisherigen: $bak}."
}
caddy_sites_installieren() { # $1 Haupt-Caddyfile
  local haupt="$1" ts quelle ziel name haupt_sum lx_labs=0 head_vorher=""
  ts="$(date +%Y%m%d-%H%M%S)"
  if trocken; then
    info "[dry-run] fampad.caddy und ntfy.caddy aus dem Repository: erst einzeln mit caddy validate prüfen, atomar nach /etc/caddy/conf.d installieren, Gesamtkonfiguration prüfen, dann reload, danach Zertifikate/Health abwarten; bei jedem Fehler Rückfall"
    return 0
  fi
  [ "$OHNE_SYSTEMD" = 0 ] || { info "[ohne systemd] Site-Dateien werden nur geprüft, nicht installiert."; caddy_kandidaten_pruefen; return 0; }
  caddy_kandidaten_pruefen
  haupt_sum="$(sha256sum "$haupt" | cut -d' ' -f1)"
  if grep -qE '^[[:space:]]*(www\.)?lx-labs\.dev' "$haupt"; then
    lx_labs=1
    head_vorher="$(curl -sI --max-time 10 https://lx-labs.dev 2>/dev/null | head -n 1 | tr -d '\r' || true)"
    info "lx-labs.dev vor der Änderung: ${head_vorher:-keine Antwort}"
  fi
  CADDY_ARBEITSLISTE=()
  CADDY_ROLLBACK_AKTIV=1
  for name in fampad ntfy; do
    ziel="/etc/caddy/conf.d/$name.caddy"
    if [ "$name" = fampad ]; then quelle="$REPO/deploy/Caddyfile"; else quelle="$REPO/deploy/ntfy/ntfy.caddy"; fi
    if [ -f "$ziel" ]; then
      if cmp -s "$quelle" "$ziel"; then info "$ziel ist aktuell."; continue; fi
      cp -p "$ziel" "$ziel.vor-neuinstallation.$ts.bak"
      CADDY_ARBEITSLISTE+=("$ziel|$ziel.vor-neuinstallation.$ts.bak")
    else
      CADDY_ARBEITSLISTE+=("$ziel|")
    fi
    install -m 644 -o root -g root "$quelle" "$ziel.neu"   # endet nicht auf .caddy: wird nicht importiert
    mv -f "$ziel.neu" "$ziel"
  done
  caddy validate --config "$haupt" --adapter caddyfile >/dev/null 2>&1 || { caddy_zuruecksetzen; fehler "caddy validate meldet Fehler in der Gesamtkonfiguration; Rückfall durchgeführt"; }
  sysd reload caddy || { caddy_zuruecksetzen; fehler "Caddy-Reload fehlgeschlagen; Rückfall durchgeführt"; }
  if [ "$lx_labs" = 1 ]; then
    sleep 3
    if ! curl -fsI --max-time 10 https://lx-labs.dev >/dev/null; then caddy_zuruecksetzen; fehler "lx-labs.dev antwortet nach dem Reload nicht mehr; Rückfall durchgeführt"; fi
    info "lx-labs.dev antwortet weiter: $(curl -sI --max-time 10 https://lx-labs.dev | head -n 1 | tr -d '\r')"
  fi
  info "Zertifikate abwarten (bis zu 90 s) ..."
  local ok=0
  for _ in $(seq 1 45); do
    if http_enthaelt "https://$DOMAIN/api/v1/health" '"db":"ok"' && http_enthaelt "https://$NTFY_DOMAIN/v1/health" '"healthy":true'; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" != 1 ]; then caddy_zuruecksetzen; fehler "https://$DOMAIN oder https://$NTFY_DOMAIN antwortet nicht (DNS/Zertifikat?). Rückfall durchgeführt. Mindestens 1 Stunde warten (Let's-Encrypt-Grenze), dann --phase caddy wiederholen; journalctl -u caddy -n 50"; fi
  [ "$(sha256sum "$haupt" | cut -d' ' -f1)" = "$haupt_sum" ] || { caddy_zuruecksetzen; fehler "Haupt-Caddyfile hat sich während des Laufs geändert (nicht durch dieses Skript)"; }
  CADDY_ROLLBACK_AKTIV=0
  info "Caddy läuft; https://$DOMAIN und https://$NTFY_DOMAIN antworten."
}
caddy_kandidaten_pruefen() {
  local f
  for f in "$REPO/deploy/Caddyfile" "$REPO/deploy/ntfy/ntfy.caddy"; do
    cp "$f" "$TMP_ARBEIT/kandidat.caddy"
    caddy validate --config "$TMP_ARBEIT/kandidat.caddy" --adapter caddyfile >/dev/null 2>&1 || fehler "caddy validate meldet Fehler in $f (nichts wurde verändert)"
  done
  info "Site-Dateien aus dem Repository sind gültig (caddy validate)."
}
caddy_zuruecksetzen() {
  local e ziel bak
  CADDY_ROLLBACK_AKTIV=0
  echo "!!  Caddy-Rückfall: Site-Dateien dieses Laufs werden zurückgesetzt (das Haupt-Caddyfile wurde hier nie angefasst)." >&2
  for e in "${CADDY_ARBEITSLISTE[@]}"; do
    ziel="${e%%|*}"; bak="${e#*|}"
    rm -f "$ziel.neu"
    if [ -n "$bak" ] && [ -f "$bak" ]; then cp -p "$bak" "$ziel" || rm -f "$ziel"; else rm -f "$ziel"; fi
  done
  sysd reload caddy || true
  if [ "$OHNE_SYSTEMD" = 0 ]; then echo "    lx-labs.dev: $(curl -sI --max-time 10 https://lx-labs.dev 2>/dev/null | head -n 1 | tr -d '\r')" >&2; fi
}

# backup.conf entsteht nur aus den (geprüften) Parametern, nie aus der Sicherung: lx-fampad-backup.sh lädt sie als root per "source"
backup_conf_schreiben() {
  local conf=/etc/lx-fampad-backup/backup.conf tmp="$TMP_ARBEIT/backup.conf"
  [ -n "$P_BACKUP_KEEP$P_BACKUP_INCLUDE_APK$P_BACKUP_INCLUDE_FILES" ] || return 0
  {
    echo "# Von deploy/neuinstallation/bootstrap-server.sh aus der Parameterdatei geschrieben (nicht aus der Sicherung übernommen)."
    [ -z "$P_BACKUP_KEEP" ] || echo "KEEP=$P_BACKUP_KEEP"
    [ -z "$P_BACKUP_INCLUDE_APK" ] || echo "INCLUDE_APK=$P_BACKUP_INCLUDE_APK"
    [ -z "$P_BACKUP_INCLUDE_FILES" ] || echo "INCLUDE_FILES=$P_BACKUP_INCLUDE_FILES"
  } > "$tmp"
  mkdir -p /etc/lx-fampad-backup
  install -m 644 -o root -g root "$tmp" "$conf"
  info "backup.conf aus den Parametern geschrieben."
}
phase_sicherung() {
  local args=() r
  if [ -z "$P_BACKUP_AGE_RECIPIENTS" ] && [ ! -s /etc/lx-fampad-backup/recipients.txt ]; then
    offen "Tägliche Sicherung NICHT eingerichtet (BACKUP_AGE_RECIPIENTS fehlt und es gibt keine wiederhergestellte recipients.txt): ohne sie hat der neue Server keine Sicherung. Parameter ergänzen und --phase sicherung wiederholen"
    return 0
  fi
  [ "$OHNE_SYSTEMD" = 0 ] || args+=(--ohne-systemd)
  if [ -n "$P_BACKUP_AGE_RECIPIENTS" ]; then
    IFS=',' read -ra teile <<<"$P_BACKUP_AGE_RECIPIENTS"; for r in "${teile[@]}"; do args+=(--age-recipient "$r"); done
  else args+=(--age-recipient-file /etc/lx-fampad-backup/recipients.txt); fi
  if [ -n "$P_BACKUP_AGE_RECIPIENTS_CONFIG" ]; then
    IFS=',' read -ra teile <<<"$P_BACKUP_AGE_RECIPIENTS_CONFIG"; for r in "${teile[@]}"; do args+=(--age-recipient-config "$r"); done
  fi
  if [ -n "$P_BACKUP_NAS_PUBKEY" ]; then args+=(--nas-pubkey "$P_BACKUP_NAS_PUBKEY" --nas-ip "$P_BACKUP_NAS_IP")
  elif [ ! -s /var/lib/lxbackup/.ssh/authorized_keys ]; then
    offen "NAS-Abholung nicht eingerichtet (BACKUP_NAS_PUBKEY/BACKUP_NAS_IP fehlen): einrichtung-backup.sh verlangt beim ersten Lauf beides"
    return 0
  fi
  if trocken; then
    info "[dry-run] bash $REPO/deploy/backup/einrichtung-status.sh"
    info "[dry-run] bash $REPO/deploy/backup/einrichtung-backup.sh ${args[*]//age1*/age1…} (installiert Skript, Dienst, Timer 03:30, Benutzer lxbackup mit rrsync -ro; Probelauf der Sicherung)"
    return 0
  fi
  backup_conf_schreiben
  bash "$REPO/deploy/backup/einrichtung-status.sh"
  bash "$REPO/deploy/backup/einrichtung-backup.sh" "${args[@]}"
  pruefpunkt "Sicherungs-Timer aktiv, Statusdatei vorhanden" bash -c "[ -s /var/backups/lx-fampad/status ] && ( [ '$OHNE_SYSTEMD' = 1 ] || systemctl is-active --quiet lx-fampad-backup.timer )"
  offen "Die neue Sicherung ist UNGEPRÜFT, bis du sie mit dem privaten age-Schlüssel testest (deploy/backup/wiederherstellung-test.sh); NAS: known_hosts auf den neuen Host-Schlüssel umstellen (docs/NEUINSTALLATION.md)"
}

# Eine Kontrolle der Abschlussprüfung: $1 Text bei Erfolg, $2 Text bei Misserfolg, Rest Befehl
PRUEFUNG_OK=1
kontrolle() {
  local ja="$1" nein="$2"; shift 2
  if "$@" >/dev/null 2>&1; then info "ok: $ja"; else info "FEHLT: $nein"; PRUEFUNG_OK=0; fi
}
api_ok() { http_enthaelt "$1" "$2"; }
nur_lokal_ports() { ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(4400|2586|5432)$' | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; }
datei_modus() { [ "$(stat -c %a "$1")" = "$2" ]; }
env_rechte_ok() { [ "$(stat -c %U:%G:%a "$ENV_FILE")" = root:root:600 ]; }
# SSH: nur lesen und melden (die sshd-Konfiguration ändert das Skript nie)
ssh_haertung_melden() {
  local t pw root
  command -v sshd >/dev/null || { info "sshd nicht gefunden: SSH-Einstellungen nicht geprüft."; return 0; }
  t="$(sshd -T 2>/dev/null || true)"
  [ -n "$t" ] || { info "sshd -T liefert nichts: SSH-Einstellungen nicht geprüft."; return 0; }
  pw="$(awk '$1 == "passwordauthentication" { print $2 }' <<<"$t")"
  root="$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$t")"
  [ "$pw" = no ] || offen "SSH erlaubt die Anmeldung mit Passwort (PasswordAuthentication $pw): nur Schlüssel zulassen (PasswordAuthentication no), sonst ist der Server per Passwort-Raten angreifbar"
  case "$root" in no|prohibit-password|without-password) ;; *) offen "SSH erlaubt root die Anmeldung mit Passwort (PermitRootLogin $root): auf prohibit-password oder no stellen, sobald dein Benutzer lx per Schlüssel funktioniert" ;; esac
  command -v fail2ban-client >/dev/null || info "Hinweis: fail2ban ist nicht installiert (sperrt wiederholt falsche SSH-Anmeldungen; optional: apt install fail2ban)."
}
lx_labs_koexistenz() { [ -f /etc/caddy/Caddyfile ] && grep -qE '^[[:space:]]*(www\.)?lx-labs\.dev' /etc/caddy/Caddyfile; }
phase_pruefung() {
  if trocken; then
    info "[dry-run] Abschlussprüfung: Dienste aktiv, Health, Ports nur lokal, Dateirechte, HTTPS (wenn DNS passt), SSH-Einstellungen (nur melden), Firewall-Hinweis"
    return 0
  fi
  local dienst
  PRUEFUNG_OK=1
  if [ "$OHNE_SYSTEMD" = 0 ]; then
    for dienst in postgresql lx-fampad ntfy caddy; do kontrolle "$dienst ist aktiv" "$dienst ist NICHT aktiv" systemctl is-active --quiet "$dienst"; done
  fi
  kontrolle "API lokal antwortet, Datenbank ok" "API lokal antwortet nicht mit db ok" api_ok http://127.0.0.1:4400/api/v1/health '"db":"ok"'
  kontrolle "ntfy lokal antwortet" "ntfy lokal antwortet nicht" api_ok http://127.0.0.1:2586/v1/health '"healthy":true'
  kontrolle "Ports 4400, 2586, 5432 nur auf localhost" "ein interner Port ist von außen erreichbar (ss -ltnp prüfen)" nur_lokal_ports
  kontrolle "env gehört root:root, Modus 600" "env hat falsche Rechte" env_rechte_ok
  kontrolle "migrate.env hat Modus 600" "migrate.env fehlt oder hat falsche Rechte" datei_modus "$MIGRATE_ENV" 600
  ssh_haertung_melden
  if [ "$OHNE_SYSTEMD" = 1 ]; then
    info "Testmodus (--ohne-systemd): keine Prüfung gegen die Internet-Adressen ($DOMAIN, lx-labs.dev)."
  elif dns_pruefen "$DOMAIN" && dns_pruefen "$NTFY_DOMAIN"; then
    kontrolle "https://$DOMAIN antwortet" "https://$DOMAIN antwortet nicht" api_ok "https://$DOMAIN/api/v1/health" '"db":"ok"'
    kontrolle "https://$NTFY_DOMAIN antwortet" "https://$NTFY_DOMAIN antwortet nicht" api_ok "https://$NTFY_DOMAIN/v1/health" '"healthy":true'
    if lx_labs_koexistenz; then kontrolle "lx-labs.dev antwortet weiter" "lx-labs.dev antwortet NICHT" curl -fsI --max-time 10 https://lx-labs.dev; fi
  else
    info "HTTPS-Prüfung übersprungen (DNS zeigt noch nicht auf diesen Server)."
  fi
  [ "$PRUEFUNG_OK" = 1 ] || fehler "Abschlussprüfung nicht bestanden (Meldungen oben)"
  info "Abschlussprüfung bestanden."
}

mensch_liste() {
  echo
  echo "==> Das musst du noch selbst tun (ausführlich: docs/NEUINSTALLATION.md)"
  echo "    1. DNS bei Cloudflare: A-Einträge 'familyhub' und 'ntfy.familyhub' (DNS only) auf die IP dieses Servers; danach: bootstrap-server.sh --phase caddy,pruefung"
  echo "    2. Firewall: nur 22, 80, 443 offen (Anbieter-Firewall oder ufw); SSH-Härtung (nur Schlüssel, kein Passwort, optional fail2ban) wie bei lx-labs"
  echo "    3. Web-App hochladen (vom PC):  deploy/deploy-web.sh   (SSH-Alias auf den neuen Server zeigen lassen)"
  echo "    4. NAS: Host-Schlüssel des neuen Servers eintragen (ssh-keygen -R, ssh-keyscan; Fingerabdruck vergleichen), Pull-Probelauf"
  echo "    5. GitHub: Secrets VPS_KNOWN_HOSTS (neuer Host-Schlüssel) und ggf. VPS_HOST; CI-Schlüssel aus CI_DEPLOY_PUBKEY muss zum Secret VPS_SSH_KEY passen"
  echo "    6. Karte (1,1 GB) neu erzeugen und hochladen (deploy/README.md Abschnitt 11), Noto-Fallback-Schriften nach /srv/fampad/font-fallback (Abschnitt 8)"
  if [ "$RESTORE" = 1 ]; then
    echo "    7. Wiederherstellung prüfen: Anmeldung mit TOTP (beweist AUTH_SECRET_KEY), Listen/Kalender sichtbar, Push-Test; Änderungen seit der Sicherung fehlen, gelöschte Daten sind zurück (Löschwünsche nachziehen)"
    echo "    8. Alten Server erst abschalten, wenn alles läuft; danach Wetter-Dienst starten (--wetter-starten), TTL der DNS-Einträge wieder erhöhen"
  else
    echo "    7. Ersten Admin anlegen:  sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --family \"<Familienname>\"   (Link einlösen: Passkey/TOTP)"
    echo "    8. Betreiber setzen (Dashboard Betrieb), ntfy-App der Familie mit Benutzer fampad-family einrichten (Passwort: sudo less /etc/lx-fampad/ntfy-family-password, danach 'q' und 'clear'; nicht per cat ins Terminal-Protokoll)"
  fi
  echo "    9. Neue Sicherung mit dem privaten age-Schlüssel testen: deploy/backup/wiederherstellung-test.sh (Schlüssel nie auf den Server)"
  echo "   10. Nie auf diesem Server ablegen/prüfen: privater age-Schlüssel, Android-Keystore, UPDATE_SIGNING_KEY (nicht in der Sicherung)"
}
zusammenfassung() {
  echo
  if trocken; then
    echo "==> Trockenlauf beendet: nichts wurde verändert."
    if [ "$PROBLEME" -gt 0 ]; then echo "    $PROBLEME PROBLEM(E) oben (mit 'PROBLEM:' markiert) müssen vor dem echten Lauf behoben werden."; fi
  else
    echo "==> Fertig. Phasen: ${PHASEN_GELAUFEN[*]:-keine}"
  fi
  if [ "${#OFFEN[@]}" -gt 0 ]; then
    echo "==> OFFEN (vom Skript erkannt, noch nicht erledigt):"
    local o
    for o in "${OFFEN[@]}"; do echo "    - $o"; done
  fi
  if trocken || [[ " ${PHASEN_GELAUFEN[*]:-} " == *" pruefung "* ]]; then mensch_liste; fi
}

# --- Aufruf --------------------------------------------------------------------------------------------------------------------------
phase_aktiv() { # $1 Name
  local p erreicht=0
  if [ -n "$NUR_PHASEN" ]; then [[ ",$NUR_PHASEN," == *",$1,"* ]]; return; fi
  if [ -n "$AB_PHASE" ]; then
    for p in "${PHASEN[@]}"; do
      [ "$p" = "$AB_PHASE" ] && erreicht=1
      if [ "$p" = "$1" ]; then [ "$erreicht" = 1 ]; return; fi
    done
  fi
  return 0
}
phase_gueltig() { local p; for p in "${PHASEN[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }
PHASEN_GELAUFEN=()
hilfe() { sed -n '2,/^set -E/{/^set -E/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
argumente_lesen() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1 ;;
      --yes) JA=1 ;;
      --ohne-systemd) OHNE_SYSTEMD=1 ;;
      --lx-anlegen) LX_ANLEGEN=1 ;;
      --params) [ $# -ge 2 ] || { echo "--params braucht einen Wert" >&2; exit 2; }; PARAMS_DATEI="$2"; shift ;;
      --phase) [ $# -ge 2 ] || { echo "--phase braucht einen Wert" >&2; exit 2; }; NUR_PHASEN="$2"; shift ;;
      --ab) [ $# -ge 2 ] || { echo "--ab braucht einen Wert" >&2; exit 2; }; AB_PHASE="$2"; shift ;;
      --sicherung) [ $# -ge 2 ] || { echo "--sicherung braucht einen Wert" >&2; exit 2; }; SICHERUNG_DIR="$2"; RESTORE=1; shift ;;
      --identity-stdin) ID_STDIN=1 ;;
      --identity-datei) [ $# -ge 2 ] || { echo "--identity-datei braucht einen Wert" >&2; exit 2; }; ID_DATEI="$2"; shift ;;
      --identity-datei-loeschen) ID_LOESCHEN=1 ;;
      --konfiguration-ersetzen) KONFIG_ERSETZEN=1 ;;
      --datenbank-ersetzen) DB_ERSETZEN=1 ;;
      --wetter-starten) WETTER_STARTEN=1 ;;
      --dns-pruefung-ueberspringen) DNS_UEBERSPRINGEN=1 ;;
      --swap-ok) SWAP_OK=1 ;;
      -h|--help|--hilfe) hilfe; exit 0 ;;
      *) echo "Unbekannte Option: $1 (--hilfe)" >&2; exit 2 ;;
    esac
    shift
  done
  if [ -n "$NUR_PHASEN" ] && [ -n "$AB_PHASE" ]; then echo "--phase und --ab nicht zusammen" >&2; exit 2; fi
  local p
  if [ -n "$NUR_PHASEN" ]; then IFS=',' read -ra teile <<<"$NUR_PHASEN"; for p in "${teile[@]}"; do phase_gueltig "$p" || { echo "Unbekannte Phase: $p (erlaubt: ${PHASEN[*]})" >&2; exit 2; }; done; fi
  if [ -n "$AB_PHASE" ]; then phase_gueltig "$AB_PHASE" || { echo "Unbekannte Phase: $AB_PHASE (erlaubt: ${PHASEN[*]})" >&2; exit 2; }; fi
  if [ "$RESTORE" = 1 ]; then
    [ "$ID_STDIN" = 1 ] || [ -n "$ID_DATEI" ] || { echo "--sicherung braucht --identity-stdin oder --identity-datei (der Schlüssel liegt nie auf dem Server)" >&2; exit 2; }
    [ "$ID_STDIN" = 0 ] || [ -z "$ID_DATEI" ] || { echo "--identity-stdin und --identity-datei nicht zusammen" >&2; exit 2; }
  else
    { [ "$ID_STDIN" = 0 ] && [ -z "$ID_DATEI" ]; } || { echo "--identity-* ohne --sicherung ergibt keinen Sinn" >&2; exit 2; }
  fi
  [ "$ID_LOESCHEN" = 0 ] || [ -n "$ID_DATEI" ] || { echo "--identity-datei-loeschen braucht --identity-datei" >&2; exit 2; }
  if [ "$ID_LOESCHEN" = 1 ]; then
    identitaet_pfad_erlaubt "$ID_DATEI" || { echo "--identity-datei-loeschen nur für Dateien unter /dev/shm, /run/lxfampad oder /run/user (Arbeitsspeicher, ohne ..)" >&2; exit 2; }
  fi
  # Testmodus nie auf einem echten Server: dort läuft systemd
  if [ "$OHNE_SYSTEMD" = 1 ] && [ -d /run/systemd/system ]; then
    echo "--ohne-systemd (und --dns-pruefung-ueberspringen) nur auf Systemen ohne systemd (Container-Tests): hier läuft systemd" >&2; exit 2
  fi
  # Nur für Container-Tests: ohne passenden DNS-Eintrag darf Caddy nur geprüft, nie gegen die echten Adressen betrieben werden
  if [ "$DNS_UEBERSPRINGEN" = 1 ] && [ "$OHNE_SYSTEMD" = 0 ]; then
    echo "--dns-pruefung-ueberspringen gibt es nur zusammen mit --ohne-systemd (Testmodus): auf einem echten Server schützt die DNS-Prüfung vor Zertifikatsfehlern und vor Aufrufen an einen fremden Server" >&2; exit 2
  fi
  if [ "$ID_STDIN" = 1 ] && [ "$JA" = 0 ] && { [ "$KONFIG_ERSETZEN" = 1 ] || [ "$DB_ERSETZEN" = 1 ]; } && [ ! -r /dev/tty ]; then
    echo "Mit --identity-stdin ist stdin belegt: für Rückfragen --yes angeben" >&2; exit 2
  fi
  return 0
}

main() {
  argumente_lesen "$@"
  [ -z "$PARAMS_DATEI" ] || parameter_lesen "$PARAMS_DATEI"
  parameter_pruefen
  if [ -n "$P_NODE_PKG_VERSION" ]; then NODE_PKG_VERSION="$P_NODE_PKG_VERSION"; warn "NODE_PKG_VERSION aus der Parameterdatei: $NODE_PKG_VERSION (Standard: 24.21.0-1nodesource1)"; fi
  if [ -n "$P_CADDY_PKG_VERSION" ]; then CADDY_PKG_VERSION="$P_CADDY_PKG_VERSION"; warn "CADDY_PKG_VERSION aus der Parameterdatei: $CADDY_PKG_VERSION (Standard: 2.11.7)"; fi
  [ "$(id -u)" -eq 0 ] || fehler "Bitte als root starten:  sudo bash $0 ..."
  if ! trocken; then sperren; fi
  TMP_ARBEIT="$(mktemp -d)"
  trap aufraeumen EXIT
  trap 'bei_fehler $LINENO' ERR
  trap 'exit 130' INT TERM HUP
  repo_bestimmen
  if trocken; then echo "==> TROCKENLAUF: es wird nichts verändert."; fi
  local p n=0 gesamt=${#PHASEN[@]}
  for p in "${PHASEN[@]}"; do
    n=$((n + 1))
    phase_aktiv "$p" || continue
    AKTUELLE_PHASE="$p"
    schritt "Phase $n/$gesamt: $p"
    "phase_$p"
    PHASEN_GELAUFEN+=("$p")
  done
  AKTUELLE_PHASE="-"
  zusammenfassung
  [ "$PROBLEME" -eq 0 ] || exit 1
}

# Nur ausführen, wenn das Skript gestartet (nicht eingelesen) wird; test-bootstrap.sh liest es ein und prüft die Hilfsfunktionen.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${BOOTSTRAP_NUR_FUNKTIONEN:-}" ]; then
  main "$@"
  exit $?
fi
