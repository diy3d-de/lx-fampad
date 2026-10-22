#!/usr/bin/env bash
# Startet die Tests von bootstrap-server.sh in einem frischen Debian-13-Container (Docker nötig; nichts am Rechner selbst wird verändert).
#   deploy/neuinstallation/test-docker.sh
# Das Netz wird nur zum Bauen des Test-Images gebraucht (apt: age, python3, shellcheck); die Tests selbst laufen mit --network none,
# das Repository ist nur lesend eingebunden. (Der Trockenlauf meldet ohne Netz "nicht erreichbar": das erwartet der Test.)
set -euo pipefail
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HIER/../.." && pwd)"
command -v docker >/dev/null || { echo "docker fehlt" >&2; exit 1; }
docker build -q -t lx-fampad-test-basis:trixie - >/dev/null <<'EOF'
FROM debian:trixie
ENV LC_ALL=C.UTF-8
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends age python3 shellcheck ca-certificates curl iproute2 openssl && rm -rf /var/lib/apt/lists/*
EOF
MSYS_NO_PATHCONV=1 docker run --rm --network none -v "$REPO:/repo:ro" lx-fampad-test-basis:trixie bash -c '
  set -e
  cd /repo
  echo "== shellcheck"
  shellcheck -x -S warning deploy/neuinstallation/bootstrap-server.sh deploy/neuinstallation/test-bootstrap.sh deploy/neuinstallation/test-docker.sh \
    deploy/neuinstallation/test-integration/*.sh deploy/deploy.sh
  echo "   shellcheck ok"
  bash deploy/neuinstallation/test-bootstrap.sh
'
