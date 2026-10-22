#!/usr/bin/env bash
# Tests der Hilfsfunktionen und des Trockenlaufs von bootstrap-server.sh. Verändert nichts außerhalb eines Wegwerf-Ordners.
# Läuft als root (chown in den Hilfen), mit bash 5, age, tar, python3, awk. Am einfachsten im Debian-13-Container:
#   deploy/neuinstallation/test-docker.sh          (siehe dort)
# Aufruf direkt:   bash deploy/neuinstallation/test-bootstrap.sh
# shellcheck disable=SC2034,SC2015,SC2016
# (SC2034: P_*/AGE_ID/REPO werden von den eingelesenen Funktionen benutzt; SC2015/SC2016: Absicht in den Testzeilen)
set -uo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKRIPT="$HIER/bootstrap-server.sh"
REPO_WURZEL="$(cd "$HIER/../.." && pwd)"
ARBEIT="$(mktemp -d)"
trap 'rm -rf "$ARBEIT"' EXIT
OK=0; FEHL=0; UEBERSPRUNGEN=0

ok() { OK=$((OK + 1)); echo "  ok    $1"; }
fehl() { FEHL=$((FEHL + 1)); echo "  FEHLT $1"; }
uebersprungen() { UEBERSPRUNGEN=$((UEBERSPRUNGEN + 1)); echo "  --    $1 (übersprungen: $2)"; }
# erwartet(Text, erwarteter Wert, tatsächlicher Wert)
gleich() { if [ "$2" = "$3" ]; then ok "$1"; else fehl "$1 (erwartet '$2', erhalten '$3')"; fi; }
# gelingt(Text, Befehl...) / scheitert(Text, Befehl...)
gelingt() { local t="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$t"; else fehl "$t"; fi; }
scheitert() { local t="$1"; shift; if "$@" >/dev/null 2>&1; then fehl "$t (hätte scheitern müssen)"; else ok "$t"; fi; }
hat_werkzeug() { command -v "$1" >/dev/null 2>&1; }

# Skript einlesen, ohne es auszuführen
export BOOTSTRAP_NUR_FUNKTIONEN=1
# shellcheck disable=SC1090
. "$SKRIPT"
set +e +E
trap - ERR
TMP_ARBEIT="$ARBEIT"

echo "== Syntax"
gelingt "bash -n" bash -n "$SKRIPT"
gelingt "bash -n deploy.sh" bash -n "$REPO_WURZEL/deploy/deploy.sh"

echo "== Aufruf und Optionen"
a() { env -u BOOTSTRAP_NUR_FUNKTIONEN bash "$SKRIPT" "$@"; }
scheitert "unbekannte Option -> Exit 2" a --gibtsnicht
gleich "unbekannte Option Exit-Code" 2 "$(a --gibtsnicht >/dev/null 2>&1; echo $?)"
gleich "--sicherung ohne Schlüssel Exit-Code" 2 "$(a --sicherung /tmp >/dev/null 2>&1; echo $?)"
gleich "--identity ohne --sicherung Exit-Code" 2 "$(a --identity-stdin >/dev/null 2>&1; echo $?)"
gleich "--phase und --ab zusammen Exit-Code" 2 "$(a --phase pruefen --ab caddy >/dev/null 2>&1; echo $?)"
gleich "unbekannte Phase Exit-Code" 2 "$(a --phase gibtsnicht >/dev/null 2>&1; echo $?)"
gleich "--identity-datei-loeschen ohne Datei Exit-Code" 2 "$(a --identity-datei-loeschen >/dev/null 2>&1; echo $?)"
gleich "--dns-pruefung-ueberspringen ohne --ohne-systemd Exit-Code" 2 "$(a --dns-pruefung-ueberspringen >/dev/null 2>&1; echo $?)"
gleich "--identity-datei-loeschen außerhalb von /dev/shm und /run Exit-Code" 2 "$(a --sicherung /tmp --identity-datei /tmp/x --identity-datei-loeschen >/dev/null 2>&1; echo $?)"
gelingt "--hilfe nennt die Phasen" bash -c "env -u BOOTSTRAP_NUR_FUNKTIONEN bash '$SKRIPT' --hilfe | grep -q 'konfiguration'"

echo "== Parameterdatei"
p() { # Inhalt -> Exit-Code von parameter_lesen+parameter_pruefen in einer Unterschale
  printf '%s\n' "$1" > "$ARBEIT/p.txt"
  ( P_GIT_REPO_URL="git@github.com:diy3d-de/lx-fampad.git"; P_GIT_REF=""; P_SWAP_MB=0
    P_BACKUP_NAS_PUBKEY=""; P_BACKUP_NAS_IP=""; P_BACKUP_AGE_RECIPIENTS=""; P_BACKUP_AGE_RECIPIENTS_CONFIG=""
    P_E2EE_PW_BACKUP=""; P_AUTH_LEGACY_PASSWORD_LOGIN=""; P_WEATHER_ENABLED=""; P_WEATHER_PLACE=""; P_WEATHER_STATION_MAC=""; P_WEATHER_BBOX=""
    P_RELEASE_CERT_SHA256=""; P_LX_SSH_PUBKEY=""; P_CI_DEPLOY_PUBKEY=""
    parameter_lesen "$ARBEIT/p.txt"; parameter_pruefen ) >/dev/null 2>&1
}
RECIP="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
gelingt "gültige Datei (Beispielwerte)" p $'# Kommentar\nGIT_REF=v0.6.5\nSWAP_MB=1024\nWEATHER_ENABLED=true\nWEATHER_PLACE=Salz\nWEATHER_STATION_MAC=aa:bb:cc:dd:ee:ff\nWEATHER_BBOX=50.49,7.94,50.53,7.99'
scheitert "unbekannter Schlüssel (z. B. ein Netatmo-Geheimnis)" p 'NETATMO_CLIENT_SECRET=abc'
scheitert "privater age-Schlüssel im Wert" p 'GIT_REF=AGE-SECRET-KEY-1ABCDEF'
scheitert "Zeile ohne =" p 'GIT_REF'
scheitert "Shell-Code als Wert wird nicht akzeptiert" p 'GIT_REF=$(touch /tmp/x)'
scheitert "GIT_REF mit Leerzeichen" p 'GIT_REF=a b'
scheitert "GIT_REF beginnt mit -" p 'GIT_REF=-x'
scheitert "fremde Repository-URL" p 'GIT_REPO_URL=https://evil.example/x/y.git'
scheitert "SWAP_MB zu klein" p 'SWAP_MB=100'
scheitert "ungültiger age-Empfänger" p 'BACKUP_AGE_RECIPIENTS=age1zzz'
scheitert "NAS-Schlüssel ohne IP" p 'BACKUP_NAS_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc'
gelingt "NAS-Schlüssel mit IP" p $'BACKUP_NAS_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc nas\nBACKUP_NAS_IP=203.0.113.7'
scheitert "LEGACY=false ohne E2EE_PW_BACKUP" p 'AUTH_LEGACY_PASSWORD_LOGIN=false'
gelingt "LEGACY=false mit E2EE_PW_BACKUP" p $'AUTH_LEGACY_PASSWORD_LOGIN=false\nE2EE_PW_BACKUP=true'
scheitert "RELEASE_CERT_SHA256 zu kurz" p 'RELEASE_CERT_SHA256=AA:BB'
scheitert "Wetter-Ort mit Anführungszeichen" p 'WEATHER_PLACE=Sa"lz'
sed -E 's/^#([A-Z0-9_]+=)/\1/' "$HIER/parameter.beispiel" > "$ARBEIT/beispiel.txt"
gelingt "parameter.beispiel: alle Schlüssel einkommentiert sind gültig" p "$(cat "$ARBEIT/beispiel.txt")"
ERLAUBTE="$(grep -E '^ +GIT_REPO_URL\|' "$SKRIPT" | tr -d ' ' | sed 's/)$//' | tr '|' ' ')"
gleich "parameter.beispiel enthält jeden erlaubten Schlüssel (Liste im Skript: $(wc -w <<<"$ERLAUBTE") Stück)" "" "$(for k in $ERLAUBTE; do grep -q "^$k=" "$ARBEIT/beispiel.txt" || echo -n "$k "; done)"
: "$RECIP"

echo "== Rechte-Prüfungen und Schlüsseldatei"
: > "$ARBEIT/r1"; chmod 644 "$ARBEIT/r1"
gelingt "root-eigene Datei mit 644 ist zulässig" nur_root_schreibbar "$ARBEIT/r1"
chmod 664 "$ARBEIT/r1"; scheitert "gruppenschreibbare Datei wird abgelehnt" nur_root_schreibbar "$ARBEIT/r1"
chmod 646 "$ARBEIT/r1"; scheitert "weltschreibbare Datei wird abgelehnt" nur_root_schreibbar "$ARBEIT/r1"
chmod 644 "$ARBEIT/r1"; ln -s "$ARBEIT/r1" "$ARBEIT/r2"; scheitert "Symlink wird abgelehnt" nur_root_schreibbar "$ARBEIT/r2"
printf 'GIT_REF=v1\n' > "$ARBEIT/pg.txt"; chmod 664 "$ARBEIT/pg.txt"
scheitert "Parameterdatei mit Gruppen-Schreibrecht wird abgelehnt" bash -c "BOOTSTRAP_NUR_FUNKTIONEN=1 . '$SKRIPT'; set +e; parameter_lesen '$ARBEIT/pg.txt'"
scheitert "Schlüsseldatei außerhalb von /dev/shm und /run darf nicht gelöscht werden" identitaet_datei_loeschbar "$ARBEIT/r1"
if [ -d /dev/shm ]; then
  SHM="/dev/shm/bootstrap-test-$$"; : > "$SHM"; chmod 600 "$SHM"
  gelingt "Datei in /dev/shm (root, kein Symlink) darf gelöscht werden" identitaet_datei_loeschbar "$SHM"
  ln -s "$SHM" "$SHM.link"; scheitert "Symlink in /dev/shm wird abgelehnt" identitaet_datei_loeschbar "$SHM.link"
  rm -f "$SHM" "$SHM.link"
else uebersprungen "Schlüsseldatei in /dev/shm" "/dev/shm fehlt"; fi

echo "== env_wert und env_setzen"
printf 'A=1\nB=zwei\nB=drei\nC=x=y' > "$ARBEIT/env"
gleich "letzte Zeile gewinnt" "drei" "$(env_wert "$ARBEIT/env" B)"
gleich "Wert mit =" "x=y" "$(env_wert "$ARBEIT/env" C)"
gleich "fehlender Schlüssel" "" "$(env_wert "$ARBEIT/env" Z)"
ENV_WERT='geheim$wert\n&"' env_setzen "$ARBEIT/env" B
gleich "env_setzen ersetzt (erste Zeile) und entfernt Doppelte nicht" 'geheim$wert\n&"' "$(env_wert "$ARBEIT/env" A >/dev/null; sed -n 's/^B=//p' "$ARBEIT/env" | head -1)"
ENV_WERT='neu' env_setzen "$ARBEIT/env" NEU
gleich "env_setzen hängt an" "neu" "$(env_wert "$ARBEIT/env" NEU)"
gleich "env_setzen: Modus 600" "600" "$(stat -c %a "$ARBEIT/env")"
gleich "env_setzen: Zeilenumbruch am Ende ergänzt (letzte Zeile intakt)" "1" "$(env_wert "$ARBEIT/env" A)"

echo "== db_passwort_lesen"
printf 'DATABASE_URL=postgres://lx_fampad:Abc123xyz789@127.0.0.1:5432/lx_fampad\n' > "$ARBEIT/db.env"
gleich "Passwort aus URL" "Abc123xyz789" "$(db_passwort_lesen "$ARBEIT/db.env" DATABASE_URL)"
printf "DATABASE_URL=postgres://lx_fampad:ab'cd1234@127.0.0.1:5432/x\n" > "$ARBEIT/db2.env"
scheitert "Passwort mit Anführungszeichen wird abgelehnt (kein SQL-Risiko)" db_passwort_lesen "$ARBEIT/db2.env" DATABASE_URL
printf 'DATABASE_URL=postgres://lx_fampad:kurz@127.0.0.1:5432/x\n' > "$ARBEIT/db3.env"
scheitert "zu kurzes Passwort wird abgelehnt" db_passwort_lesen "$ARBEIT/db3.env" DATABASE_URL

echo "== Caddy-Hauptdatei"
gleich "fehlt" "fehlt" "$(caddy_haupt_zustand "$ARBEIT/gibtsnicht")"
printf '# nur Kommentar\n' > "$ARBEIT/c1"; gleich "leer/Kommentar = standard" "standard" "$(caddy_haupt_zustand "$ARBEIT/c1")"
cat > "$ARBEIT/c2" <<'EOF'
# The Caddyfile is an easy way to configure your Caddy web server.
#
# Unless the file starts with a global options block, the first
# uncommented line is always the address of your site.

# Refer to the Caddy docs for more information:
# https://caddyserver.com/docs/caddyfile

:80 {
	# Set this path to your site's directory.
	root * /usr/share/caddy

	# Enable the static file server.
	file_server

	# Another common task is to set up a reverse proxy:
	# reverse_proxy localhost:8080
}

# Refer to the Caddy docs for more information:
EOF
gleich "Standard-Caddyfile des Pakets" "standard" "$(caddy_haupt_zustand "$ARBEIT/c2")"
printf 'lx-labs.dev {\n\treverse_proxy 127.0.0.1:3000\n}\n' > "$ARBEIT/c3"; gleich "lx-labs ohne Import = fremd" "fremd" "$(caddy_haupt_zustand "$ARBEIT/c3")"
printf 'lx-labs.dev {\n}\nimport /etc/caddy/conf.d/*.caddy\n' > "$ARBEIT/c4"; gleich "mit Importzeile = import" "import" "$(caddy_haupt_zustand "$ARBEIT/c4")"
printf ':80 {\n\troot * /usr/share/caddy\n\tfile_server\n\tbasicauth { x y }\n}\n' > "$ARBEIT/c5"; gleich "veränderter Standard = fremd" "fremd" "$(caddy_haupt_zustand "$ARBEIT/c5")"
printf '# import /etc/caddy/conf.d/*.caddy\n:80 {\n}\n' > "$ARBEIT/c6"; gleich "auskommentierte Importzeile zählt nicht" "fremd" "$(caddy_haupt_zustand "$ARBEIT/c6")"

echo "== DNS-Vergleich"
gelingt "A-Adresse ist lokal" dns_vergleichen "203.0.113.7" "203.0.113.7" ""
scheitert "A-Adresse ist fremd" dns_vergleichen "203.0.113.7" "198.51.100.1" ""
scheitert "kein A-Eintrag" dns_vergleichen "203.0.113.7" "" ""
scheitert "AAAA zeigt woanders hin" dns_vergleichen $'203.0.113.7\n2001:db8::1' "203.0.113.7" "2001:db8::99"
gelingt "A und AAAA lokal" dns_vergleichen $'203.0.113.7\n2001:db8::1' "203.0.113.7" "2001:db8::1"

echo "== Fingerabdruck -> Base64url"
if hat_werkzeug python3; then
  gleich "32 Nullbytes" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "$(fingerabdruck_base64url "$(printf '00:%.0s' {1..31})00")"
  gleich "Sonderzeichen +/ werden zu -_ und die Auffüllung entfällt" "-_8" "$(fingerabdruck_base64url "FB:FF")"
  gleich "drei Bytes ohne Auffüllung" "_-7d" "$(fingerabdruck_base64url "FF:EE:DD")"
else uebersprungen "Fingerabdruck" "python3 fehlt"; fi

echo "== ntfy-Pins (eine Quelle: deploy/einrichtung-ntfy.sh)"
REPO="$REPO_WURZEL"
( ntfy_pins_lesen; [ -n "$NTFY_VERSION" ] && [ "${#NTFY_FPR}" = 40 ] && [ "${#NTFY_DEB_SHA256}" = 64 ] ) >/dev/null 2>&1 && ok "Pins aus einrichtung-ntfy.sh lesbar" || fehl "Pins aus einrichtung-ntfy.sh lesbar"
heredoc() { # Inhalt des Heredocs, der nach Zeile "$2" beginnt, in Datei $1
  awk -v marker="$2" 'index($0, marker) { f = 1; next } f && /^EOF$/ { exit } f { print }' "$1"
}
gleich "Härtungs-Drop-in von ntfy ist in beiden Skripten gleich" \
  "$(heredoc "$REPO_WURZEL/deploy/einrichtung-ntfy.sh" "haertung.conf <<'EOF'")" \
  "$(heredoc "$SKRIPT" "haertung.conf\" <<'EOF'")"
gleich "apt-Pin-Datei von ntfy ist in beiden Skripten gleich" \
  "$(heredoc "$REPO_WURZEL/deploy/einrichtung-ntfy.sh" "preferences.d/ntfy <<'EOF'")" \
  "$(heredoc "$SKRIPT" "preferences.d/ntfy <<'EOF'")"
gleich "Wetter-Einheit nutzt dasselbe Node-Binary wie die API" "ExecStart=/usr/bin/node dist/cli/weather-poller.js" "$(grep '^ExecStart=' "$REPO_WURZEL/deploy/lx-fampad-weather.service")"
gleich "Node-Pin passt zu server/.nvmrc" "$(cat "$REPO_WURZEL/server/.nvmrc")" "${NODE_PKG_VERSION%%-*}"
gelingt "Site-Datei fampad.caddy enthält die Domain" grep -q "^$DOMAIN {" "$REPO_WURZEL/deploy/Caddyfile"
gelingt "ntfy.caddy enthält die ntfy-Domain" grep -q "^$NTFY_DOMAIN {" "$REPO_WURZEL/deploy/ntfy/ntfy.caddy"
gelingt "Pins stehen in docs/VERSIONEN.md (Node)" grep -q "$NODE_PKG_VERSION" "$REPO_WURZEL/docs/VERSIONEN.md"
gelingt "Pins stehen in docs/VERSIONEN.md (Caddy)" grep -q "$CADDY_PKG_VERSION" "$REPO_WURZEL/docs/VERSIONEN.md"

echo "== age und Sicherungsarchive"
if hat_werkzeug age && hat_werkzeug age-keygen && hat_werkzeug tar; then
  K="$ARBEIT/key.txt"; age-keygen -o "$K" >/dev/null 2>&1
  PUB="$(age-keygen -y "$K")"
  K2="$ARBEIT/key2.txt"; age-keygen -o "$K2" >/dev/null 2>&1
  baue_config() { # $1 Ausgabe, Rest: tar-Argumente (im Ordner $ARBEIT/wurzel)
    local out="$1"; shift
    tar -czf - -C "$ARBEIT/wurzel" "$@" | age -r "$PUB" -o "$out"
  }
  mkdir -p "$ARBEIT/wurzel/etc/lx-fampad"
  printf 'AUTH_SECRET_KEY=%s\nPUBLIC_URL=https://familie.lx-labs.dev\n' "$(printf 'k%.0s' {1..40})" > "$ARBEIT/wurzel/etc/lx-fampad/env"
  head -c 64 /dev/urandom > "$ARBEIT/wurzel/dump.bin"
  printf 'PGDMPxxxxxxxxxxxx' | age -r "$PUB" -o "$ARBEIT/db-20261022-033000.dump.age"
  baue_config "$ARBEIT/config-gut.age" etc/lx-fampad
  # Swap: ohne --swap-ok Abbruch vor dem Einlesen, mit --swap-ok Warnung; Schlüssel wird verworfen
  ( swapon() { echo "/swapfile file 1G 0B -2"; }; ID_STDIN=1; SWAP_OK=0; identitaet_laden < "$K" ) >/dev/null 2>&1 && fehl "aktiver Swap bricht vor dem Einlesen des Schlüssels ab" || ok "aktiver Swap bricht vor dem Einlesen des Schlüssels ab"
  ( swapon() { echo "/swapfile file 1G 0B -2"; }; ID_STDIN=1; SWAP_OK=1; identitaet_laden < "$K"; [ -n "$AGE_ID" ] ) >/dev/null 2>&1 && ok "mit --swap-ok wird der Schlüssel trotz Swap gelesen" || fehl "mit --swap-ok wird der Schlüssel trotz Swap gelesen"
  ( swapon() { :; }; ID_STDIN=1; SWAP_OK=0; RESTORE=1; identitaet_laden < "$K"; schluessel_verwerfen; [ -z "$AGE_ID" ] && [ "$SCHLUESSEL_VERWORFEN" = 1 ] ) >/dev/null 2>&1 && ok "schluessel_verwerfen leert den Schlüssel" || fehl "schluessel_verwerfen leert den Schlüssel"
  AGE_ID="$(grep '^AGE-SECRET-KEY-' "$K")"
  DB_ARCHIV="$ARBEIT/db-20261022-033000.dump.age"; CFG_ARCHIV="$ARBEIT/config-gut.age"
  gleich "Entschlüsselung mit dem richtigen Schlüssel (Pipe, keine Schlüsseldatei)" "PGDMPxxxxxxxxxxxx" "$(age_entschluesseln "$DB_ARCHIV")"
  ( sicherung_inhalt_pruefen ) >/dev/null 2>&1 && ok "gutes Archiv wird akzeptiert" || fehl "gutes Archiv wird akzeptiert"
  AGE_ID="$(grep '^AGE-SECRET-KEY-' "$K2")"
  ( sicherung_inhalt_pruefen ) >/dev/null 2>&1 && fehl "falscher Schlüssel wird abgelehnt" || ok "falscher Schlüssel wird abgelehnt"
  AGE_ID="$(grep '^AGE-SECRET-KEY-' "$K")"
  # Symlink im Archiv
  ln -s /etc/passwd "$ARBEIT/wurzel/etc/lx-fampad/link"
  baue_config "$ARBEIT/config-link.age" etc/lx-fampad
  CFG_ARCHIV="$ARBEIT/config-link.age"
  ( sicherung_inhalt_pruefen ) >/dev/null 2>&1 && fehl "Archiv mit Symlink wird abgelehnt" || ok "Archiv mit Symlink wird abgelehnt"
  rm -f "$ARBEIT/wurzel/etc/lx-fampad/link"
  # Pfad mit ..
  tar -czf - --transform='s|^etc/lx-fampad/env$|../evil|' -C "$ARBEIT/wurzel" etc/lx-fampad/env etc/lx-fampad | age -r "$PUB" -o "$ARBEIT/config-punkt.age"
  CFG_ARCHIV="$ARBEIT/config-punkt.age"
  ( sicherung_inhalt_pruefen ) >/dev/null 2>&1 && fehl "Archiv mit .. im Pfad wird abgelehnt" || ok "Archiv mit .. im Pfad wird abgelehnt"
  # ohne env
  mkdir -p "$ARBEIT/wurzel2/etc/lx-fampad"; : > "$ARBEIT/wurzel2/etc/lx-fampad/andere"
  tar -czf - -C "$ARBEIT/wurzel2" etc/lx-fampad | age -r "$PUB" -o "$ARBEIT/config-ohne.age"
  CFG_ARCHIV="$ARBEIT/config-ohne.age"
  ( sicherung_inhalt_pruefen ) >/dev/null 2>&1 && fehl "Archiv ohne env wird abgelehnt" || ok "Archiv ohne env wird abgelehnt"
  # kein pg_dump
  printf 'kein dump' | age -r "$PUB" -o "$ARBEIT/db-falsch.age"
  DB_ARCHIV="$ARBEIT/db-falsch.age"; CFG_ARCHIV="$ARBEIT/config-gut.age"
  ( sicherung_inhalt_pruefen ) >/dev/null 2>&1 && fehl "Datei ohne PGDMP-Kennung wird abgelehnt" || ok "Datei ohne PGDMP-Kennung wird abgelehnt"
  # Extraktion: nur erlaubte Pfade, Eigentümer root
  DB_ARCHIV="$ARBEIT/db-20261022-033000.dump.age"; CFG_ARCHIV="$ARBEIT/config-gut.age"
  ( sicherung_inhalt_pruefen && config_hat etc/lx-fampad ) >/dev/null 2>&1 && ok "config_hat erkennt vorhandene Pfade" || fehl "config_hat erkennt vorhandene Pfade"
  CFG_NAMEN="etc/lx-fampad/
etc/lx-fampad/env"
  scheitert "config_hat verneint fehlende Pfade" config_hat var/lib/ntfy
  scheitert "config_hat verwechselt Präfixe nicht (etc/lx-fampad-backup)" config_hat etc/lx-fampad-backup
  # Ordnerprüfung
  mkdir -p "$ARBEIT/lauf"
  cp "$DB_ARCHIV" "$ARBEIT/lauf/"; cp "$ARBEIT/config-gut.age" "$ARBEIT/lauf/config-20261022-033000.tar.age"
  ( cd "$ARBEIT/lauf" && sha256sum -- *.age > SHA256SUMS )
  ( SICHERUNG_DIR="$ARBEIT/lauf"; sicherung_ordner_pruefen ) >/dev/null 2>&1 && ok "Sicherungsordner mit passenden Prüfsummen" || fehl "Sicherungsordner mit passenden Prüfsummen"
  printf 'x' >> "$ARBEIT/lauf/config-20261022-033000.tar.age"
  ( SICHERUNG_DIR="$ARBEIT/lauf"; sicherung_ordner_pruefen ) >/dev/null 2>&1 && fehl "veränderte Datei fällt über die Prüfsumme auf" || ok "veränderte Datei fällt über die Prüfsumme auf"
  # SHA256SUMS muss alle benutzten Archive nennen
  cp "$ARBEIT/config-gut.age" "$ARBEIT/lauf/config-20261022-033000.tar.age"
  ( cd "$ARBEIT/lauf" && sha256sum -- db-*.age > SHA256SUMS )
  ( SICHERUNG_DIR="$ARBEIT/lauf"; sicherung_ordner_pruefen ) >/dev/null 2>&1 && fehl "Archiv ohne Eintrag in SHA256SUMS wird abgelehnt" || ok "Archiv ohne Eintrag in SHA256SUMS wird abgelehnt"
  ( cd "$ARBEIT/lauf" && sha256sum -- *.age > SHA256SUMS )
  chmod 666 "$ARBEIT/lauf/SHA256SUMS"
  ( SICHERUNG_DIR="$ARBEIT/lauf"; sicherung_ordner_pruefen ) >/dev/null 2>&1 && fehl "weltschreibbare SHA256SUMS wird abgelehnt" || ok "weltschreibbare SHA256SUMS wird abgelehnt"
  chmod 644 "$ARBEIT/lauf/SHA256SUMS"
  ( SICHERUNG_DIR="$ARBEIT/lauf"; sicherung_ordner_pruefen ) >/dev/null 2>&1 && ok "Sicherungsordner mit richtigen Rechten und vollständiger SHA256SUMS" || fehl "Sicherungsordner mit richtigen Rechten und vollständiger SHA256SUMS"
  # Dateiablage-Archiv (ungepacktes tar): Hardlink, fremder Pfad, gutes Archiv
  mkdir -p "$ARBEIT/wf/srv/fampad/files"; echo x > "$ARBEIT/wf/srv/fampad/files/a"; ln "$ARBEIT/wf/srv/fampad/files/a" "$ARBEIT/wf/srv/fampad/files/b"
  tar -cf - -C "$ARBEIT/wf" srv | age -r "$PUB" -o "$ARBEIT/files-hardlink.age"
  ( tar_archiv_pruefen "$ARBEIT/files-hardlink.age" "" "Dateiablage" ) >/dev/null 2>&1 && fehl "Dateiablage-Archiv mit Hardlink wird abgelehnt" || ok "Dateiablage-Archiv mit Hardlink wird abgelehnt"
  rm "$ARBEIT/wf/srv/fampad/files/b"
  tar -cf - -C "$ARBEIT/wf" srv | age -r "$PUB" -o "$ARBEIT/files-gut.age"
  gleich "Dateiablage-Archiv ohne Links wird gelesen" "$(printf 'srv/\nsrv/fampad/\nsrv/fampad/files/\nsrv/fampad/files/a')" "$(tar_archiv_pruefen "$ARBEIT/files-gut.age" "" "Dateiablage" 2>/dev/null)"
  AGE_ID=""
else
  uebersprungen "age-Tests" "age, age-keygen oder tar fehlt"
fi

echo "== Trockenlauf (nur wenn auf einem Debian-13-System als root)"
if [ "$(id -u)" = 0 ] && grep -q '^VERSION_ID="13"' /etc/os-release 2>/dev/null; then
  OUT="$(a --dry-run --ohne-systemd --lx-anlegen 2>&1)"; RC=$?
  # ohne Netz (--network none) meldet der Trockenlauf "nicht erreichbar" als PROBLEM: das ist erwartet, alles andere nicht
  ANDERE_PROBLEME="$(grep -E '^ +PROBLEM:' <<<"$OUT" | grep -vc 'nicht erreichbar' || true)"
  gleich "Trockenlauf: keine anderen PROBLEM-Zeilen als fehlendes Netz" 0 "$ANDERE_PROBLEME"
  if [ "$RC" = 0 ] || { [ "$RC" = 1 ] && grep -q 'nicht erreichbar' <<<"$OUT"; }; then ok "Trockenlauf Exit-Code (0, oder 1 nur wegen fehlendem Netz)"; else fehl "Trockenlauf Exit-Code $RC"; fi
  gelingt "Trockenlauf nennt alle Phasen" bash -c "for p in pruefen pakete system code konfiguration datenbank anwendung ntfy caddy sicherung pruefung; do echo \"\$1\" | grep -q \"Phase .*: \$p\" || exit 1; done" _ "$OUT"
  gelingt "Trockenlauf meldet 'nichts wurde verändert'" grep -q 'nichts wurde verändert' <<<"$OUT"
  gelingt "Trockenlauf listet die Aufgaben für den Menschen" grep -q 'Das musst du noch selbst tun' <<<"$OUT"
  scheitert "Trockenlauf hat nichts installiert (kein /srv/fampad)" test -d /srv/fampad/server
  scheitert "Trockenlauf hat keinen Benutzer lx angelegt" id lx
else
  uebersprungen "Trockenlauf" "kein Debian 13 als root (test-docker.sh startet einen Container)"
fi

echo
echo "Ergebnis: $OK ok, $FEHL fehlgeschlagen, $UEBERSPRUNGEN übersprungen"
[ "$FEHL" -eq 0 ]
