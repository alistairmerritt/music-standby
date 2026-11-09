#!/bin/bash
# selftest.sh — CHANGES PLAYBACK. Exercises play, pause, next, previous and
# playpause, re-reads Music.app after each one, and records playerInfo
# notifications alongside. Needs --yes.
#
#   ./selftest.sh --yes [logdir]

[ "${1:-}" = "--yes" ] || { echo "selftest changes playback; pass --yes" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
logdir=${2:-$(mktemp -d -t musicprobe-selftest)}
notes="$logdir/notifications.log"

snap() {
  "$here/musicprobe.sh" json | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin); t = d.get("track") or {}
print("%-8s pos=%-8s %-28s pid=%s db=%s class=%s" % (
    d["state"], d.get("position"), (t.get("title") or "-")[:28],
    t.get("persistentID"), t.get("databaseID"), t.get("trackClass")))'
}

osascript "$here/notifywatch.applescript" 45 2>> "$notes" &
watcher=$!
sleep 2

step() {
  echo "--- $1"
  echo "$(date +%T) CMD $1" >> "$notes"
  osascript -e "tell application \"Music\" to $1" 2>&1
  sleep "$2"
  snap
}

echo "--- before"; snap
step "play" 3
step "pause" 2
step "next track" 3
step "next track" 3
step "previous track" 3
step "previous track" 3
step "playpause" 2
step "playpause" 2

wait "$watcher"
echo
echo "=== notifications ($notes) ==="
cat "$notes"
