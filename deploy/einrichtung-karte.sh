#!/usr/bin/env bash
# ENTWURF (nicht ausgeführt, nicht auf dem Server getestet): Auslieferung der Kartenkacheln (PMTiles) unter https://familie.lx-labs.dev/karte-daten/
# (docs/KARTE-SPIKE.md, tools/karte/README.md). Idempotent, Muster wie einrichtung-ntfy.sh / einrichtung-2.sh.
#   1. Vorabprüfungen (nichts wird verändert, wenn eine fehlschlägt)
#   2. Ordner /srv/fampad/karte anlegen (Besitzer: der aufrufende Benutzer, damit "scp" ohne sudo dorthin kopieren kann)
#   3. Caddy: Der Block aus deploy/karte/karte-daten.handle wird in /etc/caddy/conf.d/fampad.caddy eingefügt (vor dem letzten Fang-Block "handle {").
#      Das Haupt-Caddyfile (gehört lx-labs.dev) wird NIE geschrieben. Ablauf: sichern, Kandidat validieren, ersetzen, Gesamtkonfiguration validieren,
#      erst dann reload, danach lx-labs.dev + familie prüfen; bei JEDEM Fehler Rückfall (vorherige fampad.caddy zurück, reload, lx-labs.dev prüfen).
#   4. Prüfung per HTTPS: Range-Anfrage auf die Datei (206, "PMTiles"-Kennung, kein Content-Encoding), falls sie schon liegt; sonst 404.
# Die CSP (Content-Security-Policy) in deploy/Caddyfile bleibt unverändert: die Karte lädt alles von der eigenen Domain (connect-src 'self').
#
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-karte.sh [--dry-run]
#   --dry-run  macht nur die Prüfungen, zeigt die geplante Änderung als Diff und schreibt/lädt nichts.
# WICHTIG: In tmux/screen starten (oder: sudo systemd-run --scope bash <Skript>), damit ein SSH-Abbruch den Lauf nicht mitten in der Caddy-Änderung beendet.
#
# Danach (Betrieb): neue Karte erzeugen und einspielen siehe tools/karte/README.md (scp nach /srv/fampad/karte/neu.pmtiles, atomar umbenennen).
# Hinweis: deploy.sh meldet eine Abweichung zwischen deploy/Caddyfile und conf.d/fampad.caddy und schlägt "cp" vor. Dieses cp würde den Karten-Block entfernen.
#   Dauerhafte Lösung (Entscheidung des Betreibers): den Block aus deploy/karte/karte-daten.handle in deploy/Caddyfile übernehmen (kein CSP-Eingriff);
#   dann erledigt deploy.sh das, und dieses Skript wird nur noch für Ordner und Prüfung gebraucht.
set -Eeuo pipefail

CADDYFILE=/etc/caddy/Caddyfile
SITE=/etc/caddy/conf.d/fampad.caddy
IMPORT_RE='^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy'
KARTE_DIR=/srv/fampad/karte
PMTILES_NAME=westerwald.pmtiles
MARKER='handle_path /karte-daten/*'
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_MAIN="/etc/caddy/Caddyfile.vor-karte.${STAMP}"             # nur zum Nachlesen; das Haupt-Caddyfile wird nie zurückgeschrieben
BACKUP_SITE="/etc/caddy/conf.d/fampad.caddy.vor-karte.${STAMP}.bak"   # endet nicht auf .caddy: wird nicht importiert

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "Aufruf: sudo bash $0 [--dry-run]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
  echo "Bitte als Benutzer lx starten:  sudo bash $0 [--dry-run]" >&2
  exit 1
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SELF_DIR/karte/karte-daten.handle"

ARMED=0
WORK=""
MAIN_SUM=""

aufraeumen() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }

zuruecksetzen() {
  trap - ERR INT TERM HUP
  set +e
  ARMED=0
  echo "!!  Fehler: fampad.caddy wird zurückgesetzt." >&2
  rm -f "$SITE.neu"
  if [ -f "$BACKUP_SITE" ]; then cp -p "$BACKUP_SITE" "$SITE"; fi
  systemctl reload caddy || true
  echo "    lx-labs.dev:  $(curl -sI --max-time 10 https://lx-labs.dev 2>/dev/null | head -1)" >&2
  echo "    Haupt-Caddyfile wurde nicht verändert. Ursache: journalctl -u caddy -n 50; danach das Skript erneut ausführen." >&2
  aufraeumen
  exit 1
}
bei_fehler() {
  local code=$? zeile=${1:-?}
  trap - ERR
  echo "!!  Fehler in Zeile $zeile (Code $code)." >&2
  if [ "$ARMED" = 1 ]; then zuruecksetzen; fi
  aufraeumen
  exit "$code"
}
bei_abbruch() {
  trap - ERR INT TERM HUP
  echo "!!  Abbruch." >&2
  if [ "$ARMED" = 1 ]; then zuruecksetzen; fi
  aufraeumen
  exit 130
}
trap 'bei_fehler $LINENO' ERR
trap bei_abbruch INT TERM HUP
trap aufraeumen EXIT

fehler() { echo "FEHLER: $*" >&2; exit 1; }

# --- 1. Vorabprüfungen -----------------------------------------------------------------------------------------------------
echo "==> 1/4 Prüfungen$([ "$DRY" = 1 ] && echo ' (Trockenlauf: es wird nichts verändert)')"
for b in curl caddy systemctl sha256sum awk install; do
  command -v "$b" >/dev/null || fehler "$b fehlt"
done
[ -f "$FRAGMENT" ] || fehler "$FRAGMENT fehlt (Repository aktuell? git pull)"
if ! grep -q "$MARKER" "$FRAGMENT" || ! grep -q "root \* $KARTE_DIR" "$FRAGMENT"; then fehler "karte-daten.handle passt nicht zu $KARTE_DIR"; fi
[ -f "$CADDYFILE" ] || fehler "$CADDYFILE fehlt"
[ -f "$SITE" ] || fehler "$SITE fehlt (zuerst einrichtung-2.sh)"
grep -qsE "$IMPORT_RE" "$CADDYFILE" || fehler "In $CADDYFILE fehlt 'import /etc/caddy/conf.d/*.caddy' (zuerst einrichtung-2.sh, Schritt 6 in deploy/README.md). Das Skript ändert das Haupt-Caddyfile nie."
curl -fsI --max-time 10 https://lx-labs.dev >/dev/null || fehler "lx-labs.dev antwortet schon vor der Änderung nicht, Abbruch"
echo "    lx-labs.dev antwortet."
# Der Fang-Block "handle {" muss genau einmal als Block der Site vorkommen, sonst weiß das Skript nicht, wohin der Karten-Block gehört
N="$(grep -cE '^	handle \{$' "$SITE" || true)"
[ "$N" = 1 ] || fehler "$SITE enthält $N Zeilen '<Tab>handle {' (erwartet genau 1); Aufbau der Datei hat sich geändert, Block von Hand einfügen"
MAIN_SUM="$(sha256sum "$CADDYFILE" | cut -d' ' -f1)"

WORK="$(mktemp -d)"
NEU=1
if grep -qF "$MARKER" "$SITE"; then
  NEU=0
  echo "    $SITE enthält den Karten-Block schon (kein Eingriff in Caddy nötig)."
else
  awk -v fragment="$FRAGMENT" 'BEGIN{while((getline l < fragment)>0) f=f l "\n"} /^\thandle \{$/ && !done {printf "%s", f; done=1} {print}' "$SITE" > "$WORK/fampad.caddy"
  grep -qF "$MARKER" "$WORK/fampad.caddy" || fehler "Einfügen des Karten-Blocks fehlgeschlagen"
  # Kandidat allein prüfen (vor jeder Änderung an /etc/caddy/conf.d)
  caddy validate --config "$WORK/fampad.caddy" --adapter caddyfile >/dev/null 2>&1 || fehler "Kandidat der fampad.caddy ist ungültig; nichts verändert"
  echo "    Kandidat ist gültig. Geplante Änderung an $SITE:"
  diff -u "$SITE" "$WORK/fampad.caddy" | sed 's/^/      /' || true
fi
# CSP bleibt unverändert: der Kandidat darf die Content-Security-Policy-Zeile nicht ändern
if [ "$NEU" = 1 ]; then
  [ "$(grep -F 'Content-Security-Policy' "$SITE")" = "$(grep -F 'Content-Security-Policy' "$WORK/fampad.caddy")" ] || fehler "CSP-Zeile würde sich ändern (nicht vorgesehen)"
fi

if [ "$DRY" = 1 ]; then
  echo "==> Trockenlauf beendet: alle Prüfungen bestanden. Geplant wäre: $KARTE_DIR anlegen (Besitzer $SUDO_USER),"
  [ "$NEU" = 1 ] && echo "    Karten-Block in $SITE einfügen, validieren, reload, Range-Prüfung. Haupt-Caddyfile bleibt unberührt."
  exit 0
fi

# --- 2. Ordner ---------------------------------------------------------------------------------------------------------------
echo "==> 2/4 Ordner $KARTE_DIR"
install -d -m 755 -o "$SUDO_USER" -g "$SUDO_USER" "$KARTE_DIR"

# --- 3. Caddy ------------------------------------------------------------------------------------------------------------------
echo "==> 3/4 Caddy ($SITE)"
if [ "$NEU" = 1 ]; then
  cp -p "$CADDYFILE" "$BACKUP_MAIN"
  echo "    Sicherung des Haupt-Caddyfiles (nur zum Nachlesen): $BACKUP_MAIN"
  cp -p "$SITE" "$BACKUP_SITE"
  echo "    Sicherung der bisherigen fampad.caddy: $BACKUP_SITE"
  ARMED=1
  # atomar: erst unter einem Namen ohne .caddy-Endung (wird nicht importiert), dann umbenennen
  install -m 644 -o root -g root "$WORK/fampad.caddy" "$SITE.neu"
  mv -f "$SITE.neu" "$SITE"
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
  systemctl reload caddy
  sleep 3
  echo "    lx-labs.dev: $(curl -fsI --max-time 10 https://lx-labs.dev | head -1)"
fi

# --- 4. Prüfung ----------------------------------------------------------------------------------------------------------------
echo "==> 4/4 Prüfung per HTTPS"
URL="https://familie.lx-labs.dev/karte-daten/$PMTILES_NAME"
curl -fsI --max-time 10 https://lx-labs.dev >/dev/null
curl -fsS --max-time 10 https://familie.lx-labs.dev/api/v1/health 2>/dev/null | grep -q '"db":"ok"' || { echo "    familie.lx-labs.dev antwortet nicht mehr mit db ok" >&2; false; }
if [ -s "$KARTE_DIR/$PMTILES_NAME" ]; then
  # Range auf die ersten 16 Byte; Accept-Encoding wie ein Browser, damit eine (unerwünschte) Kompression auffiele
  H="$(curl -s -D "$WORK/h.txt" -o "$WORK/b.bin" --max-time 20 -H 'Accept-Encoding: gzip, br, zstd' -r 0-15 "$URL" -w '%{http_code}')"
  [ "$H" = 206 ] || { echo "    Range-Anfrage liefert $H statt 206" >&2; false; }
  head -c 7 "$WORK/b.bin" | grep -q 'PMTiles' || { echo "    Antwort beginnt nicht mit der PMTiles-Kennung" >&2; false; }
  ! grep -qi '^content-encoding:' "$WORK/h.txt" || { echo "    Antwort ist komprimiert (Content-Encoding): Range-Anfragen würden brechen" >&2; false; }
  grep -qi '^etag:' "$WORK/h.txt" || { echo "    kein ETag" >&2; false; }
  echo "    Range-Anfrage: 206, PMTiles-Kennung, kein Content-Encoding, ETag vorhanden."
else
  C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)"
  echo "    $KARTE_DIR/$PMTILES_NAME liegt noch nicht dort (HTTP $C, erwartet 404). Datei einspielen: tools/karte/README.md."
fi
[ "$(sha256sum "$CADDYFILE" | cut -d' ' -f1)" = "$MAIN_SUM" ] || { echo "    Haupt-Caddyfile hat sich während des Laufs geändert (nicht durch dieses Skript)" >&2; false; }
ARMED=0
trap - ERR INT TERM HUP
echo "    lx-labs.dev: $(curl -sI --max-time 10 https://lx-labs.dev | head -1)"

cat <<EOF

Fertig. Kacheln werden unter $URL ausgeliefert.
Rückbau: sudo cp $BACKUP_SITE $SITE && sudo systemctl reload caddy   (bzw. den Block 'handle_path /karte-daten/*' aus $SITE entfernen)
EOF
