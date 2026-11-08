#!/bin/bash
# musicprobe.sh — minimal Music.app probe for Music StandBy.
#
# Read-only by default. Playback-changing subcommands refuse to run unless you
# pass --yes or set MUSICPROBE_ALLOW_CONTROL=1.
#
#   ./musicprobe.sh status            human-readable snapshot
#   ./musicprobe.sh json              one JSON object on stdout
#   ./musicprobe.sh watch [seconds]   poll and print JSON on every change
#   ./musicprobe.sh play --yes        playback control (guarded)
#   ./musicprobe.sh pause --yes
#   ./musicprobe.sh next --yes
#   ./musicprobe.sh previous --yes
#
# See README.md for permissions and FINDINGS.md for what is and isn't reliable.

set -uo pipefail

US=$'\x1f'   # field separator; cannot occur in track metadata

# Is Music.app running? Asked through System Events so we never launch it.
music_running() {
  [ "$(osascript -e 'tell application "System Events" to return (exists process "Music")' 2>/dev/null)" = "true" ]
}

# Emit the player snapshot as US-separated fields. Never launches Music.
# Order: state position name artist album albumArtist duration persistentID databaseID trackClass artworkCount
read_snapshot() {
  osascript 2>/dev/null <<'APPLESCRIPT'
set US to (ASCII character 31)
tell application "Music"
	set playerState to (player state as text)
	set pos to "0"
	try
		set pos to (player position as text)
	end try
	set f to {playerState, pos, "", "", "", "", "0", "", "0", "", "0"}
	try
		set t to current track
		set item 3 of f to (name of t)
		set item 4 of f to (artist of t)
		set item 5 of f to (album of t)
		try
			set item 6 of f to (album artist of t)
		end try
		set item 7 of f to (duration of t as text)
		try
			set item 8 of f to (persistent ID of t)
		end try
		try
			set item 9 of f to (database ID of t as text)
		end try
		set item 10 of f to (class of t as text)
		try
			set item 11 of f to (count of artworks of t as text)
		end try
	end try
	set AppleScript's text item delimiters to US
	set out to f as text
	set AppleScript's text item delimiters to ""
	return out
end tell
APPLESCRIPT
}

# US-separated fields on stdin -> one JSON object. Uses only the Python stdlib.
to_json() {
  /usr/bin/python3 -I -c '
import json, sys, time
raw = sys.stdin.readline().rstrip("\n")
if not raw:
    print(json.dumps({"running": False, "state": "stopped", "capturedAt": time.time()}))
    sys.exit(0)
f = raw.split("\x1f")
f += [""] * (11 - len(f))
def num(x):
    try:
        return round(float(x), 3)
    except ValueError:
        return 0.0
state = {"playing": "playing", "paused": "paused"}.get(f[0], "stopped")
track = None
if f[2]:
    track = {
        "title": f[2], "artist": f[3], "album": f[4],
        "albumArtist": f[5] or None,
        "duration": num(f[6]),
        "persistentID": f[7] or None,
        "databaseID": int(f[8]) if f[8].isdigit() else None,
        "trackClass": f[9] or None,
        "artworkCount": int(f[10]) if f[10].isdigit() else 0,
    }
print(json.dumps({
    "running": True,
    "state": state,
    "isPlaying": state == "playing",
    "position": num(f[1]),
    "capturedAt": time.time(),
    "track": track,
}, ensure_ascii=False))
'
}

snapshot_json() {
  if ! music_running; then
    printf '' | to_json
    return
  fi
  read_snapshot | to_json
}

# Change identity: everything a listener would care about, excluding position.
change_key() {
  /usr/bin/python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
t = d.get("track") or {}
print("|".join(str(x) for x in [
    d.get("running"), d.get("state"),
    t.get("persistentID"), t.get("title"), t.get("artist"), t.get("album"),
]))
'
}

control() {
  local verb=$1 approved=$2
  if [ "$approved" != "yes" ]; then
    echo "refusing to $verb: pass --yes or set MUSICPROBE_ALLOW_CONTROL=1" >&2
    return 2
  fi
  if ! music_running; then
    echo "Music.app is not running" >&2
    return 1
  fi
  osascript -e "tell application \"Music\" to $verb" >/dev/null 2>&1
  sleep 0.4
  snapshot_json
}

cmd=${1:-status}
shift || true
approved=no
[ "${MUSICPROBE_ALLOW_CONTROL:-0}" = "1" ] && approved=yes
for a in "$@"; do [ "$a" = "--yes" ] && approved=yes; done

case "$cmd" in
  json)
    snapshot_json
    ;;

  status)
    if ! music_running; then
      echo "Music.app: not running"
      exit 0
    fi
    snapshot_json | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin)
t = d.get("track")
print("Music.app: running")
print("State:     %s" % d["state"])
if not t:
    print("Track:     (none)")
    raise SystemExit(0)
print("Track:     %s" % t["title"])
print("Artist:    %s" % t["artist"])
print("Album:     %s" % t["album"])
print("Duration:  %.1fs" % t["duration"])
print("Position:  %.1fs" % d["position"])
print("Class:     %s" % t["trackClass"])
print("Artworks:  %d" % t["artworkCount"])
print("ID:        %s (db %s)" % (t["persistentID"], t["databaseID"]))
'
    ;;

  watch)
    interval=${1:-1}
    case "$interval" in ''|*[!0-9.]*) interval=1 ;; esac
    echo "watching every ${interval}s, ctrl-c to stop" >&2
    last=""
    while true; do
      snap=$(snapshot_json)
      key=$(printf '%s' "$snap" | change_key)
      if [ "$key" != "$last" ]; then
        printf '%s\n' "$snap"
        last=$key
      fi
      sleep "$interval"
    done
    ;;

  play)      control "play" "$approved" ;;
  pause)     control "pause" "$approved" ;;
  playpause) control "playpause" "$approved" ;;
  next)      control "next track" "$approved" ;;
  previous)  control "previous track" "$approved" ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
