#!/usr/bin/env bash
# Tests der Hilfsfunktionen des Umzugs-Assistenten (umzug.sh). Verändert nichts außerhalb eines Wegwerf-Ordners.
# Läuft als root (chown in den Hilfen) mit bash 5, age, tar, awk. Am einfachsten im Debian-13-Container:
#   deploy/neuinstallation/test-docker.sh          (siehe dort)
# Aufruf direkt:   bash deploy/neuinstallation/test-umzug.sh
# shellcheck disable=SC2034,SC2015,SC2016,SC1090
# (SC2034: A_*/AGE_ID usw. werden von den eingelesenen Funktionen benutzt; SC2015/SC2016: Absicht in den Testzeilen)
set -uo pipefail

[ ! -e /srv/fampad/server ] || { echo "Abbruch: /srv/fampad/server existiert (ein echter Server?). Die Tests laufen nur in Wegwerf-Containern." >&2; exit 99; }
[ -f /.dockerenv ] || { echo "Abbruch: Die Tests laufen nur in einem Docker-Container (/.dockerenv fehlt): sie rufen den Assistenten als root auf und er schreibt nach /root." >&2; exit 99; }
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKRIPT="$HIER/umzug.sh"
BOOT="$HIER/bootstrap-server.sh"
ARBEIT="$(mktemp -d)"
trap 'rm -rf "$ARBEIT"' EXIT
OK=0; FEHL=0; UEBERSPRUNGEN=0

ok() { OK=$((OK + 1)); echo "  ok    $1"; }
fehl() { FEHL=$((FEHL + 1)); echo "  FEHLT $1"; }
uebersprungen() { UEBERSPRUNGEN=$((UEBERSPRUNGEN + 1)); echo "  --    $1 (übersprungen: $2)"; }
gleich() { if [ "$2" = "$3" ]; then ok "$1"; else fehl "$1 (erwartet '$2', erhalten '$3')"; fi; }
gelingt() { local t="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$t"; else fehl "$t"; fi; }
scheitert() { local t="$1"; shift; if "$@" >/dev/null 2>&1; then fehl "$t (hätte scheitern müssen)"; else ok "$t"; fi; }
enthaelt() { # Text, Haystack, Nadel (fester Text)
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fehl "$1 (nicht gefunden: $3)"; fi
}
enthaelt_nicht() { if grep -qF -- "$3" <<<"$2"; then fehl "$1 (gefunden: $3)"; else ok "$1"; fi; }

# Skript einlesen, ohne es auszuführen
export UMZUG_NUR_FUNKTIONEN=1
. "$SKRIPT"
set +e +u
trap - ERR
a() { env -u UMZUG_NUR_FUNKTIONEN bash "$SKRIPT" "$@"; }
# Pfade der Antworten usw. in den Wegwerf-Ordner umlenken
ANTWORTEN_DATEI="$ARBEIT/antworten"; OFFEN_DATEI="$ARBEIT/offen.txt"; BERICHT_DATEI="$ARBEIT/bericht.txt"; LAUF_LOG="$ARBEIT/lauf.log"; PARAMS_ERZEUGT="$ARBEIT/umzug.params"
SSH_KEY_RE="$(bootstrap_wert SSH_KEY_RE)"

echo "== Syntax und Aufruf"
gelingt "bash -n" bash -n "$SKRIPT"
gleich "unbekannte Option: Exit-Code 2" 2 "$(a --gibtsnicht >/dev/null 2>&1; echo $?)"
gleich "--weiter mit unbekanntem Schritt: Exit-Code 2" 2 "$(a --weiter irgendwas >/dev/null 2>&1; echo $?)"
gleich "--weiter zusammen mit --probe: Exit-Code 2" 2 "$(a --weiter caddy --probe >/dev/null 2>&1; echo $?)"
gleich "--ip mit privater Adresse: Exit-Code 2" 2 "$(a --ip 192.168.1.5 >/dev/null 2>&1; echo $?)"
gleich "--ip mit Unsinn: Exit-Code 2" 2 "$(a --ip abc >/dev/null 2>&1; echo $?)"
gleich "--dns-pruefung-ueberspringen ohne --ohne-systemd: Exit-Code 2" 2 "$(a --dns-pruefung-ueberspringen >/dev/null 2>&1; echo $?)"
HILFE="$(a --hilfe)"
enthaelt "--hilfe nennt --probe" "$HILFE" "--probe"
enthaelt "--hilfe nennt --weiter" "$HILFE" "--weiter caddy"
gleich "Hilfe ohne Escape-Codes (nicht auf einem Terminal)" 0 "$(printf '%s' "$HILFE" | grep -c $'\033')"
mkdir "$ARBEIT/allein"; cp "$SKRIPT" "$ARBEIT/allein/umzug.sh"; chmod 700 "$ARBEIT/allein/umzug.sh"
SOLO="$(env -u UMZUG_NUR_FUNKTIONEN bash "$ARBEIT/allein/umzug.sh" 2>&1)"; SOLO_RC=$?
gleich "ohne bootstrap-server.sh neben dem Skript: Exit-Code 2" 2 "$SOLO_RC"
enthaelt "Fehlermeldung nennt die Maßnahme (scp)" "$SOLO" "scp deploy/neuinstallation/umzug.sh"
mkdir "$ARBEIT/schreibbar"; cp "$SKRIPT" "$ARBEIT/schreibbar/umzug.sh"; cp "$BOOT" "$ARBEIT/schreibbar/bootstrap-server.sh"
chmod 700 "$ARBEIT/schreibbar/umzug.sh"; chmod 666 "$ARBEIT/schreibbar/bootstrap-server.sh"
RW="$(env -u UMZUG_NUR_FUNKTIONEN bash "$ARBEIT/schreibbar/umzug.sh" 2>&1)"; RW_RC=$?
gleich "für andere schreibbares bootstrap-server.sh wird abgelehnt (Exit-Code 1)" 1 "$RW_RC"
enthaelt "Meldung nennt chown/chmod" "$RW" "chmod 700"
gleich "keine Farben ohne Terminal" "" "$(farben_init; printf '%s' "$C_G$C_RESET")"

echo "== Prüfungen der Eingaben"
for p in /root/sicherung/20261022-033000 /srv/x_y-z.1/a@b+c; do gelingt "Pfad ok: $p" gueltiger_pfad "$p"; done
for p in relativ/pfad "/a/../b" "/a b" '/a;b' '/a$(x)' "/a/.." "" "/a'b"; do scheitert "Pfad abgelehnt: '$p'" gueltiger_pfad "$p"; done
for t in v0.9.0 v1.10.22 v0.0.0-test v1.0.0-rc.1 abcdef1 0123456789abcdef0123456789abcdef01234567; do gelingt "Tag/Commit ok: $t" gueltiger_tag "$t"; done
for t in main 0.9.0 v0.9 "v0.9.0 x" 'v0.9.0;ls' "-v0.9.0" abc12 ""; do scheitert "Tag abgelehnt: '$t'" gueltiger_tag "$t"; done
for i in 203.0.113.7 8.8.8.8 1.2.3.4; do gelingt "IPv4 ok: $i" gueltige_ipv4 "$i"; done
for i in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d "" "1.2.3.4/24"; do scheitert "IPv4 abgelehnt: '$i'" gueltige_ipv4 "$i"; done
for i in 10.0.0.1 127.0.0.1 192.168.1.1 172.16.0.1 172.31.255.1 169.254.1.1 100.64.0.1; do gelingt "private IPv4 erkannt: $i" private_ipv4 "$i"; done
for i in 8.8.8.8 172.32.0.1 172.15.0.1 203.0.113.7 100.63.0.1; do scheitert "öffentliche IPv4 nicht privat: $i" private_ipv4 "$i"; done
for i in 203.0.113.7 203.0.113.0/24 203.0.0.0/16 2001:db8::1 2001:db8::/48 "203.0.113.7,2001:db8::1"; do gelingt "NAS-IP ok: $i" gueltige_nas_ip "$i"; done
for i in "" abc "1.2.3" "203.0.113.7;ls" "203.0.113.7 " "a:b:zz" 256.1.1.1 203.0.113.256 01.2.3.4 0.0.0.0 224.0.0.1 240.0.0.1 203.0.113.7/24 10.0.0.0/8 203.0.113.0/15 203.0.113.0/33 2001:db8::/32 :: ff02::1 ::ffff:1.2.3.4 2001:db8:::1 1:2:3:4:5:6:7:8:9; do scheitert "NAS-IP abgelehnt: '$i'" gueltige_nas_ip "$i"; done
for s in 0 256 1024 8192; do gelingt "Swap ok: $s" gueltiger_swap "$s"; done
for s in 100 8193 -1 abc ""; do scheitert "Swap abgelehnt: '$s'" gueltiger_swap "$s"; done
SSHOK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc test@pc"
gelingt "SSH-Schlüssel ok" gueltiger_ssh_schluessel "$SSHOK"
scheitert "privater SSH-Schlüssel wird abgelehnt" gueltiger_ssh_schluessel "-----BEGIN OPENSSH PRIVATE KEY-----"
scheitert "SSH-Schlüssel mit Optionen davor wird abgelehnt" gueltiger_ssh_schluessel "command=\"ls\" $SSHOK"
gleich "trimmen" "a b" "$(trimmen "   a b  ")"
gelingt "liste_enthaelt" liste_enthaelt "a,b,c" b
scheitert "liste_enthaelt: Teilstring zählt nicht" liste_enthaelt "ab,c" b

echo "== Eingabe aus stdin (Fragen)"
gleich "frage_ja: Enter = Standard ja" 0 "$(printf '\n' | { frage_ja "x" ja 2>/dev/null; echo $?; })"
gleich "frage_ja: Enter = Standard nein" 1 "$(printf '\n' | { frage_ja "x" nein 2>/dev/null; echo $?; })"
gleich "frage_ja: ja" 0 "$(printf 'ja\n' | { frage_ja "x" nein 2>/dev/null; echo $?; })"
gleich "frage_ja: erst Unsinn, dann nein" 1 "$(printf 'vielleicht\nnein\n' | { frage_ja "x" ja >/dev/null 2>&1; echo $?; })"
gleich "Ende der Eingabe bricht ab (Exit-Code 1)" 1 "$( ( : | lies_zeile "x" ) >/dev/null 2>&1; echo $? )"

echo "== Schlüssel einlesen (nur aus der Pipe, nie angezeigt)"
KEYZEILE="AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
RESTSTDIN="$(printf '# created: x\n# public key: age1x\n%s\nnaechste-antwort\n' "$KEYZEILE" | { schluessel_einlesen 2>/dev/null; echo "KEY=${AGE_ID:+gesetzt}"; IFS= read -r r; echo "REST=$r"; })"
enthaelt "Schlüsseldatei mit Kommentarzeilen wird erkannt" "$RESTSTDIN" "KEY=gesetzt"
enthaelt "nach dem Schlüssel bleibt die restliche Eingabe unberührt" "$RESTSTDIN" "REST=naechste-antwort"
enthaelt_nicht "der Schlüssel wird nicht ausgegeben" "$RESTSTDIN" "AGE-SECRET-KEY"
gleich "Eingabe ohne Schlüssel: Rückgabe 1" 1 "$(printf 'hallo\n' | { schluessel_einlesen >/dev/null 2>&1; echo $?; })"
gleich "Schlüssel mit Windows-Zeilenende" gesetzt "$(printf '%s\r\n' "$KEYZEILE" | { schluessel_einlesen 2>/dev/null; echo "${AGE_ID:+gesetzt}"; })"
gleich "Schlüssel ohne Zeilenumbruch am Ende" gesetzt "$(printf '%s' "$KEYZEILE" | { schluessel_einlesen 2>/dev/null; echo "${AGE_ID:+gesetzt}"; })"

echo "== Gemerkte Antworten (nur Nicht-Geheimes)"
AGE_ID="$KEYZEILE"
A_SICHERUNG=/root/sicherung/20261022-033000; A_GIT_REF=v0.9.0; A_SWAP_MB=1024; A_IP=203.0.113.10; A_NAS_IP=203.0.113.7; A_NAS_PUBKEY="$SSHOK"
A_WETTER=1; A_MUELL=1; A_MUELL_LINK=1; A_KEEP=3; A_APK=1; A_FILES=0; A_FRAGEN=1; A_FERTIG="pruefen,pakete"; A_ERLEDIGT=""
HINWEISE=("Beispielhinweis ohne Geheimnis")
antworten_schreiben
gleich "Antwortdatei: Modus 600, root" "600:root" "$(stat -c %a:%U "$ANTWORTEN_DATEI")"
enthaelt "Antwortdatei enthält den Sicherungspfad" "$(cat "$ANTWORTEN_DATEI")" "SICHERUNG=/root/sicherung/20261022-033000"
enthaelt "Antwortdatei enthält den Code-Stand" "$(cat "$ANTWORTEN_DATEI")" "GIT_REF=v0.9.0"
enthaelt_nicht "Antwortdatei enthält KEINEN Schlüssel (obwohl er im Speicher ist)" "$(cat "$ANTWORTEN_DATEI")" "AGE-SECRET-KEY"
gleich "kein Schlüsselmaterial in der Antwortdatei (auch nicht der Rest)" 0 "$(grep -c "QQQQQQQQQQ" "$ANTWORTEN_DATEI")"
AGE_ID=""
antworten_zuruecksetzen
gelingt "Antwortdatei wird gelesen" antworten_lesen
gleich "gelesen: Code-Stand" v0.9.0 "$A_GIT_REF"
gleich "gelesen: fertige Phasen" "pruefen,pakete" "$A_FERTIG"
gleich "gelesen: Hinweis" "Beispielhinweis ohne Geheimnis" "${HINWEISE[0]}"
fertig_markieren system
gleich "fertig_markieren hängt an und schreibt" "pruefen,pakete,system" "$(grep '^FERTIG=' "$ANTWORTEN_DATEI" | cut -d= -f2)"
fertig_markieren system
gleich "fertig_markieren ist idempotent" "pruefen,pakete,system" "$(grep '^FERTIG=' "$ANTWORTEN_DATEI" | cut -d= -f2)"
printf 'GIT_REF=v0.1.0\nSWAP_MB=1024 und mehr\nSICHERUNG=/a/../b\nNAS_PUBKEY=AGE-SECRET-KEY-1ABC\nFERTIG=Pakete;rm\nUNBEKANNT=1\nIP=999.1.1.1\n' > "$ANTWORTEN_DATEI"; chmod 600 "$ANTWORTEN_DATEI"
antworten_zuruecksetzen; antworten_lesen
gleich "gültiger Wert wird übernommen" v0.1.0 "$A_GIT_REF"
gleich "ungültiger Swap-Wert wird verworfen" "" "$A_SWAP_MB"
gleich "Pfad mit .. wird verworfen" "" "$A_SICHERUNG"
gleich "privater Schlüssel als Wert wird verworfen" "" "$A_NAS_PUBKEY"
gleich "Phasenliste mit Sonderzeichen wird verworfen" "" "$A_FERTIG"
gleich "ungültige IP wird verworfen" "" "$A_IP"
chmod 644 "$ANTWORTEN_DATEI"; antworten_zuruecksetzen
scheitert "für andere lesbare Antwortdatei wird ignoriert" antworten_lesen
chmod 600 "$ANTWORTEN_DATEI"; mv "$ANTWORTEN_DATEI" "$ARBEIT/echt"; ln -s "$ARBEIT/echt" "$ANTWORTEN_DATEI"
scheitert "Symlink als Antwortdatei wird ignoriert" antworten_lesen
rm -f "$ANTWORTEN_DATEI" "$ARBEIT/echt"

echo "== Parameterdatei für bootstrap-server.sh"
antworten_zuruecksetzen
A_GIT_REF=v0.9.0; A_SWAP_MB=1024; A_LX_PUBKEY="$SSHOK"; A_NAS_IP=203.0.113.7; A_NAS_PUBKEY="$SSHOK"; A_KEEP=5; A_APK=0; A_FILES=1
EXTRA=([BACKUP_AGE_RECIPIENTS]="age1$(printf 'q%.0s' {1..58})" [GIT_REF]=v0.0.1)
params_schreiben "$ARBEIT/p.params"
gleich "Parameterdatei: Modus 600, root" "600:root" "$(stat -c %a:%U "$ARBEIT/p.params")"
P="$(cat "$ARBEIT/p.params")"
enthaelt "GIT_REF aus den Antworten (nicht aus --params)" "$P" "GIT_REF=v0.9.0"
enthaelt_nicht "GIT_REF aus --params wird nicht doppelt geschrieben" "$P" "v0.0.1"
enthaelt "Swap" "$P" "SWAP_MB=1024"
enthaelt "NAS-Daten" "$P" "BACKUP_NAS_IP=203.0.113.7"
enthaelt "Einstellungen der Sicherung" "$P" "BACKUP_KEEP=5"
enthaelt "unveränderter Wert aus --params" "$P" "BACKUP_AGE_RECIPIENTS=age1"
enthaelt_nicht "kein privater Schlüssel" "$P" "AGE-SECRET-KEY"
gelingt "bootstrap-server.sh liest und prüft diese Datei" bash -c "BOOTSTRAP_NUR_FUNKTIONEN=1 . '$BOOT'; set +e; parameter_lesen '$ARBEIT/p.params' && parameter_pruefen"
A_NAS_IP=""; A_NAS_PUBKEY=""
params_schreiben "$ARBEIT/p2.params"
enthaelt_nicht "ohne NAS-Daten keine halben BACKUP_NAS_*-Zeilen" "$(cat "$ARBEIT/p2.params")" "BACKUP_NAS"
gelingt "auch diese Datei besteht die Prüfung von bootstrap-server.sh" bash -c "BOOTSTRAP_NUR_FUNKTIONEN=1 . '$BOOT'; set +e; parameter_lesen '$ARBEIT/p2.params' && parameter_pruefen"
EXTRA=()

echo "== Optionale Parameterdatei (--params)"
ep() { # Inhalt, Modus -> Exit-Code von extra_params_lesen in einer Unterschale
  printf '%s\n' "$1" > "$ARBEIT/e.txt"; chmod "${2:-600}" "$ARBEIT/e.txt"
  ( A_GIT_REF=""; A_SWAP_MB=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""; EXTRA=(); extra_params_lesen "$ARBEIT/e.txt" ) >/dev/null 2>&1
}
gelingt "gültige --params-Datei" ep $'# Kommentar\nGIT_REF=v0.6.5\nSWAP_MB=1024'
scheitert "unbekannter Schlüssel (z. B. ein Netatmo-Geheimnis)" ep 'NETATMO_CLIENT_SECRET=abc'
scheitert "privater age-Schlüssel im Wert" ep 'GIT_REF=AGE-SECRET-KEY-1ABC'
scheitert "Zeile ohne =" ep 'GIT_REF'
scheitert "Datei mit Gruppen-Schreibrecht" ep 'GIT_REF=v1.0.0' 664
gleich "Vorgaben für die Fragen aus --params" "v0.6.5|1024|203.0.113.7" "$(printf 'GIT_REF=v0.6.5\nSWAP_MB=1024\nBACKUP_NAS_IP=203.0.113.7\n' > "$ARBEIT/e2.txt"; chmod 600 "$ARBEIT/e2.txt"; ( A_GIT_REF=""; A_SWAP_MB=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""; EXTRA=(); extra_params_lesen "$ARBEIT/e2.txt"; echo "$A_GIT_REF|$A_SWAP_MB|$A_NAS_IP" ))"
gleich "gemerkte Antworten gehen vor --params" "v0.9.9" "$( ( A_GIT_REF=v0.9.9; A_SWAP_MB=""; A_NAS_IP=""; A_NAS_PUBKEY=""; A_LX_PUBKEY=""; EXTRA=(); extra_params_lesen "$ARBEIT/e2.txt"; echo "$A_GIT_REF" ) )"

echo "== Sicherungsordner"
S="$ARBEIT/sich"; mkdir -p "$S/20261022-033000" "$S/20261021-033000" "$S/ohne-archive" "$S/20261020-033000"
for d in 20261022-033000 20261021-033000; do
  echo db > "$S/$d/db-$d.dump.age"; echo cfg > "$S/$d/config-$d.tar.age"
  ( cd "$S/$d" && sha256sum db-*.age config-*.age > SHA256SUMS )
done
echo db > "$S/20261020-033000/db-20261020-033000.dump.age"   # unvollständig: ohne config und SHA256SUMS
SICHERUNG_BASIS="$S"
sicherungen_finden
gleich "zwei vollständige Sicherungen gefunden, neueste zuerst" "20261022-033000 20261021-033000" "$(for k in "${KANDIDATEN[@]}"; do basename "$k"; done | tr '\n' ' ' | sed 's/ $//')"
enthaelt "Beschreibung nennt die Prüfsummen" "$(sicherung_beschreiben "$S/20261022-033000")" "Prüfsummen ok"
chown -R root:root "$S"; chmod -R go-w "$S"
gelingt "Rechte: root-eigen, keine Schreibrechte für andere" sicherung_rechte_pruefen "$S/20261022-033000"
chmod 664 "$S/20261022-033000/SHA256SUMS"
scheitert "Rechte: gruppenschreibbare Datei" sicherung_rechte_pruefen "$S/20261022-033000"
gleich "Befund: rechte" rechte "$NUR_ROOT_FEHLER"
chmod 644 "$S/20261022-033000/SHA256SUMS"; ln -s "$S/20261022-033000/SHA256SUMS" "$S/20261022-033000/link"
scheitert "Rechte: Symlink im Ordner" sicherung_rechte_pruefen "$S/20261022-033000"
gleich "Befund: symlink" symlink "$NUR_ROOT_FEHLER"
rm -f "$S/20261022-033000/link"
echo manipuliert >> "$S/20261021-033000/config-20261021-033000.tar.age"
enthaelt "geänderte Datei: Prüfsummen FALSCH" "$(sicherung_beschreiben "$S/20261021-033000")" "PRÜFSUMMEN FALSCH"
scheitert "geänderte Datei wird nicht übernommen" bash -c "UMZUG_NUR_FUNKTIONEN=1 . '$SKRIPT'; sicherung_uebernehmen '$S/20261021-033000'"
cp -r "$S/20261022-033000" "$S/unvollstaendig"; ( cd "$S/unvollstaendig" && sha256sum db-*.age > SHA256SUMS ); chown -R root:root "$S"; chmod -R go-w "$S"
enthaelt "Archiv fehlt in SHA256SUMS: nicht 'Prüfsummen ok'" "$(sicherung_beschreiben "$S/unvollstaendig")" "PRÜFSUMMEN FALSCH"
scheitert "Archiv fehlt in SHA256SUMS: wird nicht übernommen" bash -c "UMZUG_NUR_FUNKTIONEN=1 . '$SKRIPT'; sicherung_uebernehmen '$S/unvollstaendig'"
rm -rf "$S/unvollstaendig"
gelingt "unveränderte Sicherung wird übernommen" bash -c "UMZUG_NUR_FUNKTIONEN=1 . '$SKRIPT'; sicherung_uebernehmen '$S/20261022-033000'"

echo "== Schlüsselprüfung und Konfiguration (mit echtem age)"
if command -v age >/dev/null && command -v age-keygen >/dev/null; then
  age-keygen -o "$ARBEIT/k1.txt" >/dev/null 2>&1; age-keygen -o "$ARBEIT/k2.txt" >/dev/null 2>&1
  PUB1="$(age-keygen -y "$ARBEIT/k1.txt")"
  KEY1="$(grep '^AGE-SECRET-KEY-1' "$ARBEIT/k1.txt")"; KEY2="$(grep '^AGE-SECRET-KEY-1' "$ARBEIT/k2.txt")"
  CFGW="$ARBEIT/cfgw"; mkdir -p "$CFGW/etc/lx-fampad" "$CFGW/etc/lx-fampad-backup" "$CFGW/srv/fampad/releases/android"
  # die Geheimnisse stehen nur als Text in der Datei (nie in einer Variable des Tests), damit die Prüfung der Variablen unten aussagekräftig ist
  printf 'PUBLIC_URL=https://familie.lx-labs.dev\nAUTH_SECRET_KEY=GEHEIMER-WERT-AUTH-123456789\nWEATHER_ENABLED=true\nWASTE_ENABLED=true\nWASTE_ICS_URL=https://abfall.example.org/?key=GEHEIMER-LINK-KEY\nDATABASE_URL=postgres://u:PW-GEHEIM-1234@127.0.0.1/db\n' > "$CFGW/etc/lx-fampad/env"
  printf 'KEEP=5\nINCLUDE_APK=0   # Kommentar\nINCLUDE_FILES=1\nUNSINN=ls\n' > "$CFGW/etc/lx-fampad-backup/backup.conf"
  printf '{"payload":"{\\"packageName\\":\\"dev.x\\",\\"version\\":\\"0.9.0\\",\\"versionCode\\":9,\\"minVersion\\":\\"0.0.0\\"}","signature":"abc"}' > "$CFGW/srv/fampad/releases/android/latest.json"
  ( cd "$CFGW" && tar -czf - etc srv ) | age -r "$PUB1" -o "$ARBEIT/config-20261022-033000.tar.age"
  { printf 'PGDMP'; head -c 2000 /dev/urandom; } | age -r "$PUB1" -o "$ARBEIT/db-20261022-033000.dump.age"
  DB_ARCHIV="$ARBEIT/db-20261022-033000.dump.age"; CFG_ARCHIV="$ARBEIT/config-20261022-033000.tar.age"
  AGE_ID="$KEY1"; gelingt "richtiger Schlüssel passt zur Sicherung" schluessel_passt
  AGE_ID="$KEY2"; scheitert "falscher Schlüssel passt nicht" schluessel_passt
  AGE_ID="not-a-key"; scheitert "Unsinn als Schlüssel passt nicht" schluessel_passt
  AGE_ID="$KEY1"
  A_WETTER=""; A_MUELL=""; A_MUELL_LINK=""; A_KEEP=""; A_APK=""; A_FILES=""; CFG_VERSION=""
  config_auswerten
  gleich "Wetter war aktiv" 1 "$A_WETTER"; gleich "Müll war aktiv" 1 "$A_MUELL"; gleich "Müll-Link war gesetzt" 1 "$A_MUELL_LINK"
  gleich "App-Version aus dem Update-Kanal" 0.9.0 "$CFG_VERSION"
  gleich "Einstellungen der Sicherung: behalte" 5 "$A_KEEP"; gleich "APK (mit Kommentar am Zeilenende)" 0 "$A_APK"; gleich "Dateiablage" 1 "$A_FILES"
  VARS="$(declare -p)"
  enthaelt_nicht "kein AUTH_SECRET_KEY aus der Konfiguration in den Variablen des Assistenten" "$VARS" "GEHEIMER-WERT-AUTH"
  enthaelt_nicht "kein Link des Abfallkalenders in den Variablen" "$VARS" "GEHEIMER-LINK-KEY"
  enthaelt_nicht "kein Datenbank-Passwort in den Variablen" "$VARS" "PW-GEHEIM-1234"
  # falsche Domain in der Sicherung
  printf 'PUBLIC_URL=https://fremd.example.org\nAUTH_SECRET_KEY=x\n' > "$CFGW/etc/lx-fampad/env"
  ( cd "$CFGW" && tar -czf - etc srv ) | age -r "$PUB1" -o "$ARBEIT/config-fremd.tar.age"
  FREMD="$( ( CFG_ARCHIV="$ARBEIT/config-fremd.tar.age"; AGE_ID="$KEY1"; OPT_PROBE=1; config_auswerten ) 2>&1; echo "RC=$?" )"
  enthaelt "Sicherung einer anderen Domain wird abgelehnt (Exit-Code 1)" "$FREMD" "RC=1"
  enthaelt "Meldung nennt die Domain" "$FREMD" "nicht zu https://familie.lx-labs.dev"
  AGE_ID=""
else uebersprungen "Schlüsselprüfung und Konfiguration" "age fehlt"; fi

echo "== Bericht ohne Geheimnisse und Liste"
A_SICHERUNG=/root/sicherung/20261022-033000; A_GIT_REF=v0.9.0; A_SWAP_MB=0; A_FERTIG="pruefen"
printf '==> Phase 2/11: pakete\n    Prüfpunkt ok: PostgreSQL\nFEHLER: pg_restore fehlgeschlagen\npg_restore: COPY users (name) Anna Mustermann Passwort-Hash\nAGE-SECRET-KEY-1ABCDEF steht im Log\n    OFFEN: DNS postgres://user:pw123@host/db tk_ABCDEF123\n' > "$LAUF_LOG"
bericht_schreiben "Phase fehlgeschlagen" "Maßnahme"
B="$(cat "$BERICHT_DATEI")"
gleich "Bericht: Modus 600" 600 "$(stat -c %a "$BERICHT_DATEI")"
enthaelt "Bericht nennt Ursache" "$B" "Phase fehlgeschlagen"
enthaelt "Bericht enthält die eigenen Meldungen von bootstrap-server.sh" "$B" "FEHLER: pg_restore fehlgeschlagen"
enthaelt_nicht "Bericht enthält keine Programmausgaben (mögliche Personendaten)" "$B" "Mustermann"
enthaelt_nicht "Bericht enthält keinen Schlüssel" "$B" "AGE-SECRET-KEY"
enthaelt_nicht "Bericht enthält kein Passwort aus einer URL" "$B" "pw123"
enthaelt_nicht "Bericht enthält kein ntfy-Token" "$B" "tk_ABCDEF123"
fehlermassnahme "Swap ist aktiv (/proc/swaps)" | grep -q swapoff && ok "Maßnahme zu Swap" || fehl "Maßnahme zu Swap"
fehlermassnahme "Prüfsummen stimmen nicht: die Sicherung" | grep -q "beschädigt" && ok "Maßnahme zu Prüfsummen" || fehl "Maßnahme zu Prüfsummen"
fehlermassnahme "" | grep -q "denselben Befehl" && ok "allgemeine Maßnahme nennt den Neustart" || fehl "allgemeine Maßnahme"

HINWEISE=("WEBAUTHN_ORIGINS fehlt (Beispiel)" "Die neue Sicherung ist UNGEPRÜFT, bis du ..."); A_IP=203.0.113.10; IP_V6=""
A_WETTER=1; A_MUELL=0; A_MUELL_LINK=0; A_NAS_IP=203.0.113.7; A_ERLEDIGT="caddy"
liste_bauen
L="$(printf '%s\n' "${LISTE[@]}")"
enthaelt "Liste: neue IP bei den DNS-Einträgen" "$L" "familie        A   203.0.113.10"
enthaelt "Liste: ntfy.familie als A-Eintrag" "$L" "ntfy.familie   A   203.0.113.10"
enthaelt "Liste: Kontrollbefehl dig" "$L" "dig +short familie.lx-labs.dev"
enthaelt "Liste: Caddy-Schritt mit --weiter caddy und Vermerk erledigt" "$L" "--weiter caddy"
enthaelt "Liste: Caddy als erledigt markiert" "$L" "(erst nach [2]!)   -> erledigt"
enthaelt "Liste: Web-App" "$L" "deploy/deploy-web.sh"
enthaelt "Liste: NAS neu verbinden" "$L" "ssh-keygen -R familie.lx-labs.dev"
enthaelt "Liste: Wetter-Dienst" "$L" "--weiter wetter"
enthaelt_nicht "Liste: kein Müll-Schritt, wenn Müll nicht aktiv war" "$L" "--weiter muell"
enthaelt "Liste: Wiederherstellungstest" "$L" "wiederherstellung-test.sh"
enthaelt "Liste: Hinweis des Aufbaus" "$L" "WEBAUTHN_ORIGINS fehlt"
enthaelt_nicht "Liste: doppelte Hinweise (Sicherung ungeprüft) fehlen" "$L" "UNGEPRÜFT"
enthaelt_nicht "Liste: keine Geheimnisse" "$L" "AGE-SECRET-KEY"
A_MUELL=1; A_MUELL_LINK=1; A_NAS_IP=""
liste_bauen; L="$(printf '%s\n' "${LISTE[@]}")"
enthaelt "Liste: Müll-Dienst, wenn Müll aktiv war" "$L" "--weiter muell"
enthaelt "Liste: Müll-Link steht schon in der Konfiguration" "$L" "Link des Abfallkalenders steht in der gesicherten Konfiguration"
enthaelt "Liste: ohne NAS-Daten der Nachholschritt" "$L" "NAS-Abholung nachholen"
liste_schreiben
gleich "Listendatei: Modus 600" 600 "$(stat -c %a "$OFFEN_DATEI")"
enthaelt "Listendatei enthält die Liste" "$(cat "$OFFEN_DATEI")" "DNS bei Cloudflare umstellen"

echo "== Aufbau, Neustart und Swap (reine Logik)"
# Swap bei Wiederaufnahme (SWAPS_DATEI-Attrappe): --swap-ok nur, wenn die Option da ist oder Swap läuft UND kein Schlüssel nötig/im Speicher ist
printf 'Filename Type Size Used Priority\n/swapfile file 1048572 0 -2\n' > "$ARBEIT/swaps-an"; printf 'Filename Type Size Used Priority\n' > "$ARBEIT/swaps-aus"
PARAMS_PFAD="$ARBEIT/x.params"; OPT_SWAP_OK=0; AGE_ID=""
SWAPS_DATEI="$ARBEIT/swaps-an"
A_FERTIG="pruefen,pakete,system,code,konfiguration,datenbank,anwendung"
bootstrap_basis; enthaelt "Wiederaufnahme nach der Phase anwendung mit laufendem Swap: --swap-ok wird durchgereicht (kein Schlüssel nötig)" "${BA[*]}" "--swap-ok"
A_FERTIG="pruefen,pakete,system"
bootstrap_basis; enthaelt_nicht "solange der Schlüssel nötig ist: kein stilles --swap-ok" "${BA[*]}" "--swap-ok"
A_FERTIG="pruefen,pakete,system,code,konfiguration,datenbank,anwendung"; AGE_ID="x"
bootstrap_basis; enthaelt_nicht "Schlüssel im Speicher (neue Sicherung einspielen): kein stilles --swap-ok" "${BA[*]}" "--swap-ok"
AGE_ID=""; SWAPS_DATEI="$ARBEIT/swaps-aus"
bootstrap_basis; enthaelt_nicht "ohne Swap kein --swap-ok" "${BA[*]}" "--swap-ok"
OPT_SWAP_OK=1; bootstrap_basis; enthaelt "mit der Option immer --swap-ok" "${BA[*]}" "--swap-ok"; OPT_SWAP_OK=0
SWAPS_DATEI="$ARBEIT/swaps-an"; A_FERTIG=""
gelingt "swap_aktiv erkennt die Attrappe" swap_aktiv
SWAPS_DATEI="$ARBEIT/swaps-aus"; scheitert "ohne Swap meldet swap_aktiv nichts" swap_aktiv
SWAPS_DATEI="$ARBEIT/gibtsnicht"; gelingt "nicht lesbare /proc/swaps gilt als aktiv (fail-closed)" swap_aktiv
SWAPS_DATEI=/proc/swaps
# --neu: die Antworten verfallen, der Stand des Aufbaus bleibt (sonst blockiert Schritt 1 den halb eingerichteten Server)
A_SICHERUNG=/root/sicherung/x; A_GIT_REF=v0.9.0; A_SWAP_MB=1024; A_FRAGEN=1; A_FERTIG="pruefen,pakete,system,code,konfiguration,datenbank,anwendung"; A_ERLEDIGT="caddy,wetter"; A_WETTER=1; A_PARAMS=/root/p; HINWEISE=("h1")
antworten_neu_beginnen
gleich "--neu: Antworten verworfen (Sicherung)" "" "$A_SICHERUNG"; gleich "--neu: Fragen verworfen" "" "$A_FRAGEN"; gleich "--neu: Pfad der Parameterdatei verworfen" "" "$A_PARAMS"
gleich "--neu: Stand des Aufbaus bleibt" "pruefen,pakete,system,code,konfiguration,datenbank,anwendung" "$A_FERTIG"
gleich "--neu: erledigte Folgeschritte bleiben" "caddy,wetter" "$A_ERLEDIGT"; gleich "--neu: Schalter aus der Konfiguration bleiben" 1 "$A_WETTER"; gleich "--neu: Hinweise bleiben" h1 "${HINWEISE[0]}"
gleich "--neu merkt sich den bisherigen Code-Stand" v0.9.0 "$GIT_REF_VORHER"
# anderer Code-Stand: code, anwendung und alles danach laufen noch einmal, konfiguration und datenbank bleiben
A_GIT_REF=v0.9.1; A_FERTIG="pruefen,pakete,system,code,konfiguration,datenbank,anwendung,ntfy,caddy,sicherung,pruefung"; A_ERLEDIGT="caddy,wetter"
code_stand_wechsel_pruefen v0.9.0 >/dev/null
gleich "anderer Code-Stand: Stand des Aufbaus ab code zurückgesetzt" "pruefen,pakete,system,konfiguration,datenbank" "$A_FERTIG"
gleich "anderer Code-Stand: caddy nicht mehr als erledigt" "wetter" "$A_ERLEDIGT"
A_FERTIG="pruefen,pakete"; code_stand_wechsel_pruefen v0.9.0 >/dev/null
gleich "anderer Code-Stand, aber code noch nicht gelaufen: nichts zu tun" "pruefen,pakete" "$A_FERTIG"
A_FERTIG="pruefen,pakete,system,code,konfiguration,datenbank,anwendung"; A_GIT_REF=v0.9.0; code_stand_wechsel_pruefen v0.9.0 >/dev/null
gleich "gleicher Code-Stand: nichts zurückgesetzt" "pruefen,pakete,system,code,konfiguration,datenbank,anwendung" "$A_FERTIG"
A_FERTIG=""; A_ERLEDIGT=""; A_PARAMS=""; HINWEISE=()
# Pfad der --params-Datei wird gemerkt (nicht der Inhalt) und beim Neustart wieder gelesen
printf 'CI_DEPLOY_PUBKEY=%s\nBACKUP_NAS_IP=203.0.113.7\n' "$SSHOK" > "$ARBEIT/mem.params"; chmod 600 "$ARBEIT/mem.params"
EXTRA=(); OPT_PARAMS="$ARBEIT/mem.params"; extra_params_einbinden >/dev/null; OPT_PARAMS=""
gleich "--params: Pfad wird in den Antworten gemerkt" "$ARBEIT/mem.params" "$A_PARAMS"
antworten_schreiben; enthaelt "gemerkter Pfad steht in der Antwortdatei" "$(cat "$ANTWORTEN_DATEI")" "PARAMS=$ARBEIT/mem.params"
enthaelt_nicht "der Inhalt der --params-Datei steht NICHT in der Antwortdatei" "$(cat "$ANTWORTEN_DATEI")" "CI_DEPLOY_PUBKEY"
antworten_zuruecksetzen; EXTRA=(); antworten_lesen; extra_params_einbinden >/dev/null
gleich "Neustart ohne Option: Parameterdatei wird aus dem gemerkten Pfad gelesen" "$SSHOK" "${EXTRA[CI_DEPLOY_PUBKEY]:-}"
params_schreiben "$ARBEIT/mem2.params"; enthaelt "Wert aus der gemerkten Parameterdatei landet in der Datei für bootstrap" "$(cat "$ARBEIT/mem2.params")" "CI_DEPLOY_PUBKEY="
A_PARAMS="$ARBEIT/weg.params"; EXTRA=(); HINT="$(extra_params_einbinden 2>&1)"
enthaelt "fehlende gemerkte Parameterdatei: deutlicher Hinweis" "$HINT" "gibt es nicht mehr"
A_PARAMS=""; EXTRA=(); rm -f "$ANTWORTEN_DATEI"

echo "== Steuerzeichen und Kürzung"
gleich "sauber entfernt Escape-Folgen" "FEHLER: x[31m" "$(sauber $'FEHLER: x\033[31m')"
hinweis_merken $'Hinweis mit \033[2J Escape und\ttab'; gleich "hinweis_merken: Steuerzeichen entfernt" "Hinweis mit [2J Escape undtab" "${HINWEISE[0]}"
LANG_T="$(printf 'ä%.0s' {1..700})"; HINWEISE=(); hinweis_merken "$LANG_T"
gleich "hinweis_merken kürzt nach Zeichen (nicht Bytes): 600 Zeichen" 600 "${#HINWEISE[0]}"
HINWEISE=()
B2="$(BERICHT_DATEI="$ARBEIT/b2.txt"; bericht_schreiben $'Ursache mit \033[31m Escape und AGE-SECRET-KEY-1ABCDEF' "Maßnahme"; cat "$ARBEIT/b2.txt")"
enthaelt_nicht "Bericht: keine Escape-Zeichen in der Ursache" "$B2" $'\033'
enthaelt_nicht "Bericht: Schlüssel in der Ursache wird entfernt" "$B2" "AGE-SECRET-KEY-1ABCDEF"
enthaelt "Bericht weist auf Pfade und Adressen hin" "$B2" "mit Pfaden, IP-Adressen"

echo "== Absicherung (xtrace, --probe --neu, falsche Reihenfolge)"
XT="$(env -u UMZUG_NUR_FUNKTIONEN bash -x "$SKRIPT" --probe 2>&1 >/dev/null)"; XT_RC=$(env -u UMZUG_NUR_FUNKTIONEN bash -x "$SKRIPT" --probe >/dev/null 2>&1; echo $?)
gleich "bash -x wird abgelehnt (Exit-Code 2)" 2 "$XT_RC"
enthaelt "Meldung nennt xtrace" "$XT" "xtrace"
gleich "BASH_XTRACEFD wird abgelehnt (Exit-Code 2)" 2 "$(BASH_XTRACEFD=9 env -u UMZUG_NUR_FUNKTIONEN bash "$SKRIPT" --probe 9>/dev/null >/dev/null 2>&1; echo $?)"
gleich "--probe --neu: Exit-Code 2" 2 "$(a --probe --neu >/dev/null 2>&1; echo $?)"
gleich "--aktualisieren --probe: Exit-Code 2" 2 "$(a --aktualisieren --probe >/dev/null 2>&1; echo $?)"
gleich "--weiter zusammen mit --aktualisieren: Exit-Code 2" 2 "$(a --weiter caddy --aktualisieren >/dev/null 2>&1; echo $?)"
# --weiter ohne vorherigen Lauf: Exit-Code 1 mit klarer Meldung (Skripte liegen root-eigen in einem Wegwerf-Ordner)
mkdir -p "$ARBEIT/lauf"; install -m 700 "$SKRIPT" "$ARBEIT/lauf/umzug.sh"; install -m 700 "$BOOT" "$ARBEIT/lauf/bootstrap-server.sh"
W1="$(env -u UMZUG_NUR_FUNKTIONEN bash "$ARBEIT/lauf/umzug.sh" --weiter caddy 2>&1)"; W1_RC=$?
gleich "--weiter ohne gemerkte Antworten: Exit-Code 1" 1 "$W1_RC"
enthaelt "Meldung: noch kein Lauf des Assistenten" "$W1" "noch keinen Lauf"
rm -f /root/umzug-bericht.txt
# Kopplung an bootstrap-server.sh: fehlt eine genutzte Funktion, bricht der Assistent hart ab
mkdir -p "$ARBEIT/alt"; install -m 700 "$SKRIPT" "$ARBEIT/alt/umzug.sh"; printf "SSH_KEY_RE='^ssh-ed25519 '\n" > "$ARBEIT/alt/bootstrap-server.sh"; chmod 700 "$ARBEIT/alt/bootstrap-server.sh"
K1="$(env -u UMZUG_NUR_FUNKTIONEN bash "$ARBEIT/alt/umzug.sh" --weiter pruefung 2>&1)"; K1_RC=$?
gleich "bootstrap-server.sh ohne dns_pruefen: Exit-Code 1" 1 "$K1_RC"
enthaelt "Meldung: nicht zum selben Stand" "$K1" "nicht zum selben Stand"
rm -f /root/umzug-bericht.txt
# umzug.sh führt nur die geprüfte Kopie aus: die Kopie liegt im Arbeitsverzeichnis, die Originaldatei wird danach nicht mehr gelesen
gelingt "bootstrap_pruefen kopiert nach ARBEIT_DIR und setzt BOOTSTRAP auf die Kopie" bash -c "UMZUG_NUR_FUNKTIONEN=1 . '$SKRIPT'; ARBEIT_DIR='$ARBEIT/kopie'; mkdir -p \"\$ARBEIT_DIR\"; chmod 700 \"\$ARBEIT_DIR\"; BOOTSTRAP_ORIG='$ARBEIT/lauf/bootstrap-server.sh'; UMZUG_PFAD='$ARBEIT/lauf/umzug.sh'; bootstrap_pruefen && [ \"\$BOOTSTRAP\" = '$ARBEIT/kopie/bootstrap-server.sh' ] && cmp -s '$BOOT' \"\$BOOTSTRAP\" && [ \"\$(stat -c %a \"\$BOOTSTRAP\")\" = 700 ]"

echo "== Gegenprobe mit gefälschtem bootstrap (PROBLEM-Zeilen)"
cat > "$ARBEIT/fake-boot.sh" <<'EOF'
#!/usr/bin/env bash
echo "    PROBLEM: zu wenig Platz (Beispiel)" >&2
echo "    PROBLEM: Netz nicht erreichbar \033[31m"  >&2
exit 1
EOF
BOOTSTRAP="$ARBEIT/fake-boot.sh"; PARAMS_PFAD="$ARBEIT/x.params"; A_SICHERUNG="$ARBEIT/sich"; A_FERTIG=""
gegenprobe
gleich "Gegenprobe sammelt beide PROBLEM-Zeilen" 2 "${#PROBLEME[@]}"
enthaelt "Gegenprobe: Text der ersten Zeile" "${PROBLEME[0]}" "zu wenig Platz"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ARBEIT/fake-boot.sh"; gegenprobe
gleich "Fehler ohne PROBLEM-Zeile wird trotzdem gemeldet" 1 "${#PROBLEME[@]}"
BOOTSTRAP="$BOOT"

echo "== Fehlermeldungen passen zu den Texten von bootstrap-server.sh"
mm() { # bootstrap-Text-Auszug (muss im Skript stehen) -> die Maßnahme darf nicht die allgemeine sein
  grep -qF -- "$1" "$BOOT" || { fehl "Text steht nicht mehr in bootstrap-server.sh: $1"; return; }
  if fehlermassnahme "$1" | grep -q "Behebe die Ursache laut Meldung"; then fehl "keine eigene Maßnahme für: $1"; else ok "eigene Maßnahme für: $1"; fi
}
mm "Swap aktiv"; mm "Swap ist aktiv"; mm "nicht lesen oder ist kein pg_dump"; mm "Prüfsummen stimmen nicht"; mm "muss root gehören"; mm "PUBLIC_URL der Sicherung"; mm "deploy.sh fehlgeschlagen"
mm "GIT_REF '"; mm "weicht von der Sicherung ab"
enthaelt "deploy.sh-Fehler (nennt auch GIT_REF) bekommt die Migrations-Maßnahme, nicht die Tag-Maßnahme" "$(fehlermassnahme "deploy.sh fehlgeschlagen (Meldungen oben; häufig: Migration passt nicht zum Code-Stand, GIT_REF prüfen)")" "journalctl"
enthaelt "Maßnahme zu Tag/Migration nennt \"Code-Stand ändern?\"" "$(fehlermassnahme "GIT_REF 'v9' nicht gefunden")" "Code-Stand ändern?"
enthaelt_nicht "Maßnahmen verweisen nicht mehr auf --neu zum Ändern des Tags" "$(fehlermassnahme "GIT_REF 'v9' nicht gefunden")" "--neu"

echo "== Kopplung an bootstrap-server.sh (Listen und Version)"
gleich "PHASEN stimmen mit bootstrap-server.sh überein" "$(bash -c "BOOTSTRAP_NUR_FUNKTIONEN=1 . '$BOOT'; echo \"\${PHASEN[*]}\"")" "${PHASEN[*]}"
BP="$(grep -E '^ +GIT_REPO_URL[|]' "$BOOT" | tr -d ' ' | sed 's/)$//' | tr '|' ' ')"
gleich "PARAM_SCHLUESSEL stimmen mit den erlaubten Schlüsseln von bootstrap-server.sh überein" " $BP " "$PARAM_SCHLUESSEL"
for p in ${SCHLUESSEL_PHASEN//,/ }; do
  gelingt "phase_$p ruft restore_bereit auf (Schlüssel nötig)" bash -c "sed -n '/^phase_$p() {/,/^}/p' '$BOOT' | grep -q restore_bereit"
done
for p in ${BIS_DATENBANK//,/ }; do liste_enthaelt "pruefen,pakete,system,code,konfiguration,datenbank" "$p" || fehl "BIS_DATENBANK: $p"; done
gleich "BIS_DATENBANK endet mit datenbank (die Phase, nach der der Schlüssel verworfen wird)" datenbank "${BIS_DATENBANK##*,}"
for p in ${NACH_CODE//,/ }; do gelingt "NACH_CODE: $p ist eine Phase" bash -c "BOOTSTRAP_NUR_FUNKTIONEN=1 . '$BOOT'; [[ \" \${PHASEN[*]} \" == *\" $p \"* ]]"; done
if [ -f "$HIER/../../app/pubspec.yaml" ]; then
  gleich "UMZUG_VERSION stimmt mit app/pubspec.yaml überein (bei jedem Release mitziehen)" "$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$HIER/../../app/pubspec.yaml" | head -n 1)" "$UMZUG_VERSION"
else uebersprungen "UMZUG_VERSION gegen pubspec.yaml" "app/pubspec.yaml nicht erreichbar"; fi
# Der Weg "DNS stimmt" mit gefälschten ip/getent (ohne --dns-pruefung-ueberspringen): bootstrap-server.sh setzt PATH selbst, die Attrappen liegen darum in /usr/local/sbin
cat > /usr/local/sbin/ip <<'EOF'
#!/bin/sh
case "$*" in
  *"addr show scope global"*) echo "2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0" ;;
  *) exit 0 ;;
esac
EOF
cat > /usr/local/sbin/getent <<'EOF'
#!/bin/sh
case "$1" in
  ahostsv4) echo "${FAKE_A:-203.0.113.10}      STREAM $2" ;;
  ahostsv6) : ;;
esac
EOF
chmod 755 /usr/local/sbin/ip /usr/local/sbin/getent
OPT_DNS_SKIP=0
gleich "dns_ok: A-Eintrag zeigt auf diesen Server" ok "$(bootstrap_dns familie.lx-labs.dev)"
gelingt "dns_ok (ohne Überspringen) für beide Domains" bash -c "UMZUG_NUR_FUNKTIONEN=1 . '$SKRIPT'; OPT_DNS_SKIP=0; dns_ok familie.lx-labs.dev && dns_ok ntfy.familie.lx-labs.dev"
gleich "plan_bauen: bei passendem DNS läuft Caddy im Hauptlauf mit" 1 "$( A_FERTIG=""; plan_bauen; echo "$CADDY_JETZT" )"
gleich "dns_ok: Eintrag zeigt woanders hin -> nicht ok" "zeigt auf 198.51.100.9 (keine globale Adresse dieses Servers)" "$(FAKE_A=198.51.100.9 bootstrap_dns familie.lx-labs.dev)"
gleich "plan_bauen: bei falschem DNS wird Caddy auf später verschoben" 0 "$( A_FERTIG=""; FAKE_A=198.51.100.9 plan_bauen; echo "$CADDY_JETZT" )"
rm -f /usr/local/sbin/ip /usr/local/sbin/getent

echo "== sudo-Regel für den Müll-Dienst"
if command -v visudo >/dev/null; then
  printf 'lx ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-fampad\n' > "$ARBEIT/sudoers"; ARBEIT_DIR="$ARBEIT"
  SUDOERS_DATEI="$ARBEIT/sudoers" sudoers_muell_ergaenzen >/dev/null
  enthaelt "Müll-Regel wird an die vorhandene Regel angehängt" "$(cat "$ARBEIT/sudoers")" "restart lx-fampad-waste"
  gelingt "ergänzte sudoers-Datei ist gültig" visudo -cf "$ARBEIT/sudoers"
  SUDOERS_DATEI="$ARBEIT/sudoers" sudoers_muell_ergaenzen >/dev/null
  gleich "zweiter Aufruf ändert nichts (nur eine Regel)" 1 "$(grep -c 'restart lx-fampad-waste' "$ARBEIT/sudoers")"
  printf 'lx ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-fampad, /usr/bin/systemctl restart lx-fampad-weather\n' > "$ARBEIT/sudoers"
  SUDOERS_DATEI="$ARBEIT/sudoers" sudoers_muell_ergaenzen >/dev/null
  enthaelt "mit Wetter-Regel: beide bleiben, Müll kommt dazu" "$(cat "$ARBEIT/sudoers")" "restart lx-fampad-weather, /usr/bin/systemctl restart lx-fampad-waste"
  ARBEIT_DIR=""
else uebersprungen "sudo-Regel für den Müll-Dienst" "visudo fehlt in diesem Container (Szenario C prüft es mit sudo)"; fi

echo "== Konfiguration: nicht lesbar oder leer"
if command -v age >/dev/null && command -v age-keygen >/dev/null; then
  # Konfigurationsarchiv nur für einen anderen Schlüssel (BACKUP_AGE_RECIPIENTS_CONFIG): der Datenbank-Schlüssel kann es nicht öffnen
  DB_ARCHIV="$ARBEIT/db-20261022-033000.dump.age"; CFG_ARCHIV="$ARBEIT/config-nurk2.tar.age"
  ( cd "$CFGW" && tar -czf - etc srv ) | age -r "$(age-keygen -y "$ARBEIT/k2.txt")" -o "$CFG_ARCHIV"
  AGE_ID="$KEY1"
  scheitert "Datenbank passt, Konfiguration ist für einen anderen Schlüssel: nicht lesbar" konfiguration_lesbar
  gelingt "...aber der Datenbank-Schlüssel passt" schluessel_passt
  KL="$( ( OPT_PROBE=1; SWAPS_DATEI="$ARBEIT/swaps-aus"; frage_schluessel ) 2>&1 < <(printf '%s\n' "$KEY1"); echo "RC=$?" )"
  enthaelt "frage_schluessel bricht früh ab (Exit-Code 1)" "$KL" "RC=1"
  enthaelt "Meldung nennt das Konfigurationsarchiv" "$KL" "Konfigurationsarchiv lässt sich nicht öffnen"
  enthaelt_nicht "es wird NICHT behauptet, die Konfiguration lasse sich öffnen" "$KL" "Datenbank und Konfiguration lassen sich öffnen"
  # leere env: etc/lx-fampad/env nicht im Archiv
  mkdir -p "$ARBEIT/cfgleer/etc/lx-fampad-backup"; echo x > "$ARBEIT/cfgleer/etc/lx-fampad-backup/backup.conf"
  ( cd "$ARBEIT/cfgleer" && tar -czf - etc ) | age -r "$PUB1" -o "$ARBEIT/config-leer.tar.age"
  CFG_ARCHIV="$ARBEIT/config-leer.tar.age"; AGE_ID="$KEY1"
  scheitert "Konfigurationsarchiv ohne env: nicht lesbar" konfiguration_lesbar
  A_WETTER=1; A_MUELL=1; A_MUELL_LINK=1; config_auswerten
  gleich "config_auswerten setzt Wetter nicht, wenn die env nicht gelesen wurde" 1 "$A_WETTER"
  gleich "config_auswerten setzt Müll nicht, wenn die env nicht gelesen wurde" 1 "$A_MUELL"
  A_WETTER=""; A_MUELL=""; A_MUELL_LINK=""
  AGE_ID=""
else uebersprungen "Konfiguration nicht lesbar" "age fehlt"; fi

echo "== Ausgabe ohne Terminal"
gleich "liste_ausgeben ohne Escape-Codes (nicht auf einem Terminal)" 0 "$(liste_ausgeben | grep -c $'\033')"
gleich "NO_COLOR schaltet Farben ab" "" "$(NO_COLOR=1 farben_init; printf '%s' "$C_G")"

echo
echo "Ergebnis: $OK ok, $FEHL fehlgeschlagen, $UEBERSPRUNGEN übersprungen"
[ "$FEHL" -eq 0 ]
