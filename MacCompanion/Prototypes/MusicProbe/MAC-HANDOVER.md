# Mac handover — MusicProbe spike

For the developer building the SwiftUI menu-bar app. The evidence for each point is in
[`FINDINGS.md`](FINDINGS.md). Everything here was **executed on macOS 27.0.1** unless
marked otherwise.

## Verified Music.app APIs

All of these go through AppleScript (`osascript` here, `NSAppleScript` in the app). No
private APIs and no ScriptingBridge.

| Need | API | Status |
| --- | --- | --- |
| State | `player state` → playing / paused / stopped | Verified |
| Position | `player position`, fractional seconds | Verified |
| Metadata | `name`, `artist`, `album`, `duration` of `current track` | Verified, including streamed `URL track` |
| Identity | `persistent ID`, `database ID`, `class` | Verified within one Music run |
| Artwork | `raw data of artwork 1 of current track` | Verified. Real PNG bytes, byte-stable SHA-256 |
| Control | `play`, `pause`, `playpause`, `next track`, `previous track` | Verified, each re-read afterwards |
| Change signal | `com.apple.Music.playerInfo` distributed notification | Observed via AppleScriptObjC |

## Checking whether Music is running — never launch it

Any `tell application "Music"` **launches Music** if it is closed. A poller that does this
will keep reopening Music after the user quits it. That is the likely reason Music
reopened itself during testing on this Mac (the separate `music_to_ha.py` bridge).

Use two guards. `musicprobe.sh` and `artwork.sh` now do both:

1. **A process check before any Apple Event.** In Swift, check
   `NSWorkspace.shared.runningApplications` for `com.apple.Music`; in shell, `pgrep -x
   Music`. These send no events and return in milliseconds.
2. **An in-script guard**, for the case where Music quits between the check and the
   event: start the script with
   `if not (application id "com.apple.Music" is running) then return "NOT_RUNNING"`.
   `is running` does not launch the app (verified against Chess, which stayed closed).

Playback commands follow the same rule: if Music is not running, return an error. Do not
launch it.

## States to report

`not_running` · `stopped` (running, no track) · `paused` · `playing` ·
`automation_denied` (AppleScript error −1743) · `error`.

**Never fold an AppleScript failure into `not_running`.** The probe used to, and a
permission problem looked exactly like Music being closed.

## Notifications and polling together

- Observe `com.apple.Music.playerInfo`. Treat it as a **trigger only** and re-read state
  through AppleScript. The payload has no persistent ID and no position, it often arrives
  twice for one change, and its `Total Time` value varies between reports for the same
  track.
- Keep a **2 s poll** as a fallback, and to keep `position` accurate.
- Emit only when the change key changes (running, state, persistent ID, title, artist,
  album). Leave position out of the key, or every tick counts as a change.
- `playerInfo` **says nothing when Music launches**. When Music quits it sends only
  `Player State = Stopped`, which looks the same as playback stopping. For app lifecycle,
  observe `NSWorkspace.didLaunchApplicationNotification` and
  `didTerminateApplicationNotification`, filtered to `com.apple.Music`.

## Artwork

Use `raw data of artwork 1` and take the SHA-256 of the bytes. That hash is the
`artworkID` and the relay's cache key. Upload with `PUT /v1/artwork/{sha256}` only when the
relay doesn't already have it. Downscale the 800 × 800 PNG (376 KB) to about 600 px JPEG
first, and **hash the bytes you actually upload**. In Swift, read
`NSAppleEventDescriptor.data` directly; `artwork.sh` goes through a temporary file only
because it is a shell script.

## Quit, relaunch and missing tracks

- **A Music restart loses a streamed track completely.** It comes back `stopped` with no
  current track. The track can't be found again because it isn't in the library, and
  `set player position` fails. Don't try to restore it: report `stopped` and let the relay
  end the session.
- AppleScript answers immediately after a relaunch. There is no warm-up period to wait out.
- `persistent ID` is a reliable song ID **within one Music run**. Across restarts, fall back
  to `title|artist|album|duration`. Whether a streamed track keeps its persistent ID after
  a restart can't be tested, because it can't be reached again.
- Keep a separate **session id**. Create it when playback starts and keep it across track
  changes; don't derive it from the song.

## Music restart vs network disconnect

They look nothing alike from the Mac, so the app should tell the relay which one happened
rather than leave it to guess:

| | Music restart | Network drop (Mac ↔ relay) |
| --- | --- | --- |
| Local signal | NSWorkspace terminate, then launch | WebSocket closes, Music still running |
| Music state afterwards | `stopped`, no track | Unchanged |
| What to send | `not_running` (or `stopped`) **at once**, over the socket | Nothing — reconnect, then resend current state |
| Relay action | Send `end` now | Wait out the 60 s grace (relay design §7) |

**Not tested:** Music losing its own connection while streaming (a catalogue track that
can't buffer). Music stays running in that case. It probably shows up as a pause or a
stop, and it should be treated as an ordinary state change.

## Incorporating into the menu-bar app

`MusicProbe.swift` already has the right shape: a serial queue for `NSAppleScript`, a
compiled script reused across reads, a `playerInfo` observer, a 2 s timer and
`changeKey`. Before it ships, port in what the shell probes learned after it was written:

1. The in-script `NOT_RUNNING` guard. It currently checks the process only.
2. The `not_running` / `automation_denied` / `error` states. It currently logs and returns
   "not running".
3. NSWorkspace launch and terminate observers.
4. Artwork bytes through `NSAppleEventDescriptor.data`, then a downscale, then a hash.
5. A visible "Music access denied" state that sends the user to System Settings → Privacy
   & Security → Automation.

## Outstanding — needs Xcode

- **`MusicProbe.swift` has never been compiled.** The Command Line Tools on this Mac are
  damaged (`redefinition of module 'SwiftBridging'`) and Xcode is not installed.
- The app's `Info.plist` needs `NSAppleEventsUsageDescription`. If sandboxed, it needs
  `com.apple.security.automation.apple-events` plus a
  `temporary-exception.apple-events` entitlement for `com.apple.Music`.
- The first-run Automation prompt has never been seen, because Terminal already had
  permission. Check it on a clean account.
- The `automation_denied` path is written but has not been run.
- The real Music-closed path has been tested only with a simulated closed state
  (`MUSICPROBE_FORCE_NOT_RUNNING=1`), because Music reopens itself on this Mac.
