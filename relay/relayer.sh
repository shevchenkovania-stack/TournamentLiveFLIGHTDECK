#!/bin/sh
# TournamentLive relay - Layer 2.5.
# Pushes each stable broadcast/<letter> output OUT to the configured platforms
# (VK, YouTube, ...). One destination per line in /outputs/outputs.local.conf
# (falls back to outputs.conf sample) in the form:
#
#     <letter> <full-rtmp-url-with-key>
#     #<letter> <url>      <- commented line = disabled entry
#
# Several lines may share the SAME letter: broadcast/<letter> is then relayed
# to every platform on its own independent ffmpeg (one relay per letter+dest
# pair, not per letter).
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
# Re-evaluated EVERY tick: the web panel may create outputs.local.conf only
# AFTER this container started (e.g. keys were .paused at boot) and we must
# follow the file change without a container restart.
pick_conf() {
  if [ -n "${OUTPUTS_CONF:-}" ]; then
    printf '%s' "$OUTPUTS_CONF"
  elif [ -f "/outputs/outputs.local.conf" ]; then
    printf '%s' "/outputs/outputs.local.conf"
  else
    printf '%s' "/outputs/outputs.conf"
  fi
}

log() { printf '[%s] relay: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

TAB=$(printf '\t')
CR=$(printf '\r')
BOM=$(printf '\xEF\xBB\xBF')   # UTF-8 BOM: Windows editors love to add it
STATE=$(mktemp -d)

# Relay identity is the letter+dest pair, so one letter can have many relays.
# When a key changes, the id changes too: the old relay is torn down by step 1
# and the new one starts in step 2 - no special-casing needed.
entry_id() { # $1=letter $2=dest -> numeric cksum on stdout
  printf '%s %s' "$1" "$2" | cksum | { read -r x _; printf '%s' "$x"; }
}

running_pid() { cat "$STATE/pid.$1" 2>/dev/null; }

start_relay() { # $1=id $2=letter $3=dest
  ffmpeg -hide_banner -loglevel warning \
    -i "rtmp://${HOST}:${PORT}/broadcast/${2}" -c copy -f flv "$3" &
  echo "$!" > "$STATE/pid.$1"
  printf '%s' "$2" > "$STATE/letter.$1"
  printf '%s' "$3" > "$STATE/dest.$1"
  log "relay $2 -> $3 (pid $!)"
}

stop_relay() { # $1=id
  pid="$(running_pid "$1")"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  rm -f "$STATE/pid.$1" "$STATE/letter.$1" "$STATE/dest.$1"
}

# Parse the config into "$STATE/plan" as "<id>\t<letter>\t<dest>" lines.
build_plan() {
  p="$STATE/plan.new"
  : > "$p"
  if [ -f "$CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%"$CR"}"
      line="${line#"$BOM"}"          # strip leading BOM so '#'-comments parse
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
      # Guard against the classic panel mistake: the FULL platform URL pasted
      # into the stream-key field, producing "rtmp://host/app/rtmp://host/app".
      # Such a destination can never connect - refuse to relay it loudly.
      case "$dest" in
        *rtsp://*|*rtmp://*rtmp://*|*rtmp://*rtsps://*|*rtmps://*rtmps://*|*srt://*srt://*)
          log "ERROR: skipping doubled URL (server URL pasted as key?) letter=$letter dest=$dest"
          continue ;;
      esac
      case "$letter" in
        *[!a-zA-Z0-9-]*)
          log "skipping malformed letter (need a..h, got '$letter')"
          continue ;;
      esac
      printf '%s\t%s\t%s\n' "$(entry_id "$letter" "$dest")" "$letter" "$dest" >> "$p"
    done < "$CONF"
  fi
  mv "$p" "$STATE/plan"
}

CONF="$(pick_conf)"
log "watching $CONF (reconcile every ${CHECK_SEC}s)"

while :; do
  c="$(pick_conf)"
  if [ "$c" != "$CONF" ]; then
    log "config file changed: $CONF -> $c (re-reading)"
    CONF="$c"
  fi
  build_plan

  # 1) Drop relays whose letter+dest pair is no longer in the plan.
  for pf in "$STATE"/pid.*; do
    [ -e "$pf" ] || continue
    id=${pf##*pid.}
    if ! grep -q "^${id}$(printf '\t')" "$STATE/plan" 2>/dev/null; then
      log "relay removed (letter=$(cat "$STATE/letter.$id" 2>/dev/null) no longer configured): $(cat "$STATE/dest.$id" 2>/dev/null)"
      stop_relay "$id"
    fi
  done

  # 2) Ensure every planned entry has a live relay.
  if [ -f "$STATE/plan" ]; then
    while IFS="$TAB" read -r id l dest || [ -n "$id" ]; do
      [ -n "$id" ] || continue
      pid="$(running_pid "$id")"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        : # healthy, leave it running
      else
        [ -n "$pid" ] && rm -f "$STATE/pid.$id" "$STATE/letter.$id" "$STATE/dest.$id"
        log "relay $l (re)connecting -> $dest"
        start_relay "$id" "$l" "$dest"
      fi
    done < "$STATE/plan"
  fi

  sleep "$CHECK_SEC"
done
