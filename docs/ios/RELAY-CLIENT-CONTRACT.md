# Relay client contract — what the iOS app expects

9 November 2026. For the Mac/relay developer.

**Status: draft, awaiting your confirmation.** `Shared/StandByProtocol` v1 fixes the messages but leaves the pairing, token and session endpoints out (`PROTOCOL.md` §9). The iOS client follows `RELAY-DESIGN-8-NOV-2026.md` §4 for those, because nothing else exists. Every path and draft body is in one file, `StandByKit/Sources/StandByKit/Relay/RelayAPI.swift`, so an agreed contract changes that file.

**Nothing here has run against a real relay.** It is tested against scripted HTTP responses only.

## Decisions needed from you

| # | Question | What the client does today |
| --- | --- | --- |
| 1 | **Shape of `GET /v1/session`.** The proposal says only "current session or null" | Expects `{"session":{"sessionID":"…","playback":<PlaybackMessage>}}` or `{"session":null}`. `204` also means none |
| 2 | **Pairing error body.** The proposal has `404 {"error":"unknown_or_expired_code"}`; `PROTOCOL.md` makes every error `{"error":{"code":…}}` and defines `pairing_rejected` | Treats any `404`, `pairing_rejected` or unrecognised code from claim as a rejected code. Suggest `pairing_rejected` in the object form |
| 3 | **Who the phone is.** The proposal's claim sends `deviceName`; the `paired` frame needs a `DeviceIdentity` | Sends both `deviceName` and `device` |
| 4 | **Is polling acceptable?** The app has no socket | Polls `GET /v1/session` every 5 s while foregrounded, and only then |
| 5 | **A `401` ends the pairing** | The app deletes its credential and asks to pair again, so don't return `401` for anything recoverable |

## Endpoints

All calls send `X-Protocol-Version: 1`. If a response carries that header with another value, the client refuses it. Bodies use `StandByWire` coding. Every call except claim sends `Authorization: Bearer <phoneToken>`. Redirects are never followed.

| Call | Sent by | Body | Success |
| --- | --- | --- | --- |
| `POST /v1/pair/claim` | App, no auth | `{"code","deviceName","device":<DeviceIdentity>}` | `200 {"pairingID","phoneToken","mac":<PairedMac>}` |
| `POST /v1/commands` | **Extension** | `CommandRequest`, plus `Idempotency-Key: <command.id>` | `200 CommandResponse` |
| `POST /v1/tokens/start` | App | `{"pushToStartToken":"<hex>"}` | Any 2xx |
| `POST /v1/tokens/session` | Extension | `{"sessionID","pushToken":"<hex>"}` | Any 2xx |
| `DELETE /v1/tokens/session/{id}` | App | None | Any 2xx |
| `GET /v1/session` | App | None | See question 1 |
| `DELETE /v1/pairing` | App | None | Any 2xx. Best effort: the phone forgets the pairing regardless |
| `GET /v1/artwork/{artworkID}` | App, extension | None, `Accept: image/png, image/jpeg` | `200` image bytes with `Content-Type` |

Non-2xx bodies are `ErrorResponse`.

| Response | Client behaviour |
| --- | --- |
| `401`, or `pairing_revoked` | Pairing over: credential deleted, session ended |
| `429`, or `rate_limited` | Reported, using `retryAfter` or the `Retry-After` header |
| `504`, `mac_unreachable`, or no answer in 1.5 s | Command fails: the extension throws |
| Network failure in the foreground loop | Reconnects, backing off 1 s to 30 s. The session is kept for 60 s |

## How commands behave

- The extension posts directly and needs nothing from the main app, which may be suspended or force-quit.
- It waits for the `CommandAck`, and **changes nothing on screen**. The visible result must arrive as a push.
- `accepted: false` makes the handler throw. The relay must answer within the 1.5 s client timeout. The proposal's 1.2 s hold fits; neither number is measured.
- Commands carry `issuedAt`, and the id is the idempotency key.

## What the extension needs from pushes

The push `attributes` decode as `MacPlaybackAttributes`: `id`, `macName`, `revision`, `isPlaying`, `elapsedTime`, `timestamp`, `track`, `canGoNext`, `canGoPrevious`.

- `id` is your session identifier, fresh per session.
- `track.artworkID` is optional. **Prefer omitting `track.artworkURL`.** The extension fetches `/v1/artwork/{artworkID}` itself. A URL is honoured only over HTTPS on the relay's own host, port 443.
- `timestamp` is expected as ISO-8601, unverified until a real push arrives (design §11).
- Send `end` for `stopped`, `not_running` and `automation_denied`. The app ends the session on those too when it is foregrounded.

## Artwork limits

PNG or JPEG only, decided from the bytes. Anything over the limit is treated as no artwork.

| Where | Maximum |
| --- | --- |
| The extension, which is what fills the Lock Screen and StandBy | **1 MB and 800 pixels per side** |
| The foreground app | `ArtworkDescriptor.maximumByteCount` (5 MB) and 4096 pixels per side |

**Please serve artwork at about 600×600.** iOS holds the extension to a hard 6 MB of memory, seen in the system log on an iPhone running iOS 27.2. A 1200-pixel image is about 5.8 MB once decoded. The 800-pixel figure is a judgement from that limit, and real sizes haven't yet been measured on a phone.

## Confirmed on an iPhone

With the mock transport on an iPhone 15 Pro, iOS 27.2, connected by USB. No relay was involved.

- The extension made HTTPS requests from command handlers in 120 to 250 ms, and iOS waited for them.
- The extension read a Keychain item the app had written, on a free developer team.
- iOS logs a "network restriction" for the extension. HTTPS to a public host still worked. Its scope is unknown, so a relay on an unusual port or host type should be tried early.
