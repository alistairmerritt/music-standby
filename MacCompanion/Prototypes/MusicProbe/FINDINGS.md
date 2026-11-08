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
| 6 | Playing / paused / stopped | **Executed.** Observed `paused` only |
| 7 | Play, Pause, Next, Previous | **Written, not executed.** Guarded behind `--yes`; not run, per the brief |
| 8 | Track-change detection | **Split.** Polling fallback **executed**; the distributed notification is **written, not observed** |

Objective 8 is the gap. `com.apple.Music.playerInfo` is the long-standing public
notification and `MusicProbe.swift` registers for it, but confirming it fires needs a
playback change, which was out of bounds without approval. Two minutes to verify — README,
last section.

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
