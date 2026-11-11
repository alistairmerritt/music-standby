# Mac companion — status

11 November 2026, branch `feature/macos`. macOS 27.0.1, Xcode 27.2 (Swift 6.4.2, macOS 27.2
SDK), Music.app 1.7.

**Renamed to Second Chair on 11 November 2026.** The app is now `build/Second Chair.app`, and its menu and permission text say Second Chair. Its bundle identifier (`com.alistairmerritt.MusicStandBy.Mac`), its `defaults` domain and its Keychain items keep the old name, so approvals and the pairing carry over. Older entries use the old name.

**Executed** means run on this Mac with output recorded. **Not verified** means written and
unit-tested at most.

## Summary

| | State |
| --- | --- |
| Compiled | Yes. `swift build` and `scripts/build.sh` with Xcode 27.2, Swift 6 language mode, no warnings |
| Unit tests | 114 tests in 12 suites pass (`scripts/test.sh`, 11 November evening) |
| Shared protocol | 56 tests in 10 suites pass (`scripts/test.sh`, 10 November); builds for iOS with `xcodebuild` |
| How Music is driven | **Raw Apple Events addressed to Music's process id**, sent off the main thread (`RawEventRunner`, evening of 9 November). NSAppleScript is kept only as the reference `msbctl compare` checks against |
| Against real Music.app | Executed through `msbctl`: reads, artwork, all five commands, phone commands, three quits with relaunches |
| Menu-bar app | Launched and quit cleanly with the AppleScript runner. On the night of 9 November, launched again (raw events, relay build) from the shell: registered with a local relay, connected, saved its credential in the Keychain, reconnected with it after a relaunch, and said `goodbye` on each quit. On 10 November it drove real Music from a real iPhone through the deployed relay (below). The menu has never been clicked by hand |
| Relay | `RelayTransport` over a WebSocket to the relay on `feature/relay`. **Executed end to end on this Mac** with real Music and a simulated iPhone, then a real iPhone (below) |
| Xcode app project | Not made. The app is built by `scripts/build.sh` |

## Seek, volume and output (11 November 2026, evening)

Three value commands from the phone, on top of play, pause, next and previous. All executed on
this Mac against the real Music.app 1.7, with Music paused and the Mac's system output at 0.

| Command | What the Mac does | Executed |
| --- | --- | --- |
| `seek` (`position`, seconds) | `set player position`, clamped to the track | `msbctl control seek 60`: 1.3 s → 60.0 s while paused. Through the relay harness while playing: 30.5 s read back |
| `setVolume` (`level`, 0–1) | `set sound volume` 0–100: **Music's own volume, never the Mac's** | 100 → 40 → 100; harness 1 → 0.3 → 1 |
| `selectOutput` (`outputID`) | `set current AirPlay devices` to that one device, found by id in Music's list | Mac → Study HomePod → Mac. An unknown id is `invalid_request`, nothing sent |

The snapshot gained two fields: `sound volume` and `properties of every AirPlay device`, one
event each (13 devices here: the Mac, AirPods Max, six HomePods, Apple TVs, a TV and a Google
Mini through AirPort Express). A snapshot still reads in 87–101 ms on the controller's queue;
`msbctl compare` is identical to AppleScript on all 13 fields. A device's id is its network
address, or `name:<name>` for the Mac itself, so two devices called "Living Room" (a TV and a
HomePod) stay apart.

Found on the way:

- **`every` is an absolute ordinal in host byte order.** `abso` with big-endian `all ` got
  -1728 from Music; AppleScript's own event prints as `abso($206c6c61)`. An enumeration got
  -10001.
- **Switching output changes Music's volume.** Selecting the Study HomePod set `sound volume`
  to 11 (that device's level), and switching back to the Mac left it at 11. The phone's volume
  slider follows, since the next state carries the new level.
- Music moves a device it has just played to up its list, so `selectOutput` reads the list and
  sets by index within the same few milliseconds.
- Setting `player position` and `sound volume` works while paused, so none of this needs audio.

**From the real iPhone, 12 November morning** (Music paused throughout, system output 0):
seek from Control Centre's scrubber (Music 14 s → 124 s) and from the app (200 s → 59 s → 87 s);
Music's volume from the app (100 → 27) and from the Control Centre slider (35 → 49 → 69, two
coalesced commands); output from the app's Play To picker, Mac → Study HomePod → Mac, twice.

The switch is now sent **without waiting for Music's reply**: a HomePod Music hasn't used
lately took longer than the 5 s wait (-1712), and Music finished the switch after we'd given
up, leaving the ack `command_failed` for a switch that happened. The ack now means the request
reached Music; the next reads show where it plays. Two devices refused by Music itself, from
AppleScript as well, with -15014: the Kitchen HomePod and the Living Room HomePod (checked
12 November; the Study HomePod switched in under 2 s). Music's own AirPlay menu is the
place to look for those.

Unit tests: 114 (was 105). Not done: the menu-bar app has no volume or output controls of its own.

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
- **The keep-alive across a real network drop.** The fix for the 16:54 crash (below) held
  against a local relay that was killed, left half-alive and frozen, but this Mac's own network
  was never turned off or slept.
- **The pairing controls clicked in the running app.** Rendered offscreen in all four states
  against the live relay; the approval itself was given through `msbctl`.

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

## A real iPhone through the deployed relay (10 November)

Executed on this Mac with the menu-bar app launched from `build/`, real Music at volume 0,
and an iPhone 15 Pro running the `feature/ios` build. A UI test on the phone tapped the
Control Centre player while a script on the Mac recorded Music's state.

| Tap on the phone | Music on the Mac | The phone afterwards |
| --- | --- | --- |
| Pause | Paused about 2.1 s after the tap | Showed the Mac's new revision after 1.4 s; the button became Play |
| Play | Playing after about 1.3 s | Revision after 1.2 s; the button became Pause |
| Next | Next track after about 2.7 s | Revision after 1.9 s; new title |
| Previous | Restarted the track, 14 s in, after about 2.6 s | Revision after 1.9 s |
| Pause | Paused after about 1.8 s | Revision after 2.2 s; the button became Play |
| Play | Played on (paused at 16 s, 29 s when the script paused it) | Revision after 1.2 s; the button became Pause |

Every command the phone sent got `200` from the relay. Previous restarted the current track
instead of going back to the one before. That is Music's own `previous track`: sent by
`osascript` 6 s into a track, it restarted it, and sent again at 0 s it went to the track
before. The app does what Music's Back button does.

Two things came out of this:
- **The app crashed at 16:54** in `RelayTransport.keepAlive`: URLSession called a pong handler
  twice, and the second call resumed a continuation already resumed. The pong deadline also
  didn't work, because the task group waited for the ping's handler however long it took.
  Now the first of the pong, the deadline and cancellation settles each ping
  (`RelayTransport.ping`, `RelayPingTests`).
- **`build.sh` signs with the Apple Development identity** when there is one. With an ad-hoc
  signature each rebuild was a new app to macOS, which blocked the app at launch on a
  Keychain prompt for its relay credential.

**Missing artwork is mostly Music's.** After a skip, `count of artworks of current track` was
checked every 0.1 s for 4 s, paused and playing, on six tracks from an autoplay queue
(`URL track`, not in the library, no current playlist). Three read 0 throughout, two read 1
only in the first 0.1 s (likely the previous track's value) and then 0, and one went from 0
to 1 within 0.1 s. One of them stayed at 0 for 25 s more. In an `msbctl` run, four more
skipped tracks got no artwork step at all. With no artwork in Music, the companion sends the
track without an `artworkID` and the phone shows none (seen on the phone as
`Setting nowPlayingInfo artwork (id: (null))`). The two tracks in an `msbctl` run that had
artwork were read, converted and announced within 100 ms of the skip. Where Music's count
arrives late, the companion sends the artwork in a later state frame, which a locked phone
only gets through a push.

**Catalogue artwork since then.** When Music reports no artwork, the companion now asks
Apple's public catalogue (`ITunesCatalogArtwork`, the iTunes Search API) once per track, off
the serial chain, and sends the art in the next state frame. It only takes a result with the
same title and artist, and the same album or a length within 3 s. Executed:
- `msbctl watch` over five skips: the two tracks Music had no artwork for got catalogue art
  0.7 and 0.9 s after the skip; "You Ain't the Problem" matched the album *KIWANUKA*, not
  the remix or the radio edit. The other four used Music's own art and made no lookup.
- On the phone, through the deployed relay: Music reported 0 artworks for "C-Side", and the
  phone showed and downloaded (`200`) its catalogue art.
- Opt out with `defaults write com.alistairmerritt.MusicStandBy.Mac catalogArtwork -bool false`.

**The phone can ask for artwork before the relay has it.** After a Next on the phone, two
artwork downloads started together: one got `404` and the other, 100 ms later, `200`. The
relay asks the Mac for new artwork only when the state naming it arrives, and answered
`404` at once until the Mac's upload landed. Fixed in the relay (`feature/relay`): such a GET
now waits up to 3 s for the upload. Deployed as version `cb80f918`; afterwards, three Nexts
from the phone gave two tracks whose two downloads each got `200`. The third, "Godspeed",
showed no artwork: the phone read the state before its catalogue art arrived, and the
follow-up state needs a push to reach it.

The fixed keep-alive, executed afterwards with `msbctl watch --relay` against `npm run dev`:

| Relay | Result |
| --- | --- |
| Killed with `kill -9` | Reconnecting at once, then retries with backoff up to 30 s. No crash |
| Left as an orphaned `workerd` that accepts connections but never answers | Each attempt timed out after 15 s and was retried |
| Restarted | Welcomed again within 0.1 s of the next attempt |
| Frozen with `SIGSTOP`, so the socket stays open and pongs stop | Dropped 10.5 s after the next ping (connected 20:03:45.5, dropped 20:04:26.0); reconnected 1 s after `SIGCONT`. The old code waited on the frozen socket indefinitely |

On this macOS, `lsof -i` doesn't list the app's WebSocket: the connection shows only as a
`CHAN` descriptor. `nettop -p <pid>` shows its traffic, about 28 bytes of pongs every 30 s.

**Changes at the Mac reach a suspended phone by push (11 November).** With the paid Apple
team and the APNs key in the relay, the phone's app was sent to the Home Screen and left 30 s
so iOS suspended it. Control Centre was then read while the Mac skipped, paused and skipped
again (Music at volume 0). Each change arrived as an APNs push 1.4–3 s after the Mac command,
and Control Centre showed the new track, then Play, then the next track. No Mac code changed:
the fixes were in the relay's APNs sender (`feature/relay`) and in how the phone decodes a
push (`feature/ios`, docs/ios/STATUS.md). Not yet tried: a locked phone and StandBy by hand,
and late catalogue artwork (the "Godspeed" case) arriving by push.

**One session for the whole pairing (11 November).** A session the relay started by push,
after Music stopped and played again, never appeared on the phone: iOS shows only a session
the app asked for while open. The relay and the phone now keep one session through stops,
quits, long pauses and the Mac going away, showing the last track paused. The companion's
`listeningSessionID` no longer changes what the phone sees. Executed on the iPhone with the
app in the background: stop, play, quit Music, relaunch and play; the phone followed each.

**Artwork mixed up between songs (11 November).** Two causes, both in how Music reports
autoplay and radio tracks. First, Music gave every song of an autoplay queue the same
persistent ID (`3C97D19625454E5C` for six different songs), and the companion keyed its
artwork and catalogue caches on it: a song got the previous one's image, or no lookup. Track
IDs are now `pid:<persistent ID>-<12 hex>`, the hex a hash of title, artist, album and
length. Second, after a skip Music can hand out the previous song's image: for 0.9 s once,
for a whole song another time, and once an image it then withdrew. Music's artwork is now
read only 1.5 s after a track change, and an image identical to the previous song's from
another album is read again, then replaced by the catalogue's after 4 s. Executed with
`msbctl watch` over 8 autoplay skips at volume 0: 9 songs, 9 different images; Music's own
art about 1.7 s after each skip; one song that kept the previous image fell back to the
catalogue. 98 tests.

**Artwork uploaded before the state that names it (11 November).** After the fix above, the
phone showed no artwork at all. The companion uploaded an image only when the relay asked for
it, which it does on seeing the state that names it. By then the phone's extension, which iOS
suspends about a second after each update, had already tried to fetch the image and run out
of time. The companion now uploads a new song's artwork before sending that state, once per
connection, and waits at most 2 s (`uploadAheadLimit`) before sending the state anyway. The
upload carries on in the background, and `artwork-request` remains the fallback. Together with
the phone and relay changes (iOS STATUS, relay README), the artwork showed on the iPhone. 100 tests.

**Artwork sooner (11 November).** The wait before trusting Music's artwork after a track
change is now 0.75 s, down from 1.5 s. The previous song's image from another album is still
caught and read again, now 0.5 s later rather than on the next poll. The next song from the same
album (same name and album artist, or artist) shows the previous song's artwork at once, until
Music's own is read. Executed with `msbctl watch` over 8 skips of an autoplay queue at volume 0:
8 songs, 8 different images, each about 1.0 s after the title (1.7 s before). The phone handed
each image over 0.25–0.55 s after the update reached it. All 8 songs were from different
albums, so the same-album case has only unit tests. Seen in passing, and older than this change:
just before a skip takes effect, Music can report the outgoing song with no artwork for about
0.25 s. That sends one state without artwork and an unneeded catalogue lookup. 105 tests.

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
3. Done on 10 November: the iOS side adopted the contract, and a real iPhone drove Music
   through the deployed relay (above). Changes made at the Mac reach a locked phone only
   through a push, and since 11 November those pushes are live (above).
