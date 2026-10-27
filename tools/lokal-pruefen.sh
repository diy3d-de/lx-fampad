#!/usr/bin/env bash
# Schnelle lokale Prüfung vor dem Push (ersetzt die CI nicht: libsodium-Tests, Vertragsprüfung und der signierte Release laufen nur dort).
#   bash tools/lokal-pruefen.sh server   # Lint, Typen, Tests gegen PostgreSQL 17 in Docker (Port 5433)
#   bash tools/lokal-pruefen.sh app      # analyze + flutter test (libsodium-Tests werden ohne C-Compiler übersprungen)
#   bash tools/lokal-pruefen.sh alles    # beides nacheinander (nie parallel: unter Last laufen Zeitgrenzen der Tests über)
#   bash tools/lokal-pruefen.sh db-stop  # Test-Datenbank beenden
# Fortschritt in VS Code: .pruefung-status (kurze Übersicht mit "Tests: x/y", alle 5 Sekunden aktualisiert) und .pruefung-log (volle Ausgabe) in der
# Repo-Wurzel öffnen; beide stehen in .gitignore. Die Gesamtzahl y stammt vom letzten vollständigen Lauf (.pruefung-gesamt, ebenfalls ignoriert).
set -euo pipefail
WURZEL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME=lxfampad-testdb
DB_PORT=5433
STATUS="$WURZEL/.pruefung-status"
LOG="$WURZEL/.pruefung-log"
GESAMT="$WURZEL/.pruefung-gesamt"
PHASE=""
PHASE_START=0
LOG_START=0
WATCHER=""

# Gesamtzahl der Tests einer Phase vom letzten vollständigen Lauf (0 = unbekannt).
gesamt_lesen() { # $1 = Phase
  [ -f "$GESAMT" ] && grep -E "^$1=" "$GESAMT" | tail -1 | cut -d= -f2 || true
}

gesamt_schreiben() { # $1 = Phase, $2 = Zahl
  { [ -f "$GESAMT" ] && grep -vE "^$1=" "$GESAMT" || true; echo "$1=$2"; } > "$GESAMT.neu"
  mv -f "$GESAMT.neu" "$GESAMT"
}

# Ausgabe der laufenden Phase (ohne die der vorigen Phase), Wagenrückläufe als Zeilenumbruch.
phasen_log() { [ -s "$LOG" ] && tail -c +"$((LOG_START + 1))" "$LOG" | tr '\r' '\n' || true; }

# Stand der Tests als "erledigt gesamt rot": flutter ("01:09 +68 ~2 -1: …" = bestanden, übersprungen, rot), vitest (verbose: eine Zeile je Test).
zaehle() { # $1 = Phase; schreibt "erledigt rot"
  local t p s f
  t="$(phasen_log)"
  if [ "$1" = "App" ]; then
    local z
    z="$(printf '%s\n' "$t" | grep -oE '[0-9]+:[0-9]+ \+[0-9]+( ~[0-9]+)?( -[0-9]+)?' | tail -1 || true)"
    p="$(printf '%s' "$z" | grep -oE '\+[0-9]+' | tr -d + || true)"
    s="$(printf '%s' "$z" | grep -oE '~[0-9]+' | tr -d '~' || true)"
    f="$(printf '%s' "$z" | grep -oE ' -[0-9]+' | tr -d ' -' || true)"
    echo "$(( ${p:-0} + ${s:-0} + ${f:-0} )) ${f:-0}"
  else
    p="$(printf '%s\n' "$t" | grep -cE '^ *(✓|↓)' || true)"
    f="$(printf '%s\n' "$t" | grep -cE '^ *×' || true)"
    echo "$(( ${p:-0} + ${f:-0} )) ${f:-0}"
  fi
}

schreibe_status() { # $1 = Zustand
  local seit="-" erledigt=0 rot=0 gesamt tests
  [ "$PHASE_START" -gt 0 ] && seit="$(date -d "@$PHASE_START" +%H:%M:%S 2>/dev/null || echo -)"
  if [ -n "$PHASE" ]; then
    read -r erledigt rot <<< "$(zaehle "$PHASE")"
    gesamt="$(gesamt_lesen "$PHASE")"
    if [ -n "${gesamt:-}" ] && [ "$gesamt" -gt 0 ]; then
      tests="$erledigt/$gesamt ($(( erledigt * 100 / gesamt )) %), Gesamtzahl vom letzten Lauf"
    else
      tests="$erledigt/? (Gesamtzahl erst nach dem ersten vollständigen Lauf bekannt)"
    fi
    [ "$rot" -gt 0 ] && tests="$tests, rot: $rot"
  else
    tests="-"
  fi
  {
    echo "Zustand:  $1"
    echo "Phase:    ${PHASE:--}"
    echo "Seit:     $seit"
    echo "Tests:    $tests"
    echo "Stand:    $(date +%H:%M:%S)"
  } > "$STATUS.neu"
  mv -f "$STATUS.neu" "$STATUS"
}

watcher_stop() {
  [ -n "$WATCHER" ] && kill "$WATCHER" 2>/dev/null || true
  WATCHER=""
}

# Eine Phase mit sichtbarem Fortschritt: Ausgabe auf den Bildschirm UND in die Logdatei, Status im Hintergrund aktualisiert.
lauf() { # $1 = Name, Rest = Funktion
  PHASE="$1"; shift
  PHASE_START="$(date +%s)"
  LOG_START="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
  schreibe_status "läuft"
  ( while true; do sleep 5; schreibe_status "läuft"; done ) &
  WATCHER=$!
  local ok=0
  "$@" 2>&1 | tee -a "$LOG" || ok=1
  watcher_stop
  local erledigt rot
  read -r erledigt rot <<< "$(zaehle "$PHASE")"
  # Gesamtzahl nur merken, wenn die Phase bis zum Ende der Tests kam (mindestens ein Test, nicht abgebrochen)
  if [ "$ok" -eq 0 ] || [ "$rot" -gt 0 ]; then [ "$erledigt" -gt 0 ] && gesamt_schreiben "$PHASE" "$erledigt"; fi
  if [ "$ok" -eq 0 ]; then schreibe_status "$PHASE fertig: ok"; else schreibe_status "$PHASE fertig: FEHLER"; return 1; fi
}
trap watcher_stop EXIT

db_start() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker läuft nicht: Tests laufen nur gegen PGlite (schwächer als echtes PostgreSQL)." >&2
    return 1
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$DB_NAME"; then
    docker rm -f "$DB_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$DB_NAME" -e POSTGRES_PASSWORD=ci -p "127.0.0.1:${DB_PORT}:5432" postgres:17 >/dev/null
  fi
  for _ in $(seq 1 30); do
    docker exec "$DB_NAME" pg_isready -U postgres >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "Datenbank wurde nicht bereit." >&2
  return 1
}

server() {
  cd "$WURZEL/server"
  [ -d node_modules ] || npm ci --no-fund --no-audit
  npm run lint
  npm run typecheck
  if db_start; then
    TEST_DATABASE_URL="postgres://postgres:ci@127.0.0.1:${DB_PORT}/postgres" npm test -- --hookTimeout=60000 --reporter=verbose
  else
    npm test -- --hookTimeout=60000 --reporter=verbose
  fi
}

app() {
  cd "$WURZEL/app"
  flutter pub get --enforce-lockfile
  dart run build_runner build --delete-conflicting-outputs >/dev/null
  flutter analyze
  NIX_SKIP_SODIUM_BUILD_HOOKS=1 flutter test --reporter=compact
}

beginne_log() { : > "$LOG"; }

case "${1:-alles}" in
  server) beginne_log; lauf Server server ;;
  app) beginne_log; lauf App app ;;
  alles) beginne_log; lauf Server server; lauf App app ;;
  db-stop) docker rm -f "$DB_NAME" ;;
  *) echo "Aufruf: $0 server|app|alles|db-stop" >&2; exit 2 ;;
esac
