#!/usr/bin/env bash
# UnifiedPush-Zugriff für ntfy (deploy/README.md, Abschnitt 7, "Push für die Handys"). Voraussetzung: einrichtung-ntfy.sh ist gelaufen.
# NUR ntfy-CLI (user.db) und eine root-only Passwortdatei; Caddy, Haupt-Caddyfile und /etc/lx-fampad/env werden NICHT angefasst.
# Idempotent: mehrfaches Ausführen ist gefahrlos.
#
# Rechte (deny-all bleibt Standard, anonym nie etwas):
#   fampad-server (Token des Fastify-Servers)  ->  'up*' write-only     (Server sendet Wecker; schreibt nie anonym)
#   fampad-family (neuer Lese-Benutzer)         ->  'up*' read-only      (die ntfy-App der Handys abonniert ihr up<Zufall>-Topic)
# Begründung: Die ntfy-App ist nur Empfänger (Verteiler) und muss die Topics lesen; geschrieben wird ausschließlich vom Server mit Token.
# Anonymes Lesen/Schreiben auf 'up*' wäre unnötig offen (Topic-Namen sind zwar zufällig, aber ein Geheimnis darf nicht die einzige Hürde sein).
# Ein gemeinsamer Lese-Benutzer für die Familie genügt: Er kann nichts senden, nur Wecker ohne Inhalt lesen.
# Das Passwort wird zufällig erzeugt, nie angezeigt und liegt root-only in /etc/lx-fampad/ntfy-family-password.
#
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-ntfy-up.sh [--dry-run | --rotate]
#   --dry-run  prüft nur.
#   --rotate   setzt ein neues Passwort für fampad-family (danach in allen ntfy-Apps neu eintragen).
set -Eeuo pipefail

NTFY_USER=ntfy
NTFY_HOST="ntfy.familie.lx-labs.dev"
NTFY_PORT=2586
CFG=/etc/ntfy/server.yml
PUSH_USER="fampad-server"
FAMILY_USER="fampad-family"
UP_TOPICS='up*'
TOKEN_FILE=/etc/lx-fampad/ntfy-token
PW_FILE=/etc/lx-fampad/ntfy-family-password
LOCAL="http://127.0.0.1:${NTFY_PORT}"

DRY=0
ROTATE=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  --rotate) ROTATE=1 ;;
  *) echo "Aufruf: sudo bash $0 [--dry-run | --rotate]" >&2; exit 2 ;;
esac

fehler() { echo "FEHLER: $*" >&2; exit 1; }
trap 'echo "!!  Fehler in Zeile $LINENO." >&2' ERR

if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
  echo "Bitte als Benutzer lx starten:  sudo bash $0 [--dry-run | --rotate]" >&2
  exit 1
fi

echo "==> 1/3 Prüfungen$([ "$DRY" = 1 ] && echo ' (Trockenlauf)')"
for b in ntfy curl runuser install head base64 tr; do command -v "$b" >/dev/null || fehler "$b fehlt"; done
[ -f "$CFG" ] || fehler "$CFG fehlt (zuerst einrichtung-ntfy.sh)"
systemctl is-active --quiet ntfy || fehler "Dienst ntfy läuft nicht (zuerst einrichtung-ntfy.sh)"
# erst in eine Variable (bei "curl | grep -q" bricht pipefail ab, sobald grep früh schließt)
GESUND="$(curl -fsS --max-time 5 "$LOCAL/v1/health" 2>/dev/null || true)"
grep -q '"healthy":true' <<<"$GESUND" || fehler "ntfy antwortet lokal nicht"
[ -s "$TOKEN_FILE" ] || fehler "$TOKEN_FILE fehlt (zuerst einrichtung-ntfy.sh)"
ntfy_als_ntfy() { runuser -u "$NTFY_USER" -- ntfy "$@"; }
ULIST="$(ntfy_als_ntfy user --config "$CFG" list)"
grep -q "^user ${PUSH_USER} " <<<"$ULIST" || fehler "ntfy-Benutzer $PUSH_USER fehlt (zuerst einrichtung-ntfy.sh)"
HAVE_FAMILY=0; grep -q "^user ${FAMILY_USER} " <<<"$ULIST" && HAVE_FAMILY=1
# Rolle des vorhandenen Benutzers (muss "user" sein, nie admin): Zeile "user NAME (role: user, tier: none)"
FAMILY_ROLE="$(sed -n "s/^user ${FAMILY_USER} (role: \([a-z]*\),.*/\1/p" <<<"$ULIST" | head -n1)"
echo "    ntfy läuft, $PUSH_USER vorhanden, $FAMILY_USER: $([ "$HAVE_FAMILY" = 1 ] && echo "vorhanden (Rolle ${FAMILY_ROLE:-unbekannt})" || echo neu)."
if [ "$DRY" = 1 ]; then
  echo "==> Trockenlauf beendet. Geplant: $FAMILY_USER anlegen/prüfen, Passwort nach $PW_FILE (root, 0600), '$UP_TOPICS': $PUSH_USER write-only, $FAMILY_USER read-only."
  exit 0
fi

echo "==> 2/3 Benutzer $FAMILY_USER und Rechte"
if [ "$HAVE_FAMILY" = 1 ] && [ "$FAMILY_ROLE" != user ]; then
  ntfy_als_ntfy user --config "$CFG" change-role "$FAMILY_USER" user >/dev/null
  echo "    Rolle von $FAMILY_USER war '${FAMILY_ROLE:-unbekannt}', jetzt 'user' (kein Admin)."
fi
neues_passwort() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n'; }
speichern() { [ -d /etc/lx-fampad ] || install -d -m 755 -o root -g root /etc/lx-fampad; ( umask 077; printf '%s\n' "$1" > "$PW_FILE" ); chown root:root "$PW_FILE"; chmod 600 "$PW_FILE"; }
if [ "$HAVE_FAMILY" = 0 ]; then
  PW="$(neues_passwort)"
  NTFY_PASSWORD="$PW" ntfy_als_ntfy user --config "$CFG" add --role=user "$FAMILY_USER" >/dev/null
  speichern "$PW"; unset PW
  echo "    Benutzer angelegt, Passwort in $PW_FILE (nicht angezeigt)."
elif [ "$ROTATE" = 1 ] || [ ! -s "$PW_FILE" ]; then
  PW="$(neues_passwort)"
  NTFY_PASSWORD="$PW" ntfy_als_ntfy user --config "$CFG" change-pass "$FAMILY_USER" >/dev/null
  speichern "$PW"; unset PW
  echo "    neues Passwort gesetzt (in allen ntfy-Apps der Familie neu eintragen), Datei $PW_FILE."
else
  echo "    Benutzer und Passwortdatei vorhanden, unverändert."
fi
chmod 600 "$PW_FILE"
ntfy_als_ntfy access --config "$CFG" "$PUSH_USER" "$UP_TOPICS" write-only >/dev/null
ntfy_als_ntfy access --config "$CFG" "$FAMILY_USER" "$UP_TOPICS" read-only >/dev/null
echo "    $PUSH_USER: '$UP_TOPICS' write-only; $FAMILY_USER: '$UP_TOPICS' read-only."

echo "==> 3/3 Rechteprobe (lokal und über HTTPS; Zugangsdaten nie in der Prozessliste)"
TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
FPW="$(head -n1 "$PW_FILE" | tr -d '[:space:]')"
T=upPruefung0000
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
tok() { printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$@" || true; }
fam() { printf 'user = "%s:%s"\n' "$FAMILY_USER" "$FPW" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$@" || true; }
nein() { [ "$1" = 401 ] || [ "$1" = 403 ]; }
for base in "$LOCAL" "https://${NTFY_HOST}"; do
  nein "$(code -d x "$base/$T")" || fehler "$base: anonymes Schreiben auf $T ist nicht verboten"
  nein "$(code "$base/$T/json?poll=1")" || fehler "$base: anonymes Lesen auf $T ist nicht verboten"
  [ "$(tok -d 'Prüfung' "$base/$T")" = 200 ] || fehler "$base: Token darf nicht auf $T schreiben"
  [ "$(fam "$base/$T/json?poll=1")" = 200 ] || fehler "$base: $FAMILY_USER darf $T nicht lesen"
  nein "$(fam -d x "$base/$T")" || fehler "$base: $FAMILY_USER darf auf $T schreiben (erwartet verboten)"
  nein "$(fam "$base/fampad-pruefung/json?poll=1")" || fehler "$base: $FAMILY_USER darf fampad-* lesen (erwartet verboten)"
done
echo "    bestanden (anonym 401/403; Server schreibt 200; $FAMILY_USER liest 200, schreibt 401/403)."
unset TOKEN FPW

cat <<EOT

Fertig. In der ntfy-App jedes Handys eintragen (Einstellungen > Standardserver bzw. beim ersten Verteiler-Zugriff):
    Server:    https://${NTFY_HOST}
    Benutzer:  ${FAMILY_USER}
    Passwort:  sudo cat ${PW_FILE}      (nur Betreiber; der Familie persönlich weitergeben, nicht per Chat)
Nach jedem Entfernen eines Mitglieds (oder verlorenem Handy) das Passwort wechseln:  sudo bash ~/lx-fampad/deploy/einrichtung-ntfy-up.sh --rotate
Der Server braucht nichts Neues: NTFY_URL/NTFY_TOKEN stehen schon in /etc/lx-fampad/env (Abschnitt 7); danach  sudo systemctl restart lx-fampad.
EOT
