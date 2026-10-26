#!/usr/bin/env bash
# Schnelle lokale Prüfung vor dem Push (ersetzt die CI nicht: libsodium-Tests, Vertragsprüfung und der signierte Release laufen nur dort).
#   bash tools/lokal-pruefen.sh server   # Lint, Typen, Tests gegen PostgreSQL 17 in Docker (Port 5433)
#   bash tools/lokal-pruefen.sh app      # analyze + flutter test (libsodium-Tests werden ohne C-Compiler übersprungen)
#   bash tools/lokal-pruefen.sh alles    # beides nacheinander (nie parallel: unter Last laufen Zeitgrenzen der Tests über)
#   bash tools/lokal-pruefen.sh db-stop  # Test-Datenbank beenden
set -euo pipefail
WURZEL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME=lxfampad-testdb
DB_PORT=5433

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
    TEST_DATABASE_URL="postgres://postgres:ci@127.0.0.1:${DB_PORT}/postgres" npm test -- --hookTimeout=60000
  else
    npm test -- --hookTimeout=60000
  fi
}

app() {
  cd "$WURZEL/app"
  flutter pub get --enforce-lockfile
  dart run build_runner build --delete-conflicting-outputs >/dev/null
  flutter analyze
  NIX_SKIP_SODIUM_BUILD_HOOKS=1 flutter test --reporter=compact
}

case "${1:-alles}" in
  server) server ;;
  app) app ;;
  alles) server; app ;;
  db-stop) docker rm -f "$DB_NAME" ;;
  *) echo "Aufruf: $0 server|app|alles|db-stop" >&2; exit 2 ;;
esac
