#!/usr/bin/env bash
# Startet die Tests von bootstrap-server.sh in einem frischen Debian-13-Container (Docker nötig; nichts am Rechner selbst wird verändert).
#   deploy/neuinstallation/test-docker.sh
# Der Container bekommt das Repository nur lesend; Netz wird nur für apt gebraucht (age, python3, shellcheck).
set -euo pipefail
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HIER/../.." && pwd)"
command -v docker >/dev/null || { echo "docker fehlt" >&2; exit 1; }
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/repo:ro" debian:trixie bash -c '
  set -e
  export LC_ALL=C.UTF-8
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends age python3 shellcheck ca-certificates curl iproute2 openssl >/dev/null 2>&1
  cd /repo
  echo "== shellcheck"
  shellcheck -x -S warning deploy/neuinstallation/bootstrap-server.sh deploy/neuinstallation/test-bootstrap.sh deploy/neuinstallation/test-docker.sh deploy/deploy.sh
  echo "   shellcheck ok"
  bash deploy/neuinstallation/test-bootstrap.sh
'
