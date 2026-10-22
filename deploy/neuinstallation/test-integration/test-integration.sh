#!/usr/bin/env bash
# Integrationstest in zwei frischen Debian-13-Containern (Docker nötig, Netz für apt/npm; dauert einige Minuten):
#   A: leere Neuinstallation -> Testdaten -> Sicherung (age) | B: frischer Container: Wiederherstellung aus dieser Sicherung (Schlüssel über stdin)
# Ohne systemd (eine Attrappe für systemctl, siehe fake-systemctl.sh); Caddy/DNS/Zertifikate und GitHub-Zugriff werden NICHT geprüft.
#   deploy/neuinstallation/test-integration/test-integration.sh
set -euo pipefail
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HIER/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v docker >/dev/null || { echo "docker fehlt" >&2; exit 1; }
lauf() { # $1 Szenario
  MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/repo:ro" -v "$WORK:/work" debian:trixie bash /repo/deploy/neuinstallation/test-integration/container-lauf.sh "$1"
}
echo "######## Szenario A: leere Neuinstallation und Sicherung"
lauf neu
echo
echo "######## Szenario B: Wiederherstellung auf einem frischen Server"
lauf wiederherstellung
