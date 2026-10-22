#!/usr/bin/env bash
# Läuft auf dem Server (vom PC aus gestartet: ssh lx-labs bash lx-fampad/deploy/deploy.sh):
# neuesten Stand von GitHub holen, Server bauen, nach /srv/fampad/server übertragen, Dienst neu starten.
# Die Web-App wird getrennt mit deploy/deploy-web.sh hochgeladen (Flutter ist nicht auf dem Server installiert).
# Die Vorversion bleibt in /srv/fampad/server.prev; schlägt der Health-Check nach dem Neustart fehl, wird sie automatisch zurückgespielt.
# Datenbank-Migrationen laufen beim Start des Dienstes (ExecStartPre in lx-fampad.service).
#
# Pakete: Installation immer mit --ignore-scripts (kein fremder Code aus Paket-Skripten auf dem Server). Gebaut wird mit
# allen Paketen (TypeScript braucht die devDependencies); nach /srv/fampad/server kommen nur die Produktivpakete,
# frisch installiert (npm ci --omit=dev) in einem Zwischenordner. Brauchen künftige Pakete ein Installationsskript
# (z. B. Prebuild-Download), wird es dort bewusst und einzeln freigegeben, nicht global eingeschaltet.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET=/srv/fampad/server
# Fest: derselbe Port steht in lx-fampad.service und deploy/Caddyfile (die env-Datei ist für lx nicht lesbar)
PORT=4400
# Vorversion für den automatischen Rückfall (nur lx schreibbar, siehe deploy/README.md, Schritt 2)
PREV=/srv/fampad/server.prev

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# DEPLOY_OHNE_PULL=1: nur für deploy/neuinstallation/bootstrap-server.sh (ein festgelegter Code-Stand, GIT_REF, soll bleiben)
if [ "${DEPLOY_OHNE_PULL:-0}" = 1 ]; then
  echo "==> git pull übersprungen (DEPLOY_OHNE_PULL=1)"
else
  echo "==> git pull"
  git pull --ff-only
fi

echo "==> npm ci (alle Pakete, ohne Skripte) + build"
cd server
npm ci --ignore-scripts --no-fund --no-audit
npm run build

echo "==> Produktivpakete installieren (npm ci --omit=dev --ignore-scripts)"
cp package.json package-lock.json "$STAGE/"
(cd "$STAGE" && npm ci --omit=dev --ignore-scripts --no-fund --no-audit)

if [ -f drizzle/0005_ohne_gaeste.sql ] && [ ! -f "$TARGET/drizzle/0005_ohne_gaeste.sql" ]; then
  echo "==> ACHTUNG: Migration 0005 (Gäste entfallen) steht an. Sie löscht Gast-Konten, ist nicht umkehrbar und wird bei Fehler NICHT zurückgerollt." >&2
  echo "    Vorher: sudo -u postgres pg_dump lx_fampad > ~/lx_fampad-vor-0005.sql (deploy/README.md, Updates veröffentlichen). Abbruch mit Strg+C in 15 s." >&2
  sleep 15
fi

echo "==> nach $TARGET übertragen"
mkdir -p "$TARGET"
# Vorversion sichern (für den automatischen Rückfall). Das Verzeichnis legt die Einrichtung an (README, Schritt 2),
# weil lx in /srv/fampad nichts anlegen darf. Beim allerersten Deployment gibt es noch nichts zu sichern.
HAT_VORVERSION=0
if [ -f "$TARGET/dist/server.js" ]; then
  if [ ! -d "$PREV" ] || [ ! -w "$PREV" ]; then
    echo "==> FEHLER: $PREV fehlt oder ist nicht beschreibbar (deploy/README.md, Schritt 2). Es wurde nichts verändert." >&2
    exit 1
  fi
  rsync -a --delete "$TARGET/" "$PREV/"
  HAT_VORVERSION=1
fi
rsync -a --delete dist/ "$TARGET/dist/"
rsync -a --delete drizzle/ "$TARGET/drizzle/"
rsync -a --delete "$STAGE/node_modules/" "$TARGET/node_modules/"
cp package.json package-lock.json "$TARGET/"
cd ..

# Erst "fertig" melden, wenn der Dienst antwortet UND die Datenbank erreichbar ist
# ("db":"ok"; ohne Datenbank meldet der Dienst "skipped", mit Fehler 503 und "down").
# Der Aufruf kommt von 127.0.0.1 und ist daher vom Rate-Limit ausgenommen (server/src/routes/system.ts).
url="http://127.0.0.1:${PORT}/api/v1/health"
warte_auf_health() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 3 "$url" 2>/dev/null | grep -q '"db":"ok"'; then
      echo "==> online mit Datenbank nach ${i}s"
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "==> restart"
sudo systemctl restart lx-fampad
if ! warte_auf_health; then
  echo "==> FEHLER: Dienst antwortet nach 30s nicht mit \"db\":\"ok\". Logs: sudo journalctl -u lx-fampad -n 50" >&2
  if [ "$HAT_VORVERSION" -eq 1 ]; then
    echo "==> Rückfall auf die Vorversion ($PREV)" >&2
    rsync -a --delete "$PREV/" "$TARGET/"
    sudo systemctl restart lx-fampad
    if warte_auf_health; then
      echo "==> Vorversion läuft wieder. Die neue Version ist NICHT aktiv; Ursache in den Logs suchen." >&2
      echo "    Hinweis: Migrationen der neuen Version wurden schon angewendet (nur vorwärts, rückwärtskompatibel)." >&2
    else
      echo "==> FEHLER: auch die Vorversion antwortet nicht. Logs: sudo journalctl -u lx-fampad -n 50" >&2
    fi
  else
    echo "==> Keine Vorversion vorhanden, kein Rückfall möglich." >&2
  fi
  exit 1
fi

# Wetter-Abruf (eigener Dienst, deploy/README.md Abschnitt 12): nach dem Update nur neu starten, wenn er läuft oder eingeschaltet ist (ein
# Neustart eines ausgeschalteten Dienstes würde ihn starten: zwei Server dürfen das Netatmo-Token nicht gleichzeitig abrufen). Beim Aufbau durch
# neuinstallation/bootstrap-server.sh (DEPLOY_OHNE_PULL=1) wird der Wetter-Dienst nie angefasst.
if [ "${DEPLOY_OHNE_PULL:-0}" != 1 ] && systemctl cat lx-fampad-weather.service >/dev/null 2>&1; then
  # läuft ODER ist eingeschaltet (enabled): ein gescheiterter, aber eingeschalteter Dienst wird wie früher beim Deploy neu gestartet;
  # ein ausgeschalteter, gestoppter wird nie gestartet
  if systemctl is-active --quiet lx-fampad-weather || systemctl is-enabled --quiet lx-fampad-weather; then
    echo "==> restart lx-fampad-weather"
    sudo -n systemctl restart lx-fampad-weather || echo "==> WARNUNG: lx-fampad-weather ließ sich nicht neu starten (sudoers-Regel fehlt? README Schritt 5). Manuell: sudo systemctl restart lx-fampad-weather" >&2
  else
    echo "==> lx-fampad-weather läuft nicht und ist nicht eingeschaltet: wird nicht gestartet"
  fi
  if ! cmp -s deploy/lx-fampad-weather.service /etc/systemd/system/lx-fampad-weather.service; then
    echo "==> Hinweis: deploy/lx-fampad-weather.service weicht von /etc/systemd/system ab. Übernehmen mit: sudo bash ~/lx-fampad/deploy/einrichtung-wetter.sh dienst"
  fi
fi

# Caddy-Konfiguration wird nicht automatisch übernommen (braucht sudo mit Passwort)
if ! cmp -s deploy/Caddyfile /etc/caddy/conf.d/fampad.caddy; then
  echo "==> Hinweis: deploy/Caddyfile weicht von /etc/caddy/conf.d/fampad.caddy ab. Übernehmen mit:"
  echo "    sudo cp ~/lx-fampad/deploy/Caddyfile /etc/caddy/conf.d/fampad.caddy && caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy"
fi
# Ein Deploy von lx-labs ersetzt /etc/caddy/Caddyfile und entfernt dabei die Import-Zeile (deploy/README.md, Schritt 6)
if ! grep -qsE '^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy' /etc/caddy/Caddyfile; then
  echo "==> WARNUNG: /etc/caddy/Caddyfile enthält die Zeile 'import /etc/caddy/conf.d/*.caddy' nicht (nach einem lx-labs-Deploy?)." >&2
  echo "    familie.lx-labs.dev ist dann nicht erreichbar. Siehe deploy/README.md, Schritt 6." >&2
fi

echo "==> deployed: $(git log -1 --format='%h %s')"
