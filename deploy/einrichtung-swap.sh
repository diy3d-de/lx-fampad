#!/usr/bin/env bash
# Swapdatei einrichten (Standard 1 GB, /swapfile, 0600, vm.swappiness=10). Der Server hat 2 GB RAM und derzeit keinen Swap; ein kurzer
# Speicherengpass (Deploy, Sicherung, Build) würde sonst den OOM-Killer auslösen, der auch lx-labs treffen kann.
# Idempotent: ist /swapfile schon aktiv oder in /etc/fstab eingetragen, wird nichts doppelt angelegt.
# Es wird nichts an lx-labs, Caddy oder PostgreSQL verändert.
#
# Aufruf auf dem Server als Benutzer lx:   sudo bash ~/lx-fampad/deploy/einrichtung-swap.sh [--dry-run] [--size-mb 1024]
#   --dry-run     nur prüfen und anzeigen, was geschähe
#   --size-mb N   Größe in MB (Standard 1024, 256 bis 8192)
# Rückbau:  sudo swapoff /swapfile && sudo rm /swapfile && sudo sed -i '\|^/swapfile |d' /etc/fstab && sudo rm /etc/sysctl.d/99-lx-fampad-swap.conf && sudo sysctl vm.swappiness=60
set -Eeuo pipefail

SWAPFILE=/swapfile
SIZE_MB=1024
SYSCTL=/etc/sysctl.d/99-lx-fampad-swap.conf
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --size-mb) [ $# -ge 2 ] || { echo "--size-mb braucht einen Wert" >&2; exit 2; }; SIZE_MB="$2"; shift ;;
    -h|--help) sed -n '2,/^set -E/{/^set -E/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Aufruf: sudo bash $0 [--dry-run] [--size-mb N]" >&2; exit 2 ;;
  esac
  shift
done
{ [[ "$SIZE_MB" =~ ^[0-9]+$ ]] && [ "$SIZE_MB" -ge 256 ] && [ "$SIZE_MB" -le 8192 ]; } || { echo "FEHLER: --size-mb muss zwischen 256 und 8192 liegen." >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten:  sudo bash $0" >&2; exit 1; }

tue() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }
fehler() { echo "FEHLER: $*" >&2; exit 1; }
FSTAB="${LXB_FSTAB:-/etc/fstab}"          # nur für Tests überschreibbar
NO_ACT="${LXB_SWAP_NO_ACTIVATE:-0}"       # nur für Tests im Container (kein mkswap/swapon)
ANGELEGT=0        # 1: diese Swapdatei stammt aus diesem Lauf (wird bei Fehler entfernt)
FSTAB_GEAENDERT=0 # 1: fstab wurde in diesem Lauf geändert (wird bei Fehler aus der Sicherung zurückgespielt)
zurueck() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    set +e
    if [ "$FSTAB_GEAENDERT" = 1 ] && [ -f "$FSTAB.vor-swap" ]; then
      echo "!!  Fehler: $FSTAB wird aus der Sicherung zurückgespielt." >&2
      cp -p "$FSTAB.vor-swap" "$FSTAB"
    fi
    rm -f "$FSTAB.neu"
    if [ "$ANGELEGT" = 1 ]; then
      echo "!!  Fehler: angelegte Swapdatei wird entfernt." >&2
      # nur löschen, wenn swapoff gelang oder die Datei gar nicht aktiv ist (sonst läge ein aktiver Swap unter dem Dateisystem weg)
      if swapoff "$SWAPFILE" 2>/dev/null || ! swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
        rm -f "$SWAPFILE"
      else
        echo "!!  WARNUNG: swapoff $SWAPFILE schlug fehl, die aktive Swapdatei bleibt bestehen (von Hand prüfen)." >&2
      fi
    fi
  fi
  exit "$rc"
}
trap zurueck EXIT

echo "==> Prüfungen$([ "$DRY" = 1 ] && echo ' (Trockenlauf)')"
echo "    RAM: $(free -m | awk '/^Mem:/{print $2" MB gesamt, "$7" MB verfügbar"}'); Swap jetzt: $(free -m | awk '/^Swap:/{print $2" MB"}')"
AKTIV=0
if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then AKTIV=1; echo "    $SWAPFILE ist schon aktiv."; fi
if [ "$AKTIV" = 1 ] && [ "$(stat -c '%a %U' "$SWAPFILE")" != "600 root" ]; then
  fehler "$SWAPFILE ist aktiv, hat aber nicht die Rechte 0600 root (chmod 600 $SWAPFILE von Hand; das Skript ändert eine laufende Swapdatei nicht)"
fi
if [ "$AKTIV" = 0 ] && [ -e "$SWAPFILE" ]; then
  fehler "$SWAPFILE existiert, ist aber nicht aktiv. Prüfen (ls -l $SWAPFILE); das Skript überschreibt nichts."
fi
if [ "$AKTIV" = 0 ]; then
  FREI_MB="$(df --output=avail -m / | tail -1 | tr -d ' ')"
  # nach dem Anlegen sollen mindestens 4 GB frei bleiben (Datenbank, Sicherungen, Updates)
  [ "$FREI_MB" -ge $((SIZE_MB + 4096)) ] || fehler "zu wenig freier Platz auf /: ${FREI_MB} MB (benötigt ${SIZE_MB} MB + 4096 MB Reserve)"
  echo "    freier Platz auf /: ${FREI_MB} MB, benötigt: ${SIZE_MB} MB."
  FSTYPE="$(findmnt -no FSTYPE -T /)"
  echo "    Dateisystem: $FSTYPE"
  case "$FSTYPE" in btrfs|zfs) fehler "Swapdatei auf $FSTYPE braucht Sonderbehandlung, bitte von Hand einrichten." ;; esac
fi
[ -f "$FSTAB" ] || fehler "$FSTAB fehlt"
FSTAB_HAT=0; if grep -qE '^[[:space:]]*/swapfile[[:space:]]' "$FSTAB"; then FSTAB_HAT=1; fi
echo "    fstab-Eintrag: $([ "$FSTAB_HAT" = 1 ] && echo vorhanden || echo fehlt)"
if [ -f "$SYSCTL" ] && grep -qx 'vm.swappiness=10' "$SYSCTL"; then echo "    swappiness-Datei vorhanden."; fi

echo "==> Anlegen"
if [ "$AKTIV" = 0 ]; then
  if [ "$DRY" = 0 ]; then ANGELEGT=1; fi
  tue install -m 0600 -o root -g root /dev/null "$SWAPFILE"
  tue ionice -c3 dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=none
  tue chmod 0600 "$SWAPFILE"
  if [ "$NO_ACT" = 0 ]; then
    tue mkswap -q "$SWAPFILE"
    tue swapon "$SWAPFILE"
    if [ "$DRY" = 0 ]; then echo "    $SWAPFILE ($SIZE_MB MB) aktiviert."; fi
  fi
fi
if [ "$FSTAB_HAT" = 0 ]; then
  if [ "$DRY" = 1 ]; then
    echo "    [dry-run] $FSTAB: Kopie bauen, '/swapfile none swap sw 0 0' anhängen (mit Zeilenumbruch-Prüfung), findmnt --verify, erst dann ersetzen (Sicherung $FSTAB.vor-swap)"
  else
    cp -p "$FSTAB" "$FSTAB.vor-swap"
    cp -p "$FSTAB" "$FSTAB.neu"
    # fehlt der Zeilenumbruch am Ende, würde der Eintrag an die letzte Zeile geklebt
    if [ -s "$FSTAB.neu" ] && [ -n "$(tail -c1 "$FSTAB.neu")" ]; then echo >> "$FSTAB.neu"; fi
    printf '%s\n' '/swapfile none swap sw 0 0' >> "$FSTAB.neu"
    RC_ALT=0; findmnt --verify --tab-file "$FSTAB" >/dev/null 2>&1 || RC_ALT=$?
    RC_NEU=0; VERIFY="$(findmnt --verify --tab-file "$FSTAB.neu" 2>&1)" || RC_NEU=$?
    if [ "$RC_NEU" -gt "$RC_ALT" ]; then echo "$VERIFY" >&2; fehler "findmnt --verify meldet Fehler in der neuen fstab; $FSTAB bleibt unverändert."; fi
    FSTAB_GEAENDERT=1
    mv -f "$FSTAB.neu" "$FSTAB"
    echo "    fstab ergänzt (Sicherung: $FSTAB.vor-swap)."
  fi
fi
if [ "$DRY" = 1 ]; then
  echo "    [dry-run] $SYSCTL: vm.swappiness=10"
else
  printf '%s\n' '# lx-fampad: Swap nur im Notfall nutzen' 'vm.swappiness=10' > "$SYSCTL"
  if [ "$NO_ACT" = 0 ]; then sysctl -q -p "$SYSCTL"; fi
fi

if [ "$DRY" = 0 ]; then
  echo "==> Prüfung"
  if [ "$NO_ACT" = 0 ]; then
    if [ "$AKTIV" = 0 ]; then
      # fstab-Probe (nur für die in diesem Lauf angelegte Datei): aus und über die fstab wieder ein, genau wie beim Neustart
      swapoff "$SWAPFILE"
      swapon -a || fehler "swapon -a mit der neuen fstab schlägt fehl"
    else
      echo "    $SWAPFILE war schon aktiv: die Probe mit swapoff/swapon wird übersprungen (laufender Swap bleibt unangetastet); fstab-Prüfung per findmnt --verify."
    fi
    swapon --show=NAME --noheadings | grep -qx "$SWAPFILE" || fehler "$SWAPFILE ist nicht aktiv"
    swapon --show
    [ "$(sysctl -n vm.swappiness)" = 10 ] || fehler "vm.swappiness ist nicht 10"
  fi
  [ "$(stat -c '%a %U' "$SWAPFILE")" = "600 root" ] || fehler "$SWAPFILE hat falsche Rechte"
  free -m
  ANGELEGT=0
  FSTAB_GEAENDERT=0
  rm -f "$FSTAB.neu"
  echo "Fertig. Neustart-Test: nach dem nächsten Neustart zeigt 'swapon --show' die Datei wieder. Sicherung der alten fstab: $FSTAB.vor-swap"
else
  echo "==> Trockenlauf beendet, nichts verändert."
fi
