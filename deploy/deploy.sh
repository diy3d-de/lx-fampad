#!/usr/bin/env bash
# Läuft auf dem Server (vom PC aus gestartet: ssh lx-labs bash lx-familienzentrale/deploy/deploy.sh):
# neuesten Stand von GitHub holen, Server bauen, nach /srv/familie/server übertragen, Dienst neu starten.
# Die Web-App wird getrennt mit deploy/deploy-web.sh hochgeladen (Flutter ist nicht auf dem Server installiert).
# Datenbank-Migrationen laufen beim Start des Dienstes (ExecStartPre in lx-familie.service).
#
# Pakete: Installation immer mit --ignore-scripts (kein fremder Code aus Paket-Skripten auf dem Server). Gebaut wird mit
# allen Paketen (TypeScript braucht die devDependencies); nach /srv/familie/server kommen nur die Produktivpakete,
# frisch installiert (npm ci --omit=dev) in einem Zwischenordner. Brauchen künftige Pakete ein Installationsskript
# (z. B. Prebuild-Download), wird es dort bewusst und einzeln freigegeben, nicht global eingeschaltet.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET=/srv/familie/server
# Fest: derselbe Port steht in lx-familie.service und deploy/Caddyfile (die env-Datei ist für lx nicht lesbar)
PORT=4400

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> git pull"
git pull --ff-only

echo "==> npm ci (alle Pakete, ohne Skripte) + build"
cd server
npm ci --ignore-scripts --no-fund --no-audit
npm run build

echo "==> Produktivpakete installieren (npm ci --omit=dev --ignore-scripts)"
cp package.json package-lock.json "$STAGE/"
(cd "$STAGE" && npm ci --omit=dev --ignore-scripts --no-fund --no-audit)

echo "==> nach $TARGET übertragen"
mkdir -p "$TARGET"
rsync -a --delete dist/ "$TARGET/dist/"
rsync -a --delete drizzle/ "$TARGET/drizzle/"
rsync -a --delete "$STAGE/node_modules/" "$TARGET/node_modules/"
cp package.json package-lock.json "$TARGET/"
cd ..

echo "==> restart"
sudo systemctl restart lx-familie

# Erst "fertig" melden, wenn der Dienst wieder antwortet UND die Datenbank erreichbar ist
# ("db":"ok"; ohne Datenbank meldet der Dienst "skipped", mit Fehler 503 und "down").
url="http://127.0.0.1:${PORT}/api/v1/health"
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 "$url" 2>/dev/null | grep -q '"db":"ok"'; then
    echo "==> online mit Datenbank nach ${i}s"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "==> FEHLER: Dienst antwortet nach 30s nicht mit \"db\":\"ok\". Logs: sudo journalctl -u lx-familie -n 50" >&2
    exit 1
  fi
  sleep 1
done

# Caddy-Konfiguration wird nicht automatisch übernommen (braucht sudo mit Passwort)
if ! cmp -s deploy/Caddyfile /etc/caddy/familie.caddy; then
  echo "==> Hinweis: deploy/Caddyfile weicht von /etc/caddy/familie.caddy ab. Übernehmen mit:"
  echo "    sudo cp ~/lx-familienzentrale/deploy/Caddyfile /etc/caddy/familie.caddy && sudo systemctl reload caddy"
fi
# Ein Deploy von lx-labs ersetzt /etc/caddy/Caddyfile und entfernt dabei die Import-Zeile (deploy/README.md, Schritt 6)
if ! grep -qs '^[[:space:]]*import[[:space:]]\+/etc/caddy/familie\.caddy' /etc/caddy/Caddyfile; then
  echo "==> WARNUNG: /etc/caddy/Caddyfile enthält die Zeile 'import /etc/caddy/familie.caddy' nicht (nach einem lx-labs-Deploy?)." >&2
  echo "    familie.lx-labs.dev ist dann nicht erreichbar. Siehe deploy/README.md, Schritt 6." >&2
fi

echo "==> deployed: $(git log -1 --format='%h %s')"
