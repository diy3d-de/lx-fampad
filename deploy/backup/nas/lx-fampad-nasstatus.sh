#!/usr/bin/env bash
# Läuft auf dem NAS (oder dem Rechner, der die Sicherung ABHOLT): meldet dem Server den Stand der Abholung und des Wiederherstellungstests (Betrieb Paket 3).
# Der Server hält keine Zugangsdaten zum NAS: der Rückweg ist ein zweiter, eigener SSH-Schlüssel des NAS, der auf dem Server nur den erzwungenen Befehl
# lx-fampad-nasstatus-empfang ausführen darf (eine validierte Datei von höchstens 4 KB in einen eigenen Ordner, nichts sonst; einrichtung-nasstatus.sh).
#
# Gelesen werden nur die beiden Statusdateien dieses NAS (`$DEST/pull-status` vom Pull-Skript, `$DEST/restoretest-status` vom Wiederherstellungstest). Aus ihnen wird eine
# neue, kleine Datei gebaut, die ausschließlich feste Schlüssel mit Zahlen, Zeitpunkten und ok/fehler/ja/nein enthält (alles andere wird verworfen): nie Pfade, Dateinamen,
# Fehlertexte oder Inhalte. Das Pull- und das Restoretest-Skript rufen dieses Skript am Ende jedes Laufs auf (nur wenn der Schlüssel unten existiert); es lässt sich
# auch von Hand starten:  bash lx-fampad-nasstatus.sh [--print]
#   --print   nur anzeigen, was gesendet würde (nichts senden)
# Ein Fehler beim Senden ist nie ein Fehler der Sicherung: das Skript meldet ihn und endet mit Exit 1, die aufrufenden Skripte ignorieren das.
#
# Einstellungen per Umgebungsvariable (dieselben Namen wie beim Pull-Skript, LXB_…):
#   LXB_SERVER, LXB_PORT, LXB_DEST, LXB_KNOWN_HOSTS  wie lx-fampad-pull.sh (derselbe Server, dieselbe known_hosts-Datei)
#   LXB_STATUS_KEY   privater SSH-Schlüssel NUR für diese Meldung (Standard ~/.ssh/lx-fampad-status)
#   LXB_STATUS_USER  Benutzer auf dem Server (Standard lxnasstatus)
set -Eeuo pipefail
umask 077

SERVER="${LXB_SERVER:-familyhub.lx-labs.dev}"
PORT="${LXB_PORT:-22}"
DEST="${LXB_DEST:-/volume1/backup/lx-fampad}"
KNOWN_HOSTS="${LXB_KNOWN_HOSTS:-$HOME/.ssh/lx-fampad-backup.known_hosts}"
KEY="${LXB_STATUS_KEY:-$HOME/.ssh/lx-fampad-status}"
SSH_USER="${LXB_STATUS_USER:-lxnasstatus}"

PRINT=0
case "${1:-}" in
  --print) PRINT=1 ;;
  '') ;;
  *) echo "Aufruf: $0 [--print]" >&2; exit 2 ;;
esac

case "$SERVER$KEY$KNOWN_HOSTS$SSH_USER" in
  *[[:space:]\'\"\\]*) echo "Host, Benutzer und Pfade dürfen keine Leerzeichen, Anführungszeichen oder Backslashes enthalten" >&2; exit 2 ;;
esac
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "LXB_PORT muss eine Zahl sein" >&2; exit 2; }

# Wert einer Statusdatei lesen und nur zurückgeben, wenn er zur erwarteten Art passt (sonst leer)
lesen() {   # $1 = Datei, $2 = Schlüssel, $3 = Art (epoch|count|ok|ja)
  local f="$1" k="$2" art="$3" v
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %s "$f")" -le 4096 ] || return 0
  v="$(sed -n "s/^$k=\([0-9A-Za-z:._-]*\)\$/\1/p" "$f" | head -1)"
  case "$art" in
    epoch) [[ "$v" =~ ^[0-9]{10,11}$ ]] && echo "$v" ;;
    count) [[ "$v" =~ ^[0-9]{1,5}$ ]] && echo "$v" ;;
    ok) { [ "$v" = ok ] || [ "$v" = fehler ]; } && echo "$v" ;;
    ja) { [ "$v" = ja ] || [ "$v" = nein ]; } && echo "$v" ;;
  esac
  return 0
}
zeile() { local k="$1" v="$2"; [ -z "$v" ] || echo "$k=$v"; return 0; }

PULL="$DEST/pull-status"
REST="$DEST/restoretest-status"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
{
  echo "nas_format=1"
  echo "reported_epoch=$(date -u +%s)"
  zeile pull_result "$(lesen "$PULL" last_result ok)"
  zeile pull_run_epoch "$(lesen "$PULL" last_run_epoch epoch)"
  zeile pull_success_epoch "$(lesen "$PULL" last_success_epoch epoch)"
  zeile pull_newest_epoch "$(lesen "$PULL" newest_backup_epoch epoch)"
  zeile pull_count "$(lesen "$PULL" archive_count count)"
  zeile restore_result "$(lesen "$REST" last_result ok)"
  zeile restore_run_epoch "$(lesen "$REST" last_run_epoch epoch)"
  zeile restore_success_epoch "$(lesen "$REST" last_success_epoch epoch)"
  zeile restore_config_check "$(lesen "$REST" config_check ja)"
} > "$TMP"
grep -q '^\(pull\|restore\)_result=' "$TMP" || { echo "Keine Statusdatei mit Ergebnis gefunden ($PULL, $REST): nichts zu melden." >&2; exit 1; }

if [ "$PRINT" = 1 ]; then cat "$TMP"; exit 0; fi

[ -r "$KEY" ] || { echo "SSH-Schlüssel für die Statusmeldung nicht lesbar: $KEY" >&2; exit 1; }
[ -s "$KNOWN_HOSTS" ] || { echo "known_hosts-Datei fehlt: $KNOWN_HOSTS" >&2; exit 1; }
# -T: kein Terminal; der Server führt nur den erzwungenen Befehl aus und ignoriert alles, was hier stünde
timeout 60 ssh -T -p "$PORT" -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" \
  -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$SSH_USER@$SERVER" < "$TMP" >/dev/null \
  || { echo "Statusmeldung an den Server fehlgeschlagen (Schlüssel, Adresse, Einrichtung auf dem Server prüfen)" >&2; exit 1; }
echo "Status an den Server gemeldet."
