#!/usr/bin/env bash
# Einrichtung der Abfuhrtermine ("Müll") auf dem Server (als root). Keine Geheimnisse in dieser Datei: der Link des Abfallkalenders
# (enthält den Schlüssel "key=…") wird nur abgefragt (ohne Echo) und in /etc/lx-fampad/env geschrieben (root:root, 0600).
#
#   sudo bash einrichtung-muell.sh einstellungen [--ort NAME] [--user-agent TEXT] [--dry-run]
#       NACH deploy.sh: fragt den Link ab, PRÜFT ihn (und Ort/Browser-Kennung) mit derselben Funktion wie der Server (dist/config.js) und schreibt
#       WASTE_ENABLED, WASTE_ICS_URL und ggf. WASTE_PLACE/WASTE_USER_AGENT gemeinsam und atomar in /etc/lx-fampad/env.
#   sudo bash einrichtung-muell.sh dienst [--dry-run]
#       NACH deploy.sh und dem ersten Start der API (Migration 0027): Abruf-Dienst lx-fampad-waste.service einrichten.
#
# Bricht irgendetwas ab (ungültiger Link, abweichender vorhandener Wert, Abbruch während der Eingabe), bleibt die env-Datei unverändert:
# geschrieben wird erst am Ende in eine Temp-Datei im selben Ordner (Rechte 0600), die dann per mv an ihre Stelle kommt.
# Idempotent: vorhandene Einträge mit gleichem Wert bleiben, ein abweichender Wert bricht ab (nichts wird überschrieben).
# Den Link ändern: von Hand in der env-Datei (sudoedit) und danach: sudo systemctl restart lx-fampad lx-fampad-waste.
# Der Link gehört nie ins Repo, ins Log oder in einen Chat. Der Ort ist nur ein Anzeigename (nie die Straße).
set -euo pipefail
umask 077

ENV_DATEI="${ENV_DATEI:-/etc/lx-fampad/env}"
POLLER="${POLLER:-/srv/fampad/server/dist/cli/waste-poller.js}"
CONFIG_JS="${CONFIG_JS:-/srv/fampad/server/dist/config.js}"
UNIT=lx-fampad-waste.service
UNIT_ZIEL="/etc/systemd/system/$UNIT"
UNIT_QUELLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$UNIT"

usage() {
  echo "Aufruf: sudo bash $0 einstellungen [--ort NAME] [--user-agent TEXT] [--dry-run]" >&2
  echo "        sudo bash $0 dienst [--dry-run]" >&2
  exit 2
}

modus="${1:-}"
[ "$modus" = "einstellungen" ] || [ "$modus" = "dienst" ] || usage
shift
trocken=0
ort="${WASTE_PLACE:-}"
ua=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) trocken=1 ;;
    --ort) [ $# -ge 2 ] || usage; ort="$2"; shift ;;
    --ort=*) ort="${1#--ort=}" ;;
    --user-agent) [ $# -ge 2 ] || usage; ua="$2"; shift ;;
    --user-agent=*) ua="${1#--user-agent=}" ;;
    *) echo "Unbekanntes Argument: $1" >&2; usage ;;
  esac
  shift
done
if [ "$modus" = "dienst" ] && { [ -n "$ort" ] || [ -n "$ua" ]; }; then usage; fi

# EINRICHTUNG_OHNE_ROOT=1: nur für Tests dieses Skripts (ohne root)
if [ "$(id -u)" -ne 0 ] && [ "${EINRICHTUNG_OHNE_ROOT:-0}" != 1 ]; then
  echo "Bitte mit sudo ausführen." >&2
  exit 1
fi

tu() { # Befehl ausführen oder im Trockenlauf nur anzeigen
  if [ "$trocken" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

# Prüft Link, Ort und Browser-Kennung mit derselben Funktion wie der Server (wasteConfig in dist/config.js). Eingabe nur über die Umgebung
# (nie als Argument, damit nichts in der Prozessliste steht); die Meldung nennt nie den Link.
pruefen() { # pruefen LINK ORT UA
  WASTE_ENABLED=true WASTE_ICS_URL="$1" WASTE_PLACE="$2" WASTE_USER_AGENT="$3" node --input-type=module -e '
    const { pathToFileURL } = await import("node:url");
    const m = await import(pathToFileURL(process.argv[1]).href);
    const c = m.wasteConfig(process.env, "production");
    if (c.configError) { console.error("    " + c.configError); process.exit(1); }
  ' "$CONFIG_JS"
}

einstellungen() {
  [ -f "$ENV_DATEI" ] || { echo "FEHLER: $ENV_DATEI fehlt." >&2; exit 1; }
  [ -f "$CONFIG_JS" ] || { echo "FEHLER: $CONFIG_JS fehlt. Erst deploy.sh ausführen." >&2; exit 1; }
  command -v node >/dev/null || { echo "FEHLER: node nicht gefunden." >&2; exit 1; }

  # 1. Vorhandenes lesen (nichts schreiben): abweichende Werte brechen ab, bevor etwas abgefragt wird
  vorhanden() { grep -E "^$1=" "$ENV_DATEI" | tail -n 1 || true; }
  en="$(vorhanden WASTE_ENABLED)"
  case "$en" in
    "") ;;
    "WASTE_ENABLED=true"|"WASTE_ENABLED=1") ;;
    *) echo "FEHLER: in $ENV_DATEI steht ein anderer Wert für WASTE_ENABLED (z. B. false). Nichts geändert; von Hand prüfen: sudoedit $ENV_DATEI" >&2; exit 1 ;;
  esac
  for k in WASTE_PLACE WASTE_USER_AGENT; do
    v="$(vorhanden "$k")"
    if [ -n "$v" ]; then
      neu="$ort"; [ "$k" = WASTE_USER_AGENT ] && neu="$ua"
      if [ -n "$neu" ] && [ "$v" != "$k=$neu" ]; then
        echo "FEHLER: $k steht schon anders in $ENV_DATEI. Nichts geändert; von Hand ändern: sudoedit $ENV_DATEI" >&2
        exit 1
      fi
    fi
  done

  # 2. Link ZUERST lesen und validieren (nichts wird geschrieben, solange etwas fehlt)
  link=""
  if [ -n "$(vorhanden WASTE_ICS_URL)" ]; then
    echo "==> WASTE_ICS_URL ist schon vorhanden (bleibt unverändert)."
  elif [ "$trocken" -eq 1 ]; then
    echo "[dry-run] der Link würde jetzt abgefragt (Eingabe unsichtbar) und geprüft"
  else
    echo "==> Link des Abfallkalenders (ICS) einfügen, Eingabe unsichtbar:"
    read -rs -p "    Link: " link
    echo
    # das Jahr im Zeitraum durch den Platzhalter ersetzen (timeperiod=YYYY0101-YYYY1231)
    link="$(printf '%s' "$link" | sed -E 's/timeperiod=[0-9]{4}0101-[0-9]{4}1231/timeperiod={YEAR}0101-{YEAR}1231/')"
    # Zeichen, die in einer env-Datei Ärger machen (Leerraum, Anführungszeichen, $, #, Backslash, Zeilenumbruch)
    if printf '%s' "$link" | grep -qE "[[:space:]\"'\$#\\\\]"; then echo "FEHLER: der Link enthält unzulässige Zeichen. Nichts geändert." >&2; exit 1; fi
  fi
  echo "==> Prüfung (dieselbe wie beim Start des Servers)"
  # ohne eingegebenen Link (vorhanden oder Trockenlauf) prüft ein Platzhalter-Link nur Ort und Browser-Kennung
  if ! pruefen "${link:-https://abfall.example.org/?timeperiod={YEAR}0101-{YEAR}1231}" "$ort" "$ua"; then
    echo "FEHLER: die Eingabe ist ungültig (siehe Meldung). Nichts geändert." >&2
    exit 1
  fi

  # 3. Was fehlt, wird gemeinsam und atomar angehängt
  neu_zeilen=()
  [ -z "$en" ] && neu_zeilen+=("WASTE_ENABLED=true")
  [ -n "$link" ] && neu_zeilen+=("WASTE_ICS_URL=$link")
  [ -n "$ort" ] && [ -z "$(vorhanden WASTE_PLACE)" ] && neu_zeilen+=("WASTE_PLACE=$ort")
  [ -n "$ua" ] && [ -z "$(vorhanden WASTE_USER_AGENT)" ] && neu_zeilen+=("WASTE_USER_AGENT=$ua")
  if [ "${#neu_zeilen[@]}" -eq 0 ]; then
    echo "Nichts zu tun: alles steht schon in $ENV_DATEI."
    return
  fi
  if [ "$trocken" -eq 1 ]; then
    for z in "${neu_zeilen[@]}"; do echo "[dry-run] anhängen: ${z%%=*}=…"; done
    echo "[dry-run] Sicherung der env-Datei, Temp-Datei im selben Ordner (0600), mv; nichts geschrieben."
    return
  fi
  tmp="$(mktemp "$ENV_DATEI.neu.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  cat "$ENV_DATEI" > "$tmp"
  # endet die Datei ohne Zeilenumbruch, würde der erste neue Eintrag an die letzte Zeile geklebt (und beide wären kaputt)
  if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]; then printf '\n' >> "$tmp"; fi
  printf '%s\n' "${neu_zeilen[@]}" >> "$tmp"
  chmod 600 "$tmp"
  chown --reference="$ENV_DATEI" "$tmp" 2>/dev/null || true
  sicherung="$ENV_DATEI.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$ENV_DATEI" "$sicherung"
  # nur die neueste Sicherung behalten (sie enthält Geheimnisse)
  ls -1t "$ENV_DATEI".bak-* 2>/dev/null | tail -n +2 | while read -r alt; do rm -f "$alt"; done
  mv -f "$tmp" "$ENV_DATEI"
  trap - EXIT
  unset link
  echo "==> angehängt: $(printf '%s\n' "${neu_zeilen[@]}" | cut -d= -f1 | tr '\n' ' ')"
  echo "Fertig. Danach: sudo systemctl restart lx-fampad (Schalter für die API) und '$0 dienst'."
}

dienst() {
  # Abruf-Dienst (eigener Prozess, deploy/lx-fampad-waste.service, README Abschnitt 13). Idempotent.
  [ -f "$UNIT_QUELLE" ] || { echo "FEHLER: $UNIT_QUELLE fehlt." >&2; exit 1; }
  [ -f "$POLLER" ] || { echo "FEHLER: $POLLER fehlt. Erst deploy.sh ausführen (Stand mit dem Abfuhr-Dienst)." >&2; exit 1; }
  [ -f "$ENV_DATEI" ] || { echo "FEHLER: $ENV_DATEI fehlt." >&2; exit 1; }
  if ! grep -qE '^WASTE_ENABLED=(true|1)[[:space:]]*$' "$ENV_DATEI"; then
    echo "Hinweis: WASTE_ENABLED=true steht nicht in $ENV_DATEI (erst 'einstellungen'). Der Dienst beendet sich sonst sofort und bleibt gestoppt." >&2
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp "$UNIT_QUELLE" "$tmp/$UNIT"
  echo "==> systemd-analyze verify"
  systemd-analyze verify "$tmp/$UNIT"
  geaendert=1
  # ab hier zählt nur die geprüfte Kopie in $tmp (nicht der Quellpfad im Home)
  if [ -f "$UNIT_ZIEL" ] && cmp -s "$tmp/$UNIT" "$UNIT_ZIEL"; then
    echo "==> Unit ist bereits aktuell: $UNIT_ZIEL"
    geaendert=0
  else
    echo "==> Unit wird installiert: $UNIT_ZIEL"
    if [ -f "$UNIT_ZIEL" ]; then diff -u "$UNIT_ZIEL" "$tmp/$UNIT" || true; fi
  fi
  if [ "$trocken" -eq 1 ]; then
    echo "[dry-run] install -m 0644 $UNIT_QUELLE $UNIT_ZIEL; systemctl daemon-reload; systemctl enable --now $UNIT (bei Änderung danach restart)"
    return
  fi
  if [ "$geaendert" -eq 1 ]; then
    install -m 0644 -o root -g root "$tmp/$UNIT" "$UNIT_ZIEL"
    systemctl daemon-reload
  fi
  systemctl enable --now "$UNIT"
  if [ "$geaendert" -eq 1 ]; then systemctl restart "$UNIT"; fi
  sleep 2
  systemctl --no-pager --full status "$UNIT" || true
  echo "Log: journalctl -u lx-fampad-waste -n 30 (zeigt nur Codes wie http_403, empty, network; nie den Link)"
}

"$modus"
