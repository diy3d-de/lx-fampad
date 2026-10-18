#!/usr/bin/env bash
# Anmeldung (Phase 1a) einrichten bzw. eine bestehende Installation darauf umstellen. Idempotent: mehrfaches Ausführen ist gefahrlos.
#   1. AUTH_SECRET_KEY in /etc/lx-fampad/env anlegen (nur wenn er fehlt; ein vorhandener Schlüssel bleibt unverändert)
#   2. Datenbank-Rollen trennen: lx_fampad_migrate (Eigentümer, darf DDL, nur für Migrationen) und lx_fampad (Laufzeit, nur DML)
#   3. Zugangsdaten der Migrationsrolle nach /etc/lx-fampad/migrate.env (root:root, 0600; nur die Migrations-Einheit lädt sie)
#   4. Einheiten lx-fampad.service und lx-fampad-migrate.service installieren
# Aufruf auf dem Server:   sudo bash ~/lx-fampad/deploy/einrichtung-auth.sh
# Danach deployen (deploy/deploy.sh) und den ersten Admin anlegen (siehe deploy/README.md, Abschnitt "Erster Admin").
#
# Die laufende Installation bleibt bis zum nächsten Deployment unverändert: Der Dienst nutzt weiter die Laufzeitrolle
# (DATABASE_URL), die Rechte sind danach auf SELECT/INSERT/UPDATE/DELETE beschränkt. Fehlt migrate.env, benutzt
# migrate-cli DATABASE_URL (eine Rolle für beides) – die Migration schlüge dann nach der Trennung fehl, deshalb legt dieses Skript
# die Datei an, bevor es die Rechte entzieht.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte mit sudo starten:  sudo bash $0" >&2
  exit 1
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=/etc/lx-fampad/env
MIGRATE_ENV=/etc/lx-fampad/migrate.env
DB=lx_fampad
RUNTIME_ROLE=lx_fampad
MIGRATE_ROLE=lx_fampad_migrate

[ -f "$ENV_FILE" ] || { echo "$ENV_FILE fehlt (zuerst Schritt 5 der Einrichtung bzw. einrichtung-1.sh)." >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl fehlt" >&2; exit 1; }
PSQL=(sudo -u postgres psql -v ON_ERROR_STOP=1 -q -X)

echo "==> 1/4 Schlüssel für die Anmeldung (AUTH_SECRET_KEY)"
if grep -q '^AUTH_SECRET_KEY=.\+' "$ENV_FILE"; then
  echo "    vorhanden, bleibt unverändert."
else
  # entfernt eine leere Zeile aus der Vorlage und hängt einen frischen 256-Bit-Schlüssel an (Base64)
  sed -i '/^AUTH_SECRET_KEY=$/d' "$ENV_FILE"
  printf '\n# Hauptschlüssel der Anmeldung (TOTP-Verschlüsselung, HMACs). NIE ändern oder verlieren: sonst sind alle TOTP-Geheimnisse und\n# Wiederherstellungs-Codes unbrauchbar. In die Datensicherung aufnehmen (getrennt von der Datenbank).\nAUTH_SECRET_KEY=%s\n' "$(openssl rand -base64 32)" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "    neu angelegt. Bitte zusätzlich sicher sichern (z. B. Passwortmanager)."
fi
grep -q '^PUBLIC_URL=.\+' "$ENV_FILE" || echo "    WARNUNG: PUBLIC_URL fehlt in $ENV_FILE (Passkey-Origin und RP-ID leiten sich davon ab)." >&2

echo "==> 2/4 Datenbank-Rollen trennen"
if ! "${PSQL[@]}" -tAc "select 1 from pg_roles where rolname='$RUNTIME_ROLE'" | grep -q 1; then
  echo "    Rolle $RUNTIME_ROLE fehlt – zuerst Datenbank einrichten (Schritt 1 der Einrichtung)." >&2
  exit 1
fi
if [ -f "$MIGRATE_ENV" ] && "${PSQL[@]}" -tAc "select 1 from pg_roles where rolname='$MIGRATE_ROLE'" | grep -q 1; then
  echo "    Migrationsrolle und $MIGRATE_ENV existieren schon, Passwort bleibt unverändert."
else
  PW="$(openssl rand -base64 24 | tr -d '/+=')"
  # Passwort über stdin setzen (nicht in der Prozessliste)
  if "${PSQL[@]}" -tAc "select 1 from pg_roles where rolname='$MIGRATE_ROLE'" | grep -q 1; then
    printf "ALTER ROLE %s LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE;\n" "$MIGRATE_ROLE" "$PW" | "${PSQL[@]}"
  else
    printf "CREATE ROLE %s LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE;\n" "$MIGRATE_ROLE" "$PW" | "${PSQL[@]}"
  fi
  umask 077
  printf 'MIGRATION_DATABASE_URL=postgres://%s:%s@127.0.0.1:5432/%s\n' "$MIGRATE_ROLE" "$PW" "$DB" > "$MIGRATE_ENV"
  chown root:root "$MIGRATE_ENV"
  chmod 600 "$MIGRATE_ENV"
  unset PW
  echo "    Rolle $MIGRATE_ROLE angelegt; Zugangsdaten nur in $MIGRATE_ENV (root, 0600)."
fi

# Eigentum an Datenbank und allen Objekten geht an die Migrationsrolle; die Laufzeitrolle bekommt nur DML.
# ALTER DEFAULT PRIVILEGES sorgt dafür, dass Tabellen künftiger Migrationen automatisch dieselben Rechte erhalten.
"${PSQL[@]}" -d "$DB" <<SQL
ALTER DATABASE $DB OWNER TO $MIGRATE_ROLE;
REASSIGN OWNED BY $RUNTIME_ROLE TO $MIGRATE_ROLE;
ALTER ROLE $RUNTIME_ROLE NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
REVOKE ALL ON DATABASE $DB FROM PUBLIC;
GRANT CONNECT ON DATABASE $DB TO $RUNTIME_ROLE, $MIGRATE_ROLE;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM $RUNTIME_ROLE;
GRANT USAGE ON SCHEMA public TO $RUNTIME_ROLE;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM $RUNTIME_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $RUNTIME_ROLE;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $RUNTIME_ROLE;
ALTER DEFAULT PRIVILEGES FOR ROLE $MIGRATE_ROLE IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $RUNTIME_ROLE;
ALTER DEFAULT PRIVILEGES FOR ROLE $MIGRATE_ROLE IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO $RUNTIME_ROLE;
DO \$\$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'drizzle') THEN
    REVOKE ALL ON SCHEMA drizzle FROM $RUNTIME_ROLE;
    REVOKE ALL ON ALL TABLES IN SCHEMA drizzle FROM $RUNTIME_ROLE;
  END IF;
END \$\$;
SQL
echo "    Eigentümer: $MIGRATE_ROLE (DDL); Laufzeit: $RUNTIME_ROLE (nur SELECT/INSERT/UPDATE/DELETE)."

echo "==> 3/4 systemd-Einheiten"
cp "$SELF_DIR/lx-fampad.service" "$SELF_DIR/lx-fampad-migrate.service" /etc/systemd/system/
systemctl daemon-reload
echo "    lx-fampad.service und lx-fampad-migrate.service installiert."

echo "==> 4/4 Fertig"
echo "    Nächste Schritte:  bash ~/lx-fampad/deploy/deploy.sh"
echo "    Erster Admin:      sudo node --env-file=/etc/lx-fampad/env /srv/fampad/server/dist/cli/bootstrap.js --family \"Familie\""
