#!/bin/bash
# lifecycletest.sh — QUITS AND RELAUNCHES MUSIC.APP. Records track identity and
# artwork before and after a restart, probes while Music is not running, and
# logs playerInfo notifications throughout. Needs --yes.
#
#   ./lifecycletest.sh --yes

[ "${1:-}" = "--yes" ] || { echo "lifecycletest quits Music.app; pass --yes" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
notes=$(mktemp -t musicprobe-lifecycle)

running() { pgrep -x Music >/dev/null && echo yes || echo no; }

snap() {
  "$here/musicprobe.sh" json | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin); t = d.get("track") or {}
print("running=%s state=%s pos=%s title=%s pid=%s db=%s class=%s" % (
    d.get("running"), d.get("state"), d.get("position"), t.get("title"),
    t.get("persistentID"), t.get("databaseID"), t.get("trackClass")))'
}

art() { "$here/artwork.sh" info | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin); print("artwork ok=%s sha=%s" % (d.get("ok"), (d.get("sha256") or d.get("error"))))'; }

timed() {
  s=$(/usr/bin/python3 -I -c 'import time; print(time.time())')
  out=$("$@" 2>&1); rc=$?
  e=$(/usr/bin/python3 -I -c 'import time; print(time.time())')
  ms=$(/usr/bin/python3 -I -c "print(int(($e - $s) * 1000))")
  echo "  [$* -> exit $rc, ${ms} ms] $out" | head -c 400; echo
}

osascript "$here/notifywatch.applescript" 75 2>> "$notes" &
watcher=$!
sleep 2

echo "=== 1. before"; snap; art
echo "=== 2. playing"; osascript -e 'tell application "Music" to play'; sleep 2; snap
echo "=== 3. paused"; osascript -e 'tell application "Music" to pause'; sleep 1; snap

echo "=== 4. quit"
echo "$(date +%T) CMD quit" >> "$notes"
osascript -e 'tell application "Music" to quit'
for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(running)" = no ] && break; sleep 1; done
echo "  Music running: $(running)"

echo "=== 5. probes while not running"
timed "$here/musicprobe.sh" json
timed "$here/musicprobe.sh" status
timed "$here/artwork.sh" info
timed "$here/musicprobe.sh" play --yes
echo "  Music running after probes (must be no): $(running)"

echo "=== 6. relaunch"
echo "$(date +%T) CMD relaunch" >> "$notes"
open -g -a Music
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ "$(running)" = yes ] && break; sleep 1; done
echo "  process up: $(running)"
echo "  immediately:"; snap
sleep 4
echo "  after 4 s:"; snap; art

echo "=== 7. resume"
echo "$(date +%T) CMD play" >> "$notes"
osascript -e 'tell application "Music" to play'; sleep 3; snap
osascript -e 'tell application "Music" to pause'; sleep 1; snap

kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
echo; echo "=== notifications"
grep -E 'CMD|OBSERVER|Player State|Name =' "$notes"
