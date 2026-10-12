#!/bin/sh
# TournamentLive stream supervisor — Linux/container port of supervisor.ps1.
#
# Keeps one OUTPUT path broadcast/<x> alive per tatami:
#   - tatami/<x> online  -> feed broadcast/<x> from the live RTMP (copy, no re-encode)
#   - tatami/<x> offline -> feed broadcast/<x> by looping /fallback/fallback_<x>.mp4
# Platforms (VK/YouTube) and the cockpit read broadcast/<x>, so the outbound
# publication survives an input drop (only a sub-second feeder swap).
#
# Idempotent: exactly one feeder per tatami; a feeder is (re)started only when
# the desired mode changes or the previous feeder process has exited.
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

start_feeder() {
  t="$1"; mode="$2"
  if [ "$mode" = "live" ]; then
    ffmpeg -hide_banner -loglevel error \
      -i "${RTMP}/tatami/${t}" -c copy -fflags +genpts \
      -f flv "${RTMP}/broadcast/${t}" &
  else
    ffmpeg -hide_banner -loglevel error \
      -re -stream_loop -1 -i "${FDIR}/fallback_${t}.mp4" -c copy -fflags +genpts \
      -f flv "${RTMP}/broadcast/${t}" &
  fi
  echo $! > "$(pid_file "$t")"
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

log "supervisor up: tatamis=[$TATAMIS] api=${API##*@} interval=${INT}s"

while :; do
  for t in $TATAMIS; do
    if [ "$(intent_of "$t")" = "ended" ]; then
      # Graceful end: stop feeding broadcast/<t> so the relay closes its
      # platform connection and the platform shows 'broadcast ended'.
      # Stay down until the operator resumes - do NOT auto-recover.
      if alive "$t"; then
        kill "$(cat "$(pid_file "$t")")" 2>/dev/null
        echo "" > "$(mode_file "$t")"
        log "tatami/$t : operator END -> broadcast/$t taken offline (platform ends)"
      fi
      continue
    fi

    if is_online "tatami/$t"; then want=live; else want=fallback; fi

    cur=""
    [ -f "$(mode_file "$t")" ] && cur="$(cat "$(mode_file "$t")")"

    if alive "$t" && [ "$cur" = "$want" ]; then
      continue  # feeder healthy and in the right mode -> nothing to do
    fi

    if alive "$t"; then
      kill "$(cat "$(pid_file "$t")")" 2>/dev/null
      sleep 0.4  # let the broadcast path free up before republishing
    fi

    start_feeder "$t" "$want"
    echo "$want" > "$(mode_file "$t")"
    log "tatami/$t : ${cur:-none} -> ${want} (feeding broadcast/$t, pid=$(cat "$(pid_file "$t")"))"
  done
  sleep "$INT"
done
