#!/bin/bash
# NUR FÜR DEN CONTAINER-TEST (test-integration.sh): Attrappe für systemctl in einem Container ohne systemd.
# Startet lx-fampad (mit vorgeschalteter Migration), ntfy und die Sicherung als normale Prozesse; alles andere ist ein Nichtstun.
# Wird nie auf einem echten Server installiert.
STATE=/run/fake-systemctl
mkdir -p "$STATE"
cmd="${1:-}"; shift || true
args=()
for a in "$@"; do case "$a" in -*) ;; *) args+=("${a%.service}") ;; esac; done
unit="${args[0]:-}"
pidfile="$STATE/$unit.pid"

laeuft() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
# setsid: der Dienst bekommt eine eigene Prozessgruppe, die beim Stoppen komplett beendet wird (runuser leitet das Signal nicht an den Kindprozess weiter)
stoppen() { if laeuft; then kill -- "-$(cat "$pidfile")" 2>/dev/null; sleep 1; fi; rm -f "$pidfile"; }
lade_env() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|'#'*) ;; *) export "${l?}" ;; esac
  done < "$1"
}
starten() {
  case "$unit" in
    lx-fampad)
      ( lade_env /etc/lx-fampad/migrate.env; export NODE_ENV=production; cd /srv/fampad/server && runuser -u lx-fampad -- node dist/db/migrate-cli.js ) >> /var/log/fake-lx-fampad-migrate.log 2>&1 || return 1
      ( lade_env /etc/lx-fampad/env; export NODE_ENV=production HOST=127.0.0.1 PORT=4400; cd /srv/fampad/server; setsid runuser -u lx-fampad -- node dist/server.js >> /var/log/fake-lx-fampad.log 2>&1 & echo $! > "$pidfile" )
      ;;
    ntfy)
      ( setsid runuser -u ntfy -- ntfy serve --config /etc/ntfy/server.yml >> /var/log/fake-ntfy.log 2>&1 & echo $! > "$pidfile" )
      ;;
    lx-fampad-backup)
      /usr/local/sbin/lx-fampad-backup
      ;;
    *) ;;
  esac
}
case "$unit" in
  postgresql@*)   # pg_ctlcluster ruft systemctl auf, sobald /run/systemd/system existiert
    cl="${unit#postgresql@}"
    case "$cmd" in
      start|stop|restart|reload) exec pg_ctlcluster --skip-systemctl-redirect "${cl%%-*}" "${cl#*-}" "$cmd" ;;
      is-active) pg_ctlcluster --skip-systemctl-redirect "${cl%%-*}" "${cl#*-}" status >/dev/null 2>&1; exit $? ;;
    esac ;;
esac
case "$cmd" in
  restart) stoppen; starten ;;
  start) laeuft || starten ;;
  stop) stoppen ;;
  enable) case " $* " in *" --now "*) touch "$STATE/$unit.aktiv"; laeuft || starten ;; esac ;;
  is-active) case "$unit" in postgresql) (cd / && runuser -u postgres -- pg_isready -q) ;; caddy) true ;; *.timer) [ -f "$STATE/$unit.aktiv" ] ;; *) laeuft ;; esac ;;
  cat) [ -f "/etc/systemd/system/$unit.service" ] ;;
  is-enabled) exit 1 ;;
  list-timers) echo "(Attrappe) lx-fampad-backup.timer" ;;
  daemon-reload|disable|reload|reset-failed|is-failed) ;;
  *) ;;   # preset, daemon-reload der Paket-Skripte usw.: nichts zu tun
esac
exit $?
