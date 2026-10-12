#!/bin/sh
# TournamentLive relay - Layer 2.5.
# Pushes each stable broadcast/<letter> output OUT to the configured platforms
# (VK, YouTube, ...). One destination per line in /outputs/outputs.local.conf
# (falls back to outputs.conf sample) in the form:
#
#     <letter> <full-rtmp-url-with-key>
#     #<letter> <url>      <- commented line = disabled entry
#
# HOT RELOAD: the config is re-read every RELAY_CHECK_SEC (default 3s). New or
# changed lines (e.g. a fresh VK key pasted in the web panel) are applied without
# restarting this container; healthy relays are left untouched. If a platform or
# the source drops, ffmpeg exits and is respawned on the next tick.

set -u

HOST="${MEDIAMTX_HOST:-mediamtx}"
PORT="${MEDIAMTX_RTMP_PORT:-1935}"
CHECK_SEC="${RELAY_CHECK_SEC:-3}"

# Prefer the gitignored secret file (real platform keys) when present; else the
# tracked sample. Set OUTPUTS_CONF to override explicitly.
if [ -z "${OUTPUTS_CONF:-}" ]; then
  if [ -f "/outputs/outputs.local.conf" ]; then
    CONF="/outputs/outputs.local.conf"
  else
    CONF="/outputs/outputs.conf"
  fi
else
  CONF="$OUTPUTS_CONF"
fi

log() { printf '[%s] relay: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

TAB=$(printf '\t')
CR=$(printf '\r')
STATE=$(mktemp -d)

running_pid()  { cat "$STATE/pid.$1"  2>/dev/null; }
running_dest() { cat "$STATE/dest.$1" 2>/dev/null; }

start_relay() { # $1=letter $2=dest
  ffmpeg -hide_banner -loglevel warning \
    -i "rtmp://${HOST}:${PORT}/broadcast/${1}" -c copy -f flv "$2" &
  echo "$!" > "$STATE/pid.$1"
  printf '%s' "$2" > "$STATE/dest.$1"
  log "relay $1 -> $2 (pid $!)"
}

stop_relay() { # $1=letter
  pid="$(running_pid "$1")"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  rm -f "$STATE/pid.$1" "$STATE/dest.$1"
}

# Parse the config into "$STATE/plan" as "<letter>\t<dest>" lines.
build_plan() {
  p="$STATE/plan.new"
  : > "$p"
  if [ -f "$CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%"$CR"}"
      case "$line" in ''|\#*) continue ;; esac
      letter="${line%% *}"
      dest="${line#* }"
      dest="${dest%"$CR"}"
      dest=$(printf '%s' "$dest" | sed 's/^[[:space:]]*//')
      [ -z "$letter" ] && continue
      if [ "$dest" = "$line" ] || [ -z "$dest" ]; then
        log "skipping malformed line (need '<letter> <rtmp-url>'): $line"
        continue
      fi
      printf '%s\t%s\n' "$letter" "$dest" >> "$p"
    done < "$CONF"
  fi
  mv "$p" "$STATE/plan"
}

log "watching $CONF (reconcile every ${CHECK_SEC}s)"

while :; do
  build_plan

  # 1) Drop relays whose letter is no longer in the plan.
  for pf in "$STATE"/pid.*; do
    [ -e "$pf" ] || continue
    l=$(basename "$pf"); l=${l#pid.}
    if ! grep -q "^${l}[[:space:]]" "$STATE/plan" 2>/dev/null; then
      log "relay $l removed (no longer configured)"
      stop_relay "$l"
    fi
  done

  # 2) Ensure every planned letter has a live relay with the correct dest.
  if [ -f "$STATE/plan" ]; then
    while IFS="$TAB" read -r l dest || [ -n "$l" ]; do
      [ -n "$l" ] || continue
      pid=$(running_pid "$l")
      cur=$(running_dest "$l")
      alive=0
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
      if [ "$alive" = 1 ] && [ "$cur" = "$dest" ]; then
        : # healthy, leave it running
      else
        if [ "$alive" = 1 ]; then
          log "relay $l restart (dest changed)"
          stop_relay "$l"
        else
          [ -n "$pid" ] && rm -f "$STATE/pid.$l" "$STATE/dest.$l"
          log "relay $l (re)connecting"
        fi
        start_relay "$l" "$dest"
      fi
    done < "$STATE/plan"
  fi

  sleep "$CHECK_SEC"
done
