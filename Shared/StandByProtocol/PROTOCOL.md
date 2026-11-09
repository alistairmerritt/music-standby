# Music StandBy wire protocol — version 1

The contract between the Mac companion, the relay and the iPhone app. The Swift types
in `Sources/StandByProtocol` are the definition; this document explains them, and every
JSON example lives in [`Examples/`](Examples/), where the tests decode and re-encode
each one so they can't drift.

**Status.** Proposed in the pull request that adds this package. Nothing here is
deployed. The relay is still a proposal (`docs/ios/RELAY-DESIGN-8-NOV-2026.md` on
`feature/ios`); this package fixes the messages, not the relay's endpoints or platform.

---

## 1. Coding rules

| Rule | Detail |
| --- | --- |
| Coders | Always `StandByWire.makeEncoder()` / `makeDecoder()`. A default `JSONEncoder` writes dates as seconds since 2001 |
| Dates | ISO-8601 string, UTC, milliseconds: `2026-11-09T07:00:00.250Z`. Decoders also accept no fraction. Numbers are rejected. Senders pass dates through `StandByWire.wirePrecision` before keeping a message, so a re-send is identical to the original |
| UUIDs | Swift writes them upper-case. Decoders accept either case. The relay must compare them case-insensitively |
| Durations, positions | Seconds, as JSON numbers, fractional allowed |
| Revisions | Integers below 2^53, so JavaScript reads them exactly |
| Absent values | Optional fields are omitted, not `null` |
| Unknown keys | Ignored |
| Unknown frame `type` | Decodes as `.unknown` and is ignored |
| Open string sets | `ErrorCode` and `DeviceKind` keep values they don't recognise |
| Closed enums | `PlaybackState` and `CommandKind`. A new case needs a version bump |

**Versioning.** `StandByWire.version` is `1`. A new optional field, frame type, error
code or device kind does not change it. Anything an older peer would misread does. The
Mac states its version in `hello`; the relay answers with `welcome`, or an `error` frame
with `unsupported_protocol_version` and closes.

---

## 2. Identities

Four identities, kept apart on purpose.

| Identity | Field | Minted by | Lifetime |
| --- | --- | --- | --- |
| **Song** | `track.id` | Mac, `TrackID.make` | One Music.app run |
| **Listening session** | `listeningSessionID` | Mac, `ListeningSessionTracker` | Play → stop or quit |
| **Artwork** | `track.artworkID` | Mac, `ArtworkID.make` | Forever (content hash) |
| **Device** | `DeviceIdentity.id` | Each device, first launch | Until reinstalled |

- **Song.** `pid:<Music persistent ID>`, or `key:<32 hex>` (a hash of
  `title|artist|album|seconds`) when Music has no persistent ID. Opaque: compare for
  equality only. The persistent ID was verified stable when revisiting a track within one
  Music run. Whether it survives a Music restart is unknown, and moot for streamed tracks,
  which Music can't reach again after one.
- **Listening session.** Opens when playback starts with none open. Survives track
  changes, pauses and one-off read errors (`error`). Closes on `stopped`, `not_running`
  and `automation_denied`. So a Music restart always ends it. It is **not** the relay's Now
  Playing session id (`MacPlaybackAttributes.id`): the relay mints that, and may end one
  and start another inside a single listening session, e.g. after a 15-minute pause or a
  disconnect grace period.
- **Artwork.** Lowercase hex SHA-256 of the bytes Music.app returns for
  `raw data of artwork 1`, before any resizing. Those bytes were verified byte-stable, so
  the same album always gets the same id whatever encoder later makes the uploaded copy.
  It is a cache key, not a checksum of the upload; `ArtworkDescriptor` describes what is
  actually served. `nil` when the track has no artwork.
- **Device.** A random id stored on first launch. Never a serial number or hardware UUID.

---

## 3. Playback

`PlaybackMessage` is one snapshot of the Mac's playback. The Mac sends one whenever
something visible changes (`hasVisibleChange(from:)`), never for ordinary progress.

| Field | Type | Notes |
| --- | --- | --- |
| `revision` | integer | See §4 |
| `state` | `PlaybackState` | New in v1. See below |
| `isPlaying` | bool | Kept from the temporary contract. Always `state == "playing"`. If the two disagree, `state` wins |
| `elapsedTime` | seconds | Position at `capturedAt` |
| `capturedAt` | date | Receivers extrapolate from here while playing: `elapsed(at:)` |
| `track` | `TrackMetadata`? | Absent when nothing is loaded |
| `canGoNext`, `canGoPrevious` | bool | |
| `listeningSessionID` | UUID? | New. Absent outside a session |
| `detail` | string? | New. Diagnostic text for `automation_denied` and `error`. Not for display |

`PlaybackState` values, matching the prototype's JSON:

| Value | Meaning | Ends the session |
| --- | --- | --- |
| `playing` | | No |
| `paused` | | No |
| `stopped` | Music running, nothing playing or loaded | Yes |
| `not_running` | Music.app closed. The Mac never launches it to check | Yes |
| `automation_denied` | AppleScript −1743. Lasts until the user changes System Settings | Yes |
| `error` | Music running but unreadable. Usually transient | No |

**Visible change** = a different `state`, `track`, `canGoNext`, `canGoPrevious` or
`listeningSessionID`, or a position more than 2 s from where the previous message
predicts (a seek). The relay can coalesce pushes on the same rule.

---

## 4. Revisions

**Revisions from one Mac only ever increase, including across restarts of the
companion.** Each run starts at `max(last persisted revision, Unix time in ms)` and adds
one per message (`RevisionCounter`). Persisting covers a clock that steps backwards;
seeding from the clock covers lost storage.

Receivers apply a message unless its revision is lower than the one they hold
(`isSuperseded(by:)`). An equal revision is a re-send of the same snapshot, e.g. after a
reconnect, and is harmless. No restart heuristic is needed: the iOS app's "accept a lower
revision if it is 5 s newer" rule becomes unnecessary, though it does no harm.

`CommandAck.revision` is the Mac's revision after handling the command. The `state`
frame that shows the result carries that revision or a later one.

---

## 5. Commands

The phone sends a `RemoteCommand`; the Mac answers each with exactly one `CommandAck`.

| Field | Notes |
| --- | --- |
| `id` | UUID. Also the idempotency key: a repeated id must not act twice |
| `kind` | `play`, `pause`, `next`, `previous` — unchanged |
| `issuedAt` | New, optional. The Mac rejects commands older than 10 s with `command_expired` |

`CommandAck` keeps `commandID`, `accepted`, `revision` and adds an optional `error`.
`accepted: true` means Music took the command. The resulting state follows separately.

Mac-side rejections:

| Code | When |
| --- | --- |
| `music_not_running` | Music is closed. The Mac does not launch it |
| `automation_denied` | Permission refused |
| `no_current_track` | `next`/`previous` with nothing loaded |
| `command_expired` | `issuedAt` older than 10 s |
| `unsupported_command` | A `kind` this build doesn't know. `RelayFrame.unsupportedCommand` keeps the id so it can still be rejected |
| `command_failed` | AppleScript ran and failed |

Verified Music behaviour worth knowing: `next` and `previous` while paused stay paused.
`previous` at position 0 goes to the previous track.

---

## 6. WebSocket frames

One JSON object per frame, with a `type`. Domain objects are nested under a key named
for them; small frame-specific fields sit beside `type`.

**Mac → relay** (`MacFrame`)

| `type` | Payload | Example |
| --- | --- | --- |
| `hello` | `protocolVersion`, `device` | [mac-hello](Examples/mac-hello.json) |
| `state` | `message`: `PlaybackMessage` | [playing](Examples/mac-state-playing.json), [not running](Examples/mac-state-not-running.json), [denied](Examples/mac-state-automation-denied.json) |
| `ack` | `ack`: `CommandAck` | [accepted](Examples/mac-ack-accepted.json), [rejected](Examples/mac-ack-rejected.json) |
| `artwork` | `artwork`: `ArtworkDescriptor` | [mac-artwork](Examples/mac-artwork.json) |
| `goodbye` | `reason` | [mac-goodbye](Examples/mac-goodbye.json) |
| `error` | `error`: `ProtocolError` | |

**Relay → Mac** (`RelayFrame`)

| `type` | Payload | Example |
| --- | --- | --- |
| `welcome` | `protocolVersion` | [relay-welcome](Examples/relay-welcome.json) |
| `command` | `command`: `RemoteCommand` | [relay-command](Examples/relay-command.json) |
| `artwork-request` | `artworkID` | [relay-artwork-request](Examples/relay-artwork-request.json) |
| `paired` | `phone`: `DeviceIdentity` | [relay-paired](Examples/relay-paired.json) |
| `revoked` | `reason` | [relay-revoked](Examples/relay-revoked.json) |
| `error` | `error`: `ProtocolError` | [relay-error](Examples/relay-error.json) |

**Phone → relay HTTP bodies:** `CommandRequest` / `CommandResponse` for
`POST /v1/commands` ([request](Examples/http-command-request.json),
[response](Examples/http-command-response.json)), and `ErrorResponse` for every non-2xx
body ([example](Examples/http-error-response.json)).

### Sequences

```
connect     Mac → hello            relay → welcome         Mac → state (current)
command     relay → command        Mac → ack               Mac → state (if it changed)
artwork     Mac → state(artworkID) relay → artwork-request Mac: PUT bytes, → artwork
Music quits Mac → state(not_running) at once. The relay can end the Now Playing session now
app quits   Mac → state, goodbye   The relay needn't wait out its reconnect grace
net drop    nothing                Mac reconnects: hello, then its current state
```

A Music restart and a network drop look nothing alike from the Mac, so the Mac says which
happened: an immediate `not_running` (then `stopped` with no track) for a restart,
silence and a reconnect for a drop.

### Connection status

`ConnectionStatus` is what each app shows about its own link: `phase` (`disconnected`,
`connecting`, `connected`, `reconnecting`, `failed`), plus `peerName`, `since`,
`nextAttemptAt` and `error` where they apply. It never crosses the wire today; it is
Codable so either app can persist or log it.

---

## 7. Changes from the temporary iOS contract and the relay proposal

| Change | Why |
| --- | --- |
| `TrackMetadata.artworkID` is optional | Tracks without artwork exist. An empty-string sentinel would send the phone looking for artwork that isn't there |
| `PlaybackMessage.state` added, `isPlaying` kept | The relay must tell `paused` (keep the session) from `stopped` and `not_running` (end it), and the Mac must report `automation_denied` as itself, never as "closed" |
| `listeningSessionID` added | Song identity and session identity must be separate. Only the Mac sees stops and Music restarts |
| Revision rule defined (§4) | The iOS app was guessing at restarts |
| `RemoteCommand.issuedAt`, `CommandAck.error` added | Stale commands, and a reason the extension can surface when it throws |
| `hello` carries `device` instead of `macName` | The relay needs a stable id as well as a name |
| `artwork` frame nests an `ArtworkDescriptor` | The proposal's flat `sha256` duplicated `artworkID` and lacked content type and size |
| `welcome` and `goodbye` frames added | Version negotiation; telling an app quit from a dropped socket |
| Error bodies are `{"error":{"code":…}}` | The proposal's `{"error":"mac_unreachable"}` had nowhere to put a message or retry time |

Every other temporary type — `CommandKind`, `RemoteCommand`, `CommandAck`, `PairedMac` —
keeps its fields, names and initialisers.

---

## 8. Adopting it in the iOS app

1. Add `Shared/StandByProtocol` as a local package dependency of `StandByKit`, and one
   file, `StandByKit/Sources/StandByKit/Exports.swift`, containing
   `@_exported import StandByProtocol`. The app and the extension then see the shared
   types through `import StandByKit`, as they see the temporary ones today.
2. Delete `StandByKit/Sources/StandByKit/Temporary/TemporaryProtocol.swift`.
   `MockTransport.swift` and `MacPlaybackAttributes+Message.swift` compile against the
   shared types unchanged, apart from step 3.
3. `artworkID` is now optional. Two call sites need a decision about no-artwork tracks:
   `Temporary/MacPlaybackAttributes+Message.swift:14` and `MockLibrary.swift:43`, both
   building a `SessionTrack` from `TrackMetadata.artworkID`.
4. Decode anything from the wire with `StandByWire.makeDecoder()`.
5. Optional: with §4 in place, `MacPlaybackAttributes.shouldBeReplaced(by:)` can drop its
   restart tolerance.

**Checked on 9 November 2026**, on a scratch copy of `feature/ios` at `f77dd3c` and not on
the branch itself: with steps 1–2 and step 3 done as `?? ""`, `StandByKit` compiles in
Swift 6 mode against this package (macOS 26 SDK, Command Line Tools `swiftc`) and all 24
of its existing tests pass. The unmodified branch also passes all 24 on the same tools.
The app and extension targets were not compiled: they need the iOS SDK.

`ConnectionStatus` does not replace StandByKit's own `ConnectionState`. The names differ
on purpose, so both can be imported together.

---

## 9. Not in version 1

- Pairing and token endpoints (relay §4–5). They remain the relay proposal's, and get
  Swift types once the relay design is agreed.
- Volume, seek, shuffle and repeat.
- The artwork upload itself (`PUT /v1/artwork/{id}`), which is HTTP, not a frame.
