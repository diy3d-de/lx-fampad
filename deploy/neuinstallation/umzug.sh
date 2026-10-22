#!/usr/bin/env bash
# Umzugs-Assistent für lx-fampad: eine geführte Hülle um bootstrap-server.sh (liegt im selben Ordner; der Assistent ersetzt es nicht, er stellt nur die
# Fragen, baut die Befehle zusammen, zeigt den Fortschritt und schreibt am Ende deine fertige Liste). Anleitung: docs/NEUINSTALLATION.md, Abschnitt "Mit dem Assistenten".
#
# Aufruf (root, am besten in tmux, auf dem NEUEN Server, Debian 13):   bash umzug.sh [Optionen]
#   (ohne Option)              der ganze Ablauf in sechs Schritten: 1 Willkommen und Prüfung, 2 Sicherung und Schlüssel, 3 Fragen, 4 Zusammenfassung,
#                              5 Aufbau, 6 "Dein Teil" (Liste mit deinen Werten, auch in /root/umzug-offen.txt)
#   --probe                    Probelauf: läuft bis zur Zusammenfassung und ändert nichts (nichts wird installiert, gemerkt oder geschrieben)
#   --weiter caddy             nach der DNS-Umstellung: Caddy und Zertifikate (bootstrap --phase caddy,pruefung)
#   --weiter wetter            nachdem der ALTE Server aus ist: Wetter-Dienst starten (Netatmo erlaubt nur einen Abrufer)
#   --weiter muell             nachdem der ALTE Server aus ist: Müll-Dienst (Abfuhrtermine) starten
#   --weiter pruefung          Abschlussprüfung wiederholen und die Liste neu schreiben
#   --ip ADRESSE               öffentliche IPv4-Adresse dieses Servers (sonst erkennt der Assistent sie; nur nötig hinter NAT)
#   --params DATEI             optionale Parameterdatei (nur Öffentliches, Vorlage parameter.beispiel) als Vorgabe, z. B. mit den NAS-Daten aus deinen Unterlagen
#   --neu                      gemerkte Antworten (/root/.umzug-antworten) verwerfen und alles neu fragen
#   --swap-ok                  trotz aktivem Swap fortfahren (sonst Abbruch VOR dem Einlesen des Schlüssels; wie bei bootstrap-server.sh)
#   --ohne-systemd, --dns-pruefung-ueberspringen   NUR für Container-Tests, werden an bootstrap-server.sh weitergegeben (das sie selbst absichert)
#   --hilfe                    diese Hilfe
# Exit-Codes: 0 fertig, 1 Fehler (Bericht: /root/umzug-bericht.txt), 2 falscher Aufruf, 10 pausiert (GitHub-Schlüssel: denselben Befehl noch einmal starten).
#
# Neustart nach einem Abbruch: derselbe Befehl. Gemerkt werden NUR Nicht-Geheimes (Sicherungspfad, Code-Stand, IP, Swap-Wunsch, NAS-Daten, Stand des
# Aufbaus) in /root/.umzug-antworten (root, 0600). Der private age-Schlüssel wird nie gemerkt: er wird unsichtbar eingelesen, liegt nur in einer Shell-Variable
# dieses Prozesses (nie in einer Datei, nie in Argumenten, Umgebung oder Log), geht an bootstrap-server.sh nur über eine Pipe (--identity-stdin) und wird nach
# der letzten Verwendung (Ende der Phase datenbank) verworfen. Nach einem Neustart vor diesem Punkt fragt der Assistent ihn noch einmal.
# Caddy und das Haupt-Caddyfile (lx-labs.dev) fasst dieses Skript nie an; das tut nur bootstrap-server.sh in seiner Phase caddy (nur conf.d, mit Rückfall).
#
# Das gesamte Skript steht in Funktionen (bash liest es vollständig, bevor es etwas ausführt).
set -uo pipefail
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
umask 077

# --- Festwerte ----------------------------------------------------------------------------------------------------------------------
# Absichtlich nicht "readonly": aus_bootstrap() liest bootstrap-server.sh in einer Unterschale ein, das dieselben Namen schreibgeschützt setzt.
DOMAIN="familie.lx-labs.dev"                          # fest: Passkeys (RP-ID) hängen daran
NTFY_DOMAIN="ntfy.familie.lx-labs.dev"
LX_USER="lx"
PHASEN=(pruefen pakete system code konfiguration datenbank anwendung ntfy caddy sicherung pruefung)   # wie in bootstrap-server.sh
GITHUB_SCHLUESSEL_SEITE="https://github.com/diy3d-de/lx-fampad/settings/keys"
SCHLUESSEL_PHASEN="pakete,konfiguration,datenbank"    # hier entschlüsselt bootstrap-server.sh (Schlüssel nötig)
BIS_DATENBANK="pruefen,pakete,system,code,konfiguration,datenbank"   # diese Phasen bekommen --sicherung (RESTORE)
declare -A PHASEN_NAME=(
  [pruefen]="Prüfung" [pakete]="Pakete installieren" [system]="Benutzer und Ordner" [code]="Code von GitHub holen"
  [konfiguration]="Konfiguration aus der Sicherung" [datenbank]="Datenbank einspielen" [anwendung]="Server bauen und starten"
  [ntfy]="Push-Dienst (ntfy)" [caddy]="Caddy und Zertifikate" [sicherung]="Tägliche Sicherung einrichten" [pruefung]="Abschlussprüfung"
)
SICHERUNG_BASIS="/root/sicherung"
ANTWORTEN_DATEI="/root/.umzug-antworten"
OFFEN_DATEI="/root/umzug-offen.txt"
BERICHT_DATEI="/root/umzug-bericht.txt"
LAUF_LOG="/root/umzug-lauf.log"
PARAMS_ERZEUGT="/root/umzug.params"
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
BOOTSTRAP="$HIER/bootstrap-server.sh"

# --- Zustand des Laufs --------------------------------------------------------------------------------------------------------------
OPT_PROBE=0; OPT_WEITER=""; OPT_IP=""; OPT_PARAMS=""; OPT_NEU=0; OPT_SWAP_OK=0; OPT_OHNE_SYSTEMD=0; OPT_DNS_SKIP=0
AGE_ID=""                                  # privater Schlüssel: nur hier im Arbeitsspeicher
PARAMS_PFAD=""; ARBEIT_DIR=""
DB_ARCHIV=""; CFG_ARCHIV=""
IP_V4=""; IP_V6=""
RAM_MB=0
FATAL=0                                    # Zähler der nicht behebbaren Befunde in Schritt 1
FEHLENDE_PAKETE=()
SSH_KEY_RE=""; NUR_ROOT_FEHLER=""; CFG_VERSION=""
KANDIDATEN=(); PLAN=(); BA=(); PROBLEME=(); LISTE=()
HINWEISE=()                                # OFFEN-Meldungen von bootstrap-server.sh
PAUSE_KEY=""; CADDY_JETZT=0; DAUER_LETZT="0:00"
LETZTE_PHASE="-"; LETZTER_FEHLER=""
# Antworten (A_*): nur Nicht-Geheimes
A_SICHERUNG=""; A_GIT_REF=""; A_SWAP_MB=""; A_IP=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""
A_WETTER=""; A_MUELL=""; A_MUELL_LINK=""; A_KEEP=""; A_APK=""; A_FILES=""
A_FRAGEN=""; A_FERTIG=""; A_ERLEDIGT=""
declare -A EXTRA=()                        # Werte aus --params (nur öffentliche Parameter)
ANTWORT=""
C_RESET=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_B=""; C_D=""

# --- Ausgabe ------------------------------------------------------------------------------------------------------------------------
farben_init() { # Farben nur auf einem Terminal (nicht bei NO_COLOR, nicht bei Umleitung)
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    C_RESET=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'; C_B=$'\033[1m'; C_D=$'\033[2m'
  fi
}
zeile() { printf '%s\n' "$*"; }
gut() { printf '  %s✓%s %s\n' "$C_G" "$C_RESET" "$*"; }
hinweis() { printf '  %s!%s %s\n' "$C_Y" "$C_RESET" "$*"; }
schlecht() { printf '  %s✗%s %s\n' "$C_R" "$C_RESET" "$*"; }
fett() { printf '%s%s%s\n' "$C_B" "$*" "$C_RESET"; }
blass() { printf '%s%s%s\n' "$C_D" "$*" "$C_RESET"; }
linie() { blass "────────────────────────────────────────────────────────────"; }
schritt_titel() { # $1 Nummer, $2 Titel
  echo; linie; printf '%s%s von 6%s  %s%s%s\n' "$C_C" "$1" "$C_RESET" "$C_B" "$2" "$C_RESET"; linie
}
dauer() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# --- Aufräumen und Abbruch ----------------------------------------------------------------------------------------------------------
# Der Schlüssel verschwindet auf jedem Weg aus dem Arbeitsspeicher; die Wegwerf-Dateien (nur Probelauf) auch.
aufraeumen() {
  local rc=$?
  trap - EXIT
  AGE_ID=""; unset AGE_ID
  if [ -n "$ARBEIT_DIR" ]; then rm -rf -- "$ARBEIT_DIR"; fi
  exit "$rc"
}
unterbrochen() {
  echo
  zeile "Abgebrochen. Nichts geht verloren: Starte denselben Befehl noch einmal, Erledigtes wird übersprungen."
  exit 130
}
# Ein Satz mit der Ursache, ein Satz mit der Maßnahme; im echten Lauf zusätzlich der Bericht ohne Geheimnisse
fehler_ende() { # $1 Ursache, $2 Maßnahme, $3 Exit-Code (Standard 1)
  local code="${3:-1}"
  echo >&2
  printf '%s✗ %s%s\n' "$C_R" "$1" "$C_RESET" >&2
  printf '  %s\n' "$2" >&2
  if [ "$OPT_PROBE" = 0 ] && [ "$(id -u)" = 0 ] && [ "$code" != 2 ]; then
    if bericht_schreiben "$1" "$2" 2>/dev/null; then printf '  Bericht ohne Geheimnisse: %s\n' "$BERICHT_DATEI" >&2; fi
  fi
  exit "$code"
}
abbruch_eingabe() {
  fehler_ende "Die Eingabe wurde beendet, bevor alle Fragen beantwortet waren." "Starte denselben Befehl noch einmal in einem Terminal (Gemerktes bleibt erhalten)."
}

# --- Eingaben -----------------------------------------------------------------------------------------------------------------------
trimmen() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
lies_zeile() { # $1 Eingabeaufforderung; Ergebnis in ANTWORT; Ende der Eingabe = Abbruch
  printf '%s' "$1" >&2
  if ! IFS= read -r ANTWORT; then echo >&2; abbruch_eingabe; fi
  ANTWORT="${ANTWORT%$'\r'}"; ANTWORT="$(trimmen "$ANTWORT")"
}
frage_ja() { # $1 Frage, $2 Standard (ja|nein); Rückgabe 0 = ja. Enter = Standard
  local std="${2:-ja}" hilfe
  if [ "$std" = ja ]; then hilfe="[Enter = ja]"; else hilfe="[ja, Enter = nein]"; fi
  while true; do
    lies_zeile "$1  $hilfe "
    case "${ANTWORT,,}" in
      '') [ "$std" = ja ]; return ;;
      ja|j|yes|y) return 0 ;;
      nein|n|no) return 1 ;;
      *) zeile "  Bitte ja oder nein eingeben." ;;
    esac
  done
}

# --- Prüfungen der Eingaben (öffentliche Werte; die endgültige Prüfung macht bootstrap-server.sh) ----------------------------------
gueltiger_pfad() { # absolut, nur A-Z a-z 0-9 . _ - / @ +, kein ..-Teil
  [[ "$1" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || return 1
  case "/$1/" in */../*) return 1 ;; esac
  return 0
}
gueltiger_tag() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]; }
gueltige_ipv4() {
  local a b c d
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
  [ "$((10#$a))" -le 255 ] && [ "$((10#$b))" -le 255 ] && [ "$((10#$c))" -le 255 ] && [ "$((10#$d))" -le 255 ]
}
private_ipv4() {
  local a b
  [[ "$1" =~ ^([0-9]+)\.([0-9]+)\. ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  case "$a" in 0|10|127) return 0 ;; esac
  { [ "$a" = 192 ] && [ "$b" = 168 ]; } && return 0
  { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } && return 0
  { [ "$a" = 169 ] && [ "$b" = 254 ]; } && return 0
  { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; } && return 0
  return 1
}
gueltige_nas_ip() { # eine oder mehrere (Komma) IPv4-/IPv6-Adressen oder CIDR; die genaue Prüfung (CIDR mindestens /16 bzw. /48) macht einrichtung-backup.sh
  local teil teile=()
  [ -n "$1" ] || return 1
  IFS=',' read -ra teile <<<"$1"
  for teil in "${teile[@]}"; do
    if [[ "$teil" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then continue; fi
    if [[ "$teil" =~ ^[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]]; then continue; fi
    return 1
  done
  return 0
}
gueltiger_ssh_schluessel() { [ -n "$SSH_KEY_RE" ] && [[ "$1" =~ $SSH_KEY_RE ]]; }
gueltiger_swap() { [[ "$1" =~ ^[0-9]+$ ]] && { [ "$1" -eq 0 ] || { [ "$1" -ge 256 ] && [ "$1" -le 8192 ]; }; }; }
liste_enthaelt() { [[ ",$1," == *",$2,"* ]]; } # $1 Kommaliste, $2 Wert

# --- Hilfen aus bootstrap-server.sh (ohne Doppelung): in einer Unterschale eingelesen, ändert nichts -------------------------------
aus_bootstrap() { # $@ Funktion und Argumente von bootstrap-server.sh
  # shellcheck disable=SC1090
  ( set +eE; export BOOTSTRAP_NUR_FUNKTIONEN=1; . "$BOOTSTRAP" >/dev/null 2>&1; set +eE; "$@" )
}
bootstrap_wert() { # $1 Name einer Variablen von bootstrap-server.sh
  # shellcheck disable=SC1090
  ( set +eE; export BOOTSTRAP_NUR_FUNKTIONEN=1; . "$BOOTSTRAP" >/dev/null 2>&1; set +eE; printf '%s' "${!1}" )
}
bootstrap_pruefen() { # beide Skripte laufen als root: nur root-eigen und nicht für andere schreibbar
  local d f
  [ -f "$BOOTSTRAP" ] && [ ! -L "$BOOTSTRAP" ] || fehler_ende "bootstrap-server.sh fehlt neben diesem Skript ($HIER)." "Kopiere beide Dateien vom PC: scp deploy/neuinstallation/umzug.sh deploy/neuinstallation/bootstrap-server.sh root@<IP>:/root/" 2
  bash -n "$BOOTSTRAP" 2>/dev/null || fehler_ende "bootstrap-server.sh ist beschädigt (Syntaxfehler)." "Kopiere die Datei noch einmal vom PC und vergleiche die Prüfsumme (sha256sum)."
  for f in "$BOOTSTRAP" "${BASH_SOURCE[0]}"; do
    d="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    if [ "$(stat -c %u "$d" 2>/dev/null)" != 0 ] || [ $(( 8#$(stat -c %a "$d" 2>/dev/null || echo 777) & 8#022 )) -ne 0 ]; then
      fehler_ende "$(basename "$f") gehört nicht root oder ist für andere schreibbar." "Führe aus: chown root:root $d && chmod 700 $d"
    fi
  done
  SSH_KEY_RE="$(bootstrap_wert SSH_KEY_RE)"
  [ -n "$SSH_KEY_RE" ] || fehler_ende "bootstrap-server.sh lässt sich nicht einlesen." "Kopiere es noch einmal vom PC (Prüfsumme vergleichen)."
}

# --- Gemerkte Antworten (nur Nicht-Geheimes, root 0600; nie als Shell ausgeführt) --------------------------------------------------------
readonly ANTWORT_SCHLUESSEL=(SICHERUNG GIT_REF SWAP_MB IP NAS_IP NAS_PUBKEY LX_PUBKEY WETTER MUELL MUELL_LINK KEEP APK FILES FRAGEN FERTIG ERLEDIGT HINWEIS)
antwort_wert_ok() { # $1 Schlüssel, $2 Wert
  case "$1" in
    SICHERUNG) gueltiger_pfad "$2" ;;
    GIT_REF) gueltiger_tag "$2" ;;
    SWAP_MB) gueltiger_swap "$2" ;;
    IP) gueltige_ipv4 "$2" ;;
    NAS_IP) gueltige_nas_ip "$2" ;;
    NAS_PUBKEY|LX_PUBKEY) gueltiger_ssh_schluessel "$2" ;;
    WETTER|MUELL|MUELL_LINK|FRAGEN|APK|FILES) [[ "$2" =~ ^[01]$ ]] ;;
    KEEP) [[ "$2" =~ ^[1-9][0-9]?$ ]] ;;
    FERTIG|ERLEDIGT) [[ "$2" =~ ^[a-z,]*$ ]] ;;
    HINWEIS) [[ "$2" =~ ^[^[:cntrl:]]{1,600}$ ]] ;;
    *) return 1 ;;
  esac
}
antworten_zuruecksetzen() {
  A_SICHERUNG=""; A_GIT_REF=""; A_SWAP_MB=""; A_IP=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""
  A_WETTER=""; A_MUELL=""; A_MUELL_LINK=""; A_KEEP=""; A_APK=""; A_FILES=""; A_FRAGEN=""; A_FERTIG=""; A_ERLEDIGT=""
  HINWEISE=()
}
antworten_lesen() { # liest ANTWORTEN_DATEI; Rückgabe 0, wenn sie da und brauchbar war
  local z key val n=0
  [ -f "$ANTWORTEN_DATEI" ] && [ ! -L "$ANTWORTEN_DATEI" ] || return 1
  if [ "$(stat -c %u "$ANTWORTEN_DATEI")" != 0 ] || [ $(( 8#$(stat -c %a "$ANTWORTEN_DATEI") & 8#077 )) -ne 0 ]; then
    hinweis "Die gemerkten Antworten gehören nicht root oder sind für andere zugänglich: ich ignoriere sie."; return 1
  fi
  while IFS= read -r z || [ -n "$z" ]; do
    z="${z%$'\r'}"
    case "$z" in ''|'#'*) continue ;; esac
    [[ "$z" =~ ^([A-Z_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    case " ${ANTWORT_SCHLUESSEL[*]} " in *" $key "*) ;; *) continue ;; esac
    if [[ "${val^^}" == *"AGE-SECRET-KEY"* ]]; then continue; fi
    antwort_wert_ok "$key" "$val" || continue
    if [ "$key" = HINWEIS ]; then HINWEISE+=("$val"); else printf -v "A_$key" '%s' "$val"; fi
    n=$((n + 1))
  done < "$ANTWORTEN_DATEI"
  [ "$n" -gt 0 ]
}
antworten_text() { # gibt die gemerkten Antworten aus (es gibt hier keine Geheimnisse)
  local k v h
  for k in "${ANTWORT_SCHLUESSEL[@]}"; do
    [ "$k" = HINWEIS ] && continue
    v="A_$k"; v="${!v}"
    [ -z "$v" ] || printf '%s=%s\n' "$k" "$v"
  done
  for h in "${HINWEISE[@]}"; do printf 'HINWEIS=%s\n' "$h"; done
}
antworten_schreiben() {
  [ "$OPT_PROBE" = 0 ] || return 0
  local tmp="$ANTWORTEN_DATEI.neu.$$"
  { echo "# lx-fampad Umzugs-Assistent: gemerkte Antworten (nur Nicht-Geheimes; nie ein Schlüssel oder Passwort). Wird nie als Shell ausgeführt."; antworten_text; } > "$tmp" \
    && chmod 600 "$tmp" && mv -f "$tmp" "$ANTWORTEN_DATEI"
}
fertig_markieren() { # $1 Phase
  liste_enthaelt "$A_FERTIG" "$1" || A_FERTIG="${A_FERTIG:+$A_FERTIG,}$1"
  antworten_schreiben
}
erledigt_markieren() { liste_enthaelt "$A_ERLEDIGT" "$1" || A_ERLEDIGT="${A_ERLEDIGT:+$A_ERLEDIGT,}$1"; antworten_schreiben; }
hinweis_merken() { # $1 Text einer OFFEN-Meldung von bootstrap-server.sh
  local t h
  t="$(printf '%s' "$1" | tr -d '[:cntrl:]' | cut -c1-600)"
  [ -n "$t" ] || return 0
  for h in "${HINWEISE[@]}"; do [ "$h" = "$t" ] && return 0; done
  HINWEISE+=("$t")
}

# --- Optionale Parameterdatei (--params): nur öffentliche Werte, gleiche Regeln wie bei bootstrap-server.sh -----------------------------
readonly PARAM_SCHLUESSEL=" GIT_REPO_URL GIT_REF LX_SSH_PUBKEY CI_DEPLOY_PUBKEY WEATHER_ENABLED WEATHER_PLACE WEATHER_STATION_MAC WEATHER_BBOX RELEASE_CERT_SHA256 E2EE_PW_BACKUP AUTH_LEGACY_PASSWORD_LOGIN BACKUP_AGE_RECIPIENTS BACKUP_AGE_RECIPIENTS_CONFIG BACKUP_NAS_PUBKEY BACKUP_NAS_IP BACKUP_KEEP BACKUP_INCLUDE_APK BACKUP_INCLUDE_FILES SWAP_MB NODE_PKG_VERSION CADDY_PKG_VERSION "
extra_params_lesen() { # $1 Datei
  local d="$1" z key val n=0 pfd re_dq='^"(.*)"$' re_sq="^'(.*)'\$"
  [ -f "$d" ] && [ ! -L "$d" ] && [ -r "$d" ] || fehler_ende "Die Parameterdatei $d ist nicht lesbar oder ein Symlink." "Gib den Pfad einer normalen Datei an (--params DATEI)." 2
  exec {pfd}< "$d"
  if [ ! -f "/proc/self/fd/$pfd" ] || [ "$(stat -L -c %u "/proc/self/fd/$pfd")" != 0 ] || [ $(( 8#$(stat -L -c %a "/proc/self/fd/$pfd") & 8#022 )) -ne 0 ]; then
    exec {pfd}<&-
    fehler_ende "Die Parameterdatei $d gehört nicht root oder ist für andere schreibbar." "Führe aus: chown root:root $d && chmod 600 $d" 2
  fi
  while IFS= read -r z <&"$pfd" || [ -n "$z" ]; do
    n=$((n + 1)); z="${z%$'\r'}"
    case "$z" in ''|'#'*) continue ;; esac
    [[ "$z" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$z" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then exec {pfd}<&-; fehler_ende "Die Parameterdatei $d ist in Zeile $n ungültig (erwartet SCHLÜSSEL=Wert)." "Prüfe die Datei (Vorlage: parameter.beispiel)." 2; fi
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ $re_dq ]]; then val="${BASH_REMATCH[1]}"; elif [[ "$val" =~ $re_sq ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ "${val^^}" == *"AGE-SECRET-KEY"* || "${val^^}" == *"PRIVATE KEY"* ]]; then exec {pfd}<&-; fehler_ende "Die Parameterdatei enthält einen privaten Schlüssel (Zeile $n)." "Ein privater Schlüssel gehört nie in eine Datei auf dem Server; entferne die Zeile." 2; fi
    case "$PARAM_SCHLUESSEL" in *" $key "*) ;; *) exec {pfd}<&-; fehler_ende "Die Parameterdatei enthält einen unbekannten Schlüssel ($key, Zeile $n)." "Erlaubt sind nur die Schlüssel aus parameter.beispiel (nur Öffentliches)." 2 ;; esac
    EXTRA["$key"]="$val"
  done
  exec {pfd}<&-
  # Vorgaben für die Fragen (gemerkte Antworten gehen vor); falsche Werte ignoriert der Assistent hier, bootstrap-server.sh prüft sie später noch einmal
  if [ -z "$A_GIT_REF" ] && [ -n "${EXTRA[GIT_REF]:-}" ] && gueltiger_tag "${EXTRA[GIT_REF]}"; then A_GIT_REF="${EXTRA[GIT_REF]}"; fi
  if [ -z "$A_SWAP_MB" ] && [ -n "${EXTRA[SWAP_MB]:-}" ] && gueltiger_swap "${EXTRA[SWAP_MB]}"; then A_SWAP_MB="${EXTRA[SWAP_MB]}"; fi
  if [ -z "$A_NAS_IP" ] && [ -n "${EXTRA[BACKUP_NAS_IP]:-}" ] && gueltige_nas_ip "${EXTRA[BACKUP_NAS_IP]}"; then A_NAS_IP="${EXTRA[BACKUP_NAS_IP]}"; fi
  if [ -z "$A_NAS_PUBKEY" ] && [ -n "${EXTRA[BACKUP_NAS_PUBKEY]:-}" ] && gueltiger_ssh_schluessel "${EXTRA[BACKUP_NAS_PUBKEY]}"; then A_NAS_PUBKEY="${EXTRA[BACKUP_NAS_PUBKEY]}"; fi
  if [ -z "$A_LX_PUBKEY" ] && [ -n "${EXTRA[LX_SSH_PUBKEY]:-}" ] && gueltiger_ssh_schluessel "${EXTRA[LX_SSH_PUBKEY]}"; then A_LX_PUBKEY="${EXTRA[LX_SSH_PUBKEY]}"; fi
  return 0
}
# Parameterdatei für bootstrap-server.sh: nur öffentliche Werte aus den Antworten (plus unveränderte Werte aus --params), root, 0600
params_schreiben() { # $1 Zieldatei
  local ziel="$1" tmp k
  tmp="$ziel.neu.$$"
  {
    echo "# Vom Umzugs-Assistenten erzeugt (deploy/neuinstallation/umzug.sh). NUR Öffentliches; nie ein Geheimnis. Wird bei jedem Start neu geschrieben."
    echo "# Bewahre sie in deinen Betriebsunterlagen auf (docs/NEUINSTALLATION.md)."
    [ -z "$A_GIT_REF" ] || echo "GIT_REF=$A_GIT_REF"
    echo "SWAP_MB=${A_SWAP_MB:-0}"
    [ -z "$A_LX_PUBKEY" ] || echo "LX_SSH_PUBKEY=$A_LX_PUBKEY"
    if [ -n "$A_NAS_IP" ] && [ -n "$A_NAS_PUBKEY" ]; then echo "BACKUP_NAS_PUBKEY=$A_NAS_PUBKEY"; echo "BACKUP_NAS_IP=$A_NAS_IP"; fi
    [ -z "$A_KEEP" ] || echo "BACKUP_KEEP=$A_KEEP"
    [ -z "$A_APK" ] || echo "BACKUP_INCLUDE_APK=$A_APK"
    [ -z "$A_FILES" ] || echo "BACKUP_INCLUDE_FILES=$A_FILES"
    for k in "${!EXTRA[@]}"; do
      case "$k" in GIT_REF|SWAP_MB|LX_SSH_PUBKEY|BACKUP_NAS_PUBKEY|BACKUP_NAS_IP|BACKUP_KEEP|BACKUP_INCLUDE_APK|BACKUP_INCLUDE_FILES) continue ;; esac
      printf '%s=%s\n' "$k" "${EXTRA[$k]}"
    done
  } > "$tmp" && chmod 600 "$tmp" && chown root:root "$tmp" && mv -f "$tmp" "$ziel"
}

# --- Schritt 1: Willkommen und Prüfung (ändert nichts) ---------------------------------------------------------------------------------
tcp_offen() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
swap_aktiv() { [ ! -r /proc/swaps ] || [ -n "$(awk 'NR > 1' /proc/swaps)" ]; }
ip_erkennen() {
  local ip=""
  if [ -n "$OPT_IP" ]; then IP_V4="$OPT_IP"
  else
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1)"
    [ -n "$ip" ] || ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
    IP_V4="$ip"
  fi
  IP_V6="$(ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u | head -n 3 | tr '\n' ' ')"
  IP_V6="$(trimmen "$IP_V6")"
}
prueffeld() { # $1 Ergebnis (ok|hinweis|fatal), $2 Text
  case "$1" in ok) gut "$2" ;; hinweis) hinweis "$2" ;; fatal) schlecht "$2"; FATAL=$((FATAL + 1)) ;; esac
}
schritt1_pruefungen() {
  local os_id os_ver frei h
  os_id="$(sed -nE 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"; os_ver="$(sed -nE 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
  if [ "$os_id" = debian ] && [ "$os_ver" = 13 ] && [ "$(dpkg --print-architecture 2>/dev/null)" = amd64 ]; then prueffeld ok "Debian 13 (trixie), 64 Bit"
  else prueffeld fatal "Vorgesehen ist nur Debian 13 (trixie), 64 Bit; gefunden: ${os_id:-?} ${os_ver:-?}. Bestelle den Server mit diesem Image neu."; fi
  RAM_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  frei="$(df --output=avail -BG /srv 2>/dev/null | tail -n 1 | tr -dc '0-9')"
  [ -n "$frei" ] || frei="$(df --output=avail -BG / 2>/dev/null | tail -n 1 | tr -dc '0-9')"
  frei="${frei:-0}"
  if [ "$RAM_MB" -ge 1500 ] && [ "$frei" -ge 5 ]; then prueffeld ok "Arbeitsspeicher: $(( (RAM_MB + 512) / 1024 )) GB   Platz frei: ${frei} GB"
  else prueffeld fatal "Zu wenig Arbeitsspeicher (${RAM_MB} MB, nötig 1,5 GB) oder Platz (${frei} GB, nötig 5 GB). Nimm einen größeren Tarif."; fi
  if [ "$frei" -lt 25 ] && [ "$frei" -ge 5 ]; then prueffeld hinweis "Platz: ${frei} GB. Für die Kartendatei später 20 GB frei halten."; fi
  FEHLENDE_PAKETE=()
  command -v curl >/dev/null || FEHLENDE_PAKETE+=(curl)
  command -v ip >/dev/null || FEHLENDE_PAKETE+=(iproute2)
  command -v age >/dev/null || FEHLENDE_PAKETE+=(age)
  dpkg -s ca-certificates >/dev/null 2>&1 || FEHLENDE_PAKETE+=(ca-certificates)
  for h in awk sed tar sha256sum getent runuser flock dpkg; do command -v "$h" >/dev/null || prueffeld fatal "Das Werkzeug '$h' fehlt: das ist kein normales Debian 13."; done
  if [ "${#FEHLENDE_PAKETE[@]}" -gt 0 ]; then prueffeld hinweis "Es fehlen kleine Werkzeuge: ${FEHLENDE_PAKETE[*]} (installiere ich nach deinem OK mit apt)."
  else prueffeld ok "Benötigte Werkzeuge sind da (curl, age, ip)"; fi
  if tcp_offen deb.debian.org 443 && tcp_offen github.com 443; then prueffeld ok "Internetverbindung (Debian-Paketquellen, GitHub)"
  else prueffeld fatal "Keine Verbindung zu deb.debian.org oder github.com (Port 443). Prüfe Netz und Firewall des Anbieters."; fi
  if command -v ss >/dev/null; then
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(4400|2586|5432)$' | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
      prueffeld hinweis "Einer der Ports 4400, 2586, 5432 ist von außen erreichbar (ss -ltnp prüfen)."
    else prueffeld ok "Ports 4400, 2586, 5432 sind von außen nicht erreichbar"; fi
  fi
  if command -v sshd >/dev/null && [ "$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')" = yes ]; then
    prueffeld hinweis "SSH erlaubt die Anmeldung mit Passwort (Hinweis: später härten, die Anmeldung nur mit Schlüssel ist sicherer)"
  fi
  if [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ]; then prueffeld hinweis "Du arbeitest nicht in tmux: bei einem Verbindungsabbruch stoppt der Aufbau. Besser: apt install tmux, dann tmux new -s umzug und hier neu starten."; fi
  if [ -e /srv/fampad/server ] || [ -e /etc/lx-fampad/env ] || [ -e /etc/systemd/system/lx-fampad.service ]; then
    if [ -n "$A_FERTIG" ]; then prueffeld ok "Teile von lx-fampad sind schon eingerichtet (Fortsetzung eines früheren Laufs: ${A_FERTIG//,/, })"
    else prueffeld fatal "Auf diesem Server ist lx-fampad schon (teilweise) eingerichtet. Der Assistent ist für einen frischen Server: nimm einen neuen oder nutze bootstrap-server.sh direkt (docs/NEUINSTALLATION.md)."; fi
  else prueffeld ok "Es läuft noch nichts von lx-fampad auf diesem Server"; fi
}
pakete_installieren() {
  if ! { env DEBIAN_FRONTEND=noninteractive apt-get update -qq && env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 apt-get install -y -qq --no-install-recommends "$@"; } >>"$LAUF_LOG" 2>&1; then
    fehler_ende "Die Pakete $* ließen sich nicht installieren." "Prüfe die Verbindung zu den Debian-Paketquellen und starte noch einmal (Einzelheiten: $LAUF_LOG)."
  fi
  gut "Installiert: $*"
}
schritt1() {
  schritt_titel 1 "Willkommen und Prüfung"
  printf 'Ich richte diesen Server für %s%s%s ein.\n' "$C_C" "$DOMAIN" "$C_RESET"
  if [ "$OPT_PROBE" = 1 ]; then zeile "PROBELAUF: Ich gehe alle Schritte bis zur Zusammenfassung durch und ändere nichts."
  else zeile "Vorher prüfe ich kurz, ob alles passt. Dabei wird nichts verändert."; fi
  echo
  ip_erkennen
  schritt1_pruefungen
  if [ -n "$IP_V4" ] && gueltige_ipv4 "$IP_V4" && ! private_ipv4 "$IP_V4"; then prueffeld ok "IP-Adresse dieses Servers: $IP_V4"
  else
    prueffeld hinweis "Die erkannte Adresse (${IP_V4:-keine}) ist keine öffentliche IPv4-Adresse."
    if [ -n "$A_IP" ]; then IP_V4="$A_IP"; zeile "    Gemerkte Adresse: $IP_V4"
    else
      while true; do
        lies_zeile "    Öffentliche IPv4-Adresse dieses Servers (siehe Konsole deines Anbieters): "
        if gueltige_ipv4 "$ANTWORT" && ! private_ipv4 "$ANTWORT"; then IP_V4="$ANTWORT"; break; fi
        zeile "    Das ist keine öffentliche IPv4-Adresse (Beispiel: 203.0.113.10)."
      done
    fi
  fi
  [ -z "$IP_V4" ] || A_IP="$IP_V4"
  if [ "$FATAL" -gt 0 ]; then echo; fehler_ende "Der Server ist so noch nicht geeignet ($FATAL Punkt(e) oben mit ✗)." "Behebe die markierten Punkte und starte denselben Befehl noch einmal."; fi
  echo
  frage_ja "Weiter?" ja || { zeile "Gut, ich höre hier auf. Es wurde nichts verändert."; exit 0; }
  if [ "${#FEHLENDE_PAKETE[@]}" -gt 0 ]; then
    if [ "$OPT_PROBE" = 1 ]; then hinweis "Probelauf: ich würde jetzt ${FEHLENDE_PAKETE[*]} installieren (apt). Ohne age kann ich den Schlüssel unten nicht prüfen."
    else
      echo
      zeile "Ich installiere jetzt nur diese kleinen Debian-Pakete: ${FEHLENDE_PAKETE[*]}. Das ist die einzige Änderung vor deiner Bestätigung in Schritt 4."
      frage_ja "Einverstanden?" ja || fehler_ende "Ohne ${FEHLENDE_PAKETE[*]} kann ich nicht weitermachen." "Installiere sie selbst (apt-get install ${FEHLENDE_PAKETE[*]}) oder starte neu und antworte ja."
      pakete_installieren "${FEHLENDE_PAKETE[@]}"
    fi
  fi
}

# --- Schritt 2: Sicherung und Schlüssel ----------------------------------------------------------------------------------------------
sicherung_ordner_gueltig() { # $1 Ordner: genau je ein db-/config-Archiv und SHA256SUMS
  local d="$1" dbs cfgs
  shopt -s nullglob
  dbs=("$d"/db-*.dump.age); cfgs=("$d"/config-*.tar.age)
  shopt -u nullglob
  [ "${#dbs[@]}" -eq 1 ] && [ "${#cfgs[@]}" -eq 1 ] && [ -f "$d/SHA256SUMS" ]
}
sicherungen_finden() { # füllt KANDIDATEN, neueste zuerst
  local d
  KANDIDATEN=()
  [ -d "$SICHERUNG_BASIS" ] || return 0
  if sicherung_ordner_gueltig "$SICHERUNG_BASIS"; then KANDIDATEN+=("$SICHERUNG_BASIS"); fi
  while IFS= read -r d; do
    if [ -n "$d" ] && sicherung_ordner_gueltig "$d"; then KANDIDATEN+=("$d"); fi
  done < <(find "$SICHERUNG_BASIS" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort -r)
}
sicherung_beschreiben() { # $1 Ordner -> Text "vor 1 Tag, 21 MB, Prüfsummen ok"
  local d="$1" name stamp="" epoche jetzt tage groesse summen
  name="$(basename "$d")"
  if [[ "$name" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    epoche="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]} UTC" +%s 2>/dev/null || echo 0)"
    jetzt="$(date +%s)"; tage=$(( (jetzt - epoche) / 86400 ))
    if [ "$epoche" -eq 0 ]; then stamp=""
    elif [ "$tage" -le 0 ]; then stamp="heute, ${BASH_REMATCH[4]}:${BASH_REMATCH[5]} UTC"
    elif [ "$tage" -eq 1 ]; then stamp="gestern, ${BASH_REMATCH[4]}:${BASH_REMATCH[5]} UTC"
    else stamp="vor $tage Tagen"; fi
  fi
  groesse="$(du -sh --apparent-size "$d" 2>/dev/null | cut -f1)"
  if ( cd "$d" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1 ); then summen="Prüfsummen ok"; else summen="PRÜFSUMMEN FALSCH"; fi
  printf '%s%s, %s' "${stamp:+$stamp, }" "${groesse:-?}" "$summen"
}
sicherung_rechte_pruefen() { # $1 Ordner; Befund in NUR_ROOT_FEHLER (symlink|rechte)
  local d="$1"
  NUR_ROOT_FEHLER=""
  if [ -n "$(find "$d" -type l -print -quit 2>/dev/null)" ]; then NUR_ROOT_FEHLER="symlink"; return 1; fi
  if [ -n "$(find "$d" \( ! -user root -o -perm /022 \) -print -quit 2>/dev/null)" ]; then NUR_ROOT_FEHLER="rechte"; return 1; fi
  return 0
}
sicherung_uebernehmen() { # $1 Ordner; Rückgabe 0 = gewählt und geprüft
  local d f
  d="$(cd "$1" && pwd)"
  if ! ( cd "$d" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1 ); then
    schlecht "Die Prüfsummen dieser Sicherung stimmen nicht (beschädigt oder unvollständig kopiert). Nimm eine ältere oder kopiere sie noch einmal."; return 1
  fi
  if ! sicherung_rechte_pruefen "$d"; then
    if [ "$NUR_ROOT_FEHLER" = symlink ]; then schlecht "In $d liegen Symlinks: das lehne ich ab (Verdacht auf Manipulation). Kopiere die Sicherung neu."; return 1; fi
    hinweis "$d gehört nicht root oder ist für andere schreibbar. bootstrap-server.sh verlangt: root-eigen, keine Schreibrechte für Gruppe und Andere."
    if [ "$OPT_PROBE" = 1 ]; then zeile "    Probelauf: im echten Lauf würde ich fragen, ob ich 'chown -R root:root' und 'chmod -R go-w' ausführen darf."
    elif frage_ja "    Soll ich das jetzt herstellen (chown -R root:root und chmod -R go-w auf diesen Ordner)?" ja; then
      if ! { chown -R root:root "$d" && chmod -R go-w "$d"; }; then schlecht "Das ging nicht."; return 1; fi
    else schlecht "Ohne diese Rechte bricht bootstrap-server.sh ab."; return 1; fi
  fi
  sicherung_ordner_gueltig "$d" || return 1
  shopt -s nullglob
  local dbs=("$d"/db-*.dump.age) cfgs=("$d"/config-*.tar.age)
  shopt -u nullglob
  DB_ARCHIV="${dbs[0]}"; CFG_ARCHIV="${cfgs[0]}"
  for f in "$DB_ARCHIV" "$CFG_ARCHIV"; do
    [[ "$(basename "$f")" =~ ^(db-[0-9]{8}-[0-9]{6}\.dump|config-[0-9]{8}-[0-9]{6}\.tar)\.age$ ]] || { schlecht "Unerwarteter Dateiname: $(basename "$f")"; return 1; }
  done
  A_SICHERUNG="$d"
  gut "Sicherung $(basename "$d"): $(sicherung_beschreiben "$d")"
  return 0
}
frage_sicherung() { # Frage 1: Ergebnis in A_SICHERUNG
  local i wahl d beschr gesamt
  echo
  fett "Frage 1: Wo liegt die Sicherung?"
  zeile "Kopiere den Sicherungsordner vom NAS hierher, zum Beispiel (auf deinem PC):"
  blass "  scp -r archiv/20261022-033000 root@${IP_V4:-<IP>}:/root/sicherung/"
  if [ -n "$A_SICHERUNG" ] && [ -d "$A_SICHERUNG" ] && sicherung_ordner_gueltig "$A_SICHERUNG"; then
    zeile "Gemerkt von vorhin: $A_SICHERUNG"
    if frage_ja "Wieder diese Sicherung nehmen?" ja && sicherung_uebernehmen "$A_SICHERUNG"; then return 0; fi
  fi
  while true; do
    sicherungen_finden
    gesamt="${#KANDIDATEN[@]}"
    if [ "$gesamt" -gt 0 ]; then
      echo "Gefunden in $SICHERUNG_BASIS:"
      i=0
      for d in "${KANDIDATEN[@]:0:5}"; do
        i=$((i + 1)); beschr="$(sicherung_beschreiben "$d")"
        printf '  %s[%d]%s %s   %s(%s)%s\n' "$C_C" "$i" "$C_RESET" "$(basename "$d")" "$C_D" "$beschr" "$C_RESET"
      done
      lies_zeile "Nimm die neueste?  [Enter = 1, oder Nummer, oder anderer Pfad] "
      wahl="${ANTWORT:-1}"
    else
      zeile "In $SICHERUNG_BASIS liegt noch keine Sicherung (erwartet: Ordner mit db-*.dump.age, config-*.tar.age und SHA256SUMS)."
      lies_zeile "Pfad des Sicherungsordners (oder Strg+C, kopiere ihn und starte neu): "
      wahl="$ANTWORT"
    fi
    if [[ "$wahl" =~ ^[0-9]{1,2}$ ]] && [ "$gesamt" -gt 0 ] && [ "$wahl" -ge 1 ] && [ "$wahl" -le "$gesamt" ] && [ "$wahl" -le 5 ]; then d="${KANDIDATEN[$((wahl - 1))]}"
    else d="$wahl"; fi
    if ! gueltiger_pfad "$d"; then zeile "  Das ist kein gültiger Pfad (absolut, nur Buchstaben, Ziffern und . _ - / @ +, ohne '..')."; continue; fi
    if [ ! -d "$d" ] || ! sicherung_ordner_gueltig "$d"; then zeile "  In $d liegt keine vollständige Sicherung (db-*.dump.age, config-*.tar.age, SHA256SUMS)."; continue; fi
    if sicherung_uebernehmen "$d"; then return 0; fi
  done
}
schluessel_einlesen() { # liest bis zu einer Zeile AGE-SECRET-KEY-1…; unsichtbar (Terminal) oder aus stdin (Skripte, Tests)
  local z="" gewarnt=0 lesen
  AGE_ID=""
  while true; do
    if [ -t 0 ]; then IFS= read -rs z; lesen=$?; else IFS= read -r z; lesen=$?; fi
    if [ "$lesen" -ne 0 ] && [ -z "$z" ]; then break; fi
    z="${z%$'\r'}"
    if [[ "$z" =~ ^AGE-SECRET-KEY-1[0-9A-Z]+$ ]]; then AGE_ID="$z"; break; fi
    if [ -n "$z" ] && [ "$gewarnt" = 0 ] && [[ "$z" != \#* ]]; then
      gewarnt=1; echo >&2; echo "  Das sieht nicht wie ein privater Schlüssel aus (er beginnt mit AGE-SECRET-KEY-1). Füge ihn ein oder beende mit Strg+D." >&2
    fi
    z=""
  done
  z=""
  echo >&2
  [ -n "$AGE_ID" ]
}
schluessel_passt() { # 0 = der Datenbank-Dump der Sicherung lässt sich öffnen (Kennung PGDMP, wie bei bootstrap-server.sh)
  local magic
  magic="$(age -d -i <(printf '%s\n' "$AGE_ID") -- "$DB_ARCHIV" 2>/dev/null | head -c 5 || true)"
  [ "$magic" = PGDMP ]
}
schluessel_noetig() { # 0, wenn noch eine Phase offen ist, die entschlüsselt
  local p
  for p in pakete konfiguration datenbank; do liste_enthaelt "$A_FERTIG" "$p" || return 0; done
  return 1
}
frage_schluessel() {
  local versuch
  echo
  fett "Dein privater Sicherungsschlüssel"
  zeile "Ohne ihn kann ich die Sicherung nicht öffnen. Er wird nicht angezeigt, nicht gespeichert und nicht weitergegeben (nur im Arbeitsspeicher dieses Laufs)."
  if swap_aktiv && [ "$OPT_SWAP_OK" = 0 ]; then
    fehler_ende "Auf diesem Server ist Swap aktiv: der Schlüssel könnte aus dem Arbeitsspeicher auf die Platte ausgelagert werden." "Führe 'swapoff -a' aus und starte neu (den Swap legt der Assistent später selbst an), oder starte bewusst mit --swap-ok."
  fi
  if swap_aktiv; then hinweis "Swap ist aktiv und --swap-ok ist angegeben: der Schlüssel kann im Swap landen."; fi
  if ! command -v age >/dev/null; then
    if [ "$OPT_PROBE" = 1 ]; then hinweis "Probelauf: age ist nicht installiert, daher prüfe ich den Schlüssel hier nicht (im echten Lauf installiere ich age vorher)."; return 0; fi
    fehler_ende "age ist nicht installiert." "Installiere es (apt-get install age) und starte neu."
  fi
  for versuch in 1 2 3; do
    zeile "Einfügen (die Eingabe bleibt unsichtbar), dann Enter. Bei einer ganzen Schlüsseldatei: Strg+D.${versuch:+ (Versuch $versuch von 3)}"
    schluessel_einlesen || fehler_ende "Es wurde kein privater Schlüssel eingegeben." "Starte neu und füge den Schlüssel (AGE-SECRET-KEY-1…) aus deinem Passwortmanager ein."
    printf '%sPrüfe, ob der Schlüssel zur Sicherung passt …%s\n' "$C_Y" "$C_RESET"
    if schluessel_passt; then gut "Der Schlüssel passt (Datenbank und Konfiguration lassen sich öffnen)."; return 0; fi
    AGE_ID=""
    schlecht "Dieser Schlüssel passt nicht zu dieser Sicherung. Nichts wurde verändert."
  done
  fehler_ende "Der Schlüssel passte dreimal nicht zur Sicherung." "Prüfe, ob es der Schlüssel zu GENAU dieser Sicherung ist (es gibt Haupt- und Ersatzschlüssel), und starte neu. Nichts wurde verändert."
}
# Liest aus der entschlüsselten Konfiguration nur Unbedenkliches (Schalter, Versionsnummer, Sicherungseinstellungen): die Zeilen werden gefiltert,
# bevor sie in eine Variable kommen; AUTH_SECRET_KEY, Passwörter und Links bleiben in der Pipe.
cfg_aus_archiv() { # $1 Pfad im Archiv; Klartext auf stdout
  age -d -i <(printf '%s\n' "$AGE_ID") -- "$CFG_ARCHIV" 2>/dev/null | tar -xzOf - "$1" 2>/dev/null
}
config_auswerten() {
  local env_flags bc zeile url="" v
  env_flags="$(cfg_aus_archiv etc/lx-fampad/env | awk '
    { sub(/\r$/, "") }
    /^WEATHER_ENABLED=/ { v = substr($0, 17); gsub(/["\047]/, "", v); w = (v == "true" || v == "1") ? 1 : 0 }
    /^WASTE_ENABLED=/ { v = substr($0, 15); gsub(/["\047]/, "", v); m = (v == "true" || v == "1") ? 1 : 0 }
    /^WASTE_ICS_URL=./ { l = 1 }
    /^PUBLIC_URL=/ { u = substr($0, 12); gsub(/["\047]/, "", u) }
    END { printf "WETTER=%d\nMUELL=%d\nMUELL_LINK=%d\n", w + 0, m + 0, l + 0; if (u != "") print "PUBLIC_URL=" u }' 2>/dev/null || true)"
  while IFS= read -r zeile; do
    case "$zeile" in
      WETTER=[01]) A_WETTER="${zeile#WETTER=}" ;;
      MUELL=[01]) A_MUELL="${zeile#MUELL=}" ;;
      MUELL_LINK=[01]) A_MUELL_LINK="${zeile#MUELL_LINK=}" ;;
      PUBLIC_URL=https://*) url="${zeile#PUBLIC_URL=}" ;;
    esac
  done <<<"$env_flags"
  if [ -n "$url" ] && [ "${url%/}" != "https://$DOMAIN" ]; then
    fehler_ende "Diese Sicherung gehört zu '${url:0:80}', nicht zu https://$DOMAIN." "Die Domain darf sich nie ändern (Passkeys): nimm die Sicherung des richtigen Servers."
  fi
  CFG_VERSION="$(cfg_aus_archiv srv/fampad/releases/android/latest.json | grep -oE '[\\"]version\\?":\\?"[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
  bc="$(cfg_aus_archiv etc/lx-fampad-backup/backup.conf | sed -nE 's/^(KEEP|INCLUDE_APK|INCLUDE_FILES)=([0-9]{1,2})[[:space:]]*(#.*)?$/\1=\2/p' || true)"
  while IFS= read -r zeile; do
    case "$zeile" in
      KEEP=*) v="${zeile#KEEP=}"; if antwort_wert_ok KEEP "$v"; then A_KEEP="$v"; fi ;;
      INCLUDE_APK=*) v="${zeile#INCLUDE_APK=}"; if antwort_wert_ok APK "$v"; then A_APK="$v"; fi ;;
      INCLUDE_FILES=*) v="${zeile#INCLUDE_FILES=}"; if antwort_wert_ok FILES "$v"; then A_FILES="$v"; fi ;;
    esac
  done <<<"$bc"
  return 0
}
schritt2() {
  schritt_titel 2 "Sicherung und Schlüssel"
  zeile "Zuerst die Sicherung (Frage 1), dann dein Schlüssel. Ihn brauche ich früh: Manches, was ich dir gleich vorschlage (Code-Stand, Wetter, Müll),"
  zeile "steht nur in der verschlüsselten Konfiguration der Sicherung."
  frage_sicherung
  if schluessel_noetig; then
    frage_schluessel
    if [ -n "$AGE_ID" ]; then config_auswerten; fi
  else
    gut "Der Schlüssel wird nicht mehr gebraucht: alle Phasen mit Entschlüsselung sind schon erledigt."
  fi
}

# --- Schritt 3: die übrigen Fragen -----------------------------------------------------------------------------------------------
lx_fehlt() { ! id "$LX_USER" >/dev/null 2>&1; }
frage_code_stand() { # Frage 2
  local vorschlag="" eingabe
  echo
  fett "Frage 2: Welcher Code-Stand?"
  if [ -n "$A_GIT_REF" ]; then vorschlag="$A_GIT_REF"; elif [ -n "$CFG_VERSION" ]; then vorschlag="v$CFG_VERSION"; fi
  if [ -n "$CFG_VERSION" ]; then printf 'Die Sicherung enthält den Update-Kanal der App-Version %s%s%s.\n' "$C_C" "$CFG_VERSION" "$C_RESET"; fi
  zeile "Die Datenbank darf nicht neuer sein als der Code. Nimm den Tag der Version, die auf dem alten Server lief (Beispiel: v0.9.0)."
  while true; do
    if [ -n "$vorschlag" ]; then lies_zeile "Ich nehme den Tag ${vorschlag}.  [Enter = ja, oder anderen Tag eingeben] "; eingabe="${ANTWORT:-$vorschlag}"
    else lies_zeile "Tag eingeben (z. B. v0.9.0): "; eingabe="$ANTWORT"; fi
    if gueltiger_tag "$eingabe"; then A_GIT_REF="$eingabe"; return 0; fi
    zeile "  Bitte einen Tag wie v0.9.0 (oder eine Commit-ID) angeben. Branches nehme ich nicht: sie ändern sich."
  done
}
frage_nas() { # Frage 3
  local ip
  echo
  fett "Frage 3: Wohin geht die NAS-Abholung?"
  zeile "Der neue Server sichert sich jede Nacht selbst; dein NAS holt die Sicherung ab. Dafür brauche ich die öffentliche IP-Adresse deines NAS"
  zeile "und seinen öffentlichen SSH-Schlüssel (auf dem NAS: ~/.ssh/lx-fampad-backup.pub, kein Geheimnis). Beides steht nicht in der Sicherung."
  if [ -n "$A_NAS_IP" ] && [ -n "$A_NAS_PUBKEY" ]; then
    printf 'Bekannt:  NAS-IP %s%s%s\n' "$C_C" "$A_NAS_IP" "$C_RESET"
    if frage_ja "Stimmt das noch?" ja; then return 0; fi
    A_NAS_IP=""; A_NAS_PUBKEY=""
  fi
  while true; do
    lies_zeile "NAS-IP (mehrere mit Komma)  [Enter = später einrichten]: "
    if [ -z "$ANTWORT" ]; then
      A_NAS_IP=""; A_NAS_PUBKEY=""
      hinweis "Ohne NAS-Daten richte ich die tägliche Sicherung NICHT ein. Du holst das später nach (steht dann in deiner Liste)."
      return 0
    fi
    if ! gueltige_nas_ip "$ANTWORT"; then zeile "  Das ist keine gültige IP-Adresse (Beispiel: 203.0.113.7)."; continue; fi
    ip="$ANTWORT"
    lies_zeile "Öffentlicher SSH-Schlüssel des NAS (eine Zeile, beginnt mit ssh-ed25519): "
    if gueltiger_ssh_schluessel "$ANTWORT"; then A_NAS_IP="$ip"; A_NAS_PUBKEY="$ANTWORT"; return 0; fi
    zeile "  Das ist kein öffentlicher SSH-Schlüssel. Vorsicht: der PRIVATE Schlüssel (Datei ohne .pub) gehört nie hierher."
  done
}
frage_swap() { # Frage 4
  local std=nein wert=1024
  echo
  fett "Frage 4: Swap anlegen?"
  [ "$RAM_MB" -ge 4000 ] || std=ja
  if [ -n "$A_SWAP_MB" ]; then
    if [ "$A_SWAP_MB" = 0 ]; then std=nein; else std=ja; wert="$A_SWAP_MB"; fi
  fi
  zeile "Swap ist Ausweichspeicher auf der Platte. Bei 2 GB Arbeitsspeicher empfohlen (1 GB): Bau und Sicherung brauchen kurz viel. Ich lege ihn erst an, wenn dein Schlüssel verworfen ist."
  if frage_ja "Swap anlegen (${wert} MB)?" "$std"; then A_SWAP_MB="$wert"; else A_SWAP_MB=0; fi
}
lx_schluessel_kandidaten() { # öffentliche Schlüssel aus /root/.ssh/authorized_keys (nur Zeilen ohne Optionen vor dem Schlüssel)
  local z
  [ -f /root/.ssh/authorized_keys ] && [ ! -L /root/.ssh/authorized_keys ] || return 0
  while IFS= read -r z || [ -n "$z" ]; do
    z="${z%$'\r'}"
    if gueltiger_ssh_schluessel "$z"; then printf '%s\n' "$z"; fi
  done < /root/.ssh/authorized_keys
}
frage_lx_schluessel() { # Frage 5, nur wenn der Benutzer lx fehlt
  local kand=() z i
  echo
  fett "Frage 5: Dein SSH-Zugang als Benutzer lx"
  zeile "Der Benutzer lx fehlt auf diesem Server; ich lege ihn an (ohne Passwort). Für deploy-web.sh vom PC brauchst du dort deinen öffentlichen SSH-Schlüssel."
  if [ -n "$A_LX_PUBKEY" ]; then
    zeile "Bekannt: ${A_LX_PUBKEY:0:40}…"
    if frage_ja "Diesen Schlüssel für lx verwenden?" ja; then return 0; fi
    A_LX_PUBKEY=""
  fi
  while IFS= read -r z; do [ -n "$z" ] && kand+=("$z"); done < <(lx_schluessel_kandidaten)
  if [ "${#kand[@]}" -gt 0 ]; then
    zeile "Deine Anmeldeschlüssel als root (in /root/.ssh/authorized_keys):"
    i=0
    for z in "${kand[@]}"; do i=$((i + 1)); printf '  %s[%d]%s %s… %s\n' "$C_C" "$i" "$C_RESET" "$(cut -c1-48 <<<"$z")" "$(awk '{print $NF}' <<<"$z")"; done
    while true; do
      lies_zeile "Welchen soll lx bekommen?  [Enter = 1, Nummer, eigener Schlüssel oder 'keinen']: "
      case "${ANTWORT,,}" in
        '') A_LX_PUBKEY="${kand[0]}"; return 0 ;;
        keinen|keine|nein) A_LX_PUBKEY=""; return 0 ;;
      esac
      if [[ "$ANTWORT" =~ ^[0-9]{1,2}$ ]] && [ "$ANTWORT" -ge 1 ] && [ "$ANTWORT" -le "${#kand[@]}" ]; then A_LX_PUBKEY="${kand[$((ANTWORT - 1))]}"; return 0; fi
      if gueltiger_ssh_schluessel "$ANTWORT"; then A_LX_PUBKEY="$ANTWORT"; return 0; fi
      zeile "  Das ist weder eine Nummer noch ein öffentlicher SSH-Schlüssel."
    done
  fi
  while true; do
    lies_zeile "Öffentlicher SSH-Schlüssel deines PCs (eine Zeile)  [Enter = keiner, lx hat dann keinen SSH-Zugang]: "
    if [ -z "$ANTWORT" ]; then A_LX_PUBKEY=""; hinweis "lx bekommt keinen SSH-Zugang: deploy-web.sh geht erst nach dem Eintrag eines Schlüssels."; return 0; fi
    if gueltiger_ssh_schluessel "$ANTWORT"; then A_LX_PUBKEY="$ANTWORT"; return 0; fi
    zeile "  Das ist kein öffentlicher SSH-Schlüssel."
  done
}
schritt3() {
  local gesamt=4
  schritt_titel 3 "Fragen"
  if [ "$A_FRAGEN" = 1 ] && [ -n "$A_GIT_REF" ] && [ -n "$A_SWAP_MB" ]; then
    gut "Die übrigen Fragen sind schon beantwortet (Code-Stand ${A_GIT_REF}, Swap ${A_SWAP_MB} MB)."
    return 0
  fi
  if lx_fehlt; then gesamt=5; fi
  zeile "Es sind noch ${gesamt} Fragen (Frage 1 war die Sicherung). Alles in [Klammern] bestätigst du mit Enter."
  frage_code_stand
  frage_nas
  frage_swap
  if lx_fehlt; then frage_lx_schluessel; fi
  A_FRAGEN=1
  antworten_schreiben
}

# --- Schritt 4: Zusammenfassung (hier endet der Teil ohne Änderungen) -----------------------------------------------------------------
dns_ok() { # $1 Host
  [ "$OPT_DNS_SKIP" = 1 ] && return 0
  aus_bootstrap dns_pruefen "$1" >/dev/null 2>&1
}
plan_bauen() { # füllt PLAN (Phasen dieses Laufs) und CADDY_JETZT
  local p
  PLAN=(); CADDY_JETZT=0
  if dns_ok "$DOMAIN" && dns_ok "$NTFY_DOMAIN"; then CADDY_JETZT=1; fi
  for p in "${PHASEN[@]}"; do
    if [ "$p" = caddy ] && [ "$CADDY_JETZT" = 0 ]; then continue; fi
    if liste_enthaelt "$A_FERTIG" "$p"; then continue; fi
    PLAN+=("$p")
  done
}
bootstrap_basis() { # BA = die gemeinsamen Argumente für bootstrap-server.sh
  BA=(--params "$PARAMS_PFAD" --lx-anlegen)
  if [ "$OPT_SWAP_OK" = 1 ]; then BA+=(--swap-ok); fi
  if [ "$OPT_OHNE_SYSTEMD" = 1 ]; then BA+=(--ohne-systemd); fi
  if [ "$OPT_DNS_SKIP" = 1 ]; then BA+=(--dns-pruefung-ueberspringen); fi
  return 0
}
gegenprobe() { # bootstrap-server.sh --dry-run: prüft Parameter, Sicherung und Rechte, ohne etwas zu ändern; Befunde in PROBLEME
  local aus rc z
  PROBLEME=()
  bootstrap_basis
  aus="$(bash "$BOOTSTRAP" --dry-run "${BA[@]}" --sicherung "$A_SICHERUNG" --identity-stdin </dev/null 2>&1)"; rc=$?
  while IFS= read -r z; do
    case "$z" in *"PROBLEM:"*) PROBLEME+=("$(sed -E 's/^[[:space:]]*PROBLEM:[[:space:]]*//' <<<"$z")") ;; esac
  done <<<"$aus"
  if [ "$rc" -ne 0 ] && [ "${#PROBLEME[@]}" -eq 0 ]; then
    z="$(grep -E '^(FEHLER|Parameterdatei|--)' <<<"$aus" | head -n 1 || true)"
    PROBLEME+=("${z:-bootstrap-server.sh --dry-run meldet einen Fehler (Code $rc)}")
  fi
  return 0
}
schritt4() {
  local n=0 p extra
  schritt_titel 4 "Zusammenfassung"
  plan_bauen
  if [ "$OPT_PROBE" = 1 ]; then PARAMS_PFAD="$ARBEIT_DIR/umzug.params"; else PARAMS_PFAD="$PARAMS_ERZEUGT"; fi
  params_schreiben "$PARAMS_PFAD" || fehler_ende "Die Parameterdatei $PARAMS_PFAD ließ sich nicht schreiben." "Prüfe den freien Platz und die Rechte von /root."
  printf '%sDas passiert jetzt%s   %s(dauert etwa 20 Minuten)%s\n\n' "$C_B" "$C_RESET" "$C_D" "$C_RESET"
  printf '  Sicherung:    %s%s\n' "$(basename "$A_SICHERUNG")" "${CFG_VERSION:+, App-Version $CFG_VERSION}"
  printf '  Domain:       %s\n' "$DOMAIN"
  printf '  IP:           %s\n' "${A_IP:-?}"
  printf '  Code-Stand:   %s\n' "$A_GIT_REF"
  if [ "$A_SWAP_MB" = 0 ]; then printf '  Swap:         keiner\n'; else printf '  Swap:         %s MB (nach dem Verwerfen deines Schlüssels)\n' "$A_SWAP_MB"; fi
  if [ -n "$A_NAS_IP" ]; then printf '  NAS-Abholung: von %s\n' "$A_NAS_IP"
  else printf '  NAS-Abholung: %snicht eingerichtet%s (die tägliche Sicherung folgt erst mit den NAS-Daten)\n' "$C_Y" "$C_RESET"; fi
  if lx_fehlt; then printf '  Benutzer lx:  wird angelegt, %s\n' "$([ -n "$A_LX_PUBKEY" ] && echo "mit deinem SSH-Schlüssel" || echo "ohne SSH-Schlüssel")"; fi
  if [ -n "$A_KEEP$A_APK$A_FILES" ]; then printf '  Sicherung:    Einstellungen wie auf dem alten Server (behalte %s, APK %s, Dateiablage %s)\n' "${A_KEEP:-Standard}" "${A_APK:-Standard}" "${A_FILES:-Standard}"; fi
  echo
  zeile "  Ich werde:"
  for p in "${PLAN[@]}"; do
    n=$((n + 1)); extra=""
    if [ "$p" = code ]; then extra="   ${C_Y}(Pause: du trägst einen Schlüssel bei GitHub ein)${C_RESET}"; fi
    printf '   %s%d%s %s%s\n' "$C_C" "$n" "$C_RESET" "${PHASEN_NAME[$p]}" "$extra"
  done
  if [ "$CADDY_JETZT" = 0 ]; then printf '   %s·%s %s: später, nach deiner DNS-Umstellung (bash umzug.sh --weiter caddy)\n' "$C_D" "$C_RESET" "${PHASEN_NAME[caddy]}"; fi
  if [ "${#PLAN[@]}" -eq 0 ]; then zeile "   (nichts mehr: alle Phasen sind schon erledigt)"; fi
  echo
  printf '  %sNichts%s wird gelöscht. Dein alter Server bleibt unberührt.\n' "$C_G" "$C_RESET"
  zeile "  Das Haupt-Caddyfile und der Web-Auftritt von lx-labs.dev werden nie angefasst (bootstrap-server.sh ändert nur conf.d, mit Rückfall)."
  echo
  zeile "Gegenprobe (bootstrap-server.sh --dry-run, ändert nichts) …"
  gegenprobe
  if [ "${#PROBLEME[@]}" -gt 0 ]; then
    for p in "${PROBLEME[@]}"; do schlecht "$p"; done
    if [ "$OPT_PROBE" = 1 ]; then hinweis "Im echten Lauf würde der Assistent hier stoppen."
    else fehler_ende "Die Gegenprobe meldet ${#PROBLEME[@]} Problem(e)." "Behebe sie (siehe oben) und starte denselben Befehl noch einmal; nichts wurde verändert."; fi
  else gut "Gegenprobe ohne Befund (Parameter, Prüfsummen, Rechte)."; fi
}
bestaetigen() { # Rückgabe 0 = starten, 1 = Probelauf (Ende)
  local k
  echo
  if [ "$OPT_PROBE" = 1 ]; then
    printf '%sProbelauf beendet. Es wurde nichts verändert.%s Für den echten Lauf: bash umzug.sh\n' "$C_G" "$C_RESET"
    return 1
  fi
  [ "${#PLAN[@]}" -gt 0 ] || return 0
  printf '%sJetzt starten?%s Tippe %sumziehen%s zur Bestätigung (alles andere bricht ab): ' "$C_B" "$C_RESET" "$C_C" "$C_RESET" >&2
  if ! IFS= read -r k; then echo >&2; abbruch_eingabe; fi
  if [ "$(trimmen "${k%$'\r'}")" != umziehen ]; then
    zeile "Abgebrochen, es wurde nichts verändert. Deine Antworten sind gemerkt: starte denselben Befehl, wenn du bereit bist."
    exit 0
  fi
  return 0
}

# --- Schritt 5: Aufbau ---------------------------------------------------------------------------------------------------------------
scrub() { sed -E 's/AGE-SECRET-KEY-1[0-9A-Z]+/[entfernt]/g; s/tk_[A-Za-z0-9]+/tk_[entfernt]/g; s#(://[^:/@ ]+:)[^@ ]+@#\1[entfernt]@#g'; }
bericht_schreiben() { # $1 Ursache, $2 Maßnahme
  local tmp="$BERICHT_DATEI.neu.$$"
  {
    echo "lx-fampad Umzugs-Assistent: Fehlerbericht (ohne Geheimnisse: kein Schlüssel, keine Passwörter, keine Links, keine Programmausgaben)"
    echo "Zeit (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "Phase: $LETZTE_PHASE"
    echo "Ursache: $1"
    echo "Maßnahme: $2"
    echo "System: $(sed -nE 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'), Arbeitsspeicher ${RAM_MB} MB"
    echo
    echo "Gemerkte Antworten:"
    antworten_text | grep -v '^HINWEIS=' | sed 's/^/  /'
    echo
    echo "Letzte Meldungen von bootstrap-server.sh (nur seine eigenen Meldungen):"
    if [ -f "$LAUF_LOG" ]; then grep -E '^(==>|!!|FEHLER|PAUSE|    (Prüfpunkt|PROBLEM|WARNUNG|OFFEN))' "$LAUF_LOG" | tail -n 60 | scrub | sed 's/^/  /'; fi
  } > "$tmp" 2>/dev/null && chmod 600 "$tmp" && mv -f "$tmp" "$BERICHT_DATEI"
}
fehlermassnahme() { # $1 letzte FEHLER-Zeile von bootstrap-server.sh -> Maßnahme in einem Satz
  case "$1" in
    *"Swap ist aktiv"*) echo "Führe 'swapoff -a' aus und starte denselben Befehl noch einmal (oder bewusst mit --swap-ok)." ;;
    *"nicht lesen oder ist kein pg_dump"*|*"no identity matched"*) echo "Der Schlüssel passt nicht zu dieser Sicherung: starte neu und gib den richtigen Schlüssel ein." ;;
    *"Prüfsummen stimmen nicht"*) echo "Die Sicherung ist beschädigt: kopiere sie noch einmal oder nimm eine ältere vom NAS." ;;
    *"muss root gehören"*) echo "Führe 'chown -R root:root' und 'chmod -R go-w' auf den Sicherungsordner aus und starte neu." ;;
    *"PUBLIC_URL der Sicherung"*) echo "Die Sicherung gehört zu einer anderen Domain: nimm die Sicherung des Servers von $DOMAIN." ;;
    *"GIT_REF"*) echo "Prüfe den Tag (git tag auf deinem PC) und starte mit 'bash umzug.sh --neu' neu, um ihn neu einzugeben." ;;
    *"deploy.sh fehlgeschlagen"*) echo "Der Code-Stand passt vermutlich nicht zur Datenbank: nimm einen neueren Tag ('bash umzug.sh --neu'); Einzelheiten: journalctl -u lx-fampad-migrate -n 50." ;;
    *"weicht von der Sicherung ab"*) echo "Auf diesem Server liegt schon eine andere Konfiguration: nimm einen frischen Server." ;;
    *"Caddy"*|*"antwortet nicht"*|*"Zertifikat"*) echo "Prüfe die DNS-Einträge (dig +short $DOMAIN), warte mindestens eine Stunde (Grenzen von Let's Encrypt) und starte 'bash umzug.sh --weiter caddy' erneut." ;;
    *) echo "Behebe die Ursache laut Meldung (Einzelheiten: $LAUF_LOG) und starte denselben Befehl noch einmal: Erledigtes wird übersprungen." ;;
  esac
}
# bootstrap-server.sh mit BA ausführen und den Fortschritt zeigen; bootstrap-server.sh läuft in einem eigenen Prozess, seine Ausgabe kommt über eine
# Pipe (Dateideskriptor 7), das Ende meldet eine Marke. Rückgabe: Exit-Code von bootstrap-server.sh. Der Schlüssel geht nur in seine stdin-Pipe.
lauf_ausfuehren() { # $1 Anzeigename, $2 Nummer-Text, $3 mit Schlüssel (1|0); Argumente in BA
  local name="$1" nr="$2" mitkey="$3" sentinel="__UMZUG_RC_${RANDOM}${RANDOM}__" start=$SECONDS rc=-1 z="" teil="" lesen
  PAUSE_KEY=""; LETZTER_FEHLER=""
  if [ "$mitkey" = 1 ] && [ -z "$AGE_ID" ]; then fehler_ende "Der Schlüssel ist nicht mehr im Speicher, wird aber für \"$name\" gebraucht." "Starte denselben Befehl noch einmal: ich frage den Schlüssel erneut ab."; fi
  printf '%s▶%s %s %s\n' "$C_Y" "$C_RESET" "$nr" "$name"
  echo "=== $(date -u '+%F %T') UTC  $name" >> "$LAUF_LOG"
  if [ "$mitkey" = 1 ]; then
    exec 7< <( bash "$BOOTSTRAP" "${BA[@]}" < <(printf '%s\n' "$AGE_ID") 2>&1; echo "$sentinel$?" )
  else
    exec 7< <( bash "$BOOTSTRAP" "${BA[@]}" < /dev/null 2>&1; echo "$sentinel$?" )
  fi
  while true; do
    if [ -t 1 ]; then IFS= read -r -t 20 -u 7 z; lesen=$?; else IFS= read -r -u 7 z; lesen=$?; fi
    if [ "$lesen" -gt 128 ]; then teil="$teil$z"; printf '    %s… läuft seit %s%s\n' "$C_D" "$(dauer $((SECONDS - start)))" "$C_RESET"; continue; fi
    [ "$lesen" -eq 0 ] || break
    z="$teil$z"; teil=""
    z="${z%$'\r'}"
    if [[ "$z" == "$sentinel"* ]]; then rc="${z#"$sentinel"}"; break; fi
    printf '%s\n' "$z" >> "$LAUF_LOG"
    case "$z" in
      "    OFFEN: "*) hinweis_merken "${z#    OFFEN: }" ;;
      "    WARNUNG: "*) printf '    %s! %s%s\n' "$C_Y" "${z#    WARNUNG: }" "$C_RESET" ;;
      "FEHLER: "*) printf '    %s%s%s\n' "$C_R" "$z" "$C_RESET"; LETZTER_FEHLER="${z#FEHLER: }" ;;
      "!!  "*) printf '    %s%s%s\n' "$C_R" "$z" "$C_RESET" ;;
      *"CODE-STAND DIESES LAUFS"*) printf '    %s\n' "$(sed -E 's/^[[:space:]]*==> //' <<<"$z")" ;;
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) if [[ "$z" =~ $SSH_KEY_RE ]]; then PAUSE_KEY="$z"; fi ;;
    esac
  done
  exec 7<&-
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  DAUER_LETZT="$(dauer $((SECONDS - start)))"
  return "$rc"
}
phase_meldung_ok() { printf '%s✓%s %s %s   %s%s%s\n' "$C_G" "$C_RESET" "$1" "$2" "$C_D" "$DAUER_LETZT" "$C_RESET"; }
github_pause() { # zeigt den öffentlichen Deploy-Key und wartet auf "weiter"; Rückgabe 0 = weiter, 1 = abgebrochen
  local k
  echo
  printf '%s║  PAUSE: GitHub lässt diesen Server noch nicht lesen.%s\n' "$C_Y" "$C_RESET"
  printf '%s║%s\n' "$C_Y" "$C_RESET"
  printf '%s║  Trage diesen öffentlichen Schlüssel bei GitHub ein%s\n' "$C_Y" "$C_RESET"
  printf '%s║  (Repository › Settings › Deploy keys › Add deploy key, OHNE Schreibrecht):%s\n' "$C_Y" "$C_RESET"
  printf '%s║  %s%s\n' "$C_Y" "$GITHUB_SCHLUESSEL_SEITE" "$C_RESET"
  printf '%s║%s\n' "$C_Y" "$C_RESET"
  if [ -n "$PAUSE_KEY" ]; then printf '%s║  %s%s%s\n' "$C_Y" "$C_B" "$PAUSE_KEY" "$C_RESET"
  else printf '%s║  (Schlüssel nicht gefunden: auf diesem Server: cat /home/%s/.ssh/id_ed25519_fampad.pub)%s\n' "$C_Y" "$LX_USER" "$C_RESET"; fi
  printf '%s║%s\n' "$C_Y" "$C_RESET"
  while true; do
    printf '%s║  Wenn du fertig bist, tippe %sweiter%s%s (oder %sabbrechen%s%s, um später mit demselben Befehl fortzufahren):%s ' "$C_Y" "$C_C" "$C_RESET" "$C_Y" "$C_C" "$C_RESET" "$C_Y" "$C_RESET" >&2
    if ! IFS= read -r k; then echo >&2; return 1; fi
    case "$(trimmen "${k,,}")" in weiter) return 0 ;; abbrechen) return 1 ;; esac
  done
}
aufbau_phase() { # $1 Phase; Rückgabe 0 = fertig
  local p="$1" nr i=0 idx mitkey=0 rc
  for idx in "${!PHASEN[@]}"; do if [ "${PHASEN[$idx]}" = "$p" ]; then i=$((idx + 1)); fi; done
  nr="$i/${#PHASEN[@]}"
  if liste_enthaelt "$SCHLUESSEL_PHASEN" "$p"; then mitkey=1; fi
  LETZTE_PHASE="$p"
  bootstrap_basis
  BA+=(--phase "$p")
  if liste_enthaelt "$BIS_DATENBANK" "$p"; then BA+=(--sicherung "$A_SICHERUNG" --identity-stdin); fi
  while true; do
    lauf_ausfuehren "${PHASEN_NAME[$p]}" "$nr" "$mitkey"; rc=$?
    if [ "$rc" -eq 0 ]; then phase_meldung_ok "$nr" "${PHASEN_NAME[$p]}"; fertig_markieren "$p"; return 0; fi
    if [ "$rc" -eq 10 ] && [ "$p" = code ]; then
      if github_pause; then continue; fi
      antworten_schreiben
      echo
      zeile "Pausiert. Trage den Schlüssel bei GitHub ein und starte danach denselben Befehl noch einmal (bash umzug.sh): Erledigtes wird übersprungen."
      zeile "Dein privater Schlüssel wird dann noch einmal abgefragt (er wird nie gespeichert)."
      exit 10
    fi
    printf '%s✗%s %s %s\n' "$C_R" "$C_RESET" "$nr" "${PHASEN_NAME[$p]}" >&2
    fehler_ende "Die Phase \"${PHASEN_NAME[$p]}\" ist fehlgeschlagen${LETZTER_FEHLER:+: $LETZTER_FEHLER}." "$(fehlermassnahme "$LETZTER_FEHLER")"
  done
}
schritt5() {
  local p
  schritt_titel 5 "Aufbau"
  : >> "$LAUF_LOG"; chmod 600 "$LAUF_LOG" 2>/dev/null || true
  antworten_schreiben
  for p in "${PLAN[@]}"; do
    aufbau_phase "$p"
    # nach der letzten Entschlüsselung (Ende der Phase datenbank) verschwindet der Schlüssel aus dem Arbeitsspeicher
    if [ "$p" = datenbank ] && [ -n "$AGE_ID" ]; then
      AGE_ID=""; unset AGE_ID; AGE_ID=""
      blass "    Schlüssel aus dem Arbeitsspeicher des Assistenten entfernt (alle Entschlüsselungen sind erledigt)."
    fi
    if [ "$p" = caddy ]; then erledigt_markieren caddy; fi
  done
  AGE_ID=""; unset AGE_ID; AGE_ID=""
  if [ "$CADDY_JETZT" = 0 ]; then printf '%s·%s %s: später, nach deiner DNS-Umstellung\n' "$C_D" "$C_RESET" "${PHASEN_NAME[caddy]}"; fi
}

# --- Schritt 6: Dein Teil -----------------------------------------------------------------------------------------------------------
host_fingerabdruck() {
  local f=/etc/ssh/ssh_host_ed25519_key.pub fp=""
  if [ -r "$f" ]; then fp="$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}')"; fi
  printf '%s' "$fp"
}
lx_hat_schluessel() { # hat der Benutzer lx schon einen SSH-Schlüssel?
  local home
  home="$(getent passwd "$LX_USER" | cut -d: -f6)"
  [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ]
}
erl() { liste_enthaelt "$A_ERLEDIGT" "$1" && printf '   -> erledigt'; return 0; }
l() { LISTE+=("$*"); }
liste_bauen() { # füllt LISTE (reiner Text; Überschriften beginnen mit "[n] ")
  local n=0 ip="${A_IP:-<IP>}" fp h hinweisliste=()
  LISTE=()
  fp="$(host_fingerabdruck)"
  l "Jetzt bist du dran. Reihenfolge einhalten:"
  l ""
  l "Vorab: Läuft der ALTE Server noch und hat sich seit der Sicherung etwas geändert (Nachrichten, Termine), fehlt es hier. Für einen verlustfreien Umzug:"
  l "  alt:   sudo systemctl stop lx-fampad lx-fampad-weather && sudo systemctl start lx-fampad-backup.service"
  l "  dann die frische Sicherung holen und hier neu einspielen (docs/NEUINSTALLATION.md, \"Umzug bei laufendem Altserver\")."
  l ""
  n=$((n + 1)); l "[$n] DNS bei Cloudflare umstellen  (graue Wolke, \"DNS only\")"
  l "      familie        A   $ip"
  l "      ntfy.familie   A   $ip"
  if [ -n "$IP_V6" ]; then l "      Gibt es einen AAAA-Eintrag: auf $IP_V6 umstellen oder löschen (sonst zeigt er noch zum alten Server)."
  else l "      Einen vorhandenen AAAA-Eintrag löschen (dieser Server hat keine globale IPv6-Adresse)."; fi
  l "    Kontrolle:  dig +short $DOMAIN   (muss $ip zeigen; unter Windows: nslookup $DOMAIN 1.1.1.1)"
  n=$((n + 1)); l "[$n] Caddy und Zertifikate holen  (erst nach [1]!)$(erl caddy)"
  l "      bash umzug.sh --weiter caddy"
  n=$((n + 1)); l "[$n] Web-App hochladen  (auf deinem PC, im Git-Checkout von lx-fampad)"
  if lx_hat_schluessel; then l "      SSH_HOST=lx@$ip deploy/deploy-web.sh"
  else l "      Auf diesem Server hat lx noch keinen SSH-Schlüssel: trage deinen öffentlichen Schlüssel in /home/lx/.ssh/authorized_keys ein, dann: SSH_HOST=lx@$ip deploy/deploy-web.sh"; fi
  n=$((n + 1))
  if [ -n "$A_NAS_IP" ]; then
    l "[$n] NAS neu verbinden  (auf dem NAS)"
    l "      ssh-keygen -R $DOMAIN -f ~/.ssh/lx-fampad-backup.known_hosts"
    l "      ssh-keyscan -t ed25519 $DOMAIN >> ~/.ssh/lx-fampad-backup.known_hosts"
    l "      Fingerabdruck vergleichen:  ${fp:-(auf dem Server: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)}"
    l "      Probe: lx-fampad-pull.sh --dry-run   (der SSH-Schlüssel des NAS bleibt gültig)"
  else
    l "[$n] NAS-Abholung nachholen  (nicht eingerichtet: es gibt noch keine tägliche Sicherung auf diesem Server)"
    l "      In $PARAMS_ERZEUGT zwei Zeilen ergänzen: BACKUP_NAS_PUBKEY=<öffentlicher SSH-Schlüssel des NAS>  und  BACKUP_NAS_IP=<IP des NAS>"
    l "      dann: bash $HIER/bootstrap-server.sh --params $PARAMS_ERZEUGT --phase sicherung   und danach den Host-Schlüssel auf dem NAS neu lernen (docs/NEUINSTALLATION.md, Abschnitt 6)"
  fi
  n=$((n + 1)); l "[$n] Alten Server stoppen"
  l "      alt:   sudo systemctl stop lx-fampad lx-fampad-weather"
  if [ "$A_WETTER" = 1 ]; then
    n=$((n + 1)); l "[$n] Wetter-Dienst hier starten  (erst wenn der alte Server aus ist: Netatmo erlaubt nur einen Abrufer)$(erl wetter)"
    l "      neu:   bash umzug.sh --weiter wetter"
    l "      Ist das gesicherte Token veraltet: sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js"
  fi
  if [ "$A_MUELL" = 1 ]; then
    n=$((n + 1)); l "[$n] Müll-Dienst (Abfuhrtermine) hier starten  (nach dem Stopp des alten Servers)$(erl muell)"
    if [ "$A_MUELL_LINK" = 1 ]; then l "      Der Link des Abfallkalenders steht in der gesicherten Konfiguration und ist schon hier."
    else l "      Der Link des Abfallkalenders fehlt in der Sicherung: erst  sudo bash /home/$LX_USER/lx-fampad/deploy/einrichtung-muell.sh einstellungen  (der Link wird unsichtbar abgefragt)."; fi
    l "      neu:   bash umzug.sh --weiter muell"
  fi
  n=$((n + 1)); l "[$n] Wiederherstellungstest  (auf deinem PC, mit dem PRIVATEN Schlüssel)"
  l "      deploy/backup/wiederherstellung-test.sh --identity ~/lx-fampad-age.key --run-dir <vom NAS geholte NEUE Sicherung dieses Servers>"
  l "      (erst nach der ersten Nacht um 03:30; Anleitung: docs/BACKUP-EINRICHTUNG-SCHRITTE.md)"
  l ""
  l "Danach, wenn du Zeit hast:"
  l "  - Firewall: nur 22, 80 und 443 offen (Anbieter-Firewall oder ufw); SSH nur mit Schlüssel."
  l "  - Release-Upload per GitHub Actions: Secrets VPS_HOST ($ip) und VPS_KNOWN_HOSTS (ssh-keyscan -t ed25519 $ip; Fingerabdruck ${fp:-vergleichen}) in der Environment vps-deploy."
  l "  - Karte (1,1 GB) neu erzeugen und Fallback-Schriften nach /srv/fampad/font-fallback (deploy/README.md, Abschnitte 8 und 11)."
  l "  - TTL der DNS-Einträge wieder erhöhen; den alten Server erst nach mindestens einer Woche stabilem Betrieb abgeben (Datenträger bereinigen lassen)."
  for h in "${HINWEISE[@]}"; do
    case "$h" in
      "Die neue Sicherung ist UNGEPRÜFT"*|"DNS zeigt noch nicht"*|"Wetter-Dienst ist installiert"*) ;;
      *) hinweisliste+=("$h") ;;
    esac
  done
  if [ "${#hinweisliste[@]}" -gt 0 ]; then
    l ""
    l "Außerdem meldet der Aufbau noch:"
    for h in "${hinweisliste[@]}"; do l "  - $h"; done
  fi
}
liste_ausgeben() { # farbig auf dem Terminal
  local z
  for z in "${LISTE[@]}"; do
    case "$z" in
      "["[0-9]*"] "*) printf '%s%s%s\n' "$C_C" "$z" "$C_RESET" ;;
      "      "*) printf '%s%s%s\n' "$C_B" "$z" "$C_RESET" ;;
      *) printf '%s\n' "$z" ;;
    esac
  done
}
liste_schreiben() {
  local tmp="$OFFEN_DATEI.neu.$$"
  { echo "lx-fampad Umzug: Dein Teil (vom Assistenten geschrieben, $(date -u '+%Y-%m-%d %H:%M UTC'); enthält keine Geheimnisse)"; echo; printf '%s\n' "${LISTE[@]}"; } > "$tmp" \
    && chmod 600 "$tmp" && mv -f "$tmp" "$OFFEN_DATEI"
}
schritt6() {
  schritt_titel 6 "Dein Teil"
  printf '%sDer Server läuft.%s  %sLokale Prüfung bestanden (Datenbank, Migrationen, Dienste)%s\n\n' "$C_G" "$C_RESET" "$C_D" "$C_RESET"
  liste_bauen
  liste_ausgeben
  if liste_schreiben; then echo; blass "Die Liste liegt auch in $OFFEN_DATEI."; else hinweis "Die Liste ließ sich nicht nach $OFFEN_DATEI schreiben."; fi
}

# --- --weiter: einzelne Folgeschritte -----------------------------------------------------------------------------------------------
weiter_vorbereiten() {
  antworten_lesen || fehler_ende "Es gibt noch keinen Lauf des Assistenten auf diesem Server (keine gemerkten Antworten)." "Starte zuerst: bash umzug.sh"
  liste_enthaelt "$A_FERTIG" datenbank || fehler_ende "Der Aufbau ist noch nicht bis zur Datenbank gekommen." "Starte zuerst: bash umzug.sh (derselbe Befehl setzt dort fort)."
  [ -f "$PARAMS_ERZEUGT" ] || fehler_ende "Die Parameterdatei $PARAMS_ERZEUGT fehlt." "Starte zuerst: bash umzug.sh"
  PARAMS_PFAD="$PARAMS_ERZEUGT"
  ip_erkennen
  [ -n "$A_IP" ] || A_IP="$IP_V4"
  : >> "$LAUF_LOG"; chmod 600 "$LAUF_LOG" 2>/dev/null || true
}
weiter_phasen() { # $1 Phasen (kommagetrennt), $2 Anzeige, $3 zusätzliche Option für bootstrap-server.sh (optional)
  local rc
  LETZTE_PHASE="$1"
  bootstrap_basis
  BA+=(--phase "$1")
  if [ -n "${3:-}" ]; then BA+=("$3"); fi
  lauf_ausfuehren "$2" "·" 0; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s✗%s %s\n' "$C_R" "$C_RESET" "$2" >&2
    fehler_ende "\"$2\" ist fehlgeschlagen${LETZTER_FEHLER:+: $LETZTER_FEHLER}." "$(fehlermassnahme "$LETZTER_FEHLER")"
  fi
  phase_meldung_ok "·" "$2"
}
weiter_liste() { echo; liste_bauen; liste_ausgeben; if liste_schreiben; then blass "Die Liste liegt auch in $OFFEN_DATEI."; fi; }
weiter_caddy() {
  local h bad=0
  weiter_vorbereiten
  echo; fett "Caddy und Zertifikate"
  for h in "$DOMAIN" "$NTFY_DOMAIN"; do
    if dns_ok "$h"; then gut "DNS ok: $h zeigt auf diesen Server"
    else schlecht "DNS: $h zeigt noch nicht auf diesen Server (${A_IP:-?})."; bad=1; fi
  done
  if [ "$bad" = 1 ]; then
    fehler_ende "Der DNS-Eintrag zeigt noch nicht auf diesen Server; Caddy würde keine Zertifikate bekommen und Let's-Encrypt-Versuche verbrauchen." "Stelle die A-Einträge familie und ntfy.familie auf ${A_IP:-diesen Server} (DNS only), warte, bis 'dig +short $DOMAIN' die Adresse zeigt, und wiederhole den Befehl."
  fi
  weiter_phasen "caddy,pruefung" "Caddy, Zertifikate und Abschlussprüfung"
  fertig_markieren caddy; fertig_markieren pruefung; erledigt_markieren caddy
  gut "https://$DOMAIN und https://$NTFY_DOMAIN antworten."
  weiter_liste
}
weiter_wetter() {
  weiter_vorbereiten
  echo; fett "Wetter-Dienst starten"
  if [ "$A_WETTER" != 1 ]; then zeile "Das Wetter war auf dem alten Server nicht eingeschaltet: nichts zu tun."; return 0; fi
  zeile "Netatmo erlaubt nur EINEN Abrufer gleichzeitig (das Token wird bei jedem Abruf erneuert)."
  lies_zeile "Ist der alte Server aus (lx-fampad-weather gestoppt)? Tippe ja, um fortzufahren: "
  if [ "${ANTWORT,,}" != ja ]; then zeile "Gut, ich starte nichts. Stoppe zuerst den alten Server und wiederhole den Befehl."; return 0; fi
  weiter_phasen "anwendung" "Server neu bauen und Wetter-Dienst einschalten" "--wetter-starten"
  erledigt_markieren wetter
  weiter_liste
}
weiter_muell() {
  local ziel
  weiter_vorbereiten
  echo; fett "Müll-Dienst starten"
  if [ "$A_MUELL" != 1 ]; then zeile "Die Abfuhrtermine waren auf dem alten Server nicht eingeschaltet: nichts zu tun."; return 0; fi
  ziel="$(getent passwd "$LX_USER" | cut -d: -f6)/lx-fampad/deploy/einrichtung-muell.sh"
  [ -f "$ziel" ] || fehler_ende "$ziel fehlt (Code-Stand ohne Abfuhrtermine?)." "Nimm einen Code-Stand ab v0.9.0 ('bash umzug.sh --neu') oder lass den Müll-Dienst weg."
  if [ "$A_MUELL_LINK" != 1 ]; then
    fehler_ende "Der Link des Abfallkalenders fehlt in der Sicherung." "Führe zuerst aus: sudo bash $ziel einstellungen   (der Link wird unsichtbar abgefragt) und wiederhole dann diesen Befehl."
  fi
  lies_zeile "Ist der alte Server aus (Müll-Dienst dort gestoppt)? Tippe ja, um fortzufahren: "
  if [ "${ANTWORT,,}" != ja ]; then zeile "Gut, ich starte nichts. Stoppe zuerst den alten Server und wiederhole den Befehl."; return 0; fi
  LETZTE_PHASE="muell"
  echo "=== $(date -u '+%F %T') UTC  einrichtung-muell.sh dienst" >> "$LAUF_LOG"
  if ! bash "$ziel" dienst >>"$LAUF_LOG" 2>&1; then
    fehler_ende "Der Müll-Dienst ließ sich nicht einrichten." "Einzelheiten: $LAUF_LOG (oder direkt: sudo bash $ziel dienst)."
  fi
  gut "Müll-Dienst (lx-fampad-waste) eingerichtet und gestartet."
  erledigt_markieren muell
  weiter_liste
}
weiter_pruefung() {
  weiter_vorbereiten
  echo; fett "Abschlussprüfung"
  weiter_phasen "pruefung" "Abschlussprüfung"
  fertig_markieren pruefung
  weiter_liste
}

# --- Aufruf -------------------------------------------------------------------------------------------------------------------------
hilfe() { sed -n '2,/^set -u/{/^set -u/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
argumente_lesen() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --probe) OPT_PROBE=1 ;;
      --weiter) [ $# -ge 2 ] || { echo "--weiter braucht einen Wert (caddy, wetter, muell, pruefung)" >&2; exit 2; }; OPT_WEITER="$2"; shift ;;
      --ip) [ $# -ge 2 ] || { echo "--ip braucht einen Wert" >&2; exit 2; }; OPT_IP="$2"; shift ;;
      --params) [ $# -ge 2 ] || { echo "--params braucht einen Wert" >&2; exit 2; }; OPT_PARAMS="$2"; shift ;;
      --neu) OPT_NEU=1 ;;
      --swap-ok) OPT_SWAP_OK=1 ;;
      --ohne-systemd) OPT_OHNE_SYSTEMD=1 ;;
      --dns-pruefung-ueberspringen) OPT_DNS_SKIP=1 ;;
      -h|--help|--hilfe) hilfe; exit 0 ;;
      *) echo "Unbekannte Option: $1 (--hilfe)" >&2; exit 2 ;;
    esac
    shift
  done
  case "$OPT_WEITER" in ''|caddy|wetter|muell|pruefung) ;; *) echo "Unbekannter Folgeschritt: $OPT_WEITER (erlaubt: caddy, wetter, muell, pruefung)" >&2; exit 2 ;; esac
  if [ -n "$OPT_WEITER" ] && { [ "$OPT_PROBE" = 1 ] || [ "$OPT_NEU" = 1 ]; }; then echo "--weiter geht nicht zusammen mit --probe oder --neu" >&2; exit 2; fi
  if [ -n "$OPT_IP" ] && { ! gueltige_ipv4 "$OPT_IP" || private_ipv4 "$OPT_IP"; }; then echo "--ip braucht eine öffentliche IPv4-Adresse (Beispiel: 203.0.113.10)" >&2; exit 2; fi
  if [ "$OPT_DNS_SKIP" = 1 ] && [ "$OPT_OHNE_SYSTEMD" = 0 ]; then echo "--dns-pruefung-ueberspringen gibt es nur zusammen mit --ohne-systemd (Container-Tests)" >&2; exit 2; fi
  return 0
}
main() {
  argumente_lesen "$@"
  farben_init
  [ "$(id -u)" -eq 0 ] || { echo "Bitte als root starten:  sudo bash $0" >&2; exit 2; }
  trap aufraeumen EXIT
  trap unterbrochen INT TERM HUP
  bootstrap_pruefen
  ARBEIT_DIR="$(mktemp -d -p /run umzug.XXXXXXXX 2>/dev/null || mktemp -d)"
  chmod 700 "$ARBEIT_DIR"
  if [ -n "$OPT_WEITER" ]; then
    case "$OPT_WEITER" in caddy) weiter_caddy ;; wetter) weiter_wetter ;; muell) weiter_muell ;; pruefung) weiter_pruefung ;; esac
    exit 0
  fi
  echo
  fett "lx-fampad · Umzugs-Assistent"
  if [ "$OPT_NEU" = 1 ]; then antworten_zuruecksetzen; rm -f "$ANTWORTEN_DATEI"
  elif [ "$OPT_PROBE" = 0 ] && antworten_lesen; then
    echo
    zeile "Ich habe die Antworten eines früheren Laufs gefunden:"
    printf '  Sicherung %s, Code-Stand %s, fertige Phasen: %s\n' "${A_SICHERUNG:-?}" "${A_GIT_REF:-?}" "${A_FERTIG:-keine}"
    if ! frage_ja "Damit weitermachen?" ja; then antworten_zuruecksetzen; rm -f "$ANTWORTEN_DATEI"; fi
  fi
  if [ -n "$OPT_PARAMS" ]; then extra_params_lesen "$OPT_PARAMS"; fi
  schritt1
  schritt2
  schritt3
  schritt4
  bestaetigen || exit 0
  schritt5
  schritt6
  exit 0
}

# Nur ausführen, wenn das Skript gestartet (nicht eingelesen) wird; test-umzug.sh liest es ein und prüft die Hilfsfunktionen.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${UMZUG_NUR_FUNKTIONEN:-}" ]; then
  main "$@"
  exit $?
fi
