#!/bin/sh
# TournamentLive stream supervisor — Linux/container port of supervisor.ps1.
#
# Screens are DECOUPLED from tatami: each broadcast/<screen> is fed from a
# SOURCE tatami chosen by the route table (ctl.py /routes), not by letter:
#   "<screen>=<letter>"  pin that tatami input to the screen
#   "<screen>=auto"      (default) take the first online input not pinned
#                        and not claimed by an earlier auto screen
#   source offline/none  -> loop the fallback clip (the source's clip when a
#   source is known, otherwise the screen's own)
# Platforms (VK/YouTube) and the cockpit read broadcast/<x>, so the outbound
# publication survives an input drop (only a sub-second feeder swap).
#
# Idempotent: exactly one feeder per screen; a feeder is (re)started only when
# the desired mode (source included) changes or the feeder process has exited.
#
# Runs inside the jrottenberg/ffmpeg image (busybox sh + curl + ffmpeg present).

set -u

HOST="${MEDIAMTX_HOST:-mediamtx}"
PORT="${MEDIAMTX_RTMP_PORT:-1935}"
API_PORT="${MEDIAMTX_API_PORT:-9997}"
USER_="${MTX_ADMIN_USER:-admin}"
PASS_="${MTX_ADMIN_PASSWORD:-admin_password_CHANGE_ME}"
TATAMIS="${TATAMIS:-a b c d e f g h}"
FDIR="${FALLBACK_DIR:-/fallback}"
INT="${INTERVAL_SEC:-2}"
INTENT_DIR="${INTENT_DIR:-/control}"
CTL_PORT="${CTL_PORT:-8090}"
# Route table (written by ctl.py) and resolved assignment (written here).
# Both live on the shared /outputs volume so ctl.py can serve them to the panel.
ROUTES_FILE="${ROUTES_FILE:-$INTENT_DIR/routes.conf}"
RESOLVED_FILE="${RESOLVED_FILE:-$INTENT_DIR/routes.resolved}"
RTMP="rtmp://${HOST}:${PORT}"
# Anonymous API when no admin password is set (local MVP grants 'any' the api
# action); authenticated when MTX_ADMIN_PASSWORD is provided (VPS).
if [ -n "${PASS_}" ] && [ "${PASS_}" != "admin_password_CHANGE_ME" ]; then
  API="http://${USER_}:${PASS_}@${HOST}:${API_PORT}"
else
  API="http://${HOST}:${API_PORT}"
fi

STATE_DIR="$(mktemp -d)"
mkdir -p "$INTENT_DIR"

# Operator control server (panel END/RESUME buttons write intent files here).
python3 /supervisor/ctl.py "$INTENT_DIR" "$CTL_PORT" &
CTL_PID=$!

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Intent for a tatami: 'ended' (graceful stop) or 'hold' (default: keep alive).
intent_of() { if [ -f "$INTENT_DIR/$1" ]; then cat "$INTENT_DIR/$1"; else echo hold; fi; }

# Returns 0 if the given MediaMTX path is online.
is_online() {
  # /v3/paths/get/{name} -> {"name":..,"online":true,..}  (name keeps its slash)
  curl -fsS -m 4 "${API}/v3/paths/get/$1" 2>/dev/null | grep -q '"online":true'
}

mode_file() { printf '%s/%s.mode' "$STATE_DIR" "$1"; }
pid_file()  { printf '%s/%s.pid'  "$STATE_DIR" "$1"; }

# Configured route for a screen: a tatami letter or 'auto' (default).
route_of() {
  r=""
  [ -f "$ROUTES_FILE" ] && r=$(grep "^$1=" "$ROUTES_FILE" 2>/dev/null | tail -n1 | cut -d= -f2)
  [ -n "$r" ] && printf '%s' "$r" || printf 'auto'
}

start_feeder() {
  s="$1"; want="$2"
  case "$want" in
    live:*)
      ffmpeg -hide_banner -loglevel error \
        -i "${RTMP}/tatami/${want#live:}" -c copy -fflags +genpts \
        -f flv "${RTMP}/broadcast/${s}" &
      ;;
    fallback:*)
      ffmpeg -hide_banner -loglevel error \
        -re -stream_loop -1 -i "${FDIR}/${want#fallback:}" -c copy -fflags +genpts \
        -f flv "${RTMP}/broadcast/${s}" &
      ;;
  esac
  echo $! > "$(pid_file "$s")"
}

alive() { [ -f "$(pid_file "$1")" ] && kill -0 "$(cat "$(pid_file "$1")")" 2>/dev/null; }

cleanup() {
  log "supervisor stopping; killing feeders"
  kill "$CTL_PID" 2>/dev/null
  for t in $TATAMIS; do
    [ -f "$(pid_file "$t")" ] && kill "$(cat "$(pid_file "$t")")" 2>/dev/null
  done
  rm -rf "$STATE_DIR"
  exit 0
}
trap cleanup INT TERM

log "supervisor up: screens=[$TATAMIS] api=${API##*@} interval=${INT}s routes=$ROUTES_FILE"

while :; do
  # 1) which inputs are online right now (one API call per input)
  ONLINE=" "
  for x in $TATAMIS; do
    is_online "tatami/$x" && ONLINE="$ONLINE$x "
  done

  # 2) resolve routes: pinned screens claim their source first, then 'auto'
  #    screens take any still-free online input, in screen order.
  CLAIMED=" "
  for s in $TATAMIS; do
    r=$(route_of "$s")
    [ "$r" = auto ] || CLAIMED="$CLAIMED$r "
  done
  : > "${RESOLVED_FILE}.tmp"
  for s in $TATAMIS; do
    r=$(route_of "$s")
    if [ "$r" = auto ]; then
      r=""
      for x in $TATAMIS; do
        case "$CLAIMED" in *" $x "*) continue ;; esac
        case "$ONLINE"  in *" $x "*) r="$x"; CLAIMED="$CLAIMED$x "; break ;; esac
      done
    fi
    echo "$s=$r" >> "${RESOLVED_FILE}.tmp"
  done
  mv "${RESOLVED_FILE}.tmp" "$RESOLVED_FILE" 2>/dev/null

  # 3) one feeder per screen, live from its resolved source or the fallback
  for s in $TATAMIS; do
    if [ "$(intent_of "$s")" = ended ]; then
      # Graceful end: stop feeding broadcast/<s> so the relay closes its
      # platform connection and the platform shows 'broadcast ended'.
      if alive "$s"; then
        kill "$(cat "$(pid_file "$s")")" 2>/dev/null
        echo "" > "$(mode_file "$s")"
        log "screen/$s : operator END -> broadcast/$s taken offline (platform ends)"
      fi
      continue
    fi

    r=$(grep "^$s=" "$RESOLVED_FILE" 2>/dev/null | tail -n1 | cut -d= -f2)
    want=""
    if [ -n "$r" ]; then
      case "$ONLINE" in *" $r "*) want="live:$r" ;; esac
    fi
    if [ -z "$want" ]; then
      fb="fallback_${r:-$s}.mp4"; [ -f "$FDIR/$fb" ] || fb="fallback_$s.mp4"
      want="fallback:$fb"
    fi

    cur=""
    [ -f "$(mode_file "$s")" ] && cur="$(cat "$(mode_file "$s")")"

    if alive "$s" && [ "$cur" = "$want" ]; then
      continue  # feeder healthy and on the right source -> nothing to do
    fi

    if alive "$s"; then
      kill "$(cat "$(pid_file "$s")")" 2>/dev/null
      sleep 0.4  # let the broadcast path free up before republishing
    fi

    start_feeder "$s" "$want"
    echo "$want" > "$(mode_file "$s")"
    log "screen/$s : ${cur:-none} -> ${want} (feeding broadcast/$s, pid=$(cat "$(pid_file "$s")"))"
  done
  sleep "$INT"
done
