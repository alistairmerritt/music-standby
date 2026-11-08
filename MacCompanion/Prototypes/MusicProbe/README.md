# MusicProbe — macOS spike

A minimal prototype that reads playback state out of Music.app and can control it.
Scope is deliberately small: prove which APIs work, so the Mac companion app can be
built on a verified foundation. It is not the app.

Branch `spike/mac-music-integration`. Nothing here is wired to the iOS side or to any
relay.

## Files

| File | State |
| --- | --- |
| `musicprobe.sh` | **Runs.** Executed successfully on macOS 27.0.1 — see FINDINGS.md |
| `artwork.sh` | **Runs.** Extracts the current track's artwork and hashes it |
| `MusicProbe.swift` | **Written, never compiled.** Same technique, ready to lift into a SwiftUI menu-bar app |
| `FINDINGS.md` | What worked, what didn't, and the limitations found |

Swift could not be compiled here: this Mac has no Xcode, and the Command Line Tools are
damaged (`swiftc` fails with `redefinition of module 'SwiftBridging'`). The brief allowed
the osascript fallback, so the shell script is the part that actually ran. The Swift file
is a transcription of the same verified AppleScript, not an untested second approach.

## Running it

```bash
cd MacCompanion/Prototypes/MusicProbe
chmod +x musicprobe.sh

./musicprobe.sh status        # human-readable snapshot
./musicprobe.sh json          # one JSON object
./musicprobe.sh watch 1       # poll every second, print JSON on change
```

All three are read-only and will not start, stop or skip anything.

### Playback control

Guarded on purpose. These change what is playing:

```bash
./musicprobe.sh pause --yes
./musicprobe.sh play --yes
./musicprobe.sh next --yes
./musicprobe.sh previous --yes
```

Without `--yes` (or `MUSICPROBE_ALLOW_CONTROL=1`) they refuse and exit 2. Each returns
the snapshot taken 0.4 s later, so the caller sees real state rather than a guess.

### Output

```json
{"running": true, "state": "paused", "isPlaying": false, "position": 251.032,
 "capturedAt": 1794130103.27,
 "track": {"title": "Losing My Edge", "artist": "LCD Soundsystem",
           "album": "LCD Soundsystem", "albumArtist": null, "duration": 473.114,
           "persistentID": "542CEB17C137B39E", "databaseID": 86657,
           "trackClass": "URL track", "artworkCount": 1}}
```

`state` is one of `playing`, `paused`, `stopped`. When Music.app is not running the object
is `{"running": false, "state": "stopped", "capturedAt": …}` and nothing is launched.

## Artwork

```bash
./artwork.sh info                 # JSON only; the image is hashed and discarded
./artwork.sh extract              # writes <sha256>.png into ./artwork-cache/
./artwork.sh extract /some/dir    # or wherever
```

```json
{"ok": true,
 "artworkID": "70d7210ced944748a7993e51335d627d93bebede61315de62de3314c2413397d",
 "sha256": "70d7210c…", "format": "png", "appleScriptFormat": "«class PNG »",
 "width": 800, "height": 800, "bytes": 376049,
 "track": {"title": "Losing My Edge", "artist": "LCD Soundsystem",
           "album": "LCD Soundsystem", "persistentID": "542CEB17C137B39E"}}
```

Both commands are read-only. `artwork-cache/` and loose image files are gitignored —
extracted album art is copyrighted and must not be committed.

Failure is reported as `{"ok": false, "error": "…"}` with exit 1: no current track, no
artwork, Music.app not running, or Automation permission denied.

### Incorporating it into the Mac app

The shape is content-addressing, and it maps straight onto the relay design (§2, §4):

1. On a track change, read the artwork bytes once.
2. SHA-256 them. That hash **is** the `artworkID` — verified byte-stable across repeated
   extractions of the same track, so the same album always produces the same key.
3. If the relay has already seen that hash, send nothing. Otherwise
   `PUT /v1/artwork/{sha256}` and let the relay serve it to the iOS extension.
4. Put the hash in `TrackMetadata.artworkID`, as the existing protocol already expects.

Two things to decide before building it:

- **Downscale first.** 800 × 800 PNG is 376 KB. Roughly 600 px JPEG would be about a tenth
  of that and is plenty for a Lock Screen. Hash whatever you actually upload, so the key
  and the bytes never disagree.
- **In Swift, skip the file round trip.** `NSAppleEventDescriptor.data` gives the bytes
  directly from the same `raw data of artwork 1` call, so there is no temporary file and no
  shelling out. `MusicProbe.swift` does not implement this yet — it is a small addition to
  the same `NSAppleScript` path, and like the rest of that file it would be unverified
  until someone with a working toolchain builds it.

## Permissions

Sending Apple Events to Music.app needs **Automation** permission, granted per calling
application under System Settings → Privacy & Security → Automation. Running
`musicprobe.sh` from Terminal asks for Terminal, once; it was already granted on the
machine this was written on, so the first-run prompt was not observed.

Refusal shows up as AppleScript error **-1743** (`errAEEventNotPermitted`). The script
treats that like "not running" rather than crashing; a real app should surface it, because
it is a permanent state the user must fix in System Settings.

For the eventual menu-bar app:

- `NSAppleEventsUsageDescription` in `Info.plist`, with a sentence the user will read in
  the prompt.
- If sandboxed, `com.apple.security.automation.apple-events`, plus
  `com.apple.security.temporary-exception.apple-events` listing `com.apple.Music`.
- The prompt appears on the first Apple Event, which means the first refresh. Trigger it
  at a moment the user expects, not silently at login.

## Integrating it

`MusicProbe.swift` is one file with no dependencies — no ScriptingBridge headers, no
generated glue, no package.

```swift
let probe = MusicProbe()
probe.onChange = { snapshot in /* publish to your model */ }
probe.start()
```

`onChange` fires only when something a listener cares about changes — running, state,
track identity — never for ordinary progress. That is `MusicSnapshot.changeKey`, and it is
the same rule the relay design wants for push coalescing.

Three things to know before building on it:

- `NSAppleScript` is not thread-safe. Every execution is funnelled through one serial
  queue, and `onChange` is called on it. Hop to the main actor before touching UI.
- The script is compiled once and reused. Compiling per refresh is noticeably slower.
- `start()` registers for `com.apple.Music.playerInfo` on the distributed notification
  centre and also runs a 2 s timer. The timer is a fallback and keeps `position` honest;
  it is not the primary change signal. **The notification path has not been observed
  firing** — see FINDINGS.md for how to verify it in two minutes.

## Verifying the notification path

Not done here, because it needs a playback change and playback control was out of bounds
without approval.

```bash
./musicprobe.sh watch 1          # in one terminal
```

Then press play in Music.app. A new JSON line should appear within a second. That proves
the polling fallback. To prove the notification itself, build `MusicProbe.swift` into any
app on a machine with a working toolchain, log inside the observer block, and press play.
