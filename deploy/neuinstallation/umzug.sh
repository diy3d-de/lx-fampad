#!/usr/bin/env bash
# Umzugs-Assistent für lx-fampad: eine geführte Hülle um bootstrap-server.sh (liegt im selben Ordner; der Assistent ersetzt es nicht, er stellt nur die
# Fragen, baut die Befehle zusammen, zeigt den Fortschritt und schreibt am Ende deine fertige Liste). Anleitung: docs/NEUINSTALLATION.md, Abschnitt "Mit dem Assistenten".
#
# Aufruf (root, am besten in tmux, auf dem NEUEN Server, Debian 13):   bash umzug.sh [Optionen]
#   (ohne Option)              der ganze Ablauf in sechs Schritten: 1 Willkommen und Prüfung, 2 Sicherung und Schlüssel, 3 Fragen, 4 Zusammenfassung,
#                              5 Aufbau, 6 "Dein Teil" (Liste mit deinen Werten, auch in /root/umzug-offen.txt)
#   --probe                    Probelauf: läuft bis zur Zusammenfassung und ändert nichts (nichts wird installiert, gemerkt oder geschrieben)
#   --aktualisieren            Umzug bei laufendem Altserver: eine NEUERE Sicherung einspielen (ersetzt die Datenbank; die bisherige bleibt umbenannt erhalten;
#                              die env dieses Servers nur bei abweichendem AUTH_SECRET_KEY). Erst nach dem Aufbau, vor der DNS-Umstellung.
#                              Schutz: Wort "aelter" bei gleicher/älterer Sicherung, Wort "verlieren" bei schon produktivem Server, Wort "anders" bei anderem Schlüssel.
#   --weiter caddy             nach der DNS-Umstellung: Caddy und Zertifikate (bootstrap --phase caddy,pruefung)
#   --weiter wetter            nachdem der ALTE Server aus ist: Wetter-Dienst starten (Netatmo erlaubt nur einen Abrufer)
#   --weiter muell             nachdem der ALTE Server aus ist: Müll-Dienst (Abfuhrtermine) starten
#   --weiter nasstatus         NAS-Rückmeldung ("Status vom NAS", Betrieb Paket 3) neu einrichten: fragt den öffentlichen zweiten SSH-Schlüssel des NAS und ruft einrichtung-nasstatus.sh auf
#   --weiter pruefung          Abschlussprüfung wiederholen und die Liste neu schreiben (geht auch ohne den Sicherungsordner)
#   --ip ADRESSE               öffentliche IPv4-Adresse dieses Servers (sonst erkennt der Assistent sie; nur nötig hinter NAT)
#   --params DATEI             optionale Parameterdatei (nur Öffentliches, Vorlage parameter.beispiel) als Vorgabe, z. B. mit den NAS-Daten aus deinen Unterlagen;
#                              der Pfad wird gemerkt (nicht der Inhalt) und beim Neustart wieder gelesen
#   --neu                      gemerkte Antworten verwerfen und alles neu fragen (der Stand des Aufbaus bleibt; ein anderer Code-Stand setzt ihn ab "code" zurück)
#   --swap-ok                  trotz aktivem Swap fortfahren (sonst Abbruch VOR dem Einlesen des Schlüssels; wie bei bootstrap-server.sh)
#   --ohne-systemd, --dns-pruefung-ueberspringen   NUR für Container-Tests, werden an bootstrap-server.sh weitergegeben (das sie selbst absichert)
#   --hilfe                    diese Hilfe
# Exit-Codes: 0 fertig, 1 Fehler (Bericht: /root/umzug-bericht.txt), 2 falscher Aufruf, 10 pausiert (GitHub-Schlüssel: denselben Befehl noch einmal starten).
#
# Neustart nach einem Abbruch: derselbe Befehl. Gemerkt werden NUR Nicht-Geheimes (Sicherungspfad, Code-Stand, IP, Swap-Wunsch, NAS-Daten, Pfad der --params-Datei,
# Stand des Aufbaus) in /root/.umzug-antworten (root, 0600). Der private age-Schlüssel wird nie gemerkt: er wird unsichtbar eingelesen, liegt nur in einer
# Shell-Variable dieses Prozesses (nie in einer Datei, nie in Argumenten, Umgebung oder Log), geht an bootstrap-server.sh nur über eine Pipe (--identity-stdin)
# und wird nach der letzten Verwendung (Ende der Phase datenbank) verworfen. Nach einem Neustart vor diesem Punkt fragt der Assistent ihn noch einmal.
# Sicherheit: bootstrap-server.sh läuft als root; der Assistent kopiert es beim Start in ein root-eigenes Arbeitsverzeichnis (/run, 0700), prüft dort Eigentümer und
# Rechte und führt NUR diese Kopie aus. xtrace (bash -x), Speicherabzüge (ulimit -c 0) und ein Terminal ohne Echo werden abgesichert.
# Das Haupt-Caddyfile (lx-labs.dev) fasst dieses Skript nie an; bootstrap-server.sh legt es nur an, wenn es fehlt oder noch das unveränderte Standard-Caddyfile
# ist (eine Kopie bleibt), ein fremdes bleibt unangetastet; sonst nur conf.d, mit Rückfall.
#
# Das gesamte Skript steht in Funktionen (bash liest es vollständig, bevor es etwas ausführt).
set -uo pipefail
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
umask 077

# --- Festwerte ----------------------------------------------------------------------------------------------------------------------
# Absichtlich nicht "readonly": aus_bootstrap() liest bootstrap-server.sh in einer Unterschale ein, das dieselben Namen schreibgeschützt setzt.
UMZUG_VERSION="0.21.0"                                 # Stand des Projekts (Versionskopf); bei jedem Versionsbump mitziehen: test-umzug.sh verlangt UMZUG_VERSION >= Version in app/pubspec.yaml
DOMAIN="familie.lx-labs.dev"                          # fest: Passkeys (RP-ID) hängen daran
NTFY_DOMAIN="ntfy.familie.lx-labs.dev"
LX_USER="lx"
PHASEN=(pruefen pakete system code konfiguration datenbank anwendung ntfy caddy sicherung pruefung)   # wie in bootstrap-server.sh (test-umzug.sh vergleicht)
GITHUB_SCHLUESSEL_SEITE="https://github.com/diy3d-de/lx-fampad/settings/keys"
SCHLUESSEL_PHASEN="pakete,konfiguration,datenbank"    # hier entschlüsselt bootstrap-server.sh (Schlüssel nötig)
BIS_DATENBANK="pruefen,pakete,system,code,konfiguration,datenbank"   # diese Phasen bekommen --sicherung (Wiederherstellung)
NACH_CODE="code,anwendung,ntfy,caddy,sicherung,pruefung"             # setzt ein anderer Code-Stand zurück (konfiguration und datenbank bleiben)
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
SWAPS_DATEI="/proc/swaps"                             # für Tests ersetzbar
ENV_LOKAL="/etc/lx-fampad/env"                        # die Konfiguration dieses Servers (für den Vergleich bei --aktualisieren; für Tests ersetzbar)
LOCK_DATEI="/run/lock/lx-fampad-umzug.lock"           # Sperre gegen zwei gleichzeitige Sitzungen
SUDOERS_DATEI="/etc/sudoers.d/lx-fampad"              # für Tests ersetzbar
UMZUG_PFAD="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HIER="$(cd "$(dirname "$UMZUG_PFAD")" 2>/dev/null && pwd || echo .)"
BOOTSTRAP_ORIG="$HIER/bootstrap-server.sh"            # die Datei, die du kopiert hast
BOOTSTRAP="$BOOTSTRAP_ORIG"                           # die Datei, die tatsächlich läuft (nach dem Start: die geprüfte Kopie im Arbeitsverzeichnis)

# --- Zustand des Laufs --------------------------------------------------------------------------------------------------------------
OPT_PROBE=0; OPT_WEITER=""; OPT_IP=""; OPT_PARAMS=""; OPT_NEU=0; OPT_AKTUALISIEREN=0; OPT_SWAP_OK=0; OPT_OHNE_SYSTEMD=0; OPT_DNS_SKIP=0
AGE_ID=""                                  # privater Schlüssel: nur hier im Arbeitsspeicher
PARAMS_PFAD=""                             # Parameterdatei für bootstrap-server.sh (im Probelauf im Arbeitsverzeichnis)
ARBEIT_DIR=""                              # root-eigenes Arbeitsverzeichnis (/run, 0700): Kopie von bootstrap-server.sh, Exit-Code-Datei
DB_ARCHIV=""; CFG_ARCHIV=""                # Archive der gewählten Sicherung
IP_V4=""; IP_V6=""                         # Adressen dieses Servers
RAM_MB=0
FATAL=0                                    # Zähler der nicht behebbaren Befunde in Schritt 1
FEHLENDE_PAKETE=()                         # kleine Werkzeuge, die Schritt 1 nachinstalliert
SSH_KEY_RE=""                              # Muster für öffentliche SSH-Schlüssel (aus bootstrap-server.sh)
NUR_ROOT_FEHLER=""                         # Befund von sicherung_rechte_pruefen: symlink|rechte
CFG_VERSION=""                             # App-Version aus dem Update-Kanal der Sicherung (Vorschlag für den Code-Stand)
KANDIDATEN=(); PLAN=(); BA=(); PROBLEME=(); LISTE=()
HINWEISE=()                                # OFFEN-Meldungen von bootstrap-server.sh
PAUSE_KEY=""; CADDY_JETZT=0; DAUER_LETZT="0:00"
LETZTE_PHASE="-"; LETZTER_FEHLER=""; ALTE_DB_NEU=""
GIT_REF_VORHER=""                          # Code-Stand vor einem "--neu" (ein anderer setzt den Aufbau ab "code" zurück)
KONFIG_GLEICH=0; KONFIG_ABW=()             # --aktualisieren: gleicher AUTH_SECRET_KEY wie in der Sicherung? Abweichende (nicht geheime) Schalter der env
SCH_GELESEN=0; SCH_W=""; SCH_M=""; SCH_ML=""; SCH_URL=""   # Schalter aus einer env (Wetter, Müll, Müll-Link, PUBLIC_URL), siehe schalter_lesen
STTY_SAVE=""                               # Terminal-Einstellungen vor dem unsichtbaren Einlesen
# Antworten (A_*): nur Nicht-Geheimes
A_SICHERUNG=""; A_GIT_REF=""; A_SWAP_MB=""; A_IP=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""; A_PARAMS=""
A_WETTER=""; A_MUELL=""; A_MUELL_LINK=""; A_KEEP=""; A_APK=""; A_FILES=""; A_ALTE_DB=""
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
# Steuerzeichen, Escape-Folgen und unsichtbare Richtungs-/Format-Zeichen (U+202A-202E, U+2066-2069, U+200B-200F, U+2028/2029, U+FEFF) entfernen (Texte aus Archiven und Programmen)
sauber() {
  local s="${1//[[:cntrl:]]/}" c
  for c in $'‪' $'‫' $'‬' $'‭' $'‮' $'⁦' $'⁧' $'⁨' $'⁩' $'​' $'‌' $'‍' $'‎' $'‏' $' ' $' ' $'﻿'; do s="${s//$c/}"; done
  printf '%s' "$s"
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
# Der Schlüssel verschwindet auf jedem Weg aus dem Arbeitsspeicher; die Wegwerf-Dateien und das Terminal werden zurückgesetzt.
terminal_zuruecksetzen() { if [ -n "$STTY_SAVE" ]; then stty "$STTY_SAVE" 2>/dev/null || true; fi; }
aufraeumen() {
  local rc=$?
  trap - EXIT
  AGE_ID=""; unset AGE_ID
  terminal_zuruecksetzen
  if [ -n "$ARBEIT_DIR" ]; then rm -rf -- "$ARBEIT_DIR"; fi
  exit "$rc"
}
unterbrochen() {
  terminal_zuruecksetzen
  echo
  zeile "Abgebrochen. Nichts geht verloren: Starte denselben Befehl noch einmal, Erledigtes wird übersprungen."
  exit 130
}
# Ein Satz mit der Ursache, ein Satz mit der Maßnahme; im echten Lauf zusätzlich der Bericht (ohne Geheimnisse)
fehler_ende() { # $1 Ursache, $2 Maßnahme, $3 Exit-Code (Standard 1)
  local code="${3:-1}" ursache
  ursache="$(sauber "$1")"
  echo >&2
  printf '%s✗ %s%s\n' "$C_R" "$ursache" "$C_RESET" >&2
  printf '  %s\n' "$2" >&2
  if [ "$OPT_PROBE" = 0 ] && [ "$(id -u)" = 0 ] && [ "$code" != 2 ]; then
    if bericht_schreiben "$ursache" "$2" 2>/dev/null; then printf '  Bericht (ohne Geheimnisse, aber mit Pfaden und Adressen): %s\n' "$BERICHT_DATEI" >&2; fi
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
# NAS-Adresse wie in einrichtung-backup.sh (ip_pruefen): Adresse oder Netz ohne gesetzte Hostbits, Präfix mindestens /16 (IPv4) bzw. /48 (IPv6),
# keine unspezifizierte, Multicast- oder reservierte Adresse, keine führenden Nullen. Die endgültige Prüfung macht einrichtung-backup.sh.
ipv4_netz_ok() {
  local ip="$1" p=32 o1 o2 o3 o4 n mask
  if [[ "$ip" == */* ]]; then p="${ip#*/}"; ip="${ip%/*}"; fi
  [[ "$p" =~ ^(0|[1-9][0-9]?)$ ]] || return 1
  [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"; o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
  [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ] || return 1
  [ "$o1" -ge 1 ] && [ "$o1" -le 223 ] || return 1                       # nicht 0.x (unspezifiziert), nicht Multicast/reserviert (ab 224)
  [ "$p" -ge 16 ] && [ "$p" -le 32 ] || return 1
  n=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  [ $(( n & ~mask & 0xFFFFFFFF )) -eq 0 ]                                # Hostbits müssen 0 sein
}
G=()                                                                     # Gruppen (Dezimalzahlen) der zuletzt zerlegten IPv6-Adresse
ipv6_gruppen() { # $1 Adresse ohne Präfix -> G[0..7]; Rückgabe 1 bei Formfehler (nur Hex und ':', ein "::" höchstens, keine ":::")
  local ip="$1" links rechts g i n
  local -a l=() r=()
  G=()
  [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ "$ip" == *:::* ]] && return 1
  if [[ "$ip" == *::* ]]; then
    links="${ip%%::*}"; rechts="${ip#*::}"
    [[ "$rechts" == *::* ]] && return 1
    if [ -n "$links" ]; then IFS=':' read -ra l <<<"$links"; fi
    if [ -n "$rechts" ]; then IFS=':' read -ra r <<<"$rechts"; fi
    n=$(( ${#l[@]} + ${#r[@]} ))
    [ "$n" -le 7 ] || return 1
    for g in "${l[@]}"; do G+=("$g"); done
    for ((i = n; i < 8; i++)); do G+=(0); done
    for g in "${r[@]}"; do G+=("$g"); done
  else
    IFS=':' read -ra G <<<"$ip"
    [ "${#G[@]}" -eq 8 ] || return 1
  fi
  for i in 0 1 2 3 4 5 6 7; do
    [[ "${G[$i]}" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    G[i]=$(( 16#${G[$i]} ))
  done
  return 0
}
ipv6_netz_ok() { # wie ip_pruefen in einrichtung-backup.sh (python ipaddress, strict): Präfix >= 48, keine Hostbits, nicht unspezifiziert/Multicast/reserviert/IPv4-mapped/6to4/Teredo
  local ip="$1" p=128 i bits mask g0
  if [[ "$ip" == */* ]]; then p="${ip#*/}"; ip="${ip%/*}"; fi
  [[ "$p" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
  [ "$p" -ge 48 ] && [ "$p" -le 128 ] || return 1
  ipv6_gruppen "$ip" || return 1
  g0="${G[0]}"
  if [ $(( G[0] | G[1] | G[2] | G[3] | G[4] )) -eq 0 ] && [ "${G[5]}" -eq 65535 ]; then return 1; fi   # ::ffff:0:0/96 (auch voll ausgeschrieben)
  [ "$g0" -ne 8194 ] || return 1                                                                      # 2002::/16 (6to4)
  if [ "$g0" -eq 8193 ] && [ "${G[1]}" -eq 0 ]; then return 1; fi                                     # 2001::/32 (Teredo)
  # erlaubt bleiben nur die nicht reservierten Bereiche: 2000::/3, fc00::/7, fe80::/9 (alles andere ist reserviert, unspezifiziert oder Multicast)
  if ! { { [ "$g0" -ge 8192 ] && [ "$g0" -le 16383 ]; } || { [ "$g0" -ge 64512 ] && [ "$g0" -le 65023 ]; } || { [ "$g0" -ge 65152 ] && [ "$g0" -le 65279 ]; }; }; then return 1; fi
  for i in 0 1 2 3 4 5 6 7; do
    bits=$(( p - 16 * i )); [ "$bits" -ge 0 ] || bits=0; [ "$bits" -le 16 ] || bits=16
    mask=$(( (0xFFFF << (16 - bits)) & 0xFFFF ))
    [ $(( G[i] & ~mask & 0xFFFF )) -eq 0 ] || return 1                                                # Hostbits müssen 0 sein
  done
  return 0
}
gueltige_nas_ip() { # eine oder mehrere (Komma) Adressen oder Netze
  local teil teile=()
  [ -n "$1" ] || return 1
  IFS=',' read -ra teile <<<"$1"
  for teil in "${teile[@]}"; do
    if [[ "$teil" == *:* ]]; then ipv6_netz_ok "$teil" || return 1; else ipv4_netz_ok "$teil" || return 1; fi
  done
  return 0
}
gueltiger_ssh_schluessel() { [ -n "$SSH_KEY_RE" ] && [[ "$1" =~ $SSH_KEY_RE ]]; }
gueltiger_swap() { [[ "$1" =~ ^[0-9]+$ ]] && { [ "$1" -eq 0 ] || { [ "$1" -ge 256 ] && [ "$1" -le 8192 ]; }; }; }
liste_enthaelt() { [[ ",$1," == *",$2,"* ]]; } # $1 Kommaliste, $2 Wert

# --- Hilfen aus bootstrap-server.sh (ohne Doppelung): in einer Unterschale eingelesen, ändert nichts -------------------------------
aus_bootstrap() { # $@ Funktion und Argumente von bootstrap-server.sh
  # shellcheck disable=SC1090,SC2030,SC2031
  ( set +eE; export BOOTSTRAP_NUR_FUNKTIONEN=1; . "$BOOTSTRAP" >/dev/null 2>&1; set +eE; "$@" )
}
bootstrap_wert() { # $1 Name einer Variablen von bootstrap-server.sh
  # shellcheck disable=SC1090,SC2030,SC2031
  ( set +eE; export BOOTSTRAP_NUR_FUNKTIONEN=1; . "$BOOTSTRAP" >/dev/null 2>&1; set +eE; printf '%s' "${!1}" )
}
bootstrap_dns() { # $1 Host -> "ok" oder der Grund (wie bootstrap-server.sh ihn meldet)
  # shellcheck disable=SC1090,SC2030,SC2031
  ( set +eE; export BOOTSTRAP_NUR_FUNKTIONEN=1; . "$BOOTSTRAP" >/dev/null 2>&1; set +eE
    if dns_pruefen "$1"; then echo ok; else printf '%s\n' "${DNS_GRUND:-unbekannt}"; fi )
}
root_eigen() { # $1 Pfad: gehört root und ist für Gruppe und Andere nicht schreibbar
  [ "$(stat -c %u "$1" 2>/dev/null)" = 0 ] && [ $(( 8#$(stat -c %a "$1" 2>/dev/null || echo 777) & 8#022 )) -eq 0 ]
}
# bootstrap-server.sh läuft mehrfach als root: einmal beim Start in das Arbeitsverzeichnis kopieren (aus dem geprüften, geöffneten Deskriptor), dort noch
# einmal prüfen und NUR diese Kopie ausführen und einlesen. Ein späterer Austausch der Originaldatei greift nicht mehr.
bootstrap_pruefen() {
  local fd kopie="$ARBEIT_DIR/bootstrap-server.sh" f
  if [ ! -f "$BOOTSTRAP_ORIG" ] || [ -L "$BOOTSTRAP_ORIG" ]; then
    fehler_ende "bootstrap-server.sh fehlt neben diesem Skript ($HIER)." "Kopiere beide Dateien vom PC: scp deploy/neuinstallation/umzug.sh deploy/neuinstallation/bootstrap-server.sh root@<IP>:/root/" 2
  fi
  root_eigen "$UMZUG_PFAD" || fehler_ende "umzug.sh gehört nicht root oder ist für andere schreibbar." "Führe aus: chown root:root $UMZUG_PFAD && chmod 700 $UMZUG_PFAD"
  exec {fd}< "$BOOTSTRAP_ORIG"
  if [ "$(stat -L -c %u "/proc/self/fd/$fd")" != 0 ] || [ $(( 8#$(stat -L -c %a "/proc/self/fd/$fd") & 8#022 )) -ne 0 ]; then
    exec {fd}<&-
    fehler_ende "bootstrap-server.sh gehört nicht root oder ist für andere schreibbar." "Führe aus: chown root:root $BOOTSTRAP_ORIG && chmod 700 $BOOTSTRAP_ORIG"
  fi
  cat <&"$fd" > "$kopie"; exec {fd}<&-
  chmod 700 "$kopie"
  root_eigen "$kopie" || fehler_ende "Die Kopie von bootstrap-server.sh im Arbeitsverzeichnis ist nicht root-eigen." "Prüfe /run (Dateisystem) und starte neu."
  bash -n "$kopie" 2>/dev/null || fehler_ende "bootstrap-server.sh ist beschädigt (Syntaxfehler)." "Kopiere die Datei noch einmal vom PC und vergleiche die Prüfsumme (sha256sum)."
  BOOTSTRAP="$kopie"
  SSH_KEY_RE="$(bootstrap_wert SSH_KEY_RE)"
  [ -n "$SSH_KEY_RE" ] || fehler_ende "bootstrap-server.sh lässt sich nicht einlesen." "Kopiere es noch einmal vom PC (Prüfsumme vergleichen)."
  for f in dns_pruefen parameter_lesen parameter_pruefen; do
    aus_bootstrap declare -F "$f" >/dev/null 2>&1 || fehler_ende "bootstrap-server.sh hat die Funktion $f nicht mehr: umzug.sh und bootstrap-server.sh gehören nicht zum selben Stand." "Kopiere beide Dateien aus demselben Git-Stand (deploy/neuinstallation/) auf den Server."
  done
}

# --- Gemerkte Antworten (nur Nicht-Geheimes, root 0600; nie als Shell ausgeführt) --------------------------------------------------------
readonly ANTWORT_SCHLUESSEL=(SICHERUNG GIT_REF SWAP_MB IP NAS_IP NAS_PUBKEY LX_PUBKEY PARAMS WETTER MUELL MUELL_LINK KEEP APK FILES ALTE_DB FRAGEN FERTIG ERLEDIGT HINWEIS)
antwort_wert_ok() { # $1 Schlüssel, $2 Wert
  case "$1" in
    SICHERUNG|PARAMS) gueltiger_pfad "$2" ;;
    GIT_REF) gueltiger_tag "$2" ;;
    SWAP_MB) gueltiger_swap "$2" ;;
    IP) gueltige_ipv4 "$2" ;;
    NAS_IP) gueltige_nas_ip "$2" ;;
    NAS_PUBKEY|LX_PUBKEY) gueltiger_ssh_schluessel "$2" ;;
    WETTER|MUELL|MUELL_LINK|FRAGEN|APK|FILES) [[ "$2" =~ ^[01]$ ]] ;;
    KEEP) [[ "$2" =~ ^[1-9][0-9]?$ ]] ;;
    ALTE_DB) [[ "$2" =~ ^lx_fampad_vor_[0-9_]{8,20}(,lx_fampad_vor_[0-9_]{8,20})*$ ]] ;;   # kommagetrennt: jede Aktualisierung legt eine weitere an
    FERTIG|ERLEDIGT) [[ "$2" =~ ^[a-z,]*$ ]] ;;
    HINWEIS) [[ "$2" =~ ^[^[:cntrl:]]{1,600}$ ]] ;;
    *) return 1 ;;
  esac
}
antworten_zuruecksetzen() {
  A_SICHERUNG=""; A_GIT_REF=""; A_SWAP_MB=""; A_IP=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""; A_PARAMS=""
  A_WETTER=""; A_MUELL=""; A_MUELL_LINK=""; A_KEEP=""; A_APK=""; A_FILES=""; A_ALTE_DB=""; A_FRAGEN=""; A_FERTIG=""; A_ERLEDIGT=""
  HINWEISE=()
}
# --neu und "Damit weitermachen? nein": die Antworten verfallen, der Stand des Aufbaus (und was sich daraus ergibt) bleibt; sonst würde Schritt 1
# einen halb eingerichteten Server als "schon eingerichtet" ablehnen
antworten_neu_beginnen() {
  local f="$A_FERTIG" e="$A_ERLEDIGT" w="$A_WETTER" m="$A_MUELL" ml="$A_MUELL_LINK" ip="$A_IP" alt="$A_ALTE_DB" g="$A_GIT_REF" pa="$A_PARAMS" h=("${HINWEISE[@]}")
  antworten_zuruecksetzen
  A_FERTIG="$f"; A_ERLEDIGT="$e"; A_WETTER="$w"; A_MUELL="$m"; A_MUELL_LINK="$ml"; A_IP="$ip"; A_ALTE_DB="$alt"; A_PARAMS="$pa"; HINWEISE=("${h[@]}")
  GIT_REF_VORHER="$g"
}
fertig_ab_code_loeschen() { # ein anderer Code-Stand: code, anwendung und alles danach muss noch einmal laufen (konfiguration und datenbank bleiben)
  local p neu="" alt
  for p in ${A_FERTIG//,/ }; do liste_enthaelt "$NACH_CODE" "$p" || neu="${neu:+$neu,}$p"; done
  alt=",$A_ERLEDIGT,"; alt="${alt//,caddy,/,}"; alt="${alt#,}"; alt="${alt%,}"
  A_FERTIG="$neu"; A_ERLEDIGT="$alt"
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
  t="$(sauber "$1")"; t="${t:0:600}"
  [ -n "$t" ] || return 0
  for h in "${HINWEISE[@]}"; do [ "$h" = "$t" ] && return 0; done
  HINWEISE+=("$t")
}

# --- Optionale Parameterdatei (--params): nur öffentliche Werte, gleiche Regeln wie bei bootstrap-server.sh -----------------------------
readonly PARAM_SCHLUESSEL=" GIT_REPO_URL GIT_REF LX_SSH_PUBKEY CI_DEPLOY_PUBKEY WEATHER_ENABLED WEATHER_PLACE WEATHER_STATION_MAC WEATHER_BBOX RELEASE_CERT_SHA256 E2EE_PW_BACKUP AUTH_LEGACY_PASSWORD_LOGIN BACKUP_AGE_RECIPIENTS BACKUP_AGE_RECIPIENTS_CONFIG BACKUP_NAS_PUBKEY BACKUP_NAS_IP BACKUP_KEEP BACKUP_INCLUDE_APK BACKUP_INCLUDE_FILES SWAP_MB NODE_PKG_VERSION CADDY_PKG_VERSION "
extra_params_lesen() { # $1 Datei
  local d="$1" z key val n=0 pfd re_dq='^"(.*)"$' re_sq="^'(.*)'\$"
  if [ ! -f "$d" ] || [ -L "$d" ] || [ ! -r "$d" ]; then
    fehler_ende "Die Parameterdatei $d ist nicht lesbar oder ein Symlink." "Gib den Pfad einer normalen Datei an (--params DATEI)." 2
  fi
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
extra_params_einbinden() { # --params bzw. der gemerkte Pfad; nach dem Lesen der Antworten
  if [ -n "$OPT_PARAMS" ]; then A_PARAMS="$(readlink -f "$OPT_PARAMS" 2>/dev/null || echo "$OPT_PARAMS")"; fi
  [ -n "$A_PARAMS" ] || return 0
  if [ -f "$A_PARAMS" ]; then extra_params_lesen "$A_PARAMS"
  else
    hinweis "Die früher angegebene Parameterdatei $A_PARAMS gibt es nicht mehr: Werte wie BACKUP_AGE_RECIPIENTS, CI_DEPLOY_PUBKEY oder RELEASE_CERT_SHA256 daraus fehlen."
    if [ "$OPT_PROBE" = 0 ]; then
      frage_ja "Trotzdem ohne diese Datei weitermachen?" nein || fehler_ende "Die gemerkte Parameterdatei $A_PARAMS fehlt." "Lege sie wieder hin (eine leere Datei genügt, wenn du nichts daraus brauchst) oder starte mit --params DATEI."
    fi
  fi
}

# --- Schritt 1: Willkommen und Prüfung (ändert nichts) ---------------------------------------------------------------------------------
tcp_offen() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
swap_aktiv() { [ ! -r "$SWAPS_DATEI" ] || [ -n "$(awk 'NR > 1' "$SWAPS_DATEI")" ]; }
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
    elif [ "$OPT_PROBE" = 1 ]; then prueffeld hinweis "lx-fampad ist hier schon (teilweise) eingerichtet. Der Probelauf läuft trotzdem weiter und ändert nichts; für den Stand eines begonnenen Laufs: bash umzug.sh --weiter pruefung."
    else prueffeld fatal "Auf diesem Server ist lx-fampad schon (teilweise) eingerichtet, aber ohne gemerkte Antworten des Assistenten. Der Assistent ist für einen frischen Server: nimm einen neuen oder nutze bootstrap-server.sh direkt (docs/NEUINSTALLATION.md)."; fi
  else prueffeld ok "Es läuft noch nichts von lx-fampad auf diesem Server"; fi
}
pakete_installieren() {
  if ! { env DEBIAN_FRONTEND=noninteractive apt-get update -qq && env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 apt-get install -y -qq --no-install-recommends "$@"; } >>"$LAUF_LOG" 2>&1; then
    fehler_ende "Die Pakete $* ließen sich nicht installieren." "Prüfe die Verbindung zu den Debian-Paketquellen und starte noch einmal (Einzelheiten: $LAUF_LOG)."
  fi
  gut "Installiert: $*"
}
pruefsumme_kurz() { sha256sum "$1" 2>/dev/null | cut -c1-16; }
schritt1() {
  schritt_titel 1 "Willkommen und Prüfung"
  printf '%slx-fampad · Umzugs-Assistent%s   %sVersion %s%s\n' "$C_B" "$C_RESET" "$C_D" "$UMZUG_VERSION" "$C_RESET"
  printf 'Ich richte diesen Server für %s%s%s ein.\n' "$C_C" "$DOMAIN" "$C_RESET"
  blass "Prüfsummen der beiden Skripte (SHA-256, Anfang): umzug.sh $(pruefsumme_kurz "$UMZUG_PFAD"), bootstrap-server.sh $(pruefsumme_kurz "$BOOTSTRAP")"
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
      zeile "Ich installiere jetzt nur diese kleinen Debian-Pakete: ${FEHLENDE_PAKETE[*]}."
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
# Stehen die benutzten Archive in SHA256SUMS? (sha256sum -c prüft sonst nur, was dort eingetragen ist; wie bootstrap-server.sh)
sha_liste_vollstaendig() { # $1 Ordner
  local d="$1" f
  shopt -s nullglob
  for f in "$d"/db-*.dump.age "$d"/config-*.tar.age "$d"/files-*.tar.age; do
    awk -v n="$(basename "$f")" '$2 == n || $2 == "*" n { g = 1 } END { exit !g }' "$d/SHA256SUMS" || { shopt -u nullglob; return 1; }
  done
  shopt -u nullglob
  return 0
}
pruefsummen_ok() { # $1 Ordner
  sha_liste_vollstaendig "$1" && ( cd "$1" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1 )
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
  if pruefsummen_ok "$d"; then summen="Prüfsummen ok"; else summen="PRÜFSUMMEN FALSCH"; fi
  printf '%s%s, %s' "${stamp:+$stamp, }" "${groesse:-?}" "$summen"
}
sicherung_rechte_pruefen() { # $1 Ordner; Befund in NUR_ROOT_FEHLER (symlink|rechte)
  local d="$1"
  NUR_ROOT_FEHLER=""
  if [ -n "$(find "$d" -type l -print -quit 2>/dev/null)" ]; then NUR_ROOT_FEHLER="symlink"; return 1; fi
  if [ -n "$(find "$d" \( ! -user root -o -perm /022 \) -print -quit 2>/dev/null)" ]; then NUR_ROOT_FEHLER="rechte"; return 1; fi
  return 0
}
sicherung_uebernehmen() { # $1 Ordner; Rückgabe 0 = gewählt und geprüft (erst Rechte, dann Prüfsummen)
  local d f
  d="$(cd "$1" && pwd)"
  if ! sicherung_rechte_pruefen "$d"; then
    if [ "$NUR_ROOT_FEHLER" = symlink ]; then schlecht "In $d liegen Symlinks: das lehne ich ab (Verdacht auf Manipulation). Kopiere die Sicherung neu."; return 1; fi
    hinweis "$d gehört nicht root oder ist für andere schreibbar. bootstrap-server.sh verlangt: root-eigen, keine Schreibrechte für Gruppe und Andere."
    if [ "$OPT_PROBE" = 1 ]; then zeile "    Probelauf: im echten Lauf würde ich fragen, ob ich 'chown -R root:root' und 'chmod -R go-w' ausführen darf."
    elif frage_ja "    Soll ich das jetzt herstellen (chown -R root:root und chmod -R go-w auf diesen Ordner)?" ja; then
      if ! { chown -R root:root "$d" && chmod -R go-w "$d"; }; then schlecht "Das ging nicht."; return 1; fi
    else schlecht "Ohne diese Rechte bricht bootstrap-server.sh ab."; return 1; fi
  fi
  if ! sha_liste_vollstaendig "$d"; then
    schlecht "In SHA256SUMS fehlt ein Archiv dieser Sicherung (unvollständig oder verändert): nimm eine andere Sicherung."; return 1
  fi
  if ! pruefsummen_ok "$d"; then
    schlecht "Die Prüfsummen dieser Sicherung stimmen nicht (beschädigt oder unvollständig kopiert). Nimm eine ältere oder kopiere sie noch einmal."; return 1
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
# Liest aus der entschlüsselten Konfiguration nur Unbedenkliches (Schalter, Versionsnummer, Sicherungseinstellungen): die Zeilen werden gefiltert,
# bevor sie in eine Variable kommen; AUTH_SECRET_KEY, Passwörter und Links bleiben in der Pipe.
cfg_aus_archiv() { # $1 Pfad im Archiv; Klartext auf stdout
  age -d -i <(printf '%s\n' "$AGE_ID") -- "$CFG_ARCHIV" 2>/dev/null | tar -xzOf - "$1" 2>/dev/null
}
konfiguration_lesbar() { # 0 = das Konfigurationsarchiv lässt sich öffnen und enthält eine nichtleere etc/lx-fampad/env
  [ -n "$(cfg_aus_archiv etc/lx-fampad/env | head -c 1 || true)" ]
}
schluessel_noetig() { # 0, wenn noch eine Phase offen ist, die entschlüsselt
  local p
  for p in ${SCHLUESSEL_PHASEN//,/ }; do liste_enthaelt "$A_FERTIG" "$p" || return 0; done
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
    zeile "Einfügen (die Eingabe bleibt unsichtbar), dann Enter. Bei einer ganzen Schlüsseldatei: Strg+D. (Versuch $versuch von 3)"
    schluessel_einlesen || fehler_ende "Es wurde kein privater Schlüssel eingegeben." "Starte neu und füge den Schlüssel (AGE-SECRET-KEY-1…) aus deinem Passwortmanager ein."
    printf '%sPrüfe, ob der Schlüssel zur Sicherung passt …%s\n' "$C_Y" "$C_RESET"
    if schluessel_passt; then
      if ! konfiguration_lesbar; then
        fehler_ende "Der Schlüssel passt zur Datenbank, aber das Konfigurationsarchiv lässt sich nicht öffnen oder enthält keine etc/lx-fampad/env (mit AUTH_SECRET_KEY)." "Die Konfiguration kann für andere Schlüssel verschlüsselt sein (BACKUP_AGE_RECIPIENTS_CONFIG): nimm den Haupt- oder Ersatzschlüssel oder eine andere Sicherung. Nichts wurde verändert."
      fi
      gut "Der Schlüssel passt (Datenbank und Konfiguration lassen sich öffnen)."; return 0
    fi
    AGE_ID=""
    schlecht "Dieser Schlüssel passt nicht zu dieser Sicherung. Nichts wurde verändert."
  done
  fehler_ende "Der Schlüssel passte dreimal nicht zur Sicherung." "Prüfe, ob es der Schlüssel zu GENAU dieser Sicherung ist (es gibt Haupt- und Ersatzschlüssel), und starte neu. Nichts wurde verändert."
}
# Schalter aus einer env (stdin; Archiv oder lokale Datei): nur Unbedenkliches (Wetter, Müll, ob ein Müll-Link da ist, PUBLIC_URL) -> SCH_*.
# Eine einzige Auswertung für die Sicherung (config_auswerten) und für diesen Server (nach --aktualisieren), damit Liste und Schalter nicht auseinanderlaufen.
schalter_lesen() {
  local zeile
  SCH_GELESEN=0; SCH_W=""; SCH_M=""; SCH_ML=""; SCH_URL=""
  while IFS= read -r zeile; do
    case "$zeile" in
      GELESEN=1) SCH_GELESEN=1 ;;
      WETTER=[01]) SCH_W="${zeile#WETTER=}" ;;
      MUELL=[01]) SCH_M="${zeile#MUELL=}" ;;
      MUELL_LINK=[01]) SCH_ML="${zeile#MUELL_LINK=}" ;;
      PUBLIC_URL=https://*) SCH_URL="${zeile#PUBLIC_URL=}" ;;
    esac
  done < <(awk '
    { sub(/\r$/, ""); n++ }
    /^WEATHER_ENABLED=/ { v = substr($0, 17); gsub(/["\047]/, "", v); w = (v == "true" || v == "1") ? 1 : 0 }
    /^WASTE_ENABLED=/ { v = substr($0, 15); gsub(/["\047]/, "", v); m = (v == "true" || v == "1") ? 1 : 0 }
    /^WASTE_ICS_URL=./ { l = 1 }
    /^PUBLIC_URL=/ { u = substr($0, 12); gsub(/["\047]/, "", u) }
    END { if (n > 0) { printf "GELESEN=1\nWETTER=%d\nMUELL=%d\nMUELL_LINK=%d\n", w + 0, m + 0, l + 0; if (u != "") print "PUBLIC_URL=" u } }' 2>/dev/null)
}
config_auswerten() { # $1 "ohne-flags": Wetter/Müll nicht setzen (--aktualisieren liest sie nach dem Lauf aus der env dieses Servers)
  local bc zeile url="" v
  schalter_lesen < <(cfg_aus_archiv etc/lx-fampad/env)
  if [ "${1:-}" != ohne-flags ] && [ "$SCH_GELESEN" = 1 ]; then A_WETTER="$SCH_W"; A_MUELL="$SCH_M"; A_MUELL_LINK="$SCH_ML"; fi   # nur setzen, wenn die env wirklich gelesen wurde
  url="$SCH_URL"
  if [ -n "$url" ] && [ "${url%/}" != "https://$DOMAIN" ]; then
    url="${url:0:80}"; url="${url//[^A-Za-z0-9:\/._-]/?}"
    fehler_ende "Diese Sicherung gehört zu '$url', nicht zu https://$DOMAIN." "Die Domain darf sich nie ändern (Passkeys): nimm die Sicherung des richtigen Servers."
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
  if ! schluessel_noetig; then
    gut "Alle Phasen, die die Sicherung brauchen, sind erledigt: ich brauche weder den Sicherungsordner noch deinen Schlüssel mehr."
    return 0
  fi
  zeile "Zuerst die Sicherung (Frage 1), dann dein Schlüssel. Ihn brauche ich früh: Manches, was ich dir gleich vorschlage (Code-Stand, Wetter, Müll),"
  zeile "steht nur in der verschlüsselten Konfiguration der Sicherung."
  frage_sicherung
  frage_schluessel
  if [ -n "$AGE_ID" ]; then config_auswerten; fi
}

# --- Schritt 3: die übrigen Fragen -----------------------------------------------------------------------------------------------
lx_fehlt() { ! id "$LX_USER" >/dev/null 2>&1; }
frage_code_stand() { # Frage 2
  local vorschlag="" eingabe
  echo
  fett "Frage 2: Welcher Code-Stand?"
  if [ -n "$A_GIT_REF" ]; then vorschlag="$A_GIT_REF"; elif [ -n "$CFG_VERSION" ]; then vorschlag="v$CFG_VERSION"; fi
  if [ -n "$CFG_VERSION" ]; then
    printf 'Die Sicherung enthält den Update-Kanal der App-Version %s%s%s.\n' "$C_C" "$CFG_VERSION" "$C_RESET"
    zeile "Das ist die Version der letzten APK, nicht unbedingt die des Servers: lief dort ein neuerer Stand, nimm diesen (auf dem alten Server: cd ~/lx-fampad && git describe --tags)."
  fi
  zeile "Die Datenbank darf nicht neuer sein als der Code (sonst scheitert der Bau bei den Migrationen). Beispiel: v0.9.0"
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
    if ! gueltige_nas_ip "$ANTWORT"; then zeile "  Das ist keine zulässige Adresse (Beispiel: 203.0.113.7; Netze höchstens /16 bzw. /48, keine Hostbits, keine Multicast-Adresse)."; continue; fi
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
code_stand_wechsel_pruefen() { # ein anderer Code-Stand als zuvor: den Aufbau ab "code" noch einmal laufen lassen
  local alt="$1"
  if [ -n "$alt" ] && [ "$A_GIT_REF" != "$alt" ] && { liste_enthaelt "$A_FERTIG" code || liste_enthaelt "$A_FERTIG" anwendung; }; then
    fertig_ab_code_loeschen
    hinweis "Neuer Code-Stand ($alt -> $A_GIT_REF): Code, Server-Bau und alles danach laufen noch einmal; Konfiguration und Datenbank bleiben."
  fi
}
schritt3() {
  local gesamt=4 vorher
  schritt_titel 3 "Fragen"
  if [ "$A_FRAGEN" = 1 ] && [ -n "$A_GIT_REF" ] && [ -n "$A_SWAP_MB" ]; then
    gut "Die übrigen Fragen sind schon beantwortet (Code-Stand ${A_GIT_REF}, Swap ${A_SWAP_MB} MB)."
    if frage_ja "Code-Stand ändern (zum Beispiel, weil der Bau bei den Migrationen scheiterte)?" nein; then
      vorher="$A_GIT_REF"; A_GIT_REF=""
      frage_code_stand
      code_stand_wechsel_pruefen "$vorher"
      antworten_schreiben
    fi
    return 0
  fi
  if lx_fehlt; then gesamt=5; fi
  zeile "Es sind noch ${gesamt} Fragen (Frage 1 war die Sicherung). Alles in [Klammern] bestätigst du mit Enter."
  frage_code_stand
  frage_nas
  frage_swap
  if lx_fehlt; then frage_lx_schluessel; fi
  A_FRAGEN=1
  code_stand_wechsel_pruefen "$GIT_REF_VORHER"
  antworten_schreiben
}

# --- Schritt 4: Zusammenfassung (hier endet der Teil ohne Änderungen) -----------------------------------------------------------------
dns_ok() { # $1 Host
  [ "$OPT_DNS_SKIP" = 1 ] && return 0
  [ "$(bootstrap_dns "$1")" = ok ]
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
# --swap-ok an bootstrap-server.sh: bei der Option, oder wenn Swap läuft und kein Schlüssel mehr im Speicher/nötig ist (z. B. nach der Phase anwendung)
swap_ok_noetig() { [ "$OPT_SWAP_OK" = 1 ] || { swap_aktiv && ! schluessel_noetig && [ -z "$AGE_ID" ]; }; }
bootstrap_basis() { # BA = die gemeinsamen Argumente für bootstrap-server.sh
  BA=(--params "$PARAMS_PFAD" --lx-anlegen)
  if swap_ok_noetig; then BA+=(--swap-ok); fi
  if [ "$OPT_OHNE_SYSTEMD" = 1 ]; then BA+=(--ohne-systemd); fi
  if [ "$OPT_DNS_SKIP" = 1 ]; then BA+=(--dns-pruefung-ueberspringen); fi
  return 0
}
gegenprobe() { # bootstrap-server.sh --dry-run: prüft Parameter, Sicherung und Rechte, ohne etwas zu ändern; Befunde in PROBLEME
  local aus rc z
  PROBLEME=()
  bootstrap_basis
  if schluessel_noetig; then
    aus="$(bash "$BOOTSTRAP" --dry-run "${BA[@]}" --sicherung "$A_SICHERUNG" --identity-stdin </dev/null 2>&1 8>&-)"; rc=$?
  else
    aus="$(bash "$BOOTSTRAP" --dry-run "${BA[@]}" </dev/null 2>&1 8>&-)"; rc=$?
  fi
  while IFS= read -r z; do
    case "$z" in *"PROBLEM:"*) PROBLEME+=("$(sauber "$(sed -E 's/^[[:space:]]*PROBLEM:[[:space:]]*//' <<<"$z")")") ;; esac
  done <<<"$aus"
  if [ "$rc" -ne 0 ] && [ "${#PROBLEME[@]}" -eq 0 ]; then
    z="$(grep -E '^(FEHLER|Parameterdatei|--)' <<<"$aus" | head -n 1 || true)"
    PROBLEME+=("$(sauber "${z:-bootstrap-server.sh --dry-run meldet einen Fehler (Code $rc)}")")
  fi
  return 0
}
lx_noch_ohne_schluessel() { lx_fehlt && [ -z "$A_LX_PUBKEY" ]; }
schritt4() {
  local n=0 p extra
  schritt_titel 4 "Zusammenfassung"
  plan_bauen
  if [ "$OPT_PROBE" = 1 ]; then PARAMS_PFAD="$ARBEIT_DIR/umzug.params"; else PARAMS_PFAD="$PARAMS_ERZEUGT"; fi
  params_schreiben "$PARAMS_PFAD" || fehler_ende "Die Parameterdatei $PARAMS_PFAD ließ sich nicht schreiben." "Prüfe den freien Platz und die Rechte von /root."
  printf '%sDas passiert jetzt%s   %s(dauert etwa 20 Minuten)%s\n\n' "$C_B" "$C_RESET" "$C_D" "$C_RESET"
  printf '  Sicherung:    %s%s\n' "$(basename "${A_SICHERUNG:-?}")" "${CFG_VERSION:+, App-Version $CFG_VERSION}"
  printf '  Domain:       %s\n' "$DOMAIN"
  printf '  IP:           %s\n' "${A_IP:-?}"
  printf '  Code-Stand:   %s   %s(den Commit zeigt die Phase "Code von GitHub holen")%s\n' "$A_GIT_REF" "$C_D" "$C_RESET"
  if [ "$A_SWAP_MB" = 0 ]; then printf '  Swap:         keiner\n'; else printf '  Swap:         %s MB (nach dem Verwerfen deines Schlüssels)\n' "$A_SWAP_MB"; fi
  if [ -n "$A_NAS_IP" ]; then printf '  NAS-Abholung: von %s\n' "$A_NAS_IP"
  else printf '  NAS-Abholung: %snicht eingerichtet%s (die tägliche Sicherung folgt erst mit den NAS-Daten)\n' "$C_Y" "$C_RESET"; fi
  if lx_fehlt; then printf '  Benutzer lx:  wird angelegt, %s\n' "$([ -n "$A_LX_PUBKEY" ] && echo "mit deinem SSH-Schlüssel" || echo "ohne SSH-Schlüssel")"; fi
  if [ -n "$A_KEEP$A_APK$A_FILES" ]; then printf '  Sicherung:    Einstellungen wie auf dem alten Server (behalte %s, APK %s, Dateiablage %s)\n' "${A_KEEP:-Standard}" "${A_APK:-Standard}" "${A_FILES:-Standard}"; fi
  if [ -n "$A_PARAMS" ]; then printf '  Parameterdatei: %s (Werte daraus gehen mit)\n' "$A_PARAMS"; fi
  echo
  zeile "  Ich werde:"
  for p in "${PLAN[@]}"; do
    n=$((n + 1)); extra=""
    if [ "$p" = code ]; then extra="   ${C_Y}(Pause: du trägst einen Schlüssel bei GitHub ein)${C_RESET}"; fi
    printf '   %s%d%s %s%s\n' "$C_C" "$n" "$C_RESET" "${PHASEN_NAME[$p]}" "$extra"
  done
  if [ "$CADDY_JETZT" = 0 ]; then printf '   %s·%s %s: später, nach deiner DNS-Umstellung (bash %s --weiter caddy)\n' "$C_D" "$C_RESET" "${PHASEN_NAME[caddy]}" "$UMZUG_PFAD"; fi
  if [ "${#PLAN[@]}" -eq 0 ]; then zeile "   (nichts mehr: alle Phasen sind schon erledigt)"; fi
  echo
  printf '  %sNichts%s wird gelöscht. Dein alter Server bleibt unberührt.\n' "$C_G" "$C_RESET"
  zeile "  Das Haupt-Caddyfile von lx-labs.dev wird nie überschrieben: bootstrap-server.sh legt es nur an, wenn es fehlt oder noch das unveränderte Standard-Caddyfile ist"
  zeile "  (eine Kopie bleibt); ein fremdes Caddyfile bleibt unangetastet, sonst ändert es nur conf.d (mit Rückfall)."
  echo
  zeile "Gegenprobe (bootstrap-server.sh --dry-run, ändert nichts) …"
  gegenprobe
  if [ "${#PROBLEME[@]}" -gt 0 ]; then
    for p in "${PROBLEME[@]}"; do schlecht "$p"; done
    if [ "$OPT_PROBE" = 1 ]; then hinweis "Im echten Lauf würde der Assistent hier stoppen."
    else fehler_ende "Die Gegenprobe meldet ${#PROBLEME[@]} Problem(e)." "Behebe sie (siehe oben) und starte denselben Befehl noch einmal; am Server wurde nichts verändert."; fi
  else gut "Gegenprobe ohne Befund (Parameter, Prüfsummen, Rechte)."; fi
}
bestaetigen() { # Rückgabe 0 = starten, 1 = Probelauf (Ende)
  local k
  echo
  if [ "$OPT_PROBE" = 1 ]; then
    printf '%sProbelauf beendet. Es wurde nichts verändert.%s Für den echten Lauf: bash %s\n' "$C_G" "$C_RESET" "$UMZUG_PFAD"
    return 1
  fi
  [ "${#PLAN[@]}" -gt 0 ] || return 0
  printf '%sJetzt starten?%s Tippe %sumziehen%s zur Bestätigung (alles andere bricht ab): ' "$C_B" "$C_RESET" "$C_C" "$C_RESET" >&2
  if ! IFS= read -r k; then echo >&2; abbruch_eingabe; fi
  if [ "$(trimmen "${k%$'\r'}")" != umziehen ]; then
    zeile "Abgebrochen, es wurde am Server nichts verändert. Deine Antworten sind gemerkt: starte denselben Befehl, wenn du bereit bist."
    exit 0
  fi
  return 0
}

# --- Schritt 5: Aufbau ---------------------------------------------------------------------------------------------------------------
scrub() { sed -E 's/AGE-SECRET-KEY-1[0-9A-Z]+/[entfernt]/g; s/tk_[A-Za-z0-9]+/tk_[entfernt]/g; s#(://[^:/@ ]+:)[^@ ]+@#\1[entfernt]@#g'; }
bericht_schreiben() { # $1 Ursache, $2 Maßnahme
  local tmp="$BERICHT_DATEI.neu.$$"
  {
    echo "lx-fampad Umzugs-Assistent: Fehlerbericht (ohne Schlüssel, Passwörter, Links und Programmausgaben; ABER mit Pfaden, IP-Adressen und dem Namen deiner Sicherung: nur gezielt weitergeben)"
    echo "Zeit (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "Phase: $(sauber "$LETZTE_PHASE")"
    echo "Ursache: $(sauber "$1" | scrub)"
    echo "Maßnahme: $(sauber "$2" | scrub)"
    echo "System: $(sed -nE 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'), Arbeitsspeicher ${RAM_MB} MB"
    echo
    echo "Gemerkte Antworten:"
    antworten_text | grep -v '^HINWEIS=' | scrub | sed 's/^/  /'
    echo
    echo "Letzte Meldungen von bootstrap-server.sh (nur seine eigenen Meldungen):"
    if [ -f "$LAUF_LOG" ]; then grep -E '^(==>|!!|FEHLER|PAUSE|    (Prüfpunkt|PROBLEM|WARNUNG|OFFEN))' "$LAUF_LOG" | tail -n 60 | scrub | sed 's/^/  /'; fi
  } > "$tmp" 2>/dev/null && chmod 600 "$tmp" && mv -f "$tmp" "$BERICHT_DATEI"
}
fehlermassnahme() { # $1 letzte FEHLER-Zeile von bootstrap-server.sh -> Maßnahme in einem Satz (die Muster stehen in bootstrap-server.sh, test-umzug.sh prüft das)
  case "$1" in
    *"Swap aktiv"*|*"Swap ist aktiv"*) echo "Führe 'swapoff -a' aus und starte denselben Befehl noch einmal (oder bewusst mit --swap-ok)." ;;
    *"nicht lesen oder ist kein pg_dump"*) echo "Der Schlüssel passt nicht zu dieser Sicherung: starte neu und gib den richtigen Schlüssel ein." ;;
    *"Prüfsummen stimmen nicht"*) echo "Die Sicherung ist beschädigt: kopiere sie noch einmal oder nimm eine ältere vom NAS." ;;
    *"muss root gehören"*) echo "Führe 'chown -R root:root' und 'chmod -R go-w' auf den Sicherungsordner aus und starte neu." ;;
    *"PUBLIC_URL der Sicherung"*) echo "Die Sicherung gehört zu einer anderen Domain: nimm die Sicherung des Servers von $DOMAIN." ;;
    *"deploy.sh fehlgeschlagen"*) echo "Der Code-Stand passt vermutlich nicht zur Datenbank: starte denselben Befehl und antworte bei \"Code-Stand ändern?\" mit ja (neuerer Tag); Einzelheiten: journalctl -u lx-fampad-migrate -n 50." ;;
    *"GIT_REF"*) echo "Der Tag wurde nicht gefunden: starte denselben Befehl und antworte bei \"Code-Stand ändern?\" mit ja (Tags auf deinem PC: git tag)." ;;
    *"weicht von der Sicherung ab"*) echo "Auf diesem Server liegt schon eine andere Konfiguration: nimm einen frischen Server." ;;
    *"Caddy"*|*"antwortet nicht"*|*"Zertifikat"*) echo "Prüfe die DNS-Einträge (dig +short $DOMAIN), warte mindestens eine Stunde (Grenzen von Let's Encrypt) und starte '$UMZUG_PFAD --weiter caddy' erneut." ;;
    *) echo "Behebe die Ursache laut Meldung (Einzelheiten: $LAUF_LOG) und starte denselben Befehl noch einmal: Erledigtes wird übersprungen." ;;
  esac
}
# bootstrap-server.sh mit BA ausführen und den Fortschritt zeigen. bootstrap-server.sh läuft in einem eigenen Prozess, seine Ausgabe kommt über eine Pipe
# (Dateideskriptor 7); sein Exit-Code geht über eine Datei im Arbeitsverzeichnis (nicht über die Ausgabe: Hintergrunddienste könnten die Pipe offen halten).
# Rückgabe: Exit-Code von bootstrap-server.sh. Der Schlüssel geht nur in seine stdin-Pipe.
lauf_ausfuehren() { # $1 Anzeigename, $2 Nummer-Text, $3 mit Schlüssel (1|0); Argumente in BA
  local name="$1" nr="$2" mitkey="$3" rcdatei="$ARBEIT_DIR/rc" start=$SECONDS rc="" z="" teil="" lesen stille=0 ausgabe
  PAUSE_KEY=""; LETZTER_FEHLER=""; ALTE_DB_NEU=""
  if [ "$mitkey" = 1 ] && [ -z "$AGE_ID" ]; then fehler_ende "Der Schlüssel ist nicht mehr im Speicher, wird aber für \"$name\" gebraucht." "Starte denselben Befehl noch einmal: ich frage den Schlüssel erneut ab."; fi
  printf '%s▶%s %-5s %s\n' "$C_Y" "$C_RESET" "$nr" "$name"
  echo "=== $(date -u '+%F %T') UTC  $name" >> "$LAUF_LOG"
  rm -f "$rcdatei"
  if [ "$mitkey" = 1 ]; then
    exec 7< <( bash "$BOOTSTRAP" "${BA[@]}" < <(printf '%s\n' "$AGE_ID") 2>&1 8>&-; echo "$?" > "$rcdatei" )
  else
    exec 7< <( bash "$BOOTSTRAP" "${BA[@]}" < /dev/null 2>&1 8>&-; echo "$?" > "$rcdatei" )
  fi
  while true; do
    IFS= read -r -t 1 -u 7 z; lesen=$?
    if [ "$lesen" -gt 128 ]; then
      teil="$teil$z"
      if [ -s "$rcdatei" ]; then break; fi        # bootstrap-server.sh ist fertig und die Pipe ist leer
      stille=$((stille + 1))
      if [ -t 1 ] && [ $((stille % 20)) -eq 0 ]; then printf '    %s… läuft seit %s%s\n' "$C_D" "$(dauer $((SECONDS - start)))" "$C_RESET"; fi
      continue
    fi
    [ "$lesen" -eq 0 ] || break
    z="$teil$z"; teil=""
    z="$(sauber "$z")"
    printf '%s\n' "$z" >> "$LAUF_LOG"
    case "$z" in
      "    OFFEN: "*) hinweis_merken "${z#    OFFEN: }" ;;
      "    WARNUNG: "*) printf '    %s! %s%s\n' "$C_Y" "${z#    WARNUNG: }" "$C_RESET" ;;
      "FEHLER: "*) printf '    %s%s%s\n' "$C_R" "$z" "$C_RESET"; LETZTER_FEHLER="${z#FEHLER: }" ;;
      "!!  "*) printf '    %s%s%s\n' "$C_R" "$z" "$C_RESET" ;;
      *"CODE-STAND DIESES LAUFS"*) printf '    %s\n' "$(sed -E 's/^[[:space:]]*==> //' <<<"$z")" ;;
      *"Bisherige Datenbank umbenannt in "*) if [[ "$z" =~ umbenannt\ in\ (lx_fampad_vor_[0-9_]+) ]]; then ALTE_DB_NEU="${BASH_REMATCH[1]}"; fi ;;
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) if [[ "$z" =~ $SSH_KEY_RE ]]; then PAUSE_KEY="$z"; fi ;;
    esac
  done
  exec 7<&-
  ausgabe=0
  for lesen in 1 2 3 4 5; do if [ -s "$rcdatei" ]; then ausgabe=1; break; fi; sleep 0.2; done
  if [ "$ausgabe" = 1 ]; then rc="$(head -n 1 "$rcdatei")"; fi
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  DAUER_LETZT="$(dauer $((SECONDS - start)))"
  return "$rc"
}
phase_meldung_ok() { printf '%s✓%s %-5s %-36s %s%s%s\n' "$C_G" "$C_RESET" "$1" "$2" "$C_D" "$DAUER_LETZT" "$C_RESET"; }
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
      zeile "Pausiert. Trage den Schlüssel bei GitHub ein und starte danach denselben Befehl noch einmal (bash $UMZUG_PFAD): Erledigtes wird übersprungen."
      zeile "Dein privater Schlüssel wird dann noch einmal abgefragt (er wird nie gespeichert)."
      exit 10
    fi
    printf '%s✗%s %-5s %s\n' "$C_R" "$C_RESET" "$nr" "${PHASEN_NAME[$p]}" >&2
    fehler_ende "Die Phase \"${PHASEN_NAME[$p]}\" ist fehlgeschlagen${LETZTER_FEHLER:+: $LETZTER_FEHLER}." "$(fehlermassnahme "$LETZTER_FEHLER")"
  done
}
schluessel_verwerfen() { AGE_ID=""; unset AGE_ID; AGE_ID=""; }
schritt5() {
  local p
  schritt_titel 5 "Aufbau"
  : >> "$LAUF_LOG"; chmod 600 "$LAUF_LOG" 2>/dev/null || true
  antworten_schreiben
  for p in "${PLAN[@]}"; do
    aufbau_phase "$p"
    # nach der letzten Entschlüsselung (Ende der Phase datenbank) verschwindet der Schlüssel aus dem Arbeitsspeicher
    if [ "$p" = datenbank ] && [ -n "$AGE_ID" ]; then
      schluessel_verwerfen
      blass "    Schlüssel aus dem Arbeitsspeicher des Assistenten entfernt (alle Entschlüsselungen sind erledigt)."
    fi
    if [ "$p" = caddy ]; then erledigt_markieren caddy; fi
  done
  schluessel_verwerfen
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
erl() { if liste_enthaelt "$A_ERLEDIGT" "$1"; then printf '   -> erledigt'; fi; return 0; }
l() { LISTE+=("$*"); }
liste_bauen() { # füllt LISTE (reiner Text; Überschriften beginnen mit "[n] ")
  local n=0 ip="${A_IP:-<IP>}" fp h hinweisliste=() u="bash $UMZUG_PFAD" dns_nr
  LISTE=()
  fp="$(host_fingerabdruck)"
  l "Jetzt bist du dran. Reihenfolge einhalten:"
  l ""
  n=$((n + 1)); l "[$n] Läuft der ALTE Server noch und hat sich seit der Sicherung etwas geändert? Dann zuerst Schreibstopp und frische Sicherung"
  l "      alt:   sudo systemctl stop lx-fampad lx-fampad-weather"
  l "      alt:   sudo systemctl start lx-fampad-backup.service      (neue Sicherung: /var/backups/lx-fampad/<neuester Ordner>, oder vom NAS holen)"
  l "      Ordner nach $ip kopieren:  scp -r <Ordner> root@$ip:/root/sicherung/"
  l "      hier:  $u --aktualisieren$(erl aktualisieren)      (fragt Sicherung, Schlüssel und das Wort \"ersetzen\"; die bisherige Datenbank bleibt umbenannt erhalten)"
  l "      Hat sich nichts geändert (oder ist der alte Server schon aus), überspringst du [$n]."
  l ""
  n=$((n + 1)); dns_nr="$n"; l "[$n] DNS bei Cloudflare umstellen  (graue Wolke, \"DNS only\")"
  l "      familie        A   $ip"
  l "      ntfy.familie   A   $ip"
  if [ -n "$IP_V6" ]; then l "      Gibt es einen AAAA-Eintrag: auf $IP_V6 umstellen oder löschen (sonst zeigt er noch zum alten Server)."
  else l "      Einen vorhandenen AAAA-Eintrag löschen (dieser Server hat keine globale IPv6-Adresse)."; fi
  l "    Kontrolle:  dig +short $DOMAIN   (muss $ip zeigen; unter Windows: nslookup $DOMAIN 1.1.1.1)"
  n=$((n + 1)); l "[$n] Caddy und Zertifikate holen  (erst nach [$dns_nr]!)$(erl caddy)"
  l "      $u --weiter caddy"
  n=$((n + 1)); l "[$n] Web-App hochladen  (auf deinem PC, im Git-Checkout von lx-fampad)"
  if lx_hat_schluessel; then l "      SSH_HOST=lx@$ip deploy/deploy-web.sh"
  else l "      Auf diesem Server hat lx noch keinen SSH-Schlüssel: trage deinen öffentlichen Schlüssel in /home/lx/.ssh/authorized_keys ein, dann: SSH_HOST=lx@$ip deploy/deploy-web.sh"; fi
  n=$((n + 1)); l "[$n] Prüfen, ob alles stimmt  (nach Caddy und Web-App)"
  l "      Anmeldung mit Passkey und mit TOTP (das beweist AUTH_SECRET_KEY), Listen und Kalender sichtbar, Push-Test, App-Update-Prüfung."
  l "      Gelöschte Daten (Löschwünsche nach DSGVO) sind seit der Sicherung wieder da und müssen erneut gelöscht werden."
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
  n=$((n + 1)); l "[$n] NAS-Rückmeldung neu einrichten  (\"Status vom NAS\" für Betrieb; nur wenn du sie nutzt: sie steht in keiner Sicherung und fehlt nach dem Umzug still)$(erl nasstatus)"
  l "      Der Server hat keine Zugangsdaten zum NAS, darum braucht er den ÖFFENTLICHEN zweiten Schlüssel des NAS: auf dem NAS  cat ~/.ssh/lx-fampad-status.pub"
  l "      (Zeile mit lx-fampad-status; gibt es ihn noch nicht: ssh-keygen -t ed25519 -N '' -C 'lx-fampad-status' -f ~/.ssh/lx-fampad-status, im selben .ssh wie der Schlüssel der Abholung)."
  l "      hier:  $u --weiter nasstatus      (fragt den öffentlichen Schlüssel und richtet es ein; nimmt die NAS-IP aus den Antworten)"
  l "      oder von Hand (als lx, nach git -C ~/lx-fampad status --short deploy):"
  l "        sudo bash ~/lx-fampad/deploy/backup/einrichtung-nasstatus.sh --dry-run --nas-pubkey '<öffentlicher zweiter Schlüssel lx-fampad-status vom NAS>' --nas-ip '${A_NAS_IP:-<NAS-IP>}'"
  l "        dann derselbe Aufruf ohne --dry-run; danach auf dem NAS lx-fampad-nasstatus.sh einmal von Hand (docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 11)."
  n=$((n + 1)); l "[$n] Alten Server endgültig stoppen  (falls noch nicht in [1] geschehen)"
  l "      alt:   sudo systemctl stop lx-fampad lx-fampad-weather"
  if [ "$A_WETTER" = 1 ]; then
    n=$((n + 1)); l "[$n] Wetter-Dienst hier starten  (erst wenn der alte Server aus ist: Netatmo erlaubt nur einen Abrufer)$(erl wetter)"
    l "      neu:   $u --weiter wetter"
    l "      Ist das gesicherte Token veraltet: sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/weather-setup.js"
  fi
  if [ "$A_MUELL" = 1 ]; then
    n=$((n + 1)); l "[$n] Müll-Dienst (Abfuhrtermine) hier starten  (nach dem Stopp des alten Servers)$(erl muell)"
    if [ "$A_MUELL_LINK" = 1 ]; then l "      Der Link des Abfallkalenders steht in der gesicherten Konfiguration und ist schon hier."
    else l "      Der Link des Abfallkalenders fehlt in der Sicherung: erst  sudo bash /home/$LX_USER/lx-fampad/deploy/einrichtung-muell.sh einstellungen  (der Link wird unsichtbar abgefragt)."; fi
    l "      neu:   $u --weiter muell      (ergänzt auch die sudo-Regel für den Neustart des Dienstes, deploy/README.md Abschnitt 13)"
  fi
  n=$((n + 1)); l "[$n] Wiederherstellungstest  (auf deinem PC, mit dem PRIVATEN Schlüssel)"
  l "      deploy/backup/wiederherstellung-test.sh --identity ~/lx-fampad-age.key --run-dir <vom NAS geholte NEUE Sicherung dieses Servers>"
  l "      (erst nach der ersten Nacht um 03:30; Anleitung: docs/BACKUP-EINRICHTUNG-SCHRITTE.md)"
  if [ -n "$A_ALTE_DB" ]; then
    n=$((n + 1)); l "[$n] Die bisherigen Datenbanken löschen  (enthalten Personendaten; erst nach der Prüfung; Übersicht: sudo -u postgres psql -l, Namen lx_fampad_vor_…)"
    for h in ${A_ALTE_DB//,/ }; do l "      sudo -u postgres psql -c \"DROP DATABASE $h\""; done
  fi
  l ""
  l "Danach, wenn du Zeit hast:"
  l "  - Firewall: nur 22, 80 und 443 offen (Anbieter-Firewall oder ufw); SSH nur mit Schlüssel."
  l "  - APK-Link: Kopie der neuesten APK als lx-familyhub-latest.apk in /srv/fampad/releases/android neu anlegen und latest.json prüfen (deploy/README.md Abschnitt 9)."
  l "  - Release-Upload per GitHub Actions: Secrets VPS_HOST ($ip) und VPS_KNOWN_HOSTS (ssh-keyscan -t ed25519 $ip; Fingerabdruck ${fp:-vergleichen}) in der Environment vps-deploy."
  l "  - Karte (1,1 GB) neu erzeugen und Fallback-Schriften nach /srv/fampad/font-fallback (deploy/README.md, Abschnitte 8 und 11)."
  l "  - TTL der DNS-Einträge wieder erhöhen; den alten Server erst nach mindestens einer Woche stabilem Betrieb abgeben (Datenträger bereinigen lassen)."
  l "  - Diese Liste später noch einmal ansehen oder neu schreiben lassen: $u --weiter pruefung   (geht auch ohne den Sicherungsordner)."
  for h in "${HINWEISE[@]}"; do
    case "$h" in
      "Die neue Sicherung ist UNGEPRÜFT"*|"DNS zeigt noch nicht"*|"NAS-Abholung nicht eingerichtet"*) ;;
      "Wetter-Dienst ist installiert"*) [ "$A_WETTER" = 1 ] || hinweisliste+=("$h") ;;
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

# --- --weiter und --aktualisieren: einzelne Folgeschritte -------------------------------------------------------------------------
weiter_vorbereiten() { # $1 "aufbau" (Standard): der Aufbau muss bis zur Datenbank gekommen sein; "fertig": bis zur Anwendung
  antworten_lesen || fehler_ende "Es gibt noch keinen Lauf des Assistenten auf diesem Server (keine gemerkten Antworten)." "Starte zuerst: bash $UMZUG_PFAD"
  liste_enthaelt "$A_FERTIG" datenbank || fehler_ende "Der Aufbau ist noch nicht bis zur Datenbank gekommen." "Starte zuerst den Aufbau: bash $UMZUG_PFAD (derselbe Befehl setzt dort fort)."
  if [ "${1:-aufbau}" = fertig ]; then
    liste_enthaelt "$A_FERTIG" anwendung || fehler_ende "Der Server ist noch nicht gebaut und gestartet (Phase \"Server bauen und starten\")." "Schließe zuerst den Aufbau ab: bash $UMZUG_PFAD"
  fi
  [ -f "$PARAMS_ERZEUGT" ] || fehler_ende "Die Parameterdatei $PARAMS_ERZEUGT fehlt." "Starte zuerst: bash $UMZUG_PFAD"
  PARAMS_PFAD="$PARAMS_ERZEUGT"
  ip_erkennen
  [ -n "$A_IP" ] || A_IP="$IP_V4"
  : >> "$LAUF_LOG"; chmod 600 "$LAUF_LOG" 2>/dev/null || true
}
# Die sudo-Regel für den Neustart des Müll-Dienstes (README Abschnitt 13, Schritt 2): bootstrap-server.sh schreibt /etc/sudoers.d/lx-fampad bei jedem
# Lauf der Phase anwendung neu (ohne diese Regel); darum nach jedem solchen Lauf wieder ergänzen
sudoers_muell_ergaenzen() {
  local f="$SUDOERS_DATEI" tmp="$ARBEIT_DIR/sudoers.neu"
  [ -f "$f" ] || { hinweis "$f fehlt: die sudo-Regel für den Müll-Dienst konnte nicht ergänzt werden."; return 1; }
  if grep -q 'restart lx-fampad-waste' "$f"; then return 0; fi
  command -v visudo >/dev/null || { hinweis "visudo fehlt: die sudo-Regel für den Müll-Dienst konnte nicht geprüft und ergänzt werden."; return 1; }
  awk -v zusatz=", /usr/bin/systemctl restart lx-fampad-waste" 'BEGIN { fertig = 0 } !fertig && /^lx ALL=\(root\) NOPASSWD:/ { print $0 zusatz; fertig = 1; next } { print } END { if (!fertig) exit 1 }' "$f" > "$tmp" \
    || { hinweis "$f hat nicht die erwartete Form: bitte die Regel von Hand ergänzen (deploy/README.md Abschnitt 13)."; return 1; }
  visudo -cf "$tmp" >/dev/null || { hinweis "Die ergänzte sudo-Regel ist ungültig und wird nicht übernommen."; return 1; }
  install -m 440 -o root -g root "$tmp" "$f"
  gut "sudo-Regel für den Neustart des Müll-Dienstes ergänzt."
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
  local h grund bad=0
  weiter_vorbereiten
  echo; fett "Caddy und Zertifikate"
  for h in "$DOMAIN" "$NTFY_DOMAIN"; do
    if [ "$OPT_DNS_SKIP" = 1 ]; then gut "DNS-Prüfung übersprungen (Testmodus): $h"; continue; fi
    grund="$(bootstrap_dns "$h")"
    if [ "$grund" = ok ]; then gut "DNS ok: $h zeigt auf diesen Server"
    else schlecht "DNS: $h $(sauber "$grund")."; bad=1; fi
  done
  if [ "$bad" = 1 ]; then
    fehler_ende "Der DNS-Eintrag zeigt noch nicht (nur) auf diesen Server; Caddy würde keine Zertifikate bekommen und Let's-Encrypt-Versuche verbrauchen." "Stelle die A-Einträge familie und ntfy.familie auf ${A_IP:-diesen Server} (DNS only), lösche oder ändere einen AAAA-Eintrag, warte, bis 'dig +short $DOMAIN' die Adresse zeigt, und wiederhole den Befehl."
  fi
  weiter_phasen "caddy,pruefung" "Caddy, Zertifikate und Abschlussprüfung"
  fertig_markieren caddy; fertig_markieren pruefung; erledigt_markieren caddy
  gut "https://$DOMAIN und https://$NTFY_DOMAIN antworten."
  weiter_liste
}
weiter_wetter() {
  weiter_vorbereiten fertig
  echo; fett "Wetter-Dienst starten"
  if [ "$A_WETTER" != 1 ]; then zeile "Das Wetter war auf dem alten Server nicht eingeschaltet: nichts zu tun."; return 0; fi
  zeile "Netatmo erlaubt nur EINEN Abrufer gleichzeitig (das Token wird bei jedem Abruf erneuert)."
  lies_zeile "Ist der alte Server aus (lx-fampad-weather gestoppt)? Tippe ja, um fortzufahren: "
  if [ "${ANTWORT,,}" != ja ]; then zeile "Gut, ich starte nichts. Stoppe zuerst den alten Server und wiederhole den Befehl."; return 0; fi
  weiter_phasen "anwendung" "Server neu bauen und Wetter-Dienst einschalten" "--wetter-starten"
  erledigt_markieren wetter
  if liste_enthaelt "$A_ERLEDIGT" muell; then sudoers_muell_ergaenzen; fi
  weiter_liste
}
# git als lx im Checkout, gehärtet: keine fsmonitor- und Hook-Programme aus der Konfiguration des Checkouts, HOME wie bei git_lx in bootstrap-server.sh
git_checkout() { # $1 Checkout, Rest: git-Argumente
  local co="$1" home; shift
  home="$(getent passwd "$LX_USER" | cut -d: -f6)"
  runuser -u "$LX_USER" -- env HOME="$home" GIT_TERMINAL_PROMPT=0 git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$co" "$@"
}
lx_checkout() { printf '%s/lx-fampad' "$(getent passwd "$LX_USER" | cut -d: -f6)"; }   # der Git-Checkout von lx (für Tests ersetzbar)
# Skripte aus dem Checkout von lx laufen als root (Müll-Dienst, NAS-Rückmeldung): nur wenn der Checkout unverändert auf dem gewählten Code-Stand steht (auch nicht per
# assume-unchanged oder skip-worktree versteckt). Das schützt vor Versehen, NICHT vor einem manipulierten lx: wer in diesem Checkout schreiben kann, hat root-Rechte.
checkout_pruefen() { # $1 Checkout
  local co="$1" status kopf soll marker
  status="$(git_checkout "$co" status --porcelain --untracked-files=all --ignored -- deploy 2>/dev/null)" || return 1
  [ -z "$status" ] || return 1
  marker="$(git_checkout "$co" ls-files -v -- deploy 2>/dev/null | grep -E '^[a-zS] ' || true)"
  [ -z "$marker" ] || return 1
  kopf="$(git_checkout "$co" rev-parse HEAD 2>/dev/null)" || return 1
  soll="$(git_checkout "$co" rev-parse --verify --quiet "${A_GIT_REF}^{commit}" 2>/dev/null)" || return 1
  [ -n "$kopf" ] && [ "$kopf" = "$soll" ]
}
weiter_muell() {
  local co ziel
  weiter_vorbereiten fertig
  echo; fett "Müll-Dienst starten"
  if [ "$A_MUELL" != 1 ]; then zeile "Die Abfuhrtermine waren auf dem alten Server nicht eingeschaltet: nichts zu tun."; return 0; fi
  co="$(lx_checkout)"
  ziel="$co/deploy/einrichtung-muell.sh"
  [ -f "$ziel" ] || fehler_ende "$ziel fehlt (Code-Stand ohne Abfuhrtermine?)." "Nimm einen Code-Stand ab v0.9.0 (starte den Assistenten neu und antworte bei \"Code-Stand ändern?\" mit ja) oder lass den Müll-Dienst weg."
  if ! checkout_pruefen "$co"; then
    fehler_ende "Der Checkout $co weicht vom Code-Stand $A_GIT_REF ab (Änderungen in deploy/ oder anderer Commit); ich führe nichts als root daraus aus." "Prüfe ihn (git -C $co status, git -C $co log -1) und stelle ihn auf $A_GIT_REF zurück. Wer in $co schreiben kann, hat mit dem Dienst root-Rechte."
  fi
  if [ "$A_MUELL_LINK" != 1 ]; then
    fehler_ende "Der Link des Abfallkalenders fehlt in der Sicherung." "Führe zuerst aus: sudo bash $ziel einstellungen   (der Link wird unsichtbar abgefragt) und wiederhole dann diesen Befehl."
  fi
  lies_zeile "Ist der alte Server aus (Müll-Dienst dort gestoppt)? Tippe ja, um fortzufahren: "
  if [ "${ANTWORT,,}" != ja ]; then zeile "Gut, ich starte nichts. Stoppe zuerst den alten Server und wiederhole den Befehl."; return 0; fi
  LETZTE_PHASE="muell"
  echo "=== $(date -u '+%F %T') UTC  einrichtung-muell.sh dienst" >> "$LAUF_LOG"
  if ! bash "$ziel" dienst >>"$LAUF_LOG" 2>&1 8>&-; then
    fehler_ende "Der Müll-Dienst ließ sich nicht einrichten." "Einzelheiten: $LAUF_LOG (oder direkt: sudo bash $ziel dienst)."
  fi
  gut "Müll-Dienst (lx-fampad-waste) eingerichtet und gestartet."
  sudoers_muell_ergaenzen
  erledigt_markieren muell
  weiter_liste
}
# NAS-Rückkanal ("Status vom NAS", Betrieb Paket 3): steht in keiner Sicherung und bootstrap-server.sh richtet ihn nicht ein (und wird hier nicht verändert).
# Nur der Aufruf von einrichtung-nasstatus.sh aus dem geprüften Checkout. Der Server hat keine Zugangsdaten zum NAS: der ÖFFENTLICHE zweite Schlüssel kommt vom NAS.
nasstatus_aufruf() { # $1 Skript, Rest: Optionen; Ausgabe auch ins Log
  local skript="$1" rc; shift
  bash "$skript" "$@" 2>&1 8>&- | tee -a "$LAUF_LOG"
  rc=${PIPESTATUS[0]}
  return "$rc"
}
# NAS-Adresse für einrichtung-nasstatus.sh: strenger als die der Abholung: höchstens 4 Adressen, Netze nur bis /24 (IPv4) bzw. /64 (IPv6), sonst lehnt das Skript sie ab
nasstatus_ip_ok() { # $1 Adressen (Komma)
  local t p teile=()
  gueltige_nas_ip "$1" || return 1
  IFS=',' read -ra teile <<<"$1"
  [ "${#teile[@]}" -le 4 ] || return 1
  for t in "${teile[@]}"; do
    [[ "$t" == */* ]] || continue
    p="${t#*/}"
    if [[ "$t" == *:* ]]; then [ "$p" -ge 64 ] || return 1; else [ "$p" -ge 24 ] || return 1; fi
  done
  return 0
}
NS_IP=""
nasstatus_ip_klaeren() { # $1 vorgeschlagene Adresse (leer = fragen); Ergebnis in NS_IP; höchstens dreimal fragen
  local ip="$1" versuch=0
  while ! nasstatus_ip_ok "$ip"; do
    [ -z "$ip" ] || hinweis "Die NAS-Adresse '${ip:0:60}' passt hier nicht: einrichtung-nasstatus.sh erlaubt nur Einzeladressen oder Netze bis /24 (IPv4) bzw. /64 (IPv6), höchstens vier."
    versuch=$((versuch + 1))
    [ "$versuch" -le 3 ] || fehler_ende "Es wurde keine zulässige NAS-Adresse eingegeben." "Beispiel: 203.0.113.7 (die öffentliche Adresse deines Anschlusses, am besten eine Einzeladresse); starte den Befehl noch einmal."
    lies_zeile "Öffentliche IP-Adresse des NAS (am sichersten eine Einzeladresse): "
    ip="$ANTWORT"
  done
  NS_IP="$ip"
}
weiter_nasstatus() {
  local co ziel ip key
  weiter_vorbereiten fertig
  echo; fett "NAS-Rückmeldung (Status vom NAS) einrichten"
  zeile "Das NAS meldet nach jeder Abholung und jedem Wiederherstellungstest eine kleine, geprüfte Statusdatei an diesen Server (eigener, zweiter SSH-Schlüssel; der Server hält keine Zugangsdaten zum NAS)."
  zeile "Ohne diesen Schritt zeigt \"Betrieb\" keine Rückmeldung des NAS und es gibt keine Warnungen dazu."
  co="$(lx_checkout)"
  ziel="$co/deploy/backup/einrichtung-nasstatus.sh"
  [ -f "$ziel" ] || fehler_ende "$ziel fehlt (Code-Stand ohne NAS-Rückkanal?)." "Nimm einen neueren Code-Stand (starte den Assistenten und antworte bei \"Code-Stand ändern?\" mit ja) oder richte ihn später von Hand ein (docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 11)."
  if ! checkout_pruefen "$co"; then
    fehler_ende "Der Checkout $co weicht vom Code-Stand $A_GIT_REF ab (Änderungen in deploy/ oder anderer Commit); ich führe nichts als root daraus aus." "Prüfe ihn (git -C $co status, git -C $co log -1) und stelle ihn auf $A_GIT_REF zurück. Wer in $co schreiben kann, hat mit dem Skript root-Rechte."
  fi
  ip="$A_NAS_IP"
  if [ -z "$ip" ]; then hinweis "In den Antworten steht keine NAS-IP (die NAS-Abholung wurde nicht eingerichtet)."
  else zeile "NAS-IP aus den Antworten: $ip"; fi
  nasstatus_ip_klaeren "$ip"; ip="$NS_IP"
  zeile "Auf dem NAS liegt der ÖFFENTLICHE Teil des zweiten Schlüssels unter ~/.ssh/lx-fampad-status.pub (Zeile mit \"lx-fampad-status\"). Gibt es ihn noch nicht:"
  blass "  ssh-keygen -t ed25519 -N '' -C 'lx-fampad-status' -f ~/.ssh/lx-fampad-status      (im selben .ssh wie der Schlüssel der Abholung; nie den privaten Teil hierher)"
  zeile "Gib genau EINE Zeile ein, die mit ssh- beginnt (der öffentliche Schlüssel, die Datei MIT .pub). Alles andere weise ich ab, ohne es weiter zu lesen."
  lies_zeile "Öffentlicher Schlüssel (eine Zeile): "
  key="$ANTWORT"
  gueltiger_ssh_schluessel "$key" || fehler_ende "Das ist kein öffentlicher SSH-Schlüssel (erwartet: eine Zeile ssh-ed25519 AAAA… lx-fampad-status)." "Kopiere die Zeile aus ~/.ssh/lx-fampad-status.pub auf dem NAS (die Datei MIT .pub; der private Teil gehört nie hierher) und starte den Befehl noch einmal."
  if [ -n "$A_NAS_PUBKEY" ] && [ "$(awk '{print $2}' <<<"$key")" = "$(awk '{print $2}' <<<"$A_NAS_PUBKEY")" ]; then
    fehler_ende "Das ist der Schlüssel der Abholung, nicht der zweite Schlüssel für die Statusmeldung." "Erzeuge auf dem NAS einen eigenen Schlüssel (ssh-keygen -t ed25519 -N '' -C 'lx-fampad-status' -f ~/.ssh/lx-fampad-status) und gib dessen .pub-Zeile an."
  fi
  case "$key" in ssh-rsa\ *) hinweis "Das ist ein RSA-Schlüssel: einrichtung-nasstatus.sh nimmt ihn an, ein ed25519-Schlüssel wäre besser (ssh-keygen -t ed25519)." ;; esac
  LETZTE_PHASE="nasstatus"
  echo "=== $(date -u '+%F %T') UTC  einrichtung-nasstatus.sh" >> "$LAUF_LOG"
  echo; zeile "Trockenlauf (einrichtung-nasstatus.sh --dry-run, ändert nichts) …"
  while ! nasstatus_aufruf "$ziel" --dry-run --nas-pubkey "$key" --nas-ip "$ip"; do
    schlecht "Der Trockenlauf von einrichtung-nasstatus.sh meldet ein Problem (siehe oben)."
    frage_ja "Eine andere NAS-IP eingeben (z. B. wenn die Adresse abgelehnt wurde)?" nein \
      || fehler_ende "Der Trockenlauf von einrichtung-nasstatus.sh meldet ein Problem (siehe oben)." "Behebe es (Einzelheiten: $LAUF_LOG, docs/BACKUP-EINRICHTUNG-SCHRITTE.md Abschnitt 11) und starte den Befehl noch einmal."
    nasstatus_ip_klaeren ""; ip="$NS_IP"
  done
  echo
  frage_ja "Trockenlauf ohne Befund. Jetzt einrichten?" ja || { zeile "Gut, ich ändere nichts."; return 0; }
  nasstatus_aufruf "$ziel" --nas-pubkey "$key" --nas-ip "$ip" || fehler_ende "Das Einrichten der NAS-Rückmeldung ist fehlgeschlagen (siehe oben; das Skript hat seine Änderungen zurückgenommen)." "Behebe die Ursache (Einzelheiten: $LAUF_LOG) und starte den Befehl noch einmal."
  gut "NAS-Rückmeldung auf diesem Server eingerichtet."
  erledigt_markieren nasstatus
  zeile "Noch auf dem NAS: lx-fampad-nasstatus.sh einmal von Hand ausführen (docs/BACKUP-EINRICHTUNG-SCHRITTE.md, Abschnitt 11.4); dann zeigt \"Betrieb\" > Backups die Rückmeldung."
  weiter_liste
}
weiter_pruefung() {
  weiter_vorbereiten
  echo; fett "Abschlussprüfung"
  weiter_phasen "pruefung" "Abschlussprüfung"
  fertig_markieren pruefung
  weiter_liste
}
# --- --aktualisieren: Hilfen -------------------------------------------------------------------------------------------------------
wort_eingeben() { # $1 Aufforderung, $2 Wort; Rückgabe 0 = genau dieses Wort getippt
  local k
  printf '%s' "$1" >&2
  if ! IFS= read -r k; then echo >&2; abbruch_eingabe; fi
  [ "$(trimmen "${k%$'\r'}")" = "$2" ]
}
sicherung_zeit_text() { # $1 Ordner -> "22.10.2026 03:30:00 UTC" (aus dem Ordnernamen YYYYMMDD-HHMMSS), sonst leer
  local n
  n="$(basename "$1")"
  [[ "$n" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]] || return 0
  printf '%s.%s.%s %s:%s:%s UTC' "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
}
sicherung_aelter_gleich() { # $1 bisherige, $2 neue Sicherung: 0, wenn die neue NICHT neuer ist oder sich nicht vergleichen lässt (Name ohne Zeitstempel)
  local a b
  a="$(basename "$1")"; b="$(basename "$2")"
  [[ "$a" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "$b" =~ ^[0-9]{8}-[0-9]{6}$ ]] || return 0
  [[ ! "$b" > "$a" ]]
}
auth_hash() { # stdin: eine env; gibt den Hash des letzten AUTH_SECRET_KEY aus (nie den Wert); nichts, wenn keiner da ist
  sed -n 's/^AUTH_SECRET_KEY=//p' | tail -n 1 | { local v; IFS= read -r v && [ -n "$v" ] && printf '%s' "$v" | sha256sum | cut -d' ' -f1; }
}
env_vergleichswerte() { # stdin: eine env; Zeilen NAME=an|aus|gesetzt|nicht gesetzt für die nicht geheimen Schalter (nie ein Wert, nie der Link)
  awk '
    function norm(v) { gsub(/["\047]/, "", v); v = tolower(v); if (v == "true" || v == "1") return "an"; if (v == "false" || v == "0") return "aus"; if (v == "") return "nicht gesetzt"; return "gesetzt" }
    { sub(/\r$/, "") }
    /^WEATHER_ENABLED=/ { w = norm(substr($0, 17)) }
    /^WASTE_ENABLED=/ { m = norm(substr($0, 15)) }
    /^WASTE_ICS_URL=./ { l = "gesetzt" }
    /^E2EE_PW_BACKUP=/ { e = norm(substr($0, 16)) }
    /^AUTH_LEGACY_PASSWORD_LOGIN=/ { a = norm(substr($0, 28)) }
    END {
      print "WEATHER_ENABLED=" (w == "" ? "nicht gesetzt" : w); print "WASTE_ENABLED=" (m == "" ? "nicht gesetzt" : m)
      print "WASTE_ICS_URL=" (l == "" ? "nicht gesetzt" : l); print "E2EE_PW_BACKUP=" (e == "" ? "nicht gesetzt" : e)
      print "AUTH_LEGACY_PASSWORD_LOGIN=" (a == "" ? "nicht gesetzt" : a)
    }'
}
# Vergleich der Sicherung mit der env dieses Servers: ist der AUTH_SECRET_KEY gleich (nur per Hash, nie ausgegeben)? Bei gleichem Schlüssel bleibt die env dieses
# Servers (bootstrap-server.sh ersetzt sie nur bei abweichendem Schlüssel): dann zeigt KONFIG_ABW, worin die nicht geheimen Schalter der Sicherung abweichen.
konfiguration_vergleichen() {
  local a b n k v
  local -A sich=() lokal=()
  KONFIG_GLEICH=0; KONFIG_ABW=()
  a="$(cfg_aus_archiv etc/lx-fampad/env | auth_hash)"; b=""
  if [ -f "$ENV_LOKAL" ]; then b="$(auth_hash < "$ENV_LOKAL")"; fi
  if [ -n "$a" ] && [ "$a" = "$b" ]; then KONFIG_GLEICH=1; fi
  a=""; b=""
  [ "$KONFIG_GLEICH" = 1 ] || return 0
  while IFS='=' read -r k v; do sich["$k"]="$v"; done < <(cfg_aus_archiv etc/lx-fampad/env | env_vergleichswerte)
  while IFS='=' read -r k v; do lokal["$k"]="$v"; done < <(env_vergleichswerte < "$ENV_LOKAL")
  for n in WEATHER_ENABLED WASTE_ENABLED WASTE_ICS_URL E2EE_PW_BACKUP AUTH_LEGACY_PASSWORD_LOGIN; do
    if [ "${sich[$n]:-}" != "${lokal[$n]:-}" ]; then KONFIG_ABW+=("$n: auf diesem Server ${lokal[$n]:-?}, in der Sicherung ${sich[$n]:-?}"); fi
  done
  return 0
}
alte_db_merken() { # $1 Name einer umbenannten Datenbank (kommagetrennte Liste: jede Aktualisierung legt eine weitere an)
  if ! liste_enthaelt "$A_ALTE_DB" "$1"; then A_ALTE_DB="${A_ALTE_DB:+$A_ALTE_DB,}$1"; fi
}
# Umzug bei laufendem Altserver: eine neuere Sicherung einspielen (die bisherige Datenbank bleibt umbenannt; die env nur bei anderem AUTH_SECRET_KEY ersetzt)
aktualisieren() {
  local rc vorher zeit_neu a live=0
  weiter_vorbereiten fertig
  echo; fett "Neuere Sicherung einspielen"
  zeile "Das spielt die Datenbank der gewählten Sicherung ein. Die bisherige Datenbank wird nur umbenannt (nichts wird gelöscht), die Dienste stehen dabei kurz still."
  zeile "Die Konfiguration (env) dieses Servers wird nur ersetzt, wenn der AUTH_SECRET_KEY der Sicherung ANDERS ist; bei gleichem Schlüssel bleibt sie (fehlende Dateien in /etc/lx-fampad werden ergänzt)."
  zeile "Vorher auf dem ALTEN Server: sudo systemctl stop lx-fampad lx-fampad-weather, dann die frische Sicherung holen (Schreibstopp)."
  vorher="$A_SICHERUNG"; A_SICHERUNG=""
  frage_sicherung
  zeit_neu="$(sicherung_zeit_text "$A_SICHERUNG")"
  if sicherung_aelter_gleich "$vorher" "$A_SICHERUNG"; then
    hinweis "Diese Sicherung ($(basename "$A_SICHERUNG")${zeit_neu:+, $zeit_neu}) ist NICHT neuer als die zuletzt eingespielte ($(basename "${vorher:-?}")) oder lässt sich nicht vergleichen: du würdest einen gleichen oder älteren Stand einspielen."
    wort_eingeben "Wirklich? Tippe aelter zur Bestätigung: " aelter || { zeile "Abgebrochen, es wurde nichts verändert."; return 0; }
  fi
  frage_schluessel
  config_auswerten ohne-flags
  konfiguration_vergleichen
  echo
  if [ "$KONFIG_GLEICH" = 1 ]; then
    gut "AUTH_SECRET_KEY der Sicherung: GLEICH wie auf diesem Server (die env dieses Servers bleibt)."
    for a in "${KONFIG_ABW[@]}"; do hinweis "Schalter weichen ab: $a"; done
    if [ "${#KONFIG_ABW[@]}" -gt 0 ]; then
      hinweis "Die env dieses Servers gilt weiter. Prüfe die Abweichungen nach dem Lauf, besonders E2EE_PW_BACKUP: nutzen Konten die Anmeldung mit authKey, scheitert sie, wenn es hier aus ist."
    fi
  else
    schlecht "AUTH_SECRET_KEY der Sicherung: ANDERS als auf diesem Server (oder nicht lesbar). Das ist vermutlich die Sicherung eines anderen Servers: die env dieses Servers wird ersetzt (Kopie bleibt), TOTP-Geheimnisse und Codes der bisherigen Konten wären nur mit dem alten Schlüssel lesbar."
  fi
  if liste_enthaelt "$A_ERLEDIGT" caddy; then live=1; fi
  printf '%sAchtung:%s Die Datenbank dieses Servers wird durch die Sicherung %s%s ersetzt (die bisherige bleibt umbenannt). Tippe %sersetzen%s zur Bestätigung: ' "$C_B" "$C_RESET" "$(basename "$A_SICHERUNG")" "${zeit_neu:+ vom $zeit_neu}" "$C_C" "$C_RESET" >&2
  if ! IFS= read -r a; then echo >&2; abbruch_eingabe; fi
  if [ "$(trimmen "${a%$'\r'}")" != ersetzen ]; then zeile "Abgebrochen, es wurde nichts verändert."; schluessel_verwerfen; return 0; fi
  if [ "$KONFIG_GLEICH" != 1 ]; then
    wort_eingeben "Der AUTH_SECRET_KEY ist ANDERS: die env dieses Servers wird ersetzt. Zum Fortfahren tippe anders: " anders || { zeile "Abgebrochen, es wurde nichts verändert."; schluessel_verwerfen; return 0; }
  fi
  if [ "$live" = 1 ]; then
    hinweis "Dieser Server ist schon in Betrieb (Caddy läuft). Alles, was die Familie hier seit dem ersten Einspielen geändert hat (Nachrichten, Termine, Listen), landet in der UMBENANNTEN Datenbank und fehlt danach."
    wort_eingeben "Zum Fortfahren tippe verlieren: " verlieren || { zeile "Abgebrochen, es wurde nichts verändert."; schluessel_verwerfen; return 0; }
  fi
  antworten_schreiben
  LETZTE_PHASE="aktualisieren"
  bootstrap_basis
  BA+=(--phase "konfiguration,datenbank,anwendung" --sicherung "$A_SICHERUNG" --identity-stdin --datenbank-ersetzen --konfiguration-ersetzen --yes)
  if liste_enthaelt "$A_ERLEDIGT" wetter; then BA+=(--wetter-starten); fi
  lauf_ausfuehren "Neue Sicherung einspielen, Server neu bauen" "·" 1; rc=$?
  schluessel_verwerfen
  # Der Tausch der Datenbank ist unumkehrbar gemeldet: den Namen der umbenannten Datenbank sofort merken, auch wenn danach etwas scheitert
  if [ -n "$ALTE_DB_NEU" ]; then alte_db_merken "$ALTE_DB_NEU"; antworten_schreiben; fi
  if [ "$rc" -ne 0 ]; then
    printf '%s✗%s Neue Sicherung einspielen\n' "$C_R" "$C_RESET" >&2
    if [ -n "$ALTE_DB_NEU" ]; then
      fehler_ende "Nach dem Tausch der Datenbank ist etwas fehlgeschlagen${LETZTER_FEHLER:+: $LETZTER_FEHLER}: die neue Datenbank ist eingespielt, die bisherige heißt jetzt $ALTE_DB_NEU (nichts wurde gelöscht), der Server läuft möglicherweise nicht." "Prüfe den Zustand (sudo -u postgres psql -l, journalctl -u lx-fampad -n 50). Bei falschem Code-Stand: starte bash $UMZUG_PFAD (ohne --aktualisieren) und antworte bei \"Code-Stand ändern?\" mit ja, das baut den Server neu und tauscht die Datenbank nicht noch einmal; ein zweites --aktualisieren spielt die Sicherung noch einmal ein und legt eine ZWEITE umbenannte Datenbank (lx_fampad_vor_…) an."
    fi
    fehler_ende "Das Einspielen der neuen Sicherung ist fehlgeschlagen${LETZTER_FEHLER:+: $LETZTER_FEHLER}; die Datenbank wurde nicht getauscht." "$(fehlermassnahme "$LETZTER_FEHLER") (Bei diesem Fehler ist nichts umbenannt worden; --aktualisieren lässt sich nach der Korrektur wiederholen.)"
  fi
  phase_meldung_ok "·" "Neue Sicherung eingespielt, Server neu gestartet"
  if [ -n "$ALTE_DB_NEU" ]; then
    hinweis "Die bisherige Datenbank heißt jetzt $ALTE_DB_NEU und enthält Personendaten. Nach der Prüfung löschen: sudo -u postgres psql -c \"DROP DATABASE $ALTE_DB_NEU\""
  fi
  # Die env dieses Servers gilt jetzt (bei gleichem Schlüssel blieb sie): Schalter für Wetter und Müll von dort lesen, damit die Liste dazu passt
  if [ -f "$ENV_LOKAL" ]; then
    schalter_lesen < "$ENV_LOKAL"
    if [ "$SCH_GELESEN" = 1 ]; then A_WETTER="$SCH_W"; A_MUELL="$SCH_M"; A_MUELL_LINK="$SCH_ML"; fi
  fi
  if [ "$KONFIG_GLEICH" = 1 ]; then
    for a in "${KONFIG_ABW[@]}"; do hinweis_merken "Nach --aktualisieren blieb die env dieses Servers und weicht von der Sicherung ab: $a. Prüfen (E2EE_PW_BACKUP aus, aber Konten mit authKey: Anmeldung scheitert)."; done
  fi
  if liste_enthaelt "$A_ERLEDIGT" muell; then sudoers_muell_ergaenzen; fi
  erledigt_markieren aktualisieren
  weiter_liste
}

# --- Aufruf -------------------------------------------------------------------------------------------------------------------------
hilfe() { sed -n '2,/^set -u/{/^set -u/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
argumente_lesen() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --probe) OPT_PROBE=1 ;;
      --weiter) [ $# -ge 2 ] || { echo "--weiter braucht einen Wert (caddy, wetter, muell, nasstatus, pruefung)" >&2; exit 2; }; OPT_WEITER="$2"; shift ;;
      --aktualisieren) OPT_AKTUALISIEREN=1 ;;
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
  case "$OPT_WEITER" in ''|caddy|wetter|muell|nasstatus|pruefung) ;; *) echo "Unbekannter Folgeschritt: $OPT_WEITER (erlaubt: caddy, wetter, muell, nasstatus, pruefung)" >&2; exit 2 ;; esac
  if [ -n "$OPT_WEITER" ] && { [ "$OPT_PROBE" = 1 ] || [ "$OPT_NEU" = 1 ] || [ "$OPT_AKTUALISIEREN" = 1 ]; }; then echo "--weiter geht nicht zusammen mit --probe, --neu oder --aktualisieren" >&2; exit 2; fi
  if [ "$OPT_PROBE" = 1 ] && [ "$OPT_NEU" = 1 ]; then echo "--probe geht nicht zusammen mit --neu (der Probelauf ändert nichts, auch keine gemerkten Antworten)" >&2; exit 2; fi
  if [ "$OPT_AKTUALISIEREN" = 1 ] && { [ "$OPT_PROBE" = 1 ] || [ "$OPT_NEU" = 1 ]; }; then echo "--aktualisieren geht nicht zusammen mit --probe oder --neu" >&2; exit 2; fi
  if [ -n "$OPT_PARAMS" ]; then
    OPT_PARAMS="$(readlink -f -- "$OPT_PARAMS" 2>/dev/null || echo "$OPT_PARAMS")"
    gueltiger_pfad "$OPT_PARAMS" || { echo "--params: ungültiger Pfad (absolut, nur Buchstaben, Ziffern und . _ - / @ +, ohne '..' und Leerzeichen): $OPT_PARAMS" >&2; exit 2; }
  fi
  if [ -n "$OPT_IP" ] && { ! gueltige_ipv4 "$OPT_IP" || private_ipv4 "$OPT_IP"; }; then echo "--ip braucht eine öffentliche IPv4-Adresse (Beispiel: 203.0.113.10)" >&2; exit 2; fi
  if [ "$OPT_DNS_SKIP" = 1 ] && [ "$OPT_OHNE_SYSTEMD" = 0 ]; then echo "--dns-pruefung-ueberspringen gibt es nur zusammen mit --ohne-systemd (Container-Tests)" >&2; exit 2; fi
  return 0
}
# Absicherung gegen unbeabsichtigte Spuren des Schlüssels: kein xtrace (würde die Eingabe ins Terminal oder in eine Datei schreiben), keine Speicherabzüge
sicherheit_pruefen() {
  case "$-" in *x*) echo "Abbruch: xtrace (bash -x, set -x) ist eingeschaltet: es würde auch den privaten Schlüssel protokollieren. Starte ohne -x." >&2; exit 2 ;; esac
  if [ -n "${BASH_XTRACEFD:-}" ]; then echo "Abbruch: BASH_XTRACEFD ist gesetzt (Protokollierung der Befehle): unset BASH_XTRACEFD und neu starten." >&2; exit 2; fi
  ulimit -c 0 2>/dev/null || true
}
# Sperre gegen zwei gleichzeitige Sitzungen (Dateideskriptor 8; an bootstrap-server.sh und alles, was es startet, wird er nicht vererbt: 8>&-). Der Probelauf ändert
# nichts und braucht keine Sperre.
sperre_holen() {
  [ "$OPT_PROBE" = 0 ] || return 0
  mkdir -p "$(dirname "$LOCK_DATEI")" 2>/dev/null || true
  if ! { exec 8>"$LOCK_DATEI"; } 2>/dev/null || ! flock -n 8; then
    fehler_ende "Eine andere Sitzung des Assistenten läuft schon (Sperre $LOCK_DATEI)." "Warte, bis sie fertig ist (tmux attach -t umzug), und starte dann denselben Befehl noch einmal." 2
  fi
}
main() {
  sicherheit_pruefen
  argumente_lesen "$@"
  farben_init
  [ "$(id -u)" -eq 0 ] || { echo "Bitte als root starten:  sudo bash $0" >&2; exit 2; }
  trap aufraeumen EXIT
  trap unterbrochen INT TERM HUP
  if [ -t 0 ]; then STTY_SAVE="$(stty -g 2>/dev/null || true)"; fi
  ARBEIT_DIR="$(mktemp -d -p /run umzug.XXXXXXXX 2>/dev/null || mktemp -d)"
  if [ -z "$ARBEIT_DIR" ] || [ ! -d "$ARBEIT_DIR" ]; then echo "Abbruch: Das Arbeitsverzeichnis ließ sich nicht anlegen (/run voll oder nicht beschreibbar?)." >&2; exit 1; fi
  chmod 700 "$ARBEIT_DIR"
  sperre_holen
  bootstrap_pruefen
  if [ -n "$OPT_WEITER" ]; then
    case "$OPT_WEITER" in caddy) weiter_caddy ;; wetter) weiter_wetter ;; muell) weiter_muell ;; nasstatus) weiter_nasstatus ;; pruefung) weiter_pruefung ;; esac
    exit 0
  fi
  if [ "$OPT_AKTUALISIEREN" = 1 ]; then aktualisieren; exit 0; fi
  echo
  if [ "$OPT_NEU" = 1 ]; then antworten_lesen || true; antworten_neu_beginnen
  elif [ "$OPT_PROBE" = 0 ] && antworten_lesen; then
    echo
    zeile "Ich habe die Antworten eines früheren Laufs gefunden:"
    printf '  Sicherung %s, Code-Stand %s, fertige Phasen: %s\n' "${A_SICHERUNG:-?}" "${A_GIT_REF:-?}" "${A_FERTIG:-keine}"
    if [ -n "$A_PARAMS" ]; then printf '  Zusätzliche Parameterdatei: %s\n' "$A_PARAMS"; fi
    if ! frage_ja "Damit weitermachen?" ja; then antworten_neu_beginnen; fi
  fi
  extra_params_einbinden
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
  # shellcheck disable=SC2317
  exit $?
fi
