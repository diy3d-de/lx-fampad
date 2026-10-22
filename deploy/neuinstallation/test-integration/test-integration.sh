#!/usr/bin/env bash
# Integrationstest in zwei frischen Debian-13-Containern (Docker nötig, Netz für apt/npm; dauert einige Minuten):
#   A: leere Neuinstallation -> Testdaten -> Sicherung (age) | B: frischer Container: Wiederherstellung aus dieser Sicherung (Schlüssel über stdin)
# Ohne systemd (eine Attrappe für systemctl, siehe fake-systemctl.sh); Caddy/DNS/Zertifikate und GitHub-Zugriff werden NICHT geprüft.
# Isolation: alle Aufrufe mit --ohne-systemd (spricht nie die echten Internet-Adressen familie.lx-labs.dev / lx-labs.dev an), Container-Lauf und
# Attrappe brechen ohne /.dockerenv ab. Das Netz braucht der Test nur für Paketquellen (apt, npm, NodeSource, Caddy, ntfy).
# Der Code-Stand kommt aus einem Tarball der verfolgten und neuen (nicht ignorierten) Dateien, nicht aus einer Kopie des Arbeitsbaums mit .git/Geheimnissen.
#   deploy/neuinstallation/test-integration/test-integration.sh
set -euo pipefail
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HIER/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v docker >/dev/null || { echo "docker fehlt" >&2; exit 1; }
( cd "$REPO" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf "$WORK/repo.tar" )
WORK_DOCKER="$(cygpath -m "$WORK" 2>/dev/null || echo "$WORK")"   # Git Bash unter Windows: Pfad, den Docker versteht
lauf() { # $1 Szenario
  MSYS_NO_PATHCONV=1 docker run --rm -v "$WORK_DOCKER:/work" debian:trixie bash -c \
    'set -e; mkdir /repo; tar -xf /work/repo.tar -C /repo; bash /repo/deploy/neuinstallation/test-integration/container-lauf.sh "$1"' _ "$1"
}
echo "######## Szenario A: leere Neuinstallation und Sicherung"
lauf neu
echo
echo "######## Szenario B: Wiederherstellung auf einem frischen Server"
lauf wiederherstellung
