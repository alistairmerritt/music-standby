# Mac companion — status

9 November 2026, branch `feature/macos`. macOS 27.0.1, Xcode 27.2 (Swift 6.4.2, macOS 27.2
SDK), Music.app 1.7.

**Executed** means run on this Mac with output recorded. **Not verified** means written and
unit-tested at most.

## Summary

| | State |
| --- | --- |
| Compiled | Yes. `swift build` and `scripts/build.sh` with Xcode 27.2, Swift 6 language mode, no warnings |
| Unit tests | 67 tests in 10 suites pass (`swift test`) |
| Shared protocol | 49 tests pass under `swift test`; builds for iOS with `xcodebuild` |
| How Music is driven | **Raw Apple Events addressed to Music's process id**, sent off the main thread (`RawEventRunner`, evening of 9 November). NSAppleScript is kept only as the reference `msbctl compare` checks against |
| Against real Music.app | Executed through `msbctl`: reads, artwork, all five commands, phone commands, three quits with relaunches |
| Menu-bar app | Launched and quit cleanly with the AppleScript runner. On the night of 9 November, launched again (raw events, relay build) from the shell: registered with a local relay, connected, saved its credential in the Keychain, reconnected with it after a relaunch, and said `goodbye` on each quit. The menu has never been clicked by hand |
| Relay | `RelayTransport` over a WebSocket to the relay on `feature/relay`. **Executed end to end on this Mac** with real Music and a simulated iPhone (below) |
| Xcode app project | Not made. The app is built by `scripts/build.sh` |

## Raw Apple Events

STATUS.md recommended this as the next step this afternoon. It is done and adopted.
Everything below was executed on this Mac on 9 November 2026. Scratch probes were kept out of
the repo.

### What changed

- `RawEventRunner` sends each `MusicScript` as Music's own events, from four-character codes
  read from `sdef /System/Applications/Music.app`. `player state` is `pPlS`, enum `ePlS`
  (`kPSS`, `kPSP`, `kPSp`, `kPSF`, `kPSR`), `player position` is `pPos`, `current track` is
  `pTrk`, `properties` is `pALL`, artwork is `cArt` and its `raw data` is `pRaw`. Reads are
  `core/getd`, counts are `core/cnte`, and the commands are `hook/Play`, `Paus`, `PlPs`,
  `Next` and `Prev`. Each event's target is `NSAppleEventDescriptor(processIdentifier:)`.
- `MusicController` is an actor on its own serial dispatch queue, no longer `@MainActor`.
- The 2 s hold after `playerInfo` "Stopped" is gone. The 3 s settle after NSWorkspace's
  launch notification stays, and reads also wait while Music's process is under 4 s old.
- `MusicProcess` finds Music without NSRunningApplication's flapping (below).
- A send that fails with -600 or -609 because its PID has exited counts as `not_running`.

### Off the main thread

| Where `sendEvent` ran | Median per event | Notes |
| --- | --- | --- |
| Main thread | 8–9.5 ms | Music stopped, nothing loaded; 10 rounds of 8 kinds of event |
| Global GCD queue | 7–9.1 ms | Main thread blocked in `DispatchGroup.wait` throughout |
| Private serial queue | 7.5–9.4 ms | |
| `Thread` | 6.6–9.5 ms | |
| Actor on a serial-queue executor | 7.3–9.5 ms | The arrangement `MusicController` now uses |
| Actor on the cooperative pool | 6.7–9.7 ms | |
| `Task.detached` | 5.9–10 ms | |

The first round was slower: 1.1 s for the very first event, and 0.28 s and 0.54 s for two
others. The slowest single event after that took 94 ms. NSAppleScript took 8–158 s off the
main thread or hung.

| Through `msbctl` | AppleScript (before) | Raw events (now) |
| --- | --- | --- |
| One snapshot, four events | 25–183 ms on the main thread | 22–33 ms on the controller's queue |
| Artwork, four events, 210 KB | 34–51 ms on the main thread | 29–32 ms |
| `msbctl snapshot`, a fresh process | 214–256 ms | 70–100 ms |
| Longest main-thread stall during a read | The whole read | 3 ms, once 17 ms |

### Same output as the AppleScript

- `msbctl compare` ran both runners against the same Music. The `ScriptOutput` values were
  identical for a paused shared track and for Music with nothing loaded. The paused record was
  `paused␟305.531005859375␟when sunday comes around␟Marlon Funaki␟…␟shared track␟1`. With
  nothing loaded it was `stopped␟missing value␟␟␟␟␟0␟␟0␟␟0` and `NO_TRACK`. Matching took
  AppleScript's text rules for reals, measured with `osascript`: up to 12 decimals and
  `1.0e+4` style from 10000 up and at 0.001 and below. The rules are unit-tested with 31
  measured pairs.
- `msbctl snapshot` against the build of the previous commit (AppleScript), three times while
  playing: every field was identical, and only the position differed, by the 0.08–0.10 s between
  the two reads. The `PlaybackMessage` differed only in `elapsedTime`, its `capturedAt`, its
  revision and its listening-session id.
- Artwork bytes are byte-identical to `Prototypes/MusicProbe/artwork.sh`: 210,976-byte JPEG,
  SHA-256 `abf388165d59c4048add262c837084581aaae7238215e09b994c983c5b6d3389`. The descriptor
  type is `tdta`, as from NSAppleScript.
- Errors keep the scripts' `try` blocks. An error in Music's reply, such as -1728 with
  nothing loaded, is ignored where the script ignored it. An error sending (-600, -609,
  -1712, -1743) always fails the read, where the script's `try` would have hidden it.
  `sendEvent` doesn't throw for an error Music sends back: it comes in the reply's `errn`.

### Commands

- `msbctl control` sent pause, play, next, previous and playpause twice. All six were
  `performed`. The read 0.4 s later showed the new state four times. After pause and after
  next it still showed the old one, and the next read 1.5 s later had caught up.
- `msbctl watch` with phone commands: pause and play were acknowledged in 0.47–0.48 s with
  the new state, and previous in 0.61 s. Next took 1.28 s, and its ack carried the pre-skip
  revision: Music still reported the old track, and the poll 0.18 s after the ack published
  the new one. The same check with AppleScript wasn't repeated, so whether raw events changed
  this is unknown.

### Quitting Music

Three quits, each with `NSRunningApplication.terminate()` and with the user's agreement.

1. **Scratch probe, an event every 20 ms to the old PID.** Music answered normally for the
   0.84 s between `terminate()` and exit ("playing"). The event in flight when it exited failed
   with -609 after 505 ms; each one after failed with -600 in 0.5 ms. The probe sent 427 events
   and none launched anything. The log has every event as `target='kpid'[pid=33902]`, then
   `copyPortByPID: Couldn't find a process with pid 33902`. The new Music was launched by
   **Alcove** (`com.henrikruscon.Alcove`): its event addressed by name got `procNotFound`,
   then `LAUNCH: Opening … on behalf of 1822`. The new Music first answered **3.85 s after
   it spawned**, 2.93 s after `didLaunch`. An event sent to it as soon as it appeared timed
   out (-1712).
2. **`msbctl watch` with the quit hold removed, a read asked for every 100 ms.** Every event
   was addressed by PID (`kpid` 45909, then 47519), and `not_running` went out 0.76 s after
   `terminate()`. The new Music was launched by an `osascript` (pid 47516). That's
   `lastfm_scrobbler.py`, which runs `tell application "Music"` every second. Two faults
   showed up:
   - A read reached the new Music 0.12 s after it spawned, before `didLaunch`, and timed
     out, so an `error` frame was published.
   - A false `not_running` was answered with no event sent. NSRunningApplication had listed
     no Music (below).
3. **The same, after the fixes.** Frames: `stopped`, then `not_running` 0.76 s after
   `terminate()`, then `stopped` from the relaunched Music. There were no `error` frames and no
   false `not_running`. All 247 events were `kpid`: 58 to the old Music and 189 to the new one.
   The first to the new one went out 4.04 s after it spawned and was answered. The relauncher
   was the scrobbler's `osascript` again (pid 49418).

LaunchServices logs the requester as `LAUNCH: Asking CSUI to launch` in the requesting process,
and `LAUNCH: Opening … on behalf of <pid>` in CoreServicesUIAgent. `log show --info` finds
both. `appleevents:send` lines show each event's target: `psn '[Music]` for name-addressed
events, `kpid'[pid=…]` for raw ones. Alcove and the scrobbler both send name-addressed
`core/getd` events to Music continually.

### NSRunningApplication lists no Music for a moment

`runningApplications(withBundleIdentifier: "com.apple.Music")` returned an empty list while
Music ran, for about 10 ms, 5 times in 15 s on the main thread. On a background thread sampled
every 1 ms it happened 4 times in 12 s, for 3–15 ms each. The gaps line up with LaunchServices
check-ins of short-lived processes: the scrobbler's `osascript`, every 1.2 s. This was the
companion's process check before today, so it could report Music closed for one read. From
those rates, at a 2 s poll, an estimated one false `not_running` every 5–10 minutes. `MusicProcess` now
remembers Music's PID and checks it with `proc_pidpath` (the kernel). It looks the PID up
again only when that process has gone.

### Holds, as measured

| Hold | Before | Now | Why |
| --- | --- | --- | --- |
| After `playerInfo` "Stopped" | 2 s, nothing sent | **Removed** | PID-addressed events can't relaunch Music. During a quit they're answered until exit, then fail at once. Quit 1 also sent `playerInfo` "Paused", not "Stopped", so the hold could miss a quit anyway |
| After NSWorkspace `didLaunch` | 3 s | **Kept**, 3 s | Music first answered 2.93 s after `didLaunch` |
| While Music's process is young | — | **Added**, 4 s | The process exists about 0.85 s before `didLaunch`. Music first answered 3.85 s after spawn (quit 1). An event 4.04 s after spawn was answered (quit 3) |

## Verified against real Music.app (AppleScript runner, afternoon)

| Check | Result |
| --- | --- |
| Snapshot fields | Match `musicprobe.sh json` for the same track: state, position, title, artist, album, persistent ID, database ID, class, artwork count |
| Artwork bytes | **Byte-identical** to `artwork.sh`: 404,475-byte PNG, SHA-256 `1f9f9de4…38d3`, same across repeated reads. The descriptor type is `tdta`; `.data` is the raw PNG with no wrapper |
| Artwork processing | 800 px PNG → 600 px JPEG of 86 KB in about 90 ms including extraction |
| Commands | play, pause, next and previous each acknowledged, ack revision equal to the state frame that preceded it. Phone command to ack: 0.55–0.62 s, most of it the 0.4 s settle |
| Skip while paused | Stays paused, as the spike found |
| Track identity | `previous` back to a track gives the same `pid:` id |
| Listening session | One id kept through play, pause, next and previous |
| Stale, duplicate, unknown commands | `command_expired` without touching Music; one play for two identical ids, identical acks; `unsupported_command` by id |
| Skip with nothing loaded | `no_current_track`, nothing sent to Music |
| Reconnect | `hello` again, then the same state frame with the same revision |
| `playerInfo` | Received (11 in one 50 s run) and used as a debounced trigger |
| Quit | NSWorkspace terminate → `not_running` sent at once, answered by the process check with no Apple Event |
| Relaunch | NSWorkspace launch → read after a 3 s settle → `stopped` with no track |
| Never launching Music | After the 2 s hold, LaunchServices names another process as the relauncher both times |

## Findings that change the design

1. **NSAppleScript must run on the main thread.** On a GCD queue or `Thread`, a one-event
   script took 8–158 s; on an actor with a serial-queue executor it hung. On main it takes
   5–30 ms, but each read then blocked the UI for 30–620 ms. **Resolved by raw Apple
   Events**, which take 7–10 ms an event on any thread.
2. **One read was eleven Apple Events.** `properties of current track` fetches every track
   field in one; a read is four events, in both runners.
3. **The companion relaunched Music.** An event addressed by name, sent in the second
   between `playerInfo` and Music exiting, made LaunchServices relaunch Music, naming
   `msbctl` as the parent. The 2 s hold fixed it then. **Resolved by addressing Music by
   PID**, verified in three quits; the hold is gone.
4. **Other apps relaunch Music.** `~/Scripts/lastfm_scrobbler.py` (an `osascript` every
   second) and **Alcove** both did, 0.2–0.7 s after an exit. Left alone; neither is part
   of this project. The 2 s hold could never stop them.
5. **Music answers events about 4 s after its process starts.** NSWorkspace reports the
   launch, with `isFinishedLaunching` true, about 3 s before that.
6. **Out-of-order reads.** A notification read taken before a pause landed after the
   pause's own re-read and briefly re-published "playing". Older reads are now dropped.
7. **Wire dates.** A microsecond `capturedAt` didn't survive the millisecond wire format,
   so a re-sent message differed from the original. Fixed in the protocol
   (`StandByWire.wirePrecision`, integer-millisecond formatting).
8. **`play` on a paused track at 0:00 can start a different track.** Music's queue moved on
   to the next item. Music behaviour, not the companion's.
9. **NSRunningApplication can't be the process check.** It lists no Music for 3–15 ms every
   few seconds (above).

## Not verified

- **The menu-bar app with raw events.** Built, not launched: a rebuilt app asks for
  Automation permission again, which needs someone at the Mac. `msbctl` exercised the same
  `CompanionCore` code.
- **The first-run Automation prompt**, with either runner. Every check ran with this shell's
  existing permission. The `automation_denied` path is unit-tested only. Whether raw events
  bring up the prompt the way NSAppleScript does is untested.
- **The menu opened by hand.** Rendered offscreen only.
- **Launch at Login.** The toggle is wired to `SMAppService.mainApp` but was not switched:
  that changes the login items, and the dev build isn't in `/Applications`.
- **A command sent in the 0.85 s between a relaunch and `didLaunch`.** Commands wait for
  the launch settle but don't check the process's age. Such a command can wait 3 s and fail
  `command_failed`.
- **Main-thread cost in daily use.** Measured per read, not over hours.
- **Local files, radio, podcasts, AirPlay, tracks with several artworks.** The raw-event
  compare ran on a "shared track"; the afternoon's AppleScript checks were on "URL track".
- **A real iPhone on the relay.** Only the simulated iPhone (`Relay/tools/mock-phone.mjs`) has
  talked to it, first under `wrangler dev` on this Mac and, on 10 November, on the deployed
  relay: 29/29, including Next, pause and play changing the real Music.app through
  Cloudflare, acknowledged in 62–156 ms round trip.
- **The pairing controls clicked in the running app.** Rendered offscreen in all four states
  against the live relay; the approval itself was given through `msbctl`.
- **Reading Music from inside the app with raw events.** The relay-build app was launched
  from the shell, so it used this shell's Automation permission. Music was paused and nothing
  checked the app's reads.

## Relay connection (night of 9 November)

Executed on this Mac against `wrangler dev` (feature/relay), real Music, and the simulated
iPhone. `Relay/tools/e2e-local.mjs` reproduces it.

| Check | Result |
| --- | --- |
| End-to-end harness, `--playback` | **27/27 passed** |
| End-to-end harness, read-only | 19/19 passed |
| Pairing | Code on the Mac; the phone's claim waited until the Mac said `approve`; the credential came once; the code couldn't be reused |
| Next from the phone | Changed the real song (Let's Go Back → Last Dance; Everything Now → Farolim de Felgueiras). Ack in 7–16 ms |
| Pause and play | Took effect in Music; acks in 8–43 ms; the phone saw the state change |
| Same command id twice | One skip (Last Dance → Wild Horses, the next in the playlist); identical acks |
| Command naming an old session | `409 session_mismatch`; the song didn't change |
| Artwork | 600 px JPEG fetched through its signed URL with no credential; refused without the signature |
| Companion killed, no goodbye | Relay saw it go; a command got `504 mac_unreachable`; the restarted companion reconnected in about 0.1 s |
| Companion restarted mid-song | **First run: a new session**, because the listening session wasn't persisted. Fixed; afterwards the session survived |
| Relay restarted | The Mac backed off 1.9 s, then 4.9 s, reconnected, said `hello`, resent state; same session |
| Unpair | Mac told `revoked`; phone credential dead |

Two changes came out of this:
- The Mac acks a phone command as soon as Music takes it. Its re-read follows as the next
  state frame.
- The listening session is saved, so restarting the companion mid-song doesn't give the phone
  a new Now Playing session.

## For the relay design

- `not_running` arrives within about 0.8 s of `terminate()`, so the relay can end the Now
  Playing session at once instead of waiting for its 60 s grace.
- `goodbye` tells a deliberate companion quit from a dropped socket.
- A phone command now gets its ack in 7–43 ms through the local relay, because the Mac acks
  when Music takes the command and re-reads afterwards. Its revision is the pre-command one;
  the result follows as an ordinary state frame (PROTOCOL.md §5).
- After a relaunch Music can't answer for about 4 s, and a command in that window waits.
- Artwork ids are known before the state frame leaves, so `artwork-request` works as
  proposed.

## Recommended next step

1. At the Mac: launch the menu-bar app with `relayURL` set, allow the Automation prompt, and
   pair from the menu. That covers the prompt, the menu by hand, and the app's own reads.
2. Done on 10 November: the relay is deployed to `workers.dev`, and its APNs probe got
   APNs' own `403 InvalidProviderToken`, so Cloudflare reaches APNs over HTTP/2. The
   `--playback` harness passed 29/29 against the deployment.
3. The iOS side adopts the contract (docs/relay/API-v1.md §13). Then a real phone can
   replace the mock.
