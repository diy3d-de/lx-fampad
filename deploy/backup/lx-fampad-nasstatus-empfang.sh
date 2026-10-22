#!/bin/bash
# Erzwungener Befehl des NAS-Statuskanals (Betrieb Paket 3): das NAS schickt nach jeder Abholung und jedem Wiederherstellungstest eine kleine Statusdatei an den Server.
# Der Server hält dafür KEINE Zugangsdaten zum NAS; der SSH-Schlüssel des NAS (eigener, zweiter Schlüssel, nur von der NAS-Adresse) darf auf dem Server genau diesen
# Befehl ausführen (authorized_keys: restrict,from="<NAS-IP>",command="/usr/local/sbin/lx-fampad-nasstatus-empfang"), sonst nichts: keine Shell, kein PTY, keine Weiterleitung.
#
# Der Befehl liest von stdin höchstens 4 KB (Zeitlimit 30 Sekunden), prüft JEDE Zeile streng und schreibt die Datei atomar nach $DIR/nas.status (Ordner gehört dem Benutzer lxnasstatus, Gruppe
# lx-fampad liest; der Dienst lx-fampad kann dort nichts schreiben). Geprüft wird:
#   - Größe höchstens 4096 Bytes, keine NUL-Bytes, höchstens 30 Zeilen, keine doppelten Schlüssel
#   - nur Zeilen "schluessel=wert" (a-z und _ ; Werte nur [0-9A-Za-z:._-])
#   - nur bekannte Schlüssel (Whitelist unten), Werte je Schlüssel als Zahl, Zeitpunkt (Unix-Sekunden, plausibel, nicht in der Zukunft), "ok"/"fehler" oder "ja"/"nein"
# Nicht Erlaubtes wird abgelehnt (Exit 1, die alte Datei bleibt unverändert). SSH_ORIGINAL_COMMAND und alle Argumente werden ignoriert. Der Befehl ergänzt die Zeile
# received_epoch (Uhr des Servers); eine vom NAS gesendete Zeile gleichen Namens wird abgelehnt (nicht in der Whitelist).
# Er legt nichts außerhalb von $DIR an, ruft keine anderen Programme mit Eingaben aus der Datei auf und gibt nie Dateiinhalt aus.
#
# Einrichtung: deploy/backup/einrichtung-nasstatus.sh (root, --dry-run), Anleitung docs/BACKUP-EINRICHTUNG-SCHRITTE.md Abschnitt 11.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 027

# Der Zielordner ist fest. Nur ohne SSH-Sitzung (Selbsttest der Einrichtung, Tests) darf LX_NASSTATUS_DIR ihn ersetzen: über SSH ist SSH_CONNECTION immer gesetzt,
# so kann nie ein Client (auch nicht über AcceptEnv oder SetEnv) den Ordner umlenken.
DIR=/var/lib/lx-fampad-nasstatus
if [ -z "${SSH_CONNECTION:-}" ] && [ -n "${LX_NASSTATUS_DIR:-}" ]; then DIR="$LX_NASSTATUS_DIR"; fi
MAX_BYTES=4096
MAX_LINES=30

abgelehnt() { echo "abgelehnt: $1" >&2; exit 1; }

[ -d "$DIR" ] && [ ! -L "$DIR" ] || abgelehnt "Zielordner fehlt"
# liegengebliebene Zwischendateien (abgebrochene Übertragung) nach 5 Minuten wegräumen: im eigenen Ordner, nur eigene Namen, keine Links
find "$DIR" -maxdepth 1 -type f \( -name '.empfang.*' -o -name '.nas.status.*' \) -mmin +5 -delete 2>/dev/null || true
IN="$(mktemp "$DIR/.empfang.XXXXXX")" || abgelehnt "Zwischendatei nicht anlegbar"
OUT="$(mktemp "$DIR/.nas.status.XXXXXX")" || { rm -f "$IN"; abgelehnt "Zwischendatei nicht anlegbar"; }
trap 'rm -f "$IN" "$OUT"' EXIT

# höchstens MAX_BYTES + 1 Byte lesen: ist es mehr, wird abgelehnt (nie ein abgeschnittener Rest)
# mit Zeitlimit: ein NAS, das die Verbindung offen hält und nichts sendet, blockiert den Befehl höchstens 30 Sekunden
timeout 30 head -c "$((MAX_BYTES + 1))" > "$IN" || abgelehnt "Lesen fehlgeschlagen oder Zeitlimit"
[ "$(stat -c %s "$IN")" -le "$MAX_BYTES" ] || abgelehnt "mehr als 4 KB"
[ "$(stat -c %s "$IN")" -gt 0 ] || abgelehnt "leer"
[ "$(tr -d '\000' < "$IN" | wc -c)" = "$(stat -c %s "$IN")" ] || abgelehnt "NUL-Byte"

JETZT="$(date -u +%s)"
# Werte je Schlüssel: epoch = Unix-Sekunden (10 bis 11 Ziffern, ab 2020, höchstens eine Stunde in der Zukunft), count = 1 bis 5 Ziffern, ok = ok|fehler, ja = ja|nein
wert_ok() {   # $1 = Art, $2 = Wert
  case "$1" in
    epoch) [[ "$2" =~ ^[0-9]{10,11}$ ]] && [ "$((10#$2))" -ge 1600000000 ] && [ "$((10#$2))" -le "$((JETZT + 3600))" ] ;;
    count) [[ "$2" =~ ^[0-9]{1,5}$ ]] ;;
    ok) [ "$2" = ok ] || [ "$2" = fehler ] ;;
    ja) [ "$2" = ja ] || [ "$2" = nein ] ;;
    version) [ "$2" = 1 ] ;;
    *) return 1 ;;
  esac
}
art_von() {   # Whitelist der Schlüssel
  case "$1" in
    nas_format) echo version ;;
    reported_epoch|pull_run_epoch|pull_success_epoch|pull_newest_epoch|restore_run_epoch|restore_success_epoch) echo epoch ;;
    pull_count) echo count ;;
    pull_result|restore_result) echo ok ;;
    restore_config_check) echo ja ;;
    *) echo "" ;;
  esac
}

declare -A GESEHEN=()
ZEILEN=0
ECHT=0
while IFS= read -r zeile || [ -n "$zeile" ]; do
  zeile="${zeile%$'\r'}"
  [ -n "$zeile" ] || continue
  ZEILEN=$((ZEILEN + 1))
  [ "$ZEILEN" -le "$MAX_LINES" ] || abgelehnt "zu viele Zeilen"
  [[ "$zeile" =~ ^[a-z_]+=[0-9A-Za-z:._-]*$ ]] || abgelehnt "Zeile mit unerwartetem Format"
  schluessel="${zeile%%=*}"
  wert="${zeile#*=}"
  art="$(art_von "$schluessel")"
  [ -n "$art" ] || abgelehnt "unbekannter Schlüssel"
  [ -z "${GESEHEN[$schluessel]:-}" ] || abgelehnt "doppelter Schlüssel"
  GESEHEN[$schluessel]=1
  wert_ok "$art" "$wert" || abgelehnt "ungültiger Wert für $schluessel"
  printf '%s=%s\n' "$schluessel" "$wert" >> "$OUT"
  case "$schluessel" in pull_result|restore_result) ECHT=1 ;; esac
done < "$IN"
[ "$ECHT" = 1 ] || abgelehnt "weder Abholung noch Wiederherstellungstest enthalten"

printf 'received_epoch=%s\n' "$JETZT" >> "$OUT"
chmod 0640 "$OUT"
mv -f "$OUT" "$DIR/nas.status"
echo "ok"
