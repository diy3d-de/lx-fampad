#!/usr/bin/env bash
# Läuft IM Debian-13-Container (aufgerufen von container-lauf.sh, Szenario "umzug"): testet den Umzugs-Assistenten (umzug.sh) gegen die Sicherung aus Szenario A.
# Isolation: bricht ohne /.dockerenv ab; alle Aufrufe mit --ohne-systemd (spricht nie die echten Internet-Adressen familie.lx-labs.dev / lx-labs.dev an;
# nur die DNS-Abfrage der Prüfung selbst), systemctl ist die Attrappe aus fake-systemctl.sh. Die Eingaben des Assistenten kommen aus einer Pipe
# (wie "gespeicherte Antworten"): jede Zeile ist die Antwort auf eine Frage.
# Ablauf: Falsche Reihenfolge (--weiter ohne Lauf) > Probelauf (ändert nichts) > falscher Schlüssel (bricht ab, ändert nichts) > echter Lauf bis zur
#         GitHub-Pause (zweimal "weiter", dann Abbruch, Exit 10) > Neustart mit falschem Tag (Fehler) > "Code-Stand ändern" mit falschem Tag (Fehler) >
#         --neu mit richtigem Tag bis zum Ende > Wiederholung mit Swap (nichts mehr zu tun) > --weiter caddy/wetter/muell/pruefung >
#         --aktualisieren (zweite, neuere Sicherung einspielen).
# Der Lecktest läuft ab dem Probelauf bis zum Ende: ein Hintergrundprozess prüft alle 50 ms, ob der Schlüssel in Argumenten oder Umgebung irgendeines Prozesses steht.
set -uo pipefail
[ -f /.dockerenv ] || { echo "umzug-lauf.sh läuft nur in einem Docker-Container (/.dockerenv fehlt): Abbruch" >&2; exit 99; }
export LC_ALL=C.UTF-8
REPO_QUELLE=/repo
ARBEIT=/work
LXHOME=/home/lx
IP_TEST=203.0.113.10

ok() { echo "  ok    $*"; }
fehl() { echo "  FEHLT $*"; FEHLER=1; }
FEHLER=0
pruefe() { local t="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$t"; else fehl "$t"; fi; }
enthaelt() { # Text, Datei, Nadel
  if grep -qF -- "$3" "$2"; then ok "$1"; else fehl "$1 (nicht gefunden: $3)"; fi
}
enthaelt_nicht() { if grep -qF -- "$3" "$2"; then fehl "$1 (gefunden: $3)"; else ok "$1"; fi; }
gleich() { if [ "$2" = "$3" ]; then ok "$1"; else fehl "$1 (erwartet '$2', erhalten '$3')"; fi; }
psql_db() { (cd / && runuser -u postgres -- psql -X -d "$1" -tAc "$2"); }

echo "== Vorbereitung (wie ein frischer Server: nur die zwei Skripte, die Sicherung, ein Schlüssel)"
install -m 700 -o root -g root "$REPO_QUELLE/deploy/neuinstallation/umzug.sh" /root/umzug.sh
install -m 700 -o root -g root "$REPO_QUELLE/deploy/neuinstallation/bootstrap-server.sh" /root/bootstrap-server.sh
LAUF="$(ls -1 "$ARBEIT/sicherung" | sort | tail -1)"
mkdir -p /root/sicherung; cp -r "$ARBEIT/sicherung/$LAUF" /root/sicherung/
chown -R root:root /root/sicherung; chmod -R go-w /root/sicherung
KEY="$(grep '^AGE-SECRET-KEY-' "$ARBEIT/key.txt")"
printf '%s\n' "$KEY" > "$ARBEIT/key-nur.txt"          # nur für den Lecktest (Muster-Datei von grep -f), liegt auf dem Host-Mount, nicht auf dem "Server"
age-keygen -o "$ARBEIT/falsch.txt" >/dev/null 2>&1
KEY_FALSCH="$(grep '^AGE-SECRET-KEY-' "$ARBEIT/falsch.txt")"
ssh-keygen -q -t ed25519 -N "" -C pc-test -f "$ARBEIT/pc_key"
ssh-keygen -q -t ed25519 -N "" -C ci-test -f "$ARBEIT/ci_key"
mkdir -p /root/.ssh; chmod 700 /root/.ssh
cp "$ARBEIT/pc_key.pub" /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
# öffentliche Vorgaben wie aus den Betriebsunterlagen: --params (NAS und der Schlüssel des Release-Uploads)
{ echo "BACKUP_NAS_PUBKEY=$(cut -d' ' -f1-2 "$ARBEIT/nas_key.pub") lx-fampad-backup-nas"; echo "BACKUP_NAS_IP=203.0.113.7"; echo "CI_DEPLOY_PUBKEY=$(cut -d' ' -f1-2 "$ARBEIT/ci_key.pub") lx-fampad-release"; } > /root/vorgabe.params
chmod 600 /root/vorgabe.params
UMZUG=(bash /root/umzug.sh --ohne-systemd --swap-ok --ip "$IP_TEST" --params /root/vorgabe.params)
UMZUG_OHNE_PARAMS=(bash /root/umzug.sh --ohne-systemd --swap-ok --ip "$IP_TEST")
UMZUG_OHNE_SWAPOK=(bash /root/umzug.sh --ohne-systemd --ip "$IP_TEST" --params /root/vorgabe.params)
# Eingaben des Assistenten (je Zeile eine Antwort), siehe die Reihenfolge der Fragen in umzug.sh
eingabe_fragen() { printf '%s\n' "" "" "$KEY" "$1" "" "nein" ""; }   # Weiter, Sicherung, Schlüssel, Tag, NAS stimmt, kein Swap, SSH-Schlüssel für lx

# Lecktest ab hier
rm -f "$ARBEIT/leck.txt" /tmp/monitor.stop
( while [ ! -f /tmp/monitor.stop ]; do grep -alF -f "$ARBEIT/key-nur.txt" /proc/[0-9]*/cmdline /proc/[0-9]*/environ >> "$ARBEIT/leck.txt" 2>/dev/null; sleep 0.05; done ) &
MONITOR=$!

echo
echo "== 0. Falsche Reihenfolge: --weiter ohne vorherigen Lauf"
"${UMZUG[@]}" --weiter caddy > "$ARBEIT/weiter0.log" 2>&1 < /dev/null; RC=$?
gleich "--weiter caddy ohne Lauf: Exit-Code 1" 1 "$RC"
enthaelt "Meldung: noch kein Lauf des Assistenten" "$ARBEIT/weiter0.log" "noch keinen Lauf"
rm -f /root/umzug-bericht.txt

echo
echo "== 1. Probelauf (--probe): läuft bis zur Zusammenfassung und ändert nichts"
eingabe_fragen v0.0.0-test | "${UMZUG[@]}" --probe > "$ARBEIT/probe.log" 2>&1; RC=$?
tail -30 "$ARBEIT/probe.log"
gleich "Probelauf endet mit Exit-Code 0" 0 "$RC"
enthaelt "Probelauf nennt sich Probelauf" "$ARBEIT/probe.log" "Probelauf beendet. Es wurde nichts verändert."
enthaelt "Versionskopf" "$ARBEIT/probe.log" "Umzugs-Assistent"
enthaelt "Prüfsummen der Skripte werden gezeigt" "$ARBEIT/probe.log" "Prüfsummen der beiden Skripte"
enthaelt "Der Schlüssel passt (Prüfung ohne Änderung)" "$ARBEIT/probe.log" "Der Schlüssel passt"
enthaelt "Zusammenfassung zeigt den Code-Stand" "$ARBEIT/probe.log" "v0.0.0-test"
enthaelt "Zusammenfassung zeigt die NAS-IP aus --params" "$ARBEIT/probe.log" "203.0.113.7"
enthaelt "Gegenprobe (bootstrap --dry-run) ohne Befund" "$ARBEIT/probe.log" "Gegenprobe ohne Befund"
enthaelt "Caddy wird auf später verschoben" "$ARBEIT/probe.log" "--weiter caddy"
enthaelt_nicht "Probelauf fragt nicht nach 'umziehen'" "$ARBEIT/probe.log" "Tippe umziehen"
pruefe "nichts angelegt: kein /srv/fampad" bash -c "[ ! -e /srv/fampad ]"
pruefe "nichts angelegt: kein Benutzer lx" bash -c "! id lx"
pruefe "nichts angelegt: keine Konfiguration /etc/lx-fampad" bash -c "[ ! -e /etc/lx-fampad ]"
pruefe "nichts gemerkt: keine Antwortdatei" bash -c "[ ! -e /root/.umzug-antworten ]"
pruefe "nichts geschrieben: keine Parameterdatei, kein Log, keine Liste, kein Bericht" bash -c "[ ! -e /root/umzug.params ] && [ ! -e /root/umzug-lauf.log ] && [ ! -e /root/umzug-offen.txt ] && [ ! -e /root/umzug-bericht.txt ]"
pruefe "keine Wegwerf-Dateien in /run übrig" bash -c "! ls -d /run/umzug.* 2>/dev/null | grep -q ."
pruefe "PostgreSQL wurde nicht installiert" bash -c "! dpkg -s postgresql >/dev/null 2>&1"

echo
echo "== 2. Falscher Schlüssel: bricht nach drei Versuchen ab, ändert nichts"
printf '%s\n' "" "" "$KEY_FALSCH" "$KEY_FALSCH" "$KEY_FALSCH" | "${UMZUG[@]}" > "$ARBEIT/falsch.log" 2>&1; RC=$?
tail -12 "$ARBEIT/falsch.log"
gleich "Exit-Code 1" 1 "$RC"
enthaelt "Meldung: Schlüssel passt nicht, nichts verändert" "$ARBEIT/falsch.log" "Dieser Schlüssel passt nicht zu dieser Sicherung. Nichts wurde verändert."
pruefe "dreimal versucht" bash -c "[ \"\$(grep -c 'Dieser Schlüssel passt nicht' '$ARBEIT/falsch.log')\" = 3 ]"
pruefe "nichts angelegt (kein /srv/fampad, kein lx, keine Antwortdatei)" bash -c "[ ! -e /srv/fampad ] && ! id lx && [ ! -e /root/.umzug-antworten ] && [ ! -e /etc/lx-fampad ]"
pruefe "Bericht wurde geschrieben (Modus 600)" bash -c "[ \"\$(stat -c %a /root/umzug-bericht.txt)\" = 600 ]"
pruefe "Bericht enthält keinen Schlüssel" bash -c "! grep -q 'AGE-SECRET-KEY' /root/umzug-bericht.txt"
rm -f /root/umzug-bericht.txt

echo
echo "== 3. Echter Lauf bis zur GitHub-Pause (kein Checkout vorhanden; Tag absichtlich falsch; zweimal 'weiter', dann Abbruch)"
{ eingabe_fragen v0.0.0-falsch; printf '%s\n' "umziehen" "weiter" "abbrechen"; } | "${UMZUG[@]}" 2>&1 | tee "$ARBEIT/lauf1.log" | tail -60
RC=${PIPESTATUS[1]}
gleich "Exit-Code 10 (pausiert)" 10 "$RC"
gleich "PAUSE wurde nach 'weiter' erneut angezeigt (GitHub lässt den Server noch nicht lesen): zweimal" 2 "$(grep -c 'PAUSE: GitHub lässt diesen Server noch nicht lesen.' "$ARBEIT/lauf1.log")"
DEPLOYKEY="$(cut -d' ' -f1-2 "$LXHOME/.ssh/id_ed25519_fampad.pub")"
enthaelt "der öffentliche Schlüssel des Servers steht in der Anzeige" "$ARBEIT/lauf1.log" "$DEPLOYKEY"
enthaelt "Fortschritt: Prüfung" "$ARBEIT/lauf1.log" "1/11  Prüfung"
enthaelt "Fortschritt: Pakete mit Häkchen" "$ARBEIT/lauf1.log" "✓ 2/11  Pakete installieren"
enthaelt "Fortschritt: Benutzer und Ordner" "$ARBEIT/lauf1.log" "✓ 3/11  Benutzer und Ordner"
pruefe "Antwortdatei: Modus 600, root" bash -c "[ \"\$(stat -c %a:%U /root/.umzug-antworten)\" = 600:root ]"
enthaelt "gemerkt: Sicherungspfad" /root/.umzug-antworten "SICHERUNG=/root/sicherung/$LAUF"
enthaelt "gemerkt: Code-Stand" /root/.umzug-antworten "GIT_REF=v0.0.0-falsch"
enthaelt "gemerkt: Pfad der --params-Datei (nicht der Inhalt)" /root/.umzug-antworten "PARAMS=/root/vorgabe.params"
enthaelt_nicht "Inhalt der --params-Datei steht nicht in der Antwortdatei" /root/.umzug-antworten "CI_DEPLOY_PUBKEY"
enthaelt "gemerkt: fertige Phasen (Pause vor code)" /root/.umzug-antworten "FERTIG=pruefen,pakete,system"
enthaelt_nicht "Antwortdatei enthält keinen Schlüssel" /root/.umzug-antworten "AGE-SECRET-KEY"
pruefe "Parameterdatei: Modus 600, nur Öffentliches" bash -c "[ \"\$(stat -c %a /root/umzug.params)\" = 600 ] && grep -q '^GIT_REF=v0.0.0-falsch' /root/umzug.params && ! grep -qiE 'AGE-SECRET|password|passwort' /root/umzug.params"
pruefe "Benutzer lx mit dem SSH-Schlüssel des PCs angelegt" bash -c "grep -qF \"\$(cut -d' ' -f1-2 '$ARBEIT/pc_key.pub')\" $LXHOME/.ssh/authorized_keys"
"${UMZUG[@]}" --weiter caddy > "$ARBEIT/weiter1.log" 2>&1 < /dev/null; RC=$?
gleich "--weiter caddy vor der Datenbank: Exit-Code 1" 1 "$RC"
enthaelt "Meldung: noch nicht bis zur Datenbank gekommen" "$ARBEIT/weiter1.log" "noch nicht bis zur Datenbank"
rm -f /root/umzug-bericht.txt

echo
echo "== 4a. Neustart (derselbe Befehl, ohne --params): der Tag ist falsch, der Checkout ist da: die Phase code scheitert"
# Der Test nimmt den Code-Stand aus dem Tarball statt von GitHub (wie container-lauf.sh): lokaler Checkout mit dem richtigen Tag v0.0.0-test
cp -r "$REPO_QUELLE" "$LXHOME/lx-fampad"
chown -R lx:lx "$LXHOME/lx-fampad"
runuser -u lx -- bash -c "cd '$LXHOME/lx-fampad' && git init -q && git config user.email t@example.org && git config user.name test && git add -A && git commit -q -m 'Teststand' && git tag v0.0.0-test && git remote add origin '$LXHOME/lx-fampad'"
printf '%s\n' "" "" "" "$KEY" "" "umziehen" | "${UMZUG_OHNE_PARAMS[@]}" 2>&1 | tee "$ARBEIT/lauf2a.log" | tail -25
RC=${PIPESTATUS[1]}
gleich "Exit-Code 1 (Tag nicht gefunden)" 1 "$RC"
enthaelt "die gemerkte --params-Datei wird beim Neustart angezeigt" "$ARBEIT/lauf2a.log" "Zusätzliche Parameterdatei: /root/vorgabe.params"
enthaelt "Fehler nennt den Tag" "$ARBEIT/lauf2a.log" "GIT_REF 'v0.0.0-falsch' nicht gefunden"
enthaelt "Maßnahme: Code-Stand ändern" "$ARBEIT/lauf2a.log" "Code-Stand ändern?"
pruefe "Bericht wurde geschrieben, ohne Schlüssel" bash -c "[ -s /root/umzug-bericht.txt ] && ! grep -q 'AGE-SECRET-KEY' /root/umzug-bericht.txt"
pruefe "die gemerkte Parameterdatei wirkt auch ohne --params: CI_DEPLOY_PUBKEY steht in der Datei für bootstrap" grep -q '^CI_DEPLOY_PUBKEY=' /root/umzug.params
pruefe "Stand des Aufbaus unverändert (code fehlt)" bash -c "grep -q '^FERTIG=pruefen,pakete,system\$' /root/.umzug-antworten"

echo
echo "== 4b. 'Code-Stand ändern?' mit ja, aber wieder ein falscher Tag"
printf '%s\n' "" "" "" "$KEY" "ja" "v0.0.0-falsch2" "umziehen" | "${UMZUG_OHNE_PARAMS[@]}" 2>&1 | tee "$ARBEIT/lauf2b.log" | tail -15
RC=${PIPESTATUS[1]}
gleich "Exit-Code 1 (zweiter falscher Tag)" 1 "$RC"
enthaelt "neuer Tag wurde gemerkt" /root/.umzug-antworten "GIT_REF=v0.0.0-falsch2"

echo
echo "== 4c. --neu mit richtigem Tag bis zum Ende (der Stand des Aufbaus bleibt, nur die Antworten werden neu gefragt)"
printf '%s\n' "" "" "$KEY" "v0.0.0-test" "" "nein" "umziehen" | "${UMZUG[@]}" --neu 2>&1 | tee "$ARBEIT/lauf2.log" | tail -70
RC=${PIPESTATUS[1]}
gleich "Exit-Code 0" 0 "$RC"
enthaelt_nicht "--neu: keine Rückfrage nach früheren Antworten" "$ARBEIT/lauf2.log" "Ich habe die Antworten eines früheren Laufs gefunden"
enthaelt "Fortsetzung eines früheren Laufs (kein 'schon eingerichtet'-Abbruch)" "$ARBEIT/lauf2.log" "Fortsetzung eines früheren Laufs"
pruefe "Plan dieses Laufs beginnt nicht mehr bei den Paketen" bash -c "! sed -n '/Ich werde:/,/Nichts/p' '$ARBEIT/lauf2.log' | grep -q 'Pakete installieren'"
enthaelt "Code-Stand dieses Laufs wird gezeigt" "$ARBEIT/lauf2.log" "CODE-STAND DIESES LAUFS"
enthaelt "Datenbank eingespielt (Spalten ausgerichtet)" "$ARBEIT/lauf2.log" "✓ 6/11  Datenbank einspielen"
enthaelt "Schlüssel wird nach der Datenbank verworfen" "$ARBEIT/lauf2.log" "Schlüssel aus dem Arbeitsspeicher des Assistenten entfernt"
enthaelt "Abschlussprüfung bestanden" "$ARBEIT/lauf2.log" "✓ 11/11 Abschlussprüfung"
enthaelt "Caddy wartet auf DNS" "$ARBEIT/lauf2.log" "Caddy und Zertifikate: später"
enthaelt "Dein Teil: neue IP" "$ARBEIT/lauf2.log" "familie        A   $IP_TEST"
enthaelt "Dein Teil: ntfy.familie" "$ARBEIT/lauf2.log" "ntfy.familie   A   $IP_TEST"
enthaelt "Dein Teil: Kontrollbefehl dig" "$ARBEIT/lauf2.log" "dig +short familie.lx-labs.dev"
enthaelt "Dein Teil: erst Schreibstopp und frische Sicherung, dann --aktualisieren" "$ARBEIT/lauf2.log" "--aktualisieren"
enthaelt "Dein Teil: Web-App" "$ARBEIT/lauf2.log" "SSH_HOST=lx@$IP_TEST deploy/deploy-web.sh"
enthaelt "Dein Teil: Wiederherstellung prüfen" "$ARBEIT/lauf2.log" "Anmeldung mit Passkey und mit TOTP"
enthaelt "Dein Teil: NAS neu verbinden mit Fingerabdruck-Hinweis" "$ARBEIT/lauf2.log" "Fingerabdruck vergleichen"
enthaelt "Dein Teil: Wetter (war in der Sicherung aktiv), mit absolutem Pfad" "$ARBEIT/lauf2.log" "bash /root/umzug.sh --weiter wetter"
enthaelt_nicht "Dein Teil: kein Müll-Schritt (war nicht aktiv)" "$ARBEIT/lauf2.log" "--weiter muell"
enthaelt "Dein Teil: APK-Link" "$ARBEIT/lauf2.log" "lx-familyhub-latest.apk"
pruefe "Liste liegt in /root/umzug-offen.txt (Modus 600) und enthält die IP" bash -c "[ \"\$(stat -c %a /root/umzug-offen.txt)\" = 600 ] && grep -q '$IP_TEST' /root/umzug-offen.txt"
pruefe "Liste enthält keine Geheimnisse" bash -c "! grep -qE 'AGE-SECRET|tk_|AUTH_SECRET_KEY=|PASSWORD' /root/umzug-offen.txt"
pruefe "Lauf-Log: Modus 600" bash -c "[ \"\$(stat -c %a /root/umzug-lauf.log)\" = 600 ]"
pruefe "CI-Schlüssel aus --params wurde für lx eingetragen (nur Schreiben, rrsync)" bash -c "grep -q 'restrict,command=\"[^\"]*rrsync -wo /srv/fampad/releases/android\" ssh-ed25519' $LXHOME/.ssh/authorized_keys"

echo
echo "== 5. Ergebnis wie bei einer Wiederherstellung mit bootstrap-server.sh"
pruefe "API antwortet mit db ok" bash -c "curl -fsS http://127.0.0.1:4400/api/v1/health | grep -q '\"db\":\"ok\"'"
pruefe "AUTH_SECRET_KEY stammt aus der Sicherung" bash -c "[ \"\$(sed -n 's/^AUTH_SECRET_KEY=//p' /etc/lx-fampad/env | sha256sum | cut -d' ' -f1)\" = \"\$(cat $ARBEIT/auth.sha)\" ]"
pruefe "Familie aus der Sicherung ist da" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -d lx_fampad -tAc 'select name from families limit 1')\" = Testfamilie ]"
pruefe "ntfy-Token aus der Sicherung ist gültig" bash -c "runuser -u ntfy -- ntfy token --config /etc/ntfy/server.yml list | grep -q \"\$(head -n1 /etc/lx-fampad/ntfy-token)\""
pruefe "Einstellungen der Sicherung aus der alten Konfiguration übernommen (INCLUDE_APK=0), aber nicht die Datei selbst" bash -c "grep -q '^INCLUDE_APK=0' /etc/lx-fampad-backup/backup.conf && ! grep -q MARKER-AUS-DER-SICHERUNG /etc/lx-fampad-backup/backup.conf"
pruefe "NAS-Zugang aus --params eingerichtet (nur lesen, rrsync)" bash -c "grep -q 'restrict,from=\"203.0.113.7\",command=\"/usr/bin/rrsync -ro /var/backups/lx-fampad\"' /var/lib/lxbackup/.ssh/authorized_keys"
pruefe "Wetter-Regel noch nicht in der sudo-Datei" bash -c "! grep -q 'lx-fampad-weather' /etc/sudoers.d/lx-fampad"
pruefe "keine Caddy-Site-Dateien (DNS fehlt, Testmodus)" bash -c "[ ! -e /etc/caddy/conf.d/fampad.caddy ] && [ ! -e /etc/caddy/Caddyfile ]"

echo
echo "== 6. Wiederholung (alles erledigt) mit Swap und ohne --swap-ok: kein Schlüssel, kein Sicherungsordner nötig"
# Der Sicherungsordner ist nicht mehr nötig: weg damit (die Sicherung liegt weiter beim "NAS")
mv /root/sicherung "$ARBEIT/sicherung-beiseite"
printf '%s\n' "" "" "" | "${UMZUG_OHNE_SWAPOK[@]}" > "$ARBEIT/lauf3.log" 2>&1; RC=$?
tail -15 "$ARBEIT/lauf3.log"
gleich "Exit-Code 0 (auch wenn der Container Swap des Hosts zeigt: --swap-ok wird nur an die Gegenprobe gegeben, weil kein Schlüssel nötig ist)" 0 "$RC"
enthaelt "Sicherung und Schlüssel werden nicht mehr gebraucht" "$ARBEIT/lauf3.log" "weder den Sicherungsordner noch deinen Schlüssel mehr"
enthaelt "nichts mehr zu tun" "$ARBEIT/lauf3.log" "alle Phasen sind schon erledigt"
mv "$ARBEIT/sicherung-beiseite" /root/sicherung

echo
echo "== 7. Folgeschritte (--weiter)"
"${UMZUG[@]}" --weiter caddy > "$ARBEIT/weiter-caddy1.log" 2>&1 < /dev/null; RC=$?
gleich "--weiter caddy ohne passenden DNS-Eintrag: Exit-Code 1" 1 "$RC"
enthaelt "Meldung: DNS zeigt noch nicht auf diesen Server (mit dem Grund)" "$ARBEIT/weiter-caddy1.log" "keine globale Adresse dieses Servers"
pruefe "ohne DNS wurde Caddy nicht angefasst" bash -c "[ ! -e /etc/caddy/Caddyfile ] && ! command -v caddy"
bash /root/umzug.sh --ohne-systemd --swap-ok --dns-pruefung-ueberspringen --weiter caddy > "$ARBEIT/weiter-caddy2.log" 2>&1 < /dev/null; RC=$?
tail -12 "$ARBEIT/weiter-caddy2.log"
gleich "--weiter caddy (DNS-Prüfung im Test übersprungen): Exit-Code 0" 0 "$RC"
pruefe "Caddy installiert, Site-Dateien nur geprüft (Testmodus)" bash -c "command -v caddy && [ ! -e /etc/caddy/conf.d/fampad.caddy ]"
enthaelt "Caddy ist in der Liste als erledigt markiert" /root/umzug-offen.txt "-> erledigt"
printf '%s\n' "nein" | "${UMZUG[@]}" --weiter wetter > "$ARBEIT/weiter-wetter1.log" 2>&1; RC=$?
gleich "--weiter wetter ohne 'ja': startet nichts, Exit-Code 0" 0 "$RC"
pruefe "ohne 'ja' keine Wetter-Regel" bash -c "! grep -q 'lx-fampad-weather' /etc/sudoers.d/lx-fampad"
printf '%s\n' "ja" | "${UMZUG[@]}" --weiter wetter > "$ARBEIT/weiter-wetter2.log" 2>&1; RC=$?
tail -8 "$ARBEIT/weiter-wetter2.log"
gleich "--weiter wetter nach 'ja': Exit-Code 0" 0 "$RC"
pruefe "Wetter-Neustart-Regel in der sudo-Datei (--wetter-starten)" bash -c "grep -q 'restart lx-fampad-weather' /etc/sudoers.d/lx-fampad"
pruefe "Wetter in der Liste als erledigt markiert" grep -qE 'Wetter-Dienst hier starten.*-> erledigt' /root/umzug-offen.txt
"${UMZUG[@]}" --weiter muell > "$ARBEIT/weiter-muell.log" 2>&1 < /dev/null; RC=$?
gleich "--weiter muell ohne Müll in der Sicherung: Exit-Code 0, nichts zu tun" 0 "$RC"
enthaelt "Meldung: nichts zu tun" "$ARBEIT/weiter-muell.log" "nichts zu tun"
# Müll vortäuschen (nur die Antwortdatei; die Sicherung enthält keinen Müll): der Checkout von lx wird als root benutzt, also muss er sauber sein
printf 'MUELL=1\nMUELL_LINK=1\n' >> /root/.umzug-antworten
echo "# Manipulation" >> "$LXHOME/lx-fampad/deploy/README.md"
printf '%s\n' "ja" | "${UMZUG[@]}" --weiter muell > "$ARBEIT/weiter-muell2.log" 2>&1; RC=$?
gleich "--weiter muell mit verändertem Checkout (deploy/): Exit-Code 1, nichts als root ausgeführt" 1 "$RC"
enthaelt "Meldung: Checkout weicht vom Code-Stand ab" "$ARBEIT/weiter-muell2.log" "weicht vom Code-Stand"
runuser -u lx -- git -C "$LXHOME/lx-fampad" checkout -- deploy/README.md
# versteckte Änderungen (assume-unchanged) und eine fremde Datei in deploy/ zählen ebenfalls
runuser -u lx -- git -C "$LXHOME/lx-fampad" update-index --assume-unchanged deploy/README.md
echo "# Versteckte Manipulation" >> "$LXHOME/lx-fampad/deploy/README.md"
printf '%s\n' "ja" | "${UMZUG[@]}" --weiter muell > "$ARBEIT/weiter-muell2b.log" 2>&1; RC=$?
gleich "--weiter muell mit per assume-unchanged versteckter Änderung: Exit-Code 1" 1 "$RC"
runuser -u lx -- git -C "$LXHOME/lx-fampad" update-index --no-assume-unchanged deploy/README.md
runuser -u lx -- git -C "$LXHOME/lx-fampad" checkout -- deploy/README.md
echo "echo boese" > "$LXHOME/lx-fampad/deploy/zusatz.sh"
printf '%s\n' "ja" | "${UMZUG[@]}" --weiter muell > "$ARBEIT/weiter-muell2c.log" 2>&1; RC=$?
gleich "--weiter muell mit fremder (nicht verfolgter) Datei in deploy/: Exit-Code 1" 1 "$RC"
rm -f "$LXHOME/lx-fampad/deploy/zusatz.sh"
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemd-analyze; chmod 755 /usr/local/sbin/systemd-analyze     # Attrappe (kein systemd im Container)
printf '%s\n' "ja" | "${UMZUG[@]}" --weiter muell > "$ARBEIT/weiter-muell3.log" 2>&1; RC=$?
tail -8 "$ARBEIT/weiter-muell3.log"
gleich "--weiter muell mit sauberem Checkout: Exit-Code 0" 0 "$RC"
pruefe "Müll-Einheit installiert" test -f /etc/systemd/system/lx-fampad-waste.service
pruefe "sudo-Regel für den Müll-Dienst ergänzt (und gültig), Wetter-Regel bleibt" bash -c "grep -q 'restart lx-fampad-waste' /etc/sudoers.d/lx-fampad && grep -q 'restart lx-fampad-weather' /etc/sudoers.d/lx-fampad && visudo -cf /etc/sudoers.d/lx-fampad"
pruefe "Müll in der Liste als erledigt markiert" grep -qE 'Müll-Dienst.*-> erledigt' /root/umzug-offen.txt
rm -f /usr/local/sbin/systemd-analyze
"${UMZUG[@]}" --weiter pruefung > "$ARBEIT/weiter-pruefung.log" 2>&1 < /dev/null; RC=$?
gleich "--weiter pruefung: Exit-Code 0" 0 "$RC"
enthaelt "Abschlussprüfung bestanden" "$ARBEIT/weiter-pruefung.log" "Abschlussprüfung"

echo
echo "== 8. --aktualisieren: neuere Sicherung einspielen (Umzug bei laufendem Altserver)"
# Der "Altserver" hat inzwischen etwas geändert: Name der Familie ändern und eine zweite, neuere Sicherung erzeugen
FAMILIE_VORHER="$(psql_db lx_fampad 'select name from families limit 1')"
psql_db lx_fampad "update families set name = 'Testfamilie-neu'" >/dev/null
sleep 1
/usr/local/sbin/lx-fampad-backup >/dev/null 2>&1
NEU="$(cat /var/backups/lx-fampad/LATEST)"
cp -r "/var/backups/lx-fampad/$NEU" /root/sicherung/
chown -R root:root /root/sicherung; chmod -R go-w /root/sicherung
psql_db lx_fampad "update families set name = '$FAMILIE_VORHER'" >/dev/null      # der "neue Server" steht wieder auf dem alten Stand
printf '\nE2EE_PW_BACKUP=true\n' >> /etc/lx-fampad/env                          # die env dieses Servers weicht jetzt von der Sicherung ab (Schalter), der AUTH_SECRET_KEY bleibt gleich
# Die ältere (erste) Sicherung: ausdrückliche Rückfrage, ohne das Wort wird nichts verändert
printf '%s\n' "2" "nein" | "${UMZUG[@]}" --aktualisieren > "$ARBEIT/akt-alt.log" 2>&1; RC=$?
gleich "--aktualisieren mit der älteren Sicherung ohne das Wort aelter: Exit-Code 0, nichts verändert" 0 "$RC"
enthaelt "Rückfrage: nicht neuer als die zuletzt eingespielte" "$ARBEIT/akt-alt.log" "NICHT neuer als die zuletzt eingespielte"
gleich "Familie unverändert nach der Rückfrage" "$FAMILIE_VORHER" "$(psql_db lx_fampad 'select name from families limit 1')"
printf '%s\n' "" "$KEY" "nein" | "${UMZUG[@]}" --aktualisieren > "$ARBEIT/akt0.log" 2>&1; RC=$?
gleich "--aktualisieren mit falschem Bestätigungswort: Exit-Code 0, nichts verändert" 0 "$RC"
gleich "Familie unverändert (Stand des neuen Servers)" "$FAMILIE_VORHER" "$(psql_db lx_fampad 'select name from families limit 1')"
# Der Server ist schon live (Caddy erledigt): ein zweites Wort ist nötig
printf '%s\n' "" "$KEY" "ersetzen" "nein" | "${UMZUG[@]}" --aktualisieren > "$ARBEIT/akt0b.log" 2>&1; RC=$?
gleich "--aktualisieren auf einem schon produktiven Server ohne das Wort verlieren: Exit-Code 0, nichts verändert" 0 "$RC"
enthaelt "Warnung: Änderungen landen in der umbenannten Datenbank" "$ARBEIT/akt0b.log" "landet in der UMBENANNTEN Datenbank"
gleich "Familie unverändert (zweites Wort fehlte)" "$FAMILIE_VORHER" "$(psql_db lx_fampad 'select name from families limit 1')"
gleich "keine umbenannte Datenbank angelegt" 0 "$(psql_db postgres "select count(*) from pg_database where datname like 'lx_fampad_vor_%'")"
printf '%s\n' "" "$KEY" "ersetzen" "verlieren" | "${UMZUG[@]}" --aktualisieren 2>&1 | tee "$ARBEIT/akt1.log" | tail -25
RC=${PIPESTATUS[1]}
gleich "--aktualisieren: Exit-Code 0" 0 "$RC"
enthaelt "die neueste Sicherung wurde zur Auswahl angeboten" "$ARBEIT/akt1.log" "$NEU"
enthaelt "Achtung-Satz nennt Datum und Uhrzeit der Sicherung" "$ARBEIT/akt1.log" "vom $(sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$/\3.\2.\1 \4:\5:\6/' <<<"$NEU") UTC"
enthaelt "AUTH_SECRET_KEY: gleich (nur Vergleich, kein Wert)" "$ARBEIT/akt1.log" "GLEICH wie auf diesem Server"
enthaelt "abweichender Schalter wird angezeigt" "$ARBEIT/akt1.log" "E2EE_PW_BACKUP: auf diesem Server an, in der Sicherung nicht gesetzt"
enthaelt "Abweichung steht als Hinweis in der Liste" /root/umzug-offen.txt "E2EE_PW_BACKUP"
pruefe "die env dieses Servers blieb (gleicher Schlüssel): E2EE_PW_BACKUP=true steht noch drin" grep -q '^E2EE_PW_BACKUP=true' /etc/lx-fampad/env
gleich "Datenbank stammt aus der neueren Sicherung" "Testfamilie-neu" "$(psql_db lx_fampad 'select name from families limit 1')"
gleich "die bisherige Datenbank blieb umbenannt erhalten (genau eine)" 1 "$(psql_db postgres "select count(*) from pg_database where datname like 'lx_fampad_vor_%'")"
enthaelt "Hinweis zum späteren Löschen (Personendaten)" "$ARBEIT/akt1.log" "DROP DATABASE lx_fampad_vor_"
enthaelt "Liste nennt das Löschen der alten Datenbank" /root/umzug-offen.txt "DROP DATABASE lx_fampad_vor_"
pruefe "API antwortet mit db ok" bash -c "curl -fsS http://127.0.0.1:4400/api/v1/health | grep -q '\"db\":\"ok\"'"
pruefe "sudo-Regeln nach dem erneuten Bau: Neustart von lx-fampad, Wetter UND Müll" bash -c "grep -q 'restart lx-fampad-weather' /etc/sudoers.d/lx-fampad && grep -q 'restart lx-fampad-waste' /etc/sudoers.d/lx-fampad && grep -q 'restart lx-fampad\b' /etc/sudoers.d/lx-fampad"
pruefe "gemerkt: neue Sicherung und alte Datenbank" bash -c "grep -q 'SICHERUNG=/root/sicherung/$NEU' /root/.umzug-antworten && grep -q '^ALTE_DB=lx_fampad_vor_' /root/.umzug-antworten"
enthaelt "Liste: aktualisieren als erledigt" /root/umzug-offen.txt "-> erledigt"

echo
echo "== 9. Schlüsselhygiene: der private Schlüssel nirgends auf der Platte, nirgends in der Prozessliste"
touch /tmp/monitor.stop; wait "$MONITOR" 2>/dev/null
FUNDE="$(grep -rIlF -- "$KEY" /etc /root /srv /var /tmp /dev/shm /home /run 2>/dev/null || true)"
if [ -z "$FUNDE" ]; then ok "der private Schlüssel liegt nirgends auf der Platte (gesucht in /etc /root /srv /var /tmp /dev/shm /home /run)"; else fehl "Schlüssel gefunden in: $FUNDE"; fi
LECKS="$(sort -u "$ARBEIT/leck.txt" 2>/dev/null | tr '\n' ' ')"
if [ -z "$LECKS" ]; then ok "während des ganzen Laufs (Probelauf, Pause, Neustarts, Aktualisieren) war der Schlüssel nie in Argumenten oder Umgebung eines Prozesses (Abfrage alle 50 ms)"; else fehl "Schlüssel in der Prozessliste: $LECKS"; fi
pruefe "Antwortdatei enthält keinen Schlüssel (Endstand)" bash -c "! grep -q 'AGE-SECRET-KEY' /root/.umzug-antworten"
pruefe "Antwortdatei, Parameterdatei, Liste, Log, Bericht: nirgends Schlüsselmaterial" bash -c "! grep -qF -f '$ARBEIT/key-nur.txt' /root/.umzug-antworten /root/umzug.params /root/umzug-offen.txt /root/umzug-lauf.log /root/umzug-bericht.txt"
pruefe "keine Wegwerf-Dateien in /run übrig (auch nach Fehlern und Abbrüchen)" bash -c "! ls -d /run/umzug.* 2>/dev/null | grep -q ."

echo
if [ "$FEHLER" = 0 ]; then echo "SZENARIO umzug: BESTANDEN"; else echo "SZENARIO umzug: FEHLER"; exit 1; fi
