#!/bin/bash
# artwork.sh — extract the current track's album artwork from Music.app.
#
# Read-only. Never changes playback and never launches Music.app.
#
#   ./artwork.sh info              JSON only; the image is hashed and discarded
#   ./artwork.sh extract [dir]     writes <sha256>.<ext> into dir, prints JSON
#                                  (dir defaults to ./artwork-cache, gitignored)
#
# The SHA-256 is of the bytes Music.app hands over, so it is the natural cache
# key and the natural artworkID for the relay. Verified byte-stable across
# repeated calls for the same track — see FINDINGS.md.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)

music_running() {
  [ "$(osascript -e 'tell application "System Events" to return (exists process "Music")' 2>/dev/null)" = "true" ]
}

fail_json() {
  /usr/bin/python3 -I -c 'import json,sys; print(json.dumps({"ok": False, "error": sys.argv[1]}))' "$1"
  exit 1
}

# Writes the raw artwork bytes to $1. Prints the AppleScript format class, or
# nothing on failure.
dump_artwork() {
  osascript 2>/dev/null <<APPLESCRIPT
tell application "Music"
	set t to current track
	if (count of artworks of t) is 0 then error "no artwork"
	set a to artwork 1 of t
	set fmt to "unknown"
	try
		set fmt to (format of a) as text
	end try
	set d to raw data of a
end tell
set fh to open for access (POSIX file "$1") with write permission
set eof fh to 0
write d to fh
close access fh
return fmt
APPLESCRIPT
}

# Track identity, so the JSON says which track the artwork belongs to.
track_identity() {
  osascript 2>/dev/null <<'APPLESCRIPT'
set US to (ASCII character 31)
tell application "Music"
	set t to current track
	set pid to ""
	try
		set pid to (persistent ID of t)
	end try
	-- Each property is pulled into a local first. A list of live references
	-- cannot be coerced to text inside a tell block (error -1700).
	set nm to (name of t) as text
	set ar to (artist of t) as text
	set al to (album of t) as text
	set AppleScript's text item delimiters to US
	set out to {nm, ar, al, pid} as text
	set AppleScript's text item delimiters to ""
	return out
end tell
APPLESCRIPT
}

extract() {
  mode=$1
  outdir=$2

  music_running || fail_json "Music.app is not running"

  tmp=$(mktemp -t musicprobe-artwork)
  fmt=$(dump_artwork "$tmp")

  if [ -z "$fmt" ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    fail_json "no artwork data (no current track, no artwork, or Automation permission denied)"
  fi

  sha=$(shasum -a 256 "$tmp" | awk '{print $1}')
  bytes=$(wc -c < "$tmp" | tr -d ' ')
  sipsout=$(sips -g pixelWidth -g pixelHeight -g format "$tmp" 2>/dev/null)
  width=$(printf '%s' "$sipsout" | awk '/pixelWidth/ {print $2}')
  height=$(printf '%s' "$sipsout" | awk '/pixelHeight/ {print $2}')
  format=$(printf '%s' "$sipsout" | awk '/format:/ {print $2}')
  [ -z "$format" ] && format="unknown"

  ext=$format
  [ "$format" = "jpeg" ] && ext="jpg"

  path=""
  if [ "$mode" = "extract" ]; then
    mkdir -p "$outdir" || fail_json "cannot create $outdir"
    path="$outdir/$sha.$ext"
    # Content-addressed: if it is already there, the bytes are already right.
    [ -f "$path" ] || mv "$tmp" "$path"
    rm -f "$tmp"
  else
    rm -f "$tmp"
  fi

  track_identity | /usr/bin/python3 -I -c '
import json, sys
f = (sys.stdin.readline().rstrip("\n").split("\x1f") + [""] * 4)[:4]
sha, fmt, cls, w, h, size, path = sys.argv[1:8]
out = {
    "ok": True,
    "artworkID": sha,
    "sha256": sha,
    "format": fmt,
    "appleScriptFormat": cls,
    "width": int(w) if w.isdigit() else None,
    "height": int(h) if h.isdigit() else None,
    "bytes": int(size) if size.isdigit() else None,
    "track": {"title": f[0], "artist": f[1], "album": f[2],
              "persistentID": f[3] or None},
}
if path:
    out["path"] = path
print(json.dumps(out, ensure_ascii=False))
' "$sha" "$format" "$fmt" "$width" "$height" "$bytes" "$path"
}

cmd=${1:-info}
case "$cmd" in
  info)    extract info "" ;;
  extract) extract extract "${2:-$here/artwork-cache}" ;;
  *)       sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
