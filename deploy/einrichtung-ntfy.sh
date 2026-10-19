#!/usr/bin/env bash
# Einrichtung ntfy (selbst gehostet, UnifiedPush) unter https://ntfy.familie.lx-labs.dev (deploy/README.md, Abschnitt 7).
# Idempotent: mehrfaches Ausführen ist gefahrlos.
#   1. Vorabprüfungen (nichts wird verändert, wenn eine fehlschlägt)
#   2. ntfy installieren: Version exakt gepinnt, aus dem offiziellen apt-Repository mit geprüftem Schlüssel-Fingerabdruck
#      (Fallback: GitHub-.deb mit gepinnter SHA-256), apt-mark hold
#   3. Systembenutzer ntfy, /var/lib/ntfy, /var/cache/ntfy, /etc/ntfy/server.yml, systemd-Härtung, Dienst starten
#   4. Benutzer fampad-server mit Token (nur Schreibrecht auf 'fampad-*') -> /etc/lx-fampad/ntfy-token (root, 0600)
#   5. Caddy: NUR /etc/caddy/conf.d/ntfy.caddy. Das Haupt-Caddyfile (gehört lx-labs.dev) wird NIE geschrieben.
#      Ablauf wie einrichtung-2.sh: sichern, validieren, erst dann reload, danach lx-labs.dev + familie + ntfy prüfen;
#      bei JEDEM Fehler Rückfall (vorherige ntfy.caddy zurück bzw. entfernen, reload, lx-labs.dev prüfen).
# /etc/lx-fampad/env wird NICHT verändert; das Skript meldet nur, was einzutragen ist.
#
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-ntfy.sh [--dry-run]
#   --dry-run  macht nur die Prüfungen und schreibt/installiert/lädt nichts.
set -Eeuo pipefail

# --- Festwerte ---------------------------------------------------------------------------------------------------------
NTFY_VERSION="2.28.0"                      # exakt gepinnt (Release vom 27.08.2026, älter als 14 Tage); neuere erst nach 14 Tagen Wartezeit
NTFY_FPR="55BA774A6F5EE67431E4B6B7CFDB962D4F1EC4AF"   # Schlüssel des ntfy-apt-Repositorys (docs.ntfy.sh/install, vor Änderung dort gegenlesen)
NTFY_APT_URL="https://archive.ntfy.sh/apt"
# Fallback (nur wenn das Repository die Version nicht mehr führt): offizielles Release-.deb, SHA-256 aus den GitHub-Release-Metadaten
NTFY_DEB_URL="https://github.com/binwiederhier/ntfy/releases/download/v${NTFY_VERSION}/ntfy_${NTFY_VERSION}_linux_amd64.deb"
NTFY_DEB_SHA256="48e95870ff4b1e30df8648f40e2d7f4a96956e93dc75fd07f770f726c1a4f2c5"
NTFY_PORT=2586                             # derselbe Wert steht in deploy/ntfy/server.yml und deploy/ntfy/ntfy.caddy
NTFY_HOST="ntfy.familie.lx-labs.dev"
NTFY_USER=ntfy
PUSH_USER="fampad-server"                  # ntfy-Benutzer des Fastify-Servers
PUSH_TOPICS='fampad-*'
TOKEN_FILE=/etc/lx-fampad/ntfy-token
ENV_FILE=/etc/lx-fampad/env
CADDYFILE=/etc/caddy/Caddyfile
SITE=/etc/caddy/conf.d/ntfy.caddy
FAMPAD_SITE=/etc/caddy/conf.d/fampad.caddy
IMPORT_RE='^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy'
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_MAIN="/etc/caddy/Caddyfile.vor-ntfy.${STAMP}"   # nur Sicherung zum Nachlesen; das Haupt-Caddyfile wird nie zurückgeschrieben
BACKUP_SITE="/etc/caddy/conf.d/ntfy.caddy.vor-ntfy.${STAMP}.bak"   # endet nicht auf .caddy: wird nicht importiert

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "Aufruf: sudo bash $0 [--dry-run]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
  echo "Bitte als Benutzer lx starten:  sudo bash $0 [--dry-run]" >&2
  exit 1
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(getent passwd "$SUDO_USER" | cut -d: -f6)/lx-fampad"
SRC_YML="$SELF_DIR/ntfy/server.yml"
SRC_CADDY="$SELF_DIR/ntfy/ntfy.caddy"

ARMED=0          # 1, sobald ntfy.caddy angefasst wurde: ab dann löst jeder Fehler den Rückfall aus
WORK=""
HAD_SITE=0
MAIN_SUM=""

aufraeumen() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }

# Rückfall: nur ntfy.caddy (vorherige Fassung oder entfernen), nie das Haupt-Caddyfile
zuruecksetzen() {
  trap - ERR INT TERM
  ARMED=0
  echo "!!  Fehler: ntfy.caddy wird zurückgesetzt." >&2
  if [ "$HAD_SITE" = 1 ] && [ -f "$BACKUP_SITE" ]; then
    cp -p "$BACKUP_SITE" "$SITE" || rm -f "$SITE"
  else
    rm -f "$SITE"
  fi
  systemctl reload caddy || true
  echo "    lx-labs.dev:  $(curl -sI --max-time 10 https://lx-labs.dev 2>/dev/null | head -1)" >&2
  echo "    Haupt-Caddyfile wurde nicht verändert. Ursache: journalctl -u caddy -n 50; danach das Skript erneut ausführen." >&2
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
bei_abbruch() {
  trap - ERR INT TERM
  echo "!!  Abbruch." >&2
  if [ "$ARMED" = 1 ]; then zuruecksetzen; fi
  aufraeumen
  exit 130
}
trap 'bei_fehler $LINENO' ERR
trap bei_abbruch INT TERM
trap aufraeumen EXIT

tue() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }
fehler() { echo "FEHLER: $*" >&2; exit 1; }

# --- 1. Vorabprüfungen -----------------------------------------------------------------------------------------------------
echo "==> 1/6 Prüfungen$([ "$DRY" = 1 ] && echo ' (Trockenlauf: es wird nichts verändert)')"

[ "$(dpkg --print-architecture)" = amd64 ] || fehler "nur amd64 vorgesehen (gepinnte Prüfsumme gilt für amd64)"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = debian ] || echo "    Hinweis: Debian erwartet, gefunden: ${ID:-unbekannt}"
for b in curl caddy systemctl ss runuser install sha256sum awk; do
  command -v "$b" >/dev/null || fehler "$b fehlt"
done
[ -f "$SRC_YML" ] && [ -f "$SRC_CADDY" ] || fehler "deploy/ntfy/server.yml oder ntfy.caddy fehlt (Repository $REPO aktuell? git pull)"
grep -q "listen-http: \"127.0.0.1:${NTFY_PORT}\"" "$SRC_YML" || fehler "server.yml lauscht nicht auf 127.0.0.1:${NTFY_PORT}"
grep -q "127.0.0.1:${NTFY_PORT}" "$SRC_CADDY" || fehler "ntfy.caddy zeigt nicht auf 127.0.0.1:${NTFY_PORT}"
[ -f "$CADDYFILE" ] || fehler "$CADDYFILE fehlt"

# Importzeile MUSS schon im Haupt-Caddyfile stehen; das Skript ergänzt sie nie selbst
if ! grep -qsE "$IMPORT_RE" "$CADDYFILE"; then
  cat >&2 <<EOF
FEHLER: In $CADDYFILE fehlt die Zeile
    import /etc/caddy/conf.d/*.caddy
Das Skript ändert das Haupt-Caddyfile (lx-labs.dev) nie. Meist hat ein lx-labs-Deploy die Zeile entfernt.
Zuerst  sudo bash ~/lx-fampad/deploy/einrichtung-2.sh  (stellt sie mit Sicherung und Prüfung wieder her) oder
Schritt 6 in deploy/README.md ausführen, danach dieses Skript erneut starten.
EOF
  exit 1
fi
echo "    Importzeile im Haupt-Caddyfile vorhanden."

# fampad.caddy darf keinen aktiven ntfy-Block enthalten (doppelte Site-Definition)
if [ -f "$FAMPAD_SITE" ] && grep -qE '^ntfy\.familie\.lx-labs\.dev' "$FAMPAD_SITE"; then
  fehler "$FAMPAD_SITE enthält schon einen aktiven ntfy-Block (doppelte Site-Definition). Block dort entfernen (alles ab '^ntfy.familie') und neu starten."
fi

curl -fsI --max-time 10 https://lx-labs.dev >/dev/null || fehler "lx-labs.dev antwortet schon vor der Änderung nicht, Abbruch"
echo "    lx-labs.dev antwortet."
curl -fsS --max-time 10 https://familie.lx-labs.dev/api/v1/health 2>/dev/null | grep -q '"db":"ok"' \
  || echo "    Hinweis: familie.lx-labs.dev/api/v1/health antwortet nicht mit db ok (wird nur nach der Änderung zur Gegenprobe benutzt)."
getent hosts "$NTFY_HOST" >/dev/null || fehler "DNS für $NTFY_HOST fehlt (A-Eintrag, nur DNS/graue Wolke); ohne ihn gibt es kein Zertifikat"
if [ -d /etc/lx-fampad ]; then echo "    /etc/lx-fampad vorhanden."; else
  if [ "$DRY" = 1 ]; then echo "    Hinweis: /etc/lx-fampad fehlt (Teil 1 der Einrichtung)."; else fehler "/etc/lx-fampad fehlt (Teil 1 der Einrichtung)"; fi
fi

# Port frei oder von ntfy belegt?
LISTEN="$(ss -ltnpH "sport = :${NTFY_PORT}" 2>/dev/null || true)"
if [ -n "$LISTEN" ] && ! grep -q '"ntfy"' <<<"$LISTEN"; then
  fehler "Port ${NTFY_PORT} ist von einem anderen Prozess belegt: $LISTEN"
fi
echo "    Port ${NTFY_PORT}: $([ -n "$LISTEN" ] && echo 'von ntfy belegt (Wiederholung)' || echo 'frei')."
INSTALLED="$(dpkg-query -W -f='${Version}' ntfy 2>/dev/null || true)"
echo "    ntfy installiert: ${INSTALLED:-nein} (Ziel $NTFY_VERSION)"
if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$NTFY_VERSION" ]; then
  echo "    Hinweis: andere Version installiert; das Skript ändert sie nicht (Downgrade/Upgrade bewusst von Hand: apt-mark unhold ntfy)."
fi
[ -f "$SITE" ] && HAD_SITE=1
echo "    ntfy.caddy: $([ "$HAD_SITE" = 1 ] && echo 'vorhanden (wird gesichert und ersetzt)' || echo 'neu')"
MAIN_SUM="$(sha256sum "$CADDYFILE" | cut -d' ' -f1)"

if [ "$DRY" = 1 ]; then
  echo "==> Trockenlauf beendet: alle Prüfungen bestanden. Geplant wäre: ntfy $NTFY_VERSION installieren, Dienst auf 127.0.0.1:${NTFY_PORT},"
  echo "    Benutzer $PUSH_USER samt Token nach $TOKEN_FILE, $SITE anlegen (Haupt-Caddyfile bleibt unberührt)."
  exit 0
fi

WORK="$(mktemp -d)"

# --- 2. Installation -------------------------------------------------------------------------------------------------------
echo "==> 2/6 ntfy $NTFY_VERSION installieren"
if [ "$INSTALLED" = "$NTFY_VERSION" ]; then
  echo "    schon installiert."
elif [ -n "$INSTALLED" ]; then
  echo "    übersprungen (andere Version installiert, siehe Hinweis oben)."
else
  command -v gpg >/dev/null || { apt-get update -qq && apt-get install -y --no-install-recommends gnupg; }
  mkdir -p /etc/apt/keyrings
  curl -fsSL --max-time 60 -o "$WORK/ntfy.gpg" "$NTFY_APT_URL/keyring.gpg"
  # Schlüssel prüfen: genau ein Hauptschlüssel, und sein Fingerabdruck ist der gepinnte
  GOT="$(gpg --batch --show-keys --with-colons "$WORK/ntfy.gpg" | awk -F: '$1=="pub"{p=1} $1=="fpr"&&p{print $10; p=0}')"
  [ "$GOT" = "$NTFY_FPR" ] || fehler "Fingerabdruck des ntfy-Schlüssels stimmt nicht (erwartet $NTFY_FPR, gefunden: ${GOT:-keiner}). Nichts installiert."
  install -m 644 -o root -g root "$WORK/ntfy.gpg" /etc/apt/keyrings/ntfy.gpg
  echo "    Schlüssel-Fingerabdruck geprüft: $NTFY_FPR"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/ntfy.gpg] $NTFY_APT_URL stable main" > /etc/apt/sources.list.d/ntfy.list
  apt-get update -qq
  if apt-cache madison ntfy | awk '{print $3}' | grep -Fxq "$NTFY_VERSION"; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "ntfy=$NTFY_VERSION"
  else
    echo "    $NTFY_VERSION steht nicht (mehr) im Repository; Fallback: Release-.deb mit gepinnter SHA-256."
    curl -fsSL --max-time 300 -o "$WORK/ntfy.deb" "$NTFY_DEB_URL"
    echo "$NTFY_DEB_SHA256  $WORK/ntfy.deb" | sha256sum -c - || fehler "Prüfsumme des .deb stimmt nicht, nichts installiert"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$WORK/ntfy.deb"
  fi
  apt-mark hold ntfy >/dev/null
  echo "    installiert und per apt-mark hold festgehalten."
fi
command -v ntfy >/dev/null || fehler "ntfy nicht installiert"

# --- 3. Benutzer, Verzeichnisse, Konfiguration, Härtung, Start ---------------------------------------------------------------
echo "==> 3/6 Benutzer, Konfiguration, Dienst"
getent passwd "$NTFY_USER" >/dev/null || useradd --system --no-create-home --home-dir /var/lib/ntfy --shell /usr/sbin/nologin "$NTFY_USER"
install -d -m 750 -o "$NTFY_USER" -g "$NTFY_USER" /var/lib/ntfy /var/cache/ntfy
install -d -m 755 -o root -g root /etc/ntfy
if [ -f /etc/ntfy/server.yml ] && ! cmp -s "$SRC_YML" /etc/ntfy/server.yml; then
  cp -p /etc/ntfy/server.yml "/etc/ntfy/server.yml.vor-ntfy.${STAMP}.bak"
  echo "    bisherige server.yml gesichert: /etc/ntfy/server.yml.vor-ntfy.${STAMP}.bak"
fi
install -m 640 -o root -g "$NTFY_USER" "$SRC_YML" /etc/ntfy/server.yml
# Härtung als Drop-in (die Paket-Einheit bleibt unverändert)
install -d -m 755 /etc/systemd/system/ntfy.service.d
cat > /etc/systemd/system/ntfy.service.d/haertung.conf <<'EOF'
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
chmod 644 /etc/systemd/system/ntfy.service.d/haertung.conf
systemctl daemon-reload
systemctl enable ntfy >/dev/null 2>&1
systemctl restart ntfy
LOCAL="http://127.0.0.1:${NTFY_PORT}"
OK=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 3 "$LOCAL/v1/health" 2>/dev/null | grep -q '"healthy":true'; then OK=1; break; fi
  sleep 1
done
if [ "$OK" != 1 ]; then
  journalctl -u ntfy -n 30 --no-pager >&2 || true
  fehler "ntfy startet nicht (Log oben). Caddy wurde noch nicht angefasst."
fi
echo "    ntfy läuft auf 127.0.0.1:${NTFY_PORT}."

# --- 4. Benutzer und Token für den Familien-Server ---------------------------------------------------------------------------
echo "==> 4/6 Benutzer $PUSH_USER und Token (nur Schreibrecht auf '$PUSH_TOPICS')"
CFG=/etc/ntfy/server.yml
if runuser -u "$NTFY_USER" -- ntfy user list --config "$CFG" 2>/dev/null | grep -q "user ${PUSH_USER} "; then
  echo "    Benutzer vorhanden."
else
  # Passwort wird nie benutzt oder gespeichert (Zugriff nur per Token); Rolle user, nicht admin
  PW="$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n')"
  NTFY_PASSWORD="$PW" runuser -u "$NTFY_USER" -- ntfy user add --config "$CFG" --role=user "$PUSH_USER" >/dev/null
  unset PW
  echo "    Benutzer angelegt."
fi
runuser -u "$NTFY_USER" -- ntfy access --config "$CFG" "$PUSH_USER" "$PUSH_TOPICS" write-only >/dev/null
echo "    Zugriff: $PUSH_USER darf nur auf '$PUSH_TOPICS' schreiben."

TOKEN=""
if [ -s "$TOKEN_FILE" ]; then
  TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
  if runuser -u "$NTFY_USER" -- ntfy token list --config "$CFG" "$PUSH_USER" 2>/dev/null | grep -Fq "$TOKEN"; then
    echo "    Token in $TOKEN_FILE ist gültig, bleibt unverändert."
  else
    echo "    Token in $TOKEN_FILE ist dem Server unbekannt, wird ersetzt."
    TOKEN=""
  fi
fi
if [ -z "$TOKEN" ]; then
  OUT="$(runuser -u "$NTFY_USER" -- ntfy token add --config "$CFG" --label=lx-fampad "$PUSH_USER")"
  TOKEN="$(grep -o 'tk_[A-Za-z0-9]\+' <<<"$OUT" | head -n1)"
  [ -n "$TOKEN" ] || fehler "Token konnte nicht angelegt werden"
  install -d -m 755 -o root -g root /etc/lx-fampad
  ( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
  echo "    neues Token angelegt."
fi
chown root:root "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
unset OUT

# Lokale Probe der Rechte (Token nie in der Prozessliste: curl liest die Kopfzeile von stdin)
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
mit_token() { printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - -d 'Prüfung' "$1" || true; }
[ "$(http_code -d x "$LOCAL/fampad-pruefung")" = 403 ] || fehler "anonymes Schreiben ist nicht verboten (erwartet 403)"
[ "$(mit_token "$LOCAL/fampad-pruefung")" = 200 ] || fehler "Token darf nicht auf fampad-* schreiben"
[ "$(mit_token "$LOCAL/fremdes-topic")" = 403 ] || fehler "Token darf außerhalb von fampad-* schreiben (erwartet 403)"
echo "    Rechteprobe bestanden (anonym 403, fampad-* 200, fremdes Topic 403)."

# --- 5. Caddy: nur ntfy.caddy ----------------------------------------------------------------------------------------------
echo "==> 5/6 Caddy ($SITE)"
mkdir -p /etc/caddy/conf.d
cp -p "$CADDYFILE" "$BACKUP_MAIN"
echo "    Sicherung des Haupt-Caddyfiles (nur zum Nachlesen): $BACKUP_MAIN"
if [ "$HAD_SITE" = 1 ]; then cp -p "$SITE" "$BACKUP_SITE"; echo "    Sicherung der bisherigen ntfy.caddy: $BACKUP_SITE"; fi
ARMED=1
install -m 644 -o root -g root "$SRC_CADDY" "$SITE"
caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl reload caddy
sleep 3
HEAD="$(curl -fsI --max-time 10 https://lx-labs.dev)"
echo "    lx-labs.dev: ${HEAD%%$'\n'*}"

echo "==> 6/6 Zertifikat für $NTFY_HOST abwarten (bis zu 90 s) und prüfen"
OK=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 "https://${NTFY_HOST}/v1/health" 2>/dev/null | grep -q '"healthy":true'; then OK=1; break; fi
  sleep 2
done
[ "$OK" = 1 ] || { echo "    $NTFY_HOST antwortet nicht über HTTPS (DNS/Zertifikat?)." >&2; false; }
echo "    $NTFY_HOST antwortet über HTTPS."
[ "$(http_code -d x "https://${NTFY_HOST}/fampad-pruefung")" = 403 ] || { echo "    anonymes Schreiben über HTTPS nicht verboten" >&2; false; }
[ "$(mit_token "https://${NTFY_HOST}/fampad-pruefung")" = 200 ] || { echo "    Token-Schreiben über HTTPS schlägt fehl" >&2; false; }
curl -fsI --max-time 10 https://lx-labs.dev >/dev/null
curl -fsS --max-time 10 https://familie.lx-labs.dev/api/v1/health 2>/dev/null | grep -q '"db":"ok"' \
  || { echo "    familie.lx-labs.dev antwortet nicht mehr mit db ok" >&2; false; }
[ "$(sha256sum "$CADDYFILE" | cut -d' ' -f1)" = "$MAIN_SUM" ] || { echo "    Haupt-Caddyfile hat sich während des Laufs geändert (nicht durch dieses Skript)" >&2; false; }
ARMED=0
trap - ERR INT TERM
echo "    lx-labs.dev:      $(curl -sI --max-time 10 https://lx-labs.dev | head -1)"
echo "    familie.lx-labs.dev: ok"

cat <<EOF

Fertig. ntfy $NTFY_VERSION läuft unter https://${NTFY_HOST} (Standard: deny-all).

In /etc/lx-fampad/env eintragen (das Skript ändert die Datei nicht; das Token bleibt in $TOKEN_FILE, root, 0600):
    NTFY_URL=https://${NTFY_HOST}
    NTFY_TOKEN=<Inhalt von $TOKEN_FILE>
Ohne das Token auf dem Bildschirm auszugeben, hängt dieser Befehl beide Zeilen an (nur ausführen, wenn NTFY_* dort noch fehlt):
    sudo sh -c 'printf "NTFY_URL=https://${NTFY_HOST}\nNTFY_TOKEN=%s\n" "\$(cat $TOKEN_FILE)" >> $ENV_FILE'
$(grep -qE '^(NTFY_URL|NTFY_TOKEN)=' "$ENV_FILE" 2>/dev/null && echo "ACHTUNG: $ENV_FILE enthält schon NTFY_*-Zeilen; prüfen und nicht doppelt anhängen.")
Danach:  sudo systemctl restart lx-fampad
Der Push-Versand selbst kommt mit Phase 1c-3; bis dahin liest der Server die Werte nicht aus.

UnifiedPush: Anonymes Schreiben auf up*-Topics und Lesen je Handy sind bewusst NICHT freigegeben; siehe deploy/README.md, Abschnitt 7.
Rückbau: sudo rm /etc/caddy/conf.d/ntfy.caddy && sudo systemctl reload caddy   (Details: deploy/README.md)
EOF
