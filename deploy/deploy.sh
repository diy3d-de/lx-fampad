#!/usr/bin/env bash
# Läuft auf dem Server (vom PC aus gestartet: ssh lx-labs bash lx-familienzentrale/deploy/deploy.sh):
# neuesten Stand von GitHub holen, Server bauen, nach /srv/familie/server übertragen, Dienst neu starten.
# Die Web-App wird getrennt mit deploy/deploy-web.sh hochgeladen (Flutter ist nicht auf dem Server installiert).
# Datenbank-Migrationen laufen beim Start des Dienstes (ExecStartPre in lx-familie.service).
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET=/srv/familie/server

echo "==> git pull"
git pull --ff-only

echo "==> npm ci + build"
cd server
npm ci --no-fund --no-audit
npm run build
npm prune --omit=dev --no-fund --no-audit

echo "==> nach $TARGET übertragen"
mkdir -p "$TARGET"
rsync -a --delete dist/ "$TARGET/dist/"
rsync -a --delete drizzle/ "$TARGET/drizzle/"
rsync -a --delete node_modules/ "$TARGET/node_modules/"
cp package.json package-lock.json "$TARGET/"
cd ..

echo "==> restart"
sudo systemctl restart lx-familie

# Erst "fertig" melden, wenn der Dienst wieder antwortet (inkl. Migration und Datenbank-Prüfung).
# Der Port steht in /etc/lx-familie/env (nicht für lx lesbar); Standard 4400.
url="http://127.0.0.1:${FAMILIE_PORT:-4400}/api/v1/health"
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
    echo "==> online nach ${i}s"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "==> FEHLER: Dienst antwortet nach 30s nicht. Logs: sudo journalctl -u lx-familie -n 50" >&2
    exit 1
  fi
  sleep 1
done

# Caddy-Konfiguration wird nicht automatisch übernommen (braucht sudo mit Passwort)
if ! cmp -s deploy/Caddyfile /etc/caddy/familie.caddy; then
  echo "==> Hinweis: deploy/Caddyfile weicht von /etc/caddy/familie.caddy ab. Übernehmen mit:"
  echo "    sudo cp ~/lx-familienzentrale/deploy/Caddyfile /etc/caddy/familie.caddy && sudo systemctl reload caddy"
fi

echo "==> deployed: $(git log -1 --format='%h %s')"
