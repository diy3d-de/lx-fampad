#!/usr/bin/env bash
# Einrichtung Teil 1: Datenbank, Verzeichnisse, Konfiguration, Dienst, erstes Deployment.
# Fasst die Schritte 1 bis 5 aus deploy/README.md zusammen. Rührt Caddy, DNS und ntfy NICHT an
# (das folgt in Teil 2); lx-labs.dev ist davon nicht betroffen.
#
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-1.sh
# Voraussetzung: Der Code liegt in ~/lx-fampad, PostgreSQL 17 und Node 24 sind installiert.
# Das Skript kann gefahrlos mehrfach laufen: Vorhandenes wird nicht überschrieben (auch nicht das Datenbank-Passwort).
set -euo pipefail

if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
  echo "Bitte als Benutzer lx starten:  sudo bash $0" >&2
  exit 1
fi
LX="$SUDO_USER"
REPO="$(getent passwd "$LX" | cut -d: -f6)/lx-fampad"
[ -f "$REPO/deploy/lx-fampad.service" ] || { echo "Code fehlt in $REPO" >&2; exit 1; }
command -v psql >/dev/null || { echo "PostgreSQL fehlt (apt install postgresql postgresql-client rsync)" >&2; exit 1; }
command -v node >/dev/null || { echo "Node.js fehlt" >&2; exit 1; }
echo "Node: $(node --version)  PostgreSQL: $(psql --version)"

echo "==> 1/7 Log-Aufbewahrung auf 7 Tage begrenzen"
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nMaxRetentionSec=7day\n' > /etc/systemd/journald.conf.d/lx-retention.conf
systemctl restart systemd-journald

echo "==> 2/7 Systembenutzer und Verzeichnisse"
id lx-fampad >/dev/null 2>&1 || adduser --system --group --no-create-home --shell /usr/sbin/nologin lx-fampad
usermod -aG lx-fampad "$LX"
mkdir -p /srv/fampad/{server,server.prev,web,releases/android,well-known,font-fallback,files} /etc/lx-fampad
chown "$LX":lx-fampad /srv/fampad/server /srv/fampad/server.prev
chmod 750 /srv/fampad/server /srv/fampad/server.prev
chown -R "$LX":"$LX" /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback
chmod -R 755 /srv/fampad/web /srv/fampad/releases /srv/fampad/well-known /srv/fampad/font-fallback
chown lx-fampad:lx-fampad /srv/fampad/files
chmod 700 /srv/fampad/files
chmod 755 /srv/fampad

echo "==> 3/7 Datenbank und Konfiguration"
if [ -f /etc/lx-fampad/env ]; then
  echo "    /etc/lx-fampad/env existiert schon, bleibt unverändert."
else
  PW="$(openssl rand -base64 24 | tr -d '/+=')"
  # Passwort über stdin setzen (nicht in der Prozessliste)
  if sudo -u postgres psql -tAc "select 1 from pg_roles where rolname='lx_fampad'" | grep -q 1; then
    echo "    Rolle lx_fampad existiert schon (ohne env-Datei): bekommt ein neues Passwort."
    printf "ALTER ROLE lx_fampad LOGIN PASSWORD '%s';\n" "$PW" | sudo -u postgres psql -v ON_ERROR_STOP=1 -q
  else
    printf "CREATE ROLE lx_fampad LOGIN PASSWORD '%s';\n" "$PW" | sudo -u postgres psql -v ON_ERROR_STOP=1 -q
  fi
  sudo -u postgres psql -tAc "select 1 from pg_database where datname='lx_fampad'" | grep -q 1 \
    || sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE lx_fampad OWNER lx_fampad ENCODING 'UTF8'"
  umask 077
  sed "s|CHANGE_ME|$PW|" "$REPO/server/.env.example" > /etc/lx-fampad/env
  chown root:root /etc/lx-fampad/env
  chmod 600 /etc/lx-fampad/env
  unset PW
  echo "    Datenbank angelegt, Passwort steht nur in /etc/lx-fampad/env (root, 0600)."
fi

echo "==> 4/7 Anmeldung einrichten (Schlüssel, getrennte Datenbank-Rollen) und Dienst installieren"
# legt AUTH_SECRET_KEY an, trennt Migrations- und Laufzeitrolle und installiert lx-fampad.service + lx-fampad-migrate.service
bash "$REPO/deploy/einrichtung-auth.sh"

echo "==> 5/7 sudo-Regel für den Neustart durch deploy.sh"
echo "$LX ALL=(root) NOPASSWD: /usr/bin/systemctl restart lx-fampad" > /etc/sudoers.d/lx-fampad
chmod 440 /etc/sudoers.d/lx-fampad
if ! visudo -cf /etc/sudoers.d/lx-fampad >/dev/null; then
  rm -f /etc/sudoers.d/lx-fampad
  echo "sudoers-Prüfung fehlgeschlagen, Datei wieder entfernt." >&2
  exit 1
fi

echo "==> 6/7 Erstes Deployment (baut den Server, startet den Dienst)"
# Die Gruppe lx-fampad gilt für lx erst in einer neuen Anmeldung; sg setzt sie für diesen Aufruf.
sudo -u "$LX" -H sg lx-fampad -c "bash '$REPO/deploy/deploy.sh'"
systemctl enable lx-fampad

echo "==> 7/7 Prüfung"
curl -fsS http://127.0.0.1:4400/api/v1/health && echo
systemctl is-active lx-fampad lx-labs caddy
curl -sI https://lx-labs.dev | head -1
echo
echo "Fertig. Teil 2 (DNS, Caddy, ntfy, Web-App) folgt, sobald die DNS-Einträge bei Cloudflare angelegt sind."
