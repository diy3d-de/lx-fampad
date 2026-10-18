#!/usr/bin/env bash
# Läuft auf dem PC (Git Bash/WSL/Linux) oder in der CI: baut die Flutter-Web-App und lädt sie versioniert
# nach /srv/familie/web/<version>; "current" zeigt danach auf die neue Version (alte bleiben zum Zurückrollen,
# die letzten 5 werden behalten). Aufruf: deploy/deploy-web.sh   (SSH_HOST überschreibt den Alias, Standard lx-labs)
set -euo pipefail
cd "$(dirname "$0")/.."
SSH_HOST="${SSH_HOST:-lx-labs}"

version=$(grep -E '^version:' app/pubspec.yaml | head -1 | sed -E 's/version:[[:space:]]*//; s/\+.*//')
release="${version}-$(date +%Y%m%d%H%M%S)"

echo "==> flutter build web ($release)"
(cd app && flutter build web --release --no-web-resources-cdn)

echo "==> hochladen nach /srv/familie/web/$release"
ssh "$SSH_HOST" "mkdir -p /srv/familie/web/$release"
tar -C app/build/web -cf - . | ssh "$SSH_HOST" "tar -xf - -C /srv/familie/web/$release"

echo "==> current -> $release"
ssh "$SSH_HOST" "cd /srv/familie/web && ln -sfn $release current.new && mv -Tf current.new current && ls -1dt [0-9]*/ | tail -n +6 | xargs -r rm -rf"

echo "==> fertig: https://familie.lx-labs.dev"
