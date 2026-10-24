#!/usr/bin/env bash
# Läuft auf dem PC (Git Bash/WSL/Linux) oder in der CI: baut die Flutter-Web-App und lädt sie versioniert
# nach /srv/fampad/web/<version>; "current" zeigt danach auf die neue Version (alte bleiben zum Zurückrollen,
# die letzten 5 werden behalten). Aufruf: deploy/deploy-web.sh   (SSH_HOST überschreibt den Alias, Standard lx-labs)
#
# Aufruf mit Release-Version (deploy/deploy-web.sh 0.4.0 oder RELEASE_VERSION=0.4.0, auch mit führendem v): bricht ab, wenn app/pubspec.yaml eine andere Version hat.
# Ohne Angabe gilt ein Git-Tag auf HEAD (v*) als Release-Version; gibt es keinen, nur eine Warnung.
#
# Die Kennung <version> wird auf zwei Wegen bekannt gemacht, damit /api/v1/version "webVersion" liefern kann:
#  - als Datei version.txt im Build (der Server liest WEB_VERSION_FILE=/srv/fampad/web/current/version.txt)
#  - als --dart-define=WEB_VERSION=<version> in der App: weicht die Kennung des Servers ab, zeigt die App
#    "Neue Version - neu laden"
# $release soll bewusst schon auf dem PC eingesetzt werden (SC2029)
# shellcheck disable=SC2029
set -euo pipefail
cd "$(dirname "$0")/.."
SSH_HOST="${SSH_HOST:-lx-labs}"

version=$(grep -E '^version:' app/pubspec.yaml | head -1 | sed -E 's/version:[[:space:]]*//; s/\+.*//')
release="${version}-$(date +%Y%m%d%H%M%S)"

erwartet="${1:-${RELEASE_VERSION:-}}"
erwartet="${erwartet#v}"
if [ -z "$erwartet" ]; then
  erwartet=$(git describe --tags --exact-match HEAD 2>/dev/null | sed -n 's/^v\([0-9][0-9.]*\)$/\1/p' || true)
fi
if [ -n "$erwartet" ]; then
  if [ "$erwartet" != "$version" ]; then
    echo "Abbruch: Release-Version $erwartet, aber app/pubspec.yaml hat $version. Version in app/pubspec.yaml und server/package.json setzen und committen." >&2
    exit 1
  fi
else
  echo "Warnung: keine Release-Version angegeben (Parameter, RELEASE_VERSION oder Git-Tag): die Version $version aus app/pubspec.yaml wird nicht geprüft." >&2
fi

echo "==> Prüfsummen von sqlite3.wasm und drift_worker.js"
(cd app && sha256sum -c web-assets.sha256)

echo "==> flutter build web ($release)"
(cd app && flutter build web --release --no-web-resources-cdn --dart-define=WEB_VERSION="$release")
printf '%s\n' "$release" > app/build/web/version.txt
# Das Gebaute muss dieselben Dateien enthalten wie die geprüften
(cd app && sed -E 's# (\*?)web/# \1build/web/#' web-assets.sha256 | sha256sum -c)

echo "==> hochladen nach /srv/fampad/web/$release"
ssh "$SSH_HOST" "mkdir -p /srv/fampad/web/$release"
tar -C app/build/web -cf - . | ssh "$SSH_HOST" "tar -xf - -C /srv/fampad/web/$release"

echo "==> current -> $release"
ssh "$SSH_HOST" "cd /srv/fampad/web && ln -sfn $release current.new && mv -Tf current.new current && ls -1dt [0-9]*/ | tail -n +6 | xargs -r rm -rf"

echo "==> fertig: https://familyhub.lx-labs.dev (webVersion: $release)"
