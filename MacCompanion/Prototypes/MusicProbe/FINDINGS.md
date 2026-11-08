# Findings — Music.app integration

8 November 2026. Spike branch `spike/mac-music-integration`.

## Test environment

| | |
| --- | --- |
| macOS | 27.0.1 |
| Music.app | `/System/Applications/Music.app`, running, state `paused` |
| Automation permission | Already granted to Terminal; the first-run prompt was not observed |
| Swift toolchain | **Broken.** No Xcode; `xcode-select -p` is `/Library/Developer/CommandLineTools`; `swiftc` fails with `redefinition of module 'SwiftBridging'` |
| Python | `/usr/bin/python3` present, stdlib only. No PyObjC (`import Foundation` fails) |

Everything below marked **executed** was run on this machine and its output recorded.
Everything marked **written** has not been run anywhere.

## Objectives

| # | Objective | Status |
| --- | --- | --- |
| 1 | Detect whether Music.app is running | **Executed.** Via System Events, which does not launch it |
| 2 | Song title | **Executed** |
| 3 | Artist and album | **Executed** |
| 4 | Track duration | **Executed.** Seconds, fractional |
| 5 | Playback position | **Executed.** Seconds, fractional |
| 6 | Playing / paused / stopped | **Executed.** `playing` and `paused` observed; `stopped` not reached |
| 7 | Play, Pause, Next, Previous, PlayPause | **Executed and verified** — see below |
| 8 | Track-change detection | **Executed.** Distributed notification observed for every change; polling also verified |

## Playback commands and notifications — verified

Run with explicit permission to change playback. `selftest.sh --yes` reproduces it.
Every command was followed by a fresh AppleScript read; nothing was taken on trust from a
clean return.

| Command | Result after re-reading Music.app |
| --- | --- |
| `play` | `paused` → `playing`, position advancing |
| `pause` | `playing` → `paused`, position held |
| `next track` | Track changed, new persistent ID, position reset to 0. **Stays paused if paused** |
| `previous track` | Back to the earlier track, same persistent ID and database ID as before |
| `playpause` | Toggled both ways |

Both paths verified: raw `osascript` in `selftest.sh`, and `musicprobe.sh <cmd> --yes`,
whose 0.4 s settle was enough — the snapshot it returns already shows the new state.

Behaviour worth knowing:

- **`previous track` at position 0 goes to the previous track**, not to the start of the
  current one. Untested: what it does mid-track (likely restarts the track, as the UI does).
- **Skipping while paused does not start playback.** The Lock Screen "next" should not
  assume it implies play.

### `com.apple.Music.playerInfo` — observed

Observed through AppleScriptObjC (`notifywatch.applescript`), which runs under `osascript`
with no compiler — the practical way round the broken Swift toolchain. It is the same
`NSDistributedNotificationCenter` API `MusicProbe.swift` uses, so this verifies that path's
mechanism, though not the Swift file itself.

- **Fired on play, pause, and every track change.** Eleven notifications across eight
  commands.
- **Duplicates are normal.** A single play produced two `Playing` notifications. Debounce,
  or compare against the last snapshot — `changeKey` already does.
- The last pause in the run produced no notification inside the 30 s watch window; the run
  overran the window, so this is most likely a test artefact, not a miss. `selftest.sh` now
  listens for 45 s.
- **The payload is not enough on its own.** Keys seen: `Name`, `Artist`, `Album`, `Genre`,
  `Player State`, `Total Time`. **No persistent ID and no position.** `Total Time` (ms) also
  wobbled for one track — 473162, 473000, 473114 — so it is not a reliable identity field.

**Use the notification as a trigger, then re-read via AppleScript.** That is what
`MusicProbe.swift` does already, and this test is why.

## Track identity — verified

| Track | persistent ID | database ID | class |
| --- | --- | --- | --- |
| Losing My Edge | `542CEB17C137B39E` | 86657 | URL track |
| Idontknow | `542CEB17C137B3A5` | 132799 | URL track |
| Dreamland | `542CEB17C137B3AC` | 132810 | URL track |

- **Revisiting a track gives the same persistent ID and database ID.** Checked by going
  next, next, previous, previous, and again through `musicprobe.sh`.
- **Track change vs position change is unambiguous**: a track change alters the persistent
  ID and resets position to 0; a seek or tick does neither.
- The persistent IDs are near-sequential (`…B39E`, `…B3A5`, `…B3AC`). That suggests they
  identify an entry in this queue or playlist rather than the catalogue song. **Untested:**
  whether the same song reached from a different album, playlist or search gets the same ID,
  and whether IDs survive a Music.app restart. Music was not restarted, per the brief.

**Recommended identity strategy:**

- **Song identity** = `persistent ID`. Fall back to `name|artist|album` if it is ever blank.
  Never `database ID` alone, never `Total Time`.
- **Playback-session identity** is a different thing and should not be derived from the
  song. Mint it on the Mac (or in the relay, as the relay design proposes) when playback
  starts after a stop or a disconnect, and keep it across track changes. A session is "this
  run of listening"; a song is one item in it.
- **Change detection** = `changeKey` (running, state, persistent ID, title, artist, album),
  which excludes position. Position travels separately as `elapsedTime` + `capturedAt` and
  the iOS side extrapolates it.

## Recorded output

```
Music.app: running
State:     paused
Track:     Losing My Edge
Artist:    LCD Soundsystem
Album:     LCD Soundsystem
Duration:  473.1s
Position:  251.0s
Class:     URL track
Artworks:  1
ID:        542CEB17C137B39E (db 86657)
```

## The catalogue-track limitation

This was the specific risk named in the brief: earlier macOS versions returned empty or
missing metadata for Apple Music catalogue tracks that are not in the user's library.

**On macOS 27.0.1 it did not reproduce.** The track above is exactly that case — AppleScript
reports `class` as `URL track`, which is what a streamed catalogue item is, rather than
`file track` for a local file. Every field needed by the relay came back correctly:

| Property | Result on a `URL track` |
| --- | --- |
| `name`, `artist`, `album` | Correct |
| `duration` | Correct, `473.114` |
| `player position` | Correct, fractional |
| `persistent ID` | Present, `542CEB17C137B39E` |
| `database ID` | Present, `86657` |
| `count of artworks` | `1` — artwork is reachable |
| `album artist` | **Empty.** The only property that came back blank |

Caveats, stated plainly:

- **n = 1.** One catalogue track, paused, on one machine. This is evidence that the old
  failure mode is gone on macOS 27, not proof that every catalogue track behaves.
- `album artist` being empty may be a property of this release rather than of catalogue
  tracks. Do not rely on it; fall back to `artist`.
- Not tested: tracks with no artwork, radio streams, podcasts, audiobooks, local files
  (`file track`), shared-library tracks (`shared track`), or anything while `playing`.
- Reading `current track` while stopped throws. Every property access in the script is
  wrapped for that reason.

**Recommendation:** treat every property except `name` as optional, and read `class of
current track` on every refresh so the app can tell local from streamed and report
anything unexpected rather than silently emitting blanks.

## API choice

| Approach | Verdict |
| --- | --- |
| **AppleScript via `osascript` / `NSAppleScript`** | **Recommended.** Works today, no headers, no build step, one round trip per refresh. What both files here use |
| **ScriptingBridge** | Viable but heavier: needs `sdef`/`sdp`-generated headers for Music.app, regenerated whenever the dictionary changes, and it fails in the same way when Automation is denied. No capability advantage found for this job |
| **Raw Apple Events (`NSAppleEventDescriptor`)** | Most control, most code. Only worth it if `NSAppleScript`'s per-call overhead shows up in profiling. It will not at a 2 s poll |
| **MediaRemote** | **Excluded.** Private. Would give system-wide Now Playing including other apps, which is tempting and still out of bounds |
| **`com.apple.Music.playerInfo` distributed notification** | **Recommended as the change signal**, with polling as backup. Public and long-standing. Its `userInfo` carries metadata, but that payload is undocumented — use it as a trigger only and re-read the authoritative state |

## What this means for the companion app

1. **The AppleScript route is sufficient.** Every field the relay design needs for
   `PlaybackMessage` is obtainable, including a stable track identifier and artwork.
2. **Notification first, poll second.** Register for `playerInfo`, keep a 2 s timer to
   catch anything missed and keep `position` honest. Do not poll faster: every call is an
   Apple Event round trip into another process.
3. **Emit on change, not on tick.** `MusicSnapshot.changeKey` excludes `position`, which
   is the same coalescing rule the relay design wants for push updates.
4. **Automation permission is a first-class state.** Error `-1743` is permanent until the
   user fixes it in System Settings. The app needs a visible "Music access denied" state,
   not a silent empty view.
5. **Never launch Music.app as a side effect.** Ask the running-application list first.
   `tell application "Music" to …` launches it, which would be a nasty surprise at login.

## Artwork extraction — works

Added after the first commit. **Executed**, against the same streamed catalogue track.

`raw data of artwork 1 of current track` returns the real image bytes. AppleScript writes
them with `open for access` / `write`, which is byte-exact — no re-encoding, no PICT
wrapper, no clipboard round trip.

| | |
| --- | --- |
| Format | PNG (`format of artwork 1` returns `«class PNG »`; `sips` agrees) |
| Dimensions | 800 × 800 |
| File size | 376,049 bytes |
| SHA-256 | `70d7210ced944748a7993e51335d627d93bebede61315de62de3314c2413397d` |
| Byte-stable across calls | **Yes.** Two extractions, `cmp` identical, same hash |
| `downloaded of artwork 1` | `false` |

Points worth carrying forward:

- **The hash is a usable cache key.** Repeated extraction of the same track gave
  byte-identical files. That is what makes `sha256` viable as the relay's `artworkID` and
  as a content-addressed filename.
- **`downloaded` is `false` and the bytes still arrive.** Music served full-size artwork
  for a streamed catalogue track that is not in the library — the case the brief flagged as
  historically unreliable. It did not fail here.
- **PNG at 800 × 800 is larger than it needs to be.** 376 KB per track over a push-driven
  relay is wasteful; the relay design's cap is 5 MB, so it fits, but downscaling to ~600 px
  JPEG before upload would cut it by roughly an order of magnitude. Do that in the Mac app,
  after hashing the original — or hash the downscaled bytes instead, and be consistent.
- **A list of live references cannot be coerced to text inside a `tell` block** (error
  -1700). Pull each property into a local first. Both scripts here do.
- One oddity, unexplained: an AppleScript error message once referenced the current track
  as `id 86663` while `database ID` read `86657` before and after. The persistent ID was
  stable throughout. Probably an internal object id rather than the database id, but worth
  watching, since the iOS side keys on track identity.

Not tested: tracks with no artwork (the utility reports an error, that path is written but
unexercised), multiple artworks, local files, or whether the format is ever JPEG.

## Not investigated

Out of scope for this spike, and all relevant to the real app:

- Behaviour while `playing`, and how far `player position` drifts between polls.
- AirPlay and multi-output, `shuffle`/`repeat` state, the play queue.
- What happens when Music.app quits or restarts mid-session, and how `database ID`
  behaves across a restart — which the iOS side's revision rule depends on.
