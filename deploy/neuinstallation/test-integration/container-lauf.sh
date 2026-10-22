#!/usr/bin/env bash
# Läuft IM Debian-13-Container (aufgerufen von test-integration.sh): Szenario "neu" oder "wiederherstellung".
# Nur für Tests: legt eine Attrappe für systemctl an (kein systemd im Container) und prüft das Ergebnis des Skripts.
# Bricht ab, wenn es nicht in einem Docker-Container läuft (die Attrappe und die Testdaten dürfen nie auf einen echten Server).
set -euo pipefail
[ -f /.dockerenv ] || { echo "container-lauf.sh läuft nur in einem Docker-Container (/.dockerenv fehlt): Abbruch" >&2; exit 99; }
export LC_ALL=C.UTF-8
SZENARIO="${1:?neu|wiederherstellung}"
REPO_QUELLE=/repo            # aus dem Tarball des Hosts entpackt (Kopie, nicht der Arbeitsbaum)
ARBEIT=/work                 # vom Host eingebunden: Sicherung, Testschlüssel (nur Testdaten)
SKRIPT="$REPO_QUELLE/deploy/neuinstallation/bootstrap-server.sh"
LXHOME=/home/lx

ok() { echo "  ok    $*"; }
fehl() { echo "  FEHLT $*"; FEHLER=1; }
FEHLER=0
pruefe() { local t="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$t"; else fehl "$t"; fi; }

echo "== Vorbereitung des Containers (nur Testhilfen)"
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates curl iproute2 age openssh-client >/dev/null 2>&1
install -m 755 "$REPO_QUELLE/deploy/neuinstallation/test-integration/fake-systemctl.sh" /usr/bin/systemctl
printf '#!/bin/sh\nexit 0\n' > /usr/bin/journalctl; chmod 755 /usr/bin/journalctl

if [ "$SZENARIO" = neu ]; then
  [ -f "$ARBEIT/key.txt" ] || age-keygen -o "$ARBEIT/key.txt" >/dev/null 2>&1
  PUB="$(age-keygen -y "$ARBEIT/key.txt")"
  ssh-keygen -q -t ed25519 -N "" -f "$ARBEIT/nas_key" -C nas-test
  cat > "$ARBEIT/params.txt" <<EOF
# Testparameter (nur Öffentliches)
SWAP_MB=0
BACKUP_AGE_RECIPIENTS=$PUB
BACKUP_NAS_PUBKEY=$(cut -d' ' -f1-2 "$ARBEIT/nas_key.pub")
BACKUP_NAS_IP=203.0.113.7
RELEASE_CERT_SHA256=AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99
WEATHER_ENABLED=true
WEATHER_PLACE=Salz
WEATHER_STATION_MAC=aa:bb:cc:dd:ee:ff
WEATHER_BBOX=50.49,7.94,50.53,7.99
EOF
fi
# Parameterdatei und Sicherung liegen im Container (root-eigen, nicht für andere schreibbar): das Skript verlangt das
install -m 600 -o root -g root "$ARBEIT/params.txt" /root/params.txt
PARAMS=/root/params.txt
# --swap-ok: ein Container zeigt den Swap des Hosts (/proc/swaps); im Test wird der Schlüssel nur über eine Pipe gelesen
ARGS=(--params "$PARAMS" --lx-anlegen --ohne-systemd --swap-ok)
if [ "$SZENARIO" = wiederherstellung ]; then
  LAUF="$(ls -1 "$ARBEIT/sicherung" | sort | tail -1)"
  mkdir -p /root/sicherung
  cp -r "$ARBEIT/sicherung/$LAUF" /root/sicherung/
  chown -R root:root /root/sicherung; chmod -R go-w /root/sicherung
  ARGS+=(--sicherung "/root/sicherung/$LAUF")
fi

echo "== 1. Trockenlauf (verändert nichts)"
if [ "$SZENARIO" = wiederherstellung ]; then
  bash "$SKRIPT" --dry-run "${ARGS[@]}" --identity-stdin < /dev/null 2>&1 | tail -25
else
  bash "$SKRIPT" --dry-run "${ARGS[@]}" 2>&1 | tail -12
fi
[ ! -d /srv/fampad/server ] && ok "Trockenlauf hat nichts angelegt" || fehl "Trockenlauf hat Verzeichnisse angelegt"

echo "== 2. Pakete und Benutzer"
if [ "$SZENARIO" = wiederherstellung ]; then
  bash "$SKRIPT" "${ARGS[@]}" --identity-stdin --phase pruefen,pakete,system < "$ARBEIT/key.txt"
else
  bash "$SKRIPT" "${ARGS[@]}" --phase pruefen,pakete,system
fi

echo "== 3. Checkout vorbereiten (der Test nimmt den Stand aus dem Tarball statt GitHub)"
cp -r "$REPO_QUELLE" "$LXHOME/lx-fampad"
chown -R lx:lx "$LXHOME/lx-fampad"
runuser -u lx -- bash -c "cd '$LXHOME/lx-fampad' && git init -q && git config user.email t@example.org && git config user.name test && git add -A && git commit -q -m 'Teststand'"

echo "== 4. Rest des Skripts"
if [ "$SZENARIO" = wiederherstellung ]; then
  bash "$SKRIPT" "${ARGS[@]}" --identity-stdin --ab code < "$ARBEIT/key.txt"
else
  bash "$SKRIPT" "${ARGS[@]}" --ab code
fi

echo "== 4b. Caddy: DNS zeigt woanders hin, also dürfen noch keine Site-Dateien entstehen"
[ ! -e /etc/caddy/conf.d/fampad.caddy ] && ok "keine Site-Dateien ohne passenden DNS-Eintrag" || fehl "Site-Dateien trotz falschem DNS"
CADDY_ARGS=("${ARGS[@]}"); [ "$SZENARIO" = neu ] || CADDY_ARGS+=(--identity-stdin)
CADDY_AUSGABE="$(bash "$SKRIPT" "${CADDY_ARGS[@]}" --phase caddy --dns-pruefung-ueberspringen < "$ARBEIT/key.txt" 2>&1)"
grep -q 'Site-Dateien aus dem Repository sind gültig' <<<"$CADDY_AUSGABE" && ok "Site-Dateien aus dem Repository sind gültig (caddy validate)" || fehl "Site-Dateien aus dem Repository nicht gültig: $CADDY_AUSGABE"
pruefe "mit --ohne-systemd werden nie Site-Dateien installiert" bash -c "[ ! -e /etc/caddy/conf.d/fampad.caddy ]"

echo "== 5. Prüfungen"
pruefe "API antwortet mit db ok" bash -c "curl -fsS http://127.0.0.1:4400/api/v1/health | grep -q '\"db\":\"ok\"'"
pruefe "ntfy antwortet" bash -c "curl -fsS http://127.0.0.1:2586/v1/health | grep -q '\"healthy\":true'"
pruefe "env root:root 600" bash -c "[ \"\$(stat -c %U:%G:%a /etc/lx-fampad/env)\" = root:root:600 ]"
pruefe "migrate.env root:root 600" bash -c "[ \"\$(stat -c %U:%G:%a /etc/lx-fampad/migrate.env)\" = root:root:600 ]"
pruefe "ntfy-token 600" bash -c "[ \"\$(stat -c %a /etc/lx-fampad/ntfy-token)\" = 600 ]"
pruefe "Datenbank gehört der Migrationsrolle" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -tAc \"select pg_get_userbyid(datdba) from pg_database where datname='lx_fampad'\")\" = lx_fampad_migrate ]"
pruefe "Tabellen gehören der Migrationsrolle (nicht postgres)" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -d lx_fampad -tAc \"select count(*) from pg_tables where schemaname in ('public','drizzle') and tableowner <> 'lx_fampad_migrate'\")\" = 0 ]"
pruefe "Laufzeitrolle kann keine Tabelle anlegen" bash -c "! PGPASSWORD=\"\$(sed -nE 's|^DATABASE_URL=postgres://[^:]+:([^@]*)@.*|\\1|p' /etc/lx-fampad/env)\" psql -h 127.0.0.1 -U lx_fampad -d lx_fampad -c 'create table probe(x int)'"
pruefe "Laufzeitrolle kann lesen" bash -c "PGPASSWORD=\"\$(sed -nE 's|^DATABASE_URL=postgres://[^:]+:([^@]*)@.*|\\1|p' /etc/lx-fampad/env)\" psql -h 127.0.0.1 -U lx_fampad -d lx_fampad -tAc 'select count(*) from families'"
pruefe "sudoers gültig" visudo -cf /etc/sudoers.d/lx-fampad
pruefe "sudoers enthält KEINE Wetter-Regel (ohne --wetter-starten)" bash -c "! grep -q 'lx-fampad-weather' /etc/sudoers.d/lx-fampad"
pruefe "Wetter-Einheit installiert, aber nicht gestartet" bash -c "[ -f /etc/systemd/system/lx-fampad-weather.service ] && ! [ -f /run/fake-systemctl/lx-fampad-weather.pid ]"
pruefe "Haupt-Caddyfile enthält nur die Importzeile" bash -c "grep -q '^import /etc/caddy/conf.d/\*.caddy' /etc/caddy/Caddyfile"
pruefe "assetlinks.json ist gültiges JSON mit Fingerabdruck" bash -c "grep -q 'AA:BB:CC' /srv/fampad/well-known/assetlinks.json && node -e 'JSON.parse(require(\"fs\").readFileSync(\"/srv/fampad/well-known/assetlinks.json\"))'"

if [ "$SZENARIO" = neu ]; then
  echo "== 6. Testdaten anlegen und Sicherung erzeugen"
  node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --family "Testfamilie" >/dev/null
  pruefe "Familie angelegt" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -d lx_fampad -tAc 'select count(*) from families')\" = 1 ]"
  # Marker in backup.conf: gelangt ins Konfigurationsarchiv, darf bei der Wiederherstellung NICHT übernommen werden (root lädt backup.conf per source)
  echo 'INCLUDE_APK=0   # MARKER-AUS-DER-SICHERUNG' >> /etc/lx-fampad-backup/backup.conf
  /usr/local/sbin/lx-fampad-backup >/dev/null
  rm -rf "$ARBEIT/sicherung"; mkdir -p "$ARBEIT/sicherung"
  cp -r "/var/backups/lx-fampad/$(cat /var/backups/lx-fampad/LATEST)" "$ARBEIT/sicherung/"
  sed -n 's/^AUTH_SECRET_KEY=//p' /etc/lx-fampad/env | sha256sum | cut -d' ' -f1 > "$ARBEIT/auth.sha"
  sed -n 's/^DATABASE_URL=//p' /etc/lx-fampad/env | sha256sum | cut -d' ' -f1 > "$ARBEIT/dburl.sha"
  ok "Sicherung liegt in $ARBEIT/sicherung"
  pruefe "Sicherungs-Timer-Einheit und Dienst installiert" bash -c "[ -f /etc/systemd/system/lx-fampad-backup.timer ] && [ -f /etc/systemd/system/lx-fampad-backup.service ]"
  pruefe "authorized_keys des NAS (nur lesen, rrsync)" bash -c "grep -q 'restrict,from=\"203.0.113.7\",command=\"/usr/bin/rrsync -ro /var/backups/lx-fampad\"' /var/lib/lxbackup/.ssh/authorized_keys"
else
  echo "== 6. Wiederherstellung prüfen"
  pruefe "AUTH_SECRET_KEY stammt aus der Sicherung" bash -c "[ \"\$(sed -n 's/^AUTH_SECRET_KEY=//p' /etc/lx-fampad/env | sha256sum | cut -d' ' -f1)\" = \"\$(cat $ARBEIT/auth.sha)\" ]"
  pruefe "DATABASE_URL (Passwort) stammt aus der Sicherung" bash -c "[ \"\$(sed -n 's/^DATABASE_URL=//p' /etc/lx-fampad/env | sha256sum | cut -d' ' -f1)\" = \"\$(cat $ARBEIT/dburl.sha)\" ]"
  pruefe "Familie aus der Sicherung ist da" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -d lx_fampad -tAc 'select count(*) from families')\" = 1 ]"
  pruefe "Name der Familie stimmt" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -d lx_fampad -tAc 'select name from families limit 1')\" = Testfamilie ]"
  pruefe "keine Wegwerf-Datenbank übrig" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -tAc \"select count(*) from pg_database where datname like 'lx_fampad_wieder%'\")\" = 0 ]"
  pruefe "ntfy-Token aus der Sicherung ist gültig (Benutzerdatenbank wiederhergestellt)" bash -c "runuser -u ntfy -- ntfy token --config /etc/ntfy/server.yml list | grep -q \"\$(head -n1 /etc/lx-fampad/ntfy-token)\""
  pruefe "NTFY_TOKEN in der env = Token-Datei" bash -c "[ \"\$(sed -n 's/^NTFY_TOKEN=//p' /etc/lx-fampad/env)\" = \"\$(head -n1 /etc/lx-fampad/ntfy-token)\" ]"
  pruefe "ntfy-Datenbank gehört dem Benutzer ntfy" bash -c "[ \"\$(stat -c %U /var/lib/ntfy/user.db)\" = ntfy ]"
  pruefe "recipients.txt der Sicherung wiederhergestellt" test -s /etc/lx-fampad-backup/recipients.txt
  pruefe "backup.conf aus der Sicherung wurde NICHT übernommen" bash -c "! grep -q MARKER-AUS-DER-SICHERUNG /etc/lx-fampad-backup/backup.conf"
  pruefe "Modi in /etc/lx-fampad: nur Dateien, alle 600 root:root" bash -c "[ -z \"\$(find /etc/lx-fampad -mindepth 1 \\( ! -type f -o ! -perm 600 -o ! -user root \\) -print)\" ]"
  SCHLUESSEL="$(grep '^AGE-SECRET-KEY-' "$ARBEIT/key.txt")"
  FUNDE="$(grep -rIlF -- "$SCHLUESSEL" /etc /root /srv /var /tmp /dev/shm /home /run 2>/dev/null || true)"
  [ -z "$FUNDE" ] && ok "der private Schlüssel liegt nirgends auf der Platte (gesucht in /etc /root /srv /var /tmp /dev/shm /home /run)" || fehl "Schlüssel gefunden in: $FUNDE"
  SCHLUESSEL=""
  echo "== 7. Wiederholung (muss ohne Änderung durchlaufen; Datenbank nicht leer: kein erneutes Einspielen; ntfy ohne Neustart)"
  NTFY_PID_VORHER="$(cat /run/fake-systemctl/ntfy.pid)"
  # fehlende Teile werden auch bei gleichem AUTH_SECRET_KEY wiederhergestellt ("nur wenn fehlt")
  TOKEN_VORHER="$(head -n1 /etc/lx-fampad/ntfy-token)"
  rm -f /etc/lx-fampad/ntfy-token
  WIEDERHOLUNG="$(bash "$SKRIPT" "${ARGS[@]}" --identity-stdin < "$ARBEIT/key.txt" 2>&1)"
  grep -E 'übersprungen|bleibt unverändert|stammt schon|nicht leer|kein Neustart' <<<"$WIEDERHOLUNG" | head -8 || true
  pruefe "Wiederholung meldet: Datenbank nicht leer, kein erneutes Einspielen" grep -q 'nicht leer' <<<"$WIEDERHOLUNG"
  pruefe "fehlendes ntfy-token wurde trotz gleichem AUTH_SECRET_KEY aus der Sicherung ergänzt" bash -c "[ \"\$(head -n1 /etc/lx-fampad/ntfy-token)\" = '$TOKEN_VORHER' ]"
  pruefe "Wiederholung startet ntfy nicht neu" bash -c "[ \"\$(cat /run/fake-systemctl/ntfy.pid)\" = '$NTFY_PID_VORHER' ]"
  pruefe "Familie nach Wiederholung unverändert" bash -c "[ \"\$(cd / && runuser -u postgres -- psql -d lx_fampad -tAc 'select count(*) from families')\" = 1 ]"
  pruefe "Wiederholung ohne --wetter-starten fügt keine Wetter-Regel hinzu" bash -c "! grep -q 'lx-fampad-weather' /etc/sudoers.d/lx-fampad"
fi
echo
if [ "$FEHLER" = 0 ]; then echo "SZENARIO $SZENARIO: BESTANDEN"; else echo "SZENARIO $SZENARIO: FEHLER"; exit 1; fi
