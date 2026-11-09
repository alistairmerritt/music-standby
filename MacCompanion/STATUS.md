# Mac companion — status

9 November 2026, branch `feature/macos`. macOS 27.0.1, Xcode 27.2 (Swift 6.4.2, macOS 27.2
SDK), Music.app 1.7.

**Executed** means run on this Mac with output recorded. **Not verified** means written and
unit-tested at most.

## Summary

| | State |
| --- | --- |
| Compiled | Yes. `swift build` and `scripts/build.sh` with Xcode 27.2, Swift 6 language mode, no warnings |
| Unit tests | 46 tests in 7 suites pass (`swift test`), five runs in a row without a failure |
| Shared protocol | 49 tests pass under `swift test`; builds for iOS with `xcodebuild` |
| Against real Music.app | Executed through `msbctl`: reads, artwork, all four commands, notifications, quit and relaunch |
| Menu-bar app | Launched and quit cleanly. Its view was rendered offscreen in a live and a mock-playing state. The menu was not opened by hand |
| Xcode app project | Not made. The app is built by `scripts/build.sh` |

## Verified against real Music.app

| Check | Result |
| --- | --- |
| Snapshot fields | Match `musicprobe.sh json` for the same track: state, position, title, artist, album, persistent ID, database ID, class, artwork count |
| Artwork bytes | **Byte-identical** to `artwork.sh`: 404,475-byte PNG, SHA-256 `1f9f9de4…38d3`, same across repeated reads. The descriptor type is `tdta`; `.data` is the raw PNG with no wrapper |
| Artwork processing | 800 px PNG → 600 px JPEG of 86 KB in about 90 ms including extraction |
| Commands | play, pause, next and previous each acknowledged, ack revision equal to the state frame that preceded it. Phone command to ack: 0.55–0.62 s, most of it the verified 0.4 s settle |
| Skip while paused | Stays paused, as the spike found |
| Track identity | `previous` back to a track gives the same `pid:` id |
| Listening session | One id kept through play, pause, next and previous |
| Stale, duplicate, unknown commands | `command_expired` without touching Music; one play for two identical ids, identical acks; `unsupported_command` by id |
| Skip with nothing loaded | `no_current_track`, nothing sent to Music |
| Reconnect | `hello` again, then the same state frame with the same revision |
| `playerInfo` | Received (11 in one 50 s run) and used as a debounced trigger |
| Quit | NSWorkspace terminate → `not_running` sent at once, answered by the process check with no Apple Event |
| Relaunch | NSWorkspace launch → read after a 3 s settle → `stopped` with no track |
| Never launching Music | After the fix below, LaunchServices names another process as the relauncher both times |

## Findings that change the design

1. **NSAppleScript must run on the main thread.** On a GCD queue or `Thread`, a
   one-event script took 8–158 s; on an actor with a serial-queue executor it hung. On
   main it takes 5–30 ms. The spike's background-queue design had this problem; its
   `snapshot()` only worked because `queue.sync` from main ran the script on main.
   The controller is now `@MainActor`, so **each read blocks the main thread**: 30–100 ms
   with a track loaded, 340–620 ms when Music has nothing loaded (Music itself is slow
   then; a bare `osascript` took 484 ms).
2. **One read was eleven Apple Events.** `properties of current track` fetches every track
   field in one; a read is now four events.
3. **The companion relaunched Music.** Quitting Music sends `playerInfo` "Stopped", then
   Music takes about a second to exit, and both launch guards say "running" throughout.
   The debounced read sent an Apple Event into that window and LaunchServices relaunched
   Music, naming `msbctl` as the parent. Fixed with a 2 s hold after any "Stopped" and a
   3 s hold after a launch. Re-tested twice: the companion sent nothing during the window.
4. **The relauncher on this Mac is `~/Scripts/lastfm_scrobbler.py`**, not
   `music_to_ha.py` as the spike assumed. It spawns `osascript` about every 1.4 s and
   relaunched Music within 0.5–2 s of each quit. Left alone; it is not part of this project.
5. **NSWorkspace reports a launch before Music answers.** The first read after a relaunch
   timed out at 3 s even though `isFinishedLaunching` was true. Hence the 3 s settle.
6. **Out-of-order reads.** A notification read taken before a pause landed after the
   pause's own re-read and briefly re-published "playing". Older reads are now dropped.
7. **Wire dates.** A microsecond `capturedAt` didn't survive the millisecond wire format,
   so a re-sent message differed from the original. Fixed in the protocol
   (`StandByWire.wirePrecision`, integer-millisecond formatting).
8. **`play` on a paused track at 0:00 can start a different track.** Music's queue moved on
   to the next item. Music behaviour, not the companion's.

## Not verified

- **The first-run Automation prompt.** Every check ran with this shell's existing
  permission. The `automation_denied` path is unit-tested only.
- **The menu opened by hand.** Rendered offscreen only; clicking its buttons was not
  tried. The same `Companion.perform` path was exercised through `msbctl`.
- **Launch at Login.** The toggle is wired to `SMAppService.mainApp` but was not switched:
  that changes the login items, and the dev build isn't in `/Applications`.
- **Whether compiling** a `tell application "Music"` script can launch a closed Music.
  Scripts are compiled once, only after the process check finds Music running.
- **Main-thread cost in daily use.** Measured per read, not over hours.
- **Local files, radio, podcasts, AirPlay, tracks with several artworks.**
- **Anything over a network.** The relay and the WebSocket transport don't exist.

## For the relay design

- `not_running` arrives within a few milliseconds of Music quitting, so the relay can
  end the Now Playing session at once instead of waiting for its 60 s grace.
- `goodbye` tells a deliberate companion quit from a dropped socket.
- A phone command normally gets its ack in about 0.6 s, inside the proposed 1.2 s.
  During a quit or launch window it waits up to 2–3 s and will miss that deadline. That's
  acceptable: Music isn't usable then.
- Artwork ids are known before the state frame leaves, so `artwork-request` works as
  proposed.

## Recommended next step

Send raw Apple Events with `NSAppleEventDescriptor.sendEvent(options:timeout:)` addressed
to **Music's process id**. An event addressed by PID fails rather than relaunching a
quitting app, which would remove the quit-window heuristic. It may also be usable off the
main thread, which would remove the UI cost; that needs testing. The spike ruled this out
as "most code"; the findings above are the reason to reconsider.
