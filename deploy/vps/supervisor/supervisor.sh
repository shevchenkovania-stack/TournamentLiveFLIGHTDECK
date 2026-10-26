#!/bin/sh
# TournamentLive stream supervisor — Linux/container port of supervisor.ps1.
#
# NUMBERED-KEY model (zero screen/tatami ambiguity):
#   Screen N (internally the letter a..h = screens 1..8) shows EXACTLY what
#   arrives on key N: rtmp://<host>:1935/tatami/ + key N. Nothing to route,
#   nothing to claim - the operator reads key N off the card of screen N.
#     key N online   -> feed broadcast/<letter> from tatami/<N>
#     key N offline  -> loop that screen's fallback clip
#   The "tatami / tournament" name is a free-text label in the panel only;
#   the infrastructure never depends on it (ten mats may all be called "A").
# Platforms (VK/YouTube) read broadcast/<x>, so the outbound publication
# survives an input drop (only a sub-second feeder swap).
#
# Idempotent: exactly one feeder per screen; a feeder is (re)started only when
# the desired mode changes or the feeder process has exited.
#
# Runs inside the supervisor image (busybox sh + curl + ffmpeg + python3).

set -u

HOST="${MEDIAMTX_HOST:-mediamtx}"
PORT="${MEDIAMTX_RTMP_PORT:-1935}"
API_PORT="${MEDIAMTX_API_PORT:-9997}"
USER_="${MTX_ADMIN_USER:-admin}"
PASS_="${MTX_ADMIN_PASSWORD:-admin_password_CHANGE_ME}"
# Screen letters: a..h == screens 1..8 (broadcast/<letter>, fallback_<letter>.mp4).
TATAMIS="${TATAMIS:-a b c d e f g h}"
FDIR="${FALLBACK_DIR:-/fallback}"
INT="${INTERVAL_SEC:-2}"
INTENT_DIR="${INTENT_DIR:-/control}"
# Active screen count: screens.conf NEXT TO the outputs file (panel writes it
# via ctl.py POST /screens). The rig starts small (default 2) and grows by the
# panel '+' button; screens beyond the count stay fully dormant.
SCR_FILE="$(dirname "${OUTPUTS_PATH:-/outputs/x.conf}")/screens.conf"
DEFAULT_COUNT=2
CTL_PORT="${CTL_PORT:-8090}"
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

# Operator control server (panel END/RESUME buttons + labels write files here).
python3 /supervisor/ctl.py "$INTENT_DIR" "$CTL_PORT" &
CTL_PID=$!

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Intent for a screen: 'ended' (graceful stop) or 'hold' (default: keep alive).
intent_of() { if [ -f "$INTENT_DIR/$1" ]; then cat "$INTENT_DIR/$1"; else echo hold; fi; }

# Screen letter -> its number (a=1 .. h=8). The ingest key operators use.
no_of() { printf '%s' "$1" | tr 'abcdefgh' '12345678'; }

# Active screen count 1..8; garbage/missing file -> sane default.
screen_count() {
  max=$(printf '%s\n' $TATAMIS | wc -l)
  c="$DEFAULT_COUNT"
  if [ -f "$SCR_FILE" ]; then
    v=$(grep -m1 -oE '[0-9]+' "$SCR_FILE" 2>/dev/null)
    [ -n "$v" ] && c="$v"
  fi
  [ "$c" -ge 1 ] || c=1
  [ "$c" -le "$max" ] || c="$max"
  printf '%s' "$c"
}

# Returns 0 if the given MediaMTX path is online.
is_online() {
  # /v3/paths/get/{name} -> {"name":..,"online":true,..}  (name keeps its slash)
  curl -fsS -m 4 "${API}/v3/paths/get/$1" 2>/dev/null | grep -q '"online":true'
}

mode_file() { printf '%s/%s.mode' "$STATE_DIR" "$1"; }
pid_file()  { printf '%s/%s.pid'  "$STATE_DIR" "$1"; }

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

log "supervisor up: screens=[$TATAMIS] keys=1..8 active=$(screen_count) api=${API##*@} interval=${INT}s"

while :; do
  CNT=$(screen_count)
  i=0
  for s in $TATAMIS; do
    i=$((i+1))
    n=$(no_of "$s")

    # Screen past the active count (operator removed it with '-'): make sure
    # its feeder is stopped, then skip. Re-adding it resumes automatically.
    if [ "$i" -gt "$CNT" ]; then
      if alive "$s"; then
        kill "$(cat "$(pid_file "$s")")" 2>/dev/null
        echo "" > "$(mode_file "$s")"
        log "screen/$s (key $n): deactivated (count=$CNT)"
      fi
      continue
    fi

    if [ "$(intent_of "$s")" = ended ]; then
      # Graceful end: stop feeding broadcast/<s> so the relay closes its
      # platform connection and the platform shows 'broadcast ended'.
      if alive "$s"; then
        kill "$(cat "$(pid_file "$s")")" 2>/dev/null
        echo "" > "$(mode_file "$s")"
        log "screen/$s (key $n): operator END -> broadcast/$s taken offline (platform ends)"
      fi
      continue
    fi

    if is_online "tatami/$n"; then
      want="live:$n"
    else
      fb="fallback_$s.mp4"
      [ -f "$FDIR/$fb" ] || fb="fallback_a.mp4"
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
    log "screen/$s (key $n): ${cur:-none} -> ${want} (feeding broadcast/$s, pid=$(cat "$(pid_file "$s")"))"
  done
  sleep "$INT"
done
